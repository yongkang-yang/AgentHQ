import AgentHQKit
import AgentHQTransport
import Foundation

/// Reads the machines the user already configured in herdr.
///
/// herdr keeps saved SSH machines in
/// `~/.local/state/herdr/client/endpoints.json`, written by
/// `herdr machine add`. Its fields line up with ``Machine`` closely enough
/// that AgentHQ has no reason to ask for the same information twice: add a
/// machine in herdr and it shows up here.
///
/// **This is internal herdr state, not a published API.** It is versioned
/// (`version: 1`) and nothing promises it will keep its shape. So it is an
/// import source, never a dependency: a missing, unreadable, or unrecognized
/// file yields no machines rather than an error the user has to care about,
/// and AgentHQ's own configuration remains the fallback.
public struct HerdrMachineRegistry: Sendable {
    /// The `version` values this loader understands. A newer file is ignored
    /// rather than guessed at — silently importing machines from a schema we
    /// do not know is worse than importing none.
    public static let supportedVersions: Set<Int> = [1]

    public static func defaultURL(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: "\(home)/.local/state/herdr/client/endpoints.json")
    }

    /// Machines from herdr's registry, or an empty array if there is nothing
    /// usable to read.
    public static func machines(
        at url: URL? = nil,
        home: String = NSHomeDirectory()
    ) -> [Machine] {
        let location = url ?? defaultURL(home: home)
        guard let data = try? Data(contentsOf: location) else { return [] }
        return machines(from: data)
    }

    static func machines(from data: Data) -> [Machine] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let version = (root["version"] as? NSNumber)?.intValue,
            supportedVersions.contains(version),
            let entries = root["ssh"] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            guard
                let id = entry["id"] as? String, !id.isEmpty,
                let target = entry["target"] as? String, !target.isEmpty
            else { return nil }

            let label = entry["label"] as? String
            let session = entry["session"] as? String ?? HerdrSocketLayout.defaultSession

            return Machine(
                // herdr already generates a stable id per machine, so adopting
                // it keeps dwell timers and acknowledged notifications
                // attached across restarts — and across a rename, which is
                // exactly what a hostname-derived id would break.
                id: MachineID(id),
                displayName: label?.isEmpty == false ? label! : target,
                transport: .ssh(
                    destination: target,
                    port: nil,
                    session: session,
                    // Resolved on first connect: the remote home is not
                    // knowable from here and ssh will not expand a tilde in a
                    // forward spec.
                    remoteSocketPath: nil
                ),
                isEnabled: entry["enabled"] as? Bool ?? true
            )
        }
    }
}
