import AppKit
import SwiftUI

/// The panel's window: a borderless sheet hung under the status item.
///
/// It replaced an `NSPopover`, whose corner radius is the system's to choose
/// and cannot be changed. The panel wants a 28pt corner — the radius Tahoe's
/// own menu-bar panels use, and the one the rows inside are concentric with —
/// so it draws its own. What the popover gave for free is rebuilt here, each
/// piece for a reason the popover had already been relied on for:
///
/// - It closes on a click anywhere outside it, on Escape, and when another app
///   comes forward, as a transient popover did.
/// - It grows and shrinks with its content, anchored at the top edge: the
///   agent list measures itself, and a panel whose top moved every time a row
///   appeared would slide out from under the pointer.
/// - It becomes key, or the reply field cannot take typing.
/// - The status item stays highlighted while it is open, which the bar's
///   template tinting depends on.
///
/// There is no arrow. Tahoe's menu-bar panels have none; the highlighted item
/// says where the panel came from.
///
/// And there is no shadow, by choice. The surface's tone and a hairline rim
/// are the edge — see `backdrop(around:)` and `RimView`. Two
/// shadows were tried and both were worse than none: the window server's,
/// traced from the pixels, squared off the bottom corners; a drawn one, even
/// tuned down to a tight contact shadow, read as a haze around the panel.
@MainActor
final class PanelWindowController: NSObject {
    static let cornerRadius: CGFloat = 28


    /// Gap between the bottom of the menu bar and the top of the panel.
    private static let gap: CGFloat = 6

    private let panel: GlassPanel
    private let hosting: NSHostingController<AnyView>
    private weak var anchor: NSStatusBarButton?
    private var outsideClickMonitor: Any?
    private var sizeObservation: NSKeyValueObservation?
    private var resignObserver: NSObjectProtocol?

    var isShown: Bool { panel.isVisible }

    init<Content: View>(rootView: Content) {
        hosting = NSHostingController(rootView: AnyView(rootView))
        // The window follows the SwiftUI content's own size, which is how the
        // measured list height still reaches the frame.
        hosting.sizingOptions = [.preferredContentSize]

        panel = GlassPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        // Off, not left to default: the window server's shadow is traced from
        // the window's pixels, and it traced the panel wrong — square bottom
        // corners with a hairline outline under a correctly rounded panel.
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.onCancel = { [weak self] in self?.close() }
        panel.contentView = Self.backdrop(around: hosting.view)

        sizeObservation = hosting.observe(\.preferredContentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.fitToContent() }
        }
    }

    /// The panel's surface, rounded, with the SwiftUI content inside it.
    ///
    /// The system's popover material, the surface Tahoe's own menu-bar
    /// windows sit on, not an `NSGlassEffectView`. Glass was tried first and
    /// was the wrong surface for a panel with no shadow: over a white page it
    /// rendered pure white, 255 on every channel, with or without a tint, so
    /// the panel had no edge at all. The material settles a shade off the
    /// page — around 237 on white — which is the edge. Liquid Glass stays
    /// where it belongs, on the controls that float on this surface.
    private static func backdrop(around content: NSView) -> NSView {
        let material = NSVisualEffectView()
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        // By `maskImage`, not a layer corner radius: as the window's
        // background the material is drawn by the window server, which
        // ignores the layer, and the corners came out square and opaque.
        material.maskImage = roundedMask(radius: cornerRadius)
        material.autoresizingMask = [.width, .height]

        content.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            content.topAnchor.constraint(equalTo: material.topAnchor),
            content.bottomAnchor.constraint(equalTo: material.bottomAnchor),
        ])

        let rim = RimView()
        rim.addSubview(material)
        return rim
    }

    /// A stretchable rounded rect: the corners stay `radius`, the middle
    /// stretches to whatever size the panel is.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    func show(below button: NSStatusBarButton) {
        guard !isShown else { return }
        anchor = button
        fitToContent()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)

        // Clicks in other apps never reach this one; a global monitor is the
        // only way to hear them. Clicks on the status item itself are this
        // app's and go to its toggle instead.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard isShown else { return }
        panel.orderOut(nil)
        anchor?.highlight(false)
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
    }

    /// Size to the content, keeping the top edge under the status item and
    /// the whole panel on the item's screen.
    private func fitToContent() {
        guard let button = anchor, let buttonWindow = button.window else { return }
        // Before the first layout the preferred size is still zero, and a
        // panel framed from it would open as a sliver at the screen's origin.
        var size = hosting.preferredContentSize
        if size.width <= 0 || size.height <= 0 { size = hosting.view.fittingSize }
        guard size.width > 0, size.height > 0 else { return }

        let itemFrame = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .infinite

        var x = itemFrame.midX - size.width / 2
        x = min(max(x, visible.minX + Self.gap), visible.maxX - size.width - Self.gap)
        let top = itemFrame.minY - Self.gap
        let frame = NSRect(x: x, y: top - size.height, width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }
}

/// A borderless panel that can still take keyboard focus and hear Escape.
private final class GlassPanel: NSPanel {
    var onCancel: (() -> Void)?

    // Borderless windows refuse key status by default, which would leave the
    // reply field unable to take a keystroke.
    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The panel's clip and its hairline edge.
///
/// A 0.5pt line, the width of a macOS window's own border, drawn on the
/// panel's curve. With no shadow it is what holds the edge against a page of
/// nearly the same lightness as the panel. The colour is re-resolved when the
/// appearance changes, because a layer's border is a `CGColor` and does not
/// follow light and dark mode on its own.
private final class RimView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = PanelWindowController.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.borderColor = NSColor(white: isDark ? 1 : 0, alpha: isDark ? 0.18 : 0.14).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
