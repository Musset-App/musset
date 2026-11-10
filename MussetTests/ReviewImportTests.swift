import XCTest
@testable import Musset

final class ReviewImportTests: XCTestCase {
    let base = "Le facteur est passé vers midi, sous un parapluie noir.\nJe revois encore la vieille malle sous la fenêtre.\nLe bruit de la pluie lente sur le toit."

    func testReaderEditsBecomeCorrectionsOnTheCurrentText() {
        // The reader changed a word, deleted a sentence's end and commented a passage, in revision mode.
        let reader = "Le facteur est passé vers midi, sous un {~~parapluie~>parapluie de toile~~} noir.\nJe revois encore la vieille malle{-- sous la fenêtre--}.\n{==Le bruit de la pluie==}{>>Trop attendu ?<<} lente sur le toit."
        // Meanwhile the author kept writing: a new first paragraph, and a word changed elsewhere.
        let current = "Il pleuvait depuis le matin.\nLe facteur est passé vers midi, sous un parapluie noir.\nJe revois encore la vieille malle sous la fenêtre.\nLe bruit de la pluie lourde sur le toit."
        let out = ReviewImport.apply(base: base, reviewer: reader, current: current, reader: "marie")
        XCTAssertTrue(out.text.hasPrefix("Il pleuvait depuis le matin.\n"), "the author's new text stays")
        XCTAssertTrue(out.text.contains("{==Le bruit de la pluie==}{>>marie : Trop attendu ?<<} lourde"), out.text)
        XCTAssertTrue(out.unplaced.isEmpty, "\(out.unplaced)")
        // Accepting everything gives the reader's version on top of the author's latest text.
        XCTAssertEqual(Revisions.resolveAll(out.text, accept: true),
                       "Il pleuvait depuis le matin.\nLe facteur est passé vers midi, sous un parapluie de toile noir.\nJe revois encore la vieille malle.\nLe bruit de la pluie lourde sur le toit.")
        XCTAssertEqual(Revisions.resolveAll(out.text, accept: false), Revisions.resolveAll(current, accept: false))
    }

    func testPlainEditsAndRewrittenPassages() {
        // The reader edited without revision mode; the author has since rewritten the second sentence.
        let reader = "Le facteur est passé vers midi, sous un parapluie gris.\nJe revois encore la malle sous la fenêtre.\nLe bruit de la pluie lente sur le toit.\nPuis il est reparti."
        let current = "Le facteur est passé vers midi, sous un parapluie noir.\nCette malle, je la revois encore.\nLe bruit de la pluie lente sur le toit."
        let out = ReviewImport.apply(base: base, reviewer: reader, current: current, reader: "marie")
        XCTAssertTrue(out.text.contains("{~~noir.~>gris.~~}"), out.text)
        XCTAssertTrue(out.text.contains("toit.\n{++Puis il est reparti.++}"), "a new paragraph is proposed: \(out.text)")
        XCTAssertEqual(Revisions.resolveAll(out.text, accept: true),
                       "Le facteur est passé vers midi, sous un parapluie gris.\nCette malle, je la revois encore.\nLe bruit de la pluie lente sur le toit.\nPuis il est reparti.")
        XCTAssertTrue(out.text.contains("Cette malle, je la revois encore."), "the author's rewrite is untouched")
        XCTAssertEqual(out.unplaced.count, 1, "the change to the rewritten sentence comes back as a comment: \(out.unplaced)")
    }
}
