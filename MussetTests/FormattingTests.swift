import SwiftUI
import XCTest
@testable import Musset

@MainActor
final class FormattingTests: XCTestCase {
    private func view(_ text: String, select: NSRange) -> ZenTextView {
        let tv = ZenTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.string = text
        tv.setSelectedRange(select)
        return tv
    }

    func testBoldAndItalicToggle() {
        let tv = view("Il pleuvait sur Nice.", select: NSRange(location: 3, length: 8))
        tv.toggleInline("**")
        XCTAssertEqual(tv.string, "Il **pleuvait** sur Nice.")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 8))
        tv.toggleInline("**")
        XCTAssertEqual(tv.string, "Il pleuvait sur Nice.", "the same command removes it")
        tv.toggleInline("*")
        XCTAssertEqual(tv.string, "Il *pleuvait* sur Nice.")
        let empty = view("Nice", select: NSRange(location: 4, length: 0))
        empty.toggleInline("*")
        XCTAssertEqual(empty.string, "Nice**")
        XCTAssertEqual(empty.selectedRange().location, 5, "the caret goes between the markers")
    }

    func testHeadingsQuoteAndFootnote() {
        let tv = view("Titre\nTexte.", select: NSRange(location: 2, length: 0))
        tv.setHeading(2)
        XCTAssertEqual(tv.string, "## Titre\nTexte.")
        tv.setHeading(1)
        XCTAssertEqual(tv.string, "# Titre\nTexte.")
        tv.setHeading(1)
        XCTAssertEqual(tv.string, "Titre\nTexte.", "the same level again makes it text")
        let q = view("Une phrase.", select: NSRange(location: 0, length: 0))
        q.toggleQuote()
        XCTAssertEqual(q.string, "> Une phrase.")
        q.toggleQuote()
        XCTAssertEqual(q.string, "Une phrase.")
        let f = view("Le Kawai", select: NSRange(location: 8, length: 0))
        f.insertFootnote()
        XCTAssertEqual(f.string, "Le Kawai^[]")
        XCTAssertEqual(f.selectedRange().location, 10)
    }

    func testFootnotesPrint() throws {
        let typst = try Typeset.chapter("Le Kawai^[Un quart de queue, *noir*.] trônait.")
        XCTAssertTrue(typst.contains("Kawai#footnote[Un quart de queue, #emph[noir].] trônait."), typst)
    }
}

/// Typing restyles the paragraphs it touches, not the chapter: what that leaves must be what a whole pass leaves.
@MainActor
final class ParagraphRestyleTests: XCTestCase {
    private static let sample = [
        "# Le pont",
        "Il **pleuvait** sur *Nice* et sur __tout__ le _reste_.^[Une note de bas de page.]",
        "<!-- scene: La gare -->",
        "Elle attendait. <!-- vérifier l'heure --> Le train {++n'++}arrivait {--jamais--} à {~~l'heure~>temps~~}{@Jean}.",
        "> Une citation *soulignée*.",
        "* * *",
        "",
        "",
        "Après la coupure, {==un passage==}{>>à revoir<<} et {>>un mot<<}.",
        "<!-- une note",
        "sur plusieurs",
        "paragraphes --> puis le texte reprend **fort**.",
        "Une correction {++qui court",
        "sur deux paragraphes++} et s'arrête.",
        "## Suite",
        "Dernier paragraphe, *sans* fin de ligne",
    ].joined(separator: "\n")

    private func editor(_ text: String) -> ZenTextView {
        let tv = ZenTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.theme = EditorTheme(fontName: Typefaces.manuscript, fontSize: 17)
        tv.string = text
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.restyle()
        return tv
    }

    /// The text styled from scratch, with the caret where the editor has it.
    private func whole(_ tv: ZenTextView) -> NSAttributedString {
        let fresh = NSTextStorage(string: tv.string)
        MarkdownStyler.style(fresh, theme: tv.theme, caret: tv.selectedRange().location)
        return fresh
    }

    private func check(_ tv: ZenTextView, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let want = whole(tv), got = tv.textStorage!
        guard !got.isEqual(to: want) else { return }
        var at = 0
        while at < got.length {
            var r = NSRange()
            let a = got.attributes(at: at, effectiveRange: &r)
            let b = want.attributes(at: at, effectiveRange: nil)
            if !(a as NSDictionary).isEqual(to: b) { break }
            at += 1
        }
        let ns = tv.string as NSString
        let around = ns.substring(with: NSRange(location: max(0, at - 12), length: min(ns.length - max(0, at - 12), 30)))
        XCTFail("\(what): differs from a whole pass at \(at) (« \(around) »)", file: file, line: line)
    }

    private func type(_ tv: ZenTextView, _ s: String, at range: NSRange) {
        tv.insertText(s, replacementRange: range)
        tv.restyleAfterEdit()
    }

    private func place(_ tv: ZenTextView, of needle: String, offset: Int = 0) -> Int {
        (tv.string as NSString).range(of: needle).location + offset
    }

    func testTypingInAParagraphRestylesOnlyThatParagraph() {
        let tv = editor(Self.sample)
        check(tv, "loaded")
        let before = tv.wholePasses
        // In plain words, in bold, in a title, in a quote, in a footnote, in a single-line note, in single-line corrections.
        for needle in ["pleuvait", "Nice", "pont", "citation", "bas de page", "attendait", "Dernier", "vérifier", "arrivait", "jamais", "temps", "passage", "revoir"] {
            let at = place(tv, of: needle, offset: 2)
            let passes = tv.wholePasses
            type(tv, "x", at: NSRange(location: at, length: 0))
            XCTAssertEqual(tv.wholePasses, passes, "« \(needle) »")
            check(tv, "typed in « \(needle) »")
            type(tv, "", at: NSRange(location: at, length: 1))
            check(tv, "deleted in « \(needle) »")
        }
        XCTAssertEqual(tv.wholePasses, before, "typing in a paragraph never restyles the chapter")
    }

    func testMarkupTypedAndRemoved() {
        let tv = editor(Self.sample)
        // Emphasis made and broken.
        var at = place(tv, of: "attendait")
        type(tv, "*", at: NSRange(location: at, length: 0)); check(tv, "opening star")
        type(tv, "*", at: NSRange(location: at + 10, length: 0)); check(tv, "closing star")
        type(tv, "", at: NSRange(location: at, length: 1)); check(tv, "star removed")
        // A title made, deepened, unmade.
        at = place(tv, of: "> Une citation")
        type(tv, "# ", at: NSRange(location: at, length: 0)); check(tv, "title made")
        type(tv, "#", at: NSRange(location: at, length: 0)); check(tv, "title deepened")
        type(tv, "", at: NSRange(location: at, length: 3)); check(tv, "title unmade")
        // A paragraph split and joined: the second half starts with a title mark.
        at = place(tv, of: "sur *Nice*")
        type(tv, "\n# ", at: NSRange(location: at, length: 0)); check(tv, "split into a title")
        type(tv, "", at: NSRange(location: at, length: 1)); check(tv, "joined back")
        // The scene marker's title, then the marker broken and mended.
        at = place(tv, of: "La gare")
        type(tv, "Vers ", at: NSRange(location: at, length: 0)); check(tv, "scene title")
        at = place(tv, of: "<!-- scene")
        type(tv, "", at: NSRange(location: at, length: 1)); check(tv, "scene marker broken")
        type(tv, "<", at: NSRange(location: at, length: 0)); check(tv, "scene marker mended")
        // Blank paragraphs under a scene break belong to it.
        at = place(tv, of: "* * *\n", offset: 6)
        type(tv, "x", at: NSRange(location: at, length: 0)); check(tv, "typed under the break")
        type(tv, "", at: NSRange(location: at, length: 1)); check(tv, "blank again under the break")
        at = place(tv, of: "* * *")
        type(tv, "", at: NSRange(location: at, length: 1)); check(tv, "break unmade")
        type(tv, "*", at: NSRange(location: at, length: 0)); check(tv, "break made")
        // The note over several paragraphs: opened, closed, written in.
        at = place(tv, of: "<!-- une note")
        type(tv, "", at: NSRange(location: at, length: 1)); check(tv, "long note opened up")
        type(tv, "<", at: NSRange(location: at, length: 0)); check(tv, "long note closed again")
        type(tv, "x", at: NSRange(location: place(tv, of: "plusieurs"), length: 0)); check(tv, "typed inside the long note")
        type(tv, " -->", at: NSRange(location: place(tv, of: "une note", offset: 8), length: 0)); check(tv, "long note cut short")
        // The correction over two paragraphs, and a new one typed.
        type(tv, "x", at: NSRange(location: place(tv, of: "deux paragraphes"), length: 0)); check(tv, "typed inside the long correction")
        at = place(tv, of: "{++qui")
        type(tv, "", at: NSRange(location: at, length: 1)); check(tv, "long correction undone")
        type(tv, "{", at: NSRange(location: at, length: 0)); check(tv, "long correction back")
        // A character before a mark that a closing token further on would pair with.
        at = place(tv, of: "Elle attendait")
        type(tv, "{--", at: NSRange(location: at, length: 0)); check(tv, "an opening mark typed before others")
        at = place(tv, of: "Dernier")
        type(tv, "{++mot++} ", at: NSRange(location: at, length: 0)); check(tv, "correction typed")
        // Paste over a selection, several paragraphs at once; the start and the end of the text.
        at = place(tv, of: "Après")
        type(tv, "Un *paragraphe*.\n## Un titre\n<!-- scene: Collée -->\nEt **la suite**", at: NSRange(location: at, length: 5)); check(tv, "pasted")
        type(tv, "Début. ", at: NSRange(location: 0, length: 0)); check(tv, "typed at the start")
        type(tv, "\n", at: NSRange(location: (tv.string as NSString).length, length: 0)); check(tv, "new paragraph at the end")
        type(tv, "Fin *ici*", at: NSRange(location: (tv.string as NSString).length, length: 0)); check(tv, "typed at the end")
        type(tv, "", at: NSRange(location: 0, length: (tv.string as NSString).length)); check(tv, "everything deleted")
        type(tv, "Un *mot*", at: NSRange(location: 0, length: 0)); check(tv, "typed in an empty chapter")
    }

    func testTheCaretsParagraphUnfoldsAlone() {
        let tv = editor(Self.sample)
        let before = tv.wholePasses
        for needle in ["pleuvait", "La gare", "citation", "Dernier", "pont", "fort", "Suite"] {
            tv.setSelectedRange(NSRange(location: place(tv, of: needle), length: 0))
            tv.restyleCaret()
            check(tv, "caret in « \(needle) »")
        }
        XCTAssertLessThanOrEqual(tv.wholePasses - before, 2, "only entering and leaving the long note's last paragraph need the whole pass")
        // Under the scene break, then in the long note: whatever the pass, the result is the whole pass's.
        for needle in ["* * *\n", "plusieurs", "deux paragraphes"] {
            tv.setSelectedRange(NSRange(location: place(tv, of: needle, offset: needle.count), length: 0))
            tv.restyleCaret()
            check(tv, "caret after « \(needle) »")
        }
    }

    /// The editor as the app builds it, on a book in a temporary folder: a letter typed goes through the editor's own
    /// path (its delegate, the session, the proofreader) and restyles its paragraph only.
    func testTypingInTheRealEditorRestylesAParagraph() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-typing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try ParagraphCodec.encode(Self.sample).write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One")])
        m.lang = "fr"
        try BookStore(root: root).saveManifest(m)
        let session = BookSession(root: root, manifest: m)
        let bridge = EditorBridge(), proof = AutoProofreader()
        proof.enabled = true; proof.autoCorrect = false; proof.typography = false
        proof.bridge = bridge; bridge.proof = proof
        proof.attach(session)
        let host = NSHostingView(rootView: ZenEditorView(session: session, bridge: bridge, fontName: Typefaces.manuscript, fontSize: 17, columnWidth: 640,
                                                          focusMode: false, typewriter: false, lineNumbers: true).frame(width: 900, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let tv = try XCTUnwrap(bridge.textView)
        XCTAssertEqual(tv.string, session.text)
        let passes = tv.wholePasses
        for needle in ["pleuvait", "citation", "Dernier"] {
            let at = (tv.string as NSString).range(of: needle).location + 2
            tv.insertText("x", replacementRange: NSRange(location: at, length: 0))
            XCTAssertEqual(session.text, tv.string, "the session has what was typed")
            let after = NSAttributedString(attributedString: tv.textStorage!)
            XCTAssertEqual(tv.wholePasses, passes, "typed in « \(needle) »: no whole pass")
            XCTAssertEqual(tv.lineNumber(at: (tv.string as NSString).range(of: "## Suite").location), 15, "line numbers follow the text")
            let fresh = NSTextStorage(string: tv.string)
            MarkdownStyler.style(fresh, theme: tv.theme, caret: tv.selectedRange().location)
            XCTAssertTrue(after.isEqual(to: fresh), "typed in « \(needle) »: as a whole pass leaves it")
        }
        // A paragraph added above moves the numbers below.
        tv.insertText("Un paragraphe.\n", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(tv.lineNumber(at: (tv.string as NSString).range(of: "## Suite").location), 16)
        withExtendedLifetime((window, proof)) {}
    }

    // MARK: The end of a long chapter

    /// The editor as the app builds it, in a window on screen, on a long chapter in a temporary folder.
    private func longChapterEditor(typewriter: Bool, focus: Bool) throws -> (ZenTextView, NSWindow, BookSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-end-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let paragraph = "Il pleuvait sur la ville depuis le matin, et *personne* ne semblait s'en soucier ; les passants allaient **vite**, le col relevé, sans un regard pour la mer. "
        let text = (0..<120).map { String(repeating: paragraph, count: 2 + $0 % 3) }.joined(separator: "\n")
        try ParagraphCodec.encode(text).write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One")])
        m.lang = "fr"
        try BookStore(root: root).saveManifest(m)
        let session = BookSession(root: root, manifest: m)
        let bridge = EditorBridge()
        let host = NSHostingView(rootView: ZenEditorView(session: session, bridge: bridge, fontName: Typefaces.manuscript, fontSize: 17, columnWidth: 640,
                                                          focusMode: focus, typewriter: typewriter, lineNumbers: true).frame(width: 900, height: 700))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        let tv = try XCTUnwrap(bridge.textView)
        objc_setAssociatedObject(tv, "bridge", bridge, .OBJC_ASSOCIATION_RETAIN)
        // The caret at the very end, as after ⌘↓.
        let end = NSRange(location: (tv.string as NSString).length, length: 0)
        tv.setSelectedRange(end)
        tv.scrollRangeToVisible(end)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        return (tv, window, session)
    }

    /// The end of the chapter is laid out, inside the page, and the caret shows. Nothing here asks for layout.
    private func checkEnd(_ tv: ZenTextView, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let lm = tv.layoutManager!, storage = tv.textStorage!
        let length = storage.length
        XCTAssertEqual(tv.selectedRange().location, length, "\(what): the caret is at the end", file: file, line: line)
        let endsOnBlank = length == 0 || storage.mutableString.character(at: length - 1) == 10
        var last = NSRect.zero
        if length > 0 {
            last = lm.lineFragmentRect(forGlyphAt: lm.numberOfGlyphs - 1, effectiveRange: nil, withoutAdditionalLayout: true)
            XCTAssertGreaterThan(last.height, 0, "\(what): the last paragraph's glyphs are laid out", file: file, line: line)
        }
        let caretLine = endsOnBlank ? lm.extraLineFragmentRect : last
        XCTAssertGreaterThan(caretLine.height, 0, "\(what): the caret's line is laid out", file: file, line: line)
        let origin = tv.textContainerOrigin
        XCTAssertGreaterThanOrEqual(tv.frame.height, caretLine.maxY + origin.y, "\(what): the page is tall enough for its last line", file: file, line: line)
        let onPage = caretLine.offsetBy(dx: origin.x, dy: origin.y)
        let visible = tv.visibleRect
        XCTAssertTrue(visible.minY <= onPage.minY + 1 && onPage.maxY - 1 <= visible.maxY,
                      "\(what): the caret's line \(onPage.minY)…\(onPage.maxY) shows in \(visible.minY)…\(visible.maxY)", file: file, line: line)
    }

    private func typeAtTheEnd(typewriter: Bool, focus: Bool, _ mode: String) throws {
        let (tv, window, session) = try longChapterEditor(typewriter: typewriter, focus: focus)
        func end() -> NSRange { NSRange(location: (tv.string as NSString).length, length: 0) }
        // Right after each change, before the layout made when the hand rests.
        for letter in ["U", "n", " ", "m", "o", "t"] {
            tv.insertText(letter, replacementRange: end())
            checkEnd(tv, "\(mode), « \(letter) » typed")
        }
        tv.insertText("\n", replacementRange: end())
        checkEnd(tv, "\(mode), Return")
        for letter in ["E", "t", " ", "l", "a", " ", "s", "u", "i", "t", "e", "."] { tv.insertText(letter, replacementRange: end()) }
        checkEnd(tv, "\(mode), a new paragraph typed")
        tv.insertText("\n", replacementRange: end())
        tv.insertText("\n", replacementRange: end())
        checkEnd(tv, "\(mode), two more Returns")
        // Several paragraphs pasted at the end, long enough to wrap and to add most of a screen.
        let pasted = (0..<6).map { "Paragraphe collé \($0), avec *un mot* et la suite qui court assez loin pour passer à la ligne, puis encore un peu plus loin que cela." }.joined(separator: "\n")
        tv.insertText(pasted, replacementRange: end())
        checkEnd(tv, "\(mode), paragraphs pasted")
        tv.insertText("\nx", replacementRange: end())
        checkEnd(tv, "\(mode), typed after the paste")
        // Once the hand has rested and the whole chapter is laid out again.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        checkEnd(tv, "\(mode), at rest")
        XCTAssertEqual(session.text, tv.string)
        tv.insertText("y", replacementRange: end())
        checkEnd(tv, "\(mode), typed again after the rest")
        // The page already had its final height: laying out the whole chapter now changes nothing.
        tv.insertText("\nEncore un paragraphe, assez long pour passer à la ligne suivante et allonger la page d'autant, puis un peu plus.", replacementRange: end())
        checkEnd(tv, "\(mode), a last paragraph")
        let height = tv.frame.height
        tv.layoutManager!.ensureLayout(for: tv.textContainer!)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(tv.frame.height, height, "\(mode): the page had its final height while typing at the end")
        window.orderOut(nil)
    }

    /// The bug the whole-chapter layout after each letter was there for: a paragraph added at the end left undrawn.
    func testTheEndOfALongChapterIsLaidOutAndShownWhileTyping() throws {
        try typeAtTheEnd(typewriter: false, focus: false, "plain")
    }

    func testTheEndOfALongChapterShowsInTypewriterMode() throws {
        try typeAtTheEnd(typewriter: true, focus: false, "typewriter")
    }

    func testTheEndOfALongChapterShowsInFocusMode() throws {
        try typeAtTheEnd(typewriter: false, focus: true, "focus")
    }

    /// The proofreader's underlines are attributes too: those of the paragraphs restyled are put back, the others stay.
    func testProofUnderlinesSurviveAParagraphRestyle() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-restyle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tv = editor("Les enfant sont partis.\nUn paragraphe *tranquille* entre les deux.\nElle a vu des pomme rouges.\nEt la fin.")
        let bridge = EditorBridge(), proof = AutoProofreader()
        proof.enabled = true; proof.autoCorrect = false; proof.typography = false
        bridge.textView = tv; bridge.proof = proof; proof.bridge = bridge; tv.bridge = bridge
        proof.attach(root: root, lang: "fr")
        proof.running = 1
        proof.receive(.success(#"[{"original":"enfant","replacement":"enfants","reason":"accord"},{"original":"pomme","replacement":"pommes","reason":"accord"}]"#),
                      batch: proof.paragraphs(of: tv.string))
        XCTAssertEqual(tv.drawnIssues.count, 2, "both faults are underlined")
        func underlined(_ word: String) -> Bool {
            let at = (tv.string as NSString).range(of: word).location
            return at != NSNotFound && tv.textStorage!.attribute(.underlineColor, at: at, effectiveRange: nil) != nil
        }
        XCTAssertTrue(underlined("enfant") && underlined("pomme"))
        let passes = tv.wholePasses
        for (needle, insert) in [("tranquille", "x"), ("fin", "y"), ("vu des", "z"), ("partis", "\n"), ("Et la", "*un* ")] {
            type(tv, insert, at: NSRange(location: place(tv, of: needle), length: 0))
            let after = NSAttributedString(attributedString: tv.textStorage!)
            tv.restyle()
            XCTAssertTrue(after.isEqual(to: tv.textStorage!), "typed in « \(needle) »: the paragraphs' pass leaves what the whole pass leaves")
        }
        XCTAssertEqual(tv.wholePasses - passes, 5, "the whole passes are the test's own, one per check")
        XCTAssertTrue(underlined("pomme") || underlined("enfant") || tv.drawnIssues.isEmpty)
        withExtendedLifetime((bridge, proof)) {}
    }

    /// Many edits in a row, anywhere, with every kind of markup: no pass is ever reset in between.
    func testRandomEditsMatchAWholePass() {
        for seed: UInt64 in [0x5EED, 7, 20_261_114] { randomEdits(seed: seed) }
    }

    private func randomEdits(seed start: UInt64) {
        var seed = start
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return n == 0 ? 0 : Int((seed >> 33) % UInt64(n))
        }
        // Mostly whole pieces, as an author types them; now and then a lone marker, which opens or closes something.
        let pieces = ["a", " ", "é", "mot ", "\n", "\n\n", "*mot*", "**fort**", "_un_", "\n# Titre\n", "\n> cité\n", "<!-- note -->", "\n<!-- scene: X -->\n",
                      "{++plus++}", "{--moins--}", "{~~a~>b~~}", "{==vu==}{>>dit<<}", "{>>seul<<}{@J}", "^[note]", "\n* * *\n", "\n---\n\n", "\u{2028}", "\t"]
        let markers = ["*", "**", "_", "# ", "> ", "<!--", "-->", "{++", "++}", "{--", "--}", "{~~", "~>", "~~}", "{==", "==}", "{>>", "<<}", "^[", "]", "{", "}", "<", "-"]
        // A chapter's worth of ordinary paragraphs around the sample: most edits fall far from what runs over paragraphs.
        let plain = (0..<24).map { "Paragraphe \($0), avec *un mot* et **un autre**, puis {++un ajout++} et la fin.^[Note \($0).]" }
        let chapter = (plain.prefix(12) + [Self.sample] + plain.suffix(12)).joined(separator: "\n")
        let tv = editor(chapter)
        var whole = 0
        for step in 0..<600 {
            let length = (tv.string as NSString).length
            let passes = tv.wholePasses
            switch next(6) {
            case 0:
                // The caret goes elsewhere, as after a click.
                tv.setSelectedRange(NSRange(location: next(length + 1), length: 0))
                tv.restyleCaret()
            case 1, 2 where length > 0:
                let at = next(length)
                let r = (tv.string as NSString).rangeOfComposedCharacterSequences(for: NSRange(location: at, length: min(length - at, 1 + next(3))))
                type(tv, "", at: r)
            default:
                let s = next(20) == 0 ? markers[next(markers.count)] : pieces[next(pieces.count)]
                let at = length == 0 ? 0 : (tv.string as NSString).rangeOfComposedCharacterSequence(at: min(next(length + 1), length - 1)).location
                type(tv, s, at: NSRange(location: at, length: 0))
            }
            whole += tv.wholePasses - passes
            check(tv, "step \(step)")
            if testRun?.failureCount ?? 0 > 0 { return }
            // A text too tangled to restyle by paragraphs any more: start again from the sample.
            if step % 40 == 39 {
                tv.string = chapter
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.restyle()
            }
        }
        XCTAssertLessThan(whole, 300, "most steps restyle paragraphs only, so they are what is checked")
    }
}
