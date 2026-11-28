import SwiftUI

/// What a command acts on: the app, the editor in front, and the way to open the Settings window.
@MainActor
struct CommandContext {
    let app: AppState
    let bridge: EditorBridge
    var openSettings: () -> Void = {}
}

/// A keyboard shortcut, declared once: the menus bind it, the palette and the tooltips print it.
struct Shortcut: Equatable {
    let key: Character
    let modifiers: EventModifiers

    init(_ key: Character, _ modifiers: EventModifiers = .command) { self.key = key; self.modifiers = modifiers }

    var keyboardShortcut: KeyboardShortcut { KeyboardShortcut(KeyEquivalent(key), modifiers: modifiers) }

    /// As macOS prints it: ⌃⌥⇧⌘, then the key.
    var glyphs: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        switch key {
        case KeyEquivalent.return.character: out += "↩"
        case KeyEquivalent.delete.character: out += "⌫"
        case KeyEquivalent.tab.character: out += "⇥"
        case KeyEquivalent.rightArrow.character: out += "→"
        case KeyEquivalent.leftArrow.character: out += "←"
        default: out += String(key).uppercased()
        }
        return out
    }

    static func == (a: Shortcut, b: Shortcut) -> Bool { a.key == b.key && a.modifiers == b.modifiers }
}

/// One command of Musset: its name, its shortcut, when it applies and what it does. The menus, the command
/// bar (⌘K) and the tooltips all read `AppCommand.all`, so a command has one name and one shortcut everywhere.
@MainActor
struct AppCommand: Identifiable {
    /// Where the command bar files it.
    enum Group: Int, CaseIterable {
        case go, view, write, format, revise, panes, book, app
        var label: String {
            switch self {
            case .go: L("Go to")
            case .view: L("View")
            case .write: L("Write")
            case .format: L("Format")
            case .revise: L("Revise")
            case .panes: L("Panes")
            case .book: L("Book")
            case .app: "Musset"
            }
        }
    }

    /// When a command applies; the menus grey it out otherwise, and the command bar leaves it out.
    enum Gate {
        case always
        /// A book is open, even under Home.
        case session
        /// A book is open and in front.
        case book
        /// The pane one is in shows a chapter.
        case editor
        /// The pane one is in shows a chapter of several scenes, or its scene cards, which can always be left.
        case scenes
        /// An editor mode: it needs the editor, but one that is on can always be switched off.
        case mode
        /// The pane one is in shows a tab.
        case tab
        /// What asks an AI: a book in front and an AI engine on.
        case ai
        /// The AI reader's tab: as `ai`, or while it still offers to set one up.
        case aiHome
    }

    let id: String
    let group: Group
    private let name: () -> String
    /// The name while the command is on, when it changes (« Show Sidebar » / « Hide Sidebar »).
    private let onName: (() -> String)?
    var shortcut: Shortcut?
    var icon = "circle"
    var gate = Gate.always
    /// Whether it is on now: a mode, a panel that shows.
    var isOn: ((CommandContext) -> Bool)?
    /// Shown with a checkmark in the menus rather than under two names.
    var check = false
    /// What it opens in a pane, for « Open Beside ».
    var tab: PaneTab?
    /// Run inside an animation by the command bar (panels sliding in). Off for what repaints the whole window.
    var animated = true
    /// The command bar itself is the only command the bar does not list.
    var inPalette = true
    /// A name that says one of the book's levels: it follows the open book's own words (« New Entry Here »).
    var bookName: ((BookWords) -> String)? = nil
    let run: (CommandContext) -> Void

    init(_ id: String, _ group: Group, _ name: @autoclosure @escaping () -> String, on onName: (() -> String)? = nil,
         _ shortcut: Shortcut? = nil, icon: String = "circle", gate: Gate = .always, isOn: ((CommandContext) -> Bool)? = nil,
         check: Bool = false, tab: PaneTab? = nil, animated: Bool = true, inPalette: Bool = true,
         bookName: ((BookWords) -> String)? = nil, run: @escaping (CommandContext) -> Void) {
        self.id = id; self.group = group; self.name = name; self.onName = onName; self.shortcut = shortcut
        self.icon = icon; self.gate = gate; self.isOn = isOn; self.check = check; self.tab = tab
        self.animated = animated; self.inPalette = inPalette; self.bookName = bookName; self.run = run
    }

    /// Every name it can show, in the interface's language.
    var titles: [String] { [name()] + (onName.map { [$0()] } ?? []) }

    /// Its name now.
    func title(_ c: CommandContext) -> String {
        if !check, let onName, isOn?(c) == true { return onName() }
        if let bookName, let session = c.app.current { return bookName(session.words) }
        return name()
    }

    func applies(_ c: CommandContext) -> Bool {
        switch gate {
        case .always: true
        case .session: c.app.current != nil
        case .book: c.app.hasBook
        case .editor: c.app.hasEditor
        case .mode: c.app.hasEditor || isOn?(c) == true
        case .scenes: c.app.hasScenes || isOn?(c) == true
        case .tab: c.app.workspace?.activeTab != nil
        case .ai: c.app.hasBook && AIStatus.shared.isOn
        case .aiHome: c.app.hasBook && AIHome.shown
        }
    }

    // MARK: Looking one up

    static let byID: [String: AppCommand] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// « ⇧⌘F », or nothing when the command has no shortcut.
    static func glyphs(_ id: String) -> String { byID[id]?.shortcut?.glyphs ?? "" }

    /// A tooltip: the command's name, without its ellipsis, and its shortcut: « Bold (⌘B) ».
    static func hint(_ id: String) -> String { hint((byID[id]?.titles.first ?? "").titled, id) }

    /// A tooltip in other words than the command's name, with its shortcut.
    static func hint(_ text: String, _ id: String) -> String {
        let keys = glyphs(id)
        return keys.isEmpty ? text : "\(text) (\(keys))"
    }

    /// The command's item in a menu: a button, or a checkmark for a mode, with its shortcut, greyed out when it does not apply.
    @ViewBuilder static func menuItem(_ id: String, _ c: CommandContext) -> some View {
        if let cmd = byID[id] {
            if cmd.check, let isOn = cmd.isOn {
                Toggle(cmd.title(c), isOn: Binding(get: { isOn(c) }, set: { _ in cmd.run(c) }))
                    .keyboardShortcut(cmd.shortcut?.keyboardShortcut).disabled(!cmd.applies(c))
            } else {
                Button(cmd.title(c)) { cmd.run(c) }
                    .keyboardShortcut(cmd.shortcut?.keyboardShortcut).disabled(!cmd.applies(c))
            }
        }
    }

    // MARK: The table

    static let all: [AppCommand] = go + view + write + format + revise + panes + book + app

    private static func inspector(_ id: String, _ name: @autoclosure @escaping () -> String, _ key: Character, _ tab: InspectorTab, gate: Gate = .book) -> AppCommand {
        AppCommand(id, .view, name(), Shortcut(key), icon: tab.icon, gate: gate) { c in withAnimation { c.app.toggleInspector(tab) } }
    }

    private static let go: [AppCommand] = [
        AppCommand("go.home", .go, L("All Books"), Shortcut("h", [.command, .shift]), icon: "house") { $0.app.showHome = true },
        AppCommand("go.overview", .go, L("Overview"), icon: "rectangle.grid.1x2", gate: .book, tab: .overview(OverviewTab.summary.rawValue)) { $0.app.open(OverviewTab.summary.tab) },
        AppCommand("go.synopsis", .go, L("Synopsis"), icon: "text.alignleft", gate: .book, tab: OverviewTab.synopsis.tab) { $0.app.open(OverviewTab.synopsis.tab) },
        AppCommand("go.debate", .go, L("Debate"), icon: "person.3", gate: .ai, tab: .debate) { $0.app.open(.debate) },
        AppCommand("go.sources", .go, L("Sources"), icon: "books.vertical", gate: .book, tab: .sources) { $0.app.open(.sources) },
    ]

    private static let view: [AppCommand] = [
        AppCommand("view.blame", .view, L("Who Wrote What"), on: { L("Hide Who Wrote What") }, Shortcut("b", [.command, .option]),
                   icon: "person.2.wave.2", gate: .editor, isOn: { $0.bridge.blameOn }) { $0.bridge.blameOn.toggle() },
        AppCommand("view.sidebar", .view, L("Show Sidebar"), on: { L("Hide Sidebar") }, Shortcut("1"), icon: "sidebar.left", gate: .book,
                   isOn: { $0.app.showSidebar }) { $0.app.showSidebar.toggle() },
        inspector("view.notes", L("Notes"), "2", .edits),
        inspector("view.chat", L("AI Reader"), "3", .chat, gate: .aiHome),
        inspector("view.stats", L("Stats"), "4", .stats),
        AppCommand("view.grid", .view, L("Plot Grid"), on: { L("Hide Plot Grid") }, Shortcut("5"), icon: "tablecells", gate: .book,
                   isOn: { $0.app.activeTab == OverviewTab.grid.tab }, tab: OverviewTab.grid.tab) { $0.app.activeTab == OverviewTab.grid.tab ? $0.app.showChapter() : $0.app.open(OverviewTab.grid.tab) },
        AppCommand("view.sceneCards", .view, L("Scene Cards"), Shortcut("l", [.command, .control]), icon: "square.grid.2x2", gate: .scenes,
                   isOn: { $0.app.workspace?.focusedSceneCards != nil }, check: true, bookName: { $0.sceneCards }) { $0.app.workspace?.toggleSceneCards() },
        inspector("view.plan", L("Plan"), "6", .plan),
        inspector("view.history", L("History"), "7", .history),
        AppCommand("view.formatBar", .view, L("Show Format Bar"), icon: "textformat", isOn: { $0.app.formatBar }, check: true) { $0.app.formatBar.toggle() },
        AppCommand("view.focus", .view, L("Focus Mode"), Shortcut("d", [.command, .shift]), icon: "eye", gate: .mode,
                   isOn: { $0.app.focusMode }, check: true) { $0.app.focusMode.toggle() },
        AppCommand("view.typewriter", .view, L("Typewriter Scrolling"), Shortcut("t", [.command, .shift]), icon: "keyboard", gate: .mode,
                   isOn: { $0.app.typewriter }, check: true) { $0.app.typewriter.toggle() },
        AppCommand("view.kiosk", .view, L("Kiosk Mode"), Shortcut("k", [.command, .control]), icon: "lock.display",
                   isOn: { $0.app.kiosk }, check: true) { $0.app.kiosk.toggle() },
        AppCommand("view.ultraFocus", .view, L("Ultra Focus"), Shortcut("u", [.command, .control]), icon: "forward.end", gate: .session) { UltraFocus.shared.toggle($0.app) },
        // Line numbers and the minimap: in Settings ▸ Editor and here, not in the menu bar, so without a shortcut.
        AppCommand("view.lineNumbers", .view, L("Line Numbers"), icon: "list.number", gate: .mode,
                   isOn: { $0.app.lineNumbers }, check: true) { $0.app.lineNumbers.toggle() },
        AppCommand("view.minimap", .view, L("Minimap"), icon: "sidebar.squares.right", gate: .mode,
                   isOn: { $0.app.minimap }, check: true) { $0.app.minimap.toggle() },
        AppCommand("view.reading", .view, L("Reading Mode"), Shortcut("r", [.command, .shift]), icon: "book", gate: .mode,
                   isOn: { $0.app.reviewMode }, check: true) { $0.app.reviewMode.toggle() },
        AppCommand("view.repetitions", .view, L("Repetitions"), Shortcut("r", [.command, .control]), icon: "repeat", gate: .mode,
                   isOn: { $0.app.repetitions }, check: true) { $0.app.repetitions.toggle() },
        AppCommand("view.light", .view, L("Light Mode"), icon: Appearance.light.icon, animated: false) { _ in Appearance.light.choose() },
        AppCommand("view.dark", .view, L("Dark Mode"), icon: Appearance.dark.icon, animated: false) { _ in Appearance.dark.choose() },
        AppCommand("view.system", .view, L("Follow macOS Appearance"), icon: Appearance.system.icon, animated: false) { _ in Appearance.system.choose() },
    ]

    private static let write: [AppCommand] = [
        AppCommand("find.find", .write, L("Find…"), Shortcut("f"), icon: "magnifyingglass", gate: .editor) { $0.bridge.openFind() },
        AppCommand("find.replace", .write, L("Find and Replace…"), Shortcut("f", [.command, .option]), icon: "arrow.left.arrow.right", gate: .editor) { $0.bridge.openFind(replace: true) },
        AppCommand("find.next", .write, L("Find Next"), Shortcut("g"), icon: "chevron.down", gate: .editor) { $0.bridge.findNext() },
        AppCommand("find.previous", .write, L("Find Previous"), Shortcut("g", [.command, .shift]), icon: "chevron.up", gate: .editor) { $0.bridge.findNext(forward: false) },
        AppCommand("write.proofNext", .write, L("Next Proofreading Suggestion"), Shortcut(";"), icon: "text.badge.checkmark", gate: .editor) { _ in
            NotificationCenter.default.post(name: .mussetProofread, object: nil)
        },
        AppCommand("write.note", .write, L("Add Note…"), Shortcut("n", [.command, .option]), icon: "plus.bubble", gate: .editor) { $0.bridge.textView?.beginNote() },
        AppCommand("write.scene", .write, L("New Scene Here"), Shortcut("n", [.command, .shift]), icon: "plus.square.dashed", gate: .editor,
                   bookName: { $0.newSceneHere }) { $0.bridge.textView?.beginScene() },
        AppCommand("write.dictionary", .write, L("Dictionary & Exceptions…"), icon: "character.book.closed", gate: .book) { $0.app.showProofExceptions = true },
        AppCommand("write.typography", .write, L("Apply Typography to the Whole Book…"), icon: "textformat", gate: .session) { $0.app.applyTypographyToBook() },
    ]

    private static let format: [AppCommand] = [
        AppCommand("format.bold", .format, L("Bold"), Shortcut("b"), icon: "bold", gate: .editor) { $0.bridge.textView?.toggleInline("**") },
        AppCommand("format.italic", .format, L("Italic"), Shortcut("i"), icon: "italic", gate: .editor) { $0.bridge.textView?.toggleInline("*") },
        AppCommand("format.h1", .format, L("Heading 1"), Shortcut("1", [.command, .option]), icon: "textformat.size.larger", gate: .editor) { $0.bridge.textView?.setHeading(1) },
        AppCommand("format.h2", .format, L("Heading 2"), Shortcut("2", [.command, .option]), icon: "textformat.size", gate: .editor) { $0.bridge.textView?.setHeading(2) },
        AppCommand("format.h3", .format, L("Heading 3"), Shortcut("3", [.command, .option]), icon: "textformat.size.smaller", gate: .editor) { $0.bridge.textView?.setHeading(3) },
        AppCommand("format.body", .format, L("Body Text"), Shortcut("0", [.command, .option]), icon: "text.justify.left", gate: .editor) { $0.bridge.textView?.setHeading(0) },
        AppCommand("format.quote", .format, L("Quotation"), Shortcut("'", [.command, .option]), icon: "text.quote", gate: .editor) { $0.bridge.textView?.toggleQuote() },
        AppCommand("format.footnote", .format, L("Footnote"), Shortcut("6", [.command, .option]), icon: "textformat.superscript", gate: .editor) { $0.bridge.textView?.insertFootnote() },
    ]

    private static let revise: [AppCommand] = [
        AppCommand("revise.mode", .revise, L("Revision Mode"), Shortcut("e", [.command, .shift]), icon: "pencil.line", gate: .editor,
                   isOn: { $0.bridge.trackChanges }, check: true) { $0.bridge.trackChanges.toggle() },
        // Revision mode first: its bar is what asks for the comment.
        AppCommand("revise.comment", .revise, L("Comment…"), Shortcut("m", [.command, .shift]), icon: "text.bubble", gate: .editor) { c in
            c.bridge.trackChanges = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NotificationCenter.default.post(name: .mussetAskComment, object: nil) }
        },
        AppCommand("revise.next", .revise, L("Next Correction"), Shortcut("]", [.command, .option]), icon: "arrow.down.to.line", gate: .editor) { $0.bridge.textView?.nextRevision() },
        AppCommand("revise.accept", .revise, L("Accept Correction"), Shortcut(KeyEquivalent.return.character, [.command, .option]), icon: "checkmark", gate: .editor) {
            $0.bridge.textView?.decideRevision(accept: true)
        },
        AppCommand("revise.reject", .revise, L("Reject Correction"), Shortcut(KeyEquivalent.delete.character, [.command, .option]), icon: "xmark", gate: .editor) {
            $0.bridge.textView?.decideRevision(accept: false)
        },
        AppCommand("revise.acceptAll", .revise, L("Accept All Corrections"), icon: "checkmark.circle", gate: .editor) { $0.bridge.textView?.decideRevision(accept: true, all: true) },
        AppCommand("revise.rejectAll", .revise, L("Reject All Corrections…"), icon: "xmark.circle", gate: .editor) { c in
            RejectAll.confirm(c.bridge.pendingRevisions) { c.bridge.textView?.decideRevision(accept: false, all: true) }
        },
    ]

    private static let panes: [AppCommand] = [
        AppCommand("panes.closeTab", .panes, L("Close Tab"), Shortcut("w"), icon: "xmark") { c in
            if let w = c.app.workspace, w.canCloseTab { w.closeActiveTab() } else { NSApp.keyWindow?.performClose(nil) }
        },
        AppCommand("panes.closeWindow", .panes, L("Close Window"), Shortcut("w", [.command, .shift]), icon: "xmark.rectangle") { _ in NSApp.keyWindow?.performClose(nil) },
        AppCommand("panes.openBeside", .panes, L("Open Beside…"), Shortcut("o", [.command, .shift]), icon: "rectangle.split.2x1", gate: .session) { c in
            c.app.openBeside = true; c.app.showQuickOpen = true
        },
        AppCommand("panes.splitRight", .panes, L("Split Right"), Shortcut("\\"), icon: "rectangle.split.2x1", gate: .tab) { $0.app.workspace?.splitActive(.right) },
        AppCommand("panes.splitDown", .panes, L("Split Down"), Shortcut("\\", [.command, .option]), icon: "rectangle.split.1x2", gate: .tab) { $0.app.workspace?.splitActive(.bottom) },
        AppCommand("panes.nextTab", .panes, L("Next Tab"), Shortcut(KeyEquivalent.tab.character, .control), icon: "arrow.right.square") { c in c.app.workspace?.cycleTab(by: 1) },
        AppCommand("panes.previousTab", .panes, L("Previous Tab"), Shortcut(KeyEquivalent.tab.character, [.control, .shift]), icon: "arrow.left.square") { c in
            c.app.workspace?.cycleTab(by: -1)
        },
        AppCommand("panes.nextPane", .panes, L("Next Pane"), Shortcut(KeyEquivalent.rightArrow.character, [.command, .option]), icon: "arrow.right.to.line") { c in
            c.app.workspace?.cyclePane(by: 1)
        },
        AppCommand("panes.previousPane", .panes, L("Previous Pane"), Shortcut(KeyEquivalent.leftArrow.character, [.command, .option]), icon: "arrow.left.to.line") { c in
            c.app.workspace?.cyclePane(by: -1)
        },
        AppCommand("panes.saveLayout", .panes, L("Save the Layout…"), icon: "rectangle.3.group", gate: .session) { $0.app.namingLayout = true },
    ]

    private static let book: [AppCommand] = [
        AppCommand("book.search", .book, L("Search the Book…"), Shortcut("f", [.command, .shift]), icon: "magnifyingglass", gate: .book) { $0.app.openSearch() },
        AppCommand("book.settings", .book, L("Book Settings…"), Shortcut(",", [.command, .option]), icon: "gearshape", gate: .session) { $0.app.showSettings() },
        AppCommand("book.special", .book, L("Cover & Special Pages"), icon: "rectangle.portrait", gate: .session) { $0.app.open(SpecialPage.cover.tab) },
        AppCommand("book.export", .book, L("Export…"), Shortcut("e"), icon: "square.and.arrow.up", gate: .session) { $0.app.showExport = true },
        AppCommand("book.wordReview", .book, L("Bring In a Corrected Word File…"), icon: "doc.badge.arrow.up", gate: .session) { $0.app.showWordReview = true },
        AppCommand("book.share", .book, L("Share This Book…"), icon: "person.2", gate: .session) { $0.app.showReaders() },
        AppCommand("book.invite", .book, L("Invite Someone to This Book…"), icon: "person.badge.plus", gate: .session) { $0.app.showReaders(inviting: true) },
        AppCommand("book.rubric", .book, L("Rubric…"), icon: "list.bullet.clipboard", gate: .ai) { $0.app.showRubric = true },
        AppCommand("book.newVersion", .book, L("New Version of This Chapter…"), icon: "square.on.square", gate: .book,
                   bookName: { $0.newVersion }) { $0.app.showTryVersion = true },
        AppCommand("book.history", .book, L("The Book’s History"), icon: "point.topleft.down.to.point.bottomright.curvepath", gate: .book, tab: .story) { $0.app.open(.story) },
        AppCommand("book.newTrack", .book, L("New Track…"), icon: "arrow.triangle.branch", gate: .book) { $0.app.newPiste = TrackStart() },
        AppCommand("book.milestone", .book, L("Set a Milestone…"), icon: "flag", gate: .book) { $0.app.newJalon = TrackStart() },
        // Everything written is saved as one goes; this also puts it in the book's history at once.
        AppCommand("book.save", .book, L("Save Now"), Shortcut("s"), icon: "checkmark.seal", gate: .session) { c in
            c.app.current?.flushSave(); c.app.current?.commitNow("musset: snapshot")
        },
    ]

    private static let app: [AppCommand] = [
        AppCommand("app.palette", .app, L("Command Bar…"), Shortcut("k"), icon: "command", gate: .book, inPalette: false) { $0.app.showQuickOpen = true },
        AppCommand("app.capture", .app, L("Capture a Note…"), icon: "square.and.pencil") { _ in CaptureController.shared.toggle() },
        AppCommand("app.newBook", .app, L("New Book…"), Shortcut("n"), icon: "plus.rectangle.on.folder") { $0.app.showNewBook = true },
        AppCommand("app.openBook", .app, L("Open Book Folder…"), Shortcut("o"), icon: "folder") { $0.app.addBookViaPanel() },
        AppCommand("app.account", .app, L("Sign In to Musset…"), on: { L("Musset Account…") }, icon: "person.crop.circle",
                   isOn: { _ in Collab.shared.signedIn }) { $0.app.showAccount() },
        AppCommand("app.settings", .app, L("Settings…"), Shortcut(","), icon: "gearshape.2") { $0.openSettings() },
        AppCommand("app.updates", .app, L("Check for Updates…"), icon: "arrow.down.circle") { _ in Updates.shared.check() },
        AppCommand("app.feedback", .app, L("Send Feedback…"), icon: "bubble.left.and.text.bubble.right") { $0.app.showFeedback = true },
    ]
}

/// « Reject All »: one question before it happens, whichever place asks (the Format menu, the command bar,
/// the title bar, the Notes tab).
@MainActor
enum RejectAll {
    static func confirm(_ count: Int, then reject: @escaping () -> Void) {
        guard count > 0 else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = L("Reject these \(count) corrections?")
        alert.informativeText = L("The text goes back to what it was before them.")
        alert.addButton(withTitle: L("Reject")).hasDestructiveAction = true
        alert.addButton(withTitle: L("Cancel"))
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { reject() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            reject()
        }
    }
}
