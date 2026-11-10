import AppKit
import SwiftUI

/// Synonyms, homonyms or alliterations for a word, from the right-click menu.
/// A synonym takes the word's place; a homonym or an alliteration is copied, to be used elsewhere.
struct WordCard: View {
    let kind: WordLookup.Kind
    let word: String
    let context: String
    let lang: String
    let root: URL
    let replace: (String) -> Void

    @State private var words: [WordLookup.Word]?
    @State private var error: String?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(kind.heading.uppercased()).font(.ui(10, .semibold)).foregroundStyle(.secondary)
                Text("« \(word) »").font(.ui(13, .semibold))
            }
            if let error {
                Text(error).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let words {
                if words.isEmpty {
                    Text(L("Nothing found.")).font(.ui(12)).foregroundStyle(.secondary)
                }
                FlowLayout(spacing: 6) {
                    ForEach(Array(words.enumerated()), id: \.offset) { _, w in
                        Chip(label: w.sense.map { "\(w.word) · \($0)" } ?? w.word, on: copied == w.word) { pick(w.word) }
                            .help(kind.replaces ? L("Replace with « \(w.word) »")
                                                : L("Copy « \(w.word) »"))
                    }
                }
                if !kind.replaces, !words.isEmpty {
                    Text(copied == nil ? L("Click a word to copy it.") : L("Copied."))
                        .font(.ui(11)).foregroundStyle(.tertiary)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Looking…")).font(.ui(12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .task {
            do { words = try await WordLookup.lookup(kind, word: word, context: context, lang: lang, root: root) }
            catch { self.error = error.localizedDescription }
        }
    }

    private func pick(_ w: String) {
        if kind.replaces { replace(w); return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(w, forType: .string)
        copied = w
    }
}
