import SwiftUI

@main
struct MussetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var app = AppState()
    @State private var bridge = EditorBridge()
    @State private var chat = ChatModel()
    @State private var pangram = PangramModel()
    @State private var proof = AutoProofreader()
    @State private var annotator = Annotator()

    init() { _ = GitService.start; Typefaces.register(); TaskModels.migrate(); Updates.shared.start() }

    /// A command's menu item, from the one table of commands.
    private func item(_ id: String) -> some View { AppCommand.menuItem(id, CommandContext(app: app, bridge: bridge)) }

    var body: some Scene {
        WindowGroup {
            ContentView(app: app, bridge: bridge, chat: chat, pangram: pangram, proof: proof, annotator: annotator)
                .frame(minWidth: 720, minHeight: 480)
                .font(.ui(13))
                .onAppear {
                    bridge.proof = proof
                    bridge.annotator = annotator
                    bridge.openSheet = { [app] path in app.open(.sheet(path)) }
                    bridge.renameEntry = { [app] path in app.renaming = .init(path: path) }
                    bridge.openSources = { [app] in app.open(.sources) }
                    proof.bridge = bridge
                    delegate.app = app; delegate.chat = chat; delegate.proof = proof
                }
                .task { await AIStatus.shared.detect() }
                .onOpenURL { app.open(mussetURL: $0) }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Every item below is a row of `AppCommand.all`: its name, shortcut, and when it applies are set there.
            CommandGroup(replacing: .newItem) {
                item("go.home")
                item("app.capture")
                Divider()
                item("app.newBook")
                item("app.openBook")
            }
            PaneCommands(app: app, bridge: bridge)
            CommandGroup(after: .appInfo) {
                item("app.updates")
            }
            CommandGroup(after: .appSettings) {
                item("app.account")
            }
            CommandGroup(after: .newItem) {
                item("app.palette")
                item("book.settings")
                item("book.special")
                item("book.export")
                item("book.wordReview")
                Divider()
                ForEach(Array(app.books.prefix(9).enumerated()), id: \.element.path) { i, b in
                    Button(b.title) { app.switchToBook(index: i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                }
            }
            CommandGroup(after: .textEditing) {
                Section {
                    item("find.find")
                    item("find.replace")
                    item("find.next")
                    item("find.previous")
                    item("book.search")
                }
            }
            CommandMenu(L("Format")) {
                item("format.bold")
                item("format.italic")
                Divider()
                item("format.h1")
                item("format.h2")
                item("format.h3")
                item("format.body")
                Divider()
                item("format.quote")
                item("format.footnote")
                Divider()
                item("revise.mode")
                item("revise.comment")
                item("revise.next")
                item("revise.accept")
                item("revise.reject")
                item("revise.acceptAll")
                item("revise.rejectAll")
                Divider()
                item("view.formatBar")
            }
            CommandMenu(L("Write")) {
                item("view.focus")
                item("view.typewriter")
                item("view.kiosk")
                item("view.ultraFocus")
                item("view.reading")
                item("view.repetitions")
                Divider()
                item("write.proofNext")
                item("write.note")
                item("write.scene")
                item("write.dictionary")
                item("write.typography")
                item("book.save")
            }
            CommandGroup(after: .sidebar) {
                item("view.blame")
                item("view.sidebar")
                item("view.notes")
                item("view.chat")
                item("view.stats")
                item("view.grid")
                item("view.sceneCards")
                item("view.plan")
                item("view.history")
            }
            #if DEBUG
            PageDemoCommands()
            #endif
        }

        // The book's other windows: a tab torn off, « Open in New Window ».
        WindowGroup(id: PaneWindow.sceneID, for: WindowRef.self) { $ref in
            PaneWindow(app: app, bridge: bridge, proof: proof, ref: ref)
                .frame(minWidth: 420, minHeight: 320)
                .font(.ui(13))
        }
        .defaultSize(width: 760, height: 820)

        Settings { SettingsView(app: app).font(.ui(13)) }
        #if DEBUG
        Window("Reading Engine Demo", id: PageDemo.windowID) { PageDemo() }.defaultSize(width: 1440, height: 900)
        #endif
    }
}

/// ⌘W closes a tab; the Panes menu splits, cycles and opens beside.
struct PaneCommands: Commands {
    let app: AppState
    let bridge: EditorBridge

    private func item(_ id: String) -> some View { AppCommand.menuItem(id, CommandContext(app: app, bridge: bridge)) }

    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            item("panes.closeTab")
            item("panes.closeWindow")
        }
        CommandMenu(L("Panes")) {
            item("panes.openBeside")
            Divider()
            item("panes.splitRight")
            item("panes.splitDown")
            Divider()
            item("panes.nextTab")
            item("panes.previousTab")
            item("panes.nextPane")
            item("panes.previousPane")
            Divider()
            item("panes.saveLayout")
            if let session = app.current, !session.layoutNames.isEmpty {
                Menu(L("Layouts")) {
                    ForEach(session.layoutNames, id: \.self) { name in Button(name) { session.applyLayout(named: name) } }
                    Divider()
                    Menu(L("Delete")) {
                        ForEach(session.layoutNames, id: \.self) { name in Button(name) { session.deleteLayout(named: name) } }
                    }
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var app: AppState?
    var chat: ChatModel?
    var proof: AutoProofreader?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { Appearance.apply() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // What was written in Ultra Focus goes into the book before anything else is saved.
            UltraFocus.shared.finish(showSummary: false)
            chat?.persist()
            proof?.save()
            app?.shutdown()
            LanguageToolServer.stopNow()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Windows closing as the app quits stay with the book, to open again.
        MainActor.assumeIsolated { app?.quitting = true }
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
