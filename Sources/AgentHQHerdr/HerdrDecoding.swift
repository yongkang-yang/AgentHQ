import Foundation

/// Decoding for herdr 0.9.0 / protocol 22.
///
/// Field names below were read off a live socket, not inferred from an older
/// client. Protocol 22 renamed enough that guessing would quietly produce
/// empty rows: workspaces and tabs carry `label` where 17 had `name`.
///
/// `revision` and `state_change_seq` are *not* two names for one field, which
/// is the easy mistake to make from the rename above. `agent.get` returns both
/// at once with different values, and only `state_change_seq` tracks agent
/// state — see ``HerdrAgentInfo/stateChangeSeq``.
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
        let rawTokens = pane["tokens"] as? [String: Any] ?? [:]
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
            // A metadata value can be null, and a null token means the reporter
            // withdrew it; keeping only strings matches that intent.
            tokens: rawTokens.compactMapValues { $0 as? String },
            revision: (pane["revision"] as? NSNumber)?.uint64Value ?? 0
        )
    }

    /// One agent from `agent.list` or `agent.get`.
    ///
    /// `state_change_seq` is read here and nowhere else, because it exists
    /// nowhere else: neither `session.snapshot`'s pane records nor `pane.get`
    /// carry it. Reading it off a pane yields nil, and a client that treated
    /// that as zero would compare zero against zero and believe every
    /// staleness check passed.
    static func decodeAgentInfo(_ agent: [String: Any]) -> HerdrAgentInfo? {
        guard let paneId = agent["pane_id"] as? String, !paneId.isEmpty else { return nil }
        return HerdrAgentInfo(
            paneId: paneId,
            agent: agent["agent"] as? String ?? "",
            agentStatus: agent["agent_status"] as? String ?? "unknown",
            stateChangeSeq: (agent["state_change_seq"] as? NSNumber)?.uint64Value ?? 0
        )
    }

    /// One pushed event.
    ///
    /// The wire shape is `{"event": "<name>", "data": {...}}` — not the
    /// JSON-RPC `result`/`params` envelope a request reply uses. And the names
    /// are snake_case (`pane_updated`) even though a *subscription* asks for
    /// them dotted (`pane.updated`). Reading the reply envelope, or matching
    /// the dotted name, silently drops every event: the subscription connects,
    /// the panel renders once, and then never changes again.
    static func decodeEvent(_ line: Data) -> HerdrEvent? {
        guard
            let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any]
        else { return nil }

        // A subscription ack arrives on the same connection as the events.
        if let result = object["result"] as? [String: Any],
           result["type"] as? String == "subscription_started" {
            return .connected
        }

        let data = object["data"] as? [String: Any] ?? [:]
        guard let name = object["event"] as? String ?? data["type"] as? String else {
            return nil
        }

        switch name {
        case "pane_updated", "pane_created", "pane_agent_detected":
            // `data.pane` carries the full pane record, identical to the one
            // in a snapshot, so these patch in place instead of forcing a
            // resnapshot per event.
            guard let pane = data["pane"] as? [String: Any],
                  let decoded = decodePane(pane) else { return nil }
            return .paneUpdated(decoded)

        case "pane_closed", "pane_exited":
            guard let paneId = data["pane_id"] as? String
                ?? (data["pane"] as? [String: Any])?["pane_id"] as? String
            else { return nil }
            return .paneClosed(paneId: paneId)

        default:
            // Workspace, tab, worktree and focus events change labels and
            // topology, not agent state, and do not carry a pane. Resnapshot
            // rather than patch — reconstructing a rename from an event is how
            // label maps drift out of sync.
            if name.hasPrefix("workspace_") || name.hasPrefix("tab_")
                || name.hasPrefix("worktree_") || name.hasPrefix("pane_") {
                return .topologyChanged
            }
            return nil
        }
    }

}
