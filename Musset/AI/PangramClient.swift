import CryptoKit
import Foundation
import Security

/// Pangram AI-detection API (same endpoints as the book's pangram_check.py).
struct PangramResult: Codable, Hashable {
    struct Window: Codable, Hashable {
        var text: String
        var label: String
        var ai_assistance_score: Double?
        var confidence: String?
    }
    var stage: String
    var prediction_short: String?
    var headline: String?
    var fraction_ai: Double?
    var fraction_ai_assisted: Double?
    var fraction_human: Double?
    var windows: [Window]?

    var flaggedWindows: [Window] { (windows ?? []).filter { $0.label != "Human Written" } }
}

enum PangramClient {
    static let base = URL(string: "https://text.external-api.pangram.com")!

    /// Same cleanup as pangram_check.py: no HTML comments, no headings.
    static func body(_ text: String) -> String {
        let noComments = BookStore.stripHTMLComments(text)
        let re = try! NSRegularExpression(pattern: #"^#{1,6}\s+.*$"#, options: [.anchorsMatchLines])
        return re.stringByReplacingMatches(in: noComments, range: NSRange(noComments.startIndex..., in: noComments), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Checks text, using the on-disk cache keyed by content hash.
    static func check(_ raw: String, key: String, cacheDir: URL, label: String) async throws -> PangramResult {
        let text = body(raw)
        guard text.split(whereSeparator: \.isWhitespace).count >= 50 else {
            throw NSError(domain: "Pangram", code: 1, userInfo: [NSLocalizedDescriptionKey: L("Pangram needs at least 50 words.")])
        }
        let digest = sha(text)
        let cache = cacheDir.appendingPathComponent("\(label)-\(digest.prefix(12)).json")
        if let data = try? Data(contentsOf: cache), let r = try? JSONDecoder().decode(PangramResult.self, from: data), r.stage == "STAGE_SUCCESS" {
            return r
        }
        let created = try await request(key: key, path: "/task", body: ["text": text, "public_dashboard_link": false])
        guard let taskID = created["task_id"] as? String else {
            throw NSError(domain: "Pangram", code: 2, userInfo: [NSLocalizedDescriptionKey: L("Pangram did not return a task id.")])
        }
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let obj = try await request(key: key, path: "/task/\(taskID)", body: nil)
            let stage = obj["stage"] as? String
            if stage == "STAGE_SUCCESS" || stage == "STAGE_FAILED" {
                let data = try JSONSerialization.data(withJSONObject: obj)
                let r = try JSONDecoder().decode(PangramResult.self, from: data)
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try? data.write(to: cache)
                return r
            }
        }
        throw NSError(domain: "Pangram", code: 3, userInfo: [NSLocalizedDescriptionKey: L("Pangram timed out.")])
    }

    private static func request(key: String, path: String, body: [String: Any]?) async throws -> [String: Any] {
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 45
        if let body {
            req.httpMethod = "POST"
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // Never echo bodies or credentials.
            throw NSError(domain: "Pangram", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "Pangram HTTP \(http.statusCode)"])
        }
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    /// Ranges of flagged windows in the editor text (window text has headings/comments removed, so search by content).
    static func ranges(of windows: [PangramResult.Window], in text: String) -> [NSRange] {
        let ns = text as NSString
        var from = 0
        var out: [NSRange] = []
        for w in windows {
            for line in w.text.split(separator: "\n") where line.count > 12 && !line.hasPrefix("#") {
                let needle = String(line)
                var r = ns.range(of: needle, options: [], range: NSRange(location: from, length: ns.length - from))
                if r.location == NSNotFound { r = ns.range(of: needle) }
                if r.location != NSNotFound { out.append(r); from = NSMaxRange(r) }
            }
        }
        return out
    }
}

/// Pangram key: Keychain first, then a book's `.env` (PANGRAM_API_KEY=…), which is copied into the Keychain.
enum Secrets {
    /// Tests keep their keys apart: a test that forgets a server must never delete the author's real key (it did, every
    /// time the suite ran, for OpenRouter's).
    static let service = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? "app.musset.Musset" : "app.musset.Musset.tests"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty else { return }
        var add = q
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func pangramKey(bookRoot: URL?) -> String? {
        if let k = get("pangram"), !k.isEmpty { return k }
        guard let root = bookRoot, let env = try? String(contentsOf: root.appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        for line in env.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "export ", with: "")
            if t.hasPrefix("PANGRAM_API_KEY=") {
                let v = String(t.dropFirst("PANGRAM_API_KEY=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                if !v.isEmpty { set("pangram", v); return v }
            }
        }
        return nil
    }
}
