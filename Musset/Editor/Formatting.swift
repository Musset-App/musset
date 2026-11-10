import AppKit

/// Markdown formatting from the format bar and the Format menu. Every change goes through the text view,
/// so it is undoable, saved, and followed by the notes.
extension ZenTextView {
    private func change(_ range: NSRange, to text: String, select: NSRange? = nil) {
        untracked = true
        defer { untracked = false }
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    /// Wraps the selection in `marker` (** or *), or unwraps it when it is already wrapped.
    /// With nothing selected, puts a pair at the caret and the caret inside.
    func toggleInline(_ marker: String) {
        let ns = string as NSString
        let r = selectedRange()
        let m = marker as NSString
        let before = NSRange(location: r.location - m.length, length: m.length)
        let after = NSRange(location: NSMaxRange(r), length: m.length)
        if r.location >= m.length, NSMaxRange(after) <= ns.length,
           ns.substring(with: before) == marker, ns.substring(with: after) == marker,
           !(marker == "*" && (r.location >= 2 && ns.substring(with: NSRange(location: r.location - 2, length: 2)) == "**" && ns.substring(with: NSRange(location: NSMaxRange(r), length: min(2, ns.length - NSMaxRange(r)))) == "**")) {
            let inner = ns.substring(with: r)
            change(NSRange(location: before.location, length: r.length + 2 * m.length), to: inner,
                   select: NSRange(location: before.location, length: (inner as NSString).length))
            return
        }
        let inner = ns.substring(with: r)
        change(r, to: marker + inner + marker, select: NSRange(location: r.location + m.length, length: r.length))
    }

    /// Makes the caret's paragraph a heading of `level` (1–3); the same level again, or 0, makes it text again.
    func setHeading(_ level: Int) {
        let ns = string as NSString
        let p = ns.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = ns.substring(with: p)
        let hashes = line.prefix { $0 == "#" }.count
        let prefixLength = hashes > 0 && line.dropFirst(hashes).first == " " ? hashes + 1 : 0
        let target = hashes == level ? 0 : level
        let newPrefix = target > 0 ? String(repeating: "#", count: target) + " " : ""
        let caret = selectedRange().location - p.location
        change(NSRange(location: p.location, length: prefixLength), to: newPrefix,
               select: NSRange(location: p.location + max((newPrefix as NSString).length, caret - prefixLength + (newPrefix as NSString).length), length: 0))
    }

    /// Turns the selected paragraphs into a quotation, or back.
    func toggleQuote() {
        let ns = string as NSString
        let block = ns.lineRange(for: selectedRange())
        let lines = ns.substring(with: block).components(separatedBy: "\n")
        let quoted = lines.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix("> ") }
        let out = lines.map { l in l.isEmpty ? l : (quoted ? String(l.dropFirst(2)) : "> " + l) }.joined(separator: "\n")
        change(block, to: out, select: NSRange(location: block.location, length: (out as NSString).length))
    }

    /// A footnote at the caret, written ^[…] (Markdown's inline note): the caret goes inside.
    func insertFootnote() {
        let r = selectedRange()
        let at = NSMaxRange(r)
        change(NSRange(location: at, length: 0), to: "^[]", select: NSRange(location: at + 2, length: 0))
    }

    // MARK: Revisions: the editor's tools

    /// True when the selection touches an existing correction: the tools then refuse rather than nest marks
    /// (nested marks would no longer be read, and their syntax would show).
    private func touchesCorrection(_ r: NSRange) -> Bool {
        Revisions.marks(in: string).contains { m in
            r.length == 0 ? (m.range.location < r.location && r.location < NSMaxRange(m.range))
                          : NSIntersectionRange(m.range, r).length > 0
        }
    }

    /// Strikes the selection out (a correction to accept or reject).
    func markDeletion() {
        let r = selectedRange()
        guard r.length > 0, !touchesCorrection(r) else { NSSound.beep(); return }
        let text = "{--" + (string as NSString).substring(with: r) + "--}"
        change(r, to: text, select: NSRange(location: r.location + (text as NSString).length, length: 0))
    }

    /// Proposes `added` at the caret (after the selection, if any). Inside an addition, it simply grows it.
    func markInsertion(_ added: String) {
        guard !added.isEmpty else { return }
        let at = NSMaxRange(selectedRange())
        if let m = Revisions.marks(in: string).first(where: { $0.kind == .insertion && $0.first.location <= at && at <= NSMaxRange($0.first) }) {
            _ = m
            change(NSRange(location: at, length: 0), to: added, select: NSRange(location: at + (added as NSString).length, length: 0))
            return
        }
        guard !touchesCorrection(NSRange(location: at, length: 0)) else { NSSound.beep(); return }
        let text = "{++" + added + "++}"
        change(NSRange(location: at, length: 0), to: text, select: NSRange(location: at + (text as NSString).length, length: 0))
    }

    /// Proposes `replacement` for the selection.
    func markSubstitution(_ replacement: String) {
        let r = selectedRange()
        guard r.length > 0, !replacement.isEmpty, !touchesCorrection(r) else { NSSound.beep(); return }
        let text = "{~~" + (string as NSString).substring(with: r) + "~>" + replacement + "~~}"
        change(r, to: text, select: NSRange(location: r.location + (text as NSString).length, length: 0))
    }

    /// Highlights the selection, with a comment if one is given. On an existing highlight: the same passage
    /// changes nothing (but adds the comment), a wider selection extends it, a selection inside it narrows it.
    func markHighlight(comment: String = "") {
        let r = selectedRange()
        let ns = string as NSString
        let marks = Revisions.marks(in: string)
        if let h = marks.first(where: { $0.kind == .highlight && NSIntersectionRange($0.range, r).length > 0 }) {
            // Any other correction in the way: refuse.
            if marks.contains(where: { $0 != h && NSIntersectionRange($0.range, r).length > 0 }) { NSSound.beep(); return }
            let oldComment = h.second.map { ns.substring(with: $0) } ?? ""
            let note = comment.isEmpty ? oldComment : (oldComment.isEmpty ? comment : oldComment + " — " + comment)
            let tail = note.isEmpty ? "" : "{>>" + note + "<<}"
            let inner = h.first
            let within = r.location >= inner.location && NSMaxRange(r) <= NSMaxRange(inner)
            if within && r == inner && comment.isEmpty { return }
            let replaced: String
            let range: NSRange
            if within {
                // Narrow: the words outside the selection stay, unhighlighted.
                let before = ns.substring(with: NSRange(location: inner.location, length: r.location - inner.location))
                let after = ns.substring(with: NSRange(location: NSMaxRange(r), length: NSMaxRange(inner) - NSMaxRange(r)))
                replaced = before + "{==" + ns.substring(with: r) + "==}" + tail + after
                range = h.range
            } else {
                // Extend over the selection: the old highlight's syntax is dropped from the middle.
                let start = min(r.location, h.range.location), end = max(NSMaxRange(r), NSMaxRange(h.range))
                let covered = NSRange(location: start, length: end - start)
                var words = ns.substring(with: covered)
                let local = (h.range.location - start, h.range.length)
                let markText = ns.substring(with: h.range)
                let plainMark = ns.substring(with: inner)
                words = (words as NSString).replacingCharacters(in: NSRange(location: local.0, length: local.1), with: plainMark)
                _ = markText
                replaced = "{==" + words + "==}" + tail
                range = covered
            }
            change(range, to: replaced, select: NSRange(location: range.location + (replaced as NSString).length, length: 0))
            return
        }
        if r.length == 0 {
            guard !comment.isEmpty, !touchesCorrection(r) else { NSSound.beep(); return }
            let text = "{>>" + comment + "<<}"
            change(r, to: text, select: NSRange(location: r.location + (text as NSString).length, length: 0))
            return
        }
        guard !touchesCorrection(r) else { NSSound.beep(); return }
        let text = "{==" + ns.substring(with: r) + "==}" + (comment.isEmpty ? "" : "{>>" + comment + "<<}")
        change(r, to: text, select: NSRange(location: r.location + (text as NSString).length, length: 0))
    }

    // MARK: Revisions

    /// Highlights the selection and opens a comment on it: {==passage==}{>>…<<}, caret in the comment.
    func commentSelection() {
        let r = selectedRange()
        let ns = string as NSString
        if r.length == 0 {
            change(r, to: "{>><<}", select: NSRange(location: r.location + 3, length: 0))
            return
        }
        let passage = ns.substring(with: r)
        let text = "{==" + passage + "==}{>><<}"
        change(r, to: text, select: NSRange(location: r.location + (text as NSString).length - 3, length: 0))
    }

    /// Accepts or rejects the correction at the caret (or all of them); the caret moves to the next one.
    func decideRevision(accept: Bool, all: Bool = false) {
        let text = string
        if all {
            let out = Revisions.resolveAll(text, accept: accept)
            guard out != text else { NSSound.beep(); return }
            change(NSRange(location: 0, length: (text as NSString).length), to: out, select: NSRange(location: min(selectedRange().location, (out as NSString).length), length: 0))
            return
        }
        guard let m = Revisions.mark(at: selectedRange().location, in: text) else { NSSound.beep(); return }
        let out = Revisions.resolved(m, in: text, accept: accept)
        change(m.range, to: out, select: NSRange(location: m.range.location + (out as NSString).length, length: 0))
        nextRevision()
    }

    /// Decides the marks `matching` picks, from the Notes list; the others stay waiting.
    func decideRevisions(accept: Bool, matching: (Revisions.Mark) -> Bool) {
        let text = string
        let out = Revisions.resolve(text, accept: accept, matching: matching)
        guard out != text else { NSSound.beep(); return }
        let caret = min(selectedRange().location, (out as NSString).length)
        change(NSRange(location: 0, length: (text as NSString).length), to: out, select: NSRange(location: caret, length: 0))
    }

    /// Moves to the next correction (wrapping round to the first).
    func nextRevision() {
        let marks = Revisions.marks(in: string)
        let here = selectedRange().location
        guard let m = marks.first(where: { $0.range.location > here }) ?? marks.first else { return }
        setSelectedRange(NSRange(location: m.range.location, length: 0))
        scrollRangeToVisible(m.range)
        showFindIndicator(for: m.range)
    }
}
