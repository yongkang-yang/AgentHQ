import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

/// Records what the console window actually asked herdr for.
private actor ConsoleClient: HerdrClient {
    enum Call: Equatable {
        case prompt(String)
        case text(String)
        case keys([String])
    }

    private(set) var reads: [(lines: Int, source: PaneReadSource)] = []
    private(set) var calls: [Call] = []
    private let status: String?

    init(status: String?) { self.status = status }

    func handshake() async throws -> (version: String, protocolVersion: Int) { ("0.9.1", 22) }
    func connect() async throws {}
    func disconnect() async {}
    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: [HerdrPane(
                paneId: "w:p1", workspaceId: "w", tabId: "w:t1", agentStatus: status ?? "idle",
                agent: "pi", title: nil, cwd: nil, revision: 0
            )],
            workspaceNames: [:]
        )
    }
    nonisolated func events() -> AsyncStream<HerdrEvent> { AsyncStream { _ in } }
    func readPane(paneId: String, lines: Int, source: PaneReadSource) async throws -> String? {
        reads.append((lines, source))
        return "screen"
    }
    func agents() async throws -> [HerdrAgentInfo] { [] }
    func agent(paneId: String) async throws -> HerdrAgentInfo? {
        status.map { HerdrAgentInfo(paneId: paneId, agent: "pi", agentStatus: $0, stateChangeSeq: 1) }
    }
    func sendKeys(paneId: String, keys: [String]) async throws { calls.append(.keys(keys)) }
    func sendText(paneId: String, text: String) async throws { calls.append(.text(text)) }
    func prompt(paneId: String, text: String) async throws { calls.append(.prompt(text)) }
    func focusPane(paneId: String) async throws {}
}

@Suite("The console window")
struct ConsoleTests {
    private let machine = Machine(
        id: MachineID("m"), displayName: "m",
        transport: .local(socketPath: "/tmp/agenthq-console-test.sock")
    )
    private let pane = AgentID("w:p1")

    private func session(status: String?) async -> (MachineSession, ConsoleClient) {
        let client = ConsoleClient(status: status)
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.start()
        return (session, client)
    }

    /// One screen is one pane-height; a reply longer than that arrived with
    /// its opening cut off. It reads the scrollback, unwrapped for re-wrapping.
    @Test("it reads past the visible screen")
    func readsScrollback() async throws {
        let (session, client) = await session(status: "idle")
        _ = try await session.screen(for: pane)
        let read = try #require(await client.reads.last)
        #expect(read.source == .recentUnwrapped)
        #expect(read.lines > 58)
        await session.stop()
    }

    /// Steady-state cost must not change: the classifier still reads the
    /// wrapped tail its rules were written against.
    @Test("the classifier's own read is unchanged")
    func classifierReadUnchanged() async throws {
        let (session, client) = await session(status: "idle")
        let reads = await client.reads
        #expect(reads.allSatisfy { $0.source == .recent && $0.lines == 60 })
        await session.stop()
    }

    /// `agent.prompt` sends text and Enter as one submission, so a long
    /// message cannot arrive split from its Enter.
    @Test("a message to an agent awaiting input goes as one prompt")
    func idlePrompts() async throws {
        let (session, client) = await session(status: "idle")
        try await session.submit("carry on", to: pane)
        #expect(await client.calls == [.prompt("carry on")])
        await session.stop()
    }

    /// herdr refuses `agent.prompt` for a blocked agent, and the question on
    /// screen is what the user is answering.
    /// One call with the newline inside it: separately, the words can land
    /// and the submit not, leaving the agent holding half an answer.
    @Test("an answer to a blocked agent is typed with its newline, in one call")
    func blockedTypes() async throws {
        let (session, client) = await session(status: "blocked")
        try await session.submit("yes, the second one", to: pane)
        #expect(await client.calls == [.text("yes, the second one\n")])
        await session.stop()
    }

    @Test("an empty line is a bare Enter")
    func emptyIsEnter() async throws {
        let (session, client) = await session(status: "idle")
        try await session.submit("", to: pane)
        #expect(await client.calls == [.keys(["enter"])])
        await session.stop()
    }

    @Test("a key button presses that key and nothing else")
    func pressesKeys() async throws {
        let (session, client) = await session(status: "working")
        try await session.press(["esc"], in: pane)
        #expect(await client.calls == [.keys(["esc"])])
        await session.stop()
    }

    @Test("an agent on an unknown machine reports it rather than hanging")
    func unknownMachine() async throws {
        let store = await FleetStore()
        await #expect(throws: (any Error).self) {
            try await store.screen(
                for: AgentRef(machine: MachineID("nope"), agent: AgentID("w:p1"))
            )
        }
    }
}
