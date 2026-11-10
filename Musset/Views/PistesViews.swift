import SwiftUI

extension Ink {
    /// A track's colour, and a milestone's.
    static let piste = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(srgbRed: 0.65, green: 0.65, blue: 1.0, alpha: 1) : NSColor(srgbRed: 0.36, green: 0.34, blue: 0.82, alpha: 1) })
    static let jalon = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua]) != nil
        ? NSColor(srgbRed: 0.91, green: 0.69, blue: 0.36, alpha: 1) : NSColor(srgbRed: 0.68, green: 0.42, blue: 0.05, alpha: 1) })
}

/// The title bar's « where I write »: the manuscript or a track, and what one does with tracks.
struct PisteMenu: View {
    let app: AppState
    let session: BookSession

    var body: some View {
        PopMenu(sections: sections) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.ui(11))
                Text(session.piste?.name ?? L("Manuscript")).font(.ui(12)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170)
            }
            .foregroundStyle(session.piste == nil ? Color.secondary : Ink.piste)
            .padding(.horizontal, 9).frame(height: 22)
            .background(session.piste == nil ? Ink.panel : Ink.piste.opacity(0.14), in: Capsule())
        }
        .help(L("Where you write: the manuscript, or a track beside it"))
    }

    private var sections: [PopSection] {
        var lines = [PopItem(title: L("The manuscript"), checked: session.piste == nil,
                             subtitle: L("the book’s folder")) { session.enter(nil) }]
        for p in session.openPistes {
            lines.append(PopItem(title: p.name, checked: session.piste?.id == p.id, dot: Ink.piste,
                                 subtitle: session.isTakenBack(p) ? L("taken back") : L("from ") + p.from) { session.enter(p) })
        }
        var actions = [PopItem(title: L("Try something else…")) { app.newPiste = TrackStart() }]
        if let p = session.piste {
            actions.append(PopItem(title: L("Take this track back…")) { app.takingBack = p })
            if session.reference == nil {
                actions.append(PopItem(title: L("Show the manuscript beside")) { session.showBeside("") })
            }
        }
        actions.append(PopItem(title: L("Set a milestone…")) { app.newJalon = TrackStart() })
        actions.append(PopItem(title: L("The book’s history…")) { app.showStory = true })
        return [PopSection(title: L("Where I write"), items: lines), PopSection(items: actions)]
    }
}

// MARK: New track, new milestone

struct NewPisteSheet: View {
    let session: BookSession
    let start: TrackStart
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var from: String
    /// The open chapter starts blank in the track, the manuscript beside it.
    @State private var blank = false

    init(session: BookSession, start: TrackStart) {
        self.session = session
        self.start = start
        _from = State(initialValue: start.rev)
    }

    /// Where it may start: the given point, the manuscript now, each milestone.
    private var origins: [(rev: String, label: String)] {
        var out = [(rev: start.rev, label: start.label)]
        if start.rev != "HEAD" { out.append(("HEAD", L("the manuscript"))) }
        out += session.jalons.map { ($0.commit, "« \($0.title) »") }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Try something else")).font(.custom("EB Garamond", size: 26))
            Text(L("A track is a parallel draft. Write in it freely; the manuscript doesn’t move. Later, take back what works, paragraph by paragraph — or put the track away."))
                .font(.ui(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("What you’re trying")).font(.ui(12, .medium))
                TextField(L("Without the father"), text: $name).textFieldStyle(.roundedBorder).font(.ui(14))
                    .onSubmit(open)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Starting from")).font(.ui(12, .medium))
                Picker("", selection: $from) {
                    ForEach(origins, id: \.rev) { o in Text(o.label).tag(o.rev) }
                }
                .labelsHidden().pickerStyle(.radioGroup)
                if let ch = session.selectedChapter {
                    Toggle(L("« \(ch.title) » starts on a blank page"), isOn: $blank)
                        .font(.ui(13)).padding(.top, 4)
                }
            }
            Text(L("The manuscript opens beside it, read-only."))
                .font(.ui(12)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
                Button(L("Open the Track"), action: open).buttonStyle(.ink)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28).frame(width: 520)
    }

    private func open() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let label = origins.first { $0.rev == from }?.label ?? start.label
        session.newPiste(named: name, from: from, fromLabel: label, opening: blank ? session.blankPage : nil)
        dismiss()
    }
}

struct JalonSheet: View {
    let session: BookSession
    let start: TrackStart
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "flag").foregroundStyle(Ink.jalon)
                Text(L("Set a milestone")).font(.custom("EB Garamond", size: 26))
            }
            Text((start.rev == "HEAD" ? L("A milestone marks a state of the book you’ll want to come back to: a submission, a reading, the end of a draft. It keeps every chapter as it is today.") : L("A milestone marks a state of the book you’ll want to come back to: a submission, a reading, the end of a draft. It keeps every chapter as it was then.")))
                .font(.ui(13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Name")).font(.ui(12, .medium))
                TextField(L("Sent to the publisher"), text: $title).textFieldStyle(.roundedBorder).font(.ui(14))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(L("A note for later (optional)")).font(.ui(12, .medium))
                TextEditor(text: $note).font(.ui(13)).frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.hairline))
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
                Button(L("Set the Milestone")) {
                    session.addJalon(title: title, note: note.trimmingCharacters(in: .whitespacesAndNewlines), at: start.rev)
                    dismiss()
                }
                .buttonStyle(.ink).disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(28).frame(width: 520)
    }
}

// MARK: Taking a track back

/// The manuscript and the track side by side, the whole chapter or the differences in context;
/// each paragraph that differs is kept from one side, the other, or both.
struct TakeBackView: View {
    let session: BookSession
    var piste: Piste? = nil
    /// A past state, instead of a track.
    var point: BringPoint? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("fontName") private var fontName = Typefaces.manuscript
    @AppStorage("fontSize") private var fontSize = 17.0
    @State private var chapters: [BookSession.MergeChapter] = []
    @State private var picks: [String: [Int: ParagraphMerge.Pick]] = [:]
    @State private var current: String?
    @State private var whole = true
    @State private var loaded = false

    private var chapter: BookSession.MergeChapter? { chapters.first { $0.id == current } ?? chapters.first }
    private var sourceName: String { piste?.name ?? point?.label ?? "" }
    private func left(_ c: BookSession.MergeChapter) -> Int { c.blocks.filter { $0.isChange && picks[c.id]?[$0.id] == nil }.count }
    private var remaining: Int { chapters.reduce(0) { $0 + left($1) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if chapters.isEmpty {
                VStack(spacing: 8) {
                    Text(L("Nothing to bring")).font(.custom("EB Garamond", size: 22))
                    Text(L("Both sides say the same thing.")).font(.ui(13)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                tabs
                Divider()
                columnsHeader
                Divider()
                if let c = chapter { body(of: c) }
            }
        }
        .frame(minWidth: 1100, idealWidth: 1300, minHeight: 720, idealHeight: 860)
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            guard !loaded else { return }
            chapters = piste.map { session.prepareTakeBack($0) } ?? point.map { session.prepareBring(rev: $0.rev, base: $0.base, chapters: $0.chapters) } ?? []
            for c in chapters {
                picks[c.id] = Dictionary(uniqueKeysWithValues: c.blocks.compactMap { b in b.suggested.map { (b.id, $0) } })
            }
            current = chapters.first?.id
            loaded = true
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Bring « \(sourceName) » into the manuscript")).font(.custom("EB Garamond", size: 22))
                Text(chapters.isEmpty ? " " : remaining == 0
                     ? L("Everything is chosen · what only one side changed was chosen for you; change it if you like")
                     : L("\(remaining) paragraphs left to choose · what only one side changed is already chosen"))
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Cancel")) { dismiss() }.buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
            if !chapters.isEmpty {
                if let c = chapter {
                    Button(L("Keep the manuscript here")) {
                        for b in c.blocks where b.isChange { picks[c.id, default: [:]][b.id] = .mine }
                    }
                    .buttonStyle(.inkSecondary)
                    .help(L("Nothing changes in this chapter"))
                }
                Button(L("Take All from Here")) {
                    for c in chapters { for b in c.blocks where b.isChange { picks[c.id, default: [:]][b.id] = .theirs } }
                }
                .buttonStyle(.inkSecondary)
            }
            Button(remaining == 0 ? L("Bring into the Manuscript") : L("\(remaining) left to choose")) {
                var out: [String: String] = [:]
                for c in chapters { out[c.id] = ParagraphMerge.result(c.blocks, picks: picks[c.id] ?? [:]) }
                if let piste { session.takeBack(piste, chapters: out) }
                else { session.applyBring(out, message: "musset: bring from \(sourceName)") }
                dismiss()
            }
            .buttonStyle(.ink).disabled(!loaded || remaining > 0)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(chapters) { c in
                        Button { current = c.id } label: {
                            HStack(spacing: 6) {
                                Text(c.title)
                                let n = left(c)
                                Text(n == 0 ? "✓" : "\(n)").foregroundStyle(n == 0 ? Color.green : Ink.piste)
                            }
                            .font(.ui(12)).padding(.horizontal, 10).frame(height: 26)
                            .background(c.id == chapter?.id ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Segmented(options: [(true, L("Whole chapter", ctx: "Chapitre entier")), (false, L("In context"))], selection: $whole)
                .frame(width: 260)
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
    }

    private var columnsHeader: some View {
        HStack(spacing: 20) {
            Text(L("The manuscript")).frame(maxWidth: .infinity, alignment: .leading)
            Text(L("Keep")).frame(width: 120)
            Text(sourceName).lineLimit(1).foregroundStyle(Ink.piste).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.ui(11, .semibold)).foregroundStyle(.secondary).textCase(.uppercase)
        .padding(.horizontal, 32).padding(.vertical, 10)
    }

    private var prose: Font { .custom(fontName, size: fontSize) }

    private func body(of c: BookSession.MergeChapter) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(c.blocks.enumerated()), id: \.element.id) { i, b in
                    if b.isChange { change(b, in: c) }
                    else { same(b.same, first: i == 0, last: i == c.blocks.count - 1) }
                }
            }
            .padding(.horizontal, 32).padding(.vertical, 20)
        }
        .id(c.id)
    }

    @ViewBuilder private func same(_ paragraphs: [String], first: Bool, last: Bool) -> some View {
        if whole || paragraphs.count <= 2 {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in sameRow(p) }
        } else {
            let head = first ? [] : [paragraphs[0]]
            let tail = last ? [] : [paragraphs[paragraphs.count - 1]]
            let hidden = paragraphs.count - head.count - tail.count
            ForEach(Array(head.enumerated()), id: \.offset) { _, p in sameRow(p) }
            if hidden > 0 {
                Button { whole = true } label: {
                    Text(L("\(hidden) identical paragraphs · show all"))
                        .font(.ui(12)).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.vertical, 10)
                        .overlay(alignment: .top) { Divider() }.overlay(alignment: .bottom) { Divider() }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).padding(.vertical, 8)
            }
            ForEach(Array(tail.enumerated()), id: \.offset) { _, p in sameRow(p) }
        }
    }

    private func sameRow(_ p: String) -> some View {
        HStack(alignment: .top, spacing: 20) {
            paragraph(p).foregroundStyle(.secondary).padding(.horizontal, 13)
            Text("=").font(.ui(12)).foregroundStyle(.quaternary).frame(width: 120).padding(.top, 4)
            paragraph(p).foregroundStyle(.secondary).padding(.horizontal, 13)
        }
        .padding(.vertical, 4)
    }

    private func change(_ b: ParagraphMerge.Block, in c: BookSession.MergeChapter) -> some View {
        let pick = picks[c.id]?[b.id]
        let keepL = pick == .mine || pick == .both, keepR = pick == .theirs || pick == .both
        return HStack(alignment: .top, spacing: 20) {
            side(b.mine, kept: keepL, dropped: pick != nil && !keepL, tint: .primary, empty: L("(nothing here in the manuscript)"))
            VStack(spacing: 6) {
                if b.conflict {
                    Text(L("Changed on both sides")).font(.ui(11)).foregroundStyle(Ink.jalon).multilineTextAlignment(.center)
                }
                choice(L("← This one"), on: pick == .mine) { picks[c.id, default: [:]][b.id] = .mine }
                choice(L("That one →"), on: pick == .theirs, tint: Ink.piste) { picks[c.id, default: [:]][b.id] = .theirs }
                choice(L("Both"), on: pick == .both) { picks[c.id, default: [:]][b.id] = .both }
            }
            .frame(width: 120).padding(.top, 6)
            side(b.theirs, kept: keepR, dropped: pick != nil && !keepR, tint: Ink.piste, empty: L("(nothing here on that side)"))
        }
        .padding(.vertical, 10)
    }

    private func side(_ paragraphs: [String], kept: Bool, dropped: Bool, tint: Color, empty: String) -> some View {
        VStack(alignment: .leading, spacing: fontSize * 0.7) {
            if paragraphs.isEmpty { Text(empty).font(.ui(12)).italic().foregroundStyle(.tertiary) }
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, p in paragraph(p) }
        }
        .foregroundStyle(dropped ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kept ? tint.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(kept ? tint.opacity(0.7) : Ink.hairline))
    }

    private func paragraph(_ p: String) -> some View {
        Text(p.isEmpty ? " " : p.replacingOccurrences(of: String(ParagraphCodec.lineBreak), with: "\n"))
            .font(prose).lineSpacing(fontSize * 0.55)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    private func choice(_ title: String, on: Bool, tint: Color = .primary, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.ui(12)).frame(maxWidth: .infinity).frame(height: 30)
                .background(on ? tint.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(on ? tint.opacity(0.8) : Ink.hairline))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
