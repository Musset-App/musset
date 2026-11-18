import SwiftUI

/// The card on a name in the text: who it is, how much they're in the book, and the way to their sheet.
struct NameCard: View {
    let path: String
    let session: BookSession
    let open: () -> Void
    let rename: () -> Void

    var body: some View {
        if let entry = session.bible.entry(path: path) {
            let chapters = session.bible.occurrences[path]?.count ?? 0
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.title).font(.system(size: 17, design: .serif))
                    Spacer()
                    Text(session.bible.tier(of: entry).label).font(.ui(11)).foregroundStyle(.secondary)
                }
                Text(session.words.count(chapters, .piece) + " · " + L("\(session.bible.presence(path)) times")).font(.ui(11)).foregroundStyle(.secondary)
                if let line = Self.summary(of: entry) {
                    Text(line).font(.ui(12)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Button(L("Open the sheet"), action: open)
                    Button(L("Rename…"), action: rename)
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
        }
    }

    /// The first thing the sheet says: its opening line, or its first filled field.
    static func summary(of entry: BibleEntry) -> String? {
        if let line = entry.body.split(separator: "\n").map({ BibleLinks.plain(String($0)).trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty }) {
            return line
        }
        return entry.fields.first { !$0.value.isEmpty }.map { "\($0.name): \($0.value)" }
    }
}

/// « Odile joins the cast, as an extra »: shown a moment beside the text when a new name gets its sheet.
struct NameJoinedNotice: View {
    let spotter: NameSpotter
    let open: (String) -> Void

    var body: some View {
        if let joined = spotter.joined {
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(Ink.accent).frame(width: 6, height: 6).padding(.top, 5)
                VStack(alignment: .leading, spacing: 4) {
                    Text(joined.kind == .place ? L("\(joined.title) joins the places.") : L("\(joined.title) joins the cast, as an extra."))
                        .font(.ui(12)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 10) {
                        Button(L("See")) { open(joined.path); spotter.joined = nil }
                            .buttonStyle(.link)
                        Button(L("Not a name")) { spotter.notAName(joined.path) }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    .font(.ui(12))
                }
            }
            .frame(width: 170, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: Radius.control).fill(Ink.side))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
            .transition(.opacity)
            .task(id: joined) {
                try? await Task.sleep(for: .seconds(9))
                if spotter.joined == joined { withAnimation { spotter.joined = nil } }
            }
        }
    }
}

/// « What the book says »: the facts the chapters state about a character or a place, each with its words and its
/// chapter, and where the book disagrees with itself. Kept by Musset; the author's sheet stays theirs.
struct BookSaysView: View {
    let app: AppState
    let session: BookSession
    let path: String

    private var keeper: BibleKeeper { session.keeper }

    var body: some View {
        let entity = keeper.entity(path)
        let titles = Dictionary(session.manifest.chapters.enumerated().map { ($0.element.id, session.manifest.pieceReference(at: $0.offset)) }, uniquingKeysWith: { a, _ in a })
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("What the book says")).font(.ui(13, .semibold))
                Spacer()
                status
            }
            Text(L("Kept up to date by Musset. Your sheet stays yours.")).font(.ui(11)).foregroundStyle(.secondary)
            if let entity {
                ForEach(entity.contradictions.filter { !$0.dismissed }) { c in contradiction(c, titles: titles) }
                if !entity.aliases.isEmpty {
                    Text(L("Also called \(entity.aliases.map { inQuotes($0) }.listed)")).font(.ui(12)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entity.facts) { f in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(f.text).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            chapterLink(f, titles: titles)
                        }
                        .padding(.vertical, 6)
                        .overlay(alignment: .bottom) { Divider().opacity(0.6) }
                        .help(f.quote)
                    }
                }
            } else if keeper.running == nil {
                Text(L("Musset reads each chapter when you pause, and writes here what it says about them, with its own words."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let error = keeper.lastError { Text(error).font(.ui(11)).foregroundStyle(Ink.warning) }
        }
    }

    @ViewBuilder private var status: some View {
        if let id = keeper.running {
            Text(L("Reading « \(session.manifest.chapters.first { $0.id == id }?.title ?? id) »…")).font(.ui(11)).foregroundStyle(.secondary)
        } else if let stale = session.manifest.chapters.first(where: { keeper.stale($0.id) }), BibleKeeper.enabled {
            Button(L("Read again")) { keeper.read(stale.id) }.buttonStyle(.link).font(.ui(11))
        }
    }

    private func contradiction(_ c: BookFacts.Contradiction, titles: [String: String]) -> some View {
        let a = keeper.facts.fact(c.a, of: path), b = keeper.facts.fact(c.b, of: path)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("Continuity")).font(.ui(11, .semibold)).foregroundStyle(Ink.critique)
            Text(c.why).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
            ForEach([a, b].compactMap { $0 }) { f in
                HStack(alignment: .firstTextBaseline) {
                    Text("« \(f.quote) »").font(.uiMono(11)).foregroundStyle(.secondary).lineLimit(2)
                    Spacer(minLength: 4)
                    chapterLink(f, titles: titles)
                }
            }
            Button(L("On purpose")) { keeper.dismiss(c, of: path) }.buttonStyle(.link).font(.ui(11))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Ink.critique.opacity(0.08)))
    }

    private func chapterLink(_ f: BookFacts.Fact, titles: [String: String]) -> some View {
        Button(titles[f.chapter] ?? f.chapter) { go(to: f) }
            .buttonStyle(.link).font(.ui(11))
            .help(session.manifest.chapters.first { $0.id == f.chapter }?.title ?? "")
    }

    /// Opens the chapter on the quoted words.
    private func go(to f: BookFacts.Fact) {
        app.showChapter()
        session.open(f.chapter)
        session.pendingSelection = ReadingCheck.locate(f.quote, in: session.text)
    }
}
