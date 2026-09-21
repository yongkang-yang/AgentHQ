import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

private let socketPath = ProcessInfo.processInfo.environment["AGENTHQ_HERDR_SOCKET"]

/// The whole stack against a herdr running on this Mac: transport → client →
/// session → fleet snapshot. Opt in with `AGENTHQ_HERDR_SOCKET`.
@Suite(
    "fleet against live herdr",
    .enabled(if: socketPath != nil, "set AGENTHQ_HERDR_SOCKET to run")
)
struct FleetIntegrationTests {
    /// A stored property, not computed: `Machine.init` generates a fresh
    /// MachineID every call, so a computed one would hand out a different
    /// machine to each access and no identity assertion could ever hold.
    private let machine = Machine(
        displayName: "this mac",
        transport: .local(socketPath: socketPath ?? "")
    )

    @Test("a local machine connects and reports its agents")
    func localMachineConnects() async throws {
        let session = MachineSession(machine: machine)
        await session.start()
        defer { Task { await session.stop() } }

        let view = await session.view()
        #expect(view.reachability == .connected)
        #expect(!view.agentsAreStale)

        for agent in view.agents {
            #expect(agent.ref.machine == machine.id)
            #expect(!agent.provider.isEmpty)
        }
    }

    @Test("dwell survives a resync")
    func dwellIsCarriedForward() async throws {
        // A refresh that resets every timer makes the panel report that
        // nothing has been waiting longer than one poll interval.
        let session = MachineSession(machine: machine)
        await session.start()
        defer { Task { await session.stop() } }

        let before = await session.view().agents
        try #require(!before.isEmpty, "needs at least one agent running under herdr")
        let entered = Dictionary(before.map { ($0.ref, $0.stateEnteredAt) },
                                 uniquingKeysWith: { a, _ in a })

        try await session.resync()

        for agent in await session.view().agents where entered[agent.ref] != nil {
            if agent.state == before.first(where: { $0.ref == agent.ref })?.state {
                #expect(agent.stateEnteredAt == entered[agent.ref])
            }
        }
    }

    @Test("the fleet assembles a snapshot with a usable signal")
    @MainActor
    func fleetSnapshot() async throws {
        let store = FleetStore()
        store.add(machine)

        // add() starts the session in the background; poll until it settles.
        for _ in 0..<40 {
            await store.refresh()
            if store.snapshot.machines.first?.reachability == .connected { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        let snapshot = store.snapshot
        #expect(snapshot.machines.count == 1)
        #expect(snapshot.machines.first?.reachability == .connected)

        let grouped = AttentionGroup.allCases.flatMap { snapshot.agents(in: $0) }
        #expect(grouped.count == snapshot.allAgents.count)

        let signal = snapshot.signal
        #expect(signal.unreachableMachineCount == 0)
        #expect(signal.attentionCount + signal.workingCount <= snapshot.allAgents.count)
    }
}
