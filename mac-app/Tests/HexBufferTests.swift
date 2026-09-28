import Foundation
import XCTest
@testable import XGecuBufferCore

final class HexBufferTests: XCTestCase {
    func testFillUndoRedoAndEdges() throws {
        var buffer = HexBuffer(bytes: Data([0x10, 0x20, 0x30, 0x40]))
        try buffer.fill(start: 0, end: 3, value: 0xFF)
        XCTAssertEqual(buffer.bytes, Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertTrue(buffer.canUndo)
        XCTAssertEqual(buffer.undo(), 0..<4)
        XCTAssertEqual(buffer.bytes, Data([0x10, 0x20, 0x30, 0x40]))
        XCTAssertTrue(buffer.canRedo)
        XCTAssertEqual(buffer.redo(), 0..<4)
        XCTAssertEqual(buffer.bytes, Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }

    func testSingleByteEditAndNewEditClearsRedo() throws {
        var buffer = HexBuffer(bytes: Data([0x00, 0x01, 0x02]))
        try buffer.setByte(at: 2, to: 0xAB)
        XCTAssertEqual(buffer.bytes, Data([0x00, 0x01, 0xAB]))
        buffer.undo()
        try buffer.setByte(at: 0, to: 0xCD)
        XCTAssertEqual(buffer.bytes, Data([0xCD, 0x01, 0x02]))
        XCTAssertFalse(buffer.canRedo)
    }

    func testInvalidRangeDoesNotChangeBuffer() {
        var buffer = HexBuffer(bytes: Data([0x12, 0x34]))
        for (start, end) in [(-1, 0), (1, 0), (0, 2)] {
            XCTAssertThrowsError(try buffer.fill(start: start, end: end, value: 0xFF))
        }
        XCTAssertEqual(buffer.bytes, Data([0x12, 0x34]))
        XCTAssertFalse(buffer.canUndo)
    }

    func testLoadClearsHistory() throws {
        var buffer = HexBuffer(bytes: Data([0x01]))
        try buffer.setByte(at: 0, to: 0x02)
        buffer.load(Data([0x03, 0x04]))
        XCTAssertEqual(buffer.bytes, Data([0x03, 0x04]))
        XCTAssertFalse(buffer.canUndo)
        XCTAssertFalse(buffer.canRedo)
    }
}
