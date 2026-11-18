#if DEBUG
import MussetPage
import SwiftUI

/// The new reading engine on a fixture book, with sample marks: Debug ▸ Reading Engine Demo. Not in release builds.
struct PageDemo: View {
    static let windowID = "musset-page-demo"
    @State private var model: ReaderModel?
    @State private var problem: String?

    var body: some View {
        Group {
            if let model {
                PageView(model: model)
                    .toolbar {
                        ToolbarItemGroup {
                            Picker("Page", selection: Binding(get: { model.fit }, set: { model.fit = $0 })) {
                                Text("Reflow").tag(PageFit.reflow)
                                Text("Print").tag(PageFit.print)
                            }
                            .pickerStyle(.segmented)
                            ReaderControls(model: model)
                        }
                    }
                    .navigationTitle(model.source.title + " · " + model.pageLabel)
            } else if let problem {
                Text(problem).foregroundStyle(.secondary).padding()
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .task { load() }
    }

    private func load() {
        guard model == nil else { return }
        guard let dir = Self.fixture() else { problem = "No fixture book: put one in fixtures/ (conatus, europa, brainiacs)."; return }
        guard let template = Bundle.main.url(forResource: "musset", withExtension: "typ").flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else {
            problem = "musset.typ is not in the app."; return
        }
        let manifest = (try? Data(contentsOf: dir.appendingPathComponent(".musset/book.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        let listed = (manifest["chapters"] as? [[String: Any]] ?? []).filter { ($0["excludeFromExport"] as? Bool) != true }
            .compactMap { c -> (String, String)? in (c["id"] as? String).flatMap { id in (c["file"] as? String).map { (id, $0) } } }
        let files = listed.isEmpty
            ? ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") && $0.first?.isNumber == true }.sorted()
                .map { (String($0.dropLast(3)), $0) }
            : listed
        let chapters = files.compactMap { id, file in
            (try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)).map { BookSource.Chapter(id: id, markdown: $0) }
        }
        guard !chapters.isEmpty else { problem = "\(dir.lastPathComponent) has no chapters."; return }
        let fonts = [Bundle.main.resourceURL, URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Fonts"),
                     dir.appendingPathComponent("fonts")].compactMap { $0 }
        let source = BookSource(chapters: chapters, template: template, title: manifest["title"] as? String ?? dir.lastPathComponent,
                                author: "Musset", lang: manifest["lang"] as? String ?? "fr",
                                layout: PageLayout(paper: ("130mm", "200mm"), margins: ["inside": "20mm", "outside": "15mm", "top": "17mm", "bottom": "21mm"],
                                                   size: "10.8pt", numbered: false, titlePage: false),
                                sceneBreak: manifest["sceneBreak"] as? String, fontDirectories: fonts)
        let m = ReaderModel(source: source, marks: Self.sampleMarks(chapters))
        m.onAction = { [weak m] action, sel in
            guard let m else { return }
            let id = UUID().uuidString
            switch action {
            case .highlight(let ink): m.marks.append(MussetPage.Mark(id: id, chapter: sel.chapter, range: sel.range, kind: .highlight, ink: ink, person: "You"))
            case .underline: m.marks.append(MussetPage.Mark(id: id, chapter: sel.chapter, range: sel.range, kind: .underline, ink: .blue, person: "You"))
            case .strike: m.marks.append(MussetPage.Mark(id: id, chapter: sel.chapter, range: sel.range, kind: .strike, ink: .blue, person: "You"))
            case .note(let t): m.marks.append(MussetPage.Mark(id: id, chapter: sel.chapter, range: sel.range, kind: .note, ink: .blue, person: "You", note: t))
            case .suggest(let t):
                m.marks.append(MussetPage.Mark(id: id, chapter: sel.chapter, range: sel.range, kind: .strike, ink: .rose, person: "You", note: "→ " + t))
            }
        }
        // Open on the first margin note, among the sample marks.
        if let note = m.marks.first(where: { $0.note != nil }) {
            m.go(to: PageAnchor(chapter: note.chapter, offset: note.range.lowerBound))
        }
        if UserDefaults.standard.bool(forKey: "MussetPageDemoNight") { m.theme = .night }
        if case let page = UserDefaults.standard.integer(forKey: "MussetPageDemoPage"), page > 0 {
            // Once composed: a page number (from 1) to open on.
            Task { @MainActor in
                while m.book == nil || m.composing { try? await Task.sleep(for: .milliseconds(100)) }
                m.go(to: page - 1)
            }
        }
        model = m
    }

    /// fixtures/<book> beside the sources, walking up from this file (worktrees live inside the checkout).
    static func fixture() -> URL? {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            for book in ["conatus", "europa", "brainiacs"] {
                let u = dir.appendingPathComponent("fixtures/\(book)")
                if FileManager.default.fileExists(atPath: u.appendingPathComponent(".musset").path) { return u }
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Marks of three people on the opening chapters, on whatever words are there.
    static func sampleMarks(_ chapters: [BookSource.Chapter]) -> [MussetPage.Mark] {
        var out: [MussetPage.Mark] = []
        let samples: [(MussetPage.Mark.Kind, MussetPage.Ink, String, String?)] = [
            (.highlight, .amber, "Claire", nil),
            (.note, .amber, "Claire", "Why here? Name it earlier, or keep it vague."),
            (.underline, .teal, "Tom", nil),
            (.note, .teal, "Tom", "this line! keep it"),
            (.strike, .rose, "Inès", nil),
            (.highlight, .yellow, "Inès", nil),
            (.note, .blue, "Inès", "Trop long ? On pourrait couper ici."),
        ]
        for (ci, ch) in chapters.prefix(4).enumerated() {
            let ns = ch.markdown as NSString
            // Sentences of the chapter's prose, skipping headings and notes.
            var sentences: [NSRange] = []
            let re = try! NSRegularExpression(pattern: #"(?m)^(?![#>\-<\\]).{40,}$"#)
            for p in re.matches(in: ch.markdown, range: NSRange(location: 0, length: ns.length)).prefix(12) {
                let para = ns.substring(with: p.range) as NSString
                var start = 0
                para.enumerateSubstrings(in: NSRange(location: 0, length: para.length), options: .bySentences) { _, r, _, _ in
                    if r.length > 20 { sentences.append(NSRange(location: p.range.location + r.location, length: min(r.length, 90))) }
                    start += 1
                }
            }
            for (i, s) in samples.enumerated() where i * 2 + ci < sentences.count {
                let r = sentences[i * 2 + ci]
                out.append(MussetPage.Mark(id: "\(ch.id)-sample-\(i)", chapter: ch.id, range: r.location..<(r.location + r.length - 1),
                                kind: s.0, ink: s.1, person: s.2, note: s.3))
            }
        }
        return out
    }
}

/// Debug ▸ Reading Engine Demo. Launched with `-MussetPageDemo YES`, the window opens by itself.
struct PageDemoCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @MainActor private static var opened = false
    var body: some Commands {
        let _ = Self.openAtLaunch(openWindow)
        CommandMenu("Debug") {
            Button("Reading Engine Demo") { openWindow(id: PageDemo.windowID) }
        }
    }

    @MainActor private static func openAtLaunch(_ open: OpenWindowAction) {
        guard !opened, UserDefaults.standard.bool(forKey: "MussetPageDemo") else { return }
        opened = true
        DispatchQueue.main.async { open(id: PageDemo.windowID) }
    }
}
#endif
