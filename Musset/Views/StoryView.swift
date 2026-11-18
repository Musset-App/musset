import SwiftUI

/// The book's history as a writer sees it: the manuscript as a line of sittings, tracks leaving it and
/// coming back, milestones as flags. Pick a sitting to see what changed, compare, or start from there.
/// A tab like the others (the History tab's wide view): it opens beside a chapter, and it is where one
/// goes from the manuscript to a track and back.
struct StoryView: View {
    let app: AppState
    let session: BookSession
    @AppStorage("fontName") private var fontName = Typefaces.manuscript
    @State private var points: [GitService.Point] = []
    @State private var lanes: [Lane] = []
    @State private var selection: Selection?
    /// History points shown at once.
    @State private var shownPoints = 200
    @State private var newPiste: TrackStart?
    @State private var newJalon: TrackStart?
    @State private var compare: CompareItem?
    @State private var renaming: Piste?
    @State private var newName = ""
    private static let wide: CGFloat = 1040

    enum Selection: Hashable { case point(String), jalon(String) }

    /// A track on the frieze: its own commits, where it left the manuscript, where it came back.
    struct Lane: Identifiable {
        let piste: Piste
        let dates: [Date]
        let start: Date
        let end: Date
        let back: Date?
        var id: String { piste.id }
    }

    var body: some View {
        // The pane's own width, whatever the content would like: under `wide`, what the selection holds goes below.
        GeometryReader { geo in
            let width = geo.size.width
            if width >= Self.wide {
                HStack(spacing: 0) {
                    sidebar.frame(width: 250)
                    Divider()
                    middle
                    Divider()
                    detail.frame(width: 340)
                }
            } else {
                // A narrow pane (beside a chapter): the places on the left, the selection under the sittings.
                let side = min(220, max(160, width * 0.34))
                HStack(spacing: 0) {
                    sidebar.frame(width: side)
                    Divider()
                    // Held to the room there is: the frieze and the rows are cut rather than pushing the pane wider.
                    VStack(spacing: 0) {
                        middle
                        Divider()
                        detail.frame(height: 300)
                    }
                    .frame(width: max(120, width - side - 1), alignment: .leading)
                    .clipped()
                }
            }
        }
        .onAppear(perform: reload)
        // A track started, put away or entered elsewhere (the History tab, the command bar), a milestone set.
        .onChange(of: session.pistes.count) { _, _ in reload() }
        .onChange(of: session.jalons.count) { _, _ in reload() }
        .onChange(of: session.piste?.id) { _, _ in reload() }
        .sheet(item: $newPiste, onDismiss: reload) { NewPisteSheet(session: session, start: $0) }
        .sheet(item: $newJalon, onDismiss: reload) { JalonSheet(session: session, start: $0) }
        .sheet(item: $compare) { CompareView(item: $0) }
        .alert(L("Rename the track"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("", text: $newName)
            Button("OK") { if let p = renaming { session.renamePiste(p, to: newName); reload() }; renaming = nil }
            Button(L("Cancel"), role: .cancel) { renaming = nil }
        }
    }

    private var middle: some View {
        VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) { title; hint; Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 2) { title; hint }
            }
            Frieze(points: points, lanes: lanes, jalons: session.jalons, selection: $selection)
                .frame(height: 70 + CGFloat(max(1, lanes.count)) * 34)
                .padding(16)
                .background(Ink.panel.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.card))
            sessions
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var title: some View { Text(L("The Book’s History")).font(.custom("EB Garamond", size: 28)).lineLimit(1) }
    private var hint: some View { Text(L("Each dot is a sitting, saved on its own.")).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1) }

    private func reload() {
        session.flushSave()
        session.refreshTracks()
        let since = Calendar.current.date(byAdding: .day, value: -90, to: Date())
        points = session.git.points("HEAD", since: since, limit: 400)
        lanes = session.pistes.filter { $0.shelved != true }.compactMap { p in
            guard let tip = session.git.resolve(p.branch) else { return nil }
            let own = session.git.points(p.branch, limit: 300).prefix { $0.id != p.start }
            let back = points.first { $0.parents.count > 1 && $0.parents[1] == tip }?.date
            let end = session.piste?.id == p.id ? Date() : (own.first?.date ?? p.created)
            return Lane(piste: p, dates: own.map(\.date), start: p.created, end: max(end, p.created), back: back)
        }
        if selection == nil, let first = points.first { selection = .point(first.id) }
    }

    // MARK: Left: where I write, milestones

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    heading(L("Where I write"))
                    place(L("The manuscript"), detail: session.bookCounts.label, tint: .primary, on: session.piste == nil) { session.enter(nil) }
                    ForEach(session.openPistes) { p in
                        place(p.name, detail: session.isTakenBack(p) ? L("brought into the manuscript") : L("from \(p.from)"), tint: Ink.piste, on: session.piste?.id == p.id) {
                            session.enter(p)
                        }
                        .contextMenu {
                            Button(L("Write in It")) { session.enter(p) }
                            Button(L("Bring into the Manuscript…")) { app.takingBack = p }
                            Button(L("Rename…")) { newName = p.name; renaming = p }
                            Divider()
                            Button(L("Put Away")) { session.shelve(p); reload() }
                        }
                    }
                    // On a track: the manuscript read beside it (the title bar's menu held this).
                    if session.piste != nil, session.reference == nil {
                        Button { session.showBeside(""); app.showChapter() } label: {
                            Text(L("Show the manuscript beside")).font(.ui(12)).foregroundStyle(Ink.piste).padding(.horizontal, 10).padding(.top, 2)
                        }
                        .buttonStyle(.plain)
                    }
                    Button { newPiste = TrackStart() } label: {
                        Text("+ " + L("New Track…")).font(.ui(12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).frame(height: 32)
                            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [3])))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).padding(.top, 4)
                    let shelved = session.pistes.filter { $0.shelved == true }
                    if !shelved.isEmpty {
                        Menu(L("\(shelved.count) put away")) {
                            ForEach(shelved) { p in Button(p.name) { session.shelve(p, false); reload() } }
                        }
                        .menuStyle(.borderlessButton).font(.ui(11)).foregroundStyle(.secondary).fixedSize().padding(.top, 2)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    heading(L("Milestones"))
                    if session.jalons.isEmpty {
                        Text(L("None yet.")).font(.ui(12)).foregroundStyle(.tertiary).padding(.horizontal, 10)
                    }
                    ForEach(session.jalons) { j in
                        Button { selection = .jalon(j.id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "flag").font(.ui(11)).foregroundStyle(Ink.jalon)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(j.title).font(.ui(13)).lineLimit(1)
                                    Text(j.date.formatted(.dateTime.day().month(.abbreviated).year().locale(UILang.locale))).font(.ui(11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(selection == .jalon(j.id) ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    Button { newJalon = TrackStart() } label: {
                        Text("+ " + L("Set a Milestone…")).font(.ui(12)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Ink.side)
    }

    private func heading(_ s: String) -> some View {
        SectionLabel(s).padding(.horizontal, 10).padding(.bottom, 4)
    }

    private func place(_ title: String, detail: String, tint: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().strokeBorder(tint, lineWidth: 2).background(Circle().fill(on ? tint : .clear)).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.ui(13, .medium)).lineLimit(1)
                    Text(detail).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(on ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Middle: sessions

    private var sessions: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(L("In the manuscript"))
            if points.isEmpty {
                Text(L("No history in the last three months.")).font(.ui(12)).foregroundStyle(.tertiary)
            }
            ScrollView {
                // Eager and bounded, like the history's list (a LazyVStack spun forever in SwiftUI's prefetch).
                VStack(spacing: 2) {
                    ForEach(points.prefix(shownPoints)) { p in
                        Button { selection = .point(p.id) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 14) {
                                Text(p.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute().locale(UILang.locale)))
                                    .font(.ui(12)).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                                if p.parents.count > 1 { Image(systemName: "arrow.triangle.merge").font(.ui(11)).foregroundStyle(Ink.piste) }
                                Text(Self.describe(p.subject, session: session)).font(.ui(13)).lineLimit(1)
                                Spacer()
                                if let j = session.jalons.first(where: { $0.commit == p.id }) {
                                    Label(j.title, systemImage: "flag").font(.ui(11)).foregroundStyle(Ink.jalon).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(selection == .point(p.id) ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.control))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if points.count > shownPoints {
                        Button(L("Show older")) { shownPoints += 200 }.buttonStyle(.link).font(.ui(12)).padding(12)
                    }
                }
            }
        }
    }

    /// « musset: edit 07_marx_dormoy » → « Marx Dormoy ».
    static func describe(_ subject: String, session: BookSession) -> String {
        let body = subject.hasPrefix("musset: ") ? String(subject.dropFirst(8)) : subject
        if body.hasPrefix("edit ") {
            let id = String(body.dropFirst(5))
            return session.manifest.chapters.first { $0.id == id }?.title ?? (id.isEmpty ? L("Writing") : id)
        }
        if body == "snapshot" { return L("Saved by hand") }
        return body
    }

    // MARK: Right: what the selection holds

    @ViewBuilder private var detail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                switch selection {
                case .point(let id): if let p = points.first(where: { $0.id == id }) { PointDetail(point: p, session: session, fontName: fontName, compare: $compare, newPiste: $newPiste, newJalon: $newJalon) }
                case .jalon(let id): if let j = session.jalons.first(where: { $0.id == id }) {
                    JalonDetail(jalon: j, session: session, newPiste: $newPiste, selection: $selection, reload: reload) {
                        app.exportAt = j
                        app.showExport = true
                    }
                }
                case nil: EmptyView()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Ink.side)
    }
}

/// The manuscript line with its sessions, the tracks under it, the milestones above.
private struct Frieze: View {
    let points: [GitService.Point]
    let lanes: [StoryView.Lane]
    let jalons: [GitService.Tag]
    @Binding var selection: StoryView.Selection?

    var body: some View {
        let start = ([points.last?.date] + lanes.map(\.start) + [Calendar.current.date(byAdding: .day, value: -14, to: Date())]).compactMap { $0 }.min() ?? Date()
        let span = max(3600, Date().timeIntervalSince(start))
        GeometryReader { geo in
            let labelW: CGFloat = 130
            let w = geo.size.width - labelW - 16
            let x = { (d: Date) -> CGFloat in labelW + CGFloat(d.timeIntervalSince(start) / span) * w }
            let mainY: CGFloat = 36
            ZStack(alignment: .topLeading) {
                Text(L("The manuscript")).font(.ui(12, .medium)).position(x: 56, y: mainY)
                Path { p in p.move(to: CGPoint(x: labelW, y: mainY)); p.addLine(to: CGPoint(x: labelW + w, y: mainY)) }
                    .stroke(Color.secondary.opacity(0.5), lineWidth: 2)
                ForEach(Array(lanes.enumerated()), id: \.element.id) { i, lane in
                    let y = mainY + 34 * CGFloat(i + 1)
                    Text(lane.piste.name).font(.ui(12)).foregroundStyle(Ink.piste).lineLimit(1).frame(width: labelW - 10, alignment: .leading).position(x: (labelW - 10) / 2, y: y)
                    Path { p in
                        p.move(to: CGPoint(x: x(lane.start), y: mainY))
                        p.addLine(to: CGPoint(x: x(lane.start), y: y))
                        p.addLine(to: CGPoint(x: x(lane.back ?? lane.end), y: y))
                        if let back = lane.back { p.addLine(to: CGPoint(x: x(back), y: mainY)) }
                    }
                    .stroke(Ink.piste, lineWidth: 2)
                    ForEach(Array(lane.dates.enumerated()), id: \.offset) { _, d in
                        Circle().fill(Ink.piste).frame(width: 7, height: 7).position(x: x(d), y: y)
                    }
                }
                ForEach(points) { p in
                    let on = selection == .point(p.id)
                    Circle().fill(on ? Color.primary : Color.secondary)
                        .frame(width: on ? 11 : 7, height: on ? 11 : 7)
                        .position(x: x(p.date), y: mainY)
                        .onTapGesture { selection = .point(p.id) }
                        .help(p.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(UILang.locale)))
                }
                ForEach(jalons.filter { $0.date >= start }) { j in
                    HStack(spacing: 3) {
                        Image(systemName: "flag.fill").font(.ui(9))
                        Text(j.title).font(.ui(10)).lineLimit(1)
                    }
                    .foregroundStyle(Ink.jalon)
                    .fixedSize()
                    .position(x: min(x(j.date) + 30, geo.size.width - 60), y: 8)
                    .onTapGesture { selection = .jalon(j.id) }
                }
            }
        }
    }
}

private struct PointDetail: View {
    let point: GitService.Point
    let session: BookSession
    let fontName: String
    @Binding var compare: CompareItem?
    @Binding var newPiste: TrackStart?
    @Binding var newJalon: TrackStart?

    private var chapters: [ChapterEntry] {
        let paths = Set(session.git.changedPaths(point.id))
        return session.manifest.chapters.filter { paths.contains($0.file) }
    }

    var body: some View {
        let parent = point.parents.first
        let touched = chapters
        let deltas = touched.map { ch -> (ChapterEntry, Int, Int) in
            let before = parent.flatMap { session.git.show($0, path: ch.file) } ?? ""
            let after = session.git.show(point.id, path: ch.file) ?? ""
            let s = WordDiff.stats(Diff.words(before, after))
            return (ch, s.added, s.removed)
        }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(point.date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute().locale(UILang.locale))).font(.ui(12)).foregroundStyle(.secondary)
                Text(StoryView.describe(point.subject, session: session)).font(.custom("EB Garamond", size: 22))
                let added = deltas.reduce(0) { $0 + $1.1 }, removed = deltas.reduce(0) { $0 + $1.2 }
                if !deltas.isEmpty {
                    Text("+\(added.ui) / −\(removed.ui) " + L("words") + " · " + session.words.count(deltas.count, .piece))
                        .font(.ui(12)).foregroundStyle(.secondary)
                }
            }
            if let (ch, _, _) = deltas.first {
                let before = parent.flatMap { session.git.show($0, path: ch.file) } ?? ""
                let after = session.git.show(point.id, path: ch.file) ?? ""
                Text(WordDiff.attributed(Self.excerpt(Diff.words(before, after))))
                    .font(.custom(fontName, size: 13)).lineSpacing(4)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control))
                    .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
                    .textSelection(.enabled)
            }
            VStack(alignment: .leading, spacing: 8) {
                if let ch = touched.first {
                    Button(L("Compare with Today")) {
                        session.flushSave()
                        compare = CompareItem(title: "\(ch.title) · \(point.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(UILang.locale))) → " + L("today"),
                                              left: session.git.show(point.id, path: ch.file) ?? "", right: session.store.read(ch))
                    }
                    .buttonStyle(.inkSecondary)
                }
                Button(L("Start a Track from Here…")) {
                    newPiste = TrackStart(rev: point.id, label: L("the sitting of \(point.date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(UILang.locale)))"))
                }
                .buttonStyle(.inkSecondary)
                Button(L("Set a Milestone Here…")) { newJalon = TrackStart(rev: point.id) }
                    .buttonStyle(.inkSecondary)
            }
            Text(L("Nothing is ever erased: going back opens a track, the manuscript stays as it is."))
                .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Only the paragraphs that changed, a few of them.
    static func excerpt(_ diff: String) -> String {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: true).filter { $0.contains("[-") || $0.contains("{+") }
        let shown = lines.prefix(4).map { $0.count > 600 ? String($0.prefix(600)) + "…" : String($0) }
        return "@@\n" + shown.joined(separator: "\n\n") + (lines.count > 4 ? "\n\n…" : "")
    }
}

private struct JalonDetail: View {
    let jalon: GitService.Tag
    let session: BookSession
    @Binding var newPiste: TrackStart?
    @Binding var selection: StoryView.Selection?
    let reload: () -> Void
    let export: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        let rows = session.manifest.chapters.compactMap { ch -> (ChapterEntry, Int, Int)? in
            let before = session.git.show(jalon.commit, path: ch.file) ?? ""
            let s = WordDiff.stats(Diff.words(before, session.store.read(ch)))
            return s.added + s.removed == 0 ? nil : (ch, s.added, s.removed)
        }
        let added = rows.reduce(0) { $0 + $1.1 }, removed = rows.reduce(0) { $0 + $1.2 }
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(jalon.date.formatted(.dateTime.day().month(.wide).year().locale(UILang.locale)), systemImage: "flag").font(.ui(12)).foregroundStyle(Ink.jalon)
                Text(jalon.title).font(.custom("EB Garamond", size: 22))
                if !jalon.note.isEmpty { Text(jalon.note).font(.ui(12)).foregroundStyle(.secondary) }
            }
            SectionLabel(L("Since then, in the manuscript"))
            HStack(spacing: 10) {
                stat("+\(added.ui)", L("words written"), Ink.added)
                stat("−\(removed.ui)", L("words cut"), Ink.removed)
                stat("\(rows.count)", session.words.usual(.piece) ? L("chapters") : session.words.plural(.piece).lowercased(), .primary)
            }
            VStack(spacing: 2) {
                ForEach(rows, id: \.0.id) { ch, a, r in
                    HStack {
                        Text(ch.title).font(.ui(12)).lineLimit(1)
                        Spacer()
                        Text("+\(a.ui) / −\(r.ui)").font(.uiMono(11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Button(L("Start a Track from This Milestone…")) {
                    newPiste = TrackStart(rev: jalon.commit, label: inQuotes(jalon.title))
                }
                .buttonStyle(.inkSecondary)
                Button(L("Export the Book as It Was…"), action: export).buttonStyle(.inkSecondary)
                Button(L("Remove the Milestone…")) { confirmDelete = true }.buttonStyle(.inkSecondary)
            }
        }
        .confirmationDialog(L("Remove « \(jalon.title) »?"), isPresented: $confirmDelete) {
            Button(L("Remove"), role: .destructive) { session.removeJalon(jalon); selection = nil; reload() }
        } message: {
            Text(L("Only the flag goes: the text stays in the history."))
        }
    }

    private func stat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.ui(18, .medium)).foregroundStyle(tint).monospacedDigit()
            Text(label).font(.ui(11)).foregroundStyle(.secondary)
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.control))
    }
}
