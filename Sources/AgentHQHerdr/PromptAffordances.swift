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

    /// The key a pane says will *exit* the agent, or nil where it says
    /// nothing.
    ///
    /// Two shapes, both taken from live panes:
    ///
    /// - Paired: `ctrl+c/ctrl+d clear/exit` — pi's input footer, read off the
    ///   user's own herd. The keys and the verbs are two parallel lists, and
    ///   they have to be zipped rather than scanned. Scanning would find
    ///   "ctrl+c" and "exit" on one line and send `C-c`, which on pi clears
    ///   the input and exits nothing.
    /// - Direct: `ctrl+d to exit`, `q to quit`, `press ctrl-c again to exit`.
    ///
    /// Returns herdr's own key spelling, not the agent's.
    public func exitKey(inRecentOutput output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        let footer = Self.footer(of: output)
        return Self.pairedExitKey(in: footer) ?? Self.directExitKey(in: footer)
    }

    /// The key a pane is asking to have pressed *again* in order to exit,
    /// after a first press has already landed — Claude Code's
    /// "Press Ctrl-C again to exit".
    ///
    /// Separate from ``exitKey(inRecentOutput:)`` because it means something
    /// different: not "this key exits" but "you are one press away". It is
    /// only ever read from a pane re-read after a key was sent, which is what
    /// makes acting on it honest rather than a guess about a second press.
    public func exitConfirmationKey(inRecentOutput output: String?) -> String? {
        guard let output, !output.isEmpty else { return nil }
        for line in Self.footer(of: output).reversed() {
            guard let match = line.range(
                of: Self.exitConfirmationPattern,
                options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            guard let key = Self.capture(in: String(line[match]), of: Self.exitConfirmationPattern)
            else { continue }
            return Self.herdrKeyName(key)
        }
        return nil
    }

    /// `press ctrl-c again to exit`, `ctrl+c again to quit`, `esc again to exit`.
    static let exitConfirmationPattern =
        #"(?:press\s+)?(ctrl[+-]\w|\^\w|c-\w|esc|escape|q)\s+again\s+(?:to\s+)?(?:exit|quit)\b"#

    /// `ctrl+c/ctrl+d clear/exit` — parallel key and verb lists.
    static func pairedExitKey(in footer: [String]) -> String? {
        let pattern = #"((?:ctrl[+-]\w|\^\w|c-\w|esc|q)(?:/(?:ctrl[+-]\w|\^\w|c-\w|esc|q))+)\s+(\w+(?:/\w+)+)"#
        for line in footer.reversed() {
            guard let match = line.range(
                of: pattern, options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            let fragment = String(line[match])
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let hit = regex.firstMatch(
                      in: fragment,
                      range: NSRange(fragment.startIndex..<fragment.endIndex, in: fragment)
                  ),
                  let keysRange = Range(hit.range(at: 1), in: fragment),
                  let verbsRange = Range(hit.range(at: 2), in: fragment)
            else { continue }

            let keys = fragment[keysRange].split(separator: "/").map(String.init)
            let verbs = fragment[verbsRange].split(separator: "/").map { $0.lowercased() }
            // Only a same-length pairing carries meaning. `a/b/c x/y` says
            // nothing about which key goes with which verb.
            guard keys.count == verbs.count else { continue }
            for (key, verb) in zip(keys, verbs) where verb == "exit" || verb == "quit" {
                return herdrKeyName(key)
            }
        }
        return nil
    }

    /// `ctrl+d to exit`, `q to quit`.
    static func directExitKey(in footer: [String]) -> String? {
        let pattern = #"(\bctrl[+-]\w|\^\w|\bc-\w|\besc|\bescape|\bq)\b\s+(?:to\s+)?(?:exit|quit)\b"#
        for line in footer.reversed() {
            guard let match = line.range(
                of: pattern, options: [.regularExpression, .caseInsensitive]
            ) else { continue }
            if let key = capture(in: String(line[match]), of: pattern) {
                return herdrKeyName(key)
            }
        }
        return nil
    }

    /// Translate what an agent printed into what `pane.send_keys` accepts.
    ///
    /// `ctrl+d`, `^d` and `c-d` are three spellings of one key and herdr takes
    /// exactly one of them. `C-c` is the proven case — it is what Decline and
    /// Stop already send — and the rest follow its shape. A miss here is
    /// visible and harmless: herdr answers `invalid_key`, `MachineSession`
    /// turns that into a refusal the row prints, and nothing reaches the pane.
    static func herdrKeyName(_ key: String) -> String {
        let lower = key.lowercased()
        if lower == "escape" || lower == "esc" { return "esc" }
        if lower == "q" { return "q" }
        if let letter = lower.split(whereSeparator: { "+-^".contains($0) }).last,
           letter.count == 1, lower != letter {
            return "C-\(letter)"
        }
        if lower.hasPrefix("^"), lower.count == 2 {
            return "C-\(lower.dropFirst())"
        }
        return lower
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
    /// What End presses first when the pane named no exit key of its own.
    ///
    /// Not a guess in the sense invariant 11 forbids: `C-c` is the terminal's
    /// own interrupt, delivered as a signal to the foreground process group —
    /// verified against herdr 0.9.1, where it produced `^C` in a pane running
    /// `sleep 300` and returned the shell prompt. It is the opening of a
    /// two-step gesture, and nothing follows it unless the pane asks.
    static let defaultInterruptKey = "C-c"

    /// What the panel may offer for one agent.
    ///
    /// Reads the state, not the provider: the two answering actions exist only
    /// while something is actually waiting to be answered. Offering Approve on
    /// a working agent would send a `y` into a running turn.
    func actions(for state: AgentState, recentOutput: String?) -> AgentActions {
        switch state {
        case .needsApproval, .needsInput:
            let keys = affordances(inRecentOutput: recentOutput)
            return AgentActions(
                approveKey: keys.approve,
                denyKey: keys.deny,
                canEnd: true,
                canReveal: true
            )

        case .working, .rateLimited, .ciFailed, .mergeConflict, .finished, .idle, .unknown:
            // Alive, with nothing to answer. Words for it go through the
            // console, where the user can see what they are answering.
            return AgentActions(canEnd: true, canReveal: true)

        case .crashed:
            // The process is gone. Every one of these would be sent into a
            // dead pane, and herdr would accept the request and do nothing.
            return .none
        }
    }
}
