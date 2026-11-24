// Vision OCR with options; prints TSV like ocr3: L <x> <y> <w> <h> <text>, then W lines for each word.
// usage: ocrx scan.pdf lang first last maxpx(2400) correction(0/1) revision(2/3) level(accurate/fast)
import Foundation
import PDFKit
import Vision
let args = CommandLine.arguments
guard args.count >= 9, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { fatalError("usage") }
let first = Int(args[3])!, last = Int(args[4])!
let maxpx = CGFloat(Double(args[5])!)
func f(_ b: CGRect) -> String { String(format: "%.4f\t%.4f\t%.4f\t%.4f", b.minX, b.minY, b.width, b.height) }
for n in first...min(last, doc.pageCount) {
    guard let page = doc.page(at: n - 1) else { continue }
    let box = page.bounds(for: .mediaBox)
    let scale = maxpx / max(box.width, box.height)
    let size = NSSize(width: box.width * scale, height: box.height * scale)
    let image = page.thumbnail(of: size, for: .mediaBox)
    guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = args[8] == "fast" ? .fast : .accurate
    request.recognitionLanguages = [args[2]]
    request.usesLanguageCorrection = args[6] == "1"
    request.revision = args[7] == "2" ? VNRecognizeTextRequestRevision2 : VNRecognizeTextRequestRevision3
    do { try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request]) } catch { FileHandle.standardError.write("page \(n): \(error)\n".data(using: .utf8)!) }
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
