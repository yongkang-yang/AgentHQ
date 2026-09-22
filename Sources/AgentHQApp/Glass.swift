import SwiftUI

/// Liquid Glass, where the system has it, and the flat tonal look everywhere
/// else.
///
/// Glass is for the control layer only. The panel is the system's popover
/// material — see `PanelWindowController` — and the agent rows are content
/// sitting on it, so they stay tonal fills: glass on content is what the HIG
/// asks you not to do, and a row of glass cards reads as a row of buttons. What floats is
/// what the user presses.
///
/// The package still targets macOS 14, so every glass call is behind an
/// availability check with the pre-glass look as its fallback. None of it
/// animates on its own: `.interactive()` responds to a press and then stops,
/// which is the only kind of motion invariant 12 allows in the panel.

/// How much a button should stand out from its neighbours.
enum ActionEmphasis {
    /// The row's committing action — Approve, Send, Confirm. A filled glass
    /// capsule in a fixed tone that holds white text in both appearances.
    case prominent
    /// The committing action for something that cannot be taken back.
    case destructive
    /// Everything else: clear glass, the tint carried by the label alone.
    case standard
}

struct ActionButton: View {
    let title: String
    let tint: Color
    var emphasis: ActionEmphasis = .standard
    let action: () -> Void

    var body: some View {
        if #available(macOS 26, *) {
            glass
        } else {
            flat
        }
    }

    @available(macOS 26, *)
    @ViewBuilder private var glass: some View {
        let label = Text(title).font(Brand.sectionLabel)
        switch emphasis {
        case .prominent, .destructive:
            Button(action: action) { label }
                .buttonStyle(.glassProminent)
                .tint(emphasis == .destructive ? Brand.destructiveFill : Brand.prominentFill)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        case .standard:
            Button(action: action) { label.foregroundStyle(tint) }
                .buttonStyle(.glass)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
        }
    }

    private var flat: some View {
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

/// A run of glass controls that should read as one cluster.
///
/// Glass cannot sample other glass, so neighbouring buttons each rendered
/// alone refract each other's edges; a container renders them as one layer
/// and lets them blend where they meet.
struct GlassCluster<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) { content }
            }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

extension View {
    /// Soften the list's edges where it scrolls under the header and footer,
    /// in place of a hard rule. Before glass there is no edge effect, so the
    /// footer keeps its separator there — see `PanelView`.
    @ViewBuilder func softScrollEdges() -> some View {
        if #available(macOS 26, *) {
            scrollEdgeEffectStyle(.soft, for: .vertical)
        } else {
            self
        }
    }
}
