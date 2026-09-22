import AgentHQKit
import Testing
@testable import AgentHQApp

@Suite("Every machine wears the same chip every launch")
struct MachineColorTests {
    @Test("the same machine id always picks the same colour")
    func stable() {
        let id = MachineID("agenthq-local")
        #expect(Brand.machineColorIndex(for: id) == Brand.machineColorIndex(for: id))
    }

    @Test("real machine ids do not all collide")
    func realIdsSpread() {
        // The bug the splitmix64 finalizer pays for: plain FNV-1a put all
        // three of these on chip 7, so every machine looked alike.
        let ids = [
            MachineID("agenthq-local"),
            MachineID("822f3f7c5aefc1d1b873d31c7dd04e35"),
            MachineID("3820f198aa41e67920f90e8eb4217c2c"),
        ]
        let indices = Set(ids.map(Brand.machineColorIndex(for:)))
        #expect(indices.count == ids.count)
    }

    @Test("an index always lands inside the palette")
    func inRange() {
        for id in ["", "a", "agenthq-local", String(repeating: "x", count: 200)] {
            let index = Brand.machineColorIndex(for: MachineID(id))
            #expect(Brand.machinePalette.indices.contains(index))
        }
    }

    @Test("the same machine id gives the same stable index across calls")
    func stableIndex() {
        let value = "agenthq-local:wC:p5"
        #expect(Brand.stableIndex(value, modulo: 10) == Brand.stableIndex(value, modulo: 10))
        #expect((0..<10).contains(Brand.stableIndex(value, modulo: 10)))
    }
}
