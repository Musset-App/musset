import Foundation

/// Markdown chapters → one Typst document set with Musset's templates (`Resources/Typst/musset.typ`).
/// Musset's Markdown is a small, prose-only subset: headings, paragraphs, *italics*, **bold**, block quotes,
/// scene breaks, simple lists, links. Author's notes (HTML comments) never reach the page.
enum TypstMarkup {
    /// A chapter's Markdown as Typst markup. With `markers`, every paragraph starts with `#mk(chapter, offset)`
    /// so a position on the page can be mapped back to the text.
    static func chapter(_ md: String, id: String, markers: Bool, sceneBreak: SceneBreak = .none) -> String {
        let ns = Revisions.refusingMultiline(md) as NSString
        var out = ""
        var cursor = 0
        var quote: [(text: String, hardBreak: Bool)] = []
        var quoteOffset = 0
        var inComment = false
        var sawProse = false
        func marker(_ offset: Int) -> String { markers ? "#mk(\"\(escapeString(id))\", \(offset))" : "" }
        func flushQuote() {
            guard !quote.isEmpty else { return }
            sawProse = true
            let lines = quote.enumerated().map { i, q in inline(q.text) + (i == quote.count - 1 ? "" : q.hardBreak ? " \\\n" : " ") }
            out += "#quote(block: true)[\(marker(quoteOffset))\(lines.joined())]\n\n"
            quote = []
        }
        while cursor < ns.length {
            // Lines, not paragraphs: in the editor form a paragraph may hold U+2028 line breaks.
            let r = ns.lineRange(for: NSRange(location: cursor, length: 0))
            cursor = NSMaxRange(r)
            // Pending corrections are not printed: the line as it stood before them (line by line, so the
            // paragraph offsets used by reading mode still point into the editor's text).
            var text = Revisions.resolveAll(ns.substring(with: r), accept: false)
            // A scene marker: a break between scenes (never before the first one).
            let bare = text.trimmingCharacters(in: .newlines)
            if !inComment, Scenes.pattern.firstMatch(in: bare, range: NSRange(location: 0, length: (bare as NSString).length)) != nil {
                flushQuote()
                if sawProse {
                    switch sceneBreak {
                    case .none: break
                    case .blank: out += "#scenegap()\n\n"
                    case .asterism: out += "#asterism()\n\n"
                    }
                }
                continue
            }
            let breaksInside = text.hasSuffix("\u{2028}")
            // Strip author's notes, including ones spanning several lines.
            text = stripComments(text, inComment: &inComment)
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { flushQuote(); continue }
            if line.hasPrefix(">") {
                if quote.isEmpty { quoteOffset = r.location }
                let body = String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                let backslash = body.hasSuffix("\\")
                quote.append((backslash ? String(body.dropLast()) : body, breaksInside || backslash || text.hasSuffix("  \n")))
                continue
            }
            flushQuote()
            if line.hasPrefix("\\"), let block = latexBlock(line) {
                out += block
            } else if line.allSatisfy({ "*-_ ".contains($0) }) && line.filter({ !$0.isWhitespace }).count >= 3 {
                out += "#scenebreak()\n\n"
            } else if let h = heading(line) {
                sawProse = false
                out += String(repeating: "=", count: h.level) + " " + marker(r.location) + inline(h.text) + "\n\n"
            } else if let item = listItem(line) {
                out += item.marker + " " + inline(item.text) + "\n"
            } else {
                // Markdown hard line break: two trailing spaces or a backslash.
                sawProse = true
                let hard = breaksInside || text.hasSuffix("  \n") || line.hasSuffix("\\")
                let body = hard && line.hasSuffix("\\") ? String(line.dropLast()) : line
                out += marker(r.location) + inline(body) + (hard ? " \\\n" : "\n\n")
            }
        }
        flushQuote()
        return out
    }

    private static func stripComments(_ s: String, inComment: inout Bool) -> String {
        var out = ""
        var rest = Substring(s)
        while !rest.isEmpty {
            if inComment {
                guard let end = rest.range(of: "-->") else { return out }
                rest = rest[end.upperBound...]
                inComment = false
            } else if let start = rest.range(of: "<!--") {
                out += rest[..<start.lowerBound]
                rest = rest[start.upperBound...]
                inComment = true
            } else {
                out += rest
                break
            }
        }
        return out
    }

    // MARK: Raw LaTeX the books used with pandoc (exergues, dedications)

    /// A line that is a LaTeX layout command, as Typst. Nil when the line is ordinary text.
    static func latexBlock(_ line: String) -> String? {
        guard let m = line.firstMatch(of: /^\\([a-zA-Z]+)(\*?)(?:\{([^}]*)\})?\s*$/) else { return nil }
        let name = String(m.1), arg = m.3.map(String.init)
        switch name {
        case "begin":
            switch arg {
            case "center": return "#align(center)[\n"
            case "flushright": return "#align(right)[\n"
            case "flushleft": return "#align(left)[\n"
            case "quote", "quotation": return "#quote(block: true)[\n"
            default: return "#block[\n"
            }
        case "end": return "]\n\n"
        case "clearpage", "newpage", "cleardoublepage", "pagebreak": return "#pagebreak()\n\n"
        case "thispagestyle": return arg == "empty" ? "#nofolio()\n" : ""
        case "vspace", "vskip": return "#v(\(latexLength(arg ?? "1em")))\n"
        case "vfill": return "#v(1fr)\n"
        case "noindent", "centering", "raggedright", "raggedleft", "bigskip", "medskip", "smallskip":
            return name.hasSuffix("skip") ? "#v(\(name == "bigskip" ? "1em" : name == "medskip" ? "0.5em" : "0.25em"))\n" : ""
        default: return nil   // \emph{…} and friends are text: the inline conversion handles them
        }
    }

    /// "0.42\\textheight" → "42%", "0.75\\baselineskip" → "0.75em", "\\fill" → "1fr", "12mm" stays.
    static func latexLength(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t == "\\fill" || t == "\\vfill" { return "1fr" }
        let number = Double(t.prefix { $0.isNumber || $0 == "." }) ?? 1
        if t.hasSuffix("\\textheight") { return "\(Int((number * 100).rounded()))%" }
        if t.hasSuffix("\\baselineskip") { return "\(number)em" }
        if t.range(of: #"^[0-9.]+(mm|cm|pt|em|in)$"#, options: .regularExpression) != nil { return t }
        return "1em"
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
    }

    private static func listItem(_ line: String) -> (marker: String, text: String)? {
        // Bullets only: in prose, "1943. Barcelone." is a sentence, not a numbered list.
        for bullet in ["- ", "+ "] where line.hasPrefix(bullet) { return ("-", String(line.dropFirst(2))) }
        return nil
    }

    /// Inline Markdown → Typst: emphasis, strong, code, links; everything else escaped.
    static func inline(_ s: String) -> String {
        var result = inlineBody(s)
        // "1943. …" at the start of a line would be a Typst numbered list.
        if let r = result.range(of: #"^\d+\."#, options: .regularExpression) {
            result.replaceSubrange(result.index(before: r.upperBound)..<r.upperBound, with: "\\.")
        }
        return result
    }

    private static func inlineBody(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        var i = 0
        func find(_ token: String, from: Int) -> Int? {
            let t = Array(token)
            var j = from
            while j + t.count <= chars.count {
                if Array(chars[j..<(j + t.count)]) == t, j > from, !chars[j - 1].isWhitespace { return j }
                j += 1
            }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            let next = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "*" && next == "*", let end = find("**", from: i + 2), next.map({ !$0.isWhitespace }) == true {
                out += "#strong[" + inline(String(chars[(i + 2)..<end])) + "]"
                i = end + 2; continue
            }
            if c == "*" || (c == "_" && (i == 0 || !chars[i - 1].isLetter)), let n = next, !n.isWhitespace,
               let end = find(String(c), from: i + 1), c == "*" || end + 1 >= chars.count || !chars[end + 1].isLetter {
                out += "#emph[" + inline(String(chars[(i + 1)..<end])) + "]"
                i = end + 1; continue
            }
            if c == "`", let end = chars[(i + 1)...].firstIndex(of: "`") {
                out += "#raw(\"" + escapeString(String(chars[(i + 1)..<end])) + "\")"
                i = end + 1; continue
            }
            // ^[…]: a footnote (brackets may nest inside it).
            if c == "^", next == "[" {
                var depth = 0, j = i + 1, close: Int? = nil
                while j < chars.count {
                    if chars[j] == "[" { depth += 1 } else if chars[j] == "]" { depth -= 1; if depth == 0 { close = j; break } }
                    j += 1
                }
                if let close {
                    out += "#footnote[" + inline(String(chars[(i + 2)..<close])) + "]"
                    i = close + 1; continue
                }
            }
            if c == "[", let close = chars[(i + 1)...].firstIndex(of: "]"), close + 1 < chars.count, chars[close + 1] == "(",
               let paren = chars[(close + 2)...].firstIndex(of: ")") {
                let label = String(chars[(i + 1)..<close]), url = String(chars[(close + 2)..<paren])
                out += "#link(\"" + escapeString(url) + "\")[" + inline(label) + "]"
                i = paren + 1; continue
            }
            // \\emph{…}, \\textit{…}, \\textbf{…}, \\textsc{…}; other LaTeX commands are dropped.
            if c == "\\", let n = next, n.isLetter {
                var j = i + 1
                while j < chars.count, chars[j].isLetter { j += 1 }
                let name = String(chars[(i + 1)..<j])
                if j < chars.count, chars[j] == "{", let close = chars[j...].firstIndex(of: "}") {
                    let arg = inline(String(chars[(j + 1)..<close]))
                    switch name {
                    case "emph", "textit": out += "#emph[\(arg)]"
                    case "textbf": out += "#strong[\(arg)]"
                    case "textsc": out += "#smallcaps[\(arg)]"
                    default: out += arg
                    }
                    i = close + 1
                } else {
                    i = j
                }
                continue
            }
            out += escape(c, atStart: out.isEmpty, next: next)
            i += 1
        }
        return out
    }

    /// Escapes one character of prose for Typst markup.
    private static func escape(_ c: Character, atStart: Bool, next: Character?) -> String {
        switch c {
        case "\\", "#", "$", "@", "<", ">", "*", "_", "`", "[", "]", "~", "/": return "\\" + String(c)
        case "-" where next == "-" || (atStart && next == " "): return "\\-"
        case "=" where atStart: return "\\="
        case "+" where atStart: return "\\+"
        default: return String(c)
        }
    }

    static func escapeString(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// The whole document: template import, style call with the preset's parameters, chapters.
    static func document(title: String, author: String, contact: String?, lang: String, layout: TypstLayout,
                         chapters: [(id: String, text: String)], markers: Bool, sceneBreak: SceneBreak = .none,
                         front: String = "", back: String = "", parts: [String: (numeral: String, title: String)] = [:]) -> String {
        var s = "#import \"musset.typ\": *\n"
        let book = BookLanguage(code: lang)
        s += "#show: \(layout.style).with(title: \(str(title)), author: \(str(author)), contact: \(contact.map(str) ?? "none"), lang: \(str(book.base)), region: \(str(book.region)), crop: \(layout.crop)"
        if let m = layout.manuscript {
            s += ", \(m.args), running: \(str(m.running)), count: \(str(m.count)), numbered: \(layout.numbered))\n\n"
            for ch in chapters {
                if let p = parts[ch.id] { s += "#part-page(\(str(p.numeral)), \(str(p.title)))\n\n" }
                s += chapter(ch.text, id: ch.id, markers: markers, sceneBreak: sceneBreak) + "\n"
            }
            return s
        }
        if let p = layout.paper { s += ", paper: (\(p.w), \(p.h))" }
        if let m = layout.margins { s += ", margins: (" + m.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ") + ")" }
        if let size = layout.fontSize { s += ", size: \(size)" }
        if layout.style == "classique" { s += ", numbered: \(layout.numbered)" }
        if !layout.titlePage { s += ", title-page-on: false" }
        if !layout.facing { s += ", facing: false" }
        s += ")\n\n"
        s += front
        for ch in chapters {
            // A part's page before its first chapter: the numeral, and its title if it has one.
            if let p = parts[ch.id] { s += "#part-page(\(str(p.numeral)), \(str(p.title)))\n\n" }
            s += chapter(ch.text, id: ch.id, markers: markers, sceneBreak: sceneBreak) + "\n"
        }
        s += back
        return s
    }

    private static func str(_ s: String) -> String { "\"" + escapeString(s) + "\"" }

    // MARK: Special pages

    /// Typst for the book's special pages: what goes before the chapters (cover, dedication, epigraph, contents;
    /// the title page is the template's own) and after them (acknowledgements, colophon). `coverImage` is the file
    /// name the cover image will have beside main.typ.
    static func specialPages(_ m: BookManifest, coverImage: String?, contact: String? = nil) -> (front: String, back: String) {
        let f = m.front ?? FrontMatter()
        func lines(_ t: String) -> String {
            t.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines).map(inline).joined(separator: " \\\n")
        }
        var front = "", back = ""
        if f.has(.cover), let c = f.cover {
            let accent = c.style == "plain" ? "#1A1A18" : c.accent
            front += "#page(margin: 0pt, header: none, footer: none, fill: rgb(\(str(c.style == "plain" ? "#FFFFFF" : c.ground))))[\n#nofolio()\n"
            if c.style == "image", let img = coverImage {
                front += "#place(top + left, image(\(str(img)), width: 100%, height: 100%, fit: \"cover\"))\n"
            }
            if c.style == "typographic" {
                front += "#place(top + left, dx: 5%, dy: 3.5%, rect(width: 90%, height: 93%, stroke: 0.6pt + rgb(\(str(accent)))))\n"
                front += "#place(top + left, dx: 6.6%, dy: 4.6%, rect(width: 86.8%, height: 90.8%, stroke: 0.6pt + rgb(\(str(accent)))))\n"
            }
            front += "#align(center)[#v(16%)#text(size: 0.95em, tracking: 0.18em)[\(inline(m.author.uppercased()))]\n#v(11%)"
            front += "#text(size: 2.6em, fill: rgb(\(str(accent))))[\(inline(m.title))]"
            if !c.genre.isEmpty { front += "\n#v(0.8em)#text(style: \"italic\")[\(inline(c.genre))]" }
            front += "]\n"
            if !c.publisher.isEmpty {
                front += "#place(bottom + center, dy: -9%, text(size: 0.7em, tracking: 0.18em)[\(inline(c.publisher.uppercased()))])\n"
            }
            front += "]\n\n"
        }
        // The title page comes after the cover (callers turn the template's own title page off).
        if f.has(.title) {
            front += "#page(header: none, footer: none)[#nofolio()#v(30%)#align(center)[#text(size: 1.25em, smallcaps[\(inline(m.title))])"
            if let sub = m.subtitle, !sub.isEmpty { front += "\n#v(4mm)#emph[\(inline(sub))]" }
            front += "\n#v(18mm)\(inline(m.author))"
            if let contact, !contact.isEmpty { front += "\n#v(1fr)#text(size: 0.8em)[\(inline(contact))]" }
            front += "]]\n\n"
        }
        if f.has(.dedication), let d = f.dedication {
            front += "#page(header: none, footer: none)[#nofolio()#v(30%)#align(center)[#emph[\(lines(d))]]]\n\n"
        }
        if f.has(.epigraph), let e = f.epigraph {
            front += "#page(header: none, footer: none)[#nofolio()#v(26%)#align(right)[#block(width: 72%)[#set align(right)\n#emph[\(lines(e))]"
            if let src = f.epigraphSource, !src.isEmpty { front += " \\\n#v(0.5em)#text(size: 0.9em)[\(inline(src))]" }
            front += "]]]\n\n"
        }
        if f.has(.contents) {
            // Its own title, not a heading: a heading would start a new right-hand page.
            front += "#page(header: none, footer: none)[#nofolio()#align(center)[#text(size: 1.3em)[\(BookTerm.contents.in(m.lang))]]#v(2em)#outline(title: none, depth: 1)]\n\n"
        }
        if f.has(.acknowledgements), let a = f.acknowledgements {
            back += "#pagebreak()\n#align(center)[#text(size: 1.2em)[\(BookTerm.acknowledgements.in(m.lang))]]\n#v(2em)\n"
            back += a.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n\n").map { inline($0.replacingOccurrences(of: "\n", with: " ")) }.joined(separator: "\n\n") + "\n\n"
        }
        if f.has(.colophon) {
            let year = Calendar.current.component(.year, from: Date())
            let text = BookTerm.colophon.in(m.lang).replacingOccurrences(of: "{year}", with: "\(year)").replacingOccurrences(of: "\n", with: " \\\n")
            back += "#page(header: none, footer: none)[#nofolio()#v(1fr)#align(center)[#text(size: 0.8em)[\(text)]]#v(3em)]\n"
        }
        return (front, back)
    }
}

/// Page parameters for a Typst run, usually derived from an export preset.
struct TypstLayout: Equatable {
    var style = "blanche"
    var paper: (w: String, h: String)?
    var margins: [String: String]?
    var fontSize: String?
    var crop = false
    var numbered = true
    var titlePage = true
    /// Facing pages (inside and outside margins, parts on a recto) or single pages (equal side margins).
    var facing = true
    /// A submission manuscript: its norm's arguments, running head and count.
    var manuscript: (args: String, running: String, count: String)?

    static func == (a: TypstLayout, b: TypstLayout) -> Bool {
        a.style == b.style && a.paper?.w == b.paper?.w && a.paper?.h == b.paper?.h && a.margins == b.margins
            && a.fontSize == b.fontSize && a.crop == b.crop && a.numbered == b.numbered && a.titlePage == b.titlePage && a.facing == b.facing
            && a.manuscript?.args == b.manuscript?.args && a.manuscript?.running == b.manuscript?.running && a.manuscript?.count == b.manuscript?.count
    }

    /// Reads a LaTeX geometry string ("paperwidth=148mm,inner=20mm,…") so existing presets keep their page.
    init(style: String, geometry: String?, fontSize: String?, crop: Bool, numbered: Bool, titlePage: Bool = true) {
        self.style = style
        self.fontSize = fontSize
        self.crop = crop
        self.numbered = numbered
        self.titlePage = titlePage
        guard let g = geometry else { return }
        var kv: [String: String] = [:]
        for part in g.split(separator: ",") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { kv[pair[0]] = pair[1] }
        }
        if let w = kv["paperwidth"], let h = kv["paperheight"] { paper = (w, h) }
        var m: [String: String] = [:]
        for (latex, typst) in [("inner", "inside"), ("outer", "outside"), ("left", "left"), ("right", "right"), ("top", "top"), ("bottom", "bottom")] {
            if let v = kv[latex] { m[typst] = v }
        }
        if !m.isEmpty { margins = m }
    }

    init(style: String) { self.style = style }
}

/// Runs the typst binary (bundled in the app, else from PATH).
enum TypstRunner {
    struct Marker: Decodable, Equatable {
        let ch: String
        let off: Int
        let page: Int
        let y: Double
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var binary: String? { Shell.bundledOrPath("typst") }

    static var templateURL: URL? { Bundle.main.url(forResource: "musset", withExtension: "typ") }

    /// Writes main.typ and the template into `dir` (the book's own templates/musset.typ wins).
    static func prepare(dir: URL, source: String, bookRoot: URL) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let custom = bookRoot.appendingPathComponent("templates/musset.typ")
        let template = FileManager.default.fileExists(atPath: custom.path) ? custom : templateURL
        guard let template else { throw Failure(message: L("Musset's Typst template is missing from the app.")) }
        let dest = dir.appendingPathComponent("musset.typ")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: template, to: dest)
        let main = dir.appendingPathComponent("main.typ")
        try source.write(to: main, atomically: true, encoding: .utf8)
        return main
    }

    private static func fontArgs(_ bookRoot: URL) -> [String] {
        var args: [String] = []
        // The app's own fonts (Iosevka, Plex Mono for a monospaced manuscript), the author's, the book's.
        let bundled = Bundle.main.resourceURL.map { [$0] } ?? []
        for dir in bundled + [URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Fonts"), bookRoot.appendingPathComponent("fonts")]
            where FileManager.default.fileExists(atPath: dir.path) {
            args += ["--font-path", dir.path]
        }
        return args
    }

    static func compile(main: URL, output: URL, bookRoot: URL) async throws {
        guard let typst = binary else { throw Failure(message: L("Typst is not installed (brew install typst).")) }
        let r = try await Shell.runAsync(typst, ["compile"] + fontArgs(bookRoot) + [main.path, output.path], cwd: main.deletingLastPathComponent())
        guard r.status == 0 else { throw Failure(message: "Typst: " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Where each paragraph landed: page and vertical position (pt from the top of the page).
    static func markers(main: URL, bookRoot: URL) async throws -> [Marker] {
        guard let typst = binary else { throw Failure(message: L("Typst is not installed (brew install typst).")) }
        let r = try await Shell.runAsync(typst, ["query"] + fontArgs(bookRoot) + [main.path, "<musset>", "--field", "value", "--format", "json"],
                                         cwd: main.deletingLastPathComponent())
        guard r.status == 0 else { throw Failure(message: "Typst: " + r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return try JSONDecoder().decode([Marker].self, from: Data(r.stdout.utf8))
    }
}
