import Foundation

enum HexBufferError: Error {
    case invalidRange
}

struct HexBuffer {
    private enum Replacement {
        case fill(UInt8)
        case bytes(Data)

        var storedBytes: Int {
            switch self {
            case .fill: 0
            case .bytes(let data): data.count
            }
        }

        func data(count: Int) -> Data {
            switch self {
            case .fill(let value): Data(repeating: value, count: count)
            case .bytes(let data): data
            }
        }
    }

    private struct Edit {
        let range: Range<Int>
        let previous: Data
        let replacement: Replacement
    }

    private static let historyLimit = 128 * 1024 * 1024

    private(set) var bytes: Data
    private var undoStack: [Edit] = []
    private var redoStack: [Edit] = []

    init(bytes: Data = Data()) {
        self.bytes = bytes
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    mutating func load(_ newBytes: Data) {
        bytes = newBytes
        undoStack.removeAll()
        redoStack.removeAll()
    }

    mutating func fill(start: Int, end: Int, value: UInt8) throws {
        let range = try checkedRange(start: start, end: end)
        apply(range: range, replacement: .fill(value))
    }

    mutating func setByte(at address: Int, to value: UInt8) throws {
        try fill(start: address, end: address, value: value)
    }

    func block(start: Int, end: Int) throws -> Data {
        bytes.subdata(in: try checkedRange(start: start, end: end))
    }

    mutating func copyBlock(start: Int, end: Int, to destination: Int) throws {
        let source = try checkedRange(start: start, end: end)
        guard destination >= 0, destination <= bytes.count - source.count else {
            throw HexBufferError.invalidRange
        }
        let snapshot = bytes.subdata(in: source)
        apply(range: destination..<(destination + source.count), replacement: .bytes(snapshot))
    }

    func find(_ needle: Data, from start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, start <= bytes.count else { return nil }
        return bytes.range(of: needle, in: start..<bytes.count)?.lowerBound
            ?? bytes.range(of: needle)?.lowerBound
    }

    private func checkedRange(start: Int, end: Int) throws -> Range<Int> {
        guard start >= 0, start <= end, end < bytes.count else {
            throw HexBufferError.invalidRange
        }
        return start..<(end + 1)
    }

    private mutating func apply(range: Range<Int>, replacement: Replacement) {
        let previous = bytes.subdata(in: range)
        bytes.replaceSubrange(range, with: replacement.data(count: range.count))
        undoStack.append(Edit(range: range, previous: previous, replacement: replacement))
        redoStack.removeAll()
        while undoStack.reduce(0, { $0 + $1.previous.count + $1.replacement.storedBytes }) > Self.historyLimit {
            undoStack.removeFirst()
        }
    }

    @discardableResult
    mutating func undo() -> Range<Int>? {
        guard let edit = undoStack.popLast() else { return nil }
        bytes.replaceSubrange(edit.range, with: edit.previous)
        redoStack.append(edit)
        return edit.range
    }

    @discardableResult
    mutating func redo() -> Range<Int>? {
        guard let edit = redoStack.popLast() else { return nil }
        bytes.replaceSubrange(edit.range, with: edit.replacement.data(count: edit.range.count))
        undoStack.append(edit)
        return edit.range
    }
}
