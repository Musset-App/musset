import SwiftUI

/// Musset's stance: the author writes by hand; the AI is a critic and writing partner, never a ghostwriter.
enum WritingPartner {
    /// The earlier version shown beside the editor: the chapter is being rewritten from it.
    static func rewriting(previous: String, text: String) -> String {
        """
        The author is rewriting this chapter from scratch, with an earlier version open beside the new one \
        (version "\(previous)", read-only). The text above is the rewrite, perhaps unfinished. The earlier version:
        <<<
        \(ParagraphCodec.encode(text))
        >>>
        Read the current text as a rewrite of it: compare the two, say what the rewrite gains and what it loses, \
        and what of the earlier version is worth carrying over (or rightly left behind). Judge the rewrite for what \
        it is so far, without counting against it what it has not reached yet. Margin notes quote only the current text.
        """
    }

    /// Appended to every request unless the author has allowed rewrites.
    static let noRewrites = """
    The author writes every word by hand: you are a critic and a writing partner, not a ghostwriter.     Never propose rewritten passages, alternative sentences, replacement wording or "for example you could write…",     not even a few words, and never output a ```revision block. Say what does not work, where, and why;     point at what to look at; ask the questions that help the author find their own words.
    """
}

/// One-click chat requests. Their answers go into the margin as notes; the chat only keeps a short overview.
enum ChatAction: String, CaseIterable, Identifiable, Codable {
    /// In this order on screen: the critique is the strongest tool, and comes first.
    case critique, style, tics, continuity, cuts, openingEnding, facts

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .style: "text.magnifyingglass"
        case .tics: "repeat"
        case .critique: "checklist"
        case .continuity: "arrow.triangle.branch"
        case .cuts: "scissors"
        case .openingEnding: "text.line.first.and.arrowtriangle.forward"
        case .facts: "magnifyingglass.circle"
        }
    }

    var help: String {
        switch self {
        case .style: L("Style, repetitions, inconsistencies, clichés, telling instead of showing — as margin notes")
        case .tics: L("The book's grid of tics: a pattern search finds the candidates, the AI applies each family's test")
        case .critique: L("A blind AI reading with the book's rubric, outside this conversation: a score per criterion, proof from the text, reservations pinned to their passages")
        case .continuity: L("Contradictions with the other chapters (dates, ages, names, places), scenes told twice")
        case .cuts: L("Passages that can go without loss")
        case .openingEnding: L("Does the first paragraph open the chapter, does the last one land it?")
        case .facts: L("Names, dates, places, quotations to verify")
        }
    }

    var defaultKind: Note.Kind {
        switch self {
        case .facts: .fact
        case .continuity: .continuity
        case .tics: .tic
        default: .critique
        }
    }

    /// The request sent to the agent (the chapter text is added by the chat itself).
    @MainActor
    func prompt(book: BookSession, selection: String) -> String {
        let language = book.manifest.lang.hasPrefix("fr") ? "French" : "English"
        var task: String
        switch self {
        case .style:
            task = """
            Analyse the chapter's style and problems: repetitions of words and of ideas (say where the other occurrence is), \
            inconsistencies inside the chapter (time, place, who knows what), clichés, sentences that explain what the scene \
            already shows, rhythm breaks, tics, vague or weak wording. Tags: [Redite], [Incohérence], [Cliché], [Explication], [Rythme], [Flou],             and for tics the family from the book's grid below (\(Tics.tags)), after applying its test.
            GRID:
            \(Tics.load(book.root))
            """
        case .tics:
            task = Tics.instruction(root: book.root, text: selection.isEmpty ? book.text : selection)
        case .critique:
            task = "" // Read blind by ChapterReader, never in the conversation.
        case .continuity:
            let files = book.manifest.chapters.filter { !$0.excludeFromExport }.enumerated()
                .map { "\($0.offset). \($0.element.title) — `\($0.element.file)`" }.joined(separator: "\n")
            task = """
            Check this chapter's continuity with the rest of the book. Before answering, read the other chapters with your \
            Read tool (files in the current directory, in book order):
            \(files)
            Flag what in this chapter contradicts them (dates, ages, names, places, objects, who knows what when) and scenes, \
            images or ideas already told elsewhere. In each note, name the other chapter.\(book.bible.sheetsForReader.isEmpty ? "" : " Check it also against the author's sheets:\n" + book.bible.sheetsForReader + "\n") Tags: [Contradiction], [Déjà dit], [Chronologie].
            """
        case .cuts:
            task = """
            Find what can be cut without loss: passages that explain what the scene already shows, redundant sentences, \
            filler, digressions, a second image that weakens the first. Each note quotes the passage to cut and says why \
            (tag [Coupe]). Be demanding but precise. In the overview, estimate how many words could go.
            """
        case .openingEnding:
            task = """
            Judge the chapter's first and last paragraphs: does the opening set the voice and pull the reader in; \
            does the ending land without explaining? Notes on those passages (tags [Ouverture], [Chute]) with a concrete \
            direction, not a rewrite.
            """
        case .facts:
            task = """
            List the facts to verify: names, dates, places, historical or technical facts, brands, quotations. \
            Each note says what to check and why it may be wrong (tag [À vérifier]).
            """
        }
        let scope = selection.isEmpty ? "" : "\nWork only on the passage the author selected (shown above)."
        return """
        \(task)\(scope)

        Do NOT write a long answer: put your observations in the margin of the text, as notes on precise passages.
        Reply in \(language) with:
        1. A short overview, at most 6 lines.
        2. A fenced block ```notes holding a JSON array of \
        {"quote": "<passage copied character for character from the chapter's current text, 3 to 25 words>", \
        "kind": \(Note.Kind.promptChoices), "note": "[Tag] <what does not work and why, a question for the author, or (praise) what works — never replacement wording>"}.
        \(WritingPartner.noRewrites)\(Annotator.existingNotes(book))
        """
    }
}

/// A rubric score as the agent returns it in a ```scores block.
struct RubricScore: Codable, Hashable {
    struct Criterion: Codable, Hashable {
        let name: String
        let score: Double
        let max: Double
        var comment: String? = nil
    }
    let criteria: [Criterion]
    let total: Double
    let max: Double
    var threshold: Double? = nil
    var eliminatory: [String]? = nil
}

/// Scores of a chapter over time: `.musset/scores/<chapter>.json`.
enum ScoreHistory {
    struct Entry: Codable, Equatable {
        let date: Date
        let version: String
        let agent: String
        let score: RubricScore
    }

    static func url(_ root: URL, _ chapter: String) -> URL { root.appendingPathComponent(".musset/scores/\(chapter).json") }

    static func load(_ root: URL, _ chapter: String) -> [Entry] {
        JSONFile.read(at: url(root, chapter), iso8601: true) ?? []
    }
}

/// Removes the machine-readable blocks (```notes, ```scores) from a reply before showing it.
/// A block still arriving shows as a line saying what is being done: « J’ajoute 12 notes… ».
func stripMachineBlocks(_ text: String) -> String {
    let done = try! NSRegularExpression(pattern: "```(notes|scores|json)[^\\n]*\\n.*?```\\n?", options: [.dotMatchesLineSeparators])
    var out = done.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
    let open = try! NSRegularExpression(pattern: "```(notes|scores|json)[^\\n]*(\\n.*)?$", options: [.dotMatchesLineSeparators])
    if let m = open.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)), let r = Range(m.range, in: out) {
        let block = out[r]
        let line: String
        if block.hasPrefix("```scores") {
            line = L("Scoring against the rubric…")
        } else {
            let n = block.components(separatedBy: "\"quote\"").count - 1
            line = n == 0 ? L("Adding notes…")
                : L("Adding \(n) notes…")
        }
        out.replaceSubrange(r, with: "*\(line)*")
    }
    return out.trimmingCharacters(in: .whitespacesAndNewlines)
}

struct ScoreCard: View {
    let score: RubricScore
    var previous: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(fmt(score.total))").font(.title2.monospacedDigit().bold())
                    .foregroundStyle(passes ? Color.primary : Ink.warning)
                Text("/ \(fmt(score.max))").foregroundStyle(.secondary)
                if let t = score.threshold { Text(L("threshold \(fmt(t))")).font(.ui(11)).foregroundStyle(.secondary) }
                if let p = previous {
                    let d = score.total - p
                    Text(d >= 0 ? "+\(fmt(d))" : fmt(d)).font(.ui(11, .semibold)).foregroundStyle(d >= 0 ? Ink.positive : Ink.error)
                        .help(L("Since the previous critique of this chapter"))
                }
                Spacer()
            }
            ForEach(Array(score.criteria.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 6) {
                    Text(c.name).font(.ui(11)).frame(width: 130, alignment: .leading).lineLimit(1)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(Ink.accent.opacity(0.7)).frame(width: g.size.width * CGFloat(c.max > 0 ? c.score / c.max : 0))
                        }
                    }
                    .frame(height: 5)
                    Text("\(fmt(c.score))/\(fmt(c.max))").font(.ui(11).monospacedDigit()).frame(width: 44, alignment: .trailing)
                }
                .help(c.comment ?? "")
            }
            if let e = score.eliminatory, !e.isEmpty {
                ForEach(e, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").font(.ui(11)).foregroundStyle(Ink.warning) }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.control))
    }

    private var passes: Bool { score.threshold.map { score.total >= $0 } ?? true }
    private func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
}

struct TicsSheet: View {
    let session: BookSession
    var body: some View {
        BookFileSheet(title: "Tics — \(session.title)",
                      caption: L("Used by « Tics » and « Style & problems ». Markdown, saved in .musset/tics.md and kept in the book’s history."),
                      starter: (L("Start from the default grid"), Tics.grid),
                      load: { Tics.load(session.root) }, save: { try? Tics.save($0, root: session.root) })
    }
}

/// A Markdown file of the book the author edits by hand (rubric, tics grid).
private struct BookFileSheet: View {
    let title: String
    let caption: String
    let starter: (label: String, text: String)
    let load: () -> String
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.ui(15, .semibold))
            Text(caption).font(.ui(11)).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(.body, design: .monospaced)).frame(minHeight: 380)
            HStack {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button(starter.label) { text = starter.text }
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Save")) { save(text); dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 720)
        .onAppear { text = load() }
    }
}
