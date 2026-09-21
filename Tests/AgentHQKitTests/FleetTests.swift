import Foundation
import Testing
@testable import AgentHQKit

private let m1 = MachineID("aaaa-1")
private let m2 = MachineID("bbbb-2")

private func agent(
    _ machine: MachineID,
    _ pane: String,
    _ state: AgentState,
    enteredSecondsAgo: TimeInterval = 0,
    provider: String = "claude",
    now: Date = Date()
) -> Agent {
    Agent(
        ref: AgentRef(machine: machine, agent: AgentID(pane)),
        provider: provider,
        state: state,
        stateEnteredAt: now.addingTimeInterval(-enteredSecondsAgo)
    )
}

private func machineView(
    _ id: MachineID,
    name: String,
    _ reachability: MachineReachability,
    _ agents: [Agent]
) -> MachineView {
    MachineView(
        machine: Machine(id: id, displayName: name, transport: .local(socketPath: "/tmp/x.sock")),
        reachability: reachability,
        agents: agents
    )
}

@Suite("AgentState")
struct AgentStateTests {
    @Test("every state belongs to exactly one group")
    func groupsAreTotal() {
        for state in AgentState.allCases {
            _ = state.group
        }
    }

    @Test("attention states are the ones in the Needs you group")
    func attentionMatchesGrouping() {
        for state in AgentState.allCases {
            #expect(state.needsAttention == (state.group == .needsYou))
        }
    }

    @Test("severity is a strict ordering with no ties")
    func severityIsUnique() {
        let severities = AgentState.allCases.map(\.severity)
        #expect(Set(severities).count == severities.count)
    }

    @Test("unknown never lands in Needs you")
    func unknownStaysSecondary() {
        // Promoting unclassified state into the alarm section trains the user
        // to ignore the alarm section.
        #expect(AgentState.unknown.group == .working)
        #expect(!AgentState.unknown.needsAttention)
    }
}

@Suite("AgentRef")
struct AgentRefTests {
    @Test("same pane id on two machines is two different agents")
    func paneIdsAreScopedToMachines() {
        let a = AgentRef(machine: m1, agent: AgentID("pane-1"))
        let b = AgentRef(machine: m2, agent: AgentID("pane-1"))
        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("the wire id survives round-tripping untouched")
    func agentIDIsAFaithfulEcho() throws {
        let id = AgentID("ws-7:pane-3")
        let data = try JSONEncoder().encode(id)
        #expect(try JSONDecoder().decode(AgentID.self, from: data).raw == "ws-7:pane-3")
    }
}

@Suite("FleetSnapshot")
struct FleetSnapshotTests {
    @Test("groups sort by severity, then by longest wait")
    func orderingWithinGroup() {
        let now = Date()
        let snapshot = FleetSnapshot(machines: [
            machineView(m1, name: "laptop", .connected, [
                agent(m1, "p1", .needsInput, enteredSecondsAgo: 10, now: now),
                agent(m1, "p2", .crashed, enteredSecondsAgo: 1, now: now),
                agent(m1, "p3", .needsInput, enteredSecondsAgo: 300, now: now),
            ])
        ])

        let rows = snapshot.agents(in: .needsYou, now: now)
        #expect(rows.map(\.ref.agent.raw) == ["p2", "p3", "p1"])
    }

    @Test("worst state wins the signal")
    func signalTakesTheWorstState() {
        let snapshot = FleetSnapshot(machines: [
            machineView(m1, name: "laptop", .connected, [
                agent(m1, "p1", .working),
                agent(m1, "p2", .needsApproval),
            ]),
            machineView(m2, name: "server", .connected, [
                agent(m2, "p1", .finished),
            ]),
        ])

        #expect(snapshot.signal.topState == .needsApproval)
        #expect(snapshot.signal.attentionCount == 1)
        #expect(snapshot.signal.workingCount == 1)
    }

    @Test("an unreachable machine does not turn its agents into alarms")
    func staleAgentsAreExcluded() {
        // The whole point of keeping reachability on its own axis: one dropped
        // tunnel must not read as two blocked agents.
        let snapshot = FleetSnapshot(machines: [
            machineView(m1, name: "server", .unreachable(reason: "ssh exited"), [
                agent(m1, "p1", .needsApproval),
                agent(m1, "p2", .needsApproval),
            ])
        ])

        #expect(snapshot.agents(in: .needsYou).isEmpty)
        #expect(snapshot.signal.topState == nil)
        #expect(snapshot.signal.attentionCount == 0)
        #expect(snapshot.signal.unreachableMachineCount == 1)
        #expect(snapshot.signal.isDegraded)
    }

    @Test("reconnecting is transient and not reported as degraded")
    func reconnectingStaysCalm() {
        let snapshot = FleetSnapshot(machines: [
            machineView(m1, name: "server", .reconnecting(attempt: 2), [])
        ])
        #expect(snapshot.signal.isDegraded == false)
        #expect(MachineReachability.reconnecting(attempt: 2).isTransient)
    }

    @Test("an empty fleet has no opinion")
    func emptyFleet() {
        #expect(FleetSnapshot.empty.signal == .empty)
    }
}
