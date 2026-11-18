import XCTest
@testable import Musset

/// Writer and free accounts, roles, the Sync price, and conversations rebuilt from everyone's files.
@MainActor
final class CircleTests: XCTestCase {
    func testRolesRoundTripWithTheServer() {
        for role in Collab.Role.allCases { XCTAssertEqual(Collab.Role(serverName: role.serverName), role) }
        XCTAssertEqual(Collab.Role.collaborator.serverName, "writer", "the server calls a co-writer a writer")
        XCTAssertTrue(Collab.Role.reader.reviews)
        XCTAssertTrue(Collab.Role.editor.reviews)
        XCTAssertFalse(Collab.Role.collaborator.reviews, "a co-writer writes in the main text")
        XCTAssertNil(Collab.Role(serverName: "owner"))
    }

    func testAFreeAccountCannotSync() {
        let collab = Collab.shared
        let saved = collab.account
        defer { collab.account = saved }
        collab.account = AccountInfo(username: "a", name: "", email: "", plan: "free", status: nil, until: nil, comp: false, mail: "digest", lang: nil)
        XCTAssertFalse(collab.account!.isWriter)
        collab.account = AccountInfo(username: "a", name: "", email: "", plan: "writer", status: "active", until: 1_800_000_000, comp: false, mail: "digest", lang: nil)
        XCTAssertTrue(collab.account!.isWriter)
        XCTAssertEqual(collab.account!.renews, Date(timeIntervalSince1970: 1_800_000_000))
        if !collab.signedIn { XCTAssertFalse(collab.canSync, "signed out: never") }
    }

    func testAccountDecodesTheServersReply() throws {
        let json = #"{"username":"claire","name":"Claire Duval","email":"c@x.test","plan":"free","status":null,"until":null,"comp":false,"mail":"digest","lang":"fr"}"#
        let info = try JSONDecoder().decode(AccountInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.name, "Claire Duval")
        XCTAssertFalse(info.isWriter)
        let person = #"{"id":3,"username":null,"email":"rights@pub.test","name":"rights@pub.test","relation":"publisher","books":[],"invited":1700000000}"#
        let p = try JSONDecoder().decode(CirclePerson.self, from: Data(person.utf8))
        XCTAssertTrue(p.isPending)
        XCTAssertEqual(Relation(rawValue: p.relation), .publisher)
        XCTAssertEqual(Relation(rawValue: "beta-reader"), .betaReader)
    }

    func testThePriceFollowsTheCurrency() {
        XCTAssertTrue(["EUR", "USD"].contains(SyncPrice.currency))
        XCTAssertTrue(SyncPrice.label.contains("4"), SyncPrice.label)
        XCTAssertTrue(SyncPrice.label.contains("99"), SyncPrice.label)
    }

    func testEachPersonKeepsOneColour() {
        XCTAssertEqual(Person.color("claire"), Person.color("claire"))
        let colours = Set(["claire", "tom", "ines", "jun", "dana", "ruth"].map { Person.palette.firstIndex(of: Person.color($0)) ?? -1 })
        XCTAssertGreaterThan(colours.count, 1, "not everyone in one colour")
    }

    // MARK: Conversations

    private func note(_ by: String, at t: TimeInterval, chapter: String = "c1", start: Int = 10) -> TalkEntry {
        let id = UUID()
        return TalkEntry(id: id, thread: id, kind: .note, by: by, at: Date(timeIntervalSince1970: t), body: "Why Tom Pellow?", chapter: chapter,
                         anchor: NoteAnchor(quote: "Tom Pellow’s cart", prefix: "It was ", suffix: " that came", start: start, version: nil), mark: .highlight, color: 0)
    }

    func testAThreadIsRebuiltFromEveryonesFiles() {
        let n = note("claire", at: 100)
        let mine = [TalkEntry(thread: n.id, kind: .reply, by: "mara", at: Date(timeIntervalSince1970: 200), body: "He is the boy with the barrow.", chapter: "c1")]
        let theirs = [n, TalkEntry(thread: n.id, kind: .reply, by: "claire", at: Date(timeIntervalSince1970: 300), body: "Then name him there.", chapter: "c1")]
        let threads = Talk.threads(from: mine + theirs)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].replies.map(\.by), ["mara", "claire"], "by date, whoever's file they came from")
        XCTAssertTrue(threads[0].waits(for: "mara", owner: "mara"), "the editor spoke last: the author's turn")
        XCTAssertFalse(threads[0].waits(for: "claire", owner: "mara"))
        XCTAssertFalse(threads[0].waits(for: "tom", owner: "mara"), "a reader not in the thread isn't waited for")
    }

    func testResolveAndReopen() {
        let n = note("tom", at: 100)
        var entries = [n, TalkEntry(thread: n.id, kind: .resolve, by: "mara", at: Date(timeIntervalSince1970: 150), chapter: "c1")]
        var t = Talk.threads(from: entries)[0]
        XCTAssertEqual(t.resolvedBy, "mara")
        XCTAssertFalse(t.waits(for: "mara", owner: "mara"), "resolved waits for no one")
        entries.append(TalkEntry(thread: n.id, kind: .reopen, by: "tom", at: Date(timeIntervalSince1970: 160), chapter: "c1"))
        t = Talk.threads(from: entries)[0]
        XCTAssertNil(t.resolvedBy)
        XCTAssertTrue(t.waits(for: "mara", owner: "mara"))
    }

    func testRepliesWithoutTheirNoteAreDropped() {
        let orphan = TalkEntry(thread: UUID(), kind: .reply, by: "tom", body: "?", chapter: "c1")
        XCTAssertTrue(Talk.threads(from: [orphan]).isEmpty, "until the note's file arrives")
    }

    func testThreadsFollowTheText() {
        let a = note("claire", at: 300, start: 50), b = note("tom", at: 100, start: 10), c = note("claire", at: 50, chapter: "c2", start: 0)
        XCTAssertEqual(Talk.threads(from: [a, b, c]).map(\.id), [b.id, a.id, c.id], "by chapter, then by place in the text")
    }

    func testEntriesSurviveTheirFile() throws {
        let n = note("claire", at: 100)
        let back = Talk.decode(Talk.encode([n]))
        XCTAssertEqual(back, [n])
        XCTAssertEqual(Talk.path("claire", "c1"), ".musset/talk/claire/c1.json")
        XCTAssertTrue(Talk.decode(Data("not json".utf8)).isEmpty)
    }

    func testMyEntriesAreWrittenToMyFileOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("talk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitService(root: root)
        try git.initRepo()
        let store = TalkStore(root: root)
        store.load(me: "claire", owner: "mara", remote: nil, chapters: ["c1"], git: git)
        let n = note("claire", at: 100)
        XCTAssertEqual(store.add(n), ".musset/talk/claire/c1.json")
        XCTAssertEqual(store.threads.count, 1)
        let reread = TalkStore(root: root)
        reread.load(me: "claire", owner: "mara", remote: nil, chapters: ["c1"], git: git)
        XCTAssertEqual(reread.threads.first?.note.body, "Why Tom Pellow?")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".musset/talk/mara").path), "never the author's file")
    }

    func testActivitySentences() throws {
        let json = #"{"id":1,"actor":"mara","actorName":"M. A. Fenwick","kind":"milestone","repo":"mara/salt-road","tag":"Draft 2","thread":null,"chapter":null,"title":"The Salt Road","message":"Chapter three rewritten.","at":1700000000,"read":0}"#
        let item = try JSONDecoder().decode(ActivityItem.self, from: Data(json.utf8))
        XCTAssertTrue(item.isUnread)
        XCTAssertTrue(item.sentence.contains("M. A. Fenwick") && item.sentence.contains("Draft 2") && item.sentence.contains("The Salt Road"), item.sentence)
    }

    /// Against a local Forgejo only (`TEST_RUNNER_MUSSET_SERVER`, `TEST_RUNNER_MUSSET_AUTHOR`): an editor's note written on
    /// their own branch (as Musset Reader does) reaches the author's Mac as a conversation.
    func testAnEditorsNoteReachesTheAuthor() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["MUSSET_SERVER"], server.contains("localhost"), let author = env["MUSSET_AUTHOR"] else {
            throw XCTSkip("needs a local Forgejo with a shared book")
        }
        let parts = author.split(separator: ":", maxSplits: 2).map(String.init)   // user:password:owner/repo
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("talk-live-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let creds = GitService.Credentials(user: parts[0], token: parts[1])
        try GitService.clone("\(server)/\(parts[2]).git", to: dir, credentials: creds)
        let git = GitService(root: dir)
        try git.fetch("origin", credentials: creds)
        let store = TalkStore(root: dir)
        store.load(me: parts[0], owner: parts[0], remote: "origin", chapters: ["03_the_ford"], git: git)
        let thread = try XCTUnwrap(store.threads.first)
        XCTAssertEqual(thread.starter, "claire")
        XCTAssertTrue(thread.waits(for: parts[0], owner: parts[0]), "the author's turn")
        let chapter = String(decoding: try Data(contentsOf: dir.appendingPathComponent("03_the_ford.md")), as: UTF8.self)
        XCTAssertEqual(thread.note.anchor.flatMap { Anchoring.resolve($0, in: chapter) }?.length, "Tom Pellow’s cart".utf16.count, "placed on its passage")
    }
}
