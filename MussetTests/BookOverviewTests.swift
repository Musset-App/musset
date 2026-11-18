import SwiftUI
import XCTest
@testable import Musset

/// Overview's first page: the book in numbers (each chapter a bar, the goal, the pages and the reading, the days)
/// over the board of its scenes, and the ways the bars lead to the board.
@MainActor
final class BookOverviewTests: XCTestCase {
    func testABarIsAsTallAsItsChapterIsLong() {
        XCTAssertEqual(BookNumbers.height(3000, peak: 3000, room: 124), 124)
        XCTAssertEqual(BookNumbers.height(1500, peak: 3000, room: 124), 62)
        XCTAssertEqual(BookNumbers.height(1000, peak: 3000, room: 124), 41, "whole points")
        // Too short to show, or empty: a stub that can still be seen and clicked.
        XCTAssertEqual(BookNumbers.height(12, peak: 3000, room: 124), 4)
        XCTAssertEqual(BookNumbers.height(0, peak: 3000, room: 124), 4)
        XCTAssertEqual(BookNumbers.height(0, peak: 0, room: 124), 4, "a book with nothing written")
        XCTAssertEqual(BookNumbers.height(5000, peak: 3000, room: 124), 124, "never taller than the row")
    }

    func testTheBarsFillTheirRowOnDevicePixels() {
        // Forty chapters in three parts and a prologue, in a narrow pane's row.
        let sizes = [[400], Array(repeating: 900, count: 11), (0..<14).map { $0 * 150 }, Array(repeating: 30, count: 14)]
        let l = BookNumbers.layout(sizes, width: 348, room: 124, scale: 2)
        XCTAssertEqual(l.groups.map(\.count), [1, 11, 14, 14])
        let slots = l.groups.flatMap { $0 }
        for s in slots {
            XCTAssertEqual((s.x * 2).rounded(), s.x * 2, "edges on pixels")
            XCTAssertEqual((s.width * 2).rounded(), s.width * 2)
            XCTAssertGreaterThanOrEqual(s.width, 0.5)
        }
        for (a, b) in zip(slots, slots.dropFirst()) { XCTAssertGreaterThanOrEqual(b.x, a.x + a.width, "no bar over another") }
        XCTAssertEqual(slots[0].x, 0)
        XCTAssertEqual(slots[slots.count - 1].x + slots[slots.count - 1].width, 348, accuracy: 0.5, "the row is filled, and not overflowed")
        // Parts stand apart by more than chapters do, each on its own line.
        XCTAssertEqual(l.spans.count, 4)
        for (a, b) in zip(l.spans, l.spans.dropFirst()) { XCTAssertGreaterThan(b.x - (a.x + a.width), l.gap) }
        XCTAssertEqual(l.spans[1].x, l.groups[1][0].x)
        // Heights are measured against the longest chapter of the book, not of the part.
        XCTAssertEqual(l.groups[2].last?.height, 124)
        XCTAssertEqual(l.groups[1][0].height, BookNumbers.height(900, peak: 1950, room: 124))
        XCTAssertEqual(l.groups[2][0].height, 4, "an empty chapter")
        XCTAssertEqual(l.groups[3][0].height, 4, "a tiny one")

        // A short book: the bars stop at their widest rather than fill the row with slabs.
        let few = BookNumbers.layout([[10, 20, 30]], width: 600, room: 124)
        XCTAssertEqual(few.groups[0].map(\.x), [0, 34, 68])
        XCTAssertEqual(few.groups[0][0].width, 30)
        XCTAssertEqual(few.spans[0].width, 98)
        // A wide row keeps wider gaps; sixty chapters in little room keep a hairline between them.
        XCTAssertEqual(BookNumbers.layout([Array(repeating: 1, count: 40)], width: 560, room: 124).gap, 4)
        XCTAssertEqual(BookNumbers.layout([Array(repeating: 1, count: 60)], width: 300, room: 124).gap, 1)
        // Nothing to draw.
        XCTAssertEqual(BookNumbers.layout([], width: 300, room: 124), BookNumbers.Layout())
        XCTAssertEqual(BookNumbers.layout([[1]], width: 0, room: 124), BookNumbers.Layout())
    }

    private func manifest() -> BookManifest {
        var m = BookManifest(title: "T", chapters: [ChapterEntry(id: "00", file: "00.md", title: "Avant"),
                                                   ChapterEntry(id: "01", file: "01.md", title: "Un", status: .final, part: "a"),
                                                   ChapterEntry(id: "02", file: "02.md", title: "Deux", status: .done, part: "a"),
                                                   ChapterEntry(id: "03", file: "03.md", title: "Trois", status: .done, part: "b")])
        m.parts = [BookPart(id: "a", title: ""), BookPart(id: "b", title: "La fuite")]
        return m
    }

    func testTheChaptersGroupedByPart() {
        var counts = [String: TextCounts]()
        for (id, words) in [("00", 10), ("01", 200), ("02", 300)] { var c = TextCounts(); c.words = words; counts[id] = c }
        let groups = BookNumbers.groups(manifest(), counts: counts, scenes: ["01": 3, "02": 2])
        XCTAssertEqual(groups.map { $0.part?.id }, [nil, "a", "b"])
        XCTAssertEqual(groups.map { $0.bars.map(\.id) }, [["00"], ["01", "02"], ["03"]])
        XCTAssertEqual(groups[1].bars.map(\.mark), ["2", "3"], "numbered as in the book")
        XCTAssertEqual(groups[1].counts.words, 500)
        XCTAssertEqual(groups[1].bars[0], BookNumbers.Bar(id: "01", mark: "2", title: "Un", status: .final, counts: counts["01"]!, scenes: 3))
        XCTAssertEqual(groups[2].bars[0].counts, .zero, "a chapter not counted yet")
        XCTAssertEqual(groups[0].bars[0].status, .draft, "no status is a draft")
        // A book with no parts is one group, with no name under it.
        var plain = manifest()
        plain.parts = nil
        let one = BookNumbers.groups(plain, counts: counts, scenes: [:])
        XCTAssertEqual(one.count, 1)
        XCTAssertNil(one[0].part)
        XCTAssertEqual(one[0].bars.count, 4)
        XCTAssertTrue(BookNumbers.groups(BookManifest(title: "T", chapters: []), counts: [:], scenes: [:]).isEmpty)
    }

    func testTheLegendCountsEachStatus() {
        let found = BookNumbers.statuses(manifest().chapters)
        XCTAssertEqual(found.map(\.status), [.draft, .done, .final], "in the statuses' order, those in use")
        XCTAssertEqual(found.map(\.count), [1, 2, 1])
        XCTAssertTrue(BookNumbers.statuses([]).isEmpty)
    }

    func testTheGoal() {
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        UserDefaults.standard.set(UILang.fr.rawValue, forKey: UILang.key)
        // No goal, no line.
        XCTAssertNil(BookNumbers.goal(words: 1000, goal: nil))
        XCTAssertNil(BookNumbers.goal(words: 1000, goal: 0))

        let part = try! XCTUnwrap(BookNumbers.goal(words: 60_740, goal: 80_000))
        XCTAssertEqual(part, BookNumbers.Goal(percent: 76, fraction: 0.75925, left: 19_260, over: 0))
        let line = BookNumbers.goalLine(part, goal: 80_000)
        XCTAssertTrue(line.percent.hasPrefix("76") && line.percent.hasSuffix("%"), line.percent)
        XCTAssertEqual(line.rest.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " "),
                       "de l’objectif de 80 000 mots · reste 19 260 mots")

        // Past the goal: the bar is full, the line says by how much.
        let over = try! XCTUnwrap(BookNumbers.goal(words: 89_600, goal: 80_000))
        XCTAssertEqual(over, BookNumbers.Goal(percent: 112, fraction: 1, left: 0, over: 9_600))
        XCTAssertTrue(BookNumbers.goalLine(over, goal: 80_000).rest.hasSuffix("· dépassé de 9\u{202F}600 mots"), BookNumbers.goalLine(over, goal: 80_000).rest)
        let exact = try! XCTUnwrap(BookNumbers.goal(words: 80_000, goal: 80_000))
        XCTAssertEqual(exact.percent, 100)
        XCTAssertTrue(BookNumbers.goalLine(exact, goal: 80_000).rest.hasSuffix("· atteint"))
        // Nothing written yet.
        XCTAssertEqual(BookNumbers.goal(words: 0, goal: 80_000), BookNumbers.Goal(percent: 0, fraction: 0, left: 80_000, over: 0))
    }

    func testPagesAndReadingTime() {
        XCTAssertEqual(BookNumbers.pages(words: 60_740), 243)
        XCTAssertEqual(BookNumbers.pages(words: 0), 0)
        XCTAssertEqual(BookNumbers.pages(words: 100), 0)
        XCTAssertEqual(BookNumbers.pages(words: 130), 1)
        // The pace the open chapter's own reading time is counted at.
        XCTAssertEqual(BookNumbers.readingMinutes(words: 60_740), 264)
        XCTAssertEqual(BookNumbers.readingMinutes(words: 0), 0)
        XCTAssertEqual(TextStats(String(repeating: "mot ", count: 2300)).readingMinutes, 10)
        XCTAssertEqual(TextStats("").readingMinutes, 1, "a chapter is never read in no time")
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(BookNumbers.reading(minutes: 264, locale: en), "4h 24m")
        XCTAssertEqual(BookNumbers.reading(minutes: 45, locale: en), "45m")
        XCTAssertEqual(BookNumbers.reading(minutes: 60, locale: en), "1h")
    }

    func testTheDaysWritten() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        cal.firstWeekday = 2
        func day(_ d: Int, hour: Int = 10) -> Date { cal.date(from: DateComponents(year: 2026, month: 11, day: d, hour: hour))! }
        // Sunday 15 November 2026: the week began on Monday the 9th.
        let now = day(15, hour: 18)
        XCTAssertNil(BookNumbers.days([], now: now, calendar: cal), "a book with no sitting yet")
        let days = try XCTUnwrap(BookNumbers.days([day(15), day(15, hour: 8), day(14), day(13), day(11), day(8), day(7)], now: now, calendar: cal))
        XCTAssertEqual(days.week, [false, false, true, false, true, true, true])
        XCTAssertEqual(days.written, 4)
        XCTAssertEqual(days.today, 6)
        XCTAssertEqual(days.streak, 3)
        // Not written today yet: yesterday's run still stands.
        XCTAssertEqual(BookNumbers.days([day(14), day(13)], now: now, calendar: cal)?.streak, 2)
        XCTAssertEqual(BookNumbers.days([day(12)], now: now, calendar: cal)?.streak, 0)
        // A run that began before the week.
        XCTAssertEqual(BookNumbers.days((5...15).map { day($0) }, now: now, calendar: cal)?.streak, 11)
    }

    /// A book in a temporary folder: a prologue in no part, two chapters in a first part, one in a second.
    private func book() throws -> BookSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-overview-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let m = manifest()
        for ch in m.chapters { try "# \(ch.title)\n\nUn mot.\n".write(to: root.appendingPathComponent(ch.file), atomically: true, encoding: .utf8) }
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        return BookSession(root: root, manifest: m)
    }

    func testABarLeadsToItsChapterOnTheBoard() throws {
        let s = try book()
        let w = s.workspace
        XCTAssertNil(w.scenesJump, "opened from the sidebar, the page starts at its top")
        w.foldScenes("b", true)
        s.showOnBoard("03", in: w)
        XCTAssertEqual(w.scenesChapter, "03")
        XCTAssertFalse(w.scenesFolded.contains("b"), "its part is unfolded")
        XCTAssertEqual(w.scenesLevel, .book)
        XCTAssertEqual(w.takeScenesJump(), ScenesJump(chapter: "03"), "the board is brought to it, as cards or as a list")
        XCTAssertNil(w.scenesJump)

        // A part's name under the bars: the board at that part, from its top, as cards.
        s.showPartOnBoard("a", in: w)
        XCTAssertEqual(s.scenesPart(in: w)?.id, "a")
        XCTAssertEqual(w.takeScenesJump(), ScenesJump(chapter: nil, cards: true))
        // A bar of another part while a part is shown: the board goes to that chapter's part.
        s.showOnBoard("03", in: w)
        XCTAssertEqual(s.scenesPart(in: w)?.id, "b")
        // One of a chapter in no part: back to the book.
        s.showOnBoard("00", in: w)
        XCTAssertEqual(w.scenesLevel, .book)
        // One of the part shown leaves it be.
        s.showPartOnBoard("a", in: w)
        s.showOnBoard("02", in: w)
        XCTAssertEqual(s.scenesPart(in: w)?.id, "a")
        // Neither a chapter nor a part that is gone moves anything.
        _ = w.takeScenesJump()
        s.showOnBoard("gone", in: w)
        s.showPartOnBoard("gone", in: w)
        XCTAssertNil(w.scenesJump)
        XCTAssertEqual(w.scenesChapter, "02")
        XCTAssertEqual(s.scenesPart(in: w)?.id, "a")
    }

    func testABarInWords() throws {
        let saved = UserDefaults.standard.string(forKey: UILang.key)
        defer { UserDefaults.standard.set(saved, forKey: UILang.key) }
        UserDefaults.standard.set(UILang.fr.rawValue, forKey: UILang.key)
        var counts = TextCounts()
        counts.words = 2034
        let unit = CountSetting.shared.unit
        defer { CountSetting.shared.unit = unit }
        CountSetting.shared.unit = .words
        let said = BookBars.words(BookNumbers.Bar(id: "33", mark: "33", title: "Flower Island", status: .done, counts: counts, scenes: 12),
                                  BookManifest(title: "T", chapters: []).words)
        XCTAssertEqual(said.replacingOccurrences(of: "\u{202F}", with: " ").replacingOccurrences(of: "\u{00A0}", with: " "),
                       "33 Flower Island · 12 scènes · 2 034 mots")
    }

    // MARK: Shots

    /// A book of `count` chapters in a temporary folder, with or without parts and a goal; sittings on some of
    /// the last days, made with dates of their own.
    private func shotBook(_ name: String, count: Int, parts: Bool, goal: Int?) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overview-\(UUID())/\(name)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let para = ["Nora descendit du bac la dernière, le manteau de son père plié sur le bras, et resta un moment sur la cale à regarder l’eau *grise* se refermer derrière le bateau.",
                    "— Tu aurais pu prévenir, dit Tom sans se retourner.",
                    "Elle ne répondit pas. Le vent portait l’odeur des bassins, cette odeur de vase et de fer qu’elle avait crue oubliée, et qui revenait d’un seul coup, **entière**, comme une phrase apprise par cœur.",
                    "Ils marchèrent jusqu’à la saline sans se parler. Les râteaux étaient restés contre le mur, là où leur mère les rangeait.",
                    "— Il est mort mardi, dit-elle enfin.",
                    "Le soir, la marée remonta jusqu’aux premières tables, et personne ne songea à fermer les vannes."]
        let names = ["Le bac", "La cale", "", "La saline, onze ans après les funérailles", "Mardi", "Les vannes", "Le grenier", "", "Tom"]
        var chapters: [ChapterEntry] = []
        for n in 1...count {
            let scenes = n == 7 ? 1 : n == 12 ? 0 : 2 + (n * 7) % 8
            var text = "# Chapitre \(n)\n\n"
            for k in 0..<scenes {
                // Chapters of very different lengths, as a book in progress has: the last ones barely begun.
                let length = n > count - 5 ? 0 : (n * 5 + k * 3) % 9
                text += "<!-- scene: \(names[(n + k) % names.count]) -->\n\n" + (0...length).map { para[($0 + n + k) % para.count] }.joined(separator: "\n\n") + "\n\n"
            }
            if n == 7 { text = "# Chapitre 7\n\n" + para[2] + "\n\n" + para[4] + "\n" }
            if n == 12 { text = "# Chapitre 12\n\n" }
            let id = String(format: "%02d", n)
            try text.write(to: root.appendingPathComponent("\(id).md"), atomically: true, encoding: .utf8)
            let title = [3: "Nice", 14: "La maison du quai des Belges, un dimanche", 28: "Peninsula", 33: "Flower Island"][n] ?? "Chapitre \(n)"
            let third = count / 3
            chapters.append(ChapterEntry(id: id, file: "\(id).md", title: title,
                                         status: n <= count / 2 ? .final : n <= count * 2 / 3 ? .edited : n <= count - 7 ? .done : .draft,
                                         part: !parts || n == 1 ? nil : n <= third ? "a" : n <= 2 * third ? "b" : "c"))
        }
        var m = BookManifest(title: name, author: "A.", lang: "fr", chapters: chapters)
        m.goal = goal
        if parts { m.parts = [BookPart(id: "a", title: ""), BookPart(id: "b", title: "La fuite"), BookPart(id: "c", title: "")] }
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        // Sittings today, yesterday, the day before, and one earlier in the week.
        for ago in [9, 4, 2, 1, 0] {
            let date = ISO8601DateFormatter().string(from: Calendar.current.date(byAdding: .day, value: -ago, to: Date())!)
            let git = Process()
            git.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            git.arguments = ["-C", root.path, "-c", "user.name=A", "-c", "user.email=a@example.invalid", "commit", "-q", "--allow-empty", "-m", "sitting", "--date", date]
            git.environment = ["GIT_COMMITTER_DATE": date, "PATH": "/usr/bin:/bin"]
            try git.run()
            git.waitUntilExit()
        }
        return root
    }

    /// Overview's first page drawn offscreen: dark and light, wide, in a pane of 700 points and in half a window,
    /// a book without parts, one without a goal, the board as a list, the page scrolled to its board and at a part.
    /// MUSSET_LIVE_SHOTS=<dir> (skipped otherwise), as `BookScenesTests.testBookScenesShots`.
    func testOverviewShots() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_LIVE_SHOTS"] else { throw XCTSkip("set MUSSET_LIVE_SHOTS") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        let keys = [UILang.key, "libraryPaths", "lastBook", "sceneCardSize", BookOverviewPage.listKey]
        let saved = keys.map { d.object(forKey: $0) }
        let unit = CountSetting.shared.unit
        defer {
            for (k, v) in zip(keys, saved) { d.set(v, forKey: k) }
            CountSetting.shared.unit = unit
        }
        d.set("fr", forKey: UILang.key)
        for k in keys.dropFirst() { d.removeObject(forKey: k) }
        CountSetting.shared.unit = .words

        let retina = NSScreen.screens.max { $0.backingScaleFactor < $1.backingScaleFactor }
        /// A book open in a window of its own, on Overview.
        func open(_ root: URL, width: CGFloat, height: CGFloat = 900, today: Int = 412) throws -> (AppState, BookSession, NSWindow) {
            let app = AppState()
            app.openBook(root)
            let s = try XCTUnwrap(app.current)
            if s.manifest.chapters.count >= 33 { s.open("33") }
            let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
            bridge.annotator = ann; bridge.proof = proof
            let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .fullSizeContentView],
                                  backing: .buffered, defer: false, screen: retina)
            window.contentView = NSHostingView(rootView: view.frame(width: width, height: height))
            app.showInspector = false
            s.state.wordsBaseline = .init(day: BookUIState.WordsBaseline.today, words: max(s.bookWordCount - today, 0))
            return (app, s, window)
        }
        func shot(_ window: NSWindow, _ name: String, dark: Bool, _ setup: () -> Void = {}) async throws {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            setup()
            try await Task.sleep(for: .seconds(1.2))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }

        // Forty chapters in three parts, with a goal.
        let sel = try shotBook("Le sel", count: 40, parts: true, goal: 20_000)
        let (app, s, wide) = try open(sel, width: 1440)
        let w = s.workspace
        let pane = try XCTUnwrap(w.focused).id
        // The page as it opens, counted: its numbers come from the counts kept, its cards from the excerpts kept.
        let clock = ContinuousClock()
        let took = clock.measure {
            _ = BookNumbers.groups(s.manifest, counts: s.chapterCounts, scenes: s.scenes.mapValues(\.count))
            for ch in s.manifest.chapters { _ = s.cardText(of: ch.id) }
        }
        print("Overview: 40 chapters' bars and card texts in \(took)")
        XCTAssertLessThan(took, .milliseconds(250))

        try await shot(wide, "ov-1-wide-dark.png", dark: true) { w.foldScenes("a", true); w.foldScenes("b", true); app.open(OverviewTab.summary.tab) }
        try await shot(wide, "ov-1-wide-light.png", dark: false)
        try await shot(wide, "ov-2-characters-dark.png", dark: true) { CountSetting.shared.unit = .charactersWithSpaces }
        CountSetting.shared.unit = .words
        try await shot(wide, "ov-3-list-dark.png", dark: true) { d.set(true, forKey: BookOverviewPage.listKey) }
        try await shot(wide, "ov-3-list-light.png", dark: false)
        // Out of a chapter's cards: the same page, on its cards again, scrolled to the chapter one comes from.
        try await shot(wide, "ov-4-from-a-chapter-dark.png", dark: true) { s.zoomOut(from: "33", toPart: false, in: w, pane: pane) }
        try await shot(wide, "ov-5-part-light.png", dark: false) { s.showPartOnBoard("b", in: w) }
        try await shot(wide, "ov-6-bar-picked-dark.png", dark: true) { s.showOnBoard("05", in: w) }

        // A pane of 700 points: the sidebar takes 256 of the window.
        let (app700, s700, narrow) = try open(try shotBook("Le sel", count: 40, parts: true, goal: 20_000), width: 956)
        try await shot(narrow, "ov-7-pane-700-dark.png", dark: true) { s700.workspace.foldScenes("a", true); app700.open(OverviewTab.summary.tab) }
        try await shot(narrow, "ov-7-pane-700-light.png", dark: false)
        // Beside a chapter: half a window.
        let (appHalf, sHalf, half) = try open(try shotBook("Le sel", count: 40, parts: true, goal: 20_000), width: 1440)
        try await shot(half, "ov-7b-half-window-dark.png", dark: true) {
            appHalf.open(OverviewTab.summary.tab)
            let pane = sHalf.workspace.focusedPane
            sHalf.workspace.open(.chapter("33"), in: .split(.right))
            sHalf.workspace.focus(pane)
        }

        // No parts; the goal passed.
        let (appPlain, _, plain) = try open(try shotBook("Les vannes", count: 24, parts: false, goal: 6_000), width: 1440)
        try await shot(plain, "ov-8-no-parts-dark.png", dark: true) { appPlain.open(OverviewTab.summary.tab) }
        try await shot(plain, "ov-8-no-parts-light.png", dark: false)

        // No goal, sixty chapters, nothing written today.
        let (appFree, sFree, free) = try open(try shotBook("La maison du quai des Belges", count: 60, parts: true, goal: nil), width: 1440, today: 0)
        try await shot(free, "ov-9-no-goal-dark.png", dark: true) { sFree.workspace.foldScenes("a", true); sFree.workspace.foldScenes("b", true); appFree.open(OverviewTab.summary.tab) }
        try await shot(free, "ov-9-no-goal-light.png", dark: false)
    }
}
