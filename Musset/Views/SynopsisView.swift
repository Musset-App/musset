import SwiftUI

/// Overview ▸ Synopsis. The book's synopsis, written by the author alone, beside the plan chapter by chapter: the written chapters with
/// their status and what each is for, then the chapters still to write. The debate judges the book against it.
struct SynopsisView: View {
    let app: AppState
    @Bindable var session: BookSession
    @State private var draft = ""
    @State private var saveTask: Task<Void, Never>?
    @AppStorage("fontName") private var fontName = Typefaces.manuscript

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Synopsis")).font(.system(size: 28, design: .serif))
                    Text(L("Yours alone: the debate reads it, Musset never writes in it.")).font(.ui(12)).foregroundStyle(.secondary)
                    TextEditor(text: $draft)
                        .font(.custom(fontName, size: 16))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 420)
                        .padding(.top, 16)
                        .accessibilityLabel(L("Synopsis"))
                        .onChange(of: draft) { _, _ in scheduleSave() }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, 48).padding(.top, 40)
                .frame(maxWidth: .infinity)
            }
            Divider()
            PlanColumn(app: app, session: session).frame(width: 400)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear { draft = session.plot.synopsis ?? "" }
        .onDisappear { save() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(for: .seconds(0.8)); if !Task.isCancelled { save() } }
    }

    private func save() {
        let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t != (session.plot.synopsis ?? "") else { return }
        session.plot.synopsis = t.isEmpty ? nil : t
        session.savePlot()
    }
}

/// Chapter by chapter: what each written chapter is for, and the ones still to write.
private struct PlanColumn: View {
    let app: AppState
    @Bindable var session: BookSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(session.words.pieceByPiece).font(.ui(13, .semibold))
                    Spacer()
                    Button(session.words.plannedPiece) { session.addPlanned(session.words.newPiece) }.buttonStyle(.link).font(.ui(12))
                }
                .padding(.bottom, 8)
                ForEach(Array(session.manifest.chapters.enumerated()), id: \.element.id) { i, ch in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(session.manifest.pieceMark(at: i)).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 16, alignment: .trailing)
                            Button(session.manifest.shownTitle(of: ch)) { app.showChapter(); session.open(ch.id) }.buttonStyle(.plain).font(.ui(13, .medium))
                            Spacer()
                            Circle().fill((ch.status ?? .draft).dot).frame(width: 6, height: 6)
                            Text((ch.status ?? .draft).label).font(.ui(11)).foregroundStyle(.secondary)
                        }
                        ChapterSynopsisField(session: session, chapter: ch.id)
                            .font(.uiMono(12)).foregroundStyle(.secondary).padding(.leading, 24)
                    }
                    .padding(.vertical, 10)
                    .overlay(alignment: .bottom) { Divider().opacity(0.6) }
                }
                ForEach(session.plot.planned ?? []) { p in planned(p) }
                if let hint = session.synopsisHint {
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(Ink.accent).frame(width: 6, height: 6).padding(.top, 5)
                        Text(hint).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: Radius.control).fill(Ink.panel))
                    .padding(.top, 14)
                }
            }
            .padding(20)
        }
        .background(Ink.side)
    }

    private func planned(_ p: PlotGrid.Planned) -> some View {
        let index = session.manifest.nextPieceMark(ahead: session.plot.planned?.firstIndex(of: p) ?? 0)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(index).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary).frame(minWidth: 16, alignment: .trailing)
                TextField(L("Title"), text: Binding(get: { p.title }, set: { session.updatePlanned(p.id, title: $0) }))
                    .textFieldStyle(.plain).font(.ui(13, .medium)).foregroundStyle(.secondary)
                Spacer()
                Text(L("planned")).font(.ui(11)).foregroundStyle(.tertiary)
                Button { session.removePlanned(p.id) } label: { Image(systemName: "xmark").font(.ui(9)) }
                    .buttonStyle(.plain).foregroundStyle(.tertiary).accessibilityLabel(L("Remove"))
            }
            TextField(L("What this chapter will do"), text: Binding(get: { p.synopsis }, set: { session.updatePlanned(p.id, synopsis: $0) }), axis: .vertical)
                .textFieldStyle(.plain).font(.uiMono(12)).foregroundStyle(.secondary).padding(.leading, 24)
            Button(L("Start writing")) { app.showChapter(); session.startWriting(p.id) }
                .buttonStyle(.link).font(.ui(12)).padding(.leading, 24)
        }
        .padding(.vertical, 10)
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(Ink.hairline))
        .padding(.top, 8)
    }
}

extension BookSession {
    func addPlanned(_ title: String) {
        plot.planned = (plot.planned ?? []) + [PlotGrid.Planned(title: title)]
        savePlot()
    }

    func updatePlanned(_ id: String, title: String? = nil, synopsis: String? = nil) {
        guard var list = plot.planned, let i = list.firstIndex(where: { $0.id == id }) else { return }
        if let title { list[i].title = title }
        if let synopsis { list[i].synopsis = synopsis }
        plot.planned = list
        savePlot()
    }

    func removePlanned(_ id: String) {
        plot.planned = plot.planned?.filter { $0.id != id }
        if plot.planned?.isEmpty == true { plot.planned = nil }
        savePlot()
    }

    /// The planned chapter becomes a real one, at the end of the book, with what it was meant to do as its synopsis.
    func startWriting(_ id: String) {
        guard let p = plot.planned?.first(where: { $0.id == id }) else { return }
        removePlanned(id)
        addChapter(title: p.title.isEmpty ? words.newPiece : p.title)
        if let new = manifest.chapters.last, !p.synopsis.isEmpty {
            plot.setChapterSynopsis(new.id, p.synopsis)
            savePlot()
        }
    }

    /// A main or secondary character the plan never names: worth a look, never written in for the author.
    var synopsisHint: String? {
        let plan = ([plot.synopsis ?? ""] + Array((plot.chapterSynopses ?? [:]).values) + (plot.planned ?? []).flatMap { [$0.title, $0.synopsis] })
            .joined(separator: "\n")
        guard !plan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let missing = bible.entries.filter { $0.kind == .character && bible.tier(of: $0) != .extra }
            .filter { e in NameMatcher(names: [(e.path, e.names)]).matches(in: plan).isEmpty }
            .sorted { bible.presence($0.path) > bible.presence($1.path) }
        guard let first = missing.first else { return nil }
        return L("\(first.title) is in \(bible.occurrences[first.path]?.count ?? 0) chapters, and the plan doesn’t mention them yet.")
    }
}
