import AgentHQFleet
import AgentHQKit
import AgentHQTransport
import AppKit
import SwiftUI

/// The app is a status item, not a window scene.
///
/// `MenuBarExtra` draws a nicer label for free, but it offers no way to open
/// itself, and opening the panel on a notification click is the whole point:
/// a blocked agent's notification is only useful if taking it lands on the
/// message and the reply box. An `NSStatusItem` + `NSPopover` pair can be
/// shown from anywhere.
@main
@MainActor
final class AgentHQApp: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AgentHQApp()
        app.delegate = delegate
        // Belt and braces with LSUIElement: no Dock icon even under `swift run`.
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private let fleet = FleetStore()
    private let notifier = Notifier()
    private let focus = PanelFocus()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        notifier.prepare()
        notifier.onOpen = { [weak self] ref in
            self?.focus.focus(ref)
            self?.showPanel()
        }
        fleet.onAnnouncements = { [notifier] batch in notifier.deliver(batch) }
        fleet.announcesCompletions = notifier.announcesCompletions

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PanelView(fleet: fleet, notifier: notifier, focus: focus)
        )
        self.popover = popover

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        self.statusItem = statusItem
        updateLabel()
        observeSignal()

        fleet.start(localSocketPath: LocalSocketTransport.resolveDefaultSocketPath())
    }

    @objc private func togglePanel() {
        popover.isShown ? popover.performClose(nil) : showPanel()
    }

    private func showPanel() {
        guard let button = statusItem.button, !popover.isShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - Status item

    private func updateLabel() {
        let renderer = ImageRenderer(content: MenuBarLabel(signal: fleet.signal))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage
        // The label is drawn in black on clear and marked as a template, so
        // the bar tints it from its alpha alone. This replaces reading the
        // button's appearance and picking a colour to match: that guess was
        // right for light and dark and wrong for the third case, the
        // highlighted item, which inverts under the popover. A template gets
        // all three for free, and Reduce Transparency and an accent-tinted
        // bar besides.
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = tooltip()
    }

    /// Names every conversation, since a block can only say "there is one".
    private func tooltip() -> String {
        let lines = fleet.snapshot.machines
            .filter { !$0.agentsAreStale }
            .flatMap { view in
                view.agents.map { agent in
                    "\(agent.provider) \(agent.project) — "
                        + "\(Brand.label(for: agent.state)) · \(view.machine.displayName)"
                }
            }
        return lines.isEmpty ? "AgentHQ" : lines.joined(separator: "\n")
    }

    /// `@Observable` read outside SwiftUI: re-arm on every change, or the bar
    /// freezes at whatever it showed at launch.
    private func observeSignal() {
        withObservationTracking {
            _ = fleet.signal
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.updateLabel()
                self?.observeSignal()
            }
        }
    }

    /// Without a main menu, ⌘C/⌘V in the reply field do nothing. `MenuBarExtra`
    /// installed one for free; a hand-built status item has to.
    private func installMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Quit AgentHQ",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }
}
