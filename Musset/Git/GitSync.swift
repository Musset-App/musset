import Foundation
import libgit2

/// What syncing needs from git: reading a file at a revision, what changed between two, moving the branch.
extension GitService {
    /// A file's bytes at a revision; nil when it isn't there.
    func data(_ rev: String, path: String) -> Data? {
        (try? withRepo { repo -> Data? in
            var obj: OpaquePointer?
            guard git_revparse_single(&obj, repo, "\(rev)^{commit}") == 0 else { return nil }
            defer { git_object_free(obj) }
            guard var id = blobID(obj, path) else { return nil }
            var blob: OpaquePointer?
            guard git_blob_lookup(&blob, repo, &id) == 0 else { return nil }
            defer { git_blob_free(blob) }
            let size = Int(git_blob_rawsize(blob))
            guard size > 0, let raw = git_blob_rawcontent(blob) else { return Data() }
            return Data(bytes: raw, count: size)
        }) ?? nil
    }

    /// The paths that differ between two revisions; a nil `from` means everything in `to`.
    func changedPaths(from: String?, to: String) throws -> [String] {
        try withRepo { repo in
            func tree(_ rev: String) throws -> OpaquePointer? {
                var obj: OpaquePointer?
                try check(git_revparse_single(&obj, repo, "\(rev)^{tree}"))
                return obj
            }
            let a: OpaquePointer? = try from.flatMap(tree)
            let b = try tree(to)
            defer { git_object_free(a); git_object_free(b) }
            var diff: OpaquePointer?
            try check(git_diff_tree_to_tree(&diff, repo, a, b, nil))
            defer { git_diff_free(diff) }
            var out = Set<String>()
            for i in 0..<git_diff_num_deltas(diff) {
                guard let d = git_diff_get_delta(diff, i)?.pointee else { continue }
                if let p = d.old_file.path { out.insert(String(cString: p)) }
                if let p = d.new_file.path { out.insert(String(cString: p)) }
            }
            return out.sorted()
        }
    }

    /// The current branch now points at `rev`, and the index with it. Files on disk are left alone:
    /// the caller wrote the book's, and the author's others are not ours to touch.
    func advance(to rev: String) throws {
        try withRepo { repo in
            var obj: OpaquePointer?
            try check(git_revparse_single(&obj, repo, "\(rev)^{commit}"))
            defer { git_object_free(obj) }
            if git_repository_head_unborn(repo) == 1 {
                var ref: OpaquePointer?
                try check(git_reference_create(&ref, repo, "refs/heads/main", git_object_id(obj), 1, "musset: sync"))
                git_reference_free(ref)
                try check(git_repository_set_head(repo, "refs/heads/main"))
            } else {
                var head: OpaquePointer?
                try check(git_repository_head(&head, repo))
                defer { git_reference_free(head) }
                var moved: OpaquePointer?
                try check(git_reference_set_target(&moved, head, git_object_id(obj), "musset: sync"))
                git_reference_free(moved)
            }
            var index: OpaquePointer?
            try check(git_repository_index(&index, repo))
            defer { git_index_free(index) }
            var tree: OpaquePointer?
            try check(git_commit_tree(&tree, obj))
            defer { git_tree_free(tree) }
            try check(git_index_read_tree(index, tree))
            try check(git_index_write(index))
        }
    }

    /// A track behind the other Mac's catches up. It isn't checked out, so only its ref moves.
    func switchTrack(_ branch: String, to rev: String) throws {
        try withRepo { repo in
            var obj: OpaquePointer?
            try check(git_revparse_single(&obj, repo, "\(rev)^{commit}"))
            defer { git_object_free(obj) }
            var ref: OpaquePointer?
            try check(git_reference_create(&ref, repo, "refs/heads/\(branch)", git_object_id(obj), 1, "musset: sync"))
            git_reference_free(ref)
        }
    }

    /// The branches a remote has, by their short name.
    func remoteBranches(_ remote: String) -> [String] {
        (try? withRepo { repo -> [String] in
            var iter: OpaquePointer?
            try check(git_branch_iterator_new(&iter, repo, GIT_BRANCH_REMOTE))
            defer { git_branch_iterator_free(iter) }
            var out: [String] = []
            var ref: OpaquePointer?
            var kind = GIT_BRANCH_REMOTE
            while git_branch_next(&ref, &kind, iter) == 0 {
                defer { git_reference_free(ref) }
                var name: UnsafePointer<CChar>?
                if git_branch_name(&name, ref) == 0, let name {
                    let s = String(cString: name)
                    if s.hasPrefix(remote + "/") { out.append(String(s.dropFirst(remote.count + 1))) }
                }
            }
            return out
        }) ?? []
    }

    /// Who made a revision, as the account's name when it has one.
    func authorName(_ rev: String) -> String? {
        (try? withRepo { repo -> String? in
            var obj: OpaquePointer?
            guard git_revparse_single(&obj, repo, "\(rev)^{commit}") == 0 else { return nil }
            defer { git_object_free(obj) }
            guard let sig = git_commit_author(obj)?.pointee else { return nil }
            return Attribution.person(name: sig.name.map { String(cString: $0) } ?? "", email: sig.email.map { String(cString: $0) } ?? "", owner: nil)
        }) ?? nil
    }

    /// Signed in, commits carry the account: that is how "who wrote what" knows people apart.
    /// Otherwise the author's git identity, else a local fallback so a fresh Mac can still commit.
    func makeSignature(_ repo: OpaquePointer?) throws -> UnsafeMutablePointer<git_signature>? {
        var sig: UnsafeMutablePointer<git_signature>?
        if let user = UserDefaults.standard.string(forKey: "collabUser"), !user.isEmpty {
            try check(git_signature_now(&sig, user, user + Attribution.accountDomain))
        } else if git_signature_default(&sig, repo) != 0 {
            try check(git_signature_now(&sig, "Musset", "musset@localhost"))
        }
        return sig
    }
}

/// Two copies of a book that parted: what each side did is kept. Files one side changed are taken;
/// files both changed are merged by kind. Nothing here asks a question.
enum SyncMerge {
    /// A chapter: paragraphs one side changed are taken. A paragraph both rewrote stays mine, with theirs as a correction.
    static func chapter(base: String, mine: String, theirs: String, who: String) -> (text: String, conflicts: Int) {
        var out: [String] = []
        var conflicts = 0
        for b in ParagraphMerge.blocks(base: base, mine: mine, theirs: theirs) {
            guard b.isChange else { out += b.same; continue }
            switch b.suggested {
            case .theirs: out += b.theirs
            case .mine, .both: out += b.mine
            case nil:
                conflicts += 1
                let plain = !(b.mine + b.theirs).contains { $0.contains("{") }
                if plain, b.mine.count == 1, b.theirs.count == 1 {
                    out.append("{~~\(b.mine[0])~>\(b.theirs[0])~~}{>>\(who)<<}")
                } else {
                    out += b.mine
                    out += b.theirs.map { $0.contains("{") ? "{>>\(who) : \($0.replacingOccurrences(of: "<<}", with: ""))<<}" : "{++\($0)++}{>>\(who)<<}" }
                }
            }
        }
        return (out.joined(separator: "\n"), conflicts)
    }

    /// Other text (sheets, notepads, the dictionary): nothing is marked, nothing is lost.
    static func plain(base: String, mine: String, theirs: String) -> String {
        var out: [String] = []
        for b in ParagraphMerge.blocks(base: base, mine: mine, theirs: theirs) {
            guard b.isChange else { out += b.same; continue }
            switch b.suggested {
            case .theirs: out += b.theirs
            case .mine, .both: out += b.mine
            case nil: out += b.mine + b.theirs
            }
        }
        return out.joined(separator: "\n")
    }

    /// JSON, by field and by record (`id`). What only one side changed is taken; where both did, mine stays.
    static func json(base: Data?, mine: Data, theirs: Data) -> Data {
        func parse(_ d: Data?) -> Any? { d.flatMap { try? JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) } }
        guard let m = parse(mine), let t = parse(theirs) else { return mine }
        let merged = value(base: parse(base), mine: m, theirs: t)
        return (try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed])) ?? mine
    }

    private static func same(_ a: Any?, _ b: Any?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return (a as AnyObject).isEqual(b)
        default: return false
        }
    }

    private static func value(base: Any?, mine: Any, theirs: Any) -> Any {
        if same(mine, theirs) { return mine }
        if same(base, mine) { return theirs }
        if same(base, theirs) { return mine }
        if let m = mine as? [String: Any], let t = theirs as? [String: Any] {
            let b = base as? [String: Any] ?? [:]
            var out: [String: Any] = [:]
            for key in Set(m.keys).union(t.keys) {
                switch (m[key], t[key]) {
                case (let x?, let y?): out[key] = value(base: b[key], mine: x, theirs: y)
                case (let x?, nil): if !same(b[key], x) { out[key] = x }   // they removed what I left alone: gone
                case (nil, let y?): if !same(b[key], y) { out[key] = y }
                default: break
                }
            }
            return out
        }
        if let m = records(mine), let t = records(theirs) { return merge(records(base ?? []) ?? [], m, t) }
        return mine
    }

    private static func records(_ any: Any) -> [[String: Any]]? {
        guard let list = any as? [[String: Any]], list.allSatisfy({ $0["id"] != nil }) else { return nil }
        return list
    }

    private static func merge(_ base: [[String: Any]], _ mine: [[String: Any]], _ theirs: [[String: Any]]) -> [[String: Any]] {
        func key(_ r: [String: Any]) -> String { "\(r["id"] ?? "")" }
        let b = Dictionary(base.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let m = Dictionary(mine.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        let t = Dictionary(theirs.map { (key($0), $0) }, uniquingKeysWith: { a, _ in a })
        // The order: theirs if I didn't reorder, else mine.
        let primary = mine.map(key) == base.map(key).filter { m[$0] != nil } ? theirs : mine
        var order = primary.map(key)
        for r in mine + theirs where !order.contains(key(r)) { order.append(key(r)) }
        return order.compactMap { id in
            switch (m[id], t[id]) {
            case (let x?, let y?): return value(base: b[id], mine: x, theirs: y) as? [String: Any]
            case (let x?, nil): return same(b[id], x) ? nil : x
            case (nil, let y?): return same(b[id], y) ? nil : y
            default: return nil
            }
        }
    }

    struct Outcome { var conflicts = 0; var changed: [String] = [] }

    /// Writes into the working folder what `theirs` brings since `base`. Only paths `allowed` says yes to are touched.
    /// `chapters`: the book's chapter files. `keepBoth`: a document both changed stays twice.
    static func apply(_ git: GitService, base: String?, theirs: String, who: String,
                      chapters: Set<String>, keepBoth: Bool, allowed: (String) -> Bool) throws -> Outcome {
        var outcome = Outcome()
        let fm = FileManager.default
        for path in try git.changedPaths(from: base, to: theirs) where allowed(path) {
            let url = git.root.appendingPathComponent(path)
            let b = base.flatMap { git.data($0, path: path) }
            let t = git.data(theirs, path: path)
            let m = try? Data(contentsOf: url)
            if m == t { continue }
            var result: Data?
            if m == b {
                result = t
            } else if t == b {
                continue   // only I changed it
            } else if let m, let t {
                result = merged(path: path, base: b, mine: m, theirs: t, who: who, chapters: chapters, outcome: &outcome)
                if result == nil, keepBoth {
                    let copy = L("\(url.deletingPathExtension().lastPathComponent) (other version).\(url.pathExtension)")
                    try t.write(to: url.deletingLastPathComponent().appendingPathComponent(copy), options: .atomic)
                    continue
                }
                if result == nil { continue }
            } else {
                result = m ?? t   // deleted on one side, changed on the other: the text stays
            }
            if let result {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try result.write(to: url, options: .atomic)
            } else if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }
            outcome.changed.append(path)
        }
        return outcome
    }

    private static func merged(path: String, base: Data?, mine: Data, theirs: Data, who: String, chapters: Set<String>, outcome: inout Outcome) -> Data? {
        func text(_ d: Data?) -> String { d.map { String(decoding: $0, as: UTF8.self) } ?? "" }
        if path.hasSuffix(".json") { return json(base: base, mine: mine, theirs: theirs) }
        // Notes merge note by note, like any record: whatever only one side changed is taken.
        if path.hasPrefix(".musset/notes/"), path.hasSuffix(".md") {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            func records(_ d: Data?) -> Data? { try? enc.encode(NoteMarkdown.decode(text(d))) }
            guard let m = records(mine), let t = records(theirs) else { return nil }
            let out = json(base: records(base), mine: m, theirs: t)
            return Data(NoteStore.sortedForDisk(NoteStore.readJSON(out)).utf8)
        }
        if chapters.contains(path) {
            let out = chapter(base: ParagraphCodec.decode(text(base)), mine: ParagraphCodec.decode(text(mine)), theirs: ParagraphCodec.decode(text(theirs)), who: who)
            outcome.conflicts += out.conflicts
            return Data(ParagraphCodec.encode(out.text).utf8)
        }
        if [".md", ".txt", ".bib", ".ris"].contains(where: path.hasSuffix) {
            return Data(plain(base: text(base), mine: text(mine), theirs: text(theirs)).utf8)
        }
        return nil
    }
}
