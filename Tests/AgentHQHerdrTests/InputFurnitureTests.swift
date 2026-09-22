import Testing
@testable import AgentHQHerdr

/// The bottom of an agent's pane is its input box, not the end of what it
/// said. Every sample here is real output captured from a live herd.
@Suite("The excerpt ends on the agent's last words, not its status bar")
struct InputFurnitureTests {
    /// A pi pane, finished. Three of the last six meaningful lines were
    /// furniture, and the final one read "MCP: 4 servers enabled".
    private let piFinished = """
     research
     Took 0.1s
     已切换到 research profile。default 的凭据已保存。
     ──────────────────────────────────────────────────────────
     ──────────────────────────────────────────────────────────
     ~/github-repo/ob-research-altas (main)
     ↑394k ↓5.2k R1.1M CH99.0% $0.108 (sub) 25.3%/272k (auto)
     🔌 MCP: 4 servers enabled
    """

    @Test("the status bar and prompt line are dropped")
    func dropsFurniture() {
        let tail = StateClassifier.tail(of: piFinished)
        #expect(tail.last == "已切换到 research profile。default 的凭据已保存。")
        #expect(!tail.contains { $0.contains("MCP: 4 servers") })
        #expect(!tail.contains { $0.contains("github-repo") })
    }

    /// The answer itself can be a table drawn from the same characters. Only
    /// the *last* rule is furniture; one further up is content.
    @Test("a table inside the answer survives")
    func keepsTables() {
        let withTable = """
         ┌──────────┬─────────────────────┐
         │ Profile  │ Reset 时间（UTC+8） │
         └──────────┴─────────────────────┘
         已恢复到 default profile。
         Resumed session
         ──────────────────────────────────────────
         ──────────────────────────────────────────
         ~/github-repo/ob-research-altas (main)
         ↑324k ↓5.1k R1.1M CH99.3% $0.093 (sub)
         🔌 MCP: 4 servers enabled
        """
        let tail = StateClassifier.tail(of: withTable)
        #expect(tail.last == "Resumed session")
        #expect(tail.contains { $0.contains("Reset 时间") })
        #expect(tail.contains { $0.contains("└") })
    }

    /// Trimming has to fail towards showing too much. A rule with a long tail
    /// under it is a transcript, not a footer.
    @Test("a rule with real content under it is left alone")
    func leavesContentAlone() {
        let manyBelow = """
         ─────────────────────────────────
         one line of the answer
         two lines of the answer
         three lines of the answer
         four lines of the answer
         five lines of the answer
        """
        let tail = StateClassifier.tail(of: manyBelow)
        #expect(tail.last == "five lines of the answer")
        #expect(tail.count == 6, "nothing should have been trimmed")
    }

    @Test("a pane with no rule at all is untouched")
    func noRule() {
        let plain = "building\nrunning tests\nall green"
        #expect(StateClassifier.tail(of: plain) == ["building", "running tests", "all green"])
    }

    /// Dashes in prose are not a rule the terminal drew.
    @Test("a sentence with a dash is not mistaken for a rule")
    func prose() {
        let prose = """
         I rewrote the parser — it now handles the empty case.
         ──────────────────────────
         ~/repo (main)
         status bar here
        """
        let tail = StateClassifier.tail(of: prose)
        #expect(tail.last == "I rewrote the parser — it now handles the empty case.")
    }

    @Test("a pane that is nothing but furniture still says something")
    func allFurniture() {
        let bare = "─────────────────────\n~/repo (main)\nstatus bar"
        #expect(!StateClassifier.tail(of: bare).isEmpty)
    }
}

@Suite("A finished run shows what it said")
struct FinishedMessageTests {
    private let piFinished = """
     Took 0.4s
     写好了 README 和安装脚本。
     已切换到 research profile。default 的凭据已保存。
     ──────────────────────────────────────────────────────────
     ~/github-repo/ob-research-altas (main)
     ↑394k ↓5.2k R1.1M CH99.0% $0.108 (sub) 25.3%/272k (auto)
     🔌 MCP: 4 servers enabled
    """

    /// A finished row used to carry neither a reason nor a message, leaving
    /// the user two buttons and nothing to base them on: there is no way to
    /// write a follow-up to an answer you cannot see.
    @Test("a finished agent carries its last words")
    func finishedCarriesMessage() throws {
        let result = StateClassifier().classify(status: "done", recentOutput: piFinished)
        #expect(result.state == .finished)
        let message = try #require(result.message)
        #expect(message.contains("已切换到 research profile"))
        #expect(!message.contains("MCP: 4 servers"), "the status bar leaked into the message")
    }

    /// An idle agent is sitting at its prompt and may never have run anything,
    /// so its last lines are whatever is on screen — not a result.
    @Test("an idle agent does not claim its screen is a result")
    func idleCarriesNothing() {
        #expect(StateClassifier().classify(status: "idle", recentOutput: piFinished).message == nil)
    }
}
