import Foundation

/// The book's reading rubric (barème), in `.musset/rubric.md`: Markdown, edited by the author, tracked in git.
enum Rubric {
    static func url(_ root: URL) -> URL { root.appendingPathComponent(".musset/rubric.md") }

    static func load(_ root: URL) -> String? {
        guard let s = try? String(contentsOf: url(root), encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    static func save(_ text: String, root: URL) throws {
        try FileManager.default.createDirectory(at: url(root).deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url(root), atomically: true, encoding: .utf8)
    }

    /// The Collection Blanche reading rubric used for the French books.
    static let blanche = """
    # Barème de lecture « Collection Blanche »

    Référence de travail pour ce livre (ce n’est pas une grille officielle de Gallimard).

    | Critère | Points | Exigence |
    |---|---:|---|
    | **Nécessité** | **20** | Une urgence intérieure porte le texte. On sent pourquoi ce livre devait être écrit par cette personne. |
    | **Langue** | **20** | Style précis, phrases nécessaires, musicalité à voix haute. Aucun jargon, cliché ou effet gratuit. |
    | **Singularité** | **15** | Voix reconnaissable en quelques pages, influences digérées, originalité du regard, du rythme ou de la structure. |
    | **Force existentielle** | **15** | Le vécu devient une expérience partageable et une pensée incarnée. Le texte atteint le lecteur. |
    | **Maîtrise de la forme** | **10** | Architecture claire, proportions justes, économie, progression et équilibre entre récit et réflexion. |
    | **Universalité** | **10** | Une expérience particulière résonne au-delà de son contexte. Le texte peut tenir dans le temps. |
    | **Densité** | **5** | Chaque passage apporte quelque chose. Les répétitions ont une fonction ; aucune page ne meuble. |
    | **Impact émotionnel** | **5** | Le texte laisse une trace, des images ou des phrases qui persistent après la lecture. |
    | **Total** | **100** | |

    **Seuil de travail : 80/100.** En dessous, révisions ciblées avant validation. Le total ne neutralise pas un défaut éliminatoire.

    ## Risques éliminatoires

    - Une opinion ou un essai interchangeable, sans nécessité propre.
    - Un ton d’article, de mémoire universitaire, de blog ou de manifeste.
    - Une abstraction qui remplace l’expérience.
    - Une structure fortement réductible sans perte.
    - Du remplissage ou des effets qui tiennent lieu de matière.
    - Une dépendance aux modes qui condamne rapidement le texte.
    - Une émotion aussitôt oubliée.
    - Une tonalité de coaching, de développement personnel ou de pamphlet plat.

    La compatibilité « Blanche » reste une exigence transversale : **sobriété, gravité tenue, tension entre douleur et lucidité, sans didactisme.**

    ## Discipline de notation

    Juger chaque version pour elle-même, étayer les réserves par des passages précis, et ne jamais confondre la gravité du sujet avec la réussite littéraire.
    """
}
