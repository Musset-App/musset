// Reads each page of a scanned PDF with the Mac's own text recognition and prints the lines, page by page.
// usage: swift ocr.swift <scan.pdf> <language, e.g. it-IT> [first page] [last page]
import Foundation
import PDFKit
import Vision

let args = CommandLine.arguments
guard args.count >= 3, let doc = PDFDocument(url: URL(fileURLWithPath: args[1])) else { fatalError("usage: ocr.swift scan.pdf lang") }
let first = args.count > 3 ? Int(args[3])! : 1
let last = args.count > 4 ? Int(args[4])! : doc.pageCount
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
    // Top to bottom.
    let lines = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
    for l in lines { if let t = l.topCandidates(1).first { print(String(format: "%.3f\t%.3f\t", l.boundingBox.minX, l.boundingBox.midY) + t.string) } }
}
