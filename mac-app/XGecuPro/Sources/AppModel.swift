import AppKit
import CryptoKit
import Foundation
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    @Published var databasePath = UserDefaults.standard.string(forKey: "databasePath") ?? "" {
        didSet { UserDefaults.standard.set(databasePath, forKey: "databasePath") }
    }
    @Published var query = ""
    @Published var hits: [String] = []
    @Published var selectedChip = ""
    @Published var chipDetails: ChipDetails?
    @Published var deviceStatus = "Programmer not checked"
    @Published var status = "Connect the T76 through USB 2.0, then click Connect / Refresh."
    @Published var busy = false
    @Published var progress: Double?
    @Published var log: [String] = []
    @Published var hexPreview = ""
    @Published var lastFile: URL?
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
    private let maxBufferBytes = 64 * 1024 * 1024
    private let pageBytes = 256
    private var buffer = HexBuffer()
    private var cleanSHA256 = ""
    private var lastSearch: Data?
    private var lastFoundOffset: Int?
    var canReadSelected: Bool {
        ChipPolicy.canRead(selectedChip, details: chipDetails, isT76: isT76)
    }

    var canWriteSelected: Bool {
        ChipPolicy.canWrite(selectedChip, isT76: isT76)
    }

    func connect() {
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
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        perform(["search", text, "--limit", "100"]) { [weak self] result in
            self?.hits = result["hits"] as? [String] ?? []
            self?.status = "Results: \(result["n"] as? Int ?? 0)."
        }
    }

    func selectChip(_ chip: String) {
        guard !busy else { return }
        selectedChip = chip
        chipDetails = nil
        perform(["describe", chip]) { [weak self] result in
            guard let self, self.selectedChip == chip else { return }
            self.chipDetails = ChipDetails(result)
            if self.chipDetails == nil {
                self.status = "Error: The chip database returned incomplete details."
            } else if ChipPolicy.isRequestedReadOnly(chip) {
                self.status = self.canReadSelected
                    ? "Read-only support is ready for hardware validation. Verify SOIC16 socket placement before inserting the chip."
                    : "Error: The database entry does not match the expected Macronix capacity and ID."
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

    func readChip() {
        guard readyForChipOperation else { return }
        guard confirmDiscardBuffer() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selectedChip.replacingOccurrences(of: "@", with: "_") + ".bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(["read", selectedChip, url.path]) { [weak self] result in
            guard let self else { return }
            let stable = result["stable"] as? Bool ?? false
            let message = stable
                ? "Dump saved and confirmed by a second read."
                : "The dump was saved, but the second read differed. Check the chip contact and read it again."
            self.openImage(url, successStatus: message)
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
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(["verify", selectedChip, url.path]) { [weak self] result in
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

    func writeChip() {
        guard readyForMutation else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let chip = selectedChip
        let selectedDatabase = databasePath
        let snapshot: (directory: URL, file: URL)
        do {
            snapshot = try makePrivateImageSnapshot(of: url)
        } catch {
            status = "Error: Could not prepare the programming image (\(englishErrorDetails(error)))."
            return
        }
        var committed = false
        perform(["write", chip, snapshot.file.path, "--dry-run"],
                databasePath: selectedDatabase,
                cleanup: {
                    if !committed { try? FileManager.default.removeItem(at: snapshot.directory) }
                }) { [weak self] _ in
            guard let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Program \(chip)?"
            alert.informativeText = "Preflight passed. This will change the chip contents; erasable chips are erased before programming. Save the original dump first."
            alert.addButton(withTitle: "Program and Verify")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            committed = true
            self.perform(["write", chip, snapshot.file.path], databasePath: selectedDatabase,
                         cleanup: { try? FileManager.default.removeItem(at: snapshot.directory) }) { [weak self] _ in
                self?.status = "Programming completed and verified by a readback."
            }
        }
    }

    func eraseChip() {
        guard readyForMutation else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Erase \(selectedChip)?"
        alert.informativeText = "All data on the chip will be erased. Save a dump first."
        alert.addButton(withTitle: "Erase")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
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
        hits = []
        selectedChip = ""
        chipDetails = nil
        status = "Local database selected: \(url.lastPathComponent)."
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
        do {
            let directory = try makePrivateTemporaryDirectory()
            let raw = directory.appendingPathComponent("buffer.bin")
            guard FileManager.default.createFile(atPath: raw.path, contents: buffer.bytes,
                                                 attributes: [.posixPermissions: 0o600]) else {
                try? FileManager.default.removeItem(at: directory)
                status = "Error: Could not prepare the buffer for saving."
                return
            }
            perform(["convert", raw.path, url.path], cleanup: {
                try? FileManager.default.removeItem(at: directory)
            }) { [weak self] _ in
                guard let self else { return }
                self.lastFile = url
                self.cleanSHA256 = self.bufferSHA256
                self.bufferDirty = false
                self.status = "Buffer saved: \(url.lastPathComponent)."
            }
        } catch {
            status = "Error: Could not save the buffer (\(englishErrorDetails(error)))."
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
            perform(["convert", url.path, raw.path], cleanup: {
                try? FileManager.default.removeItem(at: directory)
            }) { [weak self] _ in
                guard let self else { return }
                do {
                    let other = try self.readBoundedFile(raw)
                    self.compareBuffer(other, named: url.lastPathComponent)
                } catch {
                    self.status = "Error: Could not compare the files (\(self.englishErrorDetails(error)))."
                }
            }
        } catch {
            status = "Error: Could not compare the files (\(englishErrorDetails(error)))."
        }
    }

    private func compareBuffer(_ other: Data, named name: String) {
        let common = min(buffer.bytes.count, other.count)
        if buffer.bytes == other {
            status = "The buffer matches \(name) byte for byte."
        } else {
            let mismatch = zip(buffer.bytes.prefix(common), other.prefix(common))
                .enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? common
            status = String(format: "Difference from %@ at address 0x%X (sizes: %d and %d bytes).",
                            name, mismatch, buffer.bytes.count, other.count)
        }
    }

    func previousPage() {
        guard bufferOffset > 0 else { return }
        bufferOffset = max(0, bufferOffset - pageBytes)
        lastSearch = nil
        lastFoundOffset = nil
        addressText = String(bufferOffset, radix: 16).uppercased()
        renderPage()
    }

    func nextPage() {
        guard bufferOffset + pageBytes < bufferSize else { return }
        bufferOffset += pageBytes
        lastSearch = nil
        lastFoundOffset = nil
        addressText = String(bufferOffset, radix: 16).uppercased()
        renderPage()
    }

    func jumpToAddress() {
        guard bufferSize > 0 else { return }
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
        let match = buffer.find(needle, from: start)
        guard let match else {
            status = "Byte sequence not found."
            return
        }
        bufferOffset = (match / pageBytes) * pageBytes
        lastSearch = needle
        lastFoundOffset = match
        addressText = String(match, radix: 16).uppercased()
        renderPage()
        status = String(format: "Found at address 0x%X.", match)
    }

    func copyBlock() {
        guard !busy, bufferSize > 0 else { return }
        guard let start = parseHexNumber(blockStartText),
              let end = parseHexNumber(blockEndText),
              let destination = parseHexNumber(blockDestinationText) else {
            status = "Error: Enter valid HEX block and destination addresses."
            return
        }
        do {
            try buffer.copyBlock(start: start, end: end, to: destination)
        } catch {
            status = "Error: Block or destination is outside the buffer."
            return
        }
        focusEdit(at: destination)
        updateBufferState()
        status = String(format: "Copied 0x%X…0x%X to 0x%X. Save the buffer before programming.", start, end, destination)
    }

    func exportBlock() {
        guard !busy, bufferSize > 0 else { return }
        guard let start = parseHexNumber(blockStartText),
              let end = parseHexNumber(blockEndText) else {
            status = "Error: Enter a valid HEX block range."
            return
        }
        let block: Data
        do {
            block = try buffer.block(start: start, end: end)
        } catch {
            status = "Error: Block range is outside the buffer."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(format: "block_%X_%X.bin", start, end)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try block.write(to: url, options: .atomic)
            status = "Exported \(block.count) bytes to \(url.lastPathComponent)."
        } catch {
            status = "Error: Could not export the block (\(englishErrorDetails(error)))."
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
        do {
            try buffer.fill(start: start, end: end, value: UInt8(value))
        } catch {
            status = "Error: Could not fill the selected range."
            return
        }
        focusEdit(at: start)
        updateBufferState()
        status = "Buffer modified. Save it before programming."
    }

    func editByte() {
        guard !busy, bufferSize > 0 else { return }
        guard let address = parseHexNumber(byteAddressText),
              let value = parseHexNumber(byteValueText),
              address >= 0, address < bufferSize, value >= 0, value <= 0xFF else {
            status = "Error: Enter a valid HEX address and byte value."
            return
        }
        do {
            try buffer.setByte(at: address, to: UInt8(value))
        } catch {
            status = "Error: Could not edit the selected byte."
            return
        }
        focusEdit(at: address)
        updateBufferState()
        status = String(format: "Set byte at 0x%X to 0x%02X. Save the buffer before programming.", address, value)
    }

    func undoEdit() {
        guard !busy, let range = buffer.undo() else { return }
        focusEdit(at: range.lowerBound)
        updateBufferState()
        status = "Last buffer edit undone."
    }

    func redoEdit() {
        guard !busy, let range = buffer.redo() else { return }
        focusEdit(at: range.lowerBound)
        updateBufferState()
        status = "Buffer edit restored."
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
            status = "Error: Select a supported chip. The two requested Macronix SOIC16 parts require matching database details."
            return false
        }
        return true
    }

    private var readyForMutation: Bool {
        guard readyForChipOperation else { return false }
        if !canWriteSelected {
            status = "Error: Programming and erase are available only for W27C512 and W27C257."
            return false
        }
        return true
    }

    private func perform(_ arguments: [String], databasePath selectedDatabase: String? = nil,
                         cleanup: (() -> Void)? = nil,
                         success: @escaping ([String: Any]) -> Void) {
        guard !busy else { cleanup?(); return }
        busy = true
        progress = nil
        status = "Running: \(arguments.first ?? "operation")…"
        runner.run(arguments, databasePath: selectedDatabase ?? databasePath, onEvent: { [weak self] event in
            guard let self else { return }
            if let value = event["progress"] as? [String: Any],
               let done = value["done"] as? Double,
               let total = value["total"] as? Double, total > 0 {
                self.progress = min(1, done / total)
            } else if let note = event["note"] as? String {
                self.log.append(note)
            } else if event["warn"] != nil {
                self.log.append("Warning: \(event)")
            }
        }, completion: { [weak self] result in
            defer { cleanup?() }
            guard let self else { return }
            self.busy = false
            self.progress = nil
            switch result {
            case .success(let value):
                success(value)
            case .failure(let error):
                let message = self.englishErrorDetails(error)
                self.status = "Error: \(message)"
                self.log.append(message)
            }
        })
    }

    private func makePrivateTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("xgecu-pro-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    private func makePrivateImageSnapshot(of source: URL) throws -> (directory: URL, file: URL) {
        let directory = try makePrivateTemporaryDirectory()
        do {
            let suffix = source.pathExtension.isEmpty ? "bin" : source.pathExtension
            let file = directory.appendingPathComponent("program.\(suffix)")
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                                 attributes: [.posixPermissions: 0o600]) else {
                throw MiniProFailure(message: "Could not create a private image snapshot.", hint: nil)
            }
            let output = try FileHandle(forWritingTo: file)
            defer { try? output.close() }
            var copied = 0
            while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard chunk.count <= (256 * 1024 * 1024) - copied else {
                    throw MiniProFailure(message: "The image exceeds the 256 MiB input limit.", hint: nil)
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

    private func openImage(_ url: URL, successStatus: String? = nil) {
        do {
            let directory = try makePrivateTemporaryDirectory()
            let raw = directory.appendingPathComponent("image.bin")
            perform(["convert", url.path, raw.path], cleanup: {
                try? FileManager.default.removeItem(at: directory)
            }) { [weak self] _ in
                guard let self, self.loadBuffer(raw) else { return }
                self.lastFile = url
                if let successStatus {
                    self.status = successStatus
                } else {
                    self.status = "Image loaded: \(url.lastPathComponent), \(self.bufferSize) bytes."
                }
            }
        } catch {
            status = "Error: Could not open the image (\(englishErrorDetails(error)))."
        }
    }

    @discardableResult
    private func loadBuffer(_ url: URL) -> Bool {
        do {
            let bytes = try readBoundedFile(url)
            buffer.load(bytes)
            bufferSize = bytes.count
            bufferOffset = 0
            addressText = "0"
            byteAddressText = "0"
            lastSearch = nil
            lastFoundOffset = nil
            lastFile = url
            updateBufferState()
            cleanSHA256 = bufferSHA256
            bufferDirty = false
            status = "Dump loaded: \(url.lastPathComponent), \(bytes.count) bytes."
            return true
        } catch {
            status = "Error: Could not read the dump (\(englishErrorDetails(error)))."
            return false
        }
    }

    private func readBoundedFile(_ url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var bytes = Data()
        while bytes.count <= maxBufferBytes {
            let chunk = try handle.read(upToCount: min(1024 * 1024, maxBufferBytes + 1 - bytes.count)) ?? Data()
            if chunk.isEmpty { break }
            bytes.append(chunk)
        }
        guard !bytes.isEmpty, bytes.count <= maxBufferBytes else {
            throw BufferError.invalidSize
        }
        return bytes
    }

    private enum BufferError: LocalizedError {
        case invalidSize

        var errorDescription: String? {
            "The dump must be between 1 byte and 64 MiB."
        }
    }

    private func englishErrorDetails(_ error: Error) -> String {
        if let failure = error as? MiniProFailure {
            return failure.errorDescription ?? "minipro failed"
        }
        if let failure = error as? BufferError {
            return failure.errorDescription ?? "Invalid buffer"
        }
        let value = error as NSError
        return "\(value.domain), code \(value.code)"
    }

    private func updateChecksum() {
        bufferSHA256 = SHA256.hash(data: buffer.bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func updateBufferState() {
        updateChecksum()
        bufferDirty = bufferSHA256 != cleanSHA256
        canUndo = buffer.canUndo
        canRedo = buffer.canRedo
        renderPage()
    }

    private func renderPage() {
        let end = min(bufferOffset + pageBytes, bufferSize)
        hexPreview = stride(from: bufferOffset, to: end, by: 16).map { offset in
            let line = buffer.bytes[offset..<min(offset + 16, end)]
            let hex = line.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = line.map { (32...126).contains(Int($0)) ? String(UnicodeScalar($0)) : "." }.joined()
            let paddedHex = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            return String(format: "%08X", offset) + "  " + paddedHex + "  " + ascii
        }.joined(separator: "\n")
    }
}
