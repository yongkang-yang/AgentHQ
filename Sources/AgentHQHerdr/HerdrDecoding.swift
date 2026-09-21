import Foundation

/// Decoding for herdr 0.9.0 / protocol 22.
///
/// Field names below were read off a live socket, not inferred from an older
/// client. Protocol 22 renamed enough that guessing would quietly produce
/// empty rows: panes carry `revision` where 17 had `state_change_seq`, and
/// workspaces and tabs carry `label` where 17 had `name`.
extension LiveHerdrClient {
    static func decodeSnapshot(_ snap: [String: Any]) -> HerdrSnapshot {
        let workspaces = snap["workspaces"] as? [[String: Any]] ?? []
        let panes = snap["panes"] as? [[String: Any]] ?? []

        var workspaceNames: [String: String] = [:]
        for workspace in workspaces {
            guard let id = workspace["workspace_id"] as? String, !id.isEmpty else { continue }
            workspaceNames[id] = workspace["label"] as? String ?? id
        }

        return HerdrSnapshot(
            herdrVersion: snap["version"] as? String ?? "",
            protocolVersion: (snap["protocol"] as? NSNumber)?.intValue ?? 0,
            panes: panes.compactMap(decodePane),
            workspaceNames: workspaceNames
        )
    }

    static func decodePane(_ pane: [String: Any]) -> HerdrPane? {
        guard let paneId = pane["pane_id"] as? String, !paneId.isEmpty else { return nil }
        return HerdrPane(
            paneId: paneId,
            workspaceId: pane["workspace_id"] as? String ?? "",
            tabId: pane["tab_id"] as? String ?? "",
            agentStatus: pane["agent_status"] as? String ?? "unknown",
            agent: pane["agent"] as? String,
            title: pane["terminal_title_stripped"] as? String
                ?? pane["terminal_title"] as? String,
            // `foreground_cwd` is what the pane is actually working in; `cwd`
            // is where the shell started. They differ the moment anyone cds.
            cwd: pane["foreground_cwd"] as? String ?? pane["cwd"] as? String,
            revision: (pane["revision"] as? NSNumber)?.uint64Value ?? 0
        )
    }

    /// One pushed event. Unrecognized types are dropped rather than guessed at.
    static func decodeEvent(_ line: Data) -> HerdrEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let body = (object["result"] ?? object["params"]) as? [String: Any],
            let type = body["type"] as? String
        else { return nil }

        switch type {
        case "pane.updated", "pane.created", "pane.agent_detected", "pane.focused":
            guard let pane = body["pane"] as? [String: Any] ?? paneFrom(body),
                  let decoded = decodePane(pane) else { return nil }
            return .paneUpdated(decoded)

        case "pane.closed", "pane.exited":
            guard let paneId = body["pane_id"] as? String else { return nil }
            return .paneClosed(paneId: paneId)

        case "subscription_started":
            return .connected

        default:
            // Workspace, tab, worktree and layout events change labels, not
            // agent state. Resnapshot rather than patch — reconstructing a
            // rename from an event is how label maps drift out of sync.
            if type.hasPrefix("workspace.") || type.hasPrefix("tab.")
                || type.hasPrefix("worktree.") || type.hasPrefix("pane.moved") {
                return .topologyChanged
            }
            return nil
        }
    }

    /// Some pane events inline the pane's fields instead of nesting them.
    private static func paneFrom(_ body: [String: Any]) -> [String: Any]? {
        body["pane_id"] is String ? body : nil
    }
}
