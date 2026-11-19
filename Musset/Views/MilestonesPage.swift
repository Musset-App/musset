import SwiftUI

/// The book's milestones, a page of its home (Overview ▸ Milestones): the manuscript as it stands today, which
/// nobody sees but its author, then each milestone with who reads it. A milestone is the whole book on a day the
/// author chose; it is what readers read. The sittings in between are in The Book's History.
struct MilestonesPage: View {
    let app: AppState
    let session: BookSession
    /// For the tests' pictures: readers by milestone, without asking the account.
    var sample: [String: [String]]? = nil
    @State private var collab = Collab.shared
    @State private var people: [(user: String, role: Collab.Role)] = []
    @State private var reading: [String: Collab.Reading] = [:]
    @State private var since: (added: Int, removed: Int, chapters: [String])?
    @State private var removing: GitService.Tag?
    @State private var working = false

    private var shared: Bool { collab.isOwner(session.git) }

    var body: some View {
        let milestones = session.milestones
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Milestones")).font(.system(size: 30, design: .serif))
                    Text(L("A milestone is the whole book as it stood on a day you chose. You can come back to it, compare it with today, and it is what your readers read: a milestone, never your desk."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 620, alignment: .leading)
                }
                desk(latest: milestones.first)
                if milestones.isEmpty {
                    Text(L("No milestone yet. Set one when a draft is done, before a big change, or the day you send the book to someone."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(milestones.enumerated()), id: \.element.id) { i, m in
                    card(m, latest: i == 0)
                }
                if let e = collab.lastError { Text(e).font(.ui(12)).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task(id: milestones.map(\.id)) { await refresh() }
        .confirmationDialog(removing.map { L("Remove the milestone « \($0.title) »?") } ?? "", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L("Remove"), role: .destructive) {
                if let m = removing { session.removeJalon(m) }
                removing = nil
            }
            Button(L("Cancel"), role: .cancel) { removing = nil }
        } message: {
            Text(L("The text stays in the book’s history. Readers given this milestone keep nothing to read until you give them another."))
        }
    }

    // MARK: Today

    private func desk(latest: GitService.Tag?) -> some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                SectionLabel(L("On your desk, today"))
                Text(deskLine(latest)).font(.ui(15, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(deskDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button { app.newJalon = TrackStart() } label: { Label(L("Set a Milestone…"), systemImage: "flag") }
                .buttonStyle(.ink).controlSize(.large).disabled(!session.git.isRepo)
        }
        .padding(18)
        .background(Ink.side.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5])))
    }

    private func deskLine(_ latest: GitService.Tag?) -> String {
        guard let latest, let since else { return session.bookCounts.label }
        if since.added + since.removed == 0 { return session.bookCounts.label + " · " + L("nothing changed since « \(latest.title) »") }
        return session.bookCounts.label + " · " + L("\(since.added.ui) written and \(since.removed.ui) cut since « \(latest.title) »")
    }

    private var deskDetail: String {
        let nobody = L("Nobody sees this but you.")
        guard let since, !since.chapters.isEmpty else { return nobody }
        return nobody + " " + L("Touched: \(since.chapters.prefix(4).joined(separator: ", "))") + (since.chapters.count > 4 ? "…" : ".")
    }

    // MARK: A milestone

    private func readers(of m: GitService.Tag) -> [String] {
        if let sample { return sample[m.id] ?? [] }
        return reading.filter { $0.value.tag == m.id }.map(\.key).sorted()
    }

    private func name(_ user: String) -> String { collab.circle.first { $0.username == user }?.name ?? user }

    private func card(_ m: GitService.Tag, latest: Bool) -> some View {
        let who = readers(of: m)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: who.isEmpty ? "flag" : "flag.fill").foregroundStyle(Ink.jalon).font(.ui(15)).padding(.top, 5).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(m.title).font(.system(size: 22, design: .serif))
                    Text(m.date.formatted(.dateTime.day().month(.wide).year().locale(UILang.locale))).foregroundStyle(.secondary)
                    if !m.note.isEmpty { Text(m.note).italic().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                Spacer()
                if latest {
                    Text(L("Latest")).font(.ui(11, .semibold)).padding(.horizontal, 9).frame(height: 22)
                        .background(Color.green.opacity(0.16), in: Capsule())
                }
            }
            Divider()
            HStack(spacing: 10) {
                Text(who.isEmpty ? L("Not shared. Yours only.") : L("Read by \(who.map(name).joined(separator: ", "))"))
                    .foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if shared, !(sample == nil && people.isEmpty) {
                    Menu(L("Share with…")) {
                        ForEach(sample == nil ? people.filter { $0.role != .collaborator }.map(\.user) : [], id: \.self) { user in
                            Button {
                                give(who.contains(user) ? nil : m, to: user)
                            } label: {
                                if who.contains(user) { Label(name(user), systemImage: "checkmark") } else { Text(name(user)) }
                            }
                        }
                    }
                    .fixedSize().disabled(working)
                }
                Button(L("In the book’s history")) { app.open(.story) }.buttonStyle(.inkSecondary)
                Menu {
                    Button(L("Remove the Milestone…"), role: .destructive) { removing = m }
                } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel(L("More"))
            }
        }
        .padding(18)
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
    }

    // MARK: Work

    /// Gives the milestone to a reader, and tells them; none takes it back.
    private func give(_ m: GitService.Tag?, to user: String) {
        working = true
        collab.lastError = nil
        Task {
            do {
                try await collab.give(m?.id, to: user, in: session)
                if let m { await collab.notify(.milestone, in: session, recipients: [user], tag: m.title, message: nil) }
                reading = await collab.reading(of: session.git)
            } catch { collab.lastError = error.localizedDescription }
            working = false
        }
    }

    private func refresh() async {
        if let latest = session.milestones.first {
            let s = session
            since = await Task.detached { await s.changeSince(latest) }.value
        } else { since = nil }
        guard sample == nil, collab.signedIn, shared else { return }
        people = (try? await collab.people(of: session)) ?? []
        reading = await collab.reading(of: session.git)
        if collab.circle.isEmpty { await collab.refreshCircle() }
    }
}
