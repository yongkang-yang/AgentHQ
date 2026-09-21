import AgentHQKit
import Foundation
import Testing
@testable import AgentHQHerdr

@Suite("state classification")
struct StateClassifierTests {
    private let classifier = StateClassifier()

    private func classify(_ status: String, _ output: String?) -> Classification {
        classifier.classify(status: status, recentOutput: output)
    }

    // MARK: Status alone

    @Test("herdr status maps to a base state")
    func statusOnly() {
        #expect(classify("working", nil).state == .working)
        #expect(classify("done", nil).state == .finished)
        #expect(classify("exited", nil).state == .crashed)
        #expect(classify("something-new", nil).state == .unknown)
    }

    @Test("blocked without output is the weaker waiting state")
    func blockedDefaultsToNeedsInput() {
        // Claiming needsApproval unseen would put an approve/deny pair in
        // front of a question that has neither.
        #expect(classify("blocked", nil).state == .needsInput)
    }

    // MARK: Rate limiting

    @Test("throttling outranks whatever herdr thinks the agent is doing")
    func rateLimitWins() {
        for status in ["working", "blocked", "done"] {
            let result = classify(status, "Error: 429 Too Many Requests\nretry after 30s")
            #expect(result.state == .rateLimited, "status \(status)")
            #expect(result.reason?.isEmpty == false)
        }
    }

    @Test("rate-limit reasons quote the line that matched")
    func rateLimitQuotesEvidence() {
        let result = classify("working", "  usage limit reached — resets at 14:00  ")
        #expect(result.state == .rateLimited)
        #expect(result.reason == "Usage limit reached: usage limit reached — resets at 14:00")
    }

    // MARK: Approval vs input

    @Test("a bounded choice is an approval")
    func approvalPrompts() {
        let prompts = [
            "Do you want to proceed? (y/n)",
            "Allow this command to run? [y/N]",
            "  1. Yes\n  2. No",
            "Approve this edit to src/main.swift?",
            "Press Enter to confirm",
        ]
        for prompt in prompts {
            #expect(classify("blocked", prompt).state == .needsApproval, "\(prompt)")
        }
    }

    @Test("an open question is not an approval")
    func openQuestions() {
        let result = classify("blocked", "Which database should I migrate first?")
        #expect(result.state == .needsInput)
        // With no rule matched, the reason is the agent's own last line rather
        // than an invented summary.
        #expect(result.reason == "Which database should I migrate first?")
    }

    // MARK: Conflicts and failures

    @Test("git's own conflict output is recognized")
    func mergeConflicts() {
        #expect(classify("done", "CONFLICT (content): Merge conflict in README.md").state == .mergeConflict)
        #expect(classify("done", "Automatic merge failed; fix conflicts and then commit the result.").state == .mergeConflict)
        #expect(classify("working", "Unmerged paths:\n  both modified: a.txt").state == .mergeConflict)
    }

    @Test("a failed run is reported over a finished status")
    func failedRunBeatsFinished() {
        // "finished" is misleading when the run finished by failing.
        let result = classify("done", "Tests: 3 failed, 41 passed")
        #expect(result.state == .ciFailed)
        #expect(result.reason?.contains("3 failed") == true)
    }

    @Test("failure rules do not fire on an agent merely discussing failure")
    func noFalsePositivesOnNarration() {
        // The single most likely way this feature becomes a liability.
        let narration = """
        I looked at why the tests failed earlier and the cause was a missing
        fixture. I have fixed it, and the suite is green now. Let me know if
        you want me to also handle the merge conflict you mentioned.
        """
        #expect(classify("done", narration).state == .finished)
        #expect(classify("working", narration).state == .working)
    }

    @Test("only the tail is read, so old output cannot reach in")
    func onlyTheTailCounts() {
        // A conflict resolved 200 lines ago is not the current state.
        let old = "CONFLICT (content): Merge conflict in old.txt\n"
            + String(repeating: "building…\n", count: 100)
            + "Done. All clean."
        #expect(classify("done", old).state == .finished)
    }

    @Test("the newest matching line wins")
    func newestMatchWins() {
        // An agent that hit a limit and then hit a conflict is in the
        // conflict; reading oldest-first would report the stale one.
        let output = "CONFLICT (content): Merge conflict in a.txt\nresolved\nCONFLICT (content): Merge conflict in b.txt"
        #expect(classify("done", output).reason?.contains("b.txt") == true)
    }

    // MARK: Robustness

    @Test("ANSI styling does not defeat the rules")
    func ansiStripped() {
        // An escape sequence inside a word breaks every pattern above.
        let styled = "\u{1B}[31mCONFLICT (content)\u{1B}[0m: Merge conflict in a.txt"
        #expect(classify("done", styled).state == .mergeConflict)
        #expect(classify("done", styled).reason?.contains("\u{1B}") == false)
    }

    @Test("empty output falls back to the status")
    func emptyOutput() {
        #expect(classify("working", "").state == .working)
        #expect(classify("working", "   \n \n").state == .working)
    }

    @Test("a very long reason is truncated")
    func reasonIsBounded() throws {
        // Via the needs-input path, which quotes the agent's last line
        // verbatim and so is the one place an arbitrarily long string can
        // reach a reason.
        let long = "Which of these " + String(repeating: "option ", count: 60) + "do you prefer?"
        let reason = try #require(classify("blocked", long).reason)
        #expect(reason.count <= 120)
        #expect(reason.hasSuffix("…"))
    }

    // MARK: Narration

    @Test("an agent writing about a failure state is not in that state")
    func narrationIsNotEvidence() {
        // Caught on live data: this pane was reported as rateLimited because
        // the agent was describing the classifier's own state names. The pane
        // is a terminal an AI writes prose into; its narration is not a tool
        // emitting an error.
        let live = "⏺ 第 5 步：九态分类器。需要 pane 输出才能分出 needsApproval/needsInput/ciFailed/mergeConflict/rateLimited。"
        #expect(classify("working", live).state == .working)
        #expect(classify("done", live).state == .finished)
    }

    @Test("agent UI furniture marks a line as narration")
    func uiMarkers() {
        for marker in ["⏺", "✳", "✶", "●", "❯"] {
            #expect(StateClassifier.looksLikeNarration("\(marker) hit a rate limit, retrying"))
        }
    }

    @Test("prose length and CJK are treated as narration")
    func proseHeuristics() {
        #expect(StateClassifier.looksLikeNarration(String(repeating: "word ", count: 30)))
        #expect(StateClassifier.looksLikeNarration("我遇到了 rate limit，正在重试"))
        // A terse tool error is not narration.
        #expect(!StateClassifier.looksLikeNarration("Error: 429 Too Many Requests"))
        #expect(!StateClassifier.looksLikeNarration("CONFLICT (content): Merge conflict in a.txt"))
    }

    // MARK: Projection

    @Test("classification reaches the agent rows")
    func projection() {
        let pane = HerdrPane(
            paneId: "w:p1", workspaceId: "w", tabId: "w:t1",
            agentStatus: "blocked", agent: "claude", title: "t",
            cwd: "/tmp", revision: 3
        )
        let snapshot = HerdrSnapshot(
            herdrVersion: "0.9.0", protocolVersion: 22,
            panes: [pane], workspaceNames: ["w": "repo"]
        )
        let agents = snapshot.agents(
            on: MachineID("m"),
            output: ["w:p1": "Do you want to proceed? (y/n)"]
        )
        #expect(agents.count == 1)
        #expect(agents.first?.state == .needsApproval)
        #expect(agents.first?.reason?.contains("Approval") == true)
        #expect(agents.first?.workspace == "repo")
    }
}

@Suite("how far back the classifier looks")
struct ClassifierRegionTests {
    private let classifier = StateClassifier()

    @Test("the window is counted in non-empty lines, not raw ones")
    func blankPaddingDoesNotConsumeTheWindow() {
        // A boxed dialog is mostly blank padding. Counting raw lines would let
        // padding push the real prompt out of the window.
        let padded = "CONFLICT (content): Merge conflict in a.txt"
            + String(repeating: "\n", count: 30)
        #expect(classifier.classify(status: "done", recentOutput: padded).state == .mergeConflict)
    }

    @Test("output well above the window cannot reach in")
    func widthIsBounded() {
        // The failure that actually bit was width: prose further up mentioning
        // a state name was read as that state.
        let old = "Error: 429 Too Many Requests\n"
            + (1...20).map { "line \($0)" }.joined(separator: "\n")
            + "\nDone. All clean."
        #expect(classifier.classify(status: "done", recentOutput: old).state == .finished)
    }

    @Test("the window is no wider than herdr's own widest bounded region")
    func sizedAgainstHerdrsRules() {
        // herdr scopes its rules to bottom_non_empty_lines(n), most commonly 8
        // and at most 20. Ours sits between, and must not drift past 20 without
        // a reason — that is how a classifier starts reading a transcript
        // instead of a state.
        #expect(StateClassifier.tailLines <= 20)
        #expect(StateClassifier.tailLines >= 8)
    }
}
