import AgentHQKit
import AppKit
import SwiftUI
import Testing
@testable import AgentHQApp

@Suite("The menu bar mark is a drawn cut-out")
@MainActor
struct MenuBarMarkTests {
    /// Render the bare head the way the bar does, and read its pixels back.
    private func render(size: CGFloat = 60, scale: CGFloat = 2) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(
            content: RobotHead().frame(width: size, height: size).foregroundStyle(.black)
        )
        renderer.scale = scale
        let image = try #require(renderer.nsImage)
        let data = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: data))
    }

    /// The art this was measured from is black ink on a white rounded plate.
    /// Reintroduce that plate and the bar gets a white square no template tint
    /// can rescue — it is opaque in every appearance.
    @Test("the corners are clear: the mark is a shape, not a plate")
    func cornersAreClear() throws {
        let bitmap = try render()
        let corners = [
            (0, 0), (bitmap.pixelsWide - 1, 0),
            (0, bitmap.pixelsHigh - 1), (bitmap.pixelsWide - 1, bitmap.pixelsHigh - 1),
        ]
        for corner in corners {
            let colour = try #require(bitmap.colorAt(x: corner.0, y: corner.1))
            #expect(colour.alphaComponent == 0, "corner \(corner) is filled")
        }
    }

    /// The face is punched with `destinationOut`. Drop the `compositingGroup`
    /// that contains it and the punch still *looks* right on a white test
    /// background while actually erasing the menu bar behind the mark.
    @Test("the face is open and the eyes are inside it")
    func faceIsOpen() throws {
        let bitmap = try render()
        // The eye row, y=45.5 of the 73-unit grid — not the middle of the
        // box, which lands on the face above the eyes.
        let eyeRow = bitmap.pixelsHigh * 91 / 146

        func alpha(x: Int, y: Int) throws -> CGFloat {
            try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
        }

        // Across the middle: wall, face, eye, face, eye, face, wall.
        #expect(try alpha(x: bitmap.pixelsWide / 8, y: eyeRow) > 0.9, "left wall is missing")
        #expect(try alpha(x: bitmap.pixelsWide / 2, y: eyeRow) == 0, "between the eyes is not open")
        // The eyes sit ±10 either side of centre: 26.5 and 46.5.
        #expect(try alpha(x: bitmap.pixelsWide * 53 / 146, y: eyeRow) > 0.9, "left eye is missing")
        #expect(try alpha(x: bitmap.pixelsWide * 93 / 146, y: eyeRow) > 0.9, "right eye is missing")
    }

    /// Every measurement in the grid is mirrored about x=37 — the ears, the
    /// eyes, the antenna. A typo in one of them is invisible by eye at 15pt
    /// and obvious here.
    @Test("the mark is symmetric about its vertical centre")
    func isSymmetric() throws {
        let bitmap = try render()
        var mismatches = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide / 2, by: 2) {
                let left = try #require(bitmap.colorAt(x: x, y: y)).alphaComponent
                let mirrored = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 1 - x, y: y))
                let right = mirrored.alphaComponent
                if abs(left - right) > 0.05 { mismatches += 1 }
            }
        }
        #expect(mismatches == 0, "\(mismatches) sampled pixels differ across the axis")
    }

    /// A shape that scales by `min(width, height) / 73` draws the same mark at
    /// every size. The bar asks for 15pt; a Retina bar asks for it at 3x.
    @Test("the mark fills its frame at any size", arguments: [15.0, 32.0, 120.0])
    func fillsFrame(size: Double) throws {
        let bitmap = try render(size: size, scale: 2)
        let centreTop = try #require(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: 0))
        #expect(centreTop.alphaComponent > 0.5, "the antenna does not reach the top at \(size)pt")
    }
}

@Suite("Every state names a symbol the system can actually draw")
struct StateSymbolTests {
    /// A misspelled SF Symbol name is not a compile error and not a crash: the
    /// image is simply nil and the badge draws as nothing. This is the only
    /// place that catches it.
    @Test("each state's badge resolves to a real SF Symbol", arguments: AgentState.allCases)
    func symbolResolves(state: AgentState) {
        let name = Brand.symbol(for: state)
        #expect(
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
            "\(state) names \(name), which SF Symbols does not have"
        )
    }
    @Test("each state's bar glyph resolves to a real SF Symbol", arguments: AgentState.allCases)
    func barGlyphResolves(state: AgentState) {
        let name = Brand.barGlyph(for: state)
        #expect(
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
            "\(state) names \(name), which SF Symbols does not have"
        )
    }
}
