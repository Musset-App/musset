import SwiftUI

/// The sources offered after « [@ »: the matching ones, most cited first.
@MainActor
@Observable
final class CitationList {
    var items: [BibleEntry] = []
    var index = 0
    var isOpen = false
    @ObservationIgnored var queryRange = NSRange(location: 0, length: 0)
    @ObservationIgnored weak var session: BookSession?
    @ObservationIgnored var pick: (BibleEntry) -> Void = { _ in }
    @ObservationIgnored var newSource: () -> Void = {}
}

struct CitationListView: View {
    let list: CitationList

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(list.items.enumerated()), id: \.element.path) { i, e in
                Button { list.pick(e) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text([(e.meta["author"] ?? "").components(separatedBy: ";").first?.split(separator: " ").last.map(String.init), e.meta["year"]]
                            .compactMap { $0 }.joined(separator: " ") + " · " + e.title)
                            .font(.ui(13)).lineLimit(1)
                        Text("@" + (e.meta["citekey"] ?? "") + (list.session.map { s in " · " + L("cited \(References.citeCount(of: e, in: s)) times") } ?? ""))
                            .font(.uiMono(11)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(i == list.index ? Ink.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if !list.items.isEmpty { Divider().padding(.vertical, 4) }
            Button(L("+ New source from a DOI, an ISBN or a link"), action: list.newSource)
                .buttonStyle(.plain).foregroundStyle(Ink.accent).font(.ui(13))
                .padding(.horizontal, 10).padding(.vertical, 6)
            Text(L("Then « , p. 12 » for the page."))
                .font(.ui(11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6)
        }
        .padding(6)
        .frame(width: 380)
    }
}

/// The card on a citation: the source, and the passage kept from its PDF at that page, if any.
struct CitationCard: View {
    let key: String
    let page: Int?
    let session: BookSession
    let open: (String) -> Void
    let sources: () -> Void

    var body: some View {
        let entry = References.entries(session).first { $0.meta["citekey"] == key }
        VStack(alignment: .leading, spacing: 6) {
            if let e = entry {
                Text(CitationPages.inverted(e.meta["author"] ?? "") + (e.meta["year"].map { ", " + $0 } ?? "")).font(.ui(11)).foregroundStyle(.secondary)
                Text(e.title).font(.system(size: 15, design: .serif)).fixedSize(horizontal: false, vertical: true)
                if let file = e.meta["file"] {
                    let kept = Highlights.read(session.bible.store.url(file + ".md"))
                    if let hit = kept.first(where: { $0.page == page }) ?? (page == nil ? kept.first : nil) {
                        Text("« \(hit.text) »").font(.uiMono(11)).lineLimit(5).padding(8)
                            .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.row))
                        Text(L("your highlight, p. \(hit.page)")).font(.ui(10)).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 6) {
                    if let file = e.meta["file"] { Button(page.map { L("Open at p. \($0)") } ?? L("Open the PDF")) { PDFJump.page = page; open(file) } }
                    Button(L("The source"), action: sources)
                }
                .controlSize(.small)
            } else {
                Text(L("[@\(key)] isn’t among your sources.")).font(.ui(12))
                Button(L("Add it"), action: sources).controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 300, alignment: .leading)
    }
}
