import CoreGraphics
import SwiftUI

/// The inks a reader marks with. Each person keeps one colour everywhere.
public enum Ink: String, CaseIterable, Codable, Sendable, Identifiable {
    case amber, yellow, teal, rose, blue, violet

    public var id: String { rawValue }

    /// The swatch, and the highlighter's colour on the page.
    public var color: Color { Color(rgb: swatch) }
    /// A darker shade for lines and handwriting, readable on paper.
    public var lineColor: Color { Color(rgb: line) }

    var swatch: UInt32 {
        switch self {
        case .amber: 0xE0A33A
        case .yellow: 0xE8D44D
        case .teal: 0x4DB3AA
        case .rose: 0xE58BA0
        case .blue: 0x7D96E8
        case .violet: 0xA98BE0
        }
    }

    var line: UInt32 {
        switch self {
        case .amber: 0x8A5006
        case .yellow: 0x7A6A0C
        case .teal: 0x1B7F79
        case .rose: 0xA3405A
        case .blue: 0x2E4AC7
        case .violet: 0x5E3FA8
        }
    }

    /// What VoiceOver says for the swatch.
    public var name: String {
        switch self {
        case .amber: "Amber"
        case .yellow: "Yellow"
        case .teal: "Teal"
        case .rose: "Rose"
        case .blue: "Blue"
        case .violet: "Violet"
        }
    }
}

/// A mark on the text, as plain values: phase 4's annotations are turned into these.
public struct Mark: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case highlight, underline, strike, note
    }

    public var id: String
    /// The chapter's id in `BookSource.chapters`.
    public var chapter: String
    /// UTF-16 range in the chapter's Markdown.
    public var range: Range<Int>
    public var kind: Kind
    public var ink: Ink
    /// Who made it, shown under a margin note.
    public var person: String?
    /// A margin note's text (a note, or a highlight with a comment).
    public var note: String?

    public init(id: String, chapter: String, range: Range<Int>, kind: Kind, ink: Ink, person: String? = nil, note: String? = nil) {
        self.id = id
        self.chapter = chapter
        self.range = range
        self.kind = kind
        self.ink = ink
        self.person = person
        self.note = note
    }
}

/// What the reader selected: a range of one chapter, and the text it shows.
public struct TextSelection: Hashable, Sendable {
    public var chapter: String
    public var range: Range<Int>
    public var text: String
}

/// What the selection menu asks for.
public enum SelectionAction: Hashable, Sendable {
    case highlight(Ink)
    case underline
    case strike
    case note(String)
    case suggest(String)
}

extension Color {
    init(rgb: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((rgb >> 16) & 0xFF) / 255, green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255, opacity: opacity)
    }
}

/// A small random generator seeded from a mark, so its hand-drawn wobble is the same at every redraw.
struct SeededRandom {
    private var state: UInt64

    init(_ seed: String) {
        // FNV-1a: stable across launches, unlike `hashValue`.
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in seed.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01B3 }
        state = h
    }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// In -1…1.
    mutating func unit() -> CGFloat { CGFloat(Double(next() >> 11) / Double(1 << 53)) * 2 - 1 }
}
