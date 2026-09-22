import AgentHQKit
import Foundation
import Testing
@testable import AgentHQHerdr

/// Which key ends a conversation, read out of the pane.
///
/// Unlike the interrupt key, this one has no manifest behind it: herdr's agent
/// manifests carry detection rules, not exit affordances. The footers below
/// come from live panes instead — pi's is verbatim from the user's own herd.
@Suite("the key that ends a conversation")
struct ExitKeyTests {
    private let subject = PromptAffordances()

    /// pi's input footer, verbatim off a live WSL pane.
    ///
    /// The trap that makes the paired parse necessary: `ctrl+c` and `exit`
    /// both appear on this line, and `ctrl+c` is *not* the exit key. Scanning
    /// for them would send `C-c`, which on pi clears the input and exits
    /// nothing — the user would press End and watch it do nothing, forever.
    static let piFooter =
        "escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ! bash · ctrl+o more"

    @Test("parallel key and verb lists are zipped, not scanned")
    func pairsKeysToVerbs() {
        #expect(subject.exitKey(inRecentOutput: Self.piFooter) == "C-d")
    }

    @Test("a directly named exit key is read")
    func readsDirectKey() {
        #expect(subject.exitKey(inRecentOutput: "ctrl+d to exit") == "C-d")
        #expect(subject.exitKey(inRecentOutput: "q to quit") == "q")
        #expect(subject.exitKey(inRecentOutput: "^d to exit") == "C-d")
    }

    /// A mismatched pairing says nothing about which key goes with which verb,
    /// so it must yield nothing rather than a guess at the alignment.
    @Test("an uneven pairing is not guessed at")
    func unevenPairingYieldsNothing() {
        #expect(subject.exitKey(inRecentOutput: "ctrl+a/ctrl+b/ctrl+c one/exit") == nil)
    }

    @Test("a pane that names no exit yields nothing")
    func silenceYieldsNothing() {
        #expect(subject.exitKey(inRecentOutput: "⏵ Working… (esc to interrupt)") == nil)
        #expect(subject.exitKey(inRecentOutput: "enter to confirm · esc to cancel") == nil)
        #expect(subject.exitKey(inRecentOutput: nil) == nil)
    }

    /// The sentence that authorises a second press. Without one, End stops
    /// after the first key rather than pressing again on a hunch.
    @Test("an offer to press again is read as one")
    func readsTheConfirmation() {
        #expect(subject.exitConfirmationKey(
            inRecentOutput: "Press Ctrl-C again to exit") == "C-c")
        #expect(subject.exitConfirmationKey(
            inRecentOutput: "ctrl+c again to quit") == "C-c")
        #expect(subject.exitConfirmationKey(
            inRecentOutput: "esc again to exit") == "esc")
    }

    /// "esc again to cancel" is copilot's manifest string for dismissing a
    /// prompt. Reading it as an exit offer would send a second key into an
    /// agent that only wanted to close a dialog.
    @Test("an offer to press again for something else is not an exit offer")
    func cancelAgainIsNotExit() {
        #expect(subject.exitConfirmationKey(inRecentOutput: "esc again to cancel") == nil)
        #expect(subject.exitConfirmationKey(inRecentOutput: "esc to interrupt") == nil)
        #expect(subject.exitConfirmationKey(inRecentOutput: Self.piFooter) == nil)
    }

    @Test("End is offered for every live agent and withheld from a dead pane")
    func offeredWhileAlive() {
        for state in [AgentState.working, .needsInput, .needsApproval, .idle, .finished] {
            #expect(subject.actions(for: state, recentOutput: nil).canEnd, "\(state)")
        }
        #expect(!subject.actions(for: .crashed, recentOutput: nil).canEnd)
    }
}
