import Foundation

/// Per-machine UI state, git-ignored: `.musset/state.json`.
struct BookUIState: Codable {
    /// The chapter one was in, as state files said it before the layout did: read, no longer written.
    private(set) var lastChapter: String?
    mutating func forgetOldLastChapter() { lastChapter = nil }
    var selections: [String: Int] = [:]
    /// The version shown read-only beside each chapter's editor, if any.
    var references: [String: String]? = nil
    /// The version open in each chapter's editor when it isn't the book's.
    var openVersions: [String: String]? = nil
    /// The track being written in, if not the manuscript.
    var piste: String? = nil
    /// The panes and tabs of the book's window.
    var layout: Workspace.Saved? = nil
    /// The book's other windows, by their id: each its own panes and tabs.
    var windows: [String: Workspace.Saved]? = nil
    /// Layouts the author named, to put back in any window.
    var layouts: [String: Workspace.Saved]? = nil
    /// The book's words when it was first opened today: what « today » counts from.
    var wordsBaseline: WordsBaseline? = nil
    /// Musset has spoken of the first chapter marked done: once per book.
    var firstChapterDone: Bool? = nil
    /// What the author chose for the book's last export, offered again the next time.
    var export: ExportChoice? = nil

    struct WordsBaseline: Codable, Equatable {
        var day: String
        var words: Int
        static var today: String { Date().formatted(.iso8601.year().month().day()) }
    }

    /// What Musset kept in the Mac's preferences under the book's folder path, before it was kept with the book:
    /// brought in once, and the old keys removed (there was one more words key per book per day).
    mutating func adoptOldPreferences(of root: URL, from defaults: UserDefaults = .standard) -> Bool {
        let path = root.standardizedFileURL.path
        var found = false
        let words = "wordsBaseline:\(path):"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(words) {
            let day = String(key.dropFirst(words.count))
            if wordsBaseline == nil, day == WordsBaseline.today, let n = defaults.object(forKey: key) as? Int { wordsBaseline = WordsBaseline(day: day, words: n) }
            defaults.removeObject(forKey: key)
            found = true
        }
        let done = "firstChapterDone:" + path
        if defaults.object(forKey: done) != nil {
            if firstChapterDone == nil, defaults.bool(forKey: done) { firstChapterDone = true }
            defaults.removeObject(forKey: done)
            found = true
        }
        let choice = "exportChoice:" + path
        if let data = defaults.data(forKey: choice) {
            if export == nil { export = try? JSONDecoder().decode(ExportChoice.self, from: data) }
            defaults.removeObject(forKey: choice)
            found = true
        }
        return found
    }
}

/// Everything the author chose for a book's last export: the format, the layout last used for each format, which
/// chapters and special pages, single or facing pages.
struct ExportChoice: Codable, Equatable {
    var format: String
    var layouts: [String: String]
    var scope: ChapterScopeMode
    var statuses: String
    var picked: [String]
    var specials: [String]
    var facing: Bool?
}

extension SpecialPage {
    var tab: PaneTab { .special(rawValue) }
}

extension ExportPreset {
    /// The template's style this layout is set in.
    var typstStyle: String { manuscript != nil ? "manuscript" : Typesetting.style(style ?? "fullpage") }
}
