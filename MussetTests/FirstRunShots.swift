import PDFKit
import SwiftUI
import XCTest
@testable import Musset

/// The first run, screen by screen, from an empty Mac to a first export. MUSSET_SNAPSHOT=<dir>; run it under a
/// bundle identifier that has never been used, so the settings are those of a first launch.
/// MUSSET_SCRIV=<project> adds the Scrivener import.
@MainActor
final class FirstRunShots: XCTestCase {
    /// A book with pages in it, at MUSSET_BOOK_OUT, for trying the app by hand: the example, as an ordinary book.
    func testMakeABookToTryTheAppOn() throws {
        guard let out = ProcessInfo.processInfo.environment["MUSSET_BOOK_OUT"] else { throw XCTSkip("set MUSSET_BOOK_OUT") }
        let root = URL(fileURLWithPath: out)
        let content = try XCTUnwrap(ExampleBook.content("en"))
        let text = try String(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "example-time-machine-en", withExtension: "md")), encoding: .utf8)
        try ExampleBook.build(content, text: text, at: root, lang: "en-US")
        try FileManager.default.removeItem(at: root.appendingPathComponent(".musset/example"))
    }

    func testFirstRunFlow() async throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let d = UserDefaults.standard
        d.set("en", forKey: UILang.key)
        let aids = ["musset-title", "musset-step", "musset-import"]
        defer { aids.forEach(d.removeObject) }

        func window(_ app: AppState, width: CGFloat = 1280, height: CGFloat = 800) -> NSWindow {
            let bridge = EditorBridge(), ann = Annotator(), proof = AutoProofreader()
            bridge.annotator = ann; bridge.proof = proof
            let view = ContentView(app: app, bridge: bridge, chat: ChatModel(), pangram: PangramModel(), proof: proof, annotator: ann)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .aqua)
            w.contentView = NSHostingView(rootView: view.frame(width: width, height: height))
            return w
        }
        func shot(_ w: NSWindow, _ name: String, wait: Double = 1.5) async throws {
            try await Task.sleep(for: .seconds(wait))
            let v = w.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name))
        }
        /// A sheet at the size it gives itself; a height of 0 asks the view for its own.
        func sheet<V: View>(_ view: V, _ size: NSSize, _ name: String) async throws {
            var size = size
            if size.height == 0 {
                let probe = NSHostingView(rootView: view.tint(Ink.accent).frame(width: size.width))
                size.height = probe.fittingSize.height
            }
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .aqua)
            w.contentView = NSHostingView(rootView: view.tint(Ink.accent).frame(width: size.width, height: size.height))
            try await shot(w, name)
        }

        // 1. The very first window.
        aids.forEach(d.removeObject)
        try await shot(window(AppState()), "01-first-launch.png")

        // 2. A title typed: Return starts the book. 2b. The other choices, for those who ask. 3. The form.
        d.set("The Salt Road", forKey: "musset-title")
        try await shot(window(AppState()), "02-title-typed.png")
        d.set("more", forKey: "musset-step")
        try await shot(window(AppState()), "02b-more-choices.png")
        d.set("form", forKey: "musset-step")
        try await shot(window(AppState()), "03-form.png")
        aids.forEach(d.removeObject)

        // 4. Or a Scrivener project dropped on the window.
        if let scriv = ProcessInfo.processInfo.environment["MUSSET_SCRIV"] {
            d.set(scriv, forKey: "musset-import")
            try await shot(window(AppState()), "04-import-scrivener.png", wait: 8)
            aids.forEach(d.removeObject)
            // … and the book it makes, as it first opens.
            let plan = try await BookImporter.planScrivener(URL(fileURLWithPath: scriv), cwd: FileManager.default.temporaryDirectory)
            let imported = FileManager.default.temporaryDirectory.appendingPathComponent("first-run-\(UUID())/tutorial", isDirectory: true)
            addTeardownBlock { try? FileManager.default.removeItem(at: imported.deletingLastPathComponent()) }
            let other = AppState()
            try await other.createBook(at: imported, title: plan.title, author: "Mara Lindqvist", lang: "en", genre: BookGenres.first[0], chapters: plan.chapters)
            other.showHome = false
            other.showAsBook()
            try await shot(window(other), "04b-imported-book.png", wait: 6)
        }

        // 5. The book just made, as « Create book » leaves it.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("first-run-\(UUID())/the-salt-road", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let app = AppState()
        var shape = BookManifest(title: "", author: "", lang: "en", chapters: [])
        shape.setForm(.novel)
        let name = shape.newPieceTitle(1)
        try await app.createBook(at: root, title: "The Salt Road", author: "Mara Lindqvist", lang: "en", genre: BookGenres.first[0], form: .novel,
                                 chapters: [PlannedChapter(title: name, text: "# \(name)\n\n")])
        app.showHome = false
        let main = window(app)
        try await shot(main, "05-new-book.png", wait: 2.5)

        // 6. Nothing comes up over it. The AI readers are offered on a later visit, to a book with pages.
        try await sheet(AIHelpersView(), NSSize(width: 1000, height: 640), "06-ai-readers-later.png")

        // 7. A page written.
        let s = try XCTUnwrap(app.current)
        let prose = ["Nora stepped off the ferry last, her father’s coat folded over her arm, and stood a while on the slip watching the grey water close behind the boat.",
                     "“You could have sent word,” Tom said without turning round.",
                     "She did not answer. The wind carried the smell of the pans, that smell of silt and iron she thought she had forgotten, and it came back all at once, whole, like a sentence learnt by heart.",
                     "They walked to the salt works without speaking. The rakes were still against the wall, where their mother used to leave them.",
                     "“He died on Tuesday,” she said at last."]
        let entry = try XCTUnwrap(s.manifest.chapters.first)
        try s.store.write("# \(name)\n\n" + prose.joined(separator: "\n\n") + "\n", to: entry)
        let again = AppState()
        again.openBook(root)
        again.showHome = false
        again.say(L("Every version of this book is kept as you write. There is nothing to save."))
        try await shot(window(again), "07-a-page-written.png", wait: 2.5)
        again.notice = nil

        // 8. Export… 9. and what comes out with nothing touched.
        let session = try XCTUnwrap(again.current)
        try await sheet(ExportSheet(session: session), NSSize(width: 780, height: 0), "08-export.png")
        let presets = session.store.presets(session.manifest)
        print("FIRSTRUN presets: \(presets.map { "\($0.format.rawValue):\($0.name)" })")
        for (n, pdf) in [presets.first { $0.id == "reader" }].compactMap({ $0 }).enumerated() {
            let started = Date()
            let result = try await ExportService.export(manifest: session.manifest, store: session.store, preset: pdf)
            print("FIRSTRUN export: \(result.file.lastPathComponent) in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
            
            if let doc = PDFDocument(url: result.file) {
                print("FIRSTRUN pages: \(doc.pageCount)")
                for i in 0..<min(doc.pageCount, 4) {
                    guard let page = doc.page(at: i) else { continue }
                    let image = page.thumbnail(of: NSSize(width: 900, height: 1300), for: .mediaBox)
                    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("\(n == 0 ? "09-export" : "10-for-readers")-page-\(i + 1).png"))
                    }
                }
            }
        }

        // 10. The example book, from the welcome's third door.
        let shelf = FileManager.default.temporaryDirectory.appendingPathComponent("first-run-\(UUID())", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: shelf) }
        let reader = AppState()
        try await ExampleBook.open(in: reader, at: shelf, lang: "en-US")
        let example = try XCTUnwrap(reader.current)
        XCTAssertEqual(example.manifest.chapters.count, 17)
        XCTAssertEqual(example.milestones.count, 2)
        let exampleWindow = window(reader)
        try await shot(exampleWindow, "10-example-book.png", wait: 4)
        if let weena = example.bible.entries.first(where: { $0.title == "Weena" }) {
            reader.open(.sheet(weena.path))
            try await shot(exampleWindow, "11-example-sheet.png", wait: 2.5)
        }
        reader.open(OverviewTab.summary.tab)
        try await shot(exampleWindow, "12-example-overview.png", wait: 3)
    }
}
