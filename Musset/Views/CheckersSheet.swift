import SwiftUI

/// The checker library, shared by every book, and the ones this book uses.
struct CheckersSheet: View {
    let session: BookSession
    @Environment(\.dismiss) private var dismiss
    @State private var library: [Checker] = []
    @State private var book = BookCheckers()
    @State private var selected: String?
    @State private var draft = Checker(id: "", name: "", rules: "")
    @State private var confirmDelete = false

    /// Copies a book carries from another Mac whose library this one lacks.
    private var bookOnly: [Checker] { book.copies.values.filter { c in !library.contains { $0.id == c.id } }.sorted { $0.name < $1.name } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Checkers")).font(.ui(17, .semibold))
                Text(L("Your own writing rules, checked by the AI on the open chapter. It flags passages in the margin with the rule and a few leads; it never changes the text. The library is shared by all your books; tick the ones this book uses."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)
            Divider()
            HStack(spacing: 0) {
                list.frame(width: 230)
                Divider()
                editor.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button(L("Done", ctx: "Terminé")) { save(); dismiss() }.buttonStyle(.ink).keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 820, height: 600)
        .onAppear(perform: reload)
        .confirmationDialog(L("Delete « \(draft.name) »?"), isPresented: $confirmDelete) {
            Button(L("Move to Trash"), role: .destructive) { delete() }
        } message: {
            Text(L("It goes to the Finder’s Trash. Books that use it keep their copy."))
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(library) { c in row(c) }
                    if !bookOnly.isEmpty {
                        Text(L("Only in this book")).font(.ui(11, .medium)).foregroundStyle(.secondary).padding(.top, 12).padding(.horizontal, 10)
                        ForEach(bookOnly) { c in
                            HStack {
                                Text(c.name).font(.ui(13)).lineLimit(1)
                                Spacer()
                                Button(L("Add")) { try? CheckerLibrary.save(c); reload(); select(c.id) }.buttonStyle(.link).font(.ui(12))
                                    .help(L("Into this Mac’s library"))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                        }
                    }
                    if library.isEmpty && bookOnly.isEmpty {
                        Text(L("No checker yet.")).font(.ui(12)).foregroundStyle(.secondary).padding(10)
                    }
                }
                .padding(8)
            }
            Divider()
            HStack(spacing: 10) {
                Button { newChecker() } label: { Image(systemName: "plus") }.buttonStyle(.plain).help(L("New checker"))
                Button { duplicate() } label: { Image(systemName: "plus.square.on.square") }.buttonStyle(.plain)
                    .disabled(selected == nil).help(L("Duplicate"))
                Spacer()
            }
            .padding(10)
        }
    }

    private func row(_ c: Checker) -> some View {
        HStack(spacing: 8) {
            Toggle("", isOn: Binding(get: { book.enabled.contains(c.id) }, set: { on in book.set(c, on: on); save() }))
                .toggleStyle(.checkbox).labelsHidden()
                .help(L("Used by this book"))
            Text(c.name).font(.ui(13)).lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(selected == c.id ? Ink.accent.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { save(); select(c.id) }
    }

    @ViewBuilder private var editor: some View {
        if selected == nil {
            Text(L("Choose a checker, or make one with +."))
                .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                TextField(L("Name"), text: $draft.name).textFieldStyle(.roundedBorder).font(.ui(14))
                Text(L("The rules, as you would give them to an editor. Number them: the notes will cite their numbers. You can also say how findings should be presented."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextEditor(text: $draft.rules)
                    .font(.system(size: 12, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Ink.hairline))
                HStack {
                    Text(L("\(draft.rules.split(separator: "\n").count) lines") + " · " + (book.enabled.contains(draft.id) ? L("used by this book") : L("not used by this book")))
                        .font(.ui(11)).foregroundStyle(.tertiary)
                    Spacer()
                    Button(L("Delete…"), role: .destructive) { confirmDelete = true }.buttonStyle(.inkSecondary)
                }
            }
            .padding(16)
            .onChange(of: draft) { _, _ in save() }
        }
    }

    private func reload() {
        library = CheckerLibrary.all()
        book = BookCheckers.load(session.root)
        if selected == nil { select(library.first?.id) }
    }

    private func select(_ id: String?) {
        selected = id
        if let id, let c = CheckerLibrary.load(id) { draft = c }
    }

    private func newChecker() {
        save()
        let name = L("New checker")
        let c = Checker(id: CheckerLibrary.newID(for: name), name: name, rules: L("1. "))
        try? CheckerLibrary.save(c)
        // Made from this book, for this book: ticked at once (one click to untick).
        book.set(c, on: true)
        library = CheckerLibrary.all()
        select(c.id)
        save()
    }

    private func duplicate() {
        save()
        guard selected != nil else { return }
        let name = draft.name + L(" (copy)")
        let c = Checker(id: CheckerLibrary.newID(for: name), name: name, rules: draft.rules)
        try? CheckerLibrary.save(c)
        book.set(c, on: true)
        library = CheckerLibrary.all()
        select(c.id)
        save()
    }

    private func delete() {
        guard let id = selected else { return }
        try? CheckerLibrary.delete(id)
        selected = nil
        library = CheckerLibrary.all()
        select(library.first?.id)
        session.checkersChanged += 1
    }

    /// The library file, and the book's copy when the book uses it.
    private func save() {
        if let id = selected, !draft.id.isEmpty, id == draft.id {
            try? CheckerLibrary.save(draft)
            if let i = library.firstIndex(where: { $0.id == id }) { library[i] = draft }
        }
        book.refresh()
        if book != BookCheckers.load(session.root) {
            try? book.save(session.root)
            session.pendingCommit = true
        }
        session.checkersChanged += 1
    }
}
