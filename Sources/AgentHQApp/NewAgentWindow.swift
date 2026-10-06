import AgentHQFleet
import AgentHQKit
import AppKit
import SwiftUI

/// Starts an agent in a new herdr workspace on any machine, then opens its
/// console: the way in when the work lives on a machine with no terminal on
/// this Mac drawing it, a WSL host above all.
///
/// A window rather than a sheet on the panel: the panel closes the moment
/// focus moves, and typing a path is focus moving.
@MainActor
final class NewAgentWindow {
    static let shared = NewAgentWindow()

    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?

    func open(fleet: FleetStore) {
        if let panel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "New agent"
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.contentViewController = NSHostingController(
            rootView: NewAgentView(fleet: fleet) { [weak panel] in panel?.close() }
        )
        panel.center()

        self.panel = panel
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.forget() }
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func forget() {
        panel?.contentViewController = nil
        panel = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }
}

private struct NewAgentView: View {
    let fleet: FleetStore
    let close: @MainActor () -> Void

    @AppStorage("launch.machine") private var machineID = ""
    @AppStorage("launch.agent") private var launcher: AgentLauncher = .claude
    /// Newest first, per machine: a WSL path is no use on the Mac.
    @AppStorage("launch.recentDirectories") private var recentStore = Data()
    @State private var directory = ""
    @State private var isStarting = false
    @State private var failure: String?
    @State private var note: String?

    /// Only machines that can answer: opening a workspace needs herdr there.
    private var machines: [MachineView] {
        fleet.snapshot.machines.filter { $0.machine.isEnabled && $0.reachability.isConnected }
    }

    private var selected: MachineView? {
        machines.first { $0.id.raw == machineID } ?? machines.first
    }

    private var recent: [String] {
        guard let selected else { return [] }
        return Self.decode(recentStore)[selected.id.raw] ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if machines.isEmpty {
                Text("No machine is connected.")
                    .font(Brand.body)
                    .foregroundStyle(Brand.secondaryText)
            } else {
                Picker("Machine", selection: Binding(
                    get: { selected?.id.raw ?? "" },
                    set: { machineID = $0; directory = recent.first ?? "" }
                )) {
                    ForEach(machines) { view in
                        Text(view.shortName).tag(view.id.raw)
                    }
                }

                HStack(spacing: 6) {
                    TextField("Directory", text: $directory, prompt: Text("~/project or /home/you/project"))
                        .font(Brand.mono)
                        .onSubmit(start)
                    if !recent.isEmpty {
                        Menu {
                            ForEach(recent, id: \.self) { path in
                                Button(path) { directory = path }
                            }
                        } label: {
                            Image(systemName: "clock.arrow.circlepath")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("Recent directories on \(selected?.shortName ?? "this machine")")
                    }
                }

                Picker("Agent", selection: $launcher) {
                    ForEach(AgentLauncher.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            if let failure {
                ProblemText(failure)
            } else if let note {
                Text(note)
                    .font(Brand.sectionLabel)
                    .foregroundStyle(Brand.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                if isStarting {
                    Text("starting…").font(Brand.sectionLabel).foregroundStyle(Brand.secondaryText)
                }
                Button("Cancel") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Start", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isStarting || selected == nil
                              || directory.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 440)
        .onAppear { if directory.isEmpty { directory = recent.first ?? "" } }
    }

    private func start() {
        guard !isStarting, let machine = selected else { return }
        let typed = directory.trimmingCharacters(in: .whitespaces)
        guard !typed.isEmpty else { return }
        let launcher = launcher
        isStarting = true
        failure = nil
        note = nil
        Task {
            defer { isStarting = false }
            let ref: AgentRef
            do {
                ref = try await fleet.launch(launcher, in: typed, on: machine.id)
            } catch let error as LaunchError {
                failure = error.summary
                return
            } catch let error as InterventionError {
                failure = error.summary
                return
            } catch {
                failure = String(describing: error)
                return
            }
            remember(typed, on: machine.id)
            note = "Started \(launcher.title). Waiting for herdr to see it…"
            guard await fleet.awaitAgent(ref),
                  let agent = fleet.snapshot.allAgents.first(where: { $0.ref == ref })
            else {
                note = "Started in a new herdr workspace on \(machine.shortName), "
                    + "but herdr has not reported an agent in it yet."
                return
            }
            ConsoleWindows.shared.open(
                ref,
                title: "\(agent.provider) · \(agent.project) · \(machine.shortName)",
                fleet: fleet
            )
            close()
        }
    }

    private func remember(_ path: String, on machine: MachineID) {
        var all = Self.decode(recentStore)
        var list = all[machine.raw] ?? []
        list.removeAll { $0 == path }
        list.insert(path, at: 0)
        all[machine.raw] = Array(list.prefix(8))
        recentStore = (try? JSONEncoder().encode(all)) ?? recentStore
    }

    private static func decode(_ data: Data) -> [String: [String]] {
        (try? JSONDecoder().decode([String: [String]].self, from: data)) ?? [:]
    }
}
