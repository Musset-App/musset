import Foundation

extension JSONEncoder.OutputFormatting {
    /// The form of the files tracked with the book: readable, and the same from one save to the next.
    static let book: JSONEncoder.OutputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
}

/// Musset's JSON files, read and written in one way. Each file keeps the form it always had: `format` and `iso8601`
/// (dates as text) say which.
enum JSONFile {
    /// Written in one go (the folder made if need be), so a reader never finds half a file.
    static func write<T: Encodable>(_ value: T, to url: URL, _ format: JSONEncoder.OutputFormatting = .book, iso8601: Bool = false) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = format
        if iso8601 { enc.dateEncodingStrategy = .iso8601 }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(value).write(to: url, options: .atomic)
    }

    /// Nil when the file is missing or is not what was expected.
    static func read<T: Decodable>(_ type: T.Type = T.self, at url: URL, iso8601: Bool = false) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        if iso8601 { dec.dateDecodingStrategy = .iso8601 }
        return try? dec.decode(type, from: data)
    }
}
