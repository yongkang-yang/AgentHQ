import AgentHQKit
import Foundation

/// The result of classifying one agent.
public struct Classification: Sendable, Equatable {
    public let state: AgentState
    /// One short line saying why, quoting the evidence where there is any.
    /// Nil when the state came from herdr's status alone and there is nothing
    /// honest to add.
    public let reason: String?
    /// The lines a row can show when the reason is too short to act on. Nil
    /// when there is nothing worth showing.
    public let message: String?

    public init(state: AgentState, reason: String? = nil, message: String? = nil) {
        self.state = state
        self.reason = reason
        self.message = message
    }
}

/// Turns herdr's raw pane status, plus the tail of the pane's recent output,
/// into the normalized ``AgentState`` the product speaks.
///
/// Deterministic rules only. Two things keep this from becoming a source of
/// confident nonsense:
///
/// - **Only the tail is read.** Matching anywhere in the scrollback means an
///   agent that merely *discusses* a merge conflict gets reported as having
///   one. Rules look at the last few lines, which is where a prompt or a
///   failure actually sits when the agent has stopped.
/// - **Every rule carries its evidence.** A state with no reason the user can
///   check is a state they cannot act on, so each match quotes the line that
///   produced it.
public struct StateClassifier: Sendable {
    /// How much of the tail to consider, counted in **non-empty** lines.
    ///
    /// Sized against herdr's own rules, which scope to
    /// `bottom_non_empty_lines(n)` with 8 the most common and 20 the widest.
    /// This sat at 40 *raw* lines, which is both wider than any of them and
    /// inconsistent with `PromptAffordances`, which already counted 14
    /// non-empty. Raw lines are the wrong unit: a boxed dialog is mostly blank
    /// padding, so 40 raw lines can be a handful of real ones — or, in a dense
    /// transcript, far more context than the agent's current state occupies.
    ///
    /// Width is the failure mode that actually bit: the classifier reported a
    /// pane as rate limited because prose further up mentioned the word.
    /// Narrower is the fix, and it costs only the ability to see a test
    /// summary that has already scrolled well past.
    public static let tailLines = 12

    public init() {}

    // MARK: - Status only

    /// Classify from herdr's status, with no output available.
    ///
    /// `blocked` resolves to `.needsInput`, the weaker of the two waiting
    /// states: without reading the prompt there is no way to know it is a
    /// bounded approval, and claiming `.needsApproval` would put an
    /// approve/deny pair in front of a question that has neither.
    public func classify(status: String) -> Classification {
        Classification(state: Self.baseState(for: status))
    }

    static func baseState(for status: String) -> AgentState {
        switch status.lowercased() {
        case "working", "busy":  return .working
        case "blocked":          return .needsInput
        case "done", "finished": return .finished
        case "exited", "dead":   return .crashed
        // herdr reports `idle` and `done` separately and they mean different
        // things: idle is an agent sitting at its prompt between turns, done
        // is a run that completed.
        case "idle":             return .idle
        default:                 return .unknown
        }
    }

    // MARK: - Status plus output

    /// Classify using the tail of the pane's recent output.
    ///
    /// Precedence, most specific first:
    ///
    /// 1. **Rate limiting** wins outright. It explains the stall regardless of
    ///    what herdr thinks the agent is doing, and it is the one attention
    ///    state the user cannot clear by acting.
    /// 2. **A blocked agent** is waiting on a human, so the only question is
    ///    which kind of waiting — a bounded approval or an open question.
    /// 3. **Otherwise** a merge conflict or a failed test run is reported over
    ///    the status-derived state, because "finished" is misleading when the
    ///    run finished by failing.
    public func classify(status: String, recentOutput: String?) -> Classification {
        let result = coreClassify(status: status, recentOutput: recentOutput)
        // Only the states that want a human carry a message: storing one on
        // every working agent would be transcript for nobody to read.
        guard Self.messageStates.contains(result.state),
              let output = recentOutput, !output.isEmpty
        else { return result }
        return Classification(
            state: result.state,
            reason: result.reason,
            message: Self.excerpt(Self.tail(of: output))
        )
    }

    /// The states whose row can carry more than its one-line reason.
    static let messageStates: Set<AgentState> = [
        .needsApproval, .needsInput, .mergeConflict, .ciFailed, .rateLimited,
    ]

    private func coreClassify(status: String, recentOutput: String?) -> Classification {
        let base = Self.baseState(for: status)
        guard let output = recentOutput, !output.isEmpty else {
            return Classification(state: base)
        }
        let tail = Self.tail(of: output)

        if let hit = Self.firstMatch(in: tail, among: Self.rateLimitRules) {
            return Classification(state: .rateLimited, reason: hit.reason)
        }

        if base == .needsInput {
            if let hit = Self.firstMatch(in: tail, among: Self.approvalRules) {
                return Classification(state: .needsApproval, reason: hit.reason)
            }
            // A prompt that names a way to say yes *is* an approval, whatever
            // words it used to ask. Without this the two halves disagree:
            // cursor's `run (once) (y)` hands PromptAffordances an approve key
            // while matching none of the rules above, and the row renders as
            // "needs input" with an Approve button on it. Caught by driving a
            // real blocked agent rather than by reasoning about the rules.
            if PromptAffordances().affordances(inRecentOutput: output).approve != nil {
                return Classification(state: .needsApproval, reason: Self.lastMeaningfulLine(tail))
            }
            return Classification(state: .needsInput, reason: Self.lastMeaningfulLine(tail))
        }

        if let hit = Self.firstMatch(in: tail, among: Self.conflictRules) {
            return Classification(state: .mergeConflict, reason: hit.reason)
        }
        if let hit = Self.firstMatch(in: tail, among: Self.failureRules) {
            return Classification(state: .ciFailed, reason: hit.reason)
        }
        return Classification(state: base)
    }

    // MARK: - Rules

    struct Rule: Sendable {
        let pattern: String
        let label: String
    }

    struct Hit: Sendable, Equatable {
        let line: String
        let label: String
        var reason: String { "\(label): \(line)" }
    }

    /// Throttling. Deliberately narrow — these phrases are near-unambiguous,
    /// and a false rate-limit tells the user to wait when they should act.
    static let rateLimitRules: [Rule] = [
        Rule(pattern: #"rate[ -]?limit"#, label: "Rate limited"),
        Rule(pattern: #"\b429\b"#, label: "Rate limited"),
        Rule(pattern: #"too many requests"#, label: "Rate limited"),
        Rule(pattern: #"quota (exceeded|exhausted)"#, label: "Quota exhausted"),
        Rule(pattern: #"usage limit reached"#, label: "Usage limit reached"),
        Rule(pattern: #"retry after \d"#, label: "Rate limited"),
    ]

    /// A bounded choice: the agent is offering options, not asking a question.
    static let approvalRules: [Rule] = [
        Rule(pattern: #"\(y(es)?/n(o)?\)"#, label: "Approval"),
        Rule(pattern: #"\[y/N\]|\[Y/n\]"#, label: "Approval"),
        Rule(pattern: #"do you want to (proceed|continue|allow)"#, label: "Approval"),
        Rule(pattern: #"^\s*\d+\.\s+(yes|no|allow|deny)\b"#, label: "Approval"),
        Rule(pattern: #"(allow|approve|permit) this (command|tool|action|edit)"#, label: "Approval"),
        Rule(pattern: #"press (enter|y) to (confirm|continue)"#, label: "Approval"),
    ]

    /// Conflicts. These strings come from git itself, which is why they can be
    /// matched with confidence.
    static let conflictRules: [Rule] = [
        Rule(pattern: #"^CONFLICT \("#, label: "Merge conflict"),
        Rule(pattern: #"automatic merge failed"#, label: "Merge conflict"),
        Rule(pattern: #"fix conflicts and then commit"#, label: "Merge conflict"),
        Rule(pattern: #"^Unmerged paths:"#, label: "Merge conflict"),
        Rule(pattern: #"you have unmerged files"#, label: "Merge conflict"),
    ]

    /// Failed runs. Anchored to summary lines that test runners print, never
    /// to a bare "failed" — an agent narrating a failure is not a failure.
    static let failureRules: [Rule] = [
        Rule(pattern: #"^\s*\d+ (test|spec)s? failed"#, label: "Tests failed"),
        Rule(pattern: #"^(FAIL|FAILED)\b"#, label: "Tests failed"),
        Rule(pattern: #"tests? failed[.:]?\s*$"#, label: "Tests failed"),
        Rule(pattern: #"^\s*Tests:.*\bfailed\b"#, label: "Tests failed"),
        Rule(pattern: #"process completed with exit code [1-9]"#, label: "CI failed"),
        Rule(pattern: #"^npm ERR!"#, label: "Build failed"),
        Rule(pattern: #"^error: build failed"#, label: "Build failed"),
    ]

    // MARK: - Matching

    static func firstMatch(in lines: [String], among rules: [Rule]) -> Hit? {
        // Newest first: when an agent retried and succeeded, the latest line
        // is the one that describes where it actually stands.
        for line in lines.reversed() {
            let condensed = condense(line)
            // The pane is a terminal an AI writes prose into. An agent
            // explaining that it hit a rate limit, or naming the states this
            // very classifier reports, is not a tool emitting an error — and
            // matching its narration tells the user to wait when they should
            // act. Caught live: a pane discussing "rateLimited" was reported
            // as rate limited.
            guard !looksLikeNarration(condensed) else { continue }
            for rule in rules {
                if condensed.range(of: rule.pattern, options: [.regularExpression, .caseInsensitive]) != nil {
                    return Hit(line: condensed, label: rule.label)
                }
            }
        }
        return nil
    }

    /// Whether a line reads as an agent talking rather than a tool reporting.
    ///
    /// A heuristic, and openly one. It cannot be exact: the pane carries both
    /// kinds of text in the same stream with no marker separating them. It is
    /// tuned to miss real errors rather than to invent them — a missed merge
    /// conflict shows up as a finished run the user can still inspect, while a
    /// fabricated one sends them to fix nothing.
    static func looksLikeNarration(_ line: String) -> Bool {
        // Agent UI furniture: status bullets and spinners that only ever
        // prefix the agent's own messages.
        for marker in ["⏺", "✳", "✶", "✻", "●", "◑", "❯"] where line.contains(marker) {
            return true
        }
        // Tool errors are terse. Prose is not.
        if line.count > 100 { return true }
        // CJK text in this stream is the agent writing, never a CLI's error.
        if line.contains(where: { $0.unicodeScalars.contains { (0x3000...0x9FFF).contains($0.value) } }) {
            return true
        }
        return false
    }

    static func tail(of output: String) -> [String] {
        let lines = strippingANSI(output)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { condense(String($0)) }
            .filter { !$0.isEmpty }
        return Array(lines.suffix(tailLines))
    }

    /// What to quote when an agent is waiting but no rule matched.
    ///
    /// Prefers the last line that reads as a question, and only then the last
    /// line with anything in it. The bare last line is almost always wrong
    /// here: what sits directly above a terminal's input box is prompt
    /// furniture — a hint, a key legend, a parenthetical — while the question
    /// the user has to answer is a line or two further up. A row that quotes
    /// the furniture instead of the question tells them nothing.
    ///
    /// Verbatim either way. A summary of a question is a worse question.
    static func lastMeaningfulLine(_ lines: [String]) -> String? {
        let meaningful = lines
            .map(condense)
            .filter { $0.count > 3 && $0.contains(where: { $0.isLetter || $0.isNumber }) }

        if let question = meaningful.last(where: Self.readsAsAQuestion) {
            return question
        }
        return meaningful.last
    }

    static func readsAsAQuestion(_ line: String) -> Bool {
        // Both marks: agents are asked to work in whatever language the user
        // writes in, and answer in it too.
        guard let last = line.last else { return false }
        return last == "?" || last == "？"
    }

    /// How many lines of a prompt a row shows.
    ///
    /// A highlighted-row menu is a handful of lines and a footer, so six is
    /// enough to see the choices and the key that takes one. It is a cap, not a
    /// summary: every line is verbatim.
    static let excerptLines = 6

    /// The tail a row can actually show.
    ///
    /// Drops the prompt furniture that carries no letters or digits — box
    /// borders, separators, a lone cursor — so six lines are six lines of
    /// substance. Nil when nothing survives.
    static func excerpt(_ lines: [String]) -> String? {
        let meaningful = lines
            .map(condense)
            .filter { $0.count > 3 && $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !meaningful.isEmpty else { return nil }
        return meaningful.suffix(excerptLines).joined(separator: "\n")
    }

    static func condense(_ line: String) -> String {
        let collapsed = line
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.count > 120 ? String(collapsed.prefix(117)) + "…" : collapsed
    }

    /// Strip CSI/OSC escapes. `pane.read` returns `format: "text"`, but the
    /// `visible` source can still carry styling, and an escape sequence in the
    /// middle of a word defeats every rule above.
    static func strippingANSI(_ text: String) -> String {
        text
            // `\x1B`, not `\u{1B}`: inside a raw string the latter reaches the
            // regex engine as literal characters, which ICU does not read as
            // an escape — so the pattern silently matches nothing.
            .replacingOccurrences(of: #"\x1B\[[0-9;?]*[ -/]*[@-~]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\x1B\][^\x07\x1B]*(\x07|\x1B\\)"#, with: "", options: .regularExpression)
    }
}

// MARK: - Mapping panes into agents

public extension HerdrSnapshot {
    /// Project this snapshot into fleet agents for one machine.
    ///
    /// Panes without a detected agent are dropped: herdr tracks every pane,
    /// including plain shells, and a triage panel that lists shells is a
    /// process list — exactly what this product is not.
    ///
    /// **The status comes from the agent view, not the pane.** herdr has two
    /// status enums and they are not the same set: `AgentStatus`, on
    /// `agent.get` / `agent.list`, is `idle | working | blocked | done |
    /// unknown`, while `PaneAgentState`, on a pane record, drops `done`. So a
    /// finished run read off a pane arrives as `idle` — not as an error, not
    /// as a missing field, but as a different valid state. Classified from the
    /// pane alone, `.finished` was unreachable on every machine: an agent went
    /// working, then idle, and the Completed section stayed empty forever.
    ///
    /// This is invariant 7 again in a form that field names do not reveal.
    /// The field is spelled `agent_status` in both places and decodes fine in
    /// both; only the value set differs.
    /// - Parameter agentViews: what `agent.get` / `agent.list` said about each
    ///   pane, keyed by pane id. **The status is read from here in preference
    ///   to the pane's own**, and a pane with no entry falls back to its own.
    func agents(
        on machine: MachineID,
        classifier: StateClassifier = StateClassifier(),
        output: [String: String] = [:],
        agentViews: [String: HerdrAgentInfo] = [:],
        now: Date = Date()
    ) -> [Agent] {
        let affordances = PromptAffordances()
        return panes.compactMap { pane in
            guard !pane.paneId.isEmpty else { return nil }
            guard let provider = pane.agent, !provider.isEmpty else { return nil }

            let recent = output[pane.paneId]
            let view = agentViews[pane.paneId]
            let classification = classifier.classify(
                status: view?.agentStatus ?? pane.agentStatus,
                recentOutput: recent
            )

            return Agent(
                ref: AgentRef(machine: machine, agent: AgentID(pane.paneId)),
                provider: provider.lowercased(),
                model: pane.model ?? "",
                workspace: workspaceNames[pane.workspaceId] ?? pane.workspaceId,
                directory: pane.cwd ?? "",
                state: classification.state,
                reason: classification.reason,
                message: classification.message,
                stateEnteredAt: now,
                lastActivityAt: nil,
                // Derived from the same output the state came from, so the
                // buttons on a row and the pill on it can never disagree about
                // which prompt they are describing.
                actions: affordances.actions(for: classification.state, recentOutput: recent),
                stateSeq: view?.stateChangeSeq
            )
        }
    }
}
