import AgentHQKit
import Foundation
import Testing
@testable import AgentHQHerdr

@Suite("A pane's model comes from reported metadata, never from a guess")
struct PaneModelTests {
    private func pane(_ tokens: [String: String]) -> HerdrPane {
        HerdrPane(
            paneId: "w:p1", workspaceId: "w", tabId: "w:t1",
            agentStatus: "idle", agent: "pi", title: "π - repo",
            cwd: "/tmp", tokens: tokens, revision: 0
        )
    }

    @Test("the quota reporter's model token names the model")
    func quotaModel() {
        // Measured on the local machine: the pi pane reported this pair.
        let pane = pane([
            "quota_provider": "opencode-go",
            "quota_model": "deepseek-v4.1-flash",
            "quota_provider_model": "opencode-go/deepseek-v4.1-flash",
        ])
        #expect(pane.model == "deepseek-v4.1-flash")
    }

    @Test("a first-party model token wins over the quota reporter's")
    func bareModelWins() {
        let pane = pane(["model": "claude-opus-4-6", "quota_model": "deepseek-v4.1-flash"])
        #expect(pane.model == "claude-opus-4-6")
    }

    @Test("a provider-qualified token is not a model on its own")
    func providerQualifiedIsNotAModel() {
        // "Codex/gpt-5.6-luna" is an identity, not a model name; without a bare
        // model token the honest answer is no model.
        let pane = pane(["quota_provider_model": "Codex/gpt-5.6-luna"])
        #expect(pane.model == nil)
    }

    @Test("a blank or whitespace token is no model at all")
    func blankIsNil() {
        #expect(pane(["quota_model": ""]).model == nil)
        #expect(pane(["quota_model": "   "]).model == nil)
        #expect(pane([:]).model == nil)
    }

    @Test("the model reaches the agent row")
    func reachesTheRow() {
        let snapshot = HerdrSnapshot(
            herdrVersion: "0.9.0", protocolVersion: 22,
            panes: [pane(["quota_model": "gpt-5.6-luna"])],
            workspaceNames: ["w": "repo"]
        )
        let agents = snapshot.agents(on: MachineID("m"))
        #expect(agents.first?.model == "gpt-5.6-luna")
    }
}
