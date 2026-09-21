import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

private let sshHost = ProcessInfo.processInfo.environment["AGENTHQ_SSH_HOST"]
private let remoteSocket = ProcessInfo.processInfo.environment["AGENTHQ_REMOTE_SOCKET"]

/// The milestone-2 claim, end to end: a machine that is not this one, reached
/// over SSH, showing up in the fleet with live state.
///
///     AGENTHQ_SSH_HOST=wsl \
///     AGENTHQ_REMOTE_SOCKET=/home/you/.config/herdr/herdr.sock \
///     swift test
@Suite(
    "a remote machine in the fleet",
    .enabled(if: sshHost != nil && remoteSocket != nil,
             "set AGENTHQ_SSH_HOST and AGENTHQ_REMOTE_SOCKET to run")
)
struct RemoteMachineTests {
    private let machine = Machine(
        displayName: "remote",
        transport: .ssh(
            destination: sshHost ?? "",
            port: nil,
            remoteSocketPath: remoteSocket ?? ""
        )
    )

    @Test("connects over ssh and reads the remote herd")
    func remoteMachineConnects() async throws {
        let session = MachineSession(machine: machine)
        await session.start()
        defer { Task { await session.stop() } }

        let view = await session.view()
        if case .unreachable(let reason) = view.reachability {
            Issue.record("remote machine unreachable: \(reason)")
            return
        }
        #expect(view.reachability == .connected)
        #expect(!view.agentsAreStale)

        // Whatever is over there is attributed to the remote machine, not to
        // this one. This is the assertion the whole AgentRef design exists for.
        for agent in view.agents {
            #expect(agent.ref.machine == machine.id)
        }
    }

    @Test("a remote and a local machine coexist without colliding")
    func remoteAndLocalCoexist() async throws {
        // herdr numbers panes per host, so two machines will hand out the same
        // pane ids. If AgentRef were a joined string, or if AgentID alone were
        // the key, one machine's agents would silently overwrite the other's.
        guard let localSocket = ProcessInfo.processInfo.environment["AGENTHQ_HERDR_SOCKET"] else {
            return
        }
        let local = Machine(displayName: "this mac", transport: .local(socketPath: localSocket))

        let remoteSession = MachineSession(machine: machine)
        let localSession = MachineSession(machine: local)
        await remoteSession.start()
        await localSession.start()
        defer { Task { await remoteSession.stop(); await localSession.stop() } }

        let views = [await remoteSession.view(), await localSession.view()]
        let snapshot = FleetSnapshot(machines: views)

        let refs = snapshot.allAgents.map(\.ref)
        #expect(Set(refs).count == refs.count, "agent refs collided across machines")

        let machineIds = Set(snapshot.allAgents.map(\.ref.machine))
        #expect(machineIds.count <= 2)
        #expect(snapshot.signal.unreachableMachineCount == 0)
    }
}
