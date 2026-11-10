import XCTest
@testable import Musset

/// Live, against git.musset.app: an author shares, a reader reviews, the author brings the review in.
/// Two throwaway accounts; delete them afterwards on the server. MUSSET_LIVE=1.
@MainActor
final class CollabLiveTests: XCTestCase {
    func testShareReviewAndBringBack() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let c = Collab.shared
        let savedUser = c.username, savedToken = Secrets.get("forgejo-token")
        defer { c.username = savedUser; Secrets.set("forgejo-token", savedToken ?? "") }
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let author = "auteur\(stamp)", reader = "lecteur\(stamp)", pass = "musset-test-\(UUID().uuidString.prefix(8))"
        print("LIVE accounts \(author) \(reader)")

        // The reader's account first, then the author's.
        try await c.signUp(username: reader, email: "\(reader)@example.com", password: pass)
        let readerToken = Secrets.get("forgejo-token")!
        try await c.signUp(username: author, email: "\(author)@example.com", password: pass)
        let authorToken = Secrets.get("forgejo-token")!

        // The author's book.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-live-collab-\(stamp)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# Un\n\nLe facteur est passé vers midi, sous un parapluie noir.\n\nJe revois encore la vieille malle sous la fenêtre.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try GitService(root: root).initRepo()
        var manifest = BookManifest(title: "Essai \(stamp)", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")])
        manifest.exports = []
        try BookStore(root: root).saveManifest(manifest)
        let book = BookSession(root: root, manifest: manifest)
        book.open("01")
        try await c.share(book)
        XCTAssertTrue(c.isOwner(book.git))
        try await c.invite(reader, as: .editor, to: book)

        // The reader downloads it and corrects in revision mode.
        c.username = reader; Secrets.set("forgejo-token", readerToken)
        let shared = try await c.onlineBooks()
        let repo = try XCTUnwrap(shared.first { $0.owner.login == author })
        let mine = FileManager.default.temporaryDirectory.appendingPathComponent("musset-live-review-\(stamp)")
        try await c.open(repo, into: mine)
        XCTAssertEqual(GitService(root: mine).currentBranch, "relecture/\(reader)")
        let readerBook = BookSession(root: mine, manifest: try BookStore(root: mine).loadManifest())
        readerBook.open("01")
        XCTAssertTrue(c.isReviewer(readerBook.git))
        readerBook.replaceText(readerBook.text.replacingOccurrences(of: "parapluie noir", with: "parapluie {~~noir~>vert~~}"))
        try await c.sendReview(readerBook, message: "Quelques remarques.")

        // Meanwhile the author kept writing; then reads the review.
        c.username = author; Secrets.set("forgejo-token", authorToken)
        book.replaceText(book.text + "\nIl s’est rué dans les escaliers.")
        book.commitNow("musset: more writing")
        let reviews = try await c.reviews(of: book)
        let review = try XCTUnwrap(reviews.first)
        let out = try await c.importReview(review, into: book)
        print("LIVE placed \(out.placed), unplaced \(out.unplaced)")
        XCTAssertEqual(out.placed, 1)
        XCTAssertTrue(book.text.contains("{~~noir~>vert~~}") || book.text.contains("{~~noir.~>vert.~~}"), book.text)
        XCTAssertTrue(book.text.contains("Il s’est rué dans les escaliers."), "the author's new writing stays")
        let afterwards = try await c.reviews(of: book)
        XCTAssertTrue(afterwards.isEmpty, "the review is closed once brought in")
    }
}
