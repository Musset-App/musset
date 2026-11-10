import AppKit
import SwiftUI

/// Finding in the open chapter. Musset's own bar: AppKit's left a blank band over the window
/// after the column changed size, and it spoke English.
extension EditorBridge {
    func openFind(replace: Bool = false) {
        if let tv = textView {
            let selected = (tv.string as NSString).substring(with: tv.selectedRange())
            if !selected.isEmpty, !selected.contains("\n") { setSearchQuery(selected) }
        }
        if replace { findShowsReplace = true }
        findOpen = true
        findFocus += 1
    }

    func closeFind() {
        findOpen = false
        findShowsReplace = false
        setSearchQuery("")
        if let tv = textView { tv.window?.makeFirstResponder(tv) }
    }

    var findMatches: [NSRange] { BookSearch.ranges(of: searchQuery, in: textView?.string ?? "") }

    /// The match next to a position, going round the chapter.
    nonisolated static func match(in ranges: [NSRange], from selection: NSRange, forward: Bool) -> NSRange? {
        if forward { return ranges.first { $0.location >= NSMaxRange(selection) && $0 != selection } ?? ranges.first }
        return ranges.last { NSMaxRange($0) <= selection.location } ?? ranges.last
    }

    func findNext(forward: Bool = true) {
        guard !searchQuery.isEmpty, let tv = textView else { openFind(); return }
        guard let target = Self.match(in: findMatches, from: tv.selectedRange(), forward: forward) else { return }
        scroll(to: target)
    }

    /// While typing: the first match from where the search started, not past it.
    func findFromCaret() {
        guard let tv = textView else { return }
        let start = NSRange(location: tv.selectedRange().location, length: 0)
        if let target = Self.match(in: findMatches, from: start, forward: true) { scroll(to: target) }
    }

    func replaceCurrent(with text: String) {
        guard let tv = textView else { return }
        let selection = tv.selectedRange()
        if findMatches.contains(selection) {
            replace(selection, with: text)
            tv.setSelectedRange(NSRange(location: selection.location + (text as NSString).length, length: 0))
            refreshHighlights()
        }
        findNext()
    }

    /// One undo for all of it. From the end, so the earlier ranges stay right.
    func replaceAll(with text: String) {
        guard let tv = textView else { return }
        tv.undoManager?.beginUndoGrouping()
        for range in findMatches.reversed() { replace(range, with: text) }
        tv.undoManager?.endUndoGrouping()
        refreshHighlights()
    }
}

struct FindBar: View {
    @Bindable var bridge: EditorBridge
    /// Changes with the text and the caret, so the count stays right.
    let text: String
    @State private var replacement = ""
    @FocusState private var fieldFocused: Bool

    private var matches: [NSRange] { BookSearch.ranges(of: bridge.searchQuery, in: text) }

    private var count: String {
        guard !bridge.searchQuery.isEmpty else { return "" }
        if matches.isEmpty { return bridge.searchQuery.count < 2 ? "" : L("None", ctx: "Aucun") }
        if let i = matches.firstIndex(of: bridge.selectedRange) { return "\(i + 1) / \(matches.count)" }
        return "\(matches.count)"
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(L("Find in this chapter"), text: $bridge.searchQuery)
                    .textFieldStyle(.plain).font(.ui(13))
                    .focused($fieldFocused)
                    .onSubmit { bridge.findNext(forward: !NSEvent.modifierFlags.contains(.shift)); fieldFocused = true }
                Text(count).font(.ui(11)).monospacedDigit().foregroundStyle(.secondary).lineLimit(1).fixedSize()
                icon("chevron.up", L("Previous (⇧⌘G)")) { bridge.findNext(forward: false) }.disabled(matches.isEmpty)
                icon("chevron.down", L("Next (⌘G)")) { bridge.findNext() }.disabled(matches.isEmpty)
                Divider().frame(height: 14)
                Button(L("Replace")) { bridge.findShowsReplace.toggle() }
                    .buttonStyle(.plain).font(.ui(12)).foregroundStyle(bridge.findShowsReplace ? Ink.accent : .secondary)
                icon("xmark", L("Close (Esc)")) { bridge.closeFind() }
            }
            if bridge.findShowsReplace {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.2.squarepath").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField(L("Replace with"), text: $replacement)
                        .textFieldStyle(.plain).font(.ui(13))
                        .onSubmit { bridge.replaceCurrent(with: replacement) }
                    Button(L("Replace")) { bridge.replaceCurrent(with: replacement) }.disabled(matches.isEmpty)
                    Button(L("Replace All")) { bridge.replaceAll(with: replacement) }.disabled(matches.isEmpty)
                }
                .buttonStyle(.plain).font(.ui(12))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(Ink.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(Ink.hairline).frame(height: 1) }
        .onExitCommand { bridge.closeFind() }
        .onAppear { fieldFocused = true }
        .onChange(of: bridge.findFocus) { _, _ in fieldFocused = true }
        .onChange(of: bridge.searchQuery) { _, _ in
            bridge.textView?.refreshSearchHighlights()
            if fieldFocused { bridge.findFromCaret() }
        }
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 11, weight: .medium)).frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(.secondary).help(help)
    }
}
