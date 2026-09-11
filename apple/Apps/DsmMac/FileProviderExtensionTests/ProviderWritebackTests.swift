import DsmCore
import FileProvider
import Foundation
import XCTest
@testable import DsmFileProviderRuntime

final class ProviderWritebackTests: XCTestCase {
    func test未启用时保持只读且不发送写入() async throws {
        let context = try await makeContext(enabled: false)
        let item = try await context.runtime.item(for: context.identifier)
        XCTAssertFalse(item.capabilities.contains(.allowsWriting))
        await expect(.disabled) { _ = try await context.save() }
        let count = await context.repository.uploads
        XCTAssertEqual(count, 0)
    }

    func test相同内容版本覆盖并保留重复请求收据() async throws {
        let context = try await makeContext()
        let opened = try await context.runtime.item(for: context.identifier)
        let base = ProviderRequestedVersion(content: opened.itemVersion.contentVersion, metadata: opened.itemVersion.metadataVersion)
        let first = try await context.save(base: base)
        let second = try await context.save(base: base)
        XCTAssertEqual(first.itemVersion, second.itemVersion)
        let count = await context.repository.uploads
        XCTAssertEqual(count, 1)
        XCTAssertTrue(try context.journal.pendingRecords(mappingID: context.mapping.id).isEmpty)
        let record = try XCTUnwrap(context.journal.records(mappingID: context.mapping.id).first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try context.journal.contentURL(for: record).path))
    }

    func test内容版本改变时保留本机文件且不上传() async throws {
        let context = try await makeContext()
        let opened = try await context.runtime.item(for: context.identifier)
        await context.repository.externalEdit()
        await expect(.conflict) {
            _ = try await context.save(base: .init(content: opened.itemVersion.contentVersion, metadata: opened.itemVersion.metadataVersion))
        }
        let count = await context.repository.uploads
        XCTAssertEqual(count, 0)
        let record = try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first)
        XCTAssertEqual(record.phase, .conflict)
        XCTAssertEqual(try Data(contentsOf: context.journal.contentURL(for: record)), Data("local edits".utf8))
    }

    func test无可比较版本直接覆盖() async throws {
        let context = try await makeContext(versioned: false)
        let opened = try await context.runtime.item(for: context.identifier)
        await context.repository.externalEdit()
        _ = try await context.save(base: .init(content: opened.itemVersion.contentVersion, metadata: opened.itemVersion.metadataVersion))
        let bytes = await context.repository.files[context.path]
        XCTAssertEqual(bytes, Data("local edits".utf8))
    }

    func test新增检查标记不改变既有内容版本或阻断元数据更新后的下载() async throws {
        let context = try await makeContext()
        let item = try await context.runtime.item(for: context.identifier)
        let expected = DesktopDriveItemVersionStrategy.make(path: context.path, sizeBytes: 8, modifiedAt: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(item.itemVersion.contentVersion, expected.content)
        let file = try await context.runtime.fetchContents(for: context.identifier,
            requestedVersion: .init(content: expected.content, metadata: expected.metadata), progress: { _, _ in })
        XCTAssertEqual(try Data(contentsOf: file.0), Data("original".utf8))
    }

    func test打开时已有版本但保存时信息缺失不能直接覆盖() async throws {
        let context = try await makeContext()
        let item = try await context.runtime.item(for: context.identifier)
        await context.repository.setVersioned(false)
        await expect(.outcomeUnknown) {
            _ = try await context.save(base: .init(content: item.itemVersion.contentVersion, metadata: item.itemVersion.metadataVersion))
        }
        let count = await context.repository.uploads
        XCTAssertEqual(count, 0)
    }

    func test读取失败不能当成无版本而覆盖() async throws {
        let context = try await makeContext()
        await context.repository.setInfoFailure(true)
        do { _ = try await context.save(); XCTFail("读取失败必须阻止写入") } catch {}
        let count = await context.repository.uploads
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try context.journal.pendingRecords(mappingID: context.mapping.id).count, 1)
    }

    func test配置损坏后不能使用读取缓存继续写入() async throws {
        let context = try await makeContext()
        _ = try await context.runtime.item(for: context.identifier)
        let configuration = context.localFile.deletingLastPathComponent().appendingPathComponent("desktop-drive-config-v1.json")
        try Data("invalid".utf8).write(to: configuration)
        do { _ = try await context.save(); XCTFail("损坏的配置应阻止写入") } catch {}
        let count = await context.repository.uploads
        XCTAssertEqual(count, 0)
    }

    func test上传响应丢失后新实例只回读不重复覆盖() async throws {
        let context = try await makeContext()
        await context.repository.setLoseResponse(true)
        do { _ = try await context.save(); XCTFail("模拟响应丢失") } catch {}
        let restored = ProviderRuntime(mappingIdentifier: context.mapping.id.uuidString, dependencies: context.dependencies)
        _ = try await restored.writeItem(context.template, baseVersion: nil, contents: context.localFile, creating: false, progress: { _, _ in })
        let count = await context.repository.uploads
        XCTAssertEqual(count, 1)
        XCTAssertTrue(try context.journal.pendingRecords(mappingID: context.mapping.id).isEmpty)
    }

    func test系统刷新基础版本后仍复用未确认上传记录() async throws {
        let context = try await makeContext()
        let opened = try await context.runtime.item(for: context.identifier)
        await context.repository.setLoseResponse(true)
        do {
            _ = try await context.save(base: .init(content: opened.itemVersion.contentVersion, metadata: opened.itemVersion.metadataVersion))
        } catch {}
        let fresh = ProviderRuntime(mappingIdentifier: context.mapping.id.uuidString, dependencies: context.dependencies)
        let updated = try await fresh.item(for: context.identifier)
        _ = try await fresh.writeItem(context.template,
            baseVersion: .init(content: updated.itemVersion.contentVersion, metadata: updated.itemVersion.metadataVersion),
            contents: context.localFile, creating: false, progress: { _, _ in })
        let count = await context.repository.uploads
        XCTAssertEqual(count, 1)
    }

    func test结果未知且内容不符不自动重放() async throws {
        let context = try await makeContext()
        await context.repository.setLoseResponse(true)
        do { _ = try await context.save() } catch {}
        await context.repository.externalEdit()
        await expect(.outcomeUnknown) { _ = try await context.save() }
        let count = await context.repository.uploads
        XCTAssertEqual(count, 1)
    }

    func test用户确认后允许重新覆盖已变化文件() async throws {
        let context = try await makeContext()
        let opened = try await context.runtime.item(for: context.identifier)
        let base = ProviderRequestedVersion(content: opened.itemVersion.contentVersion, metadata: opened.itemVersion.metadataVersion)
        await context.repository.externalEdit()
        await expect(.conflict) { _ = try await context.save(base: base) }
        var record = try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first)
        record.allowOverwrite = true
        record.phase = .prepared
        try context.journal.save(record)
        _ = try await context.save(base: base)
        let count = await context.repository.uploads
        XCTAssertEqual(count, 1)
    }

    func test一次确认不能授权后续未知结果自动重复覆盖() async throws {
        let context = try await makeContext()
        await context.repository.setLoseResponse(true)
        do { _ = try await context.save() } catch {}
        await context.repository.externalEdit()
        var record = try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first)
        record.allowOverwrite = true
        try context.journal.save(record)
        await context.repository.setLoseResponse(true)
        do { _ = try await context.save() } catch {}
        await context.repository.externalEdit()
        await expect(.outcomeUnknown) { _ = try await context.save() }
        let count = await context.repository.uploads
        XCTAssertEqual(count, 2)
        XCTAssertFalse(try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first).allowOverwrite)
    }

    func test另存后停止不冒充保存成功且不再上传() async throws {
        let context = try await makeContext()
        await context.repository.setInfoFailure(true)
        do { _ = try await context.save() } catch {}
        let record = try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first)
        let exported = context.localFile.deletingLastPathComponent().appendingPathComponent("exported.txt")
        try FileManager.default.copyItem(at: context.journal.contentURL(for: record), to: exported)
        try context.journal.keepLocally(record)
        await context.repository.setInfoFailure(false)
        await expect(.keptLocally) { _ = try await context.save() }
        let count = await context.repository.uploads
        XCTAssertEqual(count, 0)
        XCTAssertTrue(try context.journal.pendingRecords(mappingID: context.mapping.id).isEmpty)
        XCTAssertEqual(try Data(contentsOf: exported), Data("local edits".utf8))
        XCTAssertNil(try context.journal.records(mappingID: context.mapping.id).first?.verifiedItem)
    }

    func test未上传修改阻止移除和清除连接() async throws {
        let context = try await makeContext()
        await context.repository.setInfoFailure(true)
        do { _ = try await context.save() } catch {}
        await expect(.pendingChanges) { try await context.store.setMappingState(.removing, mappingID: context.mapping.id) }
        await expect(.pendingChanges) { try await context.store.removeMapping(id: context.mapping.id) }
        await expect(.pendingChanges) { try await context.store.removeConnection(profileID: context.mapping.profileID) }
        let configuration = try await context.store.configuration(mappingID: context.mapping.id)
        XCTAssertNotNil(configuration)
    }

    func test跨实例互斥且释放后可恢复() async throws {
        let context = try await makeContext()
        var lease: DesktopDriveWritebackLease? = try context.journal.lock(mappingID: context.mapping.id)
        await expect(.busy) { _ = try await context.save() }
        withExtendedLifetime(lease) {}
        lease = nil
        _ = try await context.save()
    }

    func test新建普通文件和文件夹且不开放删除() async throws {
        let context = try await makeContext()
        let folder = ProviderImportedItemTemplate(identifier: .init("new-folder"), parentIdentifier: .rootContainer, filename: "new", isDirectory: true)
        let created = try await context.runtime.writeItem(folder, baseVersion: nil, contents: nil, creating: true, progress: { _, _ in })
        XCTAssertFalse(created.capabilities.contains(.allowsDeleting))
        XCTAssertFalse(created.capabilities.contains(.allowsTrashing))
        let file = ProviderImportedItemTemplate(identifier: .init("new-file"), parentIdentifier: created.itemIdentifier, filename: "created.txt", isDirectory: false)
        let saved = try await context.runtime.writeItem(file, baseVersion: nil, contents: context.localFile, creating: true, progress: { _, _ in })
        XCTAssertEqual(saved.filename, "created.txt")
    }

    func test移动重命名及后续枚举保持原项目标识() async throws {
        let context = try await makeContext()
        let folderPath = "/share/work/destination"
        await context.repository.addFolder(folderPath)
        try await context.store.registerItemPaths(mappingID: context.mapping.id, remotePaths: [folderPath])
        let folderID = try XCTUnwrap(DesktopDriveItemIdentity.identifier(mappingID: context.mapping.id, remotePath: folderPath))
        let moved = ProviderImportedItemTemplate(identifier: context.identifier, parentIdentifier: .init(folderID), filename: "renamed.txt", isDirectory: false)
        let saved = try await context.runtime.writeItem(moved, baseVersion: nil, contents: context.localFile, creating: false, progress: { _, _ in })
        XCTAssertEqual(saved.itemIdentifier, context.identifier)
        let repeated = try await context.runtime.writeItem(moved, baseVersion: nil, contents: context.localFile, creating: false, progress: { _, _ in })
        XCTAssertEqual(repeated.itemIdentifier, context.identifier)
        let fresh = ProviderRuntime(mappingIdentifier: context.mapping.id.uuidString, dependencies: context.dependencies)
        let page = try await fresh.enumerate(containerIdentifier: .init(folderID), offset: 0, limit: 10)
        XCTAssertEqual(page.items.first?.itemIdentifier, context.identifier)
        let count = await context.repository.uploads
        XCTAssertEqual(count, 1)
    }

    func test拒绝越界路径和回收站() async throws {
        let context = try await makeContext()
        for name in ["../outside", "#recycle"] {
            let template = ProviderImportedItemTemplate(identifier: .init("new"), parentIdentifier: .rootContainer, filename: name, isDirectory: false)
            await expect(.invalidItem) {
                _ = try await context.runtime.writeItem(template, baseVersion: nil, contents: context.localFile, creating: true, progress: { _, _ in })
            }
        }
        let count = await context.repository.uploads
        XCTAssertEqual(count, 0)
    }

    func test移动后原路径被重用不会抢占原文件标识() async throws {
        let context = try await makeContext()
        let renamed = ProviderImportedItemTemplate(identifier: context.identifier, parentIdentifier: .rootContainer, filename: "other.txt", isDirectory: false)
        _ = try await context.runtime.writeItem(renamed, baseVersion: nil, contents: nil, creating: false, progress: { _, _ in })
        await context.repository.externalEdit()
        let page = try await context.runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10)
        XCTAssertEqual(Set(page.items.map(\.itemIdentifier)).count, 2)
        XCTAssertEqual(page.items.first(where: { $0.filename == "other.txt" })?.itemIdentifier, context.identifier)
        XCTAssertNotEqual(page.items.first(where: { $0.filename == "example.txt" })?.itemIdentifier, context.identifier)
        let anchor = try await context.runtime.currentChangeAnchor(for: .rootContainer)
        XCTAssertFalse(anchor.isEmpty)
    }

    func test创建空文件仍核对内容并正确完成() async throws {
        let context = try await makeContext()
        let template = ProviderImportedItemTemplate(identifier: .init("empty"), parentIdentifier: .rootContainer, filename: "empty.txt", isDirectory: false)
        _ = try await context.runtime.writeItem(template, baseVersion: nil, contents: nil, creating: true, progress: { _, _ in })
        let bytes = await context.repository.files["/share/work/empty.txt"]
        XCTAssertEqual(bytes, Data())
    }

    private func expect(_ expected: DesktopDriveWritebackError, _ action: () async throws -> Void) async {
        do { try await action(); XCTFail("预期拒绝操作：\(expected)") }
        catch { XCTAssertEqual(error as? DesktopDriveWritebackError, expected) }
    }

    private func makeContext(enabled: Bool = true, versioned: Bool = true) async throws -> WritebackTestContext {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WritebackTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001)
        let mapping = DesktopDriveMapping(profileID: profile.id, displayName: "Synthetic", scope: .folder(path: "/share/work"))
        let store = DesktopDriveConfigurationStore(directoryURL: directory)
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)
        try await store.setMappingState(.available, mappingID: mapping.id)
        let path = "/share/work/example.txt"
        try await store.registerItemPaths(mappingID: mapping.id, remotePaths: [path])
        let identifier = NSFileProviderItemIdentifier(try XCTUnwrap(DesktopDriveItemIdentity.identifier(mappingID: mapping.id, remotePath: path)))
        let journal = DesktopDriveWritebackStore(directory: directory)
        try journal.setEnabled(enabled, mappingID: mapping.id)
        let localFile = directory.appendingPathComponent("local.txt")
        try Data("local edits".utf8).write(to: localFile)
        let repository = WritebackRepositoryProbe(profileID: profile.id, path: path, versioned: versioned)
        var dependencies = ProviderRuntimeDependencies(configurationStore: store, makeRepository: { _ in repository },
            temporaryDirectory: { _ in directory }, ensureCacheSpace: { _, _ in }, evictItem: { _, _ in },
            removeItem: { try? FileManager.default.removeItem(at: $0) }, capacityRecheckIntervalBytes: 1024, changeJournalMaximumEntries: 64)
        dependencies.writebackStore = journal
        dependencies.writebackAvailable = true
        return .init(mapping: mapping, path: path, identifier: identifier, store: store, journal: journal,
                     localFile: localFile, repository: repository, dependencies: dependencies,
                     runtime: ProviderRuntime(mappingIdentifier: mapping.id.uuidString, dependencies: dependencies))
    }
}

private struct WritebackTestContext {
    let mapping: DesktopDriveMapping
    let path: String
    let identifier: NSFileProviderItemIdentifier
    let store: DesktopDriveConfigurationStore
    let journal: DesktopDriveWritebackStore
    let localFile: URL
    let repository: WritebackRepositoryProbe
    let dependencies: ProviderRuntimeDependencies
    let runtime: ProviderRuntime
    var template: ProviderImportedItemTemplate { .init(identifier: identifier, parentIdentifier: .rootContainer, filename: "example.txt", isDirectory: false) }
    func save(base: ProviderRequestedVersion? = nil) async throws -> ProviderItem {
        try await runtime.writeItem(template, baseVersion: base, contents: localFile, creating: false, progress: { _, _ in })
    }
}

private actor WritebackRepositoryProbe: ProviderWritebackRepository {
    let profileID: UUID
    let originalPath: String
    var versioned: Bool
    var files: [String: Data]
    var folders: Set<String> = ["/share/work"]
    var time: TimeInterval = 1
    var uploads = 0
    var infoFailure = false
    var loseResponse = false
    init(profileID: UUID, path: String, versioned: Bool) {
        self.profileID = profileID; self.originalPath = path; self.versioned = versioned
        files = [path: Data("original".utf8)]
    }
    func setInfoFailure(_ value: Bool) { infoFailure = value }
    func setVersioned(_ value: Bool) { versioned = value }
    func setLoseResponse(_ value: Bool) { loseResponse = value }
    func externalEdit() { files[originalPath] = Data("external".utf8); time += 1 }
    func addFolder(_ path: String) { folders.insert(path) }
    func item(_ path: String) -> FileItem? {
        guard folders.contains(path) || files[path] != nil else { return nil }
        return FileItem(profileID: profileID, name: (path as NSString).lastPathComponent, path: path,
                        kind: folders.contains(path) ? .directory : .file, sizeBytes: files[path].map { Int64($0.count) },
                        times: versioned ? .init(modifiedAt: Date(timeIntervalSince1970: time), createdAt: nil, accessedAt: nil) : nil)
    }
    func getInfo(paths: [String]) async throws -> [FileItem] {
        if infoFailure { throw NSFileProviderError(.notAuthenticated) }
        return paths.compactMap(item)
    }
    func listShares(offset: Int, limit: Int) async throws -> FilePage { try await listFolder(path: "/share", offset: offset, limit: limit) }
    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage {
        let items = (Array(files.keys) + Array(folders)).filter { ($0 as NSString).deletingLastPathComponent == path }.compactMap(item)
        return FilePage(folderPath: path, items: items, offset: offset, total: items.count, hasMore: false)
    }
    func download(remotePath: String, to localURL: URL, expectedSize: Int64?, progress: @escaping FileTransferProgress) async throws {
        guard let bytes = files[remotePath] else { throw NSFileProviderError(.noSuchItem) }
        try bytes.write(to: localURL)
    }
    func removePartialDownload(to localURL: URL) async {}
    func upload(localURL: URL, to folderPath: String, overwrite: Bool, progress: @escaping FileTransferProgress) async throws {
        uploads += 1
        let path = (folderPath as NSString).appendingPathComponent(localURL.lastPathComponent)
        if overwrite || files[path] == nil { files[path] = try Data(contentsOf: localURL); time += 1 }
        if loseResponse { loseResponse = false; throw NSFileProviderError(.serverUnreachable) }
    }
    func result() throws -> MutationResult {
        try .init(status: .confirmedSuccess, operation: "write", submitted: true, requiresRefresh: false,
                  counts: .init(succeeded: 1, failed: 0, unknown: 0))
    }
    func createFolderResult(parentPath: String, name: String) async throws -> FileItemMutationOutcome {
        let path = (parentPath as NSString).appendingPathComponent(name)
        folders.insert(path)
        return try .init(result: result(), item: item(path))
    }
    func renameResult(path: String, newName: String) async throws -> FileItemMutationOutcome {
        let destination = ((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(newName)
        files[destination] = files.removeValue(forKey: path)
        if folders.remove(path) != nil { folders.insert(destination) }
        return try .init(result: result(), item: item(destination))
    }
    func copyMoveResult(_ request: FileCopyMoveRequest, progress: @escaping FileTransferProgress) async throws -> FileCopyMoveOutcome {
        let destination = (request.destinationFolderPath as NSString).appendingPathComponent(request.source.name)
        files[destination] = files.removeValue(forKey: request.source.path)
        if folders.remove(request.source.path) != nil { folders.insert(destination) }
        return try .init(result: result(), sourcePath: request.source.path, destinationPath: destination, item: item(destination))
    }
}
