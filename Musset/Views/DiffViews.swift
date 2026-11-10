import SwiftUI

struct CompareItem: Identifiable {
    let id = UUID()
    var title: String
    var left: String
    var right: String
}

/// Renders git's `--word-diff=plain` output ([-removed-] {+added+}) as attributed text.
enum WordDiff {
    static func attributed(_ diff: String) -> AttributedString {
        // Drop git's header lines (diff --git, index, ---, +++, @@).
        let body = diff.split(separator: "\n", omittingEmptySubsequences: false).drop { line in
            !line.hasPrefix("@@")
        }.dropFirst().joined(separator: "\n")
        var out = AttributedString()
        let re = try! NSRegularExpression(pattern: #"\[-(.*?)-\]|\{\+(.*?)\+\}"#, options: [.dotMatchesLineSeparators])
        let ns = body as NSString
        var cursor = 0
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > cursor { out += AttributedString(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))) }
            if m.range(at: 1).location != NSNotFound {
                var a = AttributedString(ns.substring(with: m.range(at: 1)))
                a.foregroundColor = .red
                a.strikethroughStyle = .single
                a.backgroundColor = .red.opacity(0.08)
                out += a
            } else {
                var a = AttributedString(ns.substring(with: m.range(at: 2)))
                a.foregroundColor = .green
                a.backgroundColor = .green.opacity(0.10)
                out += a
            }
            cursor = NSMaxRange(m.range)
        }
        if cursor < ns.length { out += AttributedString(ns.substring(from: cursor)) }
        if body.isEmpty { out = AttributedString(diff.isEmpty ? L("No differences.") : diff) }
        return out
    }

    /// Small "+12 / −30 words" summary.
    static func stats(_ diff: String) -> (added: Int, removed: Int) {
        func count(_ pattern: String) -> Int {
            let re = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
            return re.matches(in: diff, range: NSRange(diff.startIndex..., in: diff)).reduce(0) { acc, m in
                acc + ((diff as NSString).substring(with: m.range(at: 1)).split(whereSeparator: \.isWhitespace).count)
            }
        }
        return (count(#"\{\+(.*?)\+\}"#), count(#"\[-(.*?)-\]"#))
    }
}

struct CompareView: View {
    let item: CompareItem
    @Environment(\.dismiss) private var dismiss
    @State private var mode = 0
    @State private var diff: AttributedString?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.title).font(.ui(13, .semibold))
                Spacer()
                Picker("", selection: $mode) {
                    Text(L("Changes")).tag(0)
                    Text(L("Side by side")).tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Button(L("Done", ctx: "Terminé")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            if mode == 0 {
                ScrollView {
                    Group {
                        if let diff { Text(diff) } else { ProgressView() }
                    }
                    .font(.system(size: 14, design: .serif))
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: 720, alignment: .leading)
                    .padding(24)
                    .frame(maxWidth: .infinity)
                }
            } else {
                HStack(spacing: 0) {
                    pane(item.left)
                    Divider()
                    pane(item.right)
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            let l = item.left, r = item.right
            let raw = await Task.detached { GitService.wordDiff(l, r) }.value
            diff = WordDiff.attributed(raw)
        }
    }

    private func pane(_ text: String) -> some View {
        ScrollView {
            Text(text).font(.system(size: 13, design: .serif)).lineSpacing(4).textSelection(.enabled).padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
