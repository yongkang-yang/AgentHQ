import AgentHQFleet
import AgentHQKit
import SwiftUI

/// The triage desk. Three sections, most urgent first.
///
/// Grouped by attention and labelled by machine, never the reverse: a blocked
/// agent has to be findable regardless of which host it is on.
struct PanelView: View {
    let fleet: FleetStore
    let notifier: Notifier
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Rows need the machine itself, not just its name: whether it is remote
    /// changes what "reveal" can honestly claim to have done.
    private var machines: [MachineID: Machine] {
        Dictionary(
            fleet.snapshot.machines.map { ($0.machine.id, $0.machine) },
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
                                    machines: machines,
                                    now: now,
                                    fleet: fleet
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
                MachineRow(view: view, fleet: fleet)
            }

            HStack(spacing: 8) {
                Toggle("Notify", isOn: Binding(
                    get: { notifier.isEnabled },
                    set: { notifier.isEnabled = $0 }
                ))
                .toggleStyle(.checkbox)
                .font(Brand.body)
                .help("Notify when an agent needs you, or a machine stops answering")
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .font(Brand.body)
                    .keyboardShortcut("q")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

}

/// One machine: whether it is answering, what it is running, and the two
/// things the user can actually do about it.
private struct MachineRow: View {
    let view: MachineView
    let fleet: FleetStore

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(dotColor)
                .frame(width: 6, height: 6)
            Text(view.machine.displayName).font(Brand.mono)

            Text(statusText)
                .font(Brand.sectionLabel)
                .foregroundStyle(isDown ? Brand.machineDown : Brand.secondaryText)
                .lineLimit(1)
                .help(statusText)

            if let version = view.herdrVersion, view.reachability.isConnected {
                Text("herdr \(version)")
                    .font(Brand.mono)
                    .foregroundStyle(Brand.secondaryText)
            }

            Spacer()

            if isDown {
                // Rather than waiting out a reconnect cycle while looking at
                // a machine you know is back.
                Button("Retry") { fleet.retry(view.machine.id) }
                    .font(Brand.sectionLabel)
                    .buttonStyle(.link)
            }
            Button(view.machine.isEnabled ? "Disable" : "Enable") {
                fleet.setEnabled(!view.machine.isEnabled, for: view.machine.id)
            }
            .font(Brand.sectionLabel)
            .buttonStyle(.link)
            .help(view.machine.isEnabled
                  ? "Stop watching this machine and close its tunnel"
                  : "Watch this machine again")

            Text("\(view.agents.count)")
                .font(Brand.mono)
                .foregroundStyle(Brand.secondaryText)
                .frame(minWidth: 14, alignment: .trailing)
        }
    }

    private var isDown: Bool {
        if case .unreachable = view.reachability { return true }
        return false
    }

    private var dotColor: Color {
        if view.reachability.isConnected { return Brand.color(for: .working) }
        if isDown { return Brand.machineDown }
        return Brand.secondaryText
    }

    /// Verbatim for a failure. "Unreachable" alone tells the user nothing they
    /// can act on; the reason names the host and what it refused.
    private var statusText: String {
        switch view.reachability {
        case .connected:               return "connected"
        case .connecting:              return "connecting…"
        case .disabled:                return "disabled"
        case .reconnecting(let n):     return "reconnecting (\(n))"
        case .unreachable(let reason): return reason
        }
    }
}

private struct GroupSection: View {
    let title: String
    let agents: [Agent]
    let machines: [MachineID: Machine]
    let now: Date
    let fleet: FleetStore

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
                    machine: machines[agent.ref.machine],
                    now: now,
                    fleet: fleet
                )
                    .padding(.horizontal, 14)
            }
        }
    }
}

private struct AgentRow: View {
    let agent: Agent
    let machine: Machine?
    let now: Date
    let fleet: FleetStore

    @State private var isSending = false
    @State private var isNudging = false
    @State private var nudge = ""
    /// Text staged by Send and awaiting Confirm.
    @State private var pendingNudge: String?
    @State private var revealNote: String?
    @State private var failure: String?

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

                actions
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.025))
        )
    }

    // MARK: - Actions

    /// Only what the agent's own prompt offers, and each button says which key
    /// it will press.
    ///
    /// Naming the key is not a debugging detail: an Approve button that does not
    /// say `y` asks the user to trust that AgentHQ read the prompt correctly,
    /// and this is the one place in the product where a wrong reading is
    /// destructive rather than merely visible.
    @ViewBuilder private var actions: some View {
        let available = agent.actions

        if available != .none || failure != nil {
            HStack(spacing: 6) {
                if let key = available.approveKey {
                    ActionButton(title: "Approve (\(key))", tint: Brand.color(for: .working)) {
                        run(.approve)
                    }
                }
                if let key = available.denyKey {
                    ActionButton(title: "Decline (\(key))", tint: Brand.secondaryText) {
                        run(.deny)
                    }
                }
                if available.canInterrupt {
                    ActionButton(title: "Stop", tint: Brand.machineDown) { run(.interrupt) }
                }
                if available.canNudge {
                    ActionButton(title: "Nudge", tint: Brand.secondaryText) {
                        isNudging.toggle()
                        pendingNudge = nil
                    }
                }
                if available.canReveal {
                    // The row's one dependable action. Approve is missing on
                    // most prompts because most name no key, so without this
                    // a blocked row can offer nothing but Decline.
                    ActionButton(title: revealTitle, tint: Brand.secondaryText) { reveal() }
                }
                Spacer(minLength: 0)
                if isSending {
                    // A static word, not a spinner: continuous animation inside
                    // `MenuBarExtra` makes the panel flicker open and closed.
                    Text("sending…")
                        .font(Brand.sectionLabel)
                        .foregroundStyle(Brand.secondaryText)
                }
            }
            .padding(.top, 2)
            .disabled(isSending)

            if isNudging {
                if let pending = pendingNudge {
                    // Named, because the risk is not a typo — it is this text
                    // going to the wrong row. The panel is a list of similar
                    // rows and the buttons sit in the same place on each.
                    HStack(spacing: 6) {
                        Text("Send to \(agent.provider) on \(machineName)?")
                            .font(Brand.sectionLabel)
                            .foregroundStyle(Brand.secondaryText)
                        ActionButton(title: "Confirm", tint: Brand.accent) {
                            pendingNudge = nil
                            isNudging = false
                            nudge = ""
                            run(.nudge(pending))
                        }
                        ActionButton(title: "Cancel", tint: Brand.secondaryText) {
                            pendingNudge = nil
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.top, 2)
                    Text(pending)
                        .font(Brand.body)
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack(spacing: 6) {
                        TextField("Tell it what to do", text: $nudge)
                            .textFieldStyle(.roundedBorder)
                            .font(Brand.body)
                            .onSubmit { submitNudge() }
                        ActionButton(title: "Send", tint: Brand.accent) { submitNudge() }
                    }
                    .padding(.top, 2)
                }
            }

            // Shown in place, next to the button that failed, and left up until
            // the next attempt: a refusal that vanishes on the next refresh
            // reads as the click having worked.
            if let failure {
                Text(failure)
                    .font(Brand.sectionLabel)
                    .foregroundStyle(Brand.machineDown)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            } else if let revealNote {
                Text(revealNote)
                    .font(Brand.sectionLabel)
                    .foregroundStyle(Brand.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 1)
            }
        }
    }

    /// Stages the text rather than sending it. See the confirm row above.
    private func submitNudge() {
        let text = nudge.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingNudge = text
    }

    private var machineName: String {
        machine?.displayName ?? String(agent.ref.machine.raw.prefix(8))
    }

    private var isRemote: Bool { machine?.transport.isRemote ?? false }

    /// How the user gets to a remote machine's herdr from here. herdr attaches
    /// over SSH itself, so this is its command, not a raw ssh line.
    private var attachCommand: String? {
        guard case .ssh(let destination, _, let session, _) = machine?.transport else { return nil }
        return session == "default" || session.isEmpty
            ? "herdr --remote \(destination)"
            : "herdr --remote \(destination) --session \(session)"
    }

    private var revealTitle: String {
        // Says where, because on a remote machine focusing a pane changes
        // something the user is not currently looking at.
        isRemote ? "Reveal on \(machineName)" : "Reveal"
    }

    private func reveal() {
        failure = nil
        isSending = true
        Task {
            do {
                try await fleet.perform(.reveal, on: agent.ref)
                if let command = attachCommand {
                    // Focusing a pane on another machine is real but invisible
                    // from here, so hand over the command that gets the user
                    // there. Saying so is the point; a silent copy is a button
                    // that appears to do nothing.
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    revealNote = "Focused it there. Copied: \(command)"
                } else {
                    revealNote = "Focused it in herdr."
                }
            } catch let error as InterventionError {
                failure = error.summary
            } catch {
                failure = String(describing: error)
            }
            isSending = false
        }
    }

    private func run(_ intervention: Intervention) {
        failure = nil
        revealNote = nil
        isSending = true
        Task {
            do {
                try await fleet.perform(intervention, on: agent.ref)
            } catch let error as InterventionError {
                failure = error.summary
            } catch {
                // Verbatim. A transport error here already reads as a sentence,
                // and a summarized one tells the user nothing to act on.
                failure = String(describing: error)
            }
            isSending = false
        }
    }
}

private struct ActionButton: View {
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Brand.sectionLabel)
                .foregroundStyle(tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(tint.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}
