import Carbon.HIToolbox
import SwiftUI

/// What `@` can link to in the open book.
struct LinkTarget: Identifiable, Hashable {
    var kind: String
    var title: String
    var id: String { kind + title }
}

extension BookSession {
    func linkTargets(matching query: String) -> [LinkTarget] {
        let chapters = manifest.chapters.map { LinkTarget(kind: words.name(.piece), title: $0.title) }
        let sheets = bible.entries.filter { $0.kind != .cut }.map { LinkTarget(kind: $0.kind.label, title: $0.title) }
        let tags = bible.tagsWithoutSheet(plot).map { LinkTarget(kind: BibleKind.character.label, title: $0.name) }
        let all = chapters + sheets + tags
        guard !query.isEmpty else { return Array(all.prefix(6)) }
        let f = Fold.name(query)
        return Array(all.filter { Fold.name($0.title).contains(f) }.prefix(6))
    }

    /// Files a capture: with the chapter it names, else in the Bible's To sort folder. Returns where it went, in words.
    @discardableResult
    func file(capture raw: String) -> String {
        let text = TodoSyntax.normalize(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "" }
        let targets = BibleLinks.targets(in: text).map(Fold.name)
        if let ch = manifest.chapters.first(where: { targets.contains(Fold.name($0.title)) }) {
            let notes = noteStore(for: ch.id)
            for line in text.components(separatedBy: "\n") where !line.isEmpty {
                if let task = TodoSyntax.parse(Substring(line)) { notes.addPlain(task.text, kind: .todo, in: ch.id) }
                else { notes.addPlain(line, kind: .text, in: ch.id) }
            }
            pendingCommit = true
            return ch.title
        }
        let title = BibleLinks.plain(text).replacingOccurrences(of: "- [ ] ", with: "").split(separator: "\n").first.map { String($0.prefix(48)) } ?? L("Capture")
        try? bible.create(title: title, kind: .note, folder: "a-trier", body: text + "\n")
        pendingCommit = true
        return BibleStore.folderLabel("a-trier")
    }
}

/// The panel: type, `@` to link, `@todo` for a task, ⌘↩ to file it.
struct CaptureView: View {
    let session: BookSession
    let close: () -> Void
    @State private var text = ""
    @State private var picked = 0
    @FocusState private var focused: Bool

    /// The word after the last `@` being typed, if the caret is still in it.
    private var query: String? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        let rest = text[text.index(after: at)...]
        if rest.hasPrefix("[") || rest.contains("\n") || rest.count > 30 { return nil }
        if "todo".hasPrefix(rest.lowercased()) && !rest.isEmpty && rest.lowercased() == "todo" { return nil }
        return String(rest)
    }

    private var hits: [LinkTarget] { query.map(session.linkTargets(matching:)) ?? [] }

    private var destination: String {
        let t = BibleLinks.targets(in: text).map(Fold.name)
        let chapter = session.manifest.chapters.first { t.contains(Fold.name($0.title)) }?.title
        let task = TodoSyntax.normalize(text).contains("- [ ] ") ? L("To do") : nil
        return [chapter ?? BibleStore.folderLabel("a-trier"), task].compactMap { $0 }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(L("A note. @ links, @todo makes a task.")).font(.ui(15)).foregroundStyle(.tertiary).padding(.horizontal, 5).padding(.top, 1)
                }
                TextEditor(text: $text)
                    .font(.ui(15))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
                    .onKeyPress(.upArrow) { move(-1) }
                    .onKeyPress(.downArrow) { move(1) }
                    .onKeyPress(.tab) { complete() }
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.command) { save(); return .handled }
                        return complete()
                    }
                    .onChange(of: text) { _, _ in picked = 0 }
            }
            .padding(.horizontal, 16).padding(.top, 16).frame(height: 110)
            if !hits.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(hits.enumerated()), id: \.element.id) { i, hit in
                        Button { insert(hit) } label: {
                            HStack {
                                Text(hit.kind).font(.ui(12)).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
                                Text(hit.title).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 10).frame(height: 30)
                            .background(i == picked ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Ink.hairline))
                .padding(.horizontal, 12).padding(.bottom, 10)
            }
            Divider()
            HStack {
                Text(L("Goes to: \(session.title) · \(destination)")).lineLimit(1)
                Spacer()
                Text(L("⌘↩ file · Esc close"))
            }
            .font(.ui(12)).foregroundStyle(.secondary).padding(.horizontal, 16).frame(height: 38)
        }
        .frame(width: 620)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { focused = true }
        .onExitCommand { close() }
    }

    private func move(_ by: Int) -> KeyPress.Result {
        guard !hits.isEmpty else { return .ignored }
        picked = (picked + by + hits.count) % hits.count
        return .handled
    }

    private func complete() -> KeyPress.Result {
        guard hits.indices.contains(picked) else { return .ignored }
        insert(hits[picked])
        return .handled
    }

    private func insert(_ hit: LinkTarget) {
        guard let at = text.lastIndex(of: "@") else { return }
        text = String(text[..<at]) + "@[\(hit.title)] "
    }

    private func save() {
        session.file(capture: text)
        text = ""
        close()
    }
}

/// A floating panel that opens over whatever is in front, and a system-wide shortcut for it.
@MainActor
final class CaptureController {
    static let shared = CaptureController()
    weak var app: AppState?
    private var panel: NSPanel?
    private var hotKey: EventHotKeyRef?

    /// ⌃⌥N. Carbon's hot keys need no accessibility permission.
    func install() {
        guard hotKey == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { CaptureController.shared.toggle() }
            return noErr
        }, 1, &spec, nil, nil)
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(controlKey | optionKey), EventHotKeyID(signature: OSType(0x4D535354), id: 1), GetApplicationEventTarget(), 0, &hotKey)
    }

    func toggle() {
        if let panel, panel.isVisible { hide(); return }
        guard let session = app?.current else { NSApp.activate(ignoringOtherApps: true); return }
        let panel = self.panel ?? NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 170),
                                          styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        let host = NSHostingView(rootView: CaptureView(session: session, close: { [weak self] in self?.hide() }).tint(Ink.accent).id(UUID()))
        host.sizingOptions = [.intrinsicContentSize]
        panel.contentView = host
        self.panel = panel
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - 310, y: f.maxY - 150))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() { panel?.orderOut(nil) }
}
