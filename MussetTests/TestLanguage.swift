import XCTest
@testable import Musset

/// The tests read Musset's interface in French, the language they were written against: "Première version",
/// "2 chapitres"… On the author's Mac that is a saved preference; on a fresh machine (CI, a contributor's) it is not.
/// So the whole run is put in French here, and the preference is put back at the end.
/// Loaded first as the test bundle's principal class (NSPrincipalClass, in project.yml).
final class TestLanguage: NSObject, XCTestObservation {
    private var saved: String?

    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        saved = UserDefaults.standard.string(forKey: UILang.key)
        UserDefaults.standard.set(UILang.fr.rawValue, forKey: UILang.key)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        UserDefaults.standard.set(saved, forKey: UILang.key)
    }
}
