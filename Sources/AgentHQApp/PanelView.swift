import AgentHQFleet
import AgentHQKit
import Combine
import SwiftUI

/// The triage desk. Three sections, most urgent first.
///
/// Grouped by attention and labelled by machine, never the reverse: a blocked
/// agent has to be findable regardless of which host it is on.
struct PanelView: View {
    let fleet: FleetStore
    let notifier: Notifier
    /// Set by a notification click: which agent the panel should bring into
    /// view once it opens.
    let focus: PanelFocus
    @State private var now = Date()
    /// What the agent list measured itself to be. See the frame below.
    @State private var listHeight: CGFloat = 0
    /// What the last Open herdr click did, until the next one.
    @State private var openNote: OpenNote?

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
                ScrollViewReader { proxy in
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
                    // menu-bar popover has no height to inherit and no
                    // intrinsic one of its own, so `maxHeight` alone collapsed it
                    // to zero: the panel rendered its header and its footer and
                    // nothing between them, while the header cheerfully said "1
                    // need you". Measured content, floored so a collapse can never
                    // hide the list again, capped so a long herd scrolls.
                    .frame(height: min(max(listHeight, Self.minimumListHeight), Self.maximumListHeight))
                    .softScrollEdges()
                    .onPreferenceChange(ListHeightKey.self) { listHeight = $0 }
                    // A click on a notification names an agent; land the panel
                    // on it. `onAppear` covers the first show (the focus was set
                    // before the popover existed) and `onChange` a later click
                    // while it is already open.
                    .onAppear { scrollToFocus(proxy) }
                    .onChange(of: focus.nonce) { _, _ in scrollToFocus(proxy) }
                }
            }

            // Only while a machine is in trouble. The machines themselves
            // live in the settings menu; this is what keeps a down one from
            // hiding in there (invariant 2 cuts both ways: a down machine is
            // not a dead agent, and it is not nothing either).
            if !troubled.isEmpty {
                // Inset, as a Tahoe menu's separators are: a full-bleed rule
                // cuts the glass in two instead of dividing what sits on it.
                Divider().padding(.horizontal, 14)
                MachineTrouble(machines: troubled, fleet: fleet)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        }
        .frame(width: 460)
        .onReceive(tick) { now = $0 }
    }

    /// Bring the agent a notification named into view. A no-op when the panel
    /// was opened by the status item, or when that agent has since gone.
    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let ref = focus.ref else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            proxy.scrollTo(ref, anchor: .center)
        }
    }

    @ViewBuilder private var header: some View {
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
            if let local = fleet.snapshot.machines.first(where: { $0.machine.transport.isLocal }) {
                OpenHerdrButton(view: local, fleet: fleet, note: $openNote)
            }
            SettingsMenu(notifier: notifier, fleet: fleet)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, openNote == nil ? 4 : 0)
        // Under the header rather than in it: a failure here is a sentence
        // (usually the Automation grant), and the header has no room for one.
        if let openNote {
            Text(openNote.text)
                .font(Brand.sectionLabel)
                .foregroundStyle(openNote.isFailure ? Brand.machineDown : Brand.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.bottom, 4)
        }
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

    private var troubled: [MachineView] {
        fleet.snapshot.machines.filter { $0.machine.isEnabled && !$0.reachability.isConnected }
    }
}

/// The machines that are not simply connected, named, with the one thing to
/// do about them.
///
/// "build-box unreachable", not "1 unreachable", so the line alone says which
/// box to look at. The verbatim reason is in the tooltip and in the settings
/// menu, which have room for a sentence.
private struct MachineTrouble: View {
    let machines: [MachineView]
    let fleet: FleetStore

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(machines) { view in
                HStack(spacing: 6) {
                    Circle()
                        .fill(view.dotColor)
                        .frame(width: 6, height: 6)
                    MachineTag(name: view.machine.displayName, id: view.machine.id)
                    Text(view.shortStatus)
                        .font(Brand.sectionLabel)
                        .foregroundStyle(view.isDown ? Brand.machineDown : Brand.secondaryText)
                    Spacer(minLength: 0)
                    if view.canRetry {
                        // Rather than waiting out a reconnect cycle while
                        // looking at a machine you know is back.
                        Button("Retry") { fleet.retry(view.machine.id) }
                            .font(Brand.sectionLabel)
                            .buttonStyle(.link)
                    }
                }
                .help(view.statusText)
            }
        }
    }
}

extension MachineView {
    /// A failure the user is being asked to look at. `reconnecting` is not
    /// one — see ``MachineReachability/isTransient``.
    var isDown: Bool {
        if case .unreachable = reachability { return true }
        return false
    }

    var dotColor: Color {
        if reachability.isConnected { return Brand.color(for: .working) }
        if isDown { return Brand.machineDown }
        return Brand.secondaryText
    }

    /// The one-word form for a line with no room. Never the failure's reason,
    /// which is a sentence — see ``statusText``.
    var shortStatus: String {
        switch reachability {
        case .connected:    return "connected"
        case .connecting:   return "connecting"
        case .disabled:     return "disabled"
        case .reconnecting: return "reconnecting"
        case .unreachable:  return "unreachable"
        }
    }

    /// Verbatim for a failure. "Unreachable" alone tells the user nothing they
    /// can act on; the reason names the host and what it refused.
    var statusText: String {
        switch reachability {
        case .connected:               return "connected"
        case .connecting:              return "connecting…"
        case .disabled:                return "disabled"
        case .reconnecting(let n):     return "reconnecting (\(n))"
        case .unreachable(let reason): return reason
        }
    }

    /// Offered for a reconnect too, not just a failure. The supervisor backs
    /// off to half a minute between attempts, and not waiting out a cycle
    /// matters most to the state that says "reconnecting (14)". `connecting`
    /// is excluded because an attempt is already running.
    var canRetry: Bool {
        switch reachability {
        case .connected, .connecting, .disabled: return false
        case .reconnecting, .unreachable:        return true
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
            // Sentence case with a count, as macOS 26 menus head their
            // sections; the all-caps tracked label was the pre-glass idiom.
            HStack(spacing: 5) {
                Text(title)
                    .font(Brand.sectionHeader)
                    .foregroundStyle(Brand.secondaryText)
                Text("\(agents.count)")
                    .font(Brand.mono)
                    .foregroundStyle(Brand.secondaryText)
            }
            .padding(.horizontal, 18)

            ForEach(agents) { agent in
                AgentRow(
                    agent: agent,
                    machine: machines[agent.ref.machine],
                    now: now,
                    fleet: fleet
                )
                    .padding(.horizontal, 14)
                    .id(agent.ref)
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
    /// Whether End is staged and waiting to be confirmed. Never sends on its
    /// own — see the confirmation row.
    @State private var pendingEnd = false
    /// Which text action the box is currently for. Nudge and reply travel
    /// different herdr calls and are valid in opposite states, so the box has
    /// to remember which one opened it.
    @State private var composing: ComposeKind?
    @State private var revealNote: String?
    @State private var failure: String?

    /// The pane's recent output, once the user has asked to see it. Fetched
    /// on demand rather than carried on every refresh — see
    /// `MachineSession.transcript(for:lines:)`.
    @State private var transcript: String?
    @State private var isLoadingTranscript = false
    @State private var transcriptFailure: String?
    @State private var showsTranscript = false

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
                    Text(agent.project)
                        .font(Brand.body)
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(DwellFormatter.short(agent.dwell(now: now)))
                        .font(Brand.mono)
                        .foregroundStyle(Brand.secondaryText)
                }

                HStack(spacing: 6) {
                    // Solid: the state is what the row is for, so it is the
                    // one filled chip on it. See `MachineTag` for the other
                    // half of that bargain.
                    Text(Brand.label(for: agent.state).uppercased())
                        .font(Brand.sectionLabel)
                        .tracking(0.4)
                        .foregroundStyle(Brand.onStateText)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Capsule().fill(Brand.color(for: agent.state)))
                    // The machine is on every row, in mono: in a fleet, which
                    // box this is on is part of the agent's identity. The chip
                    // gives each machine its own colour so the eye can sort a
                    // mixed list by box without reading a word.
                    MachineTag(name: machineName, id: agent.ref.machine)
                    // The model is the one thing that separates two same
                    // provider rows on one machine. Shown only when a reporter
                    // named it; herdr has no model field to fall back on.
                    if !agent.model.isEmpty {
                        Text(agent.model)
                            .font(Brand.mono)
                            .foregroundStyle(Brand.secondaryText)
                            .lineLimit(1)
                    }
                }

                // The prompt itself, when there is one. It is what the row is
                // asking the user to act on: a highlighted-row menu's choices
                // and the key that takes one live over several lines, and a
                // one-line summary cannot carry them.
                if let message = agent.message {
                    Text(message)
                        .font(Brand.mono)
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                } else if let reason = agent.reason {
                    Text(reason)
                        .font(Brand.body)
                        .foregroundStyle(Brand.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                outputDisclosure

                actions
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: Brand.rowRadius, style: .continuous)
                .fill(Color.primary.opacity(0.035))
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
    private func placeholder(for kind: ComposeKind) -> String {
        switch kind {
        case .reply: return kind.placeholder
        case .nudge: return Brand.promptPlaceholder(for: agent.state)
        }
    }

    // MARK: - Output

    /// "What did it actually say?" — the question the excerpt above can only
    /// ever half answer.
    ///
    /// The excerpt is condensed: whitespace collapsed, every line cut at 117
    /// characters, six lines at most. That is right for a prompt the user has
    /// to act on and wrong for a result they have to read. This shows what the
    /// pane holds, wrapped but otherwise untouched.
    @ViewBuilder private var outputDisclosure: some View {
        // A dead pane has nothing to read, and herdr would answer a read for
        // it with an error the row cannot act on.
        if agent.state != .crashed {
            VStack(alignment: .leading, spacing: 4) {
                Button {
                    toggleTranscript()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: showsTranscript ? "chevron.down" : "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                        Text(showsTranscript ? "Hide output" : "Show output")
                            .font(Brand.sectionLabel)
                        if isLoadingTranscript {
                            Text("…").font(Brand.sectionLabel)
                        }
                    }
                    .foregroundStyle(Brand.secondaryText)
                }
                .buttonStyle(.plain)

                if showsTranscript {
                    if let transcriptFailure {
                        Text(transcriptFailure)
                            .font(Brand.body)
                            .foregroundStyle(Brand.machineDown)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let transcript {
                        ScrollView {
                            Text(transcript)
                                .font(Brand.mono)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(6)
                        }
                        // Tall enough to read a reply in, short enough that a
                        // panel of several rows is still a panel.
                        .frame(maxHeight: 220)
                        .background(
                            RoundedRectangle(cornerRadius: Brand.insetRadius, style: .continuous)
                                .fill(Color.primary.opacity(0.05))
                        )
                        // A read is a snapshot, not a feed: herdr has no
                        // output subscription, so this is what the pane held
                        // when it was asked. Saying so beats a view that looks
                        // live and is not.
                        Text("Read when opened · close and reopen to refresh")
                            .font(Brand.sectionLabel)
                            .foregroundStyle(Brand.secondaryText)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func toggleTranscript() {
        if showsTranscript {
            showsTranscript = false
            // Dropped rather than kept: reopening should show what the pane
            // holds now, and a cached copy of a finished run is the one thing
            // that would look current and not be.
            transcript = nil
            transcriptFailure = nil
            return
        }

        showsTranscript = true
        isLoadingTranscript = true
        transcriptFailure = nil
        Task {
            do {
                let text = try await fleet.transcript(for: agent.ref)
                transcript = text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                transcriptFailure = "Could not read this pane: \(error.localizedDescription)"
            }
            isLoadingTranscript = false
        }
    }

    @ViewBuilder private var actions: some View {
        let available = agent.actions

        if available != .none || failure != nil {
            GlassCluster {
                if let key = available.approveKey {
                    ActionButton(title: "Approve (\(key))", tint: Brand.color(for: .working), emphasis: .prominent) {
                        run(.approve)
                    }
                }
                if let key = available.denyKey {
                    ActionButton(title: "Decline (\(key))", tint: Brand.secondaryText) {
                        run(.deny)
                    }
                }
                if available.canEnd {
                    // Staged, never sent on the first click. This is the only
                    // action in the panel that destroys something the user
                    // cannot get back, and the panel is a list of
                    // near-identical rows with the buttons in the same place
                    // on each — so the confirmation names the row.
                    ActionButton(title: "End", tint: Brand.endAction) {
                        pendingEnd.toggle()
                    }
                }
                if available.canReply {
                    // The open question's answer. Approve/Decline cannot
                    // express it, and Nudge cannot be sent while blocked.
                    ActionButton(title: "Reply", tint: Brand.accent) { open(.reply) }
                }
                if available.canNudge {
                    ActionButton(title: Brand.promptAction(for: agent.state), tint: Brand.continueAction) {
                        open(.nudge)
                    }
                }
                if available.canReveal {
                    // The row's one dependable action. Approve is missing on
                    // most prompts because most name no key, so without this
                    // a blocked row can offer nothing but Decline.
                    // No machine name in the title: the chip on the row
                    // already says which box, and "Reveal on wsl" made the
                    // same button a different width on every row.
                    ActionButton(title: "Reveal", tint: Brand.revealAction) { reveal() }
                        .help("Show this pane in Ghostty on \(machineName)")
                }
                Spacer(minLength: 0)
                if isSending {
                    // A static word, not a spinner: continuous animation inside
                    // the menu-bar panel makes it flicker open and closed.
                    Text("sending…")
                        .font(Brand.sectionLabel)
                        .foregroundStyle(Brand.secondaryText)
                }
            }
            .padding(.top, 2)
            .disabled(isSending)

            if pendingEnd {
                GlassCluster {
                    Text("End \(agent.provider) in \(agent.project) on \(machineName)?")
                        .font(Brand.sectionLabel)
                        .foregroundStyle(Brand.secondaryText)
                    ActionButton(title: "End it", tint: Brand.machineDown, emphasis: .destructive) {
                        pendingEnd = false
                        run(.end, note: "Asked \(agent.provider) to exit.")
                    }
                    ActionButton(title: "Cancel", tint: Brand.secondaryText) {
                        pendingEnd = false
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
                Text("The conversation ends. Its pane and output stay.")
                    .font(Brand.sectionLabel)
                    .foregroundStyle(Brand.secondaryText)
            }

            if let kind = composing {
                if let pending = pendingCompose {
                    // Named, because the risk is not a typo — it is this text
                    // going to the wrong row. The panel is a list of similar
                    // rows and the buttons sit in the same place on each.
                    GlassCluster {
                        Text("\(kind.verb) \(agent.provider) in \(agent.project) on \(machineName)?")
                            .font(Brand.sectionLabel)
                            .foregroundStyle(Brand.secondaryText)
                        ActionButton(title: "Confirm", tint: Brand.accent, emphasis: .prominent) {
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
                        TextField(placeholder(for: kind), text: $compose)
                            .textFieldStyle(.roundedBorder)
                            .font(Brand.body)
                            .onSubmit { stageCompose() }
                        ActionButton(title: "Send", tint: Brand.accent, emphasis: .prominent) { stageCompose() }
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

    private func reveal() {
        failure = nil
        isSending = true
        Task {
            do {
                try await fleet.perform(.reveal, on: agent.ref)
                if let machine {
                    revealNote = try GhosttyReveal.present(machine: machine, agent: agent)
                } else {
                    failure = "Machine unavailable."
                }
            } catch let error as InterventionError {
                failure = error.summary
            } catch let error as GhosttyReveal.RevealError {
                failure = error.localizedDescription
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

/// The panel's preferences and Quit, behind one gear.
///
/// They used to be a row of their own in the footer, which cost a line of
/// the panel on every open for switches that are set once. The menu is a
/// real `NSMenu`, not a view inside the panel, so it adds nothing that
/// animates inside `MenuBarExtra` (invariant 12).
private struct SettingsMenu: View {
    let notifier: Notifier
    let fleet: FleetStore

    var body: some View {
        Menu {
            Section("Machines") {
                ForEach(fleet.snapshot.machines) { view in
                    MachineMenu(view: view, fleet: fleet)
                }
            }
            Divider()
            Toggle("Notify when an agent needs you", isOn: Binding(
                get: { notifier.isEnabled },
                set: { notifier.isEnabled = $0 }
            ))
            // Disabled rather than hidden while notifications are off: on
            // its own it controls nothing, but a menu that changes shape
            // reads as an item having gone missing.
            Toggle("Also notify when a run finishes", isOn: Binding(
                get: { notifier.announcesCompletions },
                set: {
                    notifier.announcesCompletions = $0
                    fleet.announcesCompletions = $0
                }
            ))
            .disabled(!notifier.isEnabled)
            Divider()
            Button("Quit AgentHQ") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(systemName: "gearshape")
                .foregroundStyle(Brand.secondaryText)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Settings")
        // A menu item's shortcut only answers while the menu is open, and
        // ⌘Q with the panel up used to quit. Kept on a button that draws
        // nothing so it still does — invisible by opacity, not `.hidden()`,
        // which is not guaranteed to keep a shortcut registered.
        .background(
            Button("") { NSApplication.shared.terminate(nil) }
                .keyboardShortcut("q")
                .opacity(0)
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        )
    }
}

/// One machine as a submenu: its state in the title, what can be done about
/// it inside.
///
/// A menu item cannot be coloured, so the state is a word, and the reason for
/// a failure is shown whole as the submenu's first line — the tooltip it used
/// to be in does not exist in a menu.
private struct MachineMenu: View {
    let view: MachineView
    let fleet: FleetStore

    var body: some View {
        Menu(title) {
            Text(view.statusText)
            if let version = view.herdrVersion, view.reachability.isConnected {
                Text("herdr \(version)")
            }
            Divider()
            if view.canRetry {
                Button("Retry") { fleet.retry(view.machine.id) }
            }
            Button(view.machine.isEnabled ? "Disable" : "Enable") {
                fleet.setEnabled(!view.machine.isEnabled, for: view.machine.id)
            }
        }
    }

    private var title: String {
        let agents = view.agents.count
        let count = agents == 1 ? "1 agent" : "\(agents) agents"
        return view.reachability.isConnected
            ? "\(view.machine.displayName) — \(count)"
            : "\(view.machine.displayName) — \(view.shortStatus)"
    }
}

/// What an Open herdr click reports back to the header.
struct OpenNote: Equatable {
    let text: String
    let isFailure: Bool
}

/// Opens this Mac's herdr in Ghostty, whether or not anything is running.
///
/// Reveal needs a row, and a row needs an agent, so with an empty herd the
/// panel offered no way into herdr at all. This is that way in: it focuses
/// the surface already drawing herdr when AgentHQ can reach it, and otherwise
/// opens a window running `herdr`, which starts the server as well.
struct OpenHerdrButton: View {
    let view: MachineView
    let fleet: FleetStore
    @Binding var note: OpenNote?

    var body: some View {
        ActionButton(
            title: view.reachability.isConnected ? "Open herdr" : "Start herdr",
            tint: .primary
        ) { open() }
        .help(view.reachability.isConnected
              ? "Show this Mac's herdr in Ghostty"
              : "Start herdr on this Mac in a new Ghostty window")
    }

    private func open() {
        let isServing = view.reachability.isConnected
        do {
            let result = try GhosttyReveal.open(machine: view.machine, isServing: isServing)
            note = isServing ? nil : OpenNote(text: result, isFailure: false)
            if !isServing { Self.retrySoon(view.machine.id, fleet: fleet) }
        } catch {
            note = OpenNote(text: error.localizedDescription, isFailure: true)
        }
    }

    /// A freshly started herdr is picked up by the session's own retry, but
    /// that backs off to ten seconds and more — long enough to read as the
    /// button not having worked. Asking once, after herdr has had a moment to
    /// bind its socket, turns that into about two.
    private static func retrySoon(_ id: MachineID, fleet: FleetStore) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            fleet.retry(id)
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

/// A machine's identity as a tinted chip.
///
/// A wash, where the state pill is solid. The two sit on the same row and the
/// difference in weight is what keeps "which box" from reading as "what
/// state". It used to be the other way round, and a saturated chip per row
/// out-shouted the state it sat beside — the machine is context, the state is
/// the news. The colour is stable per machine, so the same box is the same
/// chip every launch.
private struct MachineTag: View {
    let name: String
    let id: MachineID

    var body: some View {
        Text(name)
            .font(Brand.mono)
            // Primary text, not the machine colour: the palette is dark by
            // design, and dark text on a dark panel fails AA.
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Brand.machineColor(for: id).opacity(0.2)))
            .overlay(Capsule().strokeBorder(Brand.machineColor(for: id).opacity(0.45), lineWidth: 0.5))
            .help(name)
    }
}
