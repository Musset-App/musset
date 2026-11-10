import SwiftUI

enum InspectorTab: String, CaseIterable, Identifiable {
    // The raw values of the first three are the ones already remembered from before the tabs were renamed.
    case edits = "notes", chat, stats = "language", plan, history
    var id: String { rawValue }
    var label: String {
        switch self {
        case .edits: L("Notes")
        case .chat: L("Chat")
        case .stats: L("Stats")
        case .plan: L("Plan")
        case .history: L("History")
        }
    }
    var icon: String {
        switch self {
        case .edits: "checklist"
        case .chat: "bubble.left.and.text.bubble.right"
        case .stats: "chart.bar"
        case .plan: "list.bullet.indent"
        case .history: "clock.arrow.circlepath"
        }
    }
    var shortcut: String {
        switch self {
        case .edits: "⌘2"
        case .chat: "⌘3"
        case .stats: "⌘4"
        case .plan: "⌘6"
        case .history: "⌘7"
        }
    }
}

/// The right-hand column: one resizable panel, one tab at a time.
struct InspectorPanel: View {
    @Bindable var app: AppState
    let session: BookSession
    let bridge: EditorBridge
    let chat: ChatModel
    let pangram: PangramModel
    let proof: AutoProofreader
    let annotator: Annotator
    let analyst: PlotAnalyst
    let planner: ScenePlanner

    var body: some View {
        VStack(spacing: 0) {
            // Without AI, no chat.
            let ai = AIStatus.shared.isOn
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases.filter { ai || $0 != .chat }) { tab in tabButton(tab) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).frame(height: 44)
            Divider()
            switch app.inspectorTab == .chat && !ai ? .edits : app.inspectorTab {
            case .edits: NotesPanel(app: app, session: session, bridge: bridge, annotator: annotator, proof: proof)
            case .chat: ChatPanel(chat: chat, session: session, bridge: bridge)
            case .stats: StatsPanel(session: session, bridge: bridge, pangram: pangram, reader: chat.reader)
            case .plan: PlanPanel(app: app, session: session, bridge: bridge, analyst: analyst, planner: planner)
            case .history: HistoryPanel(app: app, session: session, bridge: bridge)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func tabButton(_ tab: InspectorTab) -> some View {
        let on = app.inspectorTab == tab
        return Button { app.inspectorTab = tab } label: {
            HStack(spacing: 6) {
                Image(systemName: tab.icon).font(.ui(13))
                if on { Text(tab.label).font(.ui(12, .medium)).lineLimit(1).fixedSize() }
            }
            .foregroundStyle(on ? .primary : .secondary)
            .padding(.horizontal, 9).frame(minWidth: 34, minHeight: 30)
            .background(on ? Ink.selected : .clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(tab.label) (\(tab.shortcut))")
        .accessibilityLabel(tab.label)
    }
}
