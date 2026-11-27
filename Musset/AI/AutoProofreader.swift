import AppKit
import Observation

/// Background proofreading, like a spell checker: paragraphs are checked after a pause in typing,
/// obvious mistakes are corrected once the caret has left the paragraph, the rest is underlined.
/// Results are cached by paragraph text in `.musset/proof/cache.json`, so unchanged text is never re-sent.
@MainActor
@Observable
final class AutoProofreader {
    struct Correction: Identifiable {
        let id = UUID()
        let original: String
        let replacement: String
        let reason: String
        let date = Date()
    }

    struct Paragraph {
        let range: NSRange
        let text: String
        let hash: String
    }

    struct Issue {
        let range: NSRange
        let fix: ProofFix
        let paragraph: Paragraph
    }

    var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "autoProofread"); if enabled { schedule(0.3) } } }
    var autoCorrect: Bool { didSet { UserDefaults.standard.set(autoCorrect, forKey: "autoCorrect") } }
    /// The book language's typographic conventions, applied as soon as the caret leaves a paragraph.
    var typography: Bool { didSet { UserDefaults.standard.set(typography, forKey: "autoTypography"); if typography { applyTypography() } } }
    /// Typographic fixes made since the book was opened.
    var typographyFixed = 0
    var running = 0
    var lastError: String?
    var languageToolError: String?
    var issueCount = 0
    /// Of which LanguageTool's (blue underlines).
    var languageToolCount = 0
    /// Paragraphs of the open chapter LanguageTool has checked, and how many there are.
    var languageToolChecked = 0
    var paragraphCount = 0
    /// Corrections made automatically since the book was opened, newest first.
    var corrections: [Correction] = []

    @ObservationIgnored weak var bridge: EditorBridge?
    @ObservationIgnored private var root: URL?
    @ObservationIgnored private(set) var lang = "fr"
    @ObservationIgnored private var cache: [String: [ProofFix]] = [:] { didSet { revision &+= 1 } }
    /// Goes up whenever what the issues are made from changes (results, verdicts, the author's exceptions): the
    /// issues of a text are found once, then kept until the text or this moves.
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var keptParagraphs: (text: String, lang: String, out: [Paragraph])?
    @ObservationIgnored private var keptIssues: (text: String, revision: Int, context: String, out: [Issue])?
    /// LanguageTool's results by exact paragraph text: cheap to recompute, so kept in memory only,
    /// and keyed without folding typography, which they check.
    @ObservationIgnored private var local: [String: [ProofFix]] = [:] { didSet { revision &+= 1 } }
    /// The AI's answers on LanguageTool's grammar alerts, by `GrammarArbiter.key`.
    @ObservationIgnored private var verdicts: [String: Bool] = [:] { didSet { revision &+= 1 } }
    @ObservationIgnored private var arbiterRunning = false
    @ObservationIgnored private var arbiterPausedUntil = Date.distantPast { didSet { revision &+= 1 } }
    @ObservationIgnored private var bookFacts = ""
    /// Stands in for the AI in tests.
    @ObservationIgnored var arbiterVoice: ((String) async throws -> String)?
    /// Suggestions the author chose to keep as written ("original→replacement"), per book.
    private(set) var ignored: Set<String> = [] { didSet { revision &+= 1 } }
    /// Words the author taught the book: never flagged by the AI, LanguageTool or the spell checker.
    private(set) var dictionary: [String] = [] {
        didSet {
            revision &+= 1
            dictionaryKeys = Set(dictionary.map { $0.lowercased() })
            Typography.bookNames = dictionary.filter { $0.count > 1 && $0.last.map { ";:!?".contains($0) } == true }
        }
    }
    /// Spaces this session put before a punctuation mark, in their context: the same one removed again is the author's choice.
    @ObservationIgnored private var typoSpaced: Set<String> = []
    @ObservationIgnored private var dictionaryKeys: Set<String> = []
    /// LanguageTool rules switched off for this book.
    private(set) var disabledRules: Set<String> = [] { didSet { revision &+= 1 } }
    @ObservationIgnored private var inflight: Set<String> = []
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var pausedUntil = Date.distantPast
    @ObservationIgnored private var lastEdit = Date.distantPast
    /// Set while corrections are being written: each replacement moves the caret, and the selection
    /// callback must not start a second pass with ranges the first pass is about to invalidate.
    @ObservationIgnored private var applying = false
    @ObservationIgnored private var ltRunning = false
    @ObservationIgnored private var ltPausedUntil = Date.distantPast
    /// Each paragraph's cache key, by its text: hashing every paragraph on every restyle cost ~20 ms a chapter.
    @ObservationIgnored private var keys: [String: String] = [:]

    static let idleDelay: TimeInterval = 2.0
    static let maxConcurrent = 4
    /// Small batches: Haiku catches noticeably more errors per request when given less text.
    static let batchWords = 150
    static let arbiterBatch = 8

    init() {
        let d = UserDefaults.standard
        enabled = d.object(forKey: "autoProofread") as? Bool ?? true
        autoCorrect = d.object(forKey: "autoCorrect") as? Bool ?? true
        typography = d.object(forKey: "autoTypography") as? Bool ?? true
        // Settings ▸ Proofreading writes the defaults: a switch flipped there is taken at once.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: d, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readSwitches() }
        }
    }

    /// The three switches as the defaults have them now. The defaults are the one place they are kept: the switches
    /// in Settings write there, those of the Notes panel go through this object, which writes there too.
    func readSwitches() {
        let d = UserDefaults.standard
        let on = d.object(forKey: "autoProofread") as? Bool ?? true
        let correct = d.object(forKey: "autoCorrect") as? Bool ?? true
        let typo = d.object(forKey: "autoTypography") as? Bool ?? true
        if on != enabled { enabled = on }
        if correct != autoCorrect { autoCorrect = correct }
        if typo != typography { typography = typo }
    }

    /// nil when no AI is available (no CLI, or AI off): the AI pass is skipped, the rest still runs.
    private var engine: AgentKind? { UserDefaults.standard.bool(forKey: "proofWithAI") ? TaskModels.backgroundEngine(.proof) : nil }
    private var model: String { engine.map { TaskModels.model(.proof, for: $0) } ?? "" }
    /// Separate from the AI proofreader: this only sends what LanguageTool flagged, with its neighbours.
    private var arbiterEngine: AgentKind? { UserDefaults.standard.bool(forKey: "proofArbiter") ? TaskModels.backgroundEngine(.proof) : nil }
    private var arbiterOn: Bool { arbiterVoice != nil || arbiterEngine != nil }
    private var cacheURL: URL? { root?.appendingPathComponent(".musset/proof/cache.json") }
    /// Tracked in git with the book, unlike the cache.
    private var dictionaryURL: URL? { root?.appendingPathComponent(".musset/dictionary.txt") }
    private var exceptionsURL: URL? { root?.appendingPathComponent(".musset/proof-exceptions.json") }
    struct Exceptions: Codable { var ignored: [String] = []; var disabledRules: [String] = [] }

    // MARK: Lifecycle

    struct Saved: Codable { var cache: [String: [ProofFix]]; var ignored: [String]; var verdicts: [String: Bool]? = nil }

    func attach(_ session: BookSession) {
        attach(root: session.root, lang: session.manifest.lang)
        bookFacts = GrammarArbiter.facts(plot: session.plot)
    }

    func attach(root newRoot: URL, lang: String) {
        if lang != self.lang { keys = [:] }
        self.lang = lang
        guard newRoot != root else { return }
        save()
        root = newRoot
        cache = [:]; local = [:]; verdicts = [:]; keys = [:]; ignored = []; inflight = []; corrections = []; lastError = nil; languageToolError = nil; typographyFixed = 0; typoClean = []
        if let url = cacheURL, let s = JSONFile.read(Saved.self, at: url) {
            cache = s.cache
            ignored = Set(s.ignored)
            verdicts = s.verdicts ?? [:]
        }
        dictionary = []; disabledRules = []
        if let url = dictionaryURL, let text = try? String(contentsOf: url, encoding: .utf8) {
            dictionary = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        }
        if let url = exceptionsURL, let e = JSONFile.read(Exceptions.self, at: url) {
            ignored.formUnion(e.ignored)
            disabledRules = Set(e.disabledRules)
        }
        bridge?.textView?.applyBookDictionary(dictionary)
    }

    func save() {
        guard let url = cacheURL else { return }
        try? JSONFile.write(Saved(cache: cache, ignored: [], verdicts: verdicts), to: url, [])
        saveExceptions()
    }

    private func saveExceptions() {
        guard let dictURL = dictionaryURL, let excURL = exceptionsURL else { return }
        let header = "# Words this book uses on purpose: never flagged by Musset's proofreading. One per line.\n"
        let sortedWords = dictionary.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        if !sortedWords.isEmpty || FileManager.default.fileExists(atPath: dictURL.path) {
            try? (header + sortedWords.joined(separator: "\n") + "\n").write(to: dictURL, atomically: true, encoding: .utf8)
        }
        let e = Exceptions(ignored: ignored.sorted(), disabledRules: disabledRules.sorted())
        if !e.ignored.isEmpty || !e.disabledRules.isEmpty || FileManager.default.fileExists(atPath: excURL.path) {
            try? JSONFile.write(e, to: excURL)
        }
    }

    // MARK: The author's words and overrides

    func isLearned(_ word: String) -> Bool { dictionaryKeys.contains(word.lowercased()) }

    /// Hidden because the author kept it, taught its words, or switched its rule off.
    func isSuppressed(_ fix: ProofFix) -> Bool {
        if ignored.contains(fix.ignoreKey) { return true }
        if let rule = fix.rule, disabledRules.contains(rule) { return true }
        let changed = fix.changedWords
        return !changed.isEmpty && changed.allSatisfy(isLearned)
    }

    func learn(_ word: String) {
        let w = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty, !isLearned(w) else { return }
        dictionary.append(w)
        exceptionsChanged()
    }

    func unlearn(_ word: String) {
        dictionary.removeAll { $0.lowercased() == word.lowercased() }
        exceptionsChanged()
    }

    func disableRule(_ rule: String) { disabledRules.insert(rule); exceptionsChanged() }
    func enableRule(_ rule: String) { disabledRules.remove(rule); exceptionsChanged() }
    func unignore(_ key: String) { ignored.remove(key); exceptionsChanged() }

    private func exceptionsChanged() {
        saveExceptions()
        bridge?.textView?.applyBookDictionary(dictionary)
        bridge?.refreshHighlights()
    }

    private func saveSoon() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func chapterOpened() {
        lastError = nil
        schedule(0.5)
    }

    func textChanged() {
        guard !applying else { return }   // our own corrections are not the author writing
        lastEdit = Date()
        schedule(Self.idleDelay)
    }

    func selectionChanged() {
        applyTypography()
        applyObvious()
    }

    private func schedule(_ delay: TimeInterval) {
        timer?.cancel()
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.runPending()
        }
    }

    // MARK: Paragraphs

    /// Typography is folded out of the key, so fixing spaces or apostrophes never sends a paragraph back to the AI.
    static func hash(_ text: String, lang: String) -> String {
        String(PangramClient.sha(lang + "\u{1f}t2\u{1f}" + Typography.key(text)).prefix(20))
    }

    /// Key used before typography was folded out; cached results are moved over on first sight.
    private static func legacyHash(_ text: String, lang: String) -> String {
        String(PangramClient.sha(lang + "\u{1f}" + text.trimmingCharacters(in: .whitespacesAndNewlines)).prefix(20))
    }

    private func migrate(_ text: String, to key: String) {
        guard cache[key] == nil else { return }
        let old = Self.legacyHash(text, lang: lang)
        if let fixes = cache.removeValue(forKey: old) { cache[key] = fixes }
        if let lt = cache.removeValue(forKey: Self.ltKey(old)) { cache[Self.ltKey(key)] = lt }
    }

    func paragraphs(of text: String) -> [Paragraph] {
        // Asked several times for the same text (the underlines, the counts, the next check).
        if let k = keptParagraphs, k.lang == lang, k.text == text { return k.out }
        let out = splitParagraphs(text)
        keptParagraphs = (text, lang, out)
        return out
    }

    private func splitParagraphs(_ text: String) -> [Paragraph] {
        let ns = text as NSString
        var out: [Paragraph] = []
        var cursor = 0
        while cursor < ns.length {
            let r = ns.paragraphRange(for: NSRange(location: cursor, length: 0))
            cursor = NSMaxRange(r)
            let t = ns.substring(with: r)
            let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
            // Skip blank lines, author's notes, scene breaks.
            if trimmed.count < 3 || trimmed.hasPrefix("<!--") || trimmed.hasSuffix("-->") || trimmed.allSatisfy({ "*-_ ".contains($0) }) { continue }
            let key: String
            if let k = keys[t] { key = k } else {
                key = Self.hash(t, lang: lang)
                migrate(t, to: key)
                if keys.count > 20_000 { keys = [:] }
                keys[t] = key
            }
            out.append(Paragraph(range: r, text: t, hash: key))
        }
        return out
    }

    /// Underlined issues in the current text (cached results that still match).
    func issues(in text: String) -> [Issue] {
        guard enabled else { return [] }
        // Settings read once per pass, not once per paragraph.
        let rules = (off: rulesOff, local: usesLocal)
        // The same text with the same results behind it: the same issues (the editor, the automatic fixes and the
        // Notes list each ask after every change).
        let context = "\(rules.off)|\(rules.local)|\(arbiterOn)|\(Date() < arbiterPausedUntil)|\(lang)"
        let paras = paragraphs(of: text)
        if let k = keptIssues, k.revision == revision, k.context == context, k.text == text { return k.out }
        var out: [Issue] = []
        let ns = text as NSString
        for p in paras {
            var found: [Issue] = []
            // AI fixes first; a LanguageTool match on the same words is dropped.
            for fix in (cache[p.hash] ?? []) + (ruleFixes(p, rules) ?? []) where !isSuppressed(fix) {
                let local = fix.locate(in: p.text as NSString)
                guard local.location != NSNotFound else { continue }
                let r = NSRange(location: p.range.location + local.location, length: local.length)
                guard NSMaxRange(r) <= ns.length, !found.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) else { continue }
                found.append(Issue(range: r, fix: fix, paragraph: p))
            }
            out += found.sorted { $0.range.location < $1.range.location }
        }
        keptIssues = (text, revision, context, out)
        return out
    }

    static func ltKey(_ hash: String) -> String { "lt:" + hash }

    /// The bundled LanguageTool, unless another server was chosen.
    private var usesLocal: Bool { LocalProofreader.checker == .local && LocalProofreader.supports(lang) }
    private var rulesOff: Bool {
        switch LocalProofreader.checker {
        case .off: true
        case .local: !LocalProofreader.supports(lang) && LanguageTool.mode == .off
        case .languageTool: LanguageTool.mode == .off
        }
    }

    /// The blue checker's fixes for a paragraph, or nil if it hasn't been checked yet.
    private func ruleFixes(_ p: Paragraph, _ rules: (off: Bool, local: Bool)? = nil) -> [ProofFix]? {
        let rules = rules ?? (rulesOff, usesLocal)
        if rules.off { return [] }
        guard rules.local else { return cache[Self.ltKey(p.hash)] }
        return local[p.text.trimmingCharacters(in: .newlines)]?.filter { shown($0, in: p) }
    }

    /// An alert that needs the AI's word stays hidden until it comes. With the AI off or failing, it shows as it is.
    private func shown(_ fix: ProofFix, in p: Paragraph) -> Bool {
        guard GrammarArbiter.applies(to: fix), arbiterOn else { return true }
        return verdicts[GrammarArbiter.key(paragraph: p.hash, fix: fix)] ?? (Date() < arbiterPausedUntil)
    }

    /// Called while the text view restyles; deferred so SwiftUI state isn't changed mid-update.
    func updateCount(_ issues: [Issue], text: String) {
        let lt = issues.filter(\.fix.isLanguageTool).count
        let paras = paragraphs(of: text)
        let rules = (off: rulesOff, local: usesLocal)
        let checked = paras.filter { ruleFixes($0, rules) != nil }.count
        guard issueCount != issues.count || languageToolCount != lt || languageToolChecked != checked || paragraphCount != paras.count else { return }
        DispatchQueue.main.async { [weak self] in
            self?.issueCount = issues.count
            self?.languageToolCount = lt
            self?.languageToolChecked = checked
            self?.paragraphCount = paras.count
        }
    }

    // MARK: Checking

    private func runPending() {
        applyTypography()
        runLanguageTool()
        runArbiter()
        guard enabled, engine != nil, let tv = bridge?.textView, let root, Date() >= pausedUntil else { return }
        let pending = paragraphs(of: tv.string).filter { cache[$0.hash] == nil && !inflight.contains($0.hash) }
        guard !pending.isEmpty else { return }
        // Batch paragraphs into requests of ~450 words.
        var batches: [[Paragraph]] = [[]]
        var words = 0
        for p in pending {
            batches[batches.count - 1].append(p)
            words += p.text.split(whereSeparator: \.isWhitespace).count
            if words >= Self.batchWords { batches.append([]); words = 0 }
        }
        for batch in batches.filter({ !$0.isEmpty }) where running < Self.maxConcurrent {
            send(batch, root: root)
        }
    }

    /// One LanguageTool request at a time, so the free API's rate limit is never hit while writing.
    private func runLanguageTool() {
        if usesLocal { runLocal(); return }
        guard enabled, !ltRunning, !rulesOff, Date() >= ltPausedUntil, let tv = bridge?.textView else { return }
        let pending = paragraphs(of: tv.string).filter { cache[Self.ltKey($0.hash)] == nil }
        guard !pending.isEmpty else { return }
        var batch: [Paragraph] = []
        var bytes = 0
        for p in pending {
            let size = p.text.utf8.count + 2
            if !batch.isEmpty && bytes + size > LanguageTool.maxRequestBytes { break }
            batch.append(p); bytes += size
        }
        let texts = batch.map { $0.text.trimmingCharacters(in: .newlines) }
        var starts: [Int] = []
        var offset = 0
        for t in texts { starts.append(offset); offset += (t as NSString).length + 2 }
        let joined = texts.joined(separator: "\n\n")
        let lang = self.lang
        ltRunning = true
        Task { [weak self] in
            guard let server = await LanguageTool.server() else {
                self?.ltDone(.failure(LanguageTool.Failure(message: L("LanguageTool: local server not running"), rateLimited: false)), batch: batch, texts: texts, starts: starts)
                return
            }
            let result: Result<[LanguageTool.Match], Error>
            do { result = .success(try await LanguageTool.check(joined, lang: lang, server: server)) }
            catch { result = .failure(error) }
            self?.ltDone(result, batch: batch, texts: texts, starts: starts)
        }
    }

    private func ltDone(_ result: Result<[LanguageTool.Match], Error>, batch: [Paragraph], texts: [String], starts: [Int]) {
        ltRunning = false
        switch result {
        case .failure(let error):
            languageToolError = error.localizedDescription
            ltPausedUntil = Date().addingTimeInterval(60)
            return
        case .success(let matches):
            languageToolError = nil
            let perParagraph = LanguageTool.fixes(matches, paragraphs: texts, starts: starts, lang: lang)
            for (p, fixes) in zip(batch, perParagraph) { cache[Self.ltKey(p.hash)] = fixes }
        }
        saveSoon()
        bridge?.refreshHighlights()
        // Small pause between requests: the public API allows about 20 a minute.
        ltPausedUntil = Date().addingTimeInterval(3.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in self?.runLanguageTool() }
    }

    /// LanguageTool on this Mac: a few paragraphs at a time, so results appear as they come.
    private func runLocal() {
        guard enabled, !ltRunning, let tv = bridge?.textView else { return }
        var seen: Set<String> = []
        let texts = paragraphs(of: tv.string).map { $0.text.trimmingCharacters(in: .newlines) }
            .filter { local[$0] == nil && seen.insert($0).inserted }
        guard !texts.isEmpty else { return }
        let batch = Array(texts.prefix(20))
        let lang = self.lang, words = dictionary
        ltRunning = true
        Task { [weak self] in
            let result: Result<[[ProofFix]], Error>
            do { result = .success(try await LocalProofreader.check(batch, lang: lang, words: words)) }
            catch { result = .failure(error) }
            self?.localDone(result, texts: batch)
        }
    }

    private func localDone(_ result: Result<[[ProofFix]], Error>, texts: [String]) {
        ltRunning = false
        switch result {
        case .failure(let error):
            languageToolError = error.localizedDescription
            // Nothing will change until the app is relaunched; mark them checked so the loop stops.
            for t in texts { local[t] = [] }
            return
        case .success(let fixes):
            languageToolError = nil
            for (t, f) in zip(texts, fixes) { local[t] = f.map(LocalProofreader.promotingAccents) }
        }
        applyObvious()
        bridge?.refreshHighlights()
        runLocal()
        runArbiter()
    }

    /// Asks the AI about the open chapter's undecided alerts, a few at a time.
    private func runArbiter() {
        guard enabled, usesLocal, arbiterOn, !arbiterRunning, Date() >= arbiterPausedUntil,
              Date().timeIntervalSince(lastEdit) >= Self.idleDelay, let tv = bridge?.textView, let root else { return }
        let paragraphs = paragraphs(of: tv.string)
        let text: (Int) -> String = { paragraphs.indices.contains($0) ? paragraphs[$0].text.trimmingCharacters(in: .newlines) : "" }
        var items: [GrammarArbiter.Item] = []
        var asked: [Int: String] = [:]
        scan: for (i, p) in paragraphs.enumerated() {
            for fix in local[text(i)] ?? [] where GrammarArbiter.applies(to: fix) && !isSuppressed(fix) {
                let key = GrammarArbiter.key(paragraph: p.hash, fix: fix)
                guard verdicts[key] == nil, !asked.values.contains(key) else { continue }
                let id = items.count + 1
                items.append(.init(id: id, fix: fix, paragraph: text(i), before: text(i - 1), after: text(i + 1)))
                asked[id] = key
                if items.count == Self.arbiterBatch { break scan }
            }
        }
        guard !items.isEmpty else { return }
        let prompt = GrammarArbiter.prompt(items: items, facts: bookFacts, lang: lang)
        let voice = arbiterVoice, engine = arbiterEngine
        let model = engine.map(GrammarArbiter.model(for:)) ?? ""
        arbiterRunning = true
        Task { [weak self] in
            let result: Result<String, Error>
            do {
                if let voice { result = .success(try await voice(prompt)) }
                else if let engine { result = .success(try await Agents.oneShot(engine, prompt: prompt, model: model, cwd: root)) }
                else { result = .success("") }
            } catch { result = .failure(error) }
            self?.arbiterDone(result, asked: asked)
        }
    }

    private func arbiterDone(_ result: Result<String, Error>, asked: [Int: String]) {
        arbiterRunning = false
        let decided = (try? result.get()).map(GrammarArbiter.decode) ?? [:]
        if decided.isEmpty {
            // Nothing readable came back: show the alerts unchecked rather than hide them, and try again later.
            if case .failure(let error) = result { lastError = error.localizedDescription }
            arbiterPausedUntil = Date().addingTimeInterval(60)
        } else {
            // An alert the reply skipped stays visible: the author decides.
            for (id, key) in asked { verdicts[key] = decided[id] ?? true }
            saveSoon()
        }
        bridge?.refreshHighlights()
        if !decided.isEmpty { runArbiter() }
    }

    private func send(_ batch: [Paragraph], root: URL) {
        guard let engine = self.engine else { return }
        for p in batch { inflight.insert(p.hash) }
        running += 1
        let text = batch.map { $0.text.trimmingCharacters(in: .newlines) }.joined(separator: "\n\n")
        let prompt = Proofreader.prompt(text: text, lang: lang, dictionary: dictionary, people: bookFacts)
        let model = self.model
        Task { [weak self] in
            let result: Result<String, Error>
            do { result = .success(try await Agents.oneShot(engine, prompt: prompt, model: model, cwd: root)) }
            catch { result = .failure(error) }
            self?.receive(result, batch: batch)
        }
    }

    func receive(_ result: Result<String, Error>, batch: [Paragraph]) {
        running -= 1
        for p in batch { inflight.remove(p.hash) }
        switch result {
        case .failure(let error):
            lastError = error.localizedDescription
            pausedUntil = Date().addingTimeInterval(60)
            return
        case .success(let raw):
            lastError = nil
            // Each fix belongs to the first paragraph of the batch that contains it, never to several.
            // Identical paragraphs share a hash, so keys can repeat.
            var byHash: [String: [ProofFix]] = Dictionary(batch.map { ($0.hash, [ProofFix]()) }, uniquingKeysWith: { a, _ in a })
            for fix in Self.decode(raw) {
                for p in batch {
                    let ns = p.text as NSString
                    let r = fix.locate(in: ns)
                    guard r.location != NSNotFound else { continue }
                    var f = fix
                    f.replacement = fix.adapted(to: p.text)
                    if f.replacement != ns.substring(with: r) { byHash[p.hash, default: []].append(f) }
                    break
                }
            }
            for (hash, fixes) in byHash { cache[hash] = fixes }
        }
        saveSoon()
        applyObvious()
        bridge?.refreshHighlights()
        runPending()
    }

    static func decode(_ raw: String) -> [ProofFix] {
        guard let start = raw.firstIndex(of: "["), let end = raw.lastIndex(of: "]"), start < end,
              let data = String(raw[start...end]).data(using: .utf8),
              let fixes = try? JSONDecoder().decode([ProofFix].self, from: data) else { return [] }
        return fixes.filter { !$0.original.isEmpty && $0.original != $0.replacement }
    }

    // MARK: Applying

    /// Paragraph texts already known to need no typographic fix (skips the regex work on every keystroke).
    @ObservationIgnored private var typoClean: Set<Int> = []
    @ObservationIgnored private var typoLists = ListOptions.none
    /// The lists the open book recognises: a bullet's « - » is not a dialogue dash to fix.
    private var lists: ListOptions { bridge?.session?.manifest.listOptions ?? .none }

    /// Typographic conventions in every paragraph except the one being written, as one undo step.
    func applyTypography() {
        guard typography, !applying, Typography.supports(lang), let bridge, !bridge.loading, let tv = bridge.textView, tv.window != nil else { return }
        if let um = tv.undoManager, um.isUndoing || um.isRedoing { return }
        observeUndo(tv.undoManager)
        let caret = tv.selectedRange().location
        let ns = tv.string as NSString
        var edits: [Typography.Edit] = []
        // A paragraph found clean was clean for the lists the book had then.
        if lists != typoLists { typoLists = lists; typoClean = [] }
        for r in Typography.paragraphRanges(in: tv.string) {
            let inside = caret >= r.location && caret <= NSMaxRange(r)
            if inside && Date().timeIntervalSince(lastEdit) < 30 { continue }
            let text = ns.substring(with: r)
            if typoClean.contains(text.hashValue) { continue }
            if let name = refusedSpace(in: text) { learn(name) }
            let found = Typography.edits(in: text, lang: lang, lists: lists)
            if found.isEmpty { typoClean.insert(text.hashValue); continue }
            for key in Self.spaces(in: text, edits: found).map(\.key) { typoSpaced.insert(key) }
            edits += found.map { Typography.Edit(range: NSRange(location: r.location + $0.range.location, length: $0.range.length), replacement: $0.replacement) }
        }
        guard !edits.isEmpty else { return }
        applying = true
        defer { applying = false }
        var selection = tv.selectedRange()
        tv.undoManager?.beginUndoGrouping()
        for e in edits.reversed() {
            bridge.replace(e.range, with: e.replacement)
            if e.range.location < selection.location {
                selection.location = max(e.range.location, selection.location + (e.replacement as NSString).length - e.range.length)
            }
        }
        tv.undoManager?.endUndoGrouping()
        tv.undoManager?.setActionName(Self.typographyAction)
        tv.setSelectedRange(NSRange(location: min(selection.location, (tv.string as NSString).length), length: 0))
        typographyFixed += edits.count
        bridge.refreshHighlights()
    }

    /// A word whose space the author has taken back out: `Yahoo!` must stay `Yahoo!`.
    private func refusedSpace(in text: String) -> String? {
        Self.spaces(in: text, edits: Typography.edits(in: text, lang: lang, lists: lists)).first { typoSpaced.contains($0.key) }?.name
    }

    /// The spaces these edits would add before ; : ! ?, each with the word it follows and the text around it.
    nonisolated static func spaces(in text: String, edits: [Typography.Edit]) -> [(name: String, key: String)] {
        let ns = text as NSString
        return edits.compactMap { e in
            guard e.range.length == 0, e.replacement == Typography.nbsp, e.range.location < ns.length else { return nil }
            let mark = ns.substring(with: NSRange(location: e.range.location, length: 1))
            guard ";:!?".contains(mark) else { return nil }
            let before = ns.substring(to: e.range.location)
            let word = String(before.reversed().prefix { $0.isLetter || $0.isNumber }.reversed())
            guard !word.isEmpty else { return nil }
            let after = ns.substring(from: e.range.location + 1)
            return (word + mark, before.suffix(24) + mark + after.prefix(12))
        }
    }

    /// Named in the Edit menu, and how an undone typography batch is recognised.
    private static var typographyAction: String { L("Typography") }

    @ObservationIgnored private weak var watchedUndoManager: UndoManager?

    /// When the author undoes a typography batch, those paragraphs are left as they are until they are edited again.
    private func observeUndo(_ um: UndoManager?) {
        guard let um, um !== watchedUndoManager else { return }
        watchedUndoManager = um
        NotificationCenter.default.addObserver(forName: .NSUndoManagerDidUndoChange, object: um, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, um.redoActionName == Self.typographyAction, let tv = self.bridge?.textView else { return }
                let ns = tv.string as NSString
                for r in Typography.paragraphRanges(in: tv.string) { self.typoClean.insert(ns.substring(with: r).hashValue) }
            }
        }
    }

    /// Applies obvious fixes in every paragraph except the one being written.
    func applyObvious() {
        guard enabled, autoCorrect, !applying, let bridge, !bridge.loading, let tv = bridge.textView, tv.window != nil else { return }
        let caret = tv.selectedRange().location
        let all = issues(in: tv.string).filter(\.fix.isObvious)
        let byParagraph = Dictionary(grouping: all, by: \.paragraph.range.location)
        var edits: [Issue] = []
        for (_, items) in byParagraph {
            guard let p = items.first?.paragraph else { continue }
            let inside = caret >= p.range.location && caret <= NSMaxRange(p.range)
            if inside && Date().timeIntervalSince(lastEdit) < 30 { continue }
            edits += items
        }
        guard !edits.isEmpty else { return }
        apply(edits, logAsCorrections: true)
    }

    /// Replaces issue ranges (from the end, so earlier ranges stay valid) and re-keys the
    /// paragraph caches so the edited paragraphs keep their remaining suggestions without a new request.
    private func apply(_ items: [Issue], logAsCorrections: Bool, replacement chosen: String? = nil) {
        guard !applying, let bridge, let tv = bridge.textView else { return }
        applying = true
        defer { applying = false }
        var selection = tv.selectedRange()
        // From the end so earlier ranges stay valid; overlapping fixes are dropped.
        var applied: [Issue] = []
        for item in items.sorted(by: { $0.range.location > $1.range.location }) {
            if let last = applied.last, NSMaxRange(item.range) > last.range.location { continue }
            applied.append(item)
        }
        // Remaining fixes (AI and LanguageTool) per touched paragraph, re-keyed by its new text below.
        var touched: [Int: (Paragraph, [ProofFix], [ProofFix])] = [:]
        let localRules = usesLocal
        for item in applied {
            let p = item.paragraph
            var entry = touched[p.range.location] ?? (p, cache[p.hash] ?? [], ruleFixes(p) ?? [])
            entry.1.removeAll { $0.ignoreKey == item.fix.ignoreKey }
            entry.2.removeAll { $0.ignoreKey == item.fix.ignoreKey }
            touched[p.range.location] = entry
        }
        tv.undoManager?.beginUndoGrouping()
        for item in applied {
            // Never write over text that is no longer what the fix was made for.
            guard item.fix.matches(tv.string as NSString, at: item.range) else { continue }
            let replacement = chosen ?? item.fix.replacement
            let delta = (replacement as NSString).length - item.range.length
            bridge.replace(item.range, with: replacement)
            if item.range.location < selection.location { selection.location += delta }
            if logAsCorrections {
                corrections.insert(Correction(original: item.fix.original, replacement: item.fix.replacement, reason: item.fix.reason), at: 0)
            }
        }
        tv.undoManager?.endUndoGrouping()
        tv.undoManager?.setActionName(L("Auto-correct"))
        tv.setSelectedRange(NSRange(location: min(selection.location, (tv.string as NSString).length), length: 0))
        // Re-key caches for the edited paragraphs.
        let now = paragraphs(of: tv.string)
        for (_, (old, remaining, remainingLT)) in touched {
            if let p = now.min(by: { abs($0.range.location - old.range.location) < abs($1.range.location - old.range.location) }) {
                cache[p.hash] = remaining
                if localRules {
                    // Offsets moved; the anchors only start the search, and the paragraph is checked again soon.
                    local[p.text.trimmingCharacters(in: .newlines)] = remainingLT
                } else {
                    cache[Self.ltKey(p.hash)] = remainingLT
                }
            }
        }
        saveSoon()
        bridge.refreshHighlights()
    }

    func accept(_ issue: Issue, replacement: String? = nil) {
        apply([issue], logAsCorrections: false, replacement: replacement)
        // Back in the text, wherever the correction was chosen from: ⌘Z takes it back.
        if let tv = bridge?.textView, tv.window?.firstResponder !== tv { tv.window?.makeFirstResponder(tv) }
    }

    func ignore(_ fix: ProofFix) {
        ignored.insert(fix.ignoreKey)
        saveExceptions()
        saveSoon()
        bridge?.refreshHighlights()
    }

    /// Puts back an automatic correction and stops it from being made again.
    func revert(_ c: Correction) {
        ignored.insert("\(c.original)→\(c.replacement)")
        saveExceptions()
        corrections.removeAll { $0.id == c.id }
        guard let bridge, let tv = bridge.textView else { return }
        let fix = ProofFix(original: c.replacement, replacement: c.original, reason: "")
        let r = fix.locate(in: tv.string as NSString)
        if r.location != NSNotFound { bridge.replace(r, with: c.original) }
        saveSoon()
        bridge.refreshHighlights()
    }

    /// Clears cached results for the open chapter and checks it again.
    func recheckAll() {
        guard let tv = bridge?.textView else { return }
        for p in paragraphs(of: tv.string) { cache[p.hash] = nil; cache[Self.ltKey(p.hash)] = nil; local[p.text.trimmingCharacters(in: .newlines)] = nil }
        let open = Set(paragraphs(of: tv.string).map(\.hash))
        verdicts = verdicts.filter { !open.contains(String($0.key.prefix { $0 != "|" })) }
        arbiterPausedUntil = .distantPast
        pausedUntil = .distantPast
        ltPausedUntil = .distantPast
        lastError = nil
        languageToolError = nil
        runPending()
    }

    /// Selects the next underlined issue after the caret and opens its menu.
    func revealNext() {
        guard let tv = bridge?.textView else { return }
        let list = issues(in: tv.string)
        guard !list.isEmpty else {
            pausedUntil = .distantPast
            runPending()
            return
        }
        let caret = NSMaxRange(tv.selectedRange())
        let next = list.first { $0.range.location >= caret } ?? list[0]
        tv.setSelectedRange(next.range)
        tv.scrollRangeToVisible(next.range)
        tv.showProofMenu(for: next)
    }
}
