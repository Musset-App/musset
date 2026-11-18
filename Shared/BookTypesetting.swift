import Foundation
import MussetPage

// A book as the typesetter takes it, on the Mac and in the reader: the words and the numbers are the manifest's
// (`BookStructure.swift`), the engine writes what it is given.

extension BookManifest {
    /// Where a formed book's levels open; nil for a book without a form, set as it always was.
    var typesetForm: BookSource.Form? {
        hasForm ? BookSource.Form(groupOpens: level(.group).opens.rawValue, pieceOpens: level(.piece).opens.rawValue) : nil
    }

    /// What the book recognises in its text (lists, sections), for the typesetter. Not the form's to say: a novel
    /// left as Musset always made one can ask for numbered lists, and the default is the text as it always was.
    var typesetText: BookSource.TextOptions {
        let t = textFeatures
        return BookSource.TextOptions(bullets: t.bulletLists, numbered: t.numberedLists, sections: t.subheadings)
    }

    /// The pieces for the typesetter, each with its group's page before it (`groups`: off for a piece read alone)
    /// and, in a formed book, the line it opens under.
    func typesetChapters(_ texts: [(id: String, text: String)], groups: Bool = true) -> [BookSource.Chapter] {
        let openings = groups ? groupOpenings : [:]
        let entries = Dictionary(chapters.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return texts.map { piece in
            BookSource.Chapter(id: piece.id, markdown: piece.text,
                               part: openings[piece.id].map { BookSource.Part(numeral: $0.line, title: $0.title) },
                               // A page Musset adds after the pieces (the works cited) opens under its own title, not the last piece's line.
                               opening: !hasForm ? nil : entries[piece.id].flatMap { opening(of: $0, text: piece.text) }
                                   .map { BookSource.Opening(label: $0.label, title: $0.title) } ?? BookSource.Opening())
        }
    }
}
