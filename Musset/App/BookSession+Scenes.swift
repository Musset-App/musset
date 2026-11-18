import Foundation

/// A chapter's scenes reorganised from outside its text (the scene cards, the sidebar): renamed, split, joined.
/// Each rewrites the chapter through `writeChapterText` and keeps the plot rows, keyed by title, with their scenes.
extension BookSession {
    /// The chapter's scenes as its text stands, with the plot rows they still hold under an older title.
    private func heldScenes(of chapterID: String, in text: String) -> [ChapterScene] {
        let parsed = Scenes.parse(text)
        if let kept = scenes[chapterID], kept.map(\.range) == parsed.map(\.range) { return kept }
        return parsed
    }

    /// Renames a scene: its marker is rewritten (the opening, which has none, gets one) and its plot row follows.
    /// Refused when the title is empty, or another scene's in the chapter: the plot row hangs on it.
    /// `editor`: the live editor's own edit, for the chapter one is in while its editor is on screen, so ⌘Z takes
    /// the rename back; without it the text is written as it is.
    @discardableResult
    func renameScene(_ chapterID: String, index: Int, to title: String, editor: ((NSRange, String) -> Void)? = nil) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty, inManuscript(), manifest.chapters.contains(where: { $0.id == chapterID }) else { return false }
        flushSave()
        let text = editorText(of: chapterID)
        let all = heldScenes(of: chapterID, in: text)
        guard all.indices.contains(index), let edit = Scenes.renaming(index, to: title, in: text) else { return false }
        if all[index].title == title { return true }
        guard !all.contains(where: { $0.title == title }) else {
            lastError = L("Another scene of this chapter already has this title.")
            return false
        }
        if let editor {
            // The plot row follows as the editor's text changes (`PlotGrid.follow`).
            editor(edit.range, edit.with)
            flushSave()
            return true
        }
        do {
            try writeChapterText(chapterID, (text as NSString).replacingCharacters(in: edit.range, with: edit.with))
            plot.rename(chapterID, from: all[index].key, to: title)
            // A move undone now would take this back with it, unsaid.
            lastSceneMove = nil
            savePlot()
            commitNow("musset: rename scene in \(chapterID)")
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Starts a new scene at the paragraph that holds `location`, in the chapter's text as it stands. The new
    /// scene's title ("Scene 3", or the next number free in the chapter) is there to be replaced. Returns its
    /// place among the chapter's scenes.
    @discardableResult
    func splitScene(chapterID: String, at location: Int) -> Int? {
        guard inManuscript(), manifest.chapters.contains(where: { $0.id == chapterID }) else { return nil }
        flushSave()
        let text = editorText(of: chapterID)
        let all = Scenes.parse(text)
        // Titles are the plot rows' keys: neither a scene's nor a row's left behind.
        let taken = Set(all.compactMap(\.title)).union(plot.rows[chapterID].map { Set($0.keys) } ?? [])
        var n = (all.lastIndex { $0.range.location <= location } ?? 0) + 2
        while taken.contains(words.scene(n)) { n += 1 }
        let title = words.scene(n)
        guard let out = Scenes.split(text, at: location, title: title) else { return nil }
        do {
            try writeChapterText(chapterID, out)
            lastSceneMove = nil
            commitNow("musset: split scene in \(chapterID)")
        } catch {
            lastError = error.localizedDescription
            return nil
        }
        return Scenes.parse(out).firstIndex { $0.title == title }
    }

    /// Joins a scene with the next one: the next one's marker goes, its text stays, under this scene's title.
    @discardableResult
    func mergeScene(chapterID: String, index: Int) -> Bool {
        guard inManuscript(), manifest.chapters.contains(where: { $0.id == chapterID }) else { return false }
        flushSave()
        let text = editorText(of: chapterID)
        let all = heldScenes(of: chapterID, in: text)
        guard let out = Scenes.merged(index, in: text) else { return false }
        let key = all[index].key, next = all[index + 1].key
        do {
            try writeChapterText(chapterID, out)
            // One row for the scene they make: this scene's. The next one's row is kept, under this scene's
            // title, only when this scene had none; when both had one, the next one's is dropped.
            if next != key, let row = plot.rows[chapterID]?[next] {
                plot.rows[chapterID]?[next] = nil
                if plot.rows[chapterID]?[key] == nil { plot.rows[chapterID]?[key] = row }
            }
            lastSceneMove = nil
            savePlot()
            commitNow("musset: merge scenes in \(chapterID)")
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }
}

/// A chapter's excerpts as its cards draw them: the author's emphasis shown, not its marks.
struct ChapterCardText {
    let excerpt: ChapterExcerpt
    let opening: AttributedString
    let closing: AttributedString
    let scenes: [AttributedString]

    static let empty = ChapterCardText(ChapterExcerpt())

    init(_ excerpt: ChapterExcerpt) {
        func styled(_ text: String) -> AttributedString {
            (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
        }
        self.excerpt = excerpt
        opening = styled(excerpt.opening)
        closing = styled(excerpt.closing)
        scenes = excerpt.scenes.map(styled)
    }
}

/// The scenes seen from further away: the board of Overview's first page, at the book's level and at a part's, and
/// the ways from it into a chapter and back.
extension BookSession {
    /// What the board shows of a chapter's text. Read once and kept: a page of sixty chapters asks for each
    /// of them every time it redraws, and only the chapter whose scenes changed is read again.
    func cardText(of chapterID: String) -> ChapterCardText {
        let mark = SceneExcerpts.mark(scenes[chapterID] ?? [])
        if let kept = cardTexts[chapterID], kept.mark == mark { return kept.text }
        let text = ChapterCardText(SceneExcerpts.excerpt(of: editorText(of: chapterID)))
        cardTexts[chapterID] = (mark, text)
        return text
    }

    /// « Part II », « Acte II », or « II. La fuite » when it has a title.
    func partName(_ part: BookPart) -> String { words.groupName(part) }

    /// The strand the board is read along in these panes, if the book still has it.
    func scenesStrand(in ws: Workspace) -> BookStructure.Strand? { ws.scenesStrand.flatMap(manifest.strand) }

    /// Whether the board shows a chapter in these panes: all of them, or those of the strand read alone.
    private func shows(_ ch: ChapterEntry, in ws: Workspace) -> Bool {
        scenesStrand(in: ws).map { $0.id == ch.strand } ?? true
    }

    /// A strand picked in the legend: the board reads it alone; picked again, or nil, the whole book comes back.
    func readStrand(_ id: String?, in ws: Workspace) {
        guard let id, id != ws.scenesStrand, manifest.strand(id) != nil else { ws.readScenes(alongStrand: nil); return }
        ws.readScenes(alongStrand: id)
        // The chapter chosen stays chosen only if it is still in sight.
        if let chosen = ws.scenesChapter, manifest.chapters.first(where: { $0.id == chosen })?.strand != id { ws.chooseScenesChapter(nil) }
    }

    /// The part the board shows at the part level in these panes, if it is at that level. A part with no chapter
    /// on the strand read alone has nothing to show: the board is the book's.
    func scenesPart(in ws: Workspace) -> BookPart? {
        guard manifest.groupsOn, ws.scenesLevel == .part, let id = ws.scenesPart, let part = manifest.parts?.first(where: { $0.id == id }),
              manifest.chapters.contains(where: { $0.part == id && shows($0, in: ws) }) else { return nil }
        return part
    }

    /// The chapter the board stands on: the one chosen there, else the one last written in, else the first;
    /// among the part's when a part is shown.
    func scenesChapter(in ws: Workspace) -> String? {
        let part = scenesPart(in: ws)
        let among = manifest.chapters.filter { (part == nil || $0.part == part?.id) && shows($0, in: ws) }.map(\.id)
        return [ws.scenesChapter, selectedChapterID, ws.saved.lastChapter].compactMap { $0 }.first(where: among.contains) ?? among.first
    }

    /// The part the page zooms to from the book: the chosen chapter's, else the one it showed last, else the
    /// part of the chapter last written in, else the first.
    func scenesPartToZoom(in ws: Workspace) -> String? {
        let candidates = [ws.scenesChapter.flatMap(manifest.part(of:))?.id, ws.scenesPart, selectedChapterID.flatMap(manifest.part(of:))?.id]
        guard manifest.groupsOn else { return nil }
        return candidates.compactMap { $0 }.first { id in manifest.chapters.contains { $0.part == id && shows($0, in: ws) } && manifest.parts?.contains { $0.id == id } == true }
            ?? manifest.scenesBands(strand: scenesStrand(in: ws)?.id).first { $0.part != nil }?.part?.id
    }

    /// Into a chapter from the board, in that pane: as its scenes' cards (`scene` chosen among them), or as
    /// its text when it is a single scene.
    func enterChapter(_ id: String, scene: Int? = nil, in ws: Workspace, pane: String) {
        guard anyChapter(id) != nil else { return }
        activate(ws)
        ws.focus(pane)
        open(id, show: false)
        let cards = (scenes[id]?.count ?? 0) > 1
        ws.together {
            ws.chooseScenesChapter(id)
            ws.open(.chapter(id))
            ws.setSceneCards(cards, pane: pane, chapter: id)
            if cards, let scene { ws.selectSceneCard(scene, pane: pane, chapter: id) }
        }
    }

    /// Out of a chapter's cards to the board on Overview's first page, in that pane: the whole book, or the part
    /// the chapter is in (the book when it is in none). The page scrolls past the book's numbers, to the chapter.
    func zoomOut(from chapter: String, toPart: Bool, in ws: Workspace, pane: String) {
        activate(ws)
        ws.focus(pane)
        ws.together {
            showWholeBook(for: chapter, in: ws)
            ws.chooseScenesChapter(chapter)
            // The chapter one comes from is in sight on the page, its part unfolded.
            if let part = manifest.part(of: chapter) { ws.foldScenes(part.id, false) }
            ws.zoomScenes(toPart: toPart ? manifest.part(of: chapter)?.id : nil)
            ws.jumpToScenes(ScenesJump(chapter: chapter, cards: true))
            ws.open(OverviewTab.summary.tab)
        }
    }

    /// A chapter picked on the bars above the board: chosen on it, its part unfolded, and the board brought to it.
    /// A part level that does not hold it gives way to the chapter's own part, or to the book.
    func showOnBoard(_ chapter: String, in ws: Workspace) {
        guard manifest.chapters.contains(where: { $0.id == chapter }) else { return }
        let part = manifest.part(of: chapter)
        showWholeBook(for: chapter, in: ws)
        ws.chooseScenesChapter(chapter)
        if let part { ws.foldScenes(part.id, false) }
        if ws.scenesLevel == .part, ws.scenesPart != part?.id { ws.zoomScenes(toPart: part?.id) }
        ws.jumpToScenes(ScenesJump(chapter: chapter))
    }

    /// A chapter asked for by name while a strand it does not follow is read alone: the whole book comes back,
    /// rather than a board that cannot show what was asked for.
    private func showWholeBook(for chapter: String, in ws: Workspace) {
        if let ch = manifest.chapters.first(where: { $0.id == chapter }), !shows(ch, in: ws) { ws.readScenes(alongStrand: nil) }
    }

    /// A part picked under the bars: the board at that part's level, from its top.
    func showPartOnBoard(_ part: String, in ws: Workspace) {
        guard manifest.chapters.contains(where: { $0.part == part }) else { return }
        if !manifest.chapters.contains(where: { $0.part == part && shows($0, in: ws) }) { ws.readScenes(alongStrand: nil) }
        ws.zoomScenes(toPart: part)
        ws.jumpToScenes(ScenesJump(chapter: nil, cards: true))
    }
}
