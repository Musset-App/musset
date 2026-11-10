import AppKit

/// Soft, iA-like Markdown styling: markup is dimmed in the paragraph being written, folded away elsewhere.
struct EditorTheme {
    var fontName: String
    var fontSize: CGFloat
    var lineHeight: CGFloat = 1.78
    /// Space between paragraphs, as a fraction of a line ("Aéré": half a line). One line per paragraph in the editor.
    var paragraphGap: CGFloat = CGFloat(UserDefaults.standard.object(forKey: "paragraphSpacing") as? Double ?? 0.73)

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

    var typingAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: ink, .paragraphStyle: paragraphStyle]
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

    /// Restyles the whole storage. Chapters are a few thousand words, so this is cheap.
    static func style(_ storage: NSTextStorage, theme: EditorTheme, caret: Int? = nil) {
        let full = NSRange(location: 0, length: storage.length)
        let s = storage.string
        storage.beginEditing()
        storage.setAttributes(theme.typingAttributes, range: full)
        let body = theme.bodyFont
        let fm = NSFontManager.shared
        let caretParagraph = caret.map { paragraphRange(in: s as NSString, at: $0) }

        heading.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            let level = m.range(at: 1).length
            let scale: CGFloat = level == 1 ? 1.45 : (level == 2 ? 1.2 : 1.05)
            let f = fm.convert(NSFont(descriptor: body.fontDescriptor, size: body.pointSize * scale) ?? body, toHaveTrait: .boldFontMask)
            storage.addAttribute(.font, value: f, range: m.range)
            storage.addAttribute(.foregroundColor, value: theme.faint, range: m.range(at: 1))
            storage.addAttribute(.paragraphStyle, value: theme.headingStyle(f.pointSize), range: m.range)
        }
        strong.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.font, value: fm.convert(body, toHaveTrait: .boldFontMask), range: m.range(at: 2))
            dimMarkers(storage, m, theme, caretParagraph)
        }
        emphasis.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            italicize(storage, m.range(at: 2), body)
            dimMarkers(storage, m, theme, caretParagraph)
        }
        quote.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            italicize(storage, m.range, body)
        }
        rule.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: theme.faint, range: m.range)
            storage.addAttribute(.paragraphStyle, value: theme.ruleStyle, range: m.range)
        }
        // Author's notes (HTML comments): small, faint, monospaced.
        comment.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.foregroundColor, value: theme.faint, range: m.range)
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: body.pointSize * 0.72, weight: .regular), range: m.range)
        }

        // Corrections (CriticMarkup): added in green, deleted struck through in red, highlights in yellow.
        // The syntax and the comment bodies are never shown (comments are bubbles, drawn by the editor).
        let green = NSColor(srgbRed: 0.18, green: 0.54, blue: 0.34, alpha: 1)
        let red = NSColor(srgbRed: 0.76, green: 0.22, blue: 0.18, alpha: 1)
        for m in Revisions.marks(in: s) {
            func added(_ r: NSRange) {
                storage.addAttribute(.foregroundColor, value: green, range: r)
                storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
                storage.addAttribute(.underlineColor, value: green.withAlphaComponent(0.6), range: r)
            }
            func removed(_ r: NSRange) {
                storage.addAttribute(.foregroundColor, value: red, range: r)
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: r)
            }
            switch m.kind {
            case .insertion: added(m.first)
            case .deletion: removed(m.first)
            case .substitution:
                removed(m.first)
                if let b = m.second { added(b) }
                // A little air between the old words and the new ones (drawn, not typed).
                if m.first.length > 0 { storage.addAttribute(.kern, value: body.pointSize * 0.4, range: NSRange(location: NSMaxRange(m.first) - 1, length: 1)) }
            case .highlight: storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.28), range: m.first)
            case .comment: break
            }
        }
        let hiddenFont = NSFont.systemFont(ofSize: 0.01)
        for r in Revisions.hidden(in: s) {
            storage.addAttribute(.font, value: hiddenFont, range: r)
            storage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
            storage.removeAttribute(.underlineStyle, range: r)
            storage.removeAttribute(.strikethroughStyle, range: r)
            storage.removeAttribute(.backgroundColor, range: r)
        }

        // Footnotes: smaller and grey, the ^[ ] markers faint.
        footnote.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.font, value: NSFont(descriptor: body.fontDescriptor, size: body.pointSize * 0.82) ?? body, range: m.range)
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range)
            storage.addAttribute(.foregroundColor, value: theme.faint, range: NSRange(location: m.range.location, length: 2))
            storage.addAttribute(.foregroundColor, value: theme.faint, range: NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }

        // Scene markers: the title stands out a little, the comment syntax stays faint.
        Scenes.pattern.enumerateMatches(in: s, range: full) { m, _, _ in
            guard let m else { return }
            storage.addAttribute(.paragraphStyle, value: theme.sceneStyle, range: m.range)
            storage.addAttribute(.font, value: Typefaces.nsUI(body.pointSize * 0.72), range: m.range)
            storage.addAttribute(.foregroundColor, value: theme.dimmed, range: m.range)
            storage.addAttribute(.font, value: sceneTitleFont(body.pointSize), range: m.range(at: 1))
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: m.range(at: 1))
            storage.addAttribute(.kern, value: body.pointSize * 0.08, range: m.range(at: 1))
            // Away from the caret only the title shows; the comment syntax folds to nothing.
            if let caret, !(m.range.location...NSMaxRange(m.range)).contains(caret) {
                let title = m.range(at: 1)
                let tiny = NSFont.systemFont(ofSize: 0.5)
                for r in [NSRange(location: m.range.location, length: title.location - m.range.location),
                          NSRange(location: NSMaxRange(title), length: NSMaxRange(m.range) - NSMaxRange(title))] where r.length > 0 {
                    storage.addAttribute(.font, value: tiny, range: r)
                    storage.addAttribute(.foregroundColor, value: NSColor.clear, range: r)
                }
            }
        }

        storage.endEditing()
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

    /// Italic face when the font has one; otherwise a slight slant (Inconsolata, for one, has no italic).
    private static func italicize(_ storage: NSTextStorage, _ range: NSRange, _ body: NSFont) {
        let fm = NSFontManager.shared
        let italic = fm.convert(body, toHaveTrait: .italicFontMask)
        storage.addAttribute(.font, value: italic, range: range)
        if !fm.traits(of: italic).contains(.italicFontMask) {
            storage.addAttribute(.obliqueness, value: 0.18, range: range)
        }
    }

    /// The * and ** around emphasis: faint in the paragraph with the caret, folded to nothing elsewhere.
    private static func dimMarkers(_ storage: NSTextStorage, _ m: NSTextCheckingResult, _ theme: EditorTheme, _ caretParagraph: NSRange?) {
        let open = m.range(at: 1)
        let close = NSRange(location: NSMaxRange(m.range) - open.length, length: open.length)
        let shown = caretParagraph.map { NSIntersectionRange($0, m.range).length > 0 } ?? true
        for r in [open, close] {
            if shown {
                storage.addAttribute(.foregroundColor, value: theme.faint, range: r)
            } else {
                storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 0.01), range: r)
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
