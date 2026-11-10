import Foundation
import libgit2

/// Tracks (« pistes ») and milestones (« jalons ») as plain git: a track is a branch `piste/<slug>`,
/// written straight into git (never checked out, so the book's folder always holds the manuscript);
/// a milestone is an annotated tag `jalon/<slug>`.
extension GitService {
    struct Tag: Identifiable, Hashable {
        /// Its name under refs/tags, e.g. « jalon/premier-jet ».
        let id: String
        let message: String
        let commit: String
        let date: Date
        var title: String { message.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? id }
        var note: String {
            let parts = message.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            return parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        }
    }

    /// One commit of a line of history.
    struct Point: Identifiable, Hashable {
        let id: String
        let date: Date
        let subject: String
        let parents: [String]
    }

    /// A new branch at `rev` (a branch, tag or commit); the checked-out branch does not change.
    func createBranch(_ name: String, at rev: String) throws {
        try withRepo { repo in
            var obj: OpaquePointer?
            try check(git_revparse_single(&obj, repo, "\(rev)^{commit}"))
            defer { git_object_free(obj) }
            var ref: OpaquePointer?
            try check(git_branch_create(&ref, repo, name, obj, 0))
            git_reference_free(ref)
        }
    }

    /// Commits `files` (path → content) on top of `branch`, without touching the working tree or the index.
    /// Returns false when nothing changed.
    @discardableResult
    func commit(onBranch branch: String, files: [String: String], message: String) throws -> Bool {
        try withRepo { repo in
            var tipID = git_oid()
            try check(git_reference_name_to_id(&tipID, repo, "refs/heads/\(branch)"))
            var tip: OpaquePointer?
            try check(git_commit_lookup(&tip, repo, &tipID))
            defer { git_commit_free(tip) }
            var tipTree: OpaquePointer?
            try check(git_commit_tree(&tipTree, tip))
            defer { git_tree_free(tipTree) }

            var index: OpaquePointer?
            try check(git_index_new(&index))
            defer { git_index_free(index) }
            try check(git_index_read_tree(index, tipTree))
            for (path, content) in files.sorted(by: { $0.key < $1.key }) {
                var blob = git_oid()
                let data = Array(content.utf8)
                try check(data.withUnsafeBytes { git_blob_create_from_buffer(&blob, repo, $0.baseAddress, data.count) })
                try path.withCString { cpath in
                    var entry = git_index_entry()
                    entry.mode = GIT_FILEMODE_BLOB.rawValue
                    entry.id = blob
                    entry.path = cpath
                    try check(git_index_add(index, &entry))
                }
            }
            var treeID = git_oid()
            try check(git_index_write_tree_to(&treeID, index, repo))
            if git_oid_equal(&treeID, git_commit_tree_id(tip)) == 1 { return false }
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, repo, &treeID))
            defer { git_tree_free(tree) }
            let sig = try makeSignature(repo)
            defer { git_signature_free(sig) }
            var parents: [OpaquePointer?] = [tip]
            var id = git_oid()
            try check(git_commit_create(&id, repo, "refs/heads/\(branch)", sig, sig, "UTF-8", message, tree, 1, &parents))
            return true
        }
    }

    /// True when `a` is `b` or one of its ancestors: everything in `a` is already in `b`.
    func isAncestor(_ a: String, of b: String) -> Bool {
        guard let ia = resolve(a), let ib = resolve(b) else { return false }
        if ia == ib { return true }
        return (try? withRepo { repo -> Bool in
            var x = git_oid(), y = git_oid()
            guard git_oid_fromstr(&x, ia) == 0, git_oid_fromstr(&y, ib) == 0 else { return false }
            return git_graph_descendant_of(repo, &y, &x) == 1
        }) ?? false
    }

    /// An annotated tag on `rev`: the first line of `message` is its title.
    func createTag(_ name: String, message: String, at rev: String = "HEAD") throws {
        try withRepo { repo in
            var obj: OpaquePointer?
            try check(git_revparse_single(&obj, repo, "\(rev)^{commit}"))
            defer { git_object_free(obj) }
            let sig = try makeSignature(repo)
            defer { git_signature_free(sig) }
            var id = git_oid()
            try check(git_tag_create(&id, repo, name, obj, sig, message, 0))
        }
    }

    func deleteTag(_ name: String) throws {
        try withRepo { repo in try check(git_tag_delete(repo, name)) }
    }

    /// Tags matching `pattern` (e.g. « jalon/* »), newest first.
    func tags(matching pattern: String) -> [Tag] {
        (try? withRepo { repo -> [Tag] in
            var names = git_strarray()
            try check(git_tag_list_match(&names, pattern, repo))
            defer { git_strarray_dispose(&names) }
            var out: [Tag] = []
            for i in 0..<names.count {
                guard let cname = names.strings[i] else { continue }
                let name = String(cString: cname)
                var obj: OpaquePointer?
                guard git_revparse_single(&obj, repo, "refs/tags/\(name)") == 0 else { continue }
                defer { git_object_free(obj) }
                var message = name
                var date: Date?
                if git_object_type(obj) == GIT_OBJECT_TAG {
                    message = git_tag_message(obj).map { String(cString: $0) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? name
                    if let t = git_tag_tagger(obj) { date = Date(timeIntervalSince1970: TimeInterval(t.pointee.when.time)) }
                }
                var target: OpaquePointer?
                guard git_object_peel(&target, obj, GIT_OBJECT_COMMIT) == 0 else { continue }
                defer { git_object_free(target) }
                let commit = String(cString: git_oid_tostr_s(git_object_id(target)))
                out.append(Tag(id: name, message: message, commit: commit,
                               date: date ?? Date(timeIntervalSince1970: TimeInterval(git_commit_time(target)))))
            }
            return out.sorted { $0.date > $1.date }
        }) ?? []
    }

    /// The commits of `rev` following first parents only (the line itself, not what was merged in), newest first.
    func points(_ rev: String, since: Date? = nil, limit: Int = 500) -> [Point] {
        (try? withRepo { repo -> [Point] in
            var start = git_oid()
            guard let id = resolve(rev), git_oid_fromstr(&start, id) == 0 else { return [] }
            var walk: OpaquePointer?
            try check(git_revwalk_new(&walk, repo))
            defer { git_revwalk_free(walk) }
            git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_TIME.rawValue)
            git_revwalk_simplify_first_parent(walk)
            try check(git_revwalk_push(walk, &start))
            var out: [Point] = []
            var oid = git_oid()
            while out.count < limit, git_revwalk_next(&oid, walk) == 0 {
                var commit: OpaquePointer?
                guard git_commit_lookup(&commit, repo, &oid) == 0 else { continue }
                defer { git_commit_free(commit) }
                let date = Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))
                if let since, date < since { break }
                var parents: [String] = []
                for i in 0..<git_commit_parentcount(commit) {
                    if let p = git_commit_parent_id(commit, i) { parents.append(String(cString: git_oid_tostr_s(p))) }
                }
                out.append(Point(id: String(cString: git_oid_tostr_s(&oid)), date: date,
                                 subject: git_commit_summary(commit).map { String(cString: $0) } ?? "", parents: parents))
            }
            return out
        }) ?? []
    }

    /// The files a commit changed against its first parent (all of them for a first commit).
    func changedPaths(_ commit: String) -> [String] {
        (try? withRepo { repo -> [String] in
            var obj: OpaquePointer?
            try check(git_revparse_single(&obj, repo, "\(commit)^{commit}"))
            defer { git_object_free(obj) }
            var tree: OpaquePointer?, parentTree: OpaquePointer?
            try check(git_commit_tree(&tree, obj))
            defer { git_tree_free(tree); git_tree_free(parentTree) }
            if git_commit_parentcount(obj) > 0 {
                var parent: OpaquePointer?
                if git_commit_parent(&parent, obj, 0) == 0 {
                    git_commit_tree(&parentTree, parent)
                    git_commit_free(parent)
                }
            }
            var diff: OpaquePointer?
            try check(git_diff_tree_to_tree(&diff, repo, parentTree, tree, nil))
            defer { git_diff_free(diff) }
            return (0..<git_diff_num_deltas(diff)).compactMap { i in
                git_diff_get_delta(diff, i)?.pointee.new_file.path.map { String(cString: $0) }
            }
        }) ?? []
    }
}
