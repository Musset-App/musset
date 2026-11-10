import SwiftUI
import UniformTypeIdentifiers

/// An editor's corrected Word file: what it brings, chapter by chapter, before anything changes.
struct WordReviewSheet: View {
    let app: AppState
    let session: BookSession
    let bridge: EditorBridge
    @Environment(\.dismiss) private var dismiss
    @State private var plan: WordReview.Plan?
    @State private var reading = false
    @State private var error: String?
    @State private var dropping = false
    /// Who this comes from: what the corrections and notes are signed with, and filtered by.
    @State private var sender = ""
    @FocusState private var naming: Bool

    private var senderIsEmpty: Bool { sender.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Bring in a corrected Word file")).font(.ui(16, .semibold))
            if let plan { summary(plan) } else { chooser }
            if let error { Text(error).font(.ui(12)).foregroundStyle(.red).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.buttonStyle(.inkSecondary).keyboardShortcut(.cancelAction)
                if let plan {
                    Button(L("Bring in")) { apply(plan) }.buttonStyle(.ink).keyboardShortcut(.defaultAction)
                        .disabled(plan.placed + plan.unplaced + plan.noteCount == 0 || senderIsEmpty)
                }
            }
        }
        .font(.ui(13))
        .padding(22)
        .frame(width: 520)
    }

    private var chooser: some View {
        VStack(spacing: 10) {
            if reading {
                ProgressView().controlSize(.small)
                Text(L("Reading the file…")).foregroundStyle(.secondary)
            } else {
                Text(L("Drop the .docx your editor sent back")).foregroundStyle(.secondary)
                Button(L("Choose a file…")) { choose() }.buttonStyle(.inkSecondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 130)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(dropping ? Ink.accent : Ink.hairline, style: StrokeStyle(lineWidth: dropping ? 2 : 1, dash: dropping ? [] : [5])))
        .dropDestination(for: URL.self, action: { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "docx" }) else { return false }
            read(url)
            return true
        }, isTargeted: { dropping = $0 })
    }

    @ViewBuilder private func summary(_ plan: WordReview.Plan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(plan.fileName).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
            Text(origin(plan)).font(.ui(12)).foregroundStyle(.secondary)
            if !plan.readers.isEmpty {
                Text(L("Word says: ") + plan.readers.keys.sorted().joined(separator: ", ")).font(.ui(12)).foregroundStyle(.secondary)
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(L("From", ctx: "Expéditeur")).font(.ui(11, .medium)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField(L("Who sent this file?"), text: $sender)
                    .textFieldStyle(.roundedBorder).focused($naming)
                if !session.knownSenders.isEmpty {
                    Menu {
                        ForEach(session.knownSenders, id: \.self) { name in Button(name) { sender = name } }
                    } label: { Image(systemName: "chevron.down").font(.ui(10)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help(L("Someone who already sent corrections"))
                }
            }
        }
        HStack(spacing: 22) {
            figure(plan.placed, L("corrections to decide"))
            figure(plan.noteCount, L("comments as notes"))
            if plan.unplaced > 0 { figure(plan.unplaced, L("to place by hand")) }
        }
        if let date = plan.previousImport {
            warning(L("Already brought in on \(date.formatted(date: .abbreviated, time: .omitted)). Bringing it in again adds what isn't there yet."))
        }
        if plan.sent == nil {
            warning(L("This file wasn't recognised as one of this book's exports: only its tracked changes count."))
        }
        ScrollView {
            VStack(spacing: 0) {
                ForEach(plan.chapters.filter { $0.placed + $0.unplaced.count + $0.notes.count > 0 }) { c in
                    HStack(spacing: 10) {
                        Text(c.title).lineLimit(1)
                        if plan.changedSince.contains(c.id) {
                            Text(L("rewritten since")).font(.ui(11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Text(counts(c)).font(.ui(12).monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(height: 28)
                    Divider()
                }
            }
        }
        .frame(maxHeight: 240)
        Text(L("A milestone is set first. Each correction is then yours to accept or refuse in the text; nothing prints until you do."))
            .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func figure(_ n: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(n)").font(.ui(20, .medium).monospacedDigit())
            Text(label).font(.ui(11)).foregroundStyle(.secondary)
        }
    }

    private func warning(_ text: String) -> some View {
        Text(text).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.side, in: RoundedRectangle(cornerRadius: 8))
    }

    private func origin(_ plan: WordReview.Plan) -> String {
        guard let sent = plan.sent else { return L("Origin unknown") }
        return L("Exported on ") + sent.date.formatted(date: .long, time: .omitted)
    }

    private func counts(_ c: WordReview.ChapterPlan) -> String {
        var parts: [String] = []
        if c.placed > 0 { parts.append("\(c.placed) " + L("corr.")) }
        if !c.notes.isEmpty { parts.append("\(c.notes.count) " + L("notes")) }
        if !c.unplaced.isEmpty { parts.append("\(c.unplaced.count) " + L("by hand")) }
        return parts.joined(separator: " · ")
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "docx") ?? .data]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { read(url) }
    }

    private func read(_ url: URL) {
        reading = true
        error = nil
        Task {
            do {
                let read = try await session.wordReviewPlan(url)
                sender = read.suggestedSender ?? ""
                plan = read
                naming = true
            }
            catch { self.error = error.localizedDescription }
            reading = false
        }
    }

    private func apply(_ plan: WordReview.Plan) {
        session.applyWordReview(plan, sender: sender)
        bridge.refreshHighlights()
        // To the first chapter that now has something to decide.
        if let first = plan.chapters.first(where: { $0.placed > 0 }), first.id != session.selectedChapterID {
            app.leaveBookPages()
            session.open(first.id)
        }
        dismiss()
    }
}
