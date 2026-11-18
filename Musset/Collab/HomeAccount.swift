import Foundation

/// The account's places in Home: each is a row of its left column and a page of its main area.
enum HomeSection: String, CaseIterable, Identifiable {
    case books, shared, circle, activity, notices, plan
    var id: String { rawValue }
    var label: String {
        switch self {
        case .books: L("My books")
        case .shared: L("Shared with me")
        case .circle: L("My circle")
        case .activity: L("Activity")
        case .notices: L("Notifications")
        case .plan: L("Plan and billing")
        }
    }
    /// The rows above the column's divider: what the account holds. Below it: how it is set.
    static let holdings: [HomeSection] = [.books, .shared, .circle, .activity]
    static let settings: [HomeSection] = [.notices, .plan]

    /// Where « Musset Account… » lands: the plan when signed in; signed out, the books, beside the sign-in form.
    static func account(signedIn: Bool) -> HomeSection { signedIn ? .plan : .books }

    /// Where a book that is online but not on this Mac waits to be downloaded: `repo` is « owner/name ».
    static func holding(repo: String, username: String?) -> HomeSection {
        guard let username, let owner = repo.split(separator: "/").first else { return .shared }
        return owner == username ? .books : .shared
    }
}

/// What Home shows of the account, read from `Collab` in one go, so tests can draw Home with an account of their own.
struct HomeAccount: Equatable {
    var signedIn = false
    var username: String?
    /// As others see them; the user name when the account has none.
    var name = ""
    /// A writer account (Musset Sync): its books go online.
    var writer = false
    /// Musset Sync offered: nothing to bill.
    var comp = false
    var renews: Date?
    var online: [Collab.Repo] = []
    var circle = 0
    var unread = 0

    var initials: String {
        name.split(whereSeparator: { $0 == " " || $0 == "." }).prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
    }
}

extension Collab {
    var homeAccount: HomeAccount {
        HomeAccount(signedIn: signedIn, username: username, name: account?.name.nilIfEmpty ?? username ?? "", writer: canSync,
                    comp: account?.comp ?? false, renews: account?.renews, online: online, circle: circle.count, unread: unreadActivity)
    }
}

/// A book in Home's grid: on this Mac, on the account, or both.
struct HomeBook: Identifiable {
    enum Online: Equatable {
        /// No account to compare with: the card says nothing about it.
        case unknown
        case localOnly, synced, onlineOnly
        /// Someone else's book, on this Mac.
        case shared(by: String)
    }
    var card: BookCard?
    var repo: Collab.Repo?
    var online: Online
    var id: String { card?.path ?? "online-\(repo?.id ?? 0)" }
    var title: String { card?.manifest.title ?? repo?.title ?? "" }
}

/// A book someone shared with me, for the short list: here already, or to download.
struct SharedBook: Identifiable {
    var title: String
    var owner: String
    /// Its folder, when it is on this Mac.
    var path: String?
    var repo: Collab.Repo?
    var id: String { repo.map { "online-\($0.id)" } ?? path ?? title }
}

extension Collab.Repo {
    /// The book's title is the repository's description; its name is only a slug.
    var title: String { description?.nilIfEmpty ?? name }
}

/// The library and the account, as one list.
struct HomeLibrary {
    /// Every book on this Mac, then mine that are only online.
    var books: [HomeBook] = []
    var shared: [SharedBook] = []

    /// A folder and a repository are one book when the folder has the repository as a remote: what cloning and
    /// sharing both leave behind. Without the account's list (offline), a remote on the server still tells.
    init(cards: [BookCard], account: HomeAccount, server: String) {
        guard account.signedIn else {
            books = cards.map { HomeBook(card: $0, repo: nil, online: .unknown) }
            return
        }
        func same(_ a: String, _ b: String) -> Bool { Self.bare(a) == Self.bare(b) }
        var found = Set<Int>()
        var paths: [Int: String] = [:]
        for card in cards {
            if let repo = account.online.first(where: { r in card.remotes.contains { same($0, r.clone_url) } }) {
                found.insert(repo.id)
                paths[repo.id] = card.path
                let mine = repo.owner.login == account.username
                books.append(HomeBook(card: card, repo: repo, online: mine ? .synced : .shared(by: repo.owner.login)))
            } else if let owner = card.remotes.lazy.compactMap({ Self.owner(of: $0, on: server) }).first {
                books.append(HomeBook(card: card, repo: nil, online: owner == account.username ? .synced : .shared(by: owner)))
                if owner != account.username { shared.append(SharedBook(title: card.manifest.title, owner: owner, path: card.path, repo: nil)) }
            } else {
                books.append(HomeBook(card: card, repo: nil, online: .localOnly))
            }
        }
        let others = account.online.filter { $0.owner.login != account.username }
        shared = others.map { SharedBook(title: $0.title, owner: $0.owner.login, path: paths[$0.id], repo: $0) } + shared
        books += account.online.filter { $0.owner.login == account.username && !found.contains($0.id) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { HomeBook(card: nil, repo: $0, online: .onlineOnly) }
    }

    var onlineOnly: [HomeBook] { books.filter { $0.card == nil } }

    /// The number beside each row of the account's column; none where a number says nothing.
    func count(_ section: HomeSection, account: HomeAccount) -> Int? {
        switch section {
        case .books: books.count
        case .shared: shared.count
        case .circle: account.circle
        case .activity: account.unread
        case .notices, .plan: nil
        }
    }

    private static func bare(_ url: String) -> String {
        var s = url
        if s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    /// The owner of the repository behind a remote, when it is on the account's server.
    private static func owner(of remote: String, on server: String) -> String? {
        let root = server.hasSuffix("/") ? server : server + "/"
        guard remote.hasPrefix(root) else { return nil }
        let parts = bare(String(remote.dropFirst(root.count))).split(separator: "/")
        return parts.count == 2 ? String(parts[0]) : nil
    }
}

extension AppState {
    /// The account lives in Home: what used to open its own sheet shows Home, on one of the account's sections.
    func showAccount(_ section: HomeSection? = nil) {
        homeSection = section ?? .account(signedIn: Collab.shared.signedIn)
        showHome = true
    }
}
