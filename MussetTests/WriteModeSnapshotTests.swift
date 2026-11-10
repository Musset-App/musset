import XCTest
import SwiftUI
@testable import Musset

/// The Write mode on a real chapter with its notes, dark: praise keeps to its dot, underlines stop at the
/// last letter, emphasis markers fold away from the caret. MUSSET_SNAPSHOT=<dir>.
@MainActor
final class WriteModeSnapshotTests: XCTestCase {
    func testWriteModeSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-zen-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".musset/notes"), withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        try fm.copyItem(at: fixture.appendingPathComponent("24_lavilleneuve_au_roi.md"), to: root.appendingPathComponent("01.md"))
        try fm.copyItem(at: fixture.appendingPathComponent(".musset/notes/24_lavilleneuve_au_roi.json"), to: root.appendingPathComponent(".musset/notes/01.json"))
        let session = BookSession(root: root, manifest: BookManifest(title: "Le Sel", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Lavilleneuve")]))
        session.open("01")
        for revise in [false, true] {
            let bridge = EditorBridge()
            bridge.trackChanges = revise
            let host = NSHostingView(rootView: ZenEditorView(session: session, bridge: bridge, fontName: Typefaces.manuscript, fontSize: 15, columnWidth: 640,
                                                              focusMode: false, typewriter: false, lineNumbers: false).frame(width: 1000, height: 900))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(x: 0, y: 0, width: 1000, height: 900)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(revise ? "revise.png" : "write.png"))
        }
    }

    /// The * around emphasis show in the paragraph being written and fold away in the others.
    func testEmphasisMarkersFoldAwayFromTheCaret() {
        let text = "Au *Terminus* ce soir.\nPlus loin, **rien**."
        let storage = NSTextStorage(string: text)
        let theme = EditorTheme(fontName: Typefaces.manuscript, fontSize: 17)
        MarkdownStyler.style(storage, theme: theme, caret: 2)   // in the first paragraph
        let size = { (i: Int) in (storage.attribute(.font, at: i, effectiveRange: nil) as? NSFont)?.pointSize ?? 0 }
        let star = (text as NSString).range(of: "*").location
        let bold = (text as NSString).range(of: "**").location
        XCTAssertEqual(size(star), 17, "shown where the caret is")
        XCTAssertLessThan(size(bold), 1, "folded in the other paragraph")
        MarkdownStyler.style(storage, theme: theme, caret: (text as NSString).length)
        XCTAssertLessThan(size(star), 1)
        XCTAssertEqual(size(bold), 17)
    }
}
