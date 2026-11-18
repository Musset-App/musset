import SwiftUI

/// Renders an agent's Markdown answer: headings, paragraphs, lists, quotes, code blocks, rules,
/// with inline bold, italics, code and links. Selectable.
struct MarkdownText: View {
    let text: String
    /// Body size in points; headings and code scale from it.
    var size: Double = 15

    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case bullet([String])
        case numbered([String])
        case quote(String)
        case code(String, lang: String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                view(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func view(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let s):
            Text(Self.inline(s)).font(.ui(size * (level == 1 ? 1.3 : level == 2 ? 1.15 : 1.05), .semibold)).padding(.top, 4)
        case .paragraph(let s):
            Text(Self.inline(s)).font(.ui(size)).lineSpacing(size * 0.25).fixedSize(horizontal: false, vertical: true)
        case .bullet(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(Self.inline(item)).font(.ui(size)).lineSpacing(size * 0.2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(i + 1).").font(.ui(size)).foregroundStyle(.secondary).monospacedDigit()
                        Text(Self.inline(item)).font(.ui(size)).lineSpacing(size * 0.2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        case .quote(let s):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.secondary.opacity(0.4)).frame(width: 3)
                Text(Self.inline(s)).font(.ui(size)).italic().foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .code(let s, let lang):
            VStack(alignment: .leading, spacing: 4) {
                if !lang.isEmpty { Text(lang).font(.ui(10)).foregroundStyle(.secondary) }
                Text(s).font(.uiMono(size * 0.88)).fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.row))
        case .rule:
            Divider()
        }
    }

    static func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }

    static func blocks(_ text: String) -> [Block] {
        var out: [Block] = []
        var para: [String] = []
        var bullets: [String] = [], numbers: [String] = [], quote: [String] = []
        var code: [String]? = nil
        var codeLang = ""
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
            if !bullets.isEmpty { out.append(.bullet(bullets)); bullets = [] }
            if !numbers.isEmpty { out.append(.numbered(numbers)); numbers = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: "\n"))); quote = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if line.hasPrefix("```") { out.append(.code(code!.joined(separator: "\n"), lang: codeLang)); code = nil }
                else { code!.append(raw) }
                continue
            }
            if line.hasPrefix("```") { flush(); code = []; codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue }
            if line.isEmpty { flush(); continue }
            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flush(); out.append(.heading(hashes, String(line.dropFirst(hashes + 1)))); continue
            }
            if line.allSatisfy({ "-*_ ".contains($0) }) && line.filter({ !$0.isWhitespace }).count >= 3 { flush(); out.append(.rule); continue }
            if let item = ["- ", "* ", "• "].first(where: line.hasPrefix) {
                if !para.isEmpty || !numbers.isEmpty || !quote.isEmpty { flush() }
                bullets.append(String(line.dropFirst(item.count))); continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].hasPrefix(" ") {
                if !para.isEmpty || !bullets.isEmpty || !quote.isEmpty { flush() }
                numbers.append(String(line[line.index(dot, offsetBy: 2)...])); continue
            }
            if line.hasPrefix(">") {
                if !para.isEmpty || !bullets.isEmpty || !numbers.isEmpty { flush() }
                quote.append(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)); continue
            }
            if !bullets.isEmpty || !numbers.isEmpty || !quote.isEmpty { flush() }
            para.append(line)
        }
        if let code { out.append(.code(code.joined(separator: "\n"), lang: codeLang)) }
        flush()
        return out
    }
}
