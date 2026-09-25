import AgentHQKit
import Foundation

// MARK: - HerdrPane

/// One pane as herdr describes it, before AgentHQ has an opinion about it.
///
/// Field names track herdr's wire shape rather than AgentHQ's vocabulary, on
/// purpose: this is the last place that should look like herdr. Mapping into
/// ``Agent`` happens on the way out of this module.
public struct HerdrPane: Sendable, Equatable {
    public let paneId: String
    public let workspaceId: String
    public let tabId: String
    /// Herdr's raw status string: `idle`, `working`, `blocked`, `done`, …
    public let agentStatus: String
    /// The agent binary herdr detected in the pane, if any.
    public let agent: String?
    public let title: String?
    public let cwd: String?
    /// Free-form metadata a pane reported through `pane.report_metadata`.
    ///
    /// herdr has no model field of its own, so agents and plugins report one
    /// here. Keys are capped at 32 characters and values are strings; nothing
    /// in herdr assigns them meaning.
    public let tokens: [String: String]
    /// herdr's `revision` for the pane, decoded faithfully and used for
    /// nothing.
    ///
    /// It looks like the staleness counter and is not one. Measured on a live
    /// pane, it stayed at 0 across sending text, running a command, renaming
    /// the pane, an agent being detected in it, and that agent going blocked —
    /// while `state_change_seq` moved on the state change. Anything that needs
    /// to know whether an agent moved must read ``HerdrAgentInfo`` instead;
    /// this field is kept only so the pane record decodes completely.
    public let revision: UInt64
    /// `agent_session`: the agent's own transcript, as its integration
    /// reported it. On pane records only; see ``AgentSessionRef``.
    public let agentSession: AgentSessionRef?

    public init(
        paneId: String,
        workspaceId: String,
        tabId: String,
        agentStatus: String,
        agent: String?,
        title: String?,
        cwd: String?,
        tokens: [String: String] = [:],
        revision: UInt64,
        agentSession: AgentSessionRef? = nil
    ) {
        self.paneId = paneId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.agentStatus = agentStatus
        self.agent = agent
        self.title = title
        self.cwd = cwd
        self.tokens = tokens
        self.revision = revision
        self.agentSession = agentSession
    }

    /// The model this pane's agent is running, when a reporter named one.
    ///
    /// herdr itself reports no model, so this reads the metadata tokens. The
    /// quota plugin — measured on both a local and a remote machine — writes
    /// `quota_model` (`deepseek-v4.1-flash`, `gpt-5.6-luna`). A bare `model`
    /// token is accepted first so a first-party reporter would work unchanged.
    /// Nil rather than a guess when neither is present: Codex has no reliably
    /// observable active model, and an empty chip is better than a wrong one.
    public var model: String? {
        for key in ["model", "quota_model"] {
            if let value = tokens[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                return value
            }
        }
        return nil
    }
}

// MARK: - HerdrAgentInfo

/// One agent as `agent.get` / `agent.list` describe it.
///
/// Separate from ``HerdrPane`` because herdr's two views of the same pane do
/// not carry the same fields, and the difference is load-bearing: the agent
/// views carry `state_change_seq` and the pane views do not. Folding them into
/// one type would mean a field that is populated or zero depending on which
/// call filled it, which is precisely the silent-zero trap protocol 22 is full
/// of.
public struct HerdrAgentInfo: Sendable, Equatable {
    public let paneId: String
    public let agent: String
    public let agentStatus: String

    /// herdr's state-change clock as of this agent's last change.
    ///
    /// Herd-wide and monotonic, not per-pane: driving two panes through
    /// alternating state changes yields one rising sequence across both
    /// (measured — 230, 232, 234 on one pane interleaved with 231, 233, 235 on
    /// the other). Each agent keeps its own stamp from that clock, so an
    /// unchanged stamp still means *this* agent has not moved.
    ///
    /// This is the counter ``HerdrPane/revision`` was mistaken for. `revision`
    /// sits at 0 through output, renames, agent detection and a blocked
    /// transition; it is not a usable staleness token and nothing should treat
    /// it as one.
    public let stateChangeSeq: UInt64

    public init(paneId: String, agent: String, agentStatus: String, stateChangeSeq: UInt64) {
        self.paneId = paneId
        self.agent = agent
        self.agentStatus = agentStatus
        self.stateChangeSeq = stateChangeSeq
    }
}

// MARK: - HerdrSnapshot

public struct HerdrSnapshot: Sendable, Equatable {
    public let herdrVersion: String
    public let protocolVersion: Int
    public let panes: [HerdrPane]
    /// workspaceId -> label
    public let workspaceNames: [String: String]

    public init(
        herdrVersion: String,
        protocolVersion: Int,
        panes: [HerdrPane],
        workspaceNames: [String: String]
    ) {
        self.herdrVersion = herdrVersion
        self.protocolVersion = protocolVersion
        self.panes = panes
        self.workspaceNames = workspaceNames
    }
}

// MARK: - HerdrEvent

public enum HerdrEvent: Sendable, Equatable {
    case paneUpdated(HerdrPane)
    case paneClosed(paneId: String)
    /// Labels changed; the caller should resnapshot rather than patch.
    case topologyChanged
    case connected
    case disconnected
}

// MARK: - HerdrClient

/// Talks to exactly one herdr socket.
///
/// Knows nothing about machines, SSH, or the fleet — it is handed a local path
/// and speaks the protocol over it. That ignorance is deliberate: it is what
/// lets this module stay a near-verbatim port from Shepherd while everything
/// around it is new.
///
/// **One request, one connection.** herdr 0.9.0 replies once and closes; a
/// second request on the same socket dies with EPIPE. `events.subscribe` is
/// the exception and holds its connection open, so it gets one of its own.
///
/// (Shepherd keeps two persistent sockets and serializes requests on one of
/// them, to stop an event read-loop racing requests on a shared fd. That
/// answers a protocol-17 problem; protocol 22 has no shared fd to race on.)
/// Which of herdr's views of a pane to read.
///
/// `recent` is the scrollback tail as the terminal laid it out — wrapped to
/// the pane's width, which is what the classifier wants, since its rules are
/// written against lines as they appear. `recentUnwrapped` gives the logical
/// lines instead, which is what a reader wants: the panel is not the same
/// width as the pane, and re-wrapping an already-wrapped line leaves ragged
/// half-lines down the view.
public enum PaneReadSource: String, Sendable {
    case visible
    case recent
    case recentUnwrapped = "recent_unwrapped"
    case detection
}

public protocol HerdrClient: Sendable {
    /// herdr's handshake, for the version and protocol it speaks.
    func handshake() async throws -> (version: String, protocolVersion: Int)

    func connect() async throws
    func disconnect() async

    func snapshot() async throws -> HerdrSnapshot
    func events() -> AsyncStream<HerdrEvent>

    /// The tail of one pane's output. Returns nil when herdr has nothing to
    /// give rather than throwing — an unreadable pane is a pane we classify
    /// from status alone, not a failure worth surfacing.
    func readPane(paneId: String, lines: Int, source: PaneReadSource) async throws -> String?

    /// Every agent herdr currently sees, with its state-change stamp. One
    /// round trip for the whole machine.
    func agents() async throws -> [HerdrAgentInfo]

    /// One agent, re-read immediately before acting on it. Nil when it is gone.
    func agent(paneId: String) async throws -> HerdrAgentInfo?

    // Interventions. Every one of these travels the same socket as the reads,
    // so they work unchanged over a forwarded tunnel.
    func sendKeys(paneId: String, keys: [String]) async throws
    func sendText(paneId: String, text: String) async throws
    func prompt(paneId: String, text: String) async throws

    /// Bring a pane to the front in its own herdr: the pane, and the workspace
    /// and tab holding it, or focusing the pane alone leaves it on a workspace
    /// nobody is looking at.
    func focusPane(paneId: String) async throws
}

public extension HerdrClient {
    /// The classifier's read: the wrapped tail, which is the shape its rules
    /// were written against.
    func readPane(paneId: String, lines: Int) async throws -> String? {
        try await readPane(paneId: paneId, lines: lines, source: .recent)
    }
}
