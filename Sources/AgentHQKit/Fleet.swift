import Foundation

// MARK: - MachineView

/// One machine and everything currently known about it.
///
/// `agents` is the last list successfully read. When `reachability` is not
/// `.connected` that list is stale by definition, and the UI must say so
/// rather than render it as current.
public struct MachineView: Sendable, Equatable, Identifiable {
    public var id: MachineID { machine.id }

    public let machine: Machine
    public let reachability: MachineReachability
    public let agents: [Agent]
    /// The herdr this machine is running, once it has answered. Worth showing:
    /// hosts drift, and a machine on an older protocol reports fields this
    /// client no longer reads.
    public let herdrVersion: String?

    public init(
        machine: Machine,
        reachability: MachineReachability,
        agents: [Agent],
        herdrVersion: String? = nil
    ) {
        self.machine = machine
        self.reachability = reachability
        self.agents = agents
        self.herdrVersion = herdrVersion
    }

    public var agentsAreStale: Bool { reachability.agentsAreStale }
}

// MARK: - FleetSignal

/// Everything the menu bar needs, and nothing it has to compute itself.
///
/// Carries the attention state and the degraded state side by side instead of
/// collapsing them into one verdict: an unreachable machine and a blocked
/// agent are different problems, and a bar that can only say one of them at a
/// time will hide whichever it ranks second.
public struct FleetSignal: Sendable, Equatable {
    /// Highest-severity state across every agent on every reachable machine.
    /// Nil when there are no agents to speak for.
    public let topState: AgentState?
    public let attentionCount: Int
    public let workingCount: Int
    public let unreachableMachineCount: Int

    public init(
        topState: AgentState?,
        attentionCount: Int,
        workingCount: Int,
        unreachableMachineCount: Int
    ) {
        self.topState = topState
        self.attentionCount = attentionCount
        self.workingCount = workingCount
        self.unreachableMachineCount = unreachableMachineCount
    }

    public var isDegraded: Bool { unreachableMachineCount > 0 }

    public static let empty = FleetSignal(
        topState: nil, attentionCount: 0, workingCount: 0, unreachableMachineCount: 0
    )
}

// MARK: - FleetSnapshot

/// An immutable view of the whole fleet at one instant.
///
/// A value type on purpose: the fleet is assembled from N independently
/// reconnecting machines, and passing a snapshot to the UI means a view never
/// observes a half-updated fleet.
public struct FleetSnapshot: Sendable, Equatable {
    public let machines: [MachineView]
    public let capturedAt: Date

    public init(machines: [MachineView], capturedAt: Date = Date()) {
        self.machines = machines
        self.capturedAt = capturedAt
    }

    public static let empty = FleetSnapshot(machines: [], capturedAt: .distantPast)

    // MARK: Agents

    /// Every agent across every machine, unsorted.
    public var allAgents: [Agent] {
        machines.flatMap(\.agents)
    }

    /// Agents in one panel section, ordered the way the panel shows them:
    /// most severe first, then longest-waiting, then by machine and provider
    /// so the order is stable between refreshes.
    ///
    /// Agents on machines that are not connected are excluded: their state is
    /// stale, and a stale "needs approval" row invites the user to answer a
    /// prompt that may no longer exist.
    public func agents(in group: AttentionGroup, now: Date = Date()) -> [Agent] {
        let live = machines.filter { !$0.agentsAreStale }.flatMap(\.agents)
        return live
            .filter { $0.state.group == group }
            .sorted { lhs, rhs in
                if lhs.state.severity != rhs.state.severity {
                    return lhs.state.severity > rhs.state.severity
                }
                let lhsDwell = lhs.dwell(now: now)
                let rhsDwell = rhs.dwell(now: now)
                if lhsDwell != rhsDwell { return lhsDwell > rhsDwell }
                if lhs.ref.machine.raw != rhs.ref.machine.raw {
                    return lhs.ref.machine.raw < rhs.ref.machine.raw
                }
                if lhs.provider != rhs.provider { return lhs.provider < rhs.provider }
                return lhs.ref.agent.raw < rhs.ref.agent.raw
            }
    }

    // MARK: Signal

    public var signal: FleetSignal {
        let live = machines.filter { !$0.agentsAreStale }.flatMap(\.agents)
        let unreachable = machines.filter {
            if case .unreachable = $0.reachability { return true }
            return false
        }.count

        return FleetSignal(
            topState: live.map(\.state).max(by: { $0.severity < $1.severity }),
            attentionCount: live.filter { $0.state.needsAttention }.count,
            workingCount: live.filter { $0.state == .working }.count,
            unreachableMachineCount: unreachable
        )
    }
}
