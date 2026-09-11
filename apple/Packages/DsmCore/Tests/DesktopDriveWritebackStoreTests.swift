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

    func test旧写回记录兼容且保存与删除收据互不混淆() throws {
        let id = UUID()
        let save = DesktopDriveWritebackRecord(mappingID: id, itemIdentifier: "synthetic", sourcePath: "/share/file",
            destinationPath: "/share/file", isDirectory: false, contentHash: nil, contentSize: nil, baseContentVersion: nil)
        let deletion = DesktopDriveWritebackRecord(mappingID: id, itemIdentifier: "synthetic", sourcePath: "/share/file",
            destinationPath: "/share/file", isDirectory: false, contentHash: nil, contentSize: nil, baseContentVersion: nil, operation: .delete)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(save)) as? [String: Any])
        old["operation"] = nil
        old["recursive"] = nil
        let decoded = try JSONDecoder().decode(DesktopDriveWritebackRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(decoded, save)
        XCTAssertFalse(decoded.isDeletion)
        XCTAssertNotEqual(save.id, deletion.id)
        XCTAssertEqual(try JSONDecoder().decode(DesktopDriveWritebackRecord.self, from: JSONEncoder().encode(deletion)), deletion)
    }

    func test删除授权默认关闭且关闭编辑后需重新确认() throws {
        let store = DesktopDriveWritebackStore(directory: try temporaryDirectory())
        let id = UUID()
        XCTAssertThrowsError(try store.setDeletionEnabled(true, mappingID: id))
        try store.setEnabled(true, mappingID: id)
        XCTAssertFalse(try store.isDeletionEnabled(mappingID: id))
        try store.setDeletionEnabled(true, mappingID: id)
        XCTAssertTrue(try store.isDeletionEnabled(mappingID: id))
        XCTAssertTrue(try store.records(mappingID: id).isEmpty)
        try store.setEnabled(false, mappingID: id)
        try store.setEnabled(true, mappingID: id)
        XCTAssertFalse(try store.isDeletionEnabled(mappingID: id))
    }

    func test待删除父目录阻止子文件写入且不能直接关闭授权() throws {
        let store = DesktopDriveWritebackStore(directory: try temporaryDirectory())
        let id = UUID()
        try store.setEnabled(true, mappingID: id)
        try store.setDeletionEnabled(true, mappingID: id)
        let deletion = DesktopDriveWritebackRecord(mappingID: id, itemIdentifier: "folder", sourcePath: "/share/folder",
            destinationPath: "/share/folder", isDirectory: true, contentHash: nil, contentSize: nil, baseContentVersion: nil,
            operation: .delete, recursive: true)
        _ = try store.prepare(deletion, contents: nil)
        let save = DesktopDriveWritebackRecord(mappingID: id, itemIdentifier: "child", sourcePath: nil,
            destinationPath: "/share/folder/file", isDirectory: false, contentHash: nil, contentSize: nil, baseContentVersion: nil)
        XCTAssertThrowsError(try store.prepare(save, contents: nil))
        XCTAssertThrowsError(try store.setDeletionEnabled(false, mappingID: id))
        try store.keepLocally(deletion)
        try store.setDeletionEnabled(false, mappingID: id)
        XCTAssertFalse(try store.isDeletionEnabled(mappingID: id))
    }

    func test删除生成后代变化记录且旧快照不能复活原标识() async throws {
        let directory = try temporaryDirectory()
        let store = DesktopDriveConfigurationStore(directoryURL: directory)
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001)
        let mapping = DesktopDriveMapping(profileID: profile.id, displayName: "Synthetic", scope: .folder(path: "/share"))
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)
        let path = "/share/folder/file"
        try await store.registerItemPaths(mappingID: mapping.id, remotePaths: [path])
        let before = try await store.configuration(mappingID: mapping.id)
        let identifier = try XCTUnwrap(before?.itemIdentifiersByPath[path])
        let item = FileItem(profileID: profile.id, name: "file", path: path, kind: .file)
        _ = try await store.refreshChangeJournal(mappingID: mapping.id, containerIdentifier: "workingSet",
            currentItems: [identifier: item], maximumEntryCount: 20, expectedRevision: nil)
        let revision = try await store.changeJournalRevision(mappingID: mapping.id, containerIdentifier: "workingSet")
        try await store.removeDeletedItemPaths(mappingID: mapping.id, remotePath: "/share/folder", maximumEntryCount: 20)
        let journal = try await store.changeJournal(mappingID: mapping.id, containerIdentifier: "workingSet")
        XCTAssertTrue(try XCTUnwrap(journal).isValid)
        XCTAssertEqual(journal?.entries.last?.kind, .deleted)
        XCTAssertEqual(journal?.entries.last?.itemIdentifier, identifier)
        do {
            _ = try await store.refreshChangeJournal(mappingID: mapping.id, containerIdentifier: "workingSet",
                currentItems: [identifier: item], maximumEntryCount: 20, expectedRevision: revision)
            XCTFail("旧快照不能重建已删除标识")
        } catch { XCTAssertEqual(error as? DesktopDriveConfigurationStoreError, .staleChangeJournal) }
        let restored = DesktopDriveConfigurationStore(directoryURL: directory)
        try await restored.registerItemPaths(mappingID: mapping.id, remotePaths: [path])
        let after = try await restored.configuration(mappingID: mapping.id)
        XCTAssertNotEqual(after?.itemIdentifiersByPath[path], identifier)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WritebackStoreTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
