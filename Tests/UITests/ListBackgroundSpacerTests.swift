import XCTest
import AppKit
@testable import UI

/// The gap under the command bar must paint only itself. Views don't clip to bounds since macOS 14, so AppKit can pass a
/// dirty rect far larger than the view; filling it blanked the whole content pane in v0.2.0-beta.15.
@MainActor
final class ListBackgroundSpacerTests: XCTestCase {
    func testDrawNeverPaintsOutsideItsBounds() throws {
        let spacer = ListBackgroundSpacer(frame: NSRect(x: 0, y: 0, width: 100, height: 8))
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 100, pixelsHigh: 100,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        spacer.draw(NSRect(x: 0, y: 0, width: 100, height: 100))   // an oversized dirty rect, as AppKit may pass
        NSGraphicsContext.restoreGraphicsState()

        // Bitmap rows count from the top: row 95 is inside the 8-pt strip at the bottom, row 10 is far above it.
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x: 50, y: 95)).alphaComponent, 0.9, "the strip itself is painted")
        XCTAssertEqual(try XCTUnwrap(rep.colorAt(x: 50, y: 10)).alphaComponent, 0, "nothing above the strip is painted")
    }
}
