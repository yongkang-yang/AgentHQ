import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

/// A herdr client that serves scripted state and records every write.
///
/// Recording is the whole point. The guard in `MachineSession.perform` promises
/// that a refused intervention sent *nothing* — an error thrown after the
/// keystroke already left would satisfy a test that only checked the error, and
/// would still have answered a prompt on the user's behalf.
private actor RecordingClient: HerdrClient {
    struct Sent: Equatable {
        var keys: [(pane: String, keys: [String])] = []
        var prompts: [(pane: String, text: String)] = []
        var interrupts: [String] = []
        var texts: [(pane: String, text: String)] = []

        var isEmpty: Bool {
            keys.isEmpty && prompts.isEmpty && interrupts.isEmpty && texts.isEmpty
        }

        static func == (lhs: Sent, rhs: Sent) -> Bool {
            lhs.keys.map(\.keys) == rhs.keys.map(\.keys)
                && lhs.prompts.map(\.text) == rhs.prompts.map(\.text)
                && lhs.interrupts == rhs.interrupts
                && lhs.texts.map(\.text) == rhs.texts.map(\.text)
        }
    }

    private(set) var sent = Sent()

    /// What `agent.get` will answer. Change it to simulate the agent moving
    /// between the panel rendering a row and the click arriving.
    var liveAgents: [String: HerdrAgentInfo]
    /// What `pane.read` will answer. Change it to simulate the prompt changing.
    var paneOutput: [String: String]
    var panes: [HerdrPane]

    init(panes: [HerdrPane], liveAgents: [String: HerdrAgentInfo], paneOutput: [String: String]) {
        self.panes = panes
        self.liveAgents = liveAgents
        self.paneOutput = paneOutput
    }

    func setLiveAgent(_ paneId: String, to info: HerdrAgentInfo?) {
        liveAgents[paneId] = info
    }

    func setOutput(_ paneId: String, to text: String) {
        paneOutput[paneId] = text
    }

    // MARK: HerdrClient

    func handshake() async throws -> (version: String, protocolVersion: Int) {
        ("0.9.1", 22)
    }
    func connect() async throws {}
    func disconnect() async {}

    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: panes, workspaceNames: ["w": "repo"]
        )
    }

    nonisolated func events() -> AsyncStream<HerdrEvent> {
        AsyncStream { _ in }
    }

    func readPane(paneId: String, lines: Int) async throws -> String? {
        paneOutput[paneId]
    }

    func agents() async throws -> [HerdrAgentInfo] {
        Array(liveAgents.values)
    }

    func agent(paneId: String) async throws -> HerdrAgentInfo? {
        liveAgents[paneId]
    }

    func sendKeys(paneId: String, keys: [String]) async throws {
        sent.keys.append((paneId, keys))
    }
    func sendText(paneId: String, text: String) async throws {
        sent.texts.append((paneId, text))
    }
    func prompt(paneId: String, text: String) async throws {
        sent.prompts.append((paneId, text))
    }
    func interrupt(paneId: String) async throws {
        sent.interrupts.append(paneId)
    }
}

@Suite("the intervention staleness guard")
struct InterventionGuardTests {
    private static let paneId = "w:p1"
    /// cursor.toml's real prompt: names y to run and esc to skip.
    private static let blockedPrompt = "run this command?\n  → run (once) (y)\n    skip (esc or n)"

    private func pane(status: String = "blocked") -> HerdrPane {
        HerdrPane(
            paneId: Self.paneId, workspaceId: "w", tabId: "w:t1",
            agentStatus: status, agent: "cursor", title: "t",
            cwd: "/tmp", revision: 0
        )
    }

    private func info(status: String = "blocked", seq: UInt64) -> HerdrAgentInfo {
        HerdrAgentInfo(paneId: Self.paneId, agent: "cursor", agentStatus: status, stateChangeSeq: seq)
    }

    /// A started session wired to a recording client.
    private func session(
        client: RecordingClient
    ) async -> MachineSession {
        let machine = Machine(
            displayName: "test",
            // LocalSocketTransport only validates the path; nothing connects.
            transport: .local(socketPath: "/tmp/agenthq-test.sock")
        )
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.start()
        return session
    }

    private func makeClient(seq: UInt64 = 100, output: String? = nil) -> RecordingClient {
        RecordingClient(
            panes: [pane()],
            liveAgents: [Self.paneId: info(seq: seq)],
            paneOutput: [Self.paneId: output ?? Self.blockedPrompt]
        )
    }

    // MARK: The happy path, so the refusals below mean something

    @Test("an unmoved agent is answered with the key its prompt named")
    func approveSendsTheNamedKey() async throws {
        let client = makeClient()
        let session = await session(client: client)

        try await session.perform(.approve, on: AgentID(Self.paneId))

        let sent = await client.sent
        #expect(sent.keys.map(\.keys) == [["y"]])
        #expect(sent.keys.first?.pane == Self.paneId)
    }

    @Test("decline sends the key the prompt named for backing out")
    func denySendsEscape() async throws {
        let client = makeClient()
        let session = await session(client: client)

        try await session.perform(.deny, on: AgentID(Self.paneId))

        #expect(await client.sent.keys.map(\.keys) == [["esc"]])
    }

    // MARK: Refusals — each must send nothing

    @Test("a moved agent refuses and sends nothing")
    func movedAgentSendsNothing() async throws {
        let client = makeClient(seq: 100)
        let session = await session(client: client)

        // The agent answered its own prompt, or moved on, between the panel
        // rendering the row and the click arriving.
        await client.setLiveAgent(Self.paneId, to: info(status: "working", seq: 101))

        await #expect(throws: InterventionError.self) {
            try await session.perform(.approve, on: AgentID(Self.paneId))
        }
        // The assertion that matters: a `y` did not go into whatever replaced
        // the prompt.
        #expect(await client.sent.isEmpty)
    }

    @Test("a changed prompt refuses and sends nothing")
    func changedPromptSendsNothing() async throws {
        let client = makeClient(seq: 100)
        let session = await session(client: client)

        // Same agent, same stamp, different question — a second prompt that
        // arrived without herdr counting it as a state change.
        await client.setOutput(Self.paneId, to: "delete all untracked files?\n  ❯ Yes\nenter to confirm · esc to cancel")

        await #expect(throws: InterventionError.self) {
            try await session.perform(.approve, on: AgentID(Self.paneId))
        }
        #expect(await client.sent.isEmpty)
    }

    @Test("a vanished agent refuses and sends nothing")
    func goneAgentSendsNothing() async throws {
        let client = makeClient()
        let session = await session(client: client)

        await client.setLiveAgent(Self.paneId, to: nil)

        await #expect(throws: InterventionError.self) {
            try await session.perform(.approve, on: AgentID(Self.paneId))
        }
        #expect(await client.sent.isEmpty)
    }

    @Test("an agent with no stamp refuses and sends nothing")
    func missingStampSendsNothing() async throws {
        // A row built from an event that carried no stamp. Failing closed is
        // the point: an unguarded send is exactly what the guard prevents.
        let client = RecordingClient(
            panes: [pane()],
            liveAgents: [:],
            paneOutput: [Self.paneId: Self.blockedPrompt]
        )
        let session = await session(client: client)
        // Put the agent back so the lookup succeeds but the row's own stamp,
        // taken while `agents()` returned nothing, is still nil.
        await client.setLiveAgent(Self.paneId, to: info(seq: 100))

        await #expect(throws: InterventionError.self) {
            try await session.perform(.approve, on: AgentID(Self.paneId))
        }
        #expect(await client.sent.isEmpty)
    }

    @Test("an unknown agent id refuses and sends nothing")
    func unknownAgentSendsNothing() async throws {
        let client = makeClient()
        let session = await session(client: client)

        await #expect(throws: InterventionError.self) {
            try await session.perform(.approve, on: AgentID("w:p999"))
        }
        #expect(await client.sent.isEmpty)
    }

    @Test("an action the row does not offer refuses and sends nothing")
    func unofferedActionSendsNothing() async throws {
        // herdr rejects agent.prompt on a blocked agent, so nudge is not
        // offered there. A caller reaching past AgentActions is still refused.
        let client = makeClient()
        let session = await session(client: client)

        await #expect(throws: InterventionError.self) {
            try await session.perform(.nudge("carry on"), on: AgentID(Self.paneId))
        }
        #expect(await client.sent.isEmpty)
    }

    @Test("a menu prompt refuses approve but still allows decline")
    func menuPromptRefusesApprove() async throws {
        // No key named for going ahead; esc is named for backing out.
        let client = makeClient(
            output: "Do you want to continue?\n  ❯ Yes\n    No\nenter to confirm · esc to cancel"
        )
        let session = await session(client: client)

        await #expect(throws: InterventionError.self) {
            try await session.perform(.approve, on: AgentID(Self.paneId))
        }
        #expect(await client.sent.isEmpty)

        try await session.perform(.deny, on: AgentID(Self.paneId))
        #expect(await client.sent.keys.map(\.keys) == [["esc"]])
    }

    // MARK: Interrupt

    @Test("interrupt does not depend on the prompt, only on the stamp")
    func interruptIgnoresPromptChanges() async throws {
        let client = makeClient()
        let session = await session(client: client)

        // The pane now shows something else entirely. Interrupt still applies:
        // it stops whatever is running rather than answering anything.
        await client.setOutput(Self.paneId, to: "…thinking…")

        try await session.perform(.interrupt, on: AgentID(Self.paneId))
        #expect(await client.sent.interrupts == [Self.paneId])
    }

    @Test("interrupt still refuses an agent that already moved")
    func interruptRefusesMovedAgent() async throws {
        // An agent that finished on its own must not be interrupted after the
        // fact — the keystroke would land in whatever came next.
        let client = makeClient(seq: 100)
        let session = await session(client: client)
        await client.setLiveAgent(Self.paneId, to: info(status: "done", seq: 140))

        await #expect(throws: InterventionError.self) {
            try await session.perform(.interrupt, on: AgentID(Self.paneId))
        }
        #expect(await client.sent.isEmpty)
    }
}
