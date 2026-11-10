import XCTest
@testable import Musset

@MainActor
final class NoteMarkdownTests: XCTestCase {
    private func temp() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset/notes"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private let anchor = NoteAnchor(quote: "Je me suis réveillé\nvers quatorze heures", prefix: "avant -- ici", suffix: "après", start: 42, version: "main")

    func testEveryFieldSurvives() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        var n = Note(author: .claude, kind: .continuity, body: "[Contradiction] L’Alpine est rouge.\n\n> Pas une citation\n* @moi non plus\nFin #coupe", status: .resolved, created: date, updated: date, anchor: anchor, orphaned: true, run: "run-1")
        n.replies = [Note.Reply(author: .me, body: "D’accord.\nDeux lignes.", created: date), Note.Reply(author: .codex, body: "Vu.", created: date)]
        let free = Note(author: .me, kind: .text, body: "Du texte libre.\nSur deux lignes.", anchor: NoteAnchor(quote: "", prefix: "", suffix: "", start: 0))
        let plain = Note(author: .me, kind: .todo, body: "Développer Clara", status: .done, anchor: NoteAnchor(quote: "", prefix: "", suffix: "", start: 0))
        let back = NoteMarkdown.decode(NoteMarkdown.encode([n, plain, free]))
        XCTAssertEqual(back.count, 3)
        XCTAssertEqual(back[0], n)
        XCTAssertEqual(back[1].body, "Développer Clara")
        XCTAssertEqual(back[1].status, .done)
        XCTAssertEqual(back[1].kind, .todo)
        XCTAssertEqual(back[2].kind, .text)
        XCTAssertEqual(back[2].body, free.body)
    }

    func testTheFileReadsWithoutMusset() {
        let task = Note(author: .me, kind: .todo, body: "Développer Clara", status: .done, anchor: NoteAnchor(quote: "", prefix: "", suffix: "", start: 0))
        let open = Note(author: .me, kind: .fact, body: "Vérifier la date", anchor: anchor)
        let text = NoteMarkdown.encode([task, open])
        XCTAssertTrue(text.hasPrefix("- [x] Développer Clara\n- [ ] Vérifier la date #à-vérifier\n  > Je me suis réveillé\n  > vers quatorze heures\n"), text)
        let resolved = Note(author: .claude, kind: .praise, body: "Bien.", status: .resolved, anchor: anchor)
        XCTAssertTrue(NoteMarkdown.encode([resolved]).hasPrefix("- [-] Bien. #réussite @claude\n"))
    }

    func testLinesWrittenByHandAreNotes() {
        let notes = NoteMarkdown.decode("# Idées\n\n- [ ] Une tâche\n- [X] Faite\n- [-] Laissée\n- [ ] Une question #question\n\nPlus loin, du texte.\n")
        XCTAssertEqual(notes.map(\.status), [.open, .open, .done, .resolved, .open, .open])
        XCTAssertEqual(notes.map(\.kind), [.text, .todo, .todo, .todo, .question, .text])
        XCTAssertEqual(notes[4].body, "Une question")
        // The same line keeps its id from one reading to the next: what merging needs.
        XCTAssertEqual(NoteMarkdown.decode("- [ ] Une tâche\n").first?.id, NoteMarkdown.decode("- [x] Une tâche\n").first?.id)
    }

    func testMigrationLosesNothingAndKeepsTheOldFilesIfUnreadable() throws {
        let root = try temp()
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let notes = [
            Note(author: .claude, kind: .praise, body: "Bien.", status: .resolved, created: date, updated: date, anchor: anchor),
            Note(author: .me, kind: .todo, body: "Tâche marge", status: .resolved, created: date, updated: date, anchor: anchor),
        ]
        try enc.encode(notes).write(to: root.appendingPathComponent(".musset/notes/01.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset/notepad"), withIntermediateDirectories: true)
        try "- [x] Développer Clara\n@todo Relire\n\nIdées en vrac.\n".write(to: Notepad.url(root, chapter: "01"), atomically: true, encoding: .utf8)
        try "- [ ] Tout le livre\n".write(to: Notepad.url(root, chapter: nil), atomically: true, encoding: .utf8)
        try "pas du json".write(to: root.appendingPathComponent(".musset/notes/02.json"), atomically: true, encoding: .utf8)

        XCTAssertTrue(NoteStore.migrate(root: root, chapters: ["01", "02"]))
        let out = NoteStore.read(NoteStore.url(root, "01"))
        XCTAssertEqual(out.map(\.body), ["Bien.", "Tâche marge", "Développer Clara", "Relire", "Idées en vrac."])
        XCTAssertEqual(out[0].status, .resolved, "a resolved note stays resolved")
        XCTAssertEqual(out[1].status, .done, "a resolved task was done")
        XCTAssertEqual(out[2].status, .done)
        XCTAssertEqual(out[0].id, notes[0].id)
        XCTAssertEqual(NoteStore.read(NoteStore.url(root, NoteStore.bookPage)).map(\.body), ["Tout le livre"])
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent(".musset/notes/01.json").path))
        XCTAssertFalse(fm.fileExists(atPath: Notepad.url(root, chapter: "01").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent(".musset/notes/02.json").path), "what doesn't read isn't touched")
        XCTAssertFalse(NoteStore.migrate(root: root, chapters: ["01"]), "once")
    }

    func testTickingWritesTheFileAtOnceAndFreeTextHasNoPassage() throws {
        let root = try temp()
        try "# Un\n\nDu texte ici.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let s = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")]))
        let task = s.notes.addPlain("Relire", kind: .todo, in: "01")
        s.notes.addPlain("Une idée", kind: .text, in: "01")
        s.notes.resolveAll(in: s.text)
        XCTAssertFalse(s.notes.notes.contains(where: \.orphaned), "no passage is not a lost passage")
        s.notes.change(task.id, in: "01") { $0.status = .done }
        XCTAssertEqual(try String(contentsOf: NoteStore.url(root, "01"), encoding: .utf8), "- [x] Relire\n\nUne idée\n")
        s.notes.change(task.id, in: "01") { $0.status = .open }
        XCTAssertTrue(try String(contentsOf: NoteStore.url(root, "01"), encoding: .utf8).hasPrefix("- [ ] Relire"), "and it unticks")
        // Delete, then undo: back in its place.
        let i = try XCTUnwrap(s.notes.remove(task.id, in: "01"))
        XCTAssertEqual(s.notes.notes.map(\.body), ["Une idée"])
        s.notes.restore(task, in: "01", at: i)
        XCTAssertEqual(s.notes.notes.map(\.body), ["Relire", "Une idée"])
    }
}

/// On a copy of a real book: MUSSET_CONATUS_COPY=<dir>. Nothing is lost, and the history reads fast enough.
@MainActor
final class RealBookMigrationTests: XCTestCase {
    func testRealBookMigration() throws {
        guard let path = ProcessInfo.processInfo.environment["MUSSET_CONATUS_COPY"] else { throw XCTSkip("no copy given") }
        let root = URL(fileURLWithPath: path)
        let dir = root.appendingPathComponent(".musset/notes")
        var before: [String: [Note]] = [:]
        for f in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where f.pathExtension == "json" {
            before[f.deletingPathExtension().lastPathComponent] = NoteStore.readJSON(try Data(contentsOf: f))
        }
        let total = before.values.reduce(0) { $0 + $1.count }
        let manifest = try BookStore(root: root).loadManifest()
        let head = GitService(root: root).resolve("HEAD")
        let s = BookSession(root: root, manifest: manifest)
        XCTAssertNotEqual(s.git.resolve("HEAD"), head, "one commit")
        var checked = 0
        for (id, old) in before {
            let new = Dictionary(uniqueKeysWithValues: NoteStore.read(NoteStore.url(root, id)).map { ($0.id, $0) })
            for var n in old {
                if n.kind == .todo, n.status == .resolved { n.status = .done }
                guard let m = new[n.id] else { XCTFail("lost \(n.id)"); continue }
                XCTAssertEqual(m.body, n.body); XCTAssertEqual(m.anchor, n.anchor); XCTAssertEqual(m.kind, n.kind)
                XCTAssertEqual(m.status, n.status); XCTAssertEqual(m.author, n.author); XCTAssertEqual(m.replies.map(\.body), n.replies.map(\.body))
                XCTAssertEqual(m.run, n.run); XCTAssertEqual(m.orphaned, n.orphaned)
                XCTAssertEqual(m.created.timeIntervalSince1970, n.created.timeIntervalSince1970, accuracy: 1)
                checked += 1
            }
        }
        print("MIGRATED \(checked)/\(total) notes in \(before.count) chapters, todos \(s.collectTodos().count)")
        XCTAssertEqual(checked, total)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }, [])

        var t = Date()
        var logs: [String: [GitService.Commit]] = [:]
        for ch in manifest.chapters { logs[ch.id] = s.historyReader.log(ch.file) }
        let sittings = HistoryReader.sittings(logs)
        print("LOGS \(Date().timeIntervalSince(t))s, \(logs.values.reduce(0) { $0 + $1.count }) commits, \(sittings.count) sittings")
        t = Date()
        let ch = manifest.chapters.first { $0.id == "24_lavilleneuve_au_roi" } ?? manifest.chapters[manifest.chapters.count / 2]
        var n = 0
        for st in sittings where st.chapters.contains(ch.id) { n += s.historyReader.changes(in: st, file: ch.file, log: logs[ch.id] ?? []).count }
        print("CHANGES \(Date().timeIntervalSince(t))s, \(n) changes in \(ch.id)")
        t = Date()
        var found = 0
        for c in manifest.chapters { found += s.historyReader.phrase("le froid", chapter: c.id, file: c.file).count }
        print("SEARCH whole book \(Date().timeIntervalSince(t))s, \(found) events")
    }
}
