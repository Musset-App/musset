import SwiftUI

/// The menu over a selection: the inks (or the reader's own), Underline, Note, and Suggest for an editor.
struct SelectionMenu: View {
    @Bindable var model: ReaderModel
    @State private var writing: Writing?
    @State private var text = ""
    @FocusState private var focused: Bool

    enum Writing { case note, suggestion }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                if let own = model.ownInk {
                    Button { model.perform(.highlight(own)) } label: {
                        HStack(spacing: 6) {
                            Circle().fill(own.color).frame(width: 12, height: 12)
                            Text(model.strings.highlight).font(.system(size: 12))
                        }
                        .padding(.horizontal, 8).frame(height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    ForEach(Ink.allCases) { ink in
                        Button { model.perform(.highlight(ink)) } label: {
                            Circle().fill(ink.color).frame(width: 14, height: 14)
                                .frame(width: 28, height: 28).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(ink.name)
                    }
                    Rectangle().fill(Color(rgb: 0x4A4943)).frame(width: 1, height: 18).padding(.horizontal, 4)
                }
                item(model.strings.underline) { model.perform(.underline) }
                item(model.strings.note, on: writing == .note) { start(.note) }
                if model.canSuggest {
                    item(model.strings.suggest, on: writing == .suggestion) { start(.suggestion) }
                }
            }
            if let writing {
                HStack(spacing: 6) {
                    TextField(writing == .note ? model.strings.notePlaceholder : model.strings.suggestPlaceholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...4)
                        .focused($focused)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                        .onSubmit(send)
                    item(model.strings.add, on: true, action: send)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(width: 300)
            }
        }
        .padding(6)
        .foregroundStyle(.white)
        .background(Color(rgb: 0x1A1A18), in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.strings.markSelection)
    }

    func item(_ title: String, on: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 12)).padding(.horizontal, 8).frame(height: 28)
                .background(on ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    func start(_ w: Writing) {
        writing = w
        text = w == .suggestion ? (model.selectedText?.text ?? "") : ""
        focused = true
    }

    func send() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, let writing else { return }
        model.perform(writing == .note ? .note(t) : .suggest(t))
    }
}

/// The book's pages in small, the ones shown outlined, a line of ink on the ones that hold a mark.
struct ThumbnailStrip: View {
    @Bindable var model: ReaderModel

    var body: some View {
        let shown = Set(model.visiblePages.compactMap { $0 })
        let marked = model.markedPages
        let count = model.book?.pageCount ?? 0
        HStack(spacing: 12) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    // Not lazy: a few hundred small views, and lazy stacks have frozen Musset before.
                    HStack(spacing: 6) {
                        ForEach(0..<count, id: \.self) { i in
                            thumb(i, shown: shown.contains(i), mark: marked[i]).id(i)
                        }
                    }
                    .padding(.horizontal, 16).padding(.vertical, 8)
                }
                .onChange(of: model.page) { _, p in withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(p, anchor: .center) } }
                .onAppear { proxy.scrollTo(model.page, anchor: .center) }
            }
            Text(model.pageLabel)
                .font(.system(size: 12)).monospacedDigit()
                .foregroundStyle(Color(rgb: model.theme.ink, opacity: 0.7))
                .padding(.trailing, 16)
                .fixedSize()
        }
        .frame(height: 60)
    }

    func thumb(_ i: Int, shown: Bool, mark: Ink?) -> some View {
        let size = model.book?.pageSizes[i] ?? CGSize(width: 2, height: 3)
        let h: CGFloat = 36, w = (h * size.width / max(size.height, 1)).rounded()
        return Button { model.go(to: i) } label: {
            ZStack(alignment: .top) {
                Color(rgb: model.theme.paper)
                if let image = model.thumbnails[i] {
                    Image(decorative: image, scale: 1).resizable().interpolation(.medium)
                }
                if let mark {
                    Rectangle().fill(mark.color).frame(height: 2).padding(.horizontal, 3).padding(.top, 5)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.08)))
            .padding(2)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(rgb: 0x2E4AC7), lineWidth: shown ? 2 : 0))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.strings.pages(i + 1, i + 1, model.book?.pageCount ?? 0))
    }
}

/// Text size and night, for the host's toolbar.
public struct ReaderControls: View {
    @Bindable var model: ReaderModel

    public init(model: ReaderModel) { self.model = model }

    public var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach([14.0, 15, 16, 17, 18, 20, 22, 25], id: \.self) { s in
                    Button { model.textSize = s } label: {
                        if s == model.textSize { Label("\(Int(s)) pt", systemImage: "checkmark") } else { Text("\(Int(s)) pt") }
                    }
                }
            } label: {
                Text("Aa")
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(model.strings.textSize)
            Toggle(isOn: Binding(get: { model.theme.isNight }, set: { model.theme = $0 ? .night : .day })) {
                Image(systemName: "moon")
            }
            .toggleStyle(.button)
            .accessibilityLabel(model.strings.night)
        }
    }
}
