import Foundation

/// « Your own model »: any server that speaks OpenAI's Chat Completions (OpenRouter, Ollama, LM Studio, …),
/// with the author's own key and the author's own bill. Musset calls it directly; no CLI, no margin.
/// Several servers at once; each task picks one (docs/specs/own-model-endpoint.md). The reader's loop is in ReaderLoop.swift.
enum EndpointPreset: String, CaseIterable, Identifiable, Codable {
    case openrouter, ollama, lmstudio, custom
    var id: String { rawValue }

    var label: String {
        switch self {
        case .openrouter: "OpenRouter"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        case .custom: L("Other server")
        }
    }

    var defaultURL: String {
        switch self {
        case .openrouter: "https://openrouter.ai/api/v1"
        case .ollama: "http://localhost:11434/v1"
        case .lmstudio: "http://localhost:1234/v1"
        case .custom: ""
        }
    }

    /// Local servers take no key.
    var needsKey: Bool { self == .openrouter || self == .custom }
}

struct EndpointConfig: Equatable, Codable {
    var preset: EndpointPreset = .openrouter
    var baseURL = ""
    /// The model used when a task has none of its own.
    var defaultModel = ""
    /// Background work (proofreading as you write, keeping the Bible up to date) on a paid server: off unless asked.
    var background = false

    /// One server of each kind: OpenRouter, Ollama, LM Studio, and one other.
    var id: String { preset.rawValue }
    var keychainAccount: String { "endpoint." + id }

    private enum Key {
        static let list = "endpoints"
        /// The one server of the first build, kept under these keys and the Keychain account « endpoint ».
        static let preset = "endpoint.preset", url = "endpoint.url", model = "endpoint.model", background = "endpoint.background"
        static let legacyKey = "endpoint.legacyKeyOwner"
    }

    /// Every server the author connected, in the order they were added.
    static func all(_ d: UserDefaults = .standard) -> [EndpointConfig] {
        if let data = d.data(forKey: Key.list), let list = try? JSONDecoder().decode([EndpointConfig].self, from: data) { return list }
        // Once: the single server of the first build becomes the first of the list. Its key moves when first read.
        guard let url = d.string(forKey: Key.url), !url.isEmpty else { return [] }
        let old = EndpointConfig(preset: d.string(forKey: Key.preset).flatMap(EndpointPreset.init(rawValue:)) ?? .openrouter,
                                 baseURL: url, defaultModel: d.string(forKey: Key.model) ?? "", background: d.bool(forKey: Key.background))
        store([old], d)
        d.set(old.id, forKey: Key.legacyKey)
        for k in [Key.preset, Key.url, Key.model, Key.background] { d.removeObject(forKey: k) }
        return [old]
    }

    private static func store(_ list: [EndpointConfig], _ d: UserDefaults) {
        if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: Key.list) }
    }

    static func load(_ id: String, _ d: UserDefaults = .standard) -> EndpointConfig? { all(d).first { $0.id == id } }

    /// The first server connected, or an empty form.
    static func load(_ d: UserDefaults = .standard) -> EndpointConfig { all(d).first ?? EndpointConfig() }

    /// Adds the server, or replaces the one of its kind.
    func save(_ d: UserDefaults = .standard) {
        var clean = self
        clean.baseURL = baseURL.trimmingCharacters(in: .whitespaces)
        clean.defaultModel = defaultModel.trimmingCharacters(in: .whitespaces)
        var list = Self.all(d)
        if let i = list.firstIndex(where: { $0.id == id }) { list[i] = clean } else { list.append(clean) }
        Self.store(list, d)
    }

    static func forget(_ id: String, _ d: UserDefaults = .standard) {
        Self.store(all(d).filter { $0.id != id }, d)
        Secrets.set("endpoint." + id, "")
        if d.string(forKey: Key.legacyKey) == id { d.removeObject(forKey: Key.legacyKey); Secrets.set("endpoint", "") }
    }

    /// Its key in the Keychain. The first build's key is moved under this server's own account the first time.
    func storedKey(_ d: UserDefaults = .standard) -> String? {
        if let k = Secrets.get(keychainAccount), !k.isEmpty { return k }
        guard d.string(forKey: Key.legacyKey) == id, let old = Secrets.get("endpoint"), !old.isEmpty else { return nil }
        Secrets.set(keychainAccount, old)
        Secrets.set("endpoint", "")
        d.removeObject(forKey: Key.legacyKey)
        return old
    }

    /// The base URL without its trailing slash, when it is one.
    var url: URL? {
        var s = baseURL.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        guard let u = URL(string: s), let scheme = u.scheme, ["http", "https"].contains(scheme), u.host() != nil else { return nil }
        return u
    }

    var isConfigured: Bool { url != nil }

    /// The name shown beside Claude and Codex: the preset's, or the server's host.
    var label: String {
        if preset != .custom { return preset.label }
        return url?.host() ?? L("Your model")
    }

    /// The text never leaves this Mac: the server is on it.
    var isLocal: Bool {
        guard let host = url?.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]" || host.hasSuffix(".localhost")
    }

    /// Where the author's text goes, in one line under the form.
    var destination: String {
        if isLocal { return L("Your text stays on this Mac.") }
        guard let host = url?.host() else { return "" }
        return preset == .openrouter ? L("Your text is sent to openrouter.ai, which passes it to the model's provider.")
                                     : L("Your text is sent to \(host).")
    }

    /// May a task that runs on its own, unasked, use this server?
    var allowsBackground: Bool { isLocal || background }
}

struct EndpointModel: Equatable {
    let id: String
    let name: String
    /// Tokens the model reads at once, when the server says.
    let context: Int?
    /// Whether it can call tools, when the server says (OpenRouter does; Ollama and LM Studio don't).
    let tools: Bool?
    /// Dollars per token, in and out, when the server says (OpenRouter). Negative means it varies (its router).
    var promptPrice: Double? = nil
    var completionPrice: Double? = nil
    /// When the model was published, and what the server says of it.
    var created: Date? = nil
    var summary: String = ""

    /// The part of the id before the slash: « mistralai » in « mistralai/mistral-small ».
    var provider: String { id.contains("/") ? String(id.split(separator: "/")[0]) : "" }
    var isFree: Bool { promptPrice == 0 && completionPrice == 0 }
    /// The reader works through tools (chapters, search, Bible): a model the server says can't use them isn't offered.
    /// Unknown (Ollama, LM Studio) is kept, and checked when it's first used.
    var usable: Bool { tools != false }
}

/// One message of a conversation, as Chat Completions takes it.
struct EndpointMessage: Codable, Equatable {
    let role: String
    let content: String
}

enum EndpointClient {
    /// Replaced in tests by a session whose requests a URLProtocol answers.
    nonisolated(unsafe) static var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 900
        return URLSession(configuration: c)
    }()
    /// The servers connected, and each one's key in the Keychain; replaced in tests.
    nonisolated(unsafe) static var providers: () -> [EndpointConfig] = { EndpointConfig.all().filter(\.isConfigured) }
    nonisolated(unsafe) static var key: (EndpointConfig) -> String? = { $0.storedKey() }

    /// A task's model with your own servers is « server|model »: « openrouter|mistralai/mistral-small ». Without the server,
    /// the first one connected; without the model, that server's default.
    static func route(_ provider: String, _ model: String) -> String { provider + "|" + model }

    static func split(_ choice: String) -> (provider: String?, model: String) {
        guard let bar = choice.firstIndex(of: "|") else { return (nil, choice) }
        return (String(choice[..<bar]), String(choice[choice.index(after: bar)...]))
    }

    static func resolve(_ choice: String) -> (config: EndpointConfig, model: String) {
        let (id, model) = split(choice)
        let list = providers()
        let config = id.flatMap { id in list.first { $0.id == id } } ?? list.first ?? EndpointConfig()
        return (config, model.isEmpty ? config.defaultModel : model)
    }

    struct Reply: Equatable {
        let text: String
        let model: String
        let promptTokens: Int?
        let completionTokens: Int?
        let cost: Double?
    }

    /// The models the server offers, as `GET /models` lists them.
    static func models(_ config: EndpointConfig, key: String?) async throws -> [EndpointModel] {
        guard let base = config.url else { throw failure(L("The server address isn't a web address.")) }
        var req = URLRequest(url: base.appendingPathComponent("models"))
        authorize(&req, config: config, key: key)
        let (data, response) = try await send(req)
        try check(response, data)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = obj["data"] as? [[String: Any]] else { throw failure(L("The server answered, but not with a list of models.")) }
        return list.compactMap { m in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            let params = m["supported_parameters"] as? [String]
            let pricing = m["pricing"] as? [String: Any]
            func price(_ k: String) -> Double? { (pricing?[k] as? String).flatMap(Double.init) ?? (pricing?[k] as? Double) }
            return EndpointModel(id: id, name: (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id,
                                 context: (m["context_length"] as? Int) ?? ((m["top_provider"] as? [String: Any])?["context_length"] as? Int),
                                 tools: params.map { $0.contains("tools") },
                                 promptPrice: price("prompt"), completionPrice: price("completion"),
                                 created: (m["created"] as? Double).map { Date(timeIntervalSince1970: $0) },
                                 summary: (m["description"] as? String) ?? "")
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// One answer to a conversation.
    static func complete(_ messages: [EndpointMessage], model: String, config: EndpointConfig, key: String?) async throws -> Reply {
        guard let base = config.url else { throw failure(L("Set up your own model in Settings › AI first.")) }
        let model = model.isEmpty ? config.defaultModel : model
        guard !model.isEmpty else { throw failure(L("Choose a model for \(config.label) in Settings › AI.")) }
        var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&req, config: config, key: key)
        var body: [String: Any] = ["model": model, "stream": false,
                                   "messages": messages.map { ["role": $0.role, "content": $0.content] }]
        // OpenRouter adds the cost of the call to its usage when asked.
        if config.preset == .openrouter { body["usage"] = ["include": true] }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(req)
        try check(response, data)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw failure(L("The server's answer couldn't be read."))
        }
        if let message = errorMessage(obj) { throw failure(message) }
        let choice = (obj["choices"] as? [[String: Any]])?.first
        let text = ((choice?["message"] as? [String: Any])?["content"] as? String) ?? ""
        if text.isEmpty, choice?["finish_reason"] as? String == "length" {
            throw failure(L("The model stopped before answering: the text is probably longer than it can read at once."))
        }
        let usage = obj["usage"] as? [String: Any]
        return Reply(text: text, model: obj["model"] as? String ?? model,
                     promptTokens: usage?["prompt_tokens"] as? Int, completionTokens: usage?["completion_tokens"] as? Int,
                     cost: (usage?["cost"] as? NSNumber)?.doubleValue)
    }

    static func authorize(_ req: inout URLRequest, config: EndpointConfig, key: String?) {
        if let key, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        // OpenRouter's optional attribution headers: the app's name, never the author's.
        if config.preset == .openrouter {
            req.setValue("https://musset.app", forHTTPHeaderField: "HTTP-Referer")
            req.setValue("Musset", forHTTPHeaderField: "X-Title")
        }
    }

    private static func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        do { return try await session.data(for: req) }
        catch let e as URLError { throw described(e, req) }
    }

    /// A network failure, in a sentence. A cancelled request stays what it is: the run was stopped.
    static func described(_ e: URLError, _ req: URLRequest) -> Error {
        let host = req.url?.host() ?? ""
        switch e.code {
        case .cancelled: return e
        case .cannotConnectToHost, .cannotFindHost, .networkConnectionLost:
            if req.url.map(isLocalHost) == true { return failure(L("Nothing answers at \(host). Is the server running?")) }
            return failure(L("Can't reach \(host)."))
        case .notConnectedToInternet: return failure(L("This Mac is offline."))
        case .timedOut: return failure(L("The server took too long to answer."))
        default: return failure(e.localizedDescription)
        }
    }

    private static func isLocalHost(_ url: URL) -> Bool {
        let h = url.host()?.lowercased() ?? ""
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
    }

    /// An HTTP error, in a sentence the author can act on.
    static func check(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else { return }
        let detail = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap(errorMessage)
            ?? String(decoding: data.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = detail.lowercased()
        let sentence: String
        switch http.statusCode {
        case 401, 403: sentence = L("The server refused the key. Check it in Settings › AI.")
        case 402: sentence = L("No credit left on this account.")
        case 404 where lowered.contains("model"): sentence = L("The server doesn't know this model.")
        case 404: sentence = L("Nothing at this address: check the server address (it usually ends in /v1).")
        case 429: sentence = L("Too many requests for now: wait a moment and try again.")
        case 400 where lowered.contains("context") || lowered.contains("too long") || lowered.contains("maximum"):
            sentence = L("The text is longer than this model can read at once.")
        default: sentence = L("The server answered with an error (\(http.statusCode)).")
        }
        throw failure(detail.isEmpty || sentence.contains(detail) ? sentence : sentence + "\n" + String(detail.prefix(240)))
    }

    static func errorMessage(_ obj: [String: Any]) -> String? {
        if let e = obj["error"] as? [String: Any] { return e["message"] as? String ?? L("The server answered with an error.") }
        if let e = obj["error"] as? String { return e }
        return nil
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "Musset.endpoint", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// The conversations Musset keeps itself, since there is no CLI to keep them: in memory, for the app's life.
/// A chapter reading is one such conversation; nothing of it is written to disk or to the book.
actor EndpointSessions {
    static let shared = EndpointSessions()
    private var threads: [String: [LoopMessage]] = [:]
    private var order: [String] = []
    private let limit = 40

    func messages(_ id: String) -> [EndpointMessage] {
        (threads[id] ?? []).map { EndpointMessage(role: $0.role, content: $0.content ?? "") }
    }

    func set(_ id: String, _ messages: [EndpointMessage]) {
        setLoop(id, messages.map { LoopMessage(role: $0.role, content: $0.content) })
    }

    /// A conversation with tools: its system message, questions and answers (the tool exchanges aren't kept).
    func loop(_ id: String) -> [LoopMessage] { threads[id] ?? [] }

    func setLoop(_ id: String, _ messages: [LoopMessage]) {
        threads[id] = messages
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > limit { threads[order.removeFirst()] = nil }
    }
}

extension Agents {
    /// The model a task actually runs on with this engine: for your own model, its default when the task has none.
    static func resolvedModel(_ kind: AgentKind, _ model: String) -> String {
        kind == .endpoint ? EndpointClient.resolve(model).model : model
    }

    static func endpointOneShot(prompt: String, model: String) async throws -> String {
        let (config, model) = EndpointClient.resolve(model)
        return try await EndpointClient.complete([EndpointMessage(role: "user", content: prompt)], model: model,
                                                 config: config, key: EndpointClient.key(config)).text
    }

    static func endpointConverse(prompt: String, session: String?, model: String) async throws -> (text: String, session: String?) {
        let id = session ?? UUID().uuidString
        let past = await EndpointSessions.shared.messages(id)
        let asked = past + [EndpointMessage(role: "user", content: prompt)]
        let (config, model) = EndpointClient.resolve(model)
        let reply = try await EndpointClient.complete(asked, model: model, config: config, key: EndpointClient.key(config))
        await EndpointSessions.shared.set(id, asked + [EndpointMessage(role: "assistant", content: reply.text)])
        return (reply.text, id)
    }
}
