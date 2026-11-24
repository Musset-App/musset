import SwiftUI

/// One calm line at the foot of the window: said once, gone by itself.
struct FirstNotice: Equatable, Identifiable {
    enum Action: Equatable { case read }
    let id = UUID()
    var text: String
    var action: Action? = nil
}

/// The first days with Musset. Nothing is offered before there is something written to offer it on: the first run
/// is a title and a page. What Musset does on its own (keeping every version) is said once, when it has just done it;
/// the AI readers and Musset Sync are offered on a later visit, to a book that has some pages.
extension AppState {
    private static let launches = "launches"

    /// Counted at each start of the app. Someone who had books before this version has had their first days.
    func countLaunch() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.launches) == nil, !libraryPaths.isEmpty {
            for key in ["said.kept", "said.read", "helpersOffered", "syncOffered"] { d.set(true, forKey: key) }
        }
        d.set(d.integer(forKey: Self.launches) + 1, forKey: Self.launches)
    }

    func say(_ text: String, action: FirstNotice.Action? = nil) {
        notice = FirstNotice(text: text, action: action)
    }

    func run(_ action: FirstNotice.Action) {
        notice = nil
        switch action {
        case .read: showAsBook(quietly: true)
        }
    }

    /// The whole book, typeset: where an import ends, since that is what no word processor showed its author.
    func showAsBook(quietly: Bool = false) {
        review.scope = .book
        if activeTab?.special != nil || activeTab?.overview != nil { showChapter() }
        reviewMode = true
        if !quietly { say(L("Your book, as it will print. Write, at the top, takes you back to the text.")) }
    }

    /// The book's word count moved. Only typing counts: a book imported or opened arrives with its words.
    func wordsChanged(from old: Int, to new: Int, in session: BookSession) {
        guard new > old, new - old <= 200, !ExampleBook.isExample(session.root) else { return }
        let d = UserDefaults.standard
        if new >= 25, !d.bool(forKey: "said.kept") {
            d.set(true, forKey: "said.kept")
            say(L("Every version of this book is kept as you write. There is nothing to save."))
        } else if new >= 300, !d.bool(forKey: "said.read") {
            d.set(true, forKey: "said.read")
            say(L("Three hundred words. See them as a printed page."), action: .read)
        }
    }

    /// On a later visit, to a book with pages in it: the AI readers once, then, another day, Musset Sync once.
    func considerOffers() {
        guard let s = current, !showHome, !showHelpers, !showSyncOffer, !showNewBook, !ExampleBook.isExample(s.root) else { return }
        let d = UserDefaults.standard
        let launches = d.integer(forKey: Self.launches), words = s.bookCounts.words
        if launches >= 2, words >= 250, !d.bool(forKey: "helpersSeen"), !d.bool(forKey: "helpersOffered"), !AIStatus.shared.isOn {
            d.set(true, forKey: "helpersOffered")
            showHelpers = true
        } else if launches >= 3, words >= 1000, !d.bool(forKey: "syncOffered"),
                  !Collab.shared.canSync, !Collab.shared.isLocalOnly(s), !s.repoStatus.linked {
            d.set(true, forKey: "syncOffered")
            offerSync(for: s)
        }
    }
}

/// The notice, at the foot of the window.
struct FirstNoticeView: View {
    @Bindable var app: AppState
    var body: some View {
        ZStack {
            if let notice = app.notice {
                HStack(spacing: 12) {
                    Text(notice.text)
                    if let action = notice.action {
                        Button(label(action)) { app.run(action) }.buttonStyle(.link)
                    }
                    Button { app.notice = nil } label: { Image(systemName: "xmark").font(.ui(10)) }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel(L("Close"))
                }
                .font(.ui(13))
                .padding(.horizontal, 16).frame(height: 38)
                .background(Ink.panel, in: Capsule())
                .overlay(Capsule().strokeBorder(Ink.hairline))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
                // Above the status line, and above the strip of pages when the book is read.
                .padding(.bottom, app.reviewMode ? 108 : 54)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(10))
                    if app.notice?.id == notice.id { app.notice = nil }
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: app.notice)
    }

    private func label(_ action: FirstNotice.Action) -> String {
        switch action {
        case .read: L("Read")
        }
    }
}

/// An empty first page says where to begin, and goes at the first word.
struct EmptyPageHint: View {
    let session: BookSession
    private var empty: Bool {
        guard session.manifest.chapters.count == 1, session.text.utf8.count < 240 else { return false }
        return !session.text.split(separator: "\n").contains { !$0.hasPrefix("#") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
    var body: some View {
        if empty {
            Text(L("The page is yours. Write the first sentence; Musset keeps the rest in order."))
                .font(.ui(13)).foregroundStyle(.tertiary)
                .padding(.bottom, 60)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}
