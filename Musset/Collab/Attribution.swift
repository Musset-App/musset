import Foundation
import libgit2
import SwiftUI

/// Who wrote what, word by word: the history is walked and each word keeps the commit that brought it.
/// A correction proposed by a reader counts as theirs once accepted: versions are read with corrections accepted.
struct Attribution: Sendable, Equatable {
    static let accountDomain = "@accounts.musset.app"

    struct Word: Sendable, Equatable { let text: String; let author: Int32 }
    struct Author: Sendable, Equatable { let person: String; let date: Date }

    var words: [Word] = []
    var authors: [Author] = []

    /// A commit's person: the account it was signed with, or the book's owner for commits made before accounts.
    nonisolated static func person(name: String, email: String, owner: String?) -> String {
        if email.hasSuffix(accountDomain) { return String(email.dropLast(accountDomain.count)) }
        return owner ?? name
    }

    /// The words of a text, with their place. Spaces of any kind and apostrophes don't make a word different:
    /// the typography pass must not take a word from its author.
    nonisolated static func tokens(_ text: String) -> [(word: String, range: NSRange)] {
        var out: [(String, NSRange)] = []
        let ns = text as NSString
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { s, r, _, _ in
            if let s { out.append((s.replacingOccurrences(of: "'", with: "’"), r)) }
        }
        return out
    }

    /// The operations turning `old` into `new`: for each new index, the old index it comes from. Common ends are
    /// trimmed first, and a total rewrite of a long text doesn't try to find crumbs.
    nonisolated static func matches(old: [String], new: [String]) -> [Int: Int] {
        var map: [Int: Int] = [:]
        let ends = Diff.commonEnds(old, new)
        for k in 0..<ends.head { map[k] = k }
        for k in 0..<ends.tail { map[new.count - 1 - k] = old.count - 1 - k }
        let a = old.count - ends.head - ends.tail, b = new.count - ends.head - ends.tail
        guard a > 0, b > 0, a * b < 16_000_000 else { return map }
        // Between two stretches that differ, the words are the same ones.
        var i = ends.head, j = ends.head
        for gap in Diff.gaps(old, new) + [((old.count - ends.tail)..<old.count, (new.count - ends.tail)..<new.count)] {
            while j < gap.new.lowerBound { map[j] = i; i += 1; j += 1 }
            i = gap.old.upperBound; j = gap.new.upperBound
        }
        return map
    }

    /// One version: its words take from the first parent, then the second; what neither had is the commit's.
    nonisolated static func next(words: [String], parents: [[Word]], author: Int32) -> [Word] {
        var owners = [Int32?](repeating: nil, count: words.count)
        for parent in parents {
            let map = matches(old: parent.map(\.text), new: words)
            for (n, o) in map where owners[n] == nil { owners[n] = parent[o].author }
        }
        return words.enumerated().map { Word(text: $1, author: owners[$0] ?? author) }
    }

    /// Who wrote each word of the file at HEAD. Every commit that changed it is read: run it away from the main thread.
    nonisolated static func compute(_ git: GitService, path: String, owner: String?) throws -> Attribution {
        try git.withRepo { repo in
            guard git_repository_head_unborn(repo) != 1 else { return Attribution() }
            var walk: OpaquePointer?
            try git.check(git_revwalk_new(&walk, repo))
            defer { git_revwalk_free(walk) }
            git_revwalk_sorting(walk, GIT_SORT_TOPOLOGICAL.rawValue | GIT_SORT_REVERSE.rawValue)
            try git.check(git_revwalk_push_head(walk))
            var out = Attribution()
            var byCommit: [String: (blob: String?, words: [Word])] = [:]
            func hex(_ oid: UnsafePointer<git_oid>?) -> String { oid.flatMap { git_oid_tostr_s($0) }.map { String(cString: $0) } ?? "" }
            var oid = git_oid()
            var last = ""
            while git_revwalk_next(&oid, walk) == 0 {
                var commit: OpaquePointer?
                guard git_commit_lookup(&commit, repo, &oid) == 0 else { continue }
                defer { git_commit_free(commit) }
                let id = hex(&oid)
                last = id
                let blob = git.blobID(commit, path).map { b -> String in var b = b; return hex(&b) }
                var parents: [(blob: String?, words: [Word])] = []
                for i in 0..<git_commit_parentcount(commit) {
                    if let p = byCommit[hex(git_commit_parent_id(commit, i))] { parents.append(p) }
                }
                if let same = parents.first(where: { $0.blob == blob }) {
                    byCommit[id] = (blob, same.words)
                    continue
                }
                guard let blob else { byCommit[id] = (nil, []); continue }
                guard var b = git.blobID(commit, path), let text = read(repo, &b) else { byCommit[id] = (blob, []); continue }
                let sig = git_commit_author(commit)?.pointee
                let message = git_commit_message(commit).map { String(cString: $0) } ?? ""
                let person = trailer(message) ?? Attribution.person(name: sig?.name.map { String(cString: $0) } ?? "", email: sig?.email.map { String(cString: $0) } ?? "", owner: owner)
                out.authors.append(Author(person: person, date: Date(timeIntervalSince1970: TimeInterval(git_commit_time(commit)))))
                let words = tokens(Revisions.resolveAll(text, accept: true)).map(\.word)
                byCommit[id] = (blob, next(words: words, parents: parents.map(\.words).filter { !$0.isEmpty }, author: Int32(out.authors.count - 1)))
            }
            out.words = byCommit[last]?.words ?? []
            return out
        }
    }

    private nonisolated static func read(_ repo: OpaquePointer?, _ id: inout git_oid) -> String? {
        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, repo, &id) == 0 else { return nil }
        defer { git_blob_free(blob) }
        let size = Int(git_blob_rawsize(blob))
        guard size > 0, let raw = git_blob_rawcontent(blob) else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: raw, count: size), as: UTF8.self)
    }

    /// A review brought in: the words are the reader's though the author made the commit.
    nonisolated static func trailer(_ message: String) -> String? {
        message.components(separatedBy: "\n").first { $0.hasPrefix("Musset-Author: ") }.map { String($0.dropFirst(15)) }
    }

    /// The editor's text with the old words of corrections and the comments blanked, so they count for nobody.
    nonisolated static func readable(_ text: String) -> String {
        let out = NSMutableString(string: text)
        func blank(_ r: NSRange) { out.replaceCharacters(in: r, with: String(repeating: " ", count: r.length)) }
        for m in Revisions.marks(in: text) {
            switch m.kind {
            case .deletion, .comment: blank(m.range)
            case .insertion:
                blank(NSRange(location: m.range.location, length: m.first.location - m.range.location))
                blank(NSRange(location: NSMaxRange(m.first), length: NSMaxRange(m.range) - NSMaxRange(m.first)))
            case .substitution:
                let new = m.second ?? m.first
                blank(NSRange(location: m.range.location, length: new.location - m.range.location))
                blank(NSRange(location: NSMaxRange(new), length: NSMaxRange(m.range) - NSMaxRange(new)))
            case .highlight:
                blank(NSRange(location: m.range.location, length: m.first.location - m.range.location))
                blank(NSRange(location: NSMaxRange(m.first), length: NSMaxRange(m.range) - NSMaxRange(m.first)))
            }
        }
        return out as String
    }

    struct Run: Equatable { var range: NSRange; let person: Int; let date: Date? }
    struct Share: Identifiable, Equatable { let person: String; let words: Int; var id: String { person } }
    struct Map: Equatable {
        var runs: [Run] = []
        var people: [Share] = []
    }

    /// Lays the history onto the text as it stands; what isn't committed yet is `me`'s.
    nonisolated func map(onto text: String, me: String) -> Map {
        let readable = Self.readable(text)
        let source = readable as NSString
        let current = Self.tokens(readable)
        let links = Self.matches(old: words.map(\.text), new: current.map(\.word))
        var names: [String] = []
        var counts: [Int] = []
        var runs: [Run] = []
        func index(_ name: String) -> Int {
            if let i = names.firstIndex(of: name) { return i }
            names.append(name); counts.append(0)
            return names.count - 1
        }
        for (n, token) in current.enumerated() {
            let author = links[n].map { authors[Int(words[$0].author)] }
            let who = index(author?.person ?? me)
            counts[who] += 1
            // A run stops at the end of a paragraph: a heading's tall line must not tint what follows.
            if var last = runs.last, last.person == who, last.date == author?.date,
               !source.substring(with: NSRange(location: NSMaxRange(last.range), length: token.range.location - NSMaxRange(last.range))).contains("\n") {
                last.range = NSUnionRange(last.range, token.range)
                runs[runs.count - 1] = last
            } else {
                runs.append(Run(range: token.range, person: who, date: author?.date))
            }
        }
        let people = zip(names, counts).map { Share(person: $0, words: $1) }
        return Map(runs: runs, people: people)
    }

    private static let tints: [NSColor] = [.systemBlue, .systemOrange, .systemGreen, .systemPurple, .systemPink, .systemTeal]
    static func tint(_ person: Int) -> NSColor { tints[person % tints.count] }
}

/// Above the page while "Who wrote what" is on: each person's share of the chapter, and the word under the pointer.
struct AttributionBar: View {
    @Bindable var bridge: EditorBridge
    let session: BookSession
    @State private var history: Attribution?
    @State private var working = false
    @State private var mapTask: Task<Void, Never>?

    private var key: String { (session.selectedChapterID ?? "") + "|" + (session.git.resolve("HEAD") ?? "") }

    var body: some View {
        HStack(spacing: 12) {
            if working { ProgressView().controlSize(.mini) }
            let total = max(bridge.blame.people.reduce(0) { $0 + $1.words }, 1)
            ForEach(Array(bridge.blame.people.enumerated()), id: \.element.id) { i, p in
                HStack(spacing: 5) {
                    Circle().fill(Color(nsColor: Attribution.tint(i))).frame(width: 7, height: 7)
                    Text(p.person).font(.ui(12))
                    Text("\(p.words * 100 / total) %").font(.ui(12)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let hover = bridge.blameHover { Text(hover).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1) }
            Button { bridge.blameOn = false } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .medium)) }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(L("Hide Who Wrote What"))
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Ink.hairline))
        .task(id: key) { await compute() }
        .onChange(of: session.text) { _, _ in remap(after: 400_000_000) }
        .onDisappear { bridge.blame = .init(); bridge.blameHover = nil; bridge.textView?.needsDisplay = true }
    }

    private func compute() async {
        guard let file = session.selectedChapter?.file else { return }
        working = true
        defer { working = false }
        let git = session.git, owner = Collab.shared.link(git)?.owner
        let result = await Task.detached { try? Attribution.compute(git, path: file, owner: owner) }.value
        guard !Task.isCancelled else { return }
        history = result ?? Attribution()
        remap(after: 0)
    }

    private func remap(after delay: UInt64) {
        mapTask?.cancel()
        guard let history else { return }
        let text = session.text, me = Collab.shared.username ?? L("Me")
        mapTask = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard !Task.isCancelled else { return }
            let map = await Task.detached { history.map(onto: text, me: me) }.value
            guard !Task.isCancelled else { return }
            bridge.blame = map
            bridge.textView?.needsDisplay = true
        }
    }
}
