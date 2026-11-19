import SwiftUI

/// Who reads the book, a page of its home (Overview ▸ Readers). For the author it is one of three things:
/// - no Musset Sync yet: why it is worth having, and its price;
/// - Musset Sync, but the book is on this Mac only: it has to go to the account before anyone can be invited;
/// - the book is on the account: its readers, the invitation, the reviews that came back.
/// Someone reading another person's book sees what they send back instead.
struct ReadersPage: View {
    let app: AppState
    let session: BookSession
    /// A face to show whatever the account says: for the tests' pictures.
    var forced: Case? = nil
    @State private var collab = Collab.shared
    @State private var people: [(user: String, role: Collab.Role)] = []
    @State private var reviews: [Collab.Review] = []
    /// The milestone each reader was given.
    @State private var reading: [String: Collab.Reading] = [:]
    /// What was written and cut since the latest milestone: what no reader has seen.
    @State private var since: (added: Int, removed: Int, chapters: [String])?
    @State private var inviting = false
    @State private var leaving: String?
    @State private var message = ""
    @State private var status: String?
    @State private var working = false

    enum Case { case reader, offer, notSynced, shared }

    /// Which of the page's faces this book and this account call for.
    static func which(signedIn: Bool, canSync: Bool, linked: Bool, owner: Bool) -> Case {
        if linked && !owner { return .reader }
        if !signedIn || !canSync { return .offer }
        return linked ? .shared : .notSynced
    }

    private var now: Case {
        forced ?? Self.which(signedIn: collab.signedIn, canSync: collab.canSync, linked: collab.link(session.git) != nil, owner: collab.isOwner(session.git))
    }

    private var repo: String { collab.link(session.git).map { "\($0.owner)/\($0.repo)" } ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                switch now {
                case .offer: offer
                case .notSynced: notSynced
                case .shared: shared
                case .reader: reader
                }
                if working { ProgressView().controlSize(.small) }
                if let status { Text(status).font(.ui(12)).foregroundStyle(.secondary) }
                if let e = collab.lastError { Text(e).font(.ui(12)).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(.horizontal, 40).padding(.vertical, 32)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .task { await refresh(); openInvitationIfAsked() }
        .onChange(of: app.inviteRequested) { openInvitationIfAsked() }
        .onReceive(NotificationCenter.default.publisher(for: Collab.becameWriter)) { _ in Task { await refresh() } }
        .sheet(isPresented: $inviting) {
            InviteSheet(session: session, suggestions: others) { sent in
                if let sent { status = sent }
                Task { await refresh() }
            }
        }
        .confirmationDialog(leaving.map { L("Stop sharing with \($0)") } ?? "", isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } })) {
            Button(L("Stop sharing"), role: .destructive) {
                if let user = leaving { run { try await collab.remove(user, from: session); await refresh() } }
                leaving = nil
            }
            Button(L("Cancel"), role: .cancel) { leaving = nil }
        }
    }

    /// The toolbar and the command bar ask for the invitation: it opens only where one can be sent.
    private func openInvitationIfAsked() {
        guard app.inviteRequested else { return }
        app.inviteRequested = false
        if now == .shared { inviting = true }
    }

    // MARK: No Musset Sync

    private var offer: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("MUSSET SYNC")).font(.ui(11, .semibold)).tracking(0.8).foregroundStyle(Ink.accent)
                    Text(L("Give \(session.title) its first readers.")).font(.system(size: 34, design: .serif)).fixedSize(horizontal: false, vertical: true)
                    Text(L("A book gets better the day someone else reads it. Musset Sync puts yours in front of an editor or a few trusted readers, and brings back what they think, inside your text."))
                        .font(.ui(15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Grid(alignment: .topLeading, horizontalSpacing: 28, verticalSpacing: 20) {
                    GridRow {
                        reason(L("Your first readers, inside the book"), L("Invite an editor or beta readers. Their corrections come back for you to accept or reject, and you see who wrote what."))
                        reason(L("They don’t pay"), L("Only you subscribe. Only the people you invite can open the book."))
                    }
                    GridRow {
                        reason(L("Safe, with its whole history"), L("Every version, every note and every milestone, kept off this Mac. A lost laptop costs you a laptop, not a book."))
                        reason(L("The same book on every Mac"), L("Write on the train, pick up at the desk. Offline first: it syncs when you are back."))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 12) {
                Text(SyncPrice.label).font(.system(size: 44, design: .serif))
                Text(L("a month, for all your books")).font(.ui(13)).foregroundStyle(.secondary)
                Button(L("Start Musset Sync")) { app.offerSync(for: session) }.buttonStyle(.ink).controlSize(.large).padding(.top, 6)
                Text(L("Then invite your first reader, right here.")).font(.ui(12)).foregroundStyle(.secondary)
                Divider().padding(.vertical, 4)
                Text(L("Musset stays free without it. Your book always lives on your Mac too, as plain files."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !collab.signedIn {
                    Button(L("Sign in")) { app.showAccount() }.buttonStyle(.link).font(.ui(12))
                }
            }
            .padding(22)
            .frame(width: 270, alignment: .leading)
            .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
        }
    }

    private func reason(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Divider()
            Text(title).font(.ui(14, .semibold)).padding(.top, 8)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: On this Mac only

    private var notSynced: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("\(session.title) is on this Mac only.")).font(.system(size: 30, design: .serif)).fixedSize(horizontal: false, vertical: true)
                Text(L("To invite readers, the book first has to be on your account. Activate Sync for it once; from then on Musset keeps it up to date as you write."))
                    .font(.ui(15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 14) {
                Button(L("Activate Sync for \(session.title)")) {
                    run { collab.setLocalOnly(session, false); try await collab.share(session); status = L("On your account."); await refresh() }
                }
                .buttonStyle(.ink).controlSize(.large).disabled(working)
                Text(L("It stays private: only the people you invite can open it.")).font(.ui(12)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                reason("1 · " + L("Sync it"), L("The book and its whole history go to your account. Nothing changes in your files."))
                reason("2 · " + L("Invite"), L("An editor or a few readers, by e-mail. They don’t pay."))
                reason("3 · " + L("Read what comes back"), L("Notes in your margin, corrections to accept or reject."))
            }
        }
    }

    // MARK: On the account

    /// People of the circle who are on Musset and not on this book yet.
    private var others: [CirclePerson] {
        let on = Set(people.map(\.user))
        return collab.circle.filter { p in p.username.map { !on.contains($0) && $0 != collab.username } ?? false }
    }

    /// Invited by e-mail to this book, and no account yet.
    private var pending: [CirclePerson] {
        let sent = Set(collab.invited(to: repo))
        return collab.circle.filter { $0.isPending && sent.contains(($0.email ?? "").lowercased()) }
    }

    private var shared: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(people.isEmpty && pending.isEmpty ? L("Nobody reads \(session.title) yet.") : L("Who reads \(session.title)"))
                        .font(.system(size: 30, design: .serif)).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 7) {
                        Circle().fill(collab.sync.isProblem ? Ink.warning : Color.green).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(collab.sync.isProblem ? collab.sync.help : L("On your account, private. Only the people you invite can open it."))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(L("Invite someone…")) { inviting = true }.buttonStyle(.ink).controlSize(.large)
            }

            milestoneLine

            if people.isEmpty && pending.isEmpty {
                Text(L("Invite an editor or a few first readers. Their notes land in your margin, their corrections wait for you to accept or reject. They don’t pay."))
                    .font(.ui(15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(people, id: \.user) { person in
                        personRow(person)
                        if person.user != people.last?.user || !pending.isEmpty { Divider() }
                    }
                    ForEach(pending) { p in
                        pendingRow(p)
                        if p != pending.last { Divider() }
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
            }

            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 10) {
                        SectionLabel(L("From your circle"))
                        Button(L("See my circle")) { app.showAccount(.circle) }.buttonStyle(.link).font(.ui(12))
                    }
                    FlowRow(spacing: 8) {
                        ForEach(others) { p in
                            Button { share(with: p) } label: {
                                HStack(spacing: 8) {
                                    avatar(p.initials, name: p.username ?? "", size: 24)
                                    Text(p.name)
                                    Text("· " + (Relation(rawValue: p.relation)?.label ?? "").lowercased(with: UILang.locale)).foregroundStyle(.secondary)
                                    Text(L("Share")).fontWeight(.semibold).foregroundStyle(Ink.accent)
                                }
                                .padding(.leading, 6).padding(.trailing, 12).frame(height: 36)
                                .overlay(Capsule().strokeBorder(Ink.hairline))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .help(L("Share \(session.title) with \(p.name)"))
                        }
                    }
                    Text(L("One click shares the book with the role that fits who they are to you. Change it afterwards in the list above."))
                        .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(L("Reviews to read"))
                if reviews.isEmpty { Text(L("No review waiting.")).foregroundStyle(.secondary) }
                ForEach(reviews) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).fontWeight(.medium)
                            Text(name(of: r.user.login)).font(.ui(12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Bring into my text")) {
                            run {
                                let out = try await collab.importReview(r, into: session)
                                status = L("\(out.placed) corrections placed in the chapters")
                                    + (out.unplaced > 0 ? L(", \(out.unplaced) as comments (passages you rewrote).") : ".")
                                await refresh()
                            }
                        }
                        .buttonStyle(.ink)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
                }
                Text(L("A review becomes corrections in your text: accept or reject each one (Format menu)."))
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
        }
    }

    private func name(of user: String) -> String { collab.circle.first { $0.username == user }?.name ?? user }

    /// Readers read a milestone, never the desk: the latest one, and how far the manuscript has moved since.
    private var milestoneLine: some View {
        HStack(spacing: 12) {
            Image(systemName: "flag.fill").foregroundStyle(Ink.jalon).accessibilityHidden(true)
            if let latest = session.milestones.first {
                Text(L("Each reader reads the milestone you gave them. Latest: « \(latest.title) ».") + " "
                     + ((since.map { $0.added + $0.removed } ?? 0) > 0 ? L("You have written \((since?.added ?? 0).ui) words since, which nobody has seen.") : ""))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Readers read a milestone you chose, never your desk. The first invitation sets one, named « First reading »."))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(L("Set a Milestone…")) { app.newJalon = TrackStart() }.buttonStyle(.inkSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
    }

    /// The milestone a new reader is given: the latest, or a first one set on the spot.
    private func milestoneToGive() -> String? {
        session.milestones.first?.id ?? session.addJalon(title: L("First reading"), note: "")
    }

    private func give(_ m: GitService.Tag, to user: String) {
        run {
            try await collab.give(m.id, to: user, in: session)
            await collab.notify(.milestone, in: session, recipients: [user], tag: m.title, message: nil)
            status = L("\(name(of: user)) now reads « \(m.title) ».")
            await refresh()
        }
    }

    private func avatar(_ initials: String, name: String, size: CGFloat) -> some View {
        Text(initials).font(.ui(size * 0.36, .semibold)).foregroundStyle(Person.color(name))
            .frame(width: size, height: size)
            .background(Person.color(name).opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }

    private func personRow(_ person: (user: String, role: Collab.Role)) -> some View {
        let known = collab.circle.first { $0.username == person.user }
        let waiting = reviews.filter { $0.user.login == person.user }.count
        return HStack(spacing: 12) {
            avatar(known?.initials ?? String(person.user.prefix(2)).uppercased(), name: person.user, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(known?.name ?? person.user).fontWeight(.medium)
                Text([known.flatMap { Relation(rawValue: $0.relation)?.label }, "@" + person.user].compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if waiting > 0 {
                Text(L("Sent a review")).font(.ui(12)).padding(.horizontal, 9).frame(height: 22)
                    .background(Ink.accent.opacity(0.12), in: Capsule())
            }
            if person.role != .collaborator {
                let given = reading[person.user].flatMap { r in session.jalons.first { $0.id == r.tag } }
                Menu {
                    ForEach(session.milestones) { m in
                        Button { give(m, to: person.user) } label: {
                            if m.id == given?.id { Label(m.title, systemImage: "checkmark") } else { Text(m.title) }
                        }
                    }
                } label: {
                    Label(given.map { L("Reads « \($0.title) »") } ?? L("No milestone yet"), systemImage: "flag")
                }
                .fixedSize().disabled(session.jalons.isEmpty)
                if let latest = session.milestones.first, given?.id != latest.id {
                    Button(L("Give « \(latest.title) »")) { give(latest, to: person.user) }.buttonStyle(.inkSecondary)
                }
            } else {
                Text(L("Writes in the text itself")).font(.ui(12)).foregroundStyle(.secondary)
            }
            Picker("", selection: Binding(get: { person.role }, set: { new in run { try await collab.setRole(new, of: person.user, in: session); await refresh() } })) {
                ForEach(Collab.Role.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden().fixedSize()
            Button { leaving = person.user } label: { Image(systemName: "xmark").font(.ui(11)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Stop sharing with \(person.user)"))
                .accessibilityLabel(L("Stop sharing with \(person.user)"))
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private func pendingRow(_ p: CirclePerson) -> some View {
        HStack(spacing: 12) {
            Text("@").font(.ui(12, .semibold)).foregroundStyle(.secondary).frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [3]))).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).fontWeight(.medium)
                Text([Relation(rawValue: p.relation)?.label, p.invited.map { L("invited \(Date(timeIntervalSince1970: TimeInterval($0)).formatted(.relative(presentation: .named).locale(UILang.locale))), no account yet") }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Send again")) {
                let email = p.email ?? ""
                run {
                    try await collab.invite(email: email, as: .reader, to: session, relation: Relation(rawValue: p.relation) ?? .other, message: "",
                                            milestone: milestoneToGive())
                    status = L("Invitation sent to \(email).")
                }
            }
            .buttonStyle(.inkSecondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Ink.side.opacity(0.5))
    }

    /// Someone of the circle, in one click: the role that goes with who they are, and they hear of it.
    private func share(with p: CirclePerson) {
        guard let user = p.username else { return }
        let role = ReadersPage.role(for: Relation(rawValue: p.relation) ?? .other)
        let milestone = role == .collaborator ? nil : milestoneToGive()
        run {
            try await collab.invite(user, as: role, to: session)
            await collab.announceShare(to: user, in: session, as: role, milestone: milestone)
            status = L("Shared with \(p.name).")
            await refresh()
        }
    }

    /// What someone usually does with a book, from who they are to its author. The author changes it in the list.
    static func role(for relation: Relation) -> Collab.Role {
        switch relation {
        case .editor, .publisher, .translator: .editor
        case .author: .collaborator
        case .betaReader, .agent, .other: .reader
        }
    }

    // MARK: Reading someone else's book

    private var reader: some View {
        VStack(alignment: .leading, spacing: 12) {
            let owner = collab.link(session.git)?.owner ?? ""
            if collab.role(session.git) == .collaborator {
                Text(L("You are a collaborator on \(owner)'s book: you write in the text together, and what each of you writes is sent as you go."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if session.git.currentBranch?.hasPrefix("relecture/") == true {
                    Button(L("Write in the main text")) { run { try await collab.joinMainText(session); status = L("You are in the main text.") } }
                        .buttonStyle(.ink).help(L("Send your review first: what isn't sent stays behind."))
                }
            } else {
                Text(L("You are reading \(owner)'s book. Revision mode is on: your changes are kept as corrections."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                readingLine
                TextField(L("A word for the author (optional)"), text: $message, axis: .vertical)
                    .textFieldStyle(.roundedBorder).frame(width: 420)
                HStack {
                    Button(L("Send my review")) {
                        run { try await collab.sendReview(session, message: message); message = ""; status = L("Sent. The author will see it in their reviews.") }
                    }
                    .buttonStyle(.ink)
                    Button(L("Get the latest version")) {
                        run { try await collab.refreshReview(session); session.open(session.selectedChapterID ?? ""); status = L("Up to date.") }
                    }
                    .buttonStyle(.inkSecondary)
                    .help(L("Starts again from the author's latest text: send your review first."))
                }
            }
        }
    }

    /// What I was given to read, and whether a newer milestone has come since this copy was set.
    @ViewBuilder private var readingLine: some View {
        let given = collab.username.flatMap { reading[$0]?.tag }
        let here = collab.adopted(for: session.git)
        if let given, given != here {
            HStack(spacing: 12) {
                Image(systemName: "flag.fill").foregroundStyle(Ink.jalon).accessibilityHidden(true)
                Text(L("A new milestone arrived: « \(milestoneTitle(given)) ». Send your review first: your notes follow, what isn’t sent stays behind."))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(L("Read it")) {
                    run { try await collab.refreshReview(session); session.open(session.selectedChapterID ?? ""); status = L("Up to date."); await refresh() }
                }
                .buttonStyle(.ink)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Ink.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.card))
        } else if let here {
            Label(L("You are reading « \(milestoneTitle(here)) ». What the author has written since is theirs until they share it."), systemImage: "flag")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func milestoneTitle(_ tag: String) -> String {
        session.git.tags(matching: "jalon/*").first { $0.id == tag }?.title ?? String(tag.dropFirst(6))
    }

    // MARK: Work

    private func refresh() async {
        guard forced == nil, collab.signedIn else { return }
        await collab.refreshAccount()
        guard collab.link(session.git) != nil else { return }
        reading = await collab.reading(of: session.git)
        guard collab.isOwner(session.git) else { _ = try? await collab.refreshRole(session.git); return }
        if let latest = session.milestones.first {
            let s = session
            since = await Task.detached { await s.changeSince(latest) }.value
        }
        people = (try? await collab.people(of: session)) ?? []
        reviews = (try? await collab.reviews(of: session)) ?? []
        await collab.refreshCircle()
        collab.settleInvited(to: repo)
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        collab.lastError = nil
        status = nil
        Task {
            do { try await work() } catch { collab.lastError = error.localizedDescription }
            working = false
        }
    }
}

// MARK: The invitation

/// One person, one book: who, what they may do, who they are to the author, a word. Its button is in a footer
/// of its own, so no field can push it out of the window.
struct InviteSheet: View {
    let session: BookSession
    /// People of the circle who are not on the book yet, offered under the field.
    let suggestions: [CirclePerson]
    /// Called on the way out, with what to say if something was sent.
    let done: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    private var collab: Collab { .shared }
    @State private var who = ""
    @State private var role = Collab.Role.reader
    @State private var relation = Relation.betaReader
    @State private var message = ""
    /// The milestone they are given to read: the latest unless the author picks another.
    @State private var milestone = ""
    @State private var sending = false
    @State private var error: String?
    @FocusState private var onWho: Bool

    private var value: String { who.trimmingCharacters(in: .whitespaces) }
    /// A name of the circle typed or picked: nothing to ask about who they are, the circle knows.
    private var known: CirclePerson? { collab.circle.first { $0.username == value || $0.name == value } }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L("Invite someone to read \(session.title)")).font(.system(size: 24, design: .serif)).fixedSize(horizontal: false, vertical: true)
                    Text(L("They get an e-mail with a link. Their account is free, and always will be.")).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Who")).fontWeight(.semibold)
                    TextField(L("E-mail or Musset name"), text: $who).textFieldStyle(.roundedBorder).controlSize(.large).focused($onWho).onSubmit(send)
                    if !suggestions.isEmpty {
                        HStack(spacing: 6) {
                            Text(L("From your circle") + ":").font(.ui(12)).foregroundStyle(.secondary)
                            ForEach(suggestions.prefix(4)) { p in
                                Button(p.name) {
                                    who = p.username ?? p.name
                                    relation = Relation(rawValue: p.relation) ?? .other
                                    role = ReadersPage.role(for: relation)
                                }
                                .buttonStyle(.inkSecondary).controlSize(.small)
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("What they can do")).fontWeight(.semibold)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Collab.Role.allCases) { r in
                            Button { role = r } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(r.label).fontWeight(.semibold)
                                    Text(r.help).font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(11).frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
                                .background(role == r ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.card))
                                .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(role == r ? Color.primary : Ink.hairline, lineWidth: role == r ? 1.5 : 1))
                                .contentShape(RoundedRectangle(cornerRadius: Radius.card))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(role == r ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("What they read")).fontWeight(.semibold)
                    if role == .collaborator {
                        Text(L("The manuscript itself, as it is: a co-writer writes in it with you.")).foregroundStyle(.secondary)
                    } else if session.jalons.isEmpty {
                        Text(L("The book as it is now: a first milestone, « First reading », is set when you send. What you write afterwards stays on your desk until you share a new one."))
                            .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Picker("", selection: $milestone) {
                            ForEach(session.milestones) { m in
                                Text(m.title + " · " + m.date.formatted(.dateTime.day().month().locale(UILang.locale))).tag(m.id)
                            }
                        }
                        .labelsHidden().fixedSize()
                        Text(L("A milestone, never your desk. Give them a newer one whenever you like.")).font(.ui(11)).foregroundStyle(.secondary)
                    }
                }
                if known == nil {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("They are your")).fontWeight(.semibold)
                            Picker("", selection: $relation) { ForEach(Relation.allCases) { Text($0.label).tag($0) } }.labelsHidden().fixedSize()
                            Text(L("This is how they appear in your circle.")).font(.ui(11)).foregroundStyle(.secondary)
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("A word for them (optional)")).fontWeight(.semibold)
                            TextField("", text: $message, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...4)
                        }
                    }
                }
                Text(L("They can open \(session.title) on a Mac, an iPhone or an iPad, and never your other books. You can stop sharing at any moment."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
                if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
            }
            .padding(28)

            Divider()
            HStack(spacing: 10) {
                if sending { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.inkSecondary)
                Button(L("Send the invitation"), action: send).keyboardShortcut(.defaultAction).buttonStyle(.ink)
                    .disabled(value.isEmpty || sending)
            }
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(Ink.side)
        }
        .frame(width: 600)
        .onAppear { onWho = true; milestone = session.milestones.first?.id ?? "" }
    }

    private func send() {
        let target = value
        guard !target.isEmpty, !sending else { return }
        sending = true
        error = nil
        // Readers and editors are given a milestone; with none yet, the book as it is now becomes the first.
        let given: String? = role == .collaborator ? nil
            : (session.jalons.contains { $0.id == milestone } ? milestone : session.addJalon(title: L("First reading"), note: ""))
        Task {
            do {
                if target.contains("@") {
                    try await collab.invite(email: target, as: role, to: session, relation: relation, message: message, milestone: given)
                    if let l = collab.link(session.git) { collab.remember(invited: target, to: "\(l.owner)/\(l.repo)") }
                    done(L("Invitation sent to \(target)."))
                } else {
                    let user = known?.username ?? target
                    try await collab.invite(user, as: role, to: session)
                    await collab.announceShare(to: user, in: session, as: role, milestone: given)
                    done(L("Shared with \(known?.name ?? user)."))
                }
                dismiss()
            } catch { self.error = error.localizedDescription }
            sending = false
        }
    }
}

// MARK: Invitations still out

extension Collab {
    private static let invitedKey = "collabInvited"
    private var invitedByBook: [String: [String]] {
        get { UserDefaults.standard.dictionary(forKey: Self.invitedKey) as? [String: [String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.invitedKey) }
    }

    /// The e-mails invited to a book ("owner/repo") from this Mac that had no account then. The server lists an
    /// invited person in the circle, not the book they were invited to: this Mac remembers that part.
    func invited(to repo: String) -> [String] { invitedByBook[repo] ?? [] }

    func remember(invited email: String, to repo: String) {
        let e = email.lowercased()
        var all = invitedByBook
        if !(all[repo] ?? []).contains(e) { all[repo, default: []].append(e) }
        invitedByBook = all
    }

    /// Forgets those who joined since (the circle no longer has them waiting): they are among the book's people now.
    func settleInvited(to repo: String) {
        let waiting = Set(circle.filter(\.isPending).compactMap { $0.email?.lowercased() })
        var all = invitedByBook
        guard let sent = all[repo] else { return }
        let still = sent.filter(waiting.contains)
        if still.count != sent.count { all[repo] = still.isEmpty ? nil : still; invitedByBook = all }
    }
}

// MARK: A row that wraps

/// Lays its children left to right and wraps them: the circle's people, however many there are.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: rows.last.map { $0.y + $0.height } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0; var y: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
                rows[rows.count - 1].items = [i]; rows[rows.count - 1].width = size.width; rows[rows.count - 1].height = size.height
            } else {
                rows[rows.count - 1].items.append(i); rows[rows.count - 1].width = needed
                rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            }
        }
        return rows
    }
}
