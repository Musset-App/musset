import Foundation

/// The book's special pages, around the chapters: cover, title page, dedication, epigraph, contents,
/// and at the end acknowledgements and colophon. Kept in the manifest; typeset with the book, never in a chapter file.
struct FrontMatter: Codable, Equatable {
    struct Cover: Codable, Equatable {
        /// "typographic", "image" or "plain".
        var style: String = "typographic"
        var genre: String = ""
        var publisher: String = ""
        var ground: String = "#F3EEE2"
        var accent: String = "#9B2F26"
        /// Image path relative to the book folder, for the "image" style.
        var image: String? = nil
        var inPDF: Bool = true
    }

    var cover: Cover? = nil
    var titlePage: Bool? = nil
    var dedication: String? = nil
    var epigraph: String? = nil
    var epigraphSource: String? = nil
    var contents: Bool? = nil
    var acknowledgements: String? = nil
    var colophon: Bool? = nil

    func has(_ page: SpecialPage) -> Bool {
        switch page {
        case .cover: cover?.inPDF ?? false
        case .title: titlePage ?? true
        case .dedication: !(dedication ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .epigraph: !(epigraph ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .contents: contents ?? false
        case .acknowledgements: !(acknowledgements ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .colophon: colophon ?? false
        }
    }
}

enum SpecialPage: String, CaseIterable, Identifiable, Hashable {
    case cover, title, dedication, epigraph, contents, acknowledgements, colophon
    var id: String { rawValue }
    var isBack: Bool { self == .acknowledgements || self == .colophon }
    var label: String {
        switch self {
        case .cover: L("Cover")
        case .title: L("Title page")
        case .dedication: L("Dedication")
        case .epigraph: L("Epigraph")
        case .contents: L("Contents", ctx: "Table des matières")
        case .acknowledgements: L("Acknowledgements")
        case .colophon: L("Colophon")
        }
    }
    var icon: String {
        switch self {
        case .cover: "rectangle.portrait"
        case .title: "textformat.size"
        case .dedication: "heart.text.square"
        case .epigraph: "quote.opening"
        case .contents: "list.bullet.indent"
        case .acknowledgements: "hands.sparkles"
        case .colophon: "seal"
        }
    }
    static var front: [SpecialPage] { allCases.filter { !$0.isBack } }
    static var back: [SpecialPage] { allCases.filter(\.isBack) }
}
