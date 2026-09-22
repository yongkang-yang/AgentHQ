import AgentHQKit
import AppKit
import SwiftUI

/// The glance: the AgentHQ mark, the single most urgent state, and its count.
///
/// One indicator, not one per state. The bar has room for one number, and the
/// only useful one is the most urgent: a blocked agent must never be hidden
/// behind the working ones. The order is ``AgentState/severity`` — needs-input
/// before finished before working before idle — so the number that appears is
/// always the one that wants a human first.
///
/// Everything here draws in black on a clear background and the whole render
/// is handed to the bar as a template image. Nothing in this view chooses a
/// colour, because the bar's tint is not this view's to choose: macOS inverts
/// a template for the dark bar and again for the highlighted item, which is
/// three appearances the view would otherwise have to guess at.
struct MenuBarLabel: View {
    let signal: FleetSignal

    /// The state the bar reports: the most urgent one that has agents.
    private var top: MenuBarStateCount? { signal.stateCounts.first }

    /// Idle is the resting state. The mark alone says it, and a badge reading
    /// "nothing is happening" is a badge the eye learns to ignore — which
    /// costs the badge its meaning on the day it says something else.
    private var isResting: Bool {
        guard let top else { return true }
        return top.state == .idle || top.state == .unknown
    }

    var body: some View {
        HStack(spacing: 2) {
            MenuBarMark(badge: isResting ? nil : top?.state)

            if let top, !isResting {
                Text("\(top.count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }

            // Machine trouble is not agent state (invariant 2), so it gets its
            // own mark rather than colouring the badge. A template image has
            // no colour to spend on it anyway.
            if signal.isDegraded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.leading, 1)
            }
        }
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.black)
    }
}

/// The AgentHQ robot's head, with an optional state badge.
struct MenuBarMark: View {
    /// The state to badge with, or nil to draw the mark on its own.
    var badge: AgentState?

    /// The mark's drawn box. The head is square, and denser than the full
    /// robot it replaced, so 15pt reads as the same weight the old 15pt did.
    private static let mark: CGFloat = 15
    private static let badgeSize: CGFloat = 8.5

    /// The transparent gap punched through the mark around the badge.
    ///
    /// Without it the badge is unreadable. A template image is alpha only, so
    /// the badge and the mark are the same ink: a filled circle touching the
    /// head does not sit *on* it, it fuses with it into one blob. The ring is
    /// what makes the badge a separate object, and it is the reason this is
    /// hand-composited rather than a plain `.overlay`.
    private static let ring: CGFloat = 1.25

    /// The badge's outer radius — the glyph plus the gap around it. This, not
    /// the glyph, is what decides how much room the badge needs.
    private static let badgeRadius = badgeSize / 2 + ring

    /// Where the badge sits, in the mark's own coordinates: nested into the
    /// head's rounded top-right corner.
    ///
    /// The mark this replaced was a spindly full-body robot with an empty
    /// corner to drop a badge into. A head is a solid square, so there is no
    /// empty corner and the ring has to bite *something*. Sitting it on the
    /// diagonal means the bite lands on the corner's curve, which is already
    /// cut away — placed any further in it sliced a notch out of the flat top
    /// edge instead, and a square with a notch reads as a rendering bug.
    private static let badgeCenter = CGPoint(x: 16.25, y: 3.75)

    /// How far the badge reaches above the mark, and how far past its right
    /// edge. Zero with no badge, so a resting bar draws a tight 15pt square.
    private var topPad: CGFloat {
        badge == nil ? 0 : max(0, Self.badgeRadius - Self.badgeCenter.y)
    }

    private var rightPad: CGFloat {
        badge == nil ? 0 : max(0, Self.badgeCenter.x + Self.badgeRadius - Self.mark)
    }

    /// The canvas is padded *above and below* by the badge's overhang, even
    /// though the badge only reaches above.
    ///
    /// The status button centres whatever image it is handed, so the mark is
    /// centred in the bar only if it is centred in the image. Padding one side
    /// to make room for the badge and not the other hangs the mark low by half
    /// the overhang — 2.25pt here, which is invisible against an empty bar and
    /// unmistakable next to a neighbour that is centred properly.
    ///
    /// Horizontally there is no such constraint: the mark and the count are
    /// centred together as one row, so the badge's reach to the right costs
    /// nothing and is not mirrored on the left.
    private var canvasSize: CGSize {
        CGSize(width: Self.mark + rightPad, height: Self.mark + topPad * 2)
    }

    /// The badge's centre in canvas coordinates.
    private var badgeOrigin: CGPoint {
        CGPoint(x: Self.badgeCenter.x, y: Self.badgeCenter.y + topPad)
    }

    var body: some View {
        let canvas = canvasSize
        return ZStack(alignment: .topLeading) {
            // The mark, with the ring erased out of it where the badge lands.
            ZStack(alignment: .topLeading) {
                RobotHead()
                    .frame(width: Self.mark, height: Self.mark)
                    .offset(y: topPad)

                if badge != nil {
                    Circle()
                        .frame(width: Self.badgeRadius * 2, height: Self.badgeRadius * 2)
                        .position(badgeOrigin)
                        .blendMode(.destinationOut)
                }
            }
            .frame(width: canvas.width, height: canvas.height, alignment: .topLeading)
            // `destinationOut` erases whatever it is composited against, so
            // without this group it would punch a hole in the menu bar itself
            // rather than in the mark.
            .compositingGroup()

            if let badge {
                Image(systemName: Brand.symbol(for: badge))
                    // Bold, not semibold: `arrow.triangle.branch` is the one
                    // badge with no filled body, and at semibold its strokes
                    // thinned to nothing inside the ring.
                    .font(.system(size: Self.badgeSize, weight: .bold))
                    .frame(width: Self.badgeSize, height: Self.badgeSize)
                    .position(badgeOrigin)
            }
        }
        .frame(width: canvas.width, height: canvas.height)
    }
}

// MARK: - The mark

/// The robot head, drawn rather than downsampled.
///
/// This was a cut-out of the app icon's art at one resolution, which meant the
/// bar drew a 15pt image resampled from a raster — soft at 1x, and soft in a
/// way no interpolation setting fixed, because the mark's strokes are about a
/// point wide there. Every edge below is a curve the rasteriser resolves at
/// whatever size and scale factor it is handed.
struct RobotHead: View {
    var body: some View {
        RobotHeadSilhouette()
            .overlay { RobotFace().blendMode(.destinationOut) }
            // Same reason as the badge ring: `destinationOut` erases its
            // backdrop, so the face has to be punched inside a group.
            .compositingGroup()
            .overlay { RobotEyes() }
    }
}

/// Head, ears and antenna as one solid body.
///
/// One `Path` of overlapping rounded rects under the nonzero winding rule, not
/// three stacked views: stacked fills meet at two antialiased edges and leave a
/// seam down the join, which at 15pt is a visible notch where each ear meets
/// the head.
struct RobotHeadSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        let g = MarkGeometry(rect)
        var path = Path()
        path.addRoundedRect(in: g.rect(31.5, 0, 10, 26), cornerSize: g.radius(5))    // antenna
        path.addRoundedRect(in: g.rect(0, 33.5, 14, 24), cornerSize: g.radius(5))    // left ear
        path.addRoundedRect(in: g.rect(59, 33.5, 14, 24), cornerSize: g.radius(5))   // right ear
        path.addRoundedRect(in: g.rect(3.5, 18, 66, 55), cornerSize: g.radius(15))   // head
        return path
    }
}

/// The face: the opening the head's stroke encloses.
struct RobotFace: Shape {
    func path(in rect: CGRect) -> Path {
        let g = MarkGeometry(rect)
        return Path(roundedRect: g.rect(13.5, 27, 46, 37), cornerSize: g.radius(6))
    }
}

struct RobotEyes: Shape {
    func path(in rect: CGRect) -> Path {
        let g = MarkGeometry(rect)
        var path = Path()
        path.addEllipse(in: g.rect(21.5, 40.5, 10, 10))
        path.addEllipse(in: g.rect(41.5, 40.5, 10, 10))
        return path
    }
}

/// The mark's design grid: a 73×73 box, measured off the source art.
///
/// Keeping the numbers in the space they were measured in is the point. The
/// mark is centred on x=36.5 and the eyes sit ±10 either side of it; written
/// as fractions of the frame those relationships are three decimal places
/// nobody can check against the drawing they came from.
///
/// Vertically the mark is not centred: the head runs y=18…73 and the antenna
/// takes the space above it, so the eyes sit at y=45.5, well below the middle
/// of the box. Anything sampling "the centre row" of this mark finds the
/// bridge of the face, not the eyes.
private struct MarkGeometry {
    static let unit: CGFloat = 73

    let origin: CGPoint
    let scale: CGFloat

    init(_ rect: CGRect) {
        scale = min(rect.width, rect.height) / Self.unit
        origin = CGPoint(x: rect.minX, y: rect.minY)
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
        CGRect(
            x: origin.x + x * scale,
            y: origin.y + y * scale,
            width: width * scale,
            height: height * scale
        )
    }

    func radius(_ r: CGFloat) -> CGSize {
        CGSize(width: r * scale, height: r * scale)
    }
}
