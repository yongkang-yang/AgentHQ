import Foundation
import Testing
@testable import AgentHQKit

private let local = MachineID("m-local")
private let remote = MachineID("m-remote")

private func agent(
    _ machine: MachineID, _ pane: String, _ state: AgentState,
    provider: String = "claude", reason: String? = nil
) -> Agent {
    Agent(
        ref: AgentRef(machine: machine, agent: AgentID(pane)),
        provider: provider, state: state, reason: reason
    )
}

private func snapshot(_ views: (MachineID, String, MachineReachability, [Agent])...) -> FleetSnapshot {
    FleetSnapshot(machines: views.map { id, name, reach, agents in
        MachineView(
            machine: Machine(id: id, displayName: name, transport: .local(socketPath: "/tmp/x.sock")),
            reachability: reach, agents: agents
        )
    })
}

@Suite("notification policy")
struct NotificationPolicyTests {
    /// Runs a sequence of snapshots and returns what each one announced.
    private func run(_ snapshots: [FleetSnapshot]) -> [AnnouncementBatch] {
        var policy = NotificationPolicy()
        return snapshots.map { policy.announcements(for: $0) }
    }

    @Test("the first snapshot announces nothing")
    func firstSnapshotIsSilent() {
        // At launch everything is new. A herd that has been sitting blocked
        // for an hour is not news — it is the state the user just asked to see.
        let batches = run([
            snapshot((local, "this mac", .connected, [
                agent(local, "p1", .needsApproval),
                agent(local, "p2", .crashed),
            ]))
        ])
        #expect(batches[0].isEmpty)
    }

    @Test("entering an attention state announces once, not every refresh")
    func announcesOnEntryOnly() {
        let working = snapshot((local, "this mac", .connected, [agent(local, "p1", .working)]))
        let blocked = snapshot((local, "this mac", .connected, [agent(local, "p1", .needsApproval)]))

        let batches = run([working, blocked, blocked, blocked])
        #expect(batches[0].isEmpty)      // seeding
        #expect(batches[1].announcements.count == 1)
        // Re-announcing every refresh is the same notification several times a
        // second, which is how a user turns notifications off.
        #expect(batches[2].isEmpty)
        #expect(batches[3].isEmpty)
    }

    @Test("moving between two attention states announces again")
    func stateChangeAnnouncesAgain() {
        let batches = run([
            snapshot((local, "this mac", .connected, [agent(local, "p1", .working)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .needsInput)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .crashed)])),
        ])
        #expect(batches[1].announcements.count == 1)
        #expect(batches[2].announcements.count == 1)
    }

    @Test("finishing is not worth interrupting anyone")
    func finishedIsNotAnnounced() {
        // Good news that can wait for the next time they look. A notification
        // per completion is most of the noise a fleet produces.
        let batches = run([
            snapshot((local, "this mac", .connected, [agent(local, "p1", .working)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .finished)])),
        ])
        #expect(batches[1].isEmpty)
        #expect(!NotificationPolicy.announcedStates.contains(.finished))
        #expect(!NotificationPolicy.announcedStates.contains(.working))
        #expect(!NotificationPolicy.announcedStates.contains(.unknown))
    }

    @Test("a stalled herd is announced even though the user cannot clear it")
    func rateLimitedIsAnnounced() {
        // They would otherwise assume progress.
        let batches = run([
            snapshot((local, "this mac", .connected, [agent(local, "p1", .working)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .rateLimited)])),
        ])
        #expect(batches[1].announcements.count == 1)
    }

    @Test("an unreachable machine is announced as itself, not as its agents dying")
    func machineUnreachableIsItsOwnEvent() {
        let up = snapshot((remote, "wsl", .connected, [
            agent(remote, "p1", .working), agent(remote, "p2", .working),
        ]))
        let down = snapshot((remote, "wsl", .unreachable(reason: "ssh exited"), [
            agent(remote, "p1", .working), agent(remote, "p2", .working),
        ]))

        let batches = run([up, down, down])
        let announced = batches[1].announcements
        #expect(announced.count == 1)
        guard case .machineUnreachable(_, let reason) = announced.first?.subject else {
            Issue.record("expected a machine announcement, got \(String(describing: announced.first?.subject))")
            return
        }
        #expect(reason == "ssh exited")
        // And it is said once, not on every refresh while it stays down.
        #expect(batches[2].isEmpty)
    }

    @Test("a dropped machine does not turn its agents into a burst of alarms")
    func staleAgentsAreNotAnnounced() {
        // The failure this rule exists for: agents on an unreachable machine
        // are not evidence of anything.
        let up = snapshot((remote, "wsl", .connected, [
            agent(remote, "p1", .working), agent(remote, "p2", .working),
        ]))
        let down = snapshot((remote, "wsl", .unreachable(reason: "ssh exited"), [
            agent(remote, "p1", .needsApproval), agent(remote, "p2", .crashed),
        ]))

        let batches = run([up, down])
        // One machine event, and nothing about the agents.
        #expect(batches[1].announcements.count == 1)
        for announcement in batches[1].announcements {
            if case .agent = announcement.subject {
                Issue.record("announced an agent on an unreachable machine")
            }
        }
    }

    @Test("a machine coming back does not replay what it was already showing")
    func returningMachineIsQuiet() {
        let blocked = [agent(remote, "p1", .needsApproval)]
        let batches = run([
            snapshot((remote, "wsl", .connected, [agent(remote, "p1", .working)])),
            snapshot((remote, "wsl", .connected, blocked)),                              // announces
            snapshot((remote, "wsl", .unreachable(reason: "ssh exited"), blocked)),      // machine event
            snapshot((remote, "wsl", .connected, blocked)),                              // unchanged
        ])
        #expect(batches[1].announcements.count == 1)
        // The agent has not moved, so reconnecting is not news about it.
        for announcement in batches[3].announcements {
            if case .agent = announcement.subject {
                Issue.record("replayed an unchanged agent after reconnect")
            }
        }
    }

    @Test("every announcement says which machine")
    func machineIsAlwaysNamed() {
        // "cursor needs approval" without saying where cannot be acted on.
        let batches = run([
            snapshot((remote, "wsl", .connected, [agent(remote, "p1", .working)])),
            snapshot((remote, "wsl", .connected, [agent(remote, "p1", .needsApproval)])),
        ])
        #expect(batches[1].announcements.allSatisfy { $0.machineName == "wsl" })
    }
}

@Suite("how a batch reads")
struct AnnouncementBatchTests {
    private func batch(_ count: Int, machine: String = "wsl") -> AnnouncementBatch {
        AnnouncementBatch((0..<count).map { i in
            Announcement(
                subject: .agent(
                    ref: AgentRef(machine: remote, agent: AgentID("p\(i)")),
                    provider: "cursor", state: .needsApproval, reason: "Approval: run (once) (y)"
                ),
                machineName: machine
            )
        })
    }

    @Test("one agent reads as itself")
    func singleAgent() {
        let one = batch(1)
        #expect(one.title == "cursor on wsl — needsApproval")
        #expect(one.body == "Approval: run (once) (y)")
    }

    @Test("several at once are one notification, not several")
    func coalesced() {
        // Five notifications for one deploy is how a user mutes the product.
        let many = batch(5)
        #expect(many.title == "5 agents need you on wsl")
        #expect(many.body.split(separator: "\n").count == 5)
    }

    @Test("a fleet-wide burst says how many machines")
    func acrossMachines() {
        let mixed = AnnouncementBatch(
            batch(2, machine: "wsl").announcements + batch(1, machine: "this mac").announcements
        )
        #expect(mixed.title == "3 agents need you across 2 machines")
    }

    @Test("an empty batch says nothing")
    func empty() {
        #expect(AnnouncementBatch.none.isEmpty)
        #expect(AnnouncementBatch.none.title.isEmpty)
    }
}
