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
    private var client: (any HerdrClient)?

    private var reachability: MachineReachability
    private var agents: [Agent] = []

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
            _ = try await transport.activate()
            // TODO(milestone 2): construct LiveHerdrClient over the returned
            // socket path, connect, snapshot, and run the event loop. Until the
            // client is ported there is nothing to connect to.
            reachability = .unreachable(reason: "herdr client not implemented yet")
        } catch {
            reachability = .unreachable(reason: String(describing: error))
        }
    }

    public func stop() async {
        await client?.disconnect()
        client = nil
        await transport.deactivate()
        reachability = machine.isEnabled ? .connecting : .disabled
        // Agents are kept, not cleared: the last known list is what the UI
        // shows as stale. Clearing it would make a dropped tunnel look like
        // every agent vanished.
    }
}
