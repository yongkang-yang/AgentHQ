//  Contains material ported from Shepherd / herdr-manager
//  Copyright (c) Shyam Pandya — MIT License. See NOTICE.
//
//  Ported: herdr socket path resolution order.

import AgentHQKit
import Foundation

/// A herdr socket already on this Mac. Nothing to set up or tear down — the
/// path is the path.
///
/// This is the degenerate case of the remote transport, not a special case.
/// Keeping it behind the same protocol is what stops "local" from quietly
/// becoming the privileged path everything else has to work around.
public actor LocalSocketTransport: Transport {
    private let socketPath: String

    public init(socketPath: String) {
        self.socketPath = socketPath
    }

    public func activate() async throws -> String {
        try SocketPath.validate(socketPath)
        return socketPath
    }

    public func deactivate() async {}
}

// MARK: - Default resolution

public extension LocalSocketTransport {
    /// Where herdr puts its socket on this machine, in the order herdr itself
    /// documents. Ported from Shepherd (MIT) — see NOTICE.
    static func resolveDefaultSocketPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory()
    ) -> String {
        if let explicit = environment["HERDR_SOCKET_PATH"], !explicit.isEmpty {
            return explicit
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return "\(xdg)/herdr/herdr.sock"
        }
        return "\(home)/.config/herdr/herdr.sock"
    }
}
