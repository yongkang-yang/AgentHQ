import AgentHQHerdr
import AgentHQKit
import AgentHQTransport
import Foundation

/// Everything that happens on behalf of one machine: bring the transport up,
/// speak herdr over it, keep a current agent list, and report reachability.
///
/// One session per machine, each failing and recovering independently. A
/// machine going dark must never stall the others — which is why this owns its
/// own transport, client, and event loop rather than sharing a pool.
public actor MachineSession {
    public let machine: Machine

    private let transport: any Transport
    private var client: LiveHerdrClient?
    private var eventTask: Task<Void, Never>?

    private var reachability: MachineReachability
    private var agents: [Agent] = []
    private var herdrVersion: String?
    /// workspaceId -> label, from the last snapshot. A `pane_updated` event
    /// carries ids but not labels, so patching one in place needs this.
    private var workspaceNames: [String: String] = [:]

    public init(machine: Machine) {
        self.machine = machine
        self.transport = machine.transport.makeTransport(for: machine.id)
        self.reachability = machine.isEnabled ? .connecting : .disabled
    }

    /// The machine as the fleet currently sees it.
    public func view() -> MachineView {
        MachineView(machine: machine, reachability: reachability, agents: agents)
    }

    public func start() async {
        guard machine.isEnabled else {
            reachability = .disabled
            return
        }
        reachability = .connecting

        do {
            let socketPath = try await transport.activate()
            let client = LiveHerdrClient(socketPath: socketPath)
            let handshake = try await client.ping()
            try await client.connect()

            self.client = client
            self.herdrVersion = handshake.version
            reachability = .connected
            try await resync()
            startEventLoop(client)
        } catch {
            // The reason is shown verbatim in the panel. Transport errors
            // already read as sentences ("build-box accepted the tunnel but
            // nothing is listening on …"), which is why they are not wrapped
            // into a generic "connection failed" here.
            reachability = .unreachable(reason: String(describing: error))
        }
    }

    public func stop() async {
        eventTask?.cancel()
        eventTask = nil
        await client?.disconnect()
        client = nil
        await transport.deactivate()
        reachability = machine.isEnabled ? .connecting : .disabled
        // Agents are kept, not cleared: the last known list is what the UI
        // shows as stale. Clearing it would make a dropped tunnel look like
        // every agent vanished.
    }

    /// Pull a full snapshot and replace the agent list.
    public func resync() async throws {
        guard let client else { return }
        let snapshot = try await client.snapshot()
        workspaceNames = snapshot.workspaceNames
        agents = reconcile(snapshot.agents(on: machine.id))
    }

    /// Carry dwell forward across refreshes.
    ///
    /// `stateEnteredAt` has to survive a resnapshot, or every refresh resets
    /// every timer and the panel reports that nothing has been waiting longer
    /// than one poll interval.
    private func reconcile(_ incoming: [Agent]) -> [Agent] {
        let previous = Dictionary(agents.map { ($0.ref, $0) }, uniquingKeysWith: { a, _ in a })
        return incoming.map { agent in
            guard let old = previous[agent.ref], old.state == agent.state else { return agent }
            var carried = agent
            carried.stateEnteredAt = old.stateEnteredAt
            return carried
        }
    }

    private func startEventLoop(_ client: LiveHerdrClient) {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            for await event in client.events() {
                guard let self, !Task.isCancelled else { return }
                await self.apply(event)
            }
        }
    }

    private func apply(_ event: HerdrEvent) async {
        switch event {
        case .paneUpdated(let pane):
            // `data.pane` is the full pane record, so this patches in place.
            // Resnapshotting per event would cost a round trip each time —
            // ~115ms to a machine across an ssh tunnel — and a chatty agent
            // emits these continuously.
            patch(pane)

        case .paneClosed(let paneId):
            agents.removeAll { $0.ref.agent.raw == paneId }

        case .topologyChanged:
            // Labels moved. These events carry no pane, and rebuilding a
            // rename from them is how label maps drift out of sync.
            try? await resync()

        case .connected:
            reachability = .connected

        case .disconnected:
            reachability = .reconnecting(attempt: 1)
        }
    }

    /// Apply one pane to the agent list, preserving dwell when the state has
    /// not actually changed.
    private func patch(_ pane: HerdrPane) {
        let incoming = HerdrSnapshot(
            herdrVersion: herdrVersion ?? "",
            protocolVersion: 0,
            panes: [pane],
            workspaceNames: workspaceNames
        ).agents(on: machine.id)

        // A pane that stopped being an agent — the agent exited but the shell
        // lives on — drops out of the list rather than freezing on its last
        // state.
        guard let agent = incoming.first else {
            agents.removeAll { $0.ref.agent.raw == pane.paneId }
            return
        }

        if let index = agents.firstIndex(where: { $0.ref == agent.ref }) {
            var updated = agent
            if agents[index].state == agent.state {
                updated.stateEnteredAt = agents[index].stateEnteredAt
            }
            agents[index] = updated
        } else {
            agents.append(agent)
        }
    }
}
