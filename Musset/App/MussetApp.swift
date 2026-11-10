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

    init() { Typefaces.register(); TaskModels.migrate() }

    var body: some Scene {
        WindowGroup {
            ContentView(app: app, bridge: bridge, chat: chat, pangram: pangram, proof: proof, annotator: annotator)
                .frame(minWidth: 720, minHeight: 480)
                .font(.ui(13))
                .onAppear {
                    bridge.proof = proof
                    bridge.annotator = annotator
                    proof.bridge = bridge
                    delegate.app = app; delegate.chat = chat; delegate.proof = proof
                }
                .task { await AIStatus.shared.detect() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L("All Books")) { app.showHome = true }.keyboardShortcut("h", modifiers: [.command, .shift])
                Button(L("Capture a Note…")) { CaptureController.shared.toggle() }
                Divider()
                Button(L("New Book…")) { app.showNewBook = true }.keyboardShortcut("n")
                Button(L("Open Book Folder…")) { app.addBookViaPanel() }.keyboardShortcut("o")
            }
            CommandGroup(after: .appSettings) {
                Button(Collab.shared.signedIn ? L("Musset Account…") : L("Sign In to Musset…")) { app.showAccount = true }
            }
            CommandGroup(after: .newItem) {
                Button(L("Command Bar…")) { app.showQuickOpen = true }.keyboardShortcut("k")
                Button(L("Book Settings…")) { app.showBookSettings = true }.keyboardShortcut(",", modifiers: [.command, .option]).disabled(app.current == nil)
                Button(L("Cover & Special Pages")) { app.specialPage = .cover }.disabled(app.current == nil)
                Button(L("Export…")) { app.showExport = true }.keyboardShortcut("e").disabled(app.current == nil)
                Button(L("Bring In a Corrected Word File…")) { app.showWordReview = true }.disabled(app.current == nil)
                Divider()
                ForEach(Array(app.books.prefix(9).enumerated()), id: \.element.path) { i, b in
                    Button(b.title) { app.switchToBook(index: i) }
                        .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .control])
                }
            }
            CommandGroup(after: .textEditing) {
                Section {
                    Button(L("Find…")) { bridge.openFind() }.keyboardShortcut("f")
                    Button(L("Find and Replace…")) { bridge.openFind(replace: true) }.keyboardShortcut("f", modifiers: [.command, .option])
                    Button(L("Find Next")) { bridge.findNext() }.keyboardShortcut("g")
                    Button(L("Find Previous")) { bridge.findNext(forward: false) }.keyboardShortcut("g", modifiers: [.command, .shift])
                    Button(L("Search the Book…")) { app.openSearch() }.keyboardShortcut("f", modifiers: [.command, .shift])
                }
            }
            CommandMenu(L("Format")) {
                Button(L("Bold")) { bridge.textView?.toggleInline("**") }.keyboardShortcut("b")
                Button(L("Italic")) { bridge.textView?.toggleInline("*") }.keyboardShortcut("i")
                Divider()
                Button(L("Heading 1")) { bridge.textView?.setHeading(1) }.keyboardShortcut("1", modifiers: [.command, .option])
                Button(L("Heading 2")) { bridge.textView?.setHeading(2) }.keyboardShortcut("2", modifiers: [.command, .option])
                Button(L("Heading 3")) { bridge.textView?.setHeading(3) }.keyboardShortcut("3", modifiers: [.command, .option])
                Button(L("Body Text")) { bridge.textView?.setHeading(0) }.keyboardShortcut("0", modifiers: [.command, .option])
                Divider()
                Button(L("Quotation")) { bridge.textView?.toggleQuote() }.keyboardShortcut("'", modifiers: [.command, .option])
                Button(L("Footnote")) { bridge.textView?.insertFootnote() }.keyboardShortcut("6", modifiers: [.command, .option])
                Divider()
                Toggle(L("Revision Mode"), isOn: Binding(get: { bridge.trackChanges }, set: { bridge.trackChanges = $0 }))
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Button(L("Comment", ctx: "Commenter")) {
                    bridge.trackChanges = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { NotificationCenter.default.post(name: .mussetAskComment, object: nil) }
                }.keyboardShortcut("m", modifiers: [.command, .shift])
                Button(L("Next Correction")) { bridge.textView?.nextRevision() }.keyboardShortcut("]", modifiers: [.command, .option])
                Button(L("Accept Correction")) { bridge.textView?.decideRevision(accept: true) }.keyboardShortcut(.return, modifiers: [.command, .option])
                Button(L("Reject Correction")) { bridge.textView?.decideRevision(accept: false) }.keyboardShortcut(.delete, modifiers: [.command, .option])
                Button(L("Accept All Corrections")) { bridge.textView?.decideRevision(accept: true, all: true) }
                Button(L("Reject All Corrections")) { bridge.textView?.decideRevision(accept: false, all: true) }
                Divider()
                Toggle(L("Show Format Bar"), isOn: $app.formatBar)
            }
            CommandMenu(L("Write")) {
                Toggle(L("Focus Mode"), isOn: $app.focusMode).keyboardShortcut("d", modifiers: [.command, .shift])
                Toggle(L("Typewriter Scrolling"), isOn: $app.typewriter).keyboardShortcut("t", modifiers: [.command, .shift])
                Toggle(L("Kiosk Mode"), isOn: $app.kiosk).keyboardShortcut("k", modifiers: [.command, .control])
                Button(L("Ultra Focus")) { UltraFocus.shared.toggle(app) }
                    .keyboardShortcut("u", modifiers: [.command, .control]).disabled(app.current == nil)
                Toggle(L("Line Numbers"), isOn: $app.lineNumbers).keyboardShortcut("l", modifiers: [.command, .control])
                Toggle(L("Minimap"), isOn: $app.minimap).keyboardShortcut("m", modifiers: [.command, .control])
                Toggle(L("Reading Mode"), isOn: $app.reviewMode).keyboardShortcut("r", modifiers: [.command, .shift])
                Toggle(L("Repetitions"), isOn: $app.repetitions).keyboardShortcut("r", modifiers: [.command, .control])
                Divider()
                Button(L("Next Proofreading Suggestion")) { NotificationCenter.default.post(name: .mussetProofread, object: nil) }
                    .keyboardShortcut(";")
                Button(L("Add Note…")) { bridge.textView?.beginNote() }.keyboardShortcut("n", modifiers: [.command, .option])
                Button(L("New Scene Here")) { bridge.textView?.beginScene() }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button(L("Dictionary & Exceptions…")) { app.showProofExceptions = true }
                Button(L("Apply Typography to the Whole Book…")) { app.applyTypographyToBook() }.disabled(app.current == nil)
                Button(L("History")) { withAnimation { app.inspectorTab = .history; app.showInspector = true } }.keyboardShortcut("h", modifiers: [.command, .option])
                Button(L("Save Snapshot (commit now)")) { app.current?.flushSave(); app.current?.commitNow("musset: snapshot") }
                    .keyboardShortcut("s")
            }
            CommandGroup(after: .sidebar) {
                Button(bridge.blameOn ? L("Hide Who Wrote What") : L("Who Wrote What")) { bridge.blameOn.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .option]).disabled(app.current == nil)
                Button(app.showSidebar ? L("Hide Chapters") : L("Show Chapters")) { app.showSidebar.toggle() }.keyboardShortcut("1")
                Button(InspectorTab.edits.label) { withAnimation { app.toggleInspector(.edits) } }.keyboardShortcut("2")
                Button(L("Chat")) { withAnimation { app.toggleInspector(.chat) } }.keyboardShortcut("3").disabled(!AIStatus.shared.isOn)
                Button(L("Stats")) { withAnimation { app.toggleInspector(.stats) } }.keyboardShortcut("4")
                Button(app.showPlotGrid ? L("Hide Plot Grid") : L("Plot Grid")) { withAnimation { app.showPlotGrid.toggle() } }.keyboardShortcut("5").disabled(app.current == nil)
                Button(L("Plan")) { withAnimation { app.toggleInspector(.plan) } }.keyboardShortcut("6")
                Button(InspectorTab.history.label) { withAnimation { app.toggleInspector(.history) } }.keyboardShortcut("7")
            }
        }

        Settings { SettingsView().font(.ui(13)) }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
