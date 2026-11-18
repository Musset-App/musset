import SwiftUI

/// The conversations of a shared book, in the inspector: a note on a passage, and the replies back and forth.
/// Either side answers or resolves; the other sees who did. Filter by what waits for me, by person, or resolved.
struct ConversationsSection: View {
    let session: BookSession
    let bridge: EditorBridge
    private var collab: Collab { .shared }
    @AppStorage("conversationsOpen") private var open = true
    @State private var filter = Filter.waiting
    @State private var person: String?
    @State private var drafting = ""
    @State private var mark = TalkEntry.Mark.highlight
    @State private var replies: [UUID: String] = [:]

    enum Filter: String, CaseIterable, Identifiable {
        case waiting, all, resolved
        var id: String { rawValue }
        var label: String {
            switch self {
            case .waiting: L("Waiting for me")
            case .all: L("All", ctx: "Toutes")
            case .resolved: L("Resolved")
            }
        }
    }

    private var me: String { collab.username ?? "" }
    private var owner: String { collab.link(session.git)?.owner ?? "" }

    private var shown: [TalkThread] {
        session.talk.threads.filter { t in
            let byFilter: Bool = switch filter {
            case .waiting: t.waits(for: me, owner: owner)
            case .all: !t.isResolved
            case .resolved: t.isResolved
            }
            return byFilter && (person.map { t.people.contains($0) } ?? true)
        }
    }

    private var people: [String] { Array(Set(session.talk.threads.flatMap(\.people)).subtracting([me])).sorted() }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.ui(10, .semibold)).foregroundStyle(.secondary)
                    SectionLabel(L("Conversations"))
                    let waiting = session.talk.waiting(me: me, owner: owner).count
                    if waiting > 0 {
                        Text("\(waiting)").font(.ui(10, .semibold)).foregroundStyle(Ink.onAccent)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Ink.accent, in: Capsule())
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                composer
                HStack(spacing: 6) {
                    Segmented(options: Filter.allCases.map { ($0, $0.label) }, selection: $filter)
                    Spacer()
                }
                if people.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            chip(nil, L("Everyone"))
                            ForEach(people, id: \.self) { chip($0, name($0)) }
                        }
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if shown.isEmpty {
                            EmptyNote(filter == .waiting ? L("Nothing waits for you.") : L("No conversation yet.")).padding(.vertical, 4)
                        }
                        // Eager and bounded: lazy stacks spun in SwiftUI's prefetch elsewhere in Musset.
                        ForEach(shown.prefix(60)) { card($0) }
                    }
                }
                .frame(maxHeight: 420)
            }
        }
        .padding(12)
        .task { session.refreshTalk() }
    }

    // MARK: A new note

    @ViewBuilder private var composer: some View {
        if bridge.selectedRange.length > 0 {
            VStack(alignment: .leading, spacing: 6) {
                let quote = (session.text as NSString).substring(with: NSIntersectionRange(bridge.selectedRange, NSRange(location: 0, length: (session.text as NSString).length)))
                Text("“" + quote.prefix(140) + (quote.count > 140 ? "…" : "") + "”").font(.ui(12)).foregroundStyle(.secondary).lineLimit(3)
                TextField(L("A note for the author") , text: $drafting, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...4)
                HStack {
                    Picker("", selection: $mark) {
                        Text(L("Highlight")).tag(TalkEntry.Mark.highlight)
                        Text(L("Underline")).tag(TalkEntry.Mark.underline)
                        Text(L("Strike")).tag(TalkEntry.Mark.strike)
                        Text(L("In the margin")).tag(TalkEntry.Mark.margin)
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                    Button(L("Leave the note")) {
                        session.startTalk(on: bridge.selectedRange, body: drafting.trimmingCharacters(in: .whitespacesAndNewlines),
                                          mark: mark, color: Person.palette.firstIndex(of: Person.color(me)) ?? 0, tone: nil)
                        drafting = ""
                    }
                    .buttonStyle(.ink).controlSize(.small)
                }
            }
            .padding(10)
            .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
        }
    }

    // MARK: A thread

    private func card(_ t: TalkThread) -> some View {
        let waits = t.waits(for: me, owner: owner)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                if let q = t.note.anchor?.quote, !q.isEmpty {
                    Button { show(t) } label: {
                        Text("“" + q.prefix(60) + (q.count > 60 ? "…" : "") + "”").font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .buttonStyle(.plain).help(L("Show the passage"))
                }
                Spacer()
                if t.isResolved {
                    Text(t.resolvedBy == me ? L("Resolved by you") : L("Resolved by \(name(t.resolvedBy ?? ""))")).font(.ui(11)).foregroundStyle(.secondary)
                } else if waits {
                    Text(L("Your turn")).font(.ui(11, .medium)).foregroundStyle(Ink.accent)
                }
            }
            entry(t.note)
            ForEach(t.replies) { entry($0) }
            if !t.isResolved {
                TextField(L("Reply…"), text: Binding(get: { replies[t.id] ?? "" }, set: { replies[t.id] = $0 }), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(1...5)
            }
            HStack {
                Spacer()
                Button(t.isResolved ? L("Reopen") : L("Resolve")) { session.setResolved(t, !t.isResolved) }.buttonStyle(.inkSecondary).controlSize(.small)
                if !t.isResolved {
                    Button(L("Reply")) {
                        let text = (replies[t.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { return }
                        session.reply(to: t, text)
                        replies[t.id] = nil
                    }
                    .buttonStyle(.ink).controlSize(.small).disabled((replies[t.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(waits ? Person.color(t.last.by) : Ink.hairline, lineWidth: waits ? 1.5 : 1))
        .opacity(t.isResolved ? 0.8 : 1)
    }

    private func entry(_ e: TalkEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(initials(e.by)).font(.ui(9, .semibold)).foregroundStyle(e.by == me ? Ink.onPrimary : Person.color(e.by))
                .frame(width: 22, height: 22)
                .background(e.by == me ? Color.primary.opacity(0.85) : Person.color(e.by).opacity(0.15), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text((e.by == me ? L("You") : name(e.by)) + " · " + e.at.formatted(.relative(presentation: .named)))
                    .font(.ui(11)).foregroundStyle(.secondary)
                if !e.body.isEmpty { Text(e.body).font(.ui(13)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
            }
        }
    }

    private func chip(_ who: String?, _ label: String) -> some View {
        Button { person = who } label: {
            Text(label).font(.ui(11)).padding(.horizontal, 8).padding(.vertical, 3)
                .foregroundStyle(who.map { Person.color($0) } ?? .primary)
                .overlay(Capsule().strokeBorder(person == who ? (who.map { Person.color($0) } ?? .primary) : Ink.hairline))
        }
        .buttonStyle(.plain)
    }

    private func name(_ user: String) -> String { collab.circle.first { $0.username == user }?.name ?? user }

    private func initials(_ user: String) -> String {
        name(user).split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
    }

    /// Opens the thread's chapter and selects its passage where it stands now.
    private func show(_ t: TalkThread) {
        if session.selectedChapterID != t.chapter { session.open(t.chapter) }
        guard let a = t.note.anchor, let r = Anchoring.resolve(a, in: session.text) else { return }
        bridge.textView?.setSelectedRange(r)
        bridge.textView?.scrollRangeToVisible(r)
    }
}
