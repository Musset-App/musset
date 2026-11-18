import SwiftUI

/// What happened in the books I read or write: milestones, notes and replies, books shared with me. Newest first.
struct ActivityList: View {
    let app: AppState
    private var collab: Collab { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                AccountPageTitle(L("Activity"))
                Spacer()
                if collab.unreadActivity > 0 {
                    Button(L("Mark all as read")) { Task { await collab.markActivityRead() } }.buttonStyle(.link).font(.ui(12))
                }
            }
            .padding(.bottom, 16)
            if collab.activity.isEmpty {
                Text(L("Nothing yet. Milestones, notes and replies in the books you share show here."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            // Eager and bounded, like every list here (a LazyVStack spun forever in SwiftUI's prefetch).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(collab.activity.prefix(100)) { item in
                    row(item)
                    Divider()
                }
            }
        }
        .task { await collab.refreshActivity() }
    }

    private func row(_ item: ActivityItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle().fill(item.isUnread ? Ink.accent : .clear).frame(width: 8, height: 8).padding(.top, 6)
                .accessibilityLabel(item.isUnread ? L("Unread") : "")
            VStack(alignment: .leading, spacing: 4) {
                Text(item.sentence).font(.ui(14))
                if let m = item.message, !m.isEmpty {
                    Text("“" + m + "”").font(.ui(13)).foregroundStyle(.secondary).lineLimit(3)
                }
                Text(item.date.formatted(.relative(presentation: .named).locale(UILang.locale))).font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let repo = item.repo {
                Button(action: { open(item, repo: repo) }) {
                    Text(item.kind == "milestone" ? L("Read \(item.tag ?? "")") : (item.kind == "shared" ? L("Open") : L("Answer")))
                }
                .buttonStyle(item.kind == "milestone" ? .ink : .inkSecondary)
            }
        }
        .padding(.vertical, 14)
    }

    private func open(_ item: ActivityItem, repo: String) {
        Task { await collab.markActivityRead(all: false, ids: [item.id]) }
        var c = URLComponents()
        c.scheme = "musset"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "repo", value: repo)] + (item.tag.map { [URLQueryItem(name: "tag", value: $0)] } ?? [])
        if let url = c.url { app.open(mussetURL: url) }
    }
}
