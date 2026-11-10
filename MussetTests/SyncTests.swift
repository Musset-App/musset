import XCTest
@testable import Musset

final class SyncMergeTests: XCTestCase {
    func testChapterTakesEachSideAndKeepsMineWhenBothRewrote() {
        let base = "# T\nUn.\nDeux.\nTrois."
        let out = SyncMerge.chapter(base: base, mine: "# T\nUn modifié.\nDeux.\nTrois moi.", theirs: "# T\nUn.\nDeux lui.\nTrois lui.", who: "bob")
        XCTAssertEqual(out.conflicts, 1)
        XCTAssertEqual(out.text, "# T\nUn modifié.\nDeux lui.\n{~~Trois moi.~>Trois lui.~~}{>>bob<<}")
    }

    func testJSONByFieldAndRecord() throws {
        func d(_ s: String) -> Data { Data(s.utf8) }
        let base = #"{"title":"T","goal":1,"chapters":[{"id":"a","title":"A"},{"id":"b","title":"B"}]}"#
        let mine = #"{"title":"Moi","goal":1,"chapters":[{"id":"a","title":"A2"},{"id":"b","title":"B"}]}"#
        let theirs = #"{"title":"T","goal":2,"chapters":[{"id":"a","title":"A"},{"id":"c","title":"C"}]}"#
        let out = try JSONSerialization.jsonObject(with: SyncMerge.json(base: d(base), mine: d(mine), theirs: d(theirs))) as! [String: Any]
        XCTAssertEqual(out["title"] as? String, "Moi")
        XCTAssertEqual(out["goal"] as? Int, 2)
        let chapters = out["chapters"] as! [[String: Any]]
        XCTAssertEqual(chapters.map { $0["id"] as! String }, ["a", "c"], "b was removed there, untouched here")
        XCTAssertEqual(chapters[0]["title"] as? String, "A2")
    }
}

final class AttributionTests: XCTestCase {
    func testWordsKeepTheirAuthorThroughEdits() {
        let first = Attribution.next(words: ["le", "chat", "dort"], parents: [], author: 0)
        let second = Attribution.next(words: ["le", "gros", "chat", "dort", "ici"], parents: [first], author: 1)
        XCTAssertEqual(second.map(\.author), [0, 1, 0, 0, 1])
        let merged = Attribution.next(words: ["le", "gros", "chat", "dort", "ici", "encore"],
                                      parents: [first, second], author: 2)
        XCTAssertEqual(merged.map(\.author), [0, 1, 0, 0, 1, 2], "A merge doesn't take the words of its second parent")
    }

    func testTypographyDoesNotTakeAWord() {
        XCTAssertEqual(Attribution.tokens("l'A6").map(\.word), Attribution.tokens("l’A6").map(\.word))
        XCTAssertEqual(Attribution.tokens("Oui !").map(\.word), Attribution.tokens("Oui\u{00A0}!").map(\.word))
    }

    func testMapLaysHistoryOnTheTextWithCorrectionsAndUnsavedWords() {
        var a = Attribution()
        a.authors = [.init(person: "alice", date: Date(timeIntervalSince1970: 1))]
        a.words = Attribution.next(words: ["le", "chat", "dort"], parents: [], author: 0)
        let map = a.map(onto: "le {~~chat~>chien~~}{>>bob<<} dort bien", me: "moi")
        XCTAssertEqual(map.people.first { $0.person == "alice" }?.words, 2)
        XCTAssertEqual(map.people.first { $0.person == "moi" }?.words, 2, "chien and bien")
    }
}

/// End to end against a Forgejo on this Mac: MUSSET_SERVER=http://localhost:3939, users alice, bob, carol.
@MainActor
final class SyncLiveTests: XCTestCase {
    private func tmp(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("musset-sync-\(UUID().uuidString.prefix(6))-\(name)")
        addTeardownBlock { try? FileManager.default.removeItem(at: u) }
        return u
    }
    private func signIn(_ u: String) async throws { try await Collab.shared.signIn(username: u, password: "testpass-\(u)-123") }
    private func session(_ root: URL) throws -> BookSession { BookSession(root: root, manifest: try BookStore(root: root).loadManifest()) }
    private func write(_ s: BookSession, _ text: String) { s.textDidChange(text); s.flushSave() }

    func testTwoMacsRolesDocumentsAndWhoWroteWhat() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_SERVER"] != nil)
        let c = Collab.shared
        addTeardownBlock { await MainActor.run { Collab.shared.signOut() } }
        try await signIn("alice")

        // The author's first Mac: a book, a file of their own in the folder.
        let macA = tmp("A")
        try FileManager.default.createDirectory(at: macA, withIntermediateDirectories: true)
        let original = "# Lyon\n\nUn.\n\nDeux.\n\nTrois.\n"
        try original.write(to: macA.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "à moi".write(to: macA.appendingPathComponent("mes-notes.txt"), atomically: true, encoding: .utf8)
        try GitService(root: macA).initRepo()
        let title = "Essai \(UUID().uuidString.prefix(6))"
        try BookStore(root: macA).saveManifest(BookManifest(title: title, chapters: [ChapterEntry(id: "01", file: "01.md", title: "Lyon")]))
        let a = try session(macA)
        try await c.share(a)
        await c.syncNow(a)
        XCTAssertEqual(c.sync, .upToDate)

        // The second Mac finds it on the account.
        let repoFound = try await c.onlineBooks().first { $0.description == title }
        let repo = try XCTUnwrap(repoFound)
        let macB = tmp("B")
        try await c.open(repo, into: macB)
        let b = try session(macB)
        XCTAssertEqual(b.manifest.title, title)
        XCTAssertEqual(b.git.currentBranch, "main")
        XCTAssertFalse(FileManager.default.fileExists(atPath: macB.appendingPathComponent("mes-notes.txt").path), "The author's own files stay on their Mac")

        // Offline on both: different paragraphs merge, and a new chapter comes along.
        write(a, a.text.replacingOccurrences(of: "Un.", with: "Un, sur A."))
        write(b, b.text.replacingOccurrences(of: "Trois.", with: "Trois, sur B."))
        b.addChapter(title: "Nice")
        b.open("01")
        await c.syncNow(a)
        await c.syncNow(b)
        await c.syncNow(a)
        XCTAssertEqual(c.sync, .upToDate)
        for s in [a, b] {
            XCTAssertTrue(s.text.contains("Un, sur A."), s.root.lastPathComponent)
            XCTAssertTrue(s.text.contains("Trois, sur B."), s.root.lastPathComponent)
            XCTAssertEqual(s.manifest.chapters.map(\.title), ["Lyon", "Nice"])
        }
        XCTAssertEqual(try String(contentsOf: macA.appendingPathComponent("mes-notes.txt"), encoding: .utf8), "à moi")

        // The same paragraph on both: nothing lost, the other side as a correction.
        write(a, a.text.replacingOccurrences(of: "Deux.", with: "Deux par A."))
        write(b, b.text.replacingOccurrences(of: "Deux.", with: "Deux par B."))
        await c.syncNow(a)
        await c.syncNow(b)
        XCTAssertEqual(c.sync, .corrections(1))
        XCTAssertTrue(b.text.contains("{~~Deux par B.~>Deux par A.~~}"), b.text)
        await c.syncNow(a)
        XCTAssertEqual(a.text, b.text)

        // Documents travel in their own repository.
        let docs = a.bible.store.dir.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try Data([0, 1, 2, 3, 255]).write(to: docs.appendingPathComponent("plan.pdf"))
        try a.bible.store.prepare(docs.appendingPathComponent("plan.pdf"))
        await c.syncNow(a)
        XCTAssertEqual(c.sync, .upToDate)
        await c.syncNow(b)
        XCTAssertEqual(try? Data(contentsOf: b.bible.store.dir.appendingPathComponent("documents/plan.pdf")), Data([0, 1, 2, 3, 255]))
        XCTAssertNil(a.git.show("HEAD", path: "bible/documents/plan.pdf"), "Never in the book's history")

        // Two roles, on the server.
        try await c.invite("bob", as: .editor, to: a)
        try await c.invite("carol", as: .collaborator, to: a)
        let people = try await c.people(of: a)
        XCTAssertEqual(people.first { $0.user == "bob" }?.role, .editor)
        XCTAssertEqual(people.first { $0.user == "carol" }?.role, .collaborator)

        try await signIn("carol")
        let macC = tmp("C")
        let forCarolFound = try await c.onlineBooks().first { $0.description == title }
        let forCarol = try XCTUnwrap(forCarolFound)
        try await c.open(forCarol, into: macC)
        let carol = try session(macC)
        XCTAssertEqual(c.role(carol.git), .collaborator)
        XCTAssertEqual(carol.git.currentBranch, "main")
        XCTAssertFalse(c.isReviewer(carol.git))
        await c.syncNow(carol)
        XCTAssertNotNil(try? Data(contentsOf: carol.bible.store.dir.appendingPathComponent("documents/plan.pdf")), "A collaborator sees the documents")
        write(carol, carol.text.replacingOccurrences(of: "Un, sur A.", with: "Un, sur A, avec Carol."))
        await c.syncNow(carol)
        XCTAssertEqual(c.sync, .upToDate)
        XCTAssertTrue(carol.git.show("HEAD", path: "01.md")?.contains("avec Carol") == true, "Her words are committed, beside the documents' own repository")

        try await signIn("bob")
        let macD = tmp("D")
        let forBobFound = try await c.onlineBooks().first { $0.description == title }
        let forBob = try XCTUnwrap(forBobFound)
        try await c.open(forBob, into: macD)
        let bob = try session(macD)
        XCTAssertEqual(c.role(bob.git), .editor)
        XCTAssertTrue(c.isReviewer(bob.git))
        XCTAssertEqual(bob.git.currentBranch, "relecture/bob")
        // Even a client that tries can't write in the main text.
        let creds = try XCTUnwrap(c.credentials)
        XCTAssertThrowsError(try bob.git.push("origin", refspecs: ["refs/heads/relecture/bob:refs/heads/main"], credentials: creds))
        write(bob, bob.text.replacingOccurrences(of: "Trois, sur B.", with: "Trois, relu."))
        try await c.sendReview(bob, message: "")
        await c.syncNow(bob)
        XCTAssertNil(try? Data(contentsOf: bob.bible.store.dir.appendingPathComponent("documents/plan.pdf")), "An editor gets no document")

        // Back to the author: a review arrives as corrections, signed by its reader.
        try await signIn("alice")
        await c.syncNow(a)
        XCTAssertTrue(a.text.contains("avec Carol"))
        let waiting = try await c.reviews(of: a)
        let review = try XCTUnwrap(waiting.first)
        _ = try await c.importReview(review, into: a)
        XCTAssertTrue(a.text.contains("relu"), a.text)

        // Who wrote what, word by word.
        let history = try Attribution.compute(a.git, path: "01.md", owner: "alice")
        let map = history.map(onto: a.text, me: "alice")
        let names = Set(map.people.map(\.person))
        XCTAssertEqual(names, ["alice", "carol", "bob"], "\(map.people)")
        let ns = a.text as NSString
        let carols = map.runs.filter { map.people[$0.person].person == "carol" }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(carols, ["avec Carol"], "\(carols)")
        let bobs = map.runs.filter { map.people[$0.person].person == "bob" }.map { ns.substring(with: $0.range) }
        XCTAssertEqual(bobs, ["relu"], "\(bobs)")
    }
}
