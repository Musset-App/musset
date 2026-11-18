import SwiftUI

/// A book read page by page: two pages side by side when the window is wide, reflowed when it changes size or the
/// text size changes (the place is kept), day or night, footnotes in a bubble, marks drawn by hand, notes in the
/// margin (or a marker when the margin is narrow), and a strip of page thumbnails.
public struct PageView: View {
    @Bindable var model: ReaderModel
    var showsThumbnails: Bool

    public init(model: ReaderModel, showsThumbnails: Bool = true) {
        self.model = model
        self.showsThumbnails = showsThumbnails
    }

    public var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    if let book = model.book {
                        Spread(model: model, book: book, size: geo.size)
                    } else if let error = model.error {
                        Text(error).font(.callout).foregroundStyle(.secondary).padding().textSelection(.enabled)
                    }
                    if model.composing && model.book == nil {
                        ProgressView(model.strings.composing)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
                .onAppear { model.setViewport(geo.size) }
                .onChange(of: geo.size) { _, s in model.setViewport(s) }
            }
            if showsThumbnails, model.book != nil {
                ThumbnailStrip(model: model)
            }
        }
        .background(Color(rgb: model.theme.desk))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { model.next(); return .handled }
        .onKeyPress(.leftArrow) { model.previous(); return .handled }
        .onKeyPress(.space) { model.next(); return .handled }
        .onKeyPress(.escape) { model.clearSelection(); return .handled }
        .onChange(of: model.theme) { _, _ in model.themeChanged() }
    }
}

/// The pages shown, with their margin notes.
private struct Spread: View {
    @Bindable var model: ReaderModel
    let book: TypesetBook
    let size: CGSize

    var body: some View {
        let pages = model.visiblePages
        let fitted = fittedSize(pages)
        let spreadWidth = fitted.width * CGFloat(pages.count)
        // Notes beside the spread when there is room; markers on the page's edge otherwise.
        let column = (size.width - spreadWidth) / 2 - 20
        let inMargin = column >= 130
        HStack(spacing: 0) {
            if inMargin { notes(for: pages.count == 2 ? pages.first ?? nil : nil, side: .leading, width: min(column, 220), height: fitted.height) }
            ForEach(Array(pages.enumerated()), id: \.offset) { i, p in
                if let p {
                    PageSurface(model: model, book: book, index: p, size: fitted, notesInMargin: inMargin,
                                outerEdge: pages.count == 2 ? (i == 0 ? .leading : .trailing) : .trailing)
                } else {
                    Color.clear.frame(width: fitted.width, height: fitted.height)
                }
            }
            if inMargin { notes(for: pages.last ?? nil, side: .trailing, width: min(column, 220), height: fitted.height) }
        }
        .overlay(alignment: .leading) { turn(.previous) }
        .overlay(alignment: .trailing) { turn(.next) }
        .frame(width: size.width, height: size.height)
        .opacity(model.composing ? 0.75 : 1)
        .animation(.easeOut(duration: 0.15), value: model.composing)
        #if os(iOS)
        .gesture(DragGesture(minimumDistance: 30).onEnded { v in
            if v.translation.width < -40 { model.next() } else if v.translation.width > 40 { model.previous() }
        })
        #endif
    }

    /// Every page shown at the same size: the slot, or the book's page scaled into it.
    func fittedSize(_ pages: [Int?]) -> CGSize {
        let ref = pages.compactMap { $0 }.first.map { book.pageSizes[$0] } ?? CGSize(width: 1, height: 1.5)
        let room = CGSize(width: (size.width - (pages.count == 2 ? 48 : 16)) / CGFloat(max(pages.count, 1)), height: size.height - 24)
        let k = min(room.width / ref.width, room.height / ref.height)
        return CGSize(width: (ref.width * k).rounded(.down), height: (ref.height * k).rounded(.down))
    }

    enum Turn { case previous, next }

    @ViewBuilder func turn(_ t: Turn) -> some View {
        Button {
            t == .next ? model.next() : model.previous()
        } label: {
            Image(systemName: t == .next ? "chevron.right" : "chevron.left")
                .font(.system(size: 15, weight: .medium))
                .frame(width: 32, height: 64)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(rgb: model.theme.ink, opacity: 0.35))
        .accessibilityLabel(t == .next ? model.strings.nextPage : model.strings.previousPage)
    }

    @ViewBuilder func notes(for page: Int?, side: HorizontalAlignment, width: CGFloat, height: CGFloat) -> some View {
        if let page {
            MarginNotes(model: model, book: book, page: page, side: side, scale: fittedSize([page]).width / book.pageSizes[page].width)
                .frame(width: width, height: height)
        } else {
            Color.clear.frame(width: width, height: height)
        }
    }
}

/// One page: its image, its marks, the selection, the menu and bubbles over it.
private struct PageSurface: View {
    @Bindable var model: ReaderModel
    let book: TypesetBook
    let index: Int
    let size: CGSize
    let notesInMargin: Bool
    let outerEdge: HorizontalAlignment
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var imageKey: RenderKey?

    struct RenderKey: Hashable { let book: ObjectIdentifier; let page: Int; let pixels: Int; let theme: PageTheme }

    var k: CGFloat { size.width / max(book.pageSizes[index].width, 1) }

    var body: some View {
        let key = RenderKey(book: ObjectIdentifier(book), page: index, pixels: Int(size.width * displayScale), theme: model.theme)
        let selection = model.selection?.page == index ? model.selection : nil
        ZStack(alignment: .topLeading) {
            Color(rgb: model.theme.paper)
            if let image {
                Image(decorative: image, scale: 1).resizable().interpolation(.high)
            }
            MarkLayer(book: book, page: index, marks: model.marks, selection: selection?.lines ?? [], night: model.theme.isNight)
            if !notesInMargin { markers }
            if let s = selection, s.finished, model.onAction != nil, let first = s.lines.first {
                SelectionMenu(model: model)
                    .fixedSize()
                    .position(menuPosition(first: first, last: s.lines.last ?? first))
            }
            if let b = model.bubble, b.page == index {
                NoteBubble(text: b.text, caption: b.caption, theme: model.theme)
                    .frame(maxWidth: min(280, size.width - 24))
                    .fixedSize(horizontal: false, vertical: true)
                    .position(x: min(max(b.point.x * k, 150), size.width - 150), y: min(b.point.y * k + 50, size.height - 60))
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .shadow(color: .black.opacity(model.theme.isNight ? 0.4 : 0.08), radius: 1, y: 1)
        .shadow(color: .black.opacity(model.theme.isNight ? 0.3 : 0.07), radius: 14, y: 8)
        .contentShape(Rectangle())
        .gesture(selectGesture)
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
            model.doubleTap(page: index, at: CGPoint(x: v.location.x / k, y: v.location.y / k))
        })
        .simultaneousGesture(SpatialTapGesture().onEnded { v in
            model.tap(page: index, at: CGPoint(x: v.location.x / k, y: v.location.y / k), notesInMargin: notesInMargin)
        })
        .task(id: key) {
            guard key != imageKey else { return }
            let scale = CGFloat(key.pixels) / max(book.pageSizes[index].width, 1)
            let (b, i, t) = (book, index, model.theme)
            let rendered = await Task.detached(priority: .userInitiated) { b.render(page: i, scale: scale, paper: t.paper, ink: t.ink) }.value
            if !Task.isCancelled {
                image = rendered
                imageKey = key
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.strings.pages(index + 1, index + 1, book.pageCount))
    }

    var selectGesture: some Gesture {
        #if os(iOS)
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { v in
                if case .second(true, let drag?) = v { select(drag) }
            }
            .onEnded { _ in model.finishSelection() }
        #else
        DragGesture(minimumDistance: 3)
            .onChanged { select($0) }
            .onEnded { _ in model.finishSelection() }
        #endif
    }

    func select(_ v: DragGesture.Value) {
        model.select(page: index, from: CGPoint(x: v.startLocation.x / k, y: v.startLocation.y / k),
                     to: CGPoint(x: v.location.x / k, y: v.location.y / k))
    }

    func menuPosition(first: CGRect, last: CGRect) -> CGPoint {
        let above = first.minY * k - 30
        let y = above > 24 ? above : last.maxY * k + 30
        return CGPoint(x: min(max(first.midX * k, 150), size.width - 150), y: y)
    }

    /// A note's marker on the page's outer edge, in the person's ink: the margin is too narrow for the note.
    @ViewBuilder var markers: some View {
        ForEach(book.notes(model.marks, page: index), id: \.mark.id) { m, lines in
            let y = (lines.first?.minY ?? 0) * k
            Button {
                model.openNote(m, page: index, at: CGPoint(x: outerEdge == .leading ? 40 : book.pageSizes[index].width - 40, y: (lines.first?.maxY ?? 0)))
            } label: {
                Capsule().fill(m.ink.lineColor).frame(width: 5, height: 20)
                    .frame(width: 24, height: 32).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .position(x: outerEdge == .leading ? 6 : size.width - 6, y: y + 10)
            .accessibilityLabel(m.note ?? "")
        }
    }
}

/// Notes written in the margin beside the page, in the person's ink and hand, each tied to its lines by a brace.
private struct MarginNotes: View {
    let model: ReaderModel
    let book: TypesetBook
    let page: Int
    let side: HorizontalAlignment
    let scale: CGFloat

    var body: some View {
        let placed = book.notes(model.marks, page: page)
        let tops = layout(placed.map { (($0.lines.first?.minY ?? 0) * scale, estimate($0.mark.note ?? "")) })
        ZStack(alignment: .topLeading) {
            ForEach(Array(placed.enumerated()), id: \.element.mark.id) { i, item in
                let m = item.mark
                let span = ((item.lines.last?.maxY ?? 0) - (item.lines.first?.minY ?? 0)) * scale
                HStack(alignment: .top, spacing: 6) {
                    if side == .trailing { brace(m, span) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(m.note ?? "")
                            .font(.custom("Noteworthy", size: 15))
                            .foregroundStyle(model.theme.isNight ? m.ink.color : m.ink.lineColor)
                            .fixedSize(horizontal: false, vertical: true)
                        if let who = m.person {
                            Text(who).font(.caption2).foregroundStyle(m.ink.lineColor.opacity(0.85))
                        }
                    }
                    if side == .leading { brace(m, span) }
                }
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
                .onTapGesture { model.onOpen?(m) }
                .frame(maxWidth: .infinity, alignment: side == .leading ? .trailing : .leading)
                .offset(y: tops[i])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    func brace(_ m: Mark, _ span: CGFloat) -> some View {
        MarkLayer.brace(height: max(span, 16), facingRight: side == .trailing)
            .stroke(m.ink.color, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
            .frame(width: 8, height: max(span, 16))
    }

    func estimate(_ text: String) -> CGFloat { CGFloat(text.count / 22 + 1) * 21 + 16 }

    /// Each note at its lines' height, pushed down when the one above runs into it.
    func layout(_ wanted: [(top: CGFloat, height: CGFloat)]) -> [CGFloat] {
        var out: [CGFloat] = []
        var floor: CGFloat = 0
        for (top, h) in wanted {
            let y = max(top, floor)
            out.append(y)
            floor = y + h + 8
        }
        return out
    }
}

/// A footnote, or a note opened from its marker.
struct NoteBubble: View {
    let text: String
    let caption: String?
    let theme: PageTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(text).font(.callout)
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .foregroundStyle(Color(rgb: theme.ink))
        .background(Color(rgb: theme.isNight ? 0x2A2926 : 0xFFFFFF), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color(rgb: theme.ink, opacity: 0.08)))
    }
}
