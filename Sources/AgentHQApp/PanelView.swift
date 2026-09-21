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
    /// What the agent list measured itself to be. See the frame below.
    @State private var listHeight: CGFloat = 0

    static let minimumListHeight: CGFloat = 96
    static let maximumListHeight: CGFloat = 460

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
            } else if fleet.snapshot.allAgents.isEmpty {
                Text("No agents running.")
                    .font(Brand.body)
                    .foregroundStyle(Brand.secondaryText)
                    .padding(.vertical, 18)
                    .frame(maxWidth: .infinity, alignment: .center)
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
                    // Measure what the list actually wants to be.
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ListHeightKey.self, value: proxy.size.height
                            )
                        }
                    )
                }
                // An explicit height, not `maxHeight`. A ScrollView inside a
                // MenuBarExtra window has no height to inherit and no
                // intrinsic one of its own, so `maxHeight` alone collapsed it
                // to zero: the panel rendered its header and its footer and
                // nothing between them, while the header cheerfully said "1
                // need you". Measured content, floored so a collapse can never
                // hide the list again, capped so a long herd scrolls.
                .frame(height: min(max(listHeight, Self.minimumListHeight), Self.maximumListHeight))
                .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
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
    @State private var compose = ""
    /// Text staged by Send and awaiting Confirm.
    @State private var pendingCompose: String?
    /// Which text action the box is currently for. Nudge and reply travel
    /// different herdr calls and are valid in opposite states, so the box has
    /// to remember which one opened it.
    @State private var composing: ComposeKind?
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
                    ActionButton(title: "Stop", tint: Brand.machineDown) {
                        // Says what it sent. Interrupt frequently changes
                        // nothing the row can show — the agent catches the
                        // signal and carries on, or herdr has not re-detected
                        // it yet — and a silent success is indistinguishable
                        // from a button that does not work.
                        run(.interrupt, note: "Sent ⌃C.")
                    }
                }
                if available.canReply {
                    // The open question's answer. Approve/Decline cannot
                    // express it, and Nudge cannot be sent while blocked.
                    ActionButton(title: "Reply", tint: Brand.accent) { open(.reply) }
                }
                if available.canNudge {
                    ActionButton(title: "Nudge", tint: Brand.secondaryText) { open(.nudge) }
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

            if let kind = composing {
                if let pending = pendingCompose {
                    // Named, because the risk is not a typo — it is this text
                    // going to the wrong row. The panel is a list of similar
                    // rows and the buttons sit in the same place on each.
                    HStack(spacing: 6) {
                        Text("\(kind.verb) \(agent.provider) on \(machineName)?")
                            .font(Brand.sectionLabel)
                            .foregroundStyle(Brand.secondaryText)
                        ActionButton(title: "Confirm", tint: Brand.accent) {
                            pendingCompose = nil
                            composing = nil
                            compose = ""
                            run(kind.intervention(pending))
                        }
                        ActionButton(title: "Cancel", tint: Brand.secondaryText) {
                            pendingCompose = nil
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
                        TextField(kind.placeholder, text: $compose)
                            .textFieldStyle(.roundedBorder)
                            .font(Brand.body)
                            .onSubmit { stageCompose() }
                        ActionButton(title: "Send", tint: Brand.accent) { stageCompose() }
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

    private func open(_ kind: ComposeKind) {
        composing = composing == kind ? nil : kind
        pendingCompose = nil
        compose = ""
    }

    /// Stages the text rather than sending it. See the confirm row above.
    private func stageCompose() {
        let text = compose.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        pendingCompose = text
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

    private func run(_ intervention: Intervention, note: String? = nil) {
        failure = nil
        revealNote = nil
        isSending = true
        Task {
            do {
                try await fleet.perform(intervention, on: agent.ref)
                revealNote = note
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

/// Carries the agent list's measured height up to the frame that applies it.
private struct ListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// The two things a row can send words with.
///
/// Separate cases rather than a flag, because they are valid in opposite
/// states and travel different herdr calls: nudge is `agent.prompt` on a
/// working agent, reply is `pane.send_text` on a blocked one, and herdr
/// refuses each where the other belongs.
private enum ComposeKind: Equatable {
    case nudge
    case reply

    var placeholder: String {
        switch self {
        case .nudge: return "Tell it what to do"
        case .reply: return "Answer its question"
        }
    }

    /// Reads into the confirmation line, which names the target.
    var verb: String {
        switch self {
        case .nudge: return "Send to"
        case .reply: return "Reply to"
        }
    }

    func intervention(_ text: String) -> Intervention {
        switch self {
        case .nudge: return .nudge(text)
        case .reply: return .reply(text)
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
