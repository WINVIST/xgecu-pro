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

    func testBlockExportUsesInclusiveEnd() throws {
        let buffer = HexBuffer(bytes: Data([0x10, 0x20, 0x30, 0x40]))
        XCTAssertEqual(try buffer.block(start: 1, end: 2), Data([0x20, 0x30]))
        XCTAssertThrowsError(try buffer.block(start: 2, end: 4))
    }

    func testOverlappingCopyUsesSourceSnapshotAndCanUndo() throws {
        var buffer = HexBuffer(bytes: Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        try buffer.copyBlock(start: 0, end: 2, to: 1)
        XCTAssertEqual(buffer.bytes, Data([0x01, 0x01, 0x02, 0x03, 0x05]))
        buffer.undo()
        XCTAssertEqual(buffer.bytes, Data([0x01, 0x02, 0x03, 0x04, 0x05]))
        buffer.redo()
        XCTAssertEqual(buffer.bytes, Data([0x01, 0x01, 0x02, 0x03, 0x05]))
        XCTAssertThrowsError(try buffer.copyBlock(start: 0, end: 2, to: 3))
    }

    func testByteSearchWrapsAndRejectsEmptyNeedle() {
        let buffer = HexBuffer(bytes: Data("ABCDAB".utf8))
        XCTAssertEqual(buffer.find(Data("AB".utf8), from: 1), 4)
        XCTAssertEqual(buffer.find(Data("AB".utf8), from: 5), 0)
        XCTAssertEqual(buffer.find(Data("BC".utf8), from: 2), 1)
        XCTAssertNil(buffer.find(Data(), from: 0))
        XCTAssertNil(buffer.find(Data("AB".utf8), from: -1))
    }
}
