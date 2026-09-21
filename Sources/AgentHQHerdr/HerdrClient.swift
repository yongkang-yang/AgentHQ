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
    /// Monotonic per-pane counter. Used to detect that state moved on between
    /// reading a pane and acting on it.
    public let stateChangeSeq: UInt64

    public init(
        paneId: String,
        workspaceId: String,
        tabId: String,
        agentStatus: String,
        agent: String?,
        title: String?,
        cwd: String?,
        stateChangeSeq: UInt64
    ) {
        self.paneId = paneId
        self.workspaceId = workspaceId
        self.tabId = tabId
        self.agentStatus = agentStatus
        self.agent = agent
        self.title = title
        self.cwd = cwd
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
/// **Two sockets, not one.** The implementation must open a second connection
/// for the `events.subscribe` stream and never issue requests on it. Sharing
/// one socket between a blocking event read-loop and concurrent requests races
/// two readers on the same fd and corrupts NDJSON framing — a bug Shepherd
/// already paid for, documented here so it is not rediscovered.
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

// TODO(port): LiveHerdrClient, ported from Shepherd's LiveHerdrAdapter +
// NDJSONClient (MIT — see NOTICE). Port the NDJSON framing and the decoding
// as-is; drop the socket-path resolution, which now lives in AgentHQTransport.
