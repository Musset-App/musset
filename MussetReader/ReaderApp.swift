import MussetPage
import SwiftUI
import UIKit
import UserNotifications

@main
struct MussetReaderApp: App {
    @UIApplicationDelegateAdaptor(ReaderDelegate.self) private var delegate
    @State private var api = ReaderAPI.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if api.signedIn { ReaderTabs() } else { SignInView() }
            }
            .task {
                #if DEBUG
                // Development aid, against a local server only: signs in with a password given at launch.
                let env = ProcessInfo.processInfo.environment
                if !api.signedIn, let user = env["MUSSET_READER_USER"], let password = env["MUSSET_READER_PASSWORD"],
                   ReaderAPI.server.host == "localhost" {
                    try? await api.signIn(username: user, password: password)
                }
                #endif
                await api.refreshAll()
            }
            .onOpenURL { url in
                // musset://join/<token>: an invitation, opened on the phone.
                if url.host == "join" { ReaderDelegate.pendingInvitation = url.lastPathComponent }
            }
        }
    }
}

final class ReaderDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated(unsafe) static var pendingInvitation: String?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    /// Asked once signed in, with books to hear about: never on the first screen.
    @MainActor static func askForNotifications() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MUSSET_READER_USER"] != nil { return }  // automated runs can't answer the prompt
        #endif
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
            if granted { DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() } }
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
        Task { @MainActor in await ReaderAPI.shared.register(device: token) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
        Task { @MainActor in await ReaderAPI.shared.refreshActivity() }
        return [.banner, .sound]
    }
}

// MARK: Signing in

struct SignInView: View {
    private var api: ReaderAPI { .shared }
    @State private var creating = false
    @State private var name = ""
    @State private var email = ""
    @State private var user = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Musset").font(.custom("EBGaramond-Regular", size: 44, relativeTo: .largeTitle))
                Text("Reader").font(.custom("EBGaramond-Italic", size: 20, relativeTo: .title3)).foregroundStyle(.secondary).padding(.top, 2)
                Text(L("The books authors share with you, set like books. Read, mark them up, talk with the author."))
                    .foregroundStyle(.secondary).padding(.top, 22)
                Picker("", selection: $creating) {
                    Text(L("Sign in")).tag(false)
                    Text(L("Create an account")).tag(true)
                }
                .pickerStyle(.segmented).padding(.top, 28)
                VStack(alignment: .leading, spacing: 8) {
                    if creating {
                        field(L("Your name, as authors will see it"), text: $name)
                        field(L("E-mail"), text: $email, keyboard: .emailAddress)
                    } else {
                        field(L("User name"), text: $user)
                    }
                    Text(L("Password")).font(.subheadline).foregroundStyle(.secondary).padding(.top, 6)
                    SecureField("", text: $password).textContentType(creating ? .newPassword : .password)
                        .padding(.horizontal, 14).frame(height: 48).background(.background, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
                }
                .padding(.top, 20)
                Button(action: go) {
                    HStack { if working { ProgressView().tint(.white) }; Text(creating ? L("Create my account") : L("Sign in")).fontWeight(.medium) }
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent).tint(.primary).padding(.top, 18)
                .disabled(working || password.isEmpty || (creating ? email.isEmpty : user.isEmpty))
                if let error { Text(error).font(.footnote).foregroundStyle(.red).padding(.top, 10) }
                Text(creating ? L("Free, for reading and marking up the books shared with you. An invitation link fills this in for you.")
                              : L("Got an invitation? Open its link: it brings you straight to the book."))
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 28)
            }
            .padding(.horizontal, 28).padding(.top, 72).padding(.bottom, 40)
        }
        .background(Color(red: 1, green: 0.996, blue: 0.984))
    }

    private func field(_ label: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            TextField("", text: text).keyboardType(keyboard).textInputAutocapitalization(keyboard == .default && label != L("User name") ? .words : .never)
                .autocorrectionDisabled().padding(.horizontal, 14).frame(height: 48)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
    }

    private func go() {
        working = true
        error = nil
        Task {
            do {
                if creating { try await api.signUp(email: email, password: password, name: name, invitation: ReaderDelegate.pendingInvitation) }
                else { try await api.signIn(username: user, password: password) }
                ReaderDelegate.pendingInvitation = nil
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

// MARK: Tabs

struct ReaderTabs: View {
    private var api: ReaderAPI { .shared }
    var body: some View {
        TabView {
            NavigationStack { ShelfView() }
                .tabItem { Label(L("Books"), systemImage: "book") }
            NavigationStack { ReaderActivityView() }
                .tabItem { Label(L("Activity"), systemImage: "bell") }
                .badge(api.activity.filter(\.isUnread).count)
            NavigationStack { ReaderCircleView() }
                .tabItem { Label(L("Circle"), systemImage: "person.2") }
        }
        .tint(.primary)
        .task { ReaderDelegate.askForNotifications() }
    }
}

struct ShelfView: View {
    private var api: ReaderAPI { .shared }

    private var shared: [RemoteBook] { api.books.filter { $0.owner.login != api.username } }
    private var mine: [RemoteBook] { api.books.filter { $0.owner.login == api.username } }

    var body: some View {
        List {
            if api.books.isEmpty {
                Text(L("No book shared with you yet. When an author shares one, it appears here.")).foregroundStyle(.secondary)
            }
            if !shared.isEmpty { Section(L("Shared with me")) { ForEach(shared) { row($0) } } }
            if !mine.isEmpty { Section(L("My books")) { ForEach(mine) { row($0) } } }
        }
        .listStyle(.plain)
        .navigationTitle(L("Books"))
        .refreshable { await api.refreshAll() }
        .navigationDestination(for: RemoteBook.self) { BookReaderView(book: $0) }
    }

    private func row(_ b: RemoteBook) -> some View {
        let news = api.activity.filter { $0.isUnread && $0.repo == b.full_name }
        return NavigationLink(value: b) {
            HStack(alignment: .top, spacing: 12) {
                Circle().fill(news.isEmpty ? .clear : Color.accentColor).frame(width: 8, height: 8).padding(.top, 9)
                VStack(alignment: .leading, spacing: 3) {
                    Text(b.title).font(.custom("EBGaramond-Regular", size: 21, relativeTo: .title3))
                    Text(b.author).font(.subheadline).foregroundStyle(.secondary)
                    if let first = news.first { Text(first.sentence).font(.subheadline).foregroundStyle(Color.accentColor).lineLimit(1) }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: Reading

struct BookReaderView: View {
    let book: RemoteBook
    private var api: ReaderAPI { .shared }
    @State private var manifest: BookManifest?
    @State private var chapter: ChapterEntry?
    @State private var text = ""
    @State private var entries: [TalkEntry] = []
    @State private var ref = "main"
    @State private var milestones: [Milestone] = []
    /// The milestone the author gave me, asked once when the book opens: it is what I read.
    @State private var given: String?
    @State private var askedGiven = false
    @State private var openThread: UUID?
    @State private var reader: ReaderModel?
    @State private var error: String?

    private var threads: [TalkThread] { Talk.threads(from: entries) }
    private var me: String { api.username ?? "" }

    /// The open conversations of this chapter, drawn on its pages.
    private var marks: [MussetPage.Mark] {
        threads.filter { $0.chapter == chapter?.id && !$0.isResolved }.compactMap { $0.pageMark(in: text, name: name) }
    }

    private func name(_ user: String) -> String { user == me ? L("You") : user == book.owner.login ? book.author : user }

    /// The book's template, shipped in the app: the pages are set as the printed book's.
    private static let template = Bundle.main.url(forResource: "musset", withExtension: "typ").flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    var body: some View {
        Group {
            if let error { Text(error).foregroundStyle(.secondary).padding() }
            else if chapter == nil { ProgressView() }
            else if let reader {
                PageView(model: reader, showsThumbnails: UIDevice.current.userInterfaceIdiom == .pad)
                    .ignoresSafeArea(edges: .bottom)
            }
        }
        .navigationTitle(chapter.map { manifest?.shownTitle(of: $0) ?? $0.title } ?? book.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let m = manifest {
                        if m.hasForm {
                            // A formed book: its pieces under its own words and numbers, group by group.
                            ForEach(Self.runs(m), id: \.id) { run in
                                Section(run.title) {
                                    ForEach(run.pieces) { ch in
                                        Button(m.numberedTitle(of: ch)) { Task { await open(ch) } }
                                    }
                                }
                            }
                        } else {
                            Section(L("Chapters")) {
                                ForEach(m.chapters.filter { !$0.excludeFromExport }) { ch in
                                    Button(ch.title) { Task { await open(ch) } }
                                }
                            }
                        }
                    }
                    // The author chooses among every version; a reader given a milestone reads that one.
                    if !milestones.isEmpty, given == nil {
                        Section(L("Version")) {
                            Button(L("Latest")) { ref = "main"; Task { await reload() } }
                            ForEach(milestones) { m in Button(m.title) { ref = m.name; Task { await reload() } } }
                        }
                    }
                    if let reader {
                        Section {
                            Button(L("Larger Text")) { reader.textSize = min(reader.textSize + 2, 28) }
                            Button(L("Smaller Text")) { reader.textSize = max(reader.textSize - 2, 13) }
                            Toggle(L("Night"), isOn: Binding(get: { reader.theme.isNight }, set: { reader.theme = $0 ? .night : .day }))
                        }
                    }
                } label: { Image(systemName: "textformat.size") }
                .accessibilityLabel(L("Reading options"))
            }
        }
        .sheet(isPresented: Binding(get: { openThread != nil }, set: { if !$0 { openThread = nil } })) {
            if let id = openThread, let t = threads.first(where: { $0.id == id }) {
                ThreadSheet(thread: t, me: me, owner: book.owner.login, quote: t.note.anchor?.quote ?? "",
                            reply: { say(TalkEntry(thread: t.id, kind: .reply, by: me, body: $0, chapter: t.chapter), notify: Array(t.people.subtracting([me]))) },
                            resolve: { say(TalkEntry(thread: t.id, kind: $0 ? .resolve : .reopen, by: me, chapter: t.chapter), notify: []) })
                    .presentationDetents([.medium, .large])
            }
        }
        .task { await load() }
    }

    private func load() async {
        do {
            if !askedGiven {
                askedGiven = true
                if book.owner.login != me, let tag = await api.givenMilestone(book) { given = tag; ref = tag }
            }
            milestones = await api.milestones(book)
            let m = try await api.manifest(book, at: ref)
            manifest = m
            if let first = chapter.flatMap({ c in m.chapters.first { $0.id == c.id } }) ?? m.chapters.first(where: { !$0.excludeFromExport }) {
                await open(first)
            }
        } catch { self.error = error.localizedDescription }
    }

    private func reload() async { chapter = nil; await load() }

    private func open(_ ch: ChapterEntry) async {
        do {
            text = String(decoding: try await api.file(book, ch.file, at: ref), as: UTF8.self)
            chapter = ch
            entries = await api.talk(book, chapters: manifest?.chapters.map(\.id) ?? [ch.id])
            show(ch)
        } catch { self.error = error.localizedDescription }
    }

    /// The pieces a reader can open, as the book's form lists them: each group under its line (« Acte II. La fuite »),
    /// the pieces outside any group under the level's name (« Scènes »).
    static func runs(_ m: BookManifest) -> [(id: String, title: String, pieces: [ChapterEntry])] {
        var out: [(id: String, title: String, pieces: [ChapterEntry])] = []
        var last: String?
        for ch in m.chapters where !ch.excludeFromExport {
            let group = m.group(of: ch)
            let id = group?.id ?? ""
            if last == id { out[out.count - 1].pieces.append(ch); continue }
            last = id
            let title = group.map { g in [m.heading(of: g), m.numeral(of: g.id).isEmpty ? "" : g.title].filter { !$0.isEmpty }.joined(separator: ". ") }
            out.append((id + "#\(out.count)", title ?? m.level(.piece).plural, [ch]))
        }
        return out
    }

    /// The chapter on the reading engine's pages, with everyone's marks; selecting marks, tapping opens the thread.
    private func show(_ ch: ChapterEntry) {
        guard let template = Self.template else { error = "musset.typ is not in the app."; return }
        // A formed book's piece opens under its own line (« Scène 2 », « Prologue »), as in the printed book.
        let pieces = manifest?.typesetChapters([(id: ch.id, text: text)], groups: false) ?? [.init(id: ch.id, markdown: text)]
        let source = BookSource(chapters: pieces, template: template, style: "book",
                                title: manifest?.title ?? book.title, author: manifest?.author ?? "", lang: manifest?.lang ?? "en",
                                layout: PageLayout(numbered: false, titlePage: false), sceneBreak: manifest?.sceneBreak?.rawValue,
                                fontDirectories: [Bundle.main.resourceURL].compactMap { $0 }, systemFonts: false, form: manifest?.typesetForm, text: manifest?.typesetText ?? .init())
        if let reader {
            reader.source = source
            reader.marks = marks
            return
        }
        let m = ReaderModel(source: source, marks: marks)
        m.strings = .musset
        m.textSize = 18
        m.ownInk = Person.ink(me)
        m.onAction = { action, sel in
            let (kind, body) = action.talk
            mark(NSRange(location: sel.range.lowerBound, length: sel.range.count), kind, body: body)
        }
        m.onOpen = { openThread = UUID(uuidString: $0.id) }
        reader = m
    }

    private func mark(_ range: NSRange, _ kind: TalkEntry.Mark, body: String) {
        guard let ch = chapter else { return }
        let id = UUID()
        let anchor = Anchoring.capture(range, in: text as NSString, version: nil)
        let entry = TalkEntry(id: id, thread: id, kind: .note, by: me, body: body, chapter: ch.id, anchor: anchor, mark: kind,
                              color: Person.palette.firstIndex(of: Person.color(me)) ?? 0,
                              milestone: ref == "main" ? nil : ref)
        say(entry, notify: book.owner.login == me ? [] : [book.owner.login])
    }

    /// Saves my file for the chapter on my branch, and tells the others (a digest on their side).
    private func say(_ entry: TalkEntry, notify: [String]) {
        entries.append(entry)
        reader?.marks = marks
        let mine = entries.filter { $0.by == me && $0.chapter == entry.chapter }
        Task {
            do {
                try await api.save(mine, chapter: entry.chapter, in: book)
                if entry.kind == .note || entry.kind == .reply {
                    await api.notify(entry.kind == .note ? "note" : "reply", book: book, recipients: notify, message: entry.body, thread: entry.thread, chapter: entry.chapter)
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct ThreadSheet: View {
    let thread: TalkThread
    let me: String
    let owner: String
    let quote: String
    var reply: (String) -> Void
    var resolve: (Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    private var api: ReaderAPI { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(thread.isResolved ? L("Resolved") : (thread.waits(for: me, owner: owner) ? L("Your turn") : L("Waiting for an answer")))
                    .font(.subheadline.weight(.medium)).foregroundStyle(thread.waits(for: me, owner: owner) ? Color.accentColor : .secondary)
                Spacer()
            }
            if !quote.isEmpty {
                Text(quote).font(.custom("EBGaramond-Regular", size: 17, relativeTo: .body)).foregroundStyle(.secondary)
                    .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(Person.color(thread.starter)).frame(width: 2) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach([thread.note] + thread.replies) { e in
                        HStack(alignment: .top, spacing: 10) {
                            Text(initials(e.by)).font(.caption.weight(.semibold)).foregroundStyle(e.by == me ? .white : Person.color(e.by))
                                .frame(width: 30, height: 30)
                                .background(e.by == me ? Color.primary : Person.color(e.by).opacity(0.15), in: Circle())
                            VStack(alignment: .leading, spacing: 3) {
                                Text((e.by == me ? L("You") : name(e.by)) + " · " + e.at.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.secondary)
                                if !e.body.isEmpty { Text(e.body) }
                            }
                        }
                    }
                }
            }
            if !thread.isResolved {
                TextField(L("Reply…"), text: $text, axis: .vertical).lineLimit(2...6)
                    .padding(12).background(.background, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
            }
            HStack(spacing: 10) {
                Button(thread.isResolved ? L("Reopen") : L("Resolve")) { resolve(!thread.isResolved); dismiss() }
                    .buttonStyle(.bordered).frame(maxWidth: .infinity, minHeight: 44)
                if !thread.isResolved {
                    Button(L("Reply")) { reply(text.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                        .buttonStyle(.borderedProminent).tint(.primary).frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .padding(20)
    }

    private func name(_ user: String) -> String { api.circle.first { $0.username == user }?.name ?? user }
    private func initials(_ user: String) -> String {
        name(user).split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
    }
}

// MARK: Activity and circle

struct ReaderActivityView: View {
    private var api: ReaderAPI { .shared }
    var body: some View {
        List {
            if api.activity.isEmpty { Text(L("Nothing yet. Milestones, notes and replies in the books you share show here.")).foregroundStyle(.secondary) }
            ForEach(api.activity.prefix(100)) { item in
                HStack(alignment: .top, spacing: 12) {
                    Circle().fill(item.isUnread ? Color.accentColor : .clear).frame(width: 8, height: 8).padding(.top, 7)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.sentence)
                        if let m = item.message, !m.isEmpty { Text("“" + m + "”").font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        Text(item.date.formatted(.relative(presentation: .named))).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                .onTapGesture { Task { await api.markRead([item.id]) } }
            }
        }
        .listStyle(.plain)
        .navigationTitle(L("Activity"))
        .refreshable { await api.refreshActivity() }
    }
}

struct ReaderCircleView: View {
    private var api: ReaderAPI { .shared }
    @State private var confirmDelete = false
    @State private var error: String?

    var body: some View {
        List {
            Section(L("Your circle")) {
                if api.circle.isEmpty { Text(L("The people who share books with you appear here.")).foregroundStyle(.secondary) }
                ForEach(api.circle) { p in
                    HStack {
                        Text(p.name)
                        Spacer()
                        Text(Relation(rawValue: p.relation)?.label ?? "").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text(api.username.map { L("Signed in as \($0)") } ?? "").foregroundStyle(.secondary)
                Button(L("Sign out")) { api.signOut() }
                Button(L("Delete my account"), role: .destructive) { confirmDelete = true }
            }
            if let error { Text(error).foregroundStyle(.red) }
        }
        .navigationTitle(L("Circle"))
        .confirmationDialog(L("Delete your Musset account? Your notes are deleted with it; the books stay with their authors."), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete my account"), role: .destructive) { Task { do { try await api.deleteAccount() } catch { self.error = error.localizedDescription } } }
        }
    }
}
