import AgentHQKit
import Darwin
import Foundation
import os

/// Runs a short shell script on a machine and returns what it printed.
///
/// The one thing the forwarded herdr socket cannot do is read a file on the
/// far side, and an agent's transcript is a file on the far side. So this is a
/// second way in — deliberately narrow: a script in, bytes out, no session.
/// On this Mac it is `/bin/sh`; elsewhere it is `ssh` to the same destination
/// the tunnel uses, through the same `~/.ssh/config`, as
/// `HerdrSocketLayout.resolveConfigDirectory` already does once per machine.
///
/// Remote runs share one connection through an ssh control master that
/// outlives each call by a minute, so a console polling a transcript pays for
/// the handshake once rather than every few seconds. Measured against the WSL
/// host over Tailscale: 0.53s for the first run, 0.03s for each after it. The
/// master is ssh's own process, not the tunnel's, so nothing here changes
/// what the tunnel does, and `TunnelReaper` (which matches `-L` forwards)
/// leaves it alone; idle, it exits by itself.
public struct MachineShell: Sendable {
    private let executable: String
    private let prefix: [String]

    public init(transport: MachineTransport, uid: uid_t = getuid()) {
        switch transport {
        case .local:
            executable = "/bin/sh"
            prefix = ["-c"]
        case .ssh(let destination, let port, _, _):
            executable = "/usr/bin/ssh"
            prefix = Self.sshArguments(destination: destination, port: port, uid: uid)
        }
    }

    /// `BatchMode` for the tunnel's reason: there is no tty to prompt on.
    /// `ConnectTimeout` and the keepalives bound a run on a link that has
    /// gone away, so a console never waits on a read that cannot finish.
    /// The control socket sits in the tunnel directory, which is 0700 —
    /// anyone who can open it can run commands on the far side.
    static func sshArguments(destination: String, port: Int?, uid: uid_t) -> [String] {
        var args = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(SocketPath.tunnelDirectory(uid: uid))/%C.ctl",
            "-o", "ControlPersist=60",
            "-T",
        ]
        if let port { args += ["-p", String(port)] }
        args.append(destination)
        return args
    }

    /// The argument vector for one script.
    ///
    /// Remotely, ssh hands its command to the user's login shell, which may be
    /// zsh or fish; the script is POSIX sh, so it goes to `sh -c` in single
    /// quotes, which read the same in all three.
    func arguments(for script: String) -> [String] {
        if executable == "/bin/sh" { return prefix + [script] }
        return prefix + ["sh -c " + Self.quoted(script)]
    }

    public func run(_ script: String) async throws -> Data {
        if executable != "/bin/sh" { try Self.prepareControlDirectory() }
        let arguments = arguments(for: script)
        let executable = executable

        // Off the caller's executor: waiting on a child process is a blocking
        // wait, and invariant 6 is about exactly that.
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardInput = FileHandle.nullDevice
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: TransportError.tunnelLaunchFailed(
                        reason: error.localizedDescription
                    ))
                    return
                }

                // Both pipes drained before waiting: a child that fills one
                // while the parent blocks on the other never exits.
                let stderrBytes = OSAllocatedUnfairLock(initialState: Data())
                let group = DispatchGroup()
                group.enter()
                let errorHandle = errors.fileHandleForReading
                DispatchQueue.global().async {
                    let bytes = errorHandle.readDataToEndOfFile()
                    stderrBytes.withLock { $0 = bytes }
                    group.leave()
                }
                let data = output.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.blockUntilExited()
                let errorData = stderrBytes.withLock { $0 }

                guard process.terminationStatus == 0 else {
                    let detail = String(decoding: errorData, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(throwing: TransportError.tunnelExited(
                        code: process.terminationStatus,
                        stderr: detail.isEmpty ? "the command did not finish" : detail
                    ))
                    return
                }
                continuation.resume(returning: data)
            }
        }
    }

    private static func prepareControlDirectory() throws {
        let directory = SocketPath.tunnelDirectory()
        do {
            try FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw TransportError.tunnelDirectoryUnavailable(
                path: directory, reason: error.localizedDescription
            )
        }
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
