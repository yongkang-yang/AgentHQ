import Darwin
import Foundation

/// Cleans up tunnels left behind by a previous run.
///
/// `ssh -N -L` is an independent process: if AgentHQ crashes, is force quit,
/// or is killed by a debugger, its tunnels keep running and their sockets stay
/// on disk. On the next launch those look exactly like live tunnels — the
/// socket file is there and `connect(2)` succeeds — so they have to be cleared
/// rather than inherited.
public enum TunnelReaper {
    public struct Report: Sendable, Equatable {
        public let terminatedPIDs: [pid_t]
        public let removedSockets: [String]

        public var isEmpty: Bool { terminatedPIDs.isEmpty && removedSockets.isEmpty }
    }

    /// Terminate leftover tunnels and delete their socket files.
    ///
    /// Only processes forwarding into *our* tunnel directory are touched. A
    /// user's own `ssh -L` for anything else is left alone, which is why the
    /// match is on the full forward spec and not merely on "ssh".
    ///
    /// Note that a second AgentHQ launched while the first is running would
    /// reap the first's tunnels. That is a real limitation, and the reason to
    /// prevent a second instance rather than to widen this.
    @discardableResult
    public static func reap(
        tunnelDirectory: String = SocketPath.tunnelDirectory(),
        runProcessList: () -> String = defaultProcessList,
        terminate: (pid_t) -> Bool = { kill($0, SIGTERM) == 0 }
    ) -> Report {
        let pids = orphanPIDs(
            processList: runProcessList(),
            tunnelDirectory: tunnelDirectory
        )
        let terminated = pids.filter(terminate)

        var removed: [String] = []
        let manager = FileManager.default
        if let entries = try? manager.contentsOfDirectory(atPath: tunnelDirectory) {
            for entry in entries where entry.hasSuffix(".sock") {
                let path = "\(tunnelDirectory)/\(entry)"
                // Only sockets, and only after their tunnel is gone. A file
                // that is not a socket is not ours to delete.
                guard isSocket(path) else { continue }
                if (try? manager.removeItem(atPath: path)) != nil {
                    removed.append(path)
                }
            }
        }
        return Report(terminatedPIDs: terminated, removedSockets: removed)
    }

    /// Pick our tunnels out of a process listing.
    ///
    /// Pure so the matching can be tested without spawning anything — getting
    /// this wrong means killing something that belongs to the user.
    static func orphanPIDs(processList: String, tunnelDirectory: String) -> [pid_t] {
        let directory = tunnelDirectory.hasSuffix("/")
            ? String(tunnelDirectory.dropLast())
            : tunnelDirectory

        return processList.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { return nil }
            guard let pid = pid_t(trimmed[trimmed.startIndex..<space]) else { return nil }

            let command = String(trimmed[trimmed.index(after: space)...])
            guard isOurTunnel(command: command, directory: directory) else { return nil }
            return pid
        }
    }

    static func isOurTunnel(command: String, directory: String) -> Bool {
        // The executable must *be* ssh, not merely mention it. Substring
        // matching is not safe here: a shell running a command that contains
        // both "ssh" and our forward spec — a script, an editor, a terminal
        // wrapper, this app's own test harness — matches on content it is only
        // quoting. That process then gets a SIGTERM it did not earn. Seen for
        // real: a zsh wrapper whose argv embedded both strings.
        guard let executable = command.split(separator: " ", maxSplits: 1).first,
              executable.split(separator: "/").last == "ssh"
        else { return false }

        // And it must be forwarding a socket in our directory. The trailing
        // slash keeps /tmp/agenthq-5 from matching /tmp/agenthq-501.
        return command.contains("-L \(directory)/") || command.contains("-L\(directory)/")
    }

    private static func isSocket(_ path: String) -> Bool {
        var info = stat()
        guard stat(path, &info) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFSOCK
    }

    public static func defaultProcessList() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-eo", "pid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
