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
        /// A machine stopped answering. Not an agent problem, and never
        /// reported as one.
        case machineUnreachable(machine: MachineID, reason: String)
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
        return "\(announcements.count) agents need you\(where_)"
    }

    /// The body, which carries the detail the title had to drop.
    ///
    /// A single announcement shows the message it interrupted for: the actual
    /// question is what lets the user answer from the notification, and a
    /// restated state is not. The one-line reason is the fallback for when
    /// there was no prompt to read.
    public var body: String {
        if announcements.count == 1 {
            switch announcements[0].subject {
            case .agent(_, _, _, let reason, let message):
                return message ?? reason ?? ""
            case .machineUnreachable(_, let reason):
                return reason
            }
        }
        return announcements.map(Self.line(for:)).joined(separator: "\n")
    }

    private static func line(for announcement: Announcement) -> String {
        switch announcement.subject {
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
    /// Which states are worth a notification.
    ///
    /// `rateLimited` is included even though the user cannot clear it: the
    /// herd has stalled, and they would otherwise assume progress. `finished`
    /// is not — a run completing is good news that can wait for the next time
    /// they look, and a notification per completion is most of the noise a
    /// fleet produces.
    public static let announcedStates: Set<AgentState> = [
        .needsApproval, .needsInput, .crashed, .mergeConflict, .ciFailed, .rateLimited,
    ]

    private var lastState: [AgentRef: AgentState] = [:]
    private var unreachableMachines: Set<MachineID> = []
    private var hasSeen = false

    public init() {}

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
                guard Self.announcedStates.contains(agent.state) else { continue }
                // Only on entering the state. Re-announcing every refresh is
                // the same notification several times a second.
                guard lastState[agent.ref] != agent.state else { continue }

                result.append(Announcement(
                    subject: .agent(
                        ref: agent.ref,
                        provider: agent.provider,
                        state: agent.state,
                        reason: agent.reason,
                        message: agent.message
                    ),
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
