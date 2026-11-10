import AppKit
import XCTest
@testable import Musset

@MainActor
final class EditorFeatureTests: XCTestCase {
    func testLanguageToolMatchesMapToParagraphs() throws {
        let paras = ["Il y a avait un fils.", "Puis nou sommes partis, Kawai."]
        let json = #"""
        {"matches":[
          {"message":"Le verbe semble répété.","offset":5,"length":7,"replacements":[{"value":"a"},{"value":"avait"}],"rule":{"id":"FRENCH_WORD_REPEAT_RULE","issueType":"style"}},
          {"message":"Faute de frappe possible.","shortMessage":"Faute de frappe","offset":28,"length":3,"replacements":[{"value":"ou"},{"value":"nous"}],"rule":{"id":"FR_SPELLING_RULE","issueType":"misspelling"}},
          {"message":"Espace manquante.","offset":46,"length":1,"replacements":[{"value":" ,"}],"rule":{"id":"FRENCH_WHITESPACE","issueType":"typographical"}},
          {"message":"Faute de frappe possible.","offset":47,"length":5,"replacements":[{"value":"Kawaï"}],"rule":{"id":"FR_SPELLING_RULE","issueType":"misspelling"}}
        ]}
        """#
        struct R: Decodable { let matches: [LanguageTool.Match] }
        let matches = try JSONDecoder().decode(R.self, from: Data(json.utf8)).matches
        // Paragraph 2 starts after "Il y a avait un fils." (21) + two newlines.
        let fixes = LanguageTool.fixes(matches, paragraphs: paras, starts: [0, 23])
        XCTAssertEqual(fixes[0].map(\.original), ["a avait"])
        XCTAssertEqual(fixes[1].map(\.original), ["nou"])            // typography rule and capitalised name dropped
        XCTAssertEqual(fixes[1][0].choices, ["ou", "nous"])
        XCTAssertTrue(fixes[1][0].isLanguageTool)
        XCTAssertFalse(fixes[1][0].isObvious)
    }

    func testSearchFindsTextAcrossChapters() {
        let src = [
            BookSearch.Source(bookPath: "/b", bookTitle: "B", chapter: ChapterEntry(id: "a", file: "a.md", title: "A"), url: URL(fileURLWithPath: "/nonexistent"), live: "Le Père et le pere."),
            BookSearch.Source(bookPath: "/b", bookTitle: "B", chapter: ChapterEntry(id: "b", file: "b.md", title: "B"), url: URL(fileURLWithPath: "/nonexistent"), live: "rien"),
        ]
        let groups = BookSearch.search("père", in: src)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].total, 2)
    }

    func testLineNumbers() {
        let tv = ZenTextView(usingTextLayoutManager: false)
        tv.string = "un\n\ntrois\nquatre"
        tv.restyle()
        XCTAssertEqual(tv.lineNumber(at: 0), 1)
        XCTAssertEqual(tv.lineNumber(at: 4), 3)
        XCTAssertEqual(tv.lineNumber(at: 10), 4)
    }

    func testRepetitionsGroupFormsAndSkipSmallWords() {
        let text = "# Titre regard\n\nJe regardais la mer. Il regardait sa mère. <!-- regarder dans les notes --> Nous regarderons la mer."
        let a = Repetitions.analyze(text, lang: "fr", window: 50)
        let regard = a.counts.first { $0.display.hasPrefix("regard") }
        XCTAssertEqual(regard?.count, 3)                       // the note is ignored
        XCTAssertEqual(a.counts.first { $0.stem == "mer" }?.count, 2)
        XCTAssertNil(a.counts.first { $0.stem == "mere" })      // « mère » once: not « mer »
        XCTAssertFalse(a.words.contains { ["les", "nous", "dans"].contains($0.stem) })
    }

    func testRepetitionWindow() {
        let filler = Array(repeating: "lorem", count: 0).joined()
        let far = "maison " + String(repeating: "chat chien oiseau poisson ", count: 20) + "maison" + filler
        XCTAssertTrue(Repetitions.analyze(far, lang: "fr", window: 50).close.allSatisfy { $0.stem != "maison" })
        XCTAssertEqual(Repetitions.analyze("la maison et la maison", lang: "fr", window: 50).close.filter { $0.stem == "maison" }.count, 2)
    }

    /// Prints the most repeated words of 03_nice. Opt in with MUSSET_LIVE=1.
    func testRepetitionsOnChapter() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/conatus/03_nice.md")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let start = Date()
        let a = Repetitions.analyze(text, lang: "fr", window: 50)
        print("REP time ms:", Int(Date().timeIntervalSince(start) * 1000), "words:", a.words.count, "close:", a.close.count)
        for c in a.counts.prefix(20) { print("REP \(c.display) ×\(c.count) close \(c.close)") }
    }

    /// Live: LanguageTool on a sentence with known mistakes. Opt in with MUSSET_LIVE=1.
    func testLiveLanguageTool() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let text = "Puis il y a avait le long couloir, et nou sommes arrivé à Chaumont."
        let matches = try await LanguageTool.check(text, lang: "fr", server: LanguageTool.publicURL)
        let fixes = LanguageTool.fixes(matches, paragraphs: [text], starts: [0])[0]
        for f in fixes { print("LT «\(f.original)» → \(f.choices) (\(f.reason))") }
        XCTAssertFalse(fixes.isEmpty)
    }

    /// Renders the editor (line numbers, search highlights) and the minimap to PNGs. Opt in with MUSSET_SNAPSHOT=<dir>.
    func testSnapshot() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/conatus/03_nice.md")
        let text = try String(contentsOf: fixture, encoding: .utf8)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        let container = NSView(frame: window.contentView!.bounds)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0.12, alpha: 1).cgColor
        window.contentView = container
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 920, height: 800))
        scroll.hasVerticalScroller = true
        let tv = ZenTextView(usingTextLayoutManager: false)
        tv.frame = NSRect(x: 0, y: 0, width: 920, height: 800)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.theme = EditorTheme(fontName: ProcessInfo.processInfo.environment["MUSSET_FONT"] ?? "JetBrainsMonoNL-Regular", fontSize: 18)
        scroll.documentView = tv
        container.addSubview(scroll)
        let bridge = EditorBridge()
        bridge.textView = tv; tv.bridge = bridge
        let map = MinimapView(frame: NSRect(x: 920, y: 0, width: 72, height: 800))
        map.bridge = bridge; bridge.minimap = map
        container.addSubview(map)
        tv.string = text
        tv.recenter()
        let plain = ProcessInfo.processInfo.environment["MUSSET_FONT"] != nil
        bridge.searchQuery = plain ? "" : "mère"
        tv.showRepetitions = !plain
        bridge.focusedStem = plain ? nil : "pere"
        tv.restyle()
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        tv.scrollToCenter(offset: (text as NSString).range(of: ProcessInfo.processInfo.environment["MUSSET_FONT"] != nil ? "livrait des piles" : "Puis il y avait").location)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        if !plain { XCTAssertFalse(tv.searchRanges.isEmpty) }
        let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds)!
        container.cacheDisplay(in: container.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("editor.png"))
    }
}
