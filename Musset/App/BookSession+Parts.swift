import Foundation

extension BookSession {
    /// A new part from this chapter on: it takes the chapter and those after it that were in the same place
    /// (the rest of its part, or the loose chapters that follow). Right-click chapter 1, then chapter 8: I and II.
    @discardableResult
    func newPart(startingAt chapterID: String, title: String = "") -> String? {
        guard let i = manifest.chapters.firstIndex(where: { $0.id == chapterID }) else { return nil }
        let old = manifest.chapters[i].part
        let part = BookPart(title: title)
        manifest.parts = (manifest.parts ?? []) + [part]
        var j = i
        while j < manifest.chapters.count, manifest.chapters[j].part == old {
            manifest.chapters[j].part = part.id
            j += 1
        }
        saveManifest()
        commitNow("musset: nouvelle partie")
        return part.id
    }

    func renamePart(_ id: String, to title: String) {
        guard let i = manifest.parts?.firstIndex(where: { $0.id == id }) else { return }
        manifest.parts?[i].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        saveManifest()
        commitNow("musset: partie renommée")
    }

    /// The part goes; its chapters stay where they are, outside any part.
    func deletePart(_ id: String) {
        manifest.parts?.removeAll { $0.id == id }
        if manifest.parts?.isEmpty == true { manifest.parts = nil }
        for i in manifest.chapters.indices where manifest.chapters[i].part == id { manifest.chapters[i].part = nil }
        saveManifest()
        commitNow("musset: partie supprimée")
    }

    /// Into a part, at the end of it; out of any part (nil), just after the part it leaves. A part stays one run.
    func movePart(of chapterID: String, to part: String?) {
        guard let i = manifest.chapters.firstIndex(where: { $0.id == chapterID }), manifest.chapters[i].part != part else { return }
        var entry = manifest.chapters.remove(at: i)
        let anchor = part ?? entry.part
        entry.part = part
        let end = manifest.chapters.lastIndex { $0.part == anchor }.map { $0 + 1 } ?? min(i, manifest.chapters.count)
        manifest.chapters.insert(entry, at: end)
        saveManifest()
        commitNow(part == nil ? "musset: \(chapterID) hors partie" : "musset: \(chapterID) dans une partie")
    }

    /// Sets a chapter's part where it already stands (a drop chose the place).
    func putInPart(_ chapterID: String, _ part: String?) {
        guard let i = manifest.chapters.firstIndex(where: { $0.id == chapterID }), manifest.chapters[i].part != part,
              part == nil || manifest.parts?.contains(where: { $0.id == part }) == true else { return }
        manifest.chapters[i].part = part
        saveManifest()
        commitNow("musset: \(chapterID) change de partie")
    }

    /// Makes a piece unnumbered (a prologue, an interlude…: one of the book's kinds), or numbered again (nil).
    /// Only its number goes: its file, its title and its place stay.
    func setKind(_ chapterID: String, _ kind: String?) {
        guard let i = manifest.chapters.firstIndex(where: { $0.id == chapterID }), manifest.chapters[i].kind != kind else { return }
        manifest.chapters[i].kind = kind
        saveManifest()
        commitNow(kind == nil ? "musset: \(chapterID) numbered" : "musset: \(chapterID) unnumbered")
    }

    /// Puts pieces on a strand (one the book has), or on none (nil). An author's tool: nothing that prints changes.
    func setStrand(_ strand: String?, for chapterIDs: [String]) {
        guard strand == nil || manifest.strands.contains(where: { $0.id == strand }) else { return }
        let ids = Set(chapterIDs)
        let changed = manifest.chapters.indices.filter { ids.contains(manifest.chapters[$0].id) && manifest.chapters[$0].strand != strand }
        guard !changed.isEmpty else { return }
        for i in changed { manifest.chapters[i].strand = strand }
        saveManifest()
        commitNow("musset: \(changed.map { manifest.chapters[$0].id }.joined(separator: ", ")) " + (strand == nil ? "off its strand" : "on a strand"))
        dropEmptyStrandFilters()
    }

    /// A strand made where it is needed, from a piece's menu: named, in the first colour no strand has, and followed
    /// by these pieces. A name the book already has is that strand, not a twin of it. A book that never chose a form
    /// takes the one it reads as, as on its Structure page.
    @discardableResult
    func newStrand(named name: String, for chapterIDs: [String] = []) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let known = manifest.strands.first(where: { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }) {
            setStrand(known.id, for: chapterIDs)
            return known.id
        }
        let strand = BookStructure.Strand(name: name, colour: manifest.nextStrandColour)
        var structure = manifest.structure ?? BookStructure(form: manifest.form)
        structure.strands = (structure.strands ?? []) + [strand]
        manifest.structure = structure
        let ids = Set(chapterIDs)
        for i in manifest.chapters.indices where ids.contains(manifest.chapters[i].id) { manifest.chapters[i].strand = strand.id }
        saveManifest()
        commitNow("musset: new strand")
        return strand.id
    }

    /// The strand goes; the pieces that followed it stay, without one, and no board is left reading it alone.
    func removeStrand(_ id: String) {
        guard manifest.strands.contains(where: { $0.id == id }) else { return }
        manifest.structure?.strands?.removeAll { $0.id == id }
        if manifest.structure?.strands?.isEmpty == true { manifest.structure?.strands = nil }
        for i in manifest.chapters.indices where manifest.chapters[i].strand == id { manifest.chapters[i].strand = nil }
        saveManifest()
        commitNow("musset: strand removed")
        dropEmptyStrandFilters()
    }

    /// A board reading one strand alone goes back to the whole book once nothing follows that strand any more.
    private func dropEmptyStrandFilters() {
        for ws in allWorkspaces {
            guard let id = ws.scenesStrand else { continue }
            if manifest.strand(id) == nil || manifest.pieces(in: id) == 0 { ws.readScenes(alongStrand: nil) }
        }
    }

    /// Changes the book's form or one of its settings: names and numbers only, never the files.
    func setStructure(_ change: (inout BookManifest) -> Void) {
        var m = manifest
        change(&m)
        guard m != manifest else { return }
        let sections = manifest.textFeatures.subheadings
        manifest = m
        // An essay reads its sub-headings as sections; a novel does not.
        if manifest.textFeatures.subheadings != sections { refreshSections() }
        saveManifest()
    }
}
