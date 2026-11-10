import XCTest
@testable import Musset

@MainActor
final class FormattingTests: XCTestCase {
    private func view(_ text: String, select: NSRange) -> ZenTextView {
        let tv = ZenTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.string = text
        tv.setSelectedRange(select)
        return tv
    }

    func testBoldAndItalicToggle() {
        let tv = view("Il pleuvait sur Nice.", select: NSRange(location: 3, length: 8))
        tv.toggleInline("**")
        XCTAssertEqual(tv.string, "Il **pleuvait** sur Nice.")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 8))
        tv.toggleInline("**")
        XCTAssertEqual(tv.string, "Il pleuvait sur Nice.", "the same command removes it")
        tv.toggleInline("*")
        XCTAssertEqual(tv.string, "Il *pleuvait* sur Nice.")
        let empty = view("Nice", select: NSRange(location: 4, length: 0))
        empty.toggleInline("*")
        XCTAssertEqual(empty.string, "Nice**")
        XCTAssertEqual(empty.selectedRange().location, 5, "the caret goes between the markers")
    }

    func testHeadingsQuoteAndFootnote() {
        let tv = view("Titre\nTexte.", select: NSRange(location: 2, length: 0))
        tv.setHeading(2)
        XCTAssertEqual(tv.string, "## Titre\nTexte.")
        tv.setHeading(1)
        XCTAssertEqual(tv.string, "# Titre\nTexte.")
        tv.setHeading(1)
        XCTAssertEqual(tv.string, "Titre\nTexte.", "the same level again makes it text")
        let q = view("Une phrase.", select: NSRange(location: 0, length: 0))
        q.toggleQuote()
        XCTAssertEqual(q.string, "> Une phrase.")
        q.toggleQuote()
        XCTAssertEqual(q.string, "Une phrase.")
        let f = view("Le Kawai", select: NSRange(location: 8, length: 0))
        f.insertFootnote()
        XCTAssertEqual(f.string, "Le Kawai^[]")
        XCTAssertEqual(f.selectedRange().location, 10)
    }

    func testFootnotesPrint() {
        let typst = TypstMarkup.chapter("Le Kawai^[Un quart de queue, *noir*.] trônait.", id: "c", markers: false)
        XCTAssertTrue(typst.contains("Kawai#footnote[Un quart de queue, #emph[noir].] trônait."), typst)
    }
}
