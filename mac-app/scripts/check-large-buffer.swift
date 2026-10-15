import Foundation

// Separate CI executable: exercises the actual editor storage at the catalog
// size target, without loading an image into Data or opening a USB device.
@main
struct CheckLargeBuffer {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw HexBufferError.invalidSize }
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let expectedHash = CommandLine.arguments[2]
        let buffer = HexBuffer()
        try await buffer.load(source)
        let size = await buffer.count
        guard size == 1_140_850_688 else { throw HexBufferError.invalidSize }
        let tail = try await buffer.page(at: size - 2, count: 256)
        guard tail == Data([0, 0xAB]) else { throw HexBufferError.truncatedFile }
        let original = try await buffer.sha256()
        guard original == expectedHash else { throw HexBufferError.truncatedFile }
        try await buffer.setByte(at: size - 1, to: 0xCD)
        let difference = try await buffer.firstMismatch(with: source)
        guard difference.offset == size - 1 else { throw HexBufferError.truncatedFile }
        try await buffer.undo()
        let restored = try await buffer.sha256()
        guard restored == original else { throw HexBufferError.truncatedFile }
        let match = try await buffer.firstMismatch(with: source)
        guard match.offset == nil else { throw HexBufferError.truncatedFile }
        print("File-backed editor: \(size) bytes; paging, edit, undo, SHA-256 and comparison passed.")
    }
}
