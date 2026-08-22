import Foundation
import XCTest
@testable import DsmNetwork

final class AtomicFilePromotionTests: XCTestCase {
    func test替换失败时旧目标内容保持不变() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("destination.txt")
        let source = directory.appendingPathComponent("source.tmp")
        let oldContents = Data("old contents".utf8)
        let newContents = Data("new contents".utf8)
        try oldContents.write(to: destination)
        try newContents.write(to: source)

        XCTAssertThrowsError(
            try AtomicFilePromotion.promote(
                from: source,
                to: destination,
                replaceExisting: { _, _ in
                    throw AtomicFilePromotionTestError.replaceFailed
                }
            )
        )

        XCTAssertEqual(try Data(contentsOf: destination), oldContents)
        XCTAssertEqual(try Data(contentsOf: source), newContents)
    }

    func test同目录完整临时文件会原子提升为目标() throws {
        let directory = try makeDirectory()
        let destination = directory.appendingPathComponent("destination.txt")
        let source = directory.appendingPathComponent("source.tmp")
        try Data("old contents".utf8).write(to: destination)
        let newContents = Data("new contents".utf8)
        try newContents.write(to: source)

        try AtomicFilePromotion.promote(from: source, to: destination)

        XCTAssertEqual(try Data(contentsOf: destination), newContents)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    func test跨目录提升被拒绝且不触碰原目标() throws {
        let sourceDirectory = try makeDirectory()
        let destinationDirectory = try makeDirectory()
        let source = sourceDirectory.appendingPathComponent("source.tmp")
        let destination = destinationDirectory.appendingPathComponent("destination.txt")
        let oldContents = Data("old contents".utf8)
        try Data("new contents".utf8).write(to: source)
        try oldContents.write(to: destination)

        XCTAssertThrowsError(
            try AtomicFilePromotion.promote(from: source, to: destination)
        )

        XCTAssertEqual(try Data(contentsOf: destination), oldContents)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private enum AtomicFilePromotionTestError: Error {
    case replaceFailed
}
