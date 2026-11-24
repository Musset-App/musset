// reads words on stdin (one per line), prints those the macOS Spanish spell checker accepts
import AppKit
let sc = NSSpellChecker.shared
FileHandle.standardError.write((sc.availableLanguages.joined(separator: ",") + "\n").data(using: .utf8)!)
_ = sc.setLanguage("es")
while let w = readLine() {
    let r = sc.checkSpelling(of: w, startingAt: 0, language: "es", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
    if r.location == NSNotFound { print(w) }
}
