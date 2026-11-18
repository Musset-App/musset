import XCTest
import SwiftUI
import PDFKit
import MussetPage
@testable import Musset

/// What a book recognises in its text (Book Settings › Structure): bullet lists, numbered lists, sub-headings as
/// sections. The editor's styling and keys, the typography, the typesetter's options and the sources for pandoc.
@MainActor
final class ListsTests: XCTestCase {
    private let bullets = ListOptions()
    private let both = ListOptions(bullets: true, numbered: true)

    private func item(_ line: String, _ options: ListOptions) -> ListLines.Item? {
        ListLines.item(line as NSString, at: 0, options)
    }

    // MARK: Which lines are items

    func testBulletsAndWhatOnlyLooksLikeOne() {
        for line in ["- lait", "+ lait", "* lait", "  - lait", "-   lait"] {
            XCTAssertNotNil(item(line, bullets), line)
        }
        // A dialogue dash, a scene break, emphasis, stars, a word with a hyphen, a marker without its space.
        for line in ["— Oui, dit-il.", "– Oui.", "―  Oui", "* * *", "***", "---", "- - -", "*mot* suite", "**fort** suite", "* *", "-lait", "-", "Avant - après"] {
            XCTAssertNil(item(line, bullets), line)
        }
        XCTAssertNil(item("- lait", .none), "a book without bullet lists")
        XCTAssertNil(item("- lait", ListOptions(bullets: false, numbered: true)))
        XCTAssertEqual(item("- ", bullets)?.isEmpty, true, "an item being started")
    }

    func testNesting() {
        XCTAssertEqual(["- a", " - a", "  - a", "    - a", "      - a", "        - a", "\t- a", "\t\t- a"].map { item($0, bullets)?.level }, [0, 0, 1, 1, 2, 2, 1, 2])
        let it = item("    - lait", bullets)
        XCTAssertEqual(it?.indent, 4)
        XCTAssertEqual(it?.marker, NSRange(location: 4, length: 1))
        XCTAssertEqual(it?.text, 6)
    }

    func testNumberedListsAreTheBooksToAskFor() {
        XCTAssertNil(item("1. semer", bullets), "off: a sentence")
        XCTAssertEqual(item("1. semer", both)?.number, 1)
        XCTAssertEqual(item("1) semer", both)?.marker.length, 2)
        // A list starts at 1; another number is an item only after an item.
        XCTAssertNil(item("2. arroser", both))
        XCTAssertNil(item("36. Guerre.", both))
        let list = "Avant.\n1. semer\n2. arroser\n\n3. attendre\n    - longtemps\n4. cueillir\nAprès.\n5. rien" as NSString
        func at(_ s: String) -> ListLines.Item? { ListLines.item(list, at: list.range(of: s).location, both) }
        XCTAssertEqual(["1. semer", "2. arroser", "3. attendre", "    - longtemps", "4. cueillir"].map { at($0)?.number }, [1, 2, 3, nil, 4])
        XCTAssertNotNil(at("    - longtemps"))
        XCTAssertNil(at("5. rien"), "prose ended the list")
        XCTAssertNil(ListLines.item(list, at: list.range(of: "2. arroser").location, bullets))
    }

    /// « 1943. Barcelone. » is a sentence in every case: alone, among others, after a list, lists on or off.
    func testAYearOpensASentence() {
        for options in [ListOptions.none, bullets, both] {
            XCTAssertNil(item("1943. Barcelone.", options))
            let text = "1. un\n1943. Barcelone.\n1944. Madrid." as NSString
            XCTAssertNil(ListLines.item(text, at: 6, options))
            XCTAssertNil(ListLines.item(text, at: text.range(of: "1944").location, options))
        }
    }

    // MARK: The editor's styling

    private func editor(_ text: String, _ lists: ListOptions = ListOptions()) -> ZenTextView {
        let tv = ZenTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        var theme = EditorTheme(fontName: Typefaces.manuscript, fontSize: 17)
        theme.lists = lists
        tv.theme = theme
        tv.string = text
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.restyle()
        return tv
    }

    private func style(_ tv: ZenTextView, _ s: String) -> NSParagraphStyle {
        tv.textStorage!.attribute(.paragraphStyle, at: (tv.string as NSString).range(of: s).location, effectiveRange: nil) as! NSParagraphStyle
    }

    private func colour(_ tv: ZenTextView, _ s: String) -> NSColor {
        tv.textStorage!.attribute(.foregroundColor, at: (tv.string as NSString).range(of: s).location, effectiveRange: nil) as! NSColor
    }

    func testItemsHangAndTheirMarkersAreDimmed() {
        let text = "Un paragraphe.\n- un élément\n    - niché\n— Oui, dit-il.\n* * *\n1943. Barcelone.\n1. semer"
        let tv = editor(text)
        let faces = EditorFaces.of(tv.theme)
        let plain = style(tv, "Un paragraphe")
        XCTAssertEqual(plain.headIndent, 0)
        let item = style(tv, "- un")
        XCTAssertEqual(item.firstLineHeadIndent, 0)
        XCTAssertEqual(item.headIndent, ceil(("- " as NSString).size(withAttributes: [.font: faces.body]).width * 2) / 2, accuracy: 0.01, "wrapped lines under the text")
        XCTAssertEqual(item.paragraphSpacing, plain.paragraphSpacing)
        XCTAssertEqual(colour(tv, "- un"), faces.faint)
        XCTAssertEqual(colour(tv, "un élément"), faces.ink)
        let nested = style(tv, "    - niché")
        XCTAssertGreaterThan(nested.headIndent, item.headIndent + 10)
        // Dialogue, a scene break, a year, a numbered line in a book without numbered lists: as they were.
        for s in ["— Oui", "1943", "1. semer"] {
            XCTAssertEqual(style(tv, s).headIndent, 0, s)
            XCTAssertEqual(colour(tv, s), faces.ink, s)
        }
        XCTAssertEqual(style(tv, "* * *").alignment, .center)

        let numbered = editor(text, both)
        XCTAssertGreaterThan(style(numbered, "1. semer").headIndent, 0)
        XCTAssertEqual(colour(numbered, "1. semer"), faces.faint)
        XCTAssertEqual(style(numbered, "1943").headIndent, 0)
        XCTAssertEqual(colour(numbered, "1943"), faces.ink)

        let off = editor(text, .none)
        XCTAssertEqual(style(off, "- un").headIndent, 0, "bullet lists off: a dash line is a paragraph")
        XCTAssertEqual(colour(off, "- un"), faces.ink)
    }

    /// Typing restyles the paragraphs touched as a whole pass would: a numbered list below a line that starts or
    /// stops being its first item follows.
    func testAParagraphRestyledAloneComesOutAsInAWholePass() {
        let tv = editor("Avant.\n1. semer\n2. arroser\n3. attendre\nAprès, un paragraphe.\n- un\n- deux", both)
        func check(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
            let fresh = NSTextStorage(string: tv.string)
            MarkdownStyler.style(fresh, theme: tv.theme, caret: tv.selectedRange().location)
            XCTAssertTrue(tv.textStorage!.isEqual(to: fresh), what, file: file, line: line)
        }
        let passes = tv.wholePasses
        func type(_ s: String, at needle: String, replacing length: Int = 0) {
            let at = (tv.string as NSString).range(of: needle).location
            tv.insertText(s, replacementRange: NSRange(location: at, length: length))
            tv.restyleAfterEdit()
        }
        type("x", at: "1. semer")
        XCTAssertEqual(style(tv, "2. arroser").headIndent, 0, "no first item: the lines below are sentences")
        check("the list's first marker broken")
        type("", at: "x1. semer", replacing: 1)
        XCTAssertGreaterThan(style(tv, "3. attendre").headIndent, 0)
        check("and mended")
        type("- ", at: "Après, un")
        check("a paragraph made an item")
        type("plus ", at: "deux")
        check("typing in an item")
        XCTAssertEqual(tv.wholePasses, passes, "none of it restyled the whole chapter")
    }

    // MARK: Return and Tab

    private func typed(_ text: String, caretAfter needle: String, _ lists: ListOptions = ListOptions(), _ key: (ZenTextView) -> Void) -> (String, Int) {
        let tv = editor(text, lists)
        let r = (text as NSString).range(of: needle)
        tv.setSelectedRange(NSRange(location: NSMaxRange(r), length: 0))
        key(tv)
        return (tv.string, tv.selectedRange().location)
    }

    func testReturnContinuesAListAndEndsItOnAnEmptyItem() {
        var out = typed("- lait\nSuite", caretAfter: "lait") { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "- lait\n- \nSuite")
        XCTAssertEqual(out.1, 9)
        out = typed("- lait\n- \nSuite", caretAfter: "- lait\n- ") { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "- lait\n\nSuite", "an empty item ends the list")
        XCTAssertEqual(out.1, 7)
        out = typed("* lait et miel", caretAfter: "lait") { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "* lait\n*  et miel", "the same marker; what followed the caret goes to the new item")
        out = typed("    - niché", caretAfter: "niché") { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "    - niché\n    - ")
        out = typed("- a\n    - ", caretAfter: "    - ") { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "- a\n- ", "an empty nested item first steps out")
        // Not a list: a plain Return.
        out = typed("— Oui, dit-il.", caretAfter: "dit-il.") { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "— Oui, dit-il.\n")
        out = typed("1943. Barcelone.", caretAfter: "Barcelone.", both) { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "1943. Barcelone.\n")
        out = typed("1. semer", caretAfter: "semer") { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "1. semer\n", "numbered lists off")
        out = typed("- lait", caretAfter: "lait", .none) { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "- lait\n", "bullet lists off")
        // Before the marker, the line is pushed down as any line would be.
        let tv = editor("- lait")
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "\n- lait")
    }

    func testReturnNumbersTheNextItemAndThoseBelow() {
        var out = typed("1. semer", caretAfter: "semer", both) { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "1. semer\n2. ")
        out = typed("1) semer", caretAfter: "semer", both) { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "1) semer\n2) ")
        out = typed("1. semer\n2. arroser\n    - bien\n3. cueillir\nFin.", caretAfter: "semer", both) { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "1. semer\n2. \n3. arroser\n    - bien\n4. cueillir\nFin.", "the items below count on")
        XCTAssertEqual(out.1, 12)
        out = typed("1. semer\n5. arroser\n6. cueillir", caretAfter: "semer", both) { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "1. semer\n2. \n5. arroser\n6. cueillir", "numbers that did not follow are the author's")
        out = typed("9. neuf", caretAfter: "neuf", both) { $0.insertNewline(nil) }
        XCTAssertEqual(out.0, "9. neuf\n", "not a list: it does not start at 1")
    }

    func testOneUndoStep() {
        let text = "1. semer\n2. arroser\n3. cueillir"
        let tv = editor(text, both)
        tv.allowsUndo = true
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = tv
        tv.setSelectedRange(NSRange(location: 8, length: 0))
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "1. semer\n2. \n3. arroser\n4. cueillir")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, text, "the new item and the numbers below it, taken back together")
        tv.setSelectedRange(NSRange(location: 12, length: 0))
        tv.insertTab(nil)
        XCTAssertEqual(tv.string, "1. semer\n    1. arroser\n3. cueillir")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, text)
    }

    func testTabNestsAndShiftTabUnNests() {
        var out = typed("- a\n- b", caretAfter: "- b") { $0.insertTab(nil) }
        XCTAssertEqual(out.0, "- a\n    - b")
        XCTAssertEqual(out.1, 11, "the caret stays in its word")
        out = typed("- a\n    - b", caretAfter: "- b") { $0.insertTab(nil) }
        XCTAssertEqual(out.0, "- a\n        - b")
        out = typed("- a\n        - b", caretAfter: "- b") { $0.insertTab(nil) }
        XCTAssertEqual(out.0, "- a\n        - b", "two levels at most: nothing is written")
        out = typed("- a\n        - b", caretAfter: "- b") { $0.insertBacktab(nil) }
        XCTAssertEqual(out.0, "- a\n    - b")
        out = typed("- a\n  - b", caretAfter: "- b") { $0.insertBacktab(nil) }
        XCTAssertEqual(out.0, "- a\n- b", "two spaces were one level")
        out = typed("- a", caretAfter: "- a") { $0.insertBacktab(nil) }
        XCTAssertEqual(out.0, "- a")
        // Numbers follow the depth: a nested item opens a list, one stepping out takes the next number.
        out = typed("1. a\n2. b\n3. c", caretAfter: "2. b", both) { $0.insertTab(nil) }
        XCTAssertEqual(out.0, "1. a\n    1. b\n3. c")
        out = typed("1. a\n    1. b\n    2. c", caretAfter: "2. c", both) { $0.insertBacktab(nil) }
        XCTAssertEqual(out.0, "1. a\n    1. b\n2. c")
        // Outside a list, Tab is a tab.
        out = typed("Un mot", caretAfter: "Un") { $0.insertTab(nil) }
        XCTAssertEqual(out.0, "Un\t mot")
        out = typed("- a", caretAfter: "- a", .none) { $0.insertTab(nil) }
        XCTAssertEqual(out.0, "- a\t")
        // Several items selected move together.
        let tv = editor("- a\n- b\n- c")
        tv.setSelectedRange(NSRange(location: 5, length: 6))
        tv.insertTab(nil)
        XCTAssertEqual(tv.string, "- a\n    - b\n    - c")
    }

    /// With corrections on, a new item is recorded as an addition; an item's depth is not a correction.
    func testListsInRevisionMode() {
        let tv = editor("- lait")
        let bridge = EditorBridge()
        bridge.textView = tv; tv.bridge = bridge
        bridge.trackChanges = true
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "- lait{++\n- ++}")
        XCTAssertEqual(tv.selectedRange().location, 12, "the caret in the new item")
        XCTAssertEqual(Revisions.resolveAll(tv.string, accept: true), "- lait\n- ")
        tv.insertTab(nil)
        XCTAssertEqual(tv.string, "- lait{++\n    - ++}")
    }

    // MARK: Typography

    func testTypographyLeavesAListMarkerAlone() {
        let n = "\u{00A0}"
        // A book without bullet lists: a dash at the start of a line is a dialogue dash, as before.
        XCTAssertEqual(Typography.corrected("- Oui, dit-il.", lang: "fr"), "— Oui, dit-il.")
        XCTAssertEqual(Typography.corrected("- Oui, dit-il.", lang: "fr", lists: .none), "— Oui, dit-il.")
        // With them: the marker stays, the item's text is corrected like any other.
        XCTAssertEqual(Typography.corrected("- Oui, dit-il.", lang: "fr", lists: bullets), "- Oui, dit-il.")
        XCTAssertEqual(Typography.corrected("- du lait ; des oeufs...", lang: "fr", lists: bullets), "- du lait\(n); des oeufs…")
        XCTAssertEqual(Typography.corrected("    * \"oui\" - non", lang: "fr", lists: bullets), "    * «\(n)oui\(n)» – non")
        XCTAssertEqual(Typography.corrected("+ l'homme", lang: "fr", lists: bullets), "+ l’homme")
        XCTAssertEqual(Typography.corrected("1. l'homme", lang: "fr", lists: both), "1. l’homme")
        XCTAssertTrue(Typography.edits(in: "- lait", lang: "fr", lists: bullets).isEmpty)
        // What is not a marker is still typography's: two hyphens, an en dash, a scene break kept as it is.
        XCTAssertEqual(Typography.corrected("-- Oui.", lang: "fr", lists: bullets), "— Oui.")
        XCTAssertEqual(Typography.corrected("– Oui.", lang: "fr", lists: bullets), "— Oui.")
        XCTAssertEqual(Typography.corrected("* * *", lang: "fr", lists: bullets), "* * *")
        for lang in ["en", "en-GB", "de", "es", "it", "pt-BR", "pt-PT"] {
            XCTAssertEqual(Typography.corrected("- milk", lang: lang, lists: bullets), "- milk", lang)
            // English leaves a dash at the start of a line alone anyway.
            if !lang.hasPrefix("en") { XCTAssertNotEqual(Typography.corrected("- milk", lang: lang, lists: .none).first, "-" as Character?, lang) }
        }
        let doc = Typography.correctedDocument("- un\n- deux\n- Oui ?", lang: "fr", lists: bullets)
        XCTAssertEqual(doc.text, "- un\n- deux\n- Oui\(n)?")
    }

    /// The proofreader's typography pass, in a real editor on a book: a list's markers stay, in a book that has
    /// bullet lists; in one that has none the dash becomes dialogue's.
    func testTheProofreaderLeavesListMarkersAlone() throws {
        func run(bullets: Bool?) throws -> String {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-lists-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            try "# Un\n\n- du lait ; des oeufs\n\n- Oui, dit-il.\n\nFin.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
            var manifest = BookManifest(title: "Test", lang: "fr", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")])
            // A novel writes no lists unless its author asks: left alone, a hyphen that opens a line is dialogue.
            if let bullets { manifest.structure = BookStructure(form: .novel, text: .init(bulletLists: bullets)) }
            let session = BookSession(root: root, manifest: manifest)
            let bridge = EditorBridge(), proof = AutoProofreader()
            bridge.proof = proof
            proof.bridge = bridge
            let saved = UserDefaults.standard.object(forKey: "autoTypography")
            defer { UserDefaults.standard.set(saved, forKey: "autoTypography") }
            let view = ZenEditorView(session: session, bridge: bridge, fontName: "", fontSize: 16, columnWidth: 600, focusMode: false, typewriter: false, lineNumbers: true)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: view)
            window.makeKeyAndOrderFront(nil)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            let tv = try XCTUnwrap(bridge.textView)
            proof.attach(root: root, lang: "fr")
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            proof.typography = true
            proof.applyTypography()
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            window.orderOut(nil)
            return tv.string
        }
        let n = "\u{00A0}"
        XCTAssertEqual(try run(bullets: true), "# Un\n- du lait\(n); des oeufs\n- Oui, dit-il.\nFin.\n")
        XCTAssertEqual(try run(bullets: false), "# Un\n— du lait\(n); des oeufs\n— Oui, dit-il.\nFin.\n")
        XCTAssertEqual(try run(bullets: nil), "# Un\n— du lait\(n); des oeufs\n— Oui, dit-il.\nFin.\n", "an old book keeps its dialogue dash")
    }

    // MARK: Sections

    func testSectionsAreSubHeadings() {
        let text = "# Le verger\n\nAvant.\n\n## Les pommes {.unnumbered}\n\nTexte.\n\n### *Reinettes* ##\n\n<!-- ## pas une section -->\n\n#### Trop profond\n\n##Sans espace\n\n## \n\n## Les poires\n"
        let found = Sections.parse(text)
        XCTAssertEqual(found.map(\.title), ["Les pommes", "Reinettes", "Les poires"])
        XCTAssertEqual(found.map(\.level), [2, 3, 2])
        XCTAssertEqual((text as NSString).substring(with: found[0].line), "## Les pommes {.unnumbered}")
        XCTAssertNil(Sections.section(at: 5, in: found), "before the first section: the chapter itself")
        XCTAssertEqual(Sections.section(at: (text as NSString).range(of: "Texte").location, in: found)?.title, "Les pommes")
        XCTAssertEqual(Sections.section(at: (text as NSString).length, in: found)?.title, "Les poires")
        XCTAssertEqual(Sections.parse("# Titre\n\nRien d’autre.\n"), [])
        // The editor's form (one line per paragraph) reads the same.
        XCTAssertEqual(Sections.parse(ParagraphCodec.decode(text)).map(\.title), ["Les pommes", "Reinettes", "Les poires"])
    }

    private func book(_ structure: BookStructure?) throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-sections-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "# Un\n\n## Le verger\n\nTexte.\n\n<!-- scene: La cave -->\n\nSuite.\n\n## La ruche\n\nFin.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "# Deux\n\nSans section.\n".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "T", lang: "fr", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un"), ChapterEntry(id: "02", file: "02.md", title: "Deux")])
        m.structure = structure
        try BookStore(root: root).saveManifest(m)
        return BookSession(root: root, manifest: m)
    }

    /// Sections are read with the scenes, only in a book that reads sub-headings as sections.
    func testSectionsAreReadOnlyInABookThatHasThem() throws {
        let plain = try book(nil)
        plain.countAllWords()
        plain.open("01")
        XCTAssertTrue(plain.sections.isEmpty, "a novel pays nothing for them")
        XCTAssertEqual(plain.scenes["01"]?.count, 2)

        let essay = try book(BookStructure(form: .essay))
        essay.countAllWords()
        XCTAssertEqual(essay.sections["01"]?.map(\.title), ["Le verger", "La ruche"])
        XCTAssertNil(essay.sections["02"])
        // They follow the text as the scenes do.
        essay.open("01")
        essay.text = essay.text.replacingOccurrences(of: "## La ruche", with: "## Les ruches\n### Le miel")
        essay.refreshScenes()
        XCTAssertEqual(essay.sections["01"]?.map(\.title), ["Le verger", "Les ruches", "Le miel"])
        XCTAssertEqual(essay.scenes["01"]?.count, 2, "scenes are as they were")
        // Turned off, they go; turned on in a novel, they come.
        essay.setStructure { $0.structure?.text = .init(subheadings: false) }
        XCTAssertTrue(essay.sections.isEmpty)
        plain.setStructure { $0.structure = BookStructure(form: .novel, text: .init(subheadings: true)) }
        XCTAssertEqual(plain.sections["01"]?.map(\.title), ["Le verger", "La ruche"])
        XCTAssertFalse(plain.manifest.hasForm, "and the book still prints as it always did")
    }

    // MARK: The typesetter's options and the form

    /// `hasForm`: strands, the text's options and hiding the parts do not change the printed form.
    func testWhatShapesThePage() {
        func novel(_ change: (inout BookStructure) -> Void = { _ in }, kind: String? = nil) -> BookManifest {
            var m = BookManifest(title: "T", lang: "fr", chapters: [ChapterEntry(id: "a", file: "a.md", title: "A", kind: kind)])
            var s = BookStructure(form: .novel)
            change(&s)
            m.structure = s
            return m
        }
        XCTAssertFalse(novel { $0.strands = [.init(id: "s", name: "1943", colour: "#8FA3FF")] }.hasForm, "strands only")
        XCTAssertFalse(novel { $0.text = .init(subheadings: true, bulletLists: false, numberedLists: true) }.hasForm, "only the text's options")
        XCTAssertFalse(novel { $0.group = .init(off: true) }.hasForm, "a hidden group level")
        XCTAssertFalse(novel().hasForm)
        XCTAssertFalse(BookManifest(title: "T", chapters: []).hasForm, "no structure at all")
        XCTAssertTrue(novel { $0.piece = .init(name: "Lettre") }.hasForm, "a renamed level")
        XCTAssertTrue(novel { $0.piece = .init(numbering: .roman) }.hasForm)
        XCTAssertTrue(novel { $0.unnumbered = ["Lettre"] }.hasForm, "a list of unnumbered kinds of its own")
        XCTAssertTrue(novel(kind: "prologue").hasForm, "a piece with a kind")
        XCTAssertTrue(novel { $0.form = .essay }.hasForm, "another form")
        XCTAssertEqual(novel { $0.strands = [] }.structure?.shapesThePage, false)
    }

    /// The text's options reach the typesetter whether or not the book has a form, and say nothing new by default.
    func testTextOptionsDoNotWaitForAForm() throws {
        var m = BookManifest(title: "T", lang: "fr", chapters: [ChapterEntry(id: "a", file: "a.md", title: "A")])
        XCTAssertEqual(m.typesetText, BookSource.TextOptions(), "an old book: as Musset always read it")
        XCTAssertEqual(BookSource.TextOptions(), .init(bullets: true, numbered: false, sections: false))
        m.structure = BookStructure(form: .novel, text: .init(subheadings: true, bulletLists: false, numberedLists: true))
        XCTAssertNil(m.typesetForm)
        XCTAssertEqual(m.typesetText, .init(bullets: false, numbered: true, sections: true))
        XCTAssertEqual(m.listOptions, ListOptions(bullets: false, numbered: true))
        m.structure = BookStructure(form: .essay)
        XCTAssertEqual(m.typesetText, .init(bullets: true, numbered: true, sections: true))

        // What the typesetter writes: the same text, by the book's options.
        let md = "# Un\n\n- lait\n\n    - entier\n\n1. semer\n\n2. arroser\n\n1943. Barcelone.\n\n## Le verger\n\nFin.\n"
        func source(_ text: BookSource.TextOptions, contents: Bool = true) throws -> String {
            var pages = SpecialPages()
            if contents { pages.contents = "Table" }
            return try TypesetBook(BookSource(chapters: [.init(id: "a", markdown: md)], template: Typesetting.template(), title: "T", author: "A", lang: "fr",
                                              pages: pages, fontDirectories: Typesetting.fonts(bookRoot: FileManager.default.temporaryDirectory), text: text)).typstSource
        }
        let plain = try source(.init())
        XCTAssertTrue(plain.contains("- lait\n  - entier\n1\\. semer\n\n2\\. arroser\n\n1943\\. Barcelone.\n\n== Le verger"), plain)
        XCTAssertTrue(plain.contains("#outline(title: none, depth: 1)"), plain)
        let rich = try source(.init(bullets: true, numbered: true, sections: true))
        XCTAssertTrue(rich.contains("- lait\n  - entier\n1. semer\n+ arroser\n1943\\. Barcelone.\n\n== Le verger"), rich)
        XCTAssertTrue(rich.contains("outline(title: none, depth: 2)"), rich)
        let bare = try source(.init(bullets: false, numbered: false, sections: false))
        XCTAssertTrue(bare.contains("\\- lait\n\n\\- entier\n\n1\\. semer"), "bullet lists off: dash lines are paragraphs: \(bare)")
    }

    // MARK: For pandoc

    func testTheSourceForPandocHasTheBooksListsAndNoOther() {
        let text = "# Un\n\nAvant.\n\n- lait\n\n  - entier\n\n* oeufs\n\nAprès.\n\n1943. Barcelone.\n\n36. Guerre.\n\n1. semer\n\n2) arroser\n\n* * *\n\n— Oui.\n"
        XCTAssertEqual(ListLines.forPandoc(text, bullets),
                       "# Un\n\nAvant.\n\n- lait\n    - entier\n- oeufs\n\nAprès.\n\n1943\\. Barcelone.\n\n36\\. Guerre.\n\n1\\. semer\n\n2\\) arroser\n\n* * *\n\n— Oui.\n")
        XCTAssertEqual(ListLines.forPandoc(text, both),
                       "# Un\n\nAvant.\n\n- lait\n    - entier\n- oeufs\n\nAprès.\n\n1943\\. Barcelone.\n\n36\\. Guerre.\n\n1. semer\n2. arroser\n\n* * *\n\n— Oui.\n")
        XCTAssertEqual(ListLines.forPandoc("- lait\n\n- oeufs\n", .none), "\\- lait\n\n\\- oeufs\n", "bullet lists off")
        // A text without such a line is not touched; an item right under a line of prose is set apart from it.
        let prose = "# Un\n\nLe texte, sans liste.\n\n\nEt la suite.\n"
        XCTAssertEqual(ListLines.forPandoc(prose, both), prose)
        XCTAssertEqual(ListLines.forPandoc("Voici :\n- lait\nEt puis.", bullets), "Voici :\n\n- lait\n\nEt puis.")
    }

    /// pandoc's own reading of that source (when pandoc is there): two lists, the year a paragraph.
    func testPandocReadsTheLists() async throws {
        guard ExportService.pandoc != nil else { throw XCTSkip("pandoc is not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musset-pandoc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let text = "Avant.\n\n- lait\n\n    - entier\n\n- oeufs\n\n1943. Barcelone.\n\n1. semer\n\n2. arroser\n\na. m. est une heure.\n"
        func html(_ options: ListOptions) async throws -> String {
            try ListLines.forPandoc(text, options).write(to: dir.appendingPathComponent("in.md"), atomically: true, encoding: .utf8)
            let r = try await ExportService.runPandoc(["in.md", "--from", "markdown-fancy_lists", "--to", "html"], cwd: dir)
            XCTAssertTrue(r.ok, r.stderr)
            return r.stdout.replacingOccurrences(of: "\n", with: "")
        }
        let rich = try await html(both)
        XCTAssertTrue(rich.contains("<ul><li>lait<ul><li>entier</li></ul></li><li>oeufs</li></ul>"), rich)
        XCTAssertTrue(rich.contains("<p>1943. Barcelone.</p>"), rich)
        XCTAssertTrue(rich.contains("<li>semer</li><li>arroser</li></ol>"), rich)
        XCTAssertTrue(rich.contains("<p>a. m. est une heure.</p>"), rich)
        let plain = try await html(bullets)
        XCTAssertTrue(plain.contains("<p>1. semer</p><p>2. arroser</p>") && plain.contains("<p>1943. Barcelone.</p>") && !plain.contains("<ol"), plain)
        let bare = try await html(.none)
        XCTAssertTrue(bare.contains("<p>- lait</p>") && !bare.contains("<ul"), bare)
    }

    // MARK: Shots

    /// An essay with lists and sections, in a folder of its own: nested bullets, a numbered list, two sections a
    /// chapter, and a sentence that opens on a year.
    private func essay() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-essay-\(UUID().uuidString)/Le verger")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let para = "Il faut du temps pour qu’un verger donne, et plus encore pour qu’il donne bien : la terre se souvient de tout ce qu’on lui a fait, et le rend sans hâte, à sa manière, qui n’est pas la nôtre."
        func chapter(_ title: String, _ first: String, _ second: String) -> String {
            """
            # \(title)

            \(para)

            ## \(first)

            \(para)

            - les pommes, qu’on cueille en octobre, quand les nuits fraîchissent et que la lumière baisse sur le coteau

                - les reinettes, pour l’hiver

                - les goldens, pour tout de suite

            - les poires

            * les coings, qu’on oublie toujours

            — Et les cerises ? demanda-t-elle.

            1943. Barcelone. Le verger de son grand-père, lui, n’avait pas attendu : on l’avait arraché en une matinée.

            ## \(second)

            \(para)

            1. semer à l’abri, dès la fin de l’hiver, dans une terre fine et tamisée qu’on aura laissée reposer

            2. repiquer

                1. en godets d’abord

                2. puis en pleine terre

            3. attendre

            \(para)

            ### Une remarque

            \(para)

            """
        }
        let texts = [("01", "Le verger", chapter("Le verger", "Ce qu’on y cueille", "Ce qu’on y fait")),
                     ("02", "La ruche", chapter("La ruche", "Les abeilles", "Le miel")),
                     ("03", "L’hiver", chapter("L’hiver", "La taille", "Le repos"))]
        for (id, _, text) in texts { try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8) }
        var m = BookManifest(title: "Le verger", author: "A. Martin", lang: "fr", chapters: texts.map { ChapterEntry(id: $0.0, file: "\($0.0).md", title: $0.1) })
        m.structure = BookStructure(form: .essay)
        m.front = FrontMatter(contents: true)
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        return root
    }

    /// The essay typeset as a book and as a manuscript, and its chapter in the main window with the sidebar's
    /// sections, light and dark. MUSSET_LIVE_SHOTS=<dir> (skipped otherwise); the PDFs go to <dir>/../lists-pdf.
    func testListShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_LIVE_SHOTS"] else { throw XCTSkip("set MUSSET_LIVE_SHOTS") }
        let out = URL(fileURLWithPath: dir)
        let pdfs = out.deletingLastPathComponent().appendingPathComponent("lists-pdf")
        for d in [out, pdfs] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let root = try essay()
        let store = BookStore(root: root)
        let m = try store.loadManifest()

        var book = ExportPreset(id: "lists-book", name: "Book", format: .pdf, style: "book")
        book.facing = true
        var plain = m
        plain.structure = nil
        for (manifest, preset, name) in [(m, book, "essay-book.pdf"), (m, ManuscriptNorm.feuillet.preset, "essay-manuscript-fr.pdf"),
                                         (m, ManuscriptNorm.normseite.preset, "essay-manuscript-normseite.pdf"), (plain, book, "same-text-default-options-book.pdf")] {
            let data = try TypesetBook.pdf(Typesetting.source(manifest: manifest, store: store, preset: preset))
            try data.write(to: pdfs.appendingPathComponent(name))
            XCTAssertGreaterThan(PDFDocument(data: data)?.pageCount ?? 0, 3, name)
        }

        let d = UserDefaults.standard
        let keys = [UILang.key, "libraryPaths", "lastBook", "sidebarFoldedParts", "sidebarBookFolded"]
        let saved = keys.map { d.object(forKey: $0) }
        defer { for (k, v) in zip(keys, saved) { d.set(v, forKey: k) } }
        d.set("fr", forKey: UILang.key)
        for k in keys.dropFirst() { d.removeObject(forKey: k) }

        // The editor's faint colours are made once, for the appearance the app has then: the light shots are taken
        // in a run of their own (MUSSET_SHOTS_LIGHT=1), the dark ones otherwise.
        let light = ProcessInfo.processInfo.environment["MUSSET_SHOTS_LIGHT"] != nil
        let appearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
        defer { NSApp.appearance = appearance }
        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        s.open("01")
        let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
        bridge.annotator = ann; bridge.proof = proof
        let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 1000), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: retina)
        window.contentView = NSHostingView(rootView: view.frame(width: 1280, height: 1000))
        app.showInspector = false
        func shot(_ name: String) async throws {
            let name = name + (light ? "-light.png" : "-dark.png")
            window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
            try await Task.sleep(for: .seconds(1.2))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(s.sections["01"]?.map(\.title), ["Ce qu’on y cueille", "Ce qu’on y fait", "Une remarque"])
        let tv = try XCTUnwrap(bridge.textView)
        // The caret in the first section's list: the sidebar and the trail say where.
        let at = (tv.string as NSString).range(of: "les reinettes").location
        tv.setSelectedRange(NSRange(location: at, length: 0))
        tv.scrollToCenter(offset: at)
        try await shot("lists-1")
        let lower = (tv.string as NSString).range(of: "puis en pleine terre").location
        tv.setSelectedRange(NSRange(location: lower, length: 0))
        tv.scrollToCenter(offset: lower)
        try await shot("lists-2-numbered")
        // The same chapter in a book that reads none of it: no lists, no sections.
        s.setStructure { $0.structure = BookStructure(form: .novel, text: .init(subheadings: false, bulletLists: false, numberedLists: false)) }
        tv.setSelectedRange(NSRange(location: at, length: 0))
        tv.scrollToCenter(offset: at)
        try await shot("lists-3-all-off")
        window.orderOut(nil)
    }
}
