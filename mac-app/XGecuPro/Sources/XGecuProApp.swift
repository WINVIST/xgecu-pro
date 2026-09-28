import SwiftUI

@main
struct XGecuProApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("XGecu Pro") {
            ContentView(model: model)
                .frame(minWidth: 940, minHeight: 620)
        }
    }
}

private struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Программатор") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.deviceStatus).font(.callout)
                        Button("Подключить / обновить") { model.connect() }
                            .disabled(model.busy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    TextField("Поиск микросхемы", text: $model.query)
                        .onSubmit { model.search() }
                    Button("Найти") { model.search() }
                        .disabled(model.busy || model.query.isEmpty)
                }
                List(model.hits, id: \.self) { chip in
                    Button {
                        model.selectedChip = chip
                    } label: {
                        Text(chip).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(model.selectedChip == chip ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                Text("База: " + (model.databasePath.isEmpty ? "автоматическая" : model.databasePath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Выбрать локальную базу…") { model.chooseDatabase() }
                    .disabled(model.busy)
            }
            .padding()
            .navigationTitle("Микросхемы")
            .frame(minWidth: 300)
        } detail: {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.selectedChip.isEmpty ? "Выберите микросхему" : model.selectedChip)
                    .font(.title2.bold())
                HStack {
                    Button("Определить ID") { model.detect() }
                        .disabled(!model.canReadSelected)
                    Button("Прочитать…") { model.readChip() }
                        .disabled(!model.canReadSelected)
                    Button("Проверить пустоту") { model.blankCheck() }
                        .disabled(!model.canReadSelected)
                    Button("Сравнить с файлом…") { model.verifyChip() }
                        .disabled(!model.canReadSelected)
                    Button("Записать…") { model.writeChip() }
                        .disabled(!model.canWriteSelected)
                    Button("Стереть") { model.eraseChip() }
                        .disabled(!model.canWriteSelected)
                }
                .disabled(model.busy || !model.isT76 || model.selectedChip.isEmpty)
                if model.busy {
                    if let progress = model.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                    Text("Дождитесь завершения операции; питание сокета отключается после неё.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(model.status)
                    .foregroundColor(model.status.contains("ошиб") ? .red : .primary)
                    .textSelection(.enabled)
                TabView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Открыть файл…") { model.openBuffer() }
                                .disabled(model.busy)
                            Button("Сохранить как…") { model.saveBuffer() }
                                .disabled(model.busy || model.bufferSize == 0)
                            Button("Сравнить с файлом…") { model.compareBufferToFile() }
                                .disabled(model.busy || model.bufferSize == 0)
                            Spacer()
                            Text(model.bufferSize == 0 ? "Буфер пуст" : "\(model.bufferSize) байт" + (model.bufferDirty ? " · изменён" : ""))
                                .foregroundStyle(.secondary)
                        }
                        if model.bufferSize > 0 {
                            Text("SHA-256: \(model.bufferSHA256)")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        HStack {
                            Button("‹") { model.previousPage() }
                                .disabled(model.bufferOffset == 0)
                            Button("›") { model.nextPage() }
                                .disabled(model.bufferOffset + 256 >= model.bufferSize)
                            Text("Адрес HEX")
                            TextField("0", text: $model.addressText)
                                .frame(width: 90)
                                .onSubmit { model.jumpToAddress() }
                            Button("Перейти") { model.jumpToAddress() }
                            Spacer()
                            TextField("Найти байты HEX", text: $model.findText)
                                .frame(width: 170)
                                .onSubmit { model.findHex() }
                            Button("Найти") { model.findHex() }
                        }
                        .disabled(model.busy || model.bufferSize == 0)
                        HStack {
                            Text("Заполнить 0x")
                            TextField("начало", text: $model.fillStartText).frame(width: 80)
                            Text("…0x")
                            TextField("конец", text: $model.fillEndText).frame(width: 80)
                            Text("значением 0x")
                            TextField("FF", text: $model.fillByteText).frame(width: 46)
                            Button("Применить…") { model.fillRange() }
                        }
                        .disabled(model.busy || model.bufferSize == 0)
                        ScrollView {
                            Text(model.hexPreview.isEmpty ? "Прочитайте микросхему или откройте файл дампа." : model.hexPreview)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .textSelection(.enabled)
                        }
                    }
                    .tabItem { Text("Hex") }
                    ScrollView {
                        Text(model.log.isEmpty ? "Событий пока нет." : model.log.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                    .tabItem { Text("Журнал") }
                }
            }
            .padding(22)
            .navigationTitle("Операции T76")
        }
    }
}
