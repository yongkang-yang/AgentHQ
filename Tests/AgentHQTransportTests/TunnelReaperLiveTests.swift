import Foundation
import Testing
@testable import AgentHQTransport

/// Runs the matcher against this machine's real process table. Identifies
/// only — it never sends a signal, because a reap here would take out tunnels
/// belonging to tests running in parallel.
///
///     AGENTHQ_LIVE_PS=1 swift test
@Suite(
    "reaper against the real process table",
    .enabled(if: ProcessInfo.processInfo.environment["AGENTHQ_LIVE_PS"] != nil,
             "set AGENTHQ_LIVE_PS to run")
)
struct TunnelReaperLiveTests {
    @Test("every match on a live process table is genuinely an ssh tunnel")
    func matchesAreRealTunnels() {
        let listing = TunnelReaper.defaultProcessList()
        #expect(!listing.isEmpty, "ps produced nothing")

        let matched = TunnelReaper.orphanPIDs(
            processList: listing,
            tunnelDirectory: SocketPath.tunnelDirectory()
        )

        // Re-derive each match's command line and check it independently: the
        // executable must be ssh itself, and the forward must be ours.
        let byPID = Dictionary(
            uniqueKeysWithValues: listing.split(separator: "\n").compactMap { line -> (pid_t, String)? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard let space = t.firstIndex(of: " "),
                      let pid = pid_t(t[t.startIndex..<space]) else { return nil }
                return (pid, String(t[t.index(after: space)...]))
            }
        )

        for pid in matched {
            let command = byPID[pid] ?? ""
            let executable = command.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            #expect(executable.split(separator: "/").last == "ssh",
                    "would have signalled pid \(pid), which is not ssh: \(command.prefix(120))")
            #expect(command.contains(SocketPath.tunnelDirectory()),
                    "pid \(pid) does not forward into our directory")
        }
    }
}

/// Actually reaps. Separate opt-in from the identify-only suite, and must be
/// run alone — it will take out tunnels belonging to any test running beside it.
///
///     AGENTHQ_LIVE_REAP=1 swift test --filter LiveReapTests
@Suite(
    "reaping for real",
    .enabled(if: ProcessInfo.processInfo.environment["AGENTHQ_LIVE_REAP"] != nil,
             "set AGENTHQ_LIVE_REAP to run, and run it alone")
)
struct LiveReapTests {
    @Test("terminates leftover tunnels and clears their sockets")
    func reapsForReal() {
        let report = TunnelReaper.reap()

        // Whatever it claims to have terminated must actually be gone.
        for pid in report.terminatedPIDs {
            #expect(kill(pid, 0) != 0 || errno == ESRCH,
                    "pid \(pid) was reported terminated but is still running")
        }
        for path in report.removedSockets {
            #expect(!FileManager.default.fileExists(atPath: path))
        }
    }
}
