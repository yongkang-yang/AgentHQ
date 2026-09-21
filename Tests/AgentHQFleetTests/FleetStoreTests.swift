import AgentHQKit
import Foundation
import Testing
@testable import AgentHQFleet

@Suite("FleetStore")
@MainActor
struct FleetStoreTests {
    private func machine(_ name: String) -> Machine {
        Machine(displayName: name, transport: .local(socketPath: "/tmp/\(name).sock"))
    }

    @Test("an empty store has no signal")
    func emptyStore() {
        #expect(FleetStore().signal == .empty)
    }

    @Test("machines appear in the snapshot sorted by display name")
    func snapshotIsSorted() async {
        let store = FleetStore()
        store.add(machine("zulu"))
        store.add(machine("alpha"))
        await store.refresh()

        #expect(store.snapshot.machines.map(\.machine.displayName) == ["alpha", "zulu"])
    }

    @Test("a removed machine leaves the snapshot")
    func removal() async {
        let store = FleetStore()
        let m = machine("laptop")
        store.add(m)
        await store.refresh()
        #expect(store.snapshot.machines.count == 1)

        store.remove(m.id)
        await store.refresh()
        #expect(store.snapshot.machines.isEmpty)
    }

    @Test("a disabled machine reports as disabled, not unreachable")
    func disabledMachine() async {
        let store = FleetStore()
        var m = machine("spare")
        m.isEnabled = false
        store.add(m)
        await store.refresh()

        #expect(store.snapshot.machines.first?.reachability == .disabled)
        #expect(store.signal.isDegraded == false)
    }
}
