import Testing
@testable import AgentHQApp

@Suite("The console reads at the pace the pane is changing")
struct PollPaceTests {
    @Test("a moving pane is read at the fastest pace")
    func startsFast() {
        #expect(PollPace().interval == PollPace.fastest)
    }

    @Test("a couple of quiet reads do not slow it: output comes in bursts")
    func graceBeforeSlowing() {
        var pace = PollPace()
        for _ in 0..<PollPace.graceReads { pace.settle() }
        #expect(pace.interval == PollPace.fastest)
    }

    @Test("a pane that stays still backs off, and never past the ceiling")
    func backsOffToCeiling() {
        var pace = PollPace()
        var seen: [Duration] = []
        for _ in 0..<20 {
            pace.settle()
            seen.append(pace.interval)
        }
        #expect(seen.last == PollPace.slowest)
        #expect(seen.allSatisfy { $0 <= PollPace.slowest })
        #expect(seen == seen.sorted())
    }

    @Test("any change snaps it straight back to the fastest pace")
    func resetIsImmediate() {
        var pace = PollPace()
        for _ in 0..<20 { pace.settle() }
        pace.reset()
        #expect(pace.interval == PollPace.fastest)
        // And the grace starts over, rather than slowing on the next quiet read.
        pace.settle()
        #expect(pace.interval == PollPace.fastest)
    }
}
