import SwiftUI

/// The book's rubric: a preset to start from, the promise, the weights, the author's own requirements.
struct BaremeSheet: View {
    let session: BookSession
    var onSave: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var bareme: Bareme?
    @State private var original: Bareme?
    @State private var thresholdText = ""
    @State private var open: String?
    private let library = ScoringLibrary.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Rubric") + " — \(session.title)").font(.ui(15, .semibold))
            if bareme != nil { form } else {
                Text(L("The criteria library could not be read.")).foregroundStyle(.orange)
            }
            HStack {
                if let warning { Text(warning).font(.ui(11)).foregroundStyle(.orange).lineLimit(2) }
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.inkSecondary)
                Button(L("Save"), action: save).buttonStyle(.ink).keyboardShortcut(.defaultAction).disabled(bareme?.chapter.isEmpty ?? true)
            }
        }
        .padding(18)
        .frame(width: 720, height: 680)
        .onAppear {
            bareme = Bareme.forBook(session.root)
            original = bareme
            thresholdText = bareme?.threshold.map { "\(Int($0))" } ?? ""
        }
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    label(L("Start from"))
                    Picker("", selection: Binding(get: { bareme?.presetId ?? "" }, set: { id in
                        if let p = library.presets.first(where: { $0.id == id }) { bareme?.adopt(p); open = nil }
                    })) {
                        ForEach(library.presets) { Text($0.name).tag($0.id) }
                        if bareme?.presetId == nil { Text(L("Own grid")).tag("") }
                    }
                    .labelsHidden().fixedSize()
                    Spacer()
                    label(L("Threshold"))
                    TextField("", text: $thresholdText).textFieldStyle(.roundedBorder).frame(width: 48)
                }
                VStack(alignment: .leading, spacing: 4) {
                    label(L("What the book promises"))
                    TextField("", text: Binding(get: { bareme?.contract ?? "" }, set: { bareme?.contract = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.ui(12))
                }
                VStack(alignment: .leading, spacing: 4) {
                    label(L("How demanding: a known book and what it would score"))
                    TextField(L("Dracula would score 85/100 on this rubric."), text: Binding(get: { bareme?.calibration ?? "" }, set: { bareme?.calibration = $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(.ui(12))
                }
                grid
                VStack(alignment: .leading, spacing: 4) {
                    label(L("Your requirements (eliminatory risks, scoring discipline)"))
                    TextEditor(text: Binding(get: { bareme?.rules ?? "" }, set: { bareme?.rules = $0 }))
                        .font(.ui(12)).frame(height: 140).scrollContentBackground(.hidden)
                        .padding(6).background(Ink.panel, in: RoundedRectangle(cornerRadius: 7))
                }
            }
            .padding(.trailing, 8)
        }
    }

    private var grid: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                label(L("Chapter grid"))
                Spacer()
                let sum = bareme?.chapter.reduce(0) { $0 + $1.weight } ?? 0
                Text("\(sum) " + L("points, brought to 100 on saving")).font(.ui(11).monospacedDigit()).foregroundStyle(sum == 100 ? Color.secondary : Color.orange)
            }
            ForEach(bareme?.chapter ?? [], id: \.criterionId) { item in row(item) }
            Menu(L("Add a criterion")) {
                ForEach(ScoringLibrary.families, id: \.self) { family in
                    let free = library.chapterCriteria.filter { c in c.family == family && !(bareme?.chapter.contains { $0.criterionId == c.id } ?? false) }
                    if !free.isEmpty {
                        Menu(familyLabel(family)) {
                            ForEach(free) { c in Button(c.label) { bareme?.chapter.append(.init(criterionId: c.id, weight: 5)); bareme?.presetId = nil } }
                        }
                    }
                }
            }
            .fixedSize().font(.ui(12))
        }
    }

    /// `family` is a key of the criteria library, shown in the interface's language.
    private func familyLabel(_ family: String) -> String {
        switch family {
        case "langue": L("Language")
        case "structure": L("Structure")
        case "personnages": L("Characters")
        case "monde": L("World")
        case "idee": L("Ideas")
        case "affect": L("Emotion")
        case "meta": L("Meta")
        default: family.capitalized
        }
    }

    private func row(_ item: WeightedCriterion) -> some View {
        let c = bareme?.criterion(item.criterionId, library: library)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button { open = open == item.criterionId ? nil : item.criterionId } label: {
                    HStack(spacing: 5) {
                        Image(systemName: open == item.criterionId ? "chevron.down" : "chevron.right").font(.ui(9)).foregroundStyle(.tertiary)
                        Text(c?.label ?? item.criterionId).font(.ui(12)).lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(c?.definition ?? "")
                Spacer()
                TextField("", value: Binding(get: { item.weight }, set: { setWeight(item.criterionId, $0) }), format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 46).multilineTextAlignment(.trailing)
                Button { bareme?.chapter.removeAll { $0.criterionId == item.criterionId }; bareme?.presetId = nil } label: { Image(systemName: "xmark").font(.ui(10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Remove"))
            }
            if open == item.criterionId, let c {
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.definition).font(.ui(11)).foregroundStyle(.secondary)
                    ForEach(["5", "10", "15", "19"], id: \.self) { k in
                        Text("\(k)/20 : \(c.anchors?[k] ?? "")").font(.ui(11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private func label(_ s: String) -> some View { Text(s).font(.ui(11, .medium)).foregroundStyle(.secondary) }

    private func setWeight(_ id: String, _ weight: Int) {
        guard let i = bareme?.chapter.firstIndex(where: { $0.criterionId == id }), weight != bareme?.chapter[i].weight else { return }
        bareme?.chapter[i].weight = max(0, weight)
        bareme?.presetId = nil
    }

    /// The spec's guard rails: they warn, the author decides.
    private var warning: String? {
        guard let items = bareme?.chapter, !items.isEmpty else { return nil }
        if items.count > 10 { return L("More than 10 criteria: each one weighs little.") }
        if let c = items.first(where: { $0.weight > 40 }) { return L("\(c.criterionId) above 40 points: the grid hangs on one criterion.") }
        if items.contains(where: { $0.weight < 3 }) { return L("A weight under 3 points is below the noise of scoring.") }
        return nil
    }

    private func save() {
        guard var b = bareme else { return }
        let normalized = Scoring.normalize(Dictionary(uniqueKeysWithValues: b.chapter.map { ($0.criterionId, Double($0.weight)) }))
        b.chapter = b.chapter.compactMap { i in normalized[i.criterionId].map { .init(criterionId: i.criterionId, weight: $0) } }
        b.threshold = Double(thresholdText.trimmingCharacters(in: .whitespaces))
        // Only a change of grid makes a new version: readings under another version are not directly comparable.
        if b.chapter != original?.chapter { b.version = (original?.version ?? 0) + 1 }
        do {
            try b.save(session.root)
            session.pendingCommit = true
            onSave()
            dismiss()
        } catch { session.lastError = error.localizedDescription }
    }
}
