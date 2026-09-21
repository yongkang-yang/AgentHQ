import AgentHQKit
import Foundation
import Observation

/// The fleet: N machine sessions, and one snapshot assembled from them.
///
/// The only place in the app that knows there is more than one machine. Views
/// read ``snapshot``; they never reach into a session.
@MainActor
@Observable
public final class FleetStore {
    public private(set) var snapshot: FleetSnapshot = .empty

    private var sessions: [MachineID: MachineSession] = [:]

    public init() {}

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
        Task { [weak self] in
            await session.start()
            await self?.refresh()
        }
    }

    public func remove(_ id: MachineID) {
        guard let session = sessions.removeValue(forKey: id) else { return }
        Task { [weak self] in
            await session.stop()
            await self?.refresh()
        }
    }

    /// Rebuild the snapshot from every session.
    ///
    /// Assembled as one value and assigned once, so a view never renders a
    /// fleet that is half old and half new.
    public func refresh() async {
        var views: [MachineView] = []
        for session in sessions.values {
            views.append(await session.view())
        }
        views.sort { $0.machine.displayName < $1.machine.displayName }
        snapshot = FleetSnapshot(machines: views)
    }
}
