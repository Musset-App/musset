import XCTest
import SwiftUI
@testable import Musset

final class PistesTests: XCTestCase {
    private func picks(_ blocks: [ParagraphMerge.Block]) -> [Int: ParagraphMerge.Pick] {
        Dictionary(uniqueKeysWithValues: blocks.compactMap { b in b.suggested.map { (b.id, $0) } })
    }

    func testEachSideKeepsWhatOnlyItChanged() {
        let blocks = ParagraphMerge.blocks(base: "A\nB\nC\nD", mine: "A\nB2\nC\nD", theirs: "A\nB\nC2\nD\nE")
        let changes = blocks.filter(\.isChange)
        XCTAssertEqual(changes.map(\.suggested), [.mine, .theirs, .theirs])
        XCTAssertFalse(changes.contains(where: \.conflict))
        XCTAssertEqual(ParagraphMerge.result(blocks, picks: picks(blocks)), "A\nB2\nC2\nD\nE")
    }

    func testBothSidesRewritingAParagraphIsLeftToTheAuthor() {
        let blocks = ParagraphMerge.blocks(base: "A\nB", mine: "A\nB1", theirs: "A\nB2")
        let change = blocks.first(where: \.isChange)
        XCTAssertEqual(change?.conflict, true)
        XCTAssertNil(change?.suggested)
        XCTAssertEqual(ParagraphMerge.result(blocks, picks: [change!.id: .both]), "A\nB1\nB2")
    }

    func testADeletionOnOneSideIsSuggested() {
        let blocks = ParagraphMerge.blocks(base: "A\nB\nC", mine: "A\nB\nC", theirs: "A\nC")
        XCTAssertEqual(blocks.filter(\.isChange).map(\.suggested), [.theirs])
        XCTAssertEqual(ParagraphMerge.result(blocks, picks: picks(blocks)), "A\nC")
    }

    func testSlugs() {
        XCTAssertEqual(Pistes.slug("Sans le père", taken: []), "sans-le-pere")
        XCTAssertEqual(Pistes.slug("Sans le père", taken: ["sans-le-pere"]), "sans-le-pere-2")
        XCTAssertEqual(Pistes.slug("  !! ", taken: []), "piste")
    }

    /// A track is written into git without touching the book's folder, and taking it back is a real merge.
    func testTrackLivesInGitOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-pistes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitService(root: root)
        try git.initRepo()
        let file = root.appendingPathComponent("01.md")
        try "Un.\n\nDeux.\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try git.commit(paths: ["01.md"], message: "first"))

        try git.createBranch("piste/essai", at: "HEAD")
        let start = git.resolve("piste/essai")
        XCTAssertTrue(try git.commit(onBranch: "piste/essai", files: ["01.md": "Un.\n\nTrois.\n"], message: "in the track"))
        XCTAssertFalse(try git.commit(onBranch: "piste/essai", files: ["01.md": "Un.\n\nTrois.\n"], message: "same"))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Un.\n\nDeux.\n")
        XCTAssertEqual(git.show("piste/essai", path: "01.md"), "Un.\n\nTrois.\n")
        XCTAssertEqual(git.currentBranch, "master")
        XCTAssertNotEqual(git.resolve("piste/essai"), start)
        XCTAssertFalse(git.isAncestor("piste/essai", of: "HEAD"))

        try "Un.\n\nTrois.\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(try git.commit(paths: ["01.md"], message: "reprise", merging: "piste/essai"))
        XCTAssertTrue(git.isAncestor("piste/essai", of: "HEAD"))
        XCTAssertEqual(git.points("HEAD").first?.parents.count, 2)
        XCTAssertEqual(git.points("HEAD").count, 2, "first parents only")
        XCTAssertEqual(git.changedPaths("HEAD"), ["01.md"])

        try git.createTag("jalon/envoi", message: "Envoyé\n\nÀ l’éditeur.")
        let tag = try XCTUnwrap(git.tags(matching: "jalon/*").first)
        XCTAssertEqual(tag.title, "Envoyé")
        XCTAssertEqual(tag.note, "À l’éditeur.")
        XCTAssertEqual(tag.commit, git.resolve("HEAD"))
    }
}

@MainActor
final class PisteSessionTests: XCTestCase {
    /// Writing in a track leaves the book's folder alone; taking it back writes the choices and joins the lines.
    func testWriteInATrackThenTakeItBack() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-piste-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("01.md")
        try "Un.\n\nDeux.\n\nTrois.\n".write(to: file, atomically: true, encoding: .utf8)
        let git = GitService(root: root)
        try git.initRepo()
        try git.commit(paths: ["01.md"], message: "first")
        let manifest = BookManifest(title: "T", chapters: [ChapterEntry(id: "01", file: "01.md", title: "Un")])
        let session = BookSession(root: root, manifest: manifest)

        session.newPiste(named: "Sans le père", fromLabel: "le manuscrit")
        XCTAssertEqual(session.piste?.id, "sans-le-pere")
        XCTAssertEqual(session.reference, L("The manuscript"))
        session.textDidChange("Un.\nDeux, autrement.\nTrois.\n")
        session.flushSave()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Un.\n\nDeux.\n\nTrois.\n", "the folder holds the manuscript")
        session.commitNow("musset: edit 01")
        XCTAssertEqual(git.show("piste/sans-le-pere", path: "01.md"), "Un.\n\nDeux, autrement.\n\nTrois.\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/musset/pistes/sans-le-pere/01.md").path))

        session.enter(nil)
        XCTAssertEqual(session.text, "Un.\nDeux.\nTrois.\n")
        session.textDidChange("Un, ailleurs.\nDeux.\nTrois.\n")
        session.flushSave()

        let p = try XCTUnwrap(session.piste ?? session.pistes.first)
        let chapters = session.prepareTakeBack(p)
        XCTAssertEqual(chapters.map(\.id), ["01"])
        let blocks = chapters[0].blocks
        let picks = Dictionary(uniqueKeysWithValues: blocks.compactMap { b in b.suggested.map { (b.id, $0) } })
        XCTAssertEqual(picks.count, blocks.filter(\.isChange).count, "each side changed a different paragraph")
        session.takeBack(p, chapters: ["01": ParagraphMerge.result(blocks, picks: picks)])
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Un, ailleurs.\n\nDeux, autrement.\n\nTrois.\n")
        XCTAssertTrue(session.isTakenBack(p))
        XCTAssertEqual(git.points("HEAD").first?.parents.count, 2)

        session.addJalon(title: "Premier jet", note: "")
        XCTAssertEqual(session.jalons.map(\.title), ["Premier jet"])

        // The book as at the milestone, while the manuscript moves on.
        session.textDidChange("Un, encore.\nDeux, autrement.\nTrois.\n")
        session.flushSave()
        var store = session.store
        store.revision = session.jalons[0].commit
        XCTAssertEqual(store.read(manifest.chapters[0]), "Un, ailleurs.\n\nDeux, autrement.\n\nTrois.\n")

        // A blank page: the chapter starts over in the track, the folder keeps the manuscript.
        session.newPiste(named: "Autre", fromLabel: "le manuscrit", opening: session.blankPage)
        XCTAssertEqual(session.text, "")
        XCTAssertEqual(session.referenceText, "Un, encore.\nDeux, autrement.\nTrois.\n")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Un, encore.\n\nDeux, autrement.\n\nTrois.\n")
    }
}

@MainActor
final class PisteSnapshotTests: XCTestCase {
    /// The history and the take-back screen on a copy of a real chapter, dark, in French. MUSSET_SNAPSHOT=<dir>.
    func testPisteSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["MUSSET_SNAPSHOT"] else { throw XCTSkip("set MUSSET_SNAPSHOT") }
        let d = UserDefaults.standard
        let old = d.string(forKey: UILang.key)
        defer { d.set(old, forKey: UILang.key) }
        d.set("fr", forKey: UILang.key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-piste-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/conatus/07_marx_dormoy.md")
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("07.md"))
        let git = GitService(root: root)
        try git.initRepo()
        try git.commit(paths: ["07.md"], message: "musset: edit 07")
        let session = BookSession(root: root, manifest: BookManifest(title: "Le Sel", lang: "fr", chapters: [ChapterEntry(id: "07", file: "07.md", title: "Marx Dormoy")]))
        session.addJalon(title: "Envoyé à l’éditeur", note: "La version longue.")
        session.newPiste(named: "Sans le père", fromLabel: "le manuscrit")
        var lines = session.text.components(separatedBy: "\n")
        lines[1] = "Je me suis réveillé vers quatorze heures. Sur la table, rien, pas un mot."
        lines[2] = "En bas, il y avait des voix. Chemdi parlait fort, comme toujours ; mon père n’était pas là pour le faire taire."
        lines.insert("Personne ne demandait où était le père. On avait arrêté de demander.", at: 5)
        session.textDidChange(lines.joined(separator: "\n"))
        session.commitNow("musset: edit 07")
        session.enter(nil)
        var mine = session.text.components(separatedBy: "\n")
        mine[3] = mine[3] + " Personne n’a levé la tête."
        session.textDidChange(mine.joined(separator: "\n"))
        session.flushSave()
        session.commitNow("musset: edit 07")
        let app = AppState()

        func png(_ view: some View, _ size: NSSize, _ name: String) throws {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, .dark))
            host.appearance = NSAppearance(named: .darkAqua)
            host.frame = NSRect(origin: .zero, size: size)
            let w = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: .darkAqua)
            w.contentView = host
            RunLoop.main.run(until: Date().addingTimeInterval(0.8))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
        }
        try png(StoryView(app: app, session: session), NSSize(width: 1320, height: 820), "p-story.png")
        try png(TakeBackView(session: session, piste: session.pistes[0]), NSSize(width: 1300, height: 860), "p-takeback.png")
        try png(NewPisteSheet(session: session, start: TrackStart()), NSSize(width: 520, height: 470), "p-new.png")
        try png(TrackChip(app: app, piste: session.pistes[0]).padding(20), NSSize(width: 240, height: 70), "p-chip.png")
    }
}
