import SwiftUI
import XCTest
@testable import Musset

/// Home and the Musset account as one place: the library and the account's books in one list, the numbers of
/// the account's column, and the old ways into the account sheet, which now lead to Home. No server anywhere.
@MainActor
final class HomeAccountTests: XCTestCase {
    private let server = "https://books.example.test"

    private func card(_ title: String, remotes: [String] = []) -> BookCard {
        BookCard(path: "/books/" + title, manifest: BookManifest(title: title, chapters: []), counts: .zero, todos: 0,
                 touched: .distantPast, lastSentence: "", lastChapter: nil, remotes: remotes)
    }

    private func repo(_ id: Int, _ owner: String, _ name: String, title: String? = nil) -> Collab.Repo {
        Collab.Repo(id: id, name: name, full_name: "\(owner)/\(name)", clone_url: "\(server)/\(owner)/\(name).git",
                    owner: .init(login: owner), description: title)
    }

    private func account(_ online: [Collab.Repo], circle: Int = 0, unread: Int = 0) -> HomeAccount {
        HomeAccount(signedIn: true, username: "camille", name: "Camille Durand", writer: true, online: online, circle: circle, unread: unread)
    }

    // MARK: One list

    func testSignedOutEveryBookIsJustABook() {
        let lib = HomeLibrary(cards: [card("Le sel", remotes: ["\(server)/camille/le-sel.git"]), card("Brouillon")], account: HomeAccount(), server: server)
        XCTAssertEqual(lib.books.map(\.online), [.unknown, .unknown], "no account: the card says nothing of it")
        XCTAssertTrue(lib.shared.isEmpty)
        XCTAssertTrue(lib.onlineOnly.isEmpty)
    }

    func testLocalAndOnlineBooksMergeIntoOneList() {
        let online = [repo(1, "camille", "le-sel", title: "Le sel"), repo(2, "camille", "les-marais", title: "Les marais"),
                      repo(3, "ines", "nord", title: "Nord"), repo(4, "tom", "la-digue", title: "La digue"),
                      repo(5, "camille", "avant", title: "Avant")]
        let cards = [card("Le sel", remotes: ["\(server)/camille/le-sel.git"]), card("Brouillon"),
                     card("Nord", remotes: ["https://elsewhere.example.test/x.git", "\(server)/ines/nord.git"])]
        let lib = HomeLibrary(cards: cards, account: account(online), server: server)

        XCTAssertEqual(lib.books.map(\.title), ["Le sel", "Brouillon", "Nord", "Avant", "Les marais"], "this Mac's books first, then mine only online, by title")
        XCTAssertEqual(lib.books.map(\.online), [.synced, .localOnly, .shared(by: "ines"), .onlineOnly, .onlineOnly])
        XCTAssertEqual(lib.books[0].repo?.id, 1, "the folder and its repository are one book")
        XCTAssertNil(lib.books[1].repo)
        XCTAssertNil(lib.books[3].card)
        XCTAssertEqual(lib.onlineOnly.map(\.title), ["Avant", "Les marais"])
        XCTAssertEqual(Set(lib.books.map(\.id)).count, lib.books.count)

        // Someone else's books are the short list: the one on this Mac opens, the other downloads.
        XCTAssertEqual(lib.shared.map(\.title), ["Nord", "La digue"])
        XCTAssertEqual(lib.shared.map(\.owner), ["ines", "tom"])
        XCTAssertEqual(lib.shared[0].path, "/books/Nord")
        XCTAssertNil(lib.shared[1].path)
        XCTAssertFalse(lib.books.contains { $0.repo?.id == 4 }, "a shared book not on this Mac is not one of mine")
    }

    func testARemoteIsTheSameWithOrWithoutItsSuffix() {
        let lib = HomeLibrary(cards: [card("Le sel", remotes: ["\(server)/camille/le-sel"])], account: account([repo(1, "camille", "le-sel")]), server: server)
        XCTAssertEqual(lib.books.map(\.online), [.synced])
        XCTAssertEqual(lib.books.count, 1, "not once here and once online")
        XCTAssertEqual(lib.books[0].title, "Le sel", "the folder's title, not the repository's slug")
    }

    func testOfflineARemoteOnTheServerStillTells() {
        // The account's list could not be asked: what the folders say is enough for those on this Mac.
        let cards = [card("Le sel", remotes: ["\(server)/camille/le-sel.git"]), card("Nord", remotes: ["\(server)/ines/nord.git"]),
                     card("Ailleurs", remotes: ["https://elsewhere.example.test/camille/ailleurs.git"])]
        let lib = HomeLibrary(cards: cards, account: account([]), server: server)
        XCTAssertEqual(lib.books.map(\.online), [.synced, .shared(by: "ines"), .localOnly])
        XCTAssertEqual(lib.shared.map(\.title), ["Nord"])
        XCTAssertEqual(lib.shared.first?.path, "/books/Nord")
    }

    func testARepositoryWithNoTitleShowsItsName() {
        XCTAssertEqual(repo(1, "camille", "le-sel").title, "le-sel")
        XCTAssertEqual(repo(1, "camille", "le-sel", title: "").title, "le-sel")
        XCTAssertEqual(repo(1, "camille", "le-sel", title: "Le sel").title, "Le sel")
    }

    func testTheColumnCounts() {
        let online = [repo(1, "camille", "le-sel"), repo(2, "camille", "les-marais"), repo(3, "ines", "nord")]
        let acc = account(online, circle: 5, unread: 3)
        let lib = HomeLibrary(cards: [card("Le sel", remotes: ["\(server)/camille/le-sel.git"]), card("Brouillon")], account: acc, server: server)
        XCTAssertEqual(lib.count(.books, account: acc), 3, "two here, one only online")
        XCTAssertEqual(lib.count(.shared, account: acc), 1)
        XCTAssertEqual(lib.count(.circle, account: acc), 5)
        XCTAssertEqual(lib.count(.activity, account: acc), 3, "what is unread")
        XCTAssertNil(lib.count(.notices, account: acc))
        XCTAssertNil(lib.count(.plan, account: acc))
        XCTAssertEqual(HomeSection.holdings + HomeSection.settings, HomeSection.allCases, "every section has its row")
        XCTAssertEqual(acc.initials, "CD")
    }

    // MARK: The old ways in

    private func emptyApp() -> (AppState, () -> Void) {
        let d = UserDefaults.standard
        let saved = (d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"))
        d.removeObject(forKey: "libraryPaths"); d.removeObject(forKey: "lastBook")
        return (AppState(), { d.set(saved.0, forKey: "libraryPaths"); d.set(saved.1, forKey: "lastBook") })
    }

    func testWhereTheAccountLands() {
        XCTAssertEqual(HomeSection.account(signedIn: true), .plan)
        XCTAssertEqual(HomeSection.account(signedIn: false), .books, "signed out, the form sits beside the books")
        XCTAssertEqual(HomeSection.holding(repo: "camille/le-sel", username: "camille"), .books)
        XCTAssertEqual(HomeSection.holding(repo: "ines/nord", username: "camille"), .shared)
        XCTAssertEqual(HomeSection.holding(repo: "ines/nord", username: nil), .shared)
    }

    func testTheAccountCommandOpensHome() throws {
        let (app, cleanUp) = emptyApp()
        defer { cleanUp() }
        XCTAssertFalse(app.showHome)
        try XCTUnwrap(AppCommand.byID["app.account"]).run(CommandContext(app: app, bridge: EditorBridge()))
        XCTAssertTrue(app.showHome, "the account is in Home")
        XCTAssertEqual(app.homeSection, .account(signedIn: Collab.shared.signedIn))

        // A named section, as the links do; and leaving Home goes back to the books for the next time.
        app.showAccount(.activity)
        XCTAssertEqual(app.homeSection, .activity)
        app.showHome = false
        XCTAssertEqual(app.homeSection, .books)
        try XCTUnwrap(AppCommand.byID["go.home"]).run(CommandContext(app: app, bridge: EditorBridge()))
        XCTAssertTrue(app.showHome)
        XCTAssertEqual(app.homeSection, .books, "« All Books » is the books")
    }

    func testLinksLeadToHome() throws {
        // Signed in, an invitation is accepted on the server: not something a test does.
        try XCTSkipIf(Collab.shared.signedIn, "signed in on this Mac")
        let (app, cleanUp) = emptyApp()
        defer { cleanUp() }
        app.open(mussetURL: URL(string: "musset://join/a-token")!)
        XCTAssertEqual(app.pendingInvitation, "a-token", "kept for the form in Home's column")
        XCTAssertTrue(app.showHome)
        XCTAssertEqual(app.homeSection, .books)

        // A notice about a book that is not on this Mac: Home has it to download.
        app.showHome = false
        app.open(mussetURL: URL(string: "musset://open?repo=ines/nord")!)
        XCTAssertTrue(app.showHome)
        XCTAssertEqual(app.homeSection, .shared)
    }

    // MARK: Drawn

    /// Home drawn offscreen with no book open, signed out and with an account made up here, to look at it
    /// without opening Musset. MUSSET_LIVE_SHOTS=<dir> (skipped otherwise), as `testSceneCardsShots`.
    func testHomeShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_LIVE_SHOTS"] else { throw XCTSkip("set MUSSET_LIVE_SHOTS") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let saved = (d.string(forKey: UILang.key), d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"))
        let collab = Collab.shared
        let before = (collab.activity, collab.circle)
        defer {
            d.set(saved.0, forKey: UILang.key); d.set(saved.1, forKey: "libraryPaths"); d.set(saved.2, forKey: "lastBook")
            collab.activity = before.0; collab.circle = before.1
        }
        d.set("fr", forKey: UILang.key)
        d.removeObject(forKey: "lastBook")

        let base = FileManager.default.temporaryDirectory.appendingPathComponent("home-\(UUID())")
        defer { try? FileManager.default.removeItem(at: base) }
        func book(_ title: String, chapters: Int, remote: String? = nil) throws -> String {
            let root = base.appendingPathComponent(title)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            var entries: [ChapterEntry] = []
            for i in 1...chapters {
                let id = String(format: "%02d", i)
                let text = "# Chapitre \(i)\n\n" + Array(repeating: "Nora descendit du bac la dernière, le manteau de son père plié sur le bras, et resta un moment sur la cale à regarder l’eau grise se refermer derrière le bateau.", count: 12 + i).joined(separator: "\n\n") + "\n"
                try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
                entries.append(ChapterEntry(id: id, file: "\(id).md", title: "Chapitre \(i)", status: i < 3 ? .done : .draft))
            }
            try BookStore(root: root).saveManifest(BookManifest(title: title, author: "Camille Durand", lang: "fr", chapters: entries))
            let git = GitService(root: root)
            try git.initRepo()
            // Only a line in the folder's git config: nothing is asked of that address.
            if let remote { try git.addRemote("musset", url: remote) }
            return root.standardizedFileURL.path
        }
        let paths = [try book("Le sel", chapters: 6, remote: "\(server)/camille/le-sel.git"),
                     try book("Les marais", chapters: 4, remote: "\(server)/camille/les-marais.git"),
                     try book("Carnet de la digue", chapters: 2),
                     try book("Nord", chapters: 3, remote: "\(server)/ines/nord.git")]
        d.set(paths, forKey: "libraryPaths")

        let online = [repo(1, "camille", "le-sel", title: "Le sel"), repo(2, "camille", "les-marais", title: "Les marais"),
                      repo(3, "ines", "nord", title: "Nord"), repo(4, "tom", "la-digue", title: "La digue, onze ans après"),
                      repo(5, "camille", "avant-la-maree", title: "Avant la marée")]
        let now = Int(Date().timeIntervalSince1970)
        let activity = [
            ActivityItem(id: 1, actor: "ines", actorName: "Inès Morel", kind: "note", repo: "camille/le-sel", tag: nil, thread: nil, chapter: "03",
                         title: "Le sel", message: "Pourquoi Tom ne se retourne-t-il pas ?", at: now - 1800, read: 0),
            ActivityItem(id: 2, actor: "tom", actorName: "Tom Pellan", kind: "milestone", repo: "tom/la-digue", tag: "Deuxième partie", thread: nil,
                         chapter: nil, title: "La digue, onze ans après", message: nil, at: now - 7200, read: 0),
            ActivityItem(id: 3, actor: "ines", actorName: "Inès Morel", kind: "reply", repo: "camille/les-marais", tag: nil, thread: nil, chapter: "01",
                         title: "Les marais", message: "D’accord pour la coupe.", at: now - 90000, read: 1)]
        let circle = [
            CirclePerson(id: 1, username: "ines", email: nil, name: "Inès Morel", relation: "editor", books: ["camille/le-sel", "camille/les-marais"], invited: nil),
            CirclePerson(id: 2, username: "tom", email: nil, name: "Tom Pellan", relation: "beta-reader", books: ["camille/le-sel"], invited: nil),
            CirclePerson(id: 3, username: nil, email: nil, name: "Agence du Quai", relation: "agent", books: [], invited: now - 86400)]
        let writer = HomeAccount(signedIn: true, username: "camille", name: "Camille Durand", writer: true,
                                 renews: Date(timeIntervalSince1970: 1_800_000_000), online: online, circle: circle.count, unread: 2)
        let free = HomeAccount(signedIn: true, username: "camille", name: "Camille Durand", writer: false,
                               online: online.filter { $0.owner.login != "camille" }, circle: circle.count, unread: 0)

        let app = AppState()
        XCTAssertNil(app.current, "Home with no book open")
        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false, screen: retina)
        func shot(_ name: String, dark: Bool, width: CGFloat = 1440, height: CGFloat = 900, _ account: HomeAccount, _ section: HomeSection = .books) async throws {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            app.homeSection = section
            window.setContentSize(NSSize(width: width, height: height))
            window.contentView = NSHostingView(rootView: HomeView(app: app, preview: account).tint(Ink.accent).frame(width: width, height: height))
            try await Task.sleep(for: .seconds(1.5))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }
        try await shot("home-1-signed-out-dark.png", dark: true, HomeAccount())
        try await shot("home-1-signed-out-light.png", dark: false, HomeAccount())
        collab.activity = activity; collab.circle = circle
        try await shot("home-2-writer-books-dark.png", dark: true, writer)
        try await shot("home-2-writer-books-light.png", dark: false, writer)
        try await shot("home-2-writer-books-narrow.png", dark: true, width: 1000, height: 1500, writer)
        try await shot("home-3-shared-dark.png", dark: true, writer, .shared)
        try await shot("home-4-circle-dark.png", dark: true, writer, .circle)
        try await shot("home-5-activity-light.png", dark: false, writer, .activity)
        try await shot("home-6-notifications-dark.png", dark: true, writer, .notices)
        try await shot("home-7-plan-dark.png", dark: true, writer, .plan)
        collab.activity = []
        try await shot("home-8-free-books-dark.png", dark: true, free)
        try await shot("home-9-free-plan-light.png", dark: false, free, .plan)
    }
}
