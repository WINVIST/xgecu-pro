import AppKit
import SwiftUI

// Compiled as a separate CI executable with -D UI_PREVIEW. Never bundled in
// the app. All models below are display fixtures; no USB operation is run.
@main
struct CaptureUIPreviews {
    @MainActor
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            fatalError("Usage: capture-ui-previews OUTPUT_DIRECTORY")
        }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let states: [(String, Bool, Int, NSSize)] = [
            ("01-start", false, 0, NSSize(width: 1180, height: 820)),
            ("02-ready", false, 0, NSSize(width: 1180, height: 820)),
            ("03-programming", false, 0, NSSize(width: 1180, height: 820)),
            ("04-error-compact", false, 0, NSSize(width: 1020, height: 680)),
            ("05-ready-dark-compact", true, 0, NSSize(width: 1020, height: 680)),
            ("06-hex-editor", false, 1, NSSize(width: 1180, height: 820)),
        ]
        for (name, dark, tab, size) in states {
            let model = fixture(name)
            let content = ContentView(model: model, initialTab: tab)
                .preferredColorScheme(dark ? .dark : .light)
                .frame(width: size.width, height: size.height)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
            window.title = "XGecu Pro — UI fixture"
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            window.center()
            window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
            RunLoop.main.run(until: Date().addingTimeInterval(1))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                fatalError("Could not allocate the native view capture for \(name)")
            }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 10_000 else {
                fatalError("Native UI capture is empty: \(name)")
            }
            try png.write(to: output.appendingPathComponent(name + ".png"))
            print("Captured \(name): \(bitmap.pixelsWide) x \(bitmap.pixelsHigh), \(png.count) bytes")
            window.close()
        }
    }

    @MainActor
    private static func fixture(_ name: String) -> AppModel {
        let model = AppModel()
        guard name != "01-start" else { return model }
        model.isT76 = true
        model.deviceStatus = "T76 · firmware 00.1.07 · USB hs"
        model.query = "MX25L512"
        model.hits = ["MX25L51245G@SOIC16", "MX25L51245G@WSON8"]
        model.hasSearched = true
        model.selectedChip = model.hits[0]
        model.chipDetails = ChipDetails([
            "name": model.selectedChip, "package": "SOIC16", "pins": 16,
            "code_bytes": 67_108_864, "data_bytes": 0, "data2_bytes": 0,
            "page_bytes": 256, "chip_id": "C2201A", "blank_value": "FF", "can_erase": true,
        ])
        model.programmingFile = URL(fileURLWithPath: "/Users/example/Firmware/router-firmware.bin")
        model.programmingFileBytes = 67_108_864
        model.status = "Firmware selected: router-firmware.bin."
        if name == "03-programming" {
            model.busy = true
            model.currentStage = "Readback verification"
            model.progress = 0.64
            model.status = "Running: write…"
        } else if name == "04-error-compact" {
            model.status = "Error: The chip ID does not match the selected part. Check the marking and adapter placement before trying again."
        } else if name == "06-hex-editor" {
            model.bufferSize = 256
            model.bufferDirty = true
            model.lastFile = URL(fileURLWithPath: "/Users/example/Firmware/original-dump.bin")
            model.bufferSHA256 = String(repeating: "0123456789abcdef", count: 4)
            model.hexPreview = (0..<16).map { row in
                String(format: "%08X", row * 16) + "  " + (0..<16).map { String(format: "%02X", row * 16 + $0) }.joined(separator: " ") + "  ................"
            }.joined(separator: "\n")
            model.status = "Buffer modified. Save it before programming."
        }
        return model
    }
}
