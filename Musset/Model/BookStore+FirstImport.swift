import Foundation

/// A folder opened for the first time: what Musset guesses of the book from what is already there (the build
/// scripts' list of chapters, numbered Markdown files, the title in pandoc's settings).
extension BookStore {
    /// Builds a first manifest by reading the book's existing build scripts,
    /// falling back to numbered or scene Markdown files.
    func seedManifest() -> BookManifest {
        let files = detectChapterFiles()
        let chapters = files.map { file -> ChapterEntry in
            let id = (file as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
            return ChapterEntry(id: uniqueSafeID(id), file: file, title: readTitle(file) ?? id)
        }
        let meta = detectMetadata()
        var m = BookManifest(title: meta.title ?? root.lastPathComponent.capitalized,
                             lang: meta.lang ?? "fr", chapters: chapters)
        m.contact = meta.contact ?? ""
        return m
    }

    func detectChapterFiles() -> [String] {
        for script in ["build_version_longue.sh", "build.sh", "build_blanche.sh"] {
            if let list = parseFilesArray(in: root.appendingPathComponent(script)), !list.isEmpty {
                return list.filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
            }
        }
        let numbered = markdownFiles(in: root).filter { $0.first?.isNumber == true }
        if !numbered.isEmpty { return numbered.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
        for sub in ["scenes", "chapters", "chapitres"] {
            let dir = root.appendingPathComponent(sub)
            let files = markdownFiles(in: dir).filter { !$0.hasSuffix(".en.md") }
            if !files.isEmpty {
                return files.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { "\(sub)/\($0)" }
            }
        }
        return []
    }

    /// Parses `FILES=( "a.md" "b.md" … )` from a bash script.
    func parseFilesArray(in script: URL) -> [String]? {
        guard let text = try? String(contentsOf: script, encoding: .utf8),
              let start = text.range(of: "FILES=(") else { return nil }
        let rest = text[start.upperBound...]
        guard let end = rest.firstIndex(of: ")") else { return nil }
        let body = rest[..<end]
        let regex = try! NSRegularExpression(pattern: #"["']([^"']+\.md)["']"#)
        let s = String(body)
        return regex.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: 1), in: s).map { String(s[$0]) }
        }
    }

    private func markdownFiles(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }
    }

    func readTitle(_ file: String) -> String? {
        (try? String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)).flatMap(Self.heading(in:))
    }

    private func uniqueSafeID(_ id: String) -> String {
        id.replacingOccurrences(of: "/", with: "_")
    }

    struct DetectedMeta { var title: String?; var lang: String?; var contact: String? }

    func detectMetadata() -> DetectedMeta {
        var meta = DetectedMeta()
        if let yml = try? String(contentsOf: root.appendingPathComponent("pandoc.yml"), encoding: .utf8) {
            meta.title = firstMatch(#"(?m)^\s*title:\s*"?([^"\n]+)"?"#, in: yml)
            meta.lang = firstMatch(#"(?m)^\s*lang:\s*"?([a-zA-Z-]+)"?"#, in: yml)
        }
        for script in ["build.sh", "build_blanche.sh"] {
            guard let sh = try? String(contentsOf: root.appendingPathComponent(script), encoding: .utf8) else { continue }
            meta.title = meta.title ?? firstMatch(#"title="([^"]+)""#, in: sh)
            meta.lang = meta.lang ?? firstMatch(#"lang="([a-zA-Z-]+)""#, in: sh)
            meta.contact = meta.contact ?? firstMatch(#"CONTACT="([^"]+)""#, in: sh)
        }
        return meta
    }

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r]).trimmingCharacters(in: .whitespaces)
    }
}
