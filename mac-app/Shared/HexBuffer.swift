import Foundation

enum HexBufferError: Error {
    case invalidRange
}

struct HexBuffer {
    private struct Edit {
        let range: Range<Int>
        let previous: Data
        let value: UInt8
    }

    private static let historyLimit = 64 * 1024 * 1024

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
        guard start >= 0, start <= end, end < bytes.count else {
            throw HexBufferError.invalidRange
        }
        let range = start..<(end + 1)
        let previous = bytes.subdata(in: range)
        bytes.replaceSubrange(range, with: Data(repeating: value, count: range.count))
        undoStack.append(Edit(range: range, previous: previous, value: value))
        redoStack.removeAll()
        while undoStack.reduce(0, { $0 + $1.previous.count }) > Self.historyLimit {
            undoStack.removeFirst()
        }
    }

    mutating func setByte(at address: Int, to value: UInt8) throws {
        try fill(start: address, end: address, value: value)
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
        bytes.replaceSubrange(edit.range, with: Data(repeating: edit.value, count: edit.range.count))
        undoStack.append(edit)
        return edit.range
    }
}
