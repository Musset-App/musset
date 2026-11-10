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

    func signUp(username: String, email: String, password: String) async throws {
        struct Out: Decodable { let username: String; let token: String }
        let out: Out = try await request("POST", Self.server.appendingPathComponent("musset-api/signup"),
                                         body: ["username": username, "email": email, "password": password, "device": Host.current().localizedName ?? "Mac"])
        Secrets.set(Self.tokenKey, out.token)
        self.username = out.username
    }

    func signIn(username: String, password: String) async throws {
        struct Out: Decodable { let sha1: String }
        let out: Out = try await request("POST", api("users/\(username)/tokens"),
                                         body: ["name": "musset-\(Host.current().localizedName ?? "Mac")-\(Int(Date().timeIntervalSince1970))",
                                                "scopes": ["write:repository", "write:issue", "write:user", "read:organization", "read:misc"]],
                                         basic: (username, password))
        Secrets.set(Self.tokenKey, out.sha1)
        self.username = username
    }

    func signOut() {
        Secrets.set(Self.tokenKey, "")
        sync = .off
        username = nil
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
    func isReviewer(_ git: GitService) -> Bool { link(git) != nil && role(git) == .editor }

    /// How someone takes part in a book.
    enum Role: String, CaseIterable, Identifiable {
        case editor, collaborator
        var id: String { rawValue }
        var label: String { self == .editor ? L("Editor") : L("Collaborator") }
        var help: String {
            self == .editor
                ? L("Proposes corrections and notes. You accept or reject each one.")
                : L("Writes in the text with you, and sees the documents.")
        }
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
        let role: Role = main.protected == true && main.user_can_push == true ? .collaborator : .editor
        knownRoles["\(l.owner)/\(l.repo)"] = role.rawValue
        return role
    }

    /// Whether this book goes to the account.
    func isLocalOnly(_ session: BookSession) -> Bool { keptLocal.contains(session.root.standardizedFileURL.path) }
    func setLocalOnly(_ session: BookSession, _ on: Bool) {
        let path = session.root.standardizedFileURL.path
        if on { keptLocal.insert(path) } else { keptLocal.remove(path); opened(session) }
    }

    /// Creates the book's private repository and sends the book to it.
    func share(_ session: BookSession) async throws {
        guard let creds = credentials else { throw failure(L("Sign in first.")) }
        session.flushSave()
        session.commitNow("musset: before sharing")
        let slug = session.title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: "-")
        let repo = try await createRepo(slug.isEmpty ? "livre" : slug, description: session.title)
        if session.git.remotes()["musset"] == nil { try session.git.addRemote("musset", url: repo.clone_url) }
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
        }
        throw failure(L("This name is taken."))
    }

    /// Who the book is shared with, and how. Asking also protects main, so a book shared before roles is right from then on.
    func people(of session: BookSession) async throws -> [(user: String, role: Role)] {
        guard let l = link(session.git), l.owner == username else { return [] }
        struct U: Decodable { let login: String }
        let users: [U] = try await request("GET", api("repos/\(l.owner)/\(l.repo)/collaborators"))
        let writers = try await protectMain(l.owner, l.repo)
        return users.map { ($0.login, writers.contains($0.login) ? .collaborator : .editor) }
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

    /// Downloads a book into `folder`. An editor goes to their own branch; the others write in the main text.
    func open(_ repo: Repo, into folder: URL) async throws {
        guard let creds = credentials, let user = username else { throw failure(L("Sign in first.")) }
        try await Task.detached { try GitService.clone(repo.clone_url, to: folder, credentials: creds) }.value
        let git = GitService(root: folder)
        if try await refreshRole(git) == .editor {
            try await Task.detached { try git.switchBranch(Self.reviewBranch(user), at: "origin/main") }.value
        }
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
                                          body: ["head": branch, "base": "main", "title": L("Review by ") + user, "body": message])
    }

    /// The reader starts over from the author's latest version (after their review was read).
    func refreshReview(_ session: BookSession) async throws {
        guard let creds = credentials, let user = username, let l = link(session.git) else { return }
        let git = session.git
        try await Task.detached {
            try git.fetch(l.remote, credentials: creds)
            try git.switchBranch(Self.reviewBranch(user), at: "\(l.remote)/main")
        }.value
    }

    func reviews(of session: BookSession) async throws -> [Review] {
        guard let l = link(session.git) else { return [] }
        return try await request("GET", api("repos/\(l.owner)/\(l.repo)/pulls?state=open"))
    }

    /// Brings a review into the author's chapters as corrections to accept or reject, and its notes into the margin.
    /// Returns how many corrections were placed, and those that could not be (turned into notes).
    func importReview(_ review: Review, into session: BookSession) async throws -> (placed: Int, unplaced: Int) {
        guard let creds = credentials, let l = link(session.git) else { return (0, 0) }
        session.flushSave()
        session.commitNow("musset: before review by \(review.user.login)")
        let git = session.git
        try await Task.detached { try git.fetch(l.remote, credentials: creds) }.value
        let theirs = "\(l.remote)/\(review.head.ref)"
        guard let base = git.mergeBase("HEAD", theirs) ?? git.resolve("\(l.remote)/main") else { throw failure(L("No common version.")) }
        var placed = 0, unplaced = 0
        for ch in session.manifest.chapters {
            guard let them = git.show(theirs, path: ch.file) else { continue }
            let baseText = ParagraphCodec.decode(git.show(base, path: ch.file) ?? "")
            let theirText = ParagraphCodec.decode(them)
            guard theirText != baseText else { continue }
            let current = session.editorText(of: ch.id)
            let out = ReviewImport.apply(base: baseText, reviewer: theirText, current: current, reader: review.user.login)
            placed += out.placed
            unplaced += out.unplaced.count
            var text = out.text
            if !out.unplaced.isEmpty {
                text += "\n" + out.unplaced.map { "{>>\(review.user.login) : \($0)<<}" }.joined(separator: " ") + "\n"
            }
            if ch.id == session.selectedChapterID { session.replaceText(text) }
            else { try session.store.write(ParagraphCodec.encode(text), to: ch) }
            // The reader's margin notes join the author's.
            // A reader on an older Musset still sends JSON.
            let readers = git.show(theirs, path: ".musset/notes/\(ch.id).md").map(NoteMarkdown.decode)
                ?? git.data(theirs, path: ".musset/notes/\(ch.id).json").map(NoteStore.readJSON)
            if let readers {
                session.notes.importNotes(readers, chapter: ch.id, from: review.user.login)
                if ch.id == session.selectedChapterID { session.notes.resolveAll(in: session.text) }
            }
        }
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
    struct Result { let text: String; let placed: Int; let unplaced: [String] }

    private struct Hunk {
        let old: String
        let new: String
        let before: String
        let after: String
        /// A whole new paragraph, to go after the paragraph `before`.
        var paragraph = false
    }

    static func apply(base: String, reviewer: String, current: String, reader: String) -> Result {
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
            guard let r = locate(h, in: ns) else {
                unplaced.append(h.old.isEmpty ? L("adds « \(h.new) »")
                                : h.new.isEmpty ? L("removes « \(h.old) »")
                                : "« \(h.old) » → « \(h.new) »")
                continue
            }
            if edits.contains(where: { NSIntersectionRange($0.0, r).length > 0 || ($0.0.location == r.location && r.length == 0) }) { continue }
            let mark = h.paragraph ? "\n{++" + h.new + "++}" : h.old.isEmpty ? "{++" + h.new + "++}"
                : h.new.isEmpty ? "{--" + h.old + "--}" : "{~~" + h.old + "~>" + h.new + "~~}"
            edits.append((r, mark))
        }
        // The reader's comments, on the passage they highlighted (or the words before a lone comment).
        let rns = reviewer as NSString
        for m in Revisions.marks(in: reviewer) where m.kind == .highlight || m.kind == .comment {
            guard let c = m.second, c.length > 0 else { continue }
            let comment = rns.substring(with: c)
            let quote = m.kind == .highlight ? rns.substring(with: m.first)
                : String(Revisions.resolveAll(rns.substring(to: m.range.location), accept: false).suffix(40))
            let r = ns.range(of: quote)
            if r.location != NSNotFound, !edits.contains(where: { NSIntersectionRange($0.0, r).length > 0 }) {
                edits.append((r, m.kind == .highlight ? "{==" + quote + "==}{>>\(reader) : \(comment)<<}" : quote + "{>>\(reader) : \(comment)<<}"))
            } else {
                unplaced.append(comment)
            }
        }
        let out = NSMutableString(string: current)
        for (r, text) in edits.sorted(by: { $0.0.location > $1.0.location }) { out.replaceCharacters(in: r, with: text) }
        return Result(text: out as String, placed: edits.count, unplaced: unplaced)
    }

    /// Changes inside an edited paragraph, word by word, each with a few words of context.
    private static func wordHunks(_ a: String, _ b: String) -> [Hunk] {
        func tokens(_ s: String) -> [String] {
            var out: [String] = [], cur = ""
            for ch in s {
                if ch.isWhitespace != (cur.last?.isWhitespace ?? ch.isWhitespace), !cur.isEmpty { out.append(cur); cur = "" }
                cur.append(ch)
            }
            if !cur.isEmpty { out.append(cur) }
            return out
        }
        let x = tokens(a), y = tokens(b)
        let diff = y.difference(from: x)
        var removed = Set<Int>(), added: [Int: String] = [:]
        for c in diff {
            switch c {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, let e, _): added[o] = e
            }
        }
        // Walk both token lists together, grouping each run of changes into one hunk.
        var hunks: [Hunk] = []
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if (i < x.count && removed.contains(i)) || (j < y.count && added[j] != nil) {
                let start = i
                var old = "", new = ""
                while i < x.count, removed.contains(i) { old += x[i]; i += 1 }
                while j < y.count, added[j] != nil { new += y[j]; j += 1 }
                while i < x.count, removed.contains(i) { old += x[i]; i += 1 }
                let before = x[max(0, start - 6)..<start].joined()
                let after = x[i..<min(x.count, i + 6)].joined()
                hunks.append(Hunk(old: old, new: new, before: before, after: after))
            } else {
                i += 1; j += 1
            }
        }
        return hunks
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
