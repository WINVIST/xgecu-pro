import AppKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var databasePath = UserDefaults.standard.string(forKey: "databasePath") ?? "" {
        didSet { UserDefaults.standard.set(databasePath, forKey: "databasePath") }
    }
    var databaseDescription: String {
        if !databasePath.isEmpty { return databasePath }
        return MiniProRunner.bundledDatabasePath == nil ? "automatic (cached after first download)" : "bundled for offline use"
    }
    @Published var query = "" {
        didSet { if catalog != nil { filterCatalog() } }
    }
    @Published var hits: [String] = []
    @Published var hasSearched = false
    @Published var catalog: ChipCatalog?
    @Published var favoriteChips = FavoriteChipStore().load()
    @Published var selectedChip = "" {
        didSet { if selectedChip != oldValue { setupStatus = nil } }
    }
    @Published var setupStatus: String?
    @Published var chipDetails: ChipDetails?
    @Published var deviceStatus = "Programmer not checked"
    @Published var status = "Connect the T76 with the supplied USB cable, then click Connect / Refresh."
    @Published var busy = false
    @Published var progress: Double?
    @Published var currentStage: String?
    @Published var log: [String] = []
    @Published var hexPreview = ""
    @Published var lastFile: URL?
    @Published var programmingFile: URL?
    @Published var programmingFileBytes: Int?
    @Published var bufferChip: String?
    @Published var isT76 = false
    @Published var bufferSize = 0
    @Published var bufferOffset = 0
    @Published var bufferDirty = false
    @Published var bufferSHA256 = ""
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var addressText = "0"
    @Published var byteAddressText = "0"
    @Published var byteValueText = "FF"
    @Published var findText = ""
    @Published var asciiFindText = ""
    @Published var fillStartText = "0"
    @Published var fillEndText = "0"
    @Published var fillByteText = "FF"
    @Published var blockStartText = "0"
    @Published var blockEndText = "0"
    @Published var blockDestinationText = "0"

    private let runner = MiniProRunner()
    private let pageBytes = 256
    private let buffer = HexBuffer()
    private var cleanSHA256 = ""
    private var lastSearch: Data?
    private var lastFoundOffset: Int?

    var favoriteHits: [String] {
        let favorites = Set(favoriteChips)
        if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasSearched {
            return favoriteChips
        }
        return hits.filter { favorites.contains($0) }
    }

    var otherHits: [String] {
        let favorites = Set(favoriteChips)
        return hits.filter { !favorites.contains($0) }
    }

    func toggleFavorite(_ chip: String) {
        guard !busy, !chip.isEmpty else { return }
        var names = Set(favoriteChips)
        if names.contains(chip) { names.remove(chip) } else { names.insert(chip) }
        favoriteChips = ChipCatalog(names: Array(names)).names
        FavoriteChipStore().save(favoriteChips)
    }
    var bufferSourceDescription: String? {
        guard bufferSize > 0, let lastFile else { return nil }
        if let bufferChip {
            return "Buffer: \(lastFile.lastPathComponent) · read from \(bufferChip)"
        }
        return "Buffer: \(lastFile.lastPathComponent) · opened from file"
    }

    var bufferSourceWarning: String? {
        guard let bufferChip, !selectedChip.isEmpty, bufferChip != selectedChip else { return nil }
        return "This buffer was read from \(bufferChip), not the selected \(selectedChip)."
    }

    var canReadSelected: Bool {
        ChipPolicy.canRead(selectedChip, details: chipDetails, isT76: isT76)
    }

    var canWriteSelected: Bool {
        ChipPolicy.canWrite(selectedChip, details: chipDetails, isT76: isT76)
    }

    var canVerifySelected: Bool {
        ChipPolicy.canVerify(selectedChip, details: chipDetails, isT76: isT76)
    }

    var canEraseSelected: Bool {
        ChipPolicy.canErase(selectedChip, details: chipDetails, isT76: isT76)
    }

    func connect() {
        guard !busy else { return }
        setupStatus = nil
        // A failed refresh must not leave controls enabled for a device that
        // may have been unplugged or replaced since the last successful check.
        isT76 = false
        deviceStatus = "Programmer not checked"
        perform(["info"]) { [weak self] result in
            guard let self else { return }
            let model = result["model"] as? String ?? "Unknown model"
            let firmware = result["fw"] as? String ?? "?"
            let link = result["link"] as? String ?? "?"
            self.isT76 = model == "T76"
            self.deviceStatus = "\(model) · firmware \(firmware) · USB \(link)"
            if !self.isT76 {
                self.status = "This version of the app supports only the T76."
            } else {
                self.status = "T76 connected. Select a chip."
            }
        }
    }

    func search() {
        guard !busy else { return }
        if catalog != nil {
            filterCatalog()
            status = "Results: \(hits.count.formatted()) across the complete catalog."
        } else {
            loadCatalog()
        }
    }

    func browseCatalog() {
        guard !busy else { return }
        query = ""
        search()
    }

    private func filterCatalog() {
        guard let catalog else { return }
        hits = catalog.matching(query)
        hasSearched = true
    }

    private func loadCatalog() {
        // Count first, then request exactly that many names. No fixed search
        // truncation or chip allowlist is used for the browser.
        let database = databasePath
        perform(["search", "", "--limit", "0"], databasePath: database) { [weak self] count in
            guard let self else { return }
            guard let total = count["n"] as? Int, total >= 0, total <= 1_000_000 else {
                self.status = "Error: The database returned an invalid catalog count."
                return
            }
            self.perform(["search", "", "--limit", String(total)], databasePath: database) { [weak self] result in
                guard let self else { return }
                guard let names = result["hits"] as? [String], names.count == total,
                      result["n"] as? Int == total, result["more"] as? Bool == false else {
                    self.status = "Error: The database changed while loading its catalog. Try browsing again."
                    return
                }
                self.catalog = ChipCatalog(names: names)
                self.filterCatalog()
                self.status = "Catalog loaded: \(self.catalog?.names.count.formatted() ?? "0") entries. Filter by chip name or package."
            }
        }
    }

    func autoDetectSOIC16() {
        guard !busy else { return }
        guard isT76 else {
            status = "Click Connect / Refresh before detecting a chip."
            return
        }
        // A failed or unfamiliar ID must leave chip operations disabled.
        query = ""
        selectedChip = ""
        chipDetails = nil
        hits = []
        perform(["autodetect", "--wide"]) { [weak self] result in
            guard let self else { return }
            let id = result["id"] as? String ?? ""
            guard id.count == 6, id.allSatisfy({ $0.isHexDigit }) else {
                self.status = "Error: The programmer returned an invalid JEDEC ID."
                return
            }
            let candidates = result["matches"] as? [String] ?? []
            let total = result["n"] as? Int ?? candidates.count
            self.hits = candidates
            self.hasSearched = true
            if candidates.isEmpty {
                self.status = "Detected JEDEC ID 0x\(id.uppercased()). No SOIC16 database entry matches it. Check the chip and adapter placement."
            } else if candidates.count == 1 {
                self.selectChip(candidates[0], detectedJEDECID: id)
            } else {
                self.status = "Detected JEDEC ID 0x\(id.uppercased()). \(total) possible SOIC16 entries. Select the exact chip marking before an operation."
            }
        }
    }

    func selectChip(_ chip: String, detectedJEDECID: String? = nil) {
        guard !busy else { return }
        selectedChip = chip
        chipDetails = nil
        perform(["describe", chip]) { [weak self] result in
            guard let self, self.selectedChip == chip else { return }
            self.chipDetails = ChipDetails(result)
            if self.chipDetails == nil {
                self.status = "Error: The chip database returned incomplete details."
            } else if !self.isT76 {
                self.status = "Chip details loaded. Click Connect / Refresh to check the T76 before chip operations."
            } else if !self.canReadSelected {
                self.status = "Chip details loaded. The code region exceeds the 2 GiB read limit or has no readable code region."
            } else if let detectedJEDECID {
                self.status = "JEDEC ID 0x\(detectedJEDECID.uppercased()) suggests \(chip). Confirm the marking and adapter placement before an operation."
            } else {
                self.status = "Chip details loaded from the database."
            }
        }
    }

    func detect() {
        guard readyForChipOperation else { return }
        perform(["detect", "--like", selectedChip]) { [weak self] result in
            let id = result["id"] as? String ?? "?"
            let matches = result["matches"] as? [String] ?? []
            self?.status = "ID: 0x\(id). Matches: \(matches.prefix(4).joined(separator: ", "))."
        }
    }

    func checkSetup() {
        guard readyForChipOperation else { return }
        setupStatus = nil
        perform(["check", selectedChip]) { [weak self] result in
            guard let self else { return }
            let identity = result["chip_id_checked"] as? Bool == true
                ? "Chip ID matches the selected entry."
                : "This entry has no electronic ID; identity must be checked from the marking."
            let contacts: String
            if result["pins_checked"] as? Bool == true, let open = result["open_pins"] as? [Int] {
                contacts = open.isEmpty ? "Socket contact test passed."
                    : "Open contacts: \(open.map(String.init).joined(separator: ", ")). Check seating and adapter contacts."
            } else {
                contacts = "Contact self-test is unavailable on this programmer. Check the chip and adapter seating."
            }
            self.setupStatus = "Last setup check: " + identity + " " + contacts
            self.status = self.setupStatus ?? identity
        }
    }

    func readChip() {
        guard readyForChipOperation else { return }
        guard confirmDiscardBuffer() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selectedChip.replacingOccurrences(of: "@", with: "_") + ".bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let chip = selectedChip
        perform(["read", selectedChip, url.path]) { [weak self] result in
            guard let self else { return }
            let stable = result["stable"] as? Bool ?? false
            let message = stable
                ? "Dump saved and confirmed by a second read."
                : "The dump was saved, but the second read differed. Check the chip contact and read it again."
            self.openImage(url, successStatus: message, originChip: chip)
        }
    }

    func blankCheck() {
        guard readyForChipOperation else { return }
        perform(["blank", selectedChip]) { [weak self] result in
            let blank = result["blank"] as? Bool ?? false
            self?.status = blank
                ? "The chip is blank: every byte has the erased value."
                : "The chip is not blank. Save a dump before erasing it."
        }
    }

    func verifyChip() {
        guard readyForChipOperation else { return }
        guard canVerifySelected else {
            status = "Error: Select a chip with a code region of 1 byte to 2 GiB."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(["verify", selectedChip, url.path, "--format", inputFormat(for: url)]) { [weak self] result in
            guard let self else { return }
            if result["stable"] as? Bool != true {
                self.status = "Repeated reads differ; verification is unreliable. Check the chip contact."
            } else if result["matches"] as? Bool == true {
                self.status = "Chip contents match the file."
            } else if let offset = result["first_mismatch"] as? Int {
                self.status = String(format: "The chip differs from the file at address 0x%06X.", offset)
            } else {
                self.status = "Chip contents do not match the file."
            }
        }
    }

    func chooseProgrammingFile() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Firmware"
        panel.message = "Choose the file to program into the chip. HEX editor changes must be saved to a file first."
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        programmingFile = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        programmingFileBytes = (attributes?[.size] as? NSNumber)?.intValue
        status = "Firmware selected: \(url.lastPathComponent). Select the exact chip, then choose Program and Verify."
    }

    func writeChip() {
        guard readyForMutation, let url = programmingFile else { return }

        let chip = selectedChip
        let selectedDatabase = databasePath
        beginLocalOperation("Preparing private firmware snapshot")
        Task {
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try self.makePrivateImageSnapshot(of: url)
                }.value
                busy = false
                preflightProgramming(snapshot, original: url, chip: chip, selectedDatabase: selectedDatabase)
            } catch { failLocalOperation(error) }
        }
    }

    private func preflightProgramming(_ snapshot: (directory: URL, file: URL), original url: URL,
                                      chip: String, selectedDatabase: String) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: snapshot.file.path)
        if let size = attributes?[.size] as? NSNumber {
            appendLog("Programming image selected: \(url.lastPathComponent), \(size.intValue.formatted()) bytes.")
        }
        var committed = false
        let format = inputFormat(for: url)
        perform(["write", chip, snapshot.file.path, "--format", format, "--dry-run"],
                databasePath: selectedDatabase,
                cleanup: {
                    if !committed { try? FileManager.default.removeItem(at: snapshot.directory) }
                }) { [weak self] _ in
            guard let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Program \(chip)?"
            alert.informativeText = "Firmware: \(url.lastPathComponent)\n\nPreflight passed. This will change the chip contents; erasable chips are erased before programming. Short images are padded to the chip capacity with the erased byte. Save the original dump first."
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Program and Verify")
            alert.buttons[0].keyEquivalent = "\r"
            alert.buttons[1].keyEquivalent = ""
            guard alert.runModal() == .alertSecondButtonReturn else { return }
            committed = true
            self.perform(["write", chip, snapshot.file.path, "--format", format], databasePath: selectedDatabase,
                         cleanup: { try? FileManager.default.removeItem(at: snapshot.directory) }) { [weak self] _ in
                self?.status = "Programming completed and verified by a readback. The Hex buffer was not changed; use Read to view the chip."
            }
        }
    }

    func eraseChip() {
        guard readyForMutation else { return }
        guard canEraseSelected else {
            status = "Error: The database does not mark this chip as electrically erasable."
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase \(selectedChip)?"
        alert.informativeText = "All data on the chip will be erased. Save a dump first."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Erase")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        perform(["erase", selectedChip]) { [weak self] _ in
            self?.status = "Erase completed."
        }
    }

    func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        databasePath = url.path
        catalog = nil
        hits = []
        hasSearched = false
        selectedChip = ""
        chipDetails = nil
        status = "Local database selected: \(url.lastPathComponent)."
    }

    func useDefaultDatabase() {
        guard !busy else { return }
        databasePath = ""
        catalog = nil
        hits = []
        hasSearched = false
        selectedChip = ""
        chipDetails = nil
        status = MiniProRunner.bundledDatabasePath == nil
            ? "Automatic database selected. Search for a chip again."
            : "Bundled offline database selected. Search for a chip again."
    }

    func openBuffer() {
        guard !busy, confirmDiscardBuffer() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openImage(url)
    }

    func saveBuffer() {
        guard !busy, bufferSize > 0 else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = lastFile?.lastPathComponent ?? "buffer.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        beginLocalOperation("Preparing buffer for saving")
        Task {
            do {
                let raw = try await buffer.sourceURL()
                busy = false
                perform(["convert", raw.path, url.path, "--input-format", "raw"]) { [weak self] _ in
                    guard let self else { return }
                    self.lastFile = url
                    self.cleanSHA256 = self.bufferSHA256
                    self.bufferDirty = false
                    self.status = "Buffer saved: \(url.lastPathComponent)."
                }
            } catch { failLocalOperation(error) }
        }
    }

    func compareBufferToFile() {
        guard !busy, bufferSize > 0 else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let directory = try makePrivateTemporaryDirectory()
            let raw = directory.appendingPathComponent("comparison.bin")
            var comparing = false
            perform(["convert", url.path, raw.path, "--input-format", inputFormat(for: url)], cleanup: {
                if !comparing { try? FileManager.default.removeItem(at: directory) }
            }) { [weak self] _ in
                guard let self else { return }
                comparing = true
                self.bufferTask("Comparing buffer with file", refresh: false, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                }) {
                    let result = try await self.buffer.firstMismatch(with: raw)
                    guard let offset = result.offset else { return "The buffer matches \(url.lastPathComponent) byte for byte." }
                    return String(format: "Difference from %@ at address 0x%X (sizes: %d and %d bytes).",
                                  url.lastPathComponent, offset, self.bufferSize, result.otherBytes)
                }
            }
        } catch {
            status = "Error: Could not compare the files (\(englishErrorDetails(error)))."
        }
    }

    func previousPage() {
        guard !busy, bufferOffset > 0 else { return }
        bufferOffset = max(0, bufferOffset - pageBytes)
        lastSearch = nil
        lastFoundOffset = nil
        addressText = String(bufferOffset, radix: 16).uppercased()
        renderPage()
    }

    func nextPage() {
        guard !busy, bufferOffset + pageBytes < bufferSize else { return }
        bufferOffset += pageBytes
        lastSearch = nil
        lastFoundOffset = nil
        addressText = String(bufferOffset, radix: 16).uppercased()
        renderPage()
    }

    func jumpToAddress() {
        guard !busy, bufferSize > 0 else { return }
        guard let address = parseHexNumber(addressText), address >= 0, address < bufferSize else {
            status = "Error: Address is outside the buffer. Enter a hexadecimal offset."
            return
        }
        bufferOffset = (address / pageBytes) * pageBytes
        lastSearch = nil
        lastFoundOffset = nil
        renderPage()
    }

    func findHex() {
        guard bufferSize > 0 else { return }
        let cleaned = findText.replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard !cleaned.isEmpty, cleaned.count <= 512, cleaned.count.isMultiple(of: 2),
              cleaned.allSatisfy({ $0.isHexDigit }) else {
            status = "Error: Enter 1 to 256 HEX bytes, for example DE AD BE EF."
            return
        }
        let chars = Array(cleaned)
        let needle = Data(stride(from: 0, to: chars.count, by: 2).compactMap {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)
        })
        guard needle.count == chars.count / 2 else {
            status = "Error: Invalid HEX byte sequence."
            return
        }
        findBytes(needle)
    }

    func findASCII() {
        guard bufferSize > 0 else { return }
        let text = asciiFindText
        guard !text.isEmpty, text.utf8.count <= 256,
              text.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
            status = "Error: Enter 1 to 256 printable ASCII characters."
            return
        }
        findBytes(Data(text.utf8))
    }

    private func findBytes(_ needle: Data) {
        let requested = parseHexNumber(addressText)
        let first = requested.flatMap { $0 >= 0 && $0 < bufferSize ? $0 : nil } ?? bufferOffset
        let start = lastSearch == needle && lastFoundOffset != nil
            ? min(bufferSize, (lastFoundOffset ?? 0) + 1)
            : first
        bufferTask("Searching buffer", refresh: false) {
            guard let match = try await self.buffer.find(needle, from: start) else { return "Byte sequence not found." }
            self.bufferOffset = (match / self.pageBytes) * self.pageBytes
            self.lastSearch = needle
            self.lastFoundOffset = match
            self.addressText = String(match, radix: 16).uppercased()
            try await self.renderCurrentPage()
            return String(format: "Found at address 0x%X.", match)
        }
    }

    func copyBlock() {
        guard !busy, bufferSize > 0 else { return }
        guard let start = parseHexNumber(blockStartText),
              let end = parseHexNumber(blockEndText),
              let destination = parseHexNumber(blockDestinationText) else {
            status = "Error: Enter valid HEX block and destination addresses."
            return
        }
        bufferTask("Copying buffer block") {
            try await self.buffer.copyBlock(start: start, end: end, to: destination)
            self.focusEdit(at: destination)
            return String(format: "Copied 0x%X…0x%X to 0x%X. Save the buffer before programming.", start, end, destination)
        }
    }

    func exportBlock() {
        guard !busy, bufferSize > 0 else { return }
        guard let start = parseHexNumber(blockStartText),
              let end = parseHexNumber(blockEndText) else {
            status = "Error: Enter a valid HEX block range."
            return
        }
        guard start >= 0, start <= end, end < bufferSize else {
            status = "Error: Block range is outside the buffer."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(format: "block_%X_%X.bin", start, end)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bufferTask("Exporting buffer block", refresh: false) {
            try await self.buffer.export(start: start, end: end, to: url)
            return "Exported \(end - start + 1) bytes to \(url.lastPathComponent)."
        }
    }

    func fillRange() {
        guard !busy, bufferSize > 0 else { return }
        guard let start = parseHexNumber(fillStartText),
              let end = parseHexNumber(fillEndText),
              let value = parseHexNumber(fillByteText),
              start >= 0, start <= end, end < bufferSize, value >= 0, value <= 0xFF else {
            status = "Error: Enter a valid HEX address range and fill byte."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Fill the buffer range?"
        alert.informativeText = String(format: "Addresses 0x%X…0x%X will be set to 0x%02X. This does not program the chip.", start, end, value)
        alert.addButton(withTitle: "Fill")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        bufferTask("Filling buffer range") {
            try await self.buffer.fill(start: start, end: end, value: UInt8(value))
            self.focusEdit(at: start)
            return "Buffer modified. Save it before programming."
        }
    }

    func editByte() {
        guard !busy, bufferSize > 0 else { return }
        guard let address = parseHexNumber(byteAddressText),
              let value = parseHexNumber(byteValueText),
              address >= 0, address < bufferSize, value >= 0, value <= 0xFF else {
            status = "Error: Enter a valid HEX address and byte value."
            return
        }
        bufferTask("Updating buffer byte") {
            try await self.buffer.setByte(at: address, to: UInt8(value))
            self.focusEdit(at: address)
            return String(format: "Set byte at 0x%X to 0x%02X. Save the buffer before programming.", address, value)
        }
    }

    func undoEdit() {
        bufferTask("Undoing buffer edit") {
            if let range = try await self.buffer.undo() { self.focusEdit(at: range.lowerBound) }
            return "Last buffer edit undone."
        }
    }

    func redoEdit() {
        bufferTask("Restoring buffer edit") {
            if let range = try await self.buffer.redo() { self.focusEdit(at: range.lowerBound) }
            return "Buffer edit restored."
        }
    }

    private func focusEdit(at address: Int) {
        bufferOffset = (address / pageBytes) * pageBytes
        addressText = String(address, radix: 16).uppercased()
        byteAddressText = addressText
        lastSearch = nil
        lastFoundOffset = nil
    }

    private func parseHexNumber(_ input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = text.lowercased().hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return Int(digits, radix: 16)
    }

    private func confirmDiscardBuffer() -> Bool {
        guard bufferDirty else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The buffer has unsaved changes"
        alert.informativeText = "Loading another dump will discard those changes."
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var readyForChipOperation: Bool {
        guard !busy, isT76, !selectedChip.isEmpty else { return false }
        if !canReadSelected {
            status = "Error: Select a database chip with a code region of 1 byte to 2 GiB."
            return false
        }
        return true
    }

    private var readyForMutation: Bool {
        guard readyForChipOperation else { return false }
        if !canWriteSelected {
            status = "Error: Programming requires a database electronic ID and a code region no larger than 2 GiB."
            return false
        }
        return true
    }

    private func perform(_ arguments: [String], databasePath selectedDatabase: String? = nil,
                         cleanup: (() -> Void)? = nil,
                         success: @escaping ([String: Any]) -> Void) {
        guard !busy else { cleanup?(); return }
        let operation = arguments.first ?? "operation"
        let startedAt = Date()
        var stageStartedAt = startedAt
        var lastMilestone = -1
        busy = true
        progress = nil
        currentStage = "Starting \(operation)…"
        status = "Running: \(operation)…"
        let chipCommands: Set<String> = ["read", "write", "erase", "blank", "verify", "detect", "describe", "check"]
        let target = chipCommands.contains(operation) && !selectedChip.isEmpty ? " for \(selectedChip)" : ""
        appendLog("Started \(operation)\(target).")
        runner.run(arguments, databasePath: selectedDatabase ?? databasePath, onEvent: { [weak self] event in
            guard let self else { return }
            if let stage = event["stage"] as? String {
                if let previous = self.currentStage, !previous.hasPrefix("Starting ") {
                    self.appendLog("Finished \(previous) after \(String(format: "%.1f", Date().timeIntervalSince(stageStartedAt))) s.")
                }
                self.currentStage = stage
                self.progress = nil
                stageStartedAt = Date()
                lastMilestone = -1
                self.appendLog("Stage: \(stage).")
            } else if let value = event["progress"] as? [String: Any],
               let done = value["done"] as? Double,
               let total = value["total"] as? Double, total > 0 {
                self.progress = min(1, done / total)
                let milestone = min(10, max(0, Int(done / total * 10)))
                if milestone > lastMilestone {
                    lastMilestone = milestone
                    self.appendLog("\(self.currentStage ?? operation): \(milestone * 10)% (\(Int(done).formatted()) / \(Int(total).formatted()) bytes).")
                }
            } else if let note = event["note"] as? String {
                self.appendLog("Note: \(note)")
            } else if let warning = event["warn"] {
                self.appendLog("Warning: \(self.warningDescription(warning))")
            }
        }, completion: { [weak self] result in
            defer { cleanup?() }
            guard let self else { return }
            if let stage = self.currentStage, !stage.hasPrefix("Starting ") {
                self.appendLog("Finished \(stage) after \(String(format: "%.1f", Date().timeIntervalSince(stageStartedAt))) s.")
            }
            self.busy = false
            self.progress = nil
            self.currentStage = nil
            switch result {
            case .success(let value):
                let reportedOperation = value["op"] as? String ?? operation
                let detail: String
                if reportedOperation == "write" {
                    detail = "readback verification passed"
                } else if reportedOperation == "read" {
                    detail = (value["stable"] as? Bool == true) ? "two reads matched" : "two reads differed"
                } else if reportedOperation == "verify" {
                    detail = (value["matches"] as? Bool == true) ? "file matches chip" : "file differs from chip"
                } else {
                    detail = "completed"
                }
                self.appendLog("Result: \(reportedOperation), \(detail); total \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s.")
                success(value)
            case .failure(let error):
                let message = self.englishErrorDetails(error)
                self.status = "Error: \(message)"
                self.appendLog("Failed \(operation) after \(String(format: "%.1f", Date().timeIntervalSince(startedAt))) s: \(message)")
            }
        })
    }

    private func appendLog(_ message: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        log.append("[\(formatter.string(from: Date()))] \(message)")
    }

    private func warningDescription(_ warning: Any) -> String {
        if let code = warning as? String, code == "firmware_mismatch" {
            return "T76 firmware differs from the chip database target; verify the result carefully."
        }
        if let details = warning as? [String: Any] {
            if let pins = details["bad_contact"] as? [Int] {
                return "Poor contact on socket pins \(pins.map(String.init).joined(separator: ", "))."
            }
            if let mismatch = details["chip_id_mismatch"] as? [String: Any] {
                return "Chip ID differs from the selected database entry: \(mismatch)."
            }
        }
        return String(describing: warning)
    }

    nonisolated private func makePrivateTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xgecu-pro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    nonisolated private func makePrivateImageSnapshot(of source: URL) throws -> (directory: URL, file: URL) {
        let directory = try makePrivateTemporaryDirectory()
        do {
            let suffix = source.pathExtension.isEmpty ? "bin" : source.pathExtension
            let file = directory.appendingPathComponent("program.\(suffix)")
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            let raw = ["bin", "rom", "raw"].contains(source.pathExtension.lowercased())
            let limit = (raw ? 2 : 8) * 1024 * 1024 * 1024
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw MiniProFailure(message: "Could not create a private image snapshot.", hint: nil)
            }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            var copied = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard chunk.count <= limit - copied else {
                    throw MiniProFailure(message: raw ? "The raw image exceeds the 2 GiB image limit." : "The image exceeds the 8 GiB text input limit.", hint: nil)
                }
                try output.write(contentsOf: chunk)
                copied += chunk.count
            }
            try output.synchronize()
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
            return (directory, file)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func openImage(_ url: URL, successStatus: String? = nil, originChip: String? = nil) {
        do {
            let directory = try makePrivateTemporaryDirectory()
            let raw = directory.appendingPathComponent("image.bin")
            var loading = false
            perform(["convert", url.path, raw.path, "--input-format", inputFormat(for: url)], cleanup: {
                if !loading { try? FileManager.default.removeItem(at: directory) }
            }) { [weak self] _ in
                guard let self else { return }
                loading = true
                self.bufferTask("Loading image and computing checksum", newDocument: true, cleanup: {
                    try? FileManager.default.removeItem(at: directory)
                }) {
                    try await self.buffer.load(raw)
                    self.bufferSize = await self.buffer.count
                    self.bufferOffset = 0
                    self.addressText = "0"
                    self.byteAddressText = "0"
                    self.lastSearch = nil
                    self.lastFoundOffset = nil
                    self.lastFile = url
                    self.bufferChip = originChip
                    return successStatus ?? "Image loaded: \(url.lastPathComponent), \(self.bufferSize) bytes."
                }
            }
        } catch {
            status = "Error: Could not open the image (\(englishErrorDetails(error)))."
        }
    }

    private func inputFormat(for url: URL) -> String {
        ["bin", "rom", "raw"].contains(url.pathExtension.lowercased()) ? "raw" : "auto"
    }

    private func beginLocalOperation(_ stage: String) {
        busy = true
        progress = nil
        currentStage = stage
        status = stage + "…"
        appendLog("Started \(stage).")
    }

    private func failLocalOperation(_ error: Error) {
        busy = false
        currentStage = nil
        progress = nil
        status = "Error: \(englishErrorDetails(error))"
        appendLog(status)
    }

    private func bufferTask(_ stage: String, refresh: Bool = true, newDocument: Bool = false,
                            cleanup: (() -> Void)? = nil,
                            operation: @escaping @MainActor () async throws -> String) {
        guard !busy else { cleanup?(); return }
        beginLocalOperation(stage)
        Task {
            defer { cleanup?() }
            do {
                let message = try await operation()
                if refresh { try await updateBufferState() }
                if newDocument { cleanSHA256 = bufferSHA256; bufferDirty = false }
                status = message
                appendLog(message)
                busy = false
                currentStage = nil
                progress = nil
            } catch { failLocalOperation(error) }
        }
    }

    private func englishErrorDetails(_ error: Error) -> String {
        if let failure = error as? MiniProFailure {
            return failure.errorDescription ?? "minipro failed"
        }
        if let failure = error as? HexBufferError {
            return failure.errorDescription ?? "Invalid buffer"
        }
        let value = error as NSError
        return "\(value.domain), code \(value.code)"
    }

    private func updateBufferState() async throws {
        bufferSHA256 = try await buffer.sha256()
        bufferSize = await buffer.count
        bufferDirty = bufferSHA256 != cleanSHA256
        canUndo = await buffer.canUndo
        canRedo = await buffer.canRedo
        try await renderCurrentPage()
    }

    private func renderPage() {
        Task {
            do { try await renderCurrentPage() }
            catch { status = "Error: \(englishErrorDetails(error))" }
        }
    }

    private func renderCurrentPage() async throws {
        let address = bufferOffset
        let page = try await buffer.page(at: address, count: pageBytes)
        guard address == bufferOffset else { return }
        hexPreview = stride(from: 0, to: page.count, by: 16).map { offset in
            let line = page[offset..<min(offset + 16, page.count)]
            let hex = line.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = line.map { (32...126).contains(Int($0)) ? String(UnicodeScalar($0)) : "." }.joined()
            let paddedHex = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            return String(format: "%08X", address + offset) + "  " + paddedHex + "  " + ascii
        }.joined(separator: "\n")
    }
}
