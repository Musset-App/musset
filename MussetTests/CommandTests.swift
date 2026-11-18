import XCTest
import SwiftUI
@testable import Musset

/// The one table of commands: named in every language, one shortcut each, and all of it in the command bar.
@MainActor
final class CommandTests: XCTestCase {
    private func table(_ lang: UILang) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.main.url(forResource: lang.rawValue, withExtension: "json"), "\(lang.rawValue).json is not in the app")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    /// A book in a temporary folder, open in front with its first chapter in the pane.
    private func openBook() throws -> (AppState, () -> Void) {
        let d = UserDefaults.standard
        let saved = (d.stringArray(forKey: "libraryPaths"), d.string(forKey: "lastBook"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-commands-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "The gate was open.".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try BookStore(root: root).saveManifest(BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "One")]))
        let app = AppState()
        app.openBook(root)
        try XCTUnwrap(app.current).open("01")
        return (app, {
            d.set(saved.0, forKey: "libraryPaths"); d.set(saved.1, forKey: "lastBook")
            try? FileManager.default.removeItem(at: root)
        })
    }

    func testEveryCommandIsNamedInSixLanguages() throws {
        let d = UserDefaults.standard
        let saved = d.string(forKey: UILang.key)
        defer { d.set(saved, forKey: UILang.key) }
        // In English a command's name is its key in the tables.
        d.set(UILang.en.rawValue, forKey: UILang.key)
        let keys = AppCommand.all.flatMap { cmd in cmd.titles.map { (cmd.id, $0) } }
        XCTAssertEqual(Set(AppCommand.all.map(\.id)).count, AppCommand.all.count, "one row per id")
        for (id, key) in keys { XCTAssertFalse(key.trimmingCharacters(in: .whitespaces).isEmpty, id) }
        for lang in [UILang.fr, .de, .es, .it, .ptBR, .ptPT] {
            let t = try table(lang)
            for (id, key) in keys where key != "Musset" {
                let name = (t[key] as? String ?? "").trimmingCharacters(in: .whitespaces)
                XCTAssertFalse(name.isEmpty, "\(lang.rawValue) has no name for \(id): \(key)")
            }
            d.set(lang.rawValue, forKey: UILang.key)
            for cmd in AppCommand.all { for title in cmd.titles { XCTAssertFalse(title.isEmpty, "\(lang.rawValue): \(cmd.id)") } }
            for g in AppCommand.Group.allCases { XCTAssertFalse(g.label.isEmpty) }
        }
    }

    func testNoTwoCommandsShareAShortcut() {
        var seen: [String: String] = [:]
        for cmd in AppCommand.all {
            guard let s = cmd.shortcut else { continue }
            // Letters are told apart by ⇧, never by their case.
            XCTAssertEqual(String(s.key), String(s.key).lowercased(), cmd.id)
            if let other = seen[s.glyphs] { XCTFail("\(s.glyphs) is both \(other) and \(cmd.id)") }
            seen[s.glyphs] = cmd.id
        }
        XCTAssertEqual(AppCommand.glyphs("book.search"), "⇧⌘F")
        XCTAssertEqual(AppCommand.glyphs("revise.accept"), "⌥⌘↩")
        XCTAssertEqual(AppCommand.glyphs("revise.reject"), "⌥⌘⌫")
        XCTAssertEqual(AppCommand.glyphs("view.kiosk"), "⌃⌘K")
        XCTAssertEqual(AppCommand.glyphs("panes.nextTab"), "⌃⇥")
        XCTAssertEqual(AppCommand.glyphs("format.h1"), "⌥⌘1")
        XCTAssertEqual(AppCommand.glyphs("app.capture"), "")
    }

    func testThePaletteListsEveryCommandThatApplies() throws {
        let (app, cleanUp) = try openBook()
        defer { cleanUp() }
        let c = CommandContext(app: app, bridge: EditorBridge())
        XCTAssertTrue(app.hasBook && app.hasEditor)
        let listed = Set(CommandPalette.tableCommands(c).map(\.id))
        for cmd in AppCommand.all where cmd.applies(c) && cmd.id != "app.palette" {
            XCTAssertTrue(listed.contains(cmd.id), "the command bar lacks \(cmd.id)")
        }
        XCTAssertEqual(AppCommand.all.filter { !$0.inPalette }.map(\.id), ["app.palette"], "only the bar itself is left out")
        // What the bar lacked before the table.
        for id in ["go.overview", "go.home", "app.capture", "panes.splitRight", "panes.splitDown", "panes.nextPane", "panes.previousPane",
                   "panes.nextTab", "panes.closeTab", "panes.openBeside", "panes.saveLayout", "find.find", "revise.accept", "revise.reject",
                   "write.dictionary", "app.settings", "view.light", "view.dark", "view.system"] {
            XCTAssertTrue(listed.contains(id), id)
        }
        // Formatting has its own group.
        XCTAssertEqual(AppCommand.byID["format.bold"]?.group, .format)
    }

    func testCommandsFollowTheMenusGates() throws {
        let (app, cleanUp) = try openBook()
        defer { cleanUp() }
        let c = CommandContext(app: app, bridge: EditorBridge())
        // Under Home, nothing that needs the book in front or the editor.
        app.showHome = true
        let home = Set(CommandPalette.tableCommands(c).map(\.id))
        XCTAssertFalse(home.contains("format.bold"))
        XCTAssertFalse(home.contains("book.search"))
        XCTAssertFalse(home.contains("view.focus"))
        XCTAssertTrue(home.contains("book.export"), "as in the menu: a book is open")
        XCTAssertTrue(home.contains("app.newBook"))
        app.showHome = false
        // A page that is not a chapter: no editor commands, but a mode that is on can be switched off.
        app.open(OverviewTab.synopsis.tab)
        XCTAssertFalse(app.hasEditor)
        XCTAssertFalse(try XCTUnwrap(AppCommand.byID["format.bold"]).applies(c))
        XCTAssertFalse(try XCTUnwrap(AppCommand.byID["view.focus"]).applies(c))
        app.focusMode = true
        XCTAssertTrue(try XCTUnwrap(AppCommand.byID["view.focus"]).applies(c))
        app.focusMode = false
    }

    func testANameThatChangesWithItsState() throws {
        let d = UserDefaults.standard
        let saved = d.string(forKey: UILang.key)
        defer { d.set(saved, forKey: UILang.key) }
        d.set(UILang.en.rawValue, forKey: UILang.key)
        let (app, cleanUp) = try openBook()
        defer { cleanUp() }
        let c = CommandContext(app: app, bridge: EditorBridge())
        let sidebar = try XCTUnwrap(AppCommand.byID["view.sidebar"])
        app.showSidebar = true
        XCTAssertEqual(sidebar.title(c), "Hide Sidebar")
        sidebar.run(c)
        XCTAssertEqual(sidebar.title(c), "Show Sidebar")
        app.showSidebar = true
        XCTAssertEqual(AppCommand.hint("format.bold"), "Bold (⌘B)")
        XCTAssertEqual(AppCommand.hint("Next", "find.next"), "Next (⌘G)")
    }

    /// The inspector's tabs keep the names they are remembered under, whatever they are called on screen, and the
    /// places that were merged are each reached by one command.
    func testMergedPlacesKeepTheirStoredNamesAndTheirCommands() throws {
        XCTAssertEqual(InspectorTab(rawValue: "notes"), .edits)
        XCTAssertEqual(InspectorTab(rawValue: "chat"), .chat)
        XCTAssertEqual(InspectorTab(rawValue: "language"), .stats)
        XCTAssertEqual(InspectorTab.allCases.map(\.rawValue), ["notes", "chat", "language", "plan", "history"])
        XCTAssertEqual(AppCommand.glyphs("view.chat"), "⌘3")
        XCTAssertEqual(AppCommand.glyphs("view.grid"), "⌘5")
        XCTAssertEqual(AppCommand.byID["view.grid"]?.tab, OverviewTab.grid.tab)
        XCTAssertEqual(AppCommand.byID["go.synopsis"]?.tab, OverviewTab.synopsis.tab)
        XCTAssertEqual(AppCommand.byID["book.history"]?.tab, .story)
        XCTAssertEqual(AppCommand.byID["go.debate"]?.tab, .debate)
        XCTAssertNotNil(AppCommand.byID["book.rubric"])
        // Line numbers and the minimap left the menu bar for Settings ▸ Editor: still commands, without shortcuts.
        XCTAssertNil(AppCommand.byID["view.lineNumbers"]?.shortcut)
        XCTAssertNil(AppCommand.byID["view.minimap"]?.shortcut)

        let (app, cleanUp) = try openBook()
        defer { cleanUp() }
        let c = CommandContext(app: app, bridge: EditorBridge())
        AppCommand.byID["view.grid"]?.run(c)
        XCTAssertEqual(app.activeTab, .overview("grid"))
        AppCommand.byID["go.synopsis"]?.run(c)
        XCTAssertEqual(app.activeTab, .overview("synopsis"))
        XCTAssertEqual(app.workspace?.focused?.tabs.filter { $0.overview != nil }.count, 1, "Overview stays one tab")
        AppCommand.byID["book.history"]?.run(c)
        XCTAssertEqual(app.activeTab, .story)
        AppCommand.byID["view.grid"]?.run(c)
        AppCommand.byID["view.grid"]?.run(c)
        XCTAssertEqual(app.activeTab, .chapter("01"), "⌘5 again goes back to the chapter")
    }
}
