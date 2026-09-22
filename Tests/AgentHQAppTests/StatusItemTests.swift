import AgentHQKit
import SwiftUI
import Testing
@testable import AgentHQApp

@Suite("The status item's label renders to an image")
struct MenuBarLabelTests {
    @Test("a signal renders to a non-empty image the bar can tint")
    @MainActor
    func renders() throws {
        let signal = FleetSignal(
            topState: .needsApproval, attentionCount: 3,
            workingCount: 0, unreachableMachineCount: 1
        )
        let renderer = ImageRenderer(content: MenuBarLabel(signal: signal))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test("a resting fleet draws the mark alone — no badge, no count")
    @MainActor
    func restingIsNarrower() throws {
        func width(_ signal: FleetSignal) throws -> CGFloat {
            let renderer = ImageRenderer(content: MenuBarLabel(signal: signal))
            renderer.scale = 2
            return try #require(renderer.nsImage).size.width
        }

        let ref = AgentRef(machine: MachineID("m"), agent: AgentID("w:p1"))
        let idle = FleetSignal(
            topState: .idle, attentionCount: 0, workingCount: 0,
            unreachableMachineCount: 0,
            menuBarAgents: [MenuBarAgent(ref: ref, state: .idle)]
        )
        let busy = FleetSignal(
            topState: .needsInput, attentionCount: 1, workingCount: 0,
            unreachableMachineCount: 0,
            menuBarAgents: [MenuBarAgent(ref: ref, state: .needsInput)]
        )
        #expect(try width(idle) < width(busy))
    }

    @Test("an empty fleet still draws a symbol")
    @MainActor
    func emptyRenders() throws {
        let renderer = ImageRenderer(content: MenuBarLabel(signal: .empty))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0)
    }

    @Test("a fleet of conversations renders an icon and count per state")
    @MainActor
    func rendersStateCounts() throws {
        let agents = (0..<12).map { index in
            MenuBarAgent(
                ref: AgentRef(machine: MachineID("m"), agent: AgentID("w:p\(index)")),
                state: index < 2 ? .needsApproval : .working
            )
        }
        let signal = FleetSignal(
            topState: .needsApproval, attentionCount: 2, workingCount: 10,
            unreachableMachineCount: 1, menuBarAgents: agents
        )
        let renderer = ImageRenderer(content: MenuBarLabel(signal: signal))
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}

@Suite("A notification click names one agent to land on")
struct PanelFocusTests {
    @Test("each focus is a new event, even for the same agent")
    @MainActor
    func nonceAdvances() {
        let focus = PanelFocus()
        let ref = AgentRef(machine: MachineID("m"), agent: AgentID("w:p1"))
        focus.focus(ref)
        let first = focus.nonce
        focus.focus(ref)
        #expect(focus.nonce == first + 1)
        #expect(focus.ref == ref)
    }

    @Test("a batch click clears the focus rather than landing somewhere wrong")
    @MainActor
    func nilFocus() {
        let focus = PanelFocus()
        focus.focus(AgentRef(machine: MachineID("m"), agent: AgentID("w:p1")))
        focus.focus(nil)
        #expect(focus.ref == nil)
    }
}
