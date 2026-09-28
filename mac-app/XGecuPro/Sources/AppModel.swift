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
    @Published var addressText = "0"
    @Published var findText = ""
    @Published var fillStartText = "0"
    @Published var fillEndText = "0"
    @Published var fillByteText = "FF"

    private let runner = MiniProRunner()
    private let maxBufferBytes = 64 * 1024 * 1024
    private let pageBytes = 256
    private var buffer = Data()
    private var lastSearch: Data?
    private var lastFoundOffset: Int?
    private let readableNames = ["AT27C256R@", "MX27C2000@", "W27C512@", "W27C257@"]
    private let writableNames = ["W27C512@", "W27C257@"]

    var canReadSelected: Bool {
        isT76 && readableNames.contains(where: { selectedChip.uppercased().hasPrefix($0) })
    }

    var canWriteSelected: Bool {
        isT76 && writableNames.contains(where: { selectedChip.uppercased().hasPrefix($0) })
    }

    func connect() {
        perform(["info"]) { [weak self] result in
            guard let self else { return }
            let model = result["model"] as? String ?? "Unknown model"
            let firmware = result["fw"] as? String ?? "?"
            let link = result["link"] as? String ?? "?"
            self.isT76 = model == "T76"
            self.deviceStatus = "\(model) · firmware \(firmware) · USB \(link)"
            if !self.isT76 {
                self.status = "This version of the app supports only the T76."
            } else if link == "ss" {
                self.status = "On Apple Silicon, connect the T76 through a USB 2.0 cable or hub."
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
            guard self.loadBuffer(url) else { return }
            let stable = result["stable"] as? Bool ?? false
            self.status = stable
                ? "Dump saved and confirmed by a second read."
                : "The dump was saved, but the second read differed. Check the chip contact and read it again."
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

        perform(["write", selectedChip, url.path, "--dry-run"]) { [weak self] _ in
            guard let self else { return }
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Program \(self.selectedChip)?"
            alert.informativeText = "Preflight passed. This will change the chip contents; erasable chips are erased before programming. Save the original dump first."
            alert.addButton(withTitle: "Program and Verify")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.perform(["write", self.selectedChip, url.path]) { [weak self] _ in
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
        status = "Local database selected: \(url.lastPathComponent)."
    }

    func openBuffer() {
        guard !busy, confirmDiscardBuffer() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = loadBuffer(url)
    }

    func saveBuffer() {
        guard !busy, bufferSize > 0 else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = lastFile?.lastPathComponent ?? "buffer.bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try buffer.write(to: url, options: .atomic)
            lastFile = url
            bufferDirty = false
            status = "Buffer saved: \(url.lastPathComponent)."
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
            let other = try readBoundedFile(url)
            let common = min(buffer.count, other.count)
            if buffer == other {
                status = "The buffer matches \(url.lastPathComponent) byte for byte."
            } else {
                let mismatch = zip(buffer.prefix(common), other.prefix(common))
                    .enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? common
                status = String(format: "Difference from %@ at address 0x%X (sizes: %d and %d bytes).",
                                url.lastPathComponent, mismatch, buffer.count, other.count)
            }
        } catch {
            status = "Error: Could not compare the files (\(englishErrorDetails(error)))."
        }
    }

    func previousPage() {
        guard bufferOffset > 0 else { return }
        bufferOffset = max(0, bufferOffset - pageBytes)
        lastFoundOffset = nil
        addressText = String(bufferOffset, radix: 16).uppercased()
        renderPage()
    }

    func nextPage() {
        guard bufferOffset + pageBytes < bufferSize else { return }
        bufferOffset += pageBytes
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
        let start = min(bufferSize, lastSearch == needle ? (lastFoundOffset ?? bufferOffset) + 1 : bufferOffset)
        let match = buffer.range(of: needle, in: start..<bufferSize)
            ?? buffer.range(of: needle, in: 0..<start)
        guard let match else {
            status = "Byte sequence not found."
            return
        }
        bufferOffset = (match.lowerBound / pageBytes) * pageBytes
        lastSearch = needle
        lastFoundOffset = match.lowerBound
        addressText = String(match.lowerBound, radix: 16).uppercased()
        renderPage()
        status = String(format: "Found at address 0x%X.", match.lowerBound)
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
        buffer.replaceSubrange(start...end, with: Data(repeating: UInt8(value), count: end - start + 1))
        bufferDirty = true
        updateChecksum()
        lastFoundOffset = nil
        bufferOffset = (start / pageBytes) * pageBytes
        addressText = String(start, radix: 16).uppercased()
        renderPage()
        status = "Buffer modified. Save it before programming."
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
            status = "Error: This version supports hardware-tested AT27C256R, MX27C2000, W27C512, and W27C257 parts only."
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

    private func perform(_ arguments: [String], success: @escaping ([String: Any]) -> Void) {
        guard !busy else { return }
        busy = true
        progress = nil
        status = "Running: \(arguments.first ?? "operation")…"
        runner.run(arguments, databasePath: databasePath, onEvent: { [weak self] event in
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

    @discardableResult
    private func loadBuffer(_ url: URL) -> Bool {
        do {
            let bytes = try readBoundedFile(url)
            buffer = bytes
            bufferSize = bytes.count
            bufferOffset = 0
            addressText = "0"
            bufferDirty = false
            lastSearch = nil
            lastFoundOffset = nil
            lastFile = url
            updateChecksum()
            renderPage()
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
        bufferSHA256 = SHA256.hash(data: buffer).map { String(format: "%02x", $0) }.joined()
    }

    private func renderPage() {
        let end = min(bufferOffset + pageBytes, bufferSize)
        hexPreview = stride(from: bufferOffset, to: end, by: 16).map { offset in
            let line = buffer[offset..<min(offset + 16, end)]
            let hex = line.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = line.map { (32...126).contains(Int($0)) ? String(UnicodeScalar($0)) : "." }.joined()
            let paddedHex = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            return String(format: "%08X", offset) + "  " + paddedHex + "  " + ascii
        }.joined(separator: "\n")
    }
}
