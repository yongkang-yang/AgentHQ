import AgentHQKit
import Darwin
import Foundation

/// A herdr socket on another host, forwarded here by a supervised `ssh -N -L`.
///
/// Unix-to-unix forwarding (OpenSSH 6.7+) is what makes the rest of the app
/// transport-blind. The alternative — piping `socat` over ssh's stdio — would
/// force the NDJSON client off a raw fd and onto a pipe abstraction, spreading
/// remoteness through code that currently has no idea it exists.
///
/// Measured against a WSL2 host over Tailscale: usable 0.3s after launch, two
/// concurrent connections served independently, 200KB round trip in ~98ms.
public actor SSHTunnel: Transport {
    private let machine: MachineID
    private let destination: String
    private let port: Int?
    private let session: String
    private var remoteSocketPath: String?
    private let localSocketPath: String
    private let readinessTimeout: TimeInterval

    private var process: Process?
    private var stderr: Pipe?

    public init(
        machine: MachineID,
        destination: String,
        port: Int?,
        session: String = "default",
        remoteSocketPath: String? = nil,
        localSocketPath: String? = nil,
        readinessTimeout: TimeInterval = 20
    ) {
        self.machine = machine
        self.destination = destination
        self.port = port
        self.session = session
        self.remoteSocketPath = remoteSocketPath
        self.localSocketPath = localSocketPath ?? SocketPath.forwarded(machine: machine)
        self.readinessTimeout = readinessTimeout
    }

    // MARK: - Transport

    public func activate() async throws -> String {
        try SocketPath.validate(localSocketPath)
        let remote = try await resolvedRemoteSocketPath()

        if let process, process.isRunning,
           UnixSocketProbe.probe(path: localSocketPath) == .ready {
            return localSocketPath
        }

        await deactivate()
        try prepareTunnelDirectory()
        try launch(remote: remote)
        try await waitUntilReady()
        return localSocketPath
    }

    public func deactivate() async {
        if let process, process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        process = nil
        stderr = nil
        // ssh removes the socket on a clean exit; on a kill it does not, and
        // the next launch would fail to bind. StreamLocalBindUnlink covers
        // that too, but only for ssh's own bind — clean up regardless.
        try? FileManager.default.removeItem(atPath: localSocketPath)
    }

    /// Whether the tunnel is currently carrying traffic. Distinguishes "ssh
    /// died" from "ssh is alive but the far side went away", which are the
    /// same thing to the user and different things to the supervisor.
    public func isHealthy() -> Bool {
        guard let process, process.isRunning else { return false }
        return UnixSocketProbe.probe(path: localSocketPath) == .ready
    }

    // MARK: - Process

    private func prepareTunnelDirectory() throws {
        let directory = (localSocketPath as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                // 0700: a forwarded herdr socket accepts writes to the far
                // side, so anyone who can open it can drive another machine's
                // agents.
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: directory
            )
        } catch {
            throw TransportError.tunnelDirectoryUnavailable(
                path: directory, reason: error.localizedDescription
            )
        }
    }

    /// Resolve the far-side socket once and remember it.
    private func resolvedRemoteSocketPath() async throws -> String {
        if let remoteSocketPath { return remoteSocketPath }
        let configDirectory = try await HerdrSocketLayout.resolveConfigDirectory(
            destination: destination, port: port
        )
        let path = HerdrSocketLayout.socketPath(
            configDirectory: configDirectory, session: session
        )
        remoteSocketPath = path
        return path
    }

    private func launch(remote: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = Self.arguments(
            destination: destination, port: port,
            local: localSocketPath, remote: remote
        )
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice

        let stderr = Pipe()
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw TransportError.tunnelLaunchFailed(reason: error.localizedDescription)
        }

        self.process = process
        self.stderr = stderr
    }

    /// Poll until the tunnel carries a real connection, ssh exits, or we give
    /// up.
    ///
    /// The socket file appearing proves nothing: `ssh -L` binds it immediately,
    /// before it has any idea whether the remote socket exists. A tunnel to a
    /// host with no herdr running is byte-for-byte identical on disk to a
    /// working one, and `connect(2)` succeeds against both. Only a read tells
    /// them apart.
    private func waitUntilReady() async throws {
        let deadline = Date().addingTimeInterval(readinessTimeout)
        var consecutiveRefusals = 0
        var consecutiveReady = 0

        while Date() < deadline {
            if let process, !process.isRunning {
                throw TransportError.tunnelExited(
                    code: process.terminationStatus, stderr: drainStderr()
                )
            }

            switch UnixSocketProbe.probe(path: localSocketPath) {
            case .ready:
                // One ready is not enough. In the moment just after ssh binds
                // the socket it will accept a connection and hold it while the
                // channel is still being set up, so a peek sees an open
                // connection with no data — indistinguishable from a healthy
                // idle herdr. Measured: the probe taken at bind time reported
                // ready on 1 of 3 runs against a deliberately dead forward,
                // while every later probe correctly reported a hangup.
                consecutiveReady += 1
                consecutiveRefusals = 0
                if consecutiveReady >= Self.requiredConsecutiveReady { return }

            case .peerClosed:
                // ssh has bound the socket and is accepting connections, but
                // the far end is not there: it opens the channel, fails to
                // reach the remote socket, and hangs up. A running herdr never
                // does this, so a short run of these means the answer is no.
                // Waiting out the full timeout would make "herdr isn't running
                // over there" take 20s to say.
                consecutiveReady = 0
                consecutiveRefusals += 1
                if consecutiveRefusals >= Self.refusalsBeforeGivingUp {
                    await deactivate()
                    throw TransportError.tunnelLaunchFailed(
                        reason: "\(destination) accepted the tunnel but nothing is listening on \(remoteSocketPath ?? "its herdr socket") — is herdr running there?"
                    )
                }

            case .connectFailed:
                // ssh has not bound yet. Expected for the first few hundred
                // milliseconds; not evidence of anything.
                consecutiveRefusals = 0
                consecutiveReady = 0
            }

            try? await Task.sleep(for: .milliseconds(150))
        }

        let reason = drainStderr()
        await deactivate()
        throw TransportError.tunnelLaunchFailed(
            reason: reason.isEmpty
                ? "forwarded socket never carried a connection within \(Int(readinessTimeout))s"
                : reason
        )
    }

    /// Five refusals at 150ms is roughly 0.75s of the far side actively
    /// hanging up — long enough to ride out a herdr that is mid-restart, short
    /// enough that a machine with herdr stopped reports in about a second.
    private static let refusalsBeforeGivingUp = 5

    /// Two readings 150ms apart, so a connection accepted during channel setup
    /// cannot pass as a working tunnel. Costs one extra poll on the happy path
    /// against a tunnel that would otherwise be reported up before it is.
    private static let requiredConsecutiveReady = 2

    /// Whatever ssh has complained about so far. Read non-blocking: ssh is
    /// still running in the healthy case and a blocking read would hang.
    private func drainStderr() -> String {
        guard let stderr else { return "" }
        let data = stderr.fileHandleForReading.availableData
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Command

    /// The exact argument vector AgentHQ runs.
    ///
    /// Every option here is load-bearing:
    ///
    /// - `ExitOnForwardFailure=yes` — without it ssh stays up after the
    ///   forward fails, and the machine looks connected while every request to
    ///   its socket is refused. Fail loudly instead.
    /// - `StreamLocalBindUnlink=yes` — removes a stale socket file left by a
    ///   previous run; otherwise bind fails on the second launch forever.
    /// - `BatchMode=yes` — never prompt. There is no tty to prompt on, and a
    ///   hidden prompt reads as a hang. Keys come from ssh-agent; passwords
    ///   are not a supported path.
    /// - `ServerAliveInterval`/`CountMax` — a dropped link is detected in ~45s
    ///   instead of hanging until TCP gives up.
    /// - `-N -T` — forward only, no remote command, no tty.
    ///
    /// Host keys, jump hosts, and identity files are intentionally absent:
    /// they belong in `~/.ssh/config` under the destination alias, which is
    /// also why `destination` is passed through verbatim.
    public static func arguments(
        destination: String,
        port: Int?,
        local localSocketPath: String,
        remote remoteSocketPath: String
    ) -> [String] {
        var args = [
            "-N", "-T",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "StreamLocalBindUnlink=yes",
            "-o", "BatchMode=yes",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-L", "\(localSocketPath):\(remoteSocketPath)",
        ]
        if let port {
            args.append(contentsOf: ["-p", String(port)])
        }
        args.append(destination)
        return args
    }

    /// The command as it would run with the far-side path already known.
    /// Only meaningful once resolved; used for diagnostics and tests.
    public func commandArguments() -> [String] {
        Self.arguments(
            destination: destination,
            port: port,
            local: localSocketPath,
            remote: remoteSocketPath ?? "<unresolved>"
        )
    }
}

// MARK: - Building a transport from a machine

public extension MachineTransport {
    /// The transport that realizes this configuration.
    func makeTransport(for machine: MachineID) -> any Transport {
        switch self {
        case .local(let socketPath):
            return LocalSocketTransport(socketPath: socketPath)
        case .ssh(let destination, let port, let session, let remoteSocketPath):
            return SSHTunnel(
                machine: machine,
                destination: destination,
                port: port,
                session: session,
                remoteSocketPath: remoteSocketPath
            )
        }
    }
}
