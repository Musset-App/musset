// Reads a scan of two-page spreads with the Mac's text recognition, half by half.
// usage: ocrh scan.pdf lang <correction 0|1> <long side px> [first spread] [last spread]
// Prints "=== page <2n-1|2n>" (n = spread; odd = left half), then L <x> <y> <w> <h> <text> per line and W … per word,
// boxes relative to the half.
import Foundation
import PDFKit
import Vision
let args = CommandLine.arguments
guard args.count >= 5, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { fatalError("usage") }
let correct = args[3] == "1"
let px = CGFloat(Double(args[4])!)
let first = args.count > 5 ? Int(args[5])! : 1
let last = args.count > 6 ? Int(args[6])! : doc.pageCount
let split: CGFloat = 0.487
func f(_ b: CGRect) -> String { String(format: "%.4f\t%.4f\t%.4f\t%.4f", b.minX, b.minY, b.width, b.height) }
for n in first...min(last, doc.pageCount) {
    guard let page = doc.page(at: n - 1) else { continue }
    let box = page.bounds(for: .mediaBox)
    let scale = px / max(box.width, box.height)
    let image = page.thumbnail(of: NSSize(width: box.width * scale, height: box.height * scale), for: .mediaBox)
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let w = CGFloat(cg.width), h = CGFloat(cg.height)
    for (k, rect) in [CGRect(x: 0, y: 0, width: w * split, height: h), CGRect(x: w * split, y: 0, width: w * (1 - split), height: h)].enumerated() {
        guard let half = cg.cropping(to: rect) else { continue }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [args[2]]
        request.usesLanguageCorrection = correct
        try? VNImageRequestHandler(cgImage: half, options: [:]).perform([request])
        print("=== page \(2 * n - 1 + k)")
        for l in (request.results ?? []).sorted(by: { $0.boundingBox.midY > $1.boundingBox.midY }) {
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
}
