import AppKit
import Foundation

/// The Bible as a tree of folders, any depth. Musset's own folders (where it files sheets, cuts, drafts) are
/// "system": they hold anything, but are never renamed, moved or deleted, since the app writes into them by name.
extension BibleStore {
    enum TreeError: LocalizedError {
        case system, exists(String), intoItself, badName

        var errorDescription: String? {
            switch self {
            case .system: L("Musset files its sheets in this folder: it can’t be renamed, moved or deleted.")
            case .exists(let name): L("There is already a « \(name) » here.")
            case .intoItself: L("A folder can’t go inside itself.")
            case .badName: L("This name can’t be used for a folder.")
            }
        }
    }

    static func isSystem(_ folder: String) -> Bool { standardFolders.contains(folder) }

    /// "" for a folder at the top of the Bible.
    static func parent(of path: String) -> String { (path as NSString).deletingLastPathComponent }

    static func isInside(_ path: String, _ folder: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }

    /// Direct subfolders, in the order `folders` gives (Musset's first at the top, then by name).
    static func children(of parent: String, in folders: [String]) -> [String] {
        folders.filter { Self.parent(of: $0) == parent }
    }

    /// The name as the author typed it, made safe for the Finder; nil if nothing is left.
    static func folderName(_ typed: String) -> String? {
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    private func join(_ parent: String, _ name: String) -> String { parent.isEmpty ? name : parent + "/" + name }

    private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }

    /// A new folder, named as typed; « Notes 2 » if « Notes » is taken.
    @discardableResult
    func newFolder(named typed: String, in parent: String) throws -> String {
        guard let name = Self.folderName(typed) else { throw TreeError.badName }
        var path = join(parent, name)
        var n = 2
        while exists(path) { path = join(parent, "\(name) \(n)"); n += 1 }
        try FileManager.default.createDirectory(at: url(path), withIntermediateDirectories: true)
        return path
    }

    func renameFolder(_ path: String, to typed: String) throws -> String {
        guard !Self.isSystem(path) else { throw TreeError.system }
        guard let name = Self.folderName(typed) else { throw TreeError.badName }
        let target = join(Self.parent(of: path), name)
        guard target != path else { return path }
        // A change of case only: the Finder's volume usually ignores case, so it goes through a temporary name.
        if target.lowercased() == path.lowercased() {
            let temporary = path + "-" + UUID().uuidString
            try FileManager.default.moveItem(at: url(path), to: url(temporary))
            try FileManager.default.moveItem(at: url(temporary), to: url(target))
            return target
        }
        guard !exists(target) else { throw TreeError.exists(name) }
        try FileManager.default.moveItem(at: url(path), to: url(target))
        return target
    }

    /// Into `parent` ("" is the top of the Bible).
    func moveFolder(_ path: String, into parent: String) throws -> String {
        guard !Self.isSystem(path) else { throw TreeError.system }
        guard !Self.isInside(parent, path) else { throw TreeError.intoItself }
        let name = (path as NSString).lastPathComponent
        let target = join(parent, name)
        guard target != path else { return path }
        guard !exists(target) else { throw TreeError.exists(name) }
        try FileManager.default.createDirectory(at: url(parent), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url(path), to: url(target))
        return target
    }

    /// An entry into another folder; a document keeps its kept passages (`.pdf.md`) beside it.
    func moveEntry(_ path: String, toFolder folder: String) throws -> String {
        let moved = try move(path, toFolder: folder)
        let sidecar = url(path + ".md")
        if moved != path, FileManager.default.fileExists(atPath: sidecar.path) {
            try FileManager.default.moveItem(at: sidecar, to: url(moved + ".md"))
        }
        return moved
    }
}

extension BookSession {
    /// Where an open sheet or folder went after a rename or a move.
    static func retarget(_ path: String, from old: String, to new: String) -> String {
        BibleStore.isInside(path, old) ? new + path.dropFirst(old.count) : path
    }

    @discardableResult
    func newBibleFolder(named name: String, in parent: String) -> String? {
        bibleChange("musset: nouveau dossier dans la Bible") { try bible.store.newFolder(named: name, in: parent) }
    }

    @discardableResult
    func renameBibleFolder(_ path: String, to name: String) -> String? {
        bibleChange("musset: dossier renommé dans la Bible") { try bible.store.renameFolder(path, to: name) }
    }

    @discardableResult
    func moveBibleFolder(_ path: String, into parent: String) -> String? {
        bibleChange("musset: dossier déplacé dans la Bible") { try bible.store.moveFolder(path, into: parent) }
    }

    @discardableResult
    func moveBibleEntry(_ path: String, toFolder folder: String) -> String? {
        guard let entry = bible.entry(path: path), entry.folder != folder else { return nil }
        return bibleChange("musset: fiche déplacée dans la Bible") { try bible.store.moveEntry(path, toFolder: folder) }
    }

    /// Sheets go to the book's Trash one by one, so each can come back; files and what's left go to the Finder's Trash.
    @discardableResult
    func deleteBibleFolder(_ path: String) -> Bool {
        guard !BibleStore.isSystem(path) else { lastError = BibleStore.TreeError.system.localizedDescription; return false }
        for entry in bible.entries where !entry.isFile && BibleStore.isInside(entry.folder, path) {
            guard sheetToTrash(entry.path, commit: false) else { return false }
        }
        do {
            if FileManager.default.fileExists(atPath: bible.store.url(path).path) {
                try FileManager.default.trashItem(at: bible.store.url(path), resultingItemURL: nil)
            }
        } catch {
            lastError = error.localizedDescription
            bible.reload()
            return false
        }
        bible.reload()
        shelfChanges += 1
        commitNow("musset: dossier de la Bible supprimé")
        return true
    }

    private func bibleChange(_ message: String, _ body: () throws -> String) -> String? {
        do {
            let result = try body()
            bible.reload()
            refreshBibleMentions()
            commitNow(message)
            return result
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }
}
