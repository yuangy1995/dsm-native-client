import Foundation
import XCTest
@testable import DsmCore

final class DesktopDriveWritebackStoreTests: XCTestCase {
    func test旧提供器配置没有路径索引仍可解码() throws {
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001)
        let configuration = DesktopDriveProviderConfiguration(
            mapping: .init(profileID: profile.id, displayName: "Synthetic", scope: .folder(path: "/share/test")),
            connection: .init(profile: profile, capabilities: .init([:])))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as? [String: Any])
        object["itemIdentifiersByPath"] = nil
        let decoded = try JSONDecoder().decode(DesktopDriveProviderConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(decoded, configuration)
    }

    func test记录损坏不被当作没有待上传修改() throws {
        let directory = try temporaryDirectory()
        let id = UUID()
        let store = DesktopDriveWritebackStore(directory: directory)
        try store.setEnabled(true, mappingID: id)
        let record = DesktopDriveWritebackRecord(mappingID: id, itemIdentifier: "synthetic", sourcePath: nil,
            destinationPath: "/share/test/file", isDirectory: true, contentHash: nil, contentSize: nil, baseContentVersion: nil)
        try store.save(record)
        let file = directory.appendingPathComponent("desktop-drive-writeback-v1").appendingPathComponent(id.uuidString).appendingPathComponent(record.id + ".json")
        try Data("broken".utf8).write(to: file)
        XCTAssertThrowsError(try store.requireNoPendingChanges(mappingID: id))
        XCTAssertThrowsError(try store.setEnabled(false, mappingID: id))
        XCTAssertTrue(try store.isEnabled(mappingID: id))
    }

    func test读取记录恢复独立于配置和下载缓存() throws {
        let directory = try temporaryDirectory()
        let mappingID = UUID()
        let first = DesktopDriveWritebackStore(directory: directory)
        XCTAssertFalse(try first.isEnabled(mappingID: mappingID))
        let file = directory.appendingPathComponent("source.txt")
        try Data("synthetic pending bytes".utf8).write(to: file)
        let record = DesktopDriveWritebackRecord(mappingID: mappingID, itemIdentifier: "synthetic", sourcePath: nil,
            destinationPath: "/share/test/file.txt", isDirectory: false, contentHash: try DesktopDriveWritebackStore.hash(of: file),
            contentSize: 23, baseContentVersion: nil)
        _ = try first.prepare(record, contents: file)
        let second = DesktopDriveWritebackStore(directory: directory)
        XCTAssertEqual(try second.pendingRecords(mappingID: mappingID), [record])
        XCTAssertEqual(try Data(contentsOf: second.contentURL(for: record)), try Data(contentsOf: file))
        XCTAssertThrowsError(try second.setEnabled(false, mappingID: mappingID))
    }

    func test目录移动保留后代标识并移动固定路径() async throws {
        let directory = try temporaryDirectory()
        let store = DesktopDriveConfigurationStore(directoryURL: directory)
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001)
        let mapping = DesktopDriveMapping(profileID: profile.id, displayName: "Synthetic", scope: .folder(path: "/share"))
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)
        try await store.registerItemPaths(mappingID: mapping.id, remotePaths: ["/share/old", "/share/old/file"])
        try await store.setPinnedPaths(["/share/old/file"], mappingID: mapping.id)
        let beforeValue = try await store.configuration(mappingID: mapping.id)
        let before = try XCTUnwrap(beforeValue)
        try await store.relocateItemPaths(mappingID: mapping.id, source: "/share/old", destination: "/share/new")
        try await store.registerItemPaths(mappingID: mapping.id, remotePaths: ["/share/old", "/share/new/file"])
        let afterValue = try await store.configuration(mappingID: mapping.id)
        let after = try XCTUnwrap(afterValue)
        XCTAssertEqual(before.itemIdentifiersByPath["/share/old/file"], after.itemIdentifiersByPath["/share/new/file"])
        XCTAssertEqual(before.itemIdentifiersByPath["/share/old"], after.itemIdentifiersByPath["/share/new"])
        XCTAssertNotEqual(after.itemIdentifiersByPath["/share/old"], after.itemIdentifiersByPath["/share/new"])
        let runtime = try await store.runtime(mappingID: mapping.id)
        XCTAssertTrue(runtime.keepsOffline("/share/new/file"))
        XCTAssertFalse(runtime.keepsOffline("/share/old/file"))
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WritebackStoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
