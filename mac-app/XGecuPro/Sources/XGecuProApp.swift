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
                GroupBox("Programmer") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.deviceStatus).font(.callout)
                        Button("Connect / Refresh") { model.connect() }
                            .disabled(model.busy)
                        Button("Auto Detect SOIC16") { model.autoDetectSOIC16() }
                            .disabled(model.busy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    TextField("Search for a chip", text: $model.query)
                        .onSubmit { model.search() }
                    Button("Search") { model.search() }
                        .disabled(model.busy || model.query.isEmpty)
                }
                List(model.hits, id: \.self) { chip in
                    Button {
                        model.selectChip(chip)
                    } label: {
                        Text(chip).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                    .listRowBackground(model.selectedChip == chip ? Color.accentColor.opacity(0.15) : Color.clear)
                }
                Text("Database: " + (model.databasePath.isEmpty ? "automatic" : model.databasePath))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Button("Choose Local Database…") { model.chooseDatabase() }
                    .disabled(model.busy)
            }
            .padding()
            .navigationTitle("Chips")
            .frame(minWidth: 300)
        } detail: {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.selectedChip.isEmpty ? "Select a chip" : model.selectedChip)
                    .font(.title2.bold())
                if let details = model.chipDetails, details.name == model.selectedChip {
                    GroupBox("Chip details · database") {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Package: \(details.package) · \(details.pins) pins")
                            Text("Code: \(details.codeBytes.formatted()) bytes · Data: \(details.dataBytes.formatted()) bytes")
                            if details.extraDataBytes > 0 {
                                Text("Extra data: \(details.extraDataBytes.formatted()) bytes")
                            }
                            Text("Page: \(details.pageBytes.formatted()) bytes · Erased value: 0x\(details.blankValue)")
                            Text("Electronic ID: \(details.chipID.map { "0x" + $0 } ?? "not specified")")
                            Text(details.canErase ? "Database marks this chip as erasable." : "Database does not mark this chip as erasable.")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                HStack {
                    Button("Detect ID") { model.detect() }
                        .disabled(!model.canReadSelected)
                    Button("Read…") { model.readChip() }
                        .disabled(!model.canReadSelected)
                    Button("Blank Check") { model.blankCheck() }
                        .disabled(!model.canReadSelected)
                    Button("Verify Against File…") { model.verifyChip() }
                        .disabled(!model.canReadSelected)
                    Button("Program…") { model.writeChip() }
                        .disabled(!model.canWriteSelected)
                    Button("Erase") { model.eraseChip() }
                        .disabled(!model.canWriteSelected)
                }
                .disabled(model.busy || !model.isT76 || model.selectedChip.isEmpty)
                if model.busy {
                    if let progress = model.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView()
                    }
                    Text("Wait for the operation to finish; socket power is turned off afterward.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(model.status)
                    .foregroundColor(model.status.hasPrefix("Error:") ? .red : .primary)
                    .textSelection(.enabled)
                TabView {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Open File…") { model.openBuffer() }
                                .disabled(model.busy)
                            Button("Save As…") { model.saveBuffer() }
                                .disabled(model.busy || model.bufferSize == 0)
                            Button("Compare with File…") { model.compareBufferToFile() }
                                .disabled(model.busy || model.bufferSize == 0)
                            Spacer()
                            Text(model.bufferSize == 0 ? "Buffer empty" : "\(model.bufferSize) bytes" + (model.bufferDirty ? " · modified" : ""))
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
                            Text("HEX address")
                            TextField("0", text: $model.addressText)
                                .frame(width: 90)
                                .onSubmit { model.jumpToAddress() }
                            Button("Go") { model.jumpToAddress() }
                            Spacer()
                            TextField("Find HEX bytes", text: $model.findText)
                                .frame(width: 170)
                                .onSubmit { model.findHex() }
                            Button("Find") { model.findHex() }
                        }
                        .disabled(model.busy || model.bufferSize == 0)
                        HStack {
                            TextField("Find ASCII text", text: $model.asciiFindText)
                                .frame(width: 220)
                                .onSubmit { model.findASCII() }
                            Button("Find ASCII") { model.findASCII() }
                            Spacer()
                        }
                        .disabled(model.busy || model.bufferSize == 0)
                        HStack {
                            Text("Fill 0x")
                            TextField("start", text: $model.fillStartText).frame(width: 80)
                            Text("…0x")
                            TextField("end", text: $model.fillEndText).frame(width: 80)
                            Text("with 0x")
                            TextField("FF", text: $model.fillByteText).frame(width: 46)
                            Button("Apply…") { model.fillRange() }
                        }
                        .disabled(model.busy || model.bufferSize == 0)
                        HStack {
                            Text("Block 0x")
                            TextField("start", text: $model.blockStartText).frame(width: 80)
                            Text("…0x")
                            TextField("end", text: $model.blockEndText).frame(width: 80)
                            Text("to 0x")
                            TextField("destination", text: $model.blockDestinationText).frame(width: 90)
                            Button("Copy") { model.copyBlock() }
                            Button("Export…") { model.exportBlock() }
                        }
                        .disabled(model.busy || model.bufferSize == 0)
                        HStack {
                            Text("Byte at 0x")
                            TextField("address", text: $model.byteAddressText).frame(width: 90)
                            Text("= 0x")
                            TextField("FF", text: $model.byteValueText).frame(width: 46)
                            Button("Set") { model.editByte() }
                            Spacer()
                            Button("Undo") { model.undoEdit() }
                                .disabled(!model.canUndo)
                            Button("Redo") { model.redoEdit() }
                                .disabled(!model.canRedo)
                        }
                        .disabled(model.busy || model.bufferSize == 0)
                        ScrollView {
                            Text(model.hexPreview.isEmpty ? "Read a chip or open a dump file." : model.hexPreview)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .textSelection(.enabled)
                        }
                    }
                    .tabItem { Text("Hex") }
                    ScrollView {
                        Text(model.log.isEmpty ? "No events yet." : model.log.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                            .textSelection(.enabled)
                    }
                    .tabItem { Text("Log") }
                }
            }
            .padding(22)
            .navigationTitle("T76 Operations")
        }
    }
}
