import SwiftUI

// A strand is a thread running through the book: a period, a narrator, a place (`BookStructure.Strand`). Here is
// how the interface draws one and lets a piece follow one; the Overview's legend and its filter are with its bars
// (`BookNumbersHeader`). An author's tool: nothing here reaches a PDF, a Word file, an EPUB or the reader.

extension BookStructure.Strand {
    /// The name as lists write it; a strand not named yet still has something to be called by.
    var shownName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? L("Untitled") : typed
    }
}

/// A strand's mark: a small rounded square in its colour. A square, where a status is a dot, and a hairline round
/// it: a pale colour still shows on a light ground, a deep one on a dark ground.
struct StrandMark: View {
    /// "#8FA3FF"; nil is the grey of the pieces that follow no strand.
    let colour: String?
    var size: CGFloat = 8

    /// The grey of « No strand », in bars and legends.
    static let none = Color.primary.opacity(0.2)
    static let edge = Color.primary.opacity(0.3)

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size / 4)
        shape.fill(colour.map { Color(hex: $0) } ?? Self.none)
            .overlay(shape.strokeBorder(Self.edge, lineWidth: 0.5))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    /// The mark as a menu takes it: a menu's item keeps an image, not a shape.
    static func image(_ hex: String) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(Color(hex: hex)).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
            return true
        }
    }
}

/// « Strand › 1943 ✓ / Aujourd’hui / None / New Strand… »: in the menu of a piece, wherever it is listed.
struct StrandMenu: View {
    let session: BookSession
    let chapters: [String]
    /// Asks for the name of a new strand these pieces will follow.
    let new: ([String]) -> Void

    var body: some View {
        let m = session.manifest
        let ids = Set(chapters)
        // What the pieces follow now: one strand for all of them, none, or a mix (nothing ticked).
        let current = Set(m.chapters.filter { ids.contains($0.id) }.map { m.strand(of: $0)?.id })
        Menu(L("Strand")) {
            ForEach(m.strands) { strand in
                Toggle(isOn: Binding(get: { current == [strand.id] }, set: { _ in session.setStrand(strand.id, for: chapters) })) {
                    Label { Text(strand.shownName) } icon: { Image(nsImage: StrandMark.image(strand.colour)) }
                }
            }
            if !m.strands.isEmpty {
                Divider()
                Toggle(L("None", ctx: "Aucun"), isOn: Binding(get: { current == [nil] }, set: { _ in session.setStrand(nil, for: chapters) }))
                Divider()
            }
            Button(L("New Strand…")) { new(chapters) }
        }
    }
}

private struct NewStrandAlert: ViewModifier {
    @Binding var chapters: [String]?
    let session: BookSession
    @State private var name = ""

    func body(content: Content) -> some View {
        content.alert(L("New strand"), isPresented: Binding(get: { chapters != nil }, set: { if !$0 { chapters = nil; name = "" } })) {
            TextField(L("Name of the strand"), text: $name)
            Button(L("Create")) {
                session.newStrand(named: name, for: chapters ?? [])
                chapters = nil
                name = ""
            }
            Button(L("Cancel"), role: .cancel) { chapters = nil; name = "" }
        } message: {
            Text(L("A period, a narrator, a place."))
        }
    }
}

extension View {
    /// The one question « New Strand… » asks: its name. Its colour is the next of the palette, and the pieces
    /// in `chapters` follow it.
    func newStrandAlert(for chapters: Binding<[String]?>, session: BookSession) -> some View {
        modifier(NewStrandAlert(chapters: chapters, session: session))
    }
}
