import Foundation

/// Tracks and milestones: writing in a parallel draft of the book, taking it back, marking moments.
extension BookSession {
    /// A chapter of a track to take back: its paragraphs against the manuscript's.
    struct MergeChapter: Identifiable {
        let id: String
        let title: String
        let blocks: [ParagraphMerge.Block]
        var changes: Int { blocks.filter(\.isChange).count }
    }

    /// Operations that write the book's folder (versions, typography, scene markers) wait for the manuscript.
    func inManuscript() -> Bool {
        guard piste != nil else { return true }
        lastError = L("Go back to the manuscript to do this: in a track, the book's folder doesn't change.")
        return false
    }

    /// What was written is saved and committed before moving between lines.
    private func settle() {
        flushSave()
        commitIfPending(message: editMessage)
        commitBesideTrack()
    }

    /// In a track, commits go to the track's line and hold its chapters only. What else was written meanwhile in the
    /// book's folder (its settings, notes, the plot) is committed on the manuscript when the track is left or the book closed.
    func commitBesideTrack() {
        if piste != nil { commitManuscript("musset: notes et réglages") }
    }

    func refreshTracks() {
        pistes = Pistes.load(root)
        jalons = git.tags(matching: "jalon/*")
    }

    /// The tracks to show: not put away, newest first.
    var openPistes: [Piste] { pistes.filter { $0.shelved != true }.sorted { $0.created > $1.created } }

    /// True once everything a track holds is in the manuscript (it was taken back and not written in since).
    func isTakenBack(_ p: Piste) -> Bool {
        guard let tip = git.resolve(p.branch), tip != p.start else { return false }
        return git.isAncestor(tip, of: "HEAD")
    }

    /// Leaves the manuscript or a track for another (nil: the manuscript). What was written is committed first.
    func enter(_ target: Piste?) {
        guard target?.id != piste?.id else { return }
        settle()
        piste = target
        rememberPiste(target?.id)
        manuscriptBeside = true
        if let ch = selectedChapter { load(ch) }
        countAllWords()
    }

    /// Opens a track at `rev` (the manuscript now, a milestone, a past session) and writes in it.
    /// With `opening`, the open chapter starts from that text in the track (a blank page, a version).
    func newPiste(named name: String, from rev: String = "HEAD", fromLabel: String, opening: String? = nil) {
        guard git.isRepo else {
            lastError = L("This book has no history yet.")
            return
        }
        settle()
        let slug = Pistes.slug(name, taken: Set(pistes.map(\.id) + git.branches().compactMap { $0.hasPrefix("piste/") ? String($0.dropFirst(6)) : nil }))
        var p = Piste(id: slug, name: name.trimmingCharacters(in: .whitespaces), created: Date(), from: fromLabel)
        do {
            try git.createBranch(p.branch, at: rev)
            p.start = git.resolve(p.branch)
            pistes.append(p)
            try Pistes.save(pistes, root: root)
            commitManuscript("musset: piste « \(p.name) »")
            enter(p)
            if let opening { replaceText(opening); commitNow(editMessage) }
        } catch { lastError = error.localizedDescription }
    }

    /// The open chapter as a blank page that keeps its title line.
    var blankPage: String {
        let first = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return first.hasPrefix("#") ? first + "\n" : ""
    }

    /// A version of the open chapter, as a track of the whole book where that chapter reads as the version.
    func versionAsPiste(_ version: String) {
        guard piste == nil, let ch = selectedChapter else { return }
        let body = ParagraphCodec.decode(store.readVersion(ch, version))
        newPiste(named: "\(ch.title) · \(version)", fromLabel: L("the version \(version)"), opening: body)
    }

    /// Puts a track away (or back): its branch stays, it leaves the list.
    func shelve(_ p: Piste, _ shelved: Bool = true) {
        guard let i = pistes.firstIndex(where: { $0.id == p.id }) else { return }
        if shelved, piste?.id == p.id { enter(nil) }
        pistes[i].shelved = shelved ? true : nil
        do { try Pistes.save(pistes, root: root); commitManuscript("musset: piste « \(p.name) » \(shelved ? "rangée" : "ressortie")") }
        catch { lastError = error.localizedDescription }
    }

    func renamePiste(_ p: Piste, to name: String) {
        guard let i = pistes.firstIndex(where: { $0.id == p.id }), !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        pistes[i].name = name.trimmingCharacters(in: .whitespaces)
        if piste?.id == p.id { piste = pistes[i] }
        do { try Pistes.save(pistes, root: root) } catch { lastError = error.localizedDescription }
        pendingCommit = true
    }

    /// Commits what was written in the track onto its branch; the book's folder is not touched.
    func commitPiste(_ message: String) {
        guard let piste else { return }
        let dir = Pistes.cacheDir(root, piste)
        var files: [String: String] = [:]
        if let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let u as URL in e where (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                let path = String(u.standardizedFileURL.path.dropFirst(dir.standardizedFileURL.path.count + 1))
                if let s = try? String(contentsOf: u, encoding: .utf8) { files[path] = s }
            }
        }
        pendingCommit = false
        guard !files.isEmpty else { return }
        do {
            if try git.commit(onBranch: piste.branch, files: files, message: message) {
                lastCommitAt = Date()
                Collab.shared.sync(self)
            }
            // In git now: the cache goes, unless written again meanwhile.
            for (path, content) in files {
                let u = dir.appendingPathComponent(path)
                if (try? String(contentsOf: u, encoding: .utf8)) == content { try? FileManager.default.removeItem(at: u) }
            }
        } catch {
            lastError = "git: \(error.localizedDescription)"
            pendingCommit = true
        }
    }

    /// A commit on the manuscript, whichever line one is writing in.
    func commitManuscript(_ message: String, merging: String? = nil) {
        guard git.isRepo else { return }
        do {
            if try git.commit(paths: trackedPaths, message: message, merging: merging) {
                lastCommitAt = Date()
                Collab.shared.sync(self)
            }
        } catch { lastError = "git: \(error.localizedDescription)" }
    }

    // MARK: Taking a track back

    /// Back to the manuscript, everything committed, and the chapters where the track differs.
    func prepareTakeBack(_ p: Piste) -> [MergeChapter] {
        enter(nil)
        settle()
        let base = git.mergeBase("HEAD", p.branch)
        return manifest.chapters.compactMap { ch in
            guard let theirsDisk = git.show(p.branch, path: ch.file) else { return nil }
            let before = base.flatMap { git.show($0, path: ch.file) } ?? ""
            guard theirsDisk != before else { return nil }
            let mine = ParagraphCodec.decode(store.read(ch)), theirs = ParagraphCodec.decode(theirsDisk)
            guard mine != theirs else { return nil }
            let blocks = ParagraphMerge.blocks(base: ParagraphCodec.decode(before), mine: mine, theirs: theirs)
            return MergeChapter(id: ch.id, title: ch.title, blocks: blocks)
        }
    }

    /// Writes the chosen chapters (editor form) into the manuscript, as one commit that joins the track's line:
    /// a real merge, visible to any git tool.
    func takeBack(_ p: Piste, chapters: [String: String]) {
        enter(nil)
        for (id, chosen) in chapters {
            guard let ch = manifest.chapters.first(where: { $0.id == id }) else { continue }
            do { try writeChapterText(id, chosen) }
            catch { lastError = L("Could not save \(ch.file): \(error.localizedDescription)"); return }
        }
        commitManuscript("musset: reprise de la piste « \(p.name) »", merging: p.branch)
        pendingCommit = false
        countAllWords()
        if let ch = selectedChapter { notes.resolveAll(in: editorText(of: ch.id)) }
    }

    // MARK: Bringing things back

    /// The differences between the manuscript and a past state or a track, chapter by chapter.
    /// With `base`, what happened between `base` and `rev` comes chosen, as a pick of that sitting's work;
    /// without, the manuscript stays unless the author picks otherwise.
    func prepareBring(rev: String, base: String?, chapters ids: [String]? = nil) -> [MergeChapter] {
        flushSave()
        commitIfPending(message: editMessage)
        return manifest.chapters.compactMap { ch in
            if let ids, !ids.contains(ch.id) { return nil }
            guard let disk = git.show(rev, path: ch.file) else { return nil }
            let theirs = ParagraphCodec.decode(disk), mine = editorText(of: ch.id)
            guard mine != theirs else { return nil }
            let older = base.flatMap { git.show($0, path: ch.file) }.map(ParagraphCodec.decode) ?? theirs
            if base != nil, older == theirs { return nil }
            let blocks = ParagraphMerge.blocks(base: older, mine: mine, theirs: theirs)
            return blocks.contains(where: \.isChange) ? MergeChapter(id: ch.id, title: ch.title, blocks: blocks) : nil
        }
    }

    /// Writes the chosen chapters as one commit.
    func applyBring(_ chapters: [String: String], message: String) {
        for (id, chosen) in chapters {
            guard chosen != editorText(of: id), let ch = manifest.chapters.first(where: { $0.id == id }) else { continue }
            do { try writeChapterText(id, chosen) }
            catch { lastError = L("Could not save \(ch.file): \(error.localizedDescription)"); return }
        }
        pendingCommit = true
        commitNow(message)
        countAllWords()
    }

    /// What going back would do to one chapter.
    func goBackPreview(to rev: String, chapters ids: [String]) -> (words: Int, chapters: Int, lostNotes: Int) {
        var words = 0, changed = 0, lost = 0
        for ch in manifest.chapters where ids.contains(ch.id) {
            guard let disk = git.show(rev, path: ch.file) else { continue }
            let old = ParagraphCodec.decode(disk), now = editorText(of: ch.id)
            guard old != now else { continue }
            changed += 1
            words += BookStore.wordCount(old) - BookStore.wordCount(now)
            lost += noteStore(for: ch.id).notes(of: ch.id).filter { $0.status == .open && !$0.anchor.quote.isEmpty && Anchoring.resolve($0.anchor, in: now) != nil && Anchoring.resolve($0.anchor, in: old) == nil }.count
        }
        return (words, changed, lost)
    }

    /// Goes back to a past state by moving forward: a milestone first, then a new commit holding the old text. Nothing is erased.
    /// Notes, the Bible and settings stay. `order`: the chapters' order too (the whole manuscript).
    func goBack(to rev: String, label: String, chapters ids: [String], order: Bool) {
        guard inManuscript() else { return }
        flushSave()
        commitIfPending(message: editMessage)
        addJalon(title: L("Before going back to \(label)"), note: "")
        for ch in manifest.chapters where ids.contains(ch.id) {
            guard let disk = git.show(rev, path: ch.file) else { continue }
            do { try writeChapterText(ch.id, ParagraphCodec.decode(disk), file: disk) }
            catch { lastError = L("Could not save \(ch.file): \(error.localizedDescription)"); return }
        }
        if order, let data = git.data(rev, path: ".musset/book.json"), let old = try? JSONDecoder().decode(BookManifest.self, from: data) {
            let rank = Dictionary(old.chapters.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            manifest.chapters = manifest.chapters.enumerated().sorted { (rank[$0.element.id] ?? Int.max, $0.offset) < (rank[$1.element.id] ?? Int.max, $1.offset) }.map(\.element)
            saveManifest()
        }
        pendingCommit = true
        commitNow("musset: back to \(rev.prefix(7))")
        countAllWords()
        if let ch = selectedChapter { notes.resolveAll(in: editorText(of: ch.id)) }
    }

    // MARK: Milestones

    /// Marks the manuscript as it is now (or at `rev`) with a milestone: an annotated git tag.
    func addJalon(title: String, note: String, at rev: String = "HEAD") {
        guard git.isRepo else { return }
        settle()
        let taken = Set(jalons.map { String($0.id.dropFirst(6)) })
        let name = "jalon/" + Pistes.slug(title, taken: taken)
        let message = title.trimmingCharacters(in: .whitespaces) + (note.isEmpty ? "" : "\n\n" + note)
        do { try git.createTag(name, message: message, at: rev) } catch { lastError = error.localizedDescription }
        refreshTracks()
        Collab.shared.sync(self)
    }

    func removeJalon(_ tag: GitService.Tag) {
        do { try git.deleteTag(tag.id) } catch { lastError = error.localizedDescription; return }
        refreshTracks()
        Collab.shared.sync(self, removed: ["refs/tags/\(tag.id)"])
    }
}
