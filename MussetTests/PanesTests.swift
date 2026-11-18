import XCTest
@testable import Musset

/// Several chapters open for writing in panes: each its own text, its own notes, its own file.
@MainActor
final class PanesTests: XCTestCase {
    private var root: URL!

    private func book() throws -> BookSession {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-panes-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!) }
        try "Tom crossed at six.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "The gate was open.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        var m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One"), ChapterEntry(id: "02", file: "02.md", title: "Two")])
        m.lang = "en"
        try BookStore(root: root).saveManifest(m)
        try GitService(root: root).initRepo()
        return BookSession(root: root, manifest: m)
    }

    private func disk(_ name: String) -> String { (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "" }

    /// One number per chapter, from 1, the same in the sidebar, on its tab and in Overview.
    func testChaptersAreNumberedFromOneEverywhere() throws {
        let s = try book()
        XCTAssertEqual(BookManifest.chapterNumber(at: 0), 1)
        XCTAssertEqual(s.manifest.chapterNumber(of: "02"), 2)
        XCTAssertNil(s.manifest.chapterNumber(of: "gone"))
        XCTAssertEqual(PaneTabBar.title(.chapter("01"), session: s), "1 One", "the tab")
        XCTAssertEqual(s.chapterSummaries(todos: []).map(\.mark), ["1", "2"], "Overview's table")
    }

    func testTwoChaptersWrittenInTurnEachKeepTheirOwnFile() throws {
        let s = try book()
        s.open("01")
        s.textDidChange("Tom crossed at six. The deck was wet.")
        // To the other pane, before the first chapter's save has fired.
        s.open("02")
        s.textDidChange("The gate was open. Nobody had locked it.")
        XCTAssertEqual(s.selectedChapterID, "02")
        s.flushSave()
        XCTAssertEqual(disk("01.md"), "Tom crossed at six. The deck was wet.", "nothing lost switching pane mid-typing")
        XCTAssertEqual(disk("02.md"), "The gate was open. Nobody had locked it.")
        XCTAssertNotNil(s.docs["01"], "a chapter left stays open while a pane shows it")
        XCTAssertEqual(s.editorText(of: "01"), "Tom crossed at six. The deck was wet.")
    }

    /// The app opens a book with its counts made later, off the main thread: they end up what counting in place gives,
    /// and a chapter written in meanwhile is counted as it stands.
    func testCountsMadeLaterMatchCountsMadeInPlace() async throws {
        let inPlace = try book()
        try "# Three\n\nOpening words here.\n\n<!-- scene: Dawn -->\n\nTom woke early.\n\n<!-- scene: Dusk -->\n\nHe slept.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let manifest = inPlace.manifest
        let now = BookSession(root: root, manifest: manifest)
        let later = BookSession(root: root, manifest: manifest, countsLater: true)
        XCTAssertNotNil(later.selectedChapterID, "the chapter shows before the book is counted")
        later.textDidChange(later.text + " And two more.")
        await later.counting?.value
        XCTAssertNil(later.counting)
        XCTAssertEqual(later.scenes["02"], now.scenes["02"])
        XCTAssertEqual(later.scenes["02"]?.count, 3)
        XCTAssertEqual(later.chapterCounts["02"]?.words, now.chapterCounts["02"]?.words)
        XCTAssertEqual(later.versionCounts, now.versionCounts)
        XCTAssertEqual(later.manifest.chapters.map(\.title), now.manifest.chapters.map(\.title), "titles follow the headings either way")
        XCTAssertEqual(later.chapterCounts["01"]?.words, (now.chapterCounts["01"]?.words ?? 0) + 3, "the open chapter is counted as written, not as on disk")
        XCTAssertEqual(later.editorText(of: "02"), now.editorText(of: "02"))
    }

    /// A closed chapter is read through a cache: a file rewritten by something else is read again.
    func testAClosedChapterIsReadAgainWhenItsFileChanges() throws {
        let s = try book()
        s.open("01")
        XCTAssertEqual(s.editorText(of: "02"), "The gate was open.")
        try "The gate was shut. Locked.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(s.editorText(of: "02"), "The gate was shut. Locked.")
        try "The gate was open. Locked.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(s.editorText(of: "02"), "The gate was open. Locked.", "same length, written a moment later: still read again")
    }

    func testAPendingSaveGoesToItsOwnChapter() async throws {
        let s = try book()
        s.open("01")
        s.textDidChange("Tom crossed at seven.")
        s.open("02")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(disk("01.md"), "Tom crossed at seven.", "the timer saved chapter 01, not the one now focused")
        XCTAssertEqual(disk("02.md"), "The gate was open.")
    }

    func testNotesStayWithTheirChapter() throws {
        let s = try book()
        s.open("01")
        s.notes.add(range: (s.text as NSString).range(of: "six"), text: s.text, author: .me, kind: .note, body: "Seven?")
        s.open("02")
        XCTAssertTrue(s.notes.notes.isEmpty, "chapter 02 has no notes")
        s.notes.add(range: (s.text as NSString).range(of: "gate"), text: s.text, author: .me, kind: .note, body: "Which gate?")
        XCTAssertEqual(s.noteStore(for: "01").notes(of: "01").map(\.body), ["Seven?"])
        s.open("01")
        XCTAssertEqual(s.notes.notes.map(\.body), ["Seven?"])
        XCTAssertEqual(s.noteStore(for: "02").notes(of: "02").map(\.body), ["Which gate?"])
    }

    func testTheSameChapterInTwoPanesIsOneDocument() throws {
        let s = try book()
        s.open("01")
        let a = try XCTUnwrap(s.doc(for: "01"))
        let b = try XCTUnwrap(s.doc(for: "01"))
        XCTAssertTrue(a === b)
        s.workspace.open(.chapter("01"), in: .split(.right))
        XCTAssertEqual(s.workspace.panes.count, 2)
        XCTAssertEqual(s.workspace.panes.compactMap { $0.activeTab?.chapterID }, ["01", "01"])
    }

    func testARenameReachesAChapterOpenInAnotherPane() throws {
        let s = try book()
        s.open("02")
        s.open("01")
        _ = s.doc(for: "02")
        try s.bible.create(title: "Tom", kind: .character)
        let tom = try XCTUnwrap(s.bible.entry(named: "Tom"))
        s.notes.add(range: (s.text as NSString).range(of: "Tom crossed"), text: s.text, author: .me, kind: .note, body: "Tom again")
        s.applyRename(RenamePlan.make(tom, to: "Ewan", in: s))
        XCTAssertEqual(s.text, "Ewan crossed at six.")
        XCTAssertEqual(disk("01.md"), "Ewan crossed at six.")
        XCTAssertEqual(s.notes.notes.first?.body, "Ewan again")
    }

    func testPanesNoLongerShownLetGoOfTheirChapter() throws {
        let s = try book()
        s.open("01")
        _ = s.doc(for: "02")
        s.docs["02"]?.text = "Changed while open."
        s.docs["02"]?.dirty = true
        s.pruneDocs(keeping: ["01"])
        XCTAssertNil(s.docs["02"])
        XCTAssertEqual(disk("02.md"), "Changed while open.", "saved before being let go")
    }

    // MARK: Drags onto the panes

    func testATabTravelsAsAWire() {
        let drag = ShelfDrag.tab(pane: "A-1", index: 3)
        XCTAssertEqual(ShelfDrag(wire: drag.wire), drag)
        XCTAssertNil(drag.paneTab, "a tab moves; it opens nothing new")
        XCTAssertEqual(ShelfDrag.note(chapter: "02", id: UUID()).paneTab, .chapter("02"))
    }

    func testWhereADropLands() {
        let d = PaneDrops()
        d.paneFrames["p"] = CGRect(x: 100, y: 0, width: 400, height: 432)
        d.barFrames["p"] = CGRect(x: 100, y: 0, width: 400, height: 32)
        d.tabFrames["p"] = [0: CGRect(x: 100, y: 0, width: 100, height: 32), 1: CGRect(x: 200, y: 0, width: 100, height: 32)]
        XCTAssertEqual(d.target(at: CGPoint(x: 120, y: 10))?.zone, .tabs(0))
        XCTAssertEqual(d.target(at: CGPoint(x: 260, y: 10))?.zone, .tabs(2))
        XCTAssertEqual(d.target(at: CGPoint(x: 110, y: 230))?.zone, .edge(.left))
        XCTAssertEqual(d.target(at: CGPoint(x: 490, y: 230))?.zone, .edge(.right))
        XCTAssertEqual(d.target(at: CGPoint(x: 300, y: 40))?.zone, .edge(.top))
        XCTAssertEqual(d.target(at: CGPoint(x: 300, y: 425))?.zone, .edge(.bottom))
        XCTAssertEqual(d.target(at: CGPoint(x: 300, y: 230))?.zone, .center)
        XCTAssertNil(d.target(at: CGPoint(x: 50, y: 230)), "outside the panes: the sidebar")
    }

    func testASheetDroppedOnASideOpensANewPane() throws {
        let s = try book()
        s.open("01")
        try s.bible.create(title: "Tom", kind: .character)
        let tom = try XCTUnwrap(s.bible.entry(named: "Tom"))
        let first = try XCTUnwrap(s.workspace.focused).id
        XCTAssertTrue(s.dropOnPanes(ShelfDrag.sheet(tom.path).wire, at: .init(pane: first, zone: .edge(.right))))
        XCTAssertEqual(s.workspace.panes.map { $0.activeTab }, [.chapter("01"), .sheet(tom.path)])
        XCTAssertEqual(s.selectedChapterID, "01", "the chapter stays the one written in")
        XCTAssertNil(s.workspace.drops.hover)
    }

    func testAChapterDroppedInAPaneIsTheOneWrittenIn() throws {
        let s = try book()
        s.open("01")
        let first = try XCTUnwrap(s.workspace.focused).id
        s.dropOnPanes(ShelfDrag.chapter("02").wire, at: .init(pane: first, zone: .tabs(0)))
        XCTAssertEqual(s.workspace.focused?.tabs, [.chapter("02"), .chapter("01")])
        XCTAssertEqual(s.selectedChapterID, "02")
    }

    func testATabDraggedToAnotherPaneTakesTheChapterWithIt() throws {
        let s = try book()
        s.open("01")
        s.open(.chapter("02"), in: .newTab)
        let left = try XCTUnwrap(s.workspace.focused).id
        s.open(OverviewTab.synopsis.tab, in: .split(.right))
        let right = try XCTUnwrap(s.workspace.focused).id
        XCTAssertNotEqual(left, right)
        // Chapter 02, second tab on the left, goes among the right pane's tabs.
        s.dropOnPanes(ShelfDrag.tab(pane: left, index: 1).wire, at: .init(pane: right, zone: .tabs(1)))
        XCTAssertEqual(s.workspace.panes.map(\.tabs), [[.chapter("01")], [OverviewTab.synopsis.tab, .chapter("02")]])
        XCTAssertEqual(s.workspace.focusedPane, right)
        XCTAssertEqual(s.selectedChapterID, "02")
        // Dropped in the middle of its own pane: nothing moves.
        XCTAssertFalse(s.dropOnPanes(ShelfDrag.tab(pane: right, index: 1).wire, at: .init(pane: right, zone: .center)))
    }

    func testTabsAndPanesByKeyboard() throws {
        let s = try book()
        s.open("01")
        s.open(.chapter("02"), in: .newTab)
        let w = s.workspace
        w.cycleTab(by: 1)
        XCTAssertEqual(w.activeTab, .chapter("01"))
        w.cycleTab(by: -1)
        XCTAssertEqual(w.activeTab, .chapter("02"))
        XCTAssertTrue(w.canCloseTab)
        w.closeActiveTab()
        XCTAssertEqual(w.focused?.tabs, [.chapter("01")])
        XCTAssertFalse(w.canCloseTab, "the window's last tab stays: ⌘W closes the window")
        s.open(OverviewTab.synopsis.tab, in: .split(.right))
        w.cyclePane(by: 1)
        XCTAssertEqual(w.activeTab, .chapter("01"))
    }

    // MARK: Separate windows

    func testAWindowOfItsOwnSharesTheChapters() throws {
        let s = try book()
        s.open("01")
        let id = s.newWindow(with: .chapter("02"))
        let other = try XCTUnwrap(s.windows[id])
        XCTAssertEqual(other.activeTab, .chapter("02"))
        // A chapter shown only in that window stays open.
        _ = s.doc(for: "02")
        s.pruneDocs()
        XCTAssertNotNil(s.docs["02"])
        // In front, it is where things open.
        s.activeWindow = id
        s.open(OverviewTab.synopsis.tab, in: .newTab)
        XCTAssertEqual(other.focused?.tabs, [.chapter("02"), OverviewTab.synopsis.tab])
        XCTAssertEqual(s.mainWorkspace.focused?.tabs, [.chapter("01")])
        XCTAssertTrue(s.owner(ofPane: try XCTUnwrap(other.focused).id) === other)
    }

    func testATabDraggedToTheMainWindowLeavesItsWindow() throws {
        let s = try book()
        s.open("01")
        let id = s.newWindow(with: OverviewTab.synopsis.tab)
        let other = try XCTUnwrap(s.windows[id])
        let from = try XCTUnwrap(other.focused).id
        let to = try XCTUnwrap(s.mainWorkspace.focused).id
        XCTAssertTrue(s.dropOnPanes(ShelfDrag.tab(pane: from, index: 0).wire, at: .init(pane: to, zone: .edge(.right))))
        XCTAssertTrue(other.panes.allSatisfy(\.tabs.isEmpty), "the window is left empty, and closes")
        XCTAssertEqual(s.mainWorkspace.panes.map(\.activeTab), [.chapter("01"), OverviewTab.synopsis.tab])
        XCTAssertNil(s.activeWindow, "the main window is the one one is in")
    }

    func testWindowsAreKeptWithTheBookUntilClosed() throws {
        let s = try book()
        s.open("01")
        let id = s.newWindow(with: .chapter("02"))
        s.windows[id]?.open(.sources, in: .split(.bottom))
        s.close()
        let again = BookSession(root: root, manifest: s.manifest)
        XCTAssertEqual(again.savedWindowIDs, [id])
        let ws = again.workspace(forWindow: id)
        XCTAssertEqual(ws.panes.map(\.activeTab), [.chapter("02"), .sources])
        again.closeWindow(id)
        again.close()
        XCTAssertEqual(BookSession(root: root, manifest: s.manifest).savedWindowIDs, [], "a window closed is let go")
    }

    // MARK: One read, one write, one notes store per chapter

    /// Chapter 02 open in a second pane, the author writing in 01.
    private func twoPanes() throws -> BookSession {
        let s = try book()
        s.open("02")
        s.textDidChange("# Two\nThe gate was open.")
        s.open("01")
        s.workspace.open(.chapter("02"), in: .split(.right))
        s.workspace.focus(s.workspace.panes[0].id)
        s.followFocusedPane()
        XCTAssertEqual(s.workspace.panes.map(\.activeTab), [.chapter("01"), .chapter("02")])
        XCTAssertEqual(s.selectedChapterID, "01")
        XCTAssertNotNil(s.docs["02"])
        return s
    }

    /// Typing in the other pane, then its save: what the file holds afterwards.
    private func type(_ more: String, in chapter: String, _ s: BookSession) throws -> String {
        let doc = try XCTUnwrap(s.docs[chapter])
        s.open(chapter, show: false)
        s.textDidChange(doc.text + more)
        s.flushSave()
        return disk(chapter + ".md")
    }

    func testARenameReachesTheOtherPaneAndIsNotSavedOver() throws {
        let s = try twoPanes()
        s.renameChapter("02", to: "The Gate")
        XCTAssertEqual(s.docs["02"]?.text, "# The Gate\nThe gate was open.", "the pane shows the new heading")
        XCTAssertEqual(s.manifest.chapters[1].title, "The Gate")
        let saved = try type(" Nobody had locked it.", in: "02", s)
        XCTAssertTrue(saved.hasPrefix("# The Gate"), saved)
        XCTAssertTrue(saved.contains("Nobody had locked it."))
    }

    func testWhatIsBroughtBackReachesTheOtherPane() throws {
        let s = try twoPanes()
        s.applyBring(["02": "# Two\nThe gate was shut."], message: "musset: bring")
        XCTAssertEqual(s.docs["02"]?.text, "# Two\nThe gate was shut.")
        XCTAssertTrue(disk("02.md").contains("The gate was shut."))
        XCTAssertTrue(try type(" It had rained.", in: "02", s).contains("The gate was shut. It had rained."))
    }

    func testGoingBackReachesTheOtherPane() throws {
        let s = try twoPanes()
        s.commitNow("musset: start")
        let start = try XCTUnwrap(s.git.resolve("HEAD"))
        s.open("02", show: false)
        s.textDidChange("# Two\nThe gate was shut, and locked.")
        s.open("01", show: false)
        s.goBack(to: start, label: "start", chapters: ["02"], order: false)
        XCTAssertEqual(s.docs["02"]?.text, "# Two\nThe gate was open.")
        XCTAssertTrue(try type(" Wide open.", in: "02", s).contains("The gate was open. Wide open."))
    }

    func testASyncReloadsEveryOpenChapter() throws {
        let s = try twoPanes()
        s.flushSave()
        // What a sync writes: the files, behind the editors' backs.
        try "# Two\n\nThe gate was shut by someone else.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        try "Tom crossed at seven.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        var theirs = Note(author: .me, kind: .note, body: "From the other Mac", anchor: NoteAnchor(quote: "", prefix: "", suffix: "", start: 0, version: nil))
        theirs.source = "sync"
        try FileManager.default.createDirectory(at: NoteStore.url(root, "02").deletingLastPathComponent(), withIntermediateDirectories: true)
        try NoteStore.sortedForDisk([theirs]).write(to: NoteStore.url(root, "02"), atomically: true, encoding: .utf8)
        s.reloadAfterSync()
        XCTAssertEqual(s.text, "Tom crossed at seven.")
        XCTAssertEqual(s.docs["02"]?.text, "# Two\nThe gate was shut by someone else.", "the pane one is not in follows too")
        XCTAssertEqual(s.docs["02"]?.notes.notes.map(\.body), ["From the other Mac"])
        XCTAssertTrue(try type(" Good.", in: "02", s).contains("shut by someone else. Good."))
        XCTAssertEqual(NoteStore.read(NoteStore.url(root, "02")).map(\.body), ["From the other Mac"])
    }

    func testEachOpenChapterIsCountedAndNamedByItsOwnText() throws {
        let s = try twoPanes()
        s.textDidChange("# Ferry\nTom crossed at six. The deck was wet.")
        s.countAllWords()
        XCTAssertEqual(s.chapterCounts["01"]?.words, BookStore.wordCount("# Ferry\nTom crossed at six. The deck was wet."))
        XCTAssertEqual(s.chapterCounts["02"]?.words, BookStore.wordCount("# Two\nThe gate was open."), "not the words of the chapter one is in")
        XCTAssertEqual(s.manifest.chapters.map(\.title), ["Ferry", "Two"], "and not its heading")
        XCTAssertEqual(s.scenes["02"]?.count, Scenes.parse("# Two\nThe gate was open.").count)
    }

    func testTypographyReachesTheOtherPane() throws {
        let s = try twoPanes()
        s.manifest.lang = "fr"
        s.open("02", show: false)
        s.textDidChange("# Deux\nQui est là ?")
        s.open("01", show: false)
        s.flushSave()
        XCTAssertEqual(s.typographyPreview().chapters, 1, "the other pane's own text is the one looked at")
        s.applyTypographyToBook()
        XCTAssertEqual(s.docs["02"]?.text, "# Deux\nQui est là\u{00A0}?")
        XCTAssertEqual(s.text, "Tom crossed at six.", "the chapter one is in keeps its own text")
        XCTAssertTrue(try type(" Personne.", in: "02", s).contains("là\u{00A0}? Personne."))
    }

    func testANoteForTheOtherPaneSurvivesThatChaptersNextSave() throws {
        let s = try twoPanes()
        let two = try XCTUnwrap(s.docs["02"])
        two.notes.add(range: (two.text as NSString).range(of: "gate"), text: two.text, author: .me, kind: .note, body: "Which gate?")
        // Written from the chapter one is in, for the other one.
        XCTAssertEqual(s.file(capture: "@[Two] @todo Check the lock"), "Two")
        s.importNotes([Note(author: .me, kind: .note, body: "Too quiet", anchor: Anchoring.capture((two.text as NSString).range(of: "open"), in: two.text as NSString, version: nil))],
                      chapter: "02", from: "Ana")
        XCTAssertEqual(two.notes.notes.count, 3, "the open chapter has them in hand")
        XCTAssertNotNil(two.notes.notes.last.flatMap { two.notes.live[$0.id] }, "and the reader's note has found its passage")
        let todo = try XCTUnwrap(s.collectTodos().first { $0.text.contains("Check the lock") })
        s.toggle(todo)
        // The chapter's own store writes its notes again: a new note, then a save of the text.
        two.notes.add(range: (two.text as NSString).range(of: "Two"), text: two.text, author: .me, kind: .note, body: "Title?")
        _ = try type(" Nobody had locked it.", in: "02", s)
        let kept = NoteStore.read(NoteStore.url(root, "02"))
        XCTAssertEqual(Set(kept.map(\.body)), ["Which gate?", "@[Two] Check the lock", "**Ana** : Too quiet", "Title?"])
        XCTAssertEqual(kept.first { $0.body.hasSuffix("Check the lock") }?.status, .done)
        // To the Trash and back, still through the chapter's own store.
        let id = try XCTUnwrap(kept.first { $0.body.hasSuffix("Too quiet") }?.id)
        XCTAssertTrue(s.noteToTrash(id, in: "02"))
        XCTAssertEqual(two.notes.notes.count, 3)
        XCTAssertTrue(s.restoreFromTrash(try XCTUnwrap(s.trash.last?.id)))
        XCTAssertEqual(two.notes.notes.count, 4)
        XCTAssertNotNil(two.notes.live[id], "back on its passage")
        _ = try type(" At all.", in: "02", s)
        XCTAssertEqual(NoteStore.read(NoteStore.url(root, "02")).count, 4)
    }

    // MARK: Commits

    func testAChangeOfTheManifestAloneIsCommitted() throws {
        let s = try book()
        s.commitNow("musset: start")
        let before = s.git.log(path: ".musset/book.json").count
        XCTAssertFalse(s.pendingCommit)
        s.setStatus("01", .done)
        XCTAssertTrue(s.pendingCommit, "a status waits for a commit like the text does")
        s.close()
        XCTAssertFalse(s.pendingCommit)
        XCTAssertEqual(s.git.log(path: ".musset/book.json").count, before + 1)
        XCTAssertTrue(s.git.show("HEAD", path: ".musset/book.json")?.contains("done") == true)
        s.manifest.author = "A. N. Other"
        s.saveManifest()
        s.toggleExport("02")
        XCTAssertTrue(s.pendingCommit)
        s.commitIfPending(message: s.editMessage)
        XCTAssertTrue(s.git.show("HEAD", path: ".musset/book.json")?.contains("A. N. Other") == true)
    }

    func testAStatusSetInATrackIsCommittedOnTheManuscriptWhenTheTrackIsLeft() throws {
        let s = try book()
        s.commitNow("musset: start")
        s.newPiste(named: "Essai", fromLabel: "the manuscript")
        XCTAssertNotNil(s.piste)
        s.setStatus("02", .done)
        XCTAssertFalse(s.git.show("HEAD", path: ".musset/book.json")?.contains("done") == true)
        s.enter(nil)
        XCTAssertTrue(s.git.show("HEAD", path: ".musset/book.json")?.contains("done") == true)
    }

    func testACommitIsNamedAfterTheChapterSaved() throws {
        let s = try twoPanes()
        s.commitNow("musset: start")
        XCTAssertEqual(s.editMessage, "musset: edit 01")
        try s.writeChapterText("02", "# Two\nThe gate was shut.")
        XCTAssertEqual(s.editMessage, "musset: edit 02", "the chapter saved, not the one the author is in")
        s.commitIfPending(message: s.editMessage)
        XCTAssertEqual(s.git.log(path: "02.md").first?.subject, "musset: edit 02")
        XCTAssertEqual(s.editMessage, "musset: edit 01")
    }

    // MARK: Named layouts

    func testANamedLayoutComesBackInAnyWindow() throws {
        let s = try book()
        s.open("01")
        s.open(OverviewTab.synopsis.tab, in: .split(.right))
        s.saveLayout(named: "Writing with the plan")
        XCTAssertEqual(s.layoutNames, ["Writing with the plan"])
        s.workspace.closeActiveTab()
        XCTAssertEqual(s.workspace.panes.count, 1)
        let id = s.newWindow(with: .chapter("02"))
        s.activeWindow = id
        s.applyLayout(named: "Writing with the plan")
        let main = Set(s.mainWorkspace.panes.map(\.id))
        XCTAssertEqual(s.workspace.panes.map(\.activeTab), [.chapter("01"), OverviewTab.synopsis.tab])
        XCTAssertTrue(main.isDisjoint(with: s.workspace.panes.map(\.id)), "its panes are its own")
        s.deleteLayout(named: "Writing with the plan")
        XCTAssertEqual(s.layoutNames, [])
    }
}
