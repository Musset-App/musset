import SwiftUI

/// How long a text is, in the three ways an author is asked for: words, characters, characters with spaces.
/// Counted once and kept, so a click on the unit costs nothing.
struct TextCounts: Equatable, Sendable {
    var words = 0
    /// Without spaces of any kind.
    var characters = 0
    /// Spaces counted, line ends not.
    var charactersWithSpaces = 0

    static let zero = TextCounts()

    init() {}

    /// The same text for the three: what `BookStore.wordCount` counts, scene markers and other comments left out.
    /// A character is what the author sees as one (« é », an emoji), and Markdown's own marks are not the text's.
    init(_ text: String) {
        let body = BookStore.stripHTMLComments(text)
        words = BookStore.wordCount(body)
        var spaces = 0
        for c in body {
            if c.isNewline { continue }
            if c.isWhitespace { spaces += 1 } else if !Self.isMarkup(c) { characters += 1 }
        }
        charactersWithSpaces = characters + spaces
    }

    /// The marks `ManuscriptNorm.count` leaves out of the title page's count too.
    private static func isMarkup(_ c: Character) -> Bool { c == "*" || c == "_" || c == "#" || c == ">" || c == "`" }

    subscript(unit: CountUnit) -> Int {
        switch unit {
        case .words: words
        case .characters: characters
        case .charactersWithSpaces: charactersWithSpaces
        }
    }

    static func + (a: TextCounts, b: TextCounts) -> TextCounts {
        var out = a
        out.words += b.words
        out.characters += b.characters
        out.charactersWithSpaces += b.charactersWithSpaces
        return out
    }
}

/// The unit every count of the manuscript is shown in. One for the whole app, changed by a click on a count.
/// Writing goals and the day's words stay in words whatever it is.
enum CountUnit: String, CaseIterable, Sendable {
    case words, characters, charactersWithSpaces

    static let key = "countUnit"

    /// The one a click goes to: words, characters, characters with spaces, and words again.
    var next: CountUnit {
        switch self {
        case .words: .characters
        case .characters: .charactersWithSpaces
        case .charactersWithSpaces: .words
        }
    }

    /// « 2 034 mots », « 11 742 signes », « 13 775 signes espaces comprises »: the number as the interface writes
    /// numbers, the noun in the singular when there is one.
    func label(_ n: Int) -> String {
        let english = switch self {
        case .words: "{%0} words"
        case .characters: "{%0} characters"
        case .charactersWithSpaces: "{%0} characters with spaces"
        }
        var key = LKey(stringLiteral: english)
        key.args = [n.ui]
        key.count = n
        return Strings.text(key)
    }

    func label(_ counts: TextCounts) -> String { label(counts[self]) }

    /// Above a column of counts: short, the count beside the title says which characters.
    var heading: String {
        switch self {
        case .words: L("Words")
        case .characters, .charactersWithSpaces: L("Characters", ctx: "Signes")
        }
    }

    @MainActor static var current: CountUnit { CountSetting.shared.unit }
    @MainActor static func cycle() { CountSetting.shared.unit = current.next }
    static var help: String { L("Click to count in words, characters, or characters with spaces") }
}

/// The chosen unit, kept across launches. Observed: every view that reads it redraws when a click changes it.
@MainActor @Observable final class CountSetting {
    static let shared = CountSetting()
    var unit: CountUnit {
        didSet { UserDefaults.standard.set(unit.rawValue, forKey: CountUnit.key) }
    }

    private init() { unit = CountUnit(rawValue: UserDefaults.standard.string(forKey: CountUnit.key) ?? "") ?? .words }
}

extension TextCounts {
    /// In the unit chosen: the number alone, and with its noun.
    @MainActor var size: Int { self[CountUnit.current] }
    @MainActor var label: String { CountUnit.current.label(self) }

    /// A book's length beside its goal. The goal is in words: it shows only when the count is too.
    @MainActor func label(goal: Int?) -> String {
        guard CountUnit.current == .words, let goal else { return label }
        return words.ui + " / \(goal.ui) " + L("words")
    }
}

/// A count one can click to change the unit, everywhere at once. Its dotted line says it can be clicked.
struct CountButton: View {
    let text: String
    var body: some View {
        Button { CountUnit.cycle() } label: {
            Text(text).underline(true, pattern: .dot, color: .secondary.opacity(0.6))
        }
        .buttonStyle(.plain)
        .help(CountUnit.help)
    }
}
