import AgentHQKit
import Foundation
import Testing
@testable import AgentHQHerdr

/// Every prompt string below is verbatim from herdr's own agent manifests
/// (`~/.local/state/herdr/agent-detection/remote/*.toml`) — the same literals
/// herdr matches to decide a pane is blocked. They are not invented examples.
///
/// This is the highest-stakes file in the project to get wrong: it decides
/// which keystroke a button labelled "Approve" actually sends into a live
/// agent. A wrong answer here is not a rendering bug, it is AgentHQ answering
/// a prompt on the user's behalf with something they did not choose.
@Suite("prompt affordances")
struct PromptAffordancesTests {
    private let subject = PromptAffordances()

    private func keys(_ prompt: String) -> (approve: String?, deny: String?) {
        subject.affordances(inRecentOutput: prompt)
    }

    // MARK: Keys the prompt actually names

    @Test("cursor's run/skip prompt names both keys")
    func cursorRunPrompt() {
        // cursor.toml: contains ["run (once) (y)"] / ["skip (esc or n)"]
        let prompt = """
        waiting for approval
        run this command?
          → run (once) (y)
            skip (esc or n)
        """
        let result = keys(prompt)
        #expect(result.approve == "y")
        #expect(result.deny == "esc")
    }

    @Test("codex's bracketed y/n names both")
    func codexBracketed() {
        // codex.toml: contains ["[y/n]"]
        let result = keys("Allow command execution? [y/n]")
        #expect(result.approve == "y")
        #expect(result.deny == "n")
    }

    @Test("`yes (y)` names the affirmative key")
    func yesParenY() {
        // codex.toml: contains ["yes (y)"]
        #expect(keys("  yes (y)\n  no (n)").approve == "y")
    }

    @Test("`(y) (enter)` names the affirmative key")
    func yParenEnterParen() {
        // cursor.toml: contains ["(y) (enter)"]
        #expect(keys("accept edits (y) (enter)").approve == "y")
    }

    @Test("`keep (n)` names a negative key")
    func keepParenN() {
        // cursor.toml: contains ["keep (n)"]
        #expect(keys("revert changes?\n  keep (n)").deny == "n")
    }

    @Test("`don't trust (esc)` names esc")
    func dontTrustEsc() {
        #expect(keys("trust this workspace?\n  don't trust (esc)").deny == "esc")
    }

    // MARK: The negative cases — the ones that matter most

    @Test("a highlighted-row menu offers no approve key")
    func menuPromptHasNoApproveKey() {
        // codex.toml's other blocked shape: contains ["do you want to"] with
        // ["yes"] or ["❯"]. The footer says enter confirms, but enter takes
        // whichever row is *highlighted*, and herdr reports nothing about
        // which row that is. An Approve button here would be pressing enter
        // and hoping.
        //
        // If this test ever starts failing because someone added `enter` to
        // the affirmative patterns, the panel has begun answering prompts
        // blind. That is the failure this file exists to prevent.
        let prompt = """
        Do you want to allow this command?
          ❯ Yes
            Yes, and don't ask again
            No, tell Claude what to do differently
        enter to confirm · esc to cancel
        """
        let result = keys(prompt)
        #expect(result.approve == nil)
        // Declining is still truthful: esc is named outright.
        #expect(result.deny == "esc")
    }

    @Test("`enter to select` is not an approve key either")
    func enterToSelectIsNotApproval() {
        // Real footers: "enter to select", "enter to submit", "Enter to toggle".
        for footer in ["enter to select", "enter to submit", "Enter to toggle", "enter to set as default"] {
            #expect(keys("pick one\n  ❯ option\n\(footer)").approve == nil, "\(footer)")
        }
    }

    @Test("a bare letter in prose is not an affordance")
    func proseIsNotAKey() {
        // The whole reason the patterns require a key to appear *as* a key.
        let prompt = "I will not proceed until you say yes, and n files remain."
        let result = keys(prompt)
        #expect(result.approve == nil)
        #expect(result.deny == nil)
    }

    @Test("no output means no keys")
    func emptyOutput() {
        #expect(keys("").approve == nil)
        #expect(subject.affordances(inRecentOutput: nil).deny == nil)
    }

    // MARK: Region and precedence

    @Test("only the footer is read, so an answered prompt above does not count")
    func onlyTheFooterCounts() {
        // A pane holds the footers of prompts already answered. The live one
        // is the last.
        let prompt = """
        run (once) (y)
        """ + String(repeating: "\nbuilding…", count: 40) + """

        Do you want to continue?
        enter to confirm · esc to cancel
        """
        #expect(keys(prompt).approve == nil)
    }

    @Test("the newest footer wins when a pane holds several")
    func newestFooterWins() {
        let prompt = """
        keep (n)
        allow this edit? [y/n]
        """
        #expect(keys(prompt).approve == "y")
    }

    @Test("esc is preferred over n when a prompt offers both")
    func escapeWinsOverN() {
        // Keeping one key meaning one thing: esc is the one that also works on
        // menu-shaped prompts, so it is the deny key wherever it is offered.
        #expect(keys("skip (esc or n)").deny == "esc")
    }

    @Test("ANSI styling does not hide a key")
    func ansiStripped() {
        let styled = "\u{1B}[32mrun (once) (y)\u{1B}[0m\n\u{1B}[90mskip (esc or n)\u{1B}[0m"
        let result = keys(styled)
        #expect(result.approve == "y")
        #expect(result.deny == "esc")
    }

    // MARK: Actions by state

    @Test("answering actions exist only while something is waiting")
    func actionsRequireAWaitingState() {
        let prompt = "run (once) (y)\nskip (esc or n)"

        for state in [AgentState.needsApproval, .needsInput] {
            let actions = subject.actions(for: state, recentOutput: prompt)
            #expect(actions.approveKey == "y", "\(state)")
            #expect(actions.denyKey == "esc", "\(state)")
            // herdr refuses agent.prompt on a blocked agent outright, so the
            // button is hidden rather than shown and then failing.
            #expect(!actions.canNudge, "\(state)")
            #expect(actions.canInterrupt, "\(state)")
        }

        // Offering Approve on a working agent would send a `y` into a running
        // turn, even though the same text is sitting in its scrollback.
        for state in [AgentState.working, .finished, .rateLimited, .ciFailed, .mergeConflict, .unknown] {
            let actions = subject.actions(for: state, recentOutput: prompt)
            #expect(actions.approveKey == nil, "\(state)")
            #expect(actions.denyKey == nil, "\(state)")
            #expect(actions.canNudge, "\(state)")
        }
    }

    @Test("a crashed agent is offered nothing")
    func crashedOffersNothing() {
        // herdr accepts a send into a dead pane and does nothing with it, so
        // every one of these would be a button that silently does not work.
        let actions = subject.actions(for: .crashed, recentOutput: "run (once) (y)")
        #expect(actions == .none)
        for intervention in [Intervention.approve, .deny, .interrupt, .nudge("go on")] {
            #expect(!actions.allows(intervention), "\(intervention)")
        }
    }

    @Test("allows() agrees with the keys that were found")
    func allowsMatchesKeys() {
        let menu = subject.actions(
            for: .needsApproval,
            recentOutput: "Do you want to continue?\nenter to confirm · esc to cancel"
        )
        #expect(!menu.allows(.approve))
        #expect(menu.allows(.deny))
        #expect(menu.allows(.interrupt))
        #expect(!menu.allows(.nudge("x")))
    }
}
