import Foundation
import Testing
@testable import AgentHQKit

@Suite("An agent's project is where it is, not the workspace it is grouped in")
struct AgentProjectTests {
    private func agent(workspace: String, directory: String) -> Agent {
        Agent(
            ref: AgentRef(machine: MachineID("m"), agent: AgentID("wC:p5")),
            provider: "pi",
            workspace: workspace,
            directory: directory
        )
    }

    @Test("the working directory names the row when it differs from the workspace")
    func directoryWins() {
        // Measured: one workspace labeled RainNext held a RainNext pane and an
        // AgentHQ pane, so the label named the second one wrongly.
        let agent = agent(workspace: "RainNext", directory: "/Users/me/Code/AgentHQ")
        #expect(agent.project == "AgentHQ")
    }

    @Test("the workspace label is the fallback when herdr reports no directory")
    func workspaceFallsBack() {
        #expect(agent(workspace: "RainNext", directory: "").project == "RainNext")
    }

    @Test("a trailing slash does not make the row name empty")
    func trailingSlash() {
        #expect(agent(workspace: "RainNext", directory: "/Users/me/Code/AgentHQ/").project == "AgentHQ")
    }

    @Test("a bare root falls back rather than naming every such row a slash")
    func rootFallsBack() {
        #expect(agent(workspace: "RainNext", directory: "/").project == "RainNext")
    }
}
