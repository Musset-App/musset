import SwiftUI

/// The official Claude and Codex command-line tools, driven by Musset so the author never sees a terminal.
/// Their sign-in is the vendor's own page; the tokens stay with the tool and Musset never sees them.
enum CLIState: Equatable { case absent, signedOut, ready }

enum ManagedCLI {
    static func state(_ kind: AgentKind) async -> CLIState {
        guard let exe = await Task.detached(operation: { Shell.which(kind.rawValue) }).value else { return .absent }
        let args = kind == .claude ? ["auth", "status"] : ["login", "status"]
        let r = try? await Shell.runAsync(exe, args)
        return r.map { signedIn($0, kind: kind) } == true ? .ready : .signedOut
    }

    static func signedIn(_ r: Shell.Result, kind: AgentKind) -> Bool {
        guard r.ok else { return false }
        let out = (r.stdout + r.stderr).lowercased()
        if out.contains("not logged in") || out.contains("\"loggedin\": false") || out.contains("\"loggedin\":false") { return false }
        return true
    }

    /// Where the tool comes from, shown before anything is downloaded.
    static func source(_ kind: AgentKind) -> String {
        kind == .claude ? "claude.ai/install.sh" : L("OpenAI's npm package, @openai/codex")
    }

    static func installCommand(_ kind: AgentKind) -> [String]? {
        switch kind {
        case .claude: return ["/bin/sh", "-c", "curl -fsSL https://claude.ai/install.sh | sh"]
        case .codex:
            guard Shell.which("npm") != nil else { return nil }
            return ["/bin/sh", "-c", "npm install -g @openai/codex"]
        }
    }

    static let codexDocs = URL(string: "https://developers.openai.com/codex/cli")!

    static func loginProcess(_ kind: AgentKind) throws -> Process {
        try Shell.makeProcess(kind.rawValue, kind == .claude ? ["auth", "login"] : ["login"], cwd: nil)
    }
}

/// « Two helpers, if you like »: what they do, shown before anything is asked; nothing here is required.
struct AIHelpersView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var states: [AgentKind: CLIState] = [:]
    @State private var phase: [AgentKind: Phase] = [:]
    @State private var process: Process?
    @State private var asking: AgentKind?
    @State private var problem: String?
    @State private var pangramKey = ""
    @AppStorage("proofWithAI") private var proofWithAI = false

    enum Phase { case installing, signingIn }

    var body: some View {
        HStack(spacing: 0) {
            example.frame(width: 392)
            Divider()
            choices
        }
        .frame(width: 960, height: 640)
        .background(Color(nsColor: .textBackgroundColor))
        .task { await refresh() }
        .alert(L("Download the official tool?"), isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button(L("Download")) { if let k = asking { install(k) } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(asking.map { L("Musset will install it from ") + ManagedCLI.source($0) + L(". It then signs in on the official page.") } ?? "")
        }
    }

    private var example: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Example, on an invented text")).font(.ui(12)).foregroundStyle(.secondary).padding(.bottom, 6)
            (Text(L("She set down her case. "))
             + Text(L("A great sadness came over her.")).foregroundColor(Ink.accent)
             + Text(L(" The river ran under the bridge. "))
             + Text(L("In this silence, every memory took on a new dimension.")).foregroundColor(.orange))
                .font(.uiMono(13)).lineSpacing(6)
            card(L("Second reader"), Ink.accent, L("Precision: “great sadness” names what the case set down had already shown.")).padding(.top, 10)
            card("Pangram", .orange, L("This sentence reads like something a machine would write."))
            Spacer()
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("72").font(.ui(26, .semibold))
                Text("/100").foregroundStyle(.secondary)
                Text(L("against your book’s rubric, criterion by criterion")).font(.ui(12)).foregroundStyle(.secondary).padding(.leading, 8)
            }
        }
        .padding(28)
        .frame(maxHeight: .infinity)
        .background(Ink.side)
    }

    private func card(_ who: String, _ color: Color, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(who).font(.ui(12, .medium)).foregroundStyle(color)
            Text(text)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.hairline))
    }

    private var choices: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("Two helpers, if you like.")).font(.system(size: 26, design: .serif))
            Text(L("Musset works without them. Neither rewrites your text.")).foregroundStyle(.secondary).padding(.top, 6)
            Text(L("A demanding reader")).font(.ui(13, .semibold)).padding(.top, 20)
            Text(L("It reads each chapter in its place in the book, scores it, says what to work on, and annotates the margin.")).foregroundStyle(.secondary).padding(.top, 2)
            VStack(spacing: 0) {
                engine(.claude, L("With a Claude subscription"))
                Divider()
                engine(.codex, L("With a ChatGPT subscription"))
            }
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.hairline))
            .padding(.top, 10)
            Text(L("Your subscription, on the official page. No terminal, no key.")).font(.ui(12)).foregroundStyle(.secondary).padding(.top, 6)
            if let problem { Text(problem).font(.ui(12)).foregroundStyle(.red).lineLimit(3).padding(.top, 4) }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("Also proofread while I write")).font(.ui(13, .medium))
                    Text(L("Sends the current paragraph to the AI. Otherwise your text only leaves when you ask.")).font(.ui(12)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $proofWithAI).toggleStyle(.checkbox).labelsHidden()
            }
            .padding(.top, 10)
            Divider().padding(.top, 14)
            Text(L("An independent check")).font(.ui(13, .semibold)).padding(.top, 14)
            Text(L("Pangram flags passages that sound like a machine, before an editor does.")).foregroundStyle(.secondary).padding(.top, 2)
            HStack(spacing: 8) {
                SecureField(L("Pangram key (kept in Keychain)"), text: $pangramKey).textFieldStyle(.roundedBorder).font(.ui(12))
                Link(L("Get a key"), destination: URL(string: "https://www.pangram.com")!).font(.ui(12))
            }
            .padding(.top, 8)
            Spacer(minLength: 8)
            HStack(spacing: 12) {
                Text(L("With nothing on: offline proofreading, outline, versions and export.")).font(.ui(12)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Not now")) { close() }.buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
                Button(L("Done", ctx: "Terminé")) { close() }.buttonStyle(.ink).keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 32).padding(.top, 28).padding(.bottom, 20)
    }

    private func engine(_ kind: AgentKind, _ what: String) -> some View {
        let state = states[kind] ?? .absent
        let status: String
        switch (phase[kind], state) {
        case (.installing?, _): status = L("Downloading the official tool…")
        case (.signingIn?, _): status = L("Finish signing in in your browser…")
        case (nil, .ready): status = L("Signed in on this Mac") + " · " + what
        case (nil, .signedOut): status = L("Installed, not signed in yet") + " · " + what
        case (nil, .absent): status = L("Not on this Mac yet") + " · " + what
        }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(kind.label).font(.ui(13, .medium))
                Text(status).font(.ui(12)).foregroundStyle(state == .ready && phase[kind] == nil ? Color.green : (phase[kind] != nil ? Ink.accent : .secondary))
            }
            Spacer()
            if phase[kind] != nil {
                Button(L("Cancel")) { cancel(kind) }.buttonStyle(.inkSecondary)
            } else if state != .ready {
                Button(L("Sign in…")) { state == .absent ? (asking = kind) : signIn(kind) }.buttonStyle(.inkSecondary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }

    private func refresh() async {
        for kind in AgentKind.allCases { states[kind] = await ManagedCLI.state(kind) }
        await AIStatus.shared.detect()
    }

    private func install(_ kind: AgentKind) {
        guard let command = ManagedCLI.installCommand(kind) else {
            NSWorkspace.shared.open(ManagedCLI.codexDocs)
            problem = L("Codex installs with Node.js, which is not on this Mac. Its page is open in your browser.")
            return
        }
        problem = nil
        phase[kind] = .installing
        Task {
            let r = try? await Shell.runAsync(command[0], Array(command.dropFirst()))
            phase[kind] = nil
            if r?.ok == true { signIn(kind) } else { problem = r?.stderr ?? L("The download failed.") }
        }
    }

    private func signIn(_ kind: AgentKind) {
        problem = nil
        do {
            let p = try ManagedCLI.loginProcess(kind)
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.standardInput = Pipe()
            p.terminationHandler = { _ in Task { @MainActor in phase[kind] = nil; await refresh() } }
            try p.run()
            process = p
            phase[kind] = .signingIn
        } catch {
            problem = error.localizedDescription
        }
    }

    private func cancel(_ kind: AgentKind) {
        process?.terminate()
        phase[kind] = nil
    }

    private func close() {
        let key = pangramKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { Secrets.set("pangram", key) }
        UserDefaults.standard.set(true, forKey: "helpersSeen")
        dismiss()
    }
}
