import AppKit
import SwiftUI

extension Note.Author {
    var nsColor: NSColor {
        switch self {
        case .me: .systemGreen
        case .claude: .systemPurple
        case .codex: .systemTeal
        }
    }
    var color: Color { Color(nsColor: nsColor) }
    var engine: AgentKind { self == .codex ? .codex : .claude }
}

extension Note.Kind {
    /// Highlight colour: a very light green for what works, one colour per family of problem.
    var nsColor: NSColor {
        switch self {
        case .praise: .systemGreen
        case .tic: .systemPink
        case .cut: .systemRed
        case .repetition: .systemBrown
        case .critique: .systemOrange
        case .fact: .systemTeal
        // System indigo is hard to read on the dark panels.
        case .continuity: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(red: 0x8E / 255, green: 0x8C / 255, blue: 0xFF / 255, alpha: 1)
                : .systemIndigo
        }
        case .question: .systemPurple
        case .note: .systemGray
        case .todo: .systemYellow
        case .text: .tertiaryLabelColor
        }
    }
    var color: Color { Color(nsColor: nsColor) }
    /// How strong the passage's tint is; praise stays barely there.
    var fillAlpha: CGFloat { isPositive ? 0.07 : 0.14 }
}

/// Hovering a noted passage: who said what, in a glance. The conversation itself lives in the Notes tab.
struct NotePreview: View {
    let noteID: UUID
    let session: BookSession
    let open: () -> Void
    var close: () -> Void = {}
    /// Several notes in one card stay short each.
    var compact = false

    private var note: Note? { session.notes.notes.first { $0.id == noteID } }

    var body: some View {
        if let note {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(note.author.color).frame(width: 8, height: 8)
                    Text(note.author.label).font(.ui(11, .semibold))
                    Text("· \(note.kind.label)").font(.ui(11)).foregroundStyle(note.kind.color)
                    if let source = note.source { Text("· " + source).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer()
                    if !note.replies.isEmpty {
                        Label("\(note.replies.count)", systemImage: "bubble.left").font(.ui(11)).foregroundStyle(.secondary)
                    }
                }
                Text(LocalizedStringKey(note.body)).font(.ui(12)).lineLimit(compact ? 4 : 12).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(note.replies.isEmpty ? L("Open thread") : L("Open thread (\(note.replies.count) replies)"), action: open)
                        .buttonStyle(.link)
                    Spacer()
                    Button(note.status == .open ? L("Resolve") : L("Reopen")) {
                        session.notes.setStatus(noteID, note.status == .open ? .resolved : .open)
                        close()
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .font(.ui(11))
            }
            .padding(12)
            .frame(width: 320, alignment: .leading)
        }
    }
}

/// The notes that share a passage, one under the other in a single card.
struct NotePreviews: View {
    let noteIDs: [UUID]
    let session: BookSession
    let open: (UUID) -> Void
    var close: () -> Void = {}

    var body: some View {
        if noteIDs.count == 1, let id = noteIDs.first {
            NotePreview(noteID: id, session: session, open: { open(id) }, close: close)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(noteIDs.enumerated()), id: \.element) { i, id in
                        if i > 0 { Divider().padding(.horizontal, 12) }
                        NotePreview(noteID: id, session: session, open: { open(id) }, close: close, compact: true)
                    }
                }
            }
            .frame(width: 320)
            .frame(maxHeight: 460)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A note's conversation, Slack-thread style, in the Notes tab: the passage, the note, the replies,
/// and a composer to answer or ask Claude / Codex.
struct NoteThread: View {
    let noteID: UUID
    let session: BookSession
    let annotator: Annotator
    let bridge: EditorBridge
    let back: () -> Void
    @AppStorage("chatFontSize") private var fontSize = 15.0
    @State private var reply = ""
    @State private var composerHeight: CGFloat = 26
    @State private var editing = false
    @State private var draft = ""
    @State private var draftKind = Note.Kind.note

    private var note: Note? { session.notes.notes.first { $0.id == noteID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: back) { Label("Notes", systemImage: "chevron.left") }.buttonStyle(.borderless)
                Spacer()
                if let note {
                    if note.run != nil { Button(L("Keep")) { session.notes.keep(noteID) }.help(L("Keep this AI note")) }
                    Button(note.status == .open ? L("Resolve") : L("Reopen")) {
                        session.notes.setStatus(noteID, note.status == .open ? .resolved : .open)
                    }
                    Menu {
                        Button(L("Edit note")) { draft = note.body; draftKind = note.kind; editing = true }
                        Divider()
                        Button(L("Delete note"), role: .destructive) { session.notes.delete(noteID); back() }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            if let note {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            // The passage: click to show it in the text.
                            if note.hasPassage { Button { if let r = session.notes.live[noteID] { bridge.scroll(to: r) } } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    RoundedRectangle(cornerRadius: 1).fill(note.kind.color.opacity(0.6)).frame(width: 3)
                                    Text("« \(note.anchor.quote) »").font(.ui(fontSize - 1)).italic()
                                        .foregroundStyle(note.orphaned ? .orange : .secondary).multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(note.orphaned ? L("Passage no longer found") : L("Show the passage in the text")) }
                            if editing {
                                VStack(alignment: .leading, spacing: 6) {
                                    Picker("", selection: $draftKind) { ForEach(Note.Kind.choices, id: \.self) { Text($0.label).tag($0) } }.labelsHidden()
                                    TextEditor(text: $draft).font(.ui(fontSize)).frame(minHeight: 80)
                                    HStack {
                                        Spacer()
                                        Button(L("Cancel")) { editing = false }
                                        Button(L("Save")) { session.notes.update(noteID, body: draft, kind: draftKind); editing = false }
                                            .keyboardShortcut(.return, modifiers: .command)
                                    }
                                }
                            } else {
                                message(author: note.author, kind: note.kind.label, date: note.created, body: note.body)
                            }
                            ForEach(note.replies) { r in
                                message(author: r.author, kind: nil, date: r.created, body: r.body).id(r.id)
                            }
                            if annotator.answering == noteID {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text(L("Answering…")).font(.ui(11)).foregroundStyle(.secondary) }
                                    .id("answering")
                            }
                            Color.clear.frame(height: 1).id("bottom")
                        }
                        .padding(14)
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: note.replies.count) { _, _ in withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
                    .onChange(of: annotator.answering) { _, _ in proxy.scrollTo("bottom", anchor: .bottom) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    if let e = annotator.askError, annotator.answering == nil {
                        Text(e).font(.ui(11)).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                    }
                    // Without that AI on this Mac (or with AI off), a reply is just a note.
                    let ai = partner(of: note).flatMap { AIStatus.shared.engines.contains($0.engine) ? $0 : nil }
                    Composer(text: $reply, fontSize: fontSize,
                             placeholder: ai.map { L("Reply to \($0.label)… (⇧↩ new line)") } ?? L("Reply… (⇧↩ new line)"),
                             onSend: { if let ai { ask(ai.engine) } else { sendReply() } }, height: $composerHeight)
                        .frame(height: composerHeight)
                    HStack(spacing: 8) {
                        if annotator.answering == noteID {
                            ProgressView().controlSize(.small)
                            Text(L("\(ai?.label ?? L("The AI")) is answering…")).font(.ui(11)).foregroundStyle(.secondary)
                            Spacer()
                            Button(L("Stop")) { annotator.stopAsking() }.controlSize(.small)
                        } else {
                            // In a conversation with an AI, ↩ answers it; otherwise ↩ is a plain reply.
                            ForEach([Note.Author.claude, .codex].filter { $0 != ai && AIStatus.shared.engines.contains($0.engine) }, id: \.self) { other in
                                Button { ask(other.engine) } label: { Label(L("Ask \(other.label)"), systemImage: "sparkles") }
                                    .buttonStyle(.bordered).controlSize(.small)
                            }
                            Spacer()
                            if ai != nil {
                                Button(L("Note only"), action: sendReply)
                                    .buttonStyle(.borderless).font(.ui(11))
                                    .help(L("Add your reply without asking \(ai!.label)"))
                                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            Button(ai.map { L("Send to \($0.label)") } ?? L("Reply")) { if let ai { ask(ai.engine) } else { sendReply() } }
                                .buttonStyle(.borderedProminent).controlSize(.small)
                                .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .disabled(annotator.answering != nil && annotator.answering != noteID)
                }
                .padding(10)
            } else {
                Text(L("This note was deleted.")).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if let r = session.notes.live[noteID] { bridge.scroll(to: r) } }
    }

    /// Same look as the chat: your messages in a tinted bubble, the AI's as plain text under its name.
    @ViewBuilder
    private func message(author: Note.Author, kind: String?, date: Date, body: String) -> some View {
        if author == .me {
            VStack(alignment: .trailing, spacing: 2) {
                Text(body).font(.ui(fontSize)).textSelection(.enabled)
                    .padding(8)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                HStack(spacing: 4) {
                    if let kind { Text(kind).font(.ui(10)).foregroundStyle(.secondary) }
                    Text(date.relativeInUI).font(.ui(10)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle().fill(author.color).frame(width: 8, height: 8)
                    Text(author.label).font(.ui(fontSize - 3, .semibold)).foregroundStyle(.secondary)
                    if let kind { Text("· \(kind)").font(.ui(fontSize - 3)).foregroundStyle(.secondary) }
                    Spacer()
                    Text(date.relativeInUI).font(.ui(10)).foregroundStyle(.tertiary)
                }
                MarkdownText(text: body.isEmpty ? "…" : body, size: fontSize)
            }
        }
    }

    /// The AI this thread is a conversation with (the note's author, or the last AI that answered).
    private func partner(of note: Note) -> Note.Author? {
        if note.author.isAI { return note.author }
        return note.replies.last { $0.author.isAI }?.author
    }

    private func sendReply() {
        let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        session.notes.reply(noteID, author: .me, body: text)
        reply = ""
    }

    private func ask(_ engine: AgentKind) {
        annotator.ask(noteID, question: reply, session: session, engine: engine)
        reply = ""
    }
}

/// New note on the selected passage.
struct NoteComposer: View {
    let quote: String
    let save: (Note.Kind, String) -> Void
    let cancel: () -> Void
    @State private var kind = Note.Kind.note
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("« \(quote) »").font(.ui(11)).foregroundStyle(.secondary).lineLimit(2)
            Picker("", selection: $kind) {
                ForEach([Note.Kind.note, .question, .todo], id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            TextEditor(text: $text).font(.ui(13)).frame(minHeight: 80, maxHeight: 200).focused($focused)
            HStack {
                Text(L("⌘↩ to save")).font(.ui(10)).foregroundStyle(.tertiary)
                Spacer()
                Button(L("Cancel"), action: cancel).keyboardShortcut(.cancelAction)
                Button(L("Add Note")) { save(kind, text) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { focused = true }
    }
}

/// A comment from revision mode, shown on hovering its bubble.
struct CommentCard: View {
    let text: String
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill").foregroundStyle(Color(red: 0.48, green: 0.23, blue: 0.85))
                Text(L("Comment", ctx: "Commentaire")).font(.ui(12, .semibold))
            }
            Text(text).font(.ui(13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            HStack { Spacer(); Button(L("Remove"), action: remove).buttonStyle(.inkSecondary) }
        }
        .padding(14)
        .frame(width: 300, alignment: .leading)
    }
}
