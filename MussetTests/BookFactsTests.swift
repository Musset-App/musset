import XCTest
@testable import Musset

/// « What the book says »: facts kept only with their exact words, asked again once, contradictions only between
/// facts that exist, and the author's « on purpose » remembered.
@MainActor
final class BookFactsTests: XCTestCase {
    private func book() throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-facts-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "Tom was eleven when their mother died. Tom’s van was blue, parked by the weighing house.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "Twelve winters later, Tom still kept the tide tables.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "Salt", chapters: [ChapterEntry(id: "01", file: "01.md", title: "The Ferry"),
                                                       ChapterEntry(id: "02", file: "02.md", title: "The Salt Works")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        let s = BookSession(root: root, manifest: m)
        try s.bible.create(title: "Tom", kind: .character)
        return s
    }

    private func settle(_ k: BibleKeeper) async {
        for _ in 0..<200 where k.running != nil { try? await Task.sleep(for: .milliseconds(10)) }
    }

    func testFactsNeedTheirWordsAndContradictionsTheirFacts() async throws {
        let s = try book()
        var calls: [String] = []
        s.keeper.voice = { prompt in
            calls.append(prompt)
            if prompt.contains("cannot both be true") {
                return #"{"pairs": [[0, 1, "His age doesn't add up"], [0, 9, "made up"]]}"#
            }
            if prompt.contains("not in the chapter word for word") {
                return #"{"entities": [{"name": "Tom", "facts": [{"fact": "Was eleven when his mother died.", "quote": "Tom was eleven when their mother died"}, {"fact": "Drives a blue van.", "quote": "Tom’s van was blue"}, {"fact": "Loves the sea.", "quote": "he loved the sea"}]}]}"#
            }
            return #"{"entities": [{"name": "Tom", "aliases": ["their brother"], "facts": [{"fact": "Was eleven when his mother died.", "quote": "Tom was eleven when their mother died"}, {"fact": "Drives a blue van.", "quote": "Toms van was blue"}]}, {"name": "Someone else", "facts": [{"fact": "x", "quote": "Tom"}]}]}"#
        }
        let tom = try XCTUnwrap(s.bible.entry(named: "Tom"))
        XCTAssertTrue(s.keeper.stale("01"))
        s.keeper.read("01")
        await settle(s.keeper)
        XCTAssertNil(s.keeper.lastError)

        let e = try XCTUnwrap(s.keeper.entity(tom.path))
        XCTAssertEqual(e.facts.map(\.text), ["Was eleven when his mother died.", "Drives a blue van."], "the made-up quote is left out")
        XCTAssertEqual(calls.filter { $0.contains("not in the chapter word for word") }.count, 1, "asked again once")
        XCTAssertEqual(e.contradictions.count, 1, "a pair pointing at no fact is dropped")
        XCTAssertTrue(e.aliases.isEmpty, "an alias the chapter doesn't contain is not kept")
        XCTAssertFalse(s.keeper.stale("01"))
        XCTAssertEqual(BookFacts.load(s.root), s.keeper.facts, "saved in .musset/facts.json")

        let c = try XCTUnwrap(e.contradictions.first)
        s.keeper.dismiss(c, of: tom.path)
        XCTAssertEqual(s.keeper.entity(tom.path)?.contradictions.first?.dismissed, true)
    }

    func testReadingAChapterAgainReplacesOnlyItsFacts() {
        var f = BookFacts()
        f.replace(chapter: "01", with: ["t.md": ([.init(text: "a", chapter: "01", quote: "x")], [])], fingerprint: "1")
        f.replace(chapter: "02", with: ["t.md": ([.init(text: "b", chapter: "02", quote: "y")], ["Tommy"])], fingerprint: "2")
        f.replace(chapter: "01", with: [:], fingerprint: "3")
        XCTAssertEqual(f.entities["t.md"]?.facts.map(\.text), ["b"])
        XCTAssertEqual(f.entities["t.md"]?.aliases, ["Tommy"])
        XCTAssertEqual(f.read["01"], "3")
    }

    func testPairsAreReadLeniently() {
        let pairs = FactsPrompt.parsePairs(#"Sure: {"pairs": [[2, 0, "why"], [1, 1, "self"], [0]]}"#, count: 3)
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.0, 0)
        XCTAssertEqual(pairs.first?.1, 2)
    }
}
