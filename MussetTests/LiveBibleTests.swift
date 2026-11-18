import XCTest
@testable import Musset

/// The live Bible: names found in the text, tiers, new names spotted as the author writes.
@MainActor
final class LiveBibleTests: XCTestCase {
    private func book(_ chapters: [String], lang: String = "en") throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-live-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        var entries: [ChapterEntry] = []
        for (i, text) in chapters.enumerated() {
            let id = String(format: "%02d", i + 1)
            try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
            entries.append(ChapterEntry(id: id, file: "\(id).md", title: "Chapter \(i + 1)"))
        }
        var m = BookManifest(title: "Live", chapters: entries)
        m.lang = lang
        try BookStore(root: root).saveManifest(m)
        return BookSession(root: root, manifest: m)
    }

    private func counted(_ s: BookSession) async {
        s.refreshBibleMentions()
        for _ in 0..<100 where s.bible.writtenChapters == 0 { try? await Task.sleep(for: .milliseconds(20)) }
    }

    // MARK: Matching

    func testNamesAreWholeWordsWithTheirCaseAndPossessives() {
        let m = NameMatcher(names: [("personnages/tom.md", ["Tom", "Tommy"]), ("lieux/dover.md", ["Dover"])])
        let text = "Tom’s van. Tommy, Tomas and tom. Dover at dawn, and Tom's dog."
        let found = m.matches(in: text).map { (text as NSString).substring(with: $0.range) }
        XCTAssertEqual(found, ["Tom", "Tommy", "Dover", "Tom"])
        XCTAssertEqual(m.matches(in: text).first?.path, "personnages/tom.md")
    }

    func testANameTwoSheetsShareIsKnownAsShared() {
        let m = NameMatcher(names: [("a.md", ["Rose"]), ("b.md", ["Rose", "Rosie"])])
        XCTAssertEqual(m.shared, ["Rose"])
        XCTAssertEqual(m.matches(in: "Rose and Rosie.").map(\.path), ["b.md"], "a shared name points at nobody")
    }

    func testPronounsAreNeverNames() {
        let m = NameMatcher(names: [("lou.md", ["Lou", "elle"]), ("tom.md", ["Tom", "he"])])
        XCTAssertEqual(m.matches(in: "Lou partit. Elle revint, elle aussi. He said Tom.").count, 2)
    }

    func testTiers() {
        XCTAssertEqual(NameTier.computed(chapters: 1, mentions: 9, written: 5), .extra)
        XCTAssertEqual(NameTier.computed(chapters: 2, mentions: 3, written: 5), .secondary)
        XCTAssertEqual(NameTier.computed(chapters: 3, mentions: 12, written: 5), .main)
        XCTAssertEqual(NameTier.computed(chapters: 3, mentions: 3, written: 5), .secondary, "present but barely named")
        XCTAssertEqual(NameTier.computed(chapters: 1, mentions: 8, written: 1), .main, "a one-chapter book has its main characters")
        XCTAssertEqual(NameTier.computed(chapters: 0, mentions: 0, written: 5), .absent, "never named is not an extra")
    }

    func testTheNarratorIsMainWithoutBeingNamed() throws {
        XCTAssertTrue(NameTier.isNarrator(["le narrateur", "Julien"]))
        XCTAssertTrue(NameTier.isNarrator(["The Narrator"]))
        XCTAssertTrue(NameTier.isNarrator(["der Erzähler"]))
        XCTAssertFalse(NameTier.isNarrator(["Narcisse"]))
    }

    func testApostrophesAreOne() {
        let m = NameMatcher(names: [("u.md", ["l'urgentiste"])])
        XCTAssertEqual(m.matches(in: "Puis l’urgentiste, et l'urgentiste encore.").count, 2)
    }

    func testGridCharactersWithoutASheetGetTheirTier() async throws {
        let s = try book(["Yvette entra. Pedro aussi.", "Yvette repartit."], lang: "fr")
        s.plot.index = [PlotGrid.Tag(name: "Yvette", column: "characters"), PlotGrid.Tag(name: "Pedro", column: "characters"),
                        PlotGrid.Tag(name: "Lucie", column: "characters"), PlotGrid.Tag(name: "le narrateur", column: "characters")]
        await counted(s)
        let tier = { (n: String) in s.bible.tier(of: s.plot.tags.first { $0.name == n }!) }
        XCTAssertEqual(tier("Yvette"), .secondary)
        XCTAssertEqual(tier("Pedro"), .extra)
        XCTAssertEqual(tier("Lucie"), .absent)
        XCTAssertEqual(tier("le narrateur"), .main)
    }

    func testOccurrencesAndTiersFromTheBook() async throws {
        let s = try book(["Nora crossed. Nora waited. Tom said nothing. Nora again, and Nora. Nora, Nora.",
                          "Nora found Tom on the roof. Odile brought mugs.",
                          "Nora alone. Tom’s van."])
        try s.bible.create(title: "Nora", kind: .character)
        try s.bible.create(title: "Tom", kind: .character)
        try s.bible.create(title: "Odile", kind: .character)
        await counted(s)
        let nora = try XCTUnwrap(s.bible.entry(named: "Nora"))
        XCTAssertEqual(s.bible.occurrences[nora.path]?["01"]?.count, 6)
        XCTAssertEqual(s.bible.tier(of: nora), .main)
        XCTAssertEqual(s.bible.tier(of: try XCTUnwrap(s.bible.entry(named: "Tom"))), .secondary)
        var odile = try XCTUnwrap(s.bible.entry(named: "Odile"))
        XCTAssertEqual(s.bible.tier(of: odile), .extra)
        odile.meta["tier"] = "main"
        try s.bible.save(odile)
        XCTAssertEqual(s.bible.tier(of: try XCTUnwrap(s.bible.entry(named: "Odile"))), .main, "the author's pin wins")
    }

    // MARK: Spotting

    func testRecognisesPeopleAndPlaces() {
        let found = NameSpotter.candidates(in: "Nora met her brother Tom at the harbour in Dover, near London.", lang: "en")
        XCTAssertTrue(found.contains { $0.name == "Tom" && $0.kind == .character && !$0.sentenceStart })
        XCTAssertTrue(found.contains { $0.name == "London" && $0.kind == .place })
    }

    func testRecognisesFrenchNames() {
        let found = NameSpotter.candidates(in: "Hier, Marthe a retrouvé Paul Durand à Marseille, devant la gare.", lang: "fr")
        XCTAssertTrue(found.contains { $0.kind == .character && ($0.name.contains("Marthe") || $0.name.contains("Paul")) }, "\(found)")
        XCTAssertTrue(found.contains { $0.name == "Marseille" && $0.kind == .place }, "\(found)")
    }

    func testSentenceStart() {
        let text = "« Below, » she said. Then Tom."
        XCTAssertTrue(NameSpotter.startsSentence(text, at: text.range(of: "Below")!.lowerBound))
        XCTAssertFalse(NameSpotter.startsSentence(text, at: text.range(of: "Tom")!.lowerBound))
        let merged = NameSpotter.merge([.init(name: "Rose", kind: .character, sentenceStart: true), .init(name: "Rose", kind: .character, sentenceStart: false)])
        XCTAssertEqual(merged.count, 1)
        XCTAssertFalse(merged[0].sentenceStart, "seen once mid-sentence, it is a name")
    }

    func testANewNameGetsASheetAndNotANameIsRemembered() throws {
        let s = try book(["The office door opened."])
        s.text = "A woman came out with two mugs. “I’m Odile,” she said, and Odile smiled at Nora’s brother Tom."
        s.spotter.spot()
        let odile = try XCTUnwrap(s.bible.entry(named: "Odile"), "\(s.bible.entries.map(\.title))")
        XCTAssertEqual(odile.kind, .character)
        XCTAssertEqual(odile.meta["origin"], "musset")
        XCTAssertEqual(s.spotter.joined?.title.isEmpty, false)
        s.spotter.notAName(odile.path)
        XCTAssertNil(s.bible.entry(named: "Odile"))
        XCTAssertTrue(NameSpotter.loadIgnored(s.root).contains(Fold.name("Odile")))
        s.spotter.spot()
        XCTAssertNil(s.bible.entry(named: "Odile"), "a word refused once never comes back")
    }

    func testACommonWordStartingASentenceIsNotAName() {
        XCTAssertTrue(NameSpotter.isDictionaryWord("below", lang: "en"))
        XCTAssertFalse(NameSpotter.isDictionaryWord("odile", lang: "en"))
    }
}
