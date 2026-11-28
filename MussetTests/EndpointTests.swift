import XCTest
@testable import Musset

/// « Your own model »: a Chat Completions server answered by a URLProtocol stub, never the network.
/// The messages are read in French, like the rest of the tests (TestLanguage).
final class EndpointTests: XCTestCase {
    private var savedSession: URLSession!
    private var savedKey: ((EndpointConfig) -> String?)!
    private var savedProviders: (() -> [EndpointConfig])!

    override func setUp() {
        savedSession = EndpointClient.session
        savedKey = EndpointClient.key
        savedProviders = EndpointClient.providers
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Stub.self]
        EndpointClient.session = URLSession(configuration: c)
        EndpointClient.key = { _ in "sk-test" }
        EndpointClient.providers = { [Self.openRouter] }
        Stub.requests = []
    }

    override func tearDown() {
        EndpointClient.session = savedSession
        EndpointClient.key = savedKey
        EndpointClient.providers = savedProviders
        Stub.handler = nil
    }

    static let openRouter = EndpointConfig(preset: .openrouter, baseURL: "https://openrouter.ai/api/v1/", defaultModel: "mistralai/mistral-large")
    static let ollama = EndpointConfig(preset: .ollama, baseURL: "http://localhost:11434/v1", defaultModel: "llama3.1")

    private func reply(_ text: String, usage: [String: Any] = ["prompt_tokens": 12, "completion_tokens": 3]) -> (Int, Data) {
        (200, try! JSONSerialization.data(withJSONObject: ["model": "mistralai/mistral-large",
                                                           "choices": [["message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
                                                           "usage": usage]))
    }

    func testOpenRouterModelList() async throws {
        Stub.handler = { _ in (200, Data(#"""
        {"data": [
          {"id": "mistralai/mistral-large", "name": "Mistral Large", "context_length": 128000, "supported_parameters": ["tools", "temperature"],
           "pricing": {"prompt": "0.000002", "completion": "0.000006"}, "created": 1760000000, "description": "Mistral's flagship. Long text."},
          {"id": "acme/tiny", "name": "", "context_length": 8192, "supported_parameters": ["temperature"], "pricing": {"prompt": "0", "completion": "0"}}
        ]}
        """#.utf8)) }
        let models = try await EndpointClient.models(Self.openRouter, key: "sk-test")
        XCTAssertEqual(models.map(\.id), ["acme/tiny", "mistralai/mistral-large"], "sorted by name; an empty name falls back on the id")
        XCTAssertEqual(models.last?.context, 128000)
        XCTAssertEqual(models.last?.tools, true)
        XCTAssertEqual(models.first?.tools, false)
        XCTAssertEqual(models.last?.promptPrice, 0.000002)
        XCTAssertEqual(models.last?.provider, "mistralai")
        XCTAssertEqual(models.last?.created, Date(timeIntervalSince1970: 1760000000))
        XCTAssertEqual(models.last?.summary, "Mistral's flagship. Long text.")
        XCTAssertFalse(models.first!.usable, "OpenRouter says it can't use tools: not offered")
        XCTAssertTrue(models.last!.usable)
        XCTAssertTrue(models.first?.isFree == true)
        XCTAssertFalse(models.last?.isFree == true)
        XCTAssertEqual(ModelBrowser.dollars(0.000002), "$2", "per million tokens")
        XCTAssertEqual(ModelBrowser.dollars(0.000000075), "$0.075")
        XCTAssertEqual(ModelBrowser.dollars(0.0000000075), "$0.0075")
        XCTAssertEqual(ModelBrowser.dollars(0.0000007), "$0.70")
        let req = try XCTUnwrap(Stub.requests.first)
        XCTAssertEqual(req.url?.absoluteString, "https://openrouter.ai/api/v1/models", "the trailing slash of the address is dropped")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
        XCTAssertEqual(req.value(forHTTPHeaderField: "X-Title"), "Musset", "the app's name, never the author's")
    }

    func testOllamaModelListAndNoKey() async throws {
        Stub.handler = { _ in (200, Data(#"{"object": "list", "data": [{"id": "llama3.1", "object": "model", "owned_by": "library"}]}"#.utf8)) }
        let models = try await EndpointClient.models(Self.ollama, key: nil)
        XCTAssertEqual(models, [EndpointModel(id: "llama3.1", name: "llama3.1", context: nil, tools: nil)])
        XCTAssertTrue(models[0].usable, "Ollama doesn't say: kept, and checked when used")
        XCTAssertNil(Stub.requests.first?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(Stub.requests.first?.value(forHTTPHeaderField: "X-Title"), "OpenRouter's headers go to OpenRouter only")
    }

    func testCompletionSendsTheConversationAndReadsUsage() async throws {
        Stub.handler = { _ in self.reply("Le chapitre traîne.", usage: ["prompt_tokens": 1200, "completion_tokens": 40, "cost": 0.0031]) }
        let r = try await EndpointClient.complete([EndpointMessage(role: "user", content: "Lis ceci.")], model: "",
                                                  config: Self.openRouter, key: "sk-test")
        XCTAssertEqual(r.text, "Le chapitre traîne.")
        XCTAssertEqual(r.promptTokens, 1200)
        XCTAssertEqual(r.completionTokens, 40)
        XCTAssertEqual(r.cost, 0.0031)
        let req = try XCTUnwrap(Stub.requests.first)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.path(), "/api/v1/chat/completions")
        let body = try XCTUnwrap(Stub.body(req))
        XCTAssertEqual(body["model"] as? String, "mistralai/mistral-large", "a task without its own model uses the server's")
        XCTAssertEqual(body["stream"] as? Bool, false)
        XCTAssertEqual((body["messages"] as? [[String: String]])?.first?["content"], "Lis ceci.")
        XCTAssertEqual((body["usage"] as? [String: Bool])?["include"], true, "OpenRouter is asked for the cost")
    }

    func testNoModelAnywhereIsSaidPlainly() async {
        var config = Self.openRouter
        config.defaultModel = ""
        do {
            _ = try await EndpointClient.complete([EndpointMessage(role: "user", content: "x")], model: "", config: config, key: nil)
            XCTFail("no model: nothing is sent")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("OpenRouter"), error.localizedDescription)
            XCTAssertTrue(Stub.requests.isEmpty)
        }
    }

    func testServerErrorsBecomeSentences() async {
        let cases: [(Int, String, String)] = [
            (401, #"{"error": {"message": "No auth credentials found"}}"#, "refusé la clé"),
            (402, #"{"error": {"message": "Insufficient credits"}}"#, "Plus de crédit"),
            (404, #"{"error": {"message": "model 'llama9' not found"}}"#, "ne connaît pas ce modèle"),
            (404, "404 page not found", "par /v1"),
            (429, #"{"error": {"message": "Rate limit exceeded"}}"#, "Trop de requêtes"),
            (400, #"{"error": {"message": "This model's maximum context length is 8192 tokens"}}"#, "plus long que ce que ce modèle"),
            (500, #"{"error": {"message": "upstream exploded"}}"#, "(500)"),
        ]
        for (status, body, expected) in cases {
            Stub.handler = { _ in (status, Data(body.utf8)) }
            do {
                _ = try await EndpointClient.complete([EndpointMessage(role: "user", content: "x")], model: "", config: Self.openRouter, key: "k")
                XCTFail("\(status) should fail")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected), "\(status): \(error.localizedDescription)")
            }
        }
    }

    func testAnErrorInsideA200() async {
        Stub.handler = { _ in (200, Data(#"{"error": {"message": "Provider returned error", "code": 502}}"#.utf8)) }
        do {
            _ = try await EndpointClient.complete([EndpointMessage(role: "user", content: "x")], model: "", config: Self.openRouter, key: "k")
            XCTFail("an error object is an error, whatever the status")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Provider returned error")
        }
    }

    func testOneShotAndConverseGoThroughAgents() async throws {
        Stub.handler = { _ in self.reply("Première réponse.") }
        let text = try await Agents.oneShot(.endpoint, prompt: "Corrige.", model: "acme/tiny", cwd: FileManager.default.temporaryDirectory)
        XCTAssertEqual(text, "Première réponse.")
        XCTAssertEqual(Stub.body(Stub.requests[0])?["model"] as? String, "acme/tiny", "a task's own model wins")

        let first = try await Agents.converse(.endpoint, prompt: "Question 1", session: nil, model: "", cwd: FileManager.default.temporaryDirectory)
        let session = try XCTUnwrap(first.session)
        Stub.handler = { _ in self.reply("Deuxième réponse.") }
        let second = try await Agents.converse(.endpoint, prompt: "Question 2", session: session, model: "", cwd: FileManager.default.temporaryDirectory)
        XCTAssertEqual(second.text, "Deuxième réponse.")
        XCTAssertEqual(second.session, session)
        let thread = try XCTUnwrap(Stub.body(Stub.requests[2])?["messages"] as? [[String: String]])
        XCTAssertEqual(thread.map { $0["role"]! }, ["user", "assistant", "user"], "Musset keeps the conversation the CLIs would")
        XCTAssertEqual(thread.map { $0["content"]! }, ["Question 1", "Première réponse.", "Question 2"])
    }

    func testEveryEngineConverses() {
        let status = AIStatus(installed: [.claude, .endpoint], defaults: UserDefaults(suiteName: "musset-endpoint-\(UUID().uuidString)")!)
        XCTAssertEqual(status.conversing, [.claude, .endpoint], "your own model holds the chat through Musset's loop")
        XCTAssertEqual(AIStatus(installed: [.endpoint]).conversingEngine(preferring: nil), .endpoint)
    }

    // MARK: The reader loop

    /// A streamed answer, as server-sent events.
    private func sse(_ chunks: [[String: Any]]) -> (Int, Data) {
        var out = ": OPENROUTER PROCESSING\n\n"
        for c in chunks { out += "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: c), as: UTF8.self) + "\n\n" }
        return (200, Data((out + "data: [DONE]\n\n").utf8))
    }

    private func text(_ t: String) -> [String: Any] { ["choices": [["index": 0, "delta": ["content": t]]]] }

    private func call(_ index: Int, id: String?, name: String?, arguments: String) -> [String: Any] {
        var f: [String: Any] = ["arguments": arguments]
        if let name { f["name"] = name }
        var piece: [String: Any] = ["index": index, "function": f]
        if let id { piece["id"] = id; piece["type"] = "function" }
        return ["choices": [["index": 0, "delta": ["tool_calls": [piece]]]]]
    }

    /// A small book on disk: two chapters, a character sheet, and a private document in bible/documents/.
    private func book() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("musset-loop-\(UUID().uuidString)")
        let store = BookStore(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try store.saveManifest(BookManifest(title: "Le Sel", chapters: [
            ChapterEntry(id: "01_port", file: "01_port.md", title: "Le port"),
            ChapterEntry(id: "02_nice", file: "02_nice.md", title: "Nice"),
        ]))
        try "# Le port\n\nMarthe attend le bateau.\n\nLe vent tourne.".write(to: root.appendingPathComponent("01_port.md"), atomically: true, encoding: .utf8)
        try "# Nice\n\nÀ Nice, Marthe ne dit rien.".write(to: root.appendingPathComponent("02_nice.md"), atomically: true, encoding: .utf8)
        let bible = root.appendingPathComponent("bible/personnages"), docs = root.appendingPathComponent("bible/documents")
        try FileManager.default.createDirectory(at: bible, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        try "---\ntype: character\ntitle: Marthe\naliases: La Marthe\n---\n\nLa sœur aînée.".write(to: bible.appendingPathComponent("marthe.md"), atomically: true, encoding: .utf8)
        try "Lettre privée.".write(to: docs.appendingPathComponent("lettre.md"), atomically: true, encoding: .utf8)
        return root
    }

    func testStreamingPutsTextAndToolCallsTogether() async throws {
        Stub.handler = { _ in self.sse([self.text("Je "), self.call(0, id: "c1", name: "read_", arguments: "{\"chap"),
                                        self.call(0, id: nil, name: "chapter", arguments: "ter\": \"2\"}"), self.text("lis."),
                                        ["choices": [], "usage": ["prompt_tokens": 40, "completion_tokens": 9, "cost": 0.0002]]]) }
        var streamed = ""
        let turn = try await EndpointClient.stream([.user("Lis Nice")], tools: BookTools.definitions, model: "", config: Self.openRouter, key: "sk-test") { streamed += $0 }
        XCTAssertEqual(streamed, "Je lis.")
        XCTAssertEqual(turn.toolCalls, [LoopMessage.ToolCall(id: "c1", name: "read_chapter", arguments: #"{"chapter": "2"}"#)])
        XCTAssertEqual(turn.promptTokens, 40)
        XCTAssertEqual(turn.cost, 0.0002)
        let body = try XCTUnwrap(Stub.body(Stub.requests[0]))
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["model"] as? String, "mistralai/mistral-large", "the server's model when the task has none")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 5)
    }

    func testTheLoopReadsTheBookThenAnswers() async throws {
        let root = try book()
        Stub.handler = { req in
            let messages = Stub.body(req)?["messages"] as? [[String: Any]] ?? []
            if messages.last?["role"] as? String == "tool" { return self.sse([self.text("Marthe se tait à Nice.")]) }
            return self.sse([self.call(0, id: "a", name: "read_chapter", arguments: #"{"chapter":"Nice"}"#),
                             self.call(1, id: "b", name: "search_book", arguments: #"{"query":"marthe"}"#),
                             self.call(2, id: "c", name: "read_bible", arguments: #"{"entry":"la marthe"}"#)])
        }
        let events = Events()
        let text = try await ReaderLoop.turn(prompt: "Que fait Marthe ?", session: nil, systemPrompt: "Sois franc.", model: "", root: root, tools: true,
                                             onEvent: { events.add($0) })
        XCTAssertEqual(text, "Marthe se tait à Nice.")
        XCTAssertEqual(Stub.requests.count, 2)
        let second = try XCTUnwrap(Stub.body(Stub.requests[1])?["messages"] as? [[String: Any]])
        XCTAssertEqual(second.map { $0["role"] as? String }, ["system", "user", "assistant", "tool", "tool", "tool"])
        let system = second[0]["content"] as? String ?? ""
        XCTAssertTrue(system.contains("read_chapter") && system.hasSuffix("Sois franc."), "the tools' guide, then the caller's system prompt")
        XCTAssertNotNil(second[2]["tool_calls"])
        XCTAssertTrue(second[2]["content"] is NSNull, "a message that only calls tools has a null content")
        let results = second[3...].compactMap { $0["content"] as? String }
        XCTAssertTrue(results[0].contains("À Nice, Marthe ne dit rien."), results[0])
        XCTAssertTrue(results[1].contains("2 paragraphs") && results[1].contains("« Le port »"), results[1])
        XCTAssertTrue(results[2].contains("La sœur aînée."), results[2])
        XCTAssertEqual(second[3]["tool_call_id"] as? String, "a")
        let statuses = events.all.compactMap { if case .status(let s) = $0 { s } else { nil } }
        XCTAssertEqual(statuses.count, 3)
        XCTAssertTrue(statuses[0].contains("Nice"), statuses[0])
        guard case .session(let id) = events.all.first else { return XCTFail("the session comes first") }
        let kept = await EndpointSessions.shared.loop(id)
        XCTAssertEqual(kept.map(\.role), ["system", "user", "assistant"], "the chapters read on the way aren't kept")
        XCTAssertEqual(kept.last?.content, "Marthe se tait à Nice.")

        // The next turn continues the conversation, without sending the system message twice.
        Stub.requests = []
        Stub.handler = { _ in self.sse([self.text("Oui.")]) }
        _ = try await ReaderLoop.turn(prompt: "Vraiment ?", session: id, systemPrompt: "Sois franc.", model: "", root: root, tools: true)
        let third = try XCTUnwrap(Stub.body(Stub.requests[0])?["messages"] as? [[String: Any]])
        XCTAssertEqual(third.map { $0["role"] as? String }, ["system", "user", "assistant", "user"])
    }

    func testTheLoopStopsAfterEightRounds() async throws {
        let root = try book()
        Stub.handler = { req in
            if Stub.body(req)?["tool_choice"] as? String == "none" { return self.sse([self.text("Assez lu.")]) }
            return self.sse([self.call(0, id: "x\(Stub.requests.count)", name: "list_chapters", arguments: "{}")])
        }
        let text = try await ReaderLoop.turn(prompt: "Lis tout", session: nil, systemPrompt: nil, model: "", root: root, tools: true)
        XCTAssertEqual(text, "Assez lu.")
        XCTAssertEqual(Stub.requests.count, ReaderLoop.rounds, "the last round asks for an answer without more tools")
    }

    func testToolsNeverLeaveTheBook() throws {
        let tools = BookTools(root: try book())
        func run(_ name: String, _ args: String) -> String { tools.run(LoopMessage.ToolCall(id: "t", name: name, arguments: args)) }
        XCTAssertTrue(run("read_chapter", #"{"chapter":"../../../etc/passwd"}"#).hasPrefix("No chapter"))
        XCTAssertTrue(run("read_chapter", #"{"chapter":"/etc/hosts"}"#).hasPrefix("No chapter"))
        XCTAssertTrue(run("read_chapter", #"{"chapter":"01_port.md"}"#).contains("Marthe attend le bateau."))
        XCTAssertTrue(run("read_chapter", #"{"chapter":1}"#).contains("Le port"), "a number, even sent as a number")
        XCTAssertTrue(run("read_chapter", #"{"chapter":"Nice","version":"brouillon"}"#).contains("no version « brouillon »"))
        XCTAssertTrue(run("read_bible", #"{"entry":"documents/lettre.md"}"#).hasPrefix("No sheet"), "bible/documents stays private")
        XCTAssertFalse(run("list_bible", "{}").contains("lettre"))
        XCTAssertTrue(run("list_chapters", "{}").contains("2. Nice — file `02_nice.md`"))
        XCTAssertTrue(run("search_book", #"{"query":"a nice"}"#).contains("« Nice »"), "accents and case are ignored")
        XCTAssertTrue(run("rm", "{}").hasPrefix("No tool named rm"))
    }

    func testAModelWithoutToolsIsSaidPlainly() async throws {
        let root = try book()
        Stub.handler = { _ in (400, Data(#"{"error": {"message": "registry.ollama.ai/library/gemma:2b does not support tools"}}"#.utf8)) }
        do {
            _ = try await ReaderLoop.turn(prompt: "x", session: nil, systemPrompt: nil, model: "gemma:2b", root: root, tools: true)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("ne sait pas utiliser d’outils"), error.localizedDescription)
        }
    }

    func testSendStreamsAndStops() throws {
        let root = try book()
        Stub.handler = { _ in self.sse([self.text("Bonjour"), self.text(" Marthe.")]) }
        let events = Events()
        let done = expectation(description: "done")
        nonisolated(unsafe) var code: Int32 = -1
        _ = try Agents.send(.endpoint, prompt: "Salut", session: nil, cwd: root, model: "", systemPrompt: nil,
                            onEvent: { events.add($0) }, onDone: { c, _ in code = c; done.fulfill() })
        wait(for: [done], timeout: 5)
        XCTAssertEqual(code, 0)
        XCTAssertEqual(events.all.compactMap { if case .textDelta(let t) = $0 { t } else { nil } }.joined(), "Bonjour Marthe.")

        // Stopped: ends like a terminated process, with 15.
        Stub.handler = { _ in Thread.sleep(forTimeInterval: 2); return self.sse([self.text("trop tard")]) }
        let stopped = expectation(description: "stopped")
        let run = try Agents.send(.endpoint, prompt: "Salut", session: nil, cwd: root, model: "", systemPrompt: nil,
                                  onEvent: { _ in }, onDone: { c, _ in code = c; stopped.fulfill() })
        Thread.sleep(forTimeInterval: 0.2)
        run.terminate()
        wait(for: [stopped], timeout: 5)
        XCTAssertEqual(code, 15)
    }

    func testDetectionAndSettings() {
        XCTAssertEqual(AIStatus.detect({ _ in nil }, endpoints: []), [])
        XCTAssertEqual(AIStatus.detect({ _ in nil }, endpoints: [Self.ollama]), [.endpoint])
        XCTAssertEqual(AIStatus.detect({ $0 == "codex" ? "/usr/local/bin/codex" : nil }, endpoints: [Self.openRouter, Self.ollama]), [.codex, .endpoint])

        let d = UserDefaults(suiteName: "musset-endpoint-\(UUID().uuidString)")!
        var c = Self.openRouter
        c.background = true
        c.save(d)
        Self.ollama.save(d)
        XCTAssertEqual(EndpointConfig.all(d).map(\.id), ["openrouter", "ollama"], "several servers, in the order they were added")
        XCTAssertEqual(EndpointConfig.load("openrouter", d), EndpointConfig(preset: .openrouter, baseURL: "https://openrouter.ai/api/v1/",
                                                                           defaultModel: "mistralai/mistral-large", background: true))
        c.defaultModel = "mistralai/mistral-small"
        c.save(d)
        XCTAssertEqual(EndpointConfig.all(d).count, 2, "saving again replaces the server of its kind")
        XCTAssertEqual(EndpointConfig.load(d).defaultModel, "mistralai/mistral-small")
        EndpointConfig.forget("openrouter", d)
        XCTAssertEqual(EndpointConfig.all(d).map(\.id), ["ollama"])

        // The single server of the first build becomes the first of the list.
        let old = UserDefaults(suiteName: "musset-endpoint-\(UUID().uuidString)")!
        old.set("lmstudio", forKey: "endpoint.preset")
        old.set("http://localhost:1234/v1", forKey: "endpoint.url")
        old.set("qwen3", forKey: "endpoint.model")
        XCTAssertEqual(EndpointConfig.all(old), [EndpointConfig(preset: .lmstudio, baseURL: "http://localhost:1234/v1", defaultModel: "qwen3")])
        XCTAssertNil(old.string(forKey: "endpoint.url"))
        XCTAssertEqual(EndpointConfig.all(old).count, 1)

        XCTAssertFalse(EndpointConfig(baseURL: "openrouter.ai").isConfigured, "an address needs its scheme")
        XCTAssertFalse(EndpointConfig(baseURL: "ftp://x/v1").isConfigured)
        XCTAssertTrue(Self.ollama.isLocal)
        XCTAssertTrue(Self.ollama.allowsBackground, "a local server costs nothing: background work may use it")
        XCTAssertFalse(Self.openRouter.isLocal)
        XCTAssertFalse(Self.openRouter.allowsBackground, "a paid server only when the author says so")
        XCTAssertEqual(EndpointConfig(preset: .custom, baseURL: "https://llm.example.org/v1").label, "llm.example.org")
        XCTAssertEqual(Self.ollama.label, "Ollama")
    }

    /// Issue 4: each chat answer keeps the model that gave it, the server's default resolved, never the codex setting.
    @MainActor
    func testTheChatKnowsWhichModelAnswers() {
        EndpointClient.providers = { [Self.openRouter, Self.ollama] }
        XCTAssertEqual(TaskModels.answering(.endpoint, ""), "openrouter|mistralai/mistral-large", "empty: the first server's default")
        XCTAssertEqual(TaskModels.answering(.endpoint, "ollama|"), "ollama|llama3.1", "a server without a model: its default")
        XCTAssertEqual(TaskModels.answering(.endpoint, "openrouter|deepseek/deepseek-chat"), "openrouter|deepseek/deepseek-chat")
        XCTAssertEqual(TaskModels.answering(.claude, "opus"), "opus")
        XCTAssertEqual(TaskModels.answerLabel(.endpoint, "ollama|llama3.1"), "Ollama · llama3.1")
        XCTAssertEqual(TaskModels.answerLabel(.claude, "opus"), "Claude · Opus")
        XCTAssertEqual(TaskModels.answerLabel(.claude, nil), "Claude", "older messages: the engine alone")
        // Saved with the conversation, and read back by a Musset from before (no model: the engine alone).
        let m = ChatMessage(role: .assistant, agent: .endpoint, text: "Oui.", model: "openrouter|deepseek/deepseek-chat")
        let back = try? JSONDecoder().decode(ChatMessage.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back?.model, "openrouter|deepseek/deepseek-chat")
        let old = try? JSONDecoder().decode(ChatMessage.self, from: Data(#"{"id":"\#(UUID())","role":"assistant","agent":"endpoint","text":"x"}"#.utf8))
        XCTAssertNil(old?.model)
    }

    func testFeedbackAttachesOnlyARecentMussetCrash() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, daysAgo: Double) throws {
            let url = dir.appendingPathComponent(name)
            try name.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-daysAgo * 86400)], ofItemAtPath: url.path)
        }
        XCTAssertNil(Feedback.latestCrash(in: dir))
        try write("Musset-2026-11-01-old.ips", daysAgo: 20)
        try write("Safari-2026-11-26.ips", daysAgo: 0.5)
        XCTAssertNil(Feedback.latestCrash(in: dir), "too old, or another app's")
        try write("Musset-2026-11-25.ips", daysAgo: 2)
        try write("Musset-2026-11-26.ips", daysAgo: 1)
        XCTAssertEqual(Feedback.latestCrash(in: dir)?.text, "Musset-2026-11-26.ips", "the newest")
    }

    func testEachTaskPicksItsServer() {
        EndpointClient.providers = { [Self.openRouter, Self.ollama] }
        XCTAssertEqual(EndpointClient.resolve("ollama|qwen3:8b").config, Self.ollama)
        XCTAssertEqual(EndpointClient.resolve("ollama|qwen3:8b").model, "qwen3:8b", "a model id may hold colons and slashes")
        XCTAssertEqual(EndpointClient.resolve("ollama|").model, "llama3.1", "the server's default")
        XCTAssertEqual(EndpointClient.resolve("").config, Self.openRouter, "no server named: the first one")
        XCTAssertEqual(EndpointClient.resolve("mistralai/mistral-small").model, "mistralai/mistral-small", "a model saved by the first build")
        XCTAssertEqual(EndpointClient.resolve("lmstudio|x").config, Self.openRouter, "a server removed since: the first one")
        XCTAssertEqual(EndpointClient.route("openrouter", "a/b:free"), "openrouter|a/b:free")
        XCTAssertEqual(AgentKind.endpoint.label, "OpenRouter, Ollama")
    }

    func testBackgroundWorkStaysOffAPaidServer() {
        let status = AIStatus.shared
        let saved = (status.installed, status.enabled)
        defer { status.installed = saved.0; status.enabled = saved.1 }
        status.enabled = true
        status.installed = [.endpoint]
        XCTAssertNil(TaskModels.backgroundEngine(.proof, endpoint: Self.openRouter), "nothing else to fall back on: the work waits")
        XCTAssertEqual(TaskModels.backgroundEngine(.proof, endpoint: Self.ollama), .endpoint)
        var allowed = Self.openRouter
        allowed.background = true
        XCTAssertEqual(TaskModels.backgroundEngine(.proof, endpoint: allowed), .endpoint)
    }

    func testNotesAreSignedByTheirModel() throws {
        XCTAssertEqual(Note.Author(.endpoint), .model)
        XCTAssertEqual(Note.Author(.codex), .codex)
        XCTAssertEqual(Note.Author.model.engine, .endpoint)
        XCTAssertTrue(Note.Author.model.isAI)
        let data = try JSONEncoder().encode(Note.Author.model)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #""model""#)
    }

    /// Live: the reader loop on a real server, reading a small book with its tools. Same variables as testLiveServer.
    func testLiveReader() async throws {
        let spec = ProcessInfo.processInfo.environment["MUSSET_LIVE_ENDPOINT"]?.split(separator: " ").map(String.init) ?? []
        try XCTSkipUnless(spec.count == 2)
        EndpointClient.session = savedSession
        let config = EndpointConfig(preset: spec[0].contains("openrouter") ? .openrouter : .custom, baseURL: spec[0], defaultModel: spec[1])
        let key = ProcessInfo.processInfo.environment["MUSSET_LIVE_ENDPOINT_KEY"]
        EndpointClient.providers = { [config] }
        EndpointClient.key = { _ in key }
        let events = Events()
        let text = try await ReaderLoop.turn(prompt: "Dans quel chapitre Marthe se tait-elle, et qui est-elle selon la Bible du livre ? Vérifiez avec vos outils.",
                                             session: nil, systemPrompt: nil, model: "", root: try book(), tools: true, onEvent: { events.add($0) })
        let statuses = events.all.compactMap { if case .status(let s) = $0 { s } else { nil } }
        print("ENDPOINT TOOLS", statuses)
        print("ENDPOINT ANSWER", text)
        XCTAssertFalse(statuses.isEmpty, "the model used the book's tools")
        XCTAssertFalse(text.isEmpty)
    }

    /// Live: a real server. MUSSET_LIVE_ENDPOINT="http://localhost:11434/v1 llama3.1" (key in MUSSET_LIVE_ENDPOINT_KEY).
    func testLiveServer() async throws {
        let spec = ProcessInfo.processInfo.environment["MUSSET_LIVE_ENDPOINT"]?.split(separator: " ").map(String.init) ?? []
        try XCTSkipUnless(spec.count == 2)
        EndpointClient.session = savedSession
        let config = EndpointConfig(preset: .custom, baseURL: spec[0], defaultModel: spec[1])
        let key = ProcessInfo.processInfo.environment["MUSSET_LIVE_ENDPOINT_KEY"]
        let models = try await EndpointClient.models(config, key: key)
        print("ENDPOINT MODELS", models.prefix(10).map(\.id))
        let r = try await EndpointClient.complete([EndpointMessage(role: "user", content: "Reply with the single word: OK")],
                                                  model: "", config: config, key: key)
        print("ENDPOINT REPLY", r)
        XCTAssertFalse(r.text.isEmpty)
    }
}

/// Answers every request with what `handler` says, and keeps the requests.
/// Events gathered from callbacks on any thread.
private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [AgentEvent] = []
    func add(_ e: AgentEvent) { lock.lock(); list.append(e); lock.unlock() }
    var all: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return list }
}

private final class Stub: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var requests: [URLRequest] = []

    /// URLSession moves a request's body into a stream: read it back.
    static func body(_ req: URLRequest) -> [String: Any]? {
        var data = req.httpBody ?? Data()
        if data.isEmpty, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // The body stream can be read once: keep a copy with the body in place.
        var kept = request
        if let stream = request.httpBodyStream {
            var data = Data()
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            kept.httpBodyStream = nil
            kept.httpBody = data
        }
        Self.requests.append(kept)
        let (status, data) = Self.handler?(kept) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
