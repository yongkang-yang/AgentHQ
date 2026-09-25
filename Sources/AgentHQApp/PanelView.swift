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
    /// What the last Open herdr click or machine switch did, until the next.
    @State private var headerNote: HeaderNote?

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

            // The machines, one glyph and a count each. Always shown, so a
            // down machine is on screen rather than inside the settings menu
            // (invariant 2 cuts both ways: a down machine is not a dead
            // agent, and it is not nothing either).
            if !fleet.snapshot.machines.isEmpty {
                // Inset, as a Tahoe menu's separators are: a full-bleed rule
                // cuts the glass in two instead of dividing what sits on it.
                Divider().padding(.horizontal, 14)
                MachineBar(machines: fleet.snapshot.machines, fleet: fleet)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
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
                OpenHerdrButton(view: local, fleet: fleet, note: $headerNote)
            }
            SettingsMenu(
                machines: fleet.snapshot.machines.map(MachineMenuEntry.init),
                notifier: notifier,
                fleet: fleet,
                note: $headerNote
            )
            .equatable()
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, headerNote == nil ? 4 : 0)
        // Under the header rather than in it: a failure here is a sentence
        // (usually the Automation grant), and the header has no room for one.
        if let headerNote {
            Group {
                if headerNote.isFailure {
                    ProblemText(headerNote.text)
                } else {
                    Text(headerNote.text)
                        .font(Brand.sectionLabel)
                        .foregroundStyle(Brand.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
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
}

/// Every machine as a glyph and its agent count, one glyph per machine —
/// see ``MachineView/symbols(for:)``.
///
/// A connected machine needs nothing more than a short name beside it. One that is not connected spends the room
/// the count saved: tinted, named, its state in a word, and Retry. "wsl
/// unreachable", not a red dot, so the line alone says which box to look at.
/// The verbatim reason is in the tooltip and the settings menu, which have
/// room for a sentence.
private struct MachineBar: View {
    let machines: [MachineView]
    let fleet: FleetStore

    var body: some View {
        let symbols = MachineView.symbols(for: machines)
        HStack(spacing: 8) {
            ForEach(machines) { view in
                item(view, symbol: symbols[view.id] ?? "terminal")
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func item(_ view: MachineView, symbol: String) -> some View {
        let isTroubled = view.machine.isEnabled && !view.reachability.isConnected
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isTroubled ? Brand.problemText : Brand.secondaryText)
            if isTroubled {
                if view.isDown {
                    Image(systemName: Brand.problemSymbol).font(.system(size: 9))
                }
                Text("\(view.shortName) \(view.shortStatus)")
                    .font(Brand.sectionLabel)
                    .foregroundStyle(view.isDown ? Brand.problemText : Brand.secondaryText)
                    .lineLimit(1)
                if view.canRetry {
                    // Rather than waiting out a reconnect cycle while
                    // looking at a machine you know is back. Plain text, not
                    // a link: link blue is working's blue.
                    Button("Retry") { fleet.retry(view.machine.id) }
                        .font(Brand.sectionLabel.weight(.bold))
                        .foregroundStyle(Brand.actionText)
                        .buttonStyle(.plain)
                        .underline()
                }
            } else {
                Text(view.shortName)
                    .font(Brand.sectionLabel)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                // A disabled machine keeps its glyph, dimmed, with no count:
                // it is not watched, so it has no count to report.
                Text(view.machine.isEnabled ? "\(view.agents.count)" : "–")
                    .font(Brand.mono)
                    .foregroundStyle(Brand.secondaryText)
            }
        }
        // The same neutral wash as the machine chip on every agent row.
        // Machines are told apart by glyph and name; a hue per machine put a
        // red "wsl" beside a red "crashed".
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(Brand.chipFill))
        .overlay(Capsule().strokeBorder(Brand.chipStroke, lineWidth: 0.5))
        .opacity(view.machine.isEnabled ? 1 : 0.45)
        .help(view.tooltip)
    }
}

extension MachineView {
    /// A glyph per machine, distinct within the bar, so two remote machines
    /// are told apart without their names.
    ///
    /// This Mac is the laptop. A WSL machine is a PC, which is what it is
    /// from here — SF Symbols has neither a Windows nor a Linux mark. The
    /// rest take the next unused glyph in bar order, so no two share one
    /// until the pool runs out.
    static func symbols(for machines: [MachineView]) -> [MachineID: String] {
        let pool = ["cloud", "server.rack", "desktopcomputer", "cpu", "externaldrive", "terminal"]
        var result: [MachineID: String] = [:]
        var next = 0
        for view in machines {
            if view.machine.transport.isLocal {
                result[view.id] = "laptopcomputer"
            } else if view.isWSL {
                result[view.id] = "pc"
            } else {
                result[view.id] = pool[next % pool.count]
                next += 1
            }
        }
        return result
    }

    /// Name, status verbatim, and herdr's version once it has answered.
    var tooltip: String {
        var text = "\(machine.displayName): \(statusText)"
        if let herdrVersion, reachability.isConnected { text += " · herdr \(herdrVersion)" }
        return text
    }

    /// The bar's label: "Mac", "WSL", or the machine's own name with a
    /// capital. Shorter than `displayName`, which reads "This Mac" and keeps
    /// herdr's lower-case labels for the rows and menus.
    var shortName: String {
        if machine.transport.isLocal { return "Mac" }
        if isWSL { return "WSL" }
        return machine.displayName.prefix(1).uppercased() + machine.displayName.dropFirst()
    }

    private var isWSL: Bool {
        guard case .ssh(let destination, _, _, _) = machine.transport else { return false }
        return [machine.displayName, destination].contains { $0.localizedCaseInsensitiveContains("wsl") }
    }

    /// A failure the user is being asked to look at. `reconnecting` is not
    /// one — see ``MachineReachability/isTransient``.
    var isDown: Bool {
        if case .unreachable = reachability { return true }
        return false
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
    /// Whether End is staged and waiting to be confirmed. Never sends on its
    /// own — see the confirmation row.
    @State private var pendingEnd = false
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
                    // box this is on is part of the agent's identity.
                    MachineTag(name: machineName)
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
    @ViewBuilder private var actions: some View {
        let available = agent.actions

        // Console stands on every live row, so the cluster does too.
        if available != .none || failure != nil || agent.state != .crashed {
            GlassCluster {
                if let key = available.approveKey {
                    ActionButton(title: "Approve (\(key))", emphasis: .prominent) {
                        run(.approve)
                    }
                }
                if let key = available.denyKey {
                    ActionButton(title: "Decline (\(key))") {
                        run(.deny)
                    }
                }
                if available.canEnd {
                    // Staged, never sent on the first click. This is the only
                    // action in the panel that destroys something the user
                    // cannot get back, and the panel is a list of
                    // near-identical rows with the buttons in the same place
                    // on each — so the confirmation names the row.
                    ActionButton(title: "End") {
                        pendingEnd.toggle()
                    }
                }
                if agent.state != .crashed {
                    // Where words go. Continue, Reply and Show output used to
                    // live on the row; each was a guess at the pane from a
                    // snapshot, and the console shows the pane itself. What
                    // stays on the row is what is safe to press unseen.
                    ActionButton(title: "Console") {
                        ConsoleWindows.shared.open(
                            agent.ref,
                            title: "\(agent.provider) · \(agent.project) · \(machineName)",
                            fleet: fleet
                        )
                    }
                    .help("Open a small window that mirrors this pane")
                }
                if available.canReveal {
                    // For when the console is not enough: the full terminal.
                    // No machine name in the title: the chip on the row
                    // already says which box, and "Reveal on wsl" made the
                    // same button a different width on every row.
                    ActionButton(title: "Reveal") { reveal() }
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
                    ActionButton(title: "End it", emphasis: .prominent) {
                        pendingEnd = false
                        run(.end, note: "Asked \(agent.provider) to exit.")
                    }
                    ActionButton(title: "Cancel") {
                        pendingEnd = false
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
                Text("The conversation ends. Its pane and output stay.")
                    .font(Brand.sectionLabel)
                    .foregroundStyle(Brand.secondaryText)
            }

            // Shown in place, next to the button that failed, and left up until
            // the next attempt: a refusal that vanishes on the next refresh
            // reads as the click having worked.
            if let failure {
                ProblemText(failure)
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
///
/// The menu must not be rebuilt while it is open: SwiftUI replaces the
/// `NSMenu`'s items when this body runs again, and a submenu open at the time
/// collapses under the pointer. The body used to read the fleet snapshot,
/// which is reassigned every 1.5 seconds, so a machine's submenu closed
/// before Enable could be reached. So the machines arrive as plain values
/// that change only when something shown in the menu does, and each is one
/// flat item rather than a submenu.
private struct SettingsMenu: View, Equatable {
    let machines: [MachineMenuEntry]
    let notifier: Notifier
    let fleet: FleetStore
    @Binding var note: HeaderNote?

    // Spelled out so the panel's once-a-second tick, which re-runs the
    // header, cannot re-run this. The notification switches are read through
    // Observation, which still redraws them when they change.
    nonisolated static func == (lhs: SettingsMenu, rhs: SettingsMenu) -> Bool {
        lhs.machines == rhs.machines && lhs.notifier === rhs.notifier && lhs.fleet === rhs.fleet
    }

    var body: some View {
        Menu {
            Section("Watch machines") {
                // Checked is watched. The state and reason live in the
                // machine bar's tooltip, which updates without closing
                // anything.
                ForEach(machines) { entry in
                    Toggle(entry.name, isOn: Binding(
                        get: { entry.isEnabled },
                        set: { setEnabled($0, entry) }
                    ))
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

    /// A machine herdr saved is switched in herdr, not only here.
    ///
    /// AgentHQ reads its machines, enabled flag included, from herdr's own
    /// registry. Switching only the session here left herdr saying disabled —
    /// so a herdr client opened with Open herdr still skipped the machine,
    /// and the next launch imported it disabled again. herdr's CLI owns that
    /// file, so it makes the change; the session follows only once it has,
    /// which keeps the two from disagreeing when the command fails.
    ///
    /// This Mac is not a herdr machine profile and is switched here alone.
    private func setEnabled(_ isEnabled: Bool, _ entry: MachineMenuEntry) {
        note = nil
        guard entry.isHerdrProfile else {
            fleet.setEnabled(isEnabled, for: entry.id)
            return
        }
        Task {
            do {
                try await HerdrMachineCLI.setEnabled(isEnabled, profile: entry.id.raw)
                fleet.setEnabled(isEnabled, for: entry.id)
            } catch {
                note = HeaderNote(
                    text: "Could not \(isEnabled ? "enable" : "disable") \(entry.name): \(error.localizedDescription)",
                    isFailure: true
                )
            }
        }
    }
}

/// What the settings menu shows of a machine, and nothing that moves on its
/// own — see ``SettingsMenu``.
struct MachineMenuEntry: Equatable, Identifiable {
    let id: MachineID
    let name: String
    let isEnabled: Bool
    /// Imported from herdr's registry, whose profile id it kept.
    let isHerdrProfile: Bool

    init(_ view: MachineView) {
        id = view.id
        name = view.shortName
        isEnabled = view.machine.isEnabled
        isHerdrProfile = view.machine.transport.isRemote
    }
}

/// What an Open herdr click or a machine switch reports back to the header.
struct HeaderNote: Equatable {
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
    @Binding var note: HeaderNote?

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
            note = isServing ? nil : HeaderNote(text: result, isFailure: false)
            if !isServing { Self.retrySoon(view.machine.id, fleet: fleet) }
        } catch {
            note = HeaderNote(text: error.localizedDescription, isFailure: true)
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

/// A machine's identity as a neutral chip.
///
/// A grey wash, where the state pill is solid colour. The two sit on the same
/// row and the difference is what keeps "which box" from reading as "what
/// state". It was a hue per machine once, first saturated and then as a
/// wash, and either way a chip that shared a hue with a state read as one —
/// the machine is context, the state is the news.
private struct MachineTag: View {
    let name: String

    var body: some View {
        Text(name)
            .font(Brand.mono)
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Brand.chipFill))
            .overlay(Capsule().strokeBorder(Brand.chipStroke, lineWidth: 0.5))
            .help(name)
    }
}
