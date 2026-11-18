import SwiftUI

extension View {
    /// Starts a drag towards Drafts or Trash; nil leaves the view as it is.
    @ViewBuilder
    func shelfDraggable(_ drag: ShelfDrag?, title: String) -> some View {
        if let drag {
            onDrag {
                PaneDragWatch.shared.began()
                return NSItemProvider(object: drag.wire as NSString)
            } preview: {
                Text(title.components(separatedBy: "\n").first ?? title)
                    .font(.ui(12)).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Ink.panel, in: RoundedRectangle(cornerRadius: Radius.row))
            }
        } else {
            self
        }
    }
}

/// Drafts and Trash, pinned under the book so they stay in reach however long the list above is.
struct ShelfSection: View {
    let app: AppState
    @Bindable var session: BookSession
    let bridge: EditorBridge
    @AppStorage("sidebarDraftsOpen") private var draftsOpen = true
    @AppStorage("sidebarTrashOpen") private var trashOpen = false
    @State private var overDrafts = false
    @State private var overTrash = false
    @State private var previewing: UUID?
    @State private var confirmEmpty = false
    @State private var deletingForGood: TrashItem?

    private static let rowHeight: CGFloat = 28
    private static let maxListHeight: CGFloat = 168

    var body: some View {
        VStack(spacing: 0) {
            Divider().padding(.bottom, 4)
            header(L("Drafts"), icon: "tray", count: draftCount, open: $draftsOpen, over: $overDrafts, target: .drafts) {
                Button { newDraft() } label: { Image(systemName: "plus").font(.ui(11)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .help(L("New draft"))
            }
            if draftsOpen, draftCount > 0 { list(draftCount) { draftRows } }
            header(L("Trash"), icon: "trash", count: session.trash.count, open: $trashOpen, over: $overTrash, target: .trash) {
                if trashOpen, !session.trash.isEmpty {
                    Button(L("Empty")) { confirmEmpty = true }
                        .buttonStyle(.plain).font(.ui(11)).foregroundStyle(.secondary)
                }
            }
            if trashOpen, !session.trash.isEmpty { list(session.trash.count) { trashRows } }
        }
        .padding(.horizontal, 10).padding(.bottom, 4)
        .confirmationDialog(L("Empty the Trash?"), isPresented: $confirmEmpty) {
            Button(L("Empty"), role: .destructive) { session.deleteFromTrash(Set(session.trash.map(\.id))) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("Files go to the Finder's Trash. Notes are gone, except in the book's history."))
        }
        .confirmationDialog(deletingForGood.map { L("Delete « \($0.title) » for good?") } ?? "",
                            isPresented: Binding(get: { deletingForGood != nil }, set: { if !$0 { deletingForGood = nil } })) {
            Button(L("Delete for Good…").titled, role: .destructive) {
                if let item = deletingForGood { session.deleteFromTrash([item.id]) }
                deletingForGood = nil
            }
            Button(L("Cancel"), role: .cancel) { deletingForGood = nil }
        } message: {
            Text(L("Files go to the Finder's Trash. Notes are gone, except in the book's history."))
        }
    }

    private var draftCount: Int { session.draftChapters.count + session.draftSheets.count }

    private func list<Rows: View>(_ count: Int, @ViewBuilder rows: () -> Rows) -> some View {
        ScrollView { VStack(spacing: 0) { rows() } }
            .frame(height: min(CGFloat(count) * Self.rowHeight, Self.maxListHeight))
    }

    private func header<Accessory: View>(_ title: String, icon: String, count: Int, open: Binding<Bool>, over: Binding<Bool>, target: BookSession.ShelfTarget, @ViewBuilder accessory: () -> Accessory) -> some View {
        let trailing = accessory()
        return SidebarRowView(active: over.wrappedValue) {
            Image(systemName: open.wrappedValue ? "chevron.down" : "chevron.right").font(.ui(8)).foregroundStyle(.tertiary).frame(width: 10)
            Image(systemName: icon).font(.ui(11)).foregroundStyle(.secondary).frame(width: 14)
            Text(title).lineLimit(1)
            Spacer(minLength: 4)
            trailing
            if count > 0 { Text("\(count)").font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary) }
        }
        .overlay { if over.wrappedValue { RoundedRectangle(cornerRadius: Radius.row).strokeBorder(Ink.accent, lineWidth: 1.5) } }
        .contentShape(Rectangle())
        .onTapGesture { open.wrappedValue.toggle() }
        .accessibilityAddTraits(.isButton)
        .dropDestination(for: String.self, action: { wires, _ in
            receive(wires, on: target)
        }, isTargeted: { over.wrappedValue = $0 })
    }

    /// Whatever moved shows at once, and a Bible entry that was open stays open where it went.
    private func receive(_ wires: [String], on target: BookSession.ShelfTarget) -> Bool {
        let result = session.drop(wires, on: target)
        guard result.accepted else { return false }
        for (old, new) in result.sheets where app.activeTab == .sheet(old) {
            if let new { app.open(.sheet(new)) } else { app.showChapter() }
        }
        bridge.refreshHighlights()
        withAnimation(.easeOut(duration: 0.16)) { if target == .drafts { draftsOpen = true } else { trashOpen = true } }
        return true
    }

    // MARK: Drafts

    @ViewBuilder private var draftRows: some View {
        ForEach(session.draftChapters) { ch in
            let open = app.activeTab?.special == nil && app.activeTab?.biblePath == nil && ch.id == session.selectedChapterID
            SidebarRowView(active: open) {
                Image(systemName: "text.alignleft").font(.ui(11)).foregroundStyle(.tertiary).frame(width: 14)
                Text(ch.title).lineLimit(1).truncationMode(.tail).fontWeight(open ? .medium : .regular)
                Spacer(minLength: 4)
                Text(ChapterSidebar.compact(session.chapterCounts[ch.id]?.size ?? 0)).font(.ui(11).monospacedDigit()).foregroundStyle(.tertiary)
            }
            .padding(.leading, 18)
            .onTapGesture {
                app.open(.chapter(ch.id)) {
                    app.showChapter()
                    if ch.id != session.selectedChapterID { session.open(ch.id) }
                }
            }
            .rowButton(ch.title, selected: open)
            .shelfDraggable(.chapter(ch.id), title: ch.title)
            .contextMenu {
                OpenElsewhere(tab: .chapter(ch.id), app: app, session: session)
                Divider()
                Button(L("Put in the Book")) { session.draftToBook(ch.id) }
                Divider()
                Button(L("Move to Trash"), role: .destructive) { _ = receive([ShelfDrag.chapter(ch.id).wire], on: .trash) }
            }
        }
        ForEach(session.draftSheets) { e in
            SidebarRowView(active: app.activeTab == .sheet(e.path)) {
                Image(systemName: e.kind.icon).font(.ui(11)).foregroundStyle(.tertiary).frame(width: 14)
                Text(e.title).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .onTapGesture { app.open(clicked: .sheet(e.path)) }
            .rowButton(e.title, selected: app.activeTab == .sheet(e.path))
            .shelfDraggable(e.isFile ? nil : .sheet(e.path), title: e.title)
            .contextMenu {
                OpenElsewhere(tab: .sheet(e.path), app: app, session: session)
                Divider()
                if !e.isFile {
                    Button(L("Put in the Book")) { intoBook(e.path) }
                }
                Button(L("Reveal in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([session.bible.store.url(e.path)]) }
                if !e.isFile {
                    Divider()
                    Button(L("Move to Trash"), role: .destructive) { _ = receive([ShelfDrag.sheet(e.path).wire], on: .trash) }
                }
            }
        }
    }

    /// The new chapter opens at once, in place of the sheet it came from.
    private func intoBook(_ path: String) {
        guard let id = session.sheetToBook(path) else { return }
        if app.activeTab == .sheet(path) { app.showChapter() }
        app.showChapter()
        session.open(id)
    }

    private func newDraft() {
        guard let e = try? session.bible.create(title: BibleKind.draft.label, kind: .draft) else { return }
        draftsOpen = true
        app.open(.sheet(e.path))
    }

    // MARK: Trash

    private var trashRows: some View {
        ForEach(session.trash.reversed()) { item in
            SidebarRowView(active: previewing == item.id) {
                Image(systemName: icon(item)).font(.ui(11)).foregroundStyle(.tertiary).frame(width: 14)
                Text(item.title).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.leading, 18)
            .onTapGesture { previewing = item.id }
            .rowButton(item.title, selected: previewing == item.id)
            .popover(isPresented: Binding(get: { previewing == item.id }, set: { if !$0 { previewing = nil } }), arrowEdge: .trailing) {
                preview(item)
            }
            .shelfDraggable(.trashed(item.id), title: item.title)
            .contextMenu {
                Button(L("Put Back")) { restore(item) }
                Divider()
                Button(L("Delete for Good…"), role: .destructive) { previewing = nil; deletingForGood = item }
            }
        }
    }

    private func icon(_ item: TrashItem) -> String {
        switch item.kind {
        case .chapter: "text.alignleft"
        case .note: "note.text"
        case .sheet: "doc.text"
        case .version: "square.on.square"
        }
    }

    private func restore(_ item: TrashItem) {
        previewing = nil
        session.restoreFromTrash(item.id)
        bridge.refreshHighlights()
    }

    private func preview(_ item: TrashItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(item.title).font(.ui(13, .medium)).lineLimit(2)
            ScrollView {
                Text(session.trashPreview(item)).font(.ui(12)).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 240)
            Button(L("Put Back")) { restore(item) }.buttonStyle(.inkSecondary)
        }
        .padding(14).frame(width: 320)
    }
}
