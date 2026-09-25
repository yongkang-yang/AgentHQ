import AgentHQKit
import AgentHQTransport
import Foundation
import Testing

private let liveDestination = ProcessInfo.processInfo.environment["AGENTHQ_LIVE_TRANSCRIPT_SSH"]
private let isLive = ProcessInfo.processInfo.environment["AGENTHQ_LIVE_TRANSCRIPT"] != nil

/// Reads each agent's newest real session through the same script and shell
/// the console uses, on this Mac and, when named, over ssh on another host.
///
/// The unit suite pins the parsers to captured shapes; this is what proves the
/// script finds the file where each agent actually keeps it, on each kind of
/// machine — including opencode's fallback to python3 where a host has no
/// sqlite3, which a stock WSL Ubuntu does not.
///
///     AGENTHQ_LIVE_TRANSCRIPT=1 [AGENTHQ_LIVE_TRANSCRIPT_SSH=wsl] \
///     swift test --filter LiveTranscriptTests
@Suite(
    "each agent's real transcript reads on a real machine",
    .enabled(if: isLive, "set AGENTHQ_LIVE_TRANSCRIPT to run"),
    .serialized
)
struct LiveTranscriptTests {
    /// Finds the newest session of each agent on the machine, in the form its
    /// herdr integration reports: an id for claude, codex and opencode, a
    /// path for pi.
    private static let discovery = #"""
    c=$(ls -t "$HOME"/.claude/projects/*/*.jsonl 2>/dev/null | head -n 1)
    [ -n "$c" ] && echo "claude id $(basename "$c" .jsonl)"
    x=$(ls -t "$HOME"/.codex/sessions/*/*/*/rollout-*.jsonl 2>/dev/null | head -n 1)
    [ -n "$x" ] && echo "codex id $(basename "$x" .jsonl | rev | cut -c 1-36 | rev)"
    p=$(ls -t "$HOME"/.pi/agent/sessions/*/*.jsonl 2>/dev/null | head -n 1)
    [ -n "$p" ] && echo "pi path $p"
    db="$HOME/.local/share/opencode/opencode.db"
    q="select id from session where parent_id is null order by time_updated desc limit 1"
    if [ -f "$db" ]; then
      if command -v sqlite3 >/dev/null 2>&1; then o=$(sqlite3 -readonly "$db" "$q")
      else o=$(python3 -c "import sqlite3,sys; print(sqlite3.connect('file:'+sys.argv[1]+'?mode=ro',uri=True).execute(sys.argv[2]).fetchone()[0])" "$db" "$q"); fi
      [ -n "$o" ] && echo "opencode id $o"
    fi
    true
    """#

    private func sessions(on shell: MachineShell) async throws -> [AgentSessionRef] {
        let output = String(decoding: try await shell.run(Self.discovery), as: UTF8.self)
        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count == 3, let kind = AgentSessionRef.Kind(rawValue: parts[1]) else { return nil }
            return AgentSessionRef(agent: parts[0], kind: kind, value: parts[2])
        }
    }

    private func check(_ shell: MachineShell, where machine: String) async throws {
        let found = try await sessions(on: shell)
        #expect(!found.isEmpty, "no agent sessions found on \(machine)")
        for session in found {
            let script = try #require(TranscriptScript.script(for: session, known: 0),
                                      "no script for \(session.agent) on \(machine)")
            let read = try #require(TranscriptRead(output: try await shell.run(script)),
                                    "\(session.agent) on \(machine) answered outside the protocol")
            #expect(read != .missing, "\(session.agent) on \(machine): session not found")
            #expect(read != .noTool, "\(session.agent) on \(machine): no reader for its store")

            var buffer = TranscriptBuffer(format: try #require(session.format))
            buffer.apply(read)
            #expect(!buffer.entries.isEmpty, "\(session.agent) on \(machine) parsed to nothing")

            // And a second read with the cursor is the cheap answer.
            let again = try #require(TranscriptScript.script(for: session, known: buffer.cursor))
            let second = try #require(TranscriptRead(output: try await shell.run(again)))
            if case .full = second {
                Issue.record("\(session.agent) on \(machine) re-sent the whole transcript unchanged")
            }
        }
    }

    @Test("on this Mac")
    func local() async throws {
        try await check(MachineShell(transport: .local(socketPath: "")), where: "this Mac")
    }

    @Test("over ssh", .enabled(if: liveDestination != nil, "set AGENTHQ_LIVE_TRANSCRIPT_SSH to a host"))
    func remote() async throws {
        let destination = try #require(liveDestination)
        try await check(
            MachineShell(transport: .ssh(destination: destination, port: nil, session: "default", remoteSocketPath: nil)),
            where: destination
        )
    }
}
