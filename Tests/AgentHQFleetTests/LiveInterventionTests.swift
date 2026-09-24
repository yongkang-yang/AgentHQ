import AgentHQHerdr
import AgentHQKit
import Darwin
import Foundation
import Testing
@testable import AgentHQFleet

/// Raw JSON-RPC to herdr, for the setup calls the product has no reason to
/// expose: creating a throwaway workspace, fabricating an agent in it, and
/// closing it again. Test scaffolding, deliberately not part of `HerdrClient`.
private struct Harness {
    let socketPath: String

    @discardableResult
    func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { dst in
            bytes.withUnsafeBufferPointer { src in
                UnsafeMutableRawPointer(dst).copyMemory(
                    from: UnsafeRawPointer(src.baseAddress!), byteCount: bytes.count
                )
            }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw HarnessError.cannotConnect }

        // Request ids are strings; an integer is rejected and drops the socket.
        let body: [String: Any] = [
            "jsonrpc": "2.0", "id": "test", "method": method, "params": params,
        ]
        var payload = try JSONSerialization.data(withJSONObject: body)
        payload.append(0x0A)
        _ = payload.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }

        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !buffer.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { break }
            buffer.append(contentsOf: chunk[0..<n])
        }
        guard let object = try JSONSerialization.jsonObject(with: buffer) as? [String: Any] else {
            throw HarnessError.badReply
        }
        if let error = object["error"] as? [String: Any] {
            throw HarnessError.herdr(String(describing: error["message"] ?? ""))
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    enum HarnessError: Error { case cannotConnect, badReply, herdr(String) }
}

private let socketPath = ProcessInfo.processInfo.environment["AGENTHQ_HERDR_SOCKET"]

/// Drives a real blocked agent through a real intervention, over the real
/// socket, and checks the keystroke landed in the pane.
///
/// Everything above this is covered against a recording fake, which proves the
/// guard refuses correctly but cannot prove the wire call is shaped right — and
/// `agent.prompt` shipped taking the wrong parameter name for exactly that
/// reason. This closes that gap.
///
/// The agent is fabricated with `pane.report_agent` rather than by running a
/// real one: herdr believes the report, so a throwaway shell becomes a blocked
/// cursor agent with a real state-change stamp, and nothing has to wait for a
/// live model to reach a prompt.
///
///     AGENTHQ_LIVE_INTERVENTION=1 \
///     AGENTHQ_HERDR_SOCKET=$HOME/.config/herdr/herdr.sock \
///     swift test --filter LiveInterventionTests
@Suite(
    "a real intervention over the real socket",
    .enabled(if: socketPath != nil
             && ProcessInfo.processInfo.environment["AGENTHQ_LIVE_INTERVENTION"] != nil,
             "set AGENTHQ_LIVE_INTERVENTION and AGENTHQ_HERDR_SOCKET to run"),
    .serialized
)
struct LiveInterventionTests {
    /// cursor's real blocked prompt, from its agent manifest.
    private static let promptScript =
        #"clear; printf 'waiting for approval\nrun this command?\n  -> run (once) (y)\n     skip (esc or n)\n'"#

    /// Builds a throwaway workspace holding one fabricated blocked agent, runs
    /// `body` against it, and closes the workspace whatever happens.
    /// An open question, which classifies as needsInput and so offers Reply
    /// rather than Approve.
    private static let questionScript =
        #"clear; printf 'I need a decision.\nWhich database should I migrate first?\n'"#

    private func withFabricatedBlockedAgent(
        showing script: String? = nil,
        _ body: (Harness, String, MachineSession) async throws -> Void
    ) async throws {
        let harness = Harness(socketPath: socketPath!)

        let created = try harness.call("workspace.create", ["cwd": "/tmp", "label": "agenthq-livetest"])
        let workspace = (created["workspace"] as? [String: Any])?["workspace_id"] as? String
        let workspaceId = try #require(workspace)
        defer { try? harness.call("workspace.close", ["workspace_id": workspaceId]) }

        let panes = try harness.call("pane.list")["panes"] as? [[String: Any]] ?? []
        let paneId = try #require(
            panes.first { $0["workspace_id"] as? String == workspaceId }?["pane_id"] as? String
        )

        // Put cursor's prompt on the pane's screen, then tell herdr an agent
        // is sitting blocked in it.
        try harness.call("pane.send_text", ["pane_id": paneId, "text": script ?? Self.promptScript])
        try harness.call("pane.send_keys", ["pane_id": paneId, "keys": ["Enter"]])
        try await Task.sleep(for: .milliseconds(1200))
        try harness.call("pane.report_agent", [
            "pane_id": paneId, "source": "cursor", "agent": "cursor", "state": "blocked",
        ])
        try await Task.sleep(for: .milliseconds(400))

        let session = MachineSession(machine: Machine(
            displayName: "this mac",
            transport: .local(socketPath: socketPath!)
        ))
        await session.start()
        defer { Task { await session.stop() } }

        try await body(harness, paneId, session)
    }

    private func screen(_ harness: Harness, _ paneId: String) throws -> String {
        let read = try harness.call("pane.read", [
            "pane_id": paneId, "source": "recent", "lines": 20,
        ])
        return ((read["read"] as? [String: Any])?["text"] as? String) ?? ""
    }

    @Test("a blocked agent is classified, offered the key its prompt named, and answered")
    func approveReachesThePane() async throws {
        try await withFabricatedBlockedAgent { harness, paneId, session in
            let agents = await session.view().agents
            let agent = try #require(agents.first { $0.ref.agent.raw == paneId },
                                     "the fabricated agent did not reach the fleet")

            // Classified from the pane's own text, with the key the prompt named.
            #expect(agent.state == .needsApproval)
            #expect(agent.actions.approveKey == "y")
            #expect(agent.actions.denyKey == "esc")
            // Only agent.get carries this; a pane record would have yielded nil.
            #expect(agent.stateSeq != nil)

            try await session.perform(.approve, on: AgentID(paneId))

            // The keystroke has to have landed in the pane, not merely been
            // accepted by herdr. The shell echoes what it was sent.
            try await Task.sleep(for: .milliseconds(800))
            let after = try screen(harness, paneId)
            #expect(after.contains("y"), "no 'y' reached the pane")
        }
    }

    @Test("a console answer reaches a real blocked agent")
    func replyReachesThePane() async throws {
        try await withFabricatedBlockedAgent(showing: Self.questionScript) { harness, paneId, session in
            let agents = await session.view().agents
            let agent = try #require(agents.first { $0.ref.agent.raw == paneId })

            // An open question: nothing to press, so words are the only answer.
            #expect(agent.state == .needsInput)
            #expect(agent.actions.approveKey == nil)

            // herdr refuses agent.prompt here, so the console types instead.
            try await session.submit("echo THE_STAGING_ONE", to: AgentID(paneId))
            try await Task.sleep(for: .milliseconds(1000))

            // Sent *and* submitted: the shell ran it, which it only does on a
            // newline. A reply that arrives unsubmitted leaves the agent
            // holding half an instruction.
            let after = try screen(harness, paneId)
            #expect(after.contains("THE_STAGING_ONE"), "the reply did not reach the pane")
        }
    }

    @Test("reveal focuses the pane in real herdr")
    func revealFocusesForReal() async throws {
        try await withFabricatedBlockedAgent { harness, paneId, session in
            // The throwaway workspace is not the focused one — the user's is.
            let before = try harness.call("session.snapshot")
            let snapBefore = before["snapshot"] as? [String: Any] ?? [:]
            #expect(snapBefore["focused_pane_id"] as? String != paneId)

            try await session.perform(.reveal, on: AgentID(paneId))
            try await Task.sleep(for: .milliseconds(400))

            let after = try harness.call("session.snapshot")
            let snapAfter = after["snapshot"] as? [String: Any] ?? [:]
            // Both, or the pane is focused on a workspace nobody is showing.
            #expect(snapAfter["focused_pane_id"] as? String == paneId)
            #expect(snapAfter["focused_workspace_id"] as? String
                    == paneId.split(separator: ":").first.map(String.init))
        }
    }

    @Test("an agent that moved on is refused, and nothing reaches the pane")
    func staleRowIsRefusedAgainstRealHerdr() async throws {
        try await withFabricatedBlockedAgent { harness, paneId, session in
            let before = try screen(harness, paneId)

            // The agent moves on between the row being built and the click:
            // re-reporting bumps herdr's herd-wide state-change clock.
            try harness.call("pane.report_agent", [
                "pane_id": paneId, "source": "cursor", "agent": "cursor", "state": "working",
            ])
            try await Task.sleep(for: .milliseconds(400))

            await #expect(throws: InterventionError.self) {
                try await session.perform(.approve, on: AgentID(paneId))
            }

            // The promise the guard makes, against real herdr: nothing was sent.
            try await Task.sleep(for: .milliseconds(400))
            let after = try screen(harness, paneId)
            #expect(after.trimmingCharacters(in: .whitespacesAndNewlines)
                    == before.trimmingCharacters(in: .whitespacesAndNewlines),
                    "the pane changed after a refused intervention")
        }
    }
}
