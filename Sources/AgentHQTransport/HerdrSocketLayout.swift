import Foundation

/// Where herdr keeps its socket on a given machine.
public enum HerdrSocketLayout {
    /// The unnamed session. herdr puts this socket directly in its config
    /// directory; named sessions get a subdirectory each.
    public static let defaultSession = "default"

    /// The socket path for one session, given the machine's resolved herdr
    /// config directory.
    ///
    /// Pure and absolute by construction. `ssh -L` does not expand `~` in the
    /// remote half of a forward spec — it fails with no useful message — so a
    /// path built here must never contain one.
    public static func socketPath(configDirectory: String, session: String) -> String {
        let root = configDirectory.hasSuffix("/")
            ? String(configDirectory.dropLast())
            : configDirectory
        let name = session.trimmingCharacters(in: .whitespaces)

        if name.isEmpty || name == defaultSession {
            return "\(root)/herdr/herdr.sock"
        }
        return "\(root)/herdr/sessions/\(name)/herdr.sock"
    }

    /// Ask a host where its herdr config directory is.
    ///
    /// One ssh round trip, done once per machine and then remembered. The
    /// remote home directory is not knowable from here and cannot be deferred
    /// to ssh, so there is no way to avoid asking.
    ///
    /// Resolved the way herdr itself resolves it: `XDG_CONFIG_HOME` when set,
    /// otherwise `$HOME/.config`.
    public static func resolveConfigDirectory(
        destination: String,
        port: Int?
    ) async throws -> String {
        var arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=10",
            "-T",
        ]
        if let port {
            arguments.append(contentsOf: ["-p", String(port)])
        }
        arguments.append(destination)
        // `printf` rather than `echo`: no trailing newline to trim and no
        // shell-dependent escape handling.
        arguments.append("printf %s \"${XDG_CONFIG_HOME:-$HOME/.config}\"")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw TransportError.tunnelLaunchFailed(reason: error.localizedDescription)
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let path = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard process.terminationStatus == 0, path.hasPrefix("/") else {
            let detail = String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw TransportError.tunnelExited(
                code: process.terminationStatus,
                stderr: detail.isEmpty
                    ? "could not resolve the herdr config directory on \(destination)"
                    : detail
            )
        }
        return path
    }
}
