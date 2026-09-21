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
    /// Monotonic per-pane counter, bumped on every change to the pane. Used
    /// to detect that state moved on between reading a pane and acting on it.
    ///
    /// Protocol 22 calls this `revision`; protocol 17 called it
    /// `state_change_seq`. Anything ported from a 17-era client will read the
    /// old name and silently get zero.
    public let revision: UInt64

    public init(
        paneId: String,
        workspaceId: String,
        tabId: String,
        agentStatus: String,
        agent: String?,
        title: String?,
        cwd: String?,
        revision: UInt64
    ) {
        self.paneId = paneId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.agentStatus = agentStatus
        self.agent = agent
        self.title = title
        self.cwd = cwd
        self.revision = revision
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
public protocol HerdrClient: Sendable {
    func connect() async throws
    func disconnect() async

    func snapshot() async throws -> HerdrSnapshot
    func events() -> AsyncStream<HerdrEvent>

    // Interventions. Every one of these travels the same socket as the reads,
    // so they work unchanged over a forwarded tunnel.
    func sendKeys(paneId: String, keys: [String]) async throws
    func prompt(paneId: String, text: String) async throws
    func interrupt(paneId: String) async throws
}

