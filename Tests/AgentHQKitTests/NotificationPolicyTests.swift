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
    private func run(
        _ snapshots: [FleetSnapshot],
        announcesCompletions: Bool = true
    ) -> [AnnouncementBatch] {
        var policy = NotificationPolicy(announcesCompletions: announcesCompletions)
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

    /// The premise of a triage panel is that the user is not looking. "The
    /// thing you were waiting for is done" is the event that most deserves to
    /// reach them, and it used to be the one state that never did.
    @Test("a run finishing reaches the user")
    func finishedIsAnnounced() {
        let batches = run([
            snapshot((local, "this mac", .connected, [agent(local, "p1", .working)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .finished)])),
        ])
        #expect(batches[1].announcements.count == 1)
    }

    /// The bug this rule exists for, in the shape it was found in.
    ///
    /// Measured against herdr 0.9.1: a run in a *focused* pane goes
    /// `working` → `idle` and never reports `done`, because herdr counts a
    /// focused pane as already seen. A policy watching for `finished` waits
    /// for a state that never arrives, so the completion the user was waiting
    /// on is the one thing that never reaches them.
    @Test("a run that ends as idle is still a completion")
    func finishingAsIdleIsAnnounced() {
        let batches = run([
            snapshot((local, "this mac", .connected, [agent(local, "p1", .working)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .idle)])),
        ])
        #expect(batches[1].announcements.count == 1)
        #expect(batches[1].announcements.allSatisfy(AnnouncementBatch.isCompletion))
        #expect(batches[1].title == "claude finished on this mac")
    }

    /// The other half of the same rule, and the reason it is a transition
    /// rather than a state: most idle agents are just idle. Announcing the
    /// state alone would fire for every agent on every machine that has ever
    /// sat at its prompt.
    @Test("an agent that was never working is not a completion")
    func idleWithoutWorkingIsSilent() {
        let batches = run([
            snapshot((local, "this mac", .connected, [agent(local, "p1", .needsInput)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .idle)])),
        ])
        #expect(batches[1].isEmpty)
    }

    /// Leaving `working` for something that wants a human is that thing, not
    /// a completion — and must not be announced twice.
    @Test("working to blocked is a demand, not a completion")
    func workingToBlockedIsNotACompletion() {
        let batches = run([
            snapshot((local, "this mac", .connected, [agent(local, "p1", .working)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .needsApproval)])),
        ])
        #expect(batches[1].announcements.count == 1)
        #expect(!batches[1].announcements.contains(where: AnnouncementBatch.isCompletion))
    }

    /// A completion is one state entry, not a status that keeps re-firing
    /// while the run sits there finished — which is what makes announcing it
    /// affordable. herdr's `done` means "completed and unseen" and the seen
    /// state lives on the server, so the row does not flap.
    @Test("a run that stays done is announced once")
    func finishedAnnouncesOnlyOnEntry() {
        let batches = run([
            snapshot((local, "this mac", .connected, [agent(local, "p1", .working)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .finished)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .finished)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .finished)])),
        ])
        #expect(batches[1].announcements.count == 1)
        #expect(batches[2].isEmpty)
        #expect(batches[3].isEmpty)
    }

    /// The escape hatch for a herd big enough that completions are noise. It
    /// turns off completions and nothing else — a stuck agent still gets
    /// through, because that half of the old rationale was never in doubt.
    @Test("completions can be turned off without silencing stuck agents")
    func completionsAreOptional() {
        let snapshots = [
            snapshot((local, "this mac", .connected, [
                agent(local, "p1", .working), agent(local, "p2", .working),
            ])),
            snapshot((local, "this mac", .connected, [
                agent(local, "p1", .finished), agent(local, "p2", .needsInput),
            ])),
        ]
        let quiet = run(snapshots, announcesCompletions: false)
        #expect(quiet[1].announcements.count == 1)
        #expect(!quiet[1].announcements.contains(where: AnnouncementBatch.isCompletion))

        #expect(run(snapshots)[1].announcements.count == 2)
    }

    @Test("neither working nor unknown is ever announced")
    func runningStatesAreSilent() {
        for state in [AgentState.working, .unknown, .idle] {
            let batches = run([
                snapshot((local, "this mac", .connected, [agent(local, "p1", .needsInput)])),
                snapshot((local, "this mac", .connected, [agent(local, "p1", state)])),
            ])
            #expect(batches[1].isEmpty, "\(state)")
        }
    }

    // MARK: What the notification says

    /// A finished run is an event, not a status readout, and it does not
    /// "need you" — a notification that says so sends the user to deal with
    /// something that wants nothing from them.
    @Test("a completion is worded as an event, not as a demand")
    func completionWording() {
        let batches = run([
            snapshot((local, "this mac", .connected, [agent(local, "p1", .working)])),
            snapshot((local, "this mac", .connected, [agent(local, "p1", .finished)])),
        ])
        #expect(batches[1].title == "claude finished on this mac")
        #expect(!batches[1].title.contains("need"))
    }

    /// The mixed batch is the common one on a busy herd, and the one where a
    /// single wrong verb costs the most: it is the case where some agents
    /// really are waiting and some are merely done.
    @Test("a mixed batch counts the two kinds separately")
    func mixedBatchWording() {
        let batches = run([
            snapshot((local, "this mac", .connected, [
                agent(local, "p1", .working),
                agent(local, "p2", .working),
                agent(local, "p3", .working),
            ])),
            snapshot((local, "this mac", .connected, [
                agent(local, "p1", .finished),
                agent(local, "p2", .needsInput),
                agent(local, "p3", .needsApproval),
            ])),
        ])
        #expect(batches[1].title == "2 agents need you, 1 finished on this mac")
    }

    @Test("a batch of nothing but completions says so")
    func allFinishedWording() {
        let batches = run([
            snapshot((local, "this mac", .connected, [
                agent(local, "p1", .working), agent(local, "p2", .working),
            ])),
            snapshot((local, "this mac", .connected, [
                agent(local, "p1", .finished), agent(local, "p2", .finished),
            ])),
        ])
        #expect(batches[1].title == "2 runs finished on this mac")
    }

    /// What makes a completion notification worth having rather than merely
    /// true: the run's last words travel with it, so the user learns the
    /// answer without opening anything.
    @Test("a completion carries what the run actually said")
    func completionCarriesItsMessage() {
        var policy = NotificationPolicy()
        _ = policy.announcements(for: snapshot(
            (local, "this mac", .connected, [agent(local, "p1", .working)])
        ))
        var done = agent(local, "p1", .finished)
        done.message = "All 239 tests passed."
        let batch = policy.announcements(for: snapshot(
            (local, "this mac", .connected, [done])
        ))
        #expect(batch.body == "All 239 tests passed.")
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
                    provider: "cursor", state: .needsApproval, reason: "Approval: run (once) (y)",
                    message: nil
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

    @Test("a single notification shows the question, not a restated state")
    func singleShowsTheMessage() {
        // The question is what lets the user answer from the notification; a
        // restated state is not. The one-line reason is the fallback.
        let announcement = Announcement(
            subject: .agent(
                ref: AgentRef(machine: remote, agent: AgentID("p1")),
                provider: "cursor", state: .needsInput,
                reason: "Which database?",
                message: "Which database should I migrate first?\n  (enter to send \u{00B7} esc to cancel)"
            ),
            machineName: "wsl"
        )
        #expect(
            AnnouncementBatch([announcement]).body
                == "Which database should I migrate first?\n  (enter to send \u{00B7} esc to cancel)"
        )
    }
}
