import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

/// A client whose pane can be scripted to change what it shows after a key
/// lands — which is the whole mechanism End depends on.
private actor EndingClient: HerdrClient {
    private(set) var sent: [[String]] = []
    /// What the pane shows before any key, then after each key in turn. The
    /// last entry holds once the script runs out.
    private var screens: [String]
    /// herdr's `agent_status` on the same schedule; `nil` is no agent at all.
    private var statuses: [String?]
    private var presses = 0

    init(output: String, afterFirstKey: String? = nil) {
        self.screens = [output] + (afterFirstKey.map { [$0] } ?? [])
        self.statuses = ["idle"]
    }

    init(screens: [String], statuses: [String?]) {
        self.screens = screens
        self.statuses = statuses
    }

    private func scripted<T>(_ list: [T]) -> T { list[min(presses, list.count - 1)] }

    func handshake() async throws -> (version: String, protocolVersion: Int) { ("0.9.1", 22) }
    func connect() async throws {}
    func disconnect() async {}

    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: [HerdrPane(
                paneId: "w:p1", workspaceId: "w", tabId: "w:t1",
                agentStatus: "idle", agent: "pi",
                title: "t", cwd: "/tmp", revision: 0
            )],
            workspaceNames: ["w": "repo"]
        )
    }

    nonisolated func events() -> AsyncStream<HerdrEvent> { AsyncStream { _ in } }
    func readPane(paneId: String, lines: Int, source: PaneReadSource) async throws -> String? {
        scripted(screens)
    }
    func agents() async throws -> [HerdrAgentInfo] {
        [HerdrAgentInfo(paneId: "w:p1", agent: "pi", agentStatus: "idle", stateChangeSeq: 7)]
    }
    func agent(paneId: String) async throws -> HerdrAgentInfo? {
        scripted(statuses).map {
            HerdrAgentInfo(paneId: "w:p1", agent: "pi", agentStatus: $0, stateChangeSeq: 7)
        }
    }
    func sendKeys(paneId: String, keys: [String]) async throws {
        sent.append(keys)
        presses += 1
    }
    func sendText(paneId: String, text: String) async throws {}
    func prompt(paneId: String, text: String) async throws {}
    func focusPane(paneId: String) async throws {}
}

@Suite("Ending a conversation takes its keys from the pane")
struct EndConversationTests {
    private func session(_ client: EndingClient) async -> MachineSession {
        let machine = Machine(
            displayName: "test",
            transport: .local(socketPath: "/tmp/agenthq-end-test.sock")
        )
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.start()
        return session
    }

    /// pi names its exit key outright, so End presses that key once and is
    /// done — no ⌃C, no second press, no waiting to see what happened.
    ///
    /// Sending ⌃C here is the specific failure this defends against: on pi it
    /// clears the input line and exits nothing.
    @Test("an agent that names its exit key gets that key, once")
    func pressesTheNamedKey() async throws {
        let client = EndingClient(output: ExitKeyTestFooters.pi)
        let session = await session(client)

        try await session.perform(.end, on: AgentID("w:p1"))
        #expect(await client.sent == [["C-d"]])
        await session.stop()
    }

    /// Claude Code's shape: nothing named up front, ⌃C answered with an offer
    /// to press again, and only that offer authorises the second press.
    @Test("a two-step exit presses again only because the pane asked")
    func pressesAgainWhenOffered() async throws {
        let client = EndingClient(
            output: "⏵ Deciphering… (12s · esc to interrupt)",
            afterFirstKey: "Press Ctrl-C again to exit"
        )
        let session = await session(client)

        try await session.perform(.end, on: AgentID("w:p1"))
        #expect(await client.sent == [["C-c"], ["C-c"]])
        await session.stop()
    }

    /// The honest failure. One ⌃C has landed and cannot be recalled, so the
    /// refusal names it rather than claiming nothing was sent — and no second
    /// key goes out on a hunch that this agent probably quits on two.
    @Test("an agent that offers nothing gets one key and an honest report")
    func stopsWhenNothingIsOffered() async throws {
        let client = EndingClient(output: "just working away", afterFirstKey: "still working away")
        let session = await session(client)

        await #expect(throws: InterventionError.exitNotConfirmed(sent: "C-c")) {
            try await session.perform(.end, on: AgentID("w:p1"))
        }
        #expect(await client.sent == [["C-c"]])
        await session.stop()
    }

    /// Claude Code mid-turn, as measured: the first ⌃C interrupts the turn
    /// and offers nothing, and herdr moves `working` → `idle`. That press was
    /// spent on the turn, not on exiting, so the gesture starts over — and the
    /// second ⌃C is still pressed again only because the pane then asked.
    @Test("a press spent interrupting a turn starts the gesture over")
    func interruptedTurnStartsOver() async throws {
        let client = EndingClient(
            screens: [
                "⏺ Bash(for i in $(seq 1 60)…)\n  ✻ Running… (esc to interrupt)",
                "  ⎿  Interrupted · What should Claude do instead?\n❯",
                "Press Ctrl-C again to exit",
            ],
            statuses: ["working", "idle"]
        )
        let session = await session(client)

        try await session.perform(.end, on: AgentID("w:p1"))
        #expect(await client.sent == [["C-c"], ["C-c"], ["C-c"]])
        await session.stop()
    }

    /// Starting over is a single retry, not a loop: an agent whose status
    /// moves on every press and never offers to exit gets two keys and the
    /// honest report naming both.
    @Test("the gesture starts over at most once")
    func startsOverOnce() async throws {
        let client = EndingClient(
            screens: ["busy", "still busy", "busy again"],
            statuses: ["working", "idle", "working"]
        )
        let session = await session(client)

        await #expect(throws: InterventionError.exitNotConfirmed(sent: "C-c C-c")) {
            try await session.perform(.end, on: AgentID("w:p1"))
        }
        #expect(await client.sent == [["C-c"], ["C-c"]])
        await session.stop()
    }

    /// An agent that quits on the first ⌃C leaves nothing to confirm, and
    /// herdr saying the pane has no agent is the proof. Reporting
    /// `exitNotConfirmed` there would claim a half-quit that did not happen.
    @Test("an agent gone after one press has ended")
    func goneAfterOnePress() async throws {
        let client = EndingClient(screens: ["idle input", "$ "], statuses: ["idle", nil])
        let session = await session(client)

        try await session.perform(.end, on: AgentID("w:p1"))
        #expect(await client.sent == [["C-c"]])
        await session.stop()
    }

    /// End does not depend on the agent having stayed still, the way answering
    /// a prompt does. A conversation the user wants gone is gone whatever it
    /// happened to be doing when they clicked.
    @Test("ending does not refuse an agent that moved")
    func noStalenessGuard() async throws {
        let client = EndingClient(output: ExitKeyTestFooters.pi)
        let session = await session(client)

        // A row with no stamp at all — the case that refuses Stop outright.
        try await session.perform(.end, on: AgentID("w:p1"))
        #expect(await client.sent == [["C-d"]])
        await session.stop()
    }
}

/// Shared with `ExitKeyTests`, which lives in the herdr target and cannot be
/// imported from here.
enum ExitKeyTestFooters {
    static let pi =
        "escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash · ctrl+o more"
}
