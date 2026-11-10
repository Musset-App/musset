import Foundation

/// The notes of a chapter as a Markdown file anyone can read, without Musset:
///
///     - [ ] Vérifier la date du procès #à-vérifier
///       > Je me suis réveillé vers quatorze heures
///       <!-- musset {"id":"…","p":"…","s":"…"} -->
///     - [x] Développer Clara
///     - [-] Résolue sans être faite @claude
///
///     Du texte libre reste du texte libre.
///
/// `- [ ]` open, `- [x]` done, `- [-]` resolved without being done. What can't be read in clear
/// (where the passage was, dates) sits in one comment. Lines written by hand work as they are.
enum NoteMarkdown {
    private struct Meta: Codable {
        var id: UUID?
        var c: Date?
        var u: Date?
        var p: String?
        var s: String?
        var at: Int?
        var v: String?
        var o: Bool?
        var r: String?
        var src: String? = nil
    }

    private static let tags: [(Note.Kind, String)] = [
        (.todo, "à-faire"), (.note, "note"), (.question, "question"), (.critique, "critique"), (.fact, "à-vérifier"),
        (.continuity, "continuité"), (.praise, "réussite"), (.tic, "tic"), (.cut, "coupe"), (.repetition, "redite"),
    ]

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
    private static let iso = ISO8601DateFormatter()

    // MARK: Writing

    static func encode(_ notes: [Note]) -> String {
        var out: [String] = []
        for (i, n) in notes.enumerated() {
            if n.kind == .text {
                if i > 0, out.last != "" { out.append("") }
                out += n.body.components(separatedBy: "\n").filter { !$0.isEmpty }
                out.append("")
                continue
            }
            out += lines(of: n)
        }
        while out.last == "" { out.removeLast() }
        return out.isEmpty ? "" : out.joined(separator: "\n") + "\n"
    }

    private static func lines(of n: Note) -> [String] {
        let box = n.status == .done ? "[x]" : (n.status == .resolved ? "[-]" : "[ ]")
        let body = n.body.components(separatedBy: "\n")
        var first = "- \(box) \(body[0])"
        let lastWord = body[0].split(separator: " ").last.map(String.init) ?? ""
        if n.kind != .todo || lastWord.hasPrefix("#") || lastWord.hasPrefix("@") {
            first += " #" + (tags.first { $0.0 == n.kind }?.1 ?? "note")
        }
        if n.author != .me { first += " @" + n.author.rawValue }
        var out = [first]
        for line in body.dropFirst() { out.append("  " + escaped(line)) }
        for q in n.anchor.quote.isEmpty ? [] : n.anchor.quote.components(separatedBy: "\n") { out.append("  > " + q) }
        if needsMeta(n) {
            let a = n.anchor
            let meta = Meta(id: n.id, c: n.created, u: n.updated, p: a.prefix.isEmpty ? nil : a.prefix, s: a.suffix.isEmpty ? nil : a.suffix,
                            at: a.quote.isEmpty ? nil : a.start, v: a.version, o: n.orphaned ? true : nil, r: n.run, src: n.source)
            if let data = try? encoder.encode(meta) {
                // « -- » would close the comment.
                let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "--", with: "-\\u002d")
                out.append("  <!-- musset \(json) -->")
            }
        }
        for r in n.replies {
            out.append("  * @\(r.author == .me ? "moi" : r.author.rawValue) · \(iso.string(from: r.created)) · \(r.id.uuidString)")
            out += r.body.components(separatedBy: "\n").map { "    " + $0 }
        }
        return out
    }

    /// A plain task of the author's keeps to its line.
    private static func needsMeta(_ n: Note) -> Bool {
        !n.anchor.quote.isEmpty || !n.replies.isEmpty || n.author != .me || n.run != nil || n.orphaned || n.source != nil || n.body.contains("\n")
    }

    private static func escaped(_ line: String) -> String {
        [">", "<!--", "* @", "\\"].contains(where: line.hasPrefix) ? "\\" + line : line
    }

    // MARK: Reading

    static func decode(_ text: String) -> [Note] {
        var out: [Note] = []
        var current: Note?
        var reply: Note.Reply?
        var replyStarted = false
        var paragraph: [String] = []
        var quote: [String] = []
        var meta: Meta?
        var seen: [String: Int] = [:]

        func stableID(_ s: String) -> UUID {
            let n = seen[s, default: 0]
            seen[s] = n + 1
            return hashedID(s + (n == 0 ? "" : "#\(n)"))
        }
        func flushReply() {
            if let r = reply { current?.replies.append(r); reply = nil }
        }
        func flushNote() {
            flushReply()
            guard var n = current else { return }
            n.anchor.quote = quote.joined(separator: "\n")
            if let m = meta {
                n.id = m.id ?? stableID(n.body)
                n.created = m.c ?? n.created
                n.updated = m.u ?? n.updated
                n.anchor.prefix = m.p ?? ""
                n.anchor.suffix = m.s ?? ""
                n.anchor.start = m.at ?? 0
                n.anchor.version = m.v
                n.orphaned = m.o ?? false
                n.run = m.r
                n.source = m.src
            } else {
                n.id = stableID(n.body)
            }
            out.append(n)
            current = nil; quote = []; meta = nil
        }
        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let body = paragraph.joined(separator: "\n")
            paragraph = []
            out.append(Note(id: stableID(body), author: .me, kind: .text, body: body, created: .distantPast, updated: .distantPast, anchor: empty))
        }

        for line in text.components(separatedBy: "\n") {
            if let (status, rest) = box(line) {
                flushNote(); flushParagraph()
                let parsed = titleLine(rest)
                current = Note(author: parsed.author, kind: parsed.kind, body: parsed.body, status: status, created: .distantPast, updated: .distantPast, anchor: empty)
                continue
            }
            if current != nil, line.hasPrefix("  ") || line.isEmpty {
                if line.isEmpty { flushNote(); continue }
                if reply != nil, line.hasPrefix("    ") {
                    let piece = String(line.dropFirst(4))
                    reply?.body += replyStarted ? "\n" + piece : piece
                    replyStarted = true
                    continue
                }
                let rest = String(line.dropFirst(2))
                if rest.hasPrefix("* @"), let r = parseReply(rest) {
                    flushReply()
                    reply = r
                    replyStarted = false
                } else if rest.hasPrefix("> ") || rest == ">" {
                    quote.append(String(rest.dropFirst(2)))
                } else if rest.hasPrefix("<!-- musset "), rest.hasSuffix(" -->") {
                    let json = rest.dropFirst(12).dropLast(4)
                    meta = try? decoder.decode(Meta.self, from: Data(json.utf8))
                } else {
                    current?.body += "\n" + (rest.hasPrefix("\\") ? String(rest.dropFirst()) : rest)
                }
                continue
            }
            flushNote()
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushParagraph() } else { paragraph.append(line) }
        }
        flushNote(); flushParagraph()
        return out
    }

    private static let empty = NoteAnchor(quote: "", prefix: "", suffix: "", start: 0, version: nil)

    private static func box(_ line: String) -> (Note.Status, String)? {
        for (prefix, status) in [("- [ ] ", Note.Status.open), ("- [x] ", .done), ("- [X] ", .done), ("- [-] ", .resolved)] where line.hasPrefix(prefix) {
            return (status, String(line.dropFirst(prefix.count)))
        }
        for (prefix, status) in [("- [ ]", Note.Status.open), ("- [x]", .done), ("- [X]", .done), ("- [-]", .resolved)] where line == prefix {
            return (status, "")
        }
        return nil
    }

    private static func titleLine(_ raw: String) -> (body: String, kind: Note.Kind, author: Note.Author) {
        var words = raw.components(separatedBy: " ")
        var author = Note.Author.me, kind = Note.Kind.todo
        if let last = words.last, last.hasPrefix("@"), let a = Note.Author(rawValue: String(last.dropFirst())), a != .me {
            author = a
            words.removeLast()
        }
        if let last = words.last, last.hasPrefix("#"), let k = tags.first(where: { $0.1 == last.dropFirst() })?.0 {
            kind = k
            words.removeLast()
        }
        return (words.joined(separator: " "), kind, author)
    }

    private static func parseReply(_ line: String) -> Note.Reply? {
        let parts = line.dropFirst(3).components(separatedBy: " · ")
        guard parts.count == 3, let date = iso.date(from: parts[1]), let id = UUID(uuidString: parts[2]) else { return nil }
        let author: Note.Author = parts[0] == "moi" ? .me : (Note.Author(rawValue: parts[0]) ?? .me)
        return Note.Reply(id: id, author: author, body: "", created: date)
    }

    /// The same text gives the same id: a line written by hand can be merged like any other.
    static func hashedID(_ s: String) -> UUID {
        func fnv(_ seed: UInt64) -> UInt64 { s.utf8.reduce(seed) { ($0 ^ UInt64($1)) &* 0x100000001b3 } }
        let a = fnv(0xcbf29ce484222325), b = fnv(0x84222325cbf29ce4)
        func bytes(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) } }
        let all = bytes(a) + bytes(b)
        return UUID(uuid: (all[0], all[1], all[2], all[3], all[4], all[5], all[6], all[7], all[8], all[9], all[10], all[11], all[12], all[13], all[14], all[15]))
    }
}
