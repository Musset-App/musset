import Foundation

/// What can be dragged onto Drafts or Trash, as the plain text a drag carries.
enum ShelfDrag: Equatable {
    case chapter(String)
    case note(chapter: String, id: UUID)
    case sheet(String)
    case trashed(UUID)
    /// A folder of the Bible, moved within the Bible only.
    case folder(String)
    /// A pane's tab, moved to another place among the panes.
    case tab(pane: String, index: Int)

    private static let prefix = "musset-drag|"

    var wire: String {
        switch self {
        case .chapter(let id): Self.prefix + "chapter|" + id
        case .note(let chapter, let id): Self.prefix + "note|" + id.uuidString + "|" + chapter
        case .sheet(let path): Self.prefix + "sheet|" + path
        case .trashed(let id): Self.prefix + "trashed|" + id.uuidString
        case .folder(let path): Self.prefix + "folder|" + path
        case .tab(let pane, let index): Self.prefix + "tab|\(index)|" + pane
        }
    }

    /// Anything else dropped here (text dragged from the page, from another app) is not ours.
    init?(wire: String) {
        guard wire.hasPrefix(Self.prefix) else { return nil }
        let parts = wire.dropFirst(Self.prefix.count).split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "chapter": self = .chapter(parts[1])
        case "sheet": self = .sheet(parts[1])
        case "folder": self = .folder(parts[1])
        case "tab":
            let rest = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            guard rest.count == 2, let index = Int(rest[0]) else { return nil }
            self = .tab(pane: rest[1], index: index)
        case "trashed":
            guard let id = UUID(uuidString: parts[1]) else { return nil }
            self = .trashed(id)
        case "note":
            let rest = parts[1].split(separator: "|", maxSplits: 1).map(String.init)
            guard rest.count == 2, let id = UUID(uuidString: rest[0]) else { return nil }
            self = .note(chapter: rest[1], id: id)
        default: return nil
        }
    }
}
