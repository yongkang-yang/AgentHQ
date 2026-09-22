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
/// The state is told by the *shape* of the indicator, not by a glyph inside
/// it. The first version badged the robot's corner with the state's symbol at
/// 8.5pt, and at that size working's ellipsis and finished's checkmark were
/// the same filled dot: the one distinction the bar most needs to make —
/// "still going" versus "go and look" — came down to a few pixels of interior.
/// Now a state that wants the user is a solid capsule and one that does not is
/// bare text, which reads from across the room.
///
/// Everything here draws in black on a clear background and the whole render
/// is handed to the bar as a template image. Nothing in this view chooses a
/// colour, because the bar's tint is not this view's to choose: macOS inverts
/// a template for the dark bar and again for the highlighted item, which is
/// three appearances the view would otherwise have to guess at. Shape is the
/// only channel a template has, which is why the difference is spent there.
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
        HStack(alignment: .robotFace, spacing: 4) {
            RobotHead()
                .frame(width: MenuBarMetrics.mark, height: MenuBarMetrics.mark)
                .alignmentGuide(.robotFace) { $0.height * MarkGeometry.headCentre }

            if let top, !isResting {
                StateIndicator(state: top.state, count: top.count)
            }

            // Machine trouble is not agent state (invariant 2), so it gets its
            // own mark rather than changing the indicator. A template image
            // has no colour to spend on it anyway.
            if signal.isDegraded {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11, weight: .bold))
                    .padding(.leading, 1)
            }
        }
        .symbolRenderingMode(.monochrome)
        .foregroundStyle(.black)
    }
}

enum MenuBarMetrics {
    /// The mark's drawn box.
    ///
    /// Measured against its neighbours in the bar, not picked: a 16pt glyph
    /// like the input menu's fills its box, but a fifth of this one is antenna,
    /// so at 16pt — and at the 15pt it used to be — the head read a size
    /// smaller than everything beside it. 17pt puts the head at their weight.
    static let mark: CGFloat = 17
    /// The capsule's height: the head's, less a hair, so the two read as one
    /// row of equal weight. The head is 55/73 of the mark, 12.8pt.
    ///
    /// It also has to fit. The capsule is centred on the head, which sits
    /// low in the mark's box, and anything that reaches below the box grows
    /// the image downward — and the bar centres the image, so the robot would
    /// ride up to make room. At 11pt the capsule ends just above the box's
    /// bottom edge, and the image stays the mark's height.
    static let pill: CGFloat = 12.5

    /// A bare count matches the other counts in the bar — Linear's sits at
    /// about this size. One inside the capsule runs a point smaller, because
    /// the capsule cannot grow past the head to make room for it.
    static let count: CGFloat = 13
    static let pillCount: CGFloat = 12
}

extension VerticalAlignment {
    /// The centre of the robot's head, not of its box.
    ///
    /// The box includes the antenna, so its centre is the top of the face and
    /// anything centred on it rides visibly high. Everything else in the label
    /// centres on the head instead.
    private enum RobotFace: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat {
            d[VerticalAlignment.center]
        }
    }

    static let robotFace = VerticalAlignment(RobotFace.self)
}

/// The most urgent state and how many agents are in it.
///
/// Two silhouettes. A state that wants the user — anything in Needs you, and
/// a finished run — is a solid capsule with its glyph and count knocked out
/// of it. Working is the same glyph and count, bare. Both are static; three
/// dots are the one shape that says "in progress" standing still, which is
/// all invariant 12 allows in the bar.
struct StateIndicator: View {
    let state: AgentState
    let count: Int

    /// Everything but working. Idle never gets here — see `isResting`.
    var isFilled: Bool { state != .working }

    var body: some View {
        if isFilled {
            ZStack {
                Capsule()
                content.blendMode(.destinationOut)
            }
            .fixedSize()
            // `destinationOut` erases whatever it is composited against, so
            // without this group it would punch through to the menu bar
            // itself rather than out of the capsule.
            .compositingGroup()
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 2.5) {
            Image(systemName: Brand.barGlyph(for: state))
                .font(.system(size: isFilled ? 9.5 : 11, weight: .heavy))
            Text("\(count)")
                .font(.system(
                    size: isFilled ? MenuBarMetrics.pillCount : MenuBarMetrics.count,
                    weight: isFilled ? .bold : .semibold
                ))
                .monospacedDigit()
        }
        .padding(.horizontal, isFilled ? 5.5 : 0)
        .frame(height: MenuBarMetrics.pill)
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
struct MarkGeometry {
    static let unit: CGFloat = 73
    /// The head runs y=18…73: its centre, as a fraction of the box.
    static let headCentre: CGFloat = (18 + 73) / 2 / unit

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
