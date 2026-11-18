import AppKit

/// Soft, iA-like Markdown styling: markup is dimmed in the paragraph being written, folded away elsewhere.
struct EditorTheme {
    var fontName: String
    var fontSize: CGFloat
    var lineHeight: CGFloat = 1.78
    /// Space between paragraphs, as a fraction of a line ("Aéré": half a line). One line per paragraph in the editor.
    var paragraphGap: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "paragraphSpacing") as? Double ?? 0.73)
    /// The lists the book recognises (`BookManifest.listOptions`): their items hang, their markers are dimmed.
    var lists = ListOptions()

    var bodyFont: NSFont {
        if let f = NSFont(name: fontName, size: fontSize) { return f }
        return .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    var ink: NSColor { .textColor }
    var faint: NSColor { NSColor.textColor.withAlphaComponent(0.32) }
    var dimmed: NSColor { NSColor.textColor.withAlphaComponent(0.22) }
    var accent: NSColor { NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil ? NSColor(srgbRed: 0.45, green: 0.72, blue: 0.95, alpha: 1) : NSColor(srgbRed: 0.10, green: 0.42, blue: 0.75, alpha: 1) } }

    var paragraphStyle: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineHeight
        p.paragraphSpacing = fontSize * lineHeight * paragraphGap
        return p
    }

    /// Titles: more room above, a little less below.
    func headingStyle(_ size: CGFloat) -> NSParagraphStyle {
        let p = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        p.paragraphSpacingBefore = fontSize * lineHeight * max(1, paragraphGap * 2)
        p.paragraphSpacing = fontSize * lineHeight * max(0.4, paragraphGap)
        return p
    }

    /// Scene breaks (* * *): centred, with air around them.
    var ruleStyle: NSParagraphStyle {
        let p = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        p.alignment = .center
        p.paragraphSpacingBefore = fontSize * lineHeight * paragraphGap
        p.paragraphSpacing = fontSize * lineHeight * max(paragraphGap, 0.5)
        return p
    }

    /// Scene markers: a centred label between two hairlines, with room above.
    var sceneStyle: NSParagraphStyle {
        let p = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        p.alignment = .center
        p.paragraphSpacingBefore = fontSize * lineHeight * max(1, paragraphGap * 2)
        p.paragraphSpacing = fontSize * lineHeight * max(paragraphGap, 0.6)
        return p
    }

    var typingAttributes: [NSAttributedString.Key: Any] { EditorFaces.of(self).typing }
}

/// A theme's fonts, paragraph styles and colours, built once: the styler asks for them at every match, and a
/// chapter restyled with the same objects compares equal attribute for attribute.
final class EditorFaces {
    let body: NSFont
    let bold: NSFont
    let italic: NSFont
    /// The face has no italic (Inconsolata, for one): a slight slant stands in for it.
    let slanted: Bool
    let paragraph: NSParagraphStyle
    let rule: NSParagraphStyle
    let scene: NSParagraphStyle
    /// Titles by level: 1, 2, 3 and below.
    let headings: [(font: NSFont, style: NSParagraphStyle)]
    let comment: NSFont
    let footnote: NSFont
    let sceneSyntax: NSFont
    let sceneTitle: NSFont
    /// Folded markup: there, and too small to see.
    let hidden = NSFont.systemFont(ofSize: 0.01)
    let folded = NSFont.systemFont(ofSize: 0.5)
    let ink: NSColor
    let faint: NSColor
    let dimmed: NSColor
    let secondary = NSColor.secondaryLabelColor
    let added = NSColor(srgbRed: 0.18, green: 0.54, blue: 0.34, alpha: 1)
    let addedLine: NSColor
    let removed = NSColor(srgbRed: 0.76, green: 0.22, blue: 0.18, alpha: 1)
    let highlight = NSColor.systemYellow.withAlphaComponent(0.28)
    let typing: [NSAttributedString.Key: Any]

    init(_ theme: EditorTheme) {
        let fm = NSFontManager.shared
        let body = theme.bodyFont
        self.body = body
        bold = fm.convert(body, toHaveTrait: .boldFontMask)
        italic = fm.convert(body, toHaveTrait: .italicFontMask)
        slanted = !fm.traits(of: italic).contains(.italicFontMask)
        paragraph = theme.paragraphStyle
        rule = theme.ruleStyle
        scene = theme.sceneStyle
        headings = [1.45, 1.2, 1.05].map { (scale: CGFloat) in
            let f = fm.convert(NSFont(descriptor: body.fontDescriptor, size: body.pointSize * scale) ?? body, toHaveTrait: .boldFontMask)
            return (f, theme.headingStyle(f.pointSize))
        }
        comment = NSFont.monospacedSystemFont(ofSize: body.pointSize * 0.72, weight: .regular)
        footnote = NSFont(descriptor: body.fontDescriptor, size: body.pointSize * 0.82) ?? body
        sceneSyntax = Typefaces.nsUI(body.pointSize * 0.72)
        sceneTitle = Self.sceneTitleFont(body.pointSize)
        ink = theme.ink
        faint = theme.faint
        dimmed = theme.dimmed
        addedLine = added.withAlphaComponent(0.6)
        typing = [.font: body, .foregroundColor: ink, .paragraphStyle: paragraph]
    }

    /// Scene titles in small capitals, like a running head.
    private static func sceneTitleFont(_ size: CGFloat) -> NSFont {
        // The system face has true small capitals (Inter has none); the design draws these titles in caps.
        let base = NSFont.systemFont(ofSize: size * 0.7, weight: .medium)
        let features: [[NSFontDescriptor.FeatureKey: Int]] = [
            [.typeIdentifier: kLowerCaseType, .selectorIdentifier: kLowerCaseSmallCapsSelector],
            [.typeIdentifier: kUpperCaseType, .selectorIdentifier: kUpperCaseSmallCapsSelector],
        ]
        return NSFont(descriptor: base.fontDescriptor.addingAttributes([.featureSettings: features]), size: size * 0.7) ?? base
    }

    private var listStyles: [String: NSParagraphStyle] = [:]

    /// A list item's paragraph: its lines hang under its text, a nested one starts further in. `prefix`: the
    /// line up to the text (white space, marker, space), whose width is the hang; `lead`: the white space in it.
    func listStyle(prefix: String, lead: Int, level: Int) -> NSParagraphStyle {
        let key = "\(level)|\(prefix)"
        if let kept = listStyles[key] { return kept }
        func width(_ s: String) -> CGFloat { ceil((s as NSString).size(withAttributes: [.font: body]).width * 2) / 2 }
        let p = paragraph.mutableCopy() as! NSMutableParagraphStyle
        // The white space typed before the marker already moves it: the level's indent makes up the rest.
        let first = max(0, CGFloat(level) * body.pointSize * 1.5 - width(String(prefix.prefix(lead))))
        p.firstLineHeadIndent = first
        p.headIndent = first + width(prefix)
        listStyles[key] = p
        return p
    }

    private static var last: (key: [String], faces: EditorFaces)?

    /// The faces of a theme, kept until the theme changes (main thread: the editors).
    static func of(_ theme: EditorTheme) -> EditorFaces {
        let key = [theme.fontName, "\(theme.fontSize)", "\(theme.lineHeight)", "\(theme.paragraphGap)"]
        if let last, last.key == key { return last.faces }
        let faces = EditorFaces(theme)
        last = (key, faces)
        return faces
    }
}

enum MarkdownStyler {
    private static let heading = try! NSRegularExpression(pattern: #"^(#{1,6})[ \t]+(.*)$"#, options: [.anchorsMatchLines])
    private static let emphasis = try! NSRegularExpression(pattern: #"(?<![\*_\w])([\*_])(?!\s)(.+?)(?<!\s)\1(?![\*_\w])"#)
    private static let strong = try! NSRegularExpression(pattern: #"(\*\*|__)(?!\s)(.+?)(?<!\s)\1"#)
    private static let comment = try! NSRegularExpression(pattern: #"<!--.*?-->"#, options: [.dotMatchesLineSeparators])
    private static let quote = try! NSRegularExpression(pattern: #"^>.*$"#, options: [.anchorsMatchLines])
    /// ^[…] inline footnotes.
    private static let footnote = try! NSRegularExpression(pattern: #"\^\[[^\]\n]*\]"#)
    private static let rule = try! NSRegularExpression(pattern: #"^(\* \* \*|\*\*\*|---|___)\s*$"#, options: [.anchorsMatchLines])
    private static let ink = try! NSRegularExpression(pattern: #"\S"#)
    /// A line written as a list item (`ListLines.candidate` says whether it is one).
    private static let listLine = try! NSRegularExpression(pattern: #"^[ \t]*(?:[-+*]|\d{1,3}[.)])[ \t]"#, options: [.anchorsMatchLines])

    /// Restyles the whole storage: on load, on a change of theme, and whenever a paragraph alone can't be trusted.
    /// `marks`: the corrections in the text, when the caller has them already.
    static func style(_ storage: NSTextStorage, theme: EditorTheme, caret: Int? = nil, marks: [Revisions.Mark]? = nil) {
        let s = storage.string
        storage.beginEditing()
        apply(storage, s, EditorFaces.of(theme), caret: caret, in: NSRange(location: 0, length: storage.length), marks: marks ?? Revisions.marks(in: s), lists: theme.lists)
        storage.endEditing()
    }

    /// Restyles some paragraphs only, as the whole pass would have left them. `ranges` come from `reach`, and the
    /// caller has checked with `spans` that nothing running over several paragraphs touches them.
    static func style(_ storage: NSTextStorage, theme: EditorTheme, caret: Int?, in ranges: [NSRange]) {
        let s = storage.string
        let faces = EditorFaces.of(theme)
        storage.beginEditing()
        for r in ranges where r.length > 0 { apply(storage, s, faces, caret: caret, in: r, marks: Revisions.marks(in: s, range: r), lists: theme.lists) }
        storage.endEditing()
    }

    /// What is styled across paragraphs: author's notes and corrections that hold a paragraph break. A paragraph
    /// they touch can't be restyled alone.
    static func spans(in s: String, marks: [Revisions.Mark]) -> [NSRange] {
        let ns = s as NSString
        let breaks = CharacterSet.newlines
        func crosses(_ r: NSRange) -> Bool { ns.rangeOfCharacter(from: breaks, options: [], range: r).location != NSNotFound }
        var out = marks.map(\.range).filter(crosses)
        guard ns.range(of: "<!--").location != NSNotFound else { return out }
        comment.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            if let m, crosses(m.range) { out.append(m.range) }
        }
        return out
    }

    /// The paragraphs to restyle for `range` to come out as in a whole pass: its own, and the blank ones around
    /// that a scene break (`* * *`) above takes into its spacing. Nil when only a whole pass will do (a paragraph
    /// separator other than a new line, which a footnote may run over). In a book with numbered lists (`lists`),
    /// the list lines below too: whether « 2. » is an item depends on the line above it.
    static func reach(of range: NSRange, in ns: NSString, lists: ListOptions = .none) -> NSRange? {
        guard ns.length > 0 else { return NSRange(location: 0, length: 0) }
        let lo = min(max(0, range.location), ns.length)
        let hi = min(max(lo, NSMaxRange(range)), ns.length)
        var r = ns.paragraphRange(for: NSRange(location: lo, length: hi - lo))
        func blank(_ p: NSRange) -> Bool { ink.firstMatch(in: ns as String, range: p) == nil }
        // Blank paragraphs below belong to a break above them, or stop belonging to it.
        while NSMaxRange(r) < ns.length {
            let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(r), length: 0))
            guard blank(next) else { break }
            r = NSUnionRange(r, next)
        }
        if lists.numbered {
            while NSMaxRange(r) < ns.length {
                let next = ns.paragraphRange(for: NSRange(location: NSMaxRange(r), length: 0))
                guard blank(next) || ListLines.candidate(ns, at: next.location) != nil else { break }
                r = NSUnionRange(r, next)
            }
        }
        // A blank paragraph is styled by the break above it, if there is one: up to it.
        if blank(ns.paragraphRange(for: NSRange(location: r.location, length: 0))) {
            while r.location > 0 {
                let before = ns.paragraphRange(for: NSRange(location: r.location - 1, length: 0))
                r = NSUnionRange(before, r)
                if !blank(before) { break }
            }
        }
        let odd = CharacterSet(charactersIn: "\r\u{2029}")
        if ns.rangeOfCharacter(from: odd, options: [], range: r).location != NSNotFound { return nil }
        if r.location > 0, ns.character(at: r.location - 1) != 10 { return nil }
        return r
    }

    /// One pass over `range` (the whole text, or whole paragraphs of it). Matching looks past the range's ends, so
    /// a paragraph styled alone comes out as it does in a whole pass.
    private static func apply(_ storage: NSTextStorage, _ s: String, _ faces: EditorFaces, caret: Int?, in range: NSRange, marks: [Revisions.Mark],
                              lists: ListOptions) {
        let around: NSRegularExpression.MatchingOptions = [.withTransparentBounds, .withoutAnchoringBounds]
        storage.setAttributes(faces.typing, range: range)
        let caretParagraph = caret.map { paragraphRange(in: s as NSString, at: $0) }

        heading.enumerateMatches(in: s, options: around, range: range) { m, _, _ in
            guard let m else { return }
            let level = m.range(at: 1).length
            let h = faces.headings[min(level, 3) - 1]
            storage.addAttribute(.font, value: h.font, range: m.range)
            storage.addAttribute(.foregroundColor, value: faces.faint, range: m.range(at: 1))
            storage.addAttribute(.paragraphStyle, value: h.style, range: m.range)
        }
        // List items: the marker faint, the lines hanging under the text. Only the lines written as items are looked at.
        if lists.any {
            let ns = s as NSString
            var known: Int?, hung: NSRange?
            listLine.enumerateMatches(in: s, options: around, range: range) { m, _, _ in
                guard let m, let item = ListLines.item(ns, at: m.range.location, lists, known: known) else { return }
                known = item.line
                storage.addAttribute(.foregroundColor, value: faces.faint, range: item.marker)
                let paragraph = ns.paragraphRange(for: NSRange(location: item.line, length: 0))
                if paragraph.location == item.line {
                    let prefix = ns.substring(with: NSRange(location: item.line, length: item.text - item.line))
                    storage.addAttribute(.paragraphStyle, value: faces.listStyle(prefix: prefix, lead: item.indent, level: item.level), range: paragraph)
                    hung = paragraph
                } else if hung == paragraph {
                    // Several items in one paragraph (a list written on consecutive lines, outside Musset): their
                    // lines cannot each hang, so none does.
                    storage.addAttribute(.paragraphStyle, value: faces.paragraph, range: paragraph)
                    hung = nil
                }
            }
        }
        strong.enumerateMatches(in: s, options: around, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.font, value: faces.bold, range: m.range(at: 2))
            dimMarkers(storage, m, faces, caretParagraph)
        }
        emphasis.enumerateMatches(in: s, options: around, range: range) { m, _, _ in
            guard let m else { return }
            italicize(storage, m.range(at: 2), faces)
            dimMarkers(storage, m, faces, caretParagraph)
        }
        quote.enumerateMatches(in: s, options: around, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: faces.secondary, range: m.range)
            italicize(storage, m.range, faces)
        }
        rule.enumerateMatches(in: s, options: around, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: faces.faint, range: m.range)
            storage.addAttribute(.paragraphStyle, value: faces.rule, range: m.range)
        }
        // Author's notes (HTML comments): small, faint, monospaced.
        comment.enumerateMatches(in: s, options: around, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: faces.faint, range: m.range)
            storage.addAttribute(.font, value: faces.comment, range: m.range)
        }

        // Corrections (CriticMarkup): added in green, deleted struck through in red, highlights in yellow.
        // The syntax and the comment bodies are never shown (comments are bubbles, drawn by the editor).
        for m in marks {
            func added(_ r: NSRange) {
                storage.addAttribute(.foregroundColor, value: faces.added, range: r)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                storage.addAttribute(.underlineColor, value: faces.addedLine, range: r)
            }
            func removed(_ r: NSRange) {
                storage.addAttribute(.foregroundColor, value: faces.removed, range: r)
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            }
            switch m.kind {
            case .insertion: added(m.first)
            case .deletion: removed(m.first)
            case .substitution:
                removed(m.first)
                if let b = m.second { added(b) }
                // A little air between the old words and the new ones (drawn, not typed).
                if m.first.length > 0 { storage.addAttribute(.kern, value: faces.body.pointSize * 0.4, range: NSRange(location: NSMaxRange(m.first) - 1, length: 1)) }
            case .highlight: storage.addAttribute(.backgroundColor, value: faces.highlight, range: m.first)
            case .comment: break
            }
        }
        for r in Revisions.hidden(of: marks) {
            storage.addAttribute(.font, value: faces.hidden, range: r)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
            storage.removeAttribute(.underlineStyle, range: r)
            storage.removeAttribute(.strikethroughStyle, range: r)
            storage.removeAttribute(.backgroundColor, range: r)
        }

        // Footnotes: smaller and grey, the ^[ ] markers faint.
        footnote.enumerateMatches(in: s, options: around, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.font, value: faces.footnote, range: m.range)
            storage.addAttribute(.foregroundColor, value: faces.secondary, range: m.range)
            storage.addAttribute(.foregroundColor, value: faces.faint, range: NSRange(location: m.range.location, length: 2))
            storage.addAttribute(.foregroundColor, value: faces.faint, range: NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }

        // Scene markers: the title stands out a little, the comment syntax stays faint.
        Scenes.pattern.enumerateMatches(in: s, options: around, range: range) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.paragraphStyle, value: faces.scene, range: m.range)
            storage.addAttribute(.font, value: faces.sceneSyntax, range: m.range)
            storage.addAttribute(.foregroundColor, value: faces.dimmed, range: m.range)
            storage.addAttribute(.font, value: faces.sceneTitle, range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: faces.secondary, range: m.range(at: 1))
            storage.addAttribute(.kern, value: faces.body.pointSize * 0.08, range: m.range(at: 1))
            // Away from the caret only the title shows; the comment syntax folds to nothing.
            if let caret, !(m.range.location...NSMaxRange(m.range)).contains(caret) {
                let title = m.range(at: 1)
                for r in [NSRange(location: m.range.location, length: title.location - m.range.location),
                          NSRange(location: NSMaxRange(title), length: NSMaxRange(m.range) - NSMaxRange(title))] where r.length > 0 {
                    storage.addAttribute(.font, value: faces.folded, range: r)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                }
            }
        }
    }

    /// Italic face when the font has one; otherwise a slight slant (Inconsolata, for one, has no italic).
    private static func italicize(_ storage: NSTextStorage, _ range: NSRange, _ faces: EditorFaces) {
        storage.addAttribute(.font, value: faces.italic, range: range)
        if faces.slanted { storage.addAttribute(.obliqueness, value: 0.18, range: range) }
    }

    /// The * and ** around emphasis: faint in the paragraph with the caret, folded to nothing elsewhere.
    private static func dimMarkers(_ storage: NSTextStorage, _ m: NSTextCheckingResult, _ faces: EditorFaces, _ caretParagraph: NSRange?) {
        let open = m.range(at: 1)
        let close = NSRange(location: NSMaxRange(m.range) - open.length, length: open.length)
        let shown = caretParagraph.map { NSIntersectionRange($0, m.range).length > 0 } ?? true
        for r in [open, close] {
            if shown {
                storage.addAttribute(.foregroundColor, value: faces.faint, range: r)
            } else {
                storage.addAttribute(.font, value: faces.hidden, range: r)
                storage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
            }
        }
    }

    /// Whether a paragraph has emphasis markers, which show or fold as the caret enters or leaves it.
    static func hasEmphasis(_ text: String, in range: NSRange) -> Bool {
        guard range.location != NSNotFound, NSMaxRange(range) <= (text as NSString).length else { return false }
        return strong.firstMatch(in: text, range: range) != nil || emphasis.firstMatch(in: text, range: range) != nil
    }

    /// Paragraph around the caret.
    static func paragraphRange(in string: NSString, at location: Int) -> NSRange {
        let loc = min(max(0, location), string.length)
        return string.paragraphRange(for: NSRange(location: loc, length: 0))
    }
}
