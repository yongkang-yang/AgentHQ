import Foundation

// MARK: - Agent

/// One agent, as the UI needs to render it.
///
/// Every field here is something a row shows or sorts by. Raw herdr payloads
/// stay in `AgentHQHerdr` and are mapped into this on the way out, so the app
/// layer never pattern-matches on wire shapes.
public struct Agent: Sendable, Equatable, Identifiable {
    public var id: AgentRef { ref }

    public let ref: AgentRef

    /// Which tool is running: `claude`, `codex`, `aider`, … Lowercase wire
    /// name, used verbatim as the row label. Kept a String rather than an enum
    /// because the set is open and an unknown provider must still render.
    public var provider: String

    /// Repo or workspace label, as herdr reports it.
    public var workspace: String

    /// The working directory, when known. Distinct from `workspace`: two
    /// agents can share a workspace and sit in different worktrees.
    public var directory: String

    public var state: AgentState

    /// One short line saying *why* the agent is in this state. Nil when there
    /// is nothing honest to say — an empty reason is better than a guess.
    public var reason: String?

    /// When the agent entered its current state. Drives the dwell figure.
    public var stateEnteredAt: Date

    /// Last time output was seen, when known.
    public var lastActivityAt: Date?

    /// Which interventions the row may offer. Empty is a normal answer.
    public var actions: AgentActions

    /// herdr's reading of its state-change clock at this agent's last change.
    ///
    /// The clock is herd-wide — two agents changing state alternately produce
    /// one rising sequence, not two — but each agent keeps the value it was
    /// stamped with, so an unchanged stamp means *this* agent has not moved no
    /// matter how busy the rest of the herd was. That is what makes it usable
    /// as the token an intervention is checked against.
    ///
    /// Nil when it was not read. An action that needs the guard refuses
    /// without it rather than proceeding unguarded.
    public var stateSeq: UInt64?

    public init(
        ref: AgentRef,
        provider: String,
        workspace: String = "",
        directory: String = "",
        state: AgentState = .unknown,
        reason: String? = nil,
        stateEnteredAt: Date = Date(),
        lastActivityAt: Date? = nil,
        actions: AgentActions = .none,
        stateSeq: UInt64? = nil
    ) {
        self.ref = ref
        self.provider = provider
        self.workspace = workspace
        self.directory = directory
        self.state = state
        self.reason = reason
        self.stateEnteredAt = stateEnteredAt
        self.lastActivityAt = lastActivityAt
        self.actions = actions
        self.stateSeq = stateSeq
    }

    /// How long the agent has been in its current state.
    public func dwell(now: Date = Date()) -> TimeInterval {
        now.timeIntervalSince(stateEnteredAt)
    }
}
