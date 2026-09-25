import AgentHQKit
import SwiftUI

/// The token layer from DESIGN.md.
///
/// Views never write a raw hex value: the tokens carry the light/dark pair and
/// the measured AA contrast with them, and a colour written inline in a view
/// has neither.
enum Brand {
    // MARK: Status

    /// Six hues, one per thing a glance has to tell apart, and they are the
    /// only saturated colours in the app. Everything a user presses, and every
    /// piece of chrome, is neutral — so a colour on screen always means a
    /// state, and the eye can take in the herd without reading a word.
    ///
    /// Grouped by what the user does next, not by cause:
    ///
    /// - **Needs you** — amber. The call to action.
    /// - **Broken** — red. Crashed, tests failed, merge conflict: something
    ///   went wrong and wants looking at. Their glyphs and pill words separate
    ///   them; three neighbouring warm hues did not, at 8pt.
    /// - **Stalled** — violet. Rate limited: attention, but nothing to press.
    /// - **Working** — blue.
    /// - **Finished** — green. It used to be a second blue beside working's
    ///   navy, and the two were one colour at a glance.
    /// - **Quiet** — grey. Idle or unknown: nothing to act on.
    ///
    /// Each pair holds 4.5:1 as text on the panel and as a pill fill under
    /// ``onStateText``, in its own appearance — see `PaletteTests`.
    static func statePair(for state: AgentState) -> (light: UInt32, dark: UInt32) {
        switch state {
        case .needsApproval, .needsInput:           return (0x8A5A00, 0xFBBF24)
        case .crashed, .ciFailed, .mergeConflict:   return (0xC62828, 0xFF7B72)
        case .rateLimited:                          return (0x6D28D9, 0xB69CFF)
        case .working:                              return (0x1D4ED8, 0x6AA8FF)
        case .finished:                             return (0x137333, 0x4ADE80)
        case .idle, .unknown:                       return (0x5F666B, 0x9BA3A8)
        }
    }

    static func color(for state: AgentState) -> Color {
        let (light, dark) = statePair(for: state)
        return pair(light: light, dark: dark)
    }

    /// Text on a solid state pill. White on the light-mode state colours,
    /// near-black on the dark-mode ones: those are lifted for legibility as
    /// text on a dark panel, which makes them too light to carry white.
    static let onStateTextPair: (light: UInt32, dark: UInt32) = (0xFFFFFF, 0x111315)
    static let onStateText = pair(onStateTextPair)

    // MARK: Neutrals

    /// The one grey vocabulary for secondary text. Replaces system
    /// `.secondary`/`.tertiary`, which fall to ~3.5:1 and ~2.2:1 on small
    /// light-mode text.
    static let secondaryTextPair: (light: UInt32, dark: UInt32) = (0x5A5F64, 0xB3B8BD)
    static let secondaryText = pair(secondaryTextPair)

    /// A button's label. Primary text, not a hue: a coloured End or Reveal
    /// read as a state sitting beside the real one.
    static let actionText = Color.primary

    /// The committing button — Approve, End it. An inverted neutral: near-black
    /// in light mode, near-white in dark, with its label the other way round.
    /// It stands out by weight, which a hue could only do by borrowing a
    /// state's meaning.
    static let prominentFillPair: (light: UInt32, dark: UInt32) = (0x242424, 0xE8E8E8)
    static let prominentFill = pair(prominentFillPair)
    static let onProminentText = pair(light: 0xFFFFFF, dark: 0x111315)

    /// Something the user should read that is not an agent's state: a machine
    /// that cannot be reached, a refused click, a herdr error. Primary text
    /// behind a warning glyph — see ``ProblemText`` — never a hue. A machine
    /// going dark in red is what the Separate Axis Rule exists to prevent,
    /// and orange was one step from Needs-you amber.
    static let problemText = Color.primary
    static let problemSymbol = "exclamationmark.triangle.fill"

    /// Chrome washes: machine chips, the row card, the console's screen.
    static let chipFill = Color.primary.opacity(0.07)
    static let chipStroke = Color.primary.opacity(0.14)

    // MARK: Labels

    static func label(for state: AgentState) -> String {
        switch state {
        case .working:       return "working"
        case .needsApproval: return "needs approval"
        case .needsInput:    return "needs input"
        case .ciFailed:      return "tests failed"
        case .mergeConflict: return "merge conflict"
        case .rateLimited:   return "rate limited"
        case .finished:      return "finished"
        case .idle:          return "idle"
        case .crashed:       return "crashed"
        case .unknown:       return "unknown"
        }
    }

    /// One glyph per state, for the panel row.
    static func symbol(for state: AgentState) -> String {
        switch state {
        // An X, not an exclamation: the badge has to separate "this agent
        // died" from "this agent wants you", and at 9pt the only difference
        // the eye reliably gets is mark shape, not container shape.
        case .crashed:       return "xmark.octagon.fill"
        case .needsApproval: return "hand.raised.fill"
        // An exclamation, not a question: the bar is reporting that something
        // wants the user, and a question mark reads as the app being unsure.
        case .needsInput:    return "exclamationmark.circle.fill"
        case .mergeConflict: return "arrow.triangle.branch"
        // Paired with .finished's checkmark on purpose — the same circle, the
        // opposite mark, so "passed" and "failed" are one glance apart.
        case .ciFailed:      return "xmark.circle.fill"
        // Not an hourglass: its waist is a sub-pixel at badge size and it
        // rendered as a smudge. A pause bar survives, and "the provider
        // paused you" is the honest reading of a rate limit anyway.
        case .rateLimited:   return "pause.circle.fill"
        case .finished:      return "checkmark.circle.fill"
        // Three dots is the one shape that says "in progress" while standing
        // perfectly still, which invariant 11 requires of anything in the bar.
        case .working:       return "ellipsis.circle.fill"
        case .idle:          return "moon.zzz.fill"
        case .unknown:       return "circle.dashed"
        }
    }

    /// The glyph in the menu bar's state indicator.
    ///
    /// Bare marks, not the enclosed ones above: in the bar the glyph is either
    /// knocked out of a filled capsule, where an enclosed symbol becomes a
    /// hole with a mark floating in it, or set beside a number, where the
    /// enclosure is just a second dot. The shape family matches the panel's
    /// so a reader moving between the two sees one vocabulary.
    static func barGlyph(for state: AgentState) -> String {
        switch state {
        case .crashed:       return "xmark"
        case .needsApproval: return "hand.raised.fill"
        case .needsInput:    return "exclamationmark"
        case .mergeConflict: return "arrow.triangle.branch"
        case .ciFailed:      return "xmark"
        case .rateLimited:   return "pause.fill"
        case .finished:      return "checkmark"
        case .working:       return "ellipsis"
        case .idle:          return "moon.zzz.fill"
        case .unknown:       return "circle.dashed"
        }
    }

    // MARK: Type

    static let title = Font.system(size: 15, weight: .bold)
    static let agentName = Font.system(size: 13.5, weight: .semibold)
    static let body = Font.system(size: 12.5, weight: .medium)
    static let sectionLabel = Font.system(size: 10.5, weight: .semibold)
    static let sectionHeader = Font.system(size: 11.5, weight: .semibold)
    /// Anything measured, and the machine name — an address is read character
    /// by character.
    static let mono = Font.system(size: 10.5, weight: .medium, design: .monospaced)

    // MARK: Shape

    /// Row corners. Concentric with the panel's 28pt corner at the 14pt
    /// gutter — 28 less 14 — which is what makes a row look set into the glass
    /// rather than laid on top of it. Change one and the other goes with it;
    /// see `PanelWindowController.cornerRadius`.
    static let rowRadius: CGFloat = 14
    /// For anything nested one level inside a row.
    static let insetRadius: CGFloat = 8

    // MARK: Helpers

    private static func pair(_ hex: (light: UInt32, dark: UInt32)) -> Color {
        pair(light: hex.light, dark: hex.dark)
    }

    private static func pair(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

// MARK: - Dwell

enum DwellFormatter {
    /// Exact, never rounded up into vagueness — "waiting 4m" is information,
    /// "waiting a while" is not.
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        if total < 86_400 { return "\(total / 3600)h \((total % 3600) / 60)m" }
        return "\(total / 86_400)d"
    }
}
