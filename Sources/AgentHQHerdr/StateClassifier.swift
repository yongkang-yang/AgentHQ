import AgentHQKit
import Foundation

/// Turns herdr's raw pane status — plus, later, recent pane output — into the
/// normalized ``AgentState`` the product speaks.
///
/// v1 is deterministic rules only. The states herdr can report directly are
/// mapped here; the rest (`ciFailed`, `mergeConflict`, `rateLimited`, and
/// telling `needsApproval` apart from `needsInput`) need the pane's recent
/// output and land with the output rules.
public struct StateClassifier: Sendable {
    public init() {}

    /// Classify from status alone.
    ///
    /// `blocked` deliberately resolves to `.needsInput`, the weaker of the two
    /// waiting states. Without reading the prompt there is no way to know it is
    /// a bounded approval, and claiming `.needsApproval` would put an
    /// approve/deny pair in front of a question that has neither.
    public func classify(status: String) -> AgentState {
        switch status.lowercased() {
        case "working", "busy":   return .working
        case "blocked":           return .needsInput
        case "done", "finished":  return .finished
        case "exited", "dead":    return .crashed
        case "idle":              return .finished
        default:                  return .unknown
        }
    }

    // TODO(milestone 4): classify(status:recentOutput:) adding the output-driven
    // states. Each rule needs a matching reason string — a state with no reason
    // line is a state the user cannot act on.
}

// MARK: - Mapping panes into agents

public extension HerdrSnapshot {
    /// Project this snapshot into fleet agents for one machine.
    ///
    /// Panes without a detected agent are dropped: herdr tracks every pane,
    /// including plain shells, and a triage panel that lists shells is a
    /// process list — exactly what this product is not.
    func agents(
        on machine: MachineID,
        classifier: StateClassifier = StateClassifier(),
        now: Date = Date()
    ) -> [Agent] {
        panes.compactMap { pane in
            guard !pane.paneId.isEmpty else { return nil }
            guard let provider = pane.agent, !provider.isEmpty else { return nil }

            return Agent(
                ref: AgentRef(machine: machine, agent: AgentID(pane.paneId)),
                provider: provider.lowercased(),
                workspace: workspaceNames[pane.workspaceId] ?? pane.workspaceId,
                directory: pane.cwd ?? "",
                state: classifier.classify(status: pane.agentStatus),
                reason: nil,
                stateEnteredAt: now,
                lastActivityAt: nil
            )
        }
    }
}
