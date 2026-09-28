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
    @Published var deviceStatus = "Программатор не проверен"
    @Published var status = "Подключите T76 через USB 2.0 и нажмите «Подключить»."
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
            let model = result["model"] as? String ?? "Неизвестная модель"
            let firmware = result["fw"] as? String ?? "?"
            let link = result["link"] as? String ?? "?"
            self.isT76 = model == "T76"
            self.deviceStatus = "\(model) · прошивка \(firmware) · USB \(link)"
            if !self.isT76 {
                self.status = "Первая версия GUI поддерживает только T76."
            } else if link == "ss" {
                self.status = "T76 на Apple Silicon требует кабель или хаб USB 2.0."
            } else {
                self.status = "T76 подключён. Выберите микросхему."
            }
        }
    }

    func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        perform(["search", text, "--limit", "100"]) { [weak self] result in
            self?.hits = result["hits"] as? [String] ?? []
            self?.status = "Найдено: \(result["n"] as? Int ?? 0)."
        }
    }

    func detect() {
        guard readyForChipOperation else { return }
        perform(["detect", "--like", selectedChip]) { [weak self] result in
            let id = result["id"] as? String ?? "?"
            let matches = result["matches"] as? [String] ?? []
            self?.status = "ID: 0x\(id). Совпадения: \(matches.prefix(4).joined(separator: ", "))."
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
                ? "Дамп сохранён и совпал при повторном чтении."
                : "Дамп сохранён, но повторное чтение отличается — проверьте контакт и перечитайте чип."
        }
    }

    func blankCheck() {
        guard readyForChipOperation else { return }
        perform(["blank", selectedChip]) { [weak self] result in
            let blank = result["blank"] as? Bool ?? false
            self?.status = blank
                ? "Микросхема пуста: все байты совпали со значением стирания."
                : "Микросхема не пуста. Перед стиранием сохраните дамп."
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
                self.status = "Повторные чтения чипа различаются; сравнение ненадёжно. Проверьте контакт."
            } else if result["matches"] as? Bool == true {
                self.status = "Содержимое чипа совпадает с файлом."
            } else if let offset = result["first_mismatch"] as? Int {
                self.status = String(format: "Различие с файлом по адресу 0x%06X.", offset)
            } else {
                self.status = "Содержимое чипа не совпадает с файлом."
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
            alert.messageText = "Записать \(self.selectedChip)?"
            alert.informativeText = "Подготовка прошла успешно. Содержимое микросхемы будет изменено; для стираемых чипов перед записью выполняется стирание. Исходный дамп рекомендуется сохранить."
            alert.addButton(withTitle: "Записать и проверить")
            alert.addButton(withTitle: "Отмена")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            self.perform(["write", self.selectedChip, url.path]) { [weak self] _ in
                self?.status = "Запись завершена; данные проверены обратным чтением."
            }
        }
    }

    func eraseChip() {
        guard readyForMutation else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Стереть \(selectedChip)?"
        alert.informativeText = "Все данные на микросхеме будут удалены. Сначала сохраните дамп."
        alert.addButton(withTitle: "Стереть")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        perform(["erase", selectedChip]) { [weak self] _ in
            self?.status = "Стирание завершено."
        }
    }

    func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        databasePath = url.path
        status = "Выбрана локальная база: \(url.lastPathComponent)."
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
            status = "Буфер сохранён: \(url.lastPathComponent)."
        } catch {
            status = "Не удалось сохранить буфер: \(error.localizedDescription)"
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
                status = "Буфер полностью совпадает с \(url.lastPathComponent)."
            } else {
                let mismatch = zip(buffer.prefix(common), other.prefix(common))
                    .enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset ?? common
                status = String(format: "Различие с %@ по адресу 0x%X (размеры: %d и %d байт).",
                                url.lastPathComponent, mismatch, buffer.count, other.count)
            }
        } catch {
            status = "Не удалось сравнить файлы: \(error.localizedDescription)"
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
            status = "Адрес вне буфера. Введите шестнадцатеричное смещение."
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
            status = "Введите от 1 до 256 байт в виде HEX, например DE AD BE EF."
            return
        }
        let chars = Array(cleaned)
        let needle = Data(stride(from: 0, to: chars.count, by: 2).compactMap {
            UInt8(String(chars[$0...($0 + 1)]), radix: 16)
        })
        guard needle.count == chars.count / 2 else {
            status = "Некорректная HEX-последовательность."
            return
        }
        let start = min(bufferSize, lastSearch == needle ? (lastFoundOffset ?? bufferOffset) + 1 : bufferOffset)
        let match = buffer.range(of: needle, in: start..<bufferSize)
            ?? buffer.range(of: needle, in: 0..<start)
        guard let match else {
            status = "Последовательность не найдена."
            return
        }
        bufferOffset = (match.lowerBound / pageBytes) * pageBytes
        lastSearch = needle
        lastFoundOffset = match.lowerBound
        addressText = String(match.lowerBound, radix: 16).uppercased()
        renderPage()
        status = String(format: "Найдено по адресу 0x%X.", match.lowerBound)
    }

    func fillRange() {
        guard !busy, bufferSize > 0 else { return }
        guard let start = parseHexNumber(fillStartText),
              let end = parseHexNumber(fillEndText),
              let value = parseHexNumber(fillByteText),
              start >= 0, start <= end, end < bufferSize, value >= 0, value <= 0xFF else {
            status = "Укажите корректный диапазон адресов и байт заполнения в HEX."
            return
        }
        let alert = NSAlert()
        alert.messageText = "Заполнить диапазон буфера?"
        alert.informativeText = String(format: "Адреса 0x%X…0x%X будут заменены на 0x%02X. Изменение пока не записывается в чип.", start, end, value)
        alert.addButton(withTitle: "Заполнить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        buffer.replaceSubrange(start...end, with: Data(repeating: UInt8(value), count: end - start + 1))
        bufferDirty = true
        updateChecksum()
        lastFoundOffset = nil
        bufferOffset = (start / pageBytes) * pageBytes
        addressText = String(start, radix: 16).uppercased()
        renderPage()
        status = "Буфер изменён. Сохраните его перед записью."
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
        alert.messageText = "В буфере есть несохранённые изменения"
        alert.informativeText = "При загрузке другого дампа изменения будут потеряны."
        alert.addButton(withTitle: "Продолжить без сохранения")
        alert.addButton(withTitle: "Отмена")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private var readyForChipOperation: Bool {
        guard !busy, isT76, !selectedChip.isEmpty else { return false }
        if !canReadSelected {
            status = "В первой версии доступны аппаратно проверенные AT27C256R, MX27C2000, W27C512 и W27C257."
            return false
        }
        return true
    }

    private var readyForMutation: Bool {
        guard readyForChipOperation else { return false }
        if !canWriteSelected {
            status = "В первой версии запись и стирание доступны для W27C512 и W27C257."
            return false
        }
        return true
    }

    private func perform(_ arguments: [String], success: @escaping ([String: Any]) -> Void) {
        guard !busy else { return }
        busy = true
        progress = nil
        status = "Выполняется: \(arguments.first ?? "операция")…"
        runner.run(arguments, databasePath: databasePath, onEvent: { [weak self] event in
            guard let self else { return }
            if let value = event["progress"] as? [String: Any],
               let done = value["done"] as? Double,
               let total = value["total"] as? Double, total > 0 {
                self.progress = min(1, done / total)
            } else if let note = event["note"] as? String {
                self.log.append(note)
            } else if event["warn"] != nil {
                self.log.append("Предупреждение: \(event)")
            }
        }, completion: { [weak self] result in
            guard let self else { return }
            self.busy = false
            self.progress = nil
            switch result {
            case .success(let value):
                success(value)
            case .failure(let error):
                self.status = error.localizedDescription
                self.log.append(error.localizedDescription)
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
            status = "Дамп загружен: \(url.lastPathComponent), \(bytes.count) байт."
            return true
        } catch {
            status = "Не удалось прочитать дамп: \(error.localizedDescription)"
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
            "Размер дампа должен быть от 1 байта до 64 МиБ."
        }
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
