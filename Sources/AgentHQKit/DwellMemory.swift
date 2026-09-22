import Foundation

// MARK: - DwellRecord

/// When one agent entered the state it was last seen in.
///
/// Carries the state-change stamp alongside the time, which is what makes
/// restoring it honest — see ``DwellMemory``.
public struct DwellRecord: Sendable, Equatable, Codable {
    public let machine: String
    public let agent: String
    public let state: AgentState
    public let stateSeq: UInt64?
    public let enteredAt: Date

    public var ref: AgentRef {
        AgentRef(machine: MachineID(machine), agent: AgentID(agent))
    }

    public init(ref: AgentRef, state: AgentState, stateSeq: UInt64?, enteredAt: Date) {
        self.machine = ref.machine.raw
        self.agent = ref.agent.raw
        self.state = state
        self.stateSeq = stateSeq
        self.enteredAt = enteredAt
    }
}

// MARK: - DwellMemory

/// Carries "how long has this been waiting" across a restart.
///
/// herdr cannot answer this: its agent records carry no timestamp at all, and
/// `state_change_seq` is a counter rather than a clock. So the figure is ours
/// to remember, and a restart wiped it — every agent looked as though it had
/// entered its state the moment the app launched. That is wrong in the one
/// dimension the panel sorts by, so the longest-waiting agent stopped rising
/// to the top precisely when the user had just reopened the app to find it.
public enum DwellMemory {
    /// Restore remembered entry times onto a freshly read herd.
    ///
    /// An entry time is carried forward **only** when the agent is in the same
    /// state *and* its `state_change_seq` still matches. Matching on state
    /// alone would be a guess: an agent that went blocked, was answered, and
    /// blocked again would inherit the first block's clock and report hours of
    /// waiting that never happened. The stamp is exactly the evidence that no
    /// such round trip occurred, which is what it exists for.
    ///
    /// A missing stamp on either side refuses the restore. Fresh is wrong by
    /// at most the time the app was closed; a fabricated hour is wrong in a
    /// way the user would act on.
    public static func restore(
        _ agents: [Agent],
        from records: [DwellRecord]
    ) -> [Agent] {
        let remembered = Dictionary(
            records.map { ($0.ref, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        return agents.map { agent in
            guard
                let record = remembered[agent.ref],
                record.state == agent.state,
                let remembered = record.stateSeq,
                let current = agent.stateSeq,
                remembered == current
            else { return agent }

            var restored = agent
            restored.stateEnteredAt = record.enteredAt
            return restored
        }
    }

    /// What to write down for next launch.
    public static func records(for agents: [Agent]) -> [DwellRecord] {
        agents.map {
            DwellRecord(
                ref: $0.ref,
                state: $0.state,
                stateSeq: $0.stateSeq,
                enteredAt: $0.stateEnteredAt
            )
        }
    }
}
