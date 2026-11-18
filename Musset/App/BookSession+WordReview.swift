import CryptoKit
import Foundation

extension BookSession {
    /// Reads a corrected Word file and works out what it would bring. Nothing changes yet.
    func wordReviewPlan(_ file: URL) async throws -> WordReview.Plan {
        guard inManuscript() else { throw NSError(domain: "Musset.word", code: 3, userInfo: [NSLocalizedDescriptionKey: lastError ?? ""]) }
        flushSave()
        let root = self.root
        let chapters = (manifest.chapters + draftChapters).map { (id: $0.id, title: $0.title, version: $0.activeVersion, text: editorText(of: $0.id)) }
        return try await Task.detached(priority: .userInitiated) {
            let data = try Data(contentsOf: file)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("musset-review-\(UUID())", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let unzip = try await Shell.runAsync("/usr/bin/unzip", ["-q", file.path, "-d", dir.path])
            guard unzip.ok else { throw NSError(domain: "Musset.word", code: 1, userInfo: [NSLocalizedDescriptionKey: L("This file could not be read as a .docx.")]) }
            let doc = try DocxContent.read(dir: dir)
            let sent = WordReview.sent(for: doc, among: WordManuscript.allSent(root: root))
            let previous = WordImports.load(root).last { $0.hash == hash }?.date
            return WordReview.plan(doc: doc, fileName: file.lastPathComponent, hash: hash, sent: sent, chapters: chapters, previousImport: previous)
        }.value
    }

    /// Writes the corrections into the chapters and the comments into the notes, all signed by the sender,
    /// after a milestone to come back to.
    func applyWordReview(_ plan: WordReview.Plan, sender: String) {
        guard inManuscript() else { return }
        let sender = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        flushSave()
        commitNow("musset: avant les corrections de \(sender) (\(plan.fileName))")
        addJalon(title: L("Before the corrections of \(sender)"), note: plan.fileName)
        func signed(_ list: [(reader: String, note: Note)]) -> [Note] {
            list.map { item in
                var n = item.note
                n.source = sender
                // A second person inside the file: the sender is who sent it, the words stay theirs.
                if !item.reader.isEmpty, item.reader != sender { n.body = "**\(item.reader)** : " + n.body }
                return n
            }
        }
        for c in plan.chapters {
            guard anyChapter(c.id) != nil else { continue }
            let text = c.text.replacingOccurrences(of: WordReview.senderSlot, with: Revisions.sourceTag(sender))
            if text != editorText(of: c.id) {
                do { try writeChapterText(c.id, text) }
                catch { lastError = error.localizedDescription; continue }
            }
            importNotes(signed(c.notes), chapter: c.id, from: sender)
            let notes = noteStore(for: c.id)
            for line in c.unplaced {
                let n = notes.addPlain(line, kind: .note, in: c.id)
                notes.change(n.id, in: c.id) { $0.source = sender }
            }
        }
        importNotes(signed(plan.bookNotes), chapter: NoteStore.bookPage, from: sender)
        try? WordImports.record(.init(hash: plan.hash, date: Date(), file: plan.fileName, source: sender), root: root)
        countAllWords()
        shelfChanges += 1
        commitNow("musset: corrections de \(sender) (\(plan.fileName))\n\nMusset-Author: \(sender)")
    }

    // MARK: Deciding from the Notes list

    /// Accepts or refuses one pending correction, wherever it is.
    func decide(_ item: Revisions.Pending, accept: Bool, bridge: EditorBridge) {
        decide(in: item.chapter, accept: accept, bridge: bridge) { $0.range.location == item.location }
    }

    /// Several at once: the ones shown, or all of one sender's.
    func decide(_ items: [Revisions.Pending], accept: Bool, bridge: EditorBridge) {
        for (chapter, list) in Dictionary(grouping: items, by: \.chapter) {
            let spots = Set(list.map(\.location))
            decide(in: chapter, accept: accept, bridge: bridge) { spots.contains($0.range.location) }
        }
    }

    private func decide(in chapter: String, accept: Bool, bridge: EditorBridge, matching: (Revisions.Mark) -> Bool) {
        if chapter == selectedChapterID, let tv = bridge.textView {
            tv.decideRevisions(accept: accept, matching: matching)
        } else if anyChapter(chapter) != nil {
            let out = Revisions.resolve(editorText(of: chapter), accept: accept, matching: matching)
            do { try writeChapterText(chapter, out) } catch { lastError = error.localizedDescription; return }
        }
        pendingCommit = true
        shelfChanges += 1
    }

    /// Everyone who has sent something back, for the sender field.
    var knownSenders: [String] {
        Array(Set(WordImports.load(root).compactMap(\.source))).sorted()
    }
}
