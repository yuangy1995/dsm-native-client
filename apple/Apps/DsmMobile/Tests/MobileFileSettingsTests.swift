import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileFileSettingsTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []; try await super.tearDown() }

    func test常规保存成功后可再次编辑且通知只属于原账号() async throws {
        let service = FileSettingsFixture(), model = try await make(service)
        var refreshes = 0; model.onChanged = { _ in refreshes += 1 }
        let first = await model.save(await service.change())
        let second = await model.save(await service.change())
        XCTAssertTrue(first); XCTAssertTrue(second); XCTAssertEqual(refreshes, 2)
        let count = await service.writeCount; XCTAssertEqual(count, 2); XCTAssertTrue(model.pending.isEmpty)
    }

    func test非管理员未知权限和其他配置身份均不能写() async throws {
        let service = FileSettingsFixture(), model = try await make(service)
        await service.setAdmin(false); await model.loadAccess()
        let denied = await model.save(await service.change()); XCTAssertFalse(denied)
        model.configure(profile: try profile(UUID()), repository: service); await model.loadAccess()
        XCTAssertFalse(model.canWrite)
        let count = await service.writeCount; XCTAssertEqual(count, 0)
    }

    func test放宽权限必须明确接受具体后果() async throws {
        let service = FileSettingsFixture(), model = try await make(service)
        let old = try await service.loadFileStationSettings(); var new = old
        new.sharing = .everyone; new.fileRequests = .selected; new.showsAccounts = true
        let change = FileStationSettingsChange.general(baseline: old, updated: new)
        XCTAssertEqual(MobileFileSettingsModel.risks(change).count, 3)
        let first = await model.save(change); XCTAssertFalse(first)
        let second = await model.save(change, acceptedRisk: true); XCTAssertTrue(second)
        let count = await service.writeCount; XCTAssertEqual(count, 1)
        XCTAssertTrue(MobileFileSettingsModel.risks(.general(baseline: new, updated: old)).isEmpty)
    }

    func test未知结果只读恢复且不重发原设置() async throws {
        let service = FileSettingsFixture(), model = try await make(service)
        await service.setUnknown(true)
        let change = await service.change()
        let saved = await model.save(change); XCTAssertFalse(saved); XCTAssertTrue(model.isBlocked("general"))
        _ = await model.save(change)
        let unresolved = await model.refresh("general"); XCTAssertFalse(unresolved)
        await service.setUnknown(false)
        let resolved = await model.refresh("general"); XCTAssertTrue(resolved); XCTAssertFalse(model.isBlocked("general"))
        let writes = await service.writeCount, reads = await service.reviewCount
        XCTAssertEqual(writes, 1); XCTAssertEqual(reads, 2)
    }

    func test重启和同账号重连保留未知目标但不复用旧仓库回执() async throws {
        let service = FileSettingsFixture(), root = newRoot(), model = try await make(service, root: root)
        await service.setUnknown(true); _ = await model.save(await service.change())
        let restored = try await make(service, root: root)
        XCTAssertTrue(restored.isBlocked("general")); XCTAssertFalse(restored.canReview("general"))
        _ = await restored.save(await service.change()); _ = await restored.refresh("general")
        let replacement = FileSettingsFixture(profileID: service.profileID)
        model.configure(profile: try profile(service.profileID), repository: replacement); await model.loadAccess()
        XCTAssertTrue(model.isBlocked("general")); XCTAssertFalse(model.canReview("general"))
        let writes = await replacement.writeCount; XCTAssertEqual(writes, 0)
        let saved = try String(contentsOf: root.appendingPathComponent("settings-v1.json"), encoding: .utf8)
        for secret in ["synthetic-account", "nas.example.invalid", "footer", "schedule", "recordsTransfers"] { XCTAssertFalse(saved.contains(secret)) }
    }

    func test读取失败和明确提交前失败保持正确目标限制() async throws {
        let service = FileSettingsFixture(), model = try await make(service)
        await service.setReject(true)
        _ = await model.save(await service.change()); XCTAssertTrue(model.pending.isEmpty)
        await service.setReject(false); await service.setUnknown(true)
        _ = await model.save(await service.change()); await service.setReviewFailure(true)
        _ = await model.refresh("general"); XCTAssertTrue(model.isBlocked("general"))
        let writes = await service.writeCount; XCTAssertEqual(writes, 1)
    }

    func test损坏和无法保存的记录都零提交且不覆盖原件() async throws {
        for corrupt in [true, false] {
            let service = FileSettingsFixture(), root = newRoot()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent(corrupt ? "settings-v1.json" : "not-directory")
            let data = Data("synthetic-invalid".utf8); try data.write(to: file)
            let model = try await make(service, root: corrupt ? root : file)
            _ = await model.save(await service.change())
            XCTAssertTrue(model.recoveryFailed); XCTAssertEqual(try Data(contentsOf: file), data)
            let count = await service.writeCount; XCTAssertEqual(count, 0)
        }
    }

    func test重复点击和账号切换不影响新页面() async throws {
        let service = FileSettingsFixture(), next = FileSettingsFixture(), model = try await make(service)
        await service.setWaiting(true)
        let change = await service.change()
        let operation = Task { await model.save(change) }
        for _ in 0..<100 { if await service.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        let started = await service.started; XCTAssertTrue(started)
        _ = await model.save(change)
        model.configure(profile: try profile(next.profileID), repository: next); await model.loadAccess()
        await service.release()
        let result = await operation.value; XCTAssertFalse(result); XCTAssertNil(model.feedback); XCTAssertFalse(model.busy)
        let count = await service.writeCount; XCTAssertEqual(count, 1)
        XCTAssertTrue(model.pending.isEmpty)
    }

    func test迟到读取不带入新账号且同UUID不同账号隔离记录() async throws {
        let service = FileSettingsFixture(), model = try await make(service)
        await service.setUnknown(true); _ = await model.save(await service.change())
        await service.setWaitingRead(true)
        let read = Task { try await model.read { try await $0.loadFileStationSharingTheme() } }
        for _ in 0..<100 { if await service.started { break }; try await Task.sleep(for: .milliseconds(5)) }
        model.configure(profile: try profile(service.profileID, account: "other-account"), repository: service)
        await service.release()
        do { _ = try await read.value; XCTFail("旧账号读取不得返回新页面") } catch is CancellationError { } catch { XCTFail("错误类别不符") }
        XCTAssertTrue(model.pending.isEmpty)
        model.configure(profile: try profile(service.profileID), repository: service)
        XCTAssertTrue(model.isBlocked("general"))
    }

    func test图片上传异常保留摘要重启不重发且不同图片独立() async throws {
        let service = FileSettingsFixture(), root = newRoot(), model = try await make(service, root: root)
        let data = Data("synthetic-image".utf8)
        await service.setUploadFailure(true)
        let image = await model.upload(data: data, filename: "Sample.png", kind: .logo)
        XCTAssertNil(image); XCTAssertTrue(model.isBlocked(MobileFileSettingsModel.uploadTarget(data: data, kind: .logo)))
        let restored = try await make(service, root: root)
        _ = await restored.upload(data: data, filename: "Renamed.png", kind: .logo)
        await service.setUploadFailure(false)
        let different = await restored.upload(data: Data("different".utf8), filename: "Another.png", kind: .logo)
        XCTAssertNotNil(different)
        let count = await service.uploadCount; XCTAssertEqual(count, 2)
        let saved = try String(contentsOf: root.appendingPathComponent("settings-v1.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains("synthetic-image")); XCTAssertFalse(saved.contains("Sample.png"))
    }

    func test按钮延后执行时拒绝同UUID新账号的旧草稿() async throws {
        let service = FileSettingsFixture(), model = try await make(service)
        let token = model.activation, change = await service.change()
        model.configure(profile: try profile(service.profileID, account: "other-account"), repository: service)
        await model.loadAccess()
        let saved = await model.save(change, expectedActivation: token)
        XCTAssertFalse(saved)
        let count = await service.writeCount; XCTAssertEqual(count, 0)
    }

    func test每周时间表按星期日至周六且单小时每日整周互不串改() {
        let initial = String(repeating: "0", count: 168)
        let sunday = MobileFileScheduleEditor.paint(initial, day: 0, hour: 23, code: 49, perAccount: false)
        XCTAssertEqual(Array(sunday.utf8)[23], 49); XCTAssertEqual(sunday.filter { $0 == "1" }.count, 1)
        let saturday = MobileFileScheduleEditor.paint(sunday, day: 6, hour: nil, code: 50, perAccount: true)
        XCTAssertEqual(String(saturday.suffix(24)), String(repeating: "2", count: 24)); XCTAssertEqual(Array(saturday.utf8)[23], 49)
        XCTAssertEqual(MobileFileScheduleEditor.paint(initial, day: 7, hour: 0, code: 49, perAccount: true), initial)
        XCTAssertEqual(MobileFileScheduleEditor.paint(initial, day: 0, hour: 0, code: 50, perAccount: false), initial)
        XCTAssertEqual(MobileFileScheduleEditor.paint("bad", day: 0, hour: nil, code: 49, perAccount: true), "bad")
    }

    func test账号来源目标独立且限速边界保留继承状态() async throws {
        let id = UUID(), member = FileStationPolicyAccountID(kind: .user, value: 1001)
        let local = FileStationMountAccount(profileID: id, id: member, name: "Sample", enabled: false, canModify: true)
        let domain = FileStationMountAccount(profileID: id, id: member, name: "Sample", enabled: false, canModify: true, source: .domain("synthetic-domain"))
        XCTAssertNotEqual(MobileFileSettingsModel.target(.mountAccount(baseline: local, enabled: true)), MobileFileSettingsModel.target(.mountAccount(baseline: domain, enabled: true)))
        var row = FileStationBandwidthEntry(profileID: id, name: "Sample", ownerType: .localUser, policy: .notConfigured, schedule: "", uploadLimit: 0, downloadLimit: 10, alternateUploadLimit: 0, alternateDownloadLimit: 999_999_999)
        XCTAssertTrue(MobileFileBandwidthEditor.validRates(row)); XCTAssertEqual(row.policy, .notConfigured)
        row.uploadLimit = 9; XCTAssertFalse(MobileFileBandwidthEditor.validRates(row))
        row.uploadLimit = -1; XCTAssertFalse(MobileFileBandwidthEditor.validRates(row))
    }

    private func newRoot() -> URL { let root = FileManager.default.temporaryDirectory.appendingPathComponent("FileSettingsTests-\(UUID())"); roots.append(root); return root }
    private func make(_ service: FileSettingsFixture, root: URL? = nil) async throws -> MobileFileSettingsModel {
        let model = MobileFileSettingsModel(rootURL: root ?? newRoot()); model.configure(profile: try profile(service.profileID), repository: service); await model.loadAccess(); return model
    }
    private func profile(_ id: UUID, account: String = "synthetic-account") throws -> NasProfile { try .init(id: id, displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: account) }
}

private actor FileSettingsFixture: MobileFileSettingsServing {
    nonisolated let profileID: UUID
    private var admin = true, unknown = false, reject = false, reviewFailure = false, uploadFailure = false, waiting = false, waitingRead = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var current: FileStationSettings
    private(set) var started = false
    private(set) var writeCount = 0, reviewCount = 0, uploadCount = 0
    init(profileID: UUID = UUID()) {
        self.profileID = profileID
        current = .init(profileID: profileID, recordsTransfers: false, usesDefaultPermissions: false, showsAccounts: false, sharing: .administrators,
            fileRequests: .administrators, remoteMounts: .administrators, isoMounts: .administrators, sharingAccounts: [], requestAccounts: [], defaultLinkLimit: 10, bandwidth: .disabled, schedule: "")
    }
    func setAdmin(_ value: Bool) { admin = value }
    func setUnknown(_ value: Bool) { unknown = value }
    func setReject(_ value: Bool) { reject = value }
    func setReviewFailure(_ value: Bool) { reviewFailure = value }
    func setUploadFailure(_ value: Bool) { uploadFailure = value }
    func setWaiting(_ value: Bool) { waiting = value; started = false }
    func setWaitingRead(_ value: Bool) { waitingRead = value; started = false }
    func release() { continuation?.resume(); continuation = nil }
    func change() -> FileStationSettingsChange { var next = current; next.recordsTransfers.toggle(); return .general(baseline: current, updated: next) }
    func listShares(offset: Int, limit: Int) async throws -> FilePage { throw CancellationError() }
    func listFolder(path: String, offset: Int, limit: Int) async throws -> FilePage { throw CancellationError() }
    func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess { .init(isAdministrator: admin, writesEnabled: true) }
    func loadFileStationSettings() async throws -> FileStationSettings { current }
    func loadFileStationMountAccess() async throws -> FileStationMountAccessScope { .administrators }
    func loadFileStationMountDirectories() async throws -> FileStationMountDirectories { .init(items: [], hasUnavailableSources: false) }
    func listFileStationMountAccounts(source: FileStationMountAccountSource, kind: FileStationPrincipal.Kind, query: String, offset: Int, limit: Int) async throws -> FileStationMountAccountPage { .init(items: [], total: 0, nextOffset: 0) }
    func listFileStationPolicyAccounts(kind: FileStationPrincipal.Kind, query: String, offset: Int, limit: Int) async throws -> FileStationPolicyAccountPage { .init(items: [], total: 0, nextOffset: 0) }
    func listFileStationBandwidth(ownerType: FileStationBandwidthEntry.OwnerType, offset: Int, limit: Int) async throws -> FileStationBandwidthPage { .init(items: [], total: 0, nextOffset: 0) }
    func loadFileStationSharingTheme() async throws -> FileStationSharingTheme {
        if waitingRead { started = true; await withCheckedContinuation { continuation = $0 } }
        return .init(profileID: profileID, customLogo: false, customBackground: false, logoPosition: .topLeft, backgroundPosition: .fill, backgroundColor: "#FFFFFF", footer: "", footerUsesHTML: false)
    }
    func changeFileStationSettings(_ change: FileStationSettingsChange, confirmed: Bool) async throws -> MutationResult {
        guard !reject else { throw AppError(category: .conflict, isRetryable: true, safeUserMessage: "synthetic-conflict") }
        writeCount += 1; started = true
        if waiting { await withCheckedContinuation { continuation = $0 } }
        if case .general(_, let value) = change, !unknown { current = value }
        return try result()
    }
    func reviewFileStationSettings(_ change: FileStationSettingsChange) async throws -> MutationResult { reviewCount += 1; if reviewFailure { throw URLError(.notConnectedToInternet) }; return try result() }
    private func result() throws -> MutationResult { try .init(status: unknown ? .submittedButUnverified : .confirmedSuccess, operation: "fileStationSettings", submitted: true, requiresRefresh: unknown, counts: .init(succeeded: unknown ? 0 : 1, failed: 0, unknown: unknown ? 1 : 0)) }
    func listFileStationThemeImages(kind: FileStationThemeImage.Kind) async throws -> [FileStationThemeImage] { [] }
    func loadFileStationThemeImage(_ image: FileStationThemeImage) async throws -> Data { Data() }
    func uploadFileStationThemeImage(data: Data, filename: String, kind: FileStationThemeImage.Kind, confirmed: Bool) async throws -> FileStationThemeImage {
        uploadCount += 1; if uploadFailure { throw URLError(.timedOut) }
        return .init(kind: kind, source: .history, path: "/synthetic/history.png", name: filename, historyIndex: 0)
    }
}
