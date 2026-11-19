import SwiftUI

/// Which part of the book a reader is given: all of it, the chapters at some statuses, or chapters chosen one by
/// one. Compact, for the invitation and for changing it later. The chapters shown are those of the milestone being
/// given, with the statuses they had that day: it is what the reader's app goes by.
struct PartPicker: View {
    let session: BookSession
    let milestone: String?
    @Binding var mode: ChapterScopeMode
    @Binding var statuses: Set<ChapterStatus>
    @Binding var picked: Set<String>

    /// The book's chapters as they stand in a milestone; as they stand today for want of one.
    static func chapters(of session: BookSession, in milestone: String?) -> [ChapterEntry] {
        let now = session.manifest.chapters.filter { !$0.excludeFromExport }
        guard let tag = milestone, let commit = session.jalons.first(where: { $0.id == tag })?.commit,
              let text = session.git.show(commit, path: ".musset/book.json"),
              let then = try? JSONDecoder().decode(BookManifest.self, from: Data(text.utf8)) else { return now }
        return then.chapters.filter { !$0.excludeFromExport }
    }

    /// What the choice comes to: nothing for the whole book.
    static func scope(_ mode: ChapterScopeMode, _ statuses: Set<ChapterStatus>, _ picked: Set<String>, chapters: [ChapterEntry]) -> ReadingScope? {
        switch mode {
        case .book: nil
        case .status: .statuses(Array(statuses))
        case .pick: .chapters(chapters.map(\.id).filter(picked.contains))
        }
    }

    /// Reads a reader's part back into the three bindings' values.
    static func values(of scope: ReadingScope?) -> (mode: ChapterScopeMode, statuses: Set<ChapterStatus>, picked: Set<String>) {
        if let ids = scope?.chapters { return (.pick, [.edited, .final], Set(ids)) }
        if let list = scope?.statuses { return (.status, Set(list.compactMap(ChapterStatus.init(rawValue:))), []) }
        return (.book, [.edited, .final], [])
    }

    private var chapters: [ChapterEntry] { Self.chapters(of: session, in: milestone) }

    var body: some View {
        let all = chapters
        let scope = Self.scope(mode, statuses, picked, chapters: all)
        let given = all.filter { scope.allows($0) }
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $mode) {
                Text(L("The whole book", ctx: "Le livre entier")).tag(ChapterScopeMode.book)
                Text(session.words.piecesByStatus).tag(ChapterScopeMode.status)
                Text(session.words.chosenPieces).tag(ChapterScopeMode.pick)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if mode == .status {
                HStack(spacing: 6) {
                    ForEach(ChapterStatus.allCases) { st in
                        let n = all.filter { ($0.status ?? .draft) == st }.count
                        Chip(label: "\(st.label) \(n)", on: statuses.contains(st), dot: st.dot) {
                            if statuses.contains(st) { statuses.remove(st) } else { statuses.insert(st) }
                        }
                    }
                }
            }
            if mode == .pick {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(all) { ch in
                            Toggle(isOn: Binding(get: { picked.contains(ch.id) }, set: { if $0 { picked.insert(ch.id) } else { picked.remove(ch.id) } })) {
                                HStack {
                                    Text(session.manifest.shownTitle(of: ch)).lineLimit(1)
                                    Spacer()
                                    StatusDot(status: ch.status ?? .draft)
                                    Text((ch.status ?? .draft).label).font(.ui(11)).foregroundStyle(.secondary)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 10).frame(height: 28)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 148)
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
            }
            if mode != .book {
                Text(given.isEmpty ? L("Nothing to read yet with this choice.")
                     : L("\(session.manifest.count(given.count, .piece)) of \(all.count). In Musset and Musset Reader, they see nothing else of the book."))
                    .font(.ui(11)).foregroundStyle(given.isEmpty ? Ink.error : .secondary).fixedSize(horizontal: false, vertical: true)
            }
            if mode == .status {
                Text(L("A newer milestone brings them what has reached these statuses by then."))
                    .font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Changing, later, the part of the book someone reads.
struct PartSheet: View {
    let session: BookSession
    let name: String
    let milestone: String
    let current: ReadingScope?
    let save: (ReadingScope?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var mode = ChapterScopeMode.book
    @State private var statuses: Set<ChapterStatus> = [.edited, .final]
    @State private var picked: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text(L("What \(name) reads")).font(.system(size: 22, design: .serif))
                PartPicker(session: session, milestone: milestone, mode: $mode, statuses: $statuses, picked: $picked)
            }
            .padding(24).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.inkSecondary)
                Button(L("Save")) {
                    save(PartPicker.scope(mode, statuses, picked, chapters: PartPicker.chapters(of: session, in: milestone)))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.ink)
            }
            .padding(.horizontal, 24).padding(.vertical, 14).background(Ink.side)
        }
        .frame(width: 520)
        .onAppear { (mode, statuses, picked) = PartPicker.values(of: current) }
    }
}
