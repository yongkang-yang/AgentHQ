import AgentHQKit
import SwiftUI

/// The token layer from DESIGN.md.
///
/// Views never write a raw hex value: the tokens carry the light/dark pair and
/// the measured AA contrast with them, and a colour written inline in a view
/// has neither.
enum Brand {
    // MARK: Status

    /// Nine states, seven colours. Colour narrows the category; the pill label
    /// names the state. Past about six hues they stop being distinguishable at
    /// 8pt, so the text is load-bearing by design rather than by accident.
    static func color(for state: AgentState) -> Color {
        switch state {
        case .crashed:
            return pair(light: 0xB3261E, dark: 0xFF6B6B)      // alarm
        case .needsApproval, .needsInput:
            return pair(light: 0x8A5A00, dark: 0xFFC94D)      // needs you
        case .ciFailed, .mergeConflict:
            return pair(light: 0x9A3412, dark: 0xF59E5B)      // failure
        case .rateLimited:
            // The one cool colour in the attention group: this is the only
            // attention state the user cannot clear by acting, so it should
            // read as "stalled", not "do something".
            return pair(light: 0x00625E, dark: 0x5ED4CE)
        case .finished:
            return pair(light: 0x1E4BD2, dark: 0x6CA6FF)
        case .working:
            return pair(light: 0x1A3A69, dark: 0x8BADDC)
        case .idle, .unknown:
            // One grey for "nothing to act on". Splitting it would be an
            // eighth hue, and DESIGN.md's own limit is that past about six
            // they stop being distinguishable at 8pt — the pill label is what
            // separates these two.
            return pair(light: 0x5F666B, dark: 0x929A9F)
        }
    }

    /// Machine-level trouble. Never borrows an agent colour — a dropped tunnel
    /// is not a dead agent.
    static let machineDown = pair(light: 0xC2410C, dark: 0xFFA726)

    static let accent = pair(light: 0x8A5A00, dark: 0xFFC94D)
    static let secondaryText = pair(light: 0x5A5F64, dark: 0xB3B8BD)

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

    static func symbol(for state: AgentState) -> String {
        switch state {
        case .crashed:       return "exclamationmark.octagon.fill"
        case .needsApproval: return "hand.raised.fill"
        case .needsInput:    return "questionmark.circle.fill"
        case .mergeConflict: return "arrow.triangle.branch"
        case .ciFailed:      return "xmark.diamond.fill"
        case .rateLimited:   return "hourglass"
        case .finished:      return "checkmark.circle.fill"
        case .working:       return "circle.fill"
        case .idle:          return "pause.circle"
        case .unknown:       return "circle.dashed"
        }
    }

    // MARK: Type

    static let title = Font.system(size: 15, weight: .bold)
    static let agentName = Font.system(size: 13.5, weight: .semibold)
    static let body = Font.system(size: 12.5, weight: .medium)
    static let sectionLabel = Font.system(size: 10.5, weight: .semibold)
    /// Anything measured, and the machine name — an address is read character
    /// by character.
    static let mono = Font.system(size: 10.5, weight: .medium, design: .monospaced)

    // MARK: Helpers

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
