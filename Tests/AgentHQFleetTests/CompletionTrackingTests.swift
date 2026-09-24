import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

/// A client whose agent status the test drives, standing in for herdr.
private actor StatusClient: HerdrClient {
    private(set) var focused: [String] = []
    private var status: String
    private var seq: UInt64 = 50

    init(status: String = "working") { self.status = status }

    func set(_ value: String) {
        status = value
        seq += 1
    }

    func handshake() async throws -> (version: String, protocolVersion: Int) { ("0.9.1", 22) }
    func connect() async throws {}
    func disconnect() async {}

    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: [HerdrPane(
                paneId: "w:p1", workspaceId: "w", tabId: "w:t1",
                agentStatus: status == "done" ? "idle" : status, agent: "claude",
                title: "t", cwd: "/tmp", revision: 0
            )],
            workspaceNames: ["w": "repo"]
        )
    }

    nonisolated func events() -> AsyncStream<HerdrEvent> { AsyncStream { _ in } }
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
    func focusPane(paneId: String) async throws { focused.append(paneId) }
}

/// A run that ends in a pane herdr considers seen arrives as `idle`, not
/// `done` — so the Completed section stayed empty for exactly the runs the
/// user was watching.
///
/// Measured against herdr 0.9.1: `working` (seq 50) → `idle` (seq 51), with
/// `done` never reported. See invariant 9.
@Suite("A run this session watched finish reads as completed")
struct CompletionTrackingTests {
    private let ref = AgentRef(machine: MachineID("m"), agent: AgentID("w:p1"))

    private func session(_ client: StatusClient) -> MachineSession {
        MachineSession(
            machine: Machine(
                id: MachineID("m"), displayName: "this mac",
                transport: .local(socketPath: "/tmp/agenthq-completion-test.sock")
            ),
            makeClient: { _ in client }
        )
    }

    @Test("working then idle reads as finished, not idle")
    func promotesAWatchedCompletion() async throws {
        let client = StatusClient(status: "working")
        let session = session(client)
        await session.start()
        #expect(await session.view().agents.first?.state == .working)

        await client.set("idle")
        try await session.resync()
        #expect(await session.view().agents.first?.state == .finished)
        await session.stop()
    }

    /// The guard that keeps this from turning every dormant agent into a
    /// completion. An agent that was idle when AgentHQ first saw it never ran
    /// anything as far as this session knows.
    @Test("an agent that was idle all along stays idle")
    func doesNotInventACompletion() async throws {
        let client = StatusClient(status: "idle")
        let session = session(client)
        await session.start()
        #expect(await session.view().agents.first?.state == .idle)

        try await session.resync()
        #expect(await session.view().agents.first?.state == .idle)
        await session.stop()
    }

    /// Looking at it is what clears it, exactly as `done` would have been
    /// cleared by a focus. Without this the row sits in Completed forever,
    /// because herdr goes on saying `idle` either way.
    @Test("revealing a completed run clears it out of Completed")
    func revealMarksItSeen() async throws {
        let client = StatusClient(status: "working")
        let session = session(client)
        await session.start()
        await client.set("idle")
        try await session.resync()
        #expect(await session.view().agents.first?.state == .finished)

        try await session.perform(.reveal, on: AgentID("w:p1"))
        #expect(await client.focused == ["w:p1"])
        #expect(await session.view().agents.first?.state == .idle)
        await session.stop()
    }

    /// A new turn ends the completion, so the next one can be noticed in its
    /// own right rather than merging into a row that never left Completed.
    @Test("starting work again clears the completion")
    func newTurnClearsIt() async throws {
        let client = StatusClient(status: "working")
        let session = session(client)
        await session.start()
        await client.set("idle")
        try await session.resync()
        #expect(await session.view().agents.first?.state == .finished)

        await client.set("working")
        try await session.resync()
        #expect(await session.view().agents.first?.state == .working)

        await client.set("idle")
        try await session.resync()
        #expect(await session.view().agents.first?.state == .finished)
        await session.stop()
    }
}

/// herdr clears `done` only when one of its own clients focuses the pane, so
/// with Ghostty closed a finished row stayed finished however long the user
/// had watched it in the console.
@Suite("Watching a finished run in the console clears it")
struct ViewedCompletionTests {
    private func session(_ client: StatusClient) -> MachineSession {
        MachineSession(
            machine: Machine(
                id: MachineID("m"), displayName: "this mac",
                transport: .local(socketPath: "/tmp/agenthq-viewed-test.sock")
            ),
            makeClient: { _ in client }
        )
    }

    @Test("a herdr done that has been viewed reads as idle")
    func viewedDoneIsIdle() async throws {
        let client = StatusClient(status: "done")
        let session = session(client)
        await session.start()
        #expect(await session.view().agents.first?.state == .finished)

        await session.markViewed(AgentID("w:p1"))
        #expect(await session.view().agents.first?.state == .idle)
        // And stays so across refreshes: herdr goes on saying done.
        try await session.resync()
        #expect(await session.view().agents.first?.state == .idle)
        await session.stop()
    }

    @Test("a completion this session watched is cleared by viewing too")
    func viewedWatchedCompletionIsIdle() async throws {
        let client = StatusClient(status: "working")
        let session = session(client)
        await session.start()
        await client.set("idle")
        try await session.resync()
        #expect(await session.view().agents.first?.state == .finished)

        await session.markViewed(AgentID("w:p1"))
        #expect(await session.view().agents.first?.state == .idle)
        await session.stop()
    }

    /// The record is keyed by the stamp, and a new completion cannot arrive
    /// without a turn of work moving it.
    @Test("the next run's completion is not swallowed by the last one's view")
    func nextCompletionShows() async throws {
        let client = StatusClient(status: "done")
        let session = session(client)
        await session.start()
        await session.markViewed(AgentID("w:p1"))

        await client.set("working")
        try await session.resync()
        await client.set("done")
        try await session.resync()
        #expect(await session.view().agents.first?.state == .finished)
        await session.stop()
    }
}
