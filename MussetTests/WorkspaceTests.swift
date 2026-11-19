import XCTest
@testable import Musset

/// Panes and tabs: opening, the preview tab, splitting, closing, moving, keeping the layout.
@MainActor
final class WorkspaceTests: XCTestCase {
    /// Format, Find and the other editor commands are on only with a book in front and a chapter in the pane one is in.
    func testEditorCommandsNeedAChapterInFront() {
        XCTAssertTrue(AppState.editorCommands(book: true, tab: .chapter("01")))
        XCTAssertFalse(AppState.editorCommands(book: false, tab: .chapter("01")), "under Home, or no book")
        for tab in [OverviewTab.grid.tab, OverviewTab.synopsis.tab, .sources, .sheet("personnages/tom.md"), .overview("summary"), .special("cover")] {
            XCTAssertFalse(AppState.editorCommands(book: true, tab: tab), "\(tab)")
        }
        XCTAssertFalse(AppState.editorCommands(book: true, tab: nil))
    }

    /// The inspector gives way to the sidebar and the panes: narrower in a narrow window, folded away when even
    /// its narrowest would cut them.
    func testTheInspectorFitsTheWindow() {
        XCTAssertEqual(InspectorFit.width(wanted: 384, window: 1440, sidebar: true), 384, "room for all: as the author set it")
        XCTAssertEqual(InspectorFit.width(wanted: 384, window: 900, sidebar: true), 363, "900 − 257 − 280")
        XCTAssertNil(InspectorFit.width(wanted: 384, window: 720, sidebar: true), "the smallest window: it folds away")
        XCTAssertEqual(InspectorFit.width(wanted: 384, window: 720, sidebar: false), 384, "without the sidebar it fits")
        XCTAssertEqual(InspectorFit.width(wanted: 2000, window: 4000, sidebar: true), 900, "never wider than its range")
        XCTAssertEqual(InspectorFit.width(wanted: 384, window: .greatestFiniteMagnitude, sidebar: true), 384, "before the window is measured")
    }

    func testAClickOpensAPreviewTabTheNextOneReplaces() {
        let w = Workspace()
        w.open(.chapter("01"))
        w.pin()
        w.open(.sheet("personnages/tom.md"))
        XCTAssertEqual(w.focused?.tabs, [.chapter("01"), .sheet("personnages/tom.md")])
        XCTAssertEqual(w.focused?.preview, 1)
        w.open(OverviewTab.synopsis.tab)
        XCTAssertEqual(w.focused?.tabs, [.chapter("01"), OverviewTab.synopsis.tab], "the preview tab is replaced")
        w.open(.chapter("01"))
        XCTAssertEqual(w.focused?.active, 0, "an open tab is shown, not opened twice")
        let fresh = Workspace()
        fresh.open(.chapter("01"))
        fresh.open(OverviewTab.synopsis.tab)
        XCTAssertEqual(fresh.focused?.tabs, [.chapter("01"), OverviewTab.synopsis.tab], "a page never takes the chapter's place")
        fresh.open(.chapter("02"))
        XCTAssertEqual(fresh.focused?.tabs, [.chapter("02"), OverviewTab.synopsis.tab], "browsing chapters reuses the chapter's preview tab")
        w.open(.sources, in: .newTab)
        XCTAssertEqual(w.focused?.tabs.count, 3)
    }

    func testSplitCloseAndCollapse() {
        let w = Workspace()
        w.open(.chapter("01")); w.pin()
        w.open(.sheet("tableaux/x.canvas"), in: .split(.right))
        XCTAssertEqual(w.panes.count, 2)
        XCTAssertEqual(w.activeTab, .sheet("tableaux/x.canvas"), "the new pane is the one one is in")
        w.open(OverviewTab.synopsis.tab, in: .split(.bottom))
        XCTAssertEqual(w.panes.count, 3)
        guard case .split(false, let children, let fr) = w.root else { return XCTFail("a row of two") }
        XCTAssertEqual(children.count, 2)
        XCTAssertEqual(fr, [0.5, 0.5])
        let bottom = w.focusedPane
        w.close(0, in: bottom)
        XCTAssertEqual(w.panes.count, 2, "an empty pane goes")
        w.open(.sources, in: .split(.right))
        guard case .split(false, let row, let shares) = w.root else { return XCTFail() }
        XCTAssertEqual(row.count, 3, "a pane beside another in a row joins the row")
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 0.0001)
    }

    func testMovingATabToAnotherPaneOrAnEdge() {
        let w = Workspace()
        w.open(.chapter("01")); w.pin()
        w.open(.chapter("02"), in: .newTab)
        let left = w.focusedPane
        w.open(OverviewTab.synopsis.tab, in: .split(.right))
        let right = w.focusedPane
        w.move(1, from: left, to: right)
        XCTAssertEqual(w.panes.first { $0.id == right }?.tabs, [OverviewTab.synopsis.tab, .chapter("02")])
        XCTAssertEqual(w.panes.first { $0.id == left }?.tabs, [.chapter("01")])
        w.move(0, from: right, to: left, edge: .bottom)
        XCTAssertEqual(w.panes.count, 3)
        XCTAssertEqual(w.activeTab, OverviewTab.synopsis.tab)
    }

    func testTheLayoutIsKeptWithoutWhatIsGone() throws {
        let w = Workspace()
        w.open(.chapter("01")); w.pin()
        w.open(.sheet("personnages/gone.md"), in: .split(.right))
        let data = try JSONEncoder().encode(w.saved)
        let back = try JSONDecoder().decode(Workspace.Saved.self, from: data)
        XCTAssertEqual(back, w.saved)
        let restored = Workspace(saved: back) { tab in tab != .sheet("personnages/gone.md") }
        XCTAssertEqual(restored.panes.count, 1, "the pane left empty goes")
        XCTAssertEqual(restored.activeTab, .chapter("01"))
    }

    func testAnOldStateWithoutLayoutStillReads() throws {
        let old = #"{"lastChapter":"01","selections":{"01":12}}"#
        let state = try JSONDecoder().decode(BookUIState.self, from: Data(old.utf8))
        XCTAssertNil(state.layout)
        XCTAssertEqual(state.lastChapter, "01")
    }

    func testTheOldRoutesOpenTabs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-ws-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "One.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "Two.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let m = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One"), ChapterEntry(id: "02", file: "02.md", title: "Two")])
        try BookStore(root: root).saveManifest(m)
        let app = AppState()
        app.openBook(root)
        let s = try XCTUnwrap(app.current)
        XCTAssertEqual(s.workspace.activeTab, .chapter("01"))
        app.open(OverviewTab.synopsis.tab)
        XCTAssertTrue(app.activeTab == OverviewTab.synopsis.tab)
        XCTAssertEqual(s.workspace.activeTab, OverviewTab.synopsis.tab)
        app.showChapter()
        XCTAssertEqual(s.workspace.activeTab, .chapter("01"))
        s.open("02")
        XCTAssertEqual(s.workspace.activeTab, .chapter("02"))
        XCTAssertEqual(s.workspace.focused?.tabs, [.chapter("02"), OverviewTab.synopsis.tab], "browsing chapters reuses the chapter's preview tab; the page stays")
        s.textDidChange("Two, written.")
        s.open("01")
        XCTAssertEqual(s.workspace.focused?.tabs, [.chapter("02"), .chapter("01"), OverviewTab.synopsis.tab], "a chapter written in keeps its tab")
    }

    // MARK: The chapter written in follows the tabs

    private func twoChapters() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-ws-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        try "One.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "Two.".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        try BookStore(root: root).saveManifest(BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One"), ChapterEntry(id: "02", file: "02.md", title: "Two")]))
        return root
    }

    func testTheChapterWrittenInFollowsTheTabShownWithoutBeingTold() throws {
        let root = try twoChapters()
        let s = BookSession(root: root, manifest: try BookStore(root: root).loadManifest())
        s.open("01"); s.textDidChange("One, kept.")
        s.open("02")
        let pane = try XCTUnwrap(s.workspace.focused).id
        s.workspace.activate(0, in: pane)
        XCTAssertEqual(s.selectedChapterID, "01", "a tab shown is the chapter written in")
        s.workspace.open(OverviewTab.synopsis.tab)
        XCTAssertEqual(s.selectedChapterID, "01", "a page that is not a chapter leaves one in the chapter")
        s.workspace.open(.chapter("02"), in: .split(.right))
        XCTAssertEqual(s.selectedChapterID, "02")
        var told = 0
        let hook = s.workspace.changed
        s.workspace.changed = { told += 1; hook() }
        s.workspace.open(.sources, in: .nextPane)
        XCTAssertEqual(told, 1, "one change, told once")
        XCTAssertEqual(s.selectedChapterID, "02")
        // Another window in front: its chapter.
        let id = s.newWindow(with: .chapter("01"))
        s.activeWindow = id
        XCTAssertEqual(s.selectedChapterID, "01")
        s.activeWindow = nil
        XCTAssertEqual(s.selectedChapterID, "01", "the main window shows Sources in the pane one is in: still in the chapter left")
    }

    func testAnOldStateFileThatOnlyNamesTheLastChapterOpensIt() throws {
        let root = try twoChapters()
        let store = BookStore(root: root)
        try FileManager.default.createDirectory(at: store.mussetDir, withIntermediateDirectories: true)
        try Data(#"{"lastChapter":"02","selections":{"02":3}}"#.utf8).write(to: store.stateURL)
        let s = BookSession(root: root, manifest: try store.loadManifest())
        XCTAssertEqual(s.selectedChapterID, "02")
        XCTAssertEqual(s.savedSelection, 3)
        s.open(OverviewTab.synopsis.tab, in: .newTab)
        s.close()
        // Written again, the layout says it: the chapter of the pane one was in, even behind another page.
        let kept = try String(contentsOf: store.stateURL, encoding: .utf8)
        XCTAssertFalse(kept.contains("lastChapter"), kept)
        XCTAssertEqual(store.loadState().layout?.lastChapter, "02")
        let again = BookSession(root: root, manifest: s.manifest)
        XCTAssertEqual(again.selectedChapterID, "02")
        XCTAssertEqual(again.workspace.activeTab, OverviewTab.synopsis.tab)
    }

    /// A layout kept before Overview took in the Synopsis, the plot grid, and gave up the debate and its settings
    /// page: every tab of it still opens, on the place that took it over.
    func testALayoutKeptWithTheOldTabKindsOpensOnTheirNewPlaces() throws {
        let old = #"""
        {"focusedPane":"B","root":{"split":{"vertical":false,"fractions":[0.5,0.5],"children":[
          {"pane":{"_0":{"id":"A","active":1,"tabs":[{"chapter":{"_0":"01"}},{"plotGrid":{}},{"synopsis":{}},{"sources":{}}]}}},
          {"pane":{"_0":{"id":"B","active":0,"tabs":[{"synopsis":{}},{"overview":{"_0":"debate"}},{"overview":{"_0":"settings"}},{"special":{"_0":"cover"}}]}}}]}}}
        """#
        let saved = try JSONDecoder().decode(Workspace.Saved.self, from: Data(old.utf8))
        XCTAssertEqual(saved.root.panes.map(\.tabs), [
            [.chapter("01"), .overview("grid"), .overview("synopsis"), .sources],
            // The book's settings are a page of Overview again: a layout kept on them opens them.
            [.overview("synopsis"), .debate, .overview("settings"), .special("cover")],
        ])
        // Overview is one tab in a pane: the page that was shown stays, else the first.
        let w = Workspace(saved: saved, keep: { _ in true })
        XCTAssertEqual(w.panes.map(\.tabs), [[.chapter("01"), .overview("grid"), .sources], [.overview("synopsis"), .debate, .special("cover")]])
        XCTAssertEqual(w.panes.map(\.activeTab), [.overview("grid"), .overview("synopsis")])
        XCTAssertEqual(w.focusedPane, "B")
        // Kept again, it reads back the same, in today's words.
        let again = try JSONDecoder().decode(Workspace.Saved.self, from: JSONEncoder().encode(w.saved))
        XCTAssertEqual(again, w.saved)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(w.saved), as: UTF8.self).contains("plotGrid"))

        // The same in a whole state file: the main window's layout, another window's, a named layout.
        let root = try twoChapters()
        let store = BookStore(root: root)
        try FileManager.default.createDirectory(at: store.mussetDir, withIntermediateDirectories: true)
        let pane = #"{"focusedPane":"A","root":{"pane":{"_0":{"id":"A","active":1,"tabs":[{"chapter":{"_0":"01"}},{"plotGrid":{}}]}}}}"#
        try Data(#"{"selections":{},"layout":\#(pane),"windows":{"W":\#(pane)},"layouts":{"Plan":\#(pane)}}"#.utf8).write(to: store.stateURL)
        let state = store.loadState()
        XCTAssertEqual(state.layout?.root.panes.first?.tabs, [.chapter("01"), .overview("grid")])
        XCTAssertEqual(state.windows?["W"]?.root.panes.first?.activeTab, .overview("grid"))
        XCTAssertEqual(state.layouts?["Plan"]?.root.panes.first?.activeTab, .overview("grid"))
        let s = BookSession(root: root, manifest: try store.loadManifest())
        XCTAssertEqual(s.workspace.activeTab, OverviewTab.grid.tab)
    }

    /// Overview is one tab: opened on another page, the tab turns to it rather than a second one opening.
    func testOverviewIsOneTabWhateverItsPage() {
        let w = Workspace()
        w.open(.chapter("01"))
        w.open(OverviewTab.summary.tab, in: .newTab)
        w.open(OverviewTab.grid.tab)
        XCTAssertEqual(w.focused?.tabs, [.chapter("01"), .overview("grid")])
        w.open(OverviewTab.synopsis.tab, in: .newTab)
        XCTAssertEqual(w.focused?.tabs, [.chapter("01"), .overview("synopsis")])
        XCTAssertEqual(w.activeTab, .overview("synopsis"))
    }
}
