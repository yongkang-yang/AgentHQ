import AgentHQKit
import Foundation

/// The result of classifying one agent.
public struct Classification: Sendable, Equatable {
    public let state: AgentState
    /// One short line saying why, quoting the evidence where there is any.
    /// Nil when the state came from herdr's status alone and there is nothing
    /// honest to add.
    public let reason: String?

    public init(state: AgentState, reason: String? = nil) {
        self.state = state
        self.reason = reason
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
    /// How much of the tail to consider. Enough to cover a multi-line prompt
    /// or a test summary, short enough that older output cannot reach in.
    public static let tailLines = 40

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
        case "idle":             return .finished
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
        let cleaned = strippingANSI(output)
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return Array(lines.suffix(tailLines))
    }

    /// The last line with something in it, used as a reason when an agent is
    /// waiting but the prompt matched no rule — better a verbatim quote than
    /// an invented summary.
    static func lastMeaningfulLine(_ lines: [String]) -> String? {
        for line in lines.reversed() {
            let condensed = condense(line)
            // Box drawing and prompt furniture carry no information.
            guard condensed.count > 3,
                  condensed.contains(where: { $0.isLetter || $0.isNumber })
            else { continue }
            return condensed
        }
        return nil
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
    func agents(
        on machine: MachineID,
        classifier: StateClassifier = StateClassifier(),
        output: [String: String] = [:],
        now: Date = Date()
    ) -> [Agent] {
        panes.compactMap { pane in
            guard !pane.paneId.isEmpty else { return nil }
            guard let provider = pane.agent, !provider.isEmpty else { return nil }

            let classification = classifier.classify(
                status: pane.agentStatus,
                recentOutput: output[pane.paneId]
            )

            return Agent(
                ref: AgentRef(machine: machine, agent: AgentID(pane.paneId)),
                provider: provider.lowercased(),
                workspace: workspaceNames[pane.workspaceId] ?? pane.workspaceId,
                directory: pane.cwd ?? "",
                state: classification.state,
                reason: classification.reason,
                stateEnteredAt: now,
                lastActivityAt: nil
            )
        }
    }
}
