import XCTest
import SwiftUI
@testable import Musset

/// Timings of a chapter switch on a copy of a real book (its notes and proofreading cache included). MUSSET_PERF=1.
@MainActor
final class PerformanceTests: XCTestCase {
    func ms(_ start: CFAbsoluteTime) -> String { String(format: "%6.1f ms", (CFAbsoluteTimeGetCurrent() - start) * 1000) }

    func testChapterSwitch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_PERF"] == "1")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-perf-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent(".musset"), withIntermediateDirectories: true)
        for f in try fm.contentsOfDirectory(atPath: fixture.path) where f.range(of: #"^\d\d_.*\.md$"#, options: .regularExpression) != nil {
            try fm.copyItem(at: fixture.appendingPathComponent(f), to: root.appendingPathComponent(f))
        }
        for f in ["book.json", "notes", "proof", "dictionary.txt", "proof-exceptions.json", "plot.json"] {
            try fm.copyItem(at: fixture.appendingPathComponent(".musset/\(f)"), to: root.appendingPathComponent(".musset/\(f)"))
        }
        let manifest = try BookStore(root: root).loadManifest()
        let session = BookSession(root: root, manifest: manifest)
        let ids = manifest.chapters.map(\.id)
        let bridge = EditorBridge()
        let proof = AutoProofreader()
        proof.bridge = bridge
        bridge.proof = proof
        proof.attach(session)
        session.open(ids[0])
        let host = NSHostingView(rootView: ZenEditorView(session: session, bridge: bridge, fontName: Typefaces.manuscript, fontSize: 17, columnWidth: 640,
                                                          focusMode: false, typewriter: false, lineNumbers: false).frame(width: 1000, height: 800))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        // Pieces, on the largest chapter.
        let big = manifest.chapters.max { session.store.read($0).count < session.store.read($1).count }!
        let raw = session.store.read(big)
        var t = CFAbsoluteTimeGetCurrent(); let text = ParagraphCodec.decode(raw); print("PERF decode            \(ms(t))  (\(big.file), \((text as NSString).length) chars)")
        t = CFAbsoluteTimeGetCurrent(); session.notes.load(chapter: big, text: text); print("PERF notes.load        \(ms(t))  (\(session.notes.notes.count) notes)")
        t = CFAbsoluteTimeGetCurrent(); session.notes.resolveAll(in: text); print("PERF notes.resolveAll  \(ms(t))")
        t = CFAbsoluteTimeGetCurrent(); _ = Scenes.parse(text); print("PERF scenes.parse      \(ms(t))")
        t = CFAbsoluteTimeGetCurrent(); _ = Revisions.hidden(in: text); print("PERF revisions.hidden  \(ms(t))")
        t = CFAbsoluteTimeGetCurrent(); _ = proof.paragraphs(of: text); print("PERF proof.paragraphs  \(ms(t))")
        t = CFAbsoluteTimeGetCurrent(); _ = proof.issues(in: text); print("PERF proof.issues      \(ms(t))")
        t = CFAbsoluteTimeGetCurrent(); _ = session.store.versions(of: big); print("PERF versions          \(ms(t))")
        let storage = NSTextStorage(string: text)
        t = CFAbsoluteTimeGetCurrent(); MarkdownStyler.style(storage, theme: EditorTheme(fontName: Typefaces.manuscript, fontSize: 17), caret: 0)
        print("PERF styler.style      \(ms(t))")
        guard let tv = bridge.textView else { return XCTFail("no text view") }
        t = CFAbsoluteTimeGetCurrent(); tv.restyle(); print("PERF tv.restyle        \(ms(t))")
        t = CFAbsoluteTimeGetCurrent(); tv.setSelectedRange(NSRange(location: 10, length: 0)); print("PERF setSelectedRange  \(ms(t))")
        t = CFAbsoluteTimeGetCurrent(); proof.selectionChanged(); print("PERF selectionChanged  \(ms(t))")

        // Whole switches: model, then the editor's update and first display.
        var total = 0.0
        for id in ids.prefix(12) {
            let t0 = CFAbsoluteTimeGetCurrent()
            session.open(id)
            let t1 = CFAbsoluteTimeGetCurrent()
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date())
            host.display()
            let t2 = CFAbsoluteTimeGetCurrent()
            total += t2 - t0
            print(String(format: "PERF switch %@  open %6.1f ms  editor %6.1f ms", id.padding(toLength: 28, withPad: " ", startingAt: 0), (t1 - t0) * 1000, (t2 - t1) * 1000))
        }
        print(String(format: "PERF switch average %.1f ms", total / Double(min(12, ids.count)) * 1000))
        try? fm.removeItem(at: root)
    }

    /// The commit made when leaving a chapter just written in, on a copy of a whole real book repository.
    func testCommitOnSwitch() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MUSSET_PERF"] == "1")
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("fixtures/conatus")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-perf-git-\(UUID().uuidString)")
        try FileManager.default.copyItem(at: fixture, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = try BookStore(root: root).loadManifest()
        let git = GitService(root: root)
        let paths = manifest.chapters.map(\.file) + [".musset"]
        for i in 0..<3 {
            let f = root.appendingPathComponent(manifest.chapters[i].file)
            try (String(contentsOf: f, encoding: .utf8) + "\nUne phrase de plus.\n").write(to: f, atomically: true, encoding: .utf8)
            let t = CFAbsoluteTimeGetCurrent()
            let made = try git.commit(paths: paths, message: "perf")
            print("PERF git.commit \(ms(t)) (made: \(made))")
        }
    }
}
