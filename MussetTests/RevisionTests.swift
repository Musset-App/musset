import XCTest
import SwiftUI
@testable import Musset

final class RevisionTests: XCTestCase {
    let text = "Il {++faisait ++}chaud. {--Très chaud.--} Un {~~break~>break Citroën~~} blanc. {==Le gravier==}{>>Trop vague ?<<} {>>À vérifier<<}"

    func testMarksAreRead() {
        let kinds = Revisions.marks(in: text).map(\.kind)
        XCTAssertEqual(kinds, [.insertion, .deletion, .substitution, .highlight, .comment])
    }

    func testAcceptAndRejectAll() {
        XCTAssertEqual(Revisions.resolveAll(text, accept: true), "Il faisait chaud.  Un break Citroën blanc. Le gravier ")
        XCTAssertEqual(Revisions.resolveAll(text, accept: false), "Il chaud. Très chaud. Un break blanc. Le gravier ")
    }

    func testTypingIsTracked() {
        let t = "Il fait chaud."
        // Typing a word becomes an insertion, and the caret stays inside it so the next letters join it.
        let ins = Revisions.track(text: t, range: NSRange(location: 3, length: 0), replacement: "x")!
        XCTAssertEqual(ins.text, "{++x++}")
        XCTAssertEqual(ins.caret, 7)
        let after = "Il {++x++}fait chaud."
        XCTAssertNil(Revisions.track(text: after, range: NSRange(location: 7, length: 0), replacement: "y"), "inside one's own insertion: plain typing")
        // Deleting is kept, struck through; backspacing again grows the same deletion.
        let del = Revisions.track(text: t, range: NSRange(location: 13, length: 1), replacement: "")!
        XCTAssertEqual(del.text, "{--.--}")
        let t2 = "Il fait chaud{--.--}"
        let more = Revisions.track(text: t2, range: NSRange(location: 12, length: 1), replacement: "")!
        XCTAssertEqual(more.text, "{--d.--}")
        XCTAssertEqual(more.range, NSRange(location: 12, length: 8))
        // Typing over a selection is a substitution, caret inside the new text.
        let sub = Revisions.track(text: t, range: NSRange(location: 3, length: 4), replacement: "faisait")!
        XCTAssertEqual(sub.text, "{~~fait~>faisait~~}")
        XCTAssertEqual(sub.caret, 3 + 19 - 3)
        // An edit through a mark's syntax is refused rather than breaking it.
        let blocked = Revisions.track(text: "a{++b++}c", range: NSRange(location: 2, length: 3), replacement: "")!
        XCTAssertEqual(blocked.text, "")
        XCTAssertEqual(blocked.range.length, 0)
    }

    func testPrintedTextHasNoPendingCorrections() throws {
        let typst = try Typeset.chapter("Il {++faisait ++}chaud. {--Très chaud.--}{>>Note<<}")
        XCTAssertTrue(typst.contains("Il chaud. Très chaud."), typst)
        XCTAssertFalse(typst.contains("{"), typst)
    }

    /// Real typing in the editor, in revision mode: inserting, continuing, deleting, accepting.
    @MainActor
    func testTypingInRevisionMode() {
        let bridge = EditorBridge()
        let was = bridge.trackChanges
        defer { bridge.trackChanges = was }
        let tv = ZenTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.bridge = bridge
        tv.string = "Il fait chaud."
        bridge.trackChanges = true
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.insertText("très ", replacementRange: tv.selectedRange())
        tv.insertText("très ", replacementRange: tv.selectedRange())
        XCTAssertEqual(tv.string, "Il {++très très ++}fait chaud.")
        tv.setSelectedRange(NSRange(location: 31, length: 1))
        tv.deleteBackward(nil)
        XCTAssertEqual(tv.string, "Il {++très très ++}fait chaud{--.--}")
        bridge.trackChanges = false
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        tv.decideRevision(accept: true)
        XCTAssertEqual(tv.string, "Il très très fait chaud{--.--}")
        tv.decideRevision(accept: false, all: true)
        XCTAssertEqual(tv.string, "Il très très fait chaud.")
    }

    /// The editor with corrections, rendered. MUSSET_SNAPSHOT=<dir>.
    @MainActor
    func testRevisionSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-rev-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = "Le facteur est passé vers midi, sous un {~~parapluie~>parapluie de toile~~} noir {--qui gouttait sur le seuil--}.\n\nJe revois encore la vieille malle {++en osier ++}sous la fenêtre. {==Le bruit de la pluie sur le toit==}{>>Trop attendu : quel bruit exactement ?<<} du grenier.\n"
        try text.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let session = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        session.open("01")
        let bridge = EditorBridge()
        let host = NSHostingView(rootView: ZenEditorView(session: session, bridge: bridge, fontName: Typefaces.manuscript, fontSize: 17, columnWidth: 640,
                                                          focusMode: false, typewriter: false, lineNumbers: false).frame(width: 900, height: 420))
        host.appearance = NSAppearance(named: .aqua)
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("revisions.png"))
        func png(_ view: some View, _ size: NSSize, _ name: String, _ dir: String) throws {
            let h = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            h.appearance = NSAppearance(named: .aqua)
            h.frame = NSRect(origin: .zero, size: size)
            let win = NSWindow(contentRect: h.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = h
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            let r = h.bitmapImageRepForCachingDisplay(in: h.bounds)!
            h.cacheDisplay(in: h.bounds, to: r)
            try r.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        XCTAssertEqual(bridge.pendingRevisions, 4)
        try png(RevisionBar(bridge: bridge).padding(20), NSSize(width: 760, height: 80), "revision-bar.png", dir)
    }

    func testSyntaxIsHidden() {
        let t = "Un {~~break~>break Citroën~~} et {==le gravier==}{>>Trop vague<<}."
        let hidden = Revisions.hidden(in: t).map { (t as NSString).substring(with: $0) }
        XCTAssertEqual(hidden, ["{~~", "~>", "~~}", "{==", "==}{>>Trop vague<<}"])
    }

    @MainActor
    func testEditorTools() {
        let tv = ZenTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.string = "Un break blanc."
        tv.setSelectedRange(NSRange(location: 3, length: 5))
        tv.markSubstitution("break Citroën")
        XCTAssertEqual(tv.string, "Un {~~break~>break Citroën~~} blanc.")
        tv.string = "Un break blanc."
        tv.setSelectedRange(NSRange(location: 9, length: 5))
        tv.markDeletion()
        XCTAssertEqual(tv.string, "Un break {--blanc--}.")
        tv.string = "Un break blanc."
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        tv.markInsertion(" gris")
        XCTAssertEqual(tv.string, "Un break{++ gris++} blanc.")
        tv.string = "Un break blanc."
        tv.setSelectedRange(NSRange(location: 3, length: 5))
        tv.markHighlight(comment: "Quelle marque ?")
        XCTAssertEqual(tv.string, "Un {==break==}{>>Quelle marque ?<<} blanc.")
        // The caret jumps over hidden syntax instead of stopping inside it.
        tv.setSelectedRange(NSRange(location: 1, length: 0))
        tv.setSelectedRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 6, "moving right lands after {==")
    }

    /// Highlighting a highlight again never nests the syntax: same passage does nothing, wider extends, inside narrows.
    @MainActor
    func testHighlightTwice() {
        let tv = ZenTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.string = "Les pas sur le gravier humide."
        tv.setSelectedRange(NSRange(location: 4, length: 7))           // "pas sur"
        tv.markHighlight()
        XCTAssertEqual(tv.string, "Les {==pas sur==} le gravier humide.")
        tv.setSelectedRange(NSRange(location: 7, length: 7))           // "pas sur" inside the mark
        tv.markHighlight()
        XCTAssertEqual(tv.string, "Les {==pas sur==} le gravier humide.", "same passage: nothing")
        let end = NSMaxRange((tv.string as NSString).range(of: "gravier"))
        tv.setSelectedRange(NSRange(location: 7, length: end - 7))     // "pas sur==} le gravier": wider
        tv.markHighlight()
        XCTAssertEqual(Revisions.marks(in: tv.string).count, 1)
        XCTAssertEqual(Revisions.resolveAll(tv.string, accept: true), "Les pas sur le gravier humide.")
        XCTAssertTrue(tv.string.contains("{==pas sur le gravier==}"), tv.string)
        let m = Revisions.marks(in: tv.string)[0]
        tv.setSelectedRange(NSRange(location: m.first.location + 4, length: 3))  // "sur": narrower
        tv.markHighlight(comment: "Quel bruit ?")
        XCTAssertEqual(tv.string, "Les pas {==sur==}{>>Quel bruit ?<<} le gravier humide.")
        // Other tools refuse to nest.
        let before = tv.string
        tv.setSelectedRange(NSRange(location: 11, length: 3))
        tv.markDeletion()
        XCTAssertEqual(tv.string, before)
    }
}
