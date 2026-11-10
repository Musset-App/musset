import SwiftUI

/// « Try something else »: two questions, and the book keeps its version until one chooses.
struct TryVersionSheet: View {
    let session: BookSession
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var name = ""
    @State private var blank = false

    private var first: Bool { session.versions.count <= 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Try Something Else")).font(.ui(15, .semibold))
                Text(L("The book keeps « \(BookSession.versionLabel(session.selectedChapter?.activeVersion ?? "")) » until you choose. Nothing is erased."))
                    .font(.ui(12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if first {
                field(L("What you wrote will be called"), $current, prompt: L("First version"))
            }
            field(L("The new one"), $name, prompt: L("Version"))
            VStack(alignment: .leading, spacing: 8) {
                Text(L("It starts from")).font(.ui(12)).foregroundStyle(.secondary)
                choice(L("A copy of what I wrote"), L("Keep the beginning, change what follows"), on: !blank) { blank = false }
                choice(L("A blank page"), L("The other one stays beside it, to look at"), on: blank) { blank = true }
            }
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.inkSecondary)
                Button(L("Start")) { start() }.keyboardShortcut(.defaultAction).buttonStyle(.ink)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let ch = session.selectedChapter, ch.activeVersion != "main" { current = ch.activeVersion }
            if let ch = session.selectedChapter { name = session.store.uniqueVersionName(ch, base: L("Version \(session.versions.count + 1)")) }
        }
    }

    private func field(_ title: String, _ value: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.ui(12)).foregroundStyle(.secondary)
            TextField("", text: value, prompt: Text(prompt)).textFieldStyle(.roundedBorder)
        }
    }

    private func choice(_ title: String, _ hint: String, on: Bool, pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Ink.accent : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(hint).font(.ui(12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(on ? Ink.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Ink.accent.opacity(0.6) : Ink.hairline))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func start() {
        let previous = session.editingVersion
        session.tryAnotherVersion(named: name.trimmingCharacters(in: .whitespaces), blank: blank,
                                  currentName: first ? current : nil)
        // A blank page: what was written stays beside it.
        if blank, let previous, let ch = session.selectedChapter {
            let renamed = session.versions.contains(previous) ? previous : ch.activeVersion
            session.showBeside(renamed)
        }
        dismiss()
    }
}

/// After « Put in the book »: said once, with the way back.
struct VersionSwitchToast: View {
    let session: BookSession

    var body: some View {
        if let s = session.lastVersionSwitch {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Ink.added)
                Text(L("« \(BookSession.versionLabel(s.name)) » is now in the book. « \(BookSession.versionLabel(s.previous)) » stays here."))
                    .lineLimit(1)
                Button(L("Undo")) { session.undoVersionSwitch() }.buttonStyle(.link)
            }
            .font(.ui(13))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Ink.hairline))
            .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            .padding(.bottom, 28)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
            .task(id: s) {
                try? await Task.sleep(for: .seconds(8))
                if session.lastVersionSwitch == s { withAnimation { session.lastVersionSwitch = nil } }
            }
        }
    }
}
