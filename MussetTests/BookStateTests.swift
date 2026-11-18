import XCTest
@testable import Musset

/// The book's state on this Mac (`.musset/state.json`): everything in one file, written in one way.
@MainActor
final class BookStateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-state-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# One\n\nTom crossed at six.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try BookStore(root: root).saveManifest(BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One")]))
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func session() throws -> BookSession { BookSession(root: root, manifest: try BookStore(root: root).loadManifest()) }

    func testWhatWasKeptInThePreferencesByFolderPathComesIntoTheStateFileOnce() throws {
        let d = UserDefaults.standard
        let path = root.standardizedFileURL.path
        let today = BookUIState.WordsBaseline.today
        d.set(1, forKey: "wordsBaseline:\(path):\(today)")
        d.set(900, forKey: "wordsBaseline:\(path):2024-01-02")
        d.set(true, forKey: "firstChapterDone:\(path)")
        // The export sheet's choice, as it was encoded in the preferences.
        d.set(Data(#"{"format":"docx","layouts":{"pdf":"print"},"scope":"status","statuses":"final","picked":["01"],"specials":["title"],"facing":true}"#.utf8), forKey: "exportChoice:\(path)")
        let s = try session()
        XCTAssertEqual(s.state.wordsBaseline, .init(day: today, words: 1), "today's count is kept, not the other days'")
        XCTAssertEqual(s.wordsToday, s.bookWordCount - 1)
        XCTAssertEqual(s.state.firstChapterDone, true)
        XCTAssertEqual(s.state.export, ExportChoice(format: "docx", layouts: ["pdf": "print"], scope: .status, statuses: "final", picked: ["01"], specials: ["title"], facing: true))
        XCTAssertTrue(d.dictionaryRepresentation().keys.filter { $0.contains(path) }.isEmpty, "the old keys are gone")
        s.close()
        let again = try session()
        XCTAssertEqual(again.state.firstChapterDone, true)
        XCTAssertEqual(again.state.export?.format, "docx")
        XCTAssertEqual(again.state.wordsBaseline?.words, 1)
    }

    func testTheFirstChapterDoneSpeaksOncePerBook() throws {
        let s = try session()
        var spoken = 0
        let token = NotificationCenter.default.addObserver(forName: BookSession.firstChapterDone, object: s, queue: nil) { _ in spoken += 1 }
        defer { NotificationCenter.default.removeObserver(token) }
        s.setStatus("01", .done)
        s.setStatus("01", .draft)
        s.setStatus("01", .done)
        XCTAssertEqual(spoken, 1)
        s.close()
        let again = try session()
        again.setStatus("01", .draft)
        again.setStatus("01", .done)
        XCTAssertEqual(spoken, 1)
        XCTAssertEqual(again.state.firstChapterDone, true)
    }

    func testOnlyTodaysWordsAreKept() throws {
        let store = BookStore(root: root)
        try FileManager.default.createDirectory(at: store.mussetDir, withIntermediateDirectories: true)
        try Data(#"{"selections":{},"wordsBaseline":{"day":"2024-01-02","words":3}}"#.utf8).write(to: store.stateURL)
        let s = try session()
        XCTAssertEqual(s.state.wordsBaseline, .init(day: BookUIState.WordsBaseline.today, words: s.bookWordCount))
        XCTAssertEqual(s.wordsToday, 0)
        s.textDidChange(s.text + " And back at seven.")
        s.flushSave()
        XCTAssertEqual(s.wordsToday, 4)
    }

    func testAChangeOfStateIsWrittenAMomentLaterAndAtOnceWhenClosing() async throws {
        let s = try session()
        let store = BookStore(root: root)
        s.rememberSelection(9)
        XCTAssertNil(store.loadState().selections["01"], "not at each move of the caret")
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertEqual(store.loadState().selections["01"], 9)
        s.rememberSelection(4)
        s.close()
        XCTAssertEqual(store.loadState().selections["01"], 4)
    }
}
