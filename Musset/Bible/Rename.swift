import Foundation

/// Renaming a character or a place everywhere at once: the chapters, the Bible, the notes and the plot, previewed
/// first, then written in one commit that one undo takes back.
struct RenamePlan {
    struct Hit: Identifiable, Hashable {
        let id = UUID()
        let chapter: String
        let range: NSRange
        /// The name as written there: the title, or one of its aliases.
        let form: String
        /// The sentence around it, for the preview.
        let before: String
        let after: String
        /// Certain enough to change without asking.
        let sure: Bool
        /// Why it is to check.
        let reason: String?
    }

    let entry: BibleEntry
    var newName: String
    /// What each alias becomes; an alias left as it is stays.
    var aliasTo: [String: String]
    let hits: [Hit]
    /// Hits the author unticked.
    var skipped: Set<UUID>
    /// How many places outside the chapters change: sheets, notes, the plot.
    var elsewhere: (bible: Int, notes: Int, plot: Int)

    var old: String { entry.title }
    var toCheck: [Hit] { hits.filter { !$0.sure } }
    var sure: [Hit] { hits.filter(\.sure) }

    /// The replacement for a form, or nil when it doesn't change.
    func replacement(for form: String) -> String? {
        let to = form == old ? newName.trimmingCharacters(in: .whitespaces) : (aliasTo[form] ?? form)
        return to.isEmpty || to == form ? nil : to
    }

    func applies(_ hit: Hit) -> Bool { !skipped.contains(hit.id) && replacement(for: hit.form) != nil }
    var count: Int { hits.filter(applies).count + elsewhere.bible + elsewhere.notes + elsewhere.plot }

    // MARK: Making the plan

    @MainActor
    static func make(_ entry: BibleEntry, to newName: String, in session: BookSession) -> RenamePlan {
        let matcher = NameMatcher(names: [(entry.path, entry.names)])
        let shared = session.bible.matcher.shared
        let texts = session.manifest.chapters.map { (id: $0.id, text: session.editorText(of: $0.id)) }
        // A name is only doubtful as a word if the book also writes it as one: « the rose », not just « Rose ».
        let lower = entry.title.lowercased()
        let usedAsWord = lower != entry.title && texts.contains { NameMatcher(names: [("w", [lower])]).matches(in: $0.text).count > 0 }
        var hits: [Hit] = []
        for (id, text) in texts {
            let ns = text as NSString
            for m in matcher.matches(in: text) {
                let form = ns.substring(with: m.range)
                var reason: String?
                if form != entry.title {
                    reason = L("Another name for them: choose what it becomes.")
                } else if shared.contains(form) {
                    reason = L("Another sheet has this name too.")
                } else if usedAsWord, Range(m.range, in: text).map({ NameSpotter.startsSentence(text, at: $0.lowerBound) }) == true
                            || usedAsWord && afterArticle(m.range, in: ns) {
                    reason = L("Also an ordinary word in the book: perhaps not them.")
                }
                let lo = max(0, m.range.location - 60), hi = min(ns.length, NSMaxRange(m.range) + 60)
                hits.append(Hit(chapter: id, range: m.range, form: form,
                                before: ns.substring(with: NSRange(location: lo, length: m.range.location - lo)),
                                after: ns.substring(with: NSRange(location: NSMaxRange(m.range), length: hi - NSMaxRange(m.range))),
                                sure: reason == nil, reason: reason))
            }
        }
        // To check is not ticked: the author decides each one.
        let skipped = Set(hits.filter { !$0.sure && $0.form == entry.title }.map(\.id))
        var plan = RenamePlan(entry: entry, newName: newName, aliasTo: [:], hits: hits, skipped: skipped, elsewhere: (0, 0, 0))
        plan.elsewhere = plan.countElsewhere(in: session)
        return plan
    }

    /// « the Rose fell »: after an article, a name is often the common word.
    private static func afterArticle(_ range: NSRange, in ns: NSString) -> Bool {
        guard range.location > 0 else { return false }
        let before = ns.substring(to: range.location).split(whereSeparator: { $0.isWhitespace }).last.map { String($0).lowercased() } ?? ""
        return ["the", "a", "an", "le", "la", "les", "un", "une", "der", "die", "das", "el", "il", "lo", "o", "os", "as"].contains(before)
    }

    @MainActor
    func countElsewhere(in session: BookSession) -> (bible: Int, notes: Int, plot: Int) {
        let forms = formsTo
        var bible = 0, notes = 0
        for e in session.bible.entries where !e.isFile {
            bible += Self.replace(in: e.body, forms).1 + e.fields.map { Self.replace(in: $0.value, forms).1 }.reduce(0, +)
            if e.path == entry.path, replacement(for: old) != nil { bible += 1 }
        }
        for ch in session.manifest.chapters.map(\.id) + ["_book"] {
            for n in session.noteStore(for: ch).notes(of: ch) {
                notes += Self.replace(in: n.body, forms).1 + n.replies.map { Self.replace(in: $0.body, forms).1 }.reduce(0, +)
            }
        }
        var plot = 0
        for text in Self.plotTexts(session.plot) { plot += Self.replace(in: text, forms).1 }
        if session.plot.tags.contains(where: { $0.column == "characters" && $0.name == old }) { plot += 1 }
        return (bible, notes, plot)
    }

    /// Form → what it becomes, for the forms that change.
    var formsTo: [String: String] {
        var out: [String: String] = [:]
        for form in entry.names { if let to = replacement(for: form) { out[form] = to } }
        return out
    }

    /// Replaces whole-word forms in a text; returns the text and how many changed.
    static func replace(in text: String, _ forms: [String: String]) -> (String, Int) {
        guard !forms.isEmpty else { return (text, 0) }
        let matcher = NameMatcher(names: forms.keys.map { ($0, [$0]) })
        let found = matcher.matches(in: text)
        guard !found.isEmpty else { return (text, 0) }
        let out = NSMutableString(string: text)
        for m in found.reversed() { out.replaceCharacters(in: m.range, with: forms[m.path] ?? m.path) }
        return (out as String, found.count)
    }

    static func plotTexts(_ plot: PlotGrid) -> [String] {
        [plot.synopsis ?? ""] + Array((plot.chapterSynopses ?? [:]).values)
            + plot.rows.values.flatMap { $0.values.flatMap { $0.cells.values.map(\.text) } }
    }
}

/// What a rename changed, to put it all back.
struct RenameUndo {
    let message: String
    let chapters: [(id: String, text: String)]
    let notes: [(chapter: String, notes: [Note])]
    let entries: [BibleEntry]
    let plot: PlotGrid
}

extension BookSession {
    /// Writes the plan everywhere, in one commit. Returns what it takes to undo it.
    @discardableResult
    func applyRename(_ plan: RenamePlan) -> RenameUndo? {
        guard inManuscript(), plan.count > 0 else { return nil }
        flushSave()
        commitIfPending(message: editMessage)
        // The grid's tag must be this sheet before the sheet changes its name, to follow it.
        bindPlot()
        let forms = plan.formsTo
        let message = "\(plan.old) → \(plan.replacement(for: plan.old) ?? plan.old)"
        var chapters: [(String, String)] = []
        var notesBefore: [(String, [Note])] = []
        var entriesBefore: [BibleEntry] = []
        let plotBefore = plot

        // The chapters: only the ticked places, from the end so the ranges hold.
        for ch in manifest.chapters {
            let picked = plan.hits.filter { $0.chapter == ch.id && plan.applies($0) }
            guard !picked.isEmpty else { continue }
            let text = editorText(of: ch.id)
            let out = NSMutableString(string: text)
            for h in picked.sorted(by: { $0.range.location > $1.range.location }) {
                out.replaceCharacters(in: h.range, with: plan.replacement(for: h.form) ?? h.form)
            }
            chapters.append((ch.id, text))
            do { try writeChapterText(ch.id, out as String) } catch { lastError = error.localizedDescription }
        }

        // The notes: their text, and their anchors, so they still find their passage.
        for ch in manifest.chapters.map(\.id) + ["_book"] {
            let list = noteStore(for: ch).notes(of: ch)
            var changed = false
            let renamed = list.map { n -> Note in
                var n = n
                let (body, c) = RenamePlan.replace(in: n.body, forms)
                if c > 0 { n.body = body; changed = true }
                n.replies = n.replies.map { r in
                    var r = r
                    let (t, c) = RenamePlan.replace(in: r.body, forms)
                    if c > 0 { r.body = t; changed = true }
                    return r
                }
                for path in [\NoteAnchor.quote, \NoteAnchor.prefix, \NoteAnchor.suffix] {
                    let (t, c) = RenamePlan.replace(in: n.anchor[keyPath: path], forms)
                    if c > 0 { n.anchor[keyPath: path] = t; changed = true }
                }
                return n
            }
            if changed {
                notesBefore.append((ch, list))
                noteStore(for: ch).replaceAll(renamed, in: ch)
            }
        }
        if let open = selectedChapterID { notes.resolveAll(in: editorText(of: open)) }

        // The Bible: the sheet's own title, and every sheet's text.
        for e in bible.entries where !e.isFile {
            var next = e
            next.body = RenamePlan.replace(in: e.body, forms).0
            next.fields = e.fields.map { .init(name: $0.name, value: RenamePlan.replace(in: $0.value, forms).0) }
            if e.path == plan.entry.path {
                next.title = plan.replacement(for: e.title) ?? e.title
                next.aliases = e.aliases.map { plan.replacement(for: $0) ?? $0 }
            }
            if next != e {
                entriesBefore.append(e)
                try? bible.store.write(next)
            }
        }
        bible.reload()

        // The plot: the grid's tag is the sheet, and took its new title when the Bible was read again. What the
        // readings had found for it follows the text; then the synopses and the cells.
        if var list = plot.index {
            for i in list.indices where list[i].sheet == plan.entry.path {
                list[i].aliases = list[i].aliases.filter { $0 != plan.old }.map { plan.replacement(for: $0) ?? $0 }
            }
            plot.index = list
            bindPlot()
        }
        if let s = plot.synopsis { plot.synopsis = RenamePlan.replace(in: s, forms).0 }
        plot.chapterSynopses = plot.chapterSynopses?.mapValues { RenamePlan.replace(in: $0, forms).0 }
        for (ch, scenes) in plot.rows {
            for (key, row) in scenes {
                for (col, cell) in row.cells {
                    let (t, c) = RenamePlan.replace(in: cell.text, forms)
                    if c > 0 { plot.rows[ch]?[key]?.cells[col]?.text = t }
                }
            }
        }
        if plot != plotBefore { savePlot() }

        pendingCommit = true
        commitNow("musset: rename \(message)")
        refreshBibleMentions()
        return RenameUndo(message: message, chapters: chapters, notes: notesBefore, entries: entriesBefore, plot: plotBefore)
    }

    /// Puts everything back as it was before the rename, in one commit.
    func undoRename(_ undo: RenameUndo) {
        flushSave()
        for (id, text) in undo.chapters { try? writeChapterText(id, text) }
        for (ch, list) in undo.notes { noteStore(for: ch).replaceAll(list, in: ch) }
        if let open = selectedChapterID { notes.resolveAll(in: editorText(of: open)) }
        for e in undo.entries { try? bible.store.write(e) }
        bible.reload()
        plot = undo.plot
        savePlot()
        pendingCommit = true
        commitNow("musset: undo rename \(undo.message)")
        refreshBibleMentions()
    }
}
