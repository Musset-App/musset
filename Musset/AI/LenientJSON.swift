import Foundation

/// The JSON object in an AI's reply, even when it is slightly malformed. Readers write French, and French
/// quotes nest: « Payer le "1" » inside a JSON string breaks it, and the whole reading used to be thrown away.
enum LenientJSON {
    /// From the first `{` to the last `}`, repaired if it doesn't parse as it is.
    static func object(in raw: String) -> Data? {
        guard let start = raw.firstIndex(of: "{"), let end = raw.lastIndex(of: "}"), start < end else { return nil }
        let slice = String(raw[start...end])
        if parses(slice) { return Data(slice.utf8) }
        let repaired = repair(slice)
        return parses(repaired) ? Data(repaired.utf8) : nil
    }

    private static func parses(_ s: String) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) != nil
    }

    /// Inside a string, a `"` that isn't followed by what may come after a string (`,` `}` `]` `:` or the end)
    /// is part of the text and gets escaped; raw line breaks and tabs are escaped too.
    static func repair(_ s: String) -> String {
        let chars = Array(s)
        var out = ""
        out.reserveCapacity(s.utf8.count + 16)
        var inString = false, escaped = false
        for (i, c) in chars.enumerated() {
            guard inString else {
                if c == "\"" { inString = true }
                out.append(c)
                continue
            }
            if escaped { escaped = false; out.append(c); continue }
            switch c {
            case "\\": escaped = true; out.append(c)
            case "\"":
                let next = chars[(i + 1)...].first { !$0.isWhitespace }
                if next == nil || [",", "}", "]", ":"].contains(next!) { inString = false; out.append(c) } else { out += "\\\"" }
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(c)
            }
        }
        return out
    }
}
