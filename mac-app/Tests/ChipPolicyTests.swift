import Foundation
import XCTest
@testable import XGecuBufferCore

final class ChipPolicyTests: XCTestCase {
    private func details(_ name: String, bytes: Int, id: String) -> [String: Any] {
        [
            "name": name,
            "package": "SOIC16",
            "pins": 16,
            "code_bytes": bytes,
            "data_bytes": 0,
            "data2_bytes": 0,
            "page_bytes": 256,
            "chip_id": id,
            "blank_value": "FF",
            "can_erase": true,
        ]
    }

    func testRequestedMacronixPartsAreReadOnlyWithMatchingDatabaseDetails() throws {
        for (name, bytes, id) in [
            ("MX25L51245G@SOIC16", 67_108_864, "C2201A"),
            ("MX25L25645G@SOIC16", 33_554_432, "C22019"),
        ] {
            let chip = try XCTUnwrap(ChipDetails(details(name, bytes: bytes, id: id)))
            XCTAssertTrue(ChipPolicy.isRequestedReadOnly(name))
            XCTAssertTrue(ChipPolicy.canRead(name, details: chip, isT76: true))
            XCTAssertFalse(ChipPolicy.canRead(name, details: chip, isT76: false))
            XCTAssertFalse(ChipPolicy.canWrite(name, isT76: true))
        }
    }

    func testRequestedPartRejectsMismatchedDatabaseDetails() throws {
        let name = "MX25L51245G@SOIC16"
        let original = details(name, bytes: 67_108_864, id: "C2201A")
        for (key, replacement) in [
            ("name", "MX25L25645G@SOIC16" as Any),
            ("package", "SOIC8" as Any),
            ("pins", 8 as Any),
            ("code_bytes", 33_554_432 as Any),
            ("page_bytes", 512 as Any),
            ("chip_id", "C22019" as Any),
        ] {
            var changed = original
            changed[key] = replacement
            let chip = try XCTUnwrap(ChipDetails(changed))
            XCTAssertFalse(ChipPolicy.canRead(name, details: chip, isT76: true), key)
        }
        XCTAssertFalse(ChipPolicy.canRead(name, details: nil, isT76: true))
        XCTAssertFalse(ChipPolicy.canRead("MX25L51245G@SOIC8", details: ChipDetails(original), isT76: true))
    }

    func testOnlyPreviouslyApprovedPartsCanBeWritten() {
        XCTAssertTrue(ChipPolicy.canWrite("W27C512@DIP28", isT76: true))
        XCTAssertTrue(ChipPolicy.canWrite("W27C257@DIP28", isT76: true))
        XCTAssertFalse(ChipPolicy.canWrite("W27C512@DIP28", isT76: false))
        XCTAssertFalse(ChipPolicy.canWrite("MX25L25645G@SOIC16", isT76: true))
        XCTAssertFalse(ChipPolicy.canWrite("MX25L51245G@SOIC16", isT76: true))
    }
}
