import Foundation
import SwiftUI

/// The account's plan, its circle, invitations and notices, as musset-api keeps them beside Forgejo.
/// A free account reads, annotates and talks about the books shared with it; a writer (Musset Sync) also puts books online.
struct AccountInfo: Decodable, Equatable {
    var username: String
    var name: String
    var email: String
    var plan: String
    var status: String?
    var until: Int?
    var comp: Bool
    var mail: String
    var lang: String?
    var isWriter: Bool { plan == "writer" }
    var renews: Date? { until.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
}

/// Someone in my circle: on Musset already (`username`), or invited by e-mail and not there yet.
struct CirclePerson: Decodable, Identifiable, Equatable, Hashable {
    let id: Int
    let username: String?
    let email: String?
    let name: String
    let relation: String
    let books: [String]
    /// When they were invited, while they have no account.
    let invited: Int?

    var isPending: Bool { username == nil }
    var initials: String {
        let parts = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" }).prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }
}

/// How someone knows me, in the circle.
enum Relation: String, CaseIterable, Identifiable {
    case editor, betaReader = "beta-reader", publisher, agent, translator, author, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .editor: L("Editor", ctx: "Éditrice")
        case .betaReader: L("Beta reader")
        case .publisher: L("Publisher", ctx: "Maison d’édition")
        case .agent: L("Agent")
        case .translator: L("Translator")
        case .author: L("Author")
        case .other: L("Other", ctx: "Autre personne")
        }
    }
    /// The heading of their group: a section label, which capitalises it.
    var heading: String {
        switch self {
        case .editor: L("Editors")
        case .betaReader: L("Beta readers")
        case .publisher: L("Publishers", ctx: "Maisons d’édition")
        case .agent: L("Agents")
        case .translator: L("Translators")
        case .author: L("Authors")
        case .other: L("Others")
        }
    }
}

/// Something that happened in a book shared with me, or in one of mine.
struct ActivityItem: Decodable, Identifiable, Equatable {
    let id: Int
    let actor: String?
    let actorName: String?
    let kind: String
    let repo: String?
    let tag: String?
    let thread: String?
    let chapter: String?
    let title: String?
    let message: String?
    let at: Int
    let read: Int

    var isUnread: Bool { read == 0 }
    var date: Date { Date(timeIntervalSince1970: TimeInterval(at)) }
    var book: String { title ?? repo?.split(separator: "/").last.map(String.init) ?? "" }
    var sentence: String {
        let who = actorName ?? actor ?? ""
        switch kind {
        case "milestone": return L("\(who) marked \(tag ?? "") in \(book)")
        case "shared": return L("\(who) shared \(book) with you")
        case "reply": return L("\(who) answered in \(book)")
        case "note": return L("\(who) left a note in \(book)")
        default: return book
        }
    }
}

/// Each reader keeps one colour everywhere (their marks, their notes, their initials), picked from their name.
enum Person {
    static let palette: [Color] = [
        Color(red: 0.72, green: 0.42, blue: 0.04),   // amber
        Color(red: 0.11, green: 0.50, blue: 0.47),   // teal
        Color(red: 0.48, green: 0.30, blue: 0.76),   // purple
        Color(red: 0.18, green: 0.29, blue: 0.78),   // ink blue
        Color(red: 0.75, green: 0.25, blue: 0.40),   // rose
    ]
    static func color(_ username: String) -> Color {
        guard !username.isEmpty else { return .secondary }
        let sum = username.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[sum % palette.count]
    }
}

/// Annotations that become conversations between an author and the people reading the book.
///
/// Each person writes only their own file, `.musset/talk/<user>/<chapter>.json`: a list of entries (a note on a passage,
/// a reply, resolved, reopened). The author's is on main; a reader's is on their `relecture/<user>` branch, and main keeps
/// a copy of what each review brought (their comments in the text and margin notes included, turned into entries). A thread
/// is rebuilt from everyone's entries by id and date, each entry counted once, so nothing ever conflicts.
struct TalkEntry: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case note, reply, resolve, reopen }
    /// How a note marks its passage on the page.
    enum Mark: String, Codable, CaseIterable { case highlight, underline, strike, margin }

    var id = UUID()
    /// The note this entry belongs to (its own id for a note).
    var thread: UUID
    var kind: Kind
    /// The Musset user name of whoever wrote it.
    var by: String
    var at = Date()
    var body: String = ""
    var chapter: String
    // A note only:
    var anchor: NoteAnchor?
    var mark: Mark?
    /// One of five reader colours (0–4), for a highlight.
    var color: Int?
    /// « Question », « Critique », « Strength »…: a `Note.Kind` raw value.
    var tone: String?
    /// The milestone it was written on, when read through one.
    var milestone: String?
}

/// The part of a book a reader was given: all of it, the chapters at some statuses (as they stood in the milestone
/// they read), or chapters the author chose one by one.
struct ReadingScope: Codable, Equatable {
    var statuses: [String]? = nil
    var chapters: [String]? = nil

    static func statuses(_ list: [ChapterStatus]) -> ReadingScope { ReadingScope(statuses: ChapterStatus.allCases.filter(list.contains).map(\.rawValue)) }
    static func chapters(_ ids: [String]) -> ReadingScope { ReadingScope(chapters: ids) }

    func allows(_ ch: ChapterEntry) -> Bool {
        if let chapters { return chapters.contains(ch.id) }
        if let statuses { return statuses.contains((ch.status ?? .draft).rawValue) }
        return true
    }

    /// As the server takes it.
    var body: [String: Any] { chapters.map { ["chapters": $0] } ?? ["statuses": statuses ?? []] }

    /// « Edited, Final », « 3 chapters »: what a list says of it.
    func label(pieces: (Int) -> String) -> String {
        if let chapters { return pieces(chapters.count) }
        return (statuses ?? []).compactMap { ChapterStatus(rawValue: $0)?.label }.joined(separator: ", ")
    }
}

extension Optional where Wrapped == ReadingScope {
    /// No scope is the whole book.
    func allows(_ ch: ChapterEntry) -> Bool { self?.allows(ch) ?? true }
}

/// One conversation, anchored to a passage.
struct TalkThread: Identifiable, Equatable {
    let id: UUID
    let chapter: String
    let note: TalkEntry
    var replies: [TalkEntry]
    /// Who resolved it last, if it is resolved.
    var resolvedBy: String?

    var isResolved: Bool { resolvedBy != nil }
    var starter: String { note.by }
    var last: TalkEntry { replies.last ?? note }
    var people: Set<String> { Set([note.by] + replies.map(\.by)) }
    /// It waits for `me` when someone else spoke last, in a thread `me` takes part in (an author takes part in all of them).
    func waits(for me: String, owner: String) -> Bool {
        !isResolved && last.by != me && (me == owner || people.contains(me))
    }
}

/// Reading and writing conversation files, and rebuilding threads: the same on Mac and iPhone.
enum Talk {
    static func path(_ user: String, _ chapter: String) -> String { ".musset/talk/\(user)/\(chapter).json" }
    static func decode(_ data: Data?) -> [TalkEntry] {
        guard let data, !data.isEmpty else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([TalkEntry].self, from: data)) ?? []
    }

    static func encode(_ entries: [TalkEntry]) -> Data {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(entries)) ?? Data("[]".utf8)
    }

    static func threads(from entries: [TalkEntry]) -> [TalkThread] {
        // An entry can arrive twice (a reader's file on their branch, and the copy a review brought to main): it counts once.
        var seen = Set<UUID>()
        let byThread = Dictionary(grouping: entries.filter { seen.insert($0.id).inserted }, by: \.thread)
        var out: [TalkThread] = []
        for (id, list) in byThread {
            let sorted = list.sorted { $0.at < $1.at }
            guard let note = sorted.first(where: { $0.kind == .note && $0.id == id }) else { continue }
            var resolvedBy: String?
            for e in sorted {
                if e.kind == .resolve { resolvedBy = e.by }
                if e.kind == .reopen { resolvedBy = nil }
            }
            out.append(TalkThread(id: id, chapter: note.chapter, note: note, replies: sorted.filter { $0.kind == .reply }, resolvedBy: resolvedBy))
        }
        return out.sorted { a, b in
            if a.chapter != b.chapter { return a.chapter < b.chapter }
            let pa = a.note.anchor?.start ?? 0, pb = b.note.anchor?.start ?? 0
            return pa != pb ? pa < pb : a.note.at < b.note.at
        }
    }

}
