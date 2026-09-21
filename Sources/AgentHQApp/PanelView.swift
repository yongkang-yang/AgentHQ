import AgentHQFleet
import AgentHQKit
import SwiftUI

/// The triage desk. Three sections, most urgent first.
///
/// Skeleton: structure and vocabulary only. Visual treatment comes from the
/// token layer in DESIGN.md once it is ported.
struct PanelView: View {
    let fleet: FleetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("AgentHQ")
                .font(.system(size: 15, weight: .bold))

            if fleet.snapshot.machines.isEmpty {
                Text("No machines configured.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(AttentionGroup.allCases, id: \.rawValue) { group in
                    let agents = fleet.snapshot.agents(in: group)
                    if !agents.isEmpty {
                        Section(group.title, agents: agents)
                    }
                }
                UnreachableMachines(snapshot: fleet.snapshot)
            }
        }
        .padding(14)
        .frame(width: 500)
    }
}

private struct Section: View {
    let title: String
    let agents: [Agent]

    init(_ title: String, agents: [Agent]) {
        self.title = title
        self.agents = agents
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            ForEach(agents) { agent in
                AgentRow(agent: agent)
            }
        }
    }
}

private struct AgentRow: View {
    let agent: Agent

    var body: some View {
        HStack(spacing: 8) {
            Text(agent.provider)
                .font(.system(size: 13.5, weight: .semibold))
            Text(agent.workspace)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
            Spacer()
            // The machine is on every row. In a fleet, "which box is this on"
            // is part of the agent's identity, not a detail behind a disclosure.
            Text(agent.ref.machine.raw.prefix(8))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(agent.state.rawValue)
                .font(.system(size: 10.5, weight: .semibold))
        }
    }
}

/// A machine AgentHQ cannot reach is reported as exactly that — not as its
/// agents having died.
private struct UnreachableMachines: View {
    let snapshot: FleetSnapshot

    var body: some View {
        let down = snapshot.machines.filter {
            if case .unreachable = $0.reachability { return true }
            return false
        }
        if !down.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(down) { view in
                    if case .unreachable(let reason) = view.reachability {
                        Text("\(view.machine.displayName) unreachable — \(reason)")
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }
}
