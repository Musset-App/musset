import AppKit
import SwiftUI
import XCTest
@testable import Musset

@MainActor
final class ReturnKeyTests: XCTestCase {
    private let annotator = Annotator()

    private func key(_ tv: NSTextView, _ chars: String, code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: tv.window?.windowNumber ?? 0,
                                 context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        tv.keyDown(with: e)
    }

    func testReturnMakesANewParagraph() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-ret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Titre\n\nPremier paragraphe.\n\nDeuxième paragraphe.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        let bridge = EditorBridge(), proof = AutoProofreader()
        bridge.proof = proof; bridge.annotator = annotator; proof.bridge = bridge
        proof.attach(root: root, lang: "fr")
        let editor = ZenEditorView(session: session, bridge: bridge, fontName: "", fontSize: 16, columnWidth: 600,
                                   focusMode: false, typewriter: false, lineNumbers: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: editor)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        let tv = try XCTUnwrap(bridge.textView)
        window.makeFirstResponder(tv)
        print("RET start: \(tv.string.debugDescription)")
        let end = (tv.string as NSString).range(of: "Premier paragraphe.").upperBound
        tv.setSelectedRange(NSRange(location: end, length: 0))
        key(tv, "\r", code: 36)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        print("RET after return: \(tv.string.debugDescription) caret=\(tv.selectedRange().location)")
        key(tv, "N", code: 45)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        print("RET after typing: \(tv.string.debugDescription) caret=\(tv.selectedRange().location)")
        XCTAssertEqual(tv.string, "# Titre\nPremier paragraphe.\nN\nDeuxième paragraphe.\n")
        withExtendedLifetime(window) {}
    }

    /// The author's case: Inconsolata, the real chapter, Return at the very end (no final newline) and mid-paragraph.
    func testReturnAtEndOfRealChapter() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus/23_rue_hautefeuille.md")
        // The author's books are not in the public repository: without them, nothing to check here.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "no fixtures/conatus")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-ret2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("23.md"))
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "23", file: "23.md", title: "Rue")]))
        let bridge = EditorBridge(), proof = AutoProofreader()
        bridge.proof = proof; bridge.annotator = annotator; proof.bridge = bridge
        proof.attach(root: root, lang: "fr")
        let editor = ZenEditorView(session: session, bridge: bridge, fontName: "Inconsolata-Regular", fontSize: 18, columnWidth: 660,
                                   focusMode: false, typewriter: false, lineNumbers: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: editor)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let tv = try XCTUnwrap(bridge.textView)
        window.makeFirstResponder(tv)
        let before = tv.string as NSString
        print("RET2 tail: \(before.substring(from: max(0, before.length - 40)).debugDescription) first=\(window.firstResponder === tv)")
        tv.setSelectedRange(NSRange(location: before.length, length: 0))
        key(tv, "\r", code: 36)
        key(tv, "Y", code: 16)
        // Right after typing, before any idle time: the view must already be tall enough to show the new line.
        if let lm = tv.layoutManager, let tc = tv.textContainer {
            let needed = lm.usedRect(for: tc).height + tv.textContainerInset.height * 2
            print("RET2 immediate frame=\(tv.frame.height) needed=\(needed) visible=\(tv.visibleRect.maxY)")
            XCTAssertGreaterThanOrEqual(tv.frame.height + 1, needed)
            let caret = tv.firstRect(forCharacterRange: tv.selectedRange(), actualRange: nil)
            let inView = tv.convert(window.convertFromScreen(caret), from: nil)
            print("RET2 caret y=\(inView.minY) visible=\(tv.visibleRect.minY)...\(tv.visibleRect.maxY)")
            XCTAssertTrue(tv.visibleRect.insetBy(dx: 0, dy: -2).contains(NSPoint(x: tv.visibleRect.midX, y: inView.midY)))
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if let lm = tv.layoutManager {
            let lastGlyph = lm.glyphIndexForCharacter(at: (tv.string as NSString).length - 2)
            print("RET2 after-return last line=\(lm.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)) extra=\(lm.extraLineFragmentRect) usedRect=\(lm.usedRect(for: tv.textContainer!)) frame=\(tv.frame.size)")
        }
        key(tv, "X", code: 7)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        let after = tv.string as NSString
        print("RET2 tail after: \(after.substring(from: max(0, after.length - 40)).debugDescription) caret=\(tv.selectedRange().location)/\(after.length) first=\(window.firstResponder === tv)")
        XCTAssertTrue(after.hasSuffix("\nYX"))
        if let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] {
            tv.scrollRangeToVisible(NSRange(location: after.length, length: 0))
            tv.display()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("return-end.png"))
            if let lm = tv.layoutManager {
                var i = max(0, after.length - 12)
                while i < after.length {
                    let g = lm.glyphIndexForCharacter(at: i)
                    print("RET2 frag char \(i) \((after.substring(with: NSRange(location: i, length: 1))).debugDescription) rect=\(lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil))")
                    i += 1
                }
                print("RET2 extra=\(lm.extraLineFragmentRect)")
            }
        }
        // Mid-paragraph.
        // The start of a sentence near the middle: the chapter is the author's and keeps changing.
        let whole = tv.string as NSString
        let found = whole.range(of: ". ", range: NSRange(location: whole.length / 2, length: whole.length - whole.length / 2))
        XCTAssertNotEqual(found.location, NSNotFound)
        let mid = NSMaxRange(found)
        tv.setSelectedRange(NSRange(location: mid, length: 0))
        key(tv, "\r", code: 36)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let ns = tv.string as NSString
        print("RET2 mid: \(ns.substring(with: NSRange(location: mid - 20, length: 40)).debugDescription) caret=\(tv.selectedRange().location)")
        XCTAssertEqual(ns.character(at: mid), 10)
        XCTAssertEqual(tv.selectedRange().location, mid + 1)
        withExtendedLifetime(window) {}
    }

    /// The author's report: the last paragraph of the chapter laid out nowhere (not drawn, not scrollable).
    func testWholeChapterIsLaidOut() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus/23_rue_hautefeuille.md")
        // The author's books are not in the public repository: without them, nothing to check here.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.path), "no fixtures/conatus")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-lay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let live = ProcessInfo.processInfo.environment["MUSSET_LIVE_TEXT"] {
            try ParagraphCodec.encode(String(contentsOfFile: live, encoding: .utf8)).write(to: root.appendingPathComponent("23.md"), atomically: true, encoding: .utf8)
        } else {
            try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("23.md"))
        }
        // With its notes: every edit moves them, and that must not disturb layout.
        let notes = root.appendingPathComponent(".musset/notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.deletingLastPathComponent().appendingPathComponent(".musset/notes/23_rue_hautefeuille.md"), to: notes.appendingPathComponent("23.md"))
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "23", file: "23.md", title: "Rue")]))
        let bridge = EditorBridge(), proof = AutoProofreader()
        bridge.proof = proof; bridge.annotator = annotator; proof.bridge = bridge
        proof.attach(root: root, lang: "fr")
        let editor = ZenEditorView(session: session, bridge: bridge, fontName: "Inconsolata-Regular", fontSize: 18, columnWidth: 660,
                                   focusMode: false, typewriter: false, lineNumbers: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 845, height: 1000), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: editor)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let tv = try XCTUnwrap(bridge.textView)
        window.makeFirstResponder(tv)
        func check(_ label: String) {
            guard let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let n = lm.numberOfGlyphs
            var last = -1
            for g in 0..<n where lm.textContainer(forGlyphAt: g, effectiveRange: nil, withoutAdditionalLayout: true) != nil { last = g }
            print("LAY \(label): glyphs=\(n) lastLaid=\(last) firstUnlaid=\(lm.firstUnlaidCharacterIndex())")
            XCTAssertEqual(last, n - 1, label)
        }
        check("load")
        let at = (tv.string as NSString).range(of: "On était heureux.").upperBound
        tv.setSelectedRange(NSRange(location: at, length: 0))
        key(tv, "a", code: 0)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        check("typed")
        key(tv, "\u{7F}", code: 51)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        check("deleted")
        withExtendedLifetime(window) {}
    }
}
