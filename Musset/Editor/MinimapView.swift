import AppKit
import SwiftUI

/// The whole chapter at a glance: one thin bar per wrapped line, headings and notes marked,
/// search matches and proofreading issues as ticks, the visible part as a frame. Click or drag to scroll.
final class MinimapView: NSView {
    weak var bridge: EditorBridge?

    /// Characters per minimap row: roughly one line of the editor column.
    static let charsPerRow = 72
    static let maxRowHeight: CGFloat = 3

    private struct Line {
        let start: Int
        let length: Int
        let firstRow: Int
        let rows: Int
        let kind: Kind
    }
    private enum Kind { case blank, text, heading, note, quote, rule }

    override var isFlipped: Bool { true }

    private var textView: ZenTextView? { bridge?.textView }

    private func layout(_ ns: NSString) -> (lines: [Line], rows: Int) {
        var lines: [Line] = []
        var row = 0
        var i = 0
        var inNote = false
        while i < ns.length {
            let r = ns.lineRange(for: NSRange(location: i, length: 0))
            i = NSMaxRange(r)
            let t = ns.substring(with: r).trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: Kind
            if inNote || t.hasPrefix("<!--") {
                kind = .note
                inNote = !t.contains("-->")
            } else if t.isEmpty { kind = .blank }
            else if t.hasPrefix("#") { kind = .heading }
            else if t.hasPrefix(">") { kind = .quote }
            else if t.allSatisfy({ "*-_ ".contains($0) }) { kind = .rule }
            else { kind = .text }
            let len = (t as NSString).length
            let rows = kind == .blank ? 1 : max(1, Int(ceil(Double(len) / Double(Self.charsPerRow))))
            lines.append(Line(start: r.location, length: len, firstRow: row, rows: rows, kind: kind))
            row += rows
        }
        return (lines, max(row, 1))
    }

    private func rowHeight(_ rows: Int) -> CGFloat {
        min(Self.maxRowHeight, (bounds.height - 16) / CGFloat(rows))
    }

    private func row(for offset: Int, in lines: [Line]) -> CGFloat {
        guard let idx = lines.lastIndex(where: { $0.start <= offset }) else { return 0 }
        let l = lines[idx]
        let within = min(l.rows - 1, max(0, offset - l.start) / Self.charsPerRow)
        return CGFloat(l.firstRow + within)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let (lines, rows) = layout(ns)
        let h = rowHeight(rows)
        let top: CGFloat = 8
        let left: CGFloat = 10
        let width = bounds.width - 20
        let unit = width / CGFloat(Self.charsPerRow)
        let ink = NSColor.labelColor

        for l in lines where l.kind != .blank {
            let color: NSColor
            switch l.kind {
            case .heading: color = NSColor.controlAccentColor.withAlphaComponent(0.85)
            case .note: color = ink.withAlphaComponent(0.10)
            case .quote: color = ink.withAlphaComponent(0.18)
            case .rule: color = ink.withAlphaComponent(0.30)
            default: color = ink.withAlphaComponent(0.26)
            }
            color.setFill()
            for k in 0..<l.rows {
                let chars = k == l.rows - 1 ? l.length - k * Self.charsPerRow : Self.charsPerRow
                let x = left + (l.kind == .quote ? unit * 4 : 0)
                let w = l.kind == .rule ? width * 0.2 : max(2, CGFloat(chars) * unit)
                let y = top + CGFloat(l.firstRow + k) * h
                let barH = l.kind == .heading ? max(1.5, h * 0.95) : max(1, h * 0.6)
                NSRect(x: l.kind == .rule ? left + width * 0.4 : x, y: y, width: min(w, width), height: barH).fill()
            }
        }

        // Pangram flags: orange band on the left.
        if let bridge {
            NSColor.systemOrange.withAlphaComponent(0.7).setFill()
            for r in bridge.flagged {
                let y0 = top + row(for: r.location, in: lines) * h
                let y1 = top + (row(for: NSMaxRange(r), in: lines) + 1) * h
                NSRect(x: 2, y: y0, width: 3, height: max(2, y1 - y0)).fill()
            }
        }
        // Search matches and proofreading issues: ticks on the right.
        func tick(_ offset: Int, _ color: NSColor) {
            color.setFill()
            let y = top + row(for: offset, in: lines) * h
            NSRect(x: bounds.width - 8, y: y - 1, width: 6, height: max(2, h + 1)).fill()
        }
        for r in tv.searchRanges { tick(r.location, NSColor.systemYellow) }
        if let proof = bridge?.proof {
            for issue in proof.issues(in: tv.string) {
                tick(issue.range.location, issue.fix.isObvious ? .systemRed : (issue.fix.isLanguageTool ? .systemBlue : .systemPurple))
            }
        }
        // Repetitions: close ones as pink ticks on the left, the hovered or picked word in the accent colour.
        if let reps = tv.repetitions {
            for o in reps.close {
                NSColor.systemPink.withAlphaComponent(0.25 + 0.6 * o.strength).setFill()
                NSRect(x: 2, y: top + row(for: o.range.location, in: lines) * h, width: 4, height: max(2, h)).fill()
            }
            if let stem = tv.activeStem {
                NSColor.controlAccentColor.withAlphaComponent(0.75).setFill()
                for r in reps.occurrences(of: stem) {
                    NSRect(x: 0, y: top + row(for: r.location, in: lines) * h, width: bounds.width - 10, height: max(1.5, h * 0.8)).fill()
                }
            }
        }
        // Notes: a dot in the note's colour on the right edge.
        if let bridge, let store = bridge.session?.notes {
            for note in store.notes where note.status == .open || bridge.showResolvedNotes {
                guard let r = store.live[note.id] else { continue }
                note.kind.nsColor.withAlphaComponent(note.kind.isPositive ? 0.5 : 1).setFill()
                let y = top + row(for: r.location, in: lines) * h
                NSBezierPath(ovalIn: NSRect(x: bounds.width - 9, y: y - 1.5, width: 5, height: 5)).fill()
            }
        }
        // Caret.
        let caret = top + row(for: tv.selectedRange().location, in: lines) * h
        NSColor.controlAccentColor.setFill()
        NSRect(x: 4, y: caret, width: bounds.width - 8, height: 1).fill()

        // Visible part of the chapter.
        let vis = tv.visibleCharacterRange
        if vis.length > 0 && vis.length < ns.length {
            let y0 = top + row(for: vis.location, in: lines) * h
            let y1 = top + (row(for: NSMaxRange(vis), in: lines) + 1) * h
            let frame = NSRect(x: 3, y: y0 - 2, width: bounds.width - 6, height: max(8, y1 - y0 + 4))
            let path = NSBezierPath(roundedRect: frame, xRadius: 3, yRadius: 3)
            ink.withAlphaComponent(0.06).setFill()
            path.fill()
            ink.withAlphaComponent(0.18).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    override func mouseDown(with event: NSEvent) { scroll(to: event) }
    override func mouseDragged(with event: NSEvent) { scroll(to: event) }

    private func scroll(to event: NSEvent) {
        guard let tv = textView else { return }
        let p = convert(event.locationInWindow, from: nil)
        let ns = tv.string as NSString
        let (lines, rows) = layout(ns)
        let target = Int((p.y - 8) / rowHeight(rows))
        guard let l = lines.last(where: { $0.firstRow <= target }) else { tv.scrollToCenter(offset: 0); return }
        let offset = min(ns.length, l.start + (target - l.firstRow) * Self.charsPerRow)
        tv.scrollToCenter(offset: offset)
        needsDisplay = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

struct Minimap: NSViewRepresentable {
    let bridge: EditorBridge

    func makeNSView(context: Context) -> MinimapView {
        let v = MinimapView()
        v.bridge = bridge
        bridge.minimap = v
        return v
    }

    func updateNSView(_ v: MinimapView, context: Context) {
        bridge.minimap = v
        v.needsDisplay = true
    }
}
