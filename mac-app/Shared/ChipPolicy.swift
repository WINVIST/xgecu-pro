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
    private static let readablePrefixes = ["AT27C256R@", "MX27C2000@", "W27C512@", "W27C257@"]
    private static let writablePrefixes = ["W27C512@", "W27C257@"]
    private static let requestedReadOnly: [String: (bytes: Int, id: String)] = [
        "MX25L51245G@SOIC16": (67_108_864, "C2201A"),
        "MX25L25645G@SOIC16": (33_554_432, "C22019"),
    ]

    static func isRequestedReadOnly(_ name: String) -> Bool {
        requestedReadOnly[name.uppercased()] != nil
    }

    static func canRead(_ name: String, details: ChipDetails?, isT76: Bool) -> Bool {
        guard isT76, let details else { return false }
        let normalized = name.uppercased()
        guard details.name.uppercased() == normalized else { return false }
        if readablePrefixes.contains(where: { normalized.hasPrefix($0) }) { return true }
        guard let expected = requestedReadOnly[normalized] else { return false }
        return details.package.uppercased() == "SOIC16"
            && details.pins == 16 && details.codeBytes == expected.bytes
            && details.pageBytes == 256 && details.chipID?.uppercased() == expected.id
    }

    static func canWrite(_ name: String, details: ChipDetails?, isT76: Bool) -> Bool {
        guard canRead(name, details: details, isT76: isT76), let details else { return false }
        return writablePrefixes.contains(where: { name.uppercased().hasPrefix($0) })
            && !(details.chipID?.isEmpty ?? true)
    }
}
