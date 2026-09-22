import Foundation

// MARK: - Announcement

/// One thing worth interrupting the user about.
public struct Announcement: Sendable, Equatable {
    public enum Subject: Sendable, Equatable {
        /// An agent entered a state that wants a human.
        case agent(
            ref: AgentRef, provider: String, state: AgentState,
            reason: String?, message: String?
        )
        /// A run that just ended.
        ///
        /// Its own case rather than an ``agent`` carrying `finished`, because
        /// the state it lands in is not what makes it a completion — the
        /// transition out of `working` is, and the landing state is `idle` or
        /// `finished` depending on bookkeeping AgentHQ does not own. Every
        /// reader downstream would otherwise have to re-derive that.
        case completed(ref: AgentRef, provider: String, message: String?)

        /// A machine stopped answering. Not an agent problem, and never
        /// reported as one.
        case machineUnreachable(machine: MachineID, reason: String)

        /// The one agent this names, for a click to land on. Nil for a
        /// machine, which names no single row to open.
        public var ref: AgentRef? {
            switch self {
            case .agent(let ref, _, _, _, _):  return ref
            case .completed(let ref, _, _):    return ref
            case .machineUnreachable:          return nil
            }
        }
    }

    public let subject: Subject
    /// The machine's display name. Always carried: in a fleet, "cursor needs
    /// approval" without saying where is a notification the user cannot act on.
    public let machineName: String

    public init(subject: Subject, machineName: String) {
        self.subject = subject
        self.machineName = machineName
    }
}

// MARK: - Batch

public struct AnnouncementBatch: Sendable, Equatable {
    public let announcements: [Announcement]

    public init(_ announcements: [Announcement] = []) {
        self.announcements = announcements
    }

    public static let none = AnnouncementBatch()
    public var isEmpty: Bool { announcements.isEmpty }

    /// What to put in a single notification.
    ///
    /// Several agents going blocked at once is one event to a human, not five.
    /// Five notifications for one deploy is how a user turns notifications off,
    /// and then the product's whole promise is gone.
    public var title: String {
        guard let first = announcements.first else { return "" }
        if announcements.count == 1 { return Self.line(for: first) }

        let machines = Set(announcements.map(\.machineName))
        let where_ = machines.count == 1 ? " on \(machines.first!)" : " across \(machines.count) machines"

        // A completion does not "need you", and a batch that says so of a
        // finished run is asking the user to go deal with something that
        // wants nothing. Counted separately and named separately, including
        // in the mixed case — which is the common one on a busy herd, and the
        // one where a single wrong verb costs the most.
        let finished = announcements.filter(Self.isCompletion).count
        let needing = announcements.count - finished
        if finished == 0 { return "\(announcements.count) agents need you\(where_)" }
        if needing == 0 { return "\(finished) runs finished\(where_)" }
        return "\(needing) agents need you, \(finished) finished\(where_)"
    }

    static func isCompletion(_ announcement: Announcement) -> Bool {
        if case .completed = announcement.subject { return true }
        return false
    }

    /// The body, which carries the detail the title had to drop.
    ///
    /// A single announcement shows the message it interrupted for: the actual
    /// question is what lets the user answer from the notification, and a
    /// restated state is not. The one-line reason is the fallback for when
    /// there was no prompt to read.
    ///
    /// This is what makes a completion notification worth having rather than
    /// merely true. `finished` is one of `StateClassifier.messageStates`, so
    /// the excerpt here is the run's last words — the answer, not the fact
    /// that there is one.
    public var body: String {
        if announcements.count == 1 {
            switch announcements[0].subject {
            case .agent(_, _, _, let reason, let message):
                return message ?? reason ?? ""
            case .completed(_, _, let message):
                return message ?? ""
            case .machineUnreachable(_, let reason):
                return reason
            }
        }
        return announcements.map(Self.line(for:)).joined(separator: "\n")
    }

    private static func line(for announcement: Announcement) -> String {
        switch announcement.subject {
        case .completed(_, let provider, _):
            // "claude on wsl — finished" reads as a status readout. This is
            // the one announcement that is an event, so it is written as one.
            return "\(provider) finished on \(announcement.machineName)"
        case .agent(_, let provider, let state, _, _):
            return "\(provider) on \(announcement.machineName) — \(state.rawValue)"
        case .machineUnreachable:
            return "\(announcement.machineName) is unreachable"
        }
    }
}

// MARK: - NotificationPolicy

/// Decides what is worth interrupting the user about, from one fleet snapshot
/// to the next.
///
/// Pure except for the memory of what it has already said. The rules it
/// encodes are the difference between a product the user keeps notifications
/// on for and one they mute in the first hour.
public struct NotificationPolicy: Sendable {
    /// The states that always warrant a notification: an agent is stuck and
    /// the herd is not moving until someone does something.
    ///
    /// `rateLimited` is included even though the user cannot clear it — the
    /// herd has stalled, and they would otherwise assume progress.
    public static let announcedStates: Set<AgentState> = [
        .needsApproval, .needsInput, .crashed, .mergeConflict, .ciFailed, .rateLimited,
    ]

    /// Whether a run completing is also worth one.
    ///
    /// This was a flat no, on the grounds that a completion is good news that
    /// can wait for the next time the user looks, and that a notification per
    /// completion is most of the noise a fleet produces. Half of that is still
    /// true — it is why this is a preference rather than a constant — but the
    /// first half had the product backwards. The premise of a menu-bar triage
    /// panel is that the user is *not* looking; "the thing you were waiting
    /// for is done" is the one event that most deserves to reach them.
    ///
    /// And the noise estimate was too pessimistic, because of what `done`
    /// means. herdr reports `done` as "completed **and unseen**" and tracks
    /// the seen state server-side (invariant 9), so a completion is one state
    /// entry, announced once by the rule below. It is not a status that
    /// re-fires while the run sits there finished.
    public var announcesCompletions: Bool

    /// The states that mean "the run is over and the agent is ready for
    /// input". A completion is the *transition* into one of these from
    /// ``AgentState/working`` — not the arrival at any one of them.
    ///
    /// `idle` is in here, and that is the whole point. A finished run only
    /// reaches AgentHQ as `finished` when herdr calls it `done`, and `done`
    /// means "completed **and unseen**" (invariant 9). Measured on this herd:
    /// a run in a focused pane went `working` (seq 50) → **`idle`** (seq 51),
    /// never `done`. herdr had already counted it seen. So a policy watching
    /// for `finished` waits for a state that, for the pane the user happens
    /// to be looking at, never comes — no notification, and nothing in
    /// Completed either.
    ///
    /// Watching the transition instead needs nothing from herdr's seen-state
    /// bookkeeping, which is another client's and not ours to read.
    static let readyStates: Set<AgentState> = [.idle, .finished]

    private var lastState: [AgentRef: AgentState] = [:]
    private var unreachableMachines: Set<MachineID> = []
    private var hasSeen = false

    public init(announcesCompletions: Bool = true) {
        self.announcesCompletions = announcesCompletions
    }

    /// Whether an agent arriving at `state` from `previous` is worth saying
    /// something about.
    private func isAnnounced(_ state: AgentState, from previous: AgentState?) -> Bool {
        if Self.announcedStates.contains(state) { return true }
        return isCompletion(entering: state, from: previous)
    }

    /// A run that just ended: it was working, and now it is taking input.
    ///
    /// The `working` requirement is what keeps this from firing on every
    /// agent that is merely sitting idle — most of them, most of the time,
    /// including every one of them the first time a machine connects.
    private func isCompletion(entering state: AgentState, from previous: AgentState?) -> Bool {
        guard announcesCompletions, previous == .working else { return false }
        return Self.readyStates.contains(state)
    }

    /// What to announce for this snapshot.
    ///
    /// Mutating, because "already said that" is the whole job.
    public mutating func announcements(for snapshot: FleetSnapshot) -> AnnouncementBatch {
        var result: [Announcement] = []

        let machineNames = Dictionary(
            snapshot.machines.map { ($0.machine.id, $0.machine.displayName) },
            uniquingKeysWith: { first, _ in first }
        )

        // Machines that have newly stopped answering.
        var nowUnreachable: Set<MachineID> = []
        for view in snapshot.machines {
            guard case .unreachable(let reason) = view.reachability else { continue }
            nowUnreachable.insert(view.machine.id)
            if hasSeen, !unreachableMachines.contains(view.machine.id) {
                result.append(Announcement(
                    subject: .machineUnreachable(machine: view.machine.id, reason: reason),
                    machineName: view.machine.displayName
                ))
            }
        }
        unreachableMachines = nowUnreachable

        // Agents. Only those on machines we can currently see: a stale row is
        // not evidence of anything, and announcing from one would turn a
        // dropped tunnel into a burst of alarms.
        var nowState: [AgentRef: AgentState] = [:]
        for view in snapshot.machines where !view.agentsAreStale {
            for agent in view.agents {
                nowState[agent.ref] = agent.state
                guard hasSeen else { continue }
                let previous = lastState[agent.ref]
                // Only on entering the state. Re-announcing every refresh is
                // the same notification several times a second.
                guard previous != agent.state else { continue }
                guard isAnnounced(agent.state, from: previous) else { continue }

                let subject: Announcement.Subject =
                    isCompletion(entering: agent.state, from: previous)
                    ? .completed(
                        ref: agent.ref, provider: agent.provider, message: agent.message
                      )
                    : .agent(
                        ref: agent.ref,
                        provider: agent.provider,
                        state: agent.state,
                        reason: agent.reason,
                        message: agent.message
                      )
                result.append(Announcement(
                    subject: subject,
                    machineName: machineNames[agent.ref.machine] ?? agent.ref.machine.raw
                ))
            }
        }

        // Agents on machines that went stale keep their remembered state, so
        // coming back unchanged is not announced as if it were new.
        for (ref, state) in lastState where nowState[ref] == nil {
            if let view = snapshot.machines.first(where: { $0.machine.id == ref.machine }),
               view.agentsAreStale {
                nowState[ref] = state
            }
        }
        lastState = nowState

        // The first snapshot only teaches. At launch every agent is new, and a
        // herd that has been sitting blocked for an hour is not news — it is
        // the state of the world the user just asked to see.
        guard hasSeen else {
            hasSeen = true
            return .none
        }
        return AnnouncementBatch(result)
    }
}
