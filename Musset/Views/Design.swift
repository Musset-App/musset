import AppKit
import SwiftUI

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

    /// Something to look at: a problem that stops nothing (a stale reading, a paused AI, a score under the bar).
    static let warning = Color(nsColor: .systemOrange)
    /// Something failed.
    static let error = Color(nsColor: .systemRed)
    /// Good news, quietly: connected, words written today, the final status.
    static let positive = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(srgbRed: 0.40, green: 0.74, blue: 0.53, alpha: 1) : NSColor(srgbRed: 0.18, green: 0.54, blue: 0.34, alpha: 1) })
    /// The corrector's red pencil: Revise mode and the corrections waiting in the text.
    static let revision = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(srgbRed: 0.93, green: 0.42, blue: 0.37, alpha: 1) : NSColor(srgbRed: 0.76, green: 0.22, blue: 0.18, alpha: 1) })
    /// Text and icons on an `accent` ground (a badge, the chosen tool): white on the light theme's deep blue,
    /// ink on the dark theme's pale blue.
    static let onAccent = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(srgbRed: 0.07, green: 0.08, blue: 0.16, alpha: 1) : .white })
    /// Text and icons on a ground of `Color.primary` (the main button, an avatar): the page's own colour, so it
    /// turns with the theme as the ground does.
    static let onPrimary = Color(nsColor: .textBackgroundColor)
}

/// Corner radii: rows and small grounds, controls, cards.
enum Radius {
    static let row: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 10
}

extension ChapterStatus {
    /// The status's colour, wherever it is drawn: the one palette for chapters and scenes.
    var dot: Color {
        switch self {
        case .draft: Color(nsColor: .tertiaryLabelColor)
        case .done: Color(red: 0.18, green: 0.42, blue: 0.84)
        case .edited: Color(red: 0.82, green: 0.48, blue: 0.07)
        case .final: Ink.positive
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
                        .background(on ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
                        .shadow(color: on ? .black.opacity(0.06) : .clear, radius: 1, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.control))
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
        .foregroundStyle(on ? Ink.onPrimary : .primary)
        .background(RoundedRectangle(cornerRadius: 13).fill(on ? Color.primary : Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(on ? Color.clear : Ink.hairline, lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onTapGesture(perform: action)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

/// « Nothing yet »: the one quiet line a list or a panel shows while it has nothing to show.
struct EmptyNote: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// A section's heading, in small capitals of its own making: its key is written as a sentence, and the label
/// capitalises it in the interface's language. `tracking` spaces the letters (the Settings window's groups).
struct SectionLabel: View {
    let text: String
    var tracking: CGFloat = 0
    init(_ text: String, tracking: CGFloat = 0) { self.text = text; self.tracking = tracking }
    var body: some View {
        Text(text.uppercased(with: UILang.locale)).font(.ui(11, .semibold)).tracking(tracking).foregroundStyle(.secondary)
    }
}

// MARK: Settings rows (the Settings window, Book Settings)

/// Rows in a rounded hairline box, a hairline between each. `filled`: on a sheet's grey, the box is paper white.
struct SettingsCard<Content: View>: View {
    var filled = false
    @ViewBuilder let content: Content
    var body: some View {
        Group {
            if #available(macOS 15, *) {
                VStack(spacing: 0) {
                    Group(subviews: content) { rows in
                        ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                            if i > 0 { SettingsHairline() }
                            row
                        }
                    }
                }
            } else {
                // macOS 14 has no Group(subviews:): the older way to walk a view's rows.
                _VariadicView.Tree(SettingsCardRows()) { content }
            }
        }
        .background(filled ? Color(nsColor: .textBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
        .clipShape(RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
    }
}

private struct SettingsHairline: View {
    var body: some View { Rectangle().fill(Ink.hairline.opacity(0.6)).frame(height: 1) }
}

private struct SettingsCardRows: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.offset) { i, row in
                if i > 0 { SettingsHairline() }
                row
            }
        }
    }
}

/// One setting: its name (and a line of explanation) on the left, its control on the right; or, as a `form` row,
/// a quiet label in a column and the field beside it.
struct SettingsRow<Control: View>: View {
    enum Style { case setting, form }
    let title: String
    var hint: String? = nil
    var style = Style.setting
    @ViewBuilder let control: Control
    var body: some View {
        switch style {
        case .setting:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(13, .medium))
                    if let hint { Text(hint).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        case .form:
            HStack(spacing: 16) {
                Text(title).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                control.frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
        }
    }
}

/// An on/off setting.
struct SettingsSwitch: View {
    @Binding var on: Bool
    var body: some View { Toggle("", isOn: $on).toggleStyle(.switch).labelsHidden().controlSize(.small) }
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
            .background(hover ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
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
            .foregroundStyle(primary ? Ink.onPrimary : .primary)
            .padding(.horizontal, 14).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(primary ? Color.primary.opacity(enabled ? 1 : 0.35) : Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(primary ? Color.clear : Ink.hairline))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.control))
    }
}

/// How a toolbar button sits on its bar: a hairline outline, ink-filled for the bar's main action, or on the
/// soft ground of the segmented control beside it.
enum ToolbarGround { case outline, filled, panel }

extension View {
    /// A toolbar's button, 28 points high. A modifier rather than a button style, since `PopMenu` labels wear it too.
    func toolbarButton(_ ground: ToolbarGround = .outline) -> some View {
        self.font(.ui(12, ground == .filled ? .medium : .regular))
            .foregroundStyle(ground == .filled ? Ink.onPrimary : Color.primary)
            .padding(.horizontal, 10).frame(height: 28)
            .background(ground == .filled ? Color.primary : (ground == .panel ? Ink.panel : Color.clear), in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(ground == .outline ? Ink.hairline : Color.clear))
            .contentShape(Rectangle())
    }

    /// What every resize handle shares: a strip wide enough to grab, the resize cursor, a name for VoiceOver.
    func resizeGrip(vertical: Bool = false) -> some View {
        frame(width: vertical ? nil : ResizeGrip.thickness, height: vertical ? ResizeGrip.thickness : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push() } else { NSCursor.pop() }
            }
            .accessibilityLabel(L("Resize"))
    }
}

enum ResizeGrip {
    static let thickness: CGFloat = 6
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
            text("H1", AppCommand.hint("format.h1")) { bridge.textView?.setHeading(1) }
            text("H2", AppCommand.hint("format.h2")) { bridge.textView?.setHeading(2) }
            text("H3", AppCommand.hint("format.h3")) { bridge.textView?.setHeading(3) }
            divider
            icon("bold", AppCommand.hint("format.bold")) { bridge.textView?.toggleInline("**") }
            icon("italic", AppCommand.hint("format.italic")) { bridge.textView?.toggleInline("*") }
            divider
            icon("text.quote", AppCommand.hint("format.quote")) { bridge.textView?.toggleQuote() }
            icon("textformat.superscript", AppCommand.hint("format.footnote")) { bridge.textView?.insertFootnote() }
            icon("text.line.first.and.arrowtriangle.forward", AppCommand.hint("write.scene")) { bridge.textView?.beginScene() }
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
            tool("text.bubble", L("Comment…").titled, AppCommand.hint(L("Comment the selection"), "revise.comment")) { ask(.comment) }
            Rectangle().fill(Ink.hairline).frame(width: 1, height: 14).padding(.horizontal, 6)
            icon("chevron.down", AppCommand.hint("revise.next")) { bridge.textView?.nextRevision() }
            icon("checkmark", AppCommand.hint(L("Accept the correction at the caret"), "revise.accept")) { bridge.textView?.decideRevision(accept: true) }
            icon("xmark", AppCommand.hint(L("Reject the correction at the caret"), "revise.reject")) { bridge.textView?.decideRevision(accept: false) }
        }
        .padding(.horizontal, 6).frame(height: 32)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.revision.opacity(0.35)))
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
        case .system: L("Follow macOS Appearance")
        case .light: L("Light Mode")
        case .dark: L("Dark Mode")
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

/// Runs `action` once the open chapter's text has stopped changing for a moment. The text is watched from this view
/// alone, so the panel that uses it (in a `.background`) is not evaluated again at every letter.
struct WhenTypingPauses: View {
    let session: BookSession
    var after: Duration = .milliseconds(500)
    let action: () -> Void

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .task(id: session.text) {
                try? await Task.sleep(for: after)
                if !Task.isCancelled { action() }
            }
    }
}
