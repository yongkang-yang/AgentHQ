import AgentHQKit
import Foundation

// MARK: - TransportError

public enum TransportError: Error, Sendable, CustomStringConvertible {
    case socketPathTooLong(path: String, limit: Int)
    case tunnelDirectoryUnavailable(path: String, reason: String)
    case tunnelLaunchFailed(reason: String)
    case tunnelExited(code: Int32, stderr: String)

    public var description: String {
        switch self {
        case .socketPathTooLong(let path, let limit):
            return "Socket path is \(path.utf8.count) bytes, over the \(limit)-byte sun_path limit: \(path)"
        case .tunnelDirectoryUnavailable(let path, let reason):
            return "Cannot prepare tunnel directory \(path): \(reason)"
        case .tunnelLaunchFailed(let reason):
            return "Could not start ssh: \(reason)"
        case .tunnelExited(let code, let stderr):
            return "ssh exited with code \(code): \(stderr)"
        }
    }
}

// MARK: - Transport

/// Produces a local unix socket path that speaks herdr's protocol, and keeps
/// it alive.
///
/// The entire multi-machine design rests on this one-line contract: whatever a
/// machine is, it ends up as a path on this Mac. `AgentHQHerdr` takes a path
/// and has no opinion about how it got there.
public protocol Transport: Actor {
    /// Bring the socket up and return its local path. Idempotent — calling it
    /// on an already-active transport returns the same path.
    func activate() async throws -> String

    /// Tear the socket down and release anything holding it open.
    func deactivate() async

    /// Whether the path ``activate()`` returned is still carrying traffic.
    ///
    /// Distinguishes the two failures that look identical from above: the
    /// subscription's socket hiccuped and will come back on its own, or the
    /// thing that was serving that path is gone and no amount of resubscribing
    /// will find it. Only the second one needs the transport rebuilt, and
    /// rebuilding on the first would throw away a recovery that was already
    /// working.
    func isHealthy() async -> Bool
}

// MARK: - Socket path limits

public enum SocketPath {
    /// `sockaddr_un.sun_path` is 104 bytes on Darwin, minus the NUL. Exceeding
    /// it fails at `connect(2)` with a path that looks perfectly reasonable in
    /// a log, so it is checked up front rather than discovered later.
    public static let maxBytes = 103

    public static func validate(_ path: String) throws {
        guard path.utf8.count <= maxBytes else {
            throw TransportError.socketPathTooLong(path: path, limit: maxBytes)
        }
    }

    /// Directory holding forwarded sockets for this user.
    ///
    /// Deliberately short and outside Application Support: the obvious home,
    /// `~/Library/Application Support/AgentHQ/tunnels/<uuid>.sock`, runs about
    /// 100 bytes before the user's home directory is even long, which leaves
    /// no margin under the limit above.
    ///
    /// Created 0700 — a forwarded herdr socket accepts writes to the far side.
    public static func tunnelDirectory(uid: uid_t = getuid()) -> String {
        "/tmp/agenthq-\(uid)"
    }

    /// Local path for one machine's forwarded socket. Uses a short prefix of
    /// the machine id; a collision inside one user's tunnel directory is not
    /// a security boundary, only a naming one.
    public static func forwarded(machine: MachineID, uid: uid_t = getuid()) -> String {
        let short = machine.raw
            .replacingOccurrences(of: "-", with: "")
            .prefix(8)
            .lowercased()
        return "\(tunnelDirectory(uid: uid))/\(short).sock"
    }
}
