import AgentHQKit
import Foundation

/// Reads a blocked pane's prompt and reports which keys it *says* will answer
/// it.
///
/// The alternative would be a table keyed by provider — claude answers with
/// enter, cursor with y — and that table is wrong the moment any of them ships
/// a new dialog. herdr's own agent manifests are the evidence: a single agent
/// carries several blocking prompt shapes with different footers, and the
/// footers are the only thing that reliably names the key. So the prompt is
/// taken at its word and nothing is inferred from which agent is running.
///
/// The bar for offering a key is that the prompt printed it. Where it did not,
/// the action is not offered. That is why approve is missing more often than
/// deny: most agent prompts are highlighted-row menus whose footer says
/// "enter to confirm", and enter there takes the highlighted row — which herdr
/// reports nothing about. Pressing it would be a coin flip presented as a
/// button labelled Approve.
public struct PromptAffordances: Sendable {
    /// How far up from the bottom to look.
    ///
    /// The footer that names the keys sits directly under the prompt. herdr's
    /// own rules use `bottom_non_empty_lines(8)` for the same job; this is a
    /// little wider to cover a prompt whose body wraps, and counted in
    /// non-empty lines for the same reason herdr counts them that way — a
    /// boxed dialog is full of blank padding rows.
    public static let footerLines = 14

    public init() {}

    /// What the pane's own text offers.
    public func affordances(inRecentOutput output: String?) -> (approve: String?, deny: String?) {
        guard let output, !output.isEmpty else { return (nil, nil) }
        let footer = Self.footer(of: output)
        return (Self.affirmativeKey(in: footer), Self.negativeKey(in: footer))
    }

    // MARK: - Affirmative

    /// Patterns where the prompt spells out a key that means "go ahead".
    ///
    /// Each one requires the key to appear as a key — parenthesised, bracketed,
    /// or as the subject of "press x" — never as a bare letter in prose. A
    /// stray "y" in a sentence is not an affordance.
    ///
    /// Captured from live agent prompts and from the `contains` clauses of
    /// herdr's agent manifests, which are the same strings herdr matches to
    /// decide a pane is blocked in the first place.
    static let affirmativePatterns: [String] = [
        // `run (once) (y)`, `proceed (y)`, `(y) (enter)`, `add write(` … (y)
        #"\((y(?:es)?)\)"#,
        // `[y/N]`, `(y/n)`, `[Y/n]`
        #"[\[(](y)(?:es)?/n(?:o)?[\])]"#,
        // `allow once (a)` — a distinct key from y, and the prompt names it.
        #"\ballow\b[^\n]{0,20}\((a)\)"#,
        // `press y to continue`
        #"press\s+(y)\b"#,
    ]

    /// Patterns where the prompt spells out a key that means "don't".
    static let negativePatterns: [String] = [
        // The near-universal footer: `esc to cancel`, `esc dismiss`,
        // `esc cancel`, `(esc)`.
        #"\b(esc|escape)\b[^\n]{0,14}\b(?:to\s+)?(?:cancel|dismiss|exit|quit|skip|reject|no)\b"#,
        #"\((esc)\)"#,
        // `skip (esc or n)`, `esc or n or p`
        #"\((esc) or n"#,
        // `keep (n)`, `(n)o`
        #"\((n)o?\)"#,
        #"[\[(]y(?:es)?/(n)(?:o)?[\])]"#,
    ]

    static func affirmativeKey(in footer: [String]) -> String? {
        firstKey(in: footer, matching: affirmativePatterns)
    }

    static func negativeKey(in footer: [String]) -> String? {
        // `esc` wins over `n` when a prompt offers both: the two are equivalent
        // where both appear ("esc or n"), and `esc` is the one that also works
        // on the menu-shaped prompts, so preferring it keeps one key meaning
        // one thing across every prompt AgentHQ will ever press it on.
        if let escape = firstKey(in: footer, matching: Array(negativePatterns.prefix(3))) {
            return escape.lowercased() == "escape" ? "esc" : escape.lowercased()
        }
        return firstKey(in: footer, matching: Array(negativePatterns.dropFirst(3)))?.lowercased()
    }

    /// The first capture group of the first pattern that matches, searching the
    /// bottom line upward.
    ///
    /// Bottom-up because a pane can hold the footers of several prompts that
    /// have already been answered, and the live one is the last.
    static func firstKey(in footer: [String], matching patterns: [String]) -> String? {
        for line in footer.reversed() {
            for pattern in patterns {
                guard let match = line.range(
                    of: pattern, options: [.regularExpression, .caseInsensitive]
                ) else { continue }
                if let key = Self.capture(in: String(line[match]), of: pattern) {
                    return key.lowercased()
                }
            }
        }
        return nil
    }

    /// Pull the captured key out of a matched fragment.
    ///
    /// `NSRegularExpression` rather than `range(of:)`, because the latter
    /// reports where the whole pattern matched and cannot hand back a group —
    /// and the group is the entire point here: the pattern proves the letter is
    /// being offered as a key, and the group says which letter.
    static func capture(in fragment: String, of pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]
        ) else { return nil }
        let range = NSRange(fragment.startIndex..<fragment.endIndex, in: fragment)
        guard let match = regex.firstMatch(in: fragment, range: range) else { return nil }
        for group in 1..<match.numberOfRanges {
            guard let groupRange = Range(match.range(at: group), in: fragment) else { continue }
            let key = String(fragment[groupRange])
            if !key.isEmpty { return key }
        }
        return nil
    }

    // MARK: - Region

    /// The bottom `footerLines` non-empty lines, ANSI stripped and condensed.
    static func footer(of output: String) -> [String] {
        let lines = StateClassifier.strippingANSI(output)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { StateClassifier.condense(String($0)) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(footerLines))
    }
}

// MARK: - Actions

public extension PromptAffordances {
    /// What the panel may offer for one agent.
    ///
    /// Reads the state, not the provider: the two answering actions exist only
    /// while something is actually waiting to be answered. Offering Approve on
    /// a working agent would send a `y` into a running turn.
    func actions(for state: AgentState, recentOutput: String?) -> AgentActions {
        // `canNudge` is false for every blocked state because herdr rejects
        // `agent.prompt` there — measured, not assumed: it answers
        // `agent_blocked: agent is blocked and requires interactive input`.
        switch state {
        case .needsApproval, .needsInput:
            let keys = affordances(inRecentOutput: recentOutput)
            return AgentActions(
                approveKey: keys.approve,
                denyKey: keys.deny,
                canInterrupt: true,
                canNudge: false,
                canReveal: true,
                // Only the open question takes words. An approval prompt's
                // named keys are its answer, and typing at a highlighted-row
                // menu goes into a filter or nowhere.
                canReply: state == .needsInput
            )

        case .working:
            return AgentActions(canInterrupt: true, canNudge: true, canReveal: true)

        case .rateLimited, .ciFailed, .mergeConflict, .finished, .idle, .unknown:
            // Stopped but alive. There is nothing to answer, and a new
            // instruction is the useful thing to send.
            return AgentActions(canInterrupt: true, canNudge: true, canReveal: true)

        case .crashed:
            // The process is gone. Every one of these would be sent into a
            // dead pane, and herdr would accept the request and do nothing.
            return .none
        }
    }
}
