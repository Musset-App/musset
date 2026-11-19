import AppKit
import Foundation
import SwiftUI

/// Raised where a free account tries what only a writer can do: the app answers with the Musset Sync offer.
struct NeedsSubscription: LocalizedError {
    var errorDescription: String? { L("Putting a book online takes a writer account (Musset Sync).") }
}

extension Collab {
    private func apiCall(_ path: String) -> URL { Self.server.appendingPathComponent("musset-api/" + path) }

    /// Writer, or free; nil while unknown (signed out, offline, not asked yet).
    var canSync: Bool { signedIn && (account?.isWriter ?? false) }

    func refreshAccount() async {
        guard signedIn else { account = nil; return }
        if let info: AccountInfo = try? await request("GET", apiCall("account")) {
            let became = info.isWriter && !(account?.isWriter ?? false)
            account = info
            if became { NotificationCenter.default.post(name: Self.becameWriter, object: nil) }
        }
    }

    static let becameWriter = Notification.Name("MussetBecameWriter")

    /// Stripe Checkout, in the browser. The page it ends on sends `musset://sync/done`, which refreshes the account.
    func checkout() async throws {
        struct Out: Decodable { let url: String }
        let out: Out = try await request("POST", apiCall("checkout"))
        if let url = URL(string: out.url) { NSWorkspace.shared.open(url) }
    }

    func manageBilling() async throws {
        struct Out: Decodable { let url: String }
        let out: Out = try await request("POST", apiCall("portal"))
        if let url = URL(string: out.url) { NSWorkspace.shared.open(url) }
    }

    // MARK: Circle

    func refreshCircle() async {
        struct Out: Decodable { let people: [CirclePerson] }
        guard signedIn, let out: Out = try? await request("GET", apiCall("circle")) else { return }
        circle = out.people
    }

    /// By user name or e-mail. An e-mail with no account yet sends an invitation, in the language given.
    func addToCircle(_ who: String, relation: Relation, lang: String) async throws {
        let _: EmptyReply = try await request("POST", apiCall("circle"), body: ["who": who, "relation": relation.rawValue, "lang": lang])
        await refreshCircle()
    }

    func removeFromCircle(_ person: CirclePerson) async throws {
        let _: EmptyReply = try await request("DELETE", apiCall("circle/\(person.id)"))
        await refreshCircle()
    }

    /// Someone new, by e-mail, straight into a book: the server shares it at once if they're on Musset, or invites them.
    /// `milestone` is what they are given to read (a milestone's tag); none for a co-writer, who works in the text itself.
    func invite(email: String, as role: Role, to session: BookSession, relation: Relation, message: String, milestone: String? = nil) async throws {
        guard let l = link(session.git) else { return }
        var body: [String: Any] = [
            "email": email, "repo": "\(l.owner)/\(l.repo)", "role": role.serverName, "relation": relation.rawValue,
            "message": message, "lang": session.manifest.lang, "book": session.title]
        if let milestone { body["tag"] = milestone }
        let _: EmptyReply = try await request("POST", apiCall("invite"), body: body)
        await refreshCircle()
    }

    // MARK: Milestones given to readers

    /// The milestone a reader was given, and when.
    struct Reading: Decodable, Equatable { let tag: String; let at: Int }

    /// Who reads which milestone of this book: everyone for its author, oneself for a reader. Empty when unknown.
    func reading(of git: GitService) async -> [String: Reading] {
        struct Out: Decodable { let reading: [String: Reading] }
        guard let l = link(git) else { return [:] }
        let repo = "\(l.owner)/\(l.repo)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let out: Out? = try? await request("GET", URL(string: apiCall("reading").absoluteString + "?repo=" + repo)!)
        return out?.reading ?? [:]
    }

    /// The author gives a reader a milestone to read (its tag), or takes it back with none.
    func give(_ milestone: String?, to user: String, in session: BookSession) async throws {
        guard let l = link(session.git) else { return }
        var body: [String: Any] = ["repo": "\(l.owner)/\(l.repo)", "username": user]
        if let milestone { body["tag"] = milestone }
        let _: EmptyReply = try await request("POST", apiCall("reading"), body: body)
    }

    /// Someone already on Musset was given the book: both circles, their activity and an e-mail, through the server.
    func announceShare(to user: String, in session: BookSession, as role: Role, milestone: String? = nil) async {
        guard let l = link(session.git) else { return }
        var body: [String: Any] = ["username": user, "repo": "\(l.owner)/\(l.repo)", "role": role.serverName, "lang": session.manifest.lang, "book": session.title]
        if let milestone { body["tag"] = milestone }
        let _: EmptyReply? = try? await request("POST", apiCall("invite"), body: body)
        await refreshCircle()
    }

    /// Accepts an invitation opened from its e-mail by someone who already has an account (`musset://join/<token>`).
    func acceptInvitation(_ token: String) async throws {
        let _: EmptyReply = try await request("POST", apiCall("invitation/\(token)/accept"))
        await refreshCircle()
        await refreshActivity()
    }

    /// Tells the server the role I gave someone, so their apps (Mac or iPhone) know a reader from an editor.
    func recordRole(_ role: Role, of user: String, in session: BookSession) async {
        guard let l = link(session.git) else { return }
        let _: EmptyReply? = try? await request("POST", apiCall("roles"), body: ["repo": "\(l.owner)/\(l.repo)", "username": user, "role": role.serverName])
    }

    /// The role the author gave me in their book, as the server knows it.
    func serverRole(in git: GitService) async -> Role? {
        guard let l = link(git), let me = username else { return nil }
        struct Out: Decodable { let roles: [String: String] }
        let repo = "\(l.owner)/\(l.repo)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let out: Out = try? await request("GET", URL(string: apiCall("roles").absoluteString + "?repo=" + repo)!) else { return nil }
        return out.roles[me].flatMap(Role.init(serverName:))
    }

    // MARK: Notices

    enum NoticeKind: String { case milestone, note, reply }

    /// Tells the people reading a book that something happened. Kept for later when offline, sent with the next sync.
    func notify(_ kind: NoticeKind, in session: BookSession, recipients: [String], tag: String? = nil, message: String? = nil,
                thread: String? = nil, chapter: String? = nil) async {
        guard let l = link(session.git), !recipients.isEmpty else { return }
        var body: [String: Any] = ["repo": "\(l.owner)/\(l.repo)", "kind": kind.rawValue, "recipients": recipients,
                                   "book": session.title, "lang": session.manifest.lang]
        if let tag { body["tag"] = tag }
        if let message, !message.isEmpty { body["message"] = message }
        if let thread { body["thread"] = thread }
        if let chapter { body["chapter"] = chapter }
        do { let _: EmptyReply = try await request("POST", apiCall("notify"), body: body) }
        catch { pendingNotices.append(body) }
    }

    /// What waited while offline goes with the next sync.
    func sendPendingNotices() async {
        let waiting = pendingNotices
        pendingNotices = []
        for body in waiting {
            do { let _: EmptyReply = try await request("POST", apiCall("notify"), body: body) } catch { pendingNotices.append(body) }
        }
    }

    func refreshActivity() async {
        struct Out: Decodable { let items: [ActivityItem] }
        guard signedIn, let out: Out = try? await request("GET", apiCall("activity")) else { return }
        let known = Set(activity.map(\.id))
        let fresh = known.isEmpty ? [] : out.items.filter { $0.isUnread && !known.contains($0.id) }
        activity = out.items
        for item in fresh.prefix(3) { SystemNotice.post(title: item.book, body: item.sentence + (item.message.map { "\n“\($0)”" } ?? "")) }
    }

    func markActivityRead(all: Bool = true, ids: [Int] = []) async {
        let _: EmptyReply? = try? await request("POST", apiCall("activity/read"), body: all ? ["all": true] : ["ids": ids])
        await refreshActivity()
    }

    var unreadActivity: Int { activity.filter(\.isUnread).count }

    func setMailPreference(_ value: String) async {
        let _: EmptyReply? = try? await request("POST", apiCall("prefs"), body: ["mail": value])
        await refreshAccount()
    }
}

extension Collab.Role {
    var serverName: String {
        switch self { case .reader: "reader"; case .editor: "editor"; case .collaborator: "writer" }
    }
    init?(serverName: String) {
        switch serverName { case "reader": self = .reader; case "editor": self = .editor; case "writer": self = .collaborator; default: return nil }
    }
}


import UserNotifications

/// A macOS notification for something new in a shared book, while Musset is open.
enum SystemNotice {
    static func post(title: String, body: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
