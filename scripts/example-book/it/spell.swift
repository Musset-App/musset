// reads words on stdin (one per line), prints those the macOS Italian spell checker accepts
import AppKit
let sc = NSSpellChecker.shared
FileHandle.standardError.write((sc.availableLanguages.joined(separator: ",") + "\n").data(using: .utf8)!)
_ = sc.setLanguage("it")
while let w = readLine() {
    let r = sc.checkSpelling(of: w, startingAt: 0, language: "it", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
    if r.location == NSNotFound { print(w) }
}
