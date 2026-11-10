import XCTest
@testable import Musset

/// ⌘K lists every book's chapters: books not open are read once, and again only when they change.
@MainActor
final class PaletteSpeedTests: XCTestCase {
    func testClosedBooksAreReadOnceAndFollowChanges() throws {
        let d = UserDefaults.standard
        let saved = (d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"))
        defer { d.set(saved.0, forKey: "libraryPaths"); d.set(saved.1, forKey: "lastBook") }
        d.removeObject(forKey: "libraryPaths"); d.removeObject(forKey: "lastBook")
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("musset-palette-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        var paths: [String] = []
        for i in 0..<30 {
            let root = base.appendingPathComponent("book\(i)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let chapters = (0..<40).map { ChapterEntry(id: "c\($0)", file: "c\($0).md", title: "Chapitre \($0)") }
            try BookStore(root: root).saveManifest(BookManifest(title: "Livre \(i)", chapters: chapters))
            paths.append(root.path)
        }
        let app = AppState()
        app.libraryPaths = paths
        XCTAssertEqual(app.allChapters().count, 30 * 40)
        let start = Date()
        for _ in 0..<20 { _ = app.allChapters() }
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5, "twenty listings without reading the disk again")

        // A book changed elsewhere (sync, another Musset) shows its new chapters.
        let store = BookStore(root: base.appendingPathComponent("book0"))
        var m = try store.loadManifest()
        m.chapters.append(ChapterEntry(id: "new", file: "new.md", title: "Nouveau"))
        Thread.sleep(forTimeInterval: 1.1)   // a modification date the file system can tell apart
        try store.saveManifest(m)
        XCTAssertTrue(app.allChapters().contains { $0.chapter.title == "Nouveau" })
    }
}
