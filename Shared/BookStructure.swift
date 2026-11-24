import Foundation

// The form a book chooses: what its three levels are called and how they number. Everything that says a level's
// name or a piece's number, in the Mac app, the reader and the exports, asks the manifest here and nowhere else.

/// The book's form, in `book.json` under `structure`. Absent, the book is what Musset always made: parts in roman
/// numerals, chapters numbered through the book, scenes. Only what the author changed from the form's preset is kept.
struct BookStructure: Codable, Equatable {
    /// A preset: it names the levels and says how they number.
    enum Form: String, Codable, CaseIterable, Identifiable {
        case novel, novelInParts, collection, journal, essay, play, fragments, custom
        var id: String { rawValue }
    }

    /// The three containers, largest first: a group (a part) holds pieces (chapters, one file each), a piece holds scenes.
    enum LevelID: String, CaseIterable, Identifiable {
        case group, piece, scene
        var id: String { rawValue }
    }

    enum Numbering: String, Codable, CaseIterable, Identifiable {
        case roman, arabic, none
        var id: String { rawValue }
    }

    /// Where a level starts on the printed page.
    enum Opening: String, Codable, CaseIterable, Identifiable {
        case rightPage, newPage, inPage
        var id: String { rawValue }
    }

    /// What the author set on a level; nil leaves the form's own.
    struct Level: Codable, Equatable {
        /// The author's own words; nil reads as the form's word in the book's language.
        var name: String? = nil
        var plural: String? = nil
        var numbering: Numbering? = nil
        /// Pieces only: the numbers start again in each group.
        var restarts: Bool? = nil
        var opens: Opening? = nil
        /// Groups only: the level is not used. The parts stay in the manifest, unseen.
        var off: Bool? = nil

        var isEmpty: Bool { self == Level() }
    }

    /// A strand a piece can follow: a period, a narrator, a place.
    struct Strand: Codable, Equatable, Identifiable, Hashable {
        var id: String = UUID().uuidString
        var name: String = ""
        /// "#8FA3FF".
        var colour: String
    }

    /// What Musset recognises inside a piece's text; nil leaves the form's own.
    struct TextFeatures: Codable, Equatable {
        var subheadings: Bool? = nil
        var bulletLists: Bool? = nil
        var numberedLists: Bool? = nil
    }

    var form: Form = .novel
    var group: Level? = nil
    var piece: Level? = nil
    var scene: Level? = nil
    /// The kinds of unnumbered pieces the book offers: Musset's own by their id (`prologue`, `interlude`,
    /// `epilogue`, named in the book's language), the author's by their name. Nil reads as Musset's three.
    var unnumbered: [String]? = nil
    var strands: [Strand]? = nil
    var text: TextFeatures? = nil

    /// Whether the structure changes what is printed. A novel left as Musset always made one does not: strands,
    /// the text's options and hiding the parts are the author's tools, and giving a chapter a strand must not
    /// change the book's pages.
    var shapesThePage: Bool {
        func plain(_ level: Level?) -> Bool {
            guard var level else { return true }
            level.off = nil
            return level.isEmpty
        }
        let classic = form == .novel || form == .novelInParts
        return !(classic && plain(group) && plain(piece) && plain(scene) && unnumbered == nil)
    }

    static let builtInKinds = ["prologue", "interlude", "epilogue"]
    /// The colours offered to strands, in the order they are given out: a light one, then a deep one, so that two
    /// strands side by side differ in lightness as well as in hue (told apart without telling colours apart), and
    /// none is a status's blue, orange or green.
    static let strandColours = ["#8FA3FF", "#8E4A7A", "#E0C866", "#3F7F93", "#E58FA5", "#7A5C3E", "#7FC8A9", "#6E6A9E"]

    subscript(level: LevelID) -> Level {
        get {
            switch level {
            case .group: group ?? Level()
            case .piece: piece ?? Level()
            case .scene: scene ?? Level()
            }
        }
        set {
            let kept = newValue.isEmpty ? nil : newValue
            switch level {
            case .group: group = kept
            case .piece: piece = kept
            case .scene: scene = kept
            }
        }
    }
}

// MARK: The words, in the book's language

extension BookStructure {
    /// A word Musset knows in its six languages.
    enum Term: String {
        case part, chapter, scene, section, text, year, entry, act, fragment, beat
        case prologue, interlude, epilogue
    }

    enum Gender: String { case m, f, n }

    /// A word as a language has it: one, several, and its gender for the sentences that agree with it.
    struct Word: Equatable {
        var one: String
        var many: String
        var gender: Gender
        init(_ one: String, _ many: String, _ gender: Gender) { self.one = one; self.many = many; self.gender = gender }
    }

    /// "fr-FR", "pt_BR", "de"… → the language the tables are keyed by.
    static func language(_ code: String) -> String {
        let c = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if c.hasPrefix("pt") { return c.hasSuffix("br") ? "pt-BR" : "pt" }
        return ["fr", "de", "es", "it"].first { c.hasPrefix($0) } ?? "en"
    }

    static func word(_ term: Term, lang: String) -> Word {
        let l = language(lang)
        let forms = words[term] ?? [:]
        return forms[l] ?? forms[String(l.prefix(2))] ?? forms["en"]!
    }

    private static let words: [Term: [String: Word]] = [
        .part: ["en": Word("Part", "Parts", .n), "fr": Word("Partie", "Parties", .f), "de": Word("Teil", "Teile", .m),
                "es": Word("Parte", "Partes", .f), "it": Word("Parte", "Parti", .f), "pt": Word("Parte", "Partes", .f)],
        .chapter: ["en": Word("Chapter", "Chapters", .n), "fr": Word("Chapitre", "Chapitres", .m), "de": Word("Kapitel", "Kapitel", .n),
                   "es": Word("Capítulo", "Capítulos", .m), "it": Word("Capitolo", "Capitoli", .m), "pt": Word("Capítulo", "Capítulos", .m)],
        .scene: ["en": Word("Scene", "Scenes", .n), "fr": Word("Scène", "Scènes", .f), "de": Word("Szene", "Szenen", .f),
                 "es": Word("Escena", "Escenas", .f), "it": Word("Scena", "Scene", .f), "pt": Word("Cena", "Cenas", .f)],
        .section: ["en": Word("Section", "Sections", .n), "fr": Word("Section", "Sections", .f), "de": Word("Abschnitt", "Abschnitte", .m),
                   "es": Word("Sección", "Secciones", .f), "it": Word("Sezione", "Sezioni", .f), "pt": Word("Secção", "Secções", .f),
                   "pt-BR": Word("Seção", "Seções", .f)],
        .text: ["en": Word("Piece", "Pieces", .n), "fr": Word("Texte", "Textes", .m), "de": Word("Text", "Texte", .m),
                "es": Word("Texto", "Textos", .m), "it": Word("Testo", "Testi", .m), "pt": Word("Texto", "Textos", .m)],
        .year: ["en": Word("Year", "Years", .n), "fr": Word("Année", "Années", .f), "de": Word("Jahr", "Jahre", .n),
                "es": Word("Año", "Años", .m), "it": Word("Anno", "Anni", .m), "pt": Word("Ano", "Anos", .m)],
        .entry: ["en": Word("Entry", "Entries", .n), "fr": Word("Entrée", "Entrées", .f), "de": Word("Eintrag", "Einträge", .m),
                 "es": Word("Entrada", "Entradas", .f), "it": Word("Voce", "Voci", .f), "pt": Word("Entrada", "Entradas", .f)],
        .act: ["en": Word("Act", "Acts", .n), "fr": Word("Acte", "Actes", .m), "de": Word("Akt", "Akte", .m),
               "es": Word("Acto", "Actos", .m), "it": Word("Atto", "Atti", .m), "pt": Word("Ato", "Atos", .m)],
        .fragment: ["en": Word("Fragment", "Fragments", .n), "fr": Word("Fragment", "Fragments", .m), "de": Word("Fragment", "Fragmente", .n),
                    "es": Word("Fragmento", "Fragmentos", .m), "it": Word("Frammento", "Frammenti", .m), "pt": Word("Fragmento", "Fragmentos", .m)],
        .beat: ["en": Word("Beat", "Beats", .n), "fr": Word("Moment", "Moments", .m), "de": Word("Moment", "Momente", .m),
                "es": Word("Momento", "Momentos", .m), "it": Word("Momento", "Momenti", .m), "pt": Word("Momento", "Momentos", .m)],
        .prologue: ["en": Word("Prologue", "Prologues", .n), "fr": Word("Prologue", "Prologues", .m), "de": Word("Prolog", "Prologe", .m),
                    "es": Word("Prólogo", "Prólogos", .m), "it": Word("Prologo", "Prologhi", .m), "pt": Word("Prólogo", "Prólogos", .m)],
        .interlude: ["en": Word("Interlude", "Interludes", .n), "fr": Word("Interlude", "Interludes", .m), "de": Word("Zwischenspiel", "Zwischenspiele", .n),
                     "es": Word("Interludio", "Interludios", .m), "it": Word("Interludio", "Interludi", .m), "pt": Word("Interlúdio", "Interlúdios", .m)],
        .epilogue: ["en": Word("Epilogue", "Epilogues", .n), "fr": Word("Épilogue", "Épilogues", .m), "de": Word("Epilog", "Epiloge", .m),
                    "es": Word("Epílogo", "Epílogos", .m), "it": Word("Epilogo", "Epiloghi", .m), "pt": Word("Epílogo", "Epílogos", .m)],
    ]
}

// MARK: The presets

extension BookStructure {
    /// A level as a form sets it.
    struct LevelPreset: Equatable {
        var term: Term
        var numbering: Numbering
        var restarts = false
        var opens: Opening
        /// The form does not use this level: it stays out of its diagram, and a group level is off.
        var unused = false
    }

    struct Preset: Equatable {
        var group: LevelPreset
        var piece: LevelPreset
        var scene: LevelPreset
        /// Sub-headings and numbered lists in the text; bullet lists are on in every form.
        var richText = false

        subscript(level: LevelID) -> LevelPreset {
            switch level {
            case .group: group
            case .piece: piece
            case .scene: scene
            }
        }
    }

    /// What each form fills in. `novelInParts` is the book Musset always made: a manifest with no structure reads as
    /// it; `custom` starts from it too, and then keeps whatever the author sets.
    static func preset(_ form: Form) -> Preset {
        let part = LevelPreset(term: .part, numbering: .roman, opens: .rightPage)
        let chapter = LevelPreset(term: .chapter, numbering: .arabic, opens: .newPage)
        let scene = LevelPreset(term: .scene, numbering: .none, opens: .inPage)
        func unused(_ l: LevelPreset) -> LevelPreset { var l = l; l.unused = true; return l }
        switch form {
        case .novelInParts, .custom:
            return Preset(group: part, piece: chapter, scene: scene)
        case .novel:
            return Preset(group: unused(part), piece: chapter, scene: scene)
        case .collection:
            return Preset(group: LevelPreset(term: .section, numbering: .none, opens: .rightPage),
                          piece: LevelPreset(term: .text, numbering: .none, opens: .newPage), scene: unused(scene))
        case .journal:
            return Preset(group: LevelPreset(term: .year, numbering: .none, opens: .rightPage),
                          piece: LevelPreset(term: .entry, numbering: .none, opens: .inPage), scene: unused(scene))
        case .essay:
            return Preset(group: part, piece: chapter, scene: LevelPreset(term: .section, numbering: .arabic, restarts: true, opens: .inPage),
                          richText: true)
        case .play:
            return Preset(group: LevelPreset(term: .act, numbering: .roman, opens: .rightPage),
                          piece: LevelPreset(term: .scene, numbering: .arabic, restarts: true, opens: .newPage),
                          scene: unused(LevelPreset(term: .beat, numbering: .none, opens: .inPage)))
        case .fragments:
            return Preset(group: unused(part), piece: LevelPreset(term: .fragment, numbering: .arabic, opens: .inPage), scene: unused(scene))
        }
    }

    /// The levels a form shows in its diagram, largest first.
    static func levels(of form: Form) -> [LevelID] {
        LevelID.allCases.filter { !preset(form)[$0].unused }
    }
}

// MARK: A level as the book has it

/// A level with everything settled: the author's choices over the form's.
struct BookLevel: Equatable {
    var id: BookStructure.LevelID
    /// « Chapitre », « Chapitres »: as a heading writes them.
    var name: String
    var plural: String
    /// The word when it is Musset's own (nil once the author typed theirs): what the interface can agree with.
    var term: BookStructure.Term?
    var gender: BookStructure.Gender?
    var numbering: BookStructure.Numbering
    var restarts: Bool
    var opens: BookStructure.Opening
    /// False for a group level switched off.
    var on: Bool
}

extension BookManifest {
    /// The form the book reads as: its own, or the one Musset always made, a novel, in parts once it has some.
    var form: BookStructure.Form {
        structure?.form ?? (chapters.contains { ch in parts?.contains { $0.id == ch.part } == true } ? .novelInParts : .novel)
    }

    func level(_ id: BookStructure.LevelID) -> BookLevel {
        // No structure is the book Musset always made: a novel whose parts show as soon as it has some.
        let preset = BookStructure.preset(structure?.form ?? .novelInParts)[id]
        let own = structure?[id] ?? BookStructure.Level()
        let word = BookStructure.word(preset.term, lang: lang)
        let name = own.name.flatMap(Self.typed)
        let plural = own.plural.flatMap(Self.typed)
        let on = id == .group ? !(own.off ?? preset.unused) : true
        return BookLevel(id: id, name: name ?? word.one, plural: plural ?? name ?? word.many,
                         term: name == nil && plural == nil ? preset.term : nil, gender: name == nil ? word.gender : nil,
                         numbering: own.numbering ?? preset.numbering, restarts: id == .scene ? true : own.restarts ?? preset.restarts,
                         opens: own.opens ?? preset.opens, on: on)
    }

    private static func typed(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// What Musset recognises in the text: bullet lists always did; sub-headings and numbered lists are the essay's.
    var textFeatures: (subheadings: Bool, bulletLists: Bool, numberedLists: Bool) {
        let rich = structure.map { BookStructure.preset($0.form).richText } ?? false
        let own = structure?.text
        return (own?.subheadings ?? rich, own?.bulletLists ?? true, own?.numberedLists ?? rich)
    }

    // MARK: Names

    /// « 3 chapitres », « 1 entrée »: a count in the book's words. German keeps its capitals.
    func count(_ n: Int, _ id: BookStructure.LevelID) -> String {
        let l = level(id)
        let language = BookStructure.language(lang)
        let one = language == "fr" || language == "pt-BR" ? n == 0 || n == 1 : n == 1
        let word = one ? l.name : l.plural
        return "\(n) " + (language == "de" ? word : word.lowercased())
    }

    /// A number as a level writes it: « 3 », « III », or nothing.
    static func mark(_ n: Int, _ numbering: BookStructure.Numbering) -> String {
        switch numbering {
        case .arabic: "\(n)"
        case .roman: roman(n)
        case .none: ""
        }
    }

    // MARK: Unnumbered pieces

    /// The kinds the book offers, Musset's by id and the author's by name.
    var unnumberedKinds: [String] { structure?.unnumbered ?? BookStructure.builtInKinds }

    /// A kind's name: Musset's in the book's language, the author's as typed.
    func kindName(_ kind: String) -> String {
        BookStructure.Term(rawValue: kind).flatMap { BookStructure.builtInKinds.contains(kind) ? BookStructure.word($0, lang: lang).one : nil } ?? kind
    }

    /// The kind of an unnumbered piece, nil for one that takes its number.
    static func kind(of ch: ChapterEntry) -> String? {
        ch.kind.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    // MARK: Groups

    /// Whether the book groups its pieces: the level is on. Off, the parts stay in the manifest and nothing shows them.
    var groupsOn: Bool { level(.group).on }

    /// The parts the book shows, in its order: none when the level is off.
    var shownParts: [BookPart] { groupsOn ? orderedParts : [] }

    /// The group a piece is in, if the level is on and the part still exists.
    func group(of ch: ChapterEntry) -> BookPart? {
        guard groupsOn, let id = ch.part else { return nil }
        return parts?.first { $0.id == id }
    }

    /// A group's number as the level writes it: « II », « 2 », or nothing.
    func numeral(of part: String) -> String {
        Self.mark((orderedParts.firstIndex { $0.id == part } ?? 0) + 1, level(.group).numbering)
    }

    /// « II » or « II. La fuite »; a level without numbers gives the title, or the level's name for want of one.
    func label(of part: BookPart) -> String {
        let n = numeral(of: part.id)
        if n.isEmpty { return part.title.isEmpty ? level(.group).name : part.title }
        return part.title.isEmpty ? n : n + ". " + part.title
    }

    /// The line a group opens under: « Partie II », « Acte III »; without numbers, its title or the level's name.
    func heading(of part: BookPart) -> String {
        let n = numeral(of: part.id)
        return n.isEmpty ? (part.title.isEmpty ? level(.group).name : part.title) : level(.group).name + " " + n
    }

    /// Where each group begins among the pieces that print: the piece's id, with the group's numeral and title.
    var partOpenings: [String: (numeral: String, title: String)] {
        var out: [String: (String, String)] = [:]
        var previous: String?
        for ch in chapters where !ch.excludeFromExport {
            if let part = group(of: ch), part.id != previous { out[ch.id] = (numeral(of: part.id), part.title) }
            previous = ch.part
        }
        return out
    }

    // MARK: Pieces

    /// Each piece's number, in the book's order: nil for an unnumbered piece (it takes no number: those after it
    /// count as if it were not there) and for a level without numbers. With `restarts`, each group counts from 1.
    var pieceNumbers: [Int?] {
        let l = level(.piece)
        guard l.numbering != .none else { return chapters.map { _ in nil } }
        let restarts = l.restarts && groupsOn
        var n = 0
        var previous: String?
        return chapters.map { ch in
            let group = restarts ? self.group(of: ch)?.id : nil
            if restarts, group != previous { n = 0 }
            previous = group
            if Self.kind(of: ch) != nil { return nil }
            n += 1
            return n
        }
    }

    /// Each piece's number as lists show it: « 3 », « III », or nothing.
    var pieceMarks: [String] {
        let numbering = level(.piece).numbering
        return pieceNumbers.map { $0.map { Self.mark($0, numbering) } ?? "" }
    }

    func pieceNumber(of id: String) -> Int? {
        chapters.firstIndex { $0.id == id }.flatMap { pieceNumbers[$0] }
    }

    /// One piece's mark; a list that shows them all takes `pieceMarks` once.
    func pieceMark(at index: Int) -> String {
        let marks = pieceMarks
        return marks.indices.contains(index) ? marks[index] : ""
    }
    func pieceMark(of id: String) -> String { chapters.firstIndex { $0.id == id }.map(pieceMark(at:)) ?? "" }

    /// The line over a piece's title: « Chapitre 3 », « Scène II », « Prologue »; nil when the piece has only its title.
    func heading(of ch: ChapterEntry) -> String? {
        if let kind = Self.kind(of: ch) { return kindName(kind) }
        let mark = pieceMark(of: ch.id)
        return mark.isEmpty ? nil : level(.piece).name + " " + mark
    }

    /// What a list calls a piece: its title, or its kind's name when an unnumbered piece has none of its own.
    func shownTitle(of ch: ChapterEntry) -> String {
        guard let kind = Self.kind(of: ch), ch.title.trimmingCharacters(in: .whitespaces).isEmpty else { return ch.title }
        return kindName(kind)
    }

    /// « 3 La fuite », or the title alone: a piece in a tab, a menu, a tooltip.
    func numberedTitle(of ch: ChapterEntry) -> String {
        let mark = pieceMark(of: ch.id)
        return mark.isEmpty ? shownTitle(of: ch) : mark + " " + shownTitle(of: ch)
    }

    /// How a piece is referred to in a list of pieces: its number, or its title when it has none.
    func pieceReference(at index: Int) -> String {
        let mark = pieceMark(at: index)
        return mark.isEmpty && chapters.indices.contains(index) ? shownTitle(of: chapters[index]) : mark
    }

    /// The number the next piece would take at the end of the book, with `ahead` planned pieces before it.
    func nextPieceMark(ahead: Int = 0) -> String {
        let l = level(.piece)
        guard l.numbering != .none else { return "" }
        let numbers = pieceNumbers
        var n = numbers.compactMap { $0 }.last ?? 0
        if l.restarts, groupsOn {
            // Only the last group's pieces count.
            let last = chapters.last.flatMap { group(of: $0)?.id }
            n = 0
            for (i, ch) in chapters.enumerated().reversed() {
                if group(of: ch)?.id != last { break }
                if let k = numbers[i] { n = k; break }
            }
        }
        return Self.mark(n + 1 + ahead, l.numbering)
    }

    /// The title a new piece is given, there to be replaced: « Chapitre 8 », « Entrée 12 ».
    func newPieceTitle(_ number: Int) -> String { level(.piece).name + " \(number)" }

    /// A scene by its number, for one without a title: « Scène 3 ».
    func sceneTitle(_ number: Int) -> String { level(.scene).name + " \(number)" }

    // MARK: Changing the form

    /// Takes a form: its names and numbers replace the book's. The pieces, the parts and the files are not touched;
    /// the kinds and the strands stay. `custom` keeps the book as it stands, each word and number now the author's.
    mutating func setForm(_ form: BookStructure.Form) {
        var next = BookStructure(form: form)
        next.unnumbered = structure?.unnumbered
        next.strands = structure?.strands
        // The lists the author switched on or off stay with the book when its form changes.
        if let t = structure?.text, t.bulletLists != nil || t.numberedLists != nil {
            next.text = BookStructure.TextFeatures(bulletLists: t.bulletLists, numberedLists: t.numberedLists)
        }
        if form == .custom {
            for id in BookStructure.LevelID.allCases {
                let l = level(id)
                next[id] = BookStructure.Level(name: l.name, plural: l.plural, numbering: l.numbering,
                                               restarts: id == .piece ? l.restarts : nil, opens: l.opens, off: id == .group ? !l.on : nil)
            }
            let t = textFeatures
            next.text = BookStructure.TextFeatures(subheadings: t.subheadings, bulletLists: t.bulletLists, numberedLists: t.numberedLists)
        }
        structure = next
    }

    // MARK: Strands

    /// The strands the book has, in the author's order.
    var strands: [BookStructure.Strand] { structure?.strands ?? [] }

    func strand(_ id: String) -> BookStructure.Strand? { structure?.strands?.first { $0.id == id } }

    /// The strand a piece follows, if the book still has it.
    func strand(of ch: ChapterEntry) -> BookStructure.Strand? {
        ch.strand.flatMap(strand)
    }

    /// How many pieces follow a strand.
    func pieces(in strand: String) -> Int { chapters.filter { $0.strand == strand }.count }

    /// The colour a new strand takes: the first of the palette no strand has yet.
    var nextStrandColour: String {
        let used = Set(strands.map { $0.colour.uppercased() })
        return BookStructure.strandColours.first { !used.contains($0) } ?? BookStructure.strandColours[strands.count % BookStructure.strandColours.count]
    }
}

// MARK: On the page

/// A piece as an output opens it, in a book with a form of its own.
struct PieceOpening: Equatable {
    /// The line over the title: « Chapitre 3 », « Prologue ». Nil: the title alone.
    var label: String?
    /// The title to print for a text that has no heading of its own. Nil with no label either: nothing to print.
    var title: String?
}

/// A piece's text, as far as the book's form needs to read it.
enum PieceText {
    /// The line of a chapter's `# ` heading: near the top, outside HTML comments.
    static func headingLine(in text: String) -> Substring? {
        var inComment = false, lines = 0
        for piece in text.split(separator: "\n", maxSplits: 200, omittingEmptySubsequences: true) {
            let line = piece.prefix { $0 != "\n" }
            if inComment { inComment = !line.contains("-->"); continue }
            if line.hasPrefix("<!--") { inComment = !line.contains("-->"); continue }
            if line.hasPrefix("# ") { return line }
            lines += 1
            if lines == 10 { return nil }
        }
        return nil
    }

    static let headingAttributes = #"\s*\{[^}]*\}\s*$"#

    /// The chapter's title as its heading gives it; nil when there is none, or while it is still empty.
    static func heading(in text: String) -> String? {
        guard var title = headingLine(in: text).map({ String($0.dropFirst(2)) }) else { return nil }
        for pattern in [headingAttributes, #"\s+#+\s*$"#] {
            if let r = title.range(of: pattern, options: .regularExpression) { title.removeSubrange(r) }
        }
        title = title.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*_")))
        return title.isEmpty ? nil : title
    }
}

extension BookManifest {
    /// Whether the book prints by a form of its own: it chose one, or one of its pieces is a prologue, an interlude…
    /// A book with neither is the book Musset always made, and every output writes it exactly as it always did.
    var hasForm: Bool { structure?.shapesThePage == true || chapters.contains { Self.kind(of: $0) != nil } }

    /// A title that only says the piece's place (« Chapitre 8 », the one a new piece is given): no title at all,
    /// since the place is the form's to say, and may have changed since.
    func isPlaceholder(_ title: String) -> Bool {
        let name = level(.piece).name.lowercased()
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        guard t.hasPrefix(name + " ") else { return false }
        let rest = t.dropFirst(name.count + 1)
        return !rest.isEmpty && (rest.allSatisfy(\.isNumber) || rest.allSatisfy { "ivxlcdm".contains($0) })
    }

    /// How a piece opens in the PDF, Word, EPUB and Markdown of a formed book; nil in a book without a form.
    /// `text`: the piece's Markdown, whose `# ` heading is its printed title. The label is not said twice: a piece
    /// titled « Prologue », or still called « Chapitre 3 », opens under that alone.
    func opening(of ch: ChapterEntry, text: String) -> PieceOpening? {
        guard hasForm else { return nil }
        func same(_ a: String, _ b: String) -> Bool { a.compare(b, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let label = heading(of: ch)
        if let own = PieceText.heading(in: text) {
            // The heading prints as written; over a real title, the piece's line.
            return PieceOpening(label: label.flatMap { same($0, own) || isPlaceholder(own) ? nil : $0 }, title: nil)
        }
        let title = Self.typed(shownTitle(of: ch)).flatMap { t in isPlaceholder(t) || label.map { same($0, t) } == true ? nil : t }
        // Without a title the label is all the piece opens under.
        return PieceOpening(label: title == nil ? nil : label, title: title ?? label)
    }

    /// Where each group begins among the pieces that print, as an output writes it: the line (« II » in a book
    /// without a form, as always; « Acte II » in a formed one; the title or the level's name for a level without
    /// numbers) and the title under it. A group never opens on an empty line.
    var groupOpenings: [String: (line: String, title: String)] {
        guard hasForm else { return partOpenings.mapValues { ($0.numeral, $0.title) } }
        var out: [String: (String, String)] = [:]
        var previous: String?
        for ch in chapters where !ch.excludeFromExport {
            if let part = group(of: ch), part.id != previous {
                out[ch.id] = (heading(of: part), numeral(of: part.id).isEmpty ? "" : part.title)
            }
            previous = ch.part
        }
        return out
    }
}
