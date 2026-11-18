import SwiftUI

/// Which chapters: the whole book, those at some statuses, or a few picked by hand.
enum ChapterScopeMode: String, Codable { case book, status, pick }

/// The chapter choice of Export, shared with Debate: three rows, statuses as chips, chapters as checkboxes.
struct ChapterScopePicker: View {
    let session: BookSession
    @Binding var scope: String
    /// Statuses, comma-separated ("edited,final").
    @Binding var statusList: String
    @Binding var picked: Set<String>
    var pickHint: String

    static func statuses(_ list: String) -> Set<ChapterStatus> {
        Set(list.split(separator: ",").compactMap { ChapterStatus(rawValue: String($0)) })
    }

    /// The chapters chosen, in book order.
    static func chapters(_ m: BookManifest, scope: String, statusList: String, picked: Set<String>) -> [ChapterEntry] {
        let statuses = statuses(statusList)
        return m.chapters.filter { ch in
            switch ChapterScopeMode(rawValue: scope) ?? .book {
            case .book: !ch.excludeFromExport
            case .status: statuses.contains(ch.status ?? .draft)
            case .pick: picked.contains(ch.id)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row(.book, L("The whole book", ctx: "Le livre entier"),
                "\(session.manifest.chapters.filter { !$0.excludeFromExport }.count) " + session.words.piecesInOrder)
            row(.status, session.words.piecesByStatus, L("For example: only what is edited or final"))
            if scope == ChapterScopeMode.status.rawValue {
                let on = Self.statuses(statusList)
                HStack(spacing: 6) {
                    ForEach(ChapterStatus.allCases) { st in
                        let n = session.manifest.chapters.filter { ($0.status ?? .draft) == st }.count
                        Chip(label: "\(st.label) \(n)", on: on.contains(st), dot: st.dot) {
                            var set = on
                            if set.contains(st) { set.remove(st) } else { set.insert(st) }
                            statusList = ChapterStatus.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
                        }
                    }
                }
                .padding(.leading, 30)
            }
            row(.pick, session.words.chosenPieces, pickHint)
            if scope == ChapterScopeMode.pick.rawValue {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(session.manifest.chapters.enumerated()), id: \.element.id) { i, ch in
                            Toggle(isOn: Binding(get: { picked.contains(ch.id) }, set: { if $0 { picked.insert(ch.id) } else { picked.remove(ch.id) } })) {
                                HStack {
                                    Text(session.manifest.pieceMark(at: i)).font(.uiMono(11)).foregroundStyle(.tertiary).frame(minWidth: 18, alignment: .trailing)
                                    Text(session.manifest.shownTitle(of: ch))
                                    Spacer()
                                    StatusDot(status: ch.status ?? .draft)
                                    Text((session.chapterCounts[ch.id]?.size ?? 0).ui).font(.ui(11).monospacedDigit()).foregroundStyle(.secondary).frame(width: 48, alignment: .trailing)
                                }
                            }
                            .toggleStyle(.checkbox)
                            .padding(.horizontal, 10).frame(height: 30)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 200)
                .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
                .padding(.leading, 30)
            }
        }
    }

    private func row(_ s: ChapterScopeMode, _ title: String, _ hint: String) -> some View {
        Button { scope = s.rawValue } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: scope == s.rawValue ? "largecircle.fill.circle" : "circle").foregroundStyle(scope == s.rawValue ? .primary : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(hint).font(.ui(11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(10)
            .background(scope == s.rawValue ? Ink.side : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(scope == s.rawValue ? Color.primary.opacity(0.8) : Ink.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
