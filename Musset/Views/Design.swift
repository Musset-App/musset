import AppKit
import SwiftUI

/// The interface language: the system's, or one of Musset's six by choice (Settings ▸ General).
enum UILang: String, CaseIterable, Identifiable {
    case system, en, fr, de, es, it, ptBR = "pt-BR", ptPT = "pt-PT"
    var id: String { rawValue }
    static let key = "uiLanguage"

    /// The language the interface is in now: the chosen one, or the first of the system's that Musset speaks.
    static var current: UILang {
        let chosen = UILang(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system
        if chosen != .system { return chosen }
        for code in Locale.preferredLanguages {
            if let l = from(code) { return l }
        }
        return .en
    }

    /// "pt-BR", "pt_PT", "de-CH", "fr"… → the interface language, if Musset has it.
    static func from(_ code: String) -> UILang? {
        let c = code.replacingOccurrences(of: "_", with: "-").lowercased()
        if c.hasPrefix("pt") { return c.hasPrefix("pt-pt") ? .ptPT : .ptBR }
        return [UILang.en, .fr, .de, .es, .it].first { c.hasPrefix($0.rawValue) }
    }

    static var isFrench: Bool { current == .fr }

    /// Dates and numbers in the interface's language.
    static var locale: Locale { Locale(identifier: current.localeID) }

    var localeID: String {
        switch self {
        case .system: UILang.current.localeID
        case .en: "en_US"
        case .fr: "fr_FR"
        case .de: "de_DE"
        case .es: "es_ES"
        case .it: "it_IT"
        case .ptBR: "pt_BR"
        case .ptPT: "pt_PT"
        }
    }

    /// Each language in its own name, so anyone can find theirs.
    var label: String {
        switch self {
        case .system: L("System")
        case .en: "English"
        case .fr: "Français"
        case .de: "Deutsch"
        case .es: "Español"
        case .it: "Italiano"
        case .ptBR: "Português (Brasil)"
        case .ptPT: "Português (Portugal)"
        }
    }

    /// One when the count takes the singular (CLDR): French and Brazilian Portuguese count 0 as singular.
    func isOne(_ n: Int) -> Bool {
        switch self {
        case .fr, .ptBR: n == 0 || n == 1
        default: n == 1
        }
    }
}

/// A piece of interface text, written in English at the call site: `L("\(n) notes")`.
/// Its key is the English with `{%0}`, `{%1}`… for what is interpolated, so a translation may reorder them.
struct LKey: ExpressibleByStringInterpolation {
    var key: String
    var args: [String]
    /// The first whole number interpolated: it picks the singular or plural form.
    var count: Int?

    init(stringLiteral value: String) { key = value; args = []; count = nil }
    init(stringInterpolation s: StringInterpolation) { key = s.key; args = s.args; count = s.count }

    struct StringInterpolation: StringInterpolationProtocol {
        var key = "", args: [String] = [], count: Int?
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { key += literal }
        mutating func appendInterpolation<T>(_ value: T) {
            key += "{%\(args.count)}"
            if count == nil, let n = value as? Int { count = n }
            args.append(String(describing: value))
        }
    }
}

/// The interface's text tables, one per language, keyed by the English (`Resources/Localization/<lang>.json`).
/// An entry is a string, or `{"one": …, "other": …}` when it holds a count.
enum Strings {
    nonisolated(unsafe) private static var tables: [UILang: [String: Any]] = [:]
    private static let lock = NSLock()

    static func table(_ lang: UILang) -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        if let t = tables[lang] { return t }
        var t: [String: Any] = [:]
        if let url = Bundle.main.url(forResource: lang.rawValue, withExtension: "json", subdirectory: "Localization")
            ?? Bundle.main.url(forResource: lang.rawValue, withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t = json
        }
        tables[lang] = t
        return t
    }

    static func text(_ key: LKey, ctx: String? = nil, lang: UILang = UILang.current) -> String {
        let lookup = ctx.map { key.key + "@@" + $0 } ?? key.key
        var form: String?
        for l in [lang, .en] {
            let entry = table(l)[lookup] ?? (ctx == nil ? nil : table(l)[key.key])
            if let s = entry as? String { form = s; break }
            if let p = entry as? [String: String] {
                let one = key.count.map { l.isOne($0) } ?? false
                form = (one ? p["one"] : p["other"]) ?? p["other"]
                break
            }
        }
        var out = form ?? key.key
        for (i, a) in key.args.enumerated().reversed() { out = out.replacingOccurrences(of: "{%\(i)}", with: a) }
        return out
    }
}

/// A piece of interface text in the interface's language. `ctx` tells apart two senses of the same English
/// (« Done » the status, « Done » the button): it is the French sense, which the tables also key on.
func L(_ key: LKey, ctx: String? = nil) -> String { Strings.text(key, ctx: ctx) }

/// A text that is only known at run time (a preset's stored name, an engine's label): looked up as it is.
func L(dynamic text: String) -> String { Strings.text(LKey(stringLiteral: text)) }

/// Musset's palette: grey carries the interface; colour only ever means something (a note kind, a status, a tag).
enum Ink {
    static let hairline = Color(nsColor: .separatorColor)
    /// The critique's own colour: its button, and the voices at the table.
    static let critique = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(srgbRed: 0.96, green: 0.70, blue: 0.27, alpha: 1) : NSColor(srgbRed: 0.72, green: 0.42, blue: 0.04, alpha: 1) })
    /// What left the text and what came into it.
    static let removed = Color(nsColor: .systemRed)
    static let added = Color(nsColor: .systemGreen)
    /// Ink blue: the one accent (caret, links, the current choice).
    static let accent = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(srgbRed: 0.56, green: 0.64, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.18, green: 0.29, blue: 0.78, alpha: 1) })
    static let panel = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(srgbRed: 0.15, green: 0.15, blue: 0.14, alpha: 1) : NSColor(srgbRed: 0.949, green: 0.945, blue: 0.933, alpha: 1) })
    static let selected = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(white: 1, alpha: 0.08) : NSColor(srgbRed: 0.1, green: 0.1, blue: 0.09, alpha: 0.07) })
    static let side = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(srgbRed: 0.106, green: 0.106, blue: 0.102, alpha: 1) : NSColor(srgbRed: 0.969, green: 0.965, blue: 0.953, alpha: 1) })
}

extension ChapterStatus {
    var dot: Color {
        switch self {
        case .draft: Color(nsColor: .tertiaryLabelColor)
        case .done: Color(red: 0.18, green: 0.42, blue: 0.84)
        case .edited: Color(red: 0.82, green: 0.48, blue: 0.07)
        case .final: Color(red: 0.18, green: 0.54, blue: 0.34)
        }
    }
}

/// A 6-point status dot, with the status as its tooltip.
struct StatusDot: View {
    let status: ChapterStatus
    var body: some View {
        Circle().fill(status.dot).frame(width: 6, height: 6).help(status.label)
    }
}

/// A keyboard key, as drawn in menus and the command bar.
struct Kbd: View {
    let key: String
    init(_ key: String) { self.key = key }
    var body: some View {
        Text(key)
            .font(.ui(11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Ink.panel, in: RoundedRectangle(cornerRadius: 4))
    }
}

/// A segmented control drawn the Musset way: text only, a raised white segment for the current choice.
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.0) { value, label in
                let on = value == selection
                Button { selection = value } label: {
                    Text(label)
                        .font(.ui(12, on ? .medium : .regular))
                        .foregroundStyle(on ? .primary : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .background(on ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .shadow(color: on ? .black.opacity(0.06) : .clear, radius: 1, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A filter chip: dark when on.
struct Chip: View {
    let label: String
    let on: Bool
    var dot: Color? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
            Text(label).font(.ui(12)).lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 10).frame(height: 26)
        .foregroundStyle(on ? Color(nsColor: .textBackgroundColor) : .primary)
        .background(RoundedRectangle(cornerRadius: 13).fill(on ? Color.primary : Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(on ? Color.clear : Ink.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

/// Section title in settings-like pages.
struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.ui(11, .semibold)).foregroundStyle(.secondary)
    }
}

extension Date {
    /// "2 hours ago" / « il y a 2 heures », in the interface language.
    var relativeInUI: String {
        formatted(.relative(presentation: .named).locale(Locale(identifier: UILang.current.localeID)))
    }
}

/// A menu whose button keeps the exact look it is given (a system Menu strips backgrounds and shapes from its label).
/// Choices open in a small popover, in sections.
struct PopItem: Identifiable {
    let id = UUID()
    let title: String
    var checked = false
    var dot: Color? = nil
    /// Small mono text beside the title (a model's id), and a line under it.
    var detail: String? = nil
    var subtitle: String? = nil
    let action: () -> Void
}

struct PopSection: Identifiable {
    let id = UUID()
    var title: String? = nil
    let items: [PopItem]
}

struct PopMenu<Label: View>: View {
    let sections: [PopSection]
    @ViewBuilder let label: () -> Label
    @State private var open = false

    init(_ items: [PopItem], @ViewBuilder label: @escaping () -> Label) { self.sections = [PopSection(items: items)]; self.label = label }
    init(sections: [PopSection], @ViewBuilder label: @escaping () -> Label) { self.sections = sections; self.label = label }

    var body: some View {
        Button { open.toggle() } label: { label().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sections) { section in
                        if let t = section.title {
                            Text(t).font(.ui(11, .medium)).foregroundStyle(.secondary)
                                .padding(.horizontal, 10).padding(.top, section.id == sections.first?.id ? 2 : 8).padding(.bottom, 2)
                        }
                        ForEach(section.items) { item in
                            PopRow(item: item) { open = false; item.action() }
                        }
                    }
                }
                .padding(6)
                .frame(minWidth: 180)
            }
    }
}

private struct PopRow: View {
    let item: PopItem
    let run: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: run) {
            HStack(spacing: 8) {
                if let dot = item.dot { Circle().fill(dot).frame(width: 6, height: 6) }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.title)
                        if let d = item.detail { Text(d).font(.uiMono(11)).foregroundStyle(.secondary) }
                    }
                    if let s = item.subtitle { Text(s).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer(minLength: 12)
                if item.checked { Image(systemName: "checkmark").font(.ui(10, .semibold)) }
            }
            .font(.ui(13))
            .padding(.horizontal, 10).frame(minHeight: 26).padding(.vertical, item.subtitle == nil ? 0 : 4)
            .background(hover ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The design's two buttons: ink-filled for the main action, white with a hairline for the others.
struct InkButtonStyle: ButtonStyle {
    var primary = true
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(13, primary ? .medium : .regular))
            .foregroundStyle(primary ? Color(nsColor: .textBackgroundColor) : .primary)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Color.primary.opacity(enabled ? 1 : 0.35) : Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? Color.clear : Ink.hairline))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension ButtonStyle where Self == InkButtonStyle {
    static var ink: InkButtonStyle { InkButtonStyle() }
    static var inkSecondary: InkButtonStyle { InkButtonStyle(primary: false) }
}

extension Int {
    /// 1 472 in French, 1,472 in English: numbers follow the interface language, not the system's.
    var ui: String { formatted(.number.locale(Locale(identifier: UILang.current.localeID))) }
}

// MARK: Type

/// Musset's typefaces, shipped in the app (Resources/Fonts, SIL Open Font Licence): Inter for the interface,
/// IBM Plex Mono for the manuscript, Iosevka Aile and Etoile to choose instead, EB Garamond for the printed book (Typst finds
/// it in the same folder). Registered for this process only at launch.
enum Typefaces {
    static let ui = "Inter"
    static let mono = "IBM Plex Mono"
    /// PostScript name of the manuscript face, as the editor's font setting stores it.
    static let manuscript = "IBMPlexMono-Regular"

    static func register() {
        let urls = ["ttf", "otf"].flatMap { ext in
            (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: nil) ?? [])
                + (Bundle.main.urls(forResourcesWithExtension: ext, subdirectory: "Fonts") ?? [])
        }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }

    /// Inter at a weight, for AppKit drawing (the face is variable: weights come from its axis).
    static func nsUI(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let d = NSFontDescriptor(fontAttributes: [.family: ui, .traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: d, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }
}

extension Font {
    /// Interface text in Inter.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom(Typefaces.ui, size: size).weight(weight) }
    /// Monospaced interface text (quotes, numbers in lists) in IBM Plex Mono.
    static func uiMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .custom(Typefaces.mono, size: size).weight(weight) }
}

/// The format bar: a small floating pill at the top of the page — headings, bold, italic, quotation,
/// footnote, new scene. Every button has its shortcut, shown in its tooltip.
struct FormatBar: View {
    let bridge: EditorBridge

    var body: some View {
        HStack(spacing: 2) {
            text("H1", L("Heading 1 (⌥⌘1)")) { bridge.textView?.setHeading(1) }
            text("H2", L("Heading 2 (⌥⌘2)")) { bridge.textView?.setHeading(2) }
            text("H3", L("Heading 3 (⌥⌘3)")) { bridge.textView?.setHeading(3) }
            divider
            icon("bold", L("Bold (⌘B)")) { bridge.textView?.toggleInline("**") }
            icon("italic", L("Italic (⌘I)")) { bridge.textView?.toggleInline("*") }
            divider
            icon("text.quote", L("Quotation (⌥⌘')")) { bridge.textView?.toggleQuote() }
            icon("textformat.superscript", L("Footnote (⌥⌘6)")) { bridge.textView?.insertFootnote() }
            icon("text.line.first.and.arrowtriangle.forward", L("New scene here (⇧⌘N)")) { bridge.textView?.beginScene() }
        }
        .padding(.horizontal, 6).frame(height: 30)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.hairline))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
    }

    private var divider: some View { Rectangle().fill(Ink.hairline).frame(width: 1, height: 14).padding(.horizontal, 4) }

    private func text(_ label: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.ui(11, .semibold)).foregroundStyle(.secondary).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 26, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}


/// Revise mode's toolbar: the editor's tools on the selection, and the decisions.
struct RevisionBar: View {
    let bridge: EditorBridge
    @State private var asking: Tool?
    @State private var text = ""

    enum Tool: String, Identifiable {
        case add, replace, comment
        var id: String { rawValue }
        var prompt: String {
            switch self {
            case .add: L("Text to add")
            case .replace: L("Replace with")
            case .comment: L("Your comment")
            }
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            tool("strikethrough", L("Delete"), L("Strike out the selection")) { bridge.textView?.markDeletion() }
            tool("plus", L("Add"), L("Propose text at the caret")) { ask(.add) }
            tool("arrow.left.arrow.right", L("Replace"), L("Propose a replacement for the selection")) { ask(.replace) }
            tool("highlighter", L("Highlight"), L("Highlight the selection")) { bridge.textView?.markHighlight() }
            tool("text.bubble", L("Comment", ctx: "Commenter"), L("Comment the selection (⇧⌘M)")) { ask(.comment) }
            Rectangle().fill(Ink.hairline).frame(width: 1, height: 14).padding(.horizontal, 6)
            icon("chevron.down", L("Next correction (⌥⌘])")) { bridge.textView?.nextRevision() }
            icon("checkmark", L("Accept the correction at the caret (⌥⌘↩)")) { bridge.textView?.decideRevision(accept: true) }
            icon("xmark", L("Reject the correction at the caret (⌥⌘⌫)")) { bridge.textView?.decideRevision(accept: false) }
        }
        .padding(.horizontal, 6).frame(height: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color(red: 0.76, green: 0.22, blue: 0.18).opacity(0.35)))
        .shadow(color: .black.opacity(0.05), radius: 10, y: 3)
        .onReceive(NotificationCenter.default.publisher(for: .mussetAskComment)) { _ in ask(.comment) }
        .popover(item: $asking, arrowEdge: .bottom) { t in
            VStack(alignment: .leading, spacing: 10) {
                Text(t.prompt).font(.ui(12, .semibold)).foregroundStyle(.secondary)
                TextField("", text: $text, axis: .vertical).textFieldStyle(.roundedBorder).frame(width: 300).onSubmit { apply(t) }
                HStack {
                    Spacer()
                    Button(L("Cancel")) { asking = nil }.buttonStyle(.inkSecondary)
                    Button("OK") { apply(t) }.buttonStyle(.ink).keyboardShortcut(.defaultAction).disabled(text.isEmpty)
                }
            }
            .padding(14)
        }
    }

    private func ask(_ t: Tool) {
        if t == .replace, (bridge.textView?.selectedRange().length ?? 0) == 0 { NSSound.beep(); return }
        text = ""
        asking = t
    }

    private func apply(_ t: Tool) {
        guard !text.isEmpty, let tv = bridge.textView else { return }
        switch t {
        case .add: tv.markInsertion(text)
        case .replace: tv.markSubstitution(text)
        case .comment: tv.markHighlight(comment: text)
        }
        asking = nil
    }

    private func tool(_ icon: String, _ label: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.ui(12))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 8).frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }

    private func icon(_ name: String, _ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

/// Light, dark, or as macOS is: the whole app's appearance, remembered between launches.
enum Appearance: String, CaseIterable {
    case system, light, dark
    static let key = "appearance"
    static var current: Appearance { Appearance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .system }

    var label: String {
        switch self {
        case .system: L("Follow macOS appearance")
        case .light: L("Light mode")
        case .dark: L("Dark mode")
        }
    }
    var icon: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    /// Chosen and applied at once, to every window.
    @MainActor func choose() {
        UserDefaults.standard.set(rawValue, forKey: Appearance.key)
        Appearance.apply()
    }

    @MainActor static func apply() {
        switch current {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
