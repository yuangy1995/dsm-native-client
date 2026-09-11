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

    func test全部共享挂载可复制文件和文件夹且不重复上传() async throws {
        let context = try await makeContext(scope: .allShares)
        let shares = try await context.runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10)
        let share = try XCTUnwrap(shares.items.first)
        XCTAssertTrue(share.capabilities.contains(.allowsWriting))
        XCTAssertFalse(share.capabilities.contains(.allowsRenaming))
        XCTAssertFalse(share.capabilities.contains(.allowsReparenting))
        XCTAssertFalse(share.capabilities.contains(.allowsDeleting))
        let template = ProviderImportedItemTemplate(identifier: .init("copied-folder"), parentIdentifier: share.itemIdentifier,
                                                    filename: "copied", isDirectory: true)
        let folder = try await context.runtime.writeItem(template, baseVersion: nil, contents: nil, creating: true, progress: { _, _ in })
        let file = ProviderImportedItemTemplate(identifier: .init("copied-file"), parentIdentifier: folder.itemIdentifier,
                                                filename: "example.txt", isDirectory: false)
        for _ in 0..<2 {
            _ = try await context.runtime.writeItem(file, baseVersion: nil, contents: context.localFile, creating: true, progress: { _, _ in })
        }
        let bytes = await context.repository.files["/share/copied/example.txt"]
        let uploads = await context.repository.uploads
        XCTAssertEqual(bytes, Data("local edits".utf8))
        XCTAssertEqual(uploads, 1)
        XCTAssertTrue(try context.journal.pendingRecords(mappingID: context.mapping.id).isEmpty)
    }

    func test全部共享挂载保护挂载根和共享目录本身() async throws {
        let context = try await makeContext(scope: .allShares)
        let root = try await context.runtime.item(for: .rootContainer)
        XCTAssertFalse(root.capabilities.contains(.allowsWriting))
        XCTAssertFalse(root.capabilities.contains(.allowsDeleting))
        for directory in [false, true] {
            let template = ProviderImportedItemTemplate(identifier: .init("new-root-item"), parentIdentifier: .rootContainer,
                                                        filename: "new", isDirectory: directory)
            await expect(.invalidItem) {
                _ = try await context.runtime.writeItem(template, baseVersion: nil, contents: context.localFile, creating: true, progress: { _, _ in })
            }
        }
        let shares = try await context.runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10)
        let share = try XCTUnwrap(shares.items.first)
        let renamed = ProviderImportedItemTemplate(identifier: share.itemIdentifier, parentIdentifier: .rootContainer,
                                                    filename: "renamed", isDirectory: true)
        await expect(.invalidItem) {
            _ = try await context.runtime.writeItem(renamed, baseVersion: nil, contents: nil, creating: false, progress: { _, _ in })
        }
        XCTAssertTrue(try context.journal.records(mappingID: context.mapping.id).isEmpty)
    }

    func test全部共享挂载仍须主动启用() async throws {
        let context = try await makeContext(enabled: false, scope: .allShares)
        let shares = try await context.runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10)
        let share = try XCTUnwrap(shares.items.first)
        XCTAssertFalse(share.capabilities.contains(.allowsWriting))
        let file = ProviderImportedItemTemplate(identifier: .init("copy"), parentIdentifier: share.itemIdentifier,
                                                filename: "example.txt", isDirectory: false)
        await expect(.disabled) {
            _ = try await context.runtime.writeItem(file, baseVersion: nil, contents: context.localFile, creating: true, progress: { _, _ in })
        }
        let uploads = await context.repository.uploads
        XCTAssertEqual(uploads, 0)
    }

    func test全部共享挂载保存已有文件并拒绝跨共享移动() async throws {
        let context = try await makeContext(scope: .allShares)
        try await context.store.registerItemPaths(mappingID: context.mapping.id, remotePaths: ["/share/work", "/other"])
        let parent = NSFileProviderItemIdentifier(try XCTUnwrap(DesktopDriveItemIdentity.identifier(mappingID: context.mapping.id, remotePath: "/share/work")))
        let file = ProviderImportedItemTemplate(identifier: context.identifier, parentIdentifier: parent,
                                                filename: "example.txt", isDirectory: false)
        _ = try await context.runtime.writeItem(file, baseVersion: nil, contents: context.localFile, creating: false, progress: { _, _ in })
        let bytes = await context.repository.files[context.path]
        XCTAssertEqual(bytes, Data("local edits".utf8))
        let other = NSFileProviderItemIdentifier(try XCTUnwrap(DesktopDriveItemIdentity.identifier(mappingID: context.mapping.id, remotePath: "/other")))
        let moved = ProviderImportedItemTemplate(identifier: context.identifier, parentIdentifier: other,
                                                 filename: "example.txt", isDirectory: false)
        await expect(.invalidItem) {
            _ = try await context.runtime.writeItem(moved, baseVersion: nil, contents: nil, creating: false, progress: { _, _ in })
        }
    }

    func test全部共享挂载尊重共享目录只读权限() async throws {
        let context = try await makeContext(scope: .allShares)
        await context.repository.setReadOnly(true)
        let shares = try await context.runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10)
        let share = try XCTUnwrap(shares.items.first)
        XCTAssertFalse(share.capabilities.contains(.allowsWriting))
        let file = ProviderImportedItemTemplate(identifier: .init("copy"), parentIdentifier: share.itemIdentifier,
                                                filename: "example.txt", isDirectory: false)
        do {
            _ = try await context.runtime.writeItem(file, baseVersion: nil, contents: context.localFile, creating: true, progress: { _, _ in })
            XCTFail("只读共享不能接收上传")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteNoPermission) }
        let uploads = await context.repository.uploads
        XCTAssertEqual(uploads, 0)
    }

    func test编辑授权不自动开放删除而独立确认后开放() async throws {
        let context = try await makeContext()
        let item = try await context.runtime.item(for: context.identifier)
        let base = ProviderRequestedVersion(content: item.itemVersion.contentVersion, metadata: item.itemVersion.metadataVersion)
        XCTAssertTrue(item.capabilities.contains(.allowsWriting))
        XCTAssertFalse(item.capabilities.contains(.allowsDeleting))
        await expect(.disabled) { try await context.delete(base: base) }
        try context.journal.setDeletionEnabled(true, mappingID: context.mapping.id)
        let enabled = try await context.runtime.item(for: context.identifier)
        XCTAssertTrue(enabled.capabilities.contains(.allowsDeleting))
        XCTAssertFalse(enabled.capabilities.contains(.allowsTrashing))
        try await context.delete(base: base)
        let count = await context.repository.deletes
        XCTAssertEqual(count, 1)
    }

    func test删除确认后新实例重复回调不再次删除() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        try await context.delete(base: base)
        let restored = ProviderRuntime(mappingIdentifier: context.mapping.id.uuidString, dependencies: context.dependencies)
        try await restored.deleteItem(identifier: context.identifier, baseVersion: base, recursive: false, progress: { _, _ in })
        let count = await context.repository.deletes
        XCTAssertEqual(count, 1)
        let record = try XCTUnwrap(context.journal.records(mappingID: context.mapping.id).first)
        XCTAssertTrue(record.isDeletion)
        XCTAssertEqual(record.phase, .verified)
        XCTAssertNil(record.verifiedItem)
        let path = try await context.store.remotePath(mappingID: context.mapping.id, itemIdentifier: context.identifier.rawValue)
        XCTAssertNil(path)
    }

    func test删除后同名新文件不会被旧请求删除() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        try await context.delete(base: base)
        await context.repository.externalEdit()
        let page = try await context.runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 20)
        let replacement = try XCTUnwrap(page.items.first)
        XCTAssertNotEqual(replacement.itemIdentifier, context.identifier)
        try await context.delete(base: base)
        let bytes = await context.repository.files[context.path]
        XCTAssertEqual(bytes, Data("external".utf8))
        try await context.runtime.deleteItem(identifier: replacement.itemIdentifier,
            baseVersion: .init(content: replacement.itemVersion.contentVersion, metadata: replacement.itemVersion.metadataVersion),
            recursive: false, progress: { _, _ in })
        let count = await context.repository.deletes
        XCTAssertEqual(count, 2)
    }

    func test删除响应丢失后重启只确认结果() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.setDeletion(applies: true, losesResponse: true)
        do { try await context.delete(base: base); XCTFail("应模拟响应丢失") } catch {}
        XCTAssertEqual(try context.journal.pendingRecords(mappingID: context.mapping.id).first?.phase, .submitted)
        let restored = ProviderRuntime(mappingIdentifier: context.mapping.id.uuidString, dependencies: context.dependencies)
        try await restored.deleteItem(identifier: context.identifier, baseVersion: base, recursive: false, progress: { _, _ in })
        let count = await context.repository.deletes
        XCTAssertEqual(count, 1)
        XCTAssertTrue(try context.journal.pendingRecords(mappingID: context.mapping.id).isEmpty)
    }

    func test删除结果未知且目标仍在时不自动重试() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.setDeletion(applies: false, losesResponse: true)
        do { try await context.delete(base: base) } catch {}
        await expect(.outcomeUnknown) { try await context.delete(base: base) }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 1)
        var record = try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first)
        record.allowOverwrite = true
        try context.journal.save(record)
        await context.repository.setDeletion(applies: true)
        try await context.delete(base: base)
        let retried = await context.repository.deletes
        XCTAssertEqual(retried, 2)
    }

    func test删除的一次确认不能授权后续自动重复请求() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.setDeletion(applies: false, losesResponse: true)
        do { try await context.delete(base: base) } catch {}
        var record = try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first)
        record.allowOverwrite = true
        try context.journal.save(record)
        await context.repository.setDeletion(applies: false, losesResponse: true)
        do { try await context.delete(base: base) } catch {}
        await expect(.outcomeUnknown) { try await context.delete(base: base) }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 2)
        XCTAssertFalse(try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first).allowOverwrite)
    }

    func test删除前版本变化会暂停且不能直接重试() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.externalEdit()
        await expect(.conflict) { try await context.delete(base: base) }
        await expect(.conflict) { try await context.delete(base: base) }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 0)
        var record = try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first)
        record.phase = .prepared
        record.allowOverwrite = true
        try context.journal.save(record)
        try await context.delete(base: base)
        let retried = await context.repository.deletes
        XCTAssertEqual(retried, 1)
    }

    func test删除已知版本信息缺失且系统刷新版本也不能放行() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.setVersioned(false)
        await expect(.outcomeUnknown) { try await context.delete(base: base) }
        await expect(.outcomeUnknown) {
            try await context.delete(base: .init(content: Data(), metadata: Data("unversioned:".utf8)))
        }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 0)
    }

    func test删除读取失败不能当成项目已不存在() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.setInfoFailure(true)
        do { try await context.delete(base: base); XCTFail("读取失败必须拒绝") } catch {}
        let count = await context.repository.deletes
        XCTAssertEqual(count, 0)
        let path = try await context.store.remotePath(mappingID: context.mapping.id, itemIdentifier: context.identifier.rawValue)
        XCTAssertEqual(path, context.path)
    }

    func test删除回读失败保留记录且恢复后不重复请求() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.setDeletionInfoFailure(true)
        do { try await context.delete(base: base); XCTFail("回读失败必须保留未确认") } catch {}
        XCTAssertEqual(try context.journal.pendingRecords(mappingID: context.mapping.id).count, 1)
        await context.repository.setDeletionInfoFailure(false)
        try await context.delete(base: base)
        let count = await context.repository.deletes
        XCTAssertEqual(count, 1)
    }

    func test文件可写但不允许删除时恢复系统项目且不发请求() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.protect(context.path)
        do { try await context.delete(base: base); XCTFail("没有删除权限") }
        catch { XCTAssertEqual((error as NSError).code, NSFileProviderError.deletionRejected.rawValue) }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 0)
    }

    func test全部共享删除保护根目录和共享文件夹() async throws {
        let context = try await makeContext(scope: .allShares, deletionEnabled: true)
        let shares = try await context.runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10)
        let share = try XCTUnwrap(shares.items.first)
        XCTAssertFalse(share.capabilities.contains(.allowsDeleting))
        for identifier in [NSFileProviderItemIdentifier.rootContainer, .trashContainer, .workingSet, share.itemIdentifier] {
            await expect(.invalidItem) {
                try await context.runtime.deleteItem(identifier: identifier, baseVersion: .init(content: Data(), metadata: Data()),
                    recursive: true, progress: { _, _ in })
            }
        }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 0)
    }

    func test文件夹非递归删除拒绝非空而递归删除清理后代() async throws {
        let context = try await makeContext(scope: .allShares, deletionEnabled: true)
        try await context.store.registerItemPaths(mappingID: context.mapping.id, remotePaths: ["/share/work"])
        let folderID = NSFileProviderItemIdentifier(try XCTUnwrap(DesktopDriveItemIdentity.identifier(mappingID: context.mapping.id, remotePath: "/share/work")))
        let folder = try await context.runtime.item(for: folderID)
        let base = ProviderRequestedVersion(content: folder.itemVersion.contentVersion, metadata: folder.itemVersion.metadataVersion)
        do {
            try await context.runtime.deleteItem(identifier: folderID, baseVersion: base, recursive: false, progress: { _, _ in })
            XCTFail("不能扩大删除范围")
        } catch { XCTAssertEqual((error as NSError).code, NSFileProviderError.directoryNotEmpty.rawValue) }
        XCTAssertTrue(try context.journal.pendingRecords(mappingID: context.mapping.id).isEmpty)
        try await context.store.setPinnedPaths([context.path], mappingID: context.mapping.id)
        try await context.runtime.deleteItem(identifier: folderID, baseVersion: base, recursive: true, progress: { _, _ in })
        let files = await context.repository.files
        XCTAssertTrue(files.isEmpty)
        let path = try await context.store.remotePath(mappingID: context.mapping.id, itemIdentifier: context.identifier.rawValue)
        XCTAssertNil(path)
        let runtime = try await context.store.runtime(mappingID: context.mapping.id)
        XCTAssertTrue(runtime.pinnedPaths.isEmpty)
        let flags = await context.repository.recursiveRequests
        XCTAssertEqual(flags, [true])
    }

    func test空文件夹删除保留非递归选项() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let path = "/share/work/empty"
        await context.repository.addFolder(path)
        try await context.store.registerItemPaths(mappingID: context.mapping.id, remotePaths: [path])
        let id = NSFileProviderItemIdentifier(try XCTUnwrap(DesktopDriveItemIdentity.identifier(mappingID: context.mapping.id, remotePath: path)))
        let item = try await context.runtime.item(for: id)
        try await context.runtime.deleteItem(identifier: id,
            baseVersion: .init(content: item.itemVersion.contentVersion, metadata: item.itemVersion.metadataVersion),
            recursive: false, progress: { _, _ in })
        let flags = await context.repository.recursiveRequests
        XCTAssertEqual(flags, [false])
    }

    func test递归删除遇到不可删子项或远程挂载时整个请求不发送() async throws {
        for remote in [false, true] {
            let context = try await makeContext(scope: .allShares, deletionEnabled: true)
            try await context.store.registerItemPaths(mappingID: context.mapping.id, remotePaths: ["/share/work"])
            if remote { await context.repository.addRemoteMount("/share/work/remote") }
            else { await context.repository.protect(context.path) }
            let id = NSFileProviderItemIdentifier(try XCTUnwrap(DesktopDriveItemIdentity.identifier(mappingID: context.mapping.id, remotePath: "/share/work")))
            let item = try await context.runtime.item(for: id)
            do {
                try await context.runtime.deleteItem(identifier: id,
                    baseVersion: .init(content: item.itemVersion.contentVersion, metadata: item.itemVersion.metadataVersion),
                    recursive: true, progress: { _, _ in })
                XCTFail("不能跨过受保护项目")
            } catch { XCTAssertEqual((error as NSError).code, NSFileProviderError.directoryNotEmpty.rawValue) }
            let count = await context.repository.deletes
            XCTAssertEqual(count, 0)
        }
    }

    func test待上传子文件阻止删除父目录() async throws {
        let context = try await makeContext(scope: .allShares, deletionEnabled: true)
        try await context.store.registerItemPaths(mappingID: context.mapping.id, remotePaths: ["/share/work"])
        let id = NSFileProviderItemIdentifier(try XCTUnwrap(DesktopDriveItemIdentity.identifier(mappingID: context.mapping.id, remotePath: "/share/work")))
        let item = try await context.runtime.item(for: id)
        _ = try context.journal.prepare(.init(mappingID: context.mapping.id, itemIdentifier: context.identifier.rawValue,
            sourcePath: context.path, destinationPath: context.path, isDirectory: false, contentHash: nil, contentSize: nil, baseContentVersion: nil), contents: nil)
        await expect(.pendingChanges) {
            try await context.runtime.deleteItem(identifier: id,
                baseVersion: .init(content: item.itemVersion.contentVersion, metadata: item.itemVersion.metadataVersion),
                recursive: true, progress: { _, _ in })
        }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 0)
    }

    func test停止未确认删除后恢复系统项目而不再发送删除() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.setDeletion(applies: false, losesResponse: true)
        do { try await context.delete(base: base) } catch {}
        let record = try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first)
        try context.journal.keepLocally(record)
        try context.journal.setDeletionEnabled(false, mappingID: context.mapping.id)
        do { try await context.delete(base: base); XCTFail("应要求系统恢复项目") }
        catch { XCTAssertEqual((error as NSError).code, NSFileProviderError.deletionRejected.rawValue) }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 1)
        await expect(.conflict) { try await context.delete(base: base) }
        try context.journal.setDeletionEnabled(true, mappingID: context.mapping.id)
        var renewed = try XCTUnwrap(context.journal.pendingRecords(mappingID: context.mapping.id).first)
        renewed.allowOverwrite = true
        renewed.phase = .prepared
        try context.journal.save(renewed)
        await context.repository.setDeletion(applies: true)
        try await context.delete(base: base)
        let retried = await context.repository.deletes
        XCTAssertEqual(retried, 2)
    }

    func test配置损坏和跨进程占用时不发送删除() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        var lease: DesktopDriveWritebackLease? = try context.journal.lock(mappingID: context.mapping.id)
        await expect(.busy) { try await context.delete(base: base) }
        withExtendedLifetime(lease) {}
        lease = nil
        let configuration = context.localFile.deletingLastPathComponent().appendingPathComponent("desktop-drive-config-v1.json")
        try Data("invalid".utf8).write(to: configuration)
        do { try await context.delete(base: base); XCTFail("损坏配置必须阻止删除") } catch {}
        let count = await context.repository.deletes
        XCTAssertEqual(count, 0)
    }

    func test远程挂载的深层子文件也不能删除() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        await context.repository.addRemoteMount("/share")
        await expect(.invalidItem) { try await context.delete(base: base) }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 0)
    }

    func test取消或暂停后不发送删除请求() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await context.delete(base: base)
        }
        do { try await task.value; XCTFail("取消后不得提交") } catch {}
        try await context.store.setMappingState(.paused, mappingID: context.mapping.id)
        await expect(.disabled) { try await context.delete(base: base) }
        let count = await context.repository.deletes
        XCTAssertEqual(count, 0)
    }

    func test删除后系统通知失败也不重新删除同名新文件() async throws {
        let context = try await makeContext(deletionEnabled: true)
        let base = try await context.baseVersion()
        var failingDependencies = context.dependencies
        failingDependencies.signalDeletion = { _ in throw NSFileProviderError(.serverUnreachable) }
        let failing = ProviderRuntime(mappingIdentifier: context.mapping.id.uuidString, dependencies: failingDependencies)
        do {
            try await failing.deleteItem(identifier: context.identifier, baseVersion: base, recursive: false, progress: { _, _ in })
            XCTFail("模拟通知失败")
        } catch {}
        XCTAssertEqual(try context.journal.records(mappingID: context.mapping.id).first?.phase, .verified)
        await context.repository.externalEdit()
        let page = try await context.runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 20)
        let replacement = try XCTUnwrap(page.items.first)
        try await context.delete(base: base)
        let bytes = await context.repository.files[context.path]
        XCTAssertEqual(bytes, Data("external".utf8))
        let current = try await context.store.configuration(mappingID: context.mapping.id)
        XCTAssertEqual(current?.itemIdentifiersByPath[context.path], replacement.itemIdentifier.rawValue)
        let count = await context.repository.deletes
        XCTAssertEqual(count, 1)
    }

    private func makeContext(enabled: Bool = true, versioned: Bool = true,
                             scope: DesktopDriveScope = .folder(path: "/share/work"),
                             deletionEnabled: Bool = false) async throws -> WritebackTestContext {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("WritebackTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001)
        let mapping = DesktopDriveMapping(profileID: profile.id, displayName: "Synthetic", scope: scope)
        let store = DesktopDriveConfigurationStore(directoryURL: directory)
        try await store.saveConnection(profile: profile, capabilities: .init([:]))
        try await store.saveMapping(mapping)
        try await store.setMappingState(.available, mappingID: mapping.id)
        let path = "/share/work/example.txt"
        try await store.registerItemPaths(mappingID: mapping.id, remotePaths: [path])
        let identifier = NSFileProviderItemIdentifier(try XCTUnwrap(DesktopDriveItemIdentity.identifier(mappingID: mapping.id, remotePath: path)))
        let journal = DesktopDriveWritebackStore(directory: directory)
        try journal.setEnabled(enabled, mappingID: mapping.id)
        if deletionEnabled { try journal.setDeletionEnabled(true, mappingID: mapping.id) }
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
    func baseVersion() async throws -> ProviderRequestedVersion {
        let item = try await runtime.item(for: identifier)
        return .init(content: item.itemVersion.contentVersion, metadata: item.itemVersion.metadataVersion)
    }
    func delete(base: ProviderRequestedVersion) async throws {
        try await runtime.deleteItem(identifier: identifier, baseVersion: base, recursive: false, progress: { _, _ in })
    }
}

private actor WritebackRepositoryProbe: ProviderWritebackRepository {
    let profileID: UUID
    let originalPath: String
    var versioned: Bool
    var files: [String: Data]
    var folders: Set<String> = ["/share", "/share/work"]
    var readOnly = false
    var deletes = 0
    var appliesDeletion = true
    var loseDeleteResponse = false
    var deletionInfoFailure = false
    var protectedPaths: Set<String> = []
    var remoteMounts: Set<String> = []
    var recursiveRequests: [Bool] = []
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
    func setReadOnly(_ value: Bool) { readOnly = value }
    func setDeletion(applies: Bool, losesResponse: Bool = false) { appliesDeletion = applies; loseDeleteResponse = losesResponse }
    func setDeletionInfoFailure(_ value: Bool) { deletionInfoFailure = value }
    func protect(_ path: String) { protectedPaths.insert(path) }
    func addRemoteMount(_ path: String) { folders.insert(path); remoteMounts.insert(path) }
    func removeExternally(_ path: String) { files[path] = nil; folders.remove(path) }
    func externalEdit() { files[originalPath] = Data("external".utf8); time += 1 }
    func addFolder(_ path: String) { folders.insert(path) }
    func item(_ path: String) -> FileItem? {
        guard folders.contains(path) || files[path] != nil else { return nil }
        return FileItem(profileID: profileID, name: (path as NSString).lastPathComponent, path: path,
                        kind: folders.contains(path) ? .directory : .file, sizeBytes: files[path].map { Int64($0.count) },
                        times: versioned ? .init(modifiedAt: Date(timeIntervalSince1970: time), createdAt: nil, accessedAt: nil) : nil,
                        permissions: .init(canRead: true, canWrite: !readOnly, canDelete: !readOnly && !protectedPaths.contains(path), posixMode: nil),
                        mountPointType: remoteMounts.contains(path) ? "remote" : nil)
    }
    func getInfo(paths: [String]) async throws -> [FileItem] {
        if infoFailure || (deletionInfoFailure && deletes > 0) { throw NSFileProviderError(.notAuthenticated) }
        return paths.compactMap(item)
    }
    func listShares(offset: Int, limit: Int) async throws -> FilePage { try await listFolder(path: "/", offset: offset, limit: limit) }
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

    func deleteResult(paths: [String], recursive: Bool, progress: @escaping FileTransferProgress) async throws -> MutationResult {
        deletes += 1
        recursiveRequests.append(recursive)
        if appliesDeletion {
            for path in paths {
                files = files.filter { recursive ? !DesktopDrivePath.isAncestorOrSame(path, of: $0.key) : $0.key != path }
                folders = folders.filter { recursive ? !DesktopDrivePath.isAncestorOrSame(path, of: $0) : $0 != path }
            }
        }
        if loseDeleteResponse { loseDeleteResponse = false; throw NSFileProviderError(.serverUnreachable) }
        return try result()
    }
}
