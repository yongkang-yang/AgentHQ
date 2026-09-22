import AgentHQKit
import AgentHQTransport
import Foundation
import Observation

/// The fleet: N machine sessions, and one snapshot assembled from them.
///
/// The only place in the app that knows there is more than one machine. Views
/// read ``snapshot``; they never reach into a session.
@MainActor
@Observable
public final class FleetStore {
    static let localMachineID = MachineID("agenthq-local")

    public private(set) var snapshot: FleetSnapshot = .empty

    private var sessions: [MachineID: MachineSession] = [:]
    private var sessionsRevision: UInt64 = 0
    private var refreshTask: Task<Void, Never>?
    private var hasStarted = false
    private var notificationPolicy = NotificationPolicy()
    private let dwellStore = DwellStore()
    private var restorableDwell: [DwellRecord] = []
    private var dwellSaveRevision: UInt64 = 0

    /// Called with whatever the policy decided is worth saying, after each
    /// refresh. The store does not know what a notification is; it only knows
    /// when the fleet changed.
    public var onAnnouncements: (@MainActor (AnnouncementBatch) -> Void)?

    /// Whether a finished run is worth a notification. Set from the user's
    /// preference; the policy still owns every other question of whether to
    /// say something, which is what keeps those rules testable without a
    /// notification centre.
    public var announcesCompletions: Bool {
        get { notificationPolicy.announcesCompletions }
        set { notificationPolicy.announcesCompletions = newValue }
    }

    public init() {}

    // MARK: - Lifecycle

    /// Everything the app does at launch, in order. Idempotent: the view that
    /// calls it can be re-created, and reaping tunnels a second time would
    /// take down the ones this store just opened.
    public func start(localSocketPath: String?) {
        guard !hasStarted else { return }
        hasStarted = true

        // Before anything connects: an `ssh -N -L` outlives a crashed or
        // force-quit AgentHQ, and its leftover socket is indistinguishable
        // from a live one.
        TunnelReaper.reap()

        // Read before any machine connects, so the first herd each one reads
        // can be stamped with what it was waiting on last time.
        Task { [weak self] in
            let records = await self?.dwellStore.load() ?? []
            await MainActor.run { self?.restorableDwell = records }
            await MainActor.run {
                self?.importHerdrMachines(includingLocal: localSocketPath)
                self?.startRefreshLoop()
            }
        }
    }

    /// Stop polling. The sessions keep their tunnels; use `remove` to close one.
    public func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Poll the sessions and rebuild the snapshot.
    ///
    /// A poll, not a push, and cheap: each session already holds its own state
    /// and the network work happens inside it, driven by herdr's events. This
    /// loop only copies what the sessions already know into the value the
    /// views read. Without it the panel would render once and never change —
    /// the sessions would keep updating and nothing would ask them.
    private func startRefreshLoop(interval: Duration = .milliseconds(1500)) {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
    }

    public var signal: FleetSignal { snapshot.signal }

    /// Adopt every machine herdr already knows about, plus this Mac.
    ///
    /// Machines already present are left alone, so this is safe to call again
    /// after the user adds one in herdr.
    public func importHerdrMachines(
        includingLocal localSocketPath: String? = nil
    ) {
        if let localSocketPath, !sessions.values.contains(where: { $0.machine.transport.isLocal }) {
            add(Machine(
                id: Self.localMachineID,
                displayName: "This Mac",
                transport: .local(socketPath: localSocketPath)
            ))
        }
        for machine in HerdrMachineRegistry.machines() where sessions[machine.id] == nil {
            add(machine)
        }
    }

    public func add(_ machine: Machine) {
        let session = MachineSession(machine: machine)
        sessions[machine.id] = session
        sessionsRevision &+= 1
        let records = restorableDwell
        Task { [weak self] in
            await session.prime(dwell: records)
            await session.start()
            await self?.refresh()
        }
    }

    /// Turn a machine on or off without forgetting it.
    ///
    /// Disabling tears the tunnel down; the machine stays in the list so the
    /// user can see it is theirs and off, rather than wondering where it went.
    public func setEnabled(_ isEnabled: Bool, for id: MachineID) {
        guard let session = sessions[id] else { return }
        var machine = session.machine
        guard machine.isEnabled != isEnabled else { return }
        machine.isEnabled = isEnabled

        sessions[id] = MachineSession(machine: machine)
        sessionsRevision &+= 1
        Task { [weak self, session] in
            await session.stop()
            await self?.sessions[id]?.start()
            await self?.refresh()
        }
    }

    /// Try a machine again now, rather than waiting for a reconnect cycle.
    public func retry(_ id: MachineID) {
        guard let session = sessions[id] else { return }
        Task { [weak self] in
            await session.stop()
            await session.start()
            await self?.refresh()
        }
    }

    public func remove(_ id: MachineID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        sessionsRevision &+= 1
        Task { [weak self] in
            await session.stop()
            await self?.refresh()
        }
    }

    // MARK: - Interventions

    /// Act on one agent, wherever it is.
    ///
    /// Routed by machine rather than searched for by pane id: pane ids are only
    /// unique within a machine, so searching every session for one is how a
    /// keystroke ends up on the wrong host.
    public func perform(_ intervention: Intervention, on ref: AgentRef) async throws {
        guard let session = sessions[ref.machine] else { throw InterventionError.agentGone }
        try await session.perform(intervention, on: ref.agent)
        await refresh()
    }

    /// One agent's recent output, verbatim, fetched when a row asks to show
    /// it. Routed by machine for the same reason interventions are: a pane id
    /// is only unique within its own herd.
    public func transcript(for ref: AgentRef, lines: Int = 200) async throws -> String {
        guard let session = sessions[ref.machine] else { throw InterventionError.agentGone }
        return try await session.transcript(for: ref.agent, lines: lines)
    }

    /// Rebuild the snapshot from every session.
    ///
    /// Assembled as one value and assigned once, so a view never renders a
    /// fleet that is half old and half new.
    public func refresh() async {
        let revision = sessionsRevision
        var views: [MachineView] = []
        for session in sessions.values {
            views.append(await session.view())
        }
        // An older refresh may finish after a machine was removed or replaced.
        // Its views must not restore that machine to the snapshot.
        guard revision == sessionsRevision else { return }
        views.sort { $0.machine.displayName < $1.machine.displayName }
        snapshot = FleetSnapshot(machines: views)

        let batch = notificationPolicy.announcements(for: snapshot)
        if !batch.isEmpty { onAnnouncements?(batch) }

        dwellSaveRevision &+= 1
        await dwellStore.save(snapshot, revision: dwellSaveRevision)
    }
}
