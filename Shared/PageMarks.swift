import Foundation
import MussetPage

/// Conversations drawn by the reading engine: each thread's passage, in its starter's ink, on the Mac and the iPhone.
extension Person {
    /// The reading engine's ink for a person: the same colour as everywhere else in Musset.
    static func ink(_ username: String) -> MussetPage.Ink {
        let inks: [MussetPage.Ink] = [.amber, .teal, .violet, .blue, .rose]   // in the order of `palette`
        return inks[palette.firstIndex(of: color(username)) ?? 0]
    }
}

extension TalkThread {
    /// The thread as a mark on its chapter, where its passage stands now in `text` (nil when it can't be placed).
    /// The id is the thread's, so a tap on the mark finds its conversation.
    func pageMark(in text: String, name: (String) -> String) -> MussetPage.Mark? {
        guard let a = note.anchor, let r = Anchoring.resolve(a, in: text), r.length > 0 else { return nil }
        let kind: MussetPage.Mark.Kind = switch note.mark ?? .highlight {
        case .highlight: .highlight
        case .underline: .underline
        case .strike: .strike
        case .margin: .note
        }
        let body = note.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return MussetPage.Mark(id: id.uuidString, chapter: chapter, range: r.location..<(r.location + r.length), kind: kind,
                               ink: Person.ink(note.by), person: name(note.by), note: body.isEmpty ? nil : body)
    }
}

extension SelectionAction {
    /// What the reader asked for, as a conversation's mark and first words.
    var talk: (mark: TalkEntry.Mark, body: String) {
        switch self {
        case .highlight: (.highlight, "")
        case .underline: (.underline, "")
        case .strike: (.strike, "")
        case .note(let text): (.margin, text)
        case .suggest(let text): (.strike, "→ " + text)
        }
    }
}

extension PageStrings {
    /// The reader's words in Musset's language.
    static var musset: PageStrings {
        var s = PageStrings()
        s.highlight = L("Highlight")
        s.underline = L("Underline")
        s.note = L("Note")
        s.suggest = L("Suggest")
        s.notePlaceholder = L("A note for the author")
        s.suggestPlaceholder = L("What it should say")
        s.add = L("Add")
        s.markSelection = L("Mark the selection")
        s.previousPage = L("Previous page")
        s.nextPage = L("Next page")
        s.textSize = L("Text size")
        s.night = L("Night")
        s.composing = L("Typesetting…")
        s.pages = { first, last, count in first == last ? L("Page \(first) of \(count)") : L("Pages \(first)–\(last) of \(count)") }
        return s
    }
}
