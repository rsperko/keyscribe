import XCTest

@testable import KeyScribeKit

final class WebCustomDataTests: XCTestCase {
    // Builds a Chromium web-custom-data pickle the same way the renderer does: a payload-size prefix,
    // a pair count, then length-prefixed UTF-16 key/value strings, each padded to a 4-byte boundary.
    private func pickle(_ pairs: [(String, String)]) -> Data {
        var data = Data()
        func appendUInt32(_ value: Int) {
            var little = UInt32(value).littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendString(_ string: String) {
            let units = Array(string.utf16)
            appendUInt32(units.count)
            for unit in units {
                var little = unit.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            while data.count % 4 != 0 { data.append(0) }
        }
        appendUInt32(0)  // payload-size prefix (ignored on read)
        appendUInt32(pairs.count)
        for (key, value) in pairs {
            appendString(key)
            appendString(value)
        }
        return data
    }

    func testDecodeRoundTripsKeyValuePairs() {
        let data = pickle([("text/markdown", "within"), ("mode", "tex")])
        let map = WebCustomData.decode(data)
        XCTAssertEqual(map["text/markdown"], "within")
        XCTAssertEqual(map["mode"], "tex")
    }

    func testEmptySelectionFlagTrue() {
        let data = pickle([(
            "vscode-editor-data",
            #"{"version":1,"isFromEmptySelection":true,"multicursorText":null,"mode":"tex"}"#)])
        XCTAssertEqual(WebCustomData.vscodeIsFromEmptySelection(data), true)
    }

    func testRealSelectionFlagFalse() {
        let data = pickle([(
            "vscode-editor-data",
            #"{"version":1,"isFromEmptySelection":false,"multicursorText":null,"mode":"tex"}"#)])
        XCTAssertEqual(WebCustomData.vscodeIsFromEmptySelection(data), false)
    }

    func testNoVSCodeEntryReturnsNil() {
        // Obsidian (and other Electron editors) write web-custom-data keyed by content type, with no
        // emptiness flag. `nil` means "not a VS Code-family editor" — the caller trusts such a copy, because
        // a genuinely empty selection there copies nothing and is caught by the changeCount timeout before
        // the trust check runs.
        let data = pickle([("text/markdown", "some selected text")])
        XCTAssertNil(WebCustomData.vscodeIsFromEmptySelection(data))
    }

    func testNilAndMalformedDataReturnNil() {
        XCTAssertNil(WebCustomData.vscodeIsFromEmptySelection(nil))
        XCTAssertNil(WebCustomData.vscodeIsFromEmptySelection(Data([0x01, 0x02, 0x03])))
        XCTAssertNil(WebCustomData.vscodeIsFromEmptySelection(Data()))
    }

    func testCopyTrustDiscardsOnlyVSCodeEmptySelection() {
        func vscode(_ empty: Bool) -> Data {
            pickle([("vscode-editor-data",
                     "{\"version\":1,\"isFromEmptySelection\":\(empty),\"multicursorText\":null,\"mode\":\"tex\"}")])
        }
        XCTAssertFalse(WebCustomData.copyIsTrustworthySelection(vscode(true)))
        XCTAssertTrue(WebCustomData.copyIsTrustworthySelection(vscode(false)))
        XCTAssertTrue(WebCustomData.copyIsTrustworthySelection(pickle([("text/markdown", "selected in Obsidian")])))
        XCTAssertTrue(WebCustomData.copyIsTrustworthySelection(nil))
        XCTAssertTrue(WebCustomData.copyIsTrustworthySelection(Data([0x01, 0x02, 0x03])))
    }
}
