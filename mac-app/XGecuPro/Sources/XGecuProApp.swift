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
                    ScrollView {
                        Text(model.hexPreview.isEmpty ? "После чтения здесь появится начало дампа." : model.hexPreview)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
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
