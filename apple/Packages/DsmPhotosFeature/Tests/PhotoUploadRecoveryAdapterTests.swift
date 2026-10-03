import DsmCore
@testable import DsmPhotosFeature
import Foundation
import XCTest

final class PhotoUploadRecoveryAdapterTests: XCTestCase {
    func test平台书签注入保持既有队列格式并恢复文件() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.jpg")
        try Data([1, 2, 3]).write(to: source)
        let files = try PhotoUploadPreparation.prepare([source]).files
        let storeURL = root.appendingPathComponent("queue/record.json")
        let store = PhotoUploadRecoveryStore(url: storeURL, bookmarkAccess: FixtureBookmarks())
        try store.save(identity: "fixture-account", entries: [.init(file: try XCTUnwrap(files.first), album: nil, folder: nil)],
                       directories: [], pendingEntryID: nil, pendingDirectory: nil, pendingOperationID: nil)
        let reopened = PhotoUploadRecoveryStore(url: storeURL, bookmarkAccess: FixtureBookmarks())
        let saved = try XCTUnwrap(reopened.load())
        XCTAssertEqual(saved.version, 1)
        XCTAssertEqual(saved.identity, "fixture-account")
        let restored = try XCTUnwrap(reopened.restoredEntries(from: saved).first)
        XCTAssertEqual(restored.file.url, source)
        XCTAssertEqual(restored.file.size, 3)
        XCTAssertFalse(restored.file.requiresSourceSelection)
        XCTAssertEqual(restored.state, .cancelled, "中断项等待用户继续，不在恢复时自动重发")
    }

    func test书签失效时保留任务并要求重新选取来源() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("fixture.jpg")
        try Data([1, 2, 3]).write(to: source)
        let file = try XCTUnwrap(PhotoUploadPreparation.prepare([source]).files.first)
        let storeURL = root.appendingPathComponent("queue/record.json")
        let writer = PhotoUploadRecoveryStore(url: storeURL, bookmarkAccess: FixtureBookmarks())
        try writer.save(identity: "fixture-account", entries: [.init(file: file, album: nil, folder: nil)],
                        directories: [], pendingEntryID: nil, pendingDirectory: nil, pendingOperationID: nil)
        let reader = PhotoUploadRecoveryStore(url: storeURL, bookmarkAccess: FixtureBookmarks(isStale: true))
        let restored = try XCTUnwrap(reader.restoredEntries(from: XCTUnwrap(reader.load())).first)
        XCTAssertEqual(restored.id, file.id)
        XCTAssertTrue(restored.file.requiresSourceSelection)
        XCTAssertEqual(restored.state, .cancelled)
        XCTAssertNotNil(restored.file.recoveryBookmark)
    }
}

private struct FixtureBookmarks: PhotoUploadBookmarkAccess {
    var isStale = false
    func makeBookmark(for url: URL) throws -> Data { Data(url.absoluteString.utf8) }
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        let text = try XCTUnwrap(String(data: bookmark, encoding: .utf8))
        return (try XCTUnwrap(URL(string: text)), isStale)
    }
}
