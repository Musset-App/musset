import SwiftUI

/// Rename a character or a place: every place it changes, the doubtful ones apart, then one change and one undo.
struct RenameSheet: View {
    let session: BookSession
    let bridge: EditorBridge
    let path: String
    let done: () -> Void
    @State private var plan: RenamePlan?
    @State private var newName = ""
    /// Places shown at once in each list.
    @State private var shownHits = 200
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let entry = session.bible.entry(path: path) {
                header(entry)
                Divider()
                if let plan { list(plan) } else { Spacer() }
                Divider()
                footer
            }
        }
        .frame(width: 720, height: 600)
        .onAppear {
            newName = session.bible.entry(path: path)?.title ?? ""
            focused = true
            rebuild()
        }
    }

    private func header(_ entry: BibleEntry) -> some View {
        HStack(spacing: 10) {
            Text(L("Rename « \(entry.title) » to"))
            TextField("", text: $newName)
                .textFieldStyle(.roundedBorder).frame(width: 220).focused($focused)
                .onChange(of: newName) { _, _ in recount() }
                .onSubmit(apply)
            Spacer()
            if let plan {
                Text(L("\(plan.hits.count) in the text")).foregroundStyle(.secondary)
                if !plan.toCheck.isEmpty { Text(L("\(plan.toCheck.count) to check")).foregroundStyle(Ink.critique) }
            }
        }
        .font(.ui(13))
        .padding(20)
    }

    private func list(_ plan: RenamePlan) -> some View {
        ScrollView {
            // Eager and bounded: a name can be in the book two thousand times, and a LazyVStack of rows of every
            // height is what spun forever in SwiftUI's prefetch in the chat. The rows not shown are renamed all the same.
            VStack(alignment: .leading, spacing: 0) {
                let aliases = plan.entry.aliases.filter { a in plan.hits.contains { $0.form == a } }
                if !aliases.isEmpty {
                    section(L("Other names"))
                    ForEach(aliases, id: \.self) { alias in
                        HStack {
                            Text(L("« \(alias) » becomes"))
                            TextField(alias, text: Binding(get: { self.plan?.aliasTo[alias] ?? alias },
                                                          set: { self.plan?.aliasTo[alias] = $0; recount() }))
                                .textFieldStyle(.roundedBorder).frame(width: 180)
                        }
                        .font(.ui(13)).padding(.vertical, 4)
                    }
                }
                if !plan.toCheck.isEmpty {
                    section(L("To check"))
                    ForEach(plan.toCheck.prefix(shownHits)) { hitRow($0, plan: plan) }
                }
                section(L("In the text"))
                ForEach(plan.sure.prefix(shownHits)) { hitRow($0, plan: plan) }
                if max(plan.sure.count, plan.toCheck.count) > shownHits {
                    Button(L("Show more")) { shownHits += 200 }.buttonStyle(.link).font(.ui(12)).padding(.vertical, 10)
                }
                let e = plan.elsewhere
                if e.bible + e.notes + e.plot > 0 {
                    section(L("Also"))
                    Text([e.bible > 0 ? L("\(e.bible) in the Bible") : nil, e.notes > 0 ? L("\(e.notes) in the notes") : nil,
                          e.plot > 0 ? L("\(e.plot) in the plot") : nil].compactMap { $0 }.joined(separator: " · "))
                        .font(.ui(13)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 16)
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.ui(11, .medium)).foregroundStyle(.secondary).padding(.top, 16).padding(.bottom, 4)
    }

    private func hitRow(_ hit: RenamePlan.Hit, plan: RenamePlan) -> some View {
        let on = Binding(get: { !(self.plan?.skipped.contains(hit.id) ?? true) },
                         set: { v in if v { self.plan?.skipped.remove(hit.id) } else { self.plan?.skipped.insert(hit.id) } })
        let chapter = session.manifest.chapters.first { $0.id == hit.chapter }?.title ?? hit.chapter
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("", isOn: on).toggleStyle(.checkbox).labelsHidden()
                .accessibilityLabel(L("Rename here"))
            VStack(alignment: .leading, spacing: 2) {
                passage(hit, plan: plan, on: on.wrappedValue)
                if let reason = hit.reason { Text(reason).font(.ui(11)).foregroundStyle(Ink.critique) }
            }
            Spacer(minLength: 8)
            Text(chapter).font(.ui(11)).foregroundStyle(.secondary).lineLimit(1).frame(width: 120, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }

    private func passage(_ hit: RenamePlan.Hit, plan: RenamePlan, on: Bool) -> Text {
        // The paragraph the name is in only, revision marks taken out for reading.
        let lead = Self.readable(hit.before.components(separatedBy: "\n").last ?? "")
        let tail = Self.readable(hit.after.components(separatedBy: "\n").first ?? "")
        var t = Text("…" + lead)
        if on, let to = plan.replacement(for: hit.form) {
            t = t + Text(hit.form).strikethrough().foregroundColor(.secondary) + Text(" ") + Text(to).foregroundColor(Ink.accent)
        } else {
            t = t + Text(hit.form).bold()
        }
        return (t + Text(tail + "…")).font(.uiMono(12))
    }

    /// « {++its back doors++}{@Claire} » reads « its back doors »: the excerpt as the reader sees it.
    static func readable(_ s: String) -> String {
        s.replacingOccurrences(of: "\\{@[^}]*\\}|\\{>>[^}]*<<\\}|\\{--[^}]*--\\}|\\{~~[^}]*?~>|\\{(\\+\\+|==)|(\\+\\+|==|~~)\\}", with: "", options: .regularExpression)
    }

    private var footer: some View {
        HStack {
            Text(L("One undo reverses it all.")).font(.ui(11)).foregroundStyle(.secondary)
            Spacer()
            Button(L("Cancel"), role: .cancel, action: done).keyboardShortcut(.cancelAction)
            Button(L("Rename \(plan?.count ?? 0)"), action: apply)
                .keyboardShortcut(.defaultAction)
                .disabled((plan?.count ?? 0) == 0)
        }
        .padding(16)
    }

    private func rebuild() {
        guard let entry = session.bible.entry(path: path) else { return }
        plan = RenamePlan.make(entry, to: newName, in: session)
    }

    private func recount() {
        guard var p = plan else { return }
        p.newName = newName
        p.elsewhere = p.countElsewhere(in: session)
        plan = p
    }

    private func apply() {
        guard let plan, plan.count > 0 else { return }
        if let undo = session.applyRename(plan), let um = bridge.textView?.undoManager {
            um.registerUndo(withTarget: session) { $0.undoRename(undo) }
            um.setActionName(L("Rename"))
        }
        done()
    }
}
