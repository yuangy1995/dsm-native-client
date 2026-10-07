import DsmCore
import DsmFileFeature
import DsmNetwork
@testable import DsmMobile
import UniformTypeIdentifiers
import XCTest

@MainActor
final class MobileShareTransferTests: XCTestCase {
    func test没有账号不读取外部文件且不能上传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.accounts.revoke(profileID: fixture.profile.id)
        let model = fixture.model()
        await model.load()
        XCTAssertEqual(model.phase, .failed)
        XCTAssertFalse(model.canUpload)
        XCTAssertNotNil(model.error)
        await model.upload(overwrite: false)
        XCTAssertTrue(try fixture.transfers.records().isEmpty)
    }

    func test根目录禁用上传进入目录后可用且重复加载不重接收() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var loads = 0
        let model = fixture.model(loadInput: { loads += 1; return [fixture.file] })
        await model.load(); await model.load()
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(model.folders.map(\.path), ["/Shared"])
        XCTAssertFalse(model.canUpload)
        await model.navigate(to: "/Shared")
        XCTAssertTrue(model.canUpload)
        XCTAssertEqual(model.folders.map(\.path), ["/Shared/Subfolder"])
        await model.goUp()
        XCTAssertFalse(model.canUpload)
        XCTAssertEqual(model.path, "")
        await model.close()
    }

    func test读取文件夹失败有恢复入口且零上传() async throws {
        let fixture = try Fixture(mode: "folder-error")
        defer { fixture.cleanup() }
        let model = fixture.model()
        await model.load()
        XCTAssertNotNil(model.folderError)
        XCTAssertFalse(model.canUpload)
        await model.upload(overwrite: false)
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.uploads, 0)
        XCTAssertTrue(try fixture.transfers.records().isEmpty)
    }

    func test分享上传结果持久化且主应用恢复不重传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        try await begin(model)
        try await settled(model)
        XCTAssertTrue(model.allSucceeded)
        let records = try fixture.transfers.records()
        XCTAssertEqual(records.count, 1)
        await model.close()
        let recovery = fixture.recovery()
        try await ready(recovery)
        let queue = try XCTUnwrap(recovery.jobs.first?.queue)
        try await ready(queue)
        XCTAssertEqual(queue.batches.first?.entries.map(\.state), [.succeeded])
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.uploads, 1)
        XCTAssertEqual(state.files, ["/Shared/Sample.txt"])
        queue.removeFinished(try XCTUnwrap(queue.batches.first))
        recovery.removeEmpty(try XCTUnwrap(recovery.jobs.first))
        XCTAssertTrue(try fixture.transfers.records().isEmpty)
    }

    func test连续提交只产生一个任务和一次上传() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        await model.load(); await model.navigate(to: "/Shared")
        let first = Task { await model.upload(overwrite: false) }
        let second = Task { await model.upload(overwrite: false) }
        await first.value; await second.value
        try await settled(model)
        XCTAssertEqual(try fixture.transfers.records().count, 1)
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.uploads, 1)
        await model.close()
    }

    func test扩展持有任务时主应用不能接管关闭后仅暂停恢复() async throws {
        let fixture = try Fixture(mode: "slow")
        defer { fixture.cleanup() }
        let model = fixture.model()
        try await begin(model)
        let recovery = fixture.recovery()
        try await ready(recovery)
        XCTAssertEqual(recovery.jobs.count, 1)
        XCTAssertNil(recovery.jobs[0].queue)
        await model.close()
        recovery.refresh()
        let queue = try XCTUnwrap(recovery.jobs.first?.queue)
        try await ready(queue)
        XCTAssertEqual(queue.batches.first?.entries.map(\.state), [.paused])
        XCTAssertFalse(queue.batches.first?.isRunning ?? true)
        let before = try await fixture.network.snapshot().uploads
        try await Task.sleep(for: .milliseconds(100))
        let after = try await fixture.network.snapshot().uploads
        XCTAssertEqual(before, after)
    }

    func test发送后丢回执由原记录回读成功而不重传() async throws {
        let fixture = try Fixture(mode: "unknown")
        defer { fixture.cleanup() }
        let model = fixture.model()
        try await begin(model); try await settled(model)
        XCTAssertEqual(model.queue?.batches.first?.entries.map(\.state), [.unverified])
        await model.close()
        let recovery = fixture.recovery(); try await ready(recovery)
        let queue = try XCTUnwrap(recovery.jobs.first?.queue); try await ready(queue)
        let batch = try XCTUnwrap(queue.batches.first)
        XCTAssertEqual(batch.entries.map(\.state), [.unverified])
        await queue.refresh(batch)
        XCTAssertEqual(batch.entries.map(\.state), [.succeeded])
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.uploads, 1)
    }

    func test未提交关闭清理输入且不产生恢复任务() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var cleanups = 0
        let model = fixture.model(cleanupInput: { cleanups += 1 })
        await model.load(); await model.close(); await model.close()
        XCTAssertEqual(cleanups, 1)
        XCTAssertTrue(try fixture.transfers.records().isEmpty)
        await model.upload(overwrite: false)
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.uploads, 0)
    }

    func test同名跳过保持服务器文件且零写入() async throws {
        let fixture = try Fixture(mode: "conflict")
        defer { fixture.cleanup() }
        let model = fixture.model()
        try await begin(model); try await settled(model)
        XCTAssertEqual(model.queue?.batches.first?.entries.map(\.state), [.skipped])
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.uploads, 0)
        await model.close()
    }

    func test选择后的账号被撤销时不能提交() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        await model.load(); await model.navigate(to: "/Shared")
        try fixture.accounts.revoke(profileID: fixture.profile.id)
        await model.upload(overwrite: false)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(try fixture.transfers.records().isEmpty)
        let state = try await fixture.network.snapshot()
        XCTAssertEqual(state.uploads, 0)
        await model.close()
    }

    func test恢复记录不会给同编号的另一个账号() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        try await begin(model); try await settled(model); await model.close()
        let recovery = MobileShareTransferRecovery(store: fixture.transfers)
        let replacement = try fixture.profile.updating(usernameHint: "other")
        recovery.configure(profile: replacement, repository: fixture.repository)
        try await ready(recovery)
        XCTAssertTrue(recovery.jobs.isEmpty)
        XCTAssertEqual(try fixture.transfers.records().count, 1)
    }

    func test恢复队列身份不符时不得当作空记录删除副本() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let model = fixture.model()
        try await begin(model); try await settled(model); await model.close()
        let record = try XCTUnwrap(fixture.transfers.records().first)
        let queueURL = fixture.transfers.queueURL(record.id).appendingPathComponent("queue-v1.json")
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: queueURL)) as? [String: Any])
        var rows = try XCTUnwrap(envelope["records"] as? [[String: Any]])
        rows[0]["context"] = "other-synthetic-account"
        envelope["records"] = rows
        let altered = try JSONSerialization.data(withJSONObject: envelope)
        try altered.write(to: queueURL)
        let recovery = fixture.recovery(); try await ready(recovery)
        let job = try XCTUnwrap(recovery.jobs.first)
        let queue = try XCTUnwrap(job.queue); try await ready(queue)
        XCTAssertNotNil(queue.recoveryError)
        recovery.removeEmpty(job)
        XCTAssertEqual(try fixture.transfers.records(), [record])
        XCTAssertEqual(try Data(contentsOf: queueURL), altered)
    }

    func test任务锁独占且释放后才能接手() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var owned: (MobileShareTransfer, MobileShareTransferLease)? = try fixture.transfers.create(profile: fixture.profile)
        let record = try XCTUnwrap(owned?.0)
        XCTAssertThrowsError(try fixture.transfers.claim(record)) { XCTAssertTrue($0 is MobileShareTransferLease.LeaseError) }
        owned = nil
        let lease = try fixture.transfers.claim(record)
        try fixture.transfers.remove(record, lease: lease)
        XCTAssertTrue(try fixture.transfers.records().isEmpty)
    }

    func test系统附件在回调结束前冻结且保留正确文件扩展名() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let provider = NSItemProvider()
        provider.suggestedName = "Sample"
        provider.registerFileRepresentation(forTypeIdentifier: UTType.plainText.identifier, fileOptions: [], visibility: .all) { completion in
            completion(fixture.file, false, nil)
            try? FileManager.default.removeItem(at: fixture.file)
            return nil
        }
        let files = try await MobileShareIntake.receive([provider], directory: fixture.root.appendingPathComponent("Input"))
        XCTAssertEqual(files.map(\.lastPathComponent), ["Sample.txt"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: files[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func test接收拒绝越界文件名和符号链接且网页不冒充文件() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let input = fixture.root.appendingPathComponent("Input")
        try MobileExtensionStorage.prepareDirectory(input)
        for name in ["../outside", ".", "..", "a/b", "a\0b"] {
            XCTAssertThrowsError(try MobileShareIntake.copyRepresentation(fixture.file, suggestedName: name,
                type: UTType.fileURL.identifier, directory: input))
        }
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.file)
        XCTAssertThrowsError(try MobileShareIntake.copyRepresentation(link, suggestedName: nil,
            type: UTType.fileURL.identifier, directory: input))
        let provider = NSItemProvider(object: URL(string: "https://example.invalid")! as NSURL)
        XCTAssertNil(MobileShareIntake.supportedType(for: provider))
    }

    private func begin(_ model: MobileShareComposerModel) async throws {
        await model.load(); await model.navigate(to: "/Shared")
        XCTAssertTrue(model.canUpload)
        await model.upload(overwrite: false)
        XCTAssertEqual(model.phase, .submitted)
    }
    private func settled(_ model: MobileShareComposerModel) async throws {
        for _ in 0..<400 where model.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isRunning)
    }
    private func ready(_ recovery: MobileShareTransferRecovery) async throws {
        for _ in 0..<100 where recovery.isConfiguring { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(recovery.isConfiguring)
    }
    private func ready(_ queue: MobileFileUploadQueue) async throws {
        for _ in 0..<100 where queue.isConfiguring { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(queue.isConfiguring)
    }

    private struct Fixture: Sendable {
        let root: URL
        let profile: NasProfile
        let repository: DsmFileRepository
        let network: MobileShareSyntheticTransport
        var accounts: MobileExtensionAccountStore { .init(rootURL: root.appendingPathComponent("Accounts")) }
        var transfers: MobileShareTransferStore { .init(rootURL: root.appendingPathComponent("ShareTransfers")) }
        var file: URL { root.appendingPathComponent("Sample.txt") }

        init(mode: String = "success") throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("MobileShare-\(UUID().uuidString)")
            try MobileExtensionStorage.prepareDirectory(root)
            profile = try NasProfile(displayName: "Synthetic", host: "share-ui.invalid", port: 5001, usernameHint: "synthetic")
            network = MobileShareSyntheticTransport(root: root, mode: mode)
            repository = try DsmFileRepository(profile: profile, capabilities: MobileShareDebugEnvironment.capabilities,
                session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: network)
            _ = try accounts.activate(accounts.reserve(profile: profile, connection: profile, capabilities: MobileShareDebugEnvironment.capabilities))
            try Data().write(to: file)
        }
        @MainActor func model(loadInput: (@MainActor () async throws -> [URL])? = nil, cleanupInput: @escaping @MainActor () -> Void = {}) -> MobileShareComposerModel {
            .init(accounts: accounts, sessions: ShareUnusedSessions(), transfers: transfers,
                loadInput: loadInput ?? { [file] in [file] }, cleanupInput: cleanupInput, makeRepository: { [repository] _ in repository })
        }
        @MainActor func recovery() -> MobileShareTransferRecovery {
            let model = MobileShareTransferRecovery(store: transfers)
            model.configure(profile: profile, repository: repository)
            return model
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor ShareUnusedSessions: SessionSecureStoring {
    func save(_ session: AuthSession, for profileID: UUID) async throws {}
    func load(for profileID: UUID) async throws -> AuthSession? { nil }
    func remove(for profileID: UUID) async throws {}
}
