import Foundation

/// `.musset/book.json` — the single source of truth for what the app shows.
struct BookManifest: Codable, Equatable {
    var title: String
    var author: String = NSFullUserName()
    var lang: String = "fr"
    var contact: String = ""
    var chapters: [ChapterEntry]
    var exports: [ExportPreset] = []
    var formatVersion: Int = 1
    /// What a change of scene looks like on the page; nil reads as nothing.
    var sceneBreak: SceneBreak? = nil
    var subtitle: String? = nil
    /// Word goal for the book, shown against the count.
    var goal: Int? = nil
    /// Cover, title page, dedication… (see FrontMatter).
    var front: FrontMatter? = nil
    /// On the home screen; nil reads as in progress.
    var shelf: Shelf? = nil
    /// The genre chosen at creation: a rubric preset's id.
    var genre: String? = nil
    /// Chapters set aside: out of the book's count and export, files where they were.
    var drafts: [ChapterEntry]? = nil
    /// The book's parts (I, II, III…), numbered by where their first chapter stands. Chapters name theirs.
    var parts: [BookPart]? = nil
}

struct ChapterEntry: Codable, Equatable, Identifiable, Hashable {
    /// Stable id = canonical file name without extension, e.g. "01_the_ferry".
    var id: String
    /// Path of the canonical file, relative to the book folder. Always holds the active version.
    var file: String
    var title: String
    /// Name of the version currently in `file`. Alternates live in `.musset/versions/<id>/<name>.md`.
    var activeVersion: String = "main"
    var excludeFromExport: Bool = false
    /// Where the chapter stands; nil reads as draft.
    var status: ChapterStatus? = nil
    /// The part it belongs to (a `BookPart` id); nil outside any part.
    var part: String? = nil
}

/// A chapter's progress, in order.
enum ChapterStatus: String, Codable, CaseIterable, Identifiable {
    case draft, done, edited, final
    var id: String { rawValue }
    var label: String {
        switch self {
        case .draft: L("Draft")
        case .done: L("Done", ctx: "Écrit")
        case .edited: L("Edited")
        case .final: L("Final")
        }
    }
    var help: String {
        switch self {
        case .draft: L("Being written")
        case .done: L("First version finished")
        case .edited: L("Revised after critique")
        case .final: L("Ready, nothing more to change")
        }
    }
}

enum ExportFormat: String, Codable, CaseIterable {
    case pdf, docx, epub
}

struct ExportPreset: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var format: ExportFormat
    /// Template path relative to the book folder: reference doc for DOCX, CSS for EPUB. For PDF, an old LaTeX template
    /// only says which Typst style to use (blanche or classique).
    var template: String?
    /// LaTeX geometry string, e.g. "paperwidth=148mm,paperheight=210mm,…".
    var geometry: String?
    var fontSize: String?
    var numberSections: Bool = true
    var cropMarks: Bool = false
    var includeContact: Bool = false
    var extraArgs: [String] = []
    /// Formerly the PDF engine ("latex" or "typst"): PDF is always Typst now. Still read so old books load.
    var engine: String? = nil
    /// PDF only: facing pages, as a printed book; single pages (nil) have the same margin left and right.
    var facing: Bool? = nil
    /// PDF only: a manuscript for submission, by a country's norm (Typst's `manuscript` style).
    var manuscript: ManuscriptNorm? = nil
    /// A manuscript sent under a pseudonym (literary prizes): no name, no contact, the pseudonym instead.
    var pseudonym: String? = nil

    var usesTypst: Bool { format == .pdf }
    /// Which Typst style matches the preset's LaTeX template.
    var typstStyle: String {
        if manuscript != nil { return "manuscript" }
        return (template ?? id).lowercased().contains("blanche") ? "blanche" : "classique"
    }
    /// The name in the interface's language: a built-in preset's English name is a key of the tables; a name the author typed has none and shows as is.
    var shownName: String { L(dynamic: name) }
}

/// Per-machine UI state, git-ignored: `.musset/state.json`.
struct BookUIState: Codable {
    var lastChapter: String?
    var selections: [String: Int] = [:]
    /// The version shown read-only beside each chapter's editor, if any.
    var references: [String: String]? = nil
    /// The version open in each chapter's editor when it isn't the book's.
    var openVersions: [String: String]? = nil
    /// The track being written in, if not the manuscript.
    var piste: String? = nil
}
