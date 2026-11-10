import Foundation
import libgit2

/// Git through libgit2, linked into the app: no git, no Xcode tools needed on the Mac.
/// Commits only the paths Musset owns (chapter files + .musset), never the whole tree,
/// so the author's other files (and anything they staged themselves) stay untouched.
struct GitService {
    let root: URL

    struct Commit: Identifiable, Hashable {
        let id: String
        let date: Date
        let subject: String
        var short: String { String(id.prefix(7)) }
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    var isRepo: Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
    }

    func initRepo() throws {
        _ = Self.start
        var repo: OpaquePointer?
        try check(git_repository_init(&repo, root.path, 0))
        git_repository_free(repo)
    }

    /// Stages the given paths and commits them if anything changed. Returns true if a commit was made.
    /// With `merging`, the commit also has that commit as parent (a track taken back), even with no change.
    @discardableResult
    /// A save elsewhere can drop its temporary file while the index is scanning: that failure passes, so try again.
    func commit(paths: [String], message: String, merging: String? = nil) throws -> Bool {
        for _ in 0..<4 {
            do { return try commitOnce(paths: paths, message: message, merging: merging) }
            catch let failure as Failure where failure.message.hasPrefix("could not find") || failure.message.contains("reading file for hashing") || failure.message.contains("file changed before") { Thread.sleep(forTimeInterval: 0.05) }
        }
        return try commitOnce(paths: paths, message: message, merging: merging)
    }

    private func commitOnce(paths: [String], message: String, merging: String?) throws -> Bool {
        guard !paths.isEmpty else { return false }
        return try withRepo { repo in
            // Like `git add -A -- paths`: new, modified and deleted files under those paths.
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            try withStrArray(paths) { spec in
                try check(git_index_add_all(index, spec, GIT_INDEX_ADD_DEFAULT.rawValue, nil, nil))
                try check(git_index_update_all(index, spec, nil, nil))
            }
            try check(git_index_write(index))

            // Like `git commit -- paths`: HEAD's tree with only those paths taken from the index.
            let head = try headCommit(repo)
            defer { git_commit_free(head) }
            var staged: OpaquePointer?
            try check(git_index_new(&staged))
            defer { git_index_free(staged) }
            if let head {
                var tree: OpaquePointer?
                try check(git_commit_tree(&tree, head))
                defer { git_tree_free(tree) }
                try check(git_index_read_tree(staged, tree))
            }
            var spec: OpaquePointer?
            try withStrArray(paths) { try check(git_pathspec_new(&spec, $0)) }
            defer { git_pathspec_free(spec) }
            func matches(_ path: UnsafePointer<CChar>) -> Bool { git_pathspec_matches_path(spec, 0, path) == 1 }
            var stale: [String] = []
            for i in 0..<git_index_entrycount(staged) {
                if let e = git_index_get_byindex(staged, i), matches(e.pointee.path) { stale.append(String(cString: e.pointee.path)) }
            }
            for path in stale { git_index_remove(staged, path, 0) }
            for i in 0..<git_index_entrycount(index) {
                if let e = git_index_get_byindex(index, i), matches(e.pointee.path) { try check(git_index_add(staged, e)) }
            }
            var treeID = git_oid()
            try check(git_index_write_tree_to(&treeID, staged, repo))
            if let head {
                if merging == nil, git_oid_equal(&treeID, git_commit_tree_id(head)) == 1 { return false }
            } else if git_index_entrycount(staged) == 0 {
                return false
            }

            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, repo, &treeID))
            defer { git_tree_free(tree) }
            let sig = try makeSignature(repo)
            defer { git_signature_free(sig) }
            var parents: [OpaquePointer?] = head.map { [$0] } ?? []
            var other: OpaquePointer?
            if let merging {
                try check(git_revparse_single(&other, repo, "\(merging)^{commit}"))
                parents.append(other)
            }
            defer { git_object_free(other) }
            var id = git_oid()
            try check(git_commit_create(&id, repo, "HEAD", sig, sig, "UTF-8", message, tree, parents.count, &parents))
            return true
        }
    }

    /// The commits that changed `path`, newest first, following renames (like `git log --follow`).
    /// When the book was last saved, most recent first.
    func commitDates(limit: Int) -> [Date] {
        (try? withRepo { repo -> [Date] in
            guard let head = try headCommit(repo) else { return [] }
            git_commit_free(head)
            var walk: OpaquePointer?
            try check(git_revwalk_new(&walk, repo))
            defer { git_revwalk_free(walk) }
            git_revwalk_sorting(walk, GIT_SORT_TIME.rawValue)
            try check(git_revwalk_push_head(walk))
            var out: [Date] = []
            var oid = git_oid()
            while out.count < limit, git_revwalk_next(&oid, walk) == 0 {
                var commit: OpaquePointer?
                guard git_commit_lookup(&commit, repo, &oid) == 0 else { continue }
                defer { git_commit_free(commit) }
                out.append(Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit))))
            }
            return out
        }) ?? []
    }

    func log(path: String, limit: Int = 200) -> [Commit] {
        (try? withRepo { repo -> [Commit] in
            guard let head = try headCommit(repo) else { return [] }
            git_commit_free(head)
            var walk: OpaquePointer?
            try check(git_revwalk_new(&walk, repo))
            defer { git_revwalk_free(walk) }
            git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
            try check(git_revwalk_push_head(walk))
            var out: [Commit] = []
            var path = path
            var oid = git_oid()
            while out.count < limit, git_revwalk_next(&oid, walk) == 0 {
                var commit: OpaquePointer?
                guard git_commit_lookup(&commit, repo, &oid) == 0 else { continue }
                defer { git_commit_free(commit) }
                guard let blob = blobID(commit, path) else { continue }
                var changed = git_commit_parentcount(commit) == 0
                for i in 0..<git_commit_parentcount(commit) {
                    var parent: OpaquePointer?
                    guard git_commit_parent(&parent, commit, i) == 0 else { continue }
                    defer { git_commit_free(parent) }
                    if var old = blobID(parent, path) {
                        var b = blob
                        if git_oid_equal(&old, &b) != 1 { changed = true }
                    } else {
                        changed = true
                        if let renamed = renamedFrom(repo, parent, commit, path) { path = renamed }
                    }
                }
                guard changed else { continue }
                let summary = git_commit_summary(commit).map { String(cString: $0) } ?? ""
                out.append(Commit(id: String(cString: git_oid_tostr_s(&oid)),
                                  date: Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit))), subject: summary))
            }
            return out
        }) ?? []
    }

    /// The content of `path` at `commit` (a full or abbreviated id), like `git show commit:path`.
    func show(_ commit: String, path: String) -> String? {
        try? withRepo { repo -> String? in
            var obj: OpaquePointer?
            guard git_revparse_single(&obj, repo, "\(commit)^{commit}") == 0 else { return nil }
            defer { git_object_free(obj) }
            guard var id = blobID(obj, path) else { return nil }
            var blob: OpaquePointer?
            guard git_blob_lookup(&blob, repo, &id) == 0 else { return nil }
            defer { git_blob_free(blob) }
            let size = Int(git_blob_rawsize(blob))
            guard size > 0, let raw = git_blob_rawcontent(blob) else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: raw, count: size), as: UTF8.self)
        } ?? nil
    }

    /// Word diff of `path` between a commit and the working tree.
    func wordDiff(from commit: String, path: String) -> String {
        let now = (try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)) ?? ""
        return Self.wordDiff(show(commit, path: path) ?? "", now)
    }

    // MARK: Branches and remotes (for the collaboration server)

    /// The checked-out branch, nil when HEAD is detached or the repository has no commit yet.
    var currentBranch: String? {
        try? withRepo { repo -> String? in
            var ref: OpaquePointer?
            guard git_repository_head(&ref, repo) == 0 else { return nil }
            defer { git_reference_free(ref) }
            guard git_reference_is_branch(ref) == 1 else { return nil }
            var name: UnsafePointer<CChar>?
            return git_branch_name(&name, ref) == 0 ? name.map { String(cString: $0) } : nil
        } ?? nil
    }

    func branches() -> [String] {
        (try? withRepo { repo -> [String] in
            var iter: OpaquePointer?
            try check(git_branch_iterator_new(&iter, repo, GIT_BRANCH_LOCAL))
            defer { git_branch_iterator_free(iter) }
            var out: [String] = []
            var ref: OpaquePointer?
            var type = GIT_BRANCH_LOCAL
            while git_branch_next(&ref, &type, iter) == 0 {
                var name: UnsafePointer<CChar>?
                if git_branch_name(&name, ref) == 0, let name { out.append(String(cString: name)) }
                git_reference_free(ref)
            }
            return out.sorted()
        }) ?? []
    }

    /// A new branch at HEAD; the checked-out branch does not change.
    func createBranch(_ name: String) throws {
        try withRepo { repo in
            guard let head = try headCommit(repo) else { throw Failure(message: L("The repository has no commit yet.")) }
            defer { git_commit_free(head) }
            var ref: OpaquePointer?
            try check(git_branch_create(&ref, repo, name, head, 0))
            git_reference_free(ref)
        }
    }

    /// Remote names and URLs, e.g. ["origin": "https://…"].
    func remotes() -> [String: String] {
        (try? withRepo { repo -> [String: String] in
            var names = git_strarray()
            try check(git_remote_list(&names, repo))
            defer { git_strarray_dispose(&names) }
            var out: [String: String] = [:]
            for i in 0..<names.count {
                guard let cname = names.strings[i] else { continue }
                var remote: OpaquePointer?
                guard git_remote_lookup(&remote, repo, cname) == 0 else { continue }
                out[String(cString: cname)] = git_remote_url(remote).map { String(cString: $0) } ?? ""
                git_remote_free(remote)
            }
            return out
        }) ?? [:]
    }

    func addRemote(_ name: String, url: String) throws {
        try withRepo { repo in
            var remote: OpaquePointer?
            try check(git_remote_create(&remote, repo, name, url))
            git_remote_free(remote)
        }
    }

    // MARK: Network (the collaboration server, over HTTPS with the account's token)

    /// Clones `url` into `dir` (which must not exist yet).
    static func clone(_ url: String, to dir: URL, credentials: Credentials) throws {
        _ = start
        var opts = git_clone_options()
        git_clone_options_init(&opts, UInt32(GIT_CLONE_OPTIONS_VERSION))
        let box = Unmanaged.passRetained(credentials)
        defer { box.release() }
        opts.fetch_opts.callbacks.credentials = credentialCallback
        opts.fetch_opts.callbacks.payload = box.toOpaque()
        var repo: OpaquePointer?
        let code = git_clone(&repo, url, dir.path, &opts)
        git_repository_free(repo)
        try GitService(root: dir).check(code)
    }

    /// Sends `refspecs` (e.g. "refs/heads/main:refs/heads/main"; a leading + forces) to `remote`.
    func push(_ remote: String, refspecs: [String], credentials: Credentials) throws {
        git_error_clear()
        credentials.attempts = 0
        credentials.rejected = nil
        try withRemote(remote) { r in
            var opts = git_push_options()
            git_push_options_init(&opts, UInt32(GIT_PUSH_OPTIONS_VERSION))
            let box = Unmanaged.passRetained(credentials)
            defer { box.release() }
            opts.callbacks.credentials = credentialCallback
            opts.callbacks.push_update_reference = { name, status, payload in
                // The server's refusal of a branch is not a failed push, for libgit2: it only says so here.
                if let status, let payload {
                    Unmanaged<Credentials>.fromOpaque(payload).takeUnretainedValue().rejected = "\(name.map { String(cString: $0) } ?? "") : \(String(cString: status))"
                }
                return 0
            }
            opts.callbacks.payload = box.toOpaque()
            try withStrArray(refspecs) { try check(git_remote_push(r, $0, &opts)) }
        }
        if let rejected = credentials.rejected { throw Failure(message: rejected) }
    }

    /// Brings the remote's branches into refs/remotes/<remote>/….
    func fetch(_ remote: String, credentials: Credentials) throws {
        git_error_clear()
        credentials.attempts = 0
        try withRemote(remote) { r in
            var opts = git_fetch_options()
            git_fetch_options_init(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION))
            let box = Unmanaged.passRetained(credentials)
            defer { box.release() }
            opts.callbacks.credentials = credentialCallback
            opts.callbacks.payload = box.toOpaque()
            opts.prune = GIT_FETCH_PRUNE
            try check(git_remote_fetch(r, nil, &opts, nil))
        }
    }

    /// The commit id a revision names ("HEAD", "musset/main", a branch…), nil if unknown.
    func resolve(_ rev: String) -> String? {
        try? withRepo { repo -> String? in
            var obj: OpaquePointer?
            guard git_revparse_single(&obj, repo, "\(rev)^{commit}") == 0 else { return nil }
            defer { git_object_free(obj) }
            return String(cString: git_oid_tostr_s(git_object_id(obj)))
        } ?? nil
    }

    /// The last commit two revisions share.
    func mergeBase(_ a: String, _ b: String) -> String? {
        try? withRepo { repo -> String? in
            var x = git_oid(), y = git_oid(), base = git_oid()
            guard let ia = resolve(a), let ib = resolve(b),
                  git_oid_fromstr(&x, ia) == 0, git_oid_fromstr(&y, ib) == 0,
                  git_merge_base(&base, repo, &x, &y) == 0 else { return nil }
            return String(cString: git_oid_tostr_s(&base))
        } ?? nil
    }

    /// Makes `branch` (created at `rev` if needed) the checked-out branch, its files exactly those of `rev`.
    /// Only for a shared book's own clone: the working files are replaced.
    func switchBranch(_ branch: String, at rev: String) throws {
        try withRepo { repo in
            var obj: OpaquePointer?
            try check(git_revparse_single(&obj, repo, "\(rev)^{commit}"))
            defer { git_object_free(obj) }
            var ref: OpaquePointer?
            try check(git_branch_create(&ref, repo, branch, obj, 1))
            git_reference_free(ref)
            try check(git_repository_set_head(repo, "refs/heads/\(branch)"))
            var opts = git_checkout_options()
            git_checkout_options_init(&opts, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
            opts.checkout_strategy = GIT_CHECKOUT_FORCE.rawValue
            try check(git_reset(repo, obj, GIT_RESET_HARD, &opts))
        }
    }

    /// The account used to reach the server: user name and personal token (sent as the HTTPS password).
    final class Credentials {
        let user: String
        let token: String
        var attempts = 0
        /// A branch the server refused, with its reason.
        var rejected: String?
        init(user: String, token: String) { self.user = user; self.token = token }
    }

    private func withRemote(_ name: String, _ body: (OpaquePointer?) throws -> Void) throws {
        try withRepo { repo in
            var remote: OpaquePointer?
            try check(git_remote_lookup(&remote, repo, name))
            defer { git_remote_free(remote) }
            try body(remote)
        }
    }

    // MARK: libgit2 plumbing

    static var libraryVersion: String {
        var major: Int32 = 0, minor: Int32 = 0, rev: Int32 = 0
        git_libgit2_version(&major, &minor, &rev)
        return "\(major).\(minor).\(rev)"
    }

    static let start: Void = { _ = git_libgit2_init() }()

    func withRepo<T>(_ body: (OpaquePointer?) throws -> T) throws -> T {
        _ = Self.start
        var repo: OpaquePointer?
        try check(git_repository_open(&repo, root.path))
        defer { git_repository_free(repo) }
        return try body(repo)
    }

    func check(_ code: Int32) throws {
        guard code < 0 else { return }
        var message = git_error_last().flatMap { $0.pointee.message.map { String(cString: $0) } } ?? ""
        if message.isEmpty || code == GIT_ENONFASTFORWARD.rawValue { message = code == GIT_ENONFASTFORWARD.rawValue ? "non-fast-forward" : L("git error \(code)") }
        throw Failure(message: message)
    }

    /// HEAD's commit, nil on a repository with no commit yet. The caller frees it.
    func headCommit(_ repo: OpaquePointer?) throws -> OpaquePointer? {
        if git_repository_head_unborn(repo) == 1 { return nil }
        var id = git_oid()
        try check(git_reference_name_to_id(&id, repo, "HEAD"))
        var commit: OpaquePointer?
        try check(git_commit_lookup(&commit, repo, &id))
        return commit
    }

    /// The blob id of `path` in a commit, nil when the file isn't there.
    func blobID(_ commit: OpaquePointer?, _ path: String) -> git_oid? {
        var tree: OpaquePointer?
        guard git_commit_tree(&tree, commit) == 0 else { return nil }
        defer { git_tree_free(tree) }
        var entry: OpaquePointer?
        guard git_tree_entry_bypath(&entry, tree, path) == 0 else { return nil }
        defer { git_tree_entry_free(entry) }
        guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return nil }
        return git_tree_entry_id(entry)?.pointee
    }

    /// The path `path` had in `parent`, when `commit` renamed it.
    private func renamedFrom(_ repo: OpaquePointer?, _ parent: OpaquePointer?, _ commit: OpaquePointer?, _ path: String) -> String? {
        var a: OpaquePointer?, b: OpaquePointer?
        guard git_commit_tree(&a, parent) == 0, git_commit_tree(&b, commit) == 0 else { return nil }
        defer { git_tree_free(a); git_tree_free(b) }
        var diff: OpaquePointer?
        guard git_diff_tree_to_tree(&diff, repo, a, b, nil) == 0 else { return nil }
        defer { git_diff_free(diff) }
        var opts = git_diff_find_options()
        git_diff_find_options_init(&opts, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION))
        opts.flags = GIT_DIFF_FIND_RENAMES.rawValue
        guard git_diff_find_similar(diff, &opts) == 0 else { return nil }
        for i in 0..<git_diff_num_deltas(diff) {
            guard let d = git_diff_get_delta(diff, i)?.pointee, d.status == GIT_DELTA_RENAMED,
                  let new = d.new_file.path, String(cString: new) == path, let old = d.old_file.path else { continue }
            return String(cString: old)
        }
        return nil
    }

    func withStrArray<T>(_ items: [String], _ body: (UnsafePointer<git_strarray>) throws -> T) throws -> T {
        var cstrings = items.map { strdup($0) }
        defer { cstrings.forEach { free($0) } }
        return try cstrings.withUnsafeMutableBufferPointer { buf in
            var array = git_strarray(strings: buf.baseAddress, count: buf.count)
            return try body(&array)
        }
    }
}

/// Gives libgit2 the account's credentials; a refused token is not tried again and again.
private let credentialCallback: git_credential_acquire_cb = { out, _, _, _, payload in
    guard let payload else { return -1 }
    let creds = Unmanaged<GitService.Credentials>.fromOpaque(payload).takeUnretainedValue()
    creds.attempts += 1
    guard creds.attempts <= 2 else { return -1 }
    return git_credential_userpass_plaintext_new(out, creds.user, creds.token)
}

// MARK: Word diff

extension GitService {
    /// Word diff between two texts, in git's `--word-diff=plain` form: `[-removed-]{+added+}` inside the
    /// new text, after a `@@` line. Words are runs of non-space characters. Empty when nothing changed.
    static func wordDiff(_ a: String, _ b: String) -> String {
        let old = Token.split(a), new = Token.split(b)
        // Only the middle that differs goes through the diff: a chapter edit is usually small.
        var head = 0
        while head < old.count, head < new.count, old[head].word == new[head].word { head += 1 }
        var tail = 0
        while tail < old.count - head, tail < new.count - head, old[old.count - 1 - tail].word == new[new.count - 1 - tail].word { tail += 1 }
        let diff = new[head..<(new.count - tail)].map(\.word).difference(from: old[head..<(old.count - tail)].map(\.word))
        guard !diff.isEmpty else { return "" }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(head + offset)
            case .insert(let offset, _, _): inserted.insert(head + offset)
            }
        }
        var out = "@@ -1 +1 @@\n"
        var i = 0, j = 0
        var afterRemoval = false
        while i < old.count || j < new.count {
            if i < old.count, removed.contains(i) {
                var run = old[i].space + "[-" + old[i].word
                i += 1
                while i < old.count, removed.contains(i) { run += old[i].space + old[i].word; i += 1 }
                out += run + "-]"
                afterRemoval = true
            } else if j < new.count, inserted.contains(j) {
                var run = (afterRemoval ? "" : new[j].space) + "{+" + new[j].word
                j += 1
                while j < new.count, inserted.contains(j) { run += new[j].space + new[j].word; j += 1 }
                out += run + "+}"
                afterRemoval = false
            } else {
                // After a removal at the very start, keep the space the old text had.
                out += (afterRemoval && new[j].space.isEmpty ? old[i].space : new[j].space) + new[j].word
                i += 1; j += 1
                afterRemoval = false
            }
        }
        out += Token.trailingSpace(b)
        return out
    }

    /// A word and the whitespace before it.
    private struct Token {
        let space: String
        let word: String

        static func split(_ s: String) -> [Token] {
            var out: [Token] = []
            var space = "", word = ""
            for c in s {
                if c.isWhitespace {
                    if !word.isEmpty { out.append(Token(space: space, word: word)); space = ""; word = "" }
                    space.append(c)
                } else {
                    word.append(c)
                }
            }
            if !word.isEmpty { out.append(Token(space: space, word: word)) }
            return out
        }

        static func trailingSpace(_ s: String) -> String { String(s.reversed().prefix { $0.isWhitespace }.reversed()) }
    }
}
