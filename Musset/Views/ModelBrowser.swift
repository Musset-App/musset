import SwiftUI

/// Every model your own server lists (OpenRouter: hundreds), to search, filter by maker, price and tools, and choose one.
struct ModelBrowser: View {
    let config: EndpointConfig
    let key: String?
    /// The model chosen so far, selected when the list opens.
    let current: String
    let choose: (EndpointModel, [EndpointModel]) -> Void

    enum Sort: String, CaseIterable, Identifiable {
        case name, price, context, newest
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: L("Name")
            case .price: L("Price")
            case .context: L("Context")
            case .newest: L("Newest")
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    /// What the list shows: the models that can use tools.
    @State private var models: [EndpointModel] = []
    /// Everything the server lists, for the form's warnings.
    @State private var all: [EndpointModel] = []
    @State private var failure: String?
    @State private var query = ""
    @State private var provider = ""
    @State private var freeOnly = false
    @State private var sort: Sort = .name
    @State private var selection: String?

    /// Kept for the app's life, by address: opening the list again doesn't ask the server again.
    @MainActor private static var cache: [String: [EndpointModel]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Models on \(config.label)")).font(.ui(15, .semibold))
                if !models.isEmpty {
                    Text(L("\(shown.count) of \(models.count)")).font(.ui(12)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack(spacing: 10) {
                TextField(L("Search models"), text: $query).textFieldStyle(.roundedBorder).font(.ui(13))
                if !providers.isEmpty {
                    Picker("", selection: $provider) {
                        Text(L("All makers")).tag("")
                        Divider()
                        ForEach(providers, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 170)
                }
                Picker("", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden().frame(width: 110)
                .help(L("Sort"))
            }
            HStack(spacing: 16) {
                if hasPrices { Toggle(L("Free only"), isOn: $freeOnly).toggleStyle(.checkbox) }
                if left > 0 {
                    Text(L("\(left) models that can't use tools are left out: Musset's reader needs them.")).font(.ui(11)).foregroundStyle(.secondary)
                }
                Spacer()
                if hasPrices { Text(L("Price per million tokens: read · written")).font(.ui(11)).foregroundStyle(.secondary) }
            }
            .font(.ui(12))
            content
            HStack {
                Text(selected?.summary.firstSentence ?? "").font(.ui(11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.inkSecondary)
                Button(L("Choose")) { pick() }.buttonStyle(.ink).keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }
        .padding(18)
        .frame(width: 760, height: 560)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let failure {
            Text(failure).font(.ui(13)).foregroundStyle(Ink.error).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if models.isEmpty {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(L("Asking the server for its models…")) }
                .font(.ui(13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty {
            Text(L("No model matches")).font(.ui(13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            // A List, not a lazy stack: it's an NSTableView underneath and holds hundreds of rows without trouble.
            ScrollViewReader { proxy in
                List(shown, id: \.id, selection: $selection) { m in
                    row(m).tag(m.id).id(m.id)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: String.self) { _ in } primaryAction: { ids in
                    if let id = ids.first { selection = id; pick() }
                }
                // Opens on the model chosen so far.
                .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
            }
        }
    }

    private func row(_ m: EndpointModel) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(m.name).font(.ui(13, .medium)).lineLimit(1)
                    if m.id == config.defaultModel {
                        Text(L("default")).font(.ui(10, .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Ink.side, in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(m.id).font(.uiMono(11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(m.context.map { $0.formatted(.number.notation(.compactName)) } ?? "")
                .font(.uiMono(11)).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                .help(L("Tokens it reads at once"))
            price(m).frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 3)
        .help(m.summary)
    }

    @ViewBuilder private func price(_ m: EndpointModel) -> some View {
        if m.isFree {
            Text(L("Free")).font(.ui(11, .semibold)).foregroundStyle(Ink.positive)
        } else if let p = m.promptPrice, let c = m.completionPrice, p >= 0, c >= 0 {
            Text("\(Self.dollars(p)) · \(Self.dollars(c))").font(.uiMono(11))
        } else if m.promptPrice != nil {
            Text(L("Varies")).font(.ui(11)).foregroundStyle(.secondary)
        }
    }

    /// Per million tokens: « $0.08 », « $15 », « $0.0075 ».
    static func dollars(_ perToken: Double) -> String {
        let v = perToken * 1_000_000
        let precision: NumberFormatStyleConfiguration.Precision = v < 0.1 ? .significantDigits(1...2)
            : v == v.rounded() ? .fractionLength(0) : .fractionLength(2)
        return "$" + v.formatted(.number.locale(Locale(identifier: "en_US")).precision(precision))
    }

    // MARK: The list

    private var selected: EndpointModel? { models.first { $0.id == selection } }
    private var hasPrices: Bool { models.contains { $0.promptPrice != nil } }
    private var left: Int { all.count - models.count }

    private var providers: [String] {
        Array(Set(models.map(\.provider).filter { !$0.isEmpty })).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var shown: [EndpointModel] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let hits = models.filter { m in
            (provider.isEmpty || m.provider == provider)
                && (!freeOnly || m.isFree)
                && words.allSatisfy { m.id.lowercased().contains($0) || m.name.lowercased().contains($0) }
        }
        switch sort {
        case .name: return hits
        case .price: return hits.sorted { cost($0) < cost($1) }
        case .context: return hits.sorted { ($0.context ?? 0) > ($1.context ?? 0) }
        case .newest: return hits.sorted { ($0.created ?? .distantPast) > ($1.created ?? .distantPast) }
        }
    }

    /// What a typical reading costs: much more read than written. Unknown or variable prices go last.
    private func cost(_ m: EndpointModel) -> Double {
        guard let p = m.promptPrice, let c = m.completionPrice, p >= 0, c >= 0 else { return .infinity }
        return p * 4 + c
    }

    private func pick() {
        guard let m = selected else { return }
        choose(m, all)
        dismiss()
    }

    private func load() async {
        let address = config.baseURL
        if let cached = Self.cache[address], !cached.isEmpty { show(cached); return }
        do {
            let list = try await EndpointClient.models(config, key: key)
            Self.cache[address] = list
            show(list)
            if list.isEmpty { failure = L("The server lists no model.") }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func show(_ list: [EndpointModel]) {
        all = list
        models = list.filter(\.usable)
        if selection == nil { selection = list.first { $0.id == current }?.id }
    }
}

private extension String {
    /// The first sentence of a model's description, for the footer.
    var firstSentence: String {
        let flat = replacingOccurrences(of: "\n", with: " ")
        guard let end = flat.range(of: ". ") else { return flat }
        return String(flat[..<end.lowerBound]) + "."
    }
}
