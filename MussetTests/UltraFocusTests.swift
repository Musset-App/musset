import XCTest
@testable import Musset

/// Ultra Focus: only forward, and what was written lands where it should.
@MainActor
final class UltraFocusTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-ultra-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Amiens\n\nElle arrivait avec le train.\n".write(to: root.appendingPathComponent("amiens.md"), atomically: true, encoding: .utf8)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session() throws -> BookSession {
        let git = GitService(root: root)
        try git.initRepo()
        let m = BookManifest(title: "T", chapters: [ChapterEntry(id: "amiens", file: "amiens.md", title: "Amiens")])
        try BookStore(root: root).saveManifest(m)
        _ = try git.commit(paths: ["amiens.md", ".musset"], message: "start")
        let s = BookSession(root: root, manifest: m)
        s.open("amiens")
        return s
    }

    private func file() throws -> String { try String(contentsOf: root.appendingPathComponent("amiens.md"), encoding: .utf8) }

    func testOnlyForward() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let tv = ForwardOnlyTextView(frame: scroll.bounds)
        scroll.documentView = tv
        window.contentView?.addSubview(scroll)
        var refusals = 0
        tv.refused = { refusals += 1 }
        tv.level = .hardcore

        tv.insertText("Je prends le train", replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        tv.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        tv.paste(nil)
        XCTAssertEqual(tv.string, "Je prends le train")
        XCTAssertEqual(refusals, 3, "⌫, ←, ⌘V: refused")

        tv.setSelectedRange(NSRange(location: 3, length: 0))
        XCTAssertEqual(tv.selectedRange().location, 18, "the caret can't go back")
        tv.insertText(" pour l'été", replacementRange: NSRange(location: 2, length: 4))
        XCTAssertEqual(tv.string, "Je prends le train pour l'été", "typed at the end, whatever range is asked")
        tv.insertText("'", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(tv.string.hasSuffix("été’"), "an apostrophe after a letter is curled")
        tv.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        XCTAssertTrue(tv.string.hasSuffix("\n"), "Return is allowed: a new paragraph")
    }

    private func editor(_ level: UltraFocusLevel, chapter: String = "Avant.\n") -> (ForwardOnlyTextView, () -> Int) {
        let tv = ForwardOnlyTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        tv.string = chapter
        tv.floor = (chapter as NSString).length
        tv.level = level
        var refusals = 0
        tv.refused = { refusals += 1 }
        return (tv, { refusals })
    }

    func testNormalLetsBackspaceButNotIntoTheChapter() {
        let (tv, refusals) = editor(.normal)
        tv.insertText("Je prends", replacementRange: NSRange(location: NSNotFound, length: 0))
        tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(tv.string, "Avant.\nJe prend")
        tv.doCommand(by: #selector(NSResponder.deleteWordBackward(_:)))
        XCTAssertEqual(tv.string, "Avant.\nJe ")
        tv.doCommand(by: #selector(NSResponder.moveLeft(_:)))
        XCTAssertEqual(refusals(), 1, "no arrows in Normal")
        for _ in 0..<5 { tv.doCommand(by: #selector(NSResponder.deleteBackward(_:))) }
        XCTAssertEqual(tv.string, "Avant.\n", "never into the chapter above")
    }

    func testLightMovesInsideTheSentenceOnly() {
        let (tv, refusals) = editor(.light)
        tv.insertText("Il pleut. Je prends le train", replacementRange: NSRange(location: NSNotFound, length: 0))
        for _ in 0..<5 { tv.doCommand(by: #selector(NSResponder.moveLeft(_:))) }
        tv.insertText("vieux ", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(tv.string, "Avant.\nIl pleut. Je prends le vieux train", "typed where the caret is")
        for _ in 0..<40 { tv.doCommand(by: #selector(NSResponder.moveLeft(_:))) }
        let start = ("Avant.\nIl pleut. " as NSString).length
        XCTAssertEqual(tv.selectedRange().location, start, "the caret stops at the sentence's start")
        XCTAssertGreaterThan(refusals(), 0)
        tv.doCommand(by: #selector(NSResponder.deleteBackward(_:)))
        XCTAssertEqual(tv.string, "Avant.\nIl pleut. Je prends le vieux train", "nor deletes before it")
        tv.doCommand(by: #selector(NSResponder.deleteForward(_:)))
        XCTAssertEqual(tv.string, "Avant.\nIl pleut. e prends le vieux train")
    }

    func testTheChapterAboveIsReadNotWritten() {
        let tv = ForwardOnlyTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        tv.string = "Elle arrivait avec le train.\n"
        tv.floor = (tv.string as NSString).length
        var written = ""
        tv.changed = { written = $0 }
        tv.insertText("Je prends le train.", replacementRange: NSRange(location: 0, length: 5))
        XCTAssertEqual(tv.string, "Elle arrivait avec le train.\nJe prends le train.", "always after the chapter")
        XCTAssertEqual(written, "Je prends le train.", "only the new words count")
        XCTAssertEqual(UltraFocus.readable("# Amiens\n<!-- scene: Elle vient -->\nElle arrivait.\n"), "# Amiens\nElle arrivait.")
    }

    func testANewSceneAtTheEnd() throws {
        let s = try session()
        let date = Date(timeIntervalSince1970: 1_794_200_000)
        let place = UltraFocus.deposit("Je prends le train.\n\n\nAmiens, enfin.  ", into: s, chapter: "amiens", destination: .newScene, at: date)
        XCTAssertNotNil(place)
        let disk = try file()
        XCTAssertTrue(disk.contains("Elle arrivait avec le train.\n\n<!-- scene: Ultra Focus, "), disk)
        XCTAssertTrue(disk.hasSuffix("Je prends le train.\n\nAmiens, enfin.\n"), "blank lines collapse to one paragraph break")
        XCTAssertEqual(s.scenes["amiens"]?.last?.title?.hasPrefix("Ultra Focus"), true)
    }

    func testAtTheEndAndNothingWhenEmpty() throws {
        let s = try session()
        XCTAssertNil(UltraFocus.deposit("  \n ", into: s, chapter: "amiens", destination: .end, at: Date()))
        UltraFocus.deposit("Puis la gare.", into: s, chapter: "amiens", destination: .end, at: Date())
        XCTAssertTrue(try file().hasSuffix("Elle arrivait avec le train.\n\nPuis la gare.\n"))
    }

    func testIntoTheDrafts() throws {
        let s = try session()
        UltraFocus.deposit("Un premier jet.", into: s, chapter: "amiens", destination: .drafts, at: Date())
        let draft = try XCTUnwrap(s.draftChapters.first)
        XCTAssertTrue(draft.title.hasPrefix("Ultra Focus"))
        XCTAssertTrue(s.store.read(draft).contains("Un premier jet."))
        XCTAssertFalse(try file().contains("Un premier jet."), "the chapter is untouched")
    }

    func testIntoTheVersionBeingWritten() throws {
        let s = try session()
        s.tryAnotherVersion(named: "J’y vais", blank: false, currentName: "Paris")
        UltraFocus.deposit("Je prends le train.", into: s, chapter: "amiens", destination: .end, at: Date())
        XCTAssertFalse(try file().contains("Je prends le train"), "the book's version is untouched")
        let ch = try XCTUnwrap(s.selectedChapter)
        XCTAssertTrue(s.store.readVersion(ch, "J’y vais").contains("Je prends le train"))
    }
}
