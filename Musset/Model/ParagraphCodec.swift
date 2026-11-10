import Foundation

/// Musset edits prose with one line per paragraph; files stay standard Markdown with blank lines between paragraphs.
///
/// Inside the app (editor form)            On disk (Markdown)
///   "\n"           paragraph break   ⇄      "\n\n"      (one blank line)
///   "\n" × m       empty paragraphs  ⇄      "\n" × (m+1)
///   U+2028         line break inside ⇄      "\n"        (⇧↩ adds two trailing spaces first: a Markdown hard break)
///   newlines at the very start or end of the file are kept as they are.
///
/// Reading then writing a file gives back exactly the same bytes.
enum ParagraphCodec {
    static let lineBreak: Character = "\u{2028}"

    /// Disk Markdown → editor text.
    static func decode(_ disk: String) -> String {
        var out = ""
        out.reserveCapacity(disk.utf8.count)
        let chars = Array(disk)
        var i = 0
        while i < chars.count {
            guard chars[i] == "\n" else { out.append(chars[i]); i += 1; continue }
            var j = i
            while j < chars.count, chars[j] == "\n" { j += 1 }
            let run = j - i
            if i == 0 || j == chars.count {
                out += String(repeating: "\n", count: run)            // file edges: unchanged
            } else if run == 1 {
                out.append(lineBreak)                                 // a line break inside a block
            } else {
                out += String(repeating: "\n", count: run - 1)        // paragraph break (+ extra blank lines)
            }
            i = j
        }
        return out
    }

    /// Editor text → disk Markdown.
    static func encode(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count + 64)
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == lineBreak { out.append("\n"); i += 1; continue }
            guard c == "\n" else { out.append(c); i += 1; continue }
            var j = i
            while j < chars.count, chars[j] == "\n" { j += 1 }
            let run = j - i
            out += String(repeating: "\n", count: (i == 0 || j == chars.count) ? run : run + 1)
            i = j
        }
        return out
    }

    /// Text arriving from outside (paste, an AI answer): standard Markdown with blank lines becomes editor form;
    /// text that already has one paragraph per line is left alone.
    static func importExternal(_ s: String) -> String {
        s.contains("\n\n") ? decode(s) : s
    }
}
