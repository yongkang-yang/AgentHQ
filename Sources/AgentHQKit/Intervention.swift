import Foundation

// MARK: - Intervention

/// Something the user can do to one agent from the panel.
///
/// Deliberately not a general "send these keys" escape hatch. Every case here
/// is one the panel can label truthfully, and a button whose label does not
/// match what the keystroke will do is worse than no button: the user believes
/// they answered a prompt and walks away.
public enum Intervention: Sendable, Equatable {
    /// Answer a blocked agent's prompt in the affirmative, pressing the key
    /// the prompt itself named.
    case approve

    /// Decline it, pressing the key the prompt itself named.
    case deny

    /// Stop whatever the agent is doing, without answering anything.
    case interrupt

    /// Hand the agent a new instruction.
    case nudge(String)
}

// MARK: - AgentActions

/// Which interventions AgentHQ can honestly offer for one agent right now.
///
/// Computed from the agent's state and, for the two answering actions, from
/// the prompt's own words — never from a table of "this provider answers with
/// y". Provider-keyed guesses are wrong across versions and wrong across the
/// several prompt shapes one agent uses.
public struct AgentActions: Sendable, Equatable {
    /// The key that goes ahead, when the prompt spells one out — `y` in
    /// `run (once) (y)`.
    ///
    /// Nil for the far more common shape: a menu of options with
    /// "enter to confirm · esc to cancel", where `enter` takes whichever row
    /// is *highlighted*. herdr reports that such a pane is blocked but not
    /// which row is selected, so an Approve button there would be pressing
    /// enter and hoping. It is left off, and the row offers to open the pane.
    public var approveKey: String?

    /// The key that backs out. Nil unless the prompt names one.
    ///
    /// This is offered more often than approve, and that asymmetry is the
    /// point rather than an accident: nearly every prompt across herdr's agent
    /// manifests carries an "esc to cancel" affordance, and declining is the
    /// direction that cannot do something the user did not ask for.
    public var denyKey: String?

    /// Sending `C-c`. Offered whenever there is a live agent to send it to.
    public var canInterrupt: Bool

    /// Submitting a prompt. False while the agent is blocked, because herdr
    /// refuses it there — `agent.prompt` on a blocked agent comes back
    /// `agent_blocked: requires interactive input`. The button is hidden
    /// rather than shown and then failing.
    public var canNudge: Bool

    public init(
        approveKey: String? = nil,
        denyKey: String? = nil,
        canInterrupt: Bool = false,
        canNudge: Bool = false
    ) {
        self.approveKey = approveKey
        self.denyKey = denyKey
        self.canInterrupt = canInterrupt
        self.canNudge = canNudge
    }

    public static let none = AgentActions()

    public func allows(_ intervention: Intervention) -> Bool {
        switch intervention {
        case .approve:   return approveKey != nil
        case .deny:      return denyKey != nil
        case .interrupt: return canInterrupt
        case .nudge:     return canNudge
        }
    }
}

// MARK: - InterventionError

/// Why an intervention did not happen.
///
/// Every case names something the user can understand from the row they just
/// clicked. There is no generic failure case on purpose: "couldn't do that"
/// in front of an agent holding up work is not a report, it is a shrug.
public enum InterventionError: Error, Sendable, Equatable {
    /// The agent is no longer there — the pane closed, or the agent exited.
    case agentGone

    /// The agent moved on between the panel rendering it and the click
    /// arriving. Nothing was sent.
    ///
    /// This is the case that justifies the guard existing: a prompt answered
    /// blind is a keystroke delivered to whatever replaced it.
    case stateMoved(was: AgentState, isNow: AgentState)

    /// The prompt no longer names the key that was about to be pressed, so it
    /// is a different prompt than the one on screen. Nothing was sent.
    case promptChanged

    /// Not offered for this agent. A caller reaching past ``AgentActions``.
    case notOffered

    /// herdr refused, verbatim.
    case refused(code: String, message: String)
}

public extension InterventionError {
    /// One line, in the panel's voice.
    var summary: String {
        switch self {
        case .agentGone:
            return "That agent is gone."
        case .stateMoved(let was, let isNow):
            return "It moved from \(was.rawValue) to \(isNow.rawValue) first — nothing sent."
        case .promptChanged:
            return "The prompt changed — nothing sent."
        case .notOffered:
            return "Not available for this agent."
        case .refused(let code, let message):
            return message.isEmpty ? "herdr refused: \(code)" : message
        }
    }
}
