import CryptoKit
import Foundation
import Observation

/// An account on git.musset.app, in the author's words: "my books on all my Macs", "invite an editor or a collaborator",
/// "send my review", "reviews to read". Under it: a private Forgejo repository per book, and a second one for its documents.
/// A collaborator writes in the main text, like the author on another Mac. An editor works on their own branch, which
/// the server enforces (main is protected), and their review comes back as corrections.
@MainActor
@Observable
final class Collab {
    static let shared = Collab()
    static let server: URL = {
        #if DEBUG
        // Tests run against a Forgejo on this Mac, never the real server.
        if let local = ProcessInfo.processInfo.environment["MUSSET_SERVER"], let url = URL(string: local) { return url }
        #endif
        return URL(string: "https://git.musset.app")!
    }()
    /// A test server's token never takes the place of the real account's.
    private static let tokenKey: String = server.host == "git.musset.app" ? "forgejo-token" : "forgejo-token-\(server.host ?? "")"

    var username: String? = UserDefaults.standard.string(forKey: "collabUser") {
        didSet { UserDefaults.standard.set(username, forKey: "collabUser") }
    }
    var busy = false
    @ObservationIgnored var started = false
    @ObservationIgnored var running = Set<String>()
    @ObservationIgnored var again = Set<String>()
    @ObservationIgnored var waitingRemovals: [String: [String]] = [:]
    var lastError: String?
    /// The plan (free or writer) and the rest musset-api knows; nil until asked.
    var account: AccountInfo?
    /// The people I know on Musset, and those I invited by e-mail.
    var circle: [CirclePerson] = []
    /// What happened in the books I read or write, newest first.
    var activity: [ActivityItem] = []
    /// The books on the account, mine and shared with me, as last asked (Home asks when it shows).
    var online: [Repo] = []
    /// Notices that could not be sent (offline), for the next sync.
    var pendingNotices: [[String: Any]] {
        get { (UserDefaults.standard.array(forKey: "collabPendingNotices") as? [[String: Any]]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "collabPendingNotices") }
    }

    /// What the books' sync is doing, for the status bar.
    var sync = SyncStatus.off
    /// Send every book to the account as soon as it's opened.
    var autoSync: Bool = UserDefaults.standard.object(forKey: "collabAutoSync") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSync, forKey: "collabAutoSync") }
    }
    /// Books kept on this Mac only, by folder.
    private var keptLocal: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "collabLocalOnly") ?? []) {
        didSet { UserDefaults.standard.set(Array(keptLocal), forKey: "collabLocalOnly") }
    }

    var signedIn: Bool { username != nil && !(Secrets.get(Self.tokenKey) ?? "").isEmpty }
    var credentials: GitService.Credentials? {
        guard let u = username, let t = Secrets.get(Self.tokenKey), !t.isEmpty else { return nil }
        return .init(user: u, token: t)
    }

    // MARK: Account

    /// A free account. The user name may be left empty: the server makes one from the e-mail.
    func signUp(username: String = "", email: String, password: String, name: String = "", invitation: String? = nil) async throws {
        struct Out: Decodable { let username: String; let token: String }
        var body: [String: Any] = ["username": username, "email": email, "password": password, "name": name,
                                   "lang": UILang.current.localeID, "device": Host.current().localizedName ?? "Mac"]
        if let invitation { body["invitation"] = invitation }
        let out: Out = try await request("POST", Self.server.appendingPathComponent("musset-api/signup"), body: body)
        Secrets.set(Self.tokenKey, out.token)
        self.username = out.username
        await refreshAccount()
    }

    func signIn(username: String, password: String) async throws {
        struct Out: Decodable { let sha1: String }
        let out: Out = try await request("POST", api("users/\(username)/tokens"),
                                         body: ["name": "musset-\(Host.current().localizedName ?? "Mac")-\(Int(Date().timeIntervalSince1970))",
                                                "scopes": ["write:repository", "write:issue", "write:user", "read:organization", "read:misc"]],
                                         basic: (username, password))
        Secrets.set(Self.tokenKey, out.sha1)
        self.username = username
        await refreshAccount()
    }

    func signOut() {
        Secrets.set(Self.tokenKey, "")
        sync = .off
        username = nil
        account = nil
        circle = []
        activity = []
        online = []
    }

    // MARK: Books on the server

    struct Repo: Decodable, Identifiable, Hashable {
        struct Owner: Decodable, Hashable { let login: String }
        let id: Int
        let name: String
        let full_name: String
        let clone_url: String
        let owner: Owner
        let description: String?
    }

    struct Review: Decodable, Identifiable, Hashable {
        struct Ref: Decodable, Hashable { let ref: String }
        struct User: Decodable, Hashable { let login: String }
        let id: Int
        let number: Int
        let title: String
        let head: Ref
        let user: User
        let created_at: String
    }

    /// The shared book a folder belongs to: its remote on git.musset.app, owner and repository.
    func link(_ git: GitService) -> (remote: String, owner: String, repo: String)? {
        for (name, url) in git.remotes() where url.hasPrefix(Self.server.absoluteString) {
            let parts = url.replacingOccurrences(of: Self.server.absoluteString + "/", with: "")
                .replacingOccurrences(of: ".git", with: "").split(separator: "/")
            if parts.count == 2 { return (name, String(parts[0]), String(parts[1])) }
        }
        return nil
    }

    func isOwner(_ git: GitService) -> Bool { link(git).map { $0.owner == username } ?? false }
    /// An editor: changes stay corrections, on their own branch. Until the server says otherwise, anyone who isn't the owner.
    func isReviewer(_ git: GitService) -> Bool { link(git) != nil && (role(git)?.reviews ?? false) }

    /// How someone takes part in a book.
    enum Role: String, CaseIterable, Identifiable {
        /// Reads, marks up and leaves notes; suggests no changes.
        case reader, editor, collaborator
        var id: String { rawValue }
        var label: String {
            switch self {
            case .reader: L("Reader")
            case .editor: L("Editor")
            case .collaborator: L("Co-writer")
            }
        }
        var help: String {
            switch self {
            case .reader: L("Marks up the text and leaves notes.")
            case .editor: L("Proposes corrections and notes. You accept or reject each one.")
            case .collaborator: L("Writes in the text with you, and sees the documents.")
            }
        }
        /// Whether their changes come back as corrections (on their own branch) rather than into the text.
        var reviews: Bool { self != .collaborator }
    }

    private var knownRoles: [String: String] = UserDefaults.standard.dictionary(forKey: "collabRoles") as? [String: String] ?? [:] {
        didSet { UserDefaults.standard.set(knownRoles, forKey: "collabRoles") }
    }

    /// nil for the owner.
    func role(_ git: GitService) -> Role? {
        guard let l = link(git), l.owner != username else { return nil }
        return Role(rawValue: knownRoles["\(l.owner)/\(l.repo)"] ?? "") ?? .editor
    }

    /// Asks the server: main is protected and I may push to it, or not.
    @discardableResult
    func refreshRole(_ git: GitService) async throws -> Role? {
        guard let l = link(git), l.owner != username else { return nil }
        struct Branch: Decodable { let `protected`: Bool?; let user_can_push: Bool? }
        let main: Branch = try await request("GET", api("repos/\(l.owner)/\(l.repo)/branches/main"))
        var role: Role = main.protected == true && main.user_can_push == true ? .collaborator : .editor
        if role == .editor, await serverRole(in: git) == .reader { role = .reader }
        knownRoles["\(l.owner)/\(l.repo)"] = role.rawValue
        return role
    }

    /// Whether this book goes to the account.
    func isLocalOnly(_ session: BookSession) -> Bool { keptLocal.contains(session.root.standardizedFileURL.path) }
    func setLocalOnly(_ session: BookSession, _ on: Bool) {
        let path = session.root.standardizedFileURL.path
        if on { keptLocal.insert(path) } else { keptLocal.remove(path); opened(session) }
    }

    /// Creates the book's private repository and sends the book to it. Only a writer account puts books online.
    func share(_ session: BookSession) async throws {
        guard let creds = credentials else { throw failure(L("Sign in first.")) }
        if account == nil { await refreshAccount() }
        guard canSync else { throw NeedsSubscription() }
        session.flushSave()
        session.commitNow("musset: before sharing")
        let slug = session.title.slug()
        let repo = try await createRepo(slug.isEmpty ? "livre" : slug, description: session.title)
        if session.git.remotes()["musset"] == nil { try session.git.addRemote("musset", url: repo.clone_url) }
        session.forgetRepoStatus()
        let git = session.git
        let branch = git.currentBranch ?? "main"
        try await Task.detached { try git.push("musset", refspecs: ["refs/heads/\(branch):refs/heads/main"], credentials: creds) }.value
    }

    /// Two books with one title: the second takes a number.
    private func createRepo(_ name: String, description: String) async throws -> Repo {
        for n in 1...20 {
            let candidate = n == 1 ? name : "\(name)-\(n)"
            do {
                return try await request("POST", api("user/repos"), body: ["name": candidate, "private": true, "description": description])
            } catch let e as NSError where e.code == 409 { continue }
            catch let e as NSError where e.code == 403 || e.code == 422 && !(e.localizedDescription.contains("exist")) {
                // Forgejo refuses repositories to an account with no repository allowance: a free one.
                await refreshAccount()
                throw NeedsSubscription()
            }
        }
        throw failure(L("This name is taken."))
    }

    /// Who the book is shared with, and how. Asking also protects main, so a book shared before roles is right from then on.
    func people(of session: BookSession) async throws -> [(user: String, role: Role)] {
        guard let l = link(session.git), l.owner == username else { return [] }
        struct U: Decodable { let login: String }
        let users: [U] = try await request("GET", api("repos/\(l.owner)/\(l.repo)/collaborators"))
        let writers = try await protectMain(l.owner, l.repo)
        struct Roles: Decodable { let roles: [String: String] }
        let repo = "\(l.owner)/\(l.repo)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let known = (try? await request("GET", URL(string: Self.server.appendingPathComponent("musset-api/roles").absoluteString + "?repo=" + repo)!) as Roles)?.roles ?? [:]
        return users.map { u in
            if writers.contains(u.login) { return (u.login, .collaborator) }
            return (u.login, known[u.login] == "reader" ? .reader : .editor)
        }
    }

    /// Only those named here can push to main: anyone else invited can only push their own branch.
    private func protectMain(_ owner: String, _ repo: String, writers: [String]? = nil) async throws -> [String] {
        struct Rule: Decodable { let push_whitelist_usernames: [String]? }
        let path = "repos/\(owner)/\(repo)/branch_protections"
        let existing: Rule? = try? await request("GET", api("\(path)/main"))
        let names = writers ?? (existing?.push_whitelist_usernames ?? [])
        let body: [String: Any] = ["enable_push": true, "enable_push_whitelist": true, "push_whitelist_usernames": Array(Set(names + [owner])).sorted()]
        if existing != nil {
            if writers != nil { let _: Rule = try await request("PATCH", api("\(path)/main"), body: body) }
        } else {
            var create = body
            create["rule_name"] = "main"
            create["branch_name"] = "main"
            let _: Rule = try await request("POST", api(path), body: create)
        }
        return names
    }

    func invite(_ user: String, as role: Role, to session: BookSession) async throws {
        guard let l = link(session.git) else { return }
        let _: Empty = try await request("PUT", api("repos/\(l.owner)/\(l.repo)/collaborators/\(user)"), body: ["permission": "write"])
        try await setRole(role, of: user, in: session)
    }

    func setRole(_ role: Role, of user: String, in session: BookSession) async throws {
        guard let l = link(session.git) else { return }
        await recordRole(role, of: user, in: session)
        var writers = try await protectMain(l.owner, l.repo)
        writers.removeAll { $0 == user }
        if role == .collaborator { writers.append(user) }
        _ = try await protectMain(l.owner, l.repo, writers: writers)
        // The documents go with the collaborator's role, and only there.
        let documents = api("repos/\(l.owner)/\(l.repo)\(Self.documentsSuffix)/collaborators/\(user)")
        if role == .collaborator { let _: Empty? = try? await request("PUT", documents, body: ["permission": "write"]) }
        else { let _: Empty? = try? await request("DELETE", documents) }
    }

    func remove(_ user: String, from session: BookSession) async throws {
        guard let l = link(session.git) else { return }
        try await setRole(.editor, of: user, in: session)
        let _: Empty = try await request("DELETE", api("repos/\(l.owner)/\(l.repo)/collaborators/\(user)"))
    }

    /// Every book on the account, mine and shared with me. A book's documents are not a book.
    func onlineBooks() async throws -> [Repo] {
        var all: [Repo] = []
        for page in 1...20 {
            let batch: [Repo] = try await request("GET", api("user/repos?limit=50&page=\(page)"))
            all += batch
            if batch.count < 50 { break }
        }
        return all.filter { !$0.name.hasSuffix(Self.documentsSuffix) }
    }

    /// Asks again for the books on the account. A failure leaves the last answer in place.
    func refreshOnline() async throws {
        guard signedIn else { online = []; return }
        online = try await onlineBooks()
    }

    /// Downloads a book into `folder`. An editor goes to their own branch; the others write in the main text.
    func open(_ repo: Repo, into folder: URL) async throws {
        guard let creds = credentials, let user = username else { throw failure(L("Sign in first.")) }
        try await Task.detached { try GitService.clone(repo.clone_url, to: folder, credentials: creds) }.value
        let git = GitService(root: folder)
        let role = try await refreshRole(git)
        // A reader or an editor reads the milestone the author gave them; with none given, the text as it was sent.
        let start = await readingStart(git, remote: "origin")
        if role == .editor || (role == .reader && start.tag != nil) {
            try await Task.detached { try git.switchBranch(Self.reviewBranch(user), at: start.ref) }.value
        }
        setAdopted(start.tag, for: git)
    }

    /// Where a reader's copy starts from: the milestone they were given (once it has arrived here), else the
    /// author's text as it is.
    func readingStart(_ git: GitService, remote: String) async -> (ref: String, tag: String?) {
        guard let me = username, let tag = await reading(of: git)[me]?.tag, git.resolve("refs/tags/\(tag)") != nil else { return ("\(remote)/main", nil) }
        return ("refs/tags/\(tag)", tag)
    }

    /// The milestone this copy of someone's book was last set on, kept on this Mac: what tells a newer one has come.
    func adopted(for git: GitService) -> String? {
        (UserDefaults.standard.dictionary(forKey: "collabAdopted") as? [String: String])?[git.root.standardizedFileURL.path]
    }

    func setAdopted(_ tag: String?, for git: GitService) {
        var all = UserDefaults.standard.dictionary(forKey: "collabAdopted") as? [String: String] ?? [:]
        all[git.root.standardizedFileURL.path] = tag
        UserDefaults.standard.set(all, forKey: "collabAdopted")
    }

    /// An editor who became a collaborator leaves their branch for the main text. Their review should have been sent first.
    func joinMainText(_ session: BookSession) async throws {
        guard let creds = credentials, let l = link(session.git) else { return }
        session.flushSave()
        session.commitNow("musset: before joining the main text")
        let git = session.git
        try await Task.detached {
            try git.fetch(l.remote, credentials: creds)
            try git.switchBranch("main", at: "\(l.remote)/main")
        }.value
        session.reloadAfterSync()
    }

    nonisolated static func reviewBranch(_ user: String) -> String { "relecture/\(user)" }

    /// The reader sends their corrections and notes: their branch goes up, with a review request.
    func sendReview(_ session: BookSession, message: String) async throws {
        guard let creds = credentials, let user = username, let l = link(session.git) else { return }
        session.flushSave()
        session.notes.save()
        session.commitNow("musset: review by \(user)")
        let git = session.git
        let branch = Self.reviewBranch(user)
        try await Task.detached { try git.push(l.remote, refspecs: ["+refs/heads/\(branch):refs/heads/\(branch)"], credentials: creds) }.value
        let open: [Review] = try await request("GET", api("repos/\(l.owner)/\(l.repo)/pulls?state=open"))
        if open.contains(where: { $0.head.ref == branch }) { return }
        let _: Review = try await request("POST", api("repos/\(l.owner)/\(l.repo)/pulls"),
                                          body: ["head": branch, "base": "main", "title": L("Review by \(user)"), "body": message])
    }

    /// The reader starts over from what the author gave them to read: their milestone, or with none the author's
    /// latest text (after their review was read).
    func refreshReview(_ session: BookSession) async throws {
        guard let creds = credentials, let user = username, let l = link(session.git) else { return }
        let git = session.git
        try await Task.detached { try git.fetch(l.remote, credentials: creds) }.value
        let start = await readingStart(git, remote: l.remote)
        try await Task.detached { try git.switchBranch(Self.reviewBranch(user), at: start.ref) }.value
        setAdopted(start.tag, for: git)
    }

    func reviews(of session: BookSession) async throws -> [Review] {
        guard let l = link(session.git) else { return [] }
        return try await request("GET", api("repos/\(l.owner)/\(l.repo)/pulls?state=open"))
    }

    /// Brings a review into the author's chapters as corrections to accept or reject, and everything the reader said
    /// into the conversations. Returns how many corrections were placed, and those that could not be (now conversations).
    func importReview(_ review: Review, into session: BookSession) async throws -> (placed: Int, unplaced: Int) {
        guard let creds = credentials, let l = link(session.git) else { return (0, 0) }
        session.flushSave()
        session.commitNow("musset: before review by \(review.user.login)")
        let git = session.git
        try await Task.detached { try git.fetch(l.remote, credentials: creds) }.value
        let theirs = "\(l.remote)/\(review.head.ref)"
        guard let base = git.mergeBase("HEAD", theirs) ?? git.resolve("\(l.remote)/main") else { throw failure(L("No common version.")) }
        let (placed, unplaced) = try session.adoptReview(theirs: theirs, base: base, reader: review.user.login)
        session.countAllWords()
        session.commitNow("musset: review by \(review.user.login), as corrections\n\nMusset-Author: \(review.user.login)")
        let _: Empty = try await request("POST", api("repos/\(l.owner)/\(l.repo)/issues/\(review.number)/comments"),
                                         body: ["body": L("Read in Musset: the changes are now corrections in the author's text.")])
        let _: Review = try await request("PATCH", api("repos/\(l.owner)/\(l.repo)/pulls/\(review.number)"), body: ["state": "closed"])
        await syncNow(session)
        return (placed, unplaced)
    }

    // MARK: HTTP

    private struct Empty: Decodable {}
    struct EmptyReply: Decodable {}

    private func api(_ path: String) -> URL { URL(string: Self.server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/api/v1/" + path)! }
    func apiURL(_ path: String) -> URL { api(path) }
    func repoURL(_ owner: String, _ name: String) -> URL { api("repos/\(owner)/\(name)") }

    private func failure(_ message: String) -> NSError {
        NSError(domain: "Musset.collab", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func request<T: Decodable>(_ method: String, _ url: URL, body: [String: Any]? = nil, basic: (String, String)? = nil) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let basic {
            req.setValue("Basic " + Data("\(basic.0):\(basic.1)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        } else if let t = Secrets.get(Self.tokenKey), !t.isEmpty {
            req.setValue("token " + t, forHTTPHeaderField: "Authorization")
        }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]).flatMap { ($0["error"] ?? $0["message"]) as? String } ?? "HTTP \(status)"
            throw NSError(domain: "Musset.collab", code: status, userInfo: [NSLocalizedDescriptionKey: Self.explain(detail, status: status)])
        }
        if T.self == Empty.self || T.self == EmptyReply.self || data.isEmpty { return try JSONDecoder().decode(T.self, from: Data("{}".utf8)) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func explain(_ code: String, status: Int) -> String {
        switch code {
        case "taken": L("This name or email is already used.")
        case "bad_username": L("Names use letters, digits, - _ and . (2 to 39).")
        case "bad_email": L("This email doesn't look right.")
        case "password_too_short": L("At least 10 characters for the password.")
        case "too_many_signups": L("Too many sign-ups from here; try again in an hour.")
        default: status == 401 ? L("Wrong name or password.") : code
        }
    }
}

/// A review comes back as corrections on the author's text as it is now, even if they kept writing: what the reader
/// changed (base → reviewer) is placed where the same words still stand; what can't be placed comes back as a comment.
enum ReviewImport {
    /// Something the reader said in the text: a comment on the passage they highlighted (or on the words before it).
    /// `at` is where the passage stands in the resulting text, nil when the author has rewritten it since.
    struct Remark: Equatable { let quote: String; let body: String; let at: Int? }
    struct Result { let text: String; let placed: Int; let unplaced: [String]; let remarks: [Remark] }

    private struct Hunk {
        let old: String
        let new: String
        let before: String
        let after: String
        /// A whole new paragraph, to go after the paragraph `before`.
        var paragraph = false
    }

    static func apply(base: String, reviewer: String, current: String) -> Result {
        // The reader's own marks: what they propose is the text with them accepted; their comments travel apart.
        let target = Revisions.resolveAll(reviewer, accept: true)
        var hunks: [Hunk] = []
        // Corrections already pending in the base are not the reader's: they compared with the base accepted too.
        let baseLines = Revisions.resolveAll(base, accept: true).components(separatedBy: "\n"), targetLines = target.components(separatedBy: "\n")
        let diff = targetLines.difference(from: baseLines)
        var removed: [Int: String] = [:], inserted: [Int: String] = [:]
        for c in diff {
            switch c {
            case .remove(let o, let e, _): removed[o] = e
            case .insert(let o, let e, _): inserted[o] = e
            }
        }
        // Pair each removed line with the inserted line at the same place: an edited paragraph.
        var pairedNew = Set<Int>()
        for (o, old) in removed.sorted(by: { $0.key < $1.key }) {
            let shift = inserted.keys.filter { $0 <= o }.count - removed.keys.filter { $0 < o }.count
            if let n = inserted.keys.sorted().first(where: { !pairedNew.contains($0) && abs($0 - (o + shift)) <= 1 }) {
                pairedNew.insert(n)
                hunks += wordHunks(old, inserted[n]!)
            } else {
                hunks.append(Hunk(old: old, new: "", before: "", after: ""))
            }
        }
        for (n, line) in inserted where !pairedNew.contains(n) && !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let previous = n > 0 && n - 1 < targetLines.count ? targetLines[n - 1] : ""
            hunks.append(Hunk(old: "", new: line, before: String(previous.suffix(60)), after: "", paragraph: true))
        }

        // Place them on the current text, last first so offsets hold.
        let ns = current as NSString
        var edits: [(NSRange, String)] = []
        var unplaced: [String] = []
        for h in hunks {
            let mark = h.paragraph ? "\n{++" + h.new + "++}" : h.old.isEmpty ? "{++" + h.new + "++}"
                : h.new.isEmpty ? "{--" + h.old + "--}" : "{~~" + h.old + "~>" + h.new + "~~}"
            // The same review brought in before: its correction already stands there, waiting.
            if ns.range(of: h.before + mark).location != NSNotFound, h.after.isEmpty || ns.range(of: mark + h.after).location != NSNotFound { continue }
            guard let r = locate(h, in: ns) else {
                unplaced.append(h.old.isEmpty ? L("adds « \(h.new) »")
                                : h.new.isEmpty ? L("removes « \(h.old) »")
                                : inQuotes(h.old) + " → " + inQuotes(h.new))
                continue
            }
            if edits.contains(where: { NSIntersectionRange($0.0, r).length > 0 || ($0.0.location == r.location && r.length == 0) }) { continue }
            edits.append((r, mark))
        }
        let out = NSMutableString(string: current)
        for (r, text) in edits.sorted(by: { $0.0.location > $1.0.location }) { out.replaceCharacters(in: r, with: text) }
        // The reader's comments, on the passage they highlighted (or the words before a lone comment): they leave no
        // mark in the author's text, only where their passage is now.
        let rns = reviewer as NSString
        var remarks: [Remark] = []
        for m in Revisions.marks(in: reviewer) where m.kind == .highlight || m.kind == .comment {
            guard let c = m.second, c.length > 0 else { continue }
            var quote = m.kind == .highlight ? rns.substring(with: m.first)
                : String(Revisions.resolveAll(rns.substring(to: m.range.location), accept: false).suffix(40))
            // The words before a lone comment, from a whole word on.
            if m.kind == .comment, quote.count == 40, let space = quote.firstIndex(of: " ") { quote = String(quote[quote.index(after: space)...]) }
            let r = quote.isEmpty ? NSRange(location: NSNotFound, length: 0) : ns.range(of: quote)
            var at: Int?
            if r.location != NSNotFound, !edits.contains(where: { NSIntersectionRange($0.0, r).length > 0 }) {
                at = r.location + edits.filter { $0.0.location <= r.location }.reduce(0) { $0 + ($1.1 as NSString).length - $1.0.length }
                if let spot = at, out.substring(with: NSRange(location: spot, length: r.length)) != quote { at = nil }
            }
            remarks.append(Remark(quote: quote, body: rns.substring(with: c), at: at))
        }
        return Result(text: out as String, placed: edits.count, unplaced: unplaced, remarks: remarks)
    }

    /// Changes inside an edited paragraph, word by word, each with a few words of context.
    private static func wordHunks(_ a: String, _ b: String) -> [Hunk] {
        let x = Diff.tokens(a), y = Diff.tokens(b)
        // Each stretch that differs is one hunk.
        return Diff.gaps(x, y).map { gap in
            Hunk(old: x[gap.old].joined(), new: y[gap.new].joined(),
                 before: x[max(0, gap.old.lowerBound - 6)..<gap.old.lowerBound].joined(),
                 after: x[gap.old.upperBound..<min(x.count, gap.old.upperBound + 6)].joined())
        }
    }

    /// Where a change belongs in the current text: the old words with their context, else alone if they occur once.
    private static func locate(_ h: Hunk, in text: NSString) -> NSRange? {
        if h.old.isEmpty {
            let anchor = h.before
            guard !anchor.isEmpty else { return nil }
            let r = text.range(of: anchor)
            return r.location == NSNotFound ? nil : NSRange(location: NSMaxRange(r), length: 0)
        }
        for (before, after) in [(h.before, h.after), (h.before, ""), ("", h.after)] {
            let r = text.range(of: before + h.old + after)
            if r.location != NSNotFound {
                return NSRange(location: r.location + (before as NSString).length, length: (h.old as NSString).length)
            }
        }
        let first = text.range(of: h.old)
        guard first.location != NSNotFound else { return nil }
        let again = text.range(of: h.old, range: NSRange(location: NSMaxRange(first), length: text.length - NSMaxRange(first)))
        return again.location == NSNotFound ? first : nil
    }
}

extension BookSession {
    /// A reader's review, read from their branch `theirs` (which left the book at `base`). What they changed in the
    /// chapters becomes corrections to accept or reject; everything they said (a comment in the text, a margin note,
    /// a conversation) becomes conversations kept with the book, each once however many times the review is brought in.
    @discardableResult
    func adoptReview(theirs: String, base: String, reader: String) throws -> (placed: Int, unplaced: Int) {
        var placed = 0, unplaced = 0
        for ch in manifest.chapters {
            var said = Talk.decode(git.data(theirs, path: Talk.path(reader, ch.id)))
            if let them = git.show(theirs, path: ch.file) {
                let baseText = ParagraphCodec.decode(git.show(base, path: ch.file) ?? "")
                let theirText = ParagraphCodec.decode(them)
                if theirText != baseText {
                    let out = ReviewImport.apply(base: baseText, reviewer: theirText, current: editorText(of: ch.id))
                    placed += out.placed
                    unplaced += out.unplaced.count
                    if out.text != editorText(of: ch.id) { try writeChapterText(ch.id, out.text) }
                    said += out.remarks.map { ReviewImport.entry($0, in: out.text, chapter: ch.id, reader: reader) }
                    said += out.unplaced.map { ReviewImport.entry(.init(quote: "", body: $0, at: nil), in: out.text, chapter: ch.id, reader: reader) }
                }
            }
            // Their margin notes: the ones they wrote (not the author's own, which their branch carries too), unless
            // an earlier Musset already brought them in as notes. A reader on an older Musset still sends JSON.
            func notes(_ rev: String) -> [Note] {
                git.show(rev, path: ".musset/notes/\(ch.id).md").map(NoteMarkdown.decode)
                    ?? git.data(rev, path: ".musset/notes/\(ch.id).json").map(NoteStore.readJSON) ?? []
            }
            let mine = Set((notes(base) + noteStore(for: ch.id).notes(of: ch.id)).map(\.id))
            said += notes(theirs).filter { !mine.contains($0.id) }.flatMap { ReviewImport.entries($0, chapter: ch.id, reader: reader) }
            talk.adopt(said, chapter: ch.id, from: reader)
        }
        return (placed, unplaced)
    }
}

extension ReviewImport {
    /// The same remark always has the same id, so it is kept once.
    static func stableID(_ parts: String...) -> UUID {
        let hash = Array(SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8)))
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7],
                           hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    /// A comment the reader left in the text, as the start of a conversation on its passage in `text`.
    static func entry(_ remark: Remark, in text: String, chapter: String, reader: String) -> TalkEntry {
        let id = stableID(reader, chapter, remark.quote, remark.body)
        let length = (remark.quote as NSString).length
        let anchor: NoteAnchor? = remark.quote.isEmpty ? nil
            : remark.at.map { Anchoring.capture(NSRange(location: $0, length: length), in: text as NSString, version: nil) }
            ?? NoteAnchor(quote: remark.quote, prefix: "", suffix: "", start: 0, version: nil)
        return TalkEntry(id: id, thread: id, kind: .note, by: reader, body: remark.body, chapter: chapter, anchor: anchor,
                         mark: anchor == nil ? .margin : .highlight, color: Person.palette.firstIndex(of: Person.color(reader)) ?? 0)
    }

    /// A margin note from the reader's own notes, as a conversation: the note, what was answered under it on their
    /// side, and whether they had settled it.
    static func entries(_ note: Note, chapter: String, reader: String) -> [TalkEntry] {
        func words(_ author: Note.Author, _ body: String) -> String { author.isAI ? "\(author.label) : \(body)" : body }
        let tone = [.note, .text].contains(note.kind) ? nil : note.kind.rawValue
        var out = [TalkEntry(id: note.id, thread: note.id, kind: .note, by: reader, at: note.created, body: words(note.author, note.body),
                             chapter: chapter, anchor: note.hasPassage ? note.anchor : nil, mark: .margin,
                             color: Person.palette.firstIndex(of: Person.color(reader)) ?? 0, tone: tone)]
        out += note.replies.map { TalkEntry(id: $0.id, thread: note.id, kind: .reply, by: reader, at: $0.created, body: words($0.author, $0.body), chapter: chapter) }
        if note.isClosed {
            out.append(TalkEntry(id: stableID(note.id.uuidString, "resolve"), thread: note.id, kind: .resolve, by: reader, at: note.updated, chapter: chapter))
        }
        return out
    }
}
