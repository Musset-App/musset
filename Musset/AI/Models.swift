import Foundation
import Observation

/// What the AI is asked to do; each task has its own model, set in Settings › AI.
enum AITask: String, CaseIterable, Identifiable {
    case chat, annotate, proof, plot, words, tenses, bible
    var id: String { rawValue }

    var label: String {
        switch self {
        case .chat: L("AI reader")
        case .annotate: L("Annotations")
        case .proof: L("Proofreading")
        case .plot: L("Grid and scenes")
        case .words: L("Vocabulary")
        case .tenses: L("Tense agreement")
        case .bible: L("The Bible")
        }
    }

    var hint: String {
        switch self {
        case .chat: L("The conversation about the book.")
        case .annotate: L("Margin notes from an AI reading.")
        case .proof: L("Typos and mistakes, paragraph by paragraph.")
        case .plot: L("The book’s index, splitting into scenes.")
        case .words: L("Synonyms, homonyms and alliterations, from the right-click menu.")
        case .tenses: L("Verb tenses brought into agreement, as corrections.")
        case .bible: L("What the book says about each character and place, kept up to date.")
        }
    }
}

/// The model each task uses with each engine, and the engine each task prefers.
/// An empty model means the CLI's own default (codex: the one in ~/.codex/config.toml).
enum TaskModels {
    static func engineKey(_ task: AITask) -> String { "engine.\(task.rawValue)" }
    static func modelKey(_ task: AITask, _ engine: AgentKind) -> String { "model.\(task.rawValue).\(engine.rawValue)" }

    /// The engine chosen last for this task (it runs there when Musset picks the engine itself).
    static func preferredEngine(_ task: AITask, defaults d: UserDefaults = .standard) -> AgentKind? {
        if let raw = d.string(forKey: engineKey(task)) { return AgentKind(rawValue: raw) }
        return task == .proof ? d.string(forKey: "proofEngine").flatMap(AgentKind.init(rawValue:)) : nil
    }

    static func engine(_ task: AITask) -> AgentKind? { AIStatus.shared.engine(preferring: preferredEngine(task)) }

    /// For work that runs on its own, unasked (proofreading as you write, the Bible kept up to date): never a paid server
    /// the author hasn't allowed for it. A CLI then takes its place, or the work waits.
    static func backgroundEngine(_ task: AITask, endpoint: EndpointConfig? = nil) -> AgentKind? {
        guard let e = engine(task) else { return nil }
        if e != .endpoint || (endpoint ?? EndpointClient.resolve(model(task, for: .endpoint)).config).allowsBackground { return e }
        return AIStatus.shared.engines.first { $0 != .endpoint }
    }

    static func model(_ task: AITask, for engine: AgentKind, defaults d: UserDefaults = .standard) -> String {
        if let m = d.string(forKey: modelKey(task, engine)) { return m }
        // Before per-task models: the chat's model per engine, the proofreader's own, Opus for the plot.
        switch (task, engine) {
        case (.chat, .claude), (.annotate, .claude): return d.string(forKey: "claudeModel") ?? "opus"
        case (.chat, .codex), (.annotate, .codex): return d.string(forKey: "codexModel") ?? ""
        case (.proof, .claude): return d.string(forKey: "proofModel") ?? "haiku"
        case (.plot, .claude), (.tenses, .claude): return "opus"
        case (.words, .claude), (.bible, .claude): return "sonnet"
        case (.proof, .codex), (.plot, .codex), (.words, .codex), (.tenses, .codex), (.bible, .codex): return ""
        // Empty: the model chosen for the server as a whole.
        case (_, .endpoint): return ""
        }
    }

    /// Copies the settings from before per-task models into their new keys, once.
    static func migrate(_ d: UserDefaults = .standard) {
        for task in AITask.allCases {
            for engine in AgentKind.allCases where d.string(forKey: modelKey(task, engine)) == nil {
                d.set(model(task, for: engine, defaults: d), forKey: modelKey(task, engine))
            }
        }
    }

    static func set(_ task: AITask, engine: AgentKind, model: String, defaults d: UserDefaults = .standard) {
        d.set(engine.rawValue, forKey: engineKey(task))
        d.set(model, forKey: modelKey(task, engine))
    }
}

struct AIModel: Codable, Hashable, Identifiable {
    let engine: AgentKind
    /// What is passed to the CLI (`--model` / `-m`); empty for the CLI's default.
    let id: String
    let name: String
    let note: String
    var isDefault = false
}

/// The models the CLIs offer: claude's aliases, codex's own list (its app-server's `model/list`).
/// Kept in UserDefaults so Settings opens with the last list, then refreshed in the background.
@MainActor
@Observable
final class ModelCatalog {
    static let shared = ModelCatalog()
    private static let key = "modelCatalog"

    var models: [AIModel] = []
    var updatedAt: Date?
    var refreshing = false

    struct Saved: Codable { var models: [AIModel]; var at: Date }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let s = try? JSONDecoder().decode(Saved.self, from: data) {
            models = s.models; updatedAt = s.at
        } else {
            models = Self.claudeModels()
        }
    }

    func models(_ engine: AgentKind) -> [AIModel] { models.filter { $0.engine == engine } }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        let installed = AIStatus.shared.installed
        let codex = installed.contains(.codex) ? await Task.detached { Self.codexModels() }.value : []
        // A codex that did not answer keeps its last list; so does a server that did not.
        let kept = codex.isEmpty ? models(.codex) : codex
        var endpoint: [AIModel] = []
        for config in EndpointClient.providers() {
            let served = await Self.endpointModels(config)
            endpoint += served.isEmpty ? models(.endpoint).filter { EndpointClient.split($0.id).provider == config.id } : served
        }
        models = (installed.contains(.claude) || installed.isEmpty ? Self.claudeModels() : []) + kept + endpoint
        updatedAt = Date()
        if let data = try? JSONEncoder().encode(Saved(models: models, at: updatedAt!)) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// What one of your servers lists, marked with its default. Ids carry the server: « ollama|llama3.1 ».
    nonisolated static func endpointModels(_ config: EndpointConfig) async -> [AIModel] {
        guard let list = try? await EndpointClient.models(config, key: EndpointClient.key(config)) else { return [] }
        // Models that can't use tools aren't offered, unless one was already chosen.
        return list.filter { $0.usable || $0.id == config.defaultModel }.map { m in
            var note = m.context.map { L("Reads \($0.formatted(.number.notation(.compactName))) tokens at once.") } ?? ""
            if !m.usable { note += (note.isEmpty ? "" : " ") + L("Can't use tools, which the reader will need.") }
            return AIModel(engine: .endpoint, id: EndpointClient.route(config.id, m.id), name: m.name, note: note, isDefault: m.id == config.defaultModel)
        }
    }

    /// The aliases `claude --model` documents: each always means that family's latest model.
    nonisolated static func claudeModels() -> [AIModel] {
        [AIModel(engine: .claude, id: "fable", name: "Fable", note: L("The most capable, for the hardest work. Slower.")),
         AIModel(engine: .claude, id: "opus", name: "Opus", note: L("The finest reader: annotations, scenes.")),
         AIModel(engine: .claude, id: "sonnet", name: "Sonnet", note: L("Balanced, faster.")),
         AIModel(engine: .claude, id: "haiku", name: "Haiku", note: L("Fast and light: proofreading as you write."))]
    }

    /// Asks `codex app-server` for its model list (JSON-RPC over stdio: initialize, then model/list).
    nonisolated static func codexModels(timeout: TimeInterval = 15) -> [AIModel] {
        guard let p = try? Shell.makeProcess("codex", ["app-server"], cwd: nil) else { return [] }
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        defer { if p.isRunning { p.terminate() } }
        func send(_ o: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: o) else { return }
            input.fileHandleForWriting.write(data + Data("\n".utf8))
        }
        send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "musset", "version": "1.0"]]])
        send(["method": "initialized"])
        send(["id": 2, "method": "model/list", "params": [:] as [String: Any]])

        // Read lines until the answer to request 2, giving up after `timeout`.
        let reader = output.fileHandleForReading
        let lock = NSLock()
        var buffer = Data()
        var answer: [String: Any]?
        let done = DispatchSemaphore(value: 0)
        reader.readabilityHandler = { h in
            let chunk = h.availableData
            lock.lock(); defer { lock.unlock() }
            guard answer == nil else { return }
            if chunk.isEmpty { reader.readabilityHandler = nil; done.signal(); return }
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<nl]
                buffer.removeSubrange(buffer.startIndex...nl)
                if let o = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any], o["id"] as? Int == 2 {
                    answer = o; reader.readabilityHandler = nil; done.signal(); return
                }
            }
        }
        _ = done.wait(timeout: .now() + timeout)
        reader.readabilityHandler = nil
        lock.lock(); defer { lock.unlock() }
        guard let data = (answer?["result"] as? [String: Any])?["data"] as? [[String: Any]] else { return [] }
        return data.compactMap { m in
            guard let id = m["id"] as? String, m["hidden"] as? Bool != true else { return nil }
            return AIModel(engine: .codex, id: id, name: m["displayName"] as? String ?? id,
                           note: m["description"] as? String ?? "", isDefault: m["isDefault"] as? Bool ?? false)
        }
    }
}
