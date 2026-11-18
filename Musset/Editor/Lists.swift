import AppKit

/// Lists as they are typed: Return continues one or ends it, Tab and ⇧Tab nest and un-nest an item. Each is one
/// edit through the text view's own path, so it is one undo step, saved, tracked in revision mode and followed
/// by the notes. In every keyboard mode these are the keys that reach the text: Return and Tab typed in the text
/// (vi: in insert mode), never a mode's own commands (vi's `o`, WordStar's ⌃N open a bare line).
extension ZenTextView {
    /// Return in a list item.
    override func insertNewline(_ sender: Any?) {
        if !hasMarkedText(), continueList() { return }
        super.insertNewline(sender)
    }

    /// Tab in a list item nests it; elsewhere it is a tab.
    override func insertTab(_ sender: Any?) {
        if !hasMarkedText(), nestItems(deeper: true) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if !hasMarkedText(), nestItems(deeper: false) { return }
        super.insertBacktab(sender)
    }

    /// Several replacements as one edit and one undo step. `tracked`: in revision mode the first is recorded as a
    /// correction (a new item is an addition like any other) and the others are left, since only one can be;
    /// an item's depth or an empty marker taken away is not a correction to the text.
    private func change(_ edits: [(range: NSRange, text: String)], caret: Int?, tracked: Bool = false) -> Bool {
        let edits = edits.sorted { $0.range.location < $1.range.location }
        guard let first = edits.first, let storage = textStorage else { return false }
        let recording = tracked && bridge?.trackChanges == true
        if !recording { untracked = true }
        defer { if !recording { untracked = false } }
        if edits.count == 1 || recording {
            // Refused here means recorded as a correction, the caret already placed.
            guard shouldChangeText(in: first.range, replacementString: first.text) else { return true }
            storage.replaceCharacters(in: first.range, with: first.text)
        } else {
            guard shouldChangeText(inRanges: edits.map { NSValue(range: $0.range) }, replacementStrings: edits.map(\.text)) else { return true }
            // From the end: each replacement leaves the ranges before it where they were.
            for e in edits.reversed() { storage.replaceCharacters(in: e.range, with: e.text) }
        }
        didChangeText()
        undoManager?.setActionName(L("List"))
        if let caret { setSelectedRange(NSRange(location: min(caret, storage.length), length: 0)) }
        return true
    }

    /// Return at the end of (or inside) an item starts the next one with the same marker, a numbered one with the
    /// next number; on an item still empty it ends the list (a nested item steps out one level first).
    private func continueList() -> Bool {
        let options = theme.lists
        let sel = selectedRange()
        guard options.any, sel.length == 0 else { return false }
        let ns = string as NSString
        let line = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        guard let item = ListLines.item(ns, at: line.location, options), sel.location >= item.text else { return false }
        let end = ListLines.contentEnd(ns, line: line)
        if item.isEmpty {
            if item.level > 0 { return nestItems(deeper: false) }
            return change([(NSRange(location: line.location, length: end - line.location), "")], caret: line.location)
        }
        let lead = ns.substring(with: NSRange(location: line.location, length: item.indent))
        let marker = item.number.map { "\($0 + 1)" + item.delimiter(in: ns) } ?? ns.substring(with: item.marker)
        let insert = "\n" + lead + marker + " "
        var edits: [(range: NSRange, text: String)] = [(NSRange(location: sel.location, length: 0), insert)]
        if let n = item.number { edits += renumbering(after: line, in: ns, from: n + 1, indent: item.indent, options) }
        return change(edits, caret: sel.location + (insert as NSString).length, tracked: true)
    }

    /// The items below a numbered one, one number further each, when a new item takes the next number: only
    /// while they count on from it one by one at the same depth (nested items skipped), so numbers the author
    /// chose are left as typed. The typesetter and Word count the items themselves either way.
    private func renumbering(after line: NSRange, in ns: NSString, from taken: Int, indent: Int, _ options: ListOptions) -> [(range: NSRange, text: String)] {
        var out: [(range: NSRange, text: String)] = []
        var at = NSMaxRange(line), expected = taken
        while at < ns.length, out.count < 200 {
            let next = ns.lineRange(for: NSRange(location: at, length: 0))
            guard let c = ListLines.candidate(ns, at: next.location) else { break }
            at = NSMaxRange(next)
            if c.indent > indent { continue }
            guard c.indent == indent, c.number == expected else { break }
            out.append((NSRange(location: c.marker.location, length: c.marker.length - 1), "\(expected + 1)"))
            expected += 1
        }
        return out
    }

    /// Tab moves the items the selection touches one level in (four spaces, two levels at most), ⇧Tab one level
    /// out. A numbered item takes the number that follows the item before it at its new depth, or 1.
    /// False when the caret is not in a list item: the key is then the text view's.
    private func nestItems(deeper: Bool) -> Bool {
        let options = theme.lists
        guard options.any else { return false }
        let ns = string as NSString
        let sel = selectedRange()
        let block = ns.lineRange(for: sel)
        var edits: [(range: NSRange, text: String)] = []
        var at = block.location
        var caret = sel.location
        repeat {
            let line = ns.lineRange(for: NSRange(location: at, length: 0))
            at = NSMaxRange(line)
            guard let item = ListLines.item(ns, at: line.location, options) else {
                // A line that is not an item among those selected: the key is not a list's.
                if edits.isEmpty && line.location == block.location { return false }
                continue
            }
            let level = item.level + (deeper ? 1 : -1)
            guard level >= 0, level <= ListLines.maxLevel else { continue }
            let newLead = String(repeating: ListLines.step, count: level)
            var replaced = NSRange(location: line.location, length: item.indent), text = newLead
            if let n = item.number {
                let number = numberAt(level: level, before: line.location, in: ns, options)
                if number != n {
                    replaced.length += item.marker.length - 1
                    text += "\(number)"
                }
            }
            edits.append((replaced, text))
            if sel.length == 0, line.location <= sel.location {
                caret = max(line.location, sel.location + (text as NSString).length - replaced.length)
            }
        } while at < NSMaxRange(block)
        // In a list, at the deepest (or shallowest) level: the key does nothing, rather than write a tab in an item.
        guard !edits.isEmpty else { return true }
        return change(edits, caret: sel.length == 0 ? caret : nil)
    }

    /// The number an item takes at `level` on the line starting at `before`: one more than the numbered item just
    /// above it at that depth (deeper items skipped), or 1 when it opens a list there.
    private func numberAt(level: Int, before: Int, in ns: NSString, _ options: ListOptions) -> Int {
        var at = before
        while at > 0 {
            let line = ns.lineRange(for: NSRange(location: at - 1, length: 0))
            guard let c = ListLines.item(ns, at: line.location, options) else { break }
            if c.level < level { break }
            if c.level == level { return c.number.map { $0 + 1 } ?? 1 }
            at = line.location
        }
        return 1
    }
}
