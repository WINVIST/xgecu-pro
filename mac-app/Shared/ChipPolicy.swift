import Foundation

struct ChipDetails {
    let name: String
    let package: String
    let pins: Int
    let codeBytes: Int
    let dataBytes: Int
    let extraDataBytes: Int
    let pageBytes: Int
    let chipID: String?
    let blankValue: String
    let canErase: Bool

    init?(_ result: [String: Any]) {
        guard let name = result["name"] as? String,
              let package = result["package"] as? String,
              let pins = result["pins"] as? Int,
              let codeBytes = result["code_bytes"] as? Int,
              let dataBytes = result["data_bytes"] as? Int,
              let extraDataBytes = result["data2_bytes"] as? Int,
              let pageBytes = result["page_bytes"] as? Int,
              let blankValue = result["blank_value"] as? String,
              let canErase = result["can_erase"] as? Bool else { return nil }
        self.name = name
        self.package = package
        self.pins = pins
        self.codeBytes = codeBytes
        self.dataBytes = dataBytes
        self.extraDataBytes = extraDataBytes
        self.pageBytes = pageBytes
        self.chipID = result["chip_id"] as? String
        self.blankValue = blankValue
        self.canErase = canErase
    }
}

enum ChipPolicy {
    // These bounds come from the Rust backend. They are not a model allowlist.
    static let maxImageBytes = 256 * 1024 * 1024
    static let maxStreamedReadBytes = 2 * 1024 * 1024 * 1024

    static func canRead(_ name: String, details: ChipDetails?, isT76: Bool) -> Bool {
        guard isT76, let details else { return false }
        return details.name == name && !details.package.isEmpty && details.pins > 0
            && details.codeBytes > 0 && details.codeBytes <= maxStreamedReadBytes
            && details.dataBytes >= 0 && details.extraDataBytes >= 0
            && details.pageBytes >= 0
    }

    static func canWrite(_ name: String, details: ChipDetails?, isT76: Bool) -> Bool {
        guard canRead(name, details: details, isT76: isT76), let details else { return false }
        // Mutation requires a hardware ID check in the bundled CLI.
        return details.codeBytes <= maxImageBytes && !(details.chipID?.isEmpty ?? true)
    }

    static func canVerify(_ name: String, details: ChipDetails?, isT76: Bool) -> Bool {
        canRead(name, details: details, isT76: isT76)
            && (details?.codeBytes ?? 0) <= maxImageBytes
    }

    static func canErase(_ name: String, details: ChipDetails?, isT76: Bool) -> Bool {
        canWrite(name, details: details, isT76: isT76) && (details?.canErase ?? false)
    }
}
