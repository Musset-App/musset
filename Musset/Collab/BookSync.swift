import AppKit
import Foundation

enum SyncStatus: Equatable {
    case off, working, upToDate, offline
    /// Saved here, but what came from elsewhere left corrections to read.
    case corrections(Int)
    case failed(String)

    var word: String? {
        switch self {
        case .off: nil
        case .working: L("Syncing…")
        case .upToDate: L("In sync")
        case .offline: L("Offline")
        case .corrections(let n): L("\(n) received as corrections")
        case .failed: L("Not synced")
        }
    }
    var isProblem: Bool { if case .failed = self { true } else { false } }
    var help: String {
        switch self {
        case .offline: L("Your work is saved on this Mac. It goes out when the connection returns.")
        case .corrections: L("The same paragraph changed on both sides: yours stayed, the other is a correction to accept or reject.")
        case .failed(let why): why
        default: L("Your books follow you on all your Macs.")
        }
    }
}

/// Receive, merge, send. Runs when a book opens, when the app comes back, after each commit, and every two minutes.
extension Collab {
    static let documentsSuffix = "-documents"

    func start(_ app: AppState) {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak app] _ in
            MainActor.assumeIsolated { if let s = app?.current { Collab.shared.sync(s) } }
        }
        Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak app] _ in
            MainActor.assumeIsolated {
                if NSApp.isActive, let s = app?.current { Collab.shared.sync(s) }
                Task { await Collab.shared.refreshActivity() }
            }
        }
        // A new writer (back from Stripe): the open book goes up now.
        NotificationCenter.default.addObserver(forName: Collab.becameWriter, object: nil, queue: .main) { [weak app] _ in
            MainActor.assumeIsolated { if let s = app?.current { Collab.shared.opened(s) } }
        }
        Task {
            await refreshAccount()
            await refreshCircle()
            await refreshActivity()
        }
    }

    /// A book opens: it goes to the account if it isn't there yet, and catches up.
    func opened(_ session: BookSession) {
        guard signedIn else { sync = .off; return }
        Task {
            if account == nil { await refreshAccount() }
            // Only a writer's books go online on their own; a free account's stay here, quietly.
            if canSync, autoSync, !isLocalOnly(session), link(session.git) == nil, session.git.isRepo, session.store.hasManifest {
                do { try await share(session) } catch { sync = .failed(error.localizedDescription); return }
            }
            if link(session.git) == nil { sync = .off; return }
            if link(session.git) != nil, !isOwner(session.git) { try? await refreshRole(session.git) }
            await syncNow(session)
        }
    }

    func sync(_ session: BookSession, removed: [String] = []) {
        Task { await syncNow(session, removed: removed) }
    }

    /// One at a time per book: a request during a run makes one more run.
    func syncNow(_ session: BookSession, removed: [String] = []) async {
        guard let creds = credentials, let l = link(session.git) else {
            if link(session.git) == nil || !signedIn { sync = .off }
            return
        }
        // A reader or an editor: their own branch goes up (their notes and replies), the author's main comes down.
        if role(session.git)?.reviews ?? false {
            await syncReviewer(session, l, creds)
            return
        }
        if !pendingNotices.isEmpty { await sendPendingNotices() }
        let key = session.root.path
        waitingRemovals[key, default: []] += removed
        guard !running.contains(key) else {
            again.insert(key)
            while running.contains(key) { try? await Task.sleep(nanoseconds: 50_000_000) }
            return
        }
        running.insert(key)
        defer { running.remove(key) }
        var received: SyncStatus?
        repeat {
            again.remove(key)
            sync = .working
            let refs = waitingRemovals.removeValue(forKey: key) ?? []
            do {
                // A second round after a merge must not hide what the first one brought.
                let outcome = try await run(session, l, creds, removed: refs)
                if case .corrections = outcome { received = outcome }
                sync = outcome == .upToDate ? (received ?? outcome) : outcome
            } catch {
                waitingRemovals[key, default: []] += refs
                sync = Self.isOffline(error) ? .offline : .failed(error.localizedDescription)
            }
        } while again.contains(key)
    }

    /// Someone reading the book sends their conversation (their own branch) and receives the author's replies.
    private func syncReviewer(_ session: BookSession, _ l: (remote: String, owner: String, repo: String), _ creds: GitService.Credentials) async {
        let git = session.git
        guard let user = username else { return }
        sync = .working
        do {
            session.flushSave()
            session.notes.save()
            session.commitIfPending(message: "musset: notes by \(user)")
            try await Task.detached { try git.fetch(l.remote, credentials: creds) }.value
            let branch = Self.reviewBranch(user)
            if git.currentBranch == branch {
                try await Task.detached { try git.push(l.remote, refspecs: ["+refs/heads/\(branch):refs/heads/\(branch)"], credentials: creds) }.value
            }
            session.refreshTalk()
            sync = .upToDate
        } catch {
            sync = Self.isOffline(error) ? .offline : .failed(error.localizedDescription)
        }
    }

    private nonisolated static func isOffline(_ error: Error) -> Bool {
        let m = error.localizedDescription.lowercased()
        return ["failed to connect", "failed to resolve", "could not resolve", "timed out", "network", "connection", "offline"].contains { m.contains($0) }
    }

    private func run(_ session: BookSession, _ l: (remote: String, owner: String, repo: String), _ creds: GitService.Credentials, removed: [String]) async throws -> SyncStatus {
        let git = session.git
        session.flushSave()
        session.commitIfPending(message: session.editMessage)
        if session.pendingCommit, session.piste == nil, let e = session.lastError { throw NSError(domain: "Musset.collab", code: 3, userInfo: [NSLocalizedDescriptionKey: e]) }
        try await Task.detached { try git.fetch(l.remote, credentials: creds) }.value
        let theirs = "\(l.remote)/main"
        var conflicts = 0
        // In a track the folder holds the manuscript but the page doesn't show it: it catches up on the way back.
        if session.piste == nil, let tip = git.resolve(theirs), !git.isAncestor(tip, of: "HEAD") {
            session.flushSave()
            conflicts = try integrate(tip, into: session)
        }
        // A track that moved on both Macs isn't overwritten: it waits, and says so.
        var tracks: [String] = []
        var held: [String] = []
        for branch in git.branches() where branch.hasPrefix("piste/") {
            if let remote = git.resolve("\(l.remote)/\(branch)"), !git.isAncestor(remote, of: branch) {
                if git.isAncestor(branch, of: remote) { try? git.switchTrack(branch, to: remote) } else { held.append(branch) }
            } else { tracks.append("refs/heads/\(branch):refs/heads/\(branch)") }
        }
        for branch in git.remoteBranches(l.remote) where branch.hasPrefix("piste/") && !git.branches().contains(branch) {
            try? git.createBranch(branch, at: "\(l.remote)/\(branch)")
        }
        let branch = git.currentBranch ?? "main"
        let refspecs = ["refs/heads/\(branch):refs/heads/main"] + tracks
            + session.jalons.map { "refs/tags/\($0.id):refs/tags/\($0.id)" } + removed.map { ":" + $0 }
        try await Task.detached { try git.push(l.remote, refspecs: refspecs, credentials: creds) }.value
        try await syncDocuments(session, l, creds)
        session.refreshTalk()
        if !held.isEmpty { return .failed(L("Track changed on two Macs: \(held.listed)")) }
        return conflicts > 0 ? .corrections(conflicts) : .upToDate
    }

    /// Writes what came from elsewhere into the book, as a commit when both sides moved. The author's other files are never touched.
    private func integrate(_ tip: String, into session: BookSession) throws -> Int {
        let git = session.git
        let base = git.mergeBase("HEAD", tip)
        guard base != nil || git.resolve("HEAD") == nil else {
            throw NSError(domain: "Musset.collab", code: 2, userInfo: [NSLocalizedDescriptionKey: L("This folder and the book on the account have nothing in common.")])
        }
        var chapters = Set(session.manifest.chapters.map(\.file))
        if let data = git.data(tip, path: ".musset/book.json"), let m = try? JSONDecoder().decode(BookManifest.self, from: data) { chapters.formUnion(m.chapters.map(\.file)) }
        let person = git.authorName(tip)
        let who = person == username || person == nil ? L("From another Mac") : person!
        let out = try SyncMerge.apply(git, base: base, theirs: tip, who: who, chapters: chapters, keepBoth: false) { path in
            chapters.contains(path) || path.hasPrefix(".musset/") || path.hasPrefix(BibleStore.folderName + "/")
        }
        if git.isAncestor(git.resolve("HEAD") ?? "", of: tip) {
            try git.advance(to: tip)
        } else {
            try git.commit(paths: session.manifest.chapters.map(\.file) + Array(chapters) + [".musset", BibleStore.folderName], message: "musset: sync", merging: tip)
        }
        session.reloadAfterSync()
        return out.conflicts
    }

    /// The book's documents, in a repository of their own: never in the book's history, never with an editor.
    private func syncDocuments(_ session: BookSession, _ l: (remote: String, owner: String, repo: String), _ creds: GitService.Credentials) async throws {
        let dir = session.bible.store.dir.appendingPathComponent(BibleStore.documents, isDirectory: true)
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { ![".git", ".gitignore", ".DS_Store"].contains($0) }
        let git = GitService(root: dir)
        let name = l.repo + Self.documentsSuffix
        if !git.isRepo {
            struct Found: Decodable { let clone_url: String }
            let found: Found? = try? await request("GET", repoURL(l.owner, name))
            guard found != nil || (!files.isEmpty && l.owner == username) else { return }
            let url: String
            if let found { url = found.clone_url } else {
                let made: Repo = try await request("POST", apiURL("user/repos"), body: ["name": name, "private": true, "description": L("Documents")])
                url = made.clone_url
            }
            // Keep the book's repository out of this one, on this Mac too, before it exists.
            try session.bible.store.prepare(dir.appendingPathComponent(".gitignore"))
            try git.initRepo()
            try "*.sb-*\n.DS_Store\n".write(to: dir.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
            try git.addRemote("musset", url: url)
            // Anyone who was already a collaborator gets the documents too.
            for person in (try? await people(of: session)) ?? [] where person.role == .collaborator {
                let _: EmptyReply? = try? await request("PUT", apiURL("repos/\(l.owner)/\(name)/collaborators/\(person.user)"), body: ["permission": "write"])
            }
        }
        try await Task.detached {
            try git.commit(paths: ["*"], message: "musset: documents")
            try git.fetch("musset", credentials: creds)
            if let tip = git.resolve("musset/main"), !git.isAncestor(tip, of: "HEAD") {
                let head = git.resolve("HEAD")
                let base = head.flatMap { git.mergeBase($0, tip) }
                _ = try SyncMerge.apply(git, base: base, theirs: tip, who: "", chapters: [], keepBoth: true) { _ in true }
                if head == nil || base == head { try git.advance(to: tip) }
                else { try git.commit(paths: ["*"], message: "musset: sync documents", merging: tip) }
            }
            guard let branch = git.currentBranch, git.resolve("HEAD") != nil else { return }
            try git.push("musset", refspecs: ["refs/heads/\(branch):refs/heads/main"], credentials: creds)
        }.value
        session.bible.reload()
    }

    /// Quitting right after writing still reaches the other Macs: a few seconds at most, then it waits for next time.
    func sendBeforeQuitting(_ sessions: [BookSession]) {
        guard let creds = credentials else { return }
        let done = DispatchGroup()
        for s in sessions {
            guard let l = link(s.git), role(s.git) != .editor, let branch = s.git.currentBranch else { continue }
            let git = s.git
            done.enter()
            DispatchQueue.global().async {
                try? git.push(l.remote, refspecs: ["refs/heads/\(branch):refs/heads/main"], credentials: creds)
                done.leave()
            }
        }
        _ = done.wait(timeout: .now() + 5)
    }
}
