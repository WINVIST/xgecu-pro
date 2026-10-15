import Foundation

enum USBConnectionKind: String, CaseIterable, Identifiable {
    case unknown, direct, hub, dock, adapter

    var id: String { rawValue }
    var title: String {
        switch self {
        case .unknown: return "Not sure"
        case .direct: return "Direct to Mac"
        case .hub: return "USB hub"
        case .dock: return "Docking station"
        case .adapter: return "USB adapter"
        }
    }

    func metadata(description: String) -> [String: String] {
        ["kind": rawValue, "description": String(description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)),
         "source": "user-provided"]
    }
}

struct USBDiagnosticSummary {
    enum StepState: Equatable { case passed, failed, notRun }

    let passed: Bool
    let title: String
    let advice: String
    let speed: String
    let firmware: String
    let successfulProbes: Int
    let device: StepState
    let interface: StepState
    let exchange: StepState

    init(report: [String: Any]) {
        let opening = report["opening"] as? [String: Any] ?? [:]
        let probes = report["probes"] as? [[String: Any]] ?? []
        let error = report["error"] as? String
        let restoreError = report["restore_error"] as? String
        let link = report["link"] as? String
        let claimed = opening["interface_claimed"] as? Bool == true
        let found = link != nil || report["bos_hex"] is String || claimed
            || !(opening["configurations"] as? [Any] ?? []).isEmpty
        let successful = probes.filter { $0["error"] as? String == nil && $0["firmware"] is String }
        successfulProbes = successful.count
        let versions = Set(successful.compactMap { $0["firmware"] as? String })
        firmware = versions.count == 1 ? (versions.first ?? "Not reported") : (versions.isEmpty ? "Not reported" : "Replies differ")
        switch link {
        case "Super": speed = "USB 3 · SuperSpeed"
        case "SuperPlus": speed = "USB 3 · SuperSpeed Plus"
        case "High": speed = "USB 2 · High Speed"
        case "Full": speed = "USB Full Speed"
        case "Low": speed = "USB Low Speed"
        default: speed = "Not reported by macOS"
        }
        let complete = probes.count == 4 && successful.count == 4 && versions.count == 1
            && probes.compactMap { $0["idle_ms"] as? Int } == [0, 100, 1_000, 3_000]
        passed = report["passed"] as? Bool == true && complete && claimed
            && error == nil && restoreError == nil
        device = found ? .passed : (error == nil ? .notRun : .failed)
        interface = claimed ? .passed : (found ? .failed : .notRun)
        exchange = complete && claimed ? .passed : (claimed ? .failed : .notRun)

        if passed {
            title = "USB connection test passed"
            advice = "The T76 replied before and after idle pauses. Close this window and use Connect / Refresh. Chip reads and programming are checked by their own readback tests."
        } else if restoreError != nil {
            title = "USB settings could not be restored"
            advice = "Unplug the cable from the T76, then reconnect it before any further operation. Save this report if the problem repeats."
        } else if error?.contains("connect exactly one T76") == true {
            title = "More than one T76 is connected"
            advice = "Leave one programmer connected, then start a new test."
        } else if error?.contains("no T76 connected") == true {
            title = "T76 was not found"
            advice = "Connect the programmer with a data-capable USB cable and check its power light. Try another port or cable, then start a new test."
        } else if error?.contains("requires a confirmed SuperSpeed link") == true {
            title = "USB sleep experiment is unavailable"
            advice = "This optional experiment requires a measured USB 3 link. Use the standard connection test for this connection."
        } else if found && !claimed {
            title = "T76 was found, but its interface did not open"
            advice = "Close other programmer apps. Unplug the cable from the T76 and reconnect it, then start a new test. If it repeats, compare another port or connection and save both reports."
        } else if claimed && !probes.isEmpty {
            title = "Communication with the T76 failed"
            advice = "Try another data cable or USB port. If using a hub or dock, compare a direct connection. Save the reports for both connections."
        } else if error != nil {
            title = "USB connection test could not finish"
            advice = "Save the report and check the technical details. Reconnect the T76 before starting a new test."
        } else {
            title = "Diagnostic report is incomplete"
            advice = "Start a new test. If the report remains incomplete, save it with the app version for troubleshooting."
        }
    }
}
