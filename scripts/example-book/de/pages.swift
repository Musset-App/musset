// renders every page of a PDF to PNG: pages scan.pdf outdir maxpx
import AppKit
import PDFKit
let a = CommandLine.arguments
let doc = PDFDocument(url: URL(fileURLWithPath: a[1]))!
let mx = CGFloat(Double(a[3])!)
for n in 1...doc.pageCount {
    let page = doc.page(at: n - 1)!
    let b = page.bounds(for: .mediaBox)
    let s = mx / max(b.width, b.height)
    let img = page.thumbnail(of: NSSize(width: b.width * s, height: b.height * s), for: .mediaBox)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2] + String(format: "/p-%03d.png", n)))
}
