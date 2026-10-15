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
        app.finishLaunching()
        let states: [(String, Bool, Int, NSSize)] = [
            ("01-start", false, 0, NSSize(width: 1180, height: 820)),
            ("02-ready", false, 0, NSSize(width: 1180, height: 820)),
            ("03-programming", false, 0, NSSize(width: 1180, height: 820)),
            ("04-error-compact", false, 0, NSSize(width: 1020, height: 680)),
            ("05-ready-dark-compact", true, 0, NSSize(width: 1020, height: 680)),
            ("06-hex-editor", false, 1, NSSize(width: 1180, height: 820)),
            ("07-chip-lookup", false, 0, NSSize(width: 1020, height: 680)),
            ("08-catalog-favorites", false, 0, NSSize(width: 1180, height: 820)),
            ("09-catalog-filter-dark", true, 0, NSSize(width: 1020, height: 680)),
            ("10-setup-check", false, 0, NSSize(width: 1020, height: 680)),
            ("11-large-hex-buffer", true, 1, NSSize(width: 1180, height: 820)),
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
            RunLoop.main.run(until: Date().addingTimeInterval(2))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            // NSView.cacheDisplay misses SwiftUI's composited drawing layers.
            // Capture our own window through WindowServer instead.
            let file = output.appendingPathComponent(name + ".png")
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
            try capture.run()
            capture.waitUntilExit()
            guard capture.terminationStatus == 0,
                  let png = try? Data(contentsOf: file), png.count > 10_000,
                  let image = NSBitmapImageRep(data: png) else {
                fatalError("WindowServer capture failed or is empty: \(name)")
            }
            print("Captured \(name): \(image.pixelsWide) x \(image.pixelsHigh), \(png.count) bytes")
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
        if name == "08-catalog-favorites" || name == "09-catalog-filter-dark" {
            let names = ["AT27C256@DIP28", "MX25L51245G@SOIC16", "MX25L51245G@WSON8", "W27C512@DIP28", "W25Q128BV@SOIC8"]
            model.favoriteChips = ["MX25L51245G@SOIC16", "W27C512@DIP28"]
            model.catalog = ChipCatalog(names: names)
            model.query = name == "08-catalog-favorites" ? "" : "mx25l"
            model.status = "Catalog loaded. Favorites are shown first."
        } else if name == "07-chip-lookup" {
            model.hits = []
            model.selectedChip = ""
            model.chipDetails = nil
            model.programmingFile = nil
            model.programmingFileBytes = nil
            model.busy = true
            model.currentStage = "Loading chip database"
            model.status = "Running: search…"
        } else if name == "03-programming" {
            model.busy = true
            model.currentStage = "Readback verification"
            model.progress = 0.64
            model.status = "Running: write…"
        } else if name == "04-error-compact" {
            model.status = "Error: The chip ID does not match the selected part. Check the marking and adapter placement before trying again."
        } else if name == "10-setup-check" {
            model.setupStatus = "Chip ID matches the selected entry. Contact self-test is unavailable on this programmer. Check the chip and adapter seating."
            model.status = model.setupStatus ?? "Setup checked."
        } else if name == "06-hex-editor" || name == "11-large-hex-buffer" {
            model.bufferSize = name == "11-large-hex-buffer" ? 1_140_850_688 : 256
            model.bufferOffset = name == "11-large-hex-buffer" ? model.bufferSize - 256 : 0
            model.addressText = String(model.bufferOffset, radix: 16).uppercased()
            model.bufferDirty = true
            model.lastFile = URL(fileURLWithPath: "/Users/example/Firmware/original-dump.bin")
            model.bufferSHA256 = String(repeating: "0123456789abcdef", count: 4)
            var lines: [String] = []
            for row in 0..<16 {
                let address = String(format: "%08X", model.bufferOffset + row * 16)
                var bytes: [String] = []
                for column in 0..<16 {
                    bytes.append(String(format: "%02X", row * 16 + column))
                }
                lines.append(address + "  " + bytes.joined(separator: " ") + "  ................")
            }
            model.hexPreview = lines.joined(separator: "\n")
            model.status = "Buffer modified. Save it before programming."
        }
        return model
    }
}
