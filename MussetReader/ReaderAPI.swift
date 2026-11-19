import Foundation
import Observation
import Security

/// Musset Reader's link to the server: the account (free for everyone), the books shared with me and my own,
/// the activity, and the conversations. No git on iOS: files are read with Forgejo's API, at a branch or a milestone,
/// and my notes are written to my own branch (`relecture/<me>`, or main for an author reading their own book).
@MainActor
@Observable
final class ReaderAPI {
    static let shared = ReaderAPI()
    static let server: URL = {
        #if DEBUG
        if let local = ProcessInfo.processInfo.environment["MUSSET_SERVER"], let url = URL(string: local) { return url }
        #endif
        return URL(string: "https://git.musset.app")!
    }()

    var username: String? = UserDefaults.standard.string(forKey: "readerUser") {
        didSet { UserDefaults.standard.set(username, forKey: "readerUser") }
    }
    var account: AccountInfo?
    var books: [RemoteBook] = []
    var activity: [ActivityItem] = []
    var circle: [CirclePerson] = []
    var lastError: String?

    /// Whether the keychain holds this account's key. Kept here, and not only read from the keychain, so the
    /// interface follows it: a user name remembered without its key (a phone restored from a backup) must leave the
    /// sign-in page once signed in again, although the name itself did not change.
    private var hasKey = !(Keychain.get("forgejo-token") ?? "").isEmpty

    var signedIn: Bool { username != nil && hasKey }

    private func keep(_ token: String) {
        Keychain.set("forgejo-token", token)
        hasKey = !(Keychain.get("forgejo-token") ?? "").isEmpty
    }

    // MARK: Account

    func signIn(username: String, password: String) async throws {
        struct Out: Decodable { let sha1: String }
        let out: Out = try await request("POST", api("users/\(username)/tokens"), body: [
            "name": "musset-reader-\(Int(Date().timeIntervalSince1970))",
            "scopes": ["write:repository", "write:issue", "write:user", "read:organization", "read:misc"]], basic: (username, password))
        keep(out.sha1)
        self.username = username
        await refreshAll()
    }

    /// An invitation opened from its e-mail by someone who already has an account (`musset://join/<token>`):
    /// the book it gives is theirs to read from now on.
    func acceptInvitation(_ token: String) async throws {
        let _: Empty = try await request("POST", mussetAPI("invitation/\(token)/accept"))
        await refreshAll()
    }

    /// What the author lets me do in this book: "reader", "editor" or "writer" (a co-writer). Nil when unknown.
    func role(in book: RemoteBook) async -> String? {
        struct Out: Decodable { let roles: [String: String] }
        guard let me = username else { return nil }
        let repo = book.full_name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? book.full_name
        let out: Out? = try? await request("GET", URL(string: mussetAPI("roles").absoluteString + "?repo=" + repo)!)
        return out?.roles[me]
    }

    /// A free account: reading and annotating. Apple's rules for reader apps: no price and no purchase in here.
    func signUp(email: String, password: String, name: String, invitation: String? = nil) async throws {
        struct Out: Decodable { let username: String; let token: String }
        var body: [String: Any] = ["email": email, "password": password, "name": name, "device": "iPhone", "lang": UILang.current.localeID]
        if let invitation { body["invitation"] = invitation }
        let out: Out = try await request("POST", mussetAPI("signup"), body: body)
        keep(out.token)
        username = out.username
        await refreshAll()
    }

    func signOut() {
        keep("")
        username = nil
        account = nil
        books = []
        activity = []
        circle = []
    }

    /// Apple asks that an account made in the app can be deleted in the app. The books it read stay with their authors.
    func deleteAccount() async throws {
        let _: Empty = try await request("DELETE", mussetAPI("account"))
        signOut()
    }

    func refreshAll() async {
        guard signedIn else { return }
        account = try? await request("GET", mussetAPI("account"))
        await refreshBooks()
        await refreshActivity()
        struct C: Decodable { let people: [CirclePerson] }
        circle = (try? await request("GET", mussetAPI("circle")) as C)?.people ?? []
    }

    func refreshActivity() async {
        struct Out: Decodable { let items: [ActivityItem] }
        if let out: Out = try? await request("GET", mussetAPI("activity")) { activity = out.items }
    }

    func markRead(_ ids: [Int]) async {
        let _: Empty? = try? await request("POST", mussetAPI("activity/read"), body: ["ids": ids])
        await refreshActivity()
    }

    func register(device token: Data) async {
        let hex = token.map { String(format: "%02x", $0) }.joined()
        let _: Empty? = try? await request("POST", mussetAPI("devices"), body: ["token": hex, "platform": "ios"])
    }

    // MARK: Books

    func refreshBooks() async {
        // Every repository I can read: mine and the ones shared with me. The documents' repositories are not books.
        let all: [RemoteBook] = (try? await request("GET", api("user/repos?limit=100"))) ?? []
        books = all.filter { !$0.name.hasSuffix("-documents") }
    }

    /// A file's text at a branch, tag or commit.
    func file(_ book: RemoteBook, _ path: String, at ref: String = "main") async throws -> Data {
        let escaped = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }.joined(separator: "/")
        let url = URL(string: api("repos/\(book.full_name)/raw/\(escaped)").absoluteString + "?ref=" + (ref.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ref))!
        return try await raw(url)
    }

    func manifest(_ book: RemoteBook, at ref: String = "main") async throws -> BookManifest {
        try BookManifest.forReading(try await file(book, ".musset/book.json", at: ref))
    }

    func branches(_ book: RemoteBook) async -> [String] {
        struct B: Decodable { let name: String }
        return ((try? await request("GET", api("repos/\(book.full_name)/branches?limit=100")) as [B]?) ?? []).map(\.name)
    }

    /// What the author gave me of this book: a milestone (readers read one the author chose, never the text as it is
    /// being written), and the part of it I read (none is the whole book).
    func given(_ book: RemoteBook) async -> (tag: String, scope: ReadingScope?)? {
        struct Reading: Decodable { let tag: String; let scope: ReadingScope? }
        struct Out: Decodable { let reading: [String: Reading] }
        guard let me = username else { return nil }
        let repo = book.full_name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? book.full_name
        let out: Out? = try? await request("GET", URL(string: mussetAPI("reading").absoluteString + "?repo=" + repo)!)
        return out?.reading[me].map { ($0.tag, $0.scope) }
    }

    /// Milestones (`jalon/…` tags), newest first.
    func milestones(_ book: RemoteBook) async -> [Milestone] {
        let tags: [Milestone] = (try? await request("GET", api("repos/\(book.full_name)/tags?limit=50"))) ?? []
        return tags.filter { $0.name.hasPrefix("jalon/") }
    }

    // MARK: Conversations

    /// Where my notes go: main for the book's author, my own branch for anyone else (made from main the first time).
    func myBranch(_ book: RemoteBook) async throws -> String {
        guard let me = username else { throw ReaderError.signedOut }
        if book.owner.login == me { return "main" }
        let branch = "relecture/\(me)"
        if !(await branches(book)).contains(branch) {
            let _: Empty = try await request("POST", api("repos/\(book.full_name)/branches"), body: ["new_branch_name": branch, "old_branch_name": "main"])
        }
        return branch
    }

    /// Everyone's entries for these chapters: the author's from main, each reader's from their branch.
    func talk(_ book: RemoteBook, chapters: [String]) async -> [TalkEntry] {
        guard let me = username else { return [] }
        var sources: [(ref: String, user: String)] = [("main", book.owner.login)]
        let all = await branches(book)
        if book.owner.login == me {
            sources += all.filter { $0.hasPrefix("relecture/") }.map { ($0, String($0.dropFirst("relecture/".count))) }
        } else {
            // What I said: on my branch, and what a review of mine already brought to main.
            sources.append(("main", me))
            if all.contains("relecture/\(me)") { sources.append(("relecture/\(me)", me)) }
        }
        var out: [TalkEntry] = []
        for (ref, user) in sources {
            for ch in chapters {
                let data = try? await file(book, Talk.path(user, ch), at: ref)
                out += Talk.decode(data).filter { $0.by == user }
            }
        }
        return out
    }

    /// Writes my file for a chapter on my branch: one commit per save. Kept for later when offline.
    func save(_ entries: [TalkEntry], chapter: String, in book: RemoteBook) async throws {
        guard let me = username else { throw ReaderError.signedOut }
        let branch = try await myBranch(book)
        let path = Talk.path(me, chapter)
        struct Existing: Decodable { let sha: String }
        let existing: Existing? = try? await request("GET", URL(string: api("repos/\(book.full_name)/contents/\(path)").absoluteString + "?ref=\(branch)")!)
        var body: [String: Any] = ["content": Talk.encode(entries).base64EncodedString(), "branch": branch,
                                   "message": "musset: notes by \(me)"]
        if let sha = existing?.sha { body["sha"] = sha }
        let _: Empty = try await request(existing == nil ? "POST" : "PUT", api("repos/\(book.full_name)/contents/\(path)"), body: body)
    }

    func notify(_ kind: String, book: RemoteBook, recipients: [String], message: String, thread: UUID, chapter: String) async {
        guard !recipients.isEmpty else { return }
        let _: Empty? = try? await request("POST", mussetAPI("notify"), body: [
            "repo": book.full_name, "kind": kind, "recipients": recipients, "message": String(message.prefix(300)),
            "thread": thread.uuidString, "chapter": chapter, "book": book.title])
    }

    // MARK: HTTP

    enum ReaderError: LocalizedError {
        case signedOut, server(String)
        var errorDescription: String? {
            switch self {
            case .signedOut: L("Sign in first.")
            case .server(let m): m
            }
        }
    }

    struct Empty: Decodable {}

    private func api(_ path: String) -> URL { URL(string: Self.server.absoluteString + "/api/v1/" + path)! }
    private func mussetAPI(_ path: String) -> URL { Self.server.appendingPathComponent("musset-api/" + path) }

    private func authorize(_ req: inout URLRequest, basic: (String, String)? = nil) {
        if let basic {
            req.setValue("Basic " + Data("\(basic.0):\(basic.1)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        } else if let t = Keychain.get("forgejo-token"), !t.isEmpty {
            req.setValue("token " + t, forHTTPHeaderField: "Authorization")
        }
    }

    private func raw(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url)
        authorize(&req)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0) else { throw ReaderError.server("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        return data
    }

    func request<T: Decodable>(_ method: String, _ url: URL, body: [String: Any]? = nil, basic: (String, String)? = nil) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req, basic: basic)
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] ?? $0["message"]) as? String }
            throw ReaderError.server(Self.explain(detail ?? "HTTP \(status)", status: status))
        }
        if T.self == Empty.self || data.isEmpty { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func explain(_ code: String, status: Int) -> String {
        switch code {
        case "taken": L("This name or email is already used.")
        case "bad_email": L("This email doesn't look right.")
        case "password_too_short": L("At least 10 characters for the password.")
        case "too_many_signups": L("Too many sign-ups from here; try again in an hour.")
        default: status == 401 ? L("Wrong name or password.") : code
        }
    }
}

struct RemoteBook: Decodable, Identifiable, Hashable {
    struct Owner: Decodable, Hashable { let login: String; let full_name: String? }
    let id: Int
    let name: String
    let full_name: String
    let description: String?
    let owner: Owner
    let updated_at: String?
    var title: String { description?.isEmpty == false ? description! : name }
    var author: String { owner.full_name?.isEmpty == false ? owner.full_name! : owner.login }
}

struct Milestone: Decodable, Identifiable, Hashable {
    struct Commit: Decodable, Hashable { let sha: String }
    let name: String
    let message: String?
    let commit: Commit
    var id: String { name }
    var title: String { (message ?? "").split(separator: "\n").first.map(String.init) ?? String(name.dropFirst("jalon/".count)) }
}

enum Keychain {
    static let service = "app.musset.Reader"
    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    static func set(_ key: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess { NSLog("Musset Reader: keychain refused the token (%d)", status) }
    }
}
