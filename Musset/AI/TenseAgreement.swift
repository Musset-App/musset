import AppKit

/// « Accord temporel »: puts a passage's verbs in agreement, in the tense the passage mostly uses or in one
/// the author picks. Asked of the engine set for Settings › AI › Tenses (Opus by default); each change
/// comes back as a correction ({~~old~>new~~}) to accept or reject, never written over the text.
enum TenseAgreement {
    enum Target: String, CaseIterable, Identifiable {
        case dominant, present, simplePast, compoundPast
        var id: String { rawValue }

        var label: String {
            switch self {
            case .dominant: L("To the Main Tense")
            case .present: L("To the Present")
            case .simplePast: L("To the Simple Past and Imperfect")
            case .compoundPast: L("To the Compound Past and Imperfect")
            }
        }

        fileprivate var ask: String {
            switch self {
            case .dominant: "Find the narrative tense the passage mostly uses, and bring every verb that strays from it back into agreement."
            case .present: "Put the narration in the present tense (with the tenses the present governs: passé composé for prior actions, future for later ones)."
            case .simplePast: "Put the narration in the passé simple for actions and the imparfait for descriptions and habits (plus-que-parfait for prior actions, conditionnel for the future in the past)."
            case .compoundPast: "Put the narration in the passé composé for actions and the imparfait for descriptions and habits (plus-que-parfait for prior actions, conditionnel for the future in the past)."
            }
        }
    }

    static func prompt(_ text: String, target: Target, lang: String) -> String {
        let french = lang.lowercased().hasPrefix("fr")
        return """
        You correct the verb tenses of a passage from a book in \(french ? "French" : lang), for its author. \(target.ask)
        Apply the sequence of tenses (concordance des temps) in subordinate clauses.
        Leave alone what legitimately has its own tense: direct speech and dialogue, quotations, general truths, \
        a flashback or anticipation the text clearly marks. Change only verb forms and what their agreement requires \
        (auxiliary, past participle agreement, elision: « j’ai » / « je »), never anything else: no style, no word choice.
        If nothing needs to change, return [].

        The passage:
        <<<
        \(text)
        >>>

        Reply with JSON only, one item per verb to change, in the order of the text:
        [{"original": "<the verb with 2 to 5 words around it, copied exactly from the passage>", \
        "replacement": "<the same words with only the verb changed>", "reason": "<e.g. passé composé → passé simple>"}]
        """
    }

    /// One change, located in the text.
    struct Change: Equatable {
        var range: NSRange
        var replacement: String
    }

    /// Finds each fix in `text` within `scope`, in order, and narrows it to the words that change:
    /// « il est allé au » → « il alla au » becomes est allé → alla.
    static func changes(_ fixes: [ProofFix], in text: String, scope: NSRange) -> [Change] {
        let ns = text as NSString
        let marks = Revisions.marks(in: text).map(\.range)
        var cursor = scope.location
        var out: [Change] = []
        for fix in fixes where fix.original != fix.replacement {
            guard let re = ProofFix.tolerantRegex(fix.original) else { continue }
            let end = min(ns.length, NSMaxRange(scope) + 400)
            let found = re.firstMatch(in: text, range: NSRange(location: cursor, length: max(0, end - cursor)))?.range
                ?? re.firstMatch(in: text, range: NSRange(location: scope.location, length: max(0, end - scope.location)))?.range
            guard let r = found else { continue }
            let change = narrowed(Change(range: r, replacement: fix.adapted(to: text)), in: ns)
            guard change.range.length > 0 || !change.replacement.isEmpty,
                  !marks.contains(where: { NSIntersectionRange($0, change.range).length > 0 }),
                  !out.contains(where: { NSIntersectionRange($0.range, change.range).length > 0 }) else { continue }
            out.append(change)
            cursor = NSMaxRange(r)
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// Drops the words both sides share at the start and the end.
    static func narrowed(_ c: Change, in ns: NSString) -> Change {
        let old = ns.substring(with: c.range)
        func words(_ s: String) -> [Substring] { s.split(separator: " ", omittingEmptySubsequences: false) }
        var a = words(old), b = words(c.replacement)
        var head = 0, tail = 0
        while !a.isEmpty, !b.isEmpty, a.first == b.first { head += a.removeFirst().utf16.count + 1; b.removeFirst() }
        while !a.isEmpty, !b.isEmpty, a.last == b.last { tail += a.removeLast().utf16.count + 1; b.removeLast() }
        guard !a.isEmpty || !b.isEmpty else { return Change(range: NSRange(location: c.range.location, length: 0), replacement: "") }
        let length = max(0, c.range.length - head - tail)
        return Change(range: NSRange(location: c.range.location + min(head, c.range.length), length: length), replacement: b.joined(separator: " "))
    }

    @MainActor static func run(_ text: String, target: Target, lang: String, root: URL) async throws -> [ProofFix] {
        guard let engine = TaskModels.engine(.tenses) else {
            throw Agents.err(L("No AI engine is on. Turn one on in Settings › AI."))
        }
        let raw = try await Agents.oneShot(engine, prompt: prompt(text, target: target, lang: lang),
                                           model: TaskModels.model(.tenses, for: engine), cwd: root)
        guard raw.contains("[") else { throw Agents.err(L("The answer could not be read.")) }
        return AutoProofreader.decode(raw)
    }
}

extension EditorBridge {
    /// Agrees the tenses of `scope` (the selection, or the whole chapter) and writes each change as a
    /// correction, in one undo step. The text may change meanwhile: changes are found again when they come back.
    func agreeTenses(in scope: NSRange, target: TenseAgreement.Target) {
        guard let tv = textView, let session, tenseWork == nil, NSMaxRange(scope) <= (tv.string as NSString).length else { return }
        let passage = (tv.string as NSString).substring(with: scope)
        tenseWork = L("Agreeing tenses…")
        tenseRunning = true
        Task { @MainActor [weak self] in
            defer { self?.tenseRunning = false; self?.clearTenseWork() }
            do {
                let fixes = try await TenseAgreement.run(passage, target: target, lang: session.manifest.lang, root: session.root)
                guard let self, let tv = self.textView else { return }
                let changes = TenseAgreement.changes(fixes, in: tv.string, scope: scope)
                guard !changes.isEmpty else {
                    self.tenseWork = L("Tenses already agree")
                    return
                }
                self.tenseWork = "\(changes.count) " + L("\(changes.count) tenses to review")
                let ns = tv.string as NSString
                tv.undoManager?.beginUndoGrouping()
                for c in changes.reversed() {
                    let old = ns.substring(with: c.range)
                    let mark = old.isEmpty ? "{++\(c.replacement)++}" : c.replacement.isEmpty ? "{--\(old)--}" : "{~~\(old)~>\(c.replacement)~~}"
                    self.replace(c.range, with: mark)
                }
                tv.undoManager?.endUndoGrouping()
                tv.undoManager?.setActionName(L("Agree Tenses"))
                self.scroll(to: NSRange(location: changes[0].range.location, length: 0))
            } catch {
                self?.tenseWork = nil
                session.lastError = error.localizedDescription
            }
        }
    }

    /// The outcome stays a few seconds in the status bar.
    private func clearTenseWork() {
        let shown = tenseWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.tenseWork == shown, self?.tenseRunning == false { self?.tenseWork = nil }
        }
    }
}
