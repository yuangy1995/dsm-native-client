#if os(iOS)
import DsmCore
import FileProvider
import Foundation
import XCTest
@testable import DsmFileProviderRuntime

final class ProviderLocalStorageTests: XCTestCase {
    func test远端刷新不替换本机未保存内容或原始版本() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let initial = f.provider(version: 1, text: "original")
        try f.materialize(initial, text: "original")
        try Data("local edit".utf8).write(to: f.localURL())
        try f.storage.store(f.provider(version: 2, text: "remote edit"), remotePath: f.path)
        XCTAssertEqual(try String(contentsOf: f.localURL(), encoding: .utf8), "local edit")
        XCTAssertEqual(try f.storage.item(f.identifier).baseContentVersion, initial.itemVersion.contentVersion)
        let record = try XCTUnwrap(f.storage.captureChanges(f.identifier))
        XCTAssertEqual(record.baseContentVersion, initial.itemVersion.contentVersion)
        XCTAssertEqual(try String(contentsOf: f.journal.contentURL(for: record), encoding: .utf8), "local edit")
    }

    func test干净副本随远端版本变化失效并按需重新下载() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.materialize(f.provider(version: 1, text: "original"), text: "original")
        let url = try f.localURL()
        let remote = f.provider(version: 2, text: "remote")
        try f.storage.store(remote, remotePath: f.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(try f.storage.item(f.identifier).baseHash)
        XCTAssertEqual(try f.storage.item(f.identifier).contentVersion, remote.itemVersion.contentVersion)
    }

    func test系统回调先冻结原内容且后续编辑不覆盖未结束副本() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.materialize(f.provider(version: 1, text: "original"), text: "original")
        try Data("first edit".utf8).write(to: f.localURL())
        let first = try XCTUnwrap(f.storage.captureChanges(f.identifier))
        try Data("second edit".utf8).write(to: f.localURL())
        XCTAssertNil(try f.storage.captureChanges(f.identifier))
        XCTAssertEqual(try f.journal.pendingRecords(mappingID: f.mapping.id).count, 1)
        XCTAssertEqual(try String(contentsOf: f.journal.contentURL(for: first), encoding: .utf8), "first edit")
        XCTAssertThrowsError(try f.storage.requireNoUnsavedChanges())
    }

    func test未保存内容和未结束改名均不能被回收或移除() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.materialize(f.provider(version: 1, text: "original"), text: "original")
        let current = try f.storage.item(f.identifier)
        let rename = DesktopDriveWritebackRecord(mappingID: f.mapping.id, itemIdentifier: f.identifier.rawValue,
            sourcePath: f.path, destinationPath: "/share/renamed.txt", isDirectory: false,
            contentHash: nil, contentSize: nil, baseContentVersion: current.baseContentVersion)
        _ = try f.journal.prepare(rename, contents: nil)
        XCTAssertThrowsError(try f.storage.evict(f.identifier))
        XCTAssertThrowsError(try f.storage.remove(f.identifier))
        XCTAssertEqual(try String(contentsOf: f.localURL(), encoding: .utf8), "original")
    }

    func test保存成功只采用该次回执版本而非后续远端版本() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.materialize(f.provider(version: 1, text: "original"), text: "original")
        try Data("saved".utf8).write(to: f.localURL())
        let pending = try XCTUnwrap(f.storage.captureChanges(f.identifier))
        let saved = f.file(version: 2, text: "saved")
        try f.journal.complete(pending, item: saved)
        let provider = f.provider(saved)
        try f.storage.recordWrite(provider, remotePath: f.path, submittedHash: pending.contentHash)
        try Data("next local".utf8).write(to: f.localURL())
        try f.storage.store(f.provider(version: 3, text: "next remote"), remotePath: f.path)
        let next = try XCTUnwrap(f.storage.captureChanges(f.identifier))
        XCTAssertEqual(next.baseContentVersion, provider.itemVersion.contentVersion)
        XCTAssertEqual(try String(contentsOf: f.journal.contentURL(for: next), encoding: .utf8), "next local")
    }

    func test当前编辑授权和真实只读权限各自限制本地项目() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.storage.store(f.provider(version: 1, text: "original"), remotePath: f.path)
        XCTAssertTrue(try XCTUnwrap(f.storage.cachedItem(f.identifier).capabilities).contains(.allowsWriting))
        try f.journal.setEnabled(false, mappingID: f.mapping.id)
        XCTAssertFalse(try XCTUnwrap(f.storage.cachedItem(f.identifier).capabilities).contains(.allowsWriting))
        try f.journal.setEnabled(true, mappingID: f.mapping.id)
        try f.storage.store(f.provider(f.file(version: 1, text: "original", writable: false)), remotePath: f.path)
        XCTAssertFalse(try XCTUnwrap(f.storage.cachedItem(f.identifier).capabilities).contains(.allowsWriting))
        XCTAssertFalse(try XCTUnwrap(f.storage.cachedItem(f.identifier).capabilities).contains(.allowsDeleting))
    }

    func test重建存储保留副本基线且损坏记录不被覆盖() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let item = f.provider(version: 1, text: "original")
        try f.materialize(item, text: "original")
        let reopened = try f.makeStorage()
        XCTAssertEqual(try reopened.item(f.identifier).baseContentVersion, item.itemVersion.contentVersion)
        let snapshot = f.state.appendingPathComponent("file-provider-items-v1.json")
        let broken = Data("{invalid".utf8)
        try broken.write(to: snapshot)
        XCTAssertThrowsError(try reopened.store(item, remotePath: f.path))
        XCTAssertEqual(try Data(contentsOf: snapshot), broken)
    }

    func test符号链接不能让原位写回读取位置外的内容() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.materialize(f.provider(version: 1, text: "original"), text: "original")
        let url = try f.localURL()
        let privateFile = f.root.appendingPathComponent("private.txt")
        try Data("private test content".utf8).write(to: privateFile)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: privateFile)
        XCTAssertThrowsError(try f.storage.captureChanges(f.identifier))
        XCTAssertTrue(try f.journal.records(mappingID: f.mapping.id).isEmpty)
        XCTAssertEqual(try String(contentsOf: privateFile, encoding: .utf8), "private test content")
    }

    func test另一个位置不能接管既有本地副本记录() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.materialize(f.provider(version: 1, text: "original"), text: "original")
        let other = DesktopDriveMapping(profileID: UUID(), displayName: "Other", scope: .folder(path: "/share"))
        XCTAssertThrowsError(try ProviderLocalStorage(mapping: other,
            documentStorageURL: f.root.appendingPathComponent("Documents"), stateDirectory: f.state,
            journal: f.journal, purposeIdentifier: "ProviderLocalTests"))
        XCTAssertEqual(try String(contentsOf: f.localURL(), encoding: .utf8), "original")
    }

    private final class Fixture {
        let root: URL
        let state: URL
        let mapping: DesktopDriveMapping
        let journal: DesktopDriveWritebackStore
        let storage: ProviderLocalStorage
        let path = "/share/example.txt"
        var identifier: NSFileProviderItemIdentifier {
            .init(DesktopDriveItemIdentity.identifier(mappingID: mapping.id, remotePath: path)!)
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ProviderLocal-" + UUID().uuidString)
            state = root.appendingPathComponent("State")
            mapping = .init(profileID: UUID(), displayName: "Synthetic", scope: .folder(path: "/share"))
            journal = .init(directory: root.appendingPathComponent("Journal"))
            try journal.setEnabled(true, mappingID: mapping.id)
            try journal.setDeletionEnabled(true, mappingID: mapping.id)
            storage = try .init(mapping: mapping, documentStorageURL: root.appendingPathComponent("Documents"),
                stateDirectory: state, journal: journal, purposeIdentifier: "ProviderLocalTests")
        }
        func makeStorage() throws -> ProviderLocalStorage {
            try .init(mapping: mapping, documentStorageURL: root.appendingPathComponent("Documents"),
                stateDirectory: state, journal: journal, purposeIdentifier: "ProviderLocalTests")
        }
        func file(version: TimeInterval, text: String, writable: Bool = true) -> FileItem {
            .init(profileID: mapping.profileID, name: "example.txt", path: path, kind: .file,
                sizeBytes: Int64(text.utf8.count),
                times: .init(modifiedAt: Date(timeIntervalSince1970: version), createdAt: nil, accessedAt: nil),
                permissions: .init(canRead: true, canWrite: writable, canDelete: writable, posixMode: nil))
        }
        func provider(_ file: FileItem) -> ProviderItem {
            .init(fileItem: file, mapping: mapping, keptOffline: false, writable: true, deletable: true)
        }
        func provider(version: TimeInterval, text: String) -> ProviderItem { provider(file(version: version, text: text)) }
        func materialize(_ item: ProviderItem, text: String) throws {
            let source = root.appendingPathComponent("incoming.txt")
            try Data(text.utf8).write(to: source)
            try storage.materialize(source, item: item, remotePath: path)
        }
        func localURL() throws -> URL { try storage.localURL(storage.item(identifier)) }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
#endif
