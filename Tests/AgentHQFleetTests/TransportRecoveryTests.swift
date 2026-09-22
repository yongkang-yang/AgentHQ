import AgentHQHerdr
import AgentHQKit
import AgentHQTransport
import Foundation
import Testing
@testable import AgentHQFleet

/// A transport whose health the test controls, and which counts how many times
/// it was brought up.
///
/// The count is the whole assertion. "The machine came back" is observable
/// from the session's reachability, but *how* it came back is not — and the
/// bug this suite defends against was a session that reconnected its
/// subscription forever without ever relaunching the thing underneath it.
private actor ScriptedTransport: Transport {
    private(set) var activations = 0
    private(set) var deactivations = 0
    private var healthy: Bool
    private var failures: Int

    /// - Parameters:
    ///   - healthy: what ``isHealthy()`` reports until told otherwise.
    ///   - failures: how many `activate` calls throw before one succeeds.
    init(healthy: Bool = true, failures: Int = 0) {
        self.healthy = healthy
        self.failures = failures
    }

    func setHealthy(_ value: Bool) { healthy = value }
    func heal() { failures = 0; healthy = true }

    func activate() async throws -> String {
        activations += 1
        if failures > 0 {
            failures -= 1
            throw TransportError.tunnelLaunchFailed(reason: "wsl is not on this network")
        }
        return "/tmp/agenthq-recovery-test.sock"
    }

    func deactivate() async { deactivations += 1 }
    func isHealthy() -> Bool { healthy }
}

/// A client that serves one working agent and lets the test drive its events.
private actor RecoveryClient: HerdrClient {
    private let continuation: AsyncStream<HerdrEvent>.Continuation
    private let stream: AsyncStream<HerdrEvent>

    init() {
        var cont: AsyncStream<HerdrEvent>.Continuation!
        stream = AsyncStream { cont = $0 }
        continuation = cont
    }

    func emit(_ event: HerdrEvent) { continuation.yield(event) }

    func handshake() async throws -> (version: String, protocolVersion: Int) { ("0.9.1", 22) }
    func connect() async throws {}
    func disconnect() async {}

    func snapshot() async throws -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: [HerdrPane(
                paneId: "w:p1", workspaceId: "w", tabId: "w:t1",
                agentStatus: "working", agent: "pi",
                title: nil, cwd: nil, revision: 0
            )],
            workspaceNames: [:]
        )
    }

    nonisolated func events() -> AsyncStream<HerdrEvent> { stream }
    func readPane(paneId: String, lines: Int, source: PaneReadSource) async throws -> String? { nil }
    func agents() async throws -> [HerdrAgentInfo] {
        [HerdrAgentInfo(paneId: "w:p1", agent: "pi", agentStatus: "working", stateChangeSeq: 1)]
    }
    func agent(paneId: String) async throws -> HerdrAgentInfo? {
        HerdrAgentInfo(paneId: "w:p1", agent: "pi", agentStatus: "working", stateChangeSeq: 1)
    }
    func sendKeys(paneId: String, keys: [String]) async throws {}
    func sendText(paneId: String, text: String) async throws {}
    func prompt(paneId: String, text: String) async throws {}
    func interrupt(paneId: String) async throws {}
    func focusPane(paneId: String) async throws {}
}

@Suite("A machine recovers from its transport dying under it")
struct TransportRecoveryTests {
    private let machine = Machine(
        id: MachineID("wsl"), displayName: "wsl",
        transport: .ssh(destination: "wsl", port: nil, session: "default", remoteSocketPath: "/r.sock")
    )

    /// Long enough for a few supervisor ticks at the interval the tests use.
    private func settle(_ ms: Int = 260) async throws {
        try await Task.sleep(for: .milliseconds(ms))
    }

    private func session(
        transport: ScriptedTransport,
        client: RecoveryClient
    ) -> MachineSession {
        MachineSession(
            machine: machine,
            makeClient: { _ in client },
            transport: transport,
            supervisionInterval: .milliseconds(50)
        )
    }

    /// The reported bug. `ssh` dies with the network, the client resubscribes
    /// to a socket with nothing behind it forever, and the session sits in
    /// `reconnecting` until the app is quit and relaunched — because `activate`
    /// ran once, inside `start`.
    @Test("a machine whose tunnel died is relaunched, not just resubscribed")
    func rebuildsADeadTunnel() async throws {
        let transport = ScriptedTransport()
        let client = RecoveryClient()
        let session = session(transport: transport, client: client)

        await session.start()
        try await settle(60)
        #expect(await session.view().reachability == .connected)
        #expect(await transport.activations == 1)

        // The network changes: ssh exits, the subscription's read ends.
        await transport.setHealthy(false)
        await client.emit(.disconnected)
        try await settle()

        #expect(await transport.activations > 1)
        #expect(await session.view().reachability == .connected)
        #expect(await session.view().agents.first?.state == .working)
        await session.stop()
    }

    /// The cheap recovery must survive this fix. A herd restarting on the far
    /// side drops the subscription while the tunnel stays up, and the client
    /// resubscribes over it without a process being spawned.
    @Test("a reconnect over a live tunnel does not relaunch it")
    func leavesALiveTunnelAlone() async throws {
        let transport = ScriptedTransport(healthy: true)
        let client = RecoveryClient()
        let session = session(transport: transport, client: client)

        await session.start()
        try await settle(60)

        await client.emit(.disconnected)
        try await settle()

        #expect(await transport.activations == 1)
        #expect(await transport.deactivations == 0)
        await session.stop()
    }

    /// A machine that was unreachable at launch — the laptop opened somewhere
    /// the host is not yet routable — used to stay unreachable until the user
    /// pressed Retry, which is the same bug seen from the other end.
    @Test("a machine that was down at launch is picked up once it answers")
    func retriesAFailedFirstConnect() async throws {
        let transport = ScriptedTransport(healthy: false, failures: 2)
        let client = RecoveryClient()
        let session = session(transport: transport, client: client)

        await session.start()
        if case .unreachable = await session.view().reachability {} else {
            Issue.record("expected the first connect to fail")
        }

        await transport.heal()
        try await settle(400)

        #expect(await session.view().reachability == .connected)
        #expect(await session.view().agents.count == 1)
        await session.stop()
    }

    /// `stop` has to take the supervisor with it. A supervisor left running
    /// would relaunch the tunnel the user just closed.
    @Test("stopping a machine stops it supervising itself")
    func stopEndsSupervision() async throws {
        let transport = ScriptedTransport()
        let client = RecoveryClient()
        let session = session(transport: transport, client: client)

        await session.start()
        try await settle(60)
        await session.stop()

        let activations = await transport.activations
        try await settle(400)
        #expect(await transport.activations == activations)
    }
}
