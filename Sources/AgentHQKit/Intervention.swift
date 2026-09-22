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

    /// Hand the agent a new instruction while it is working.
    case nudge(String)

    /// Answer the question a blocked agent is asking, in words.
    ///
    /// Distinct from ``nudge`` and deliberately not sharing a button with it.
    /// Nudge interrupts an agent that is working and travels `agent.prompt`;
    /// reply answers one that is waiting, and cannot travel `agent.prompt` at
    /// all — herdr refuses it on a blocked agent with `agent_blocked`. One
    /// control doing both would send text down a path herdr rejects half the
    /// time.
    case reply(String)

    /// End the conversation: quit the agent, leaving its pane alive.
    ///
    /// The panel's only terminating action. An "interrupt the current turn"
    /// action existed alongside it briefly and was removed: stopping a turn is
    /// something you do while watching the agent, in the agent, and a triage
    /// panel that is not where you are watching from adds a second button
    /// whose difference from this one has to be explained every time.
    ///
    /// The pane and its scrollback survive, which is what keeps Show output
    /// readable afterwards — the alternative, `pane.close`, would take the
    /// record of what the agent did with it.
    ///
    /// There is no single key for this and no manifest names one: herdr's
    /// agent manifests carry detection rules, not exit affordances. So it is
    /// resolved from the pane's own footer, and where the pane says nothing it
    /// stops rather than guessing. See `MachineSession.perform`.
    case end

    /// Bring the agent's pane to the front in its own herdr.
    ///
    /// The only action that sends nothing to the agent, which is why it is the
    /// one that is always truthful. It exists because Approve usually cannot
    /// be: most prompts are highlighted-row menus that name no key, and a
    /// triage panel whose main action is generally missing is not much of a
    /// panel. "Go look at it" always works.
    case reveal
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

    /// Submitting a prompt. False while the agent is blocked, because herdr
    /// refuses it there — `agent.prompt` on a blocked agent comes back
    /// `agent_blocked: requires interactive input`. The button is hidden
    /// rather than shown and then failing.
    public var canNudge: Bool

    /// Focusing the pane. True whenever there is a pane to focus, which is
    /// every live agent — so this is the row's one dependable action.
    public var canReveal: Bool

    /// Quitting the agent. Offered wherever there is a live agent, because
    /// ending a conversation does not depend on what it is currently doing.
    public var canEnd: Bool

    /// Typing an answer. True only for ``AgentState/needsInput``.
    ///
    /// Not offered on `needsApproval`, even though that agent is equally
    /// blocked. An approval prompt is a bounded choice — often a
    /// highlighted-row menu, where typed text goes into a filter or nowhere —
    /// and its named keys *are* the answer. A Reply box there would be a
    /// control that looks like it works and usually does not.
    public var canReply: Bool

    public init(
        approveKey: String? = nil,
        denyKey: String? = nil,
        canEnd: Bool = false,
        canNudge: Bool = false,
        canReveal: Bool = false,
        canReply: Bool = false
    ) {
        self.approveKey = approveKey
        self.denyKey = denyKey
        self.canEnd = canEnd
        self.canNudge = canNudge
        self.canReveal = canReveal
        self.canReply = canReply
    }

    public static let none = AgentActions()

    public func allows(_ intervention: Intervention) -> Bool {
        switch intervention {
        case .approve:   return approveKey != nil
        case .deny:      return denyKey != nil
        case .end:       return canEnd
        case .nudge:     return canNudge
        case .reveal:    return canReveal
        case .reply:     return canReply
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

    /// The row carries no state-change stamp, so whether the agent has moved
    /// cannot be established. Nothing was sent.
    ///
    /// Distinct from ``stateMoved`` because it is a different claim, and the
    /// difference is the one invariant 3 is about: this says *we do not know*,
    /// where `stateMoved` says *it moved*. Reported as the latter, a refusal
    /// here rendered as "it moved from working to working first" — a sentence
    /// that is not true, cannot be acted on, and reads as a broken button.
    case unverifiable

    /// Not offered for this agent. A caller reaching past ``AgentActions``.
    case notOffered

    /// ``Intervention/end`` pressed the key the pane named, and the agent
    /// neither exited nor offered a confirmation to press again.
    ///
    /// **The one case here that reports something was sent.** Every other
    /// refusal promises the opposite, and this one cannot: ending a
    /// conversation is a two-step gesture on most agents, so the first key is
    /// already in the pane by the time we learn the second one was never
    /// offered. Saying "nothing happened" would be false, and saying nothing
    /// would leave the user not knowing whether their agent is half-quit.
    case exitNotConfirmed(sent: String)

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
        case .unverifiable:
            return "Couldn't confirm this agent hasn't moved — nothing sent. Try again."
        case .notOffered:
            return "Not available for this agent."
        case .exitNotConfirmed(let sent):
            return "Sent \(sent), but this agent did not offer to exit — nothing further sent. Open it to finish."
        case .refused(let code, let message):
            return message.isEmpty ? "herdr refused: \(code)" : message
        }
    }
}
