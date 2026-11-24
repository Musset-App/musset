// Vision OCR without language correction; prints TSV: L <x> <y> <w> <h> <text>, then W <x> <y> <w> <h> <word> for each word.
import Foundation
import PDFKit
import Vision
let args = CommandLine.arguments
guard args.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { fatalError("usage") }
let first = args.count > 3 ? Int(args[3])! : 1
let last = args.count > 4 ? Int(args[4])! : doc.pageCount
func f(_ b: CGRect) -> String { String(format: "%.4f\t%.4f\t%.4f\t%.4f", b.minX, b.minY, b.width, b.height) }
for n in first...min(last, doc.pageCount) {
    guard let page = doc.page(at: n - 1) else { continue }
    let box = page.bounds(for: .mediaBox)
    let scale = max(1, 2400 / max(box.width, box.height))
    let size = NSSize(width: box.width * scale, height: box.height * scale)
    let image = page.thumbnail(of: size, for: .mediaBox)
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = [args[2]]
    request.usesLanguageCorrection = false
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
    print("=== page \(n)")
    let lines = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
    for l in lines {
        guard let t = l.topCandidates(1).first else { continue }
        let s = t.string
        print("L\t\(f(l.boundingBox))\t\(s)")
        var i = s.startIndex
        while i < s.endIndex {
            while i < s.endIndex, s[i] == " " { i = s.index(after: i) }
            var j = i
            while j < s.endIndex, s[j] != " " { j = s.index(after: j) }
            if i < j, let b = try? t.boundingBox(for: i..<j) { print("W\t\(f(b.boundingBox))\t\(s[i..<j])") }
            i = j
        }
    }
}
