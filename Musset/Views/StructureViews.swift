import SwiftUI

// The book's form, where the author meets it: Book Settings › Structure, and the form step of a new book.
// What a name or a number is comes from the manifest (`BookStructure.swift`); nothing is computed here.

extension BookStructure.Form {
    /// The form's name, in the interface's language.
    var label: String {
        switch self {
        case .novel: L("Novel")
        case .novelInParts: L("Novel in parts")
        case .collection: L("Collection", ctx: "Recueil")
        case .journal: L("Journal, letters")
        case .essay: L("Essay, document")
        case .play: L("Play, screenplay")
        case .fragments: L("Fragments")
        case .custom: L("Custom", ctx: "Sur mesure")
        }
    }

    var summary: String {
        switch self {
        case .novel: L("Chapters, with scenes inside.")
        case .novelInParts: L("Parts that group the chapters.")
        case .collection: L("Stories, essays or poems: titled pieces, without numbers.")
        case .journal: L("Dated or addressed entries, in the order of time.")
        case .essay: L("Chapters, sections, sub-headings and numbered lists.")
        case .play: L("Acts and scenes.")
        case .fragments: L("Short blocks, numbered or not, without chapters.")
        case .custom: L("Name the levels yourself.")
        }
    }

    /// The levels as the form's diagram nests them, in the book's language; `custom` has none of its own yet.
    func diagram(lang: String) -> [String] {
        if self == .custom { return (1...3).map { L("Level \($0)") } }
        return BookStructure.levels(of: self).map { BookStructure.word(BookStructure.preset(self)[$0].term, lang: lang).one }
    }
}

extension BookStructure.Numbering {
    var label: String {
        switch self {
        case .roman: "I, II, III"
        case .arabic: "1, 2, 3"
        case .none: L("None", ctx: "Aucun")
        }
    }
}

extension BookStructure.Opening {
    var label: String {
        switch self {
        case .rightPage: L("On a right-hand page")
        case .newPage: L("On a new page")
        case .inPage: L("In the page, after a blank")
        }
    }
}

extension BookManifest {
    /// A small book in this book's form, for the previews: an unnumbered piece, two groups of numbered ones, another
    /// unnumbered piece between them. Its names and numbers are the real ones, computed as the book's are.
    var structureSample: BookManifest {
        var m = BookManifest(title: "", author: "", lang: lang, chapters: [])
        m.structure = structure
        let kinds = unnumberedKinds
        let strands = structure?.strands ?? []
        func piece(_ id: String, part: String?, kind: String? = nil, strand: Int? = nil) -> ChapterEntry {
            var ch = ChapterEntry(id: id, file: id + ".md", title: "", part: part, kind: kind)
            if let strand, !strands.isEmpty { ch.strand = strands[strand % strands.count].id }
            return ch
        }
        m.parts = [BookPart(id: "a"), BookPart(id: "b")]
        m.chapters = (kinds.first.map { [piece("p", part: nil, kind: $0)] } ?? [])
            + [piece("1", part: "a", strand: 0), piece("2", part: "a", strand: 1)]
            + (kinds.dropFirst().first.map { [piece("i", part: "a", kind: $0)] } ?? [])
            + [piece("3", part: "b", strand: 0)]
        // A book with no structure and no parts is a plain novel: the sample has none either.
        if structure == nil, form == .novel { m.parts = nil }
        return m
    }
}

// MARK: The preview

/// What the form gives: the sidebar as it will read, and a piece's opening as it will print.
struct StructurePreview: View {
    let manifest: BookManifest
    /// The group's opening page beside the piece's (the new book's step has the room).
    var groupPage = false

    private var sample: BookManifest { manifest.structureSample }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(L("Sidebar"), tracking: 1.4)
                sidebar
            }
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel(L("In print"), tracking: 1.4)
                HStack(spacing: 10) {
                    if groupPage, let part = sample.shownParts.first { groupOpening(part) }
                    pieceOpening
                }
            }
        }
    }

    private var sidebar: some View {
        let m = sample
        let marks = m.pieceMarks
        var previous: String?
        var rows: [(id: String, group: BookPart?, piece: Int?)] = []
        for (i, ch) in m.chapters.enumerated() {
            let group = m.group(of: ch)
            if let group, group.id != previous { rows.append(("g" + group.id, group, nil)) }
            previous = group?.id
            rows.append((ch.id, nil, i))
        }
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(rows, id: \.id) { row in
                if let group = row.group {
                    Text(m.heading(of: group).uppercased()).font(.ui(10.5, .semibold)).tracking(1).foregroundStyle(.secondary).padding(.top, 3)
                } else if let i = row.piece {
                    let ch = m.chapters[i]
                    HStack(spacing: 7) {
                        if let kind = BookManifest.kind(of: ch) {
                            Text(m.kindName(kind)).font(.system(size: 13, design: .serif).italic()).foregroundStyle(.secondary)
                        } else {
                            if !marks[i].isEmpty { Text(marks[i]).font(.uiMono(11)).foregroundStyle(.secondary) }
                            Text(L("[Title]")).font(.ui(12.5))
                        }
                        Spacer(minLength: 0)
                        if let strand = manifest.structure?.strands?.first(where: { $0.id == ch.strand }) {
                            StrandMark(colour: strand.colour)
                        }
                    }
                    .padding(.leading, m.group(of: ch) != nil ? 12 : 0)
                }
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(Ink.hairline))
    }

    /// The printed page: paper and ink, the same in both themes.
    private func page<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 6) { content() }
            .font(.system(size: 10, design: .serif))
            .foregroundStyle(Color(hex: "#26251F"))
            .padding(.horizontal, groupPage ? 14 : 18).padding(.top, groupPage ? 26 : 34)
            .frame(maxWidth: .infinity)
            .frame(height: groupPage ? 150 : 190, alignment: .top)
            .background(Color(hex: "#EFECE3"), in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Ink.hairline))
    }

    private func groupOpening(_ part: BookPart) -> some View {
        page {
            Spacer()
            Text(sample.heading(of: part).uppercased()).font(.system(size: 9, design: .serif)).tracking(1.6).lineLimit(1).minimumScaleFactor(0.7)
            Spacer()
        }
    }

    private var pieceOpening: some View {
        let m = sample
        let first = m.chapters.first { BookManifest.kind(of: $0) == nil }
        return page {
            if let heading = first.flatMap(m.heading(of:)) {
                Text(heading.uppercased()).tracking(1.4).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(L("[Title]")).font(.system(size: groupPage ? 12 : 14, design: .serif).italic())
            VStack(alignment: .leading, spacing: 6) {
                ForEach(0..<(groupPage ? 3 : 4), id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2).fill(Color(hex: "#C9C5B8")).frame(height: 3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, i == (groupPage ? 2 : 3) ? 44 : 0)
                }
            }
            .padding(.top, groupPage ? 6 : 10)
        }
    }
}

/// What the previews say in a sentence: how the groups open, how the pieces number, what carries no number.
extension BookManifest {
    var structureSentence: String {
        var out: [String] = []
        let group = level(.group), piece = level(.piece)
        if group.on { out.append(L("\(group.plural): \(group.opens.label.lowercased(with: UILang.locale))")) }
        switch piece.numbering {
        case .none: out.append(L("\(piece.plural): a title, no number"))
        default: out.append(piece.restarts && group.on ? L("\(piece.plural): the numbering starts again in each \(words.inline(group.name))")
                                                       : L("\(piece.plural): the numbering runs through the book"))
        }
        let kinds = unnumberedKinds.prefix(2).map(kindName)
        if !kinds.isEmpty { out.append(L("\(kinds.listed): a name, no number")) }
        return out.joined(separator: " · ")
    }
}

// MARK: Book Settings › Structure

struct StructureSettings: View {
    @Bindable var session: BookSession
    /// A form picked, waiting for the author's yes.
    @State private var asking: BookStructure.Form?
    @State private var hidingGroups = false
    @State private var addingKind = false
    @State private var newKind = ""
    @State private var removingStrand: BookStructure.Strand?

    private var m: BookManifest { session.manifest }
    private typealias Level = BookStructure.LevelID

    /// The group level as its switch shows it: a plain novel that never chose a form has none.
    private var groupsShown: Bool { m.structure == nil ? m.form != .novel : m.groupsOn }
    private var partsInUse: Int { Set(m.chapters.compactMap { ch in ch.part.flatMap { id in m.parts?.first { $0.id == id }?.id } }).count }

    /// One change to the structure, saved like any other setting. A book that never chose a form takes the one it reads as.
    private func change(save: Bool = true, _ edit: (inout BookStructure) -> Void) {
        var s = m.structure ?? BookStructure(form: m.form)
        edit(&s)
        guard s != m.structure else { return }
        let sections = m.textFeatures.subheadings
        session.manifest.structure = s
        if session.manifest.textFeatures.subheadings != sections { session.refreshSections() }
        if save { session.saveManifest() }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    levels
                    HStack(alignment: .top, spacing: 28) {
                        unnumbered.frame(maxWidth: .infinity, alignment: .leading)
                        strands.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    inText
                    Text(L("Changing the structure renames and renumbers; your files and your text do not move. Switching a level off only stops showing it: what it grouped stays in the book."))
                        .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Ink.side, in: RoundedRectangle(cornerRadius: Radius.control))
                        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(Ink.hairline))
                }
                .padding(.horizontal, 28).padding(.vertical, 28)
            }
            .frame(maxWidth: .infinity)
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                StructurePreview(manifest: m)
                Text(L("The preview follows each setting as you change it.")).font(.ui(12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 22).padding(.top, 34)
            .frame(width: 250, alignment: .topLeading)
        }
        .alert(asking.map { L("Change to « \($0.label) »?") } ?? "", isPresented: Binding(get: { asking != nil }, set: { if !$0 { asking = nil } })) {
            Button(L("Change form")) {
                if let form = asking { session.setStructure { $0.setForm(form) } }
                asking = nil
            }
            Button(L("Cancel"), role: .cancel) { asking = nil }
        } message: {
            Text(formWarning)
        }
        .alert(L("Stop grouping the book?"), isPresented: $hidingGroups) {
            Button(L("Stop Showing Them")) { change { $0[.group].off = true } }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("The book’s groups (\(session.words.count(partsInUse, .group))) will no longer show. They stay in the book, with what they hold, and come back when you switch the level on again."))
        }
        .alert(L("New unnumbered piece"), isPresented: $addingKind) {
            TextField(L("Name"), text: $newKind)
            Button(L("Add")) { addKind() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("For example: Intermission, Letter, Coda."))
        }
        .alert(L("Remove this strand?"), isPresented: Binding(get: { removingStrand != nil }, set: { if !$0 { removingStrand = nil } })) {
            Button(L("Remove"), role: .destructive) { if let s = removingStrand { session.removeStrand(s.id) }; removingStrand = nil }
            Button(L("Cancel"), role: .cancel) { removingStrand = nil }
        } message: {
            Text(L("What follows it (\(session.words.count(removingStrand.map { m.pieces(in: $0.id) } ?? 0, .piece))) stays where it is, without a strand."))
        }
    }

    /// What the change of form does, and what it never does; and the parts a form without groups stops showing.
    private var formWarning: String {
        var out = L("The levels take this form’s names and numbers. Your files and your text do not move.")
        if let form = asking, form != .custom, BookStructure.preset(form).group.unused, partsInUse > 0 {
            out += " " + L("This form has no groups: the book’s (\(session.words.count(partsInUse, .group))) stay in the book but no longer show.")
        }
        return out
    }

    private func heading(_ title: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(14, .semibold))
            Text(note).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(L("Structure")).font(.system(size: 28, design: .serif))
            Spacer(minLength: 12)
            Text(L("Form:")).foregroundStyle(.secondary)
            Text(m.form.label).fontWeight(.semibold)
            Menu(L("Change form…")) {
                ForEach(BookStructure.Form.allCases) { form in
                    Button { asking = form } label: {
                        if form == m.form { Label(form.label, systemImage: "checkmark") } else { Text(form.label) }
                    }
                    .disabled(form == m.form && form != .custom)
                }
            }
            .fixedSize()
        }
    }

    // MARK: Levels

    private var levels: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L("Levels"), L("From the largest to the smallest. The name is used everywhere: sidebar, overview, export."))
            SettingsCard(filled: true) {
                levelColumns(Text(""), Text(L("Name")), Text(L("Plural")), Text(L("Numerals")), Text(L("Numbering")), Text(L("Starts", ctx: "Commence")), Text(""))
                    .font(.ui(11, .semibold)).foregroundStyle(.secondary).textCase(.uppercase).lineLimit(1)
                    .padding(.vertical, 8).background(Ink.side)
                ForEach(Array(Level.allCases.enumerated()), id: \.element) { i, id in levelRow(i + 1, id) }
            }
        }
    }

    private func levelColumns<A: View, B: View, C: View, D: View, E: View, F: View, G: View>(_ a: A, _ b: B, _ c: C, _ d: D, _ e: E, _ f: F, _ g: G) -> some View {
        HStack(spacing: 10) {
            a.frame(width: 16, alignment: .leading)
            b.frame(width: 104, alignment: .leading)
            c.frame(width: 104, alignment: .leading)
            d.frame(width: 88, alignment: .leading)
            e.frame(maxWidth: .infinity, alignment: .leading)
            f.frame(maxWidth: .infinity, alignment: .leading)
            // Kept even when empty, so every row has the same columns.
            ZStack { Color.clear.frame(height: 1); g }.frame(width: 38, alignment: .trailing)
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder private func levelRow(_ n: Int, _ id: Level) -> some View {
        let level = m.level(id)
        let on = id == .group ? groupsShown : true
        let word = BookStructure.word(BookStructure.preset(m.structure?.form ?? .novelInParts)[id].term, lang: m.lang)
        levelColumns(
            Text("\(n)").font(.ui(12, .semibold)).foregroundStyle(.secondary),
            dimmed(!on, TextField(word.one, text: name(id, \.name)).textFieldStyle(.roundedBorder).onSubmit { session.saveManifest() }
                .accessibilityLabel(L("Name of level \(n)"))),
            dimmed(!on, TextField(m.structure?[id].name.flatMap { $0.isEmpty ? nil : $0 } ?? word.many, text: name(id, \.plural)).textFieldStyle(.roundedBorder).onSubmit { session.saveManifest() }
                .accessibilityLabel(L("Plural of level \(n)"))),
            dimmed(!on, menu(BookStructure.Numbering.allCases.map { ($0, $0.label) }, level.numbering, L("Numerals")) { v in change { $0[id].numbering = v } }),
            dimmed(!on, restarts(id, level)),
            dimmed(!on, menu(BookStructure.Opening.allCases.filter { id != .scene || $0 == .inPage || $0 == .newPage }.map { ($0, $0.label) }, level.opens, L("Starts", ctx: "Commence")) { v in change { $0[id].opens = v } }),
            // The switch stays live on a level that is off: it is how it comes back.
            groupSwitch(id)
        )
        .padding(.vertical, 8)
    }

    /// A control of a level that is switched off: there to be read, not to be set.
    private func dimmed<V: View>(_ off: Bool, _ view: V) -> some View {
        view.disabled(off).opacity(off ? 0.45 : 1)
    }

    @ViewBuilder private func groupSwitch(_ id: Level) -> some View {
        if id == .group {
            Toggle("", isOn: Binding(get: { groupsShown }, set: { showGroups($0) })).toggleStyle(.switch).labelsHidden().controlSize(.mini)
                .help(L("Group the pieces at this level")).accessibilityLabel(L("Group the pieces at this level"))
        }
    }

    /// Off with parts in the book asks first, and then only stops showing them.
    private func showGroups(_ on: Bool) {
        if on { change { $0[.group].off = false } }
        else if partsInUse > 0 { hidingGroups = true }
        else { change { $0[.group].off = true } }
    }

    /// The author's own word for a level: empty leaves the form's. Saved with the page, not at each letter.
    private func name(_ id: Level, _ key: WritableKeyPath<BookStructure.Level, String?>) -> Binding<String> {
        Binding(get: { m.structure?[id][keyPath: key] ?? "" },
                set: { v in change(save: false) { $0[id][keyPath: key] = v.isEmpty ? nil : v } })
    }

    @ViewBuilder private func restarts(_ id: Level, _ level: BookLevel) -> some View {
        if id == .piece, level.numbering != .none, groupsShown {
            menu([(false, L("Continues through the book")), (true, L("Starts again in each \(session.words.inline(m.level(.group).name))"))], level.restarts, L("Numbering")) { v in
                change { $0[.piece].restarts = v }
            }
        } else if level.numbering != .none, id != .scene {
            Text(L("Continues through the book")).font(.ui(12)).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }

    private func menu<T: Hashable>(_ options: [(T, String)], _ value: T, _ label: String, set: @escaping (T) -> Void) -> some View {
        Picker(label, selection: Binding(get: { value }, set: set)) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
        .labelsHidden().controlSize(.small)
    }

    // MARK: Unnumbered pieces

    private var unnumbered: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L("Unnumbered pieces"), L("They carry their name, go where you like, and do not shift the numbering."))
            Flow(spacing: 8) {
                ForEach(m.unnumberedKinds, id: \.self) { kind in
                    HStack(spacing: 6) {
                        Text(m.kindName(kind)).font(.ui(12))
                        Button { change { $0.unnumbered = m.unnumberedKinds.filter { $0 != kind } } } label: {
                            Image(systemName: "xmark").font(.ui(8, .semibold)).foregroundStyle(.secondary).frame(width: 14, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(L("Remove \(m.kindName(kind))"))
                    }
                    .padding(.leading, 10).padding(.trailing, 5).frame(height: 26)
                    .overlay(Capsule().strokeBorder(Ink.hairline))
                }
                Button { newKind = ""; addingKind = true } label: {
                    Text(L("+ Add…")).font(.ui(12)).foregroundStyle(Ink.accent).padding(.horizontal, 10).frame(height: 26)
                        .overlay(Capsule().strokeBorder(Ink.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func addKind() {
        let name = newKind.trimmingCharacters(in: .whitespacesAndNewlines)
        // One of Musset's own, typed by its name, is kept by its id: it follows the book's language.
        let kind = BookStructure.builtInKinds.first { m.kindName($0).compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame } ?? name
        guard !kind.isEmpty, !m.unnumberedKinds.contains(kind) else { return }
        change { $0.unnumbered = m.unnumberedKinds + [kind] }
    }

    // MARK: Strands

    private var strands: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L("Strands"), L("A period, a narrator, a place. Each \(session.words.inline(m.level(.piece).name)) can follow one strand; the Overview colours and filters by strand."))
            VStack(alignment: .leading, spacing: 8) {
                ForEach(m.structure?.strands ?? []) { strand in
                    HStack(spacing: 10) {
                        Menu {
                            ForEach(BookStructure.strandColours, id: \.self) { hex in
                                Button { edit(strand) { $0.colour = hex } } label: {
                                    Label { Text(hex == strand.colour ? "●" : "") } icon: { Image(nsImage: StrandMark.image(hex)) }
                                }
                            }
                        } label: {
                            // A menu keeps only an image or a text of its label.
                            Image(nsImage: StrandMark.image(strand.colour))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .accessibilityLabel(L("Colour"))
                        TextField(L("Name of the strand"), text: Binding(get: { strand.name }, set: { v in edit(strand, save: false) { $0.name = v } }))
                            .textFieldStyle(.roundedBorder).onSubmit { session.saveManifest() }
                        Text(session.words.count(m.pieces(in: strand.id), .piece)).font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                        Button { if m.pieces(in: strand.id) > 0 { removingStrand = strand } else { session.removeStrand(strand.id) } } label: {
                            Image(systemName: "xmark").font(.ui(9, .semibold)).foregroundStyle(.secondary).frame(width: 18, height: 20).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).accessibilityLabel(L("Remove"))
                    }
                }
                Button(L("+ Add a strand")) {
                    let colour = m.nextStrandColour
                    change { $0.strands = ($0.strands ?? []) + [BookStructure.Strand(colour: colour)] }
                }
                .buttonStyle(.plain).font(.ui(12)).foregroundStyle(Ink.accent)
            }
        }
    }

    private func edit(_ strand: BookStructure.Strand, save: Bool = true, _ edit: (inout BookStructure.Strand) -> Void) {
        change(save: save) { s in
            guard let i = s.strands?.firstIndex(where: { $0.id == strand.id }) else { return }
            edit(&s.strands![i])
        }
    }

    // MARK: In the text

    private var inText: some View {
        VStack(alignment: .leading, spacing: 12) {
            heading(L("In the text"), L("What Musset recognises in the text."))
            SettingsCard(filled: true) {
                SettingsRow(title: L("Sub-headings"), hint: L("Lines starting with « ## » and « ### » become sections: they show in the sidebar and the jump field, and « ## » in the table of contents.")) {
                    SettingsSwitch(on: Binding(get: { m.textFeatures.subheadings }, set: { v in change { $0.text = text($0) { $0.subheadings = v } } }))
                }
                SettingsRow(title: L("Bullet lists"), hint: L("A line that starts with « - », « * » or « + » and a space is a list item: Return continues the list, Tab nests the item. Off, a hyphen at the start of a line becomes a dialogue dash again. On, a hyphen line that reads as a line of dialogue (a sentence with its full stop or question mark) still becomes a dash, except in an essay.")) {
                    SettingsSwitch(on: Binding(get: { m.listOptions.bullets }, set: { v in change { $0.text = text($0) { $0.bulletLists = v } } }))
                }
                SettingsRow(title: L("Numbered lists"), hint: L("Off, « 1. » opens a sentence like any number. On, a line starting with « 1. » opens a list; « 1943. Barcelona. » stays a sentence.")) {
                    SettingsSwitch(on: Binding(get: { m.textFeatures.numberedLists }, set: { v in change { $0.text = text($0) { $0.numberedLists = v } } }))
                }
            }
        }
    }

    private func text(_ s: BookStructure, _ edit: (inout BookStructure.TextFeatures) -> Void) -> BookStructure.TextFeatures {
        var t = s.text ?? BookStructure.TextFeatures()
        edit(&t)
        return t
    }
}

/// Chips that wrap to the next line when the row is full.
struct Flow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = place(subviews, width: proposal.width ?? .infinity)
        return CGSize(width: proposal.width ?? rows.width, height: rows.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placed = place(subviews, width: bounds.width)
        for (view, point) in zip(subviews, placed.points) {
            view.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> (points: [CGPoint], width: CGFloat, height: CGFloat) {
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return (points, widest, y + line)
    }
}

// MARK: A new book's form

/// The form step of a new book: eight forms with their levels as they nest, and what the chosen one gives.
struct FormChooser: View {
    @Binding var form: BookStructure.Form
    let lang: String
    let title: String
    var working = false
    var error: String?
    let back: () -> Void
    let create: () -> Void

    /// The book as the chosen form makes it, for the preview.
    private var manifest: BookManifest {
        var m = BookManifest(title: title, author: "", lang: lang, chapters: [])
        m.structure = BookStructure(form: form)
        return m
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text("1 · " + L("Title")).foregroundStyle(.secondary)
                Text("—").foregroundStyle(.tertiary)
                Text("2 · " + L("Form")).fontWeight(.semibold)
                Spacer()
            }
            .font(.ui(12)).padding(.horizontal, 40).frame(height: 44)
            .background(WindowDragArea())
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("What form does your book take?")).font(.system(size: 30, design: .serif))
                    Text(L("Musset names and numbers the pieces of the book from this choice. Nothing is set in stone: the form can be changed later, and your files do not move."))
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 560, alignment: .leading)
                        .padding(.top, 8).padding(.bottom, 20)
                    VStack(spacing: 12) {
                        ForEach(0..<2, id: \.self) { row in
                            HStack(spacing: 12) {
                                ForEach(BookStructure.Form.allCases[(row * 4)..<(row * 4 + 4)]) { card($0) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle().fill(Ink.hairline).frame(width: 1)
                VStack(alignment: .leading, spacing: 16) {
                    StructurePreview(manifest: manifest, groupPage: true)
                    Text(manifest.structureSentence).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 290, alignment: .topLeading)
            }
            .padding(.horizontal, 40).padding(.top, 10)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                if let error { Text(error).font(.ui(12)).foregroundStyle(Ink.error).lineLimit(2) }
                else { Text(L("Everything can be set afterwards in Book Settings › Structure.")).font(.ui(12)).foregroundStyle(.secondary) }
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button(L("Back", ctx: "Retour"), action: back).buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
                Button(L("Begin") + " ↩", action: create).buttonStyle(.ink).keyboardShortcut(.defaultAction).disabled(working)
            }
            .padding(.horizontal, 40).padding(.vertical, 20)
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private func card(_ f: BookStructure.Form) -> some View {
        let on = f == form
        return Button { form = f } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(f.label).font(.ui(14, .semibold))
                Text(f.summary).font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                // The levels, as they nest.
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(f.diagram(lang: lang).enumerated()), id: \.offset) { k, name in
                        HStack(spacing: 7) {
                            RoundedRectangle(cornerRadius: 2).frame(width: CGFloat(22 - k * 6), height: 3)
                            Text(name).font(.ui(11.5)).lineLimit(1)
                        }
                        .foregroundStyle(k == 0 ? Color.primary : .secondary)
                        .padding(.leading, CGFloat(k * 14))
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Ink.side, in: RoundedRectangle(cornerRadius: 7))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 216)
            .background(on ? Ink.accent.opacity(0.12) : Ink.panel, in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(on ? Ink.accent : Ink.hairline, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: Radius.card))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(f.label + ", " + f.summary)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}
