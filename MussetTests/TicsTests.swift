import XCTest
@testable import Musset

final class TicsTests: XCTestCase {
    func testTagsGiveTheKind() {
        XCTAssertEqual(Note.Kind.fromTag("[Réussite] La scène tient."), .praise)
        XCTAssertEqual(Note.Kind.fromTag("[reussite] ok"), .praise)
        XCTAssertEqual(Note.Kind.fromTag("[Antithèse corrective] Personne n'imaginait X."), .tic)
        XCTAssertEqual(Note.Kind.fromTag("[Ligne seule] …"), .tic)
        XCTAssertEqual(Note.Kind.fromTag("[Coupe] …"), .cut)
        XCTAssertEqual(Note.Kind.fromTag("[Déjà dit] chapitre 3"), .repetition)
        XCTAssertEqual(Note.Kind.fromTag("[À vérifier] la date"), .fact)
        XCTAssertNil(Note.Kind.fromTag("[Langue] trop abstrait"))
        XCTAssertNil(Note.Kind.fromTag("Pas de tag"))
        XCTAssertTrue(Note.Kind.praise.isPositive)
        XCTAssertFalse(Note.Kind.tic.isPositive)
    }

    func testScannerFindsEachFamily() {
        let text = [
            "La porte a cédé. Pas un fracas. Un bruit net, sec, ridicule.",
            "Rien.",
            "Les grands événements n'ont pas de son propre, même quand tout s'effondre autour.",
            "Elle est entrée dans la cuisine sans rien dire. Lisse. Fermée.",
            "Il a posé le livre sur la table et il est sorti sans fermer. C'est pire.",
            "— Ce soir.",
        ].joined(separator: "\n")
        let ns = text as NSString
        let found = TicScanner.scan(text).map { ($0.family, ns.substring(with: $0.range)) }
        func has(_ f: TicScanner.Family, _ s: String) -> Bool { found.contains { $0.0 == f && $0.1.contains(s) } }
        XCTAssertTrue(has(.antithesis, "Pas un fracas. Un bruit net"), "\(found)")
        XCTAssertTrue(has(.oneLine, "Rien."))
        XCTAssertTrue(has(.maxim, "Les grands événements"))
        XCTAssertTrue(has(.burst, "Lisse. Fermée."))
        XCTAssertTrue(has(.ending, "C'est pire."))
        XCTAssertFalse(found.contains { $0.1.contains("Ce soir") }, "dialogue is the character, not a tic")
    }

    func testMaximWithAPersonIsNotFlagged() {
        let text = "Les mains de mon père tremblaient quand il refermait la porte du garage le soir."
        XCTAssertFalse(TicScanner.scan(text).contains { $0.family == .maxim })
    }

    func testTicsPromptHasGridAndCandidates() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let prompt = Tics.instruction(root: root, text: "Il est parti. Pas triste. Blanc.")
        XCTAssertTrue(prompt.contains("Grille des tics"))
        XCTAssertTrue(prompt.contains("[Antithèse] « Pas triste. Blanc. »"), prompt)
        XCTAssertTrue(ChatAction.tics.defaultKind == .tic)
    }
}
