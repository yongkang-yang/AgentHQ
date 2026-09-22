import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

/// Records what the row's "Show output" actually asked herdr for.
private actor TranscriptClient: HerdrClient {
    private(set) var reads: [(lines: Int, source: PaneReadSource)] = []
    private let body: String

    init(body: String) { self.body = body }

    func handshake() async throws -> (version: String, protocolVersion: Int) { ("0.9.1", 22) }
    func connect() async throws {}
    func disconnect() async {}
    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: [HerdrPane(
                paneId: "w:p1", workspaceId: "w", tabId: "w:t1", agentStatus: "idle",
                agent: "pi", title: nil, cwd: nil, revision: 0
            )],
            workspaceNames: [:]
        )
    }
    nonisolated func events() -> AsyncStream<HerdrEvent> { AsyncStream { _ in } }
    func readPane(paneId: String, lines: Int, source: PaneReadSource) async throws -> String? {
        reads.append((lines, source))
        return body
    }
    func agents() async throws -> [HerdrAgentInfo] { [] }
    func agent(paneId: String) async throws -> HerdrAgentInfo? { nil }
    func sendKeys(paneId: String, keys: [String]) async throws {}
    func sendText(paneId: String, text: String) async throws {}
    func prompt(paneId: String, text: String) async throws {}
    func interrupt(paneId: String) async throws {}
    func focusPane(paneId: String) async throws {}
}

@Suite("Showing a pane's output")
struct TranscriptTests {
    private let machine = Machine(
        id: MachineID("m"), displayName: "m",
        transport: .local(socketPath: "/tmp/agenthq-transcript-test.sock")
    )

    /// The excerpt on the row is condensed — whitespace collapsed, lines cut
    /// at 117 characters. This view exists because that is unreadable as a
    /// result, so it must not do the same thing.
    @Test("the output is returned verbatim, not condensed")
    func verbatim() async throws {
        let long = String(repeating: "x", count: 300)
        let body = "  indented line\n\n\(long)\n"
        let client = TranscriptClient(body: body)
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.start()

        let text = try await session.transcript(for: AgentID("w:p1"))
        #expect(text.contains("  indented line"), "leading whitespace was collapsed")
        #expect(text.contains(long), "a long line was truncated")
        await session.stop()
    }

    /// Wrapped lines come back split at the pane's width, and the panel is not
    /// that width — re-wrapping them leaves ragged half-lines down the view.
    @Test("it asks for logical lines, not the pane's wrapping")
    func asksUnwrapped() async throws {
        let client = TranscriptClient(body: "output")
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.start()
        _ = try await session.transcript(for: AgentID("w:p1"), lines: 200)

        let reads = await client.reads
        let transcriptRead = try #require(reads.last)
        #expect(transcriptRead.source == .recentUnwrapped)
        #expect(transcriptRead.lines == 200)
        await session.stop()
    }

    /// Steady-state cost must not change: the classifier still reads the
    /// wrapped tail its rules were written against.
    @Test("the classifier's own read is unchanged")
    func classifierReadUnchanged() async throws {
        let client = TranscriptClient(body: "output")
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.start()

        let reads = await client.reads
        #expect(reads.allSatisfy { $0.source == .recent })
        #expect(reads.allSatisfy { $0.lines == 60 })
        await session.stop()
    }

    @Test("an agent on an unknown machine reports it rather than hanging")
    func unknownMachine() async throws {
        let store = await FleetStore()
        await #expect(throws: (any Error).self) {
            try await store.transcript(
                for: AgentRef(machine: MachineID("nope"), agent: AgentID("w:p1"))
            )
        }
    }
}
