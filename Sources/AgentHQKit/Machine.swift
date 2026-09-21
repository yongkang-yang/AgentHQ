import Foundation

// MARK: - MachineID

/// Stable identity for one machine in the fleet, generated when the machine is
/// added and persisted from then on.
///
/// Not derived from hostname, user, or socket path: all three are things the
/// user edits, and an id that changes when a host is renamed would orphan every
/// dwell timer and acknowledged notification attached to it.
public struct MachineID: Hashable, Sendable, Codable {
    public let raw: String

    public init(_ raw: String) {
        self.raw = raw
    }

    public static func generate() -> MachineID {
        MachineID(UUID().uuidString)
    }

    public init(from decoder: Decoder) throws {
        self.raw = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

// MARK: - MachineTransport

/// How AgentHQ reaches a machine's herdr socket.
///
/// Both cases resolve to a local unix socket path, which is the load-bearing
/// design decision: `ssh -L <local>:<remote>` forwards a unix socket, so a
/// remote machine reduces to "a different path on this Mac". Nothing above
/// this type — not the NDJSON client, not the herdr adapter — needs to know
/// which case it is looking at.
public enum MachineTransport: Sendable, Equatable, Codable {
    /// A herdr socket on this Mac.
    case local(socketPath: String)

    /// A herdr socket on another host, forwarded to a local socket path by a
    /// managed `ssh -N -L` process.
    ///
    /// - Parameters:
    ///   - destination: An ssh destination. Prefer a `~/.ssh/config` alias —
    ///     that is where key selection, jump hosts, and keepalive settings
    ///     belong, not in this app's settings.
    ///   - port: Non-nil only to override what ssh_config already resolves.
    ///   - remoteSocketPath: Where herdr's socket lives on the far side.
    case ssh(destination: String, port: Int?, remoteSocketPath: String)

    /// WSL is not a case here on purpose. A WSL distro running its own sshd is
    /// an ordinary `.ssh` destination; routing through Windows sshd and
    /// `wsl.exe` instead would put the socket in a different namespace, where
    /// forwarding cannot reach it.
    public var isRemote: Bool {
        if case .ssh = self { return true }
        return false
    }
}

// MARK: - Machine

/// A configured machine. Persisted; holds no live state.
public struct Machine: Sendable, Equatable, Identifiable, Codable {
    public let id: MachineID
    /// What the user calls this machine. Shown on every agent row.
    public var displayName: String
    public var transport: MachineTransport
    /// A disabled machine stays configured but is not connected or polled.
    public var isEnabled: Bool

    public init(
        id: MachineID = .generate(),
        displayName: String,
        transport: MachineTransport,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.transport = transport
        self.isEnabled = isEnabled
    }
}

// MARK: - MachineReachability

/// Whether AgentHQ can currently talk to a machine.
///
/// This is a **separate axis from agent state**, and keeping it separate is a
/// product requirement, not a modelling preference. When SSH drops, the agents
/// on the far side are almost certainly fine — AgentHQ simply stopped being
/// able to see them. Folding that into a per-agent "crashed" state would turn
/// one dropped tunnel into twelve false alarms, which is precisely the kind of
/// fabricated state the UI must never show.
public enum MachineReachability: Sendable, Equatable {
    case disabled
    case connecting
    case connected
    case reconnecting(attempt: Int)
    case unreachable(reason: String)

    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// True while AgentHQ still expects to recover on its own. The UI should
    /// stay calm here and not present it as a failure the user must act on.
    public var isTransient: Bool {
        switch self {
        case .connecting, .reconnecting: return true
        case .disabled, .connected, .unreachable: return false
        }
    }

    /// What the machine's agents are worth while in this state. Anything but
    /// `.connected` means the last known agent list is stale, and rows built
    /// from it must be shown as stale rather than as current truth.
    public var agentsAreStale: Bool {
        !isConnected
    }
}
