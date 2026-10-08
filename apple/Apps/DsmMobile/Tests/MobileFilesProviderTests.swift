import DsmCore
import DsmLocalization
@testable import DsmFileProviderRuntime
import DsmNetwork
@testable import DsmMobile
import FileProvider
import XCTest
import UIKit
import UniformTypeIdentifiers

@MainActor
final class MobileFilesProviderTests: XCTestCase {
    func test新增位置重复提交只注册一次且默认不授予编辑删除() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        async let first: Void = fixture.model.add()
        async let second: Void = fixture.model.add()
        _ = await (first, second)
        let row = try XCTUnwrap(fixture.model.rows.first)
        XCTAssertTrue(row.registered); XCTAssertFalse(row.editing); XCTAssertFalse(row.deleting)
        XCTAssertEqual(fixture.model.rows.count, 1)
        let additions = await fixture.domains.additions
        XCTAssertEqual(additions, 1)
        await fixture.model.add()
        let repeated = await fixture.domains.additions
        XCTAssertEqual(repeated, 1)
    }

    func test注册失败保留同一位置供重试且不假报成功() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        await fixture.domains.setFailure(true)
        await fixture.model.add()
        XCTAssertNotNil(fixture.model.error); XCTAssertFalse(fixture.model.addedLocation)
        let location = try XCTUnwrap(fixture.model.rows.first?.location)
        XCTAssertFalse(fixture.model.rows[0].registered)
        await fixture.domains.setFailure(false)
        await fixture.model.add()
        XCTAssertEqual(fixture.model.rows.first?.id, location.id)
        XCTAssertTrue(fixture.model.rows[0].registered)
    }

    func test同身份重新登录复用位置并只读取新发布会话() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation()
        let old = try XCTUnwrap(fixture.accounts.accounts().first)
        let new = try await fixture.publish()
        XCTAssertNotEqual(old.id, new.id)
        XCTAssertEqual(try fixture.locations.requireCurrent(location, accounts: fixture.accounts).id, new.id)
        await fixture.model.add()
        XCTAssertEqual(fixture.model.rows.map(\.id), [location.id])
        _ = try await fixture.runtime(location).enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10)
    }

    @available(iOS 17.1, *)
    func test系统尚未发现扩展时说明恢复方式并保留同一位置供手动重试() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let error = NSError(domain: NSFileProviderErrorDomain,
            code: NSFileProviderError.providerNotFound.rawValue,
            userInfo: [NSUnderlyingErrorKey: NSFileProviderError(.applicationExtensionNotFound)])
        await fixture.domains.setRegistrationError(error)
        await fixture.model.reload()
        XCTAssertEqual(fixture.model.error, L10n.string("mobile.files-location.extension-unavailable"))
        XCTAssertFalse(fixture.model.hasLoaded)
        await fixture.model.add()
        XCTAssertEqual(fixture.model.error, L10n.string("mobile.files-location.extension-unavailable"))
        XCTAssertFalse(fixture.model.addedLocation)
        let location = try XCTUnwrap(fixture.locations.locations().first)
        let additions = await fixture.domains.additions
        XCTAssertEqual(additions, 0)
        await fixture.domains.setRegistrationError(nil)
        await fixture.model.add()
        XCTAssertNil(fixture.model.error)
        XCTAssertTrue(fixture.model.addedLocation)
        XCTAssertEqual(fixture.model.rows.map(\.id), [location.id])
        let completedAdditions = await fixture.domains.additions
        XCTAssertEqual(completedAdditions, 1)
    }

    @available(iOS 17.1, *)
    func test只有明确未发现扩展才显示系统恢复提示() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        await fixture.domains.setRegistrationError(NSFileProviderError(.applicationExtensionNotFound) as NSError)
        await fixture.model.reload()
        XCTAssertEqual(fixture.model.error, L10n.string("mobile.files-location.extension-unavailable"))
        await fixture.domains.setRegistrationError(NSFileProviderError(.providerNotFound) as NSError)
        await fixture.model.reload()
        XCTAssertEqual(fixture.model.error, L10n.string("mobile.files-location.error"))
        await fixture.domains.setRegistrationError(NSError(domain: NSCocoaErrorDomain,
            code: NSFileProviderError.applicationExtensionNotFound.rawValue))
        await fixture.model.reload()
        XCTAssertEqual(fixture.model.error, L10n.string("mobile.files-location.error"))
    }

    func test相同配置编号换账号不能接管旧位置() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation()
        fixture.profile = try fixture.profile.updating(usernameHint: "replacement")
        _ = try await fixture.publish()
        XCTAssertThrowsError(try fixture.locations.requireCurrent(location, accounts: fixture.accounts))
        let error = await failure { _ = try await fixture.runtime(location).enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10) }
        XCTAssertNotNil(error)
        await fixture.model.add()
        XCTAssertEqual(fixture.model.rows.count, 1)
        XCTAssertNotEqual(fixture.model.rows[0].id, location.id)
        XCTAssertEqual(try fixture.locations.locations().count, 2)
    }

    func test证书变更停止旧位置且不覆盖绑定() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation()
        fixture.profile = try fixture.profile.updating(pinnedCertificateSHA256: String(repeating: "a", count: 64))
        _ = try await fixture.publish()
        XCTAssertThrowsError(try fixture.locations.requireCurrent(location, accounts: fixture.accounts))
        XCTAssertEqual(try fixture.locations.location(id: location.id), location)
    }

    func test退出后保留根信息和位置但停止远端读取() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation(), runtime = try fixture.runtime(location)
        try fixture.accounts.revoke(profileID: fixture.profile.id)
        let root = try await runtime.item(for: .rootContainer)
        XCTAssertEqual(root.filename, fixture.profile.displayName)
        let error = await failure { _ = try await runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10) }
        XCTAssertEqual((error as NSError?)?.code, NSFileProviderError.notAuthenticated.rawValue)
        XCTAssertEqual(try fixture.locations.locations().count, 1)
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.reads, 0)
    }

    func test真实资料仓库按需下载原内容并保持文件身份() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation(), runtime = try fixture.runtime(location)
        let file = try await fixture.file(runtime)
        let result = try await runtime.fetchContents(for: file.itemIdentifier, requestedVersion: nil, progress: { _, _ in })
        XCTAssertEqual(try String(contentsOf: result.0, encoding: .utf8), "Initial sample\n")
        XCTAssertEqual(result.1.itemIdentifier, file.itemIdentifier)
        XCTAssertTrue(file.capabilities.contains(.allowsEvicting))
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.downloads, 1)
        let cache = try await fixture.locations.configurationStore(id: location.id).runtime(mappingID: location.id)
        XCTAssertEqual(cache.cacheEntries.count, 1)
    }

    func test下载中退出取消旧传输且不交付文件() async throws {
        let fixture = try await Fixture(mode: "slow"); defer { fixture.cleanup() }
        let location = try await fixture.addLocation(), runtime = try fixture.runtime(location)
        let file = try await fixture.file(runtime)
        let task = Task { try await runtime.fetchContents(for: file.itemIdentifier, requestedVersion: nil, progress: { _, _ in }) }
        for _ in 0..<100 {
            if try await fixture.network.snapshot().downloads > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try fixture.accounts.revoke(profileID: fixture.profile.id)
        do { _ = try await task.value; XCTFail("撤销后不得交付下载") } catch {}
        let cache = try await fixture.locations.configurationStore(id: location.id).runtime(mappingID: location.id)
        XCTAssertTrue(cache.cacheEntries.isEmpty)
    }

    func test暂停阻止已经创建的资料仓库继续请求且恢复可用() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation()
        let store = try fixture.locations.configurationStore(id: location.id)
        let stored = try await store.configuration(mappingID: location.id)
        let configuration = try XCTUnwrap(stored)
        let repository = try await fixture.dependencies(location).makeRepository(configuration)
        _ = try await repository.listShares(offset: 0, limit: 10)
        await fixture.model.setPaused(true, location: location)
        let reads = try await fixture.network.snapshot().reads
        let error = await failure { _ = try await repository.listShares(offset: 0, limit: 10) }
        XCTAssertNotNil(error)
        let after = try await fixture.network.snapshot().reads
        XCTAssertEqual(reads, after)
        await fixture.model.setPaused(false, location: location)
        _ = try await repository.listShares(offset: 0, limit: 10)
    }

    func test绑定记录损坏时旧实例停止请求() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation(), runtime = try fixture.runtime(location)
        _ = try await fixture.file(runtime)
        try Data("invalid".utf8).write(to: fixture.locations.rootURL.appendingPathComponent("locations-v1.json"))
        let before = try await fixture.network.snapshot().reads
        let error = await failure { _ = try await runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10) }
        XCTAssertNotNil(error)
        let after = try await fixture.network.snapshot().reads
        XCTAssertEqual(before, after)
    }

    func test允许编辑后上传并回读而重复回调不再次上传() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation(), runtime = try fixture.runtime(location)
        await fixture.model.setEditing(true, location: location)
        let file = try await fixture.file(runtime)
        XCTAssertTrue(file.capabilities.contains(.allowsWriting)); XCTAssertFalse(file.capabilities.contains(.allowsDeleting))
        let edited = try fixture.edit("Edited sample\n")
        let base = ProviderRequestedVersion(content: file.itemVersion.contentVersion, metadata: file.itemVersion.metadataVersion)
        let template = ProviderImportedItemTemplate(item: file)
        let saved = try await runtime.writeItem(template, baseVersion: base, contents: edited, creating: false, progress: { _, _ in })
        XCTAssertEqual(saved.itemIdentifier, file.itemIdentifier)
        _ = try await runtime.writeItem(template, baseVersion: base, contents: edited, creating: false, progress: { _, _ in })
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.uploads, 1)
        XCTAssertEqual(state.nodes.first(where: { $0.path == "/Shared/Sample.txt" })?.content, Data("Edited sample\n".utf8))
        XCTAssertTrue(try fixture.locations.writebackStore(id: location.id).pendingRecords(mappingID: location.id).isEmpty)
    }

    func test远端变化不覆盖并保存本机副本供导出() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation(), runtime = try fixture.runtime(location)
        await fixture.model.setEditing(true, location: location)
        let file = try await fixture.file(runtime), edited = try fixture.edit("Local edit\n")
        try await fixture.network.changeRemoteFile("/Shared/Sample.txt", content: Data("Other edit\n".utf8))
        let error = await failure {
            _ = try await runtime.writeItem(.init(item: file), baseVersion: .init(content: file.itemVersion.contentVersion, metadata: file.itemVersion.metadataVersion),
                contents: edited, creating: false, progress: { _, _ in })
        }
        XCTAssertEqual(error as? DesktopDriveWritebackError, .conflict)
        let state = try await fixture.network.snapshot(); XCTAssertEqual(state.uploads, 0)
        let record = try XCTUnwrap(fixture.locations.writebackStore(id: location.id).pendingRecords(mappingID: location.id).first)
        let copy = try fixture.model.exportURL(record, location: location)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "Local edit\n")
        await fixture.model.stop(record, location: location)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertNotNil(fixture.model.error)
        await fixture.model.stop(record, location: location, exportedCopy: true)
        XCTAssertTrue(try fixture.locations.writebackStore(id: location.id).pendingRecords(mappingID: location.id).isEmpty)
    }

    func test删除授权独立且仅允许明确删除文件() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation(), runtime = try fixture.runtime(location)
        await fixture.model.setEditing(true, location: location)
        await fixture.model.setDeleting(true, location: location)
        let file = try await fixture.file(runtime)
        XCTAssertTrue(file.capabilities.contains(.allowsDeleting))
        try await runtime.deleteItem(identifier: file.itemIdentifier,
            baseVersion: .init(content: file.itemVersion.contentVersion, metadata: file.itemVersion.metadataVersion), recursive: false, progress: { _, _ in })
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.deletions, 1); XCTAssertFalse(state.nodes.contains { $0.path == "/Shared/Sample.txt" })
        XCTAssertTrue(state.nodes.contains { $0.path == "/Shared" })
    }

    func test未完成编辑阻止关闭授权和移除位置() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation()
        await fixture.model.setEditing(true, location: location)
        let journal = try fixture.locations.writebackStore(id: location.id)
        let record = DesktopDriveWritebackRecord(mappingID: location.id, itemIdentifier: "synthetic", sourcePath: nil,
            destinationPath: "/Shared/New", isDirectory: true, contentHash: nil, contentSize: nil, baseContentVersion: nil)
        _ = try journal.prepare(record, contents: nil)
        await fixture.model.setEditing(false, location: location)
        XCTAssertTrue(try journal.isEnabled(mappingID: location.id)); XCTAssertNotNil(fixture.model.error)
        await fixture.model.remove(location)
        let removals = await fixture.domains.removals
        XCTAssertEqual(removals, 0); XCTAssertEqual(try fixture.locations.locations().count, 1)
    }

    func test移除失败保持暂停且可以明确恢复() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation()
        await fixture.domains.setFailure(true)
        await fixture.model.remove(location)
        XCTAssertNotNil(fixture.model.error)
        XCTAssertTrue(fixture.model.rows[0].paused)
        await fixture.domains.setFailure(false)
        await fixture.model.setPaused(false, location: location)
        XCTAssertFalse(fixture.model.rows[0].paused)
        _ = try await fixture.runtime(location).enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10)
    }

    func test移除前重新检查账号不接受迟到结果() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation()
        await fixture.domains.suspendSettle()
        let task = Task { await fixture.model.remove(location) }
        for _ in 0..<100 {
            if await fixture.domains.waiting { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        fixture.profile = try fixture.profile.updating(usernameHint: "other")
        await fixture.domains.releaseSettle()
        await task.value
        let removals = await fixture.domains.removals
        XCTAssertEqual(removals, 0)
        XCTAssertEqual(try fixture.locations.locations().count, 1)
    }

    func test成功移除位置保留恢复目录且不修改NAS() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation()
        let directory = try fixture.locations.directory(id: location.id)
        await fixture.model.remove(location)
        XCTAssertNil(fixture.model.error); XCTAssertTrue(try fixture.locations.locations().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.deletions, 0); XCTAssertEqual(state.uploads, 0)
    }

    func test信任变化后可保存本机副本停止旧修改并添加新位置() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let location = try await fixture.addLocation()
        await fixture.model.setEditing(true, location: location)
        let journal = try fixture.locations.writebackStore(id: location.id)
        let edit = try fixture.edit("Preserved edit\n")
        let hash = try DesktopDriveWritebackStore.hash(of: edit)
        let record = try journal.prepare(.init(mappingID: location.id, itemIdentifier: "synthetic-local",
            sourcePath: "/Shared/Sample.txt", destinationPath: "/Shared/Sample.txt", isDirectory: false,
            contentHash: hash, contentSize: 15, baseContentVersion: nil), contents: edit)
        fixture.profile = try fixture.profile.updating(pinnedCertificateSHA256: String(repeating: "b", count: 64))
        _ = try await fixture.publish()
        await fixture.model.reload()
        XCTAssertFalse(fixture.model.rows[0].hasAccess)
        let copy = try fixture.model.exportURL(record, location: location)
        XCTAssertEqual(try String(contentsOf: copy, encoding: .utf8), "Preserved edit\n")
        await fixture.model.stop(record, location: location, exportedCopy: true)
        XCTAssertNil(fixture.model.error)
        await fixture.model.add()
        XCTAssertEqual(fixture.model.rows.count, 2)
        XCTAssertEqual(fixture.model.rows.filter(\.hasAccess).count, 1)
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.uploads, 0)
    }

    func test信任变化后明确移除旧位置不调用NAS且不接管其他位置() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let old = try await fixture.addLocation()
        fixture.profile = try fixture.profile.updating(pinnedCertificateSHA256: String(repeating: "c", count: 64))
        _ = try await fixture.publish()
        await fixture.model.add()
        let new = try XCTUnwrap(fixture.model.rows.first(where: { $0.hasAccess })?.location)
        await fixture.model.remove(old)
        XCTAssertNil(fixture.model.error)
        XCTAssertEqual(try fixture.locations.locations().map(\.id), [new.id])
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.reads, 0); XCTAssertEqual(state.deletions, 0)
    }

    func test取消系统导出不会报告副本已保存且完成只回调一次() {
        var completed = 0, exported = 0
        let delegate = MobileDocumentExporter.Coordinator(completion: { completed += 1 }, exported: { _ in exported += 1 })
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        delegate.documentPickerWasCancelled(picker)
        delegate.documentPicker(picker, didPickDocumentsAt: [URL(fileURLWithPath: "/synthetic-copy")])
        XCTAssertEqual(completed, 1); XCTAssertEqual(exported, 0)
    }

    func test系统导出成功只触发一次副本完成回调() {
        var completed = 0, exported = 0
        let delegate = MobileDocumentExporter.Coordinator(completion: { completed += 1 }, exported: { _ in exported += 1 })
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.data])
        delegate.documentPicker(picker, didPickDocumentsAt: [URL(fileURLWithPath: "/synthetic-copy")])
        delegate.documentPicker(picker, didPickDocumentsAt: [URL(fileURLWithPath: "/synthetic-copy")])
        delegate.documentPickerWasCancelled(picker)
        XCTAssertEqual(completed, 1); XCTAssertEqual(exported, 1)
    }

    func test已注册未启用位置单独显示且可以移除无需等待无法进行的同步() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        await fixture.domains.setEnabled(false)
        let location = try await fixture.addLocation()
        XCTAssertTrue(fixture.model.rows[0].registered)
        XCTAssertFalse(fixture.model.rows[0].systemEnabled)
        await fixture.domains.suspendSettle()
        await fixture.model.remove(location)
        XCTAssertNil(fixture.model.error)
        XCTAssertTrue(fixture.model.rows.isEmpty)
    }

    private func failure(_ operation: () async throws -> Void) async -> Error? {
        do { try await operation(); XCTFail("预期停止操作"); return nil } catch { return error }
    }

    @MainActor private final class Fixture {
        let root: URL
        let locations: MobileFilesLocationStore
        let accounts: MobileExtensionAccountStore
        let sessions = Sessions()
        let domains = Domains()
        let network: MobileFilesSyntheticTransport
        var profile: NasProfile
        lazy var model = MobileFilesSettingsModel(locations: locations, accounts: accounts, domains: domains, currentProfile: { [weak self] in self?.profile })

        init(mode: String = "success") async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("FilesTests-\(UUID().uuidString)")
            locations = .init(rootURL: root.appendingPathComponent("Locations"))
            accounts = .init(rootURL: root.appendingPathComponent("Accounts"))
            profile = try NasProfile(displayName: "Sample NAS", host: "files-ui.invalid", port: 5001, usernameHint: "synthetic")
            network = .init(root: root.appendingPathComponent("Server"), mode: mode)
            _ = try await publish()
        }
        func publish() async throws -> MobileExtensionAccount {
            try await MobileExtensionAccess(accounts: accounts, sessions: sessions).publish(profile: profile, connection: profile,
                capabilities: MobileFilesDebugEnvironment.capabilities, session: .init(sid: "synthetic-files", synoToken: nil, did: nil, isPortalPort: false))
        }
        func addLocation() async throws -> MobileFilesLocation {
            await model.add(); XCTAssertNil(model.error)
            return try XCTUnwrap(model.rows.first?.location)
        }
        func dependencies(_ location: MobileFilesLocation) throws -> ProviderRuntimeDependencies {
            var dependencies = try MobileFilesDependencies.make(locationID: location.id, locations: locations, accounts: accounts, sessions: sessions, transport: network)
            let temporary = root.appendingPathComponent("Downloads")
            dependencies.temporaryDirectory = { _ in try MobileExtensionStorage.prepareDirectory(temporary); return temporary }
            dependencies.ensureCacheSpace = { _, _ in }
            dependencies.evictItem = { _, _ in }
            dependencies.waitForChildren = { _, _ in }
            dependencies.signalDeletion = { _ in }
            return dependencies
        }
        func runtime(_ location: MobileFilesLocation) throws -> ProviderRuntime {
            try .init(mappingIdentifier: location.id.uuidString, dependencies: dependencies(location))
        }
        func file(_ runtime: ProviderRuntime) async throws -> ProviderItem {
            let shares = try await runtime.enumerate(containerIdentifier: .rootContainer, offset: 0, limit: 10)
            let shared = try XCTUnwrap(shares.items.first)
            let files = try await runtime.enumerate(containerIdentifier: shared.itemIdentifier, offset: 0, limit: 10)
            return try XCTUnwrap(files.items.first)
        }
        func edit(_ text: String) throws -> URL {
            let url = root.appendingPathComponent("Edit.txt")
            try Data(text.utf8).write(to: url); return url
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private actor Sessions: SessionSecureStoring {
        var values: [UUID: AuthSession] = [:]
        func load(for id: UUID) async throws -> AuthSession? { values[id] }
        func save(_ session: AuthSession, for id: UUID) async throws { values[id] = session }
        func remove(for id: UUID) async throws { values[id] = nil }
    }

    private actor Domains: MobileFilesDomainControlling {
        var registered: Set<UUID> = []
        var additions = 0, removals = 0
        var enabled = true
        var fail = false, shouldSuspend = false, waiting = false
        var registrationError: NSError?
        var continuation: CheckedContinuation<Void, Never>?
        func registrations() async throws -> [UUID: Bool] {
            if let registrationError { throw registrationError }
            return Dictionary(uniqueKeysWithValues: registered.map { ($0, enabled) })
        }
        func add(_ location: MobileFilesLocation) async throws {
            additions += 1
            if fail { throw NSFileProviderError(.providerNotFound) }
            try await Task.sleep(for: .milliseconds(20))
            registered.insert(location.id)
        }
        func signal(_ location: MobileFilesLocation) async throws {}
        func captureLocalChanges(_ location: MobileFilesLocation) async throws {}
        func recover(_ record: DesktopDriveWritebackRecord, location: MobileFilesLocation) async throws {}
        func settle(_ location: MobileFilesLocation) async throws {
            if shouldSuspend { waiting = true; await withCheckedContinuation { continuation = $0 }; waiting = false }
        }
        func remove(_ location: MobileFilesLocation) async throws {
            removals += 1
            if fail { throw NSFileProviderError(.cannotSynchronize) }
            registered.remove(location.id)
        }
        func setEnabled(_ value: Bool) { enabled = value }
        func setFailure(_ value: Bool) { fail = value }
        func setRegistrationError(_ error: NSError?) { registrationError = error }
        func suspendSettle() { shouldSuspend = true }
        func releaseSettle() { continuation?.resume(); continuation = nil; shouldSuspend = false }
    }
}
