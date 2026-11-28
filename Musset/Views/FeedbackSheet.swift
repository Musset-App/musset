import SwiftUI

/// An idea, a problem or a question, sent straight to the people who make Musset (musset-api mails it to them, private).
/// Nothing from the book is sent: the message, an address to answer if given, and the details shown in the sheet.
struct FeedbackSheet: View {
    enum Kind: String, CaseIterable, Identifiable {
        case idea, problem, question
        var id: String { rawValue }
        var label: String {
            switch self {
            case .idea: L("Idea")
            case .problem: L("Problem")
            case .question: L("Question")
            }
        }
        var prompt: String {
            switch self {
            case .idea: L("What would you like Musset to do? What would it help you write?")
            case .problem: L("What did you do, what did you expect, and what happened instead?")
            case .question: L("Ask anything about Musset.")
            }
        }
    }

    var kind: Kind = .idea
    /// Filled in when the sheet opens from an error: the error, for the message.
    var context: String? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Kind = .idea
    @State private var text = ""
    @AppStorage("feedbackEmail") private var email = ""
    @State private var includeDetails = true
    @State private var includeCrash = true
    @State private var crash: Feedback.Crash?
    @State private var sending = false
    @State private var failure: String?
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sent { thanks } else { form }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            chosen = kind
            if let context, text.isEmpty { text = "\n\n—\n" + context }
            if email.isEmpty { email = Collab.shared.account?.email ?? "" }
            crash = Feedback.latestCrash()
        }
    }

    private var form: some View {
        Group {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Send Feedback")).font(.ui(17, .semibold))
                Text(L("It goes straight to the people who make Musset, not to a public page. We read every message."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Picker("", selection: $chosen) {
                ForEach(Kind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text).font(.ui(13)).scrollContentBackground(.hidden).padding(6)
                if text.isEmpty {
                    Text(chosen.prompt).font(.ui(13)).foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                }
            }
            .frame(height: 170)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Radius.control))
            .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
            VStack(alignment: .leading, spacing: 4) {
                TextField(L("Your e-mail, to get an answer (optional)"), text: $email).textFieldStyle(.roundedBorder)
                Toggle(isOn: $includeDetails) {
                    Text(L("Include details about this Mac")).font(.ui(12))
                }
                .toggleStyle(.checkbox)
                if includeDetails {
                    Text(Feedback.diagnostics().map { "\($0.key): \($0.value)" }.sorted().joined(separator: " · "))
                        .font(.ui(11)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                }
                if chosen == .problem, let crash {
                    Toggle(isOn: $includeCrash) {
                        Text(L("Attach Musset’s crash report of \(crash.date.formatted(date: .abbreviated, time: .shortened))")).font(.ui(12))
                    }
                    .toggleStyle(.checkbox)
                }
            }
            if let failure { Text(failure).font(.ui(12)).foregroundStyle(Ink.error) }
            HStack {
                Link(L("Prefer GitHub? Open a public issue"), destination: URL(string: "https://github.com/Musset-App/musset/issues/new/choose")!)
                    .font(.ui(12))
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(sending ? L("Sending…") : L("Send")) { Task { await send() } }
                    .buttonStyle(.ink).keyboardShortcut(.defaultAction)
                    .disabled(sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var thanks: some View {
        Group {
            Text(L("Thank you")).font(.ui(17, .semibold))
            Text(email.isEmpty ? L("Your message has arrived.")
                 : L("Your message has arrived. The answer will come to \(email)."))
                .font(.ui(13)).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button(L("Done", ctx: "Terminé")) { dismiss() }.buttonStyle(.ink).keyboardShortcut(.defaultAction) }
        }
    }

    private func send() async {
        sending = true
        failure = nil
        defer { sending = false }
        do {
            try await Feedback.send(kind: chosen.rawValue, text: text, email: email.trimmingCharacters(in: .whitespaces),
                                    diagnostics: includeDetails ? Feedback.diagnostics() : [:],
                                    crash: chosen == .problem && includeCrash ? crash?.text : nil)
            sent = true
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// At the foot of the sidebar, always in sight: the shortest way to tell us what works and what doesn't.
struct FeedbackButton: View {
    let app: AppState
    var body: some View {
        Button { app.showFeedback = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.text.bubble.right")
                Text(L("Send Feedback"))
                Spacer()
            }
            .font(.ui(12)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).frame(height: 26)
            .background(Ink.panel.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("An idea, a problem or a question: it goes straight to the people who make Musset"))
    }
}

enum Feedback {
    struct Crash { let date: Date; let text: String }

    /// What the sheet shows before sending, and nothing else: no book, no key, no server address.
    @MainActor
    static func diagnostics() -> [String: String] {
        let info = Bundle.main.infoDictionary ?? [:]
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let mac = "Apple silicon"
        #else
        let mac = "Intel"
        #endif
        var d = ["version": info["CFBundleShortVersionString"] as? String ?? "?",
                 "build": info["CFBundleVersion"] as? String ?? "?",
                 "macos": "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
                 "mac": mac,
                 "language": UILang.current.localeID,
                 "keys": KeyboardMode.current.rawValue]
        let engines = AgentKind.clis.filter { AIStatus.shared.installed.contains($0) }.map(\.label) + EndpointClient.providers().map(\.preset.label)
        if !engines.isEmpty { d["engines"] = engines.joined(separator: ", ") }
        if let user = Collab.shared.username { d["account"] = user }
        return d
    }

    /// Musset's latest crash report from the last week, as macOS wrote it (`~/Library/Logs/DiagnosticReports`).
    static func latestCrash(in dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports"),
                            now: Date = Date()) -> Crash? {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let reports = files.filter { $0.lastPathComponent.hasPrefix("Musset") && ["ips", "crash", "hang"].contains($0.pathExtension) }
            .compactMap { url -> (URL, Date)? in
                guard let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                      now.timeIntervalSince(date) < 7 * 86400 else { return nil }
                return (url, date)
            }
        guard let (url, date) = reports.max(by: { $0.1 < $1.1 }),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Crash(date: date, text: String(text.prefix(60_000)))
    }

    static func send(kind: String, text: String, email: String, diagnostics: [String: String], crash: String?) async throws {
        var req = URLRequest(url: Collab.server.appendingPathComponent("musset-api/feedback"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["kind": kind, "text": text, "diagnostics": diagnostics, "lang": UILang.current.localeID]
        if !email.isEmpty { body["email"] = email }
        if let crash { body["crash"] = crash }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            let message = switch error {
            case "bad_email": L("That e-mail address doesn’t look right.")
            case "too_many": L("Too many messages in an hour. Try again a little later.")
            default: L("The message couldn’t be sent. Check your connection and try again.")
            }
            throw NSError(domain: "Musset", code: status, userInfo: [NSLocalizedDescriptionKey: message])
        }
    }
}
