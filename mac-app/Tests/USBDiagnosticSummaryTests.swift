import Foundation
import XCTest
@testable import XGecuBufferCore

final class USBDiagnosticSummaryTests: XCTestCase {
    private func successfulReport() -> [String: Any] {
        ["passed": true, "link": "Super", "opening": ["interface_claimed": true],
         "probes": [0, 100, 1_000, 3_000].map { ["idle_ms": $0, "firmware": "00.1.18"] as [String: Any] }]
    }

    func testSuccessRequiresCompleteStableExchangesAndInterface() {
        let report = successfulReport()
        let summary = USBDiagnosticSummary(report: report)
        XCTAssertTrue(summary.passed)
        XCTAssertEqual(summary.speed, "USB 3 · SuperSpeed")
        XCTAssertEqual(summary.firmware, "00.1.18")
        XCTAssertEqual(summary.successfulProbes, 4)
        for key in ["probes", "opening"] {
            var incomplete = report
            incomplete.removeValue(forKey: key)
            XCTAssertFalse(USBDiagnosticSummary(report: incomplete).passed)
        }
        var failed = report
        failed["error"] = "transfer failed"
        XCTAssertFalse(USBDiagnosticSummary(report: failed).passed)
        failed = report
        failed["restore_error"] = "control stalled"
        let unrestored = USBDiagnosticSummary(report: failed)
        XCTAssertEqual(unrestored.title, "USB settings could not be restored")
        XCTAssertFalse(unrestored.passed)
        XCTAssertEqual(unrestored.exchange, .passed)
    }

    func testNoDeviceMultipleDevicesAndMissingInterfaceHaveDifferentAdvice() {
        let absent = USBDiagnosticSummary(report: ["error": "usb transport: no T76 connected"])
        XCTAssertEqual(absent.title, "T76 was not found")
        XCTAssertEqual(absent.interface, .notRun)
        let many = USBDiagnosticSummary(report: ["error": "connect exactly one T76 for USB diagnostics"])
        XCTAssertEqual(many.title, "More than one T76 is connected")
        let missing = USBDiagnosticSummary(report: ["link": "Super", "error": "claim interface 0: interface not found"])
        XCTAssertEqual(missing.device, .passed)
        XCTAssertEqual(missing.interface, .failed)
        XCTAssertFalse(missing.advice.contains("USB 2"))
    }

    func testFailedBulkAndUnknownSpeedAreNotClaimedAsSuccessOrHighSpeed() {
        let failed = USBDiagnosticSummary(report: [
            "opening": ["interface_claimed": true],
            "probes": [["idle_ms": 0, "error": "timeout"]],
        ])
        XCTAssertFalse(failed.passed)
        XCTAssertEqual(failed.title, "Communication with the T76 failed")
        XCTAssertEqual(failed.speed, "Not reported by macOS")
        XCTAssertEqual(failed.successfulProbes, 0)
        XCTAssertEqual(failed.exchange, .failed)
    }

    func testInconsistentFirmwareOrDuplicatedProbeDoesNotPass() {
        var report = successfulReport()
        var probes = report["probes"] as! [[String: Any]]
        probes[3]["firmware"] = "00.1.17"
        report["probes"] = probes
        XCTAssertFalse(USBDiagnosticSummary(report: report).passed)
        report = successfulReport()
        probes = report["probes"] as! [[String: Any]]
        probes[3]["idle_ms"] = 0
        report["probes"] = probes
        XCTAssertFalse(USBDiagnosticSummary(report: report).passed)
    }

    func testGenericConnectionMetadataIsOptionalBoundedAndExplicitlyUserProvided() {
        XCTAssertEqual(USBConnectionKind.allCases.count, 5)
        let metadata = USBConnectionKind.dock.metadata(description: "  My dock → adapter  ")
        XCTAssertEqual(metadata["kind"], "dock")
        XCTAssertEqual(metadata["description"], "My dock → adapter")
        XCTAssertEqual(metadata["source"], "user-provided")
        XCTAssertEqual(USBConnectionKind.unknown.metadata(description: "")["description"], "")
        XCTAssertEqual(USBConnectionKind.hub.metadata(description: String(repeating: "a", count: 300))["description"]?.count, 240)
    }
}
