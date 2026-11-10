import AppKit
import SwiftUI

/// Sign in or create an account. Used by the account sheet and the book's sharing page.
struct AccountForm: View {
    var signedIn: () async -> Void = {}
    private var collab: Collab { .shared }
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var creating = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Segmented(options: [(false, L("Sign in")), (true, L("Create an account"))], selection: $creating)
                .frame(width: 300)
            TextField(L("User name"), text: $name).textFieldStyle(.roundedBorder).frame(width: 300)
            if creating { TextField(L("Email"), text: $email).textFieldStyle(.roundedBorder).frame(width: 300) }
            SecureField(creating ? L("Password (10 characters or more)") : L("Password"), text: $password)
                .textFieldStyle(.roundedBorder).frame(width: 300).onSubmit(go)
            HStack(spacing: 12) {
                Button(creating ? L("Create the account") : L("Sign in"), action: go)
                    .buttonStyle(.ink).disabled(working || name.isEmpty || password.isEmpty || (creating && email.isEmpty))
                if working { ProgressView().controlSize(.small) }
                if !creating {
                    Button(L("Forgot your password?")) {
                        NSWorkspace.shared.open(Collab.server.appendingPathComponent("user/forgot_password"))
                    }
                    .buttonStyle(.link).font(.ui(12))
                }
            }
            if let error { Text(error).font(.ui(12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            Text(L("Your password isn't kept: this Mac gets its own key, in the Keychain."))
                .font(.ui(12)).foregroundStyle(.secondary)
        }
    }

    private func go() {
        guard !name.isEmpty, !password.isEmpty else { return }
        working = true
        error = nil
        Task {
            do {
                if creating { try await collab.signUp(username: name, email: email, password: password) }
                else { try await collab.signIn(username: name, password: password) }
                password = ""
                await signedIn()
            } catch { self.error = error.localizedDescription }
            working = false
        }
    }
}

/// The account: what it brings, and the books on it, with those not yet on this Mac.
struct AccountSheet: View {
    let app: AppState
    private var collab: Collab { .shared }
    @Environment(\.dismiss) private var dismiss
    @State private var books: [Collab.Repo] = []
    @State private var loading = false
    @State private var downloading: Int?
    @State private var error: String?

    /// Folders of the library that come from a repository.
    private var local: [String: String] {
        var out: [String: String] = [:]
        for path in app.libraryPaths {
            for url in GitService(root: URL(fileURLWithPath: path)).remotes().values { out[url] = path }
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("Musset account")).font(.system(size: 24, design: .serif))
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark").font(.ui(12)) }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel(L("Close"))
            }
            if collab.signedIn { account } else {
                Text(L("Your books on all your Macs, kept in sync, with their whole history. Share one with an editor or a collaborator, and see who wrote what. Without an account, everything stays on this Mac."))
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                AccountForm { await load() }
            }
        }
        .padding(24)
        .frame(width: 560)
        .font(.ui(13))
        .task { await load() }
    }

    private var account: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L("Signed in as ") + (collab.username ?? "")).foregroundStyle(.secondary)
                Button(L("Sign out")) { collab.signOut(); books = [] }.buttonStyle(.link)
            }
            Toggle(L("Send my books to my account and keep them in sync"), isOn: Binding(get: { collab.autoSync }, set: { collab.autoSync = $0 }))
                .toggleStyle(.checkbox)
            Text(L("Books stay private, in private repositories on \(Collab.server.host ?? ""). Anyone administering the server could read them: they aren't encrypted there."))
                .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SectionLabel(L("MY BOOKS ONLINE"))
            if loading { ProgressView().controlSize(.small) }
            else if books.isEmpty { Text(L("No book on your account yet. Open one here and it goes up.")).foregroundStyle(.secondary) }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(books) { row($0) }
                }
            }
            .frame(maxHeight: 320)
            if let error { Text(error).font(.ui(12)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
    }

    private func row(_ r: Collab.Repo) -> some View {
        let path = local[r.clone_url]
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(r.description?.nilIfEmpty ?? r.name).fontWeight(.medium)
                Text(r.owner.login == collab.username ? (path == nil ? L("Not on this Mac") : L("On this Mac")) : L("by ") + r.owner.login)
                    .font(.ui(12)).foregroundStyle(.secondary)
            }
            Spacer()
            if downloading == r.id { ProgressView().controlSize(.small) }
            if let path {
                Button(L("Open")) { app.openBook(URL(fileURLWithPath: path)); app.showHome = false; dismiss() }.buttonStyle(.inkSecondary)
            } else {
                Button(L("Download")) { download(r) }.buttonStyle(.ink).disabled(downloading != nil)
            }
        }
    }

    private func load() async {
        guard collab.signedIn else { return }
        loading = true
        do { books = try await collab.onlineBooks(); error = nil } catch { self.error = error.localizedDescription }
        loading = false
    }

    private func download(_ r: Collab.Repo) {
        let writings = BookStore.defaultFolder
        var folder = writings.appendingPathComponent(r.owner.login == collab.username ? r.name : "\(r.owner.login)-\(r.name)")
        var n = 2
        while FileManager.default.fileExists(atPath: folder.path) { folder = writings.appendingPathComponent("\(r.name)-\(n)"); n += 1 }
        downloading = r.id
        error = nil
        Task {
            do {
                try FileManager.default.createDirectory(at: writings, withIntermediateDirectories: true)
                try await collab.open(r, into: folder)
                app.openBook(folder)
                app.showHome = false
                dismiss()
            } catch { self.error = error.localizedDescription }
            downloading = nil
        }
    }
}
