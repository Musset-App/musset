import XCTest
@testable import Musset

/// Readers write French: straight quotes inside their JSON strings must not cost the whole reading.
final class LenientJSONTests: XCTestCase {
    func testStrayQuotesInsideStringsAreKept() throws {
        let raw = """
        ```json
        {"overview": "Je retire aussi « Payer le "1" » : en supprimant le numéro, vous avez levé la promesse.", "keep": "Il dit "oui".", "axes": [], "scores": []}
        ```
        """
        let data = try XCTUnwrap(LenientJSON.object(in: raw))
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(o["overview"] as? String, "Je retire aussi « Payer le \"1\" » : en supprimant le numéro, vous avez levé la promesse.")
        XCTAssertEqual(o["keep"] as? String, "Il dit \"oui\".")
    }

    func testValidJSONIsLeftAsItIs() throws {
        let raw = #"Voici : {"a": "x \"y\" z", "b": [1, 2]} merci"#
        XCTAssertEqual(String(decoding: try XCTUnwrap(LenientJSON.object(in: raw)), as: UTF8.self), #"{"a": "x \"y\" z", "b": [1, 2]}"#)
    }

    func testLineBreaksInsideStrings() throws {
        let data = try XCTUnwrap(LenientJSON.object(in: "{\"a\": \"une\ndeux\"}"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: String])?["a"], "une\ndeux")
    }

    func testNothingReadable() {
        XCTAssertNil(LenientJSON.object(in: "pas de JSON ici"))
        XCTAssertNil(LenientJSON.object(in: #"{"a": [1, 2}"#))
    }

    /// The reading that failed on « Interlude 1 »: its scores now come through.
    func testAReadingWithAQuoteInItsOverview() throws {
        let raw = #"{"scores":[{"criterionId":"lexique","anchor":"15","score":15,"quotes":["sur le papier paraffiné"],"justification":"Exact."}],"overview":"Je retire « Payer le "1" ».","axes":[],"keep":"","notes":[]}"#
        let answer = try XCTUnwrap(ReadingCheck.parse(raw))
        XCTAssertEqual(answer.scores.map(\.criterionId), ["lexique"])
    }
}
