import Foundation

/// The book's grid of writing tics, in `.musset/tics.md`: Markdown, edited by the author, tracked in git.
/// Each family has a definition, examples, a test to decide, and the usual way out.
enum Tics {
    static func url(_ root: URL) -> URL { root.appendingPathComponent(".musset/tics.md") }

    static func load(_ root: URL) -> String {
        guard let s = try? String(contentsOf: url(root), encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return grid }
        return s
    }

    static func save(_ text: String, root: URL) throws {
        try FileManager.default.createDirectory(at: url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url(root), atomically: true, encoding: .utf8)
    }

    static let grid = """
    # Grille des tics

    Six types de tics, chacun avec sa définition, des exemples, un test pour décider, et la correction habituelle.

    ## 1. L'antithèse corrective : « Pas X. Y. »
    On nie une chose pour en affirmer une autre.
    - « Pas calmée. Tue. » ; « Pas cheap. Cheapest. » ; « Pas triste. Blanc. »
    - « Pas un fracas. Pas une explosion. Un bruit net, sec, ridicule. »
    - « Pas une joie. Pas une guérison. Une suspension. » ; « Pas pour guider. Pour s'accrocher. » ; « Pas dehors. Dedans. »

    **Test :** le lecteur pensait-il vraiment à X ? Si personne n'imaginait un fracas, la négation fabrique un contraste pour le plaisir de le corriger.
    **Correction :** garder seulement l'affirmation.

    ## 2. Le renversement : la phrase qui se retourne sur elle-même
    La seconde moitié reprend un mot de la première et l'inverse.
    - « La mémoire n'a pas laissé une pièce vide. Elle a retiré la pièce. »
    - « La maison a gardé ses angles et m'a retiré ma place. » ; « La maison a gardé ses matières. Ma mère, non. »
    - « Il me laissait le titre. Il partait avec la perte. »
    - « Jusqu'ici, la douleur avait un dehors. Ce soir-là, elle avait mon écriture. »

    **Test :** si on coupe la seconde moitié, perd-on une information ou seulement un effet ? Si on ne perd qu'un effet, couper.

    ## 3. La chute conclusive
    Une phrase courte qui ferme le paragraphe sur un commentaire au lieu d'un fait.
    - « Ce serait propre. Trop propre. » ; « C'est pire. » ; « Rien n'était sauvé. »
    - « Les livres ont cette cruauté. Ils survivent très bien. »

    **Test :** la dernière phrase du paragraphe est-elle un fait ou un jugement ?
    **Correction :** terminer sur le fait d'avant. Le lecteur tirera la conclusion seul.

    ## 4. La maxime au présent
    Une vérité générale, au présent, avec « les » ou « on ».
    - « Les grands événements n'ont pas de son propre. » ; « Les mains servent à entrer dans le monde. »
    - « Le corps, à cet âge-là, a une brutalité sans compétence. » ; « Les enfants quittent les villes sans comprendre… »

    **Test :** la phrase pourrait-elle figurer dans un recueil de citations ? Alors c'est l'auteur qui parle, pas le personnage.
    **Correction :** couper, ou la ramener à une personne et à un moment.

    ## 5. Le fragment en rafale
    Deux ou trois mots isolés, souvent des adjectifs, en phrases séparées ou en série de trois.
    - « Lisse. Fermée. » ; « Blanche. Nette. Réelle. » ; « Lourde, chaude, réelle. »
    - « Laid. Faible. Maladif. », un par ligne.

    **Test :** les trois mots disent-ils trois choses, ou une seule chose trois fois ?
    **Correction :** garder le mot le plus précis.

    ## 6. Le paragraphe d'une ligne pour l'effet
    L'isolement typographique d'une phrase pour lui donner du poids.
    - « Rien. » ; « Pas mon père. » ; « Deux heures. » ; « Je ne savais pas danser. »

    **Test :** le silence autour de la phrase correspond-il à un silence dans la scène ? « J'avais seize ans. » oui. Ailleurs, raccrocher la phrase au paragraphe.

    ## Ce qui n'est pas un tic
    - Le zeugme avec des objets concrets (la daube parmi les invités, le fils traîné avec le chien et la poussette) : c'est la signature de l'auteur, à garder.
    - Une phrase en écho qui porte le livre : « Mon père tenait debout. Je me suis tenu. » C'est une figure, mais elle est à sa place, à la fin du chapitre, et c'est la thèse du livre.
    - La parole d'un personnage : « Ce soir. Pas toujours. Pas toute ma vie. Ce soir. », c'est le garçon qui se parle, pas l'auteur.

    **Règle simple :** au maximum une figure de ce genre par chapitre, à l'endroit où elle porte le plus.
    """

    /// The tags the notes use, one per family, matching `Note.Kind.fromTag`.
    static let tags = "[Antithèse], [Renversement], [Chute], [Maxime], [Rafale], [Ligne seule]"

    /// The request for a tics pass: the grid, then what the pattern search found in `text`.
    static func instruction(root: URL, text: String) -> String {
        let found = TicScanner.scan(text)
        let ns = text as NSString
        let list = found.prefix(80).map { c in
            "- [\(c.family.tag)] « \(ns.substring(with: c.range).replacingOccurrences(of: "\u{2028}", with: " / ")) »"
        }.joined(separator: "\n")
        return """
        Look for the author's writing tics, using the book's grid below: apply each family's test before noting anything.
        Leave a note only on real tics, tagged with the family (\(tags)), kind "tic": say which test fails and why. \
        Respect « Ce qui n'est pas un tic » and the rule of at most one such figure per chapter: if one is earned, \
        mark it once as kind "praise", tag [Réussite], and say why it carries.
        \(found.isEmpty ? "A pattern search found no candidates; read for them yourself, especially reversals (a search cannot find those)." : """
        A pattern search found these candidates. Many are fine: test each one. Reversals cannot be found by a search, so read for those yourself.
        \(list)
        """)

        GRID:
        \(load(root))
        """
    }
}

/// Finds passages that look like a tic of the grid. Only candidates: the agent applies each family's test.
enum TicScanner {
    enum Family: String, CaseIterable {
        case antithesis, ending, maxim, burst, oneLine
        var tag: String {
            switch self {
            case .antithesis: "Antithèse"
            case .ending: "Chute"
            case .maxim: "Maxime"
            case .burst: "Rafale"
            case .oneLine: "Ligne seule"
            }
        }
    }

    struct Candidate: Equatable {
        let family: Family
        let range: NSRange
    }

    private static let antithesis = try! NSRegularExpression(pattern: #"\bPas [^.!?…\n ]{1,40}[.!?…]+\s+[^.!?…\n]{1,80}[.!?…]+"#)
    private static let sentence = try! NSRegularExpression(pattern: #"[^\s.!?…][^.!?…]*[.!?…]+[»”"]?"#)
    private static let firstPerson = try! NSRegularExpression(pattern: #"(?i)\b(je|j['’]|me|m['’]|moi|mon|ma|mes|nous|notre|nos)\b"#)
    private static let pastOrConditional = try! NSRegularExpression(pattern: #"(?i)\p{L}+(ait|aient|ais)\b|\b(a|ont|ai|as|avait|avaient|était|étaient|est|sont) (\p{L}+ )?\p{L}+(é|ée|és|ées|i|is|ie|it|u|ue|us|ert|ort|eint)\b"#)
    private static let triad = try! NSRegularExpression(pattern: #"^\p{L}+, \p{L}+(, | et )\p{L}+[.!?…]+$"#)

    static func scan(_ text: String) -> [Candidate] {
        let ns = text as NSString
        var out: [Candidate] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: [.byParagraphs, .substringNotRequired]) { _, para, _, _ in
            let p = ns.substring(with: para).trimmingCharacters(in: .whitespaces)
            // Headings, comments, dialogue and quotes: not the narrator's prose.
            guard !p.isEmpty, !["#", "<!--", "—", "–", "-", "«", ">", "|", "```"].contains(where: p.hasPrefix) else { return }
            let words = p.split(whereSeparator: { $0.isWhitespace }).count
            if words < 5 { out.append(.init(family: .oneLine, range: para)); return }

            let sentences = sentence.matches(in: text, range: para).map(\.range)
            func wordCount(_ r: NSRange) -> Int { ns.substring(with: r).split(whereSeparator: { $0.isWhitespace }).count }

            for m in antithesis.matches(in: text, range: para) { out.append(.init(family: .antithesis, range: m.range)) }

            // Two or more sentences of one or two words in a row, or a lone sentence of three bare words.
            var run: [NSRange] = []
            func flushRun() {
                if run.count >= 2 { out.append(.init(family: .burst, range: NSUnionRange(run.first!, run.last!))) }
                run = []
            }
            for s in sentences {
                if wordCount(s) <= 2 { run.append(s) } else { flushRun() }
                let str = ns.substring(with: s)
                if triad.firstMatch(in: str, range: NSRange(location: 0, length: (str as NSString).length)) != nil {
                    out.append(.init(family: .burst, range: s))
                }
                // A general truth: « Les … » or « On … », present tense, nobody in particular.
                let full = NSRange(location: 0, length: (str as NSString).length)
                if str.hasPrefix("Les ") || str.hasPrefix("On "), (5...25).contains(wordCount(s)),
                   firstPerson.firstMatch(in: str, range: full) == nil, pastOrConditional.firstMatch(in: str, range: full) == nil {
                    out.append(.init(family: .maxim, range: s))
                }
            }
            flushRun()

            if sentences.count >= 2, let last = sentences.last, wordCount(last) < 6,
               !out.contains(where: { NSIntersectionRange($0.range, last).length > 0 }) {
                out.append(.init(family: .ending, range: last))
            }
        }
        var seen = Set<NSRange>()
        return out.filter { seen.insert($0.range).inserted }.sorted { $0.range.location < $1.range.location }
    }
}
