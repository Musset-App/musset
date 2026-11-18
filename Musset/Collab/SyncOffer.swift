import AppKit
import SwiftUI

/// Musset Sync: the writer account. 4.99 a month, in euros in the euro area and dollars elsewhere; Stripe decides at checkout.
enum SyncPrice {
    static var amount: Decimal { 4.99 }
    static var currency: String { Locale.current.currency?.identifier == "EUR" ? "EUR" : "USD" }
    static var label: String { amount.formatted(.currency(code: currency).locale(UILang.locale)) }
    /// « €4.99 a month ».
    static var perMonth: String { L("\(label) a month") }
}

/// The offer, from the three places it is made (the new book, « Not synced », the first chapter done) and from Sharing.
struct SyncOfferSheet: View {
    let app: AppState
    @Environment(\.dismiss) private var dismiss
    private var collab: Collab { .shared }
    @State private var email = ""
    @State private var password = ""
    @State private var haveAccount = false
    @State private var name = ""
    @State private var working = false
    @State private var waitingForStripe = false
    @State private var error: String?

    private var bookTitle: String? {
        guard let url = app.syncOfferBook else { return nil }
        return app.current?.root.standardizedFileURL == url.standardizedFileURL ? app.current?.title : nil
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(L("MUSSET SYNC")).font(.ui(11, .semibold)).tracking(0.8).foregroundStyle(Ink.accent)
                Text(bookTitle.map { L("\($0), on all your Macs. And never lost.") } ?? L("Your books on all your Macs. And never lost."))
                    .font(.system(size: 26, design: .serif)).padding(.top, 8).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 14) {
                    point(L("Safe, with its whole history"), L("Every version, every note and every milestone, kept off this Mac. A lost laptop costs you a laptop, not a book."))
                    point(L("The same book on every Mac"), L("Write on the train, pick up at the desk. Offline first: it syncs when you are back."))
                    point(L("Your first readers, inside the book"), L("Invite an editor or beta readers. Their corrections come back for you to accept or reject, and you see who wrote what."))
                    point(L("They don’t pay"), L("Only you subscribe. Only the people you invite can open the book."))
                }
                .padding(.top, 22)
                Spacer(minLength: 16)
                Text(L("Musset stays free without it. Your book always lives on your Mac too, as plain files."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 0) {
                Text(SyncPrice.label).font(.system(size: 42, design: .serif))
                Text(L("a month, for all your books")).font(.ui(13)).foregroundStyle(.secondary).padding(.top, 4)
                if waitingForStripe {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("Finish paying in your browser…")) }
                        Text(L("This window updates by itself once Stripe confirms.")).font(.ui(12)).foregroundStyle(.secondary)
                        Button(L("I have paid")) { Task { await collab.refreshAccount(); if collab.canSync { done() } } }.buttonStyle(.link)
                    }
                    .padding(.top, 26)
                } else if collab.signedIn {
                    Text(collab.username.map { L("Signed in as \($0)") } ?? "").font(.ui(12)).foregroundStyle(.secondary).padding(.top, 26)
                    Button(L("Subscribe and sync")) { subscribe() }.buttonStyle(.ink).disabled(working).padding(.top, 12)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        if !haveAccount {
                            Text(L("Your name")).font(.ui(12)).foregroundStyle(.secondary)
                            TextField("", text: $name).textFieldStyle(.roundedBorder)
                        }
                        Text(haveAccount ? L("User name") : L("E-mail")).font(.ui(12)).foregroundStyle(.secondary).padding(.top, 4)
                        TextField("", text: $email).textFieldStyle(.roundedBorder)
                        Text(L("Password")).font(.ui(12)).foregroundStyle(.secondary).padding(.top, 4)
                        SecureField("", text: $password).textFieldStyle(.roundedBorder).onSubmit(subscribe)
                    }
                    .padding(.top, 22)
                    Button(L("Subscribe and sync")) { subscribe() }.buttonStyle(.ink)
                        .disabled(working || email.isEmpty || password.isEmpty).padding(.top, 14)
                    Button(haveAccount ? L("I don’t have an account yet") : L("I already have an account")) { haveAccount.toggle() }
                        .buttonStyle(.link).font(.ui(12)).padding(.top, 10)
                }
                if working { ProgressView().controlSize(.small).padding(.top, 8) }
                if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error).fixedSize(horizontal: false, vertical: true).padding(.top, 8) }
                Text(L("Payment by Stripe, in your browser. Musset never sees your card.")).font(.ui(11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 10)
                Spacer(minLength: 12)
                Button(L("Not now")) { app.syncOfferBook = nil; dismiss() }.buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
            }
            .padding(28)
            .frame(width: 300, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Ink.side)
        }
        .frame(width: 760, height: 520)
        .font(.ui(13))
        .onReceive(NotificationCenter.default.publisher(for: Collab.becameWriter)) { _ in done() }
    }

    private func point(_ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark").font(.ui(12, .semibold)).foregroundStyle(Ink.accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(text).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func subscribe() {
        working = true
        error = nil
        Task {
            defer { working = false }
            do {
                if !collab.signedIn {
                    if haveAccount { try await collab.signIn(username: email, password: password) }
                    else { try await collab.signUp(email: email, password: password, name: name) }
                    password = ""
                }
                if collab.canSync { done(); return }
                try await collab.checkout()
                waitingForStripe = true
            } catch { self.error = error.localizedDescription }
        }
    }

    private func done() {
        waitingForStripe = false
        if let url = app.syncOfferBook, let s = app.current, s.root.standardizedFileURL == url.standardizedFileURL {
            collab.setLocalOnly(s, false)
            collab.opened(s)
        }
        app.syncOfferBook = nil
        dismiss()
    }
}

extension AppState {
    /// Offers Musset Sync, for this book if one is given.
    func offerSync(for session: BookSession?) {
        syncOfferBook = session?.root
        showSyncOffer = true
    }

    /// `musset://sync/done` (back from Stripe), `musset://join/<token>` (an invitation, already on Musset),
    /// `musset://open?repo=owner/name&tag=…` (from a notice).
    func open(mussetURL url: URL) {
        guard url.scheme == "musset" else { return }
        let collab = Collab.shared
        switch url.host {
        case "sync":
            Task { await collab.refreshAccount() }
        case "join":
            let token = url.lastPathComponent
            guard !token.isEmpty, token != "/" else { return }
            if collab.signedIn {
                Task {
                    // The book they were invited to read is now among those shared with them.
                    do { try await collab.acceptInvitation(token); try? await collab.refreshOnline() }
                    catch { collab.lastError = error.localizedDescription }
                    showAccount(.shared)
                }
            } else {
                // Home's sign-in form takes the invitation with the account.
                pendingInvitation = token
                showAccount()
            }
        case "open":
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard let repo = items.first(where: { $0.name == "repo" })?.value else { return }
            let suffix = "/" + repo + ".git"
            for path in libraryPaths where GitService(root: URL(fileURLWithPath: path)).remotes().values.contains(where: { $0.hasSuffix(suffix) }) {
                openBook(URL(fileURLWithPath: path))
                showHome = false
                return
            }
            // Not on this Mac: Home has it to download, among my books or those shared with me.
            showAccount(HomeSection.holding(repo: repo, username: collab.username))
        default:
            break
        }
    }
}
