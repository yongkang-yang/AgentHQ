import Foundation

/// The directory a new shell starts in, made into a script that runs on the
/// target machine and prints where it really is.
///
/// Resolved on the machine itself, not here: a WSL path means nothing to this
/// Mac, `~` is the remote user's home, and a directory that does not exist
/// should be refused before a workspace is opened on it.
public enum LaunchDirectory {
    /// The script, or nil when the text is not a directory this will look up.
    ///
    /// The text goes into a shell script, so it is accepted only as an
    /// absolute path, `~`, or `~/…`, and always in single quotes. `~user` and
    /// relative paths are refused rather than guessed at: relative to what?
    public static func script(for typed: String) -> String? {
        let path = typed.trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty,
              !path.contains(where: { $0.isNewline || $0 == "\0" })
        else { return nil }

        let target: String
        if path == "~" {
            target = #""$HOME""#
        } else if path.hasPrefix("~/") {
            target = #""$HOME"/"# + quoted(String(path.dropFirst(2)))
        } else if path.hasPrefix("/") {
            target = quoted(path)
        } else {
            return nil
        }
        return "cd -- \(target) && pwd -P"
    }

    /// The directory a script printed, or nil if it printed no absolute path.
    public static func resolved(from output: Data) -> String? {
        let text = String(decoding: output, as: UTF8.self)
        guard let line = text.split(whereSeparator: \.isNewline).last.map(String.init),
              line.hasPrefix("/")
        else { return nil }
        return line
    }

    /// The workspace label for a directory: its last component, which is what
    /// herdr and the panel's rows already call a project.
    public static func label(for directory: String) -> String {
        let name = (directory as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? directory : name
    }

    static func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

/// Why New shell did not open anything.
public enum LaunchError: Error, Sendable, Equatable {
    /// Not an absolute path, `~` or `~/…`.
    case unsupportedPath
    /// The machine looked and found no such directory, in its own words.
    case directoryUnavailable(String)
    /// The machine has no herdr connection to open a workspace through.
    case machineUnreachable

    public var summary: String {
        switch self {
        case .unsupportedPath:
            "Use an absolute path on that machine, or one starting with ~/."
        case .directoryUnavailable(let reason):
            reason.isEmpty ? "That directory is not there." : reason
        case .machineUnreachable:
            "That machine is not connected."
        }
    }
}
