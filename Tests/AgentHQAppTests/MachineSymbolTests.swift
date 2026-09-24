import AgentHQKit
import AppKit
import Testing
@testable import AgentHQApp

@Suite("Each machine in the bar has a glyph of its own")
struct MachineSymbolTests {
    private func remote(_ name: String, destination: String? = nil) -> MachineView {
        MachineView(
            machine: Machine(
                id: MachineID(name), displayName: name,
                transport: .ssh(destination: destination ?? name, port: nil, session: "default", remoteSocketPath: nil)
            ),
            reachability: .connected, agents: []
        )
    }

    private let local = MachineView(
        machine: Machine(id: MachineID("local"), displayName: "This Mac", transport: .local(socketPath: "/tmp/h.sock")),
        reachability: .connected, agents: []
    )

    @Test("this Mac is a laptop and a WSL machine is a PC")
    @MainActor
    func knownKinds() {
        let wsl = remote("box", destination: "me@wsl-host")
        let symbols = MachineView.symbols(for: [local, wsl])
        #expect(symbols[local.id] == "laptopcomputer")
        #expect(symbols[wsl.id] == "pc")
    }

    @Test("two remote machines never share a glyph")
    @MainActor
    func remotesAreDistinct() {
        let machines = [local, remote("cursor"), remote("build"), remote("wsl")]
        let symbols = MachineView.symbols(for: machines)
        #expect(Set(symbols.values).count == machines.count)
    }

    @Test("every glyph the bar can draw is a real SF Symbol")
    @MainActor
    func symbolsResolve() {
        let machines = [local] + (0..<8).map { remote("m\($0)") } + [remote("wsl")]
        for name in Set(MachineView.symbols(for: machines).values) {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil, "\(name)")
        }
    }
}
