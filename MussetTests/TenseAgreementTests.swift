import XCTest
@testable import Musset

final class TenseAgreementTests: XCTestCase {
    let text = "Hier, je marchais dans la rue. Soudain, un homme m’a abordé et il me demande l’heure. Je lui répondis que je ne savais pas."

    private func fix(_ o: String, _ r: String) -> ProofFix {
        ProofFix(original: o, replacement: r, reason: "temps")
    }

    func testOnlyTheChangedWordsAreMarked() {
        let changes = TenseAgreement.changes([fix("un homme m’a abordé et", "un homme m’aborda et"),
                                              fix("il me demande l’heure", "il me demanda l’heure")],
                                             in: text, scope: NSRange(location: 0, length: (text as NSString).length))
        let ns = text as NSString
        XCTAssertEqual(changes.map { ns.substring(with: $0.range) }, ["m’a abordé", "demande"])
        XCTAssertEqual(changes.map(\.replacement), ["m’aborda", "demanda"])
    }

    func testOutsideTheScopeOrOnAMarkNothingChanges() {
        let marked = "Il {~~mange~>mangea~~} et il dort."
        let none = TenseAgreement.changes([fix("Il mange et", "Il mangea et")], in: marked,
                                          scope: NSRange(location: 0, length: (marked as NSString).length))
        XCTAssertTrue(none.isEmpty)
        let same = TenseAgreement.changes([fix("je marchais dans", "je marchais dans")], in: text, scope: NSRange(location: 0, length: 20))
        XCTAssertTrue(same.isEmpty)
    }

    /// Asks the real engine (MUSSET_LIVE=1).
    @MainActor
    func testLiveAgreement() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        await AIStatus.shared.detect()
        let start = Date()
        let fixes = try await TenseAgreement.run(text, target: .dominant, lang: "fr", root: FileManager.default.temporaryDirectory)
        let changes = TenseAgreement.changes(fixes, in: text, scope: NSRange(location: 0, length: (text as NSString).length))
        let ns = text as NSString
        print("TENSES \(Int(Date().timeIntervalSince(start)))s", changes.map { "\(ns.substring(with: $0.range)) → \($0.replacement)" })
        XCTAssertTrue(changes.contains { $0.replacement.contains("demanda") })
    }
}
