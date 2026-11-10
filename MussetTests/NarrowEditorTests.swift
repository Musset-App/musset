import AppKit
import XCTest
@testable import Musset

@MainActor
final class NarrowEditorTests: XCTestCase {
    /// Regression: with the sidebar, Notes, chat and minimap open, the editor got narrower than its margins,
    /// the text container width went to zero or below, and TextKit 2 looped forever in layout.
    func testVeryNarrowEditorStillLaysOut() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        let tv = ZenTextView(usingTextLayoutManager: false)
        tv.frame = scroll.bounds
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        scroll.documentView = tv
        window.contentView = scroll
        tv.string = "# Rue Hautefeuille\n\nNous n'étions plus que trois. Ma mère, mon père et moi, dans un appartement un peu étrange sur deux niveaux.\n"
        tv.restyle()
        window.makeKeyAndOrderFront(nil)
        for width: CGFloat in [300, 120, 90, 40, 0, 200] {
            scroll.setFrameSize(NSSize(width: width, height: 500))
            tv.setFrameSize(NSSize(width: width, height: tv.frame.height))
            window.contentView?.layoutSubtreeIfNeeded()
            tv.layoutSubtreeIfNeeded()
            tv.display()
            XCTAssertGreaterThanOrEqual(tv.textContainer?.size.width ?? 0, 0)
        }
    }
}
