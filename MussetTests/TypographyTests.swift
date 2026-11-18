import MussetPage
import AppKit
import SwiftUI
import XCTest
@testable import Musset

final class TypographyTests: XCTestCase {
    let n = "\u{00A0}"

    private func apply(_ edits: [Typography.Edit], to text: String) -> String {
        var out = text as NSString
        for e in edits.reversed() { out = out.replacingCharacters(in: e.range, with: e.replacement) as NSString }
        return out as String
    }

    func testFrench() {
        let src = "Il dit: \"bonjour\" ; l'homme... Vraiment?! À 12:30, 50 % - je crois - in extremis."
        let want = "Il dit\(n): «\(n)bonjour\(n)»\(n); l’homme… Vraiment\(n)?! À 12:30, 50\(n)% – je crois – *in extremis*."
        XCTAssertEqual(Typography.corrected(src, lang: "fr"), want)
        XCTAssertEqual(apply(Typography.edits(in: src, lang: "fr"), to: src), want)
    }

    func testFrenchDialogueGuillemetsAndExisting() {
        XCTAssertEqual(Typography.corrected("- Oui, dit-il.", lang: "fr"), "— Oui, dit-il.")
        XCTAssertEqual(Typography.corrected("«colles» et « simples »", lang: "fr"), "«\(n)colles\(n)» et «\(n)simples\(n)»")
        XCTAssertEqual(Typography.corrected("Fine\u{202F}? Oui\u{202F}!", lang: "fr"), "Fine\(n)? Oui\(n)!")
        // Already right: nothing to do.
        let ok = "Il dit\(n): «\(n)oui\(n)». C’était *in extremis*\(n)!"
        XCTAssertTrue(Typography.edits(in: ok, lang: "fr").isEmpty)
    }

    func testProtectedZonesAreUntouched() {
        let src = "Voir [le site](https://a.fr/x?y=1) <!-- NOTE: vérifier... l'année --> et `code: 'x'`"
        XCTAssertEqual(Typography.corrected(src, lang: "fr"), src)
        XCTAssertEqual(Typography.corrected("* * *", lang: "fr"), "* * *")
        XCTAssertEqual(Typography.corrected("---", lang: "fr"), "---")
        XCTAssertEqual(Typography.corrected("Déjà *in extremis* ici", lang: "fr"), "Déjà *in extremis* ici")
    }

    func testNamesKeepTheirPunctuation() {
        XCTAssertEqual(Typography.corrected("Sur Yahoo! Messenger, oui !", lang: "fr"), "Sur Yahoo! Messenger, oui\(n)!")
        XCTAssertEqual(Typography.corrected("Sur Yahoo\(n)! Messenger", lang: "fr"), "Sur Yahoo! Messenger")
        XCTAssertEqual(Typography.corrected("Sur Yahoo ! Messenger", lang: "fr"), "Sur Yahoo! Messenger")
        Typography.bookNames = ["Cœur!"]
        defer { Typography.bookNames = [] }
        XCTAssertEqual(Typography.corrected("Le groupe Cœur! joue. Mon Cœur !", lang: "fr"), "Le groupe Cœur! joue. Mon Cœur!")
        XCTAssertEqual(Typography.corrected("Le Sacré-Cœur!", lang: "fr"), "Le Sacré-Cœur!")
    }

    func testARefusedSpaceIsFoundWithItsContext() {
        let text = "Il dit Kaboom! ce soir"
        let found = AutoProofreader.spaces(in: text, edits: Typography.edits(in: text, lang: "fr"))
        XCTAssertEqual(found.map(\.name), ["Kaboom!"])
        let elsewhere = "Plus loin Kaboom! ailleurs"
        XCTAssertNotEqual(found.first?.key, AutoProofreader.spaces(in: elsewhere, edits: Typography.edits(in: elsewhere, lang: "fr")).first?.key)
    }

    func testEnglish() {
        let src = "He said \"hi\" -- then left ; don't wait... It's 12:30 !"
        XCTAssertEqual(Typography.corrected(src, lang: "en"), "He said “hi”—then left; don’t wait… It’s 12:30!")
    }

    func testKeyIgnoresTypography() {
        XCTAssertEqual(Typography.key("Il dit: \"bonjour\" ; l'homme..."), Typography.key(Typography.corrected("Il dit: \"bonjour\" ; l'homme...", lang: "fr")))
        XCTAssertNotEqual(Typography.key("Il dit oui."), Typography.key("Il dit non."))
    }

    /// Prints what the rules would change in the real chapters. Opt in with MUSSET_LIVE=1.
    func testOnFixtureBooks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        for book in ["conatus", "europa"] {
            let root = fixtures.appendingPathComponent(book)
            let manifest = try BookStore(root: root).loadManifest()
            var total = 0
            var samples: [String] = []
            for ch in manifest.chapters {
                let text = BookStore(root: root).read(ch)
                let edits = Typography.edits(in: text, lang: manifest.lang)
                total += edits.count
                let ns = text as NSString
                for e in edits.prefix(200) where samples.count < 40 {
                    let ctx = NSRange(location: max(0, e.range.location - 12), length: min(ns.length - max(0, e.range.location - 12), e.range.length + 24))
                    let before = ns.substring(with: ctx)
                    let after = apply([Typography.Edit(range: NSRange(location: e.range.location - ctx.location, length: e.range.length), replacement: e.replacement)], to: before)
                    let show = { (s: String) in s.replacingOccurrences(of: "\u{00A0}", with: "⍽").replacingOccurrences(of: "\n", with: "⏎") }
                    let key = show(before) + " → " + show(after)
                    if !samples.contains(where: { $0.hasSuffix(String(key.suffix(20))) }) { samples.append(key) }
                }
            }
            print("TYPO \(book): \(total) edits")
            for s in samples { print("TYPO   \(s)") }
        }
    }
}

@MainActor
final class TypographyEditorTests: XCTestCase {
    func testAppliedInEditorWithOneUndoAndNotesFollow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-typo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let text = "Il dit: \"oui\".\n\nL'homme... part; sans rien dire.\n\nJe tape ici\n"
        try text.write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        let manifest = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")])
        let session = BookSession(root: root, manifest: manifest)
        let bridge = EditorBridge(), proof = AutoProofreader(), annotator = Annotator()
        bridge.proof = proof; bridge.annotator = annotator; proof.bridge = bridge
        proof.typography = true
        proof.attach(root: root, lang: "fr")
        let editor = ZenEditorView(session: session, bridge: bridge, fontName: "", fontSize: 16, columnWidth: 600,
                                   focusMode: false, typewriter: false, lineNumbers: true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: editor)
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let tv = try XCTUnwrap(bridge.textView)
        let note = try XCTUnwrap(session.notes.add(range: (tv.string as NSString).range(of: "sans rien dire"), text: tv.string,
                                                   author: .me, kind: .note, body: "x"))
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length - 2, length: 0))
        // Typography is applied half a second after the chapter opens, as one undoable step.
        RunLoop.main.run(until: Date().addingTimeInterval(0.9))
        let n = Typography.nbsp
        XCTAssertEqual(tv.string, "Il dit\(n): «\(n)oui\(n)».\nL’homme… part\(n); sans rien dire.\nJe tape ici\n")
        XCTAssertEqual((tv.string as NSString).substring(with: session.notes.live[note.id]!), "sans rien dire")
        XCTAssertGreaterThan(proof.typographyFixed, 0)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(tv.undoManager?.undoActionName, L("Typography"))
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, ParagraphCodec.decode(text))
        // Undone on purpose: not re-applied when the caret moves.
        proof.selectionChanged()
        XCTAssertEqual(tv.string, ParagraphCodec.decode(text))
        withExtendedLifetime((window, annotator)) {}
    }

    func testLegacyCacheIsCarriedOver() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".musset/proof"), withIntermediateDirectories: true)
        let para = "Il y a avait un chien.\n"
        let legacy = String(PangramClient.sha("fr" + "\u{1f}" + para.trimmingCharacters(in: .whitespacesAndNewlines)).prefix(20))
        let cache: [String: [[String: String]]] = [legacy: [["original": "y a avait", "replacement": "y avait", "reason": "x", "kind": "suggest"]]]
        try JSONSerialization.data(withJSONObject: ["cache": cache, "ignored": []]).write(to: root.appendingPathComponent(".musset/proof/cache.json"))
        let proof = AutoProofreader()
        proof.enabled = true
        proof.attach(root: root, lang: "fr")
        XCTAssertEqual(proof.issues(in: para).count, 1)
        // The typographic form of the same paragraph shares the key: no new AI request.
        XCTAssertEqual(AutoProofreader.hash("L'homme dit: oui", lang: "fr"), AutoProofreader.hash("L’homme dit\u{00A0}: oui", lang: "fr"))
    }

    func testWholeBookInOneCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-book-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "L'un dit: oui.\n".write(to: root.appendingPathComponent("01.md"), atomically: true, encoding: .utf8)
        try "L'autre... non!\n".write(to: root.appendingPathComponent("02.md"), atomically: true, encoding: .utf8)
        let git = GitService(root: root)
        try git.initRepo()
        let manifest = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un"), ChapterEntry(id: "02", file: "02.md", title: "Deux")])
        _ = try git.commit(paths: ["01.md", "02.md"], message: "init")
        let session = BookSession(root: root, manifest: manifest)
        XCTAssertEqual(session.typographyPreview().chapters, 2)
        session.applyTypographyToBook()
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("02.md"), encoding: .utf8), "L’autre… non\u{00A0}!\n")
        XCTAssertEqual(session.text, "L’un dit\u{00A0}: oui.\n")
        let log = try XCTUnwrap(Shell.run("/usr/bin/git", ["log", "--format=%s"], cwd: root).stdout)
        XCTAssertTrue(log.hasPrefix("musset: typography (fr)"), log)
    }
}

@MainActor
final class TypographyApplyFixtures: XCTestCase {
    /// Applies typography to the fixture books, one commit each. Run on purpose with MUSSET_APPLY_TYPOGRAPHY=1.
    func testApplyToFixtureBooks() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_APPLY_TYPOGRAPHY"] == "1")
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures")
        for book in ["conatus", "europa"] {
            let root = fixtures.appendingPathComponent(book)
            let session = BookSession(root: root, manifest: try BookStore(root: root).loadManifest())
            let preview = session.typographyPreview()
            session.applyTypographyToBook()
            print("APPLIED \(book): \(preview.edits) fixes in \(preview.chapters) chapters")
        }
    }
}

/// Musset's Markdown as the typesetter turns it into Typst.
final class TypstMarkupTests: XCTestCase {
    func testInlineAndEscapes() throws {
        XCTAssertEqual(try Typeset.chapter("Il dit *Jungle* et **non** : #1 $5 @x <a> [b] ~ a/b 1_000"),
                       "Il dit #emph[Jungle] et #strong[non] : \\#1 \\$5 \\@x \\<a\\> \\[b\\] \\~ a\\/b 1\\_000\n\n")
        XCTAssertEqual(try Typeset.chapter("1943. Barcelone."), "1943\\. Barcelone.\n\n")
        XCTAssertEqual(try Typeset.chapter("> - Oui"), "#quote(block: true)[\\- Oui]\n\n")
        XCTAssertEqual(try Typeset.chapter("*L’Appartement des Quais*. Un"), "#emph[L’Appartement des Quais]. Un\n\n")
    }

    func testChapterStructure() throws {
        let md = "# Barcelone\n\nLe soir.\n\n<!-- NOTE: secret\nsur deux lignes -->\n\n* * *\n\n> Comme on joue\n> sa vie\n\nFin.\n"
        let t = try Typeset.chapter(md, id: "04", markers: true)
        XCTAssertTrue(t.contains("= #mk(\"04\", 0)Barcelone"))
        XCTAssertTrue(t.contains("#mk(\"04\", 13)Le soir."))
        XCTAssertFalse(t.contains("secret"))
        XCTAssertTrue(t.contains("#scenebreak()"))
        XCTAssertTrue(t.contains("#quote(block: true)["))
        XCTAssertTrue(t.contains("Comme on joue sa vie"))
    }

    /// A poster, a poem: lines ending in two spaces or a backslash stay separate inside a quote.
    func testHardBreaksInAQuote() throws {
        let t = try Typeset.chapter("> *Vacuité de la mode – 2004*    \n> *Métal sur métal*\\\n> une suite\n> *Collection privée*  \n\nLa suite.\n", id: "09")
        let quote = t.components(separatedBy: "#quote(block: true)[")[1].components(separatedBy: "]\n\n")[0]
        let lines = quote.components(separatedBy: " \\\n")
        XCTAssertEqual(lines.count, 3, quote)
        XCTAssertTrue(lines[0].contains("Vacuité de la mode"))
        XCTAssertTrue(lines[1].contains("Métal sur métal"))
        XCTAssertTrue(lines[2].contains("une suite "), "no break asked for: same line")
        XCTAssertTrue(lines[2].contains("Collection privée"))
        XCTAssertFalse(quote.hasSuffix("\\"), "nothing after the last line")
    }

    /// Compiles a whole real book with both styles. Opt in with MUSSET_LIVE=1.
    func testCompileFixtureBook() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let store = BookStore(root: root)
        let m = try store.loadManifest()
        let chapters = m.chapters.filter { !$0.excludeFromExport }.map { (id: $0.id, text: store.read($0)) }
        for style in ["book", "fullpage"] {
            let start = Date()
            let pdf = try TypesetBook.pdf(Typeset.book(chapters, style: style, title: m.title, author: m.author, lang: m.lang, layout: PageLayout()).source)
            print("TYPST \(style): \(String(format: "%.2f", Date().timeIntervalSince(start)))s, \(pdf.count) bytes")
            XCTAssertEqual(String(data: pdf.prefix(4), encoding: .ascii), "%PDF")
        }
    }
}

final class TypstLatexTests: XCTestCase {
    func testExergueLatexBecomesTypst() throws {
        let md = "\\thispagestyle{empty}\n\\vspace*{0.42\\textheight}\n\n\\begin{flushright}\n\\emph{« C’est là ce que nous avons eu de meilleur. »}\n\n\\vspace{0.75\\baselineskip}\n\n— Flaubert\n\\end{flushright}\n\n\\clearpage\n"
        let t = try Typeset.chapter(md, id: "00")
        XCTAssertFalse(t.contains("\\\\begin") || t.contains("textheight"), t)
        XCTAssertTrue(t.contains("#nofolio()"), t)
        XCTAssertTrue(t.contains("#v(42%)"))
        XCTAssertTrue(t.contains("#align(right)["))
        XCTAssertTrue(t.contains("#emph[« C’est là ce que nous avons eu de meilleur. »]"), t)
        XCTAssertTrue(t.contains("#v(0.75em)"))
        XCTAssertTrue(t.contains("#pagebreak()"))
    }
}

@MainActor
final class ReviewModeTests: XCTestCase {
    /// Reading mode on the engine: a chapter of the fixture set as the book, the place of a passage found on its page,
    /// and a conversation on it drawn there. Fixtures are only read (copied).
    func testReadingModePlacesPassagesAndConversations() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: fixture.appendingPathComponent("04_barcelone.md").path), "no fixture")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-review-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for f in ["03_nice.md", "04_barcelone.md"] {
            try FileManager.default.copyItem(at: fixture.appendingPathComponent(f), to: root.appendingPathComponent(f))
        }
        let manifest = BookManifest(title: "Le Sel", chapters: [ChapterEntry(id: "03_nice", file: "03_nice.md", title: "Nice"),
                                                                 ChapterEntry(id: "04_barcelone", file: "04_barcelone.md", title: "Barcelone")])
        let session = BookSession(root: root, manifest: manifest)
        session.open("04_barcelone")
        // A sentence from the middle of the chapter, whatever its words.
        let ns = session.text as NSString
        let mid = ns.range(of: ". ", range: NSRange(location: ns.length / 2, length: ns.length / 2))
        try XCTSkipIf(mid.location == NSNotFound, "no sentence in the chapter")
        let target = NSRange(location: mid.location + 2, length: min(30, ns.length - mid.location - 2))

        let model = ReviewModel()
        model.scope = .chapter
        model.style = "book"
        model.build(session: session)
        XCTAssertNil(model.error)
        let reader = try XCTUnwrap(model.reader)
        XCTAssertEqual(reader.fit, .print, "set as it will be printed")
        let book = try TypesetBook(reader.source)
        XCTAssertGreaterThan(book.pageCount, 3)
        let page = book.page(for: PageAnchor(chapter: "04_barcelone", offset: target.location))
        let c = try XCTUnwrap(book.source.chapterIndex("04_barcelone"))
        XCTAssertFalse(book.lineRects(page: page, chapter: c, range: target.location..<(target.location + target.length)).isEmpty, "the passage is on its page")

        // A conversation on the passage becomes a mark there, in its starter's ink.
        let id = UUID()
        let note = TalkEntry(id: id, thread: id, kind: .note, by: "claire", body: "Source ?", chapter: "04_barcelone",
                             anchor: Anchoring.capture(target, in: session.text as NSString, version: nil), mark: .margin, color: 0)
        let mark = try XCTUnwrap(Talk.threads(from: [note]).first?.pageMark(in: session.text, name: { $0 }))
        XCTAssertEqual(mark.range, target.location..<(target.location + target.length))
        XCTAssertEqual(mark.kind, .note)
        XCTAssertEqual(mark.note, "Source ?")
        XCTAssertEqual(mark.ink, Person.ink("claire"))
        XCTAssertEqual(mark.id, id.uuidString, "a tap finds its thread")

        model.scope = .book
        model.build(session: session)
        XCTAssertEqual(model.reader?.source.chapters.map(\.id), ["03_nice", "04_barcelone"])
        XCTAssertTrue(model.reader === reader, "one reader, set again")
    }

    func testEveryPersonHasAnInk() {
        for user in ["claire", "tom", "ines", "jun", "dana"] {
            XCTAssertEqual(Person.ink(user).rawValue.isEmpty, false)
        }
        XCTAssertEqual(SelectionAction.note("Pourquoi ?").talk.mark, .margin)
        XCTAssertEqual(SelectionAction.suggest("Pedro").talk.body, "→ Pedro")
    }
}

final class TypstExportTests: XCTestCase {
    /// Live: every PDF preset of a real book through Typst. Opt in with MUSSET_LIVE=1.
    func testPDFPresetsThroughTypst() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_LIVE"] == "1")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let store = BookStore(root: root)
        let m = try store.loadManifest()
        for p in store.presets(m) where p.format == .pdf {
            let start = Date()
            let out = try await ExportService.export(manifest: m, store: store, preset: p)
            print("EXPORT \(p.id) [\(p.typstStyle)] \(String(format: "%.2f", Date().timeIntervalSince(start)))s → \(out.file.path)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: out.file.path))
        }
    }
}

@MainActor
final class SideBySideSnapshotTests: XCTestCase {
    /// Renders the editor with the preview beside it (wide) and full-window (narrow). Opt in with MUSSET_SNAPSHOT=<dir>.
    func testSideBySide() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-side-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("03_nice.md"), to: root.appendingPathComponent("03_nice.md"))
        let session = BookSession(root: root, manifest: BookManifest(title: "Le Sel", chapters: [ChapterEntry(id: "03_nice", file: "03_nice.md", title: "Nice")]))
        let app = AppState()
        app.reviewMode = true
        let bridge = EditorBridge(), proof = AutoProofreader()
        bridge.proof = proof; proof.bridge = bridge
        for (name, size) in [("side", NSSize(width: 1500, height: 820)), ("full", NSSize(width: 900, height: 820))] {
            let column = EditorColumn(app: app, session: session, bridge: bridge, proof: proof, fontName: "", fontSize: 16, columnWidth: 600)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: column)
            window.makeKeyAndOrderFront(nil)
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline && (app.review.reader?.book == nil || app.review.building) { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let v = window.contentView!
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent("review-\(name).png"))
        }
        app.reviewMode = false
    }
}
