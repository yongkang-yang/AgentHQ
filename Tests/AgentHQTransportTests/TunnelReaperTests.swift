import Foundation
import Testing
@testable import AgentHQTransport

@Suite("reaping orphaned tunnels")
struct TunnelReaperTests {
    private let directory = "/tmp/agenthq-501"

    /// Real `ps -eo pid=,command=` output, including the orphan that actually
    /// turned up during development.
    private let processList = """
      2162 ssh -N -T -o ExitOnForwardFailure=yes -o StreamLocalBindUnlink=yes -o BatchMode=yes -o ServerAliveInterval=15 -L /tmp/agenthq-501/ab12cd34.sock:/home/u/.config/herdr/herdr.sock wsl
      3001 ssh -N -L /tmp/agenthq-501/d073bf11.sock:/home/u/.config/herdr/herdr.sock build-box
      4002 ssh -L 8080:localhost:80 someone-elses-host
      4003 ssh -N -L /home/me/private/my.sock:/remote/my.sock my-own-host
      4004 /usr/bin/ssh user@host
      5005 tail -f /tmp/agenthq-501/ab12cd34.sock
      6006 /Applications/AgentHQ.app/Contents/MacOS/AgentHQApp
      7007 /bin/zsh -c source ~/.claude/shell-snapshots/snapshot-zsh.sh && eval 'ssh -N -T -L /tmp/agenthq-501/orphan.sock:/home/u/.config/herdr/herdr.sock wsl'
      8008 ssh-agent -l
    """

    @Test("finds only tunnels forwarding into our directory")
    func findsOurs() {
        #expect(TunnelReaper.orphanPIDs(processList: processList, tunnelDirectory: directory)
                == [2162, 3001])
    }

    @Test("leaves the user's own ssh forwards alone")
    func sparesOtherForwards() {
        let pids = TunnelReaper.orphanPIDs(processList: processList, tunnelDirectory: directory)
        // A port forward, a forward to somewhere else, and a plain ssh session
        // are all somebody else's business.
        #expect(!pids.contains(4002))
        #expect(!pids.contains(4003))
        #expect(!pids.contains(4004))
    }

    @Test("a shell quoting an ssh command is not an ssh process")
    func sparesShellWrappers() {
        // Seen for real during development: a zsh wrapper whose argv embedded
        // both "ssh" and the forward spec. Substring matching sends it a
        // SIGTERM it did not earn.
        #expect(!TunnelReaper.orphanPIDs(processList: processList, tunnelDirectory: directory)
            .contains(7007))
        #expect(!TunnelReaper.isOurTunnel(
            command: "/bin/zsh -c eval 'ssh -N -L /tmp/agenthq-501/x.sock:/r.sock h'",
            directory: directory))
        // ssh-agent is not ssh.
        #expect(!TunnelReaper.isOurTunnel(
            command: "ssh-agent -L /tmp/agenthq-501/x.sock:/r.sock", directory: directory))
    }

    @Test("a non-ssh process mentioning the path is not a tunnel")
    func sparesUnrelatedProcesses() {
        // Matching the directory alone would kill this.
        #expect(!TunnelReaper.isOurTunnel(
            command: "tail -f /tmp/agenthq-501/ab12cd34.sock", directory: directory))
        #expect(!TunnelReaper.orphanPIDs(processList: processList, tunnelDirectory: directory)
            .contains(5005))
    }

    @Test("a trailing slash on the directory does not break matching")
    func trailingSlash() {
        #expect(TunnelReaper.orphanPIDs(processList: processList, tunnelDirectory: directory + "/")
                == [2162, 3001])
    }

    @Test("a directory prefix is not enough — the path must be ours exactly")
    func prefixIsNotAMatch() {
        // `/tmp/agenthq-5` must not match `/tmp/agenthq-501/...`, or one
        // user's launch would reap another's tunnels on a shared machine.
        #expect(TunnelReaper.orphanPIDs(processList: processList, tunnelDirectory: "/tmp/agenthq-5")
                .isEmpty)
    }

    @Test("empty or malformed listings reap nothing")
    func degenerateInput() {
        #expect(TunnelReaper.orphanPIDs(processList: "", tunnelDirectory: directory).isEmpty)
        #expect(TunnelReaper.orphanPIDs(processList: "garbage\nno pid here", tunnelDirectory: directory).isEmpty)
    }

    @Test("reaping terminates exactly the matched pids")
    func reapTerminatesMatches() {
        let killed = Mutex<[pid_t]>([])
        let report = TunnelReaper.reap(
            tunnelDirectory: "/tmp/agenthq-nonexistent-test-dir",
            runProcessList: { processList.replacingOccurrences(of: "/tmp/agenthq-501", with: "/tmp/agenthq-nonexistent-test-dir") },
            terminate: { pid in killed.withLock { $0.append(pid) }; return true }
        )
        #expect(killed.withLock { $0 } == [2162, 3001])
        #expect(report.terminatedPIDs == [2162, 3001])
        #expect(report.removedSockets.isEmpty)
    }
}

/// Minimal lock box so the test's `terminate` closure can record calls.
private final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}
