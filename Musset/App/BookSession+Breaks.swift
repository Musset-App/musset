import Foundation

/// A chapter split by Return (see `Breaks`), and its undo.
extension BookSession {
    /// What ⌘Z needs to put a split back: the chapter split, its text before, and the chapter made from it.
    struct ChapterSplit: Equatable {
        let chapter: String
        let original: String
        let created: String
    }

    /// Whether the open chapter can be split here: the book's own chapters, not a track or another version.
    var canSplitChapter: Bool {
        piste == nil && openAlternate == nil && selectedChapterID.map { id in manifest.chapters.contains { $0.id == id } } == true
    }

    /// Splits the open chapter: `before` stays in it, `after` becomes the next chapter, titled by its number in the
    /// book's language. Opens the new chapter with its title selected. Returns what undoes it.
    @discardableResult
    func splitChapter(before: String, after: String) -> ChapterSplit? {
        guard canSplitChapter, let id = selectedChapterID, let i = manifest.chapters.firstIndex(where: { $0.id == id }) else { return nil }
        let original = text
        let title = manifest.newPieceTitle(i + 2)
        let entry = newChapterEntry(title: title)
        do {
            try store.write(ParagraphCodec.encode("# \(title)\n" + after), to: entry)
        } catch {
            lastError = L("Could not save \(entry.file): \(error.localizedDescription)")
            return nil
        }
        textDidChange(before)
        flushSave()
        manifest.chapters.insert(entry, at: i + 1)
        chapterCounts[entry.id] = TextCounts(after)
        saveManifest()
        commitNow("musset: split \(id) → \(entry.id)")
        let split = ChapterSplit(chapter: id, original: original, created: entry.id)
        open(entry.id)
        pendingSelection = NSRange(location: 2, length: (title as NSString).length)
        pendingSplitUndo = split
        return split
    }

    /// Puts a split back: the new chapter's file goes (Musset made it a moment ago), the chapter gets its text back.
    func undoSplit(_ split: ChapterSplit) {
        guard let created = manifest.chapters.first(where: { $0.id == split.created }),
              manifest.chapters.contains(where: { $0.id == split.chapter }) else { return }
        open(split.chapter)
        try? FileManager.default.removeItem(at: store.url(for: created))
        manifest.chapters.removeAll { $0.id == created.id }
        chapterCounts[created.id] = nil
        saveManifest()
        textDidChange(split.original)
        flushSave()
        commitNow("musset: unsplit \(split.chapter)")
    }
}
