import Foundation

// MARK: - AgentState

/// The normalized, user-facing state of one agent.
///
/// This is the vocabulary the whole product speaks: the menu-bar signal, the
/// row pill, the grouping, and the notification rules all read from it. It is
/// a *projection* computed from herdr's raw status plus recent pane output —
/// never something a view derives for itself.
///
/// v1 classifies deterministically. LLM summarization, if it ever lands, feeds
/// the reason line, not this enum.
public enum AgentState: String, Sendable, Equatable, CaseIterable, Codable {
    /// Actively producing output.
    case working

    /// Stopped on a permission or approval prompt. The agent cannot proceed
    /// until a human answers.
    case needsApproval

    /// Stopped on an open-ended question rather than a bounded prompt.
    case needsInput

    /// A test or CI run reported failure in the pane.
    case ciFailed

    /// A merge or rebase left conflicts in the working tree.
    case mergeConflict

    /// The provider is throttling. Time, not the user, unblocks this one.
    case rateLimited

    /// Run completed; nothing further is expected.
    case finished

    /// Alive and at its prompt, with nothing running.
    ///
    /// Distinct from ``finished``, which herdr also reports separately. An
    /// agent you have been working with sits here between turns; it has not
    /// completed anything. Folding the two together filled the Completed
    /// section with agents that had merely been left open, which is the
    /// opposite of what an attention-first panel is for.
    case idle

    /// The agent process is gone, or its pane died, while work was in flight.
    /// Distinct from an unreachable machine — see ``MachineReachability``.
    case crashed

    /// Alive, but AgentHQ cannot say what it is doing. Shown, never guessed at.
    case unknown
}

// MARK: - Severity

public extension AgentState {
    /// Ordering for worst-state-wins. Higher wins the menu-bar signal.
    ///
    /// `crashed` outranks `needsApproval` because a crash may have lost work,
    /// while an approval prompt waits patiently. That is a judgment call worth
    /// revisiting once there is real usage to argue from.
    var severity: Int {
        switch self {
        case .crashed:       return 80
        case .needsApproval: return 70
        case .needsInput:    return 60
        case .mergeConflict: return 50
        case .ciFailed:      return 40
        case .rateLimited:   return 30
        case .finished:      return 20
        case .working:       return 10
        case .idle:          return 5
        case .unknown:       return 0
        }
    }

    /// Whether this state is waiting on a human.
    ///
    /// `rateLimited` is deliberately included: the user cannot clear it, but
    /// they do need to know the herd has stalled rather than assume progress.
    var needsAttention: Bool {
        switch self {
        case .crashed, .needsApproval, .needsInput,
             .mergeConflict, .ciFailed, .rateLimited:
            return true
        case .working, .finished, .idle, .unknown:
            return false
        }
    }
}

// MARK: - AttentionGroup

/// The three sections of the panel, in display order.
public enum AttentionGroup: Int, Sendable, Equatable, CaseIterable, Codable {
    case needsYou = 0
    case working = 1
    case completed = 2
    /// Alive, nothing to act on.
    ///
    /// Idle used to be filed under Working, on the reasoning that it is
    /// "visible but secondary, and not Completed, which would claim work was
    /// done". Both halves of that are right and the conclusion still put a row
    /// reading IDLE under a heading reading WORKING, which claims something
    /// the row itself denies two lines below.
    case idle = 3

    public var title: String {
        switch self {
        case .needsYou:  return "Needs you"
        case .working:   return "Working"
        case .completed: return "Completed"
        case .idle:      return "Idle"
        }
    }
}

public extension AgentState {
    var group: AttentionGroup {
        switch self {
        case .crashed, .needsApproval, .needsInput,
             .mergeConflict, .ciFailed, .rateLimited:
            return .needsYou
        case .finished:
            return .completed
        case .working:
            return .working
        case .idle:
            return .idle
        case .unknown:
            // Rides along with idle, and is separated from it by the row's own
            // pill — the same split `Brand.color` already makes, where both
            // share one grey for "nothing to act on" and the label carries the
            // difference. Not `needsYou`: promoting every state we failed to
            // classify into the alarm section trains the user to ignore that
            // section, which is the one thing it cannot survive.
            return .idle
        }
    }
}
