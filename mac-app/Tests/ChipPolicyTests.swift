import Foundation
import XCTest
@testable import XGecuBufferCore

final class ChipPolicyTests: XCTestCase {
    private func details(_ name: String, bytes: Int = 1024, id: String? = "C2201B",
                         erasable: Bool = true) -> [String: Any] {
        var result: [String: Any] = [
            "name": name, "package": "SOIC16", "pins": 16,
            "code_bytes": bytes, "data_bytes": 0, "data2_bytes": 0,
            "page_bytes": 256, "blank_value": "FF", "can_erase": erasable,
        ]
        result["chip_id"] = id
        return result
    }

    func testEveryDatabaseModelCanUseReadWhenItFitsBackend() throws {
        for name in ["MX66L1G45G@SOIC16", "MX25L51245G@SOIC16", "W25Q128BV@SOIC8", "AT27C256R@DIP28"] {
            let chip = try XCTUnwrap(ChipDetails(details(name)))
            XCTAssertTrue(ChipPolicy.canRead(name, details: chip, isT76: true), name)
            XCTAssertFalse(ChipPolicy.canRead(name, details: chip, isT76: false), name)
            XCTAssertFalse(ChipPolicy.canRead(name, details: nil, isT76: true), name)
            XCTAssertFalse(ChipPolicy.canRead(name + "X", details: chip, isT76: true), name)
        }
    }

    func testBackendBoundsAndMutationCapabilities() throws {
        let name = "MX66L1G45G@SOIC16"
        let chip = try XCTUnwrap(ChipDetails(details(name, bytes: 134_217_728)))
        XCTAssertTrue(ChipPolicy.canRead(name, details: chip, isT76: true))
        XCTAssertTrue(ChipPolicy.canWrite(name, details: chip, isT76: true))
        XCTAssertTrue(ChipPolicy.canErase(name, details: chip, isT76: true))

        let tooLarge = try XCTUnwrap(ChipDetails(details(name, bytes: ChipPolicy.maxImageBytes + 1)))
        XCTAssertFalse(ChipPolicy.canRead(name, details: tooLarge, isT76: true))
        XCTAssertFalse(ChipPolicy.canWrite(name, details: tooLarge, isT76: true))

        let noID = try XCTUnwrap(ChipDetails(details(name, id: nil)))
        XCTAssertTrue(ChipPolicy.canRead(name, details: noID, isT76: true))
        XCTAssertFalse(ChipPolicy.canWrite(name, details: noID, isT76: true))

        let otp = try XCTUnwrap(ChipDetails(details(name, erasable: false)))
        XCTAssertTrue(ChipPolicy.canWrite(name, details: otp, isT76: true))
        XCTAssertFalse(ChipPolicy.canErase(name, details: otp, isT76: true))
    }
}
