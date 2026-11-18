import SwiftUI

/// The book's levels as the interface says them. A level that keeps its usual word (Part, Chapter, Scene) is said
/// in the interface's own sentences, exactly as before a book could choose its form; any other word is the book's
/// (« Texte », « Acte », the author's own), in sentences written so that no article or adjective has to agree with
/// a word Musset has never seen. The names and numbers themselves come from the manifest (`BookStructure.swift`).
struct BookWords {
    typealias Level = BookStructure.LevelID
    let manifest: BookManifest
    private let levels: [Level: BookLevel]

    init(_ manifest: BookManifest) {
        self.manifest = manifest
        levels = Dictionary(uniqueKeysWithValues: Level.allCases.map { ($0, manifest.level($0)) })
    }

    /// The level still carries the word the interface has always used for it.
    func usual(_ id: Level) -> Bool {
        let term: BookStructure.Term = switch id {
        case .group: .part
        case .piece: .chapter
        case .scene: .scene
        }
        return levels[id]?.term == term
    }

    private func usual(_ ids: Level...) -> Bool { ids.allSatisfy(usual) }

    /// « Chapter », « Texte »: the level's name, as a label.
    func name(_ id: Level) -> String {
        guard !usual(id) else {
            return switch id {
            case .group: L("Part")
            case .piece: L("Chapter")
            case .scene: L("Scene")
            }
        }
        return levels[id]!.name
    }

    func plural(_ id: Level) -> String {
        guard !usual(id) else {
            return switch id {
            case .group: L("Parts")
            case .piece: L("Chapters")
            case .scene: L("Scenes")
            }
        }
        return levels[id]!.plural
    }

    /// « 3 chapters », « 1 entrée ».
    func count(_ n: Int, _ id: Level) -> String {
        guard !usual(id) else {
            return switch id {
            case .group: L("\(n) parts")
            case .piece: L("\(n) chapters")
            case .scene: L("\(n) scenes")
            }
        }
        return manifest.count(n, id)
    }

    /// The book's word inside one of the interface's sentences: as written where nouns take a capital (English
    /// titles, German), lower case elsewhere.
    func inline(_ word: String) -> String {
        if UILang.current == .en || UILang.current == .de || BookStructure.language(manifest.lang) == "de" { return word }
        return word.lowercased()
    }

    /// The word's gender, when the interface speaks the book's language and can agree with it.
    private func gender(_ id: Level) -> String? {
        guard UILang.current.rawValue.prefix(2) == BookStructure.language(manifest.lang).prefix(2) else { return nil }
        return levels[id]?.gender?.rawValue
    }

    // MARK: Pieces

    var newPiece: String { usual(.piece) ? L("New Chapter") : L("New \(inline(name(.piece)))", ctx: gender(.piece)) }
    var renamePiece: String { usual(.piece) ? L("Rename chapter") : L("Rename") }
    var thisPiece: String { usual(.piece) ? L("This chapter") : name(.piece) }
    var wholePiece: String { usual(.piece) ? L("Whole Chapter") : L("Whole Text") }
    var pieceByPiece: String { usual(.piece) ? L("Chapter by chapter") : L("\(name(.piece)) by \(inline(name(.piece)))") }
    var bookPieceByPiece: String {
        usual(.piece) ? L("The book, chapter by chapter") : L("The book, \(inline(name(.piece))) by \(inline(name(.piece)))")
    }
    var newVersion: String { usual(.piece) ? L("New Version of This Chapter…") : L("New Version…") }
    var pieceStatus: String { usual(.piece) ? L("Chapter status") : L("Status") }
    var jumpToPiece: String { usual(.piece) ? L("Jump to chapter…") : L("Jump to…") }
    var pieceSynopsis: String { usual(.piece) ? L("Chapter synopsis") : L("Synopsis") }
    var startNextPiece: String { usual(.piece) ? L("Start the next chapter") : L("Start the next one") }
    var plannedPiece: String { usual(.piece) ? L("+ Planned chapter") : "+ " + name(.piece) }
    var piecesInOrder: String { usual(.piece) ? L("chapters, in order") : L("\(inline(plural(.piece))), in order") }
    var piecesByStatus: String { usual(.piece) ? L("Chapters by status") : L("\(plural(.piece)) by status") }
    var chosenPieces: String { usual(.piece) ? L("Chosen chapters") : L("Chosen: \(inline(plural(.piece)))") }
    var choosePieces: String { usual(.piece) ? L("Choose chapters") : L("Choose…") }

    // MARK: Groups

    var newGroupHere: String {
        usual(.group) ? L("New Part Starting Here") : L("New \(inline(name(.group))) Starting Here", ctx: gender(.group))
    }
    var takeOutOfGroup: String { usual(.group) ? L("Take Out of the Part") : L("Take Out") }
    var deleteGroup: String { usual(.group, .piece) ? L("Delete Part (Chapters Stay)") : L("Delete (Contents Stay)") }
    var nameGroup: String { usual(.group) ? L("Name the part") : L("Name…").titled }
    var groupNumberNote: String {
        if usual(.group), levels[.group]?.numbering == .roman { return L("The numeral (I, II, III…) follows the order of the parts in the book.") }
        return levels[.group]?.numbering == BookStructure.Numbering.none ? "" : L("Its number follows its place in the book.")
    }
    var foldGroup: String { usual(.group) ? L("Fold or unfold the part") : L("Fold or unfold") }
    var groupScenes: String { usual(.group, .scene) ? L("Show the scenes of this part") : L("Show: \(inline(plural(.scene)))") }

    /// « Part II », « Acte II », or « II. La fuite » when it has a title.
    func groupName(_ part: BookPart) -> String {
        guard part.title.isEmpty else { return manifest.label(of: part) }
        let numeral = manifest.numeral(of: part.id)
        return usual(.group) && !numeral.isEmpty ? L("Part \(numeral)") : manifest.heading(of: part)
    }

    /// What a group's row says when the pointer rests on it.
    func groupHelp(_ part: BookPart, members: Int) -> String {
        let numeral = manifest.numeral(of: part.id)
        if usual(.group, .piece), !numeral.isEmpty { return L("Part \(numeral): \(members) chapters. Drag chapters under it to put them in.") }
        return manifest.heading(of: part) + " · " + count(members, .piece)
    }

    // MARK: Scenes

    /// A scene without a title, by its number: « Scene 3 ».
    func scene(_ n: Int) -> String { usual(.scene) ? L("Scene \(n)") : manifest.sceneTitle(n) }
    var sceneCards: String { usual(.scene, .piece) ? L("Scene Cards") : plural(.scene) }
    var showAsCards: String { usual(.scene, .piece) ? L("Show as Scene Cards") : L("Show as Cards") }
    var openCardsBeside: String { usual(.scene, .piece) ? L("Open the Scene Cards Beside") : L("Open the Cards Beside") }
    var newSceneHere: String { usual(.scene) ? L("New Scene Here") : L("New \(inline(name(.scene))) Here", ctx: gender(.scene)) }
    var sceneAtCaret: String { usual(.scene) ? L("+ Scene at the caret") : L("+ \(name(.scene)) at the caret") }
    var newSceneAtCaretHelp: String {
        usual(.scene) ? L("New scene at the caret, the title ready to type") : L("\(name(.scene)) at the caret, the title ready to type")
    }
    var renameScene: String { usual(.scene) ? L("Rename Scene…") : L("Rename…") }
    var hideScenes: String { usual(.scene) ? L("Hide scenes") : L("Hide \(inline(plural(.scene)))") }
    var showScenes: String { usual(.scene) ? L("Show scenes") : L("Show \(inline(plural(.scene)))") }
    var proposeScenes: String { usual(.scene) ? L("Propose Scenes…") : L("Propose \(inline(plural(.scene)))…") }
    var mergeWithNextScene: String { usual(.scene) ? L("Merge with the Next Scene") : L("Merge with the Next One") }
    var sceneSizes: String { usual(.scene) ? L("Size of the scenes") : L("Size: \(inline(plural(.scene)))") }
    var relativeSceneLength: String { usual(.scene) ? L("Relative length of the scenes") : L("Relative length: \(inline(plural(.scene)))") }
}

extension BookManifest {
    var words: BookWords { BookWords(self) }
}

private struct BookWordsKey: EnvironmentKey {
    static let defaultValue = BookWords(BookManifest(title: "", chapters: []))
}

extension EnvironmentValues {
    /// The open book's words, for the small views that are given no session (a card, a pill).
    var bookWords: BookWords {
        get { self[BookWordsKey.self] }
        set { self[BookWordsKey.self] = newValue }
    }
}

extension BookSession {
    /// The book's levels as the interface says them.
    var words: BookWords { manifest.words }
}
