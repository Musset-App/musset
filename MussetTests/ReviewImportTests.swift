import XCTest
@testable import Musset

final class ReviewImportTests: XCTestCase {
    let base = "Le facteur est passé vers midi, sous un parapluie noir.\nJe revois encore la vieille malle sous la fenêtre.\nLe bruit de la pluie lente sur le toit."

    func testReaderEditsBecomeCorrectionsOnTheCurrentText() {
        // The reader changed a word, deleted a sentence's end and commented a passage, in revision mode.
        let reader = "Le facteur est passé vers midi, sous un {~~parapluie~>parapluie de toile~~} noir.\nJe revois encore la vieille malle{-- sous la fenêtre--}.\n{==Le bruit de la pluie==}{>>Trop attendu ?<<} lente sur le toit."
        // Meanwhile the author kept writing: a new first paragraph, and a word changed elsewhere.
        let current = "Il pleuvait depuis le matin.\nLe facteur est passé vers midi, sous un parapluie noir.\nJe revois encore la vieille malle sous la fenêtre.\nLe bruit de la pluie lourde sur le toit."
        let out = ReviewImport.apply(base: base, reviewer: reader, current: current)
        XCTAssertTrue(out.text.hasPrefix("Il pleuvait depuis le matin.\n"), "the author's new text stays")
        // Their comment leaves no mark in the text: it comes back as a remark on its passage, where it stands now.
        XCTAssertFalse(out.text.contains("{>>"), out.text)
        XCTAssertEqual(out.remarks.map(\.body), ["Trop attendu ?"])
        XCTAssertEqual(out.remarks.first.flatMap { r in r.at.map { (out.text as NSString).substring(with: NSRange(location: $0, length: (r.quote as NSString).length)) } }, "Le bruit de la pluie")
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
        let out = ReviewImport.apply(base: base, reviewer: reader, current: current)
        XCTAssertTrue(out.text.contains("{~~noir.~>gris.~~}"), out.text)
        XCTAssertTrue(out.text.contains("toit.\n{++Puis il est reparti.++}"), "a new paragraph is proposed: \(out.text)")
        XCTAssertEqual(Revisions.resolveAll(out.text, accept: true),
                       "Le facteur est passé vers midi, sous un parapluie gris.\nCette malle, je la revois encore.\nLe bruit de la pluie lente sur le toit.\nPuis il est reparti.")
        XCTAssertTrue(out.text.contains("Cette malle, je la revois encore."), "the author's rewrite is untouched")
        XCTAssertEqual(out.unplaced.count, 1, "the change to the rewritten sentence comes back as a comment: \(out.unplaced)")
    }
}

/// A reader's remark reaches the author one way, whatever the reader used to make it: as a conversation, kept once.
@MainActor
final class ReviewRemarksTests: XCTestCase {
    private let chapter = "Le facteur est passé vers midi, sous un parapluie noir.\nJe revois encore la vieille malle sous la fenêtre.\nLe bruit de la pluie lente sur le toit.\n"

    private func anchor(_ quote: String, in text: String) -> NoteAnchor {
        Anchoring.capture((text as NSString).range(of: quote), in: text as NSString, version: nil)
    }

    /// The author's book on main, and bob's review on his branch: a correction, a comment in the text, margin notes
    /// (Markdown for one chapter, the JSON of an older Musset for the other) and a conversation started from the page.
    private func book() throws -> (session: BookSession, base: String, own: Note) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-remarks-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".musset/notes"), withIntermediateDirectories: true)
        let manifest = BookManifest(title: "Le Sel", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un"), ChapterEntry(id: "02", file: "02.md", title: "Deux")])
        try BookStore(root: root).saveManifest(manifest)
        try chapter.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "Deuxième chapitre, sans histoire.\n".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let own = Note(author: .me, kind: .todo, body: "Vérifier l'heure du facteur", anchor: anchor("vers midi", in: chapter))
        try NoteMarkdown.encode([own]).write(to: root.appendingPathComponent(".musset/notes/01.md"), atomically: true, encoding: .utf8)
        let git = GitService(root: root)
        try git.initRepo()
        _ = try git.commit(paths: ["*"], message: "base")
        let base = try XCTUnwrap(git.resolve("HEAD"))

        try git.switchBranch("relecture/bob", at: base)
        let theirs = chapter.replacingOccurrences(of: "parapluie noir", with: "parapluie {~~noir~>vert~~}")
            .replacingOccurrences(of: "Le bruit de la pluie", with: "{==Le bruit de la pluie==}{>>Trop attendu ?<<}")
        try theirs.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        var settled = Note(author: .me, kind: .question, body: "Quelle malle ?", anchor: anchor("la vieille malle", in: chapter))
        settled.replies = [Note.Reply(author: .me, body: "Celle du grenier, vu plus loin.")]
        settled.status = .resolved
        let plain = Note(author: .me, kind: .note, body: "Beau début.", anchor: anchor("Le facteur est passé", in: chapter))
        try NoteMarkdown.encode([own, settled, plain]).write(to: root.appendingPathComponent(".musset/notes/01.md"), atomically: true, encoding: .utf8)
        let old = Note(author: .me, kind: .critique, body: "Un peu court.", anchor: anchor("sans histoire", in: "Deuxième chapitre, sans histoire.\n"))
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode([old]).write(to: root.appendingPathComponent(".musset/notes/02.json"))
        let id = UUID()
        let said = TalkEntry(id: id, thread: id, kind: .note, by: "bob", body: "On dirait un souvenir d'enfance.", chapter: "01",
                             anchor: anchor("Je revois encore", in: chapter), mark: .underline)
        try fm.createDirectory(at: root.appendingPathComponent(".musset/talk/bob"), withIntermediateDirectories: true)
        try Talk.encode([said]).write(to: root.appendingPathComponent(".musset/talk/bob/01.json"))
        _ = try git.commit(paths: ["*"], message: "review")
        try git.switchBranch("main", at: base)

        let session = BookSession(root: root, manifest: manifest)
        session.talk.load(me: "mara", owner: "mara", remote: nil, chapters: ["01", "02"], git: git)
        return (session, base, own)
    }

    func testEverythingAReaderSaidBecomesConversationsOnItsPassage() throws {
        let (s, base, own) = try book()
        let out = try s.adoptReview(theirs: "relecture/bob", base: base, reader: "bob")
        XCTAssertEqual(out.placed, 1)
        let text = s.editorText(of: "01")
        XCTAssertTrue(text.contains("{~~noir.~>vert.~~}"), text)
        XCTAssertFalse(text.contains("{>>"), "the reader's comment is a conversation, not a mark in the author's text: \(text)")

        let threads = s.talk.threads
        XCTAssertEqual(Set(threads.map(\.note.body)), ["Trop attendu ?", "Quelle malle ?", "Beau début.", "Un peu court.", "On dirait un souvenir d'enfance."])
        XCTAssertTrue(threads.allSatisfy { $0.starter == "bob" })
        let comment = try XCTUnwrap(threads.first { $0.note.body == "Trop attendu ?" })
        let spot = try XCTUnwrap(comment.note.anchor.flatMap { Anchoring.resolve($0, in: text) })
        XCTAssertEqual((text as NSString).substring(with: spot), "Le bruit de la pluie")
        let question = try XCTUnwrap(threads.first { $0.note.body == "Quelle malle ?" })
        XCTAssertEqual(question.replies.map(\.body), ["Celle du grenier, vu plus loin."])
        XCTAssertEqual(question.resolvedBy, "bob")
        XCTAssertEqual(question.note.tone, "question")
        XCTAssertEqual(threads.first { $0.note.body == "Un peu court." }?.chapter, "02", "the JSON notes of an older Musset still read")

        // The author's notes are the author's: nothing of the reader's joined them, nothing of theirs left.
        XCTAssertEqual(NoteStore.read(NoteStore.url(s.root, "01")).map(\.id), [own.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: NoteStore.url(s.root, "02").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.root.appendingPathComponent(".musset/talk/mara").path), "the author said nothing yet")
    }

    func testTheSameReviewBroughtInTwiceAddsNothing() throws {
        let (s, base, _) = try book()
        try s.adoptReview(theirs: "relecture/bob", base: base, reader: "bob")
        let text = s.editorText(of: "01")
        let files = ["01", "02"].map { try? Data(contentsOf: s.root.appendingPathComponent(Talk.path("bob", $0))) }
        let threads = s.talk.threads
        XCTAssertEqual(threads.count, 5)

        let again = try s.adoptReview(theirs: "relecture/bob", base: base, reader: "bob")
        XCTAssertEqual(again.placed, 0)
        XCTAssertEqual(again.unplaced, 0)
        XCTAssertEqual(s.editorText(of: "01"), text, "the corrections already stand in the text")
        XCTAssertEqual(s.talk.threads, threads)
        XCTAssertEqual(["01", "02"].map { try? Data(contentsOf: s.root.appendingPathComponent(Talk.path("bob", $0))) }, files, "not a byte written")

        // Read again from the folder, with the reader's branch still there: each remark once.
        let reread = TalkStore(root: s.root)
        reread.load(me: "mara", owner: "mara", remote: nil, chapters: ["01", "02"], git: s.git)
        XCTAssertEqual(reread.threads.map(\.id), threads.map(\.id))
        XCTAssertEqual(reread.threads.first { $0.note.body == "Quelle malle ?" }?.replies.count, 1)
    }

    /// A remark an earlier Musset brought in as a note stays a note, and is not said again as a conversation.
    func testANoteAlreadyBroughtInByAnOlderMussetIsNotSaidTwice() throws {
        let (s, base, _) = try book()
        let theirs = NoteMarkdown.decode(try XCTUnwrap(s.git.show("relecture/bob", path: ".musset/notes/01.md")))
        s.importNotes(theirs.filter { $0.body == "Beau début." }, chapter: "01", from: "bob")
        try s.adoptReview(theirs: "relecture/bob", base: base, reader: "bob")
        XCTAssertFalse(s.talk.threads.contains { $0.note.body == "Beau début." })
        XCTAssertEqual(s.talk.threads.count, 4)
    }

    func testAnEntrySeenOnTheBranchAndOnMainCountsOnce() {
        let id = UUID()
        let note = TalkEntry(id: id, thread: id, kind: .note, by: "bob", body: "?", chapter: "01")
        let reply = TalkEntry(thread: id, kind: .reply, by: "bob", body: "!", chapter: "01")
        let threads = Talk.threads(from: [note, reply, note, reply])
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].replies.count, 1)
    }
}
