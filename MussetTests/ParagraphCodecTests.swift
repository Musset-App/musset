import XCTest
@testable import Musset

final class ParagraphCodecTests: XCTestCase {
    let ls = "\u{2028}"

    func testMapping() {
        XCTAssertEqual(ParagraphCodec.decode("A\n\nB\n"), "A\nB\n")
        XCTAssertEqual(ParagraphCodec.decode("A\nB"), "A\(ls)B")
        XCTAssertEqual(ParagraphCodec.decode("A\n\n\nB"), "A\n\nB")
        XCTAssertEqual(ParagraphCodec.decode("\n\nA\n\n"), "\n\nA\n\n")
        XCTAssertEqual(ParagraphCodec.encode("Un\nDeux\nTrois  \(ls)vers\n"), "Un\n\nDeux\n\nTrois  \nvers\n")
        XCTAssertEqual(ParagraphCodec.importExternal("Un\n\nDeux"), "Un\nDeux")
        XCTAssertEqual(ParagraphCodec.importExternal("déjà une ligne"), "déjà une ligne")
    }

    /// Every Markdown file of the three books comes back byte for byte.
    func testRoundTripOnAllBooks() throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        // The author's books are not in the public repository: without them, nothing to check here.
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixtures.path), "no fixtures")
        guard let walker = FileManager.default.enumerator(at: fixtures, includingPropertiesForKeys: nil) else { throw XCTSkip("no fixtures") }
        var checked = 0
        for case let url as URL in walker where url.pathExtension == "md" && !url.path.contains("/.git/") && !url.path.contains("/.musset/") {
            guard let disk = try? String(contentsOf: url, encoding: .utf8) else { continue }
            XCTAssertEqual(ParagraphCodec.encode(ParagraphCodec.decode(disk)), disk, url.lastPathComponent)
            checked += 1
        }
        print("CODEC round-trip on \(checked) files")
        XCTAssertGreaterThan(checked, 60)
    }

    func testChatMarkdownBlocks() {
        let md = "## Titre\n\nUn **gras** et *italique*.\n\n- un\n- deux\n\n1. premier\n2. second\n\n> cité\n\n```revision\ntexte\n```\n"
        XCTAssertEqual(MarkdownText.blocks(md), [
            .heading(2, "Titre"), .paragraph("Un **gras** et *italique*."), .bullet(["un", "deux"]),
            .numbered(["premier", "second"]), .quote("cité"), .code("texte", lang: "revision"),
        ])
    }
}
