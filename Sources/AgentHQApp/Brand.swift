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

    /// Text on a solid state pill. White on the light-mode state colours,
    /// near-black on the dark-mode ones: those are lifted for legibility as
    /// text on a dark panel, which makes them too light to carry white.
    static let onStateText = pair(light: 0xFFFFFF, dark: 0x111315)

    /// Machine-level trouble. Never borrows an agent colour — a dropped tunnel
    /// is not a dead agent.
    static let machineDown = pair(light: 0xC2410C, dark: 0xFFA726)

    // MARK: Machines

    /// Identity colours for machines, one chip per box.
    ///
    /// A machine is a second axis, so these are deliberately not the state
    /// palette: a chip that shared a hue with a state pill would read as
    /// status, which is the Separate Axis Rule. Fixed rather than adaptive
    /// because they are only ever used as a wash under primary text, which
    /// reads the same over any of them.
    static let machinePalette: [Color] = [
        Color(nsColor: NSColor(hex: 0x1D4ED8)), // blue
        Color(nsColor: NSColor(hex: 0x6D28D9)), // violet
        Color(nsColor: NSColor(hex: 0x0F766E)), // teal
        Color(nsColor: NSColor(hex: 0xB45309)), // amber
        Color(nsColor: NSColor(hex: 0xA21CAF)), // fuchsia
        Color(nsColor: NSColor(hex: 0x0E7490)), // cyan
        Color(nsColor: NSColor(hex: 0x475569)), // slate
        Color(nsColor: NSColor(hex: 0xBE123C)), // rose
        Color(nsColor: NSColor(hex: 0x15803D)), // green
        Color(nsColor: NSColor(hex: 0x78350F)), // brown
    ]

    static func machineColor(for id: MachineID) -> Color {
        machinePalette[machineColorIndex(for: id)]
    }

    /// Stable across launches: `hashValue` is seeded per process, so an id
    /// hashed with it would wear a different chip every time the app restarts.
    static func machineColorIndex(for id: MachineID) -> Int {
        stableIndex(id.raw, modulo: machinePalette.count)
    }

    // MARK: Menu bar

    /// FNV-1a with the splitmix64 finalizer.
    ///
    /// FNV alone clusters in its low bits for short, similar strings — three
    /// real machine ids all landed on the same chip — and the finalizer spreads
    /// them before the modulo.
    static func stableIndex(_ value: String, modulo: Int) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        hash ^= hash >> 33
        hash = hash &* 0xff51_afd7_ed55_8ccd
        hash ^= hash >> 33
        hash = hash &* 0xc4ce_b9fe_1a85_ec53
        hash ^= hash >> 33
        return Int(hash % UInt64(modulo))
    }

    static let accent = pair(light: 0x8A5A00, dark: 0xFFC94D)

    /// Label colours for the row's three standing actions, so each reads by
    /// colour before its word: End red, Continue/Nudge green, Reveal orange.
    ///
    /// Their own tokens rather than borrowed state or machine colours. End in
    /// Machine Down orange said "tunnel trouble"; Reveal in it would say the
    /// same. Each pair holds AA as text on the panel in its appearance,
    /// which system `.green` and `.orange` do not in light mode.
    static let endAction = pair(light: 0xB91C1C, dark: 0xF87171)
    static let continueAction = pair(light: 0x15803D, dark: 0x4ADE80)
    static let revealAction = pair(light: 0xC2410C, dark: 0xFB923C)

    /// Fills for a prominent glass button. Fixed rather than adaptive, like the
    /// machine chips: the label on them is white in both appearances, and the
    /// dark-mode state colours are light enough that white text on them fails
    /// AA. Approve Fill navy lifted a step so it still reads as a button on a
    /// dark panel, and the light-mode Alarm red.
    static let prominentFill = Color(nsColor: NSColor(hex: 0x1E4BD2))
    static let destructiveFill = Color(nsColor: NSColor(hex: 0xB3261E))
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

    /// What the button that sends `agent.prompt` should call itself.
    ///
    /// One herdr call, two different acts. On a working agent it interrupts a
    /// train of thought with a correction — a nudge. On a stopped one it is
    /// simply the next thing said, and calling *that* a nudge reads as "hurry
    /// up": the most common way to answer a finished run was labelled as
    /// pestering it, which is most of why the button looked useless.
    static func promptAction(for state: AgentState) -> String {
        state == .working ? "Nudge" : "Continue"
    }

    /// The hint in the box that button opens.
    static func promptPlaceholder(for state: AgentState) -> String {
        state == .working ? "Tell it what to do" : "Say what happens next"
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
