import AppKit
import NaturalLanguage

/// Notices the names the author writes for the first time and gives each a light sheet in the Bible, so the cast
/// keeps itself. On the Mac, with the system's name recognition: nothing leaves the machine and nothing waits.
/// A word the author says is not a name never comes back (`.musset/names-ignored.json`).
@MainActor
@Observable
final class NameSpotter {
    struct Candidate: Hashable, Sendable {
        let name: String
        let kind: BibleKind
        /// Only ever seen at the start of a sentence, where every word has a capital.
        let sentenceStart: Bool
    }

    /// The last name that joined the Bible, for the editor's notice.
    struct Joined: Equatable {
        let path: String
        let title: String
        let kind: BibleKind
    }

    var joined: Joined?
    @ObservationIgnored weak var session: BookSession?
    @ObservationIgnored private var cache: [Int: [Candidate]] = [:]
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private(set) var ignored: Set<String> = []
    static let idleDelay: Duration = .seconds(2)

    init(session: BookSession?) {
        self.session = session
        if let root = session?.root { ignored = Self.loadIgnored(root) }
    }

    /// After a pause in the typing.
    func textChanged() {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: Self.idleDelay)
            guard !Task.isCancelled else { return }
            self?.spot()
        }
    }

    /// Looks at the open chapter's paragraphs that changed since the last look, and opens a sheet for each new name.
    func spot() {
        // The book's chapters only, in the manuscript: drafts and tracks don't make the cast.
        guard let session, session.piste == nil, let id = session.selectedChapterID, session.manifest.chapters.contains(where: { $0.id == id }) else { return }
        let lang = session.manifest.lang
        var found: [Candidate] = []
        for paragraph in session.text.components(separatedBy: "\n") where paragraph.contains(where: \.isLetter) {
            let key = paragraph.hashValue
            if let known = cache[key] { found += known; continue }
            let list = Self.candidates(in: paragraph, lang: lang)
            cache[key] = list
            found += list
        }
        for c in Self.merge(found) where isNew(c) {
            guard let entry = try? session.bible.create(title: c.name, kind: c.kind, meta: ["origin": "musset"]) else { continue }
            session.pendingCommit = true
            joined = Joined(path: entry.path, title: entry.title, kind: entry.kind)
        }
        if joined != nil { session.refreshBibleMentions() }
    }

    /// A name worth a sheet: not known by the Bible or the grid, not refused by the author, and not a common word that
    /// only got its capital from starting a sentence.
    func isNew(_ c: Candidate) -> Bool {
        guard let session else { return false }
        let f = Fold.name(c.name)
        if ignored.contains(f) || session.bible.entry(named: c.name) != nil { return false }
        if session.plot.tags.contains(where: { t in t.names.contains { Fold.name($0) == f } }) { return false }
        if c.sentenceStart, Self.isDictionaryWord(c.name.lowercased(), lang: session.manifest.lang) { return false }
        return true
    }

    /// « Not a name »: the sheet goes, and the word is never proposed again.
    func notAName(_ path: String) {
        guard let session, let entry = session.bible.entry(path: path) else { return }
        ignored.insert(Fold.name(entry.title))
        Self.saveIgnored(ignored, root: session.root)
        try? session.bible.trash(path)
        session.pendingCommit = true
        if joined?.path == path { joined = nil }
        session.refreshBibleMentions()
    }

    // MARK: Recognition

    /// People and places the system recognises in a paragraph. A name seen once mid-sentence is enough; one seen only
    /// at the start of sentences is marked so, for the dictionary to judge.
    nonisolated static func candidates(in paragraph: String, lang: String) -> [Candidate] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = paragraph
        tagger.setLanguage(NLLanguage(BookLanguage(code: lang).base), range: paragraph.startIndex..<paragraph.endIndex)
        var out: [Candidate] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(in: paragraph.startIndex..<paragraph.endIndex, unit: .word, scheme: .nameType, options: options) { tag, range in
            let kind: BibleKind? = switch tag {
            case .personalName: .character
            case .placeName: .place
            default: nil
            }
            let name = String(paragraph[range]).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if let kind, name.count > 1, name.first?.isUppercase == true {
                out.append(Candidate(name: name, kind: kind, sentenceStart: startsSentence(paragraph, at: range.lowerBound)))
            }
            return true
        }
        return out
    }

    /// The same name seen several times counts once; seen once mid-sentence, it is no longer « only at the start ».
    nonisolated static func merge(_ list: [Candidate]) -> [Candidate] {
        var byName: [String: Candidate] = [:]
        var order: [String] = []
        for c in list {
            if let prev = byName[c.name] {
                byName[c.name] = Candidate(name: c.name, kind: prev.kind, sentenceStart: prev.sentenceStart && c.sentenceStart)
            } else {
                byName[c.name] = c
                order.append(c.name)
            }
        }
        return order.compactMap { byName[$0] }
    }

    nonisolated static func startsSentence(_ text: String, at index: String.Index) -> Bool {
        var i = index
        while i > text.startIndex {
            i = text.index(before: i)
            let ch = text[i]
            if ch.isWhitespace || "«“\"‘'—–-(".contains(ch) { continue }
            return ".!?…:".contains(ch)
        }
        return true
    }

    static func isDictionaryWord(_ word: String, lang: String) -> Bool {
        let checker = NSSpellChecker.shared
        let language = BookLanguage(code: lang).base
        let miss = checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        return miss.location == NSNotFound
    }

    // MARK: The refused words

    static func ignoredURL(_ root: URL) -> URL { root.appendingPathComponent(".musset/names-ignored.json") }

    static func loadIgnored(_ root: URL) -> Set<String> {
        Set(JSONFile.read([String].self, at: ignoredURL(root)) ?? [])
    }

    static func saveIgnored(_ set: Set<String>, root: URL) {
        try? JSONFile.write(set.sorted(), to: ignoredURL(root), [.prettyPrinted, .sortedKeys])
    }
}
