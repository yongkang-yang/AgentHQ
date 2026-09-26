import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

/// A client that behaves the way herdr 0.9.1 does with no client attached:
/// a turn ending changes `agent.list` and pushes no `pane_updated`. Whether a
/// `pane.agent_status_changed` goes out is up to the test.
private actor SilentClient: HerdrClient {
    private(set) var watched: [Set<String>] = []
    private var status = "working"
    private var seq: UInt64 = 10

    private let continuation: AsyncStream<HerdrEvent>.Continuation
    private let stream: AsyncStream<HerdrEvent>

    init() {
        var cont: AsyncStream<HerdrEvent>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    /// The turn ends. herdr's own views move; no pane record is pushed.
    func finishTurn(announcing: Bool) {
        status = "idle"
        seq += 1
        if announcing {
            continuation.yield(.agentStatusChanged(paneId: "w:p1", status: "idle"))
        }
    }

    func handshake() async throws -> (version: String, protocolVersion: Int) { ("0.9.1", 22) }
    func connect() async throws {}
    func disconnect() async {}

    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: [HerdrPane(
                paneId: "w:p1", workspaceId: "w", tabId: "w:t1",
                agentStatus: status, agent: "claude",
                title: "t", cwd: "/tmp", revision: 0
            )],
            workspaceNames: ["w": "repo"]
        )
    }

    nonisolated func events() -> AsyncStream<HerdrEvent> { stream }
    func readPane(paneId: String, lines: Int, source: PaneReadSource) async throws -> String? { nil }
    func agents() async throws -> [HerdrAgentInfo] {
        [HerdrAgentInfo(paneId: "w:p1", agent: "claude", agentStatus: status, stateChangeSeq: seq)]
    }
    func agent(paneId: String) async throws -> HerdrAgentInfo? {
        HerdrAgentInfo(paneId: "w:p1", agent: "claude", agentStatus: status, stateChangeSeq: seq)
    }
    func sendKeys(paneId: String, keys: [String]) async throws {}
    func sendText(paneId: String, text: String) async throws {}
    func prompt(paneId: String, text: String) async throws {}
    func focusPane(paneId: String) async throws {}
    func watchAgentStatus(paneIds: Set<String>) async { watched.append(paneIds) }
}

/// With every Ghostty window closed, a finished turn stayed on Working in the
/// panel and in the console: herdr pushed `pane_updated` for `working` and
/// nothing for the return to `idle`. Measured against herdr 0.9.1.
@Suite("A turn that ends with no client attached still reads as finished")
struct AgentStatusWatchTests {
    private func session(_ client: SilentClient, interval: Duration = .seconds(60)) -> MachineSession {
        MachineSession(
            machine: Machine(
                id: MachineID("m"), displayName: "this mac",
                transport: .local(socketPath: "/tmp/agenthq-watch-test.sock")
            ),
            makeClient: { _ in client },
            supervisionInterval: interval
        )
    }

    @Test("the session watches the status of every agent pane it lists")
    func watchesListedPanes() async {
        let client = SilentClient()
        let session = session(client)
        await session.start()
        #expect(await client.watched.last == ["w:p1"])
        await session.stop()
    }

    @Test("a status event alone moves a working row to finished")
    func statusEventFinishesTheRow() async throws {
        let client = SilentClient()
        let session = session(client)
        await session.start()
        #expect(await session.view().agents.first?.state == .working)

        await client.finishTurn(announcing: true)
        try await Task.sleep(for: .milliseconds(120))

        let row = await session.view().agents.first
        #expect(row?.state == .finished)
        // The stamp for the state shown, not the working one: invariant 8.
        #expect(row?.stateSeq == 11)
        await session.stop()
    }

    /// The watch is dropped and reopened whenever the set of panes changes,
    /// and a transition inside that gap is not replayed.
    @Test("a transition no event reported is caught by the next supervisor tick")
    func reconcileCatchesAMissedTransition() async throws {
        let client = SilentClient()
        let session = session(client, interval: .milliseconds(50))
        await session.start()
        #expect(await session.view().agents.first?.state == .working)

        await client.finishTurn(announcing: false)
        try await Task.sleep(for: .milliseconds(300))

        #expect(await session.view().agents.first?.state == .finished)
        await session.stop()
    }
}
