import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

/// A client whose agent can be driven through state changes the way herdr
/// drives one: a `pane_updated` event carrying the new status, and an agent
/// view that only answers when asked.
private actor StampClient: HerdrClient {
    private(set) var sentPrompts: [String] = []
    private(set) var agentViewReads = 0
    private var status = "idle"
    private var seq: UInt64 = 100
    private var servesAgentViews = true

    private let continuation: AsyncStream<HerdrEvent>.Continuation
    private let stream: AsyncStream<HerdrEvent>

    init() {
        var cont: AsyncStream<HerdrEvent>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    /// Move the agent the way herdr would: the status changes, the herd-wide
    /// stamp advances, and a `pane_updated` carrying only the new status
    /// arrives. The stamp is deliberately *not* in the event — herdr does not
    /// put it there.
    func move(to newStatus: String) {
        status = newStatus
        seq += 1
        continuation.yield(.paneUpdated(pane()))
    }

    /// Make `agent.get` / `agent.list` fail, the way a degraded link does.
    func withholdAgentViews() { servesAgentViews = false }
    func restoreAgentViews() { servesAgentViews = true }

    private func pane() -> HerdrPane {
        HerdrPane(
            paneId: "w:p1", workspaceId: "w", tabId: "w:t1",
            agentStatus: status, agent: "claude",
            title: "t", cwd: "/tmp", revision: 0
        )
    }

    func handshake() async throws -> (version: String, protocolVersion: Int) { ("0.9.1", 22) }
    func connect() async throws {}
    func disconnect() async {}

    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: [pane()], workspaceNames: ["w": "repo"]
        )
    }

    nonisolated func events() -> AsyncStream<HerdrEvent> { stream }
    func readPane(paneId: String, lines: Int, source: PaneReadSource) async throws -> String? { nil }

    func agents() async throws -> [HerdrAgentInfo] {
        agentViewReads += 1
        guard servesAgentViews else { throw HerdrProtocolError.closedBeforeReply }
        return [HerdrAgentInfo(paneId: "w:p1", agent: "claude", agentStatus: status, stateChangeSeq: seq)]
    }

    func agent(paneId: String) async throws -> HerdrAgentInfo? {
        agentViewReads += 1
        guard servesAgentViews else { throw HerdrProtocolError.closedBeforeReply }
        return HerdrAgentInfo(paneId: "w:p1", agent: "claude", agentStatus: status, stateChangeSeq: seq)
    }

    func sendKeys(paneId: String, keys: [String]) async throws {}
    func sendText(paneId: String, text: String) async throws {}
    func prompt(paneId: String, text: String) async throws { sentPrompts.append(text) }
    func focusPane(paneId: String) async throws {}
}

/// Invariant 8's standing obligation: a row must carry a stamp for the state
/// it is showing, or every guarded action on it fails closed.
///
/// A `pane_updated` event carries no stamp, and the agent view used to be
/// fetched only for panes that had *stopped*. So an agent that had just
/// started working had none — and working is exactly when its one guarded
/// action, Nudge, is offered.
@Suite("A row that has just changed state can still be acted on")
struct WorkingAgentStampTests {
    private func settle() async throws {
        try await Task.sleep(for: .milliseconds(120))
    }

    private func started(_ client: StampClient) async -> MachineSession {
        let machine = Machine(
            displayName: "test",
            transport: .local(socketPath: "/tmp/agenthq-stamp-test.sock")
        )
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.start()
        return session
    }

    /// The reported bug, in the action that survived it. Without the stamp the
    /// guard refused — correctly by its own rules — for the whole window
    /// between the agent starting work and the next full resync.
    @Test("an agent that just started working can still be nudged")
    func nudgesAFreshlyWorkingAgent() async throws {
        let client = StampClient()
        let session = await started(client)
        try await settle()
        #expect(await session.view().agents.first?.state == .idle)

        await client.move(to: "working")
        try await settle()
        #expect(await session.view().agents.first?.state == .working)

        try await session.perform(.nudge("also check the tests"), on: AgentID("w:p1"))
        #expect(await client.sentPrompts == ["also check the tests"])
        await session.stop()
    }

    /// The row has to carry the stamp for the state it is actually showing,
    /// not nil and not the previous state's.
    @Test("a state change refreshes the row's staleness stamp")
    func transitionCarriesItsOwnStamp() async throws {
        let client = StampClient()
        let session = await started(client)
        try await settle()
        #expect(await session.view().agents.first?.stateSeq == 100)

        await client.move(to: "working")
        try await settle()
        #expect(await session.view().agents.first?.stateSeq == 101)
        await session.stop()
    }

    /// The cost that has to stay paid. A working agent emits `pane_updated`
    /// continuously as it writes output; a round trip per event is ~115ms to a
    /// tunnelled machine. The condition is a state *change*, not an event.
    @Test("output churn on an unchanged state costs no extra round trip")
    func steadyStateWorkingIsFree() async throws {
        let client = StampClient()
        let session = await started(client)
        try await settle()

        await client.move(to: "working")
        try await settle()
        let afterTransition = await client.agentViewReads

        for _ in 0..<10 {
            await client.move(to: "working")
        }
        try await settle()

        #expect(await client.agentViewReads == afterTransition)
        await session.stop()
    }

    /// When the stamp genuinely cannot be had — the agent view was
    /// unreachable — the refusal has to say that, not invent a move.
    ///
    /// "It moved from working to working first" was the sentence this bug
    /// showed the user, and it is exactly the fabricated state the panel is
    /// not allowed to print.
    @Test("a refusal with no stamp says it could not check, not that it moved")
    func namesTheRealReason() async throws {
        let client = StampClient()
        let session = await started(client)
        try await settle()

        // The link hiccups exactly while the transition arrives, so the row is
        // rebuilt without a stamp. By the time the user clicks, herdr answers
        // again — but the row in hand still has nothing to compare.
        await client.withholdAgentViews()
        await client.move(to: "working")
        try await settle()
        await client.restoreAgentViews()

        await #expect(throws: InterventionError.unverifiable) {
            try await session.perform(.nudge("carry on"), on: AgentID("w:p1"))
        }
        #expect(await client.sentPrompts.isEmpty)
        await session.stop()
    }
}
