import Foundation
import Observation

/// One chapter open for writing: its text as the editor shows it, whether it has changed since the last save, and its
/// notes. Several can be open at once (one per pane that shows a chapter); the session says which one the author is in.
@MainActor
@Observable
final class ChapterDoc: Identifiable {
    let chapterID: String
    /// The chapter in editor form (one line per paragraph).
    var text: String = ""
    /// The chapter's notes, anchored in this text.
    let notes: NoteStore
    /// Its versions by name (the manuscript's; a track has none), listed when one goes to the chapter.
    var versions: [String] = []
    /// The version shown read-only beside its editor, and that version's text.
    var reference: String?
    var referenceText = ""
    @ObservationIgnored var dirty = false
    /// Where the page was scrolled, so going back to its tab shows the same place (not the caret's).
    @ObservationIgnored var scrollY: CGFloat?
    @ObservationIgnored var saveTask: Task<Void, Never>?

    nonisolated var id: String { chapterID }

    init(chapterID: String, root: URL) {
        self.chapterID = chapterID
        self.notes = NoteStore(root: root)
    }
}
