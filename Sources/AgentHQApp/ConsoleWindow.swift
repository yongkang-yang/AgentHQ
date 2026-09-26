import AgentHQFleet
import AgentHQKit
import AppKit
import SwiftUI

/// A small floating window per agent that mirrors its pane and types into it,
/// so watching and steering a conversation does not need Ghostty.
///
/// Unlike the menu-bar panel it stays open when you click elsewhere: the point
/// is to keep an eye on a run while doing something else. One window per
/// `AgentRef` — opening it again brings the existing one forward.
@MainActor
final class ConsoleWindows {
    static let shared = ConsoleWindows()

    private var windows: [AgentRef: NSPanel] = [:]
    private var closeObservers: [AgentRef: NSObjectProtocol] = [:]

    func open(_ ref: AgentRef, title: String, fleet: FleetStore) {
        if let existing = windows[ref] {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            // Not `.utilityWindow`: its shrunken title bar made the window
            // controls too small to hit comfortably.
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentViewController = NSHostingController(
            rootView: ConsoleView(ref: ref, fleet: fleet) { [weak panel] in
                // Hidden behind another window, on another Space, or in the
                // Dock: nobody is reading, so nothing is read.
                panel?.occlusionState.contains(.visible) ?? false
            }
        )
        panel.setContentSize(NSSize(width: 720, height: 480))
        panel.center()

        windows[ref] = panel
        closeObservers[ref] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget(ref) }
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Dropping the hosting controller ends the view's `.task`, which is what
    /// stops the polling.
    private func forget(_ ref: AgentRef) {
        windows[ref]?.contentViewController = nil
        windows[ref] = nil
        if let observer = closeObservers.removeValue(forKey: ref) {
            NotificationCenter.default.removeObserver(observer)
        }
    }
}

private struct ConsoleView: View {
    let ref: AgentRef
    let fleet: FleetStore
    let isVisible: @MainActor () -> Bool

    @State private var screen = ""
    /// Kept apart so the next successful poll cannot wipe a refusal the
    /// user has not read yet.
    @State private var sendFailure: String?
    @State private var readFailure: String?
    @State private var input = ""
    @State private var isSending = false
    @State private var isFollowing = true
    /// Output that arrived while scrolled up, held back until the reader
    /// returns to the bottom. Swapping it in underneath them shifted the page
    /// every refresh: the 400-line window slides as lines arrive, and a
    /// status line changing length re-wraps everything below it.
    @State private var pending: String?
    @FocusState private var inputFocused: Bool

    @State private var pace = PollPace()

    @State private var transcript: TranscriptBuffer?
    /// The session `transcript` was read from. A new one — `/clear`, a resume
    /// — starts the buffer over rather than appending one file to another.
    @State private var transcriptSession: AgentSessionRef?
    /// The waiting prompt as the pane shows it now, read alongside the
    /// transcript. The row's copy goes stale the moment ↑/↓ moves a highlight.
    @State private var livePrompt: String?

    /// The screen, on request. The conversation is the default wherever
    /// there is one; the screen stays a click away because it is the only
    /// place a highlighted-row menu can be seen while answering it.
    /// Remembered across windows. Its own key: an earlier build stored a
    /// "shows conversation" flag defaulting to off, and reading that would
    /// bring the old default back.
    @AppStorage("console.showsScreen") private var showsScreen = false

    /// Offered for every agent whose integration named its session and whose
    /// format AgentHQ can read. The rest get the screen, not an empty window.
    private var canShowConversation: Bool { agent?.session?.format != nil }
    private var isShowingConversation: Bool { canShowConversation && !showsScreen }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if isShowingConversation {
                conversation
            } else {
                screenView
            }

            if isShowingConversation { waitingPrompt }

            if let failure = sendFailure ?? readFailure {
                ProblemText(failure)
            }

            inputRow
        }
        .padding(10)
        .frame(minWidth: 420, minHeight: 260)
        .onAppear { inputFocused = true }
        .task { await poll() }
        .onChange(of: isShowingConversation) {
            // The other view has not been read yet; read it now, not after the
            // slowest pace has run out.
            isFollowing = true
            readFailure = nil
            pace.reset()
            Task { await reload() }
        }
    }

    // MARK: - Screen

    private var screenView: some View {
        ScrollViewReader { proxy in
            // Wrapped at a readable size rather than shrunk to fit: a
            // pane is laid out for its own terminal, often 190 columns,
            // and fitting that into a small window took the text below
            // anything legible.
            ScrollView(.vertical) {
                Text(screen.isEmpty ? " " : screen)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(1.5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
                    .id("screen")
            }
            .followsBottom($isFollowing)
            .onChange(of: screen) {
                if isFollowing { proxy.scrollTo("screen", anchor: .bottom) }
            }
            .onChange(of: isFollowing) {
                // Back at the bottom: take whatever arrived meanwhile.
                if isFollowing, let pending { screen = pending; self.pending = nil }
            }
            .onAppear { proxy.scrollTo("screen", anchor: .bottom) }
            .overlay(alignment: .bottomTrailing) {
                if pending != nil {
                    ActionButton(title: "New output ↓", emphasis: .prominent) {
                        isFollowing = true
                        proxy.scrollTo("screen", anchor: .bottom)
                    }
                    .padding(10)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: - Conversation

    /// The agent's own transcript: what was said and which tools ran, without
    /// the terminal's furniture. The screen stays one click away for what the
    /// agent is showing right now — a prompt, a diff, a spinner.
    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let entries = transcript?.entries, !entries.isEmpty {
                        ForEach(entries) { TranscriptRow(entry: $0) }
                    } else if readFailure == nil {
                        Text(transcript == nil ? "Reading the conversation…" : "Nothing said yet.")
                            .font(Brand.body)
                            .foregroundStyle(Brand.secondaryText)
                    }
                    Color.clear.frame(height: 1).id("conversation-end")
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .followsBottom($isFollowing)
            // Appending turns grows the list below the reader, so unlike the
            // screen nothing needs holding back: the page above does not move.
            .onChange(of: transcript?.entries.count) {
                if isFollowing { proxy.scrollTo("conversation-end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("conversation-end", anchor: .bottom) }
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    /// What the agent is waiting on, pinned above the input while it waits.
    ///
    /// The transcript has the conversation but not the live prompt: a
    /// highlighted-row menu, an approval footer, a question drawn by the TUI
    /// exists only on the screen. Without it the keys below would be pressed
    /// blind. It is read from the same output the state came from, so the two
    /// cannot disagree — but it is the whole prompt, not the row's six-line
    /// excerpt, which cut a four-option question down to its last options and
    /// lost the `❯` saying which one enter would take.
    @ViewBuilder private var waitingPrompt: some View {
        if let agent, agent.state == .needsApproval || agent.state == .needsInput,
           let message = livePrompt ?? agent.prompt ?? agent.message ?? agent.reason {
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Brand.color(for: agent.state))
                    .frame(width: 3)
                Text(Self.markingHighlight(in: message, color: Brand.color(for: agent.state)))
                    .font(Brand.mono)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Brand.chipFill)
            )
        }
    }

    /// Emphasize the row a menu has highlighted — the one enter takes.
    ///
    /// Keyed on the `❯` the agent itself drew, which moves with ↑/↓; nothing
    /// is marked where the prompt drew none. A lone `❯` at the start of a line
    /// only: the same glyph also prefixes the user's echoed message above a
    /// Claude Code menu, which the prompt block already excludes.
    static func markingHighlight(in prompt: String, color: Color) -> AttributedString {
        var text = AttributedString()
        let lines = prompt.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            var run = AttributedString(String(line))
            if line.drop(while: { $0 == " " }).hasPrefix("❯") {
                run.foregroundColor = color
                run.inlinePresentationIntent = .stronglyEmphasized
            }
            text += run
            if index < lines.count - 1 { text += AttributedString("\n") }
        }
        return text
    }

    // MARK: - Input

    private var inputRow: some View {
        HStack(spacing: 6) {
            TextField("Message — Return sends", text: $input)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .focused($inputFocused)
                .onSubmit { submit() }
            GlassCluster {
                ActionButton(title: "esc") { press("esc") }
                ActionButton(title: "↑") { press("up") }
                ActionButton(title: "↓") { press("down") }
                ActionButton(title: "tab") { press("tab") }
                if !isShowingConversation {
                    // Paging moves the agent's own view, which only the
                    // screen shows.
                    ActionButton(title: "pgup") { page(.up) }
                        .help("Page the agent's own view up")
                    ActionButton(title: "pgdn") { page(.down) }
                        .help("Page down — back to the latest message")
                }
                ActionButton(title: "enter") { press("enter") }
            }
        }
        .disabled(isSending)
    }

    private var agent: Agent? {
        fleet.snapshot.machines
            .first { $0.machine.id == ref.machine }?
            .agents.first { $0.ref == ref }
    }

    @ViewBuilder private var header: some View {
        HStack(spacing: 6) {
            if let agent {
                Circle()
                    .fill(Brand.color(for: agent.state))
                    .frame(width: 7, height: 7)
                Text(Brand.label(for: agent.state).uppercased())
                    .font(Brand.sectionLabel)
                    .foregroundStyle(Brand.color(for: agent.state))
                Text("\(agent.provider) · \(agent.project)")
                    .font(Brand.body)
                    .foregroundStyle(Brand.secondaryText)
                    .lineLimit(1)
            } else {
                Text("Agent no longer listed")
                    .font(Brand.body)
                    .foregroundStyle(Brand.secondaryText)
            }
            Spacer()
            if isSending {
                Text("sending…").font(Brand.sectionLabel).foregroundStyle(Brand.secondaryText)
            }
            if canShowConversation {
                Picker("", selection: $showsScreen) {
                    Text("Conversation").tag(false)
                    Text("Screen").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .controlSize(.small)
                .help("The agent's own transcript, or the terminal as it stands")
            }
        }
    }

    /// Read the pane at the pace it is changing.
    ///
    /// A poll, because herdr has nothing to push: measured against 0.9.1, a
    /// pane writing a line every half second raised no `pane_updated` at all
    /// (no event carries output), and `pane.output_matched` fires once
    /// on its first match and never again. So the console asks — and a read
    /// is one request on one connection (invariant 5), ~115ms through a
    /// tunnel, per open console — which is why it backs off while nothing
    /// moves, and stops while nobody can see it.
    private func poll() async {
        var lastState = agent?.state
        var markedFinished = false
        var wasVisible = true
        while !Task.isCancelled {
            let state = agent?.state
            if state != lastState {
                pace.reset()
                lastState = state
                // A new state is a new prompt, or none; the last one's
                // highlight says nothing about it.
                livePrompt = nil
            }
            // A completion shown in an open console has been seen, whether it
            // was there when the window opened or landed while it was open.
            // Once per completion: markViewed resyncs the fleet.
            if state == .finished {
                if !markedFinished, isVisible() {
                    await fleet.markViewed(ref)
                    markedFinished = true
                }
            } else {
                markedFinished = false
            }
            let visible = isVisible()
            // Uncovered again: the reader is back, and what they want first
            // is whatever happened while they were away.
            if visible, !wasVisible { pace.reset() }
            wasVisible = visible
            if visible {
                let changed = await reload()
                if changed { pace.reset() } else { pace.settle() }
            }
            try? await Task.sleep(for: pace.interval)
        }
    }

    /// Whether what the window shows differed from the last read.
    @discardableResult
    private func reload() async -> Bool {
        guard isShowingConversation else { return await reloadScreen() }
        let conversation = await reloadConversation()
        let prompt = await reloadPrompt()
        return conversation || prompt
    }

    /// Re-read the pinned prompt while the agent waits. The screen view needs
    /// no such thing: it is the pane, and shows the highlight move by itself.
    private func reloadPrompt() async -> Bool {
        guard let state = agent?.state, state == .needsInput || state == .needsApproval else {
            livePrompt = nil
            return false
        }
        // A failed read keeps the last prompt: the row's copy is older still.
        guard let read = try? await fleet.prompt(for: ref), read != livePrompt else { return false }
        livePrompt = read
        return true
    }

    private func reloadConversation() async -> Bool {
        do {
            let session = agent?.session
            if session != transcriptSession {
                transcript = nil
                transcriptSession = session
            }
            guard let (read, format) = try await readTranscript() else {
                readFailure = "This agent's transcript cannot be read."
                return false
            }
            switch read {
            case .missing:
                readFailure = "The agent has not written its transcript yet, or it moved."
                return false
            case .noTool:
                readFailure = "This machine has neither sqlite3 nor python3 to read opencode's store."
                return false
            default:
                break
            }
            var buffer = transcript ?? TranscriptBuffer(format: format)
            let changed = buffer.apply(read)
            if transcript == nil || changed { transcript = buffer }
            readFailure = nil
            return changed
        } catch let error as InterventionError {
            readFailure = error.summary
        } catch {
            readFailure = "Could not read the transcript: \(error)"
        }
        return false
    }

    private func readTranscript() async throws -> (TranscriptRead, TranscriptFormat)? {
        guard let (session, read) = try await fleet.transcript(for: ref, known: transcript?.cursor ?? 0),
              let format = session.format
        else { return nil }
        // Read against a session the row no longer carries: start over.
        if session != transcriptSession {
            transcriptSession = session
            transcript = nil
            guard let (_, fresh) = try await fleet.transcript(for: ref, known: 0) else { return nil }
            return (fresh, format)
        }
        return (read, format)
    }

    private func reloadScreen() async -> Bool {
        do {
            let text = try await fleet.screen(for: ref)
            let condensed = Self.condense(text)
            let changed = condensed != (pending ?? screen)
            if isFollowing {
                if condensed != screen { screen = condensed }
                pending = nil
            } else if condensed != screen {
                pending = condensed
            }
            readFailure = nil
            return changed
        } catch let error as InterventionError {
            readFailure = error.summary
        } catch {
            readFailure = "Could not read this pane: \(error.localizedDescription)"
        }
        return false
    }

    private static let ruleLength = 48
    private static let ruleCharacters: Set<Character> = ["─", "━", "═", "-", "—", "╌", "┄", " "]

    /// The pane's screen with its empty stretches closed up.
    ///
    /// A TUI pads its layout with blank rows sized for the pane's height; in
    /// a smaller window they pushed the prompt and footer out of sight. Runs
    /// of blank rows become one, and trailing spaces go, since they would
    /// wrap into rows of nothing.
    static func condense(_ text: String) -> String {
        var lines: [Substring] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw
            while line.last?.isWhitespace == true { line = line.dropLast() }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            // A rule drawn across the pane has no break opportunity, so it
            // would wrap into two or three rows of dashes.
            if line.count > Self.ruleLength, line.allSatisfy(Self.ruleCharacters.contains) {
                line = line.prefix(Self.ruleLength)
            }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    private func submit() {
        let text = input
        act {
            try await fleet.submit(text, to: ref)
            // Cleared only once it went: a refusal leaves the words to retry.
            if input == text { input = "" }
        }
    }

    private func press(_ key: String) {
        act { try await fleet.press([key], in: ref) }
    }

    private func page(_ direction: PageDirection) {
        act { try await fleet.page(direction, in: ref) }
    }

    private func act(_ body: @escaping @MainActor () async throws -> Void) {
        isSending = true
        sendFailure = nil
        Task {
            do {
                try await body()
            } catch let error as InterventionError {
                sendFailure = error.summary
            } catch {
                sendFailure = String(describing: error)
            }
            isSending = false
            inputFocused = true
            // Having acted, the reader wants to see what it did, and the pane
            // is about to move.
            isFollowing = true
            pace.reset()
            await reload()
        }
    }
}

private extension View {
    /// Tracks whether the scroll view sits at its bottom edge. Before macOS 15
    /// there is no scroll geometry to read, and the console always follows.
    @ViewBuilder func followsBottom(_ isFollowing: Binding<Bool>) -> some View {
        if #available(macOS 15, *) {
            modifier(BottomFollowing(isFollowing: isFollowing))
        } else {
            self
        }
    }
}

/// Following stops only when the reader scrolls away, never because content
/// grew: in the instant before the scroll to the new bottom lands, the
/// geometry reads as not at the bottom, and treating that as the reader
/// leaving froze the console at random.
@available(macOS 15, *)
private struct BottomFollowing: ViewModifier {
    @Binding var isFollowing: Bool
    @State private var isScrolling = false

    func body(content: Content) -> some View {
        content
            .onScrollPhaseChange { _, phase in
                isScrolling = phase != .idle
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                if atBottom {
                    isFollowing = true
                } else if isScrolling {
                    isFollowing = false
                }
            }
    }
}

/// How long the console waits between reads.
///
/// Quick while the pane is moving, since that is when someone is watching it;
/// doubling up to a ceiling while it sits still, since an idle agent's screen
/// read every 0.8s is ~115ms of tunnel per read for nothing. Any change, any
/// key the user presses, and any state change snaps it back.
struct PollPace: Equatable {
    static let fastest: Duration = .milliseconds(800)
    static let slowest: Duration = .seconds(4)
    /// Reads that came back unchanged before slowing down at all: output
    /// arrives in bursts, and a single quiet read is usually mid-burst.
    static let graceReads = 2

    private(set) var interval: Duration = Self.fastest
    private var quietReads = 0

    mutating func reset() {
        interval = Self.fastest
        quietReads = 0
    }

    mutating func settle() {
        quietReads += 1
        guard quietReads > Self.graceReads else { return }
        interval = min(interval * 2, Self.slowest)
    }
}

/// One turn of an agent's transcript.
///
/// Neutral throughout, like every other surface that is not a state: the
/// user's words on a chip wash, the agent's as plain text, tools as one mono
/// line in secondary grey.
private struct TranscriptRow: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.role {
        case .user:
            Text(entry.text)
                .font(.system(size: 12.5, weight: .semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Brand.insetRadius, style: .continuous)
                        .fill(Brand.chipFill)
                )
        case .assistant:
            Text(Self.markdown(entry.text))
                .font(.system(size: 12.5))
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        case .tool:
            Text("▸ " + entry.text)
                .font(Brand.mono)
                .foregroundStyle(Brand.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Inline markdown only — bold, code, links — with the agent's own line
    /// breaks kept. Headings and lists stay as the agent typed them, which
    /// reads fine and cannot fail.
    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
