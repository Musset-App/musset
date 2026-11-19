import SwiftUI

/// The first chapter of a book is done. Musset says nothing while the author writes, and speaks this once:
/// what comes next, a first reading, a first reader, and (if the book is on this Mac only) that it could be lost.
struct ChapterDoneCard: View {
    let app: AppState
    let session: BookSession
    let chapterID: String
    @Environment(\.dismiss) private var dismiss
    private var collab: Collab { .shared }

    private var words: Int { session.chapterCounts[chapterID]?.words ?? 0 }
    private var title: String { session.manifest.chapters.first { $0.id == chapterID }?.title ?? "" }
    private var synced: Bool { collab.link(session.git) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("\(title) is written.")).font(.system(size: 26, design: .serif))
            Text(L("\(words.ui) words. Every version is kept.")).foregroundStyle(.secondary).padding(.top, 6)
            VStack(spacing: 8) {
                action(session.words.startNextPiece, L("While the voice of this one is still in your ear."), icon: "plus", primary: true) {
                    dismiss()
                    session.addChapter(title: nextTitle)
                }
                action(L("Ask for a first AI reading"), L("Voices read it as a first draft, rate it out of five, then debate with you."), icon: "bubble.left.and.bubble.right") {
                    dismiss()
                    if session.selectedChapterID != chapterID { session.open(chapterID) }
                    app.open(.debate)
                }
                action(L("Share it with a first reader"),
                       collab.canSync ? L("They read and annotate in their own Musset; their notes come back into your margin. They don’t pay.")
                                      : L("Musset Sync: they read and annotate in their own Musset, and don’t pay."), icon: "person.badge.plus", sync: !collab.canSync) {
                    if collab.canSync { app.showReaders(inviting: true) }
                    else { later { app.offerSync(for: session) } }
                }
            }
            .padding(.top, 20)
            if !synced {
                HStack(spacing: 10) {
                    Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
                    Text(L("These \(words.ui) words exist only on this Mac.")).font(.ui(12)).foregroundStyle(.secondary)
                    Spacer()
                    Button(L("Keep them safe")) { later { app.offerSync(for: session) } }.buttonStyle(.link).font(.ui(12, .medium))
                }
                .padding(.top, 14).padding(.top, 2)
                .overlay(alignment: .top) { Divider() }
                .padding(.top, 16)
            }
            Button(L("Back to the text")) { dismiss() }.buttonStyle(.plain).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity).padding(.top, 12).keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(width: 460)
        .font(.ui(13))
    }

    private var nextTitle: String {
        session.manifest.newPieceTitle(session.manifest.chapters.count + 1)
    }

    /// Closes the card first: one sheet at a time.
    private func later(_ then: @escaping () -> Void) {
        dismiss()
        Task { @MainActor in try? await Task.sleep(nanoseconds: 400_000_000); then() }
    }

    private func action(_ title: String, _ text: String, icon: String, primary: Bool = false, sync: Bool = false, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 18).foregroundStyle(primary ? Ink.onPrimary : (sync ? Ink.accent : .secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium).foregroundStyle(primary ? Ink.onPrimary : .primary)
                    Text(text).font(.ui(12)).foregroundStyle(primary ? Ink.onPrimary.opacity(0.75) : .secondary)
                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if sync { Text("SYNC").font(.ui(10, .semibold)).foregroundStyle(Ink.accent) }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(primary ? Color.primary : (sync ? Ink.accent.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).strokeBorder(primary ? .clear : (sync ? Ink.accent.opacity(0.25) : Ink.hairline)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
