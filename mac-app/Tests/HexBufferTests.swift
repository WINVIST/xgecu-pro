import Foundation
import XCTest
@testable import XGecuBufferCore

final class HexBufferTests: XCTestCase {
    private func makeBuffer(_ data: Data) async throws -> HexBuffer {
        let buffer = HexBuffer()
        try await buffer.load(data)
        return buffer
    }
    private func assertBytes(_ buffer: HexBuffer, _ expected: Data, file: StaticString = #filePath, line: UInt = #line) async throws {
        let actual = try await buffer.page(at: 0, count: expected.count)
        XCTAssertEqual(actual, expected, file: file, line: line)
    }
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
        return path
    }

    func testFillUndoRedoAndEdges() async throws {
        let buffer = try await makeBuffer(Data([0x10, 0x20, 0x30, 0x40]))
        try await buffer.fill(start: 0, end: 3, value: 0xFF)
        try await assertBytes(buffer, Data([0xFF, 0xFF, 0xFF, 0xFF]))
        let canUndo = await buffer.canUndo
        XCTAssertTrue(canUndo)
        let range = try await buffer.undo()
        XCTAssertEqual(range, 0..<4)
        try await assertBytes(buffer, Data([0x10, 0x20, 0x30, 0x40]))
        let canRedo = await buffer.canRedo
        XCTAssertTrue(canRedo)
        let redo = try await buffer.redo()
        XCTAssertEqual(redo, 0..<4)
        try await assertBytes(buffer, Data([0xFF, 0xFF, 0xFF, 0xFF]))
    }
    func testSingleByteEditAndNewEditClearsRedo() async throws {
        let buffer = try await makeBuffer(Data([0, 1, 2]))
        try await buffer.setByte(at: 2, to: 0xAB)
        try await assertBytes(buffer, Data([0, 1, 0xAB]))
        try await buffer.undo()
        try await buffer.setByte(at: 0, to: 0xCD)
        try await assertBytes(buffer, Data([0xCD, 1, 2]))
        let canRedo = await buffer.canRedo
        XCTAssertFalse(canRedo)
    }
    func testInvalidRangeDoesNotChangeBuffer() async throws {
        let buffer = try await makeBuffer(Data([0x12, 0x34]))
        for (start, end) in [(-1, 0), (1, 0), (0, 2)] {
            do { try await buffer.fill(start: start, end: end, value: 0xFF); XCTFail("Invalid range accepted") }
            catch HexBufferError.invalidRange {} // Expected; I/O failures must still fail this test.
        }
        try await assertBytes(buffer, Data([0x12, 0x34]))
        let canUndo = await buffer.canUndo
        XCTAssertFalse(canUndo)
    }
    func testLoadClearsHistoryAndKeepsSourceUnmodified() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("original.bin")
        try Data([3, 4]).write(to: source)
        let buffer = try await makeBuffer(Data([1]))
        try await buffer.setByte(at: 0, to: 2)
        try await buffer.load(source)
        try await assertBytes(buffer, Data([3, 4]))
        let canUndo = await buffer.canUndo
        let canRedo = await buffer.canRedo
        XCTAssertFalse(canUndo)
        XCTAssertFalse(canRedo)
        try await buffer.setByte(at: 0, to: 0xAA)
        XCTAssertEqual(try Data(contentsOf: source), Data([3, 4]))
    }
    func testBlockExportUsesInclusiveEndAndAtomicallyReplacesSymlink() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("keep.bin")
        let output = dir.appendingPathComponent("block.bin")
        try Data([0xAB]).write(to: target)
        try FileManager.default.createSymbolicLink(at: output, withDestinationURL: target)
        let buffer = try await makeBuffer(Data([0x10, 0x20, 0x30, 0x40]))
        try await buffer.export(start: 1, end: 2, to: output)
        XCTAssertEqual(try Data(contentsOf: output), Data([0x20, 0x30]))
        XCTAssertEqual(try Data(contentsOf: target), Data([0xAB]))
        do { try await buffer.export(start: 2, end: 4, to: output); XCTFail("Invalid range accepted") }
        catch HexBufferError.invalidRange {}
        XCTAssertEqual(try Data(contentsOf: output), Data([0x20, 0x30]))
    }
    func testOverlappingCopyUsesSourceSnapshotAndCanUndo() async throws {
        let buffer = try await makeBuffer(Data([1, 2, 3, 4, 5]))
        try await buffer.copyBlock(start: 0, end: 2, to: 1)
        try await assertBytes(buffer, Data([1, 1, 2, 3, 5]))
        try await buffer.undo()
        try await assertBytes(buffer, Data([1, 2, 3, 4, 5]))
        try await buffer.redo()
        try await assertBytes(buffer, Data([1, 1, 2, 3, 5]))
        do { try await buffer.copyBlock(start: 0, end: 2, to: 3); XCTFail("Invalid destination accepted") }
        catch HexBufferError.invalidRange {}
    }
    func testByteSearchWrapsAcrossChunkAndSearchBoundaries() async throws {
        var data = Data(repeating: 0, count: 65_540)
        data.replaceSubrange(65_535..<65_539, with: Data("ABCD".utf8))
        let buffer = try await makeBuffer(data)
        let boundary = try await buffer.find(Data("ABCD".utf8), from: 0)
        let wrapped = try await buffer.find(Data("ABCD".utf8), from: 65_537)
        let empty = try await buffer.find(Data(), from: 0)
        let negative = try await buffer.find(Data("AB".utf8), from: -1)
        XCTAssertEqual(boundary, 65_535)
        XCTAssertEqual(wrapped, 65_535)
        XCTAssertNil(empty)
        XCTAssertNil(negative)
    }
    func testSHAAndFileComparisonDetectByteAndSizeDifferences() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = dir.appendingPathComponent("other.bin")
        let buffer = try await makeBuffer(Data("abc".utf8))
        let hash = try await buffer.sha256()
        XCTAssertEqual(hash, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try Data("abc".utf8).write(to: other)
        let identical = try await buffer.firstMismatch(with: other)
        XCTAssertNil(identical.offset)
        try Data("abd".utf8).write(to: other)
        let different = try await buffer.firstMismatch(with: other)
        XCTAssertEqual(different.offset, 2)
        try Data("ab".utf8).write(to: other)
        let shorter = try await buffer.firstMismatch(with: other)
        XCTAssertEqual(shorter.offset, 2)
        XCTAssertEqual(shorter.otherBytes, 2)
    }
    func testLargeFilePagingEditingAndOversizedRejection() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("large.bin")
        XCTAssertTrue(FileManager.default.createFile(atPath: source.path, contents: nil))
        let handle = try FileHandle(forWritingTo: source)
        defer { try? handle.close() }
        let size = 256 * 1024 * 1024 + 17
        try handle.truncate(atOffset: UInt64(size))
        try handle.seek(toOffset: UInt64(size - 1))
        try handle.write(contentsOf: Data([0xAB]))
        let buffer = HexBuffer()
        try await buffer.load(source)
        let count = await buffer.count
        let tail = try await buffer.page(at: size - 2, count: 256)
        XCTAssertEqual(count, size)
        XCTAssertEqual(tail, Data([0, 0xAB]))
        try await buffer.setByte(at: size - 1, to: 0xCD)
        try await buffer.undo()
        let restored = try await buffer.page(at: size - 1, count: 1)
        XCTAssertEqual(restored, Data([0xAB]))
        try handle.truncate(atOffset: UInt64(HexBuffer.maxBytes + 1))
        do { try await buffer.load(source); XCTFail("Oversized image accepted") }
        catch HexBufferError.invalidSize {}
        let retained = await buffer.count
        XCTAssertEqual(retained, size)
    }
}
