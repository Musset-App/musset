import Foundation
import Observation

@MainActor
@Observable
final class TalkStore {
    let root: URL
    private(set) var threads: [TalkThread] = []
    /// My own entries, by chapter: what this Mac writes.
    @ObservationIgnored private var mine: [String: [TalkEntry]] = [:]
    /// Everyone else's entries, as the last fetch brought them.
    @ObservationIgnored private var others: [TalkEntry] = []
    /// What readers' reviews brought into the author's folder: their files as main keeps them.
    @ObservationIgnored private var kept: [TalkEntry] = []
    @ObservationIgnored private var me = ""

    init(root: URL) { self.root = root }


    private func url(_ user: String, _ chapter: String) -> URL { root.appendingPathComponent(Talk.path(user, chapter)) }

    /// Everyone's entries for these chapters: mine from the folder; the others' from the branches the last fetch brought.
    /// An author reads every `relecture/*` branch; a reader reads main (the author's replies).
    func load(me user: String, owner: String, remote: String?, chapters: [String], git: GitService) {
        me = user
        var all: [TalkEntry] = []
        mine = [:]
        for ch in chapters { mine[ch] = Talk.decode(try? Data(contentsOf: url(user, ch))) }
        if let remote {
            let branches = git.remoteBranches(remote)
            var sources: [(rev: String, user: String)] = []
            if user == owner {
                sources = branches.filter { $0.hasPrefix("relecture/") }.map { ("\(remote)/\($0)", String($0.dropFirst("relecture/".count))) }
            } else if branches.contains("main") {
                sources = [("\(remote)/main", owner)]
            }
            for (rev, who) in sources where who != user {
                for ch in chapters { all += Talk.decode(git.data(rev, path: Talk.path(who, ch))).filter { $0.by == who } }
            }
        }
        others = all
        kept = user == owner ? readersFiles(chapters) : []
        rebuild()
    }

    private func rebuild() { threads = Talk.threads(from: others + kept + mine.values.flatMap { $0 }) }

    /// The readers' files in this folder (everyone's but mine), each holding only its reader's entries.
    private func readersFiles(_ chapters: [String]) -> [TalkEntry] {
        let dir = root.appendingPathComponent(".musset/talk")
        let readers = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0 != me && !$0.hasPrefix(".") }.sorted()
        return readers.flatMap { who in chapters.flatMap { ch in Talk.decode(try? Data(contentsOf: url(who, ch))).filter { $0.by == who } } }
    }

    /// What a reader's review brought for a chapter joins the copy of their file in the author's folder: the entries
    /// it does not hold yet, so bringing the same review in again adds nothing. Returns the path if it was written.
    @discardableResult
    func adopt(_ entries: [TalkEntry], chapter: String, from reader: String) -> String? {
        let file = url(reader, chapter)
        var list = Talk.decode(try? Data(contentsOf: file))
        var known = Set(list.map(\.id))
        let new = entries.filter { $0.by == reader && $0.chapter == chapter && known.insert($0.id).inserted }
        guard !new.isEmpty else { return nil }
        list += new
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Talk.encode(list).write(to: file, options: .atomic)
        kept += new
        rebuild()
        return Talk.path(reader, chapter)
    }

    /// Adds one of my entries and writes my file for that chapter. Returns the path written, for the commit.
    @discardableResult
    func add(_ entry: TalkEntry) -> String {
        var list = mine[entry.chapter] ?? []
        list.append(entry)
        mine[entry.chapter] = list
        let file = url(me, entry.chapter)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Talk.encode(list).write(to: file, options: .atomic)
        rebuild()
        return Talk.path(me, entry.chapter)
    }

    func waiting(me: String, owner: String) -> [TalkThread] { threads.filter { $0.waits(for: me, owner: owner) } }
}

extension BookSession {
    /// Re-reads everyone's conversations, after a sync brought the others' branches.
    func refreshTalk() {
        let collab = Collab.shared
        guard let me = collab.username, let l = collab.link(git) else { return }
        talk.load(me: me, owner: l.owner, remote: l.remote, chapters: manifest.chapters.map(\.id), git: git)
    }

    /// Writes one of my entries, commits it, sends it, and tells the other side (in a digest, an hour later).
    func say(_ entry: TalkEntry, notifying: [String]) {
        let path = talk.add(entry)
        try? git.commit(paths: [path], message: "musset: \(entry.kind.rawValue) by \(entry.by)")
        let collab = Collab.shared
        collab.sync(self)
        let kind: Collab.NoticeKind = entry.kind == .note ? .note : .reply
        guard entry.kind == .note || entry.kind == .reply else { return }
        Task { await collab.notify(kind, in: self, recipients: notifying, message: String(entry.body.prefix(300)), thread: entry.thread.uuidString, chapter: entry.chapter) }
    }

    /// A new note on a passage of the open chapter: the start of a conversation.
    func startTalk(on range: NSRange, body: String, mark: TalkEntry.Mark, color: Int, tone: String?) {
        let collab = Collab.shared
        guard let me = collab.username, let l = collab.link(git), let chapter = selectedChapterID else { return }
        let anchor = Anchoring.capture(range, in: text as NSString, version: nil)
        let id = UUID()
        let entry = TalkEntry(id: id, thread: id, kind: .note, by: me, body: body, chapter: chapter, anchor: anchor, mark: mark, color: color, tone: tone)
        say(entry, notifying: me == l.owner ? [] : [l.owner])
    }

    func reply(to thread: TalkThread, _ body: String) {
        guard let me = Collab.shared.username else { return }
        say(TalkEntry(thread: thread.id, kind: .reply, by: me, body: body, chapter: thread.chapter), notifying: Array(thread.people.subtracting([me])))
    }

    func setResolved(_ thread: TalkThread, _ resolved: Bool) {
        guard let me = Collab.shared.username else { return }
        say(TalkEntry(thread: thread.id, kind: resolved ? .resolve : .reopen, by: me, chapter: thread.chapter), notifying: [])
    }
}
