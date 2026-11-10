import XCTest
@testable import Musset

final class WordLookupTests: XCTestCase {
    func testDecodesTheAnswerAroundItsProse() {
        let raw = """
        Voici :
        [{"word": "demeure"}, {"word": " "}, {"word": "méson", "sense": "particule"}, {"word": "logis", "sense": ""}]
        """
        let r = WordLookup.decode(raw)
        XCTAssertEqual(r?.map(\.word), ["demeure", "méson", "logis"])
        XCTAssertEqual(r?.map(\.sense), [nil, "particule", nil])
        XCTAssertNil(WordLookup.decode("pas de JSON"))
    }

    func testKeepsTheCapital() {
        XCTAssertEqual(WordLookup.matchingCase("demeure", of: "Maison"), "Demeure")
        XCTAssertEqual(WordLookup.matchingCase("demeure", of: "maison"), "demeure")
        XCTAssertEqual(WordLookup.matchingCase("Paris", of: "ville"), "Paris")
    }

    /// Asks the real engine (MUSSET_LIVE=1).
    @MainActor
    func testLiveLookup() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        await AIStatus.shared.detect()
        let context = "Il revint à la maison au soir, la mer derrière lui, la fatigue aux mains. Le vert des volets avait passé."
        for (kind, word) in [(WordLookup.Kind.synonyms, "maison"), (.homonyms, "vert"), (.alliterations, "maison")] {
            let r = try await WordLookup.lookup(kind, word: word, context: context, lang: "fr", root: FileManager.default.temporaryDirectory)
            print("WORDS", kind, r.map { w in w.sense.map { "\(w.word) (\($0))" } ?? w.word })
            XCTAssertFalse(r.isEmpty)
        }
    }
}
