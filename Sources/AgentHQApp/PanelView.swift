import AgentHQFleet
import AgentHQKit
import SwiftUI

/// The triage desk. Three sections, most urgent first.
///
/// Grouped by attention and labelled by machine, never the reverse: a blocked
/// agent has to be findable regardless of which host it is on.
struct PanelView: View {
    let fleet: FleetStore
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Rows show the name the user gave a machine in herdr, not its id.
    private var machineNames: [MachineID: String] {
        Dictionary(
            fleet.snapshot.machines.map { ($0.machine.id, $0.machine.displayName) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if fleet.snapshot.machines.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(AttentionGroup.allCases, id: \.rawValue) { group in
                            let agents = fleet.snapshot.agents(in: group, now: now)
                            if !agents.isEmpty {
                                GroupSection(
                                    title: group.title,
                                    agents: agents,
                                    machineNames: machineNames,
                                    now: now
                                )
                            }
                        }
                    }
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 460)

                if fleet.snapshot.allAgents.isEmpty {
                    Text("No agents running.")
                        .font(Brand.body)
                        .foregroundStyle(Brand.secondaryText)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }

            Divider()
            footer
        }
        .frame(width: 460)
        .onReceive(tick) { now = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("AgentHQ").font(Brand.title)
            Spacer()
            let signal = fleet.signal
            if signal.attentionCount > 0 {
                Text("\(signal.attentionCount) need you")
                    .font(Brand.sectionLabel)
                    .foregroundStyle(Brand.color(for: signal.topState ?? .unknown))
            } else if signal.workingCount > 0 {
                Text("\(signal.workingCount) working")
                    .font(Brand.sectionLabel)
                    .foregroundStyle(Brand.secondaryText)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No machines.").font(Brand.body)
            Text("Machines come from herdr. Add one with `herdr machine add`, or start herdr on this Mac.")
                .font(Brand.body)
                .foregroundStyle(Brand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
    }

    /// Machine-level state lives here, apart from the agents, because an
    /// unreachable machine is a different problem from a stuck agent.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(fleet.snapshot.machines) { view in
                HStack(spacing: 6) {
                    Circle()
                        .fill(view.reachability.isConnected
                              ? Brand.color(for: .working)
                              : Brand.machineDown)
                        .frame(width: 6, height: 6)
                    Text(view.machine.displayName).font(Brand.mono)
                    Text(reachabilityText(view.reachability))
                        .font(Brand.sectionLabel)
                        .foregroundStyle(view.reachability.isConnected
                                         ? Brand.secondaryText : Brand.machineDown)
                    Spacer()
                    Text("\(view.agents.count)")
                        .font(Brand.mono)
                        .foregroundStyle(Brand.secondaryText)
                }
            }

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(Brand.body)
                    .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func reachabilityText(_ reachability: MachineReachability) -> String {
        switch reachability {
        case .connected:              return "connected"
        case .connecting:             return "connecting…"
        case .disabled:               return "disabled"
        case .reconnecting(let n):    return "reconnecting (\(n))"
        // Verbatim, never summarized: "unreachable" alone tells the user
        // nothing they can act on.
        case .unreachable(let reason): return reason
        }
    }
}

private struct GroupSection: View {
    let title: String
    let agents: [Agent]
    let machineNames: [MachineID: String]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(Brand.sectionLabel)
                .tracking(0.5)
                .foregroundStyle(Brand.secondaryText)
                .padding(.horizontal, 14)

            ForEach(agents) { agent in
                AgentRow(
                    agent: agent,
                    machineName: machineNames[agent.ref.machine] ?? String(agent.ref.machine.raw.prefix(8)),
                    now: now
                )
                    .padding(.horizontal, 14)
            }
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    let machineName: String
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // The status rail. Colour is the state; a fluent reader takes in
            // the herd's health without reading a word.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Brand.color(for: agent.state))
                .frame(width: 3.5)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: Brand.symbol(for: agent.state))
                        .font(.system(size: 10))
                        .foregroundStyle(Brand.color(for: agent.state))
                    Text(agent.provider).font(Brand.agentName)
                    Text(agent.workspace)
                        .font(Brand.body)
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(DwellFormatter.short(agent.dwell(now: now)))
                        .font(Brand.mono)
                        .foregroundStyle(Brand.secondaryText)
                }

                HStack(spacing: 6) {
                    Text(Brand.label(for: agent.state).uppercased())
                        .font(Brand.sectionLabel)
                        .tracking(0.4)
                        .foregroundStyle(Brand.color(for: agent.state))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(
                            Capsule().fill(Brand.color(for: agent.state).opacity(0.14))
                        )
                    // The machine is on every row, in mono: in a fleet, which
                    // box this is on is part of the agent's identity.
                    Text(machineName)
                        .font(Brand.mono)
                        .foregroundStyle(Brand.secondaryText)
                }

                if let reason = agent.reason {
                    Text(reason)
                        .font(Brand.body)
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
    }
}
