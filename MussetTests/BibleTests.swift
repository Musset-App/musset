import XCTest
@testable import Musset

@MainActor
final class BibleTests: XCTestCase {
    private func tempBook() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-bible-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testEntryRoundTrips() {
        var e = BibleEntry(path: "personnages/marguerite.md", kind: .character, title: "Marguerite", aliases: ["Margot", "la petite"])
        e.fields = [.init(name: "Née", value: "1951, à Sète")]
        e.body = "Ne pleure jamais devant @[Paul].\n"
        let back = BibleEntry.parse(path: e.path, text: e.serialized)
        XCTAssertEqual(back.kind, .character)
        XCTAssertEqual(back.title, "Marguerite")
        XCTAssertEqual(back.aliases, ["Margot", "la petite"])
        XCTAssertEqual(back.fields, e.fields)
        XCTAssertEqual(back.body, e.body)
        XCTAssertEqual(BibleEntry.parse(path: back.path, text: back.serialized).serialized, back.serialized)
    }

    func testTextWithoutHeaderIsANote() {
        let e = BibleEntry.parse(path: "a-trier/idee.md", text: "Une idée.\n")
        XCTAssertEqual(e.kind, .note)
        XCTAssertEqual(e.title, "idee")
        XCTAssertEqual(e.body, "Une idée.\n")
    }

    func testMentionsAreWholeWordsWithTheirCase() {
        XCTAssertEqual(BibleLinks.count(["Paul", "Popol"], in: "Paul, Paulette et paul. Popol vint. L’ami de Paul."), 3)
        XCTAssertEqual(BibleLinks.count(["la petite"], in: "On disait la petite, et la petite ville."), 2)
        XCTAssertEqual(BibleLinks.count([""], in: "rien"), 0)
    }

    func testLinks() {
        XCTAssertEqual(BibleLinks.targets(in: "Voir @[Le pont] et @[Marguerite]."), ["Le pont", "Marguerite"])
        XCTAssertEqual(BibleLinks.plain("Voir @[Le pont]."), "Voir Le pont.")
    }

    func testTodoShortcuts() {
        XCTAssertEqual(TodoSyntax.normalize("@todo Vérifier\n[] Relire\nLire @todo vite\n- [ ] Déjà\nRien"),
                       "- [ ] Vérifier\n- [ ] Relire\n- [ ] Lire vite\n- [ ] Déjà\nRien")
        XCTAssertEqual(TodoSyntax.toggled("a\n- [ ] b", line: 1), "a\n- [x] b")
        XCTAssertEqual(TodoSyntax.toggled("- [x] b", line: 0), "- [ ] b")
        XCTAssertNil(TodoSyntax.toggled("texte", line: 0))
    }

    func testStoreKeepsDocumentsOutOfGitAndSidecarsOutOfTheList() throws {
        let root = try tempBook()
        let model = BibleModel(root: root)
        try model.create(title: "Marguerite", kind: .character)
        let ignore = try String(contentsOf: model.store.dir.appendingPathComponent(".gitignore"), encoding: .utf8)
        XCTAssertTrue(ignore.contains("documents/"))
        let pdf = model.store.url("documents/lettre.pdf")
        try model.store.prepare(pdf)
        try Data("x".utf8).write(to: pdf)
        try "> un passage".write(to: model.store.url("documents/lettre.pdf.md"), atomically: true, encoding: .utf8)
        model.reload()
        XCTAssertEqual(model.entries(in: "documents").map(\.title), ["lettre.pdf"])
        XCTAssertEqual(model.entry(named: "marguerite")?.kind, .character)
    }

    func testCollectAndToggleTodosAcrossSources() throws {
        let root = try tempBook()
        try "# Le pont\n\nTexte.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let s = BookSession(root: root, manifest: BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Le pont")]))
        s.notes.addPlain("Relire", kind: .todo, in: "01")
        s.notes.addPlain("Pas une tâche", kind: .text, in: "01")
        var sheet = try s.bible.create(title: "Marguerite", kind: .character)
        sheet.body = "- [ ] Vérifier son âge dans @[Le pont]\n- [x] Faite\n"
        try s.bible.save(sheet)
        let items = s.collectTodos()
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.filter { $0.chapter == "01" }.count, 2)
        let age = try XCTUnwrap(items.first { $0.text == "Vérifier son âge dans Le pont" })
        s.toggle(age)
        XCTAssertTrue(s.collectTodos().first { $0.text == age.text }?.done == true)
    }
}
