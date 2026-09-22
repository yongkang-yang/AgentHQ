import AgentHQKit
import Foundation

/// Talks to one herdr socket. Verified against herdr 0.9.0, protocol 22.
///
/// Requests open a connection, send one JSON-RPC line, read one reply, and
/// close — because that is what herdr does. The event subscription is the one
/// long-lived connection.
public actor LiveHerdrClient: HerdrClient {
    /// Protocol versions this client has actually been run against. A version
    /// outside the range is not refused — reads still work and are still
    /// useful — but the caller is told, so an unknown protocol degrades
    /// visibly instead of silently misreading fields.
    public static let verifiedProtocols = 22...22

    private let socketPath: String
    private let requestTimeout: Int

    private var nextRequestId: UInt64 = 0

    /// The subscription runs on its own thread and is reached through a box,
    /// never through actor state. See ``runSubscription``.
    private let subscriptionState = SubscriptionState()

    private let continuation: AsyncStream<HerdrEvent>.Continuation
    private let stream: AsyncStream<HerdrEvent>

    /// Global subscriptions, discovered from the server's own enum. The three
    /// remaining variants — `pane.output_matched`, `pane.agent_status_changed`,
    /// `pane.scroll_changed` — require a `pane_id` and are per-pane concerns,
    /// not herd-wide ones.
    static let globalSubscriptions = [
        "workspace.created", "workspace.updated", "workspace.metadata_updated",
        "workspace.renamed", "workspace.moved", "workspace.reordered",
        "workspace.closed", "workspace.focused",
        "worktree.created", "worktree.opened", "worktree.removed",
        "tab.created", "tab.closed", "tab.focused", "tab.renamed", "tab.moved",
        "pane.created", "pane.closed", "pane.updated", "pane.focused",
        "pane.moved", "pane.exited", "pane.agent_detected",
    ]

    public init(socketPath: String, requestTimeout: Int = 15) {
        self.socketPath = socketPath
        self.requestTimeout = requestTimeout
        var cont: AsyncStream<HerdrEvent>.Continuation!
        self.stream = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    // MARK: - Lifecycle

    public func connect() async throws {
        _ = try await handshake()
        startSubscription()
    }

    public func disconnect() async {
        // Closing the socket is what stops the reader: its `read(2)` returns 0
        // and the loop falls out. There is no way to interrupt a blocking read
        // from outside, so cancellation has to come through the fd.
        subscriptionState.stop()
        continuation.yield(.disconnected)
    }

    // `stream` is a `let`, so handing it out needs no isolation.
    public nonisolated func events() -> AsyncStream<HerdrEvent> { stream }

    // MARK: - Requests

    /// herdr's handshake. Returns its version and protocol.
    @discardableResult
    public func handshake() async throws -> (version: String, protocolVersion: Int) {
        let result = try await request(method: "ping", params: [:])
        return (
            result["version"] as? String ?? "",
            (result["protocol"] as? NSNumber)?.intValue ?? 0
        )
    }

    public func snapshot() async throws -> HerdrSnapshot {
        let result = try await request(method: "session.snapshot", params: [:])
        guard let snap = result["snapshot"] as? [String: Any] else {
            throw HerdrProtocolError.malformedJSON("session.snapshot has no `snapshot` object")
        }
        return Self.decodeSnapshot(snap)
    }

    public func readPane(
        paneId: String,
        lines: Int = 60,
        source: PaneReadSource = .recent
    ) async throws -> String? {
        // `recent` is the scrollback tail rather than what happens to be on
        // screen; `visible` would miss a prompt that has scrolled a line up.
        let result = try await request(
            method: "pane.read",
            params: ["pane_id": paneId, "source": source.rawValue, "lines": lines]
        )
        guard let read = result["read"] as? [String: Any] else { return nil }
        return read["text"] as? String
    }

    public func agents() async throws -> [HerdrAgentInfo] {
        let result = try await request(method: "agent.list", params: [:])
        let agents = result["agents"] as? [[String: Any]] ?? []
        return agents.compactMap(Self.decodeAgentInfo)
    }

    public func agent(paneId: String) async throws -> HerdrAgentInfo? {
        do {
            let result = try await request(method: "agent.get", params: ["target": paneId])
            guard let agent = result["agent"] as? [String: Any] else { return nil }
            return Self.decodeAgentInfo(agent)
        } catch HerdrProtocolError.herdr(let code, _)
                    where code == "agent_not_found" || code == "pane_not_found" {
            // Absence is an answer, and the caller — an intervention checking
            // that its target still exists — needs to tell it apart from a
            // socket that fell over.
            return nil
        }
    }

    /// Press keys in a pane.
    ///
    /// herdr validates the names (`banana` comes back `invalid_key`), so a
    /// typo here fails loudly rather than being typed into the pane as text.
    /// What it does *not* validate is the params object: it ignored an invented
    /// `expected_revision` field and answered `ok`, so there is no
    /// compare-and-swap to lean on. The guard has to happen on this side —
    /// see `MachineSession.perform`.
    public func sendKeys(paneId: String, keys: [String]) async throws {
        _ = try await request(method: "pane.send_keys", params: ["pane_id": paneId, "keys": keys])
    }

    public func sendText(paneId: String, text: String) async throws {
        _ = try await request(method: "pane.send_text", params: ["pane_id": paneId, "text": text])
    }

    /// Submit a prompt to the agent in a pane.
    ///
    /// The parameter is `target`, not `pane_id`. A `pane_id` here is not a
    /// wrong-value error — herdr rejects the whole request with
    /// `missing field `target``, so this call never worked at all.
    ///
    /// `target` accepts a pane id and nothing else useful: a terminal id comes
    /// back `agent_not_found`.
    public func prompt(paneId: String, text: String) async throws {
        _ = try await request(method: "agent.prompt", params: ["target": paneId, "text": text])
    }

    public func focusPane(paneId: String) async throws {
        // Workspace first, then the pane: focusing the pane alone on a
        // workspace that is not showing leaves it behind whatever is.
        if let workspaceId = paneId.split(separator: ":").first.map(String.init) {
            _ = try? await request(method: "workspace.focus", params: ["workspace_id": workspaceId])
        }
        _ = try await request(method: "pane.focus", params: ["pane_id": paneId])
    }

    // MARK: - Transport

    /// One request, one connection. See ``HerdrConnection``.
    private func request(method: String, params: [String: Any]) async throws -> [String: Any] {
        nextRequestId &+= 1
        let id = String(nextRequestId)
        let path = socketPath
        let timeout = requestTimeout

        let body: [String: Any] = [
            // herdr rejects an integer id with `invalid type: integer, expected
            // a string`, and closes the connection when it does.
            "jsonrpc": "2.0", "id": id, "method": method, "params": params,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        return try await withCheckedThrowingContinuation { continuation in
            Self.ioQueue.async {
                do {
                    let connection = try HerdrConnection(path: path, timeoutSeconds: timeout)
                    defer { connection.closeSocket() }
                    try connection.write(payload)
                    guard let line = try connection.readLine() else {
                        throw HerdrProtocolError.closedBeforeReply
                    }
                    continuation.resume(returning: try Self.unwrap(line))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Blocking socket work stays off the cooperative pool, so a stalled herdr
    /// cannot starve Swift concurrency's threads or freeze the menu bar.
    private static let ioQueue = DispatchQueue(
        label: "AgentHQ.herdr.io", qos: .userInitiated, attributes: .concurrent
    )

    private static func unwrap(_ line: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            throw HerdrProtocolError.malformedJSON(String(decoding: line.prefix(200), as: UTF8.self))
        }
        if let error = object["error"] as? [String: Any] {
            throw HerdrProtocolError.herdr(
                code: error["code"] as? String ?? "unknown",
                message: error["message"] as? String ?? ""
            )
        }
        return object["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Subscription

    /// Start the event subscription on a thread of its own.
    ///
    /// The read is a blocking `read(2)` with no timeout — silence between
    /// events is normal and the stream is push-based. Running that on the
    /// actor deadlocks it: the actor stays isolated inside the read forever,
    /// so every other call on this client, and on whatever owns it, waits
    /// behind an event that may never come. It cannot go on the cooperative
    /// pool either, which has a small fixed number of threads.
    private func startSubscription() {
        let path = socketPath
        nextRequestId &+= 1
        let requestId = String(nextRequestId)
        let continuation = self.continuation
        let state = subscriptionState

        let thread = Thread {
            var backoff: UInt32 = 250
            while !state.isStopped {
                do {
                    let connection = try Self.openSubscription(path: path, requestId: requestId)
                    state.adopt(connection)
                    continuation.yield(.connected)
                    backoff = 250

                    while !state.isStopped, let line = try connection.readLine() {
                        if let event = Self.decodeEvent(line) {
                            continuation.yield(event)
                        }
                    }
                } catch {
                    // fall through to backoff
                }
                state.releaseConnection()
                guard !state.isStopped else { break }
                continuation.yield(.disconnected)
                // A subscription that dies once and stays dead leaves the
                // panel showing whenever the socket hiccuped, which looks
                // exactly like a working panel.
                usleep(backoff * 1000)
                backoff = min(backoff * 2, 10_000)
            }
        }
        thread.name = "AgentHQ.herdr.events"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    private static func openSubscription(path: String, requestId: String) throws -> HerdrConnection {
        // No timeout: the stream is push-based and silence is normal.
        let connection = try HerdrConnection(path: path, timeoutSeconds: 0)
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": requestId,
            "method": "events.subscribe",
            // Objects, not strings: protocol 22 models a subscription as an
            // internally tagged enum and rejects a bare name.
            "params": ["subscriptions": globalSubscriptions.map { ["type": $0] }],
        ]
        try connection.write(try JSONSerialization.data(withJSONObject: body))
        guard let ack = try connection.readLine() else {
            throw HerdrProtocolError.closedBeforeReply
        }
        _ = try unwrap(ack)
        return connection
    }
}

// MARK: - SubscriptionState

/// Shared between the actor and its subscription thread. Lock-guarded rather
/// than actor-isolated, because the thread must be able to be told to stop
/// while the actor is busy — and because closing the fd is the only way to
/// break a blocking read.
private final class SubscriptionState: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: HerdrConnection?
    private var stopped = false

    var isStopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopped
    }

    func adopt(_ connection: HerdrConnection) {
        lock.lock(); defer { lock.unlock() }
        self.connection = connection
    }

    func releaseConnection() {
        lock.lock(); defer { lock.unlock() }
        connection?.closeSocket()
        connection = nil
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        connection?.closeSocket()
        connection = nil
    }
}
