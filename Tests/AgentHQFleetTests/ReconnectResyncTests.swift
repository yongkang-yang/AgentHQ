import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

/// A client whose herd changes between snapshots, and whose event stream can
/// be driven by the test.
private actor ReconnectClient: HerdrClient {
    private(set) var snapshotCount = 0
    private var status = "working"
    private let continuation: AsyncStream<HerdrEvent>.Continuation
    private let stream: AsyncStream<HerdrEvent>

    init() {
        var cont: AsyncStream<HerdrEvent>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    /// What the agent becomes while the subscription is down.
    func setStatus(_ value: String) { status = value }
    func emit(_ event: HerdrEvent) { continuation.yield(event) }

    func handshake() async throws -> (version: String, protocolVersion: Int) { ("0.9.1", 22) }
    func connect() async throws {}
    func disconnect() async {}

    func snapshot() async throws -> HerdrSnapshot {
        snapshotCount += 1
        return HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: [HerdrPane(
                paneId: "w:p1", workspaceId: "w", tabId: "w:t1",
                // Always `idle` here: a pane record cannot say `done`, which is
                // the whole reason the agent view below exists.
                agentStatus: status == "working" ? "working" : "idle",
                agent: "pi", title: nil, cwd: nil, revision: 0
            )],
            workspaceNames: [:]
        )
    }

    nonisolated func events() -> AsyncStream<HerdrEvent> { stream }
    func readPane(paneId: String, lines: Int, source: PaneReadSource) async throws -> String? { nil }
    func agents() async throws -> [HerdrAgentInfo] {
        [HerdrAgentInfo(paneId: "w:p1", agent: "pi", agentStatus: status, stateChangeSeq: 1)]
    }
    func agent(paneId: String) async throws -> HerdrAgentInfo? {
        HerdrAgentInfo(paneId: "w:p1", agent: "pi", agentStatus: status, stateChangeSeq: 1)
    }
    func sendKeys(paneId: String, keys: [String]) async throws {}
    func sendText(paneId: String, text: String) async throws {}
    func prompt(paneId: String, text: String) async throws {}
    func focusPane(paneId: String) async throws {}
}

@Suite("A machine catches up after its event subscription drops")
struct ReconnectResyncTests {
    private let machine = Machine(
        id: MachineID("wsl"), displayName: "wsl",
        transport: .local(socketPath: "/tmp/agenthq-reconnect-test.sock")
    )

    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(120))
    }

    /// herdr replays nothing on resubscribe, and `resync` otherwise runs only
    /// at start, on a topology event, and after an intervention. Without a
    /// resync here the list stays frozen at whatever it held when the socket
    /// dropped, while the machine goes on reporting itself connected — which
    /// is what "only the local machine updates" looks like from the panel.
    @Test("a state change missed while the subscription was down is picked up")
    func resyncsOnReconnect() async throws {
        let client = ReconnectClient()
        let session = MachineSession(machine: machine, makeClient: { _ in client })

        await session.start()
        try await settle()
        #expect(await session.view().agents.first?.state == .working)

        // The subscription drops, the agent finishes unseen, the subscription
        // comes back.
        await client.emit(.disconnected)
        try await settle()
        await client.setStatus("done")
        await client.emit(.connected)
        try await settle()

        #expect(await session.view().agents.first?.state == .finished)
        await session.stop()
    }

    /// The first `.connected` arrives moments after `start` already synced.
    /// Resyncing on it too would double every machine's startup cost, which
    /// over an ssh tunnel is a snapshot plus a read per pane.
    @Test("the first connect does not resnapshot a machine that just started")
    func firstConnectIsNotADoubleSync() async throws {
        let client = ReconnectClient()
        let session = MachineSession(machine: machine, makeClient: { _ in client })

        await session.start()
        try await settle()
        await client.emit(.connected)
        try await settle()

        #expect(await client.snapshotCount == 1)
        await session.stop()
    }

    /// The panel prints this number, so it has to be counted rather than
    /// invented — it was hardcoded to 1 on every drop.
    @Test("the reconnect attempt count rises across repeated drops")
    func attemptsAreCounted() async throws {
        let client = ReconnectClient()
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.start()
        try await settle()

        await client.emit(.disconnected)
        try await settle()
        #expect(await session.view().reachability == .reconnecting(attempt: 1))

        await client.emit(.disconnected)
        try await settle()
        #expect(await session.view().reachability == .reconnecting(attempt: 2))
        await session.stop()
    }
}
