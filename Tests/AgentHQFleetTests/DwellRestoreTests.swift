import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

private actor DwellClient: HerdrClient {
    var sequence: UInt64

    init(sequence: UInt64) { self.sequence = sequence }

    func setSequence(_ value: UInt64) { sequence = value }

    func handshake() async throws -> (version: String, protocolVersion: Int) {
        ("0.9.1", 22)
    }
    func connect() async throws {}
    func disconnect() async {}
    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: [HerdrPane(
                paneId: "w:p1", workspaceId: "w", tabId: "w:t1",
                agentStatus: "idle", agent: "claude", title: nil,
                cwd: nil, revision: 0
            )],
            workspaceNames: [:]
        )
    }
    nonisolated func events() -> AsyncStream<HerdrEvent> { AsyncStream { _ in } }
    func readPane(paneId: String, lines: Int) async throws -> String? { nil }
    func agents() async throws -> [HerdrAgentInfo] {
        [HerdrAgentInfo(
            paneId: "w:p1", agent: "claude", agentStatus: "idle",
            stateChangeSeq: sequence
        )]
    }
    func agent(paneId: String) async throws -> HerdrAgentInfo? { nil }
    func sendKeys(paneId: String, keys: [String]) async throws {}
    func sendText(paneId: String, text: String) async throws {}
    func prompt(paneId: String, text: String) async throws {}
    func interrupt(paneId: String) async throws {}
    func focusPane(paneId: String) async throws {}
}

@Suite("dwell restoration through the fleet")
struct DwellRestoreTests {
    private let enteredAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let machine = Machine(
        id: MachineID("test-machine"), displayName: "test",
        transport: .local(socketPath: "/tmp/agenthq-dwell-test.sock")
    )

    private func agent(on machine: Machine) -> Agent {
        Agent(
            ref: AgentRef(machine: machine.id, agent: AgentID("w:p1")),
            provider: "claude", state: .idle,
            stateEnteredAt: enteredAt, stateSeq: 42
        )
    }

    private func view(_ machine: Machine, _ reachability: MachineReachability,
                      agents: [Agent]) -> MachineView {
        MachineView(machine: machine, reachability: reachability, agents: agents)
    }

    @Test("a saved clock reaches the first live snapshot after restart")
    func restoresThroughSession() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agenthq-dwell-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = DwellStore(url: url)
        await writer.save(FleetSnapshot(machines: [view(machine, .connected,
                                                        agents: [agent(on: machine)])]),
                          revision: 1)

        let records = await DwellStore(url: url).load()
        let client = DwellClient(sequence: 42)
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.prime(dwell: records)
        await session.start()
        defer { Task { await session.stop() } }

        let restored = try #require(await session.view().agents.first)
        #expect(restored.state == .idle)
        #expect(restored.stateSeq == 42)
        #expect(restored.stateEnteredAt == enteredAt)

        try await session.resync()
        #expect(await session.view().agents.first?.stateEnteredAt == enteredAt)

        // The agent left idle and returned between snapshots. Its state looks
        // the same, but the new sequence means the old wait has ended.
        await client.setSequence(43)
        try await session.resync()
        let moved = try #require(await session.view().agents.first)
        #expect(moved.state == .idle)
        #expect(moved.stateSeq == 43)
        #expect(moved.stateEnteredAt > enteredAt)
    }

    @Test("a disconnected machine keeps its last clock until it reconnects")
    func preservesDisconnectedMachine() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agenthq-dwell-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        let store = DwellStore(url: url)
        await store.save(FleetSnapshot(machines: [view(machine, .connected,
                                                       agents: [agent(on: machine)])]),
                         revision: 1)
        await store.save(.empty, revision: 2)
        await store.save(FleetSnapshot(machines: [view(machine, .unreachable(reason: "offline"),
                                                       agents: [])]),
                         revision: 3)
        #expect(await store.load().count == 1)

        await store.save(FleetSnapshot(machines: [view(machine, .connected, agents: [])]),
                         revision: 4)
        #expect(await store.load().isEmpty)
    }
}
