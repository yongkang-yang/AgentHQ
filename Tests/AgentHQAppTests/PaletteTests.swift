import AgentHQKit
import Foundation
import Testing
@testable import AgentHQApp

/// The colour system's promise: a hue on screen means a state, every state
/// reads in both appearances, and no two state groups look alike.
@Suite("Colour means state, in light and dark alike")
struct PaletteTests {
    /// The panel surfaces text actually lands on: the popover material and a
    /// row card over it, per appearance. Checked against the harder of each.
    private static let lightSurfaces: [UInt32] = [0xFFFFFF, 0xF0F0F0]
    private static let darkSurfaces: [UInt32] = [0x1E1E1E, 0x2C2C2C]

    @Test("every state colour holds 4.5:1 as text on the panel, in both appearances",
          arguments: AgentState.allCases)
    func stateTextContrast(_ state: AgentState) {
        let pair = Brand.statePair(for: state)
        for surface in Self.lightSurfaces { #expect(contrast(pair.light, surface) >= 4.5) }
        for surface in Self.darkSurfaces { #expect(contrast(pair.dark, surface) >= 4.5) }
    }

    @Test("a state pill's label holds 4.5:1 on its fill, in both appearances",
          arguments: AgentState.allCases)
    func pillContrast(_ state: AgentState) {
        let pair = Brand.statePair(for: state)
        #expect(contrast(Brand.onStateTextPair.light, pair.light) >= 4.5)
        #expect(contrast(Brand.onStateTextPair.dark, pair.dark) >= 4.5)
    }

    @Test("different state groups are different hues, not shades of one")
    func groupsAreApart() {
        // One representative per group; states inside a group share a colour
        // on purpose.
        let groups: [AgentState] = [.needsInput, .crashed, .rateLimited, .working, .finished]
        for appearance in [\(light: UInt32, dark: UInt32).light, \.dark] {
            let hues = groups.map { hue(Brand.statePair(for: $0)[keyPath: appearance]) }
            for i in hues.indices {
                for j in hues.indices where j > i {
                    // Working and finished were navy and blue: 11° apart.
                    #expect(hueDistance(hues[i], hues[j]) >= 30,
                            "\(groups[i]) and \(groups[j]) are too close in hue")
                }
            }
        }
    }

    @Test("chrome is neutral, so it can never be mistaken for a state")
    func chromeIsNeutral() {
        for pair in [Brand.secondaryTextPair, Brand.prominentFillPair,
                     Brand.statePair(for: .idle)] {
            #expect(saturation(pair.light) < 0.12)
            #expect(saturation(pair.dark) < 0.12)
        }
    }

    @Test("the committing button's label holds 4.5:1 on its fill")
    func prominentContrast() {
        #expect(contrast(0xFFFFFF, Brand.prominentFillPair.light) >= 4.5)
        #expect(contrast(0x111315, Brand.prominentFillPair.dark) >= 4.5)
    }

    // MARK: - Colour arithmetic (WCAG 2.x)

    private func channels(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255)
    }

    private func luminance(_ hex: UInt32) -> Double {
        func linear(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (r, g, b) = channels(hex)
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let (hi, lo) = (max(luminance(a), luminance(b)), min(luminance(a), luminance(b)))
        return (hi + 0.05) / (lo + 0.05)
    }

    private func hue(_ hex: UInt32) -> Double {
        let (r, g, b) = channels(hex)
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 0 else { return 0 }
        let h: Double
        if high == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
        else if high == g { h = (b - r) / delta + 2 }
        else { h = (r - g) / delta + 4 }
        return (h * 60 + 360).truncatingRemainder(dividingBy: 360)
    }

    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 360 - d)
    }

    private func saturation(_ hex: UInt32) -> Double {
        let (r, g, b) = channels(hex)
        let high = max(r, g, b), low = min(r, g, b)
        return high == 0 ? 0 : (high - low) / high
    }
}
