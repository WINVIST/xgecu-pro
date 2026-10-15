import CryptoKit
import Darwin
import Foundation

enum HexBufferError: LocalizedError {
    case invalidRange, invalidSize, notLoaded, truncatedFile
    var errorDescription: String? {
        switch self {
        case .invalidRange: "The address range is outside the buffer."
        case .invalidSize: "The image must be between 1 byte and 2 GiB."
        case .notLoaded: "Open an image in the Hex Editor first."
        case .truncatedFile: "The working image could not be read completely."
        }
    }
}

// Disk I/O, search and hashing run away from the UI actor. Original files are
// never edited. Only pages and 64 KiB chunks enter RAM; history lives on disk.
actor HexBuffer {
    static let maxBytes = 2 * 1024 * 1024 * 1024
    static let chunkBytes = 64 * 1024
    private static let historyBytes = 4 * 1024 * 1024 * 1024
    private enum Replacement { case fill(UInt8), file(URL) }
    private struct Edit {
        let range: Range<Int>
        let previous: URL
        let replacement: Replacement
        var storedBytes: Int {
            switch replacement {
            case .fill: range.count
            case .file: range.count * 2
            }
        }
    }
    private var directory: URL?
    private var file: FileHandle?
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []
    private(set) var count = 0
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    deinit {
        try? file?.close()
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
    func sourceURL() throws -> URL {
        guard let directory, file != nil else { throw HexBufferError.notLoaded }
        return directory.appendingPathComponent("image.bin")
    }
    func load(_ source: URL) throws {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size > 0, size <= UInt64(Self.maxBytes) else { throw HexBufferError.invalidSize }
        let next = try Self.makeDirectory()
        do {
            let url = next.appendingPathComponent("image.bin")
            let output = try Self.createFile(url)
            do {
                try Self.copy(input, offset: 0, count: Int(size), to: output)
                try output.synchronize()
                try output.close()
            } catch { try? output.close(); throw error }
            let opened = try FileHandle(forUpdating: url)
            try? file?.close()
            if let directory { try? FileManager.default.removeItem(at: directory) }
            directory = next
            file = opened
            count = Int(size)
            undoStack.removeAll()
            redoStack.removeAll()
        } catch { try? FileManager.default.removeItem(at: next); throw error }
    }
    // Small fixtures/tests only. Production imports use load(URL).
    func load(_ bytes: Data) throws {
        guard !bytes.isEmpty, bytes.count <= Self.maxBytes else { throw HexBufferError.invalidSize }
        let temporary = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: temporary) }
        let url = temporary.appendingPathComponent("fixture.bin")
        let output = try Self.createFile(url)
        defer { try? output.close() }
        try output.write(contentsOf: bytes)
        try load(url)
    }
    func page(at address: Int, count requested: Int) throws -> Data {
        guard address >= 0, address <= count, requested >= 0,
              requested <= Self.chunkBytes else { throw HexBufferError.invalidRange }
        guard let file else { throw HexBufferError.notLoaded }
        try file.seek(toOffset: UInt64(address))
        return try Self.read(file, count: min(requested, count - address))
    }
    func sha256() throws -> String {
        guard let file else { throw HexBufferError.notLoaded }
        try file.seek(toOffset: 0)
        var hash = SHA256()
        var remaining = count
        while remaining > 0 {
            let chunk = try Self.read(file, count: min(Self.chunkBytes, remaining))
            hash.update(data: chunk)
            remaining -= chunk.count
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func firstMismatch(with source: URL) throws -> (offset: Int?, otherBytes: Int) {
        guard let file else { throw HexBufferError.notLoaded }
        let other = try FileHandle(forReadingFrom: source)
        defer { try? other.close() }
        let size = try other.seekToEnd()
        guard size <= UInt64(Self.maxBytes) else { throw HexBufferError.invalidSize }
        let common = min(count, Int(size))
        try file.seek(toOffset: 0)
        try other.seek(toOffset: 0)
        var offset = 0
        while offset < common {
            let n = min(Self.chunkBytes, common - offset)
            let a = try Self.read(file, count: n)
            let b = try Self.read(other, count: n)
            if a != b, let i = zip(a, b).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
                return (offset + i, Int(size))
            }
            offset += n
        }
        return (count == Int(size) ? nil : common, Int(size))
    }
    func find(_ needle: Data, from start: Int) throws -> Int? {
        guard !needle.isEmpty, needle.count <= 256, start >= 0, start <= count else { return nil }
        guard let file else { throw HexBufferError.notLoaded }
        func scan(from lower: Int, through upper: Int) throws -> Int? {
            try file.seek(toOffset: UInt64(lower))
            var tail = Data()
            var offset = lower
            let end = min(count, upper + needle.count - 1)
            while offset < end {
                let chunk = try Self.read(file, count: min(Self.chunkBytes, end - offset))
                var window = tail
                window.append(chunk)
                if let range = window.range(of: needle) {
                    let match = offset - tail.count + range.lowerBound
                    if match < upper { return match }
                }
                tail = Data(window.suffix(needle.count - 1))
                offset += chunk.count
            }
            return nil
        }
        return try scan(from: start, through: count) ?? scan(from: 0, through: start)
    }
    func fill(start: Int, end: Int, value: UInt8) throws {
        try apply(range: checkedRange(start: start, end: end), replacement: .fill(value))
    }
    func setByte(at address: Int, to value: UInt8) throws {
        try fill(start: address, end: address, value: value)
    }
    func copyBlock(start: Int, end: Int, to destination: Int) throws {
        let source = try checkedRange(start: start, end: end)
        guard destination >= 0, destination <= count - source.count else { throw HexBufferError.invalidRange }
        let snapshot = try snapshotRange(source)
        do { try apply(range: destination..<(destination + source.count), replacement: .file(snapshot)) }
        catch { try? FileManager.default.removeItem(at: snapshot); throw error }
    }
    func export(start: Int, end: Int, to destination: URL) throws {
        let range = try checkedRange(start: start, end: end)
        guard let file else { throw HexBufferError.notLoaded }
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".xgecu-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let output = try Self.createFile(temporary)
        defer { try? output.close() }
        try Self.copy(file, offset: range.lowerBound, count: range.count, to: output)
        try output.synchronize()
        // Atomic replacement also replaces a symlink, without following it.
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    @discardableResult
    func undo() throws -> Range<Int>? {
        guard let edit = undoStack.last else { return nil }
        do { try replace(edit.range, with: .file(edit.previous)) }
        catch { try replace(edit.range, with: edit.replacement); throw error }
        undoStack.removeLast()
        redoStack.append(edit)
        return edit.range
    }
    @discardableResult
    func redo() throws -> Range<Int>? {
        guard let edit = redoStack.last else { return nil }
        do { try replace(edit.range, with: edit.replacement) }
        catch { try replace(edit.range, with: .file(edit.previous)); throw error }
        redoStack.removeLast()
        undoStack.append(edit)
        return edit.range
    }
    private func checkedRange(start: Int, end: Int) throws -> Range<Int> {
        guard start >= 0, start <= end, end < count else { throw HexBufferError.invalidRange }
        return start..<(end + 1)
    }
    private func snapshotRange(_ range: Range<Int>) throws -> URL {
        guard let directory, let file else { throw HexBufferError.notLoaded }
        let url = directory.appendingPathComponent(UUID().uuidString)
        let output = try Self.createFile(url)
        defer { try? output.close() }
        do { try Self.copy(file, offset: range.lowerBound, count: range.count, to: output) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        return url
    }
    private func apply(range: Range<Int>, replacement: Replacement) throws {
        let previous = try snapshotRange(range)
        do { try replace(range, with: replacement) }
        catch {
            defer { try? FileManager.default.removeItem(at: previous) }
            try replace(range, with: .file(previous))
            throw error
        }
        undoStack.append(Edit(range: range, previous: previous, replacement: replacement))
        redoStack.forEach(removeFiles)
        redoStack.removeAll()
        while undoStack.count > 128 || (undoStack.count > 1 && undoStack.reduce(0, { $0 + $1.storedBytes }) > Self.historyBytes) {
            removeFiles(undoStack.removeFirst())
        }
    }
    private func replace(_ range: Range<Int>, with replacement: Replacement) throws {
        guard let file else { throw HexBufferError.notLoaded }
        try file.seek(toOffset: UInt64(range.lowerBound))
        switch replacement {
        case .fill(let value):
            let chunk = Data(repeating: value, count: Self.chunkBytes)
            var remaining = range.count
            while remaining > 0 {
                let n = min(remaining, Self.chunkBytes)
                try file.write(contentsOf: chunk.prefix(n))
                remaining -= n
            }
        case .file(let url):
            let source = try FileHandle(forReadingFrom: url)
            defer { try? source.close() }
            try Self.copy(source, offset: 0, count: range.count, to: file)
        }
    }
    private func removeFiles(_ edit: Edit) {
        try? FileManager.default.removeItem(at: edit.previous)
        if case .file(let url) = edit.replacement { try? FileManager.default.removeItem(at: url) }
    }
    private static func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("xgecu-buffer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }
    private static func createFile(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forUpdating: url)
    }
    private static func read(_ file: FileHandle, count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try autoreleasepool(invoking: { try file.read(upToCount: count - data.count) }),
                  !chunk.isEmpty else { throw HexBufferError.truncatedFile }
            data.append(chunk)
        }
        return data
    }
    private static func copy(_ input: FileHandle, offset: Int, count: Int, to output: FileHandle) throws {
        try input.seek(toOffset: UInt64(offset))
        var remaining = count
        while remaining > 0 {
            let chunk = try read(input, count: min(Self.chunkBytes, remaining))
            try output.write(contentsOf: chunk)
            remaining -= chunk.count
        }
    }
}
