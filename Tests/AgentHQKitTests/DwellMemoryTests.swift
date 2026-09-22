import Foundation
import Testing
@testable import AgentHQKit

private let machine = MachineID("m1")
private let anHourAgo = Date().addingTimeInterval(-3600)

private func agent(
    _ pane: String, _ state: AgentState, seq: UInt64?, enteredAt: Date = Date()
) -> Agent {
    Agent(
        ref: AgentRef(machine: machine, agent: AgentID(pane)),
        provider: "claude", state: state,
        stateEnteredAt: enteredAt, stateSeq: seq
    )
}

private func record(
    _ pane: String, _ state: AgentState, seq: UInt64?, enteredAt: Date = anHourAgo
) -> DwellRecord {
    DwellRecord(
        ref: AgentRef(machine: machine, agent: AgentID(pane)),
        state: state, stateSeq: seq, enteredAt: enteredAt
    )
}

@Suite("dwell across a restart")
struct DwellMemoryTests {
    @Test("an agent that has not moved keeps the clock it had")
    func unchangedAgentKeepsItsClock() throws {
        // The whole point: reopening the app to find what has been waiting
        // longest must not reset every agent to "just now".
        let restored = DwellMemory.restore(
            [agent("p1", .needsApproval, seq: 100)],
            from: [record("p1", .needsApproval, seq: 100)]
        )
        #expect(restored.first?.stateEnteredAt == anHourAgo)
    }

    @Test("a different state refuses the old clock")
    func changedStateStartsFresh() {
        let now = Date()
        let restored = DwellMemory.restore(
            [agent("p1", .working, seq: 100, enteredAt: now)],
            from: [record("p1", .needsApproval, seq: 100)]
        )
        #expect(restored.first?.stateEnteredAt == now)
    }

    @Test("the same state with a moved stamp refuses the old clock")
    func roundTripIsNotWaiting() {
        // An agent that went blocked, was answered, and blocked again is in
        // the same state but has not been waiting since the first time.
        // Matching on state alone would report hours that never happened.
        let now = Date()
        let restored = DwellMemory.restore(
            [agent("p1", .needsApproval, seq: 140, enteredAt: now)],
            from: [record("p1", .needsApproval, seq: 100)]
        )
        #expect(restored.first?.stateEnteredAt == now)
    }

    @Test("a missing stamp on either side refuses the restore")
    func noStampNoRestore() {
        let now = Date()
        // Fresh is wrong by at most the time the app was closed. A fabricated
        // hour is wrong in a way the user would act on.
        let noCurrentStamp = DwellMemory.restore(
            [agent("p1", .needsApproval, seq: nil, enteredAt: now)],
            from: [record("p1", .needsApproval, seq: 100)]
        )
        #expect(noCurrentStamp.first?.stateEnteredAt == now)

        let noRememberedStamp = DwellMemory.restore(
            [agent("p1", .needsApproval, seq: 100, enteredAt: now)],
            from: [record("p1", .needsApproval, seq: nil)]
        )
        #expect(noRememberedStamp.first?.stateEnteredAt == now)
    }

    @Test("an agent nobody remembers is left alone")
    func unknownAgentIsUntouched() {
        let now = Date()
        let restored = DwellMemory.restore(
            [agent("p9", .needsApproval, seq: 100, enteredAt: now)],
            from: [record("p1", .needsApproval, seq: 100)]
        )
        #expect(restored.first?.stateEnteredAt == now)
    }

    @Test("a record from another machine never applies")
    func machineScoped() {
        // Pane ids collide across machines. This is the same mistake AgentRef
        // exists to prevent, arriving through a file instead of a snapshot.
        let now = Date()
        let other = DwellRecord(
            ref: AgentRef(machine: MachineID("m2"), agent: AgentID("p1")),
            state: .needsApproval, stateSeq: 100, enteredAt: anHourAgo
        )
        let restored = DwellMemory.restore(
            [agent("p1", .needsApproval, seq: 100, enteredAt: now)], from: [other]
        )
        #expect(restored.first?.stateEnteredAt == now)
    }

    @Test("records round-trip through JSON, to the second")
    func codable() throws {
        let original = try #require(
            DwellMemory.records(for: [agent("p1", .needsApproval, seq: 100, enteredAt: anHourAgo)]).first
        )
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601

        let decoded = try #require(
            try decoder.decode([DwellRecord].self, from: try encoder.encode([original])).first
        )

        #expect(decoded.ref == AgentRef(machine: machine, agent: AgentID("p1")))
        #expect(decoded.state == original.state)
        #expect(decoded.stateSeq == original.stateSeq)
        // ISO8601 without fractional seconds, so the instant comes back
        // truncated. Deliberate: the figure this feeds is rendered in whole
        // seconds, and a readable file is worth more here than a millisecond
        // nobody can see. Nothing in the restore compares these dates — it
        // compares the state and the stamp — so the truncation cannot make a
        // wrong dwell, only one that is under a second short.
        #expect(abs(decoded.enteredAt.timeIntervalSince(original.enteredAt)) < 1)
    }
}
