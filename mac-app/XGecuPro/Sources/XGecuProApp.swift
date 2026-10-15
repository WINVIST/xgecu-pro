import AppKit
import SwiftUI

#if !UI_PREVIEW
@main
struct XGecuProApp: App {
    @NSApplicationDelegateAdaptor(AppExitDelegate.self) private var exitDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("XGecu Pro") {
            ContentView(model: model)
                .frame(minWidth: 1020, minHeight: 680)
                .onAppear { exitDelegate.model = model }
        }
        .defaultSize(width: 1180, height: 820)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Choose Firmware…") { model.chooseProgrammingFile() }
                    .keyboardShortcut("o").disabled(model.busy)
                Button("Open File in Hex Editor…") { model.openBuffer() }
                    .keyboardShortcut("o", modifiers: [.command, .shift]).disabled(model.busy)
                Button("Save Hex Buffer As…") { model.saveBuffer() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                    .disabled(model.busy || model.bufferSize == 0)
            }
            CommandMenu("Programmer") {
                Button("Connect / Refresh") { model.connect() }
                    .keyboardShortcut("r").disabled(model.busy)
                Button("USB Diagnostics…") { model.showUSBDiagnostics = true }
                    .disabled(model.busy)
                Button("Auto Detect SOIC16") { model.autoDetectSOIC16() }
                    .disabled(model.busy || !model.isT76)
            }
        }
    }
}
#endif

@MainActor
final class AppExitDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.busy {
            let alert = NSAlert()
            alert.messageText = "An operation is still running"
            alert.informativeText = "Wait for \(model.currentStage ?? "the current operation") to finish before quitting."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return .terminateCancel
        }
        guard model.bufferDirty else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The Hex Editor has unsaved changes"
        alert.informativeText = "Quitting will discard them. Choose Cancel, then Save Hex Buffer As to keep your edits."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit and Discard")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var selectedTab = 0

    init(model: AppModel, initialTab: Int = 0) {
        self.model = model
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationSplitView {
            ChipSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 340)
        } detail: {
            VStack(spacing: 0) {
                TabView(selection: $selectedTab) {
                    ProgrammingWorkspace(model: model)
                        .tabItem { Label("Program", systemImage: "cpu") }.tag(0)
                    HexWorkspace(model: model)
                        .tabItem { Label("Hex Editor", systemImage: "doc.text") }.tag(1)
                    ActivityWorkspace(model: model)
                        .tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }.tag(2)
                }
                .padding(16)
                Divider()
                OperationStatus(model: model)
                    .padding(.horizontal, 20).padding(.vertical, 12)
            }
            .navigationTitle("XGecu Pro")
        }
        .onChange(of: model.bufferSize) { _, size in
            if size > 0 { selectedTab = 1 }
        }
        .sheet(isPresented: $model.showUSBDiagnostics) {
            USBDiagnosticsView(model: model)
        }
        .onChange(of: model.lastFile) { _, file in
            if file != nil && model.bufferSize > 0 { selectedTab = 1 }
        }
        .onChange(of: model.programmingFile) { _, file in
            if file != nil { selectedTab = 0 }
        }
    }
}

struct USBDiagnosticsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("T76 USB Diagnostics", systemImage: "stethoscope").font(.title2.bold())
            Text("Remove the chip. Unplug and reconnect the T76 before each test. Keep it connected until the test finishes.")
            Text("Tests programmer information only. Validate full chip reads separately before relying on USB 3.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Connection", selection: $model.usbDiagnosticRoute) {
                Text("Direct to Mac").tag("Direct to Mac")
                Text("Wavlink").tag("Wavlink")
                Text("UGREEN").tag("UGREEN")
                Text("Digma (working reference)").tag("Digma")
                Text("Wavlink → Digma").tag("Wavlink → Digma")
            }.disabled(model.busy || !model.usbDiagnosticReport.isEmpty)
            Picker("Test", selection: $model.usbDiagnosticProfile) {
                Text("Standard connection").tag("baseline")
                Text("USB sleep experiment (advanced)").tag("device-u1-u2-disabled")
            }.disabled(model.busy || !model.usbDiagnosticReport.isEmpty)
            if model.usbDiagnosticProfile == "device-u1-u2-disabled" {
                Text("U1/U2 are USB energy-saving states. This experiment temporarily stops the programmer from requesting them; the Mac may still request them. Reconnect the T76 after the test.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if model.busy {
                HStack { ProgressView().controlSize(.small); Text("Testing USB… Keep the T76 connected.") }
            } else if let passed = model.usbDiagnosticPassed {
                Label(passed ? "Information test passed" : "Test failed — save the report and reconnect",
                      systemImage: passed ? "checkmark.circle" : "exclamationmark.triangle")
            }
            ScrollView {
                Text(model.usbDiagnosticReport.isEmpty ? "The report will appear here. It contains no programmer serial number or chip contents." : model.usbDiagnosticReport)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 160, maxHeight: 240)
            HStack {
                Button("Close") { dismiss() }.disabled(model.busy)
                Spacer()
                if !model.usbDiagnosticReport.isEmpty {
                    Button("New Test") {
                        model.usbDiagnosticReport = ""
                        model.usbDiagnosticPassed = nil
                    }.disabled(model.busy)
                    Button("Save Report…") { model.saveUSBDiagnosticReport() }.disabled(model.busy)
                }
                Button("Run Test") { model.diagnoseUSB() }
                    .disabled(model.busy || !model.usbDiagnosticReport.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600)
        .interactiveDismissDisabled(model.busy)
    }
}

private struct ChipSidebar: View {
    @ObservedObject var model: AppModel

    private var chipSelection: Binding<String?> {
        Binding(get: { model.selectedChip.isEmpty ? nil : model.selectedChip },
                set: { if let chip = $0 { model.selectChip(chip) } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Label(model.isT76 ? "T76 connected" : "Connect your programmer",
                      systemImage: model.isT76 ? "checkmark.circle" : "cable.connector")
                    .font(.headline)
                Text(model.deviceStatus).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if model.usb3ReadValidation {
                    Text("USB 3 read validation: read and compare available. Programming requires USB 2.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Connect / Refresh", systemImage: "arrow.clockwise") { model.connect() }
                    .disabled(model.busy).help("Check the programmer and USB link. Command-R.")
                Button("USB Diagnostics…", systemImage: "stethoscope") { model.showUSBDiagnostics = true }
                    .disabled(model.busy)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Text("Select the exact chip").font(.headline)
                Text("Match the marking printed on the chip.").font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("Chip name, e.g. MX25L512", text: $model.query)
                        .onSubmit { model.search() }.accessibilityLabel("Search chip database")
                    Button { model.search() } label: { Image(systemName: "magnifyingglass") }
                        .accessibilityLabel("Search chips").help("Search the full chip database.")
                        .disabled(model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("Auto Detect SOIC16", systemImage: "sparkle.magnifyingglass") { model.autoDetectSOIC16() }
                    .disabled(!model.isT76)
                    .help("Suggest SOIC16 entries from the chip ID; confirm the printed marking.")
                Button("Browse All Chips", systemImage: "list.bullet") { model.browseCatalog() }
                    .help("Load the complete database catalog; favorites appear first.")
            }
            .disabled(model.busy)
            List(selection: chipSelection) {
                if !model.favoriteHits.isEmpty {
                    Section("Favorites") {
                        ForEach(model.favoriteHits, id: \.self) { chip in
                            ChipBrowserRow(model: model, chip: chip).tag(chip)
                        }
                    }
                }
                Section(model.catalog == nil ? "Results" : "Catalog") {
                    ForEach(model.otherHits, id: \.self) { chip in
                        ChipBrowserRow(model: model, chip: chip).tag(chip)
                    }
                }
            }
            .listStyle(.sidebar).disabled(model.busy)
            .overlay {
                if model.favoriteHits.isEmpty && model.otherHits.isEmpty {
                    VStack(spacing: 8) {
                        if model.busy {
                            ProgressView().controlSize(.small)
                            Text(model.currentStage ?? "Preparing chip lookup…")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "cpu").font(.title2).foregroundStyle(.secondary)
                            Text(model.hasSearched ? "No matching chips" : "Find your chip").font(.callout.weight(.medium))
                            Text(model.hasSearched ? "Try a shorter part number or check the marking." : "Search by part number or use SOIC16 auto detection.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }
                    }
                    .padding(20).allowsHitTesting(false)
                }
            }
            if !model.hits.isEmpty {
                Text(model.catalog.map { "\(model.hits.count.formatted()) of \($0.names.count.formatted()) entries" }
                     ?? "\(model.hits.count) results · select to load details")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !model.favoriteHits.isEmpty {
                Text("Favorites are shortcuts, not validated hardware support.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Chip database").font(.caption.weight(.medium))
                    Text(model.databaseDescription).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).help(model.databaseDescription)
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Choose Local Database…") { model.chooseDatabase() }
                    Button("Use Bundled / Automatic Database") { model.useDefaultDatabase() }
                        .disabled(model.databasePath.isEmpty)
                } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Chip database settings").disabled(model.busy)
            }
        }
        .padding(16).navigationTitle("Chips")
    }
}

private struct ChipBrowserRow: View {
    @ObservedObject var model: AppModel
    let chip: String

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(chip.components(separatedBy: "@").first ?? chip).font(.callout.weight(.medium))
                if let package = chip.components(separatedBy: "@").dropFirst().first {
                    Text(package).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button { model.toggleFavorite(chip) } label: {
                Image(systemName: model.favoriteChips.contains(chip) ? "star.fill" : "star")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel((model.favoriteChips.contains(chip) ? "Remove from favorites: " : "Add to favorites: ") + chip)
            .help(model.favoriteChips.contains(chip) ? "Remove from favorites" : "Add to favorites")
        }
        .padding(.vertical, 3).help(chip)
    }
}

private struct ProgrammingWorkspace: View {
    @ObservedObject var model: AppModel
    @State private var showChipDetails = false
    @State private var showOtherOperations = false

    private var readiness: String {
        if model.busy { return model.currentStage ?? "Operation in progress…" }
        if !model.isT76 { return "Connect the T76 to enable programming." }
        if model.selectedChip.isEmpty { return "Select the exact chip in the sidebar." }
        if model.chipDetails == nil { return "Wait for the chip details to load." }
        if !model.canWriteSelected { return "Programming needs a database electronic ID and a code region of 1 byte to 2 GiB." }
        if model.programmingFile == nil { return "Choose the firmware file to program." }
        return "Ready for preflight. The chip ID and image are checked before confirmation."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Program a chip").font(.title2.bold())
                    Text("Select the chip, choose your firmware, then program with readback verification.").foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(model.selectedChip.isEmpty ? "No chip selected" : model.selectedChip)
                                    .font(.headline).textSelection(.enabled)
                                if let chip = model.chipDetails, chip.name == model.selectedChip {
                                    Text("\(chip.package) · \(chip.pins) pins · \(byteCount(chip.codeBytes)) code region").foregroundStyle(.secondary)
                                } else {
                                    Text("Choose the marking and package from the sidebar.").foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("Check Setup") { model.checkSetup() }.disabled(model.busy || !model.canReadSelected)
                                .help("Check chip identity and report available contact diagnostics without changing chip contents.")
                        }
                        if let status = model.setupStatus {
                            Label(status, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        if let chip = model.chipDetails, chip.name == model.selectedChip {
                            DisclosureGroup("Database details", isExpanded: $showChipDetails) {
                                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                                    GridRow { Text("Electronic ID"); Text(chip.chipID.map { "0x" + $0 } ?? "Not specified") }
                                    GridRow { Text("Data / extra data"); Text("\(chip.dataBytes.formatted()) / \(chip.extraDataBytes.formatted()) bytes") }
                                    GridRow { Text("Page / erased value"); Text("\(chip.pageBytes.formatted()) bytes / 0x\(chip.blankValue)") }
                                    GridRow { Text("Electrical erase"); Text(chip.canErase ? "Available" : "Not available") }
                                }
                                .font(.caption).foregroundStyle(.secondary).padding(.top, 6).textSelection(.enabled)
                            }
                            Text("A database entry does not establish hardware-tested support.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("1 · Chip", systemImage: "cpu") }
                GroupBox {
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(model.programmingFile?.lastPathComponent ?? "No firmware selected")
                                .font(.headline).lineLimit(2).textSelection(.enabled)
                            if let file = model.programmingFile {
                                Text(model.programmingFileBytes.map { byteCount($0) + " on disk" } ?? "Size checked during preflight")
                                    .foregroundStyle(.secondary)
                                Text(file.path).font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2).help(file.path).textSelection(.enabled)
                            } else {
                                Text("Choose a binary (.bin), Intel HEX or S-record file.").foregroundStyle(.secondary)
                            }
                            Text("Programming uses this file. Save HEX editor changes before choosing it.").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button(model.programmingFile == nil ? "Choose Firmware…" : "Change File…", systemImage: "folder") {
                            model.chooseProgrammingFile()
                        }
                        .disabled(model.busy).help("Choose the source file for programming. Command-O.")
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("2 · Firmware", systemImage: "doc") }
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(readiness).foregroundStyle(.secondary)
                        HStack(spacing: 16) {
                            Label("Save the original dump first. Programming changes chip contents.", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 0)
                            Button("Program and Verify…", systemImage: "arrow.down.to.line") { model.writeChip() }
                                .buttonStyle(.borderedProminent).controlSize(.large)
                                .disabled(model.busy || !model.canWriteSelected || model.programmingFile == nil).help(readiness)
                        }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                } label: { Label("3 · Program and verify", systemImage: "checkmark.shield") }
                DisclosureGroup("Read, compare or erase the chip", isExpanded: $showOtherOperations) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Button("Read and Save…", systemImage: "square.and.arrow.up") { model.readChip() }.disabled(!model.canReadSelected)
                            Button("Verify Against File…") { model.verifyChip() }.disabled(!model.canVerifySelected)
                            Button("Blank Check") { model.blankCheck() }.disabled(!model.canReadSelected)
                            Spacer()
                            Button("Erase…", role: .destructive) { model.eraseChip() }.disabled(!model.canEraseSelected)
                        }
                        .disabled(model.busy)
                        Text("Read saves a dump and confirms it with a second read. Erase requires confirmation.").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OperationStatus: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: model.status.hasPrefix("Error:") ? "exclamationmark.circle" : "info.circle")
                    .foregroundStyle(model.status.hasPrefix("Error:") ? Color.red : Color.secondary)
                Text(model.status).font(.callout).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
            }
            if model.busy {
                HStack {
                    Text(model.currentStage ?? "Preparing operation…")
                    Spacer()
                    if let progress = model.progress { Text("\(Int(progress * 100))% of this stage").monospacedDigit() }
                }
                .font(.caption.weight(.medium))
                if let progress = model.progress {
                    ProgressView(value: progress).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if model.keepProgrammerConnected {
                    Text("Keep the programmer connected until the operation finishes.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct HexWorkspace: View {
    @ObservedObject var model: AppModel
    @State private var showMetadata = false
    @State private var showEditing = false
    @State private var searchASCII = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button("Open File…", systemImage: "folder") { model.openBuffer() }
                        Button("Save As…", systemImage: "square.and.arrow.down") { model.saveBuffer() }.disabled(model.bufferSize == 0)
                        Button("Compare with File…") { model.compareBufferToFile() }.disabled(model.bufferSize == 0)
                        Spacer()
                        Text(model.bufferSize == 0 ? "Buffer empty" : byteCount(model.bufferSize) + (model.bufferDirty ? " · unsaved" : ""))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .disabled(model.busy)
                    if let warning = model.bufferSourceWarning {
                        Label(warning, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                    if model.bufferSize > 0 {
                        DisclosureGroup("Source and checksum", isExpanded: $showMetadata) {
                            VStack(alignment: .leading, spacing: 5) {
                                if let source = model.bufferSourceDescription { Text(source) }
                                Text("SHA-256: \(model.bufferSHA256)").font(.system(.caption, design: .monospaced))
                            }
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled).padding(.top, 5)
                        }
                    }
                    HStack(spacing: 8) {
                        Button { model.previousPage() } label: { Image(systemName: "chevron.left") }
                            .accessibilityLabel("Previous hex page").help("Previous 256 bytes").disabled(model.bufferOffset == 0)
                        Button { model.nextPage() } label: { Image(systemName: "chevron.right") }
                            .accessibilityLabel("Next hex page").help("Next 256 bytes").disabled(model.bufferOffset + 256 >= model.bufferSize)
                        Text("Address 0x").font(.caption)
                        TextField("0", text: $model.addressText).frame(width: 90).onSubmit { model.jumpToAddress() }
                            .accessibilityLabel("Hexadecimal buffer address")
                        Button("Go") { model.jumpToAddress() }
                        Spacer()
                        Text(String(format: "0x%X–0x%X", model.bufferOffset,
                                    max(model.bufferOffset, min(model.bufferOffset + 256, model.bufferSize) - 1)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .disabled(model.busy || model.bufferSize == 0)
                    HStack {
                        Picker("Search format", selection: $searchASCII) {
                            Text("HEX").tag(false)
                            Text("ASCII").tag(true)
                        }
                        .pickerStyle(.segmented).frame(width: 140).labelsHidden()
                        if searchASCII {
                            TextField("Find printable text", text: $model.asciiFindText).onSubmit { model.findASCII() }
                                .accessibilityLabel("Find ASCII text")
                        } else {
                            TextField("Find bytes, e.g. DE AD BE EF", text: $model.findText).onSubmit { model.findHex() }
                                .accessibilityLabel("Find hex bytes")
                        }
                        Button("Find Next") { if searchASCII { model.findASCII() } else { model.findHex() } }
                    }
                    .disabled(model.busy || model.bufferSize == 0)
                    DisclosureGroup("Edit buffer", isExpanded: $showEditing) { HexEditingTools(model: model).padding(.top, 8) }
                        .disabled(model.busy || model.bufferSize == 0)
                }
                .padding(4)
            }
            .frame(maxHeight: showEditing ? 380 : (showMetadata ? 310 : 230))
            Divider()
            if model.bufferSize == 0 {
                ContentUnavailableView {
                    Label("No image open", systemImage: "doc.text")
                } description: {
                    Text("Open a dump file or read a chip to inspect its bytes. Firmware selection is separate from this buffer.")
                } actions: {
                    Button("Open File…") { model.openBuffer() }.disabled(model.busy)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Text(model.hexPreview).font(.system(.body, design: .monospaced))
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled)
                }
                .defaultScrollAnchor(.topLeading)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Hexadecimal and ASCII buffer contents")
            }
            Text("Editing changes the buffer only. Save it, then choose that file under Program to flash it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

private struct HexEditingTools: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Byte at 0x")
                hexField("Byte address", text: $model.byteAddressText)
                Text("= 0x")
                hexField("Byte value", text: $model.byteValueText, width: 46)
                Button("Set Byte") { model.editByte() }
                Spacer()
                Button("Undo") { model.undoEdit() }.disabled(!model.canUndo)
                Button("Redo") { model.redoEdit() }.disabled(!model.canRedo)
            }
            HStack {
                Text("Fill 0x")
                hexField("Fill start address", text: $model.fillStartText)
                Text("…0x")
                hexField("Fill end address", text: $model.fillEndText)
                Text("with 0x")
                hexField("Fill byte", text: $model.fillByteText, width: 46)
                Button("Fill Range…") { model.fillRange() }
            }
            HStack {
                Text("Block 0x")
                hexField("Block start address", text: $model.blockStartText)
                Text("…0x")
                hexField("Block end address", text: $model.blockEndText)
                Text("to 0x")
                hexField("Block destination address", text: $model.blockDestinationText)
                Button("Copy") { model.copyBlock() }
                Button("Export…") { model.exportBlock() }
            }
            Text("All addresses and byte values are hexadecimal. Range endpoints are inclusive.").font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func hexField(_ label: String, text: Binding<String>, width: CGFloat = 80) -> some View {
        TextField("0", text: text).frame(width: width).accessibilityLabel(label)
    }
}

private struct ActivityWorkspace: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.log.isEmpty {
            ContentUnavailableView("No operations yet", systemImage: "list.bullet.rectangle",
                                   description: Text("Connection checks, operation stages and results appear here."))
        } else {
            ScrollView([.horizontal, .vertical]) {
                Text(model.log.joined(separator: "\n")).font(.system(.callout, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12).textSelection(.enabled)
            }
            .defaultScrollAnchor(.topLeading)
        }
    }
}

private func byteCount(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
}
