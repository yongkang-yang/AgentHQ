import AgentHQKit
import Foundation
import Testing
@testable import AgentHQTransport

@Suite("ssh command")
struct SSHArgumentTests {
    private func args(port: Int? = nil) -> [String] {
        SSHTunnel.arguments(
            destination: "build-box",
            port: port,
            local: "/tmp/agenthq-501/ab12cd34.sock",
            remote: "/home/yk/.config/herdr/herdr.sock"
        )
    }

    @Test("forwards the remote socket onto the local one")
    func forwardSpec() {
        let a = args()
        let index = try! #require(a.firstIndex(of: "-L"))
        #expect(a[index + 1] == "/tmp/agenthq-501/ab12cd34.sock:/home/yk/.config/herdr/herdr.sock")
    }

    @Test("fails loudly when the forward cannot be set up")
    func exitsOnForwardFailure() {
        // Without this, ssh stays up after a failed forward and the machine
        // looks connected while every request to its socket is refused.
        #expect(args().contains("ExitOnForwardFailure=yes"))
    }

    @Test("clears a stale socket file from a previous run")
    func unlinksStaleSocket() {
        #expect(args().contains("StreamLocalBindUnlink=yes"))
    }

    @Test("never prompts")
    func batchMode() {
        // There is no tty to prompt on; a hidden prompt reads as a hang.
        #expect(args().contains("BatchMode=yes"))
    }

    @Test("detects a dead link instead of hanging")
    func keepalive() {
        #expect(args().contains("ServerAliveInterval=15"))
        #expect(args().contains("ServerAliveCountMax=3"))
    }

    @Test("runs no remote command")
    func forwardOnly() {
        #expect(args().contains("-N"))
        #expect(args().contains("-T"))
    }

    @Test("destination comes last so ssh parses the options")
    func destinationIsLast() {
        #expect(args().last == "build-box")
        #expect(args(port: 2222).last == "build-box")
    }

    @Test("port is omitted unless overridden")
    func portOverride() {
        #expect(!args().contains("-p"))
        let withPort = args(port: 2222)
        let index = try! #require(withPort.firstIndex(of: "-p"))
        #expect(withPort[index + 1] == "2222")
    }
}

@Suite("socket paths")
struct SocketPathTests {
    @Test("forwarded paths stay well under the sun_path limit")
    func forwardedPathFits() throws {
        let path = SocketPath.forwarded(machine: MachineID("7F3A9C21-4B5D-4E6F-8A1B-2C3D4E5F6071"), uid: 501)
        #expect(path.utf8.count <= SocketPath.maxBytes)
        try SocketPath.validate(path)
    }

    @Test("an over-long path is rejected before connect(2) sees it")
    func overLongPathRejected() {
        // connect(2) fails on an over-long path with an error that looks like
        // an unreachable socket, so it is caught here instead.
        let long = "/tmp/" + String(repeating: "x", count: 200) + ".sock"
        #expect(throws: TransportError.self) {
            try SocketPath.validate(long)
        }
    }

    @Test("the tunnel directory is per-user")
    func tunnelDirectoryIsScoped() {
        #expect(SocketPath.tunnelDirectory(uid: 501) == "/tmp/agenthq-501")
        #expect(SocketPath.tunnelDirectory(uid: 502) != SocketPath.tunnelDirectory(uid: 501))
    }
}

@Suite("local transport")
struct LocalSocketTransportTests {
    @Test("an explicit override wins")
    func explicitOverride() {
        let path = LocalSocketTransport.resolveDefaultSocketPath(
            environment: ["HERDR_SOCKET_PATH": "/custom/herdr.sock"],
            home: "/Users/test"
        )
        #expect(path == "/custom/herdr.sock")
    }

    @Test("XDG_CONFIG_HOME is honoured before the default")
    func xdgConfigHome() {
        let path = LocalSocketTransport.resolveDefaultSocketPath(
            environment: ["XDG_CONFIG_HOME": "/Users/test/.xdg"],
            home: "/Users/test"
        )
        #expect(path == "/Users/test/.xdg/herdr/herdr.sock")
    }

    @Test("falls back to ~/.config/herdr/herdr.sock")
    func defaultPath() {
        let path = LocalSocketTransport.resolveDefaultSocketPath(
            environment: [:], home: "/Users/test"
        )
        #expect(path == "/Users/test/.config/herdr/herdr.sock")
    }

    @Test("local transport hands back its path unchanged")
    func passthrough() async throws {
        let transport = LocalSocketTransport(socketPath: "/tmp/herdr.sock")
        #expect(try await transport.activate() == "/tmp/herdr.sock")
    }
}
