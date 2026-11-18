import SwiftUI

/// Shown when hovering an underlined issue: what is wrong, what to do, and the author's ways to say no.
struct IssueCard: View {
    let issue: AutoProofreader.Issue
    let proof: AutoProofreader
    var startEditing = false
    let close: () -> Void
    @State private var custom = ""
    @State private var editing = false
    @FocusState private var fieldFocused: Bool

    private var fix: ProofFix { issue.fix }

    private var color: Color {
        fix.isObvious ? .red : (fix.isLanguageTool ? .blue : .purple)
    }

    private var source: String {
        fix.checkerName ?? L("AI proofreading", ctx: "Relecture par l’IA")
    }

    private var title: String {
        let r = fix.reason.isEmpty ? "Suggestion" : LocalProofreader.shown(fix.reason)
        return r.prefix(1).uppercased() + r.dropFirst()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(source).font(.ui(11)).foregroundStyle(.secondary)
                Spacer()
                Text(fix.isObvious ? "Correction" : "Suggestion").font(.ui(11)).foregroundStyle(color)
            }
            Text(title).font(.ui(13, .semibold))
            if let message = fix.message, !message.isEmpty, message != fix.reason {
                Text(message).font(.ui(12)).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("Recommendation")).font(.ui(11)).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(fix.original).strikethrough().foregroundStyle(.secondary)
                    Image(systemName: "arrow.right").font(.ui(11)).foregroundStyle(.tertiary)
                    Text(fix.replacement).fontWeight(.semibold)
                }
                if fix.isObvious {
                    Text(L("Corrected automatically when you leave this paragraph.")).font(.ui(11)).foregroundStyle(.secondary)
                }
                FlowButtons(choices: Array(fix.choices.prefix(5))) { choice in
                    proof.accept(issue, replacement: choice)
                    close()
                }
            }

            if editing {
                HStack {
                    TextField(L("Your correction"), text: $custom)
                        .textFieldStyle(.roundedBorder)
                        .focused($fieldFocused)
                        .onSubmit(applyCustom)
                    Button(L("Apply"), action: applyCustom).keyboardShortcut(.defaultAction)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                if !editing {
                    action(L("Correct It Myself…"), "pencil") { custom = fix.original; editing = true; fieldFocused = true }
                }
                action(L("Keep as Written"), "checkmark") { proof.ignore(fix); close() }
                let words = fix.changedWords
                if !words.isEmpty && words.count <= 3 {
                    action(L("Add « \(words.joined(separator: " ")) » to the book dictionary"), "book.closed") {
                        words.forEach(proof.learn)
                        close()
                    }
                }
                if fix.isLanguageTool, let rule = fix.rule {
                    action(L("Never Flag This Rule in This Book"), "nosign") { proof.disableRule(rule); close() }
                        .help(rule)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
        .onAppear {
            if startEditing { custom = fix.original; editing = true; fieldFocused = true }
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading) }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
    }

    private func applyCustom() {
        let value = custom
        guard !value.isEmpty, value != fix.original else { close(); return }
        proof.accept(issue, replacement: value)
        close()
    }
}

/// Replacement choices as buttons, the first one prominent. They wrap: a choice is never cut.
private struct FlowButtons: View {
    let choices: [String]
    let pick: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(choices.enumerated()), id: \.offset) { i, c in
                Button(i == 0 ? inQuotes(c) : c) { pick(c) }.buttonStyle(ChoiceStyle(prominent: i == 0))
            }
        }
    }
}

/// The system's bordered buttons stay on one line and cut what doesn't fit; this one lets its text wrap.
private struct ChoiceStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ui(12))
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(prominent ? Ink.onAccent : Color.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(prominent ? Ink.accent : Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: Radius.row))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Rectangle())
    }
}

/// The book's dictionary and the author's overrides, all removable.
struct ProofExceptionsSheet: View {
    let proof: AutoProofreader
    @Environment(\.dismiss) private var dismiss
    @State private var newWord = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Dictionary & Exceptions…").titled).font(.ui(15, .semibold))
            Text(L("Saved with this book in .musset/, in its history. The AI, LanguageTool and the spell checker all respect them."))
                .font(.ui(11)).foregroundStyle(.secondary)
            List {
                Section(L("Book dictionary (\(proof.dictionary.count))")) {
                    HStack {
                        TextField(L("Add a word"), text: $newWord).onSubmit(add)
                        Button(L("Add"), action: add).disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    ForEach(proof.dictionary.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { w in
                        row(w) { proof.unlearn(w) }
                    }
                }
                Section(L("Kept as written (\(proof.ignored.count))")) {
                    ForEach(proof.ignored.sorted(), id: \.self) { key in
                        row(key.replacingOccurrences(of: "→", with: "  ✕→  ")) { proof.unignore(key) }
                    }
                }
                Section(L("Grammar rules switched off (\(proof.disabledRules.count))")) {
                    ForEach(proof.disabledRules.sorted(), id: \.self) { rule in
                        row(rule) { proof.enableRule(rule) }
                    }
                }
            }
            .frame(minHeight: 340)
            HStack { Spacer(); Button(L("Done", ctx: "Terminé")) { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(18)
        .frame(width: 480)
    }

    private func row(_ text: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Text(text).lineLimit(1)
            Spacer()
            Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }.buttonStyle(.plain).help(L("Remove"))
        }
    }

    private func add() {
        let w = newWord.trimmingCharacters(in: .whitespaces)
        guard !w.isEmpty else { return }
        proof.learn(w)
        newWord = ""
    }
}
