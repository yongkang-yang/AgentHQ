import AgentHQKit
import Testing
@testable import AgentHQHerdr

/// herdr has two status enums for the same pane, and only one of them can say
/// a run finished.
@Suite("A finished run is read from the agent view, not the pane")
struct AgentViewStatusTests {
    private func pane(_ id: String, status: String) -> HerdrPane {
        HerdrPane(
            paneId: id, workspaceId: "wZ", tabId: "wZ:t1", agentStatus: status,
            agent: "pi", title: nil, cwd: "/home/me/repo", revision: 0
        )
    }

    private func snapshot(_ panes: [HerdrPane]) -> HerdrSnapshot {
        HerdrSnapshot(
            herdrVersion: "0.9.1", protocolVersion: 22,
            panes: panes, workspaceNames: ["wZ": "repo"]
        )
    }

    /// `PaneAgentState` is `idle | working | blocked | unknown`; `AgentStatus`
    /// adds `done`. A finished run therefore reaches a pane record as `idle`,
    /// and classifying from the pane alone made `.finished` unreachable.
    @Test("done on the agent view beats idle on the pane")
    func doneWins() throws {
        let agents = snapshot([pane("wZ:p2", status: "idle")]).agents(
            on: MachineID("m"),
            agentViews: ["wZ:p2": HerdrAgentInfo(
                paneId: "wZ:p2", agent: "pi", agentStatus: "done", stateChangeSeq: 758
            )]
        )
        #expect(agents.count == 1)
        #expect(agents.first?.state == .finished)
        #expect(agents.first?.stateSeq == 758)
    }

    /// The fallback has to stay: a pane with no agent-view entry is still a
    /// pane worth showing, and dropping it would empty the panel on any
    /// machine whose `agent.list` call failed.
    @Test("a pane with no agent view is classified from its own status")
    func fallsBackToPane() {
        let agents = snapshot([pane("wZ:p1", status: "working")]).agents(on: MachineID("m"))
        #expect(agents.first?.state == .working)
        #expect(agents.first?.stateSeq == nil)
    }

    /// Without this the guard in `MachineSession.perform` reads the stamp off
    /// a pane, finds nothing, and every intervention fails closed.
    @Test("an idle agent still reads as idle when the agent view agrees")
    func idleStaysIdle() {
        let agents = snapshot([pane("wZ:p1", status: "idle")]).agents(
            on: MachineID("m"),
            agentViews: ["wZ:p1": HerdrAgentInfo(
                paneId: "wZ:p1", agent: "pi", agentStatus: "idle", stateChangeSeq: 745
            )]
        )
        #expect(agents.first?.state == .idle)
        #expect(agents.first?.stateSeq == 745)
    }
}
