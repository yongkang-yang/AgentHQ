import AgentHQKit
import Foundation
import Testing
@testable import AgentHQHerdr

@Suite("the prompt a waiting agent pins")
struct PromptBlockTests {
    /// A Claude Code AskUserQuestion menu, read off a real pane with
    /// `pane.read` (Claude Code 2.1, herdr 0.9.1). Rules shortened; the one
    /// *inside* the menu, above "Chat about this", is the agent's own.
    static let question = """
     ▐▛███▛█   Claude Code v2.1.282
    ▝▜██████▀  Haiku 4.5 · Claude Pro
     ▝▝   ▝▝   ~/scratch


    ❯ Test only. Call the AskUserQuestion tool exactly once asking: Which database should I migrate first?
      nothing else.
    ────────────────────────────────────────
     ☐ Database

    Which database should I migrate first?

    ❯ 1. Postgres (orders)
         Migrate the orders database from Postgres
      2. MySQL (legacy users)
         Migrate the legacy users database from MySQL
      3. Skip for now
         Defer database migration to a later time
      4. Type something.
    ────────────────────────────────────────
      5. Chat about this

    Enter to select · ↑/↓ to navigate · Esc to cancel

    """

    @Test("a menu longer than the row's excerpt is pinned whole, question first")
    func wholeMenu() throws {
        let prompt = try #require(StateClassifier.prompt(in: Self.question))
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        #expect(lines.first?.trimmingCharacters(in: .whitespaces) == "☐ Database")
        #expect(lines.contains("Which database should I migrate first?"))
        #expect(lines.contains("❯ 1. Postgres (orders)"), "the highlighted row keeps its marker")
        #expect(lines.contains("  5. Chat about this"))
        #expect(lines.last == "Enter to select · ↑/↓ to navigate · Esc to cancel")
    }

    @Test("the rule inside a menu does not cut it down to its last option")
    func innerRule() throws {
        let prompt = try #require(StateClassifier.prompt(in: Self.question))
        #expect(prompt.contains("2. MySQL (legacy users)"))
        #expect(!prompt.contains("────"), "rules become blank lines, not wrapped dashes")
    }

    @Test("the user's echoed message above the menu is not part of the prompt")
    func echoExcluded() throws {
        let prompt = try #require(StateClassifier.prompt(in: Self.question))
        #expect(!prompt.contains("Test only"))
    }

    @Test("the marker follows the highlight when ↓ moves it")
    func markerMoves() throws {
        let moved = Self.question
            .replacingOccurrences(of: "❯ 1. Postgres", with: "  1. Postgres")
            .replacingOccurrences(of: "  2. MySQL", with: "❯ 2. MySQL")
        let prompt = try #require(StateClassifier.prompt(in: moved))
        #expect(prompt.contains("❯ 2. MySQL (legacy users)"))
        #expect(prompt.contains("  1. Postgres (orders)"))
    }

    @Test("a prompt with no rule above its question is shown whole, not guessed at")
    func noRule() throws {
        let output = "some earlier output\nDo you want to continue?\n  ❯ Yes\n    No\nenter to confirm · esc to cancel"
        let prompt = try #require(StateClassifier.prompt(in: output))
        #expect(prompt.hasPrefix("some earlier output"))
        #expect(prompt.hasSuffix("enter to confirm · esc to cancel"))
    }

    @Test("only a waiting agent carries a prompt; the row's excerpt stays capped")
    func onlyWhenWaiting() {
        let classifier = StateClassifier()
        let blocked = classifier.classify(status: "blocked", recentOutput: Self.question)
        #expect(blocked.prompt?.contains("1. Postgres (orders)") == true)
        let excerpt = blocked.message?.split(separator: "\n") ?? []
        #expect(excerpt.count <= StateClassifier.excerptLines)

        #expect(classifier.classify(status: "working", recentOutput: Self.question).prompt == nil)
        #expect(classifier.classify(status: "done", recentOutput: Self.question).prompt == nil)
    }

    @Test("a pane with nothing on it has no prompt")
    func empty() {
        #expect(StateClassifier.prompt(in: "\n\n   \n") == nil)
    }
}
