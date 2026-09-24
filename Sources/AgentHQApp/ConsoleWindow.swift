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
            rootView: ConsoleView(ref: ref, fleet: fleet)
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

    @State private var screen = ""
    /// Kept apart so the next successful poll cannot wipe a refusal the
    /// user has not read yet.
    @State private var sendFailure: String?
    @State private var readFailure: String?
    @State private var input = ""
    @State private var isSending = false
    @State private var isFollowing = true
    @FocusState private var inputFocused: Bool

    /// A read is one request on one connection (invariant 5), so the mirror
    /// polls at a pace a tunnelled machine can carry, only while open.
    private static let pollInterval: Duration = .milliseconds(800)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

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
                    // Only while parked at the bottom. Scrolled up to read,
                    // a jump every refresh would take the page away.
                    if isFollowing { proxy.scrollTo("screen", anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo("screen", anchor: .bottom) }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )

            if let failure = sendFailure ?? readFailure {
                Text(failure)
                    .font(Brand.sectionLabel)
                    .foregroundStyle(Brand.machineDown)
            }

            HStack(spacing: 6) {
                TextField("Message — Return sends", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($inputFocused)
                    .onSubmit { submit() }
                GlassCluster {
                    ActionButton(title: "esc", tint: Brand.secondaryText) { press("esc") }
                    ActionButton(title: "↑", tint: Brand.secondaryText) { press("up") }
                    ActionButton(title: "↓", tint: Brand.secondaryText) { press("down") }
                    ActionButton(title: "tab", tint: Brand.secondaryText) { press("tab") }
                    ActionButton(title: "enter", tint: Brand.accent) { press("enter") }
                }
            }
            .disabled(isSending)
        }
        .padding(10)
        .frame(minWidth: 420, minHeight: 260)
        .onAppear { inputFocused = true }
        .task { await poll() }
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
        }
    }

    private func poll() async {
        while !Task.isCancelled {
            await reload()
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func reload() async {
        do {
            let text = try await fleet.screen(for: ref)
            let condensed = Self.condense(text)
            if condensed != screen { screen = condensed }
            readFailure = nil
        } catch let error as InterventionError {
            readFailure = error.summary
        } catch {
            readFailure = "Could not read this pane: \(error.localizedDescription)"
        }
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
            await reload()
        }
    }
}

private extension View {
    /// Tracks whether the scroll view sits at its bottom edge. Before macOS 15
    /// there is no scroll geometry to read, and the console always follows.
    @ViewBuilder func followsBottom(_ isFollowing: Binding<Bool>) -> some View {
        if #available(macOS 15, *) {
            onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                isFollowing.wrappedValue = atBottom
            }
        } else {
            self
        }
    }
}
