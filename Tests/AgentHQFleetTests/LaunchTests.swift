import AgentHQHerdr
import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

/// Records the workspace New agent opened and what it typed there.
private actor LaunchClient: HerdrClient {
    private(set) var workspaces: [(cwd: String, label: String)] = []
    private(set) var typed: [(pane: String, text: String)] = []

    func handshake() async throws -> (version: String, protocolVersion: Int) { ("0.9.1", 22) }
    func connect() async throws {}
    func disconnect() async {}
    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(herdrVersion: "0.9.1", protocolVersion: 22, panes: [], workspaceNames: [:])
    }
    nonisolated func events() -> AsyncStream<HerdrEvent> { AsyncStream { _ in } }
    func readPane(paneId: String, lines: Int, source: PaneReadSource) async throws -> String? { nil }
    func agents() async throws -> [HerdrAgentInfo] { [] }
    func agent(paneId: String) async throws -> HerdrAgentInfo? { nil }
    func sendKeys(paneId: String, keys: [String]) async throws {}
    func sendText(paneId: String, text: String) async throws { typed.append((paneId, text)) }
    func prompt(paneId: String, text: String) async throws {}
    func focusPane(paneId: String) async throws {}
    /// Where herdr says the pane started; nil for "where it was asked".
    private let landsIn: String?
    private(set) var closed: [String] = []

    init(landsIn: String? = nil) { self.landsIn = landsIn }

    func createWorkspace(cwd: String, label: String) async throws -> HerdrCreatedWorkspace {
        workspaces.append((cwd, label))
        return HerdrCreatedWorkspace(workspaceId: "w9", paneId: "w9:p1", cwd: landsIn ?? cwd)
    }
    func closeWorkspace(workspaceId: String) async throws { closed.append(workspaceId) }
}

@Suite("New agent")
struct LaunchTests {
    private let machine = Machine(
        id: MachineID("m"), displayName: "m",
        transport: .local(socketPath: "/tmp/agenthq-launch-test.sock")
    )

    private func session(landsIn: String? = nil) async -> (MachineSession, LaunchClient) {
        let client = LaunchClient(landsIn: landsIn)
        let session = MachineSession(machine: machine, makeClient: { _ in client })
        await session.start()
        return (session, client)
    }

    @Test("it opens a workspace in the directory the machine resolved, and types the agent there")
    func launches() async throws {
        let (session, client) = await session()
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        let pane = try await session.launch(.codex, in: directory)
        #expect(pane == AgentID("w9:p1"))
        let workspace = try #require(await client.workspaces.first)
        #expect(workspace.cwd.hasPrefix("/"))
        #expect(workspace.label == (workspace.cwd as NSString).lastPathComponent)
        let typed = await client.typed
        #expect(typed.count == 1)
        #expect(typed.first?.pane == "w9:p1")
        #expect(typed.first?.text == "codex\n")
        await session.stop()
    }

    @Test("a directory that is not there opens nothing")
    func missingDirectory() async throws {
        let (session, client) = await session()
        await #expect {
            try await session.launch(.claude, in: "/nonexistent-agenthq-\(UUID().uuidString)")
        } throws: { error in
            if case LaunchError.directoryUnavailable = error { return true }
            return false
        }
        #expect(await client.workspaces.isEmpty)
        #expect(await client.typed.isEmpty)
        await session.stop()
    }

    @Test("a relative path is refused before anything runs")
    func relativePath() async throws {
        let (session, client) = await session()
        await #expect(throws: LaunchError.unsupportedPath) {
            try await session.launch(.claude, in: "dev/app")
        }
        #expect(await client.workspaces.isEmpty)
        await session.stop()
    }

    /// herdr falls back to `$HOME` without an error; reporting that as the
    /// agent started in the asked directory would be a fabricated success.
    @Test("a workspace herdr opened somewhere else is closed, and nothing is typed")
    func relocatedWorkspace() async throws {
        let (session, client) = await session(landsIn: "/home/someone")
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        await #expect {
            try await session.launch(.claude, in: directory)
        } throws: { error in
            if case LaunchError.directoryUnavailable = error { return true }
            return false
        }
        #expect(await client.closed == ["w9"])
        #expect(await client.typed.isEmpty)
        await session.stop()
    }
}
