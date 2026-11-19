import XCTest
import SwiftUI
@testable import Musset

/// The Readers page of a book's home: which of its faces a book and an account call for, the role a circle's
/// person gets in one click, and the invitations this Mac remembers.
@MainActor
final class ReadersTests: XCTestCase {
    func testThreeCasesForTheAuthor() {
        // Not subscribed, whether signed in or not: why Musset Sync.
        XCTAssertEqual(ReadersPage.which(signedIn: false, canSync: false, linked: false, owner: false), .offer)
        XCTAssertEqual(ReadersPage.which(signedIn: true, canSync: false, linked: false, owner: false), .offer)
        // Subscribed, the book on this Mac only: it has to be sent first.
        XCTAssertEqual(ReadersPage.which(signedIn: true, canSync: true, linked: false, owner: false), .notSynced)
        // On the account: its readers and the invitation.
        XCTAssertEqual(ReadersPage.which(signedIn: true, canSync: true, linked: true, owner: true), .shared)
    }

    func testSomeoneElsesBookIsReadWhateverTheAccount() {
        // A free account reads the books shared with it: never the offer on a book that isn't theirs.
        XCTAssertEqual(ReadersPage.which(signedIn: true, canSync: false, linked: true, owner: false), .reader)
        XCTAssertEqual(ReadersPage.which(signedIn: true, canSync: true, linked: true, owner: false), .reader)
    }

    func testTheRoleThatGoesWithWhoTheyAre() {
        XCTAssertEqual(ReadersPage.role(for: .betaReader), .reader)
        XCTAssertEqual(ReadersPage.role(for: .agent), .reader)
        XCTAssertEqual(ReadersPage.role(for: .editor), .editor)
        XCTAssertEqual(ReadersPage.role(for: .publisher), .editor)
        XCTAssertEqual(ReadersPage.role(for: .author), .collaborator)
    }

    func testInvitationsAreRememberedPerBookAndOnce() {
        let repo = "tests/\(UUID().uuidString)"
        let collab = Collab.shared
        XCTAssertTrue(collab.invited(to: repo).isEmpty)
        collab.remember(invited: "Lea@Example.com", to: repo)
        collab.remember(invited: "lea@example.com", to: repo)
        XCTAssertEqual(collab.invited(to: repo), ["lea@example.com"], "one entry, whatever the capitals")
        XCTAssertTrue(collab.invited(to: "tests/another").isEmpty)
        // Nobody of that address waits in the circle: the invitation is settled and forgotten.
        collab.settleInvited(to: repo)
        XCTAssertTrue(collab.invited(to: repo).isEmpty)
    }

    /// A book with its history: one chapter, committed.
    private func bookWithHistory(_ text: String = "One two three.\n\nFour five.\n") throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-milestones-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try text.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let git = GitService(root: root)
        try git.initRepo()
        try git.commit(paths: ["01.md"], message: "first")
        let s = BookSession(root: root, manifest: BookManifest(title: "The Salt Road", lang: "en", chapters: [ChapterEntry(id: "01", file: "01.md", title: "The Ferry")]))
        s.open("01")
        return s
    }

    func testAMilestoneKeepsTheBookWhileTheDeskMovesOn() throws {
        let s = try bookWithHistory()
        defer { try? FileManager.default.removeItem(at: s.root) }
        XCTAssertTrue(s.milestones.isEmpty)
        let tag = try XCTUnwrap(s.addJalon(title: "First draft", note: "The ending is new."))
        XCTAssertTrue(tag.hasPrefix("jalon/"), "its name is what a reader is given: \(tag)")
        let first = try XCTUnwrap(s.milestones.first)
        XCTAssertEqual([first.id, first.title, first.note], [tag, "First draft", "The ending is new."])

        // Nothing written since: nothing a reader has not seen.
        var since = s.changeSince(first)
        XCTAssertEqual(since.added + since.removed, 0)
        XCTAssertTrue(since.chapters.isEmpty)

        // The author writes on: the milestone does not move, and the desk says how far it has gone.
        s.textDidChange("One two three.\nFour five. Six seven.\n")
        s.flushSave()
        s.commitNow("musset: edit 01")
        since = s.changeSince(first)
        XCTAssertEqual(since.added, 2, "Six, seven")
        XCTAssertEqual(since.removed, 0)
        XCTAssertEqual(since.chapters, ["The Ferry"])
        XCTAssertEqual(s.git.show(first.commit, path: "01.md"), "One two three.\n\nFour five.\n", "what a reader given this milestone reads")
    }

    func testTheNewestMilestoneComesFirst() throws {
        let s = try bookWithHistory()
        defer { try? FileManager.default.removeItem(at: s.root) }
        s.addJalon(title: "First draft", note: "")
        s.textDidChange("One two three.\nFour.\n")
        s.flushSave()
        s.commitNow("musset: edit 01")
        // Tags are dated to the second: the second one a little later.
        Thread.sleep(forTimeInterval: 1.1)
        s.addJalon(title: "Second draft", note: "")
        XCTAssertEqual(s.milestones.map(\.title), ["Second draft", "First draft"])
    }

    func testAReadersCopyStartsFromTheAuthorsTextWhenNothingWasGiven() async throws {
        // Signed out, or a book that is on no account: no milestone can have been given, so nothing is assumed.
        let s = try bookWithHistory()
        defer { try? FileManager.default.removeItem(at: s.root) }
        let start = await Collab.shared.readingStart(s.git, remote: "origin")
        XCTAssertEqual(start.ref, "origin/main")
        XCTAssertNil(start.tag)
        // This Mac remembers the milestone a copy was set on, book by book.
        XCTAssertNil(Collab.shared.adopted(for: s.git))
        Collab.shared.setAdopted("jalon/first-draft", for: s.git)
        XCTAssertEqual(Collab.shared.adopted(for: s.git), "jalon/first-draft")
        Collab.shared.setAdopted(nil, for: s.git)
        XCTAssertNil(Collab.shared.adopted(for: s.git))
    }

    func testSettingsAndReadersArePagesOfTheBookHome() {
        XCTAssertEqual(OverviewTab.about, [.milestones, .readers, .settings])
        XCTAssertEqual(OverviewTab.planning + OverviewTab.about, OverviewTab.allCases)
        XCTAssertFalse(BookSettingsView.Section.allCases.map(\.rawValue).contains("sharing"), "sharing left the settings for Readers")
        XCTAssertEqual(OverviewTab(rawValue: "readers"), .readers)
    }

    /// Pictures of the page's faces and of the invitation, on request: MUSSET_SNAPSHOT=<folder>.
    func testAReaderIsGivenAPartOfTheBook() {
        let chapters = [ChapterEntry(id: "01", file: "01.md", title: "One", status: .final), ChapterEntry(id: "02", file: "02.md", title: "Two", status: .edited),
                        ChapterEntry(id: "03", file: "03.md", title: "Three", status: .done), ChapterEntry(id: "04", file: "04.md", title: "Four")]
        func given(_ scope: ReadingScope?) -> [String] { chapters.filter { scope.allows($0) }.map(\.id) }
        // The whole book is no scope at all.
        XCTAssertNil(PartPicker.scope(.book, [.final], ["02"], chapters: chapters))
        XCTAssertEqual(given(nil), ["01", "02", "03", "04"])
        // By status: a chapter without one is a draft.
        let byStatus = PartPicker.scope(.status, [.final, .edited], [], chapters: chapters)
        XCTAssertEqual(byStatus?.statuses, ["edited", "final"], "in the order of the statuses")
        XCTAssertEqual(given(byStatus), ["01", "02"])
        XCTAssertEqual(given(.statuses([.draft])), ["04"])
        // Chosen one by one, kept in the book's order; a chapter that is gone is dropped.
        let chosen = PartPicker.scope(.pick, [], ["03", "01", "99"], chapters: chapters)
        XCTAssertEqual(chosen?.chapters, ["01", "03"])
        XCTAssertEqual(given(chosen), ["01", "03"])
        XCTAssertEqual(given(.chapters([])), [], "nothing chosen is nothing to read, not the whole book")
        // What the server is sent, and what the sheet shows when it opens again.
        XCTAssertEqual(byStatus?.body["statuses"] as? [String], ["edited", "final"])
        XCTAssertEqual(chosen?.body["chapters"] as? [String], ["01", "03"])
        XCTAssertEqual(PartPicker.values(of: chosen).mode, .pick)
        XCTAssertEqual(PartPicker.values(of: chosen).picked, ["01", "03"])
        XCTAssertEqual(PartPicker.values(of: byStatus).statuses, [.edited, .final])
        XCTAssertEqual(PartPicker.values(of: nil).mode, .book)
        // As the server answers.
        let decoded = try? JSONDecoder().decode(Collab.Reading.self, from: Data(#"{"tag":"jalon/a","at":1,"scope":{"statuses":["final"]}}"#.utf8))
        XCTAssertEqual(decoded?.scope, .statuses([.final]))
        XCTAssertNil((try? JSONDecoder().decode(Collab.Reading.self, from: Data(#"{"tag":"jalon/a","at":1,"scope":null}"#.utf8)))?.scope)
        XCTAssertNil((try? JSONDecoder().decode(Collab.Reading.self, from: Data(#"{"tag":"jalon/a","at":1}"#.utf8)))?.scope, "an older server")
    }

    func testStatusesAreThoseOfTheMilestoneGiven() throws {
        let s = try bookWithHistory()
        defer { try? FileManager.default.removeItem(at: s.root) }
        s.saveManifest()
        s.commitNow("musset: new book")
        let tag = try XCTUnwrap(s.addJalon(title: "First draft", note: ""))
        // Marked final after the milestone: the reader's app reads the milestone, where it was still a draft.
        s.setStatus("01", .final)
        s.commitNow("musset: status")
        XCTAssertEqual(PartPicker.chapters(of: s, in: tag).map { $0.status ?? .draft }, [.draft])
        XCTAssertEqual(PartPicker.chapters(of: s, in: nil).map { $0.status ?? .draft }, [.final], "with no milestone yet, the book as it is")
    }

    func testAReadersCopyKeepsThePartItWasGiven() throws {
        let s = try bookWithHistory()
        defer { try? FileManager.default.removeItem(at: s.root); Collab.shared.setPart(nil, for: s.git) }
        XCTAssertNil(Collab.shared.part(for: s.git))
        Collab.shared.setPart(.chapters(["01"]), for: s.git)
        XCTAssertEqual(Collab.shared.part(for: s.git), .chapters(["01"]))
        Collab.shared.setPart(nil, for: s.git)
        XCTAssertNil(Collab.shared.part(for: s.git), "the whole book again")
    }

    func testPictures() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT to a folder") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-readers-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "# The Ferry\n\nThe ferry left at six.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let s = BookSession(root: root, manifest: BookManifest(title: "The Salt Road", author: "[AUTHOR]", lang: "en",
                                                                chapters: [ChapterEntry(id: "01", file: "01.md", title: "The Ferry")]))
        let app = AppState()
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        for lang in [UILang.en, .fr] {
            UserDefaults.standard.set(lang.rawValue, forKey: UILang.key)
            func png(_ view: some View, _ size: NSSize, _ name: String) throws {
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .textBackgroundColor)).environment(\.colorScheme, .light))
                host.appearance = NSAppearance(named: .aqua)
                host.frame = NSRect(origin: .zero, size: size)
                let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = host
                RunLoop.main.run(until: Date().addingTimeInterval(0.5))
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name)-\(lang.rawValue).png"))
            }
            try png(ReadersPage(app: app, session: s, forced: .offer), NSSize(width: 1000, height: 620), "readers-1-offer")
            try png(ReadersPage(app: app, session: s, forced: .notSynced), NSSize(width: 1000, height: 520), "readers-2-not-synced")
            try png(ReadersPage(app: app, session: s, forced: .shared), NSSize(width: 1000, height: 520), "readers-3-shared-empty")
            try png(InviteSheet(session: s, suggestions: []) { _ in }, NSSize(width: 600, height: 560), "readers-4-invite")
            try png(BookSettingsView(app: app, session: s), NSSize(width: 1000, height: 560), "readers-5-settings")
            let h = try bookWithHistory()
            h.addJalon(title: "First draft", note: "")
            h.textDidChange("One two three.\nFour five six seven eight.\n"); h.flushSave(); h.commitNow("musset: edit 01")
            Thread.sleep(forTimeInterval: 1.1)
            let second = h.addJalon(title: "Second draft", note: "The harbour scene moved to the end.") ?? ""
            h.textDidChange("One two.\nFour five six seven eight nine ten.\n"); h.flushSave(); h.commitNow("musset: edit 01")
            try png(MilestonesPage(app: app, session: h, sample: [second: ["Claire Morel"]]), NSSize(width: 1000, height: 640), "readers-6-milestones")
            try png(JalonSheet(session: h, start: TrackStart()), NSSize(width: 520, height: 520), "readers-7-set-milestone")
            try png(InviteSheet(session: h, suggestions: []) { _ in }, NSSize(width: 600, height: 640), "readers-8-invite-milestone")
            try? FileManager.default.removeItem(at: h.root)
            // A book of several chapters at different statuses, to choose a part of.
            let many = try bookWithHistory()
            let titles = ["The Ferry", "The Salt Works", "Inventory", "Low Water", "The Blue Boat"]
            many.manifest.chapters = titles.enumerated().map { i, t in
                ChapterEntry(id: "0\(i + 1)", file: "0\(i + 1).md", title: t, status: [.final, .final, .edited, .done, nil][i])
            }
            many.saveManifest()
            many.commitNow("musset: chapters")
            let draft = many.addJalon(title: "Second draft", note: "") ?? ""
            try png(PartSheet(session: many, name: "Claire Morel", milestone: draft, current: .statuses([.edited, .final])) { _ in }, NSSize(width: 520, height: 300), "readers-9-part-status")
            try png(PartSheet(session: many, name: "Claire Morel", milestone: draft, current: .chapters(["01", "02"])) { _ in }, NSSize(width: 520, height: 420), "readers-10-part-chosen")
            try? FileManager.default.removeItem(at: many.root)
        }
    }
}
