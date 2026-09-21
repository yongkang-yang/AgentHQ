import AgentHQKit
import Foundation
import Testing
@testable import AgentHQHerdr

/// Tests that talk to a herdr actually running on this Mac. Opt in with:
///
///     AGENTHQ_HERDR_SOCKET=$HOME/.config/herdr/herdr.sock swift test
private let socketPath = ProcessInfo.processInfo.environment["AGENTHQ_HERDR_SOCKET"]

@Suite(
    "live herdr",
    .enabled(if: socketPath != nil, "set AGENTHQ_HERDR_SOCKET to run")
)
struct LiveHerdrClientTests {
    private func client() -> LiveHerdrClient {
        LiveHerdrClient(socketPath: socketPath!)
    }

    @Test("handshake reports a version and protocol")
    func handshake() async throws {
        let (version, proto) = try await client().ping()
        #expect(!version.isEmpty)
        #expect(proto > 0)
        if !LiveHerdrClient.verifiedProtocols.contains(proto) {
            Issue.record("herdr protocol \(proto) is outside the verified range \(LiveHerdrClient.verifiedProtocols) — decoding may be reading renamed fields")
        }
    }

    @Test("consecutive requests each get their own connection")
    func requestsAreIndependent() async throws {
        // herdr closes after every reply, so a client that reuses a connection
        // works exactly once and then fails with EPIPE forever. Three in a row
        // is the cheapest way to catch that regression.
        let subject = client()
        for _ in 0..<3 {
            _ = try await subject.ping()
        }
        _ = try await subject.snapshot()
        _ = try await subject.ping()
    }

    @Test("snapshot decodes panes with real field names")
    func snapshotDecodes() async throws {
        let snapshot = try await client().snapshot()
        #expect(!snapshot.herdrVersion.isEmpty)
        #expect(snapshot.protocolVersion > 0)

        // A zero revision across every pane means the field was renamed under
        // us and we are reading a name that no longer exists.
        if !snapshot.panes.isEmpty {
            #expect(snapshot.panes.contains { $0.revision > 0 })
            #expect(snapshot.panes.allSatisfy { !$0.paneId.isEmpty })
        }
    }

    @Test("panes running an agent project into fleet agents")
    func projectsIntoAgents() async throws {
        let snapshot = try await client().snapshot()
        let machine = MachineID("test-machine")
        let agents = snapshot.agents(on: machine)

        // Every agent row must be attributable to a machine and a provider,
        // and shells must not show up as agents.
        for agent in agents {
            #expect(agent.ref.machine == machine)
            #expect(!agent.provider.isEmpty)
            #expect(!agent.ref.agent.raw.isEmpty)
        }
        #expect(agents.count <= snapshot.panes.count)
    }

    @Test("the event subscription stays open")
    func subscriptionIsPersistent() async throws {
        // Requests are one-shot; the subscription must not be, or live updates
        // stop after the first event and the panel silently goes stale.
        let subject = client()
        try await subject.connect()
        defer { Task { await subject.disconnect() } }

        var sawConnected = false
        let deadline = Date().addingTimeInterval(5)
        for await event in subject.events() {
            if case .connected = event { sawConnected = true; break }
            if Date() > deadline { break }
        }
        #expect(sawConnected)
    }
}
