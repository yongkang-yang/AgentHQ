import AgentHQKit
import Foundation
import Testing
@testable import AgentHQTransport

/// Tests that spend real ssh connections. Opt in with:
///
///     AGENTHQ_SSH_HOST=<ssh config alias> swift test
///
/// Off by default so an ordinary `swift test` never reaches the network.
private let sshHost = ProcessInfo.processInfo.environment["AGENTHQ_SSH_HOST"]

@Suite(
    "ssh tunnel against a real host",
    .enabled(if: sshHost != nil, "set AGENTHQ_SSH_HOST to run")
)
struct SSHTunnelIntegrationTests {
    private func tunnel(
        remote: String,
        local: String,
        timeout: TimeInterval = 12
    ) -> SSHTunnel {
        SSHTunnel(
            machine: .generate(),
            destination: sshHost!,
            port: nil,
            remoteSocketPath: remote,
            localSocketPath: local,
            readinessTimeout: timeout
        )
    }

    @Test("a forward to a socket that does not exist fails instead of looking connected")
    func deadFarSideIsNotReady() async throws {
        // The regression this whole probe exists for. `ssh -L` binds the local
        // socket immediately and `connect(2)` succeeds against it even when the
        // far side is missing; only a read reveals the truth. If this ever
        // passes activation, every machine with herdr stopped will show as
        // connected with an empty agent list.
        let local = "/tmp/agenthq-\(getuid())/itest-dead.sock"
        let subject = tunnel(remote: "/tmp/agenthq-definitely-not-here.sock", local: local)

        let started = Date()
        await #expect(throws: TransportError.self) {
            _ = try await subject.activate()
        }
        // And it says so quickly. A machine whose herdr is stopped must not
        // take the full readiness timeout to report that.
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(await subject.isHealthy() == false)
        await subject.deactivate()
        #expect(!FileManager.default.fileExists(atPath: local))
    }

    @Test("an unknown destination fails fast rather than hanging on a prompt")
    func unknownHostFailsFast() async throws {
        let subject = SSHTunnel(
            machine: .generate(),
            destination: "agenthq-no-such-host.invalid",
            port: nil,
            remoteSocketPath: "/tmp/whatever.sock",
            localSocketPath: "/tmp/agenthq-\(getuid())/itest-nohost.sock",
            readinessTimeout: 12
        )
        let started = Date()
        await #expect(throws: TransportError.self) {
            _ = try await subject.activate()
        }
        // BatchMode is what keeps this from sitting on a password prompt with
        // no tty to type into.
        #expect(Date().timeIntervalSince(started) < 12)
        await subject.deactivate()
    }
}
