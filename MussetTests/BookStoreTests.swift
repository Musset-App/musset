import XCTest
@testable import Musset

final class BookStoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("musset-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ path: String, _ text: String) throws {
        let u = tmp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    func testSeedsFromBuildScriptOrder() throws {
        try write("build_version_longue.sh", "FILES=(\n  \"02_b.md\"\n  \"01_a.md\"\n)\n")
        try write("01_a.md", "# Alpha\n\ntext")
        try write("02_b.md", "# Beta\n\ntext")
        try write("notes.md", "not a chapter")
        let m = BookStore(root: tmp).seedManifest()
        XCTAssertEqual(m.chapters.map(\.file), ["02_b.md", "01_a.md"])
        XCTAssertEqual(m.chapters.map(\.title), ["Beta", "Alpha"])
    }

    func testSeedsNumberedFilesNaturally() throws {
        for n in [1, 2, 10] { try write("\(n).md", "# C\(n)\n") }
        try write("BIBLE.md", "bible")
        let m = BookStore(root: tmp).seedManifest()
        XCTAssertEqual(m.chapters.map(\.file), ["1.md", "2.md", "10.md"])
    }

    func testSeedsScenesFolderSkippingTranslations() throws {
        try write("scenes/1976_home.md", "# Home")
        try write("scenes/1976_home.en.md", "# Home EN")
        try write("scenes/1992_oxford.md", "# Oxford")
        let m = BookStore(root: tmp).seedManifest()
        XCTAssertEqual(m.chapters.map(\.file), ["scenes/1976_home.md", "scenes/1992_oxford.md"])
    }

    func testActivateSwapsAndKeepsPrevious() throws {
        try write("01_a.md", "first")
        let store = BookStore(root: tmp)
        var ch = ChapterEntry(id: "01_a", file: "01_a.md", title: "A")
        try store.saveVersion(ch, name: "r2", text: "second")
        ch = try store.activate(ch, version: "r2")
        XCTAssertEqual(ch.activeVersion, "r2")
        XCTAssertEqual(store.read(ch), "second")
        XCTAssertEqual(store.readVersion(ch, "main"), "first")
        XCTAssertEqual(store.versions(of: ch), ["r2", "main"])
    }

    func testConcatenationStripsComments() throws {
        try write("01_a.md", "# A\n<!-- note -->\nbody")
        try write("02_b.md", "# B\n")
        let store = BookStore(root: tmp)
        let m = BookManifest(title: "T", chapters: [
            ChapterEntry(id: "01_a", file: "01_a.md", title: "A"),
            ChapterEntry(id: "02_b", file: "02_b.md", title: "B"),
        ])
        XCTAssertEqual(store.concatenatedManuscript(m, stripComments: true), "# A\nbody\n\n# B\n\n")
    }

    func testWordCountIgnoresComments() {
        XCTAssertEqual(BookStore.wordCount("Un deux <!-- trois quatre --> cinq"), 3)
    }

    func testProofreaderParsesAndAnchors() {
        let raw = "Here: [{\"original\":\"les chat\",\"replacement\":\"les chats\",\"reason\":\"accord\"}]"
        let fixes = Proofreader.parse(raw, source: "Il voit les chat.", offset: 100)
        XCTAssertEqual(fixes.count, 1)
        XCTAssertEqual(fixes[0].anchor, 108)
    }

    func testGitCommitsOnlyOwnedPaths() throws {
        try write("01_a.md", "one")
        try write("other.txt", "untouched")
        let git = GitService(root: tmp)
        try git.initRepo()
        XCTAssertTrue(try git.commit(paths: ["01_a.md"], message: "first"))
        XCTAssertFalse(try git.commit(paths: ["01_a.md"], message: "nothing"))
        XCTAssertNil(git.show("HEAD", path: "other.txt"))
        XCTAssertEqual(git.log(path: "01_a.md").count, 1)
    }
}

/// Runs against the copies in fixtures/ (skipped when absent).
final class FixtureTests: XCTestCase {
    let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")

    func store(_ book: String) throws -> BookStore {
        let u = fixtures.appendingPathComponent(book)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: u.path))
        return BookStore(root: u)
    }

    func testSeedsAllThreeBooks() throws {
        let c = try store("conatus").seedManifest()
        XCTAssertEqual(c.chapters.count, 23)
        XCTAssertEqual(c.chapters.first?.file, "00_exergue.md")
        XCTAssertEqual(c.lang, "fr")
        XCTAssertFalse(c.contact.isEmpty)
        let e = try store("europa").seedManifest()
        XCTAssertTrue(e.chapters.allSatisfy { $0.file.hasPrefix("scenes/") && !$0.file.hasSuffix(".en.md") })
        XCTAssertEqual(e.chapters.first?.file, "scenes/1976_home.md")
        let b = try store("brainiacs").seedManifest()
        XCTAssertEqual(b.chapters.map(\.file), (1...8).map { "\($0).md" })
        XCTAssertEqual(b.lang, "en")
    }

    /// Chapter order matches the SOURCE markers the build script wrote into CONATUS_VERSION_LONGUE.md.
    func testOrderMatchesBuildScript() throws {
        let s = try store("conatus")
        let built = try String(contentsOf: s.root.appendingPathComponent("CONATUS_VERSION_LONGUE.md"), encoding: .utf8)
        let re = try NSRegularExpression(pattern: "<!-- SOURCE: (.+?) -->")
        let sources = re.matches(in: built, range: NSRange(built.startIndex..., in: built)).map { (built as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(s.seedManifest().chapters.map(\.file), sources)
    }
}

final class ExportTests: XCTestCase {
    func testAllPresetsOnFixtures() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        for book in ["conatus", "brainiacs"] {
            let root = fixtures.appendingPathComponent(book)
            try XCTSkipUnless(FileManager.default.fileExists(atPath: root.path))
            let store = BookStore(root: root)
            let m = store.seedManifest()
            for p in m.exports {
                do {
                    let known = Set((try? FileManager.default.contentsOfDirectory(atPath: WordManuscript.directory(root).path)) ?? [])
                    let out = try await ExportService.export(manifest: m, store: store, preset: p)
                    print("EXPORT OK \(book) \(p.id) \(out.file.path)")
                    // A Word export keeps what it sent, tracked with the book: not for a test's file.
                    for name in (try? FileManager.default.contentsOfDirectory(atPath: WordManuscript.directory(root).path)) ?? [] where !known.contains(name) {
                        try? FileManager.default.removeItem(at: WordManuscript.directory(root).appendingPathComponent(name))
                    }
                    if known.isEmpty { try? FileManager.default.removeItem(at: WordManuscript.directory(root)) }
                } catch {
                    XCTFail("\(book) \(p.id): \(error.localizedDescription)")
                }
            }
        }
    }
}

final class AgentTests: XCTestCase {
    func testParsesCodexEvents() {
        let lines = [
            #"{"type":"thread.started","thread_id":"abc"}"#,
            #"{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"ok"}}"#,
        ]
        let events = lines.flatMap(Agents.parseCodex)
        guard case .session("abc") = events[0], case .fullText("ok") = events[1] else { return XCTFail("\(events)") }
    }

    func testParsesClaudeEvents() {
        let delta = #"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Bon"}}}"#
        guard case .textDelta("Bon") = Agents.parseClaude(delta).first else { return XCTFail() }
        let err = #"{"type":"result","is_error":true,"result":"Failed to authenticate"}"#
        guard case .error = Agents.parseClaude(err).first else { return XCTFail() }
    }

    /// Live: uses the codex CLI login. Opt in with MUSSET_LIVE=1.
    func testLiveCodexProofread() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let fixes = try await Proofreader.check(text: "Ma mère s'est suicidé un samedi soir. Les porte tremblait.", offset: 0, lang: "fr",
                                                engine: .codex, model: "", cwd: FileManager.default.temporaryDirectory)
        print("LIVE FIXES", fixes.map { "\($0.original) -> \($0.replacement)" })
        XCTAssertFalse(fixes.isEmpty)
    }
}

final class ProofMatchingTests: XCTestCase {
    func testStraightApostropheMatchesCurlyText() {
        let src = "Mais on est jamais trop prudent, dit l’homme."
        let raw = #"[{"original":"on est jamais","replacement":"on n'est jamais","reason":"négation"},{"original":"dit l'homme","replacement":"dit l'Homme","reason":"x"}]"#
        let fixes = Proofreader.parse(raw, source: src, offset: 0)
        XCTAssertEqual(fixes.count, 2)
        XCTAssertEqual(fixes[0].replacement, "on n’est jamais")   // follows the text's ’
        XCTAssertEqual(fixes[1].replacement, "dit l’Homme")       // keeps the source's ’
    }

    func testChunksCoverWholeText() {
        let text = (0..<30).map { "Paragraphe \($0) " + String(repeating: "mot ", count: 60) }.joined(separator: "\n\n")
        let parts = Proofreader.chunks(text)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertEqual(parts.map(\.text).joined(), text)
        for p in parts { XCTAssertEqual((text as NSString).substring(with: NSRange(location: p.offset, length: (p.text as NSString).length)), p.text) }
    }

    /// Live: whole 03_nice.md fixture through Haiku. Opt in with MUSSET_LIVE=1.
    func testLiveHaikuOnNice() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("fixtures/conatus/03_nice.md")
        let text = try String(contentsOf: url, encoding: .utf8)
        let fixes = try await Proofreader.check(text: text, offset: 0, lang: "fr", engine: .claude, model: "haiku",
                                                cwd: FileManager.default.temporaryDirectory)
        for f in fixes { print("LIVE FIX «\(f.original)» → «\(f.replacement)» (\(f.reason))") }
        print("LIVE TOTAL", fixes.count)
        XCTAssertGreaterThanOrEqual(fixes.count, 8)
    }
}

final class ExportNameTests: XCTestCase {
    private func name(_ contents: String?, revision: String? = nil) -> String {
        var m = BookManifest(title: "Le Sel", chapters: [])
        m.author = "Jeanne Martin"
        var store = BookStore(root: URL(fileURLWithPath: "/tmp/x"))
        store.revisionName = revision
        let p = ExportPreset(id: "manuscript-a4", name: "Manuscript A4 (publisher submission)", format: .pdf)
        let date = DateComponents(calendar: Calendar.current, year: 2026, month: 11, day: 8, hour: 14, minute: 32).date!
        return ExportService.fileName(m, store: store, preset: p, contents: contents, date: date)
    }

    func testWholeBook() {
        XCTAssertTrue(name(nil).hasPrefix("LE_SEL_JEANNE_MARTIN_MANUSCRI"))
        XCTAssertTrue(name(nil).hasSuffix("_A4_2026-11-08_1432.pdf"))
    }

    func testChaptersAndStatuses() {
        XCTAssertTrue(name("Le Grenier-Interlude 2").hasPrefix("LE_SEL_LE_GRENIER-INTERLUDE_2_JEANNE_MARTIN_"))
        XCTAssertTrue(name("Révisé-Final").hasPrefix("LE_SEL_REVISE-FINAL_JEANNE_MARTIN_"))
        XCTAssertTrue(name(nil, revision: "Envoi agent").hasPrefix("LE_SEL_ENVOI_AGENT_JEANNE_MARTIN_"))
    }
}

final class AgentWebSearchTests: XCTestCase {
    func testSearchesShowInTheStatus() {
        let claude = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebSearch","input":{"query":"prix Goncourt 2025"}}]}}"#
        guard case .status(let s) = Agents.parseClaude(claude).first else { return XCTFail() }
        XCTAssertTrue(s.contains("« prix Goncourt 2025 »"))
        let fetch = #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"WebFetch","input":{"url":"https://actualitte.com/livres/1"}}]}}"#
        guard case .status(let f) = Agents.parseClaude(fetch).first else { return XCTFail() }
        XCTAssertTrue(f.hasSuffix("actualitte.com"))
        let codex = #"{"type":"item.completed","item":{"type":"web_search","query":"prix Goncourt 2025"}}"#
        guard case .status(let c) = Agents.parseCodex(codex).first else { return XCTFail() }
        XCTAssertTrue(c.contains("« prix Goncourt 2025 »"))
    }
}

@MainActor
final class KioskTests: XCTestCase {
    /// AppKit throws on an invalid combination (a hidden menu bar with the Dock showing…): apply it for a moment.
    func testThePresentationOptionsAreAccepted() {
        let before = NSApp.presentationOptions
        NSApp.presentationOptions = Kiosk.options
        XCTAssertEqual(NSApp.presentationOptions, Kiosk.options)
        NSApp.presentationOptions = before
        XCTAssertFalse(Kiosk.options.contains(.disableForceQuit), "⌥⌘Esc must stay, in case Musset hangs")
    }

    /// The window loses its frame, buttons and shadow, covers the whole screen, keeps the keyboard; then gets it all back.
    func testTheWindowTakesTheWholeScreenAndComesBack() throws {
        let style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 800, height: 600), styleMask: style, backing: .buffered, defer: false)
        // The screen the window is on: with several, not always the main one.
        let screen = try XCTUnwrap(window.screen ?? NSScreen.main)
        window.isReleasedWhenClosed = false
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        window.contentView?.addSubview(field)
        window.makeFirstResponder(field)
        let before = window.frame
        let options = NSApp.presentationOptions

        Kiosk.enter(window)
        XCTAssertTrue(Kiosk.isOn)
        XCTAssertFalse(window.styleMask.contains(.titled))
        XCTAssertNil(window.standardWindowButton(.closeButton))
        XCTAssertFalse(window.hasShadow)
        XCTAssertEqual(window.frame, screen.frame, "over the menu bar strip and the notch too")
        XCTAssertTrue(window.canBecomeKey, "the page keeps the keyboard")
        XCTAssertTrue(window.firstResponder === field)

        Kiosk.leave(window)
        XCTAssertFalse(Kiosk.isOn)
        XCTAssertEqual(window.styleMask, style)
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertTrue(window.hasShadow)
        XCTAssertEqual(window.frame, before)
        XCTAssertEqual(NSApp.presentationOptions, options)
        XCTAssertEqual(window.className, "NSWindow", "its own class all along")
        let other = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
        XCTAssertFalse(other.canBecomeKey, "other borderless windows answer as before")
        window.close()
    }
}

@MainActor
final class IosevkaTests: XCTestCase {
    /// EB Garamond, the printed book's face, ships in the app: a PDF never falls back to Libertinus on a Mac without it.
    func testEBGaramondShipsForThePrintedBook() throws {
        for cut in ["Regular", "Italic", "SemiBold", "SemiBoldItalic", "Bold", "BoldItalic"] {
            XCTAssertNotNil(Bundle.main.url(forResource: "EBGaramond-\(cut)", withExtension: "otf"), cut)
        }
        Typefaces.register()
        XCTAssertNotNil(NSFont(name: "EBGaramond-Regular", size: 12))
    }

    /// Iosevka Aile and Etoile are in the app, with the italic and bold the editor asks for.
    func testBothFamiliesLoadWithItalicAndBold() throws {
        Typefaces.register()
        for name in ["Iosevka-Aile", "Iosevka-Etoile"] {
            let font = try XCTUnwrap(NSFont(name: name, size: 17), name)
            let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            XCTAssertTrue(italic.fontDescriptor.symbolicTraits.contains(.italic), name)
            XCTAssertTrue(bold.fontDescriptor.symbolicTraits.contains(.bold), name)
            XCTAssertEqual(italic.familyName, font.familyName, "the italic is Iosevka's own")
        }
    }
}
