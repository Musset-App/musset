import Foundation

/// A run the chat, the note replies and the critic table can stop: a CLI's process, or Musset's own loop.
protocol AgentRun: AnyObject {
    func terminate()
}

extension Process: AgentRun {}

// MARK: Streaming

/// One message of a conversation with tools, as Chat Completions takes it.
struct LoopMessage: Equatable {
    var role: String
    var content: String?
    var toolCalls: [ToolCall] = []
    var toolCallID: String? = nil

    struct ToolCall: Equatable {
        var id: String
        var name: String
        var arguments: String
    }

    static func system(_ s: String) -> LoopMessage { LoopMessage(role: "system", content: s) }
    static func user(_ s: String) -> LoopMessage { LoopMessage(role: "user", content: s) }
    static func assistant(_ s: String) -> LoopMessage { LoopMessage(role: "assistant", content: s) }

    var wire: [String: Any] {
        var m: [String: Any] = ["role": role]
        // An assistant message that only calls tools has no content: null, as the API documents.
        m["content"] = content ?? NSNull()
        if !toolCalls.isEmpty {
            m["tool_calls"] = toolCalls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
        }
        if let toolCallID { m["tool_call_id"] = toolCallID }
        return m
    }
}

extension EndpointClient {
    /// What one streamed answer came to: its text, the tools it asks for, and what it cost.
    struct Turn {
        var text = ""
        var toolCalls: [LoopMessage.ToolCall] = []
        var promptTokens: Int?
        var completionTokens: Int?
        var cost: Double?
    }

    /// One streamed answer (server-sent events). Text arrives through `onText` as it comes; tool calls are put together
    /// from their pieces. `toolChoice` "none" asks for an answer without more tools.
    static func stream(_ messages: [LoopMessage], tools: [[String: Any]], toolChoice: String? = nil, model: String,
                       config: EndpointConfig, key: String?, onText: (String) -> Void) async throws -> Turn {
        guard let base = config.url else { throw failure(L("Set up your own model in Settings › AI first.")) }
        let model = model.isEmpty ? config.defaultModel : model
        guard !model.isEmpty else { throw failure(L("Choose a model for \(config.label) in Settings › AI.")) }
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        authorize(&req, config: config, key: key)
        var body: [String: Any] = ["model": model, "stream": true, "messages": messages.map(\.wire),
                                   "stream_options": ["include_usage": true]]
        if !tools.isEmpty { body["tools"] = tools }
        if let toolChoice, !tools.isEmpty { body["tool_choice"] = toolChoice }
        if config.preset == .openrouter { body["usage"] = ["include": true] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await openStream(req)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            var data = Data()
            for try await b in bytes { data.append(b); if data.count > 8_000 { break } }
            try check(response, data)
        }
        var turn = Turn()
        var calls: [Int: LoopMessage.ToolCall] = [:]
        var finish: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            // Comments (OpenRouter sends « : OPENROUTER PROCESSING ») and empty lines carry nothing.
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
            if let message = errorMessage(obj) { throw failure(message) }
            if let usage = obj["usage"] as? [String: Any] {
                turn.promptTokens = usage["prompt_tokens"] as? Int
                turn.completionTokens = usage["completion_tokens"] as? Int
                turn.cost = (usage["cost"] as? NSNumber)?.doubleValue
            }
            guard let choice = (obj["choices"] as? [[String: Any]])?.first else { continue }
            if let f = choice["finish_reason"] as? String { finish = f }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let t = delta["content"] as? String, !t.isEmpty { turn.text += t; onText(t) }
            for piece in delta["tool_calls"] as? [[String: Any]] ?? [] {
                let i = piece["index"] as? Int ?? calls.count
                var call = calls[i] ?? LoopMessage.ToolCall(id: "", name: "", arguments: "")
                if let id = piece["id"] as? String, !id.isEmpty { call.id = id }
                if let f = piece["function"] as? [String: Any] {
                    if let n = f["name"] as? String { call.name += n }
                    if let a = f["arguments"] as? String { call.arguments += a }
                }
                calls[i] = call
            }
        }
        turn.toolCalls = calls.sorted { $0.key < $1.key }.map { k, c in
            var c = c
            if c.id.isEmpty { c.id = "call_\(k)" }
            return c
        }.filter { !$0.name.isEmpty }
        if turn.text.isEmpty, turn.toolCalls.isEmpty, finish == "length" {
            throw failure(L("The model stopped before answering: the text is probably longer than it can read at once."))
        }
        return turn
    }

    private static func openStream(_ req: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        do { return try await session.bytes(for: req) }
        catch let e as URLError { throw described(e, req) }
    }
}

// MARK: The book, as tools

/// What the model may read of the book: chapters, their versions, a search, the Bible's sheets. Read-only, and about
/// the book rather than files: no path ever comes from the model, so nothing outside the book can be read.
struct BookTools {
    let root: URL
    /// Longest text one call returns, in characters: a whole chapter, not a whole book.
    static let limit = 120_000

    private var store: BookStore { BookStore(root: root) }
    private var manifest: BookManifest? { try? store.loadManifest() }

    static let definitions: [[String: Any]] = [
        function("list_chapters", "The book's chapters in order: number, title, file, status, words, versions.", [:]),
        function("read_chapter", "The text of one chapter. Name it by its number, title or file. Paragraphs are numbered «¶N».",
                 ["chapter": ["type": "string", "description": "Number, title or file of the chapter"],
                  "version": ["type": "string", "description": "A version's name, if not the current one"]], required: ["chapter"]),
        function("search_book", "Finds a word or phrase in every chapter (case and accents ignored). Returns the passages, with their chapter.",
                 ["query": ["type": "string", "description": "The word or phrase"]], required: ["query"]),
        function("list_bible", "The book's Bible: its sheets on characters, places, the chronology… with their names.", [:]),
        function("read_bible", "One sheet of the Bible, by its title, one of its names, or its path.",
                 ["entry": ["type": "string", "description": "Title, name or path of the sheet"]], required: ["entry"]),
    ]

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    /// Said to the model once, in the system message: prompts written for Claude and Codex mention their Read tool and files.
    static let guide = """
    You can read the book with tools: list_chapters, read_chapter, search_book, list_bible, read_bible. \
    Where these instructions mention a Read, Grep or Glob tool, or the book's files, use these tools instead: \
    read_chapter takes a chapter's file name (such as `03_nice.md`), its title or its number. \
    Read what a question needs, not the whole book unless asked. You cannot write or change anything.
    """

    /// The line the panel shows while the tool runs.
    func status(_ call: LoopMessage.ToolCall) -> String {
        let a = Self.arguments(call.arguments)
        switch call.name {
        case "read_chapter":
            let title = a["chapter"].flatMap { chapter($0) }?.title ?? a["chapter"] ?? ""
            return L("Reading \(inQuotes(title))")
        case "search_book": return Agents.searching(a["query"] ?? "")
        case "list_chapters": return L("Looking at the chapters")
        case "list_bible": return L("Looking at the Bible")
        case "read_bible": return L("Reading the sheet \(inQuotes(a["entry"] ?? ""))")
        default: return call.name
        }
    }

    /// What a tool answers, as text for the model. A mistake is said in a sentence it can act on, never thrown.
    func run(_ call: LoopMessage.ToolCall) -> String {
        let a = Self.arguments(call.arguments)
        switch call.name {
        case "list_chapters": return listChapters()
        case "read_chapter": return readChapter(a["chapter"] ?? "", version: a["version"])
        case "search_book": return search(a["query"] ?? "")
        case "list_bible": return listBible()
        case "read_bible": return readBible(a["entry"] ?? "")
        default: return "No tool named \(call.name). The tools are: list_chapters, read_chapter, search_book, list_bible, read_bible."
        }
    }

    static func arguments(_ json: String) -> [String: String] {
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] else { return [:] }
        return obj.compactMapValues { v in
            if let s = v as? String { return s }
            if let n = v as? NSNumber { return n.stringValue }
            return nil
        }
    }

    // MARK: Chapters

    func chapter(_ name: String) -> ChapterEntry? {
        guard let chapters = manifest?.chapters else { return nil }
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"«»")))
        if let n = Int(q), (1...chapters.count).contains(n) { return chapters[n - 1] }
        let file = (q as NSString).lastPathComponent
        let plain = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        return chapters.first { $0.file == q || ($0.file as NSString).lastPathComponent == file || $0.id == q || $0.id == (file as NSString).deletingPathExtension }
            ?? chapters.first { plain($0.title) == plain(q) }
            ?? chapters.first { plain($0.title).contains(plain(q)) && q.count >= 3 }
    }

    private func listChapters() -> String {
        guard let m = manifest, !m.chapters.isEmpty else { return "The book has no chapters yet." }
        let lines = m.chapters.enumerated().map { i, c -> String in
            let words = BookStore.wordCount(store.read(c))
            let versions = store.versions(of: c)
            var line = "\(i + 1). \(c.title) — file `\(c.file)` — \((c.status ?? .draft).rawValue) — \(words) words"
            if versions.count > 1 { line += " — versions: \(versions.joined(separator: ", ")) (current: \(c.activeVersion))" }
            return line
        }
        return "« \(m.title) », \(m.chapters.count) chapters:\n" + lines.joined(separator: "\n")
    }

    private func readChapter(_ name: String, version: String?) -> String {
        guard let c = chapter(name) else { return "No chapter « \(name) ». Call list_chapters for their names." }
        let versions = store.versions(of: c)
        let v = version.flatMap { v in versions.first { $0.caseInsensitiveCompare(v.trimmingCharacters(in: .whitespaces)) == .orderedSame } } ?? c.activeVersion
        if let version, !version.isEmpty, v == c.activeVersion, version.caseInsensitiveCompare(c.activeVersion) != .orderedSame {
            return "Chapter « \(c.title) » has no version « \(version) ». Its versions: \(versions.joined(separator: ", "))."
        }
        let text = ParagraphCodec.encode(store.readVersion(c, v))
        let head = "Chapter « \(c.title) » (file `\(c.file)`, version « \(v) »):\n"
        guard text.count > Self.limit else { return head + text }
        return head + String(text.prefix(Self.limit)) + "\n[… cut here: the chapter is longer than one reading.]"
    }

    private func search(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2, let chapters = manifest?.chapters else { return "Give a word or phrase of at least two letters." }
        var hits: [String] = []
        var total = 0
        for c in chapters {
            for paragraph in store.read(c).components(separatedBy: "\n") where !paragraph.isEmpty {
                guard let r = paragraph.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
                total += 1
                guard hits.count < 30 else { continue }
                hits.append("— « \(c.title) »: " + Self.around(paragraph, r))
            }
        }
        if hits.isEmpty { return "« \(q) » appears nowhere in the book." }
        return "« \(q) » in \(total) paragraph\(total == 1 ? "" : "s")" + (total > hits.count ? " (the first \(hits.count))" : "") + ":\n" + hits.joined(separator: "\n")
    }

    /// The passage around a match, at most about 300 characters.
    static func around(_ text: String, _ r: Range<String.Index>) -> String {
        let start = text.index(r.lowerBound, offsetBy: -140, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(r.upperBound, offsetBy: 140, limitedBy: text.endIndex) ?? text.endIndex
        return (start > text.startIndex ? "…" : "") + text[start..<end].trimmingCharacters(in: .whitespaces) + (end < text.endIndex ? "…" : "")
    }

    // MARK: Bible

    /// The sheets the model may read: Markdown, outside `bible/documents/` (the author's sources, often private).
    private var sheets: [BibleEntry] {
        BibleStore(root: root).scan().entries.filter { !$0.isFile && !$0.path.hasPrefix(BibleStore.documents + "/") }
    }

    private func listBible() -> String {
        let all = sheets
        guard !all.isEmpty else { return "The book has no Bible sheets." }
        return all.map { e in
            "— \(e.title) (\(e.kind.rawValue), `\(e.path)`)" + (e.aliases.isEmpty ? "" : ", also: \(e.aliases.joined(separator: ", "))")
        }.joined(separator: "\n")
    }

    private func readBible(_ name: String) -> String {
        let q = name.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "`\"«»")))
        let plain = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        let all = sheets
        guard let e = all.first(where: { $0.path == q || $0.path == q + ".md" })
                ?? all.first(where: { $0.names.contains { plain($0) == plain(q) } }) else {
            return "No sheet « \(name) ». Call list_bible for their names."
        }
        let text = (try? String(contentsOf: BibleStore(root: root).url(e.path), encoding: .utf8)) ?? ""
        return "Sheet « \(e.title) » (`\(e.path)`):\n" + String(text.prefix(Self.limit))
    }
}

// MARK: The loop

/// Musset's own harness for your own model: sends the conversation, runs the book tools the model asks for, sends their
/// results back, at most `rounds` times, and reports what happens as the CLIs do (`AgentEvent`).
final class ReaderLoop: AgentRun, @unchecked Sendable {
    static let rounds = 8
    private var task: Task<Void, Never>?

    /// Starts one turn of the conversation `session` (a new one when nil). Ends with `onDone(0, "")`, or a code and a sentence;
    /// a stopped run ends with 15, like a terminated process.
    static func start(prompt: String, session: String?, systemPrompt: String?, model: String, root: URL, tools: Bool,
                      onEvent: @escaping @Sendable (AgentEvent) -> Void,
                      onDone: @escaping @Sendable (Int32, String) -> Void) -> ReaderLoop {
        let loop = ReaderLoop()
        loop.task = Task {
            do {
                _ = try await turn(prompt: prompt, session: session, systemPrompt: systemPrompt, model: model, root: root, tools: tools, onEvent: onEvent)
                onDone(0, "")
            } catch is CancellationError {
                onDone(15, "")
            } catch let e as URLError where e.code == .cancelled {
                onDone(15, "")
            } catch {
                if Task.isCancelled { onDone(15, ""); return }
                onDone(1, error.localizedDescription)
            }
        }
        return loop
    }

    func terminate() { task?.cancel() }

    /// One turn, start to finish: the reply's text. Kept in `EndpointSessions` under the id it announces (`.session`).
    @discardableResult
    static func turn(prompt: String, session: String?, systemPrompt: String?, model: String, root: URL, tools: Bool,
                     onEvent: @escaping @Sendable (AgentEvent) -> Void = { _ in }) async throws -> String {
        let (config, model) = EndpointClient.resolve(model)
        let key = EndpointClient.key(config)
        let id = session ?? UUID().uuidString
        onEvent(.session(id))
        let book = BookTools(root: root)
        var past = await EndpointSessions.shared.loop(id)
        if past.isEmpty {
            let system = [tools ? BookTools.guide : nil, systemPrompt].compactMap { $0 }.joined(separator: "\n\n")
            if !system.isEmpty { past = [.system(system)] }
        }
        var messages = past + [.user(prompt)]
        let definitions = tools ? BookTools.definitions : []
        for round in 1...rounds {
            let last = round == rounds
            let answer: EndpointClient.Turn
            do {
                answer = try await EndpointClient.stream(messages, tools: definitions, toolChoice: last ? "none" : nil, model: model,
                                                        config: config, key: key) { onEvent(.textDelta($0)) }
            } catch {
                throw explained(error, tools: tools)
            }
            try Task.checkCancellation()
            if answer.toolCalls.isEmpty || last {
                // What's kept for the next turn: the question and the answer, not the chapters read on the way.
                await EndpointSessions.shared.setLoop(id, past + [.user(prompt), .assistant(answer.text)])
                onEvent(.fullText(answer.text))
                return answer.text
            }
            messages.append(LoopMessage(role: "assistant", content: answer.text.isEmpty ? nil : answer.text, toolCalls: answer.toolCalls))
            if !answer.text.isEmpty { onEvent(.textDelta("\n\n")) }
            for call in answer.toolCalls {
                try Task.checkCancellation()
                onEvent(.status(book.status(call)))
                messages.append(LoopMessage(role: "tool", content: book.run(call), toolCallID: call.id))
            }
        }
        return ""
    }

    /// A model that turns out not to use tools (Ollama and LM Studio don't say beforehand) is said plainly.
    static func explained(_ error: Error, tools: Bool) -> Error {
        let text = error.localizedDescription.lowercased()
        guard tools, text.contains("tool"), text.contains("support") || text.contains("not allowed") || text.contains("unsupported") else { return error }
        return EndpointClient.failure(L("This model can't use tools, which Musset's reader needs. Choose another in Settings › AI."))
    }
}
