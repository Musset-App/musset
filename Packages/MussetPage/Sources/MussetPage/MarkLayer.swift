import SwiftUI

extension TypesetBook {
    /// The boxes of a chapter's range on a page, one per line, in page points.
    public func lineRects(page: Int, chapter: Int, range: Range<Int>) -> [CGRect] {
        var lines: [(baseline: CGFloat, rect: CGRect)] = []
        for g in glyphs(page: page) where g.footnote == nil && g.chapter == chapter && g.range.overlaps(range) {
            if let last = lines.last, abs(last.baseline - g.baseline) < 1, g.rect.minX >= last.rect.minX - 1 {
                lines[lines.count - 1].rect = last.rect.union(g.rect)
            } else {
                lines.append((g.baseline, g.rect))
            }
        }
        return lines.map(\.rect)
    }

    /// The marks with a note to write in the margin of this page: the ones starting on it.
    func notes(_ marks: [Mark], page: Int) -> [(mark: Mark, lines: [CGRect])] {
        placed(marks.filter { $0.note != nil }, page: page).filter { item in
            self.page(for: PageAnchor(chapter: item.mark.chapter, offset: item.mark.range.lowerBound)) == page
        }
    }

    /// The marks with something to show on a page, with their boxes there.
    func placed(_ marks: [Mark], page: Int) -> [(mark: Mark, lines: [CGRect])] {
        marks.compactMap { m in
            guard let c = source.chapterIndex(m.chapter) else { return nil }
            let lines = lineRects(page: page, chapter: c, range: m.range)
            return lines.isEmpty ? nil : (m, lines)
        }
    }
}

/// The marks drawn over a page, by hand: highlighter strokes, underlines and strikes that wobble a little, the same
/// way at every redraw (the wobble is seeded by the mark's id). Draws in a view the page's size, scaled.
public struct MarkLayer: View {
    let book: TypesetBook
    let page: Int
    let marks: [Mark]
    var selection: [CGRect] = []
    var night = false

    public init(book: TypesetBook, page: Int, marks: [Mark], selection: [CGRect] = [], night: Bool = false) {
        self.book = book
        self.page = page
        self.marks = marks
        self.selection = selection
        self.night = night
    }

    public var body: some View {
        let placed = book.placed(marks, page: page)
        let pageSize = book.pageSizes.indices.contains(page) ? book.pageSizes[page] : CGSize(width: 1, height: 1)
        Canvas { ctx, size in
            let k = size.width / max(pageSize.width, 1)
            ctx.scaleBy(x: k, y: k)
            // Highlighter ink sinks into the paper by day; by night it glows a little over it.
            var ink = ctx
            ink.blendMode = night ? .screen : .multiply
            for (mark, lines) in placed {
                var rng = SeededRandom(mark.id)
                for line in lines {
                    switch mark.kind {
                    case .highlight:
                        ink.fill(Self.marker(line, &rng), with: .color(mark.ink.color.opacity(night ? 0.38 : 0.42)))
                    case .note:
                        ink.fill(Self.marker(line, &rng), with: .color(mark.ink.color.opacity(night ? 0.22 : 0.26)))
                    case .underline:
                        let y = line.maxY - line.height * 0.12
                        ctx.stroke(Self.wobblyLine(from: line.minX, to: line.maxX, y: y, &rng, amplitude: 0.45),
                                   with: .color(night ? mark.ink.color : mark.ink.lineColor),
                                   style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                    case .strike:
                        let y = line.midY + line.height * 0.06
                        ctx.stroke(Self.wobblyLine(from: line.minX - 1, to: line.maxX + 1, y: y, &rng, amplitude: 0.6),
                                   with: .color(night ? mark.ink.color : mark.ink.lineColor),
                                   style: StrokeStyle(lineWidth: 1.0, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            for line in selection {
                ctx.fill(Path(roundedRect: line.insetBy(dx: -0.5, dy: 0), cornerRadius: 1.5),
                         with: .color(Color(rgb: 0x2E4AC7, opacity: night ? 0.35 : 0.18)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A highlighter stroke over a line: edges that wander, ends that are not square, a little slant.
    static func marker(_ r: CGRect, _ rng: inout SeededRandom) -> Path {
        let h = r.height * 0.78
        let mid = r.midY + r.height * 0.04
        let top = mid - h / 2, bottom = mid + h / 2
        let x0 = r.minX - 1.2 + rng.unit() * 0.8, x1 = r.maxX + 1.2 + rng.unit() * 0.8
        let slant = rng.unit() * 0.6
        let steps = max(2, Int((x1 - x0) / 14))
        var p = Path()
        p.move(to: CGPoint(x: x0 + abs(rng.unit()) * 1.5, y: top + rng.unit() * 0.6 - slant))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            p.addLine(to: CGPoint(x: x0 + (x1 - x0) * t, y: top + rng.unit() * 0.55 - slant * (1 - 2 * t)))
        }
        // The end: rounded, as a felt tip leaves it.
        p.addQuadCurve(to: CGPoint(x: x1 - abs(rng.unit()), y: bottom + rng.unit() * 0.5 + slant),
                       control: CGPoint(x: x1 + 2 + rng.unit(), y: mid))
        for i in stride(from: steps - 1, through: 0, by: -1) {
            let t = CGFloat(i) / CGFloat(steps)
            p.addLine(to: CGPoint(x: x0 + (x1 - x0) * t, y: bottom + rng.unit() * 0.55 + slant * (1 - 2 * t)))
        }
        p.addQuadCurve(to: CGPoint(x: x0 + abs(rng.unit()) * 1.5, y: top - slant), control: CGPoint(x: x0 - 1.5 + rng.unit(), y: mid))
        p.closeSubpath()
        return p
    }

    /// A pen line that is never quite straight.
    static func wobblyLine(from x0: CGFloat, to x1: CGFloat, y: CGFloat, _ rng: inout SeededRandom, amplitude: CGFloat) -> Path {
        let steps = max(2, Int((x1 - x0) / 18))
        var p = Path()
        let drift = rng.unit() * amplitude
        p.move(to: CGPoint(x: x0, y: y + rng.unit() * amplitude))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let prev = CGFloat(i - 1) / CGFloat(steps)
            let control = CGPoint(x: x0 + (x1 - x0) * (prev + t) / 2, y: y + rng.unit() * amplitude * 1.4 + drift * t)
            p.addQuadCurve(to: CGPoint(x: x0 + (x1 - x0) * t, y: y + rng.unit() * amplitude * 0.6 + drift * t), control: control)
        }
        return p
    }

    /// The little curly bracket that ties a margin note to its lines.
    static func brace(height: CGFloat, facingRight: Bool) -> Path {
        var p = Path()
        let w: CGFloat = 7, m = height / 2
        let s: CGFloat = facingRight ? 1 : -1
        p.move(to: CGPoint(x: w * s, y: 0))
        p.addCurve(to: CGPoint(x: 0, y: m), control1: CGPoint(x: -w * 0.4 * s, y: height * 0.08), control2: CGPoint(x: w * 0.7 * s, y: m * 0.9))
        p.addCurve(to: CGPoint(x: w * s, y: height), control1: CGPoint(x: w * 0.7 * s, y: m * 1.1), control2: CGPoint(x: -w * 0.4 * s, y: height * 0.92))
        return p
    }
}
