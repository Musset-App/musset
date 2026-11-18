import AppKit
import SwiftUI

/// Sign in or create an account. Used by Home's account column and the book's sharing page.
/// A new account is free: a name, an e-mail and a password; the server makes the user name from the e-mail.
struct AccountForm: View {
    var invitation: String? = nil
    /// Home's column is narrower than a settings page.
    var width: CGFloat = 300
    var signedIn: () async -> Void = {}
    private var collab: Collab { .shared }
    @State private var name = ""
    @State private var fullName = ""
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Segmented(options: [(false, L("Sign in")), (true, L("Create an account"))], selection: $creating)
                .frame(width: width)
            if creating {
                TextField(L("Your name, as others will see it"), text: $fullName).textFieldStyle(.roundedBorder).frame(width: width)
                TextField(L("Email"), text: $email).textFieldStyle(.roundedBorder).frame(width: width)
            } else {
                TextField(L("User name"), text: $name).textFieldStyle(.roundedBorder).frame(width: width)
            }
            SecureField(creating ? L("Password (10 characters or more)") : L("Password"), text: $password)
                .textFieldStyle(.roundedBorder).frame(width: width).onSubmit(go)
            // In a narrow column the link goes under the button rather than off its edge.
            let row = width < 300 ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 12))
            row {
                HStack(spacing: 12) {
                    Button(creating ? L("Create the account") : L("Sign in"), action: go)
                        .buttonStyle(.ink).disabled(working || password.isEmpty || (creating ? email.isEmpty : name.isEmpty))
                    if working { ProgressView().controlSize(.small) }
                }
                if !creating {
                    Button(L("Forgot your password?")) {
                        NSWorkspace.shared.open(Collab.server.appendingPathComponent("user/forgot_password"))
                    }
                    .buttonStyle(.link).font(.ui(12))
                }
            }
            if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
            Text(creating ? L("Free, to read and annotate the books shared with you. Putting your own books online is Musset Sync.")
                          : L("Your password isn't kept: this Mac gets its own key, in the Keychain."))
                .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(width: width, alignment: .leading)
        }
    }

    private func go() {
        guard !password.isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                if creating { try await collab.signUp(email: email, password: password, name: fullName, invitation: invitation) }
                else {
                    try await collab.signIn(username: name, password: password)
                    if let invitation { try? await collab.acceptInvitation(invitation) }
                }
                password = ""
                await signedIn()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

/// The account, down the left of Home: who you are, what you have, where things are. Signed out, what an
/// account brings and the form to get one; the books beside it need neither.
struct AccountColumn: View {
    @Bindable var app: AppState
    let account: HomeAccount
    let library: HomeLibrary
    /// The section shown, which is the books whenever nobody is signed in.
    let section: HomeSection
    static let width: CGFloat = 264

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if account.signedIn { signedIn } else { signedOut }
        }
        .font(.ui(13))
        .padding(.horizontal, 16).padding(.top, 56).padding(.bottom, 18)
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Ink.side)
        .overlay(alignment: .trailing) { Rectangle().fill(Ink.hairline).frame(width: 1) }
    }

    @ViewBuilder private var signedIn: some View {
        HStack(spacing: 10) {
            Text(account.initials).font(.ui(13, .semibold)).foregroundStyle(Ink.accent)
                .frame(width: 36, height: 36).background(Ink.accent.opacity(0.16), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name).font(.ui(13, .semibold)).lineLimit(1)
                Text(account.writer ? L("Writer account") + " · Musset Sync" : L("Free account"))
                    .font(.ui(11.5)).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8).padding(.bottom, 14)
        ForEach(HomeSection.holdings) { row($0) }
        Rectangle().fill(Ink.hairline).frame(height: 1).padding(.horizontal, 8).padding(.vertical, 10)
        ForEach(HomeSection.settings) { row($0) }
        Spacer(minLength: 12)
        VStack(alignment: .leading, spacing: 3) {
            Text(planLine)
            Text(account.writer ? L("Your books on all your Macs, and on your readers’ iPhones.")
                                : L("Read, annotate and talk about the books shared with you, on Mac, iPhone and iPad."))
        }
        .font(.ui(11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
        Button(L("Sign out")) { Collab.shared.signOut(); app.homeSection = .books }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .padding(.horizontal, 10).frame(height: 30)
    }

    /// The plan in a line: free, offered, or Musset Sync with the day it renews when the server said.
    private var planLine: String {
        guard account.writer else { return L("Free account") }
        if account.comp { return L("Musset Sync, offered.") }
        return "Musset Sync" + (account.renews.map { " · " + L("renews \($0.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(UILang.locale)))") } ?? "")
    }

    private func row(_ s: HomeSection) -> some View {
        let on = s == section
        return Button { app.homeSection = s } label: {
            HStack {
                Text(s.label).foregroundStyle(on ? .primary : .secondary)
                Spacer()
                if let n = library.count(s, account: account) {
                    if s == .activity {
                        // Only what is unread counts here, and it shows as a badge.
                        if n > 0 {
                            Text("\(n)").font(.ui(11, .semibold)).foregroundStyle(Ink.onAccent)
                                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18).background(Ink.accent, in: Capsule())
                                .accessibilityLabel(L("Unread") + " \(n)")
                        }
                    } else {
                        Text("\(n)").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(on ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: Radius.row))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fontWeight(on ? .medium : .regular)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    @ViewBuilder private var signedOut: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Musset Account…").titled).font(.system(size: 20, design: .serif))
            Text(app.pendingInvitation != nil
                 ? L("Sign in or create your free account to open the book you were invited to read.")
                 : L("A free account reads and annotates the books people share with you. Musset Sync puts your own books online, on all your Macs, and lets you share them."))
                .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            AccountForm(invitation: app.pendingInvitation, width: Self.width - 32) { app.pendingInvitation = nil }
                .padding(.top, 4)
        }
    }
}

/// A page of the account in Home's main area: its title, as the books have theirs.
struct AccountPageTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View { Text(text).font(.system(size: 30, design: .serif)) }
}

/// The books other people shared with me: open the ones on this Mac, download the others.
struct SharedBooksSection: View {
    let books: [SharedBook]
    /// The repository being downloaded, if one is.
    let downloading: Int?
    let open: (SharedBook) -> Void
    private var collab: Collab { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AccountPageTitle(L("Shared with me"))
            if books.isEmpty { Text(L("No book shared with you yet.")).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(books) { row($0) }
            }
            .frame(maxWidth: 720)
            if let e = collab.lastError { Text(e).font(.ui(12)).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func row(_ b: SharedBook) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(b.title).fontWeight(.medium)
                Text(L("by \(b.owner)") + " · " + (b.path == nil ? L("Not on this Mac") : L("On this Mac")))
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if let id = b.repo?.id, downloading == id { ProgressView().controlSize(.small) }
            if b.path != nil {
                Button(L("Open")) { open(b) }.buttonStyle(.inkSecondary)
            } else {
                Button(L("Download")) { open(b) }.buttonStyle(.ink).disabled(downloading != nil)
            }
        }
    }
}

/// The people who read my books, and those I read for: add someone, remove someone, see who was only invited.
struct CircleSection: View {
    /// A writer's circle reads their books; a free account's is who they read for.
    let writer: Bool
    private var collab: Collab { .shared }
    @State private var who = ""
    @State private var relation = Relation.betaReader
    @State private var adding = false
    @State private var added: String?
    @State private var removing: CirclePerson?
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top, spacing: 32) {
            VStack(alignment: .leading, spacing: 18) {
                AccountPageTitle(L("My circle"))
                Text(writer ? L("The people who read your books. Share a book with any of them in two clicks.")
                            : L("The people you read for, and the people they work with."))
                    .foregroundStyle(.secondary)
                if collab.circle.isEmpty {
                    Text(L("No one yet. Add someone, or share a book: the people you share with join your circle, and you theirs."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Relation.allCases) { rel in
                    let people = collab.circle.filter { Relation(rawValue: $0.relation) ?? .other == rel }
                    if !people.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel(rel.heading)
                            VStack(spacing: 0) {
                                ForEach(people) { p in
                                    personRow(p)
                                    if p != people.last { Divider() }
                                }
                            }
                            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
                        }
                    }
                }
            }
            .frame(maxWidth: 640, alignment: .leading)

            VStack(alignment: .leading, spacing: 10) {
                Text(L("Add someone")).font(.ui(14, .semibold))
                Text(L("E-mail or Musset name")).font(.ui(12)).foregroundStyle(.secondary)
                TextField("", text: $who).textFieldStyle(.roundedBorder).onSubmit(add)
                Text(L("They are your")).font(.ui(12)).foregroundStyle(.secondary)
                Picker("", selection: $relation) { ForEach(Relation.allCases) { Text($0.label).tag($0) } }.labelsHidden()
                Text(L("Someone without Musset gets an e-mail. Their account is free, and always will be."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Add to my circle"), action: add).buttonStyle(.ink).disabled(who.trimmingCharacters(in: .whitespaces).isEmpty || adding)
                    if adding { ProgressView().controlSize(.small) }
                }
                if let added { Text(added).font(.ui(12)).foregroundStyle(.secondary) }
                if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true) }
            }
            .frame(width: 240)
            .padding(.top, 8)
        }
        .confirmationDialog(removing.map { L("Remove \($0.name) from your circle?") } ?? "",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(L("Remove"), role: .destructive) {
                if let p = removing { Task { try? await collab.removeFromCircle(p) } }
                removing = nil
            }
            Button(L("Cancel"), role: .cancel) { removing = nil }
        }
    }

    private func personRow(_ p: CirclePerson) -> some View {
        HStack(spacing: 12) {
            Text(p.isPending ? "@" : p.initials).font(.ui(11, .semibold)).foregroundStyle(p.isPending ? .secondary : Person.color(p.username ?? ""))
                .frame(width: 30, height: 30)
                .background(p.isPending ? Color.clear : Person.color(p.username ?? "").opacity(0.15), in: Circle())
                .overlay(Circle().strokeBorder(p.isPending ? Ink.hairline : .clear, style: StrokeStyle(lineWidth: 1, dash: [3])))
            VStack(alignment: .leading, spacing: 1) {
                Text(p.name).fontWeight(.medium)
                Text(p.isPending ? L("Invited, no account yet") : (p.username.map { "@" + $0 } ?? ""))
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if !p.books.isEmpty {
                Text(p.books.map { $0.split(separator: "/").last.map(String.init) ?? $0 }.joined(separator: ", "))
                    .font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Menu {
                Button(L("Remove from my circle…"), role: .destructive) { removing = p }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel(L("More"))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func add() {
        let value = who.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        adding = true
        error = nil
        Task {
            do {
                try await collab.addToCircle(value, relation: relation, lang: UILang.current.localeID)
                added = value.contains("@") ? L("Invitation sent.") : L("Added.")
                who = ""
            } catch { self.error = error.localizedDescription }
            adding = false
        }
    }
}

/// What reaches the author by e-mail; Musset itself always shows everything.
struct NoticesSection: View {
    private var collab: Collab { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AccountPageTitle(L("Notifications"))
            Text(L("Musset always shows what happened in the books, here and on your iPhone. By e-mail:")).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { collab.account?.mail ?? "digest" }, set: { v in Task { await collab.setMailPreference(v) } })) {
                Text(L("Milestones at once, notes and replies grouped (an hour after the last one)")).tag("digest")
                Text(L("Everything at once")).tag("instant")
                Text(L("Never")).tag("never")
            }
            .pickerStyle(.radioGroup).labelsHidden()
        }
    }
}

/// Free or writer, what each brings, the way to billing, and whether a writer's books go online on their own.
struct PlanSection: View {
    let app: AppState
    let account: HomeAccount
    private var collab: Collab { .shared }
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            AccountPageTitle(L("Plan and billing"))
            if account.writer {
                Text(L("WRITER")).font(.ui(11, .semibold)).tracking(0.8).foregroundStyle(Ink.accent)
                if account.comp {
                    Text(L("Musset Sync, offered."))
                } else {
                    Text(SyncPrice.perMonth + (account.renews.map { " · " + L("renews \($0.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(UILang.locale)))") } ?? ""))
                    Button(L("Manage billing")) { Task { do { try await collab.manageBilling() } catch { self.error = error.localizedDescription } } }
                        .buttonStyle(.inkSecondary)
                }
                Toggle(L("Send my books to my account and keep them in sync"), isOn: Binding(get: { collab.autoSync }, set: { collab.autoSync = $0 }))
                    .toggleStyle(.checkbox).padding(.top, 8)
            } else {
                Text(L("FREE")).font(.ui(11, .semibold)).tracking(0.8).foregroundStyle(.secondary)
                Text(L("Read, annotate and talk about the books shared with you, on Mac, iPhone and iPad."))
                Text(L("Musset Sync puts your own books online, on all your Macs, and lets you share them. The people you invite don’t pay."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button(L("Musset Sync, \(SyncPrice.perMonth)…")) { app.offerSync(for: app.current) }.buttonStyle(.ink)
            }
            Text(L("Books stay private on \(Collab.server.host ?? ""). Anyone administering the server could read them: they aren't encrypted there."))
                .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error) }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}
