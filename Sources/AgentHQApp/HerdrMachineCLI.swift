import AgentHQTransport
import Foundation

/// `herdr machine`, for the changes to herdr's saved machines that herdr
/// should make itself rather than have its registry file edited under it.
enum HerdrMachineCLI {
    enum Failure: LocalizedError {
        case herdrMissing
        case exited(status: Int32, message: String)

        var errorDescription: String? {
            switch self {
            case .herdrMissing:
                "Could not find the herdr executable on this Mac."
            case .exited(let status, let message):
                // herdr's own words when it gave any: they name the profile
                // and what it refused.
                message.isEmpty ? "herdr exited with status \(status)." : message
            }
        }
    }

    /// `herdr machine enable|disable <profile id>`.
    static func setEnabled(_ isEnabled: Bool, profile: String) async throws {
        try await run(["machine", isEnabled ? "enable" : "disable", profile])
    }

    /// Off the main actor: a Process wait blocks its thread until herdr exits.
    private static func run(_ arguments: [String]) async throws {
        guard let binary = GhosttyReveal.herdrBinary() else { throw Failure.herdrMissing }
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            let errors = Pipe()
            process.standardError = errors
            process.standardOutput = FileHandle.nullDevice
            try process.run()
            process.blockUntilExited()
            guard process.terminationStatus == 0 else {
                let message = String(
                    decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                throw Failure.exited(status: process.terminationStatus, message: message)
            }
        }.value
    }
}
