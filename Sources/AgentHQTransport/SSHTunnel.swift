import AgentHQKit
import Foundation

/// A herdr socket on another host, forwarded here by a managed `ssh -N -L`.
///
/// Unix-to-unix forwarding (OpenSSH 6.7+) is what makes the rest of the app
/// transport-blind. The alternative — piping `socat` over ssh's stdio — would
/// force the NDJSON client off a raw fd and onto a pipe abstraction, spreading
/// remoteness through code that currently has no idea it exists.
///
/// Process management is milestone 2; ``arguments(destination:port:local:remote:)``
/// is already real so the command can be reviewed and tested before anything
/// spawns it.
public actor SSHTunnel: Transport {
    private let machine: MachineID
    private let destination: String
    private let port: Int?
    private let remoteSocketPath: String
    private let localSocketPath: String

    private var process: Process?

    public init(
        machine: MachineID,
        destination: String,
        port: Int?,
        remoteSocketPath: String,
        localSocketPath: String? = nil
    ) {
        self.machine = machine
        self.destination = destination
        self.port = port
        self.remoteSocketPath = remoteSocketPath
        self.localSocketPath = localSocketPath ?? SocketPath.forwarded(machine: machine)
    }

    public func activate() async throws -> String {
        try SocketPath.validate(localSocketPath)
        // TODO(milestone 2): launch and supervise the ssh process, wait for the
        // local socket to accept a connection, and reconnect with backoff when
        // it exits. Until then this transport is inert by design rather than
        // half-working.
        throw TransportError.tunnelLaunchFailed(reason: "SSH tunnel supervision not implemented yet")
    }

    public func deactivate() async {
        process?.terminate()
        process = nil
        try? FileManager.default.removeItem(atPath: localSocketPath)
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

    public nonisolated var commandArguments: [String] {
        Self.arguments(
            destination: destination,
            port: port,
            local: localSocketPath,
            remote: remoteSocketPath
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
        case .ssh(let destination, let port, let remoteSocketPath):
            return SSHTunnel(
                machine: machine,
                destination: destination,
                port: port,
                remoteSocketPath: remoteSocketPath
            )
        }
    }
}
