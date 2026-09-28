import AppKit
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

    private let runner = MiniProRunner()
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
        let panel = NSSavePanel()
        panel.nameFieldStringValue = selectedChip.replacingOccurrences(of: "@", with: "_") + ".bin"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(["read", selectedChip, url.path]) { [weak self] result in
            guard let self else { return }
            self.lastFile = url
            self.loadPreview(url)
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

    private func loadPreview(_ url: URL) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            hexPreview = "Не удалось открыть дамп."
            return
        }
        defer { try? handle.close() }
        let bytes = (try? handle.read(upToCount: 4096)) ?? Data()
        let array = Array(bytes)
        hexPreview = stride(from: 0, to: array.count, by: 16).map { offset in
            let line = array[offset..<min(offset + 16, array.count)]
            let hex = line.map { String(format: "%02X", $0) }.joined(separator: " ")
            let ascii = line.map { (32...126).contains(Int($0)) ? String(UnicodeScalar($0)) : "." }.joined()
            let paddedHex = hex.padding(toLength: 47, withPad: " ", startingAt: 0)
            return String(format: "%08X", UInt32(offset)) + "  " + paddedHex + "  " + ascii
        }.joined(separator: "\n")
        if array.count == 4096 { hexPreview += "\n… показаны первые 4096 байт" }
    }
}
