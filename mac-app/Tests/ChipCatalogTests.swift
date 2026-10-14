import Foundation
import XCTest
@testable import XGecuBufferCore

final class ChipCatalogTests: XCTestCase {
    func testCompleteCatalogAndCaseInsensitivePackageSearch() {
        let names = (0..<35_000).map { "TEST\($0)@DIP28" } + ["MX25L51245G@SOIC16"]
        let catalog = ChipCatalog(names: names)
        XCTAssertEqual(catalog.matching("").count, 35_001)
        XCTAssertEqual(catalog.matching("  mx25l512  "), ["MX25L51245G@SOIC16"])
        XCTAssertEqual(catalog.matching("soic16"), ["MX25L51245G@SOIC16"])
        XCTAssertEqual(catalog.matching("NOT_A_CHIP"), [])
    }

    func testDuplicateEntriesHaveStableUniqueIdentities() {
        let catalog = ChipCatalog(names: ["B@DIP8", "A@DIP8", "B@DIP8", ""])
        XCTAssertEqual(catalog.names, ["A@DIP8", "B@DIP8"])
    }

    func testFavoritesSurviveAStoreReloadWithoutChangingTheCatalog() throws {
        let suite = "XGecuPro.catalog-tests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = FavoriteChipStore(defaults: defaults)
        first.save(["MX25L51245G@SOIC16", "W27C512@DIP28", "MX25L51245G@SOIC16"])
        let second = FavoriteChipStore(defaults: defaults)
        XCTAssertEqual(second.load(), ["MX25L51245G@SOIC16", "W27C512@DIP28"])
        let catalog = ChipCatalog(names: ["AT27C256@DIP28", "MX25L51245G@SOIC16"])
        XCTAssertEqual(catalog.names.count, 2)
        second.save([])
        XCTAssertEqual(first.load(), [])
    }
}
