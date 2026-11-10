import AppKit
import SwiftUI

/// Another version of the chapter, read-only beside the editor: the text being rewritten, to look at
/// and copy from. Same type and column as the editor; no notes, no proofreading, nothing saved.
struct ReferencePane: View {
    @Bindable var session: BookSession
    let fontName: String
    let fontSize: Double
    let columnWidth: Double
    let paragraphSpacing: Double
    @AppStorage("sideBySideDiff") private var showDiff = true

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if session.piste == nil, let ch = session.selectedChapter, let shown = session.reference {
                    versionHeader(ch, shown: shown)
                } else {
                    trackHeader
                }
            }
            .padding(.horizontal, 14).frame(height: 34)
            Divider()
            ReferenceText(text: session.referenceText, other: showDiff && session.piste == nil ? session.text : nil,
                          fontName: fontName, fontSize: fontSize, columnWidth: columnWidth, paragraphSpacing: paragraphSpacing)
        }
        .background(Ink.side)
    }

    /// Beside a version: which one (any but the editor's), whether it is the book's, and the way to make it so.
    private func versionHeader(_ ch: ChapterEntry, shown: String) -> some View {
        let inBook = shown == ch.activeVersion
        let choices = session.versions.filter { $0 != session.editingVersion }.map { v in
            PopItem(title: BookSession.versionLabel(v), checked: v == shown, dot: v == ch.activeVersion ? Ink.added : nil) { session.showBeside(v) }
        }
        return HStack(spacing: 8) {
            PopMenu(choices) {
                HStack(spacing: 6) {
                    if inBook { Circle().fill(Ink.added).frame(width: 7, height: 7) }
                    Text(BookSession.versionLabel(shown)).font(.ui(12)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.ui(8, .semibold)).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).frame(height: 22)
                .background(Ink.panel, in: Capsule())
            }
            .help(L("The version shown beside the one you write"))
            Text("\(BookStore.wordCount(session.referenceText).ui) " + L("words"))
                .font(.ui(11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Toggle(L("What differs"), isOn: $showDiff).toggleStyle(.checkbox).font(.ui(11))
                .help(L("Lights the paragraphs that aren't in the version you write"))
            if inBook {
                Text(L("in the book")).font(.ui(11)).foregroundStyle(Ink.added)
                    .padding(.horizontal, 8).frame(height: 20)
                    .background(Ink.added.opacity(0.14), in: Capsule())
            } else {
                Button(L("Put in the Book")) { session.putInBook(shown) }
                    .buttonStyle(.ink).controlSize(.small)
            }
            Button { session.showBeside(nil) } label: { Image(systemName: "xmark").font(.ui(10, .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L("Close side by side"))
        }
    }

    /// In a track: the manuscript, read only.
    private var trackHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock").font(.ui(10)).foregroundStyle(.tertiary)
            Text(session.reference ?? "").font(.uiMono(11)).foregroundStyle(.secondary).lineLimit(1)
            Text(L("read only")).font(.ui(11)).foregroundStyle(.tertiary)
            Spacer()
            Text("\(BookStore.wordCount(session.referenceText).ui) " + L("words"))
                .font(.ui(11)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).frame(height: 20)
                .background(Ink.panel, in: Capsule())
            Button { session.showBeside(nil) } label: { Image(systemName: "xmark").font(.ui(10, .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L("Close the side version"))
        }
    }
}

/// The handle between the editor and the side version; dragging it sets the side's width.
struct SplitHandle: View {
    @Binding var width: Double
    let total: CGFloat
    @State private var start: Double?

    var body: some View {
        Rectangle().fill(Ink.hairline).frame(width: 1)
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { g in
                    let from = start ?? width
                    if start == nil { start = width }
                    width = Self.clamp(from - g.translation.width, total: total)
                }
                .onEnded { _ in start = nil })
    }

    /// Each side keeps room for a readable column.
    static func clamp(_ w: Double, total: CGFloat) -> Double {
        min(max(w, 280), max(280, Double(total) - 320))
    }
}

private struct ReferenceText: NSViewRepresentable {
    let text: String
    /// The version being written: paragraphs of `text` it doesn't have are lit.
    var other: String? = nil
    let fontName: String
    let fontSize: Double
    let columnWidth: Double
    let paragraphSpacing: Double

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let tv = ReferenceTextView(frame: scroll.contentView.bounds)
        tv.autoresizingMask = [.width]
        tv.isEditable = false
        tv.isSelectable = true
        tv.drawsBackground = false
        tv.isRichText = false
        tv.textContainer?.widthTracksTextView = true
        tv.isVerticallyResizable = true
        scroll.documentView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? ReferenceTextView, let storage = tv.textStorage else { return }
        var theme = EditorTheme(fontName: fontName, fontSize: CGFloat(fontSize))
        theme.paragraphGap = CGFloat(paragraphSpacing)
        let column = CGFloat(columnWidth)
        let lit = other.map { Self.differing(text, from: $0) } ?? []
        guard tv.string != text || tv.theme?.fontName != theme.fontName || tv.theme?.fontSize != theme.fontSize
                || tv.theme?.paragraphGap != theme.paragraphGap || tv.column != column || tv.lit != lit else { return }
        let changed = tv.string != text
        tv.theme = theme
        tv.column = column
        tv.lit = lit
        if changed { tv.string = text }
        // No caret: emphasis markers stay faint, as in a paragraph being read.
        MarkdownStyler.style(storage, theme: theme)
        for r in lit { storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.16), range: r) }
        tv.recenter()
        if changed { tv.scroll(.zero) }
    }
}

extension ReferenceText {
    /// The ranges of the paragraphs (lines) of `text` that `other` doesn't have, word for word. Blank lines never count.
    static func differing(_ text: String, from other: String) -> [NSRange] {
        let theirs = Set(other.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        var out: [NSRange] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs]) { line, range, _, _ in
            guard let line, !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  !theirs.contains(line.trimmingCharacters(in: .whitespaces)) else { return }
            out.append(range)
        }
        return out
    }
}

private final class ReferenceTextView: NSTextView {
    var theme: EditorTheme?
    var lit: [NSRange] = []
    var column: CGFloat = 680

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        recenter()
    }

    /// The column in the middle, narrowing with the pane.
    func recenter() {
        let pad = max(24, (bounds.width - column) / 2)
        let inset = NSSize(width: pad, height: 48)
        if textContainerInset != inset { textContainerInset = inset }
    }
}
