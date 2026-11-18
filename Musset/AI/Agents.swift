import Foundation

/// Claude and Codex through their own logged-in CLIs (OAuth subscriptions, no API keys).
enum AgentKind: String, CaseIterable, Identifiable, Codable {
    case claude, codex
    var id: String { rawValue }
    var label: String { self == .claude ? "Claude" : "Codex" }
}

enum AgentEvent: Sendable {
    case session(String)
    case textDelta(String)
    case fullText(String)
    case status(String)
    case error(String)
}

enum Agents {
    /// Starts one chat turn. `session` is the id from a previous turn, to continue the conversation.
    /// Starts the claude CLI without the user's MCP servers, slash commands and user-level settings:
    /// Musset needs none of them, and loading them doubled the time before the first word (5.5 s → 2.5 s).
    static let claudeLight = ["--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
                              "--disable-slash-commands", "--setting-sources", "project,local"]

    static func send(_ kind: AgentKind, prompt: String, session: String?, cwd: URL, model: String,
                     systemPrompt: String?,
                     onEvent: @escaping @Sendable (AgentEvent) -> Void,
                     onDone: @escaping @Sendable (Int32, String) -> Void) throws -> Process {
        switch kind {
        case .claude:
            var args = ["-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
                        // Read-only: the agent can look at the book, and search the web, but never edit anything.
                        "--tools", "Read,Grep,Glob,WebSearch,WebFetch", "--allowedTools", "WebSearch,WebFetch"] + claudeLight
            if !model.isEmpty { args += ["--model", model] }
            if let session { args += ["--resume", session] }
            if let systemPrompt, session == nil { args += ["--append-system-prompt", systemPrompt] }
            return try Shell.stream("claude", args, cwd: cwd, stdin: prompt, onLine: { line in
                for e in parseClaude(line) { onEvent(e) }
            }, onExit: onDone)
        case .codex:
            var args: [String]
            // `--search`: Codex's own web search, which the read-only sandbox (no network for commands) leaves open.
            if let session {
                args = ["--search", "exec", "resume", session, "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"read-only\""]
            } else {
                args = ["--search", "exec", "--json", "--skip-git-repo-check", "-s", "read-only", "-C", cwd.path]
            }
            if !model.isEmpty { args += ["-m", model] }
            args.append("-")
            return try Shell.stream("codex", args, cwd: cwd, stdin: prompt, onLine: { line in
                for e in parseCodex(line) { onEvent(e) }
            }, onExit: onDone)
        }
    }

    static func parseClaude(_ line: String) -> [AgentEvent] {
        guard let obj = json(line), let type = obj["type"] as? String else { return [] }
        var out: [AgentEvent] = []
        if let sid = obj["session_id"] as? String, type == "system" { out.append(.session(sid)) }
        switch type {
        case "stream_event":
            if let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
               let delta = ev["delta"] as? [String: Any], let text = delta["text"] as? String {
                out.append(.textDelta(text))
            }
        case "assistant":
            if let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                for c in content where c["type"] as? String == "tool_use" {
                    let name = c["name"] as? String ?? "tool"
                    let input = c["input"] as? [String: Any]
                    if name == "WebSearch", let q = input?["query"] as? String { out.append(.status(searching(q))); continue }
                    if name == "WebFetch", let u = (input?["url"] as? String).flatMap(URL.init(string:)) {
                        out.append(.status(L("Reading \(u.host() ?? u.absoluteString)"))); continue
                    }
                    let target = (input?["file_path"] ?? input?["pattern"]) as? String ?? ""
                    out.append(.status("\(name) \((target as NSString).lastPathComponent)"))
                }
            }
        case "result":
            if obj["is_error"] as? Bool == true { out.append(.error(obj["result"] as? String ?? L("Claude error"))) }
            else if let r = obj["result"] as? String { out.append(.fullText(r)) }
        default: break
        }
        return out
    }

    static func parseCodex(_ line: String) -> [AgentEvent] {
        guard let obj = json(line), let type = obj["type"] as? String else { return [] }
        switch type {
        case "thread.started":
            return (obj["thread_id"] as? String).map { [.session($0)] } ?? []
        case "item.completed", "item.started":
            guard let item = obj["item"] as? [String: Any], let itype = item["type"] as? String else { return [] }
            if itype == "agent_message", type == "item.completed", let text = item["text"] as? String { return [.fullText(text)] }
            if itype == "command_execution", let cmd = item["command"] as? String { return [.status(String(cmd.prefix(80)))] }
            if itype == "reasoning" { return [.status(L("thinking…"))] }
            if itype == "web_search" {
                let q = (item["query"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return [.status(q.map(searching) ?? L("Searching the web…"))]
            }
            return []
        case "error", "turn.failed":
            let msg = (obj["message"] as? String) ?? ((obj["error"] as? [String: Any])?["message"] as? String) ?? L("Codex error")
            return [.error(msg)]
        default: return []
        }
    }

    static func searching(_ query: String) -> String { L("Searching: \(inQuotes(query.prefix(70)))") }

    static func json(_ line: String) -> [String: Any]? {
        guard let data = line.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// One-shot, non-streaming call (used by the proofreader). Returns the final text.
    /// `tools` lets Claude read the book in `cwd` ("Read,Grep,Glob"); never anything that writes.
    static func oneShot(_ kind: AgentKind, prompt: String, model: String, cwd: URL, tools: String = "") async throws -> String {
        let result: Shell.Result
        switch kind {
        case .claude:
            var args = ["-p", "--output-format", "json", "--tools", tools] + claudeLight
            if !model.isEmpty { args += ["--model", model] }
            result = try await Shell.runAsync("claude", args, cwd: cwd, stdin: prompt)
            guard let obj = json(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw err(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            if obj["is_error"] as? Bool == true { throw err(obj["result"] as? String ?? L("Claude error")) }
            return obj["result"] as? String ?? ""
        case .codex:
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("musset-codex-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: out) }
            var args = ["exec", "--skip-git-repo-check", "--ephemeral", "-s", "read-only", "-o", out.path]
            if !model.isEmpty { args += ["-m", model] }
            args.append("-")
            result = try await Shell.runAsync("codex", args, cwd: cwd, stdin: prompt)
            guard let text = try? String(contentsOf: out, encoding: .utf8) else { throw err(result.stderr) }
            return text
        }
    }

    /// One turn of a private session: the reply, and the session to resume for the next turn. Nothing is streamed.
    static func converse(_ kind: AgentKind, prompt: String, session: String?, model: String, cwd: URL) async throws -> (text: String, session: String?) {
        switch kind {
        case .claude:
            var args = ["-p", "--output-format", "json", "--tools", ""] + claudeLight
            if !model.isEmpty { args += ["--model", model] }
            if let session { args += ["--resume", session] }
            let result = try await Shell.runAsync("claude", args, cwd: cwd, stdin: prompt)
            guard let obj = json(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw err(result.stderr.isEmpty ? result.stdout : result.stderr)
            }
            if obj["is_error"] as? Bool == true { throw err(obj["result"] as? String ?? L("Claude error")) }
            return (obj["result"] as? String ?? "", obj["session_id"] as? String)
        case .codex:
            var args = session.map { ["exec", "resume", $0, "--json", "--skip-git-repo-check", "-c", "sandbox_mode=\"read-only\""] }
                ?? ["exec", "--json", "--skip-git-repo-check", "-s", "read-only", "-C", cwd.path]
            if !model.isEmpty { args += ["-m", model] }
            args.append("-")
            let result = try await Shell.runAsync("codex", args, cwd: cwd, stdin: prompt)
            var text = "", thread = session
            for line in result.stdout.split(separator: "\n") {
                for event in parseCodex(String(line)) {
                    switch event {
                    case .session(let id): thread = id
                    case .fullText(let t): text = t
                    case .error(let e): throw err(e)
                    default: break
                    }
                }
            }
            guard !text.isEmpty else { throw err(result.stderr) }
            return (text, thread)
        }
    }

    static func err(_ message: String) -> NSError {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var text = trimmed.isEmpty ? L("The CLI returned nothing.") : String(trimmed.suffix(400))
        if text.localizedCaseInsensitiveContains("OAuth") || text.localizedCaseInsensitiveContains("login") || text.localizedCaseInsensitiveContains("authenticate") {
            text += L("\n\nRun `claude` (or `codex login`) in Terminal once to sign in again.")
        }
        return NSError(domain: "Musset.agent", code: 1, userInfo: [NSLocalizedDescriptionKey: text])
    }
}
