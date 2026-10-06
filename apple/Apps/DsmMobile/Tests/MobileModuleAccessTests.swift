import DsmCore
import DsmNetwork
import Foundation
@testable import DsmMobile
import XCTest

private actor ModuleAccessProbe {
    var privileges = DsmDesktopAppPrivileges(applications: [.downloads: true, .chat: true], isAdministrator: false)
    var failure: AppErrorCategory?
    var photoFailure: AppErrorCategory?
    var reads = 0
    var photoReads = 0
    var pending: CheckedContinuation<Void, Never>?
    var suspends = false

    func set(_ applications: [DsmDesktopApplication: Bool]) { privileges = .init(applications: applications, isAdministrator: false) }
    func fail(_ value: AppErrorCategory?) { failure = value }
    func failPhotos(_ value: AppErrorCategory?) { photoFailure = value }
    func suspend() { suspends = true }
    func release() { pending?.resume(); pending = nil; suspends = false }
    func read() async throws -> DsmDesktopAppPrivileges {
        reads += 1
        if suspends { await withCheckedContinuation { pending = $0 } }
        if let failure { throw AppError(category: failure, isRetryable: false, safeUserMessage: "") }
        return privileges
    }
    func photos() throws {
        photoReads += 1
        if let photoFailure { throw AppError(category: photoFailure, isRetryable: false, safeUserMessage: "") }
    }
}

final class MobileModuleAccessTests: XCTestCase {
    static let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: [
        DsmAPIName.desktopInitData, DsmAPIName.fileStationList, DsmAPIName.downloadStationTask,
        DsmAPIName.chatChannel, DsmAPIName.chatUser, DsmAPIName.dockerContainer,
        DsmAPIName.virtualizationAPIGuest, DsmAPIName.coreSystem,
        "SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.TeamSpace"
    ].map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1,
                               requestFormat: .form, selectedVersion: 1, verified: false)) }))

    private func reader(_ probe: ModuleAccessProbe) -> MobileModuleAccessReader {
        .init(capabilities: Self.capabilities, readPrivileges: { try await probe.read() }, readPhotoAccess: { try await probe.photos() })
    }

    func test接口存在不替代当前账号授权() {
        XCTAssertEqual(MobileModuleAccessReader.resolve(.init(applications: [.downloads: true, .chat: false], isAdministrator: false), capabilities: Self.capabilities), [.downloads])
        XCTAssertTrue(MobileModuleAccessReader.resolve(.init(applications: [:], isAdministrator: false), capabilities: Self.capabilities).isEmpty)
        XCTAssertTrue(MobileModuleAccessReader.resolve(.init(applications: [.downloads: true], isAdministrator: false), capabilities: .init([:])).isEmpty)
    }

    func test管理员入口允许缺失键但不能覆盖明确拒绝() {
        XCTAssertEqual(MobileModuleAccessReader.resolve(.init(applications: [:], isAdministrator: true), capabilities: Self.capabilities), [.containers, .nasSettings])
        XCTAssertEqual(MobileModuleAccessReader.resolve(.init(applications: [.containers: false, .nasSettings: false, .virtualMachines: true], isAdministrator: true), capabilities: Self.capabilities), [.virtualMachines])
    }

    func test照片采用独立授权且拒绝不误报整个权限加载失败() async {
        let probe = ModuleAccessProbe()
        await probe.set([.files: false])
        let allowed = await reader(probe).read()
        XCTAssertEqual(allowed.allowed, [.photos])
        await probe.failPhotos(.permissionDenied)
        let denied = await reader(probe).read()
        XCTAssertTrue(denied.allowed.isEmpty)
        XCTAssertFalse(denied.lookupFailed)
    }

    func test文件授权不能覆盖照片拒绝且缺少照片能力不发读取() async {
        let probe = ModuleAccessProbe()
        await probe.set([.files: true]); await probe.failPhotos(.permissionDenied)
        let denied = await reader(probe).read()
        XCTAssertFalse(denied.allowed.contains(.photos)); XCTAssertFalse(denied.lookupFailed)
        for missing in ["SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.TeamSpace"] {
            let fresh = ModuleAccessProbe()
            await fresh.set([.files: true])
            let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: Self.capabilities.all
                .filter { $0.name != missing }.map { ($0.name, $0) }))
            let result = await MobileModuleAccessReader(capabilities: capabilities,
                readPrivileges: { try await fresh.read() }, readPhotoAccess: { try await fresh.photos() }).read()
            XCTAssertFalse(result.allowed.contains(.photos))
            let reads = await fresh.photoReads; XCTAssertEqual(reads, 0)
        }
    }

    @MainActor
    func test恢复登录文件权限或能力受限时必须单独读取照片() async throws {
        for category in [nil, .permissionDenied, .apiUnavailable, .versionUnsupported] as [AppErrorCategory?] {
            let probe = ModuleAccessProbe(); await probe.fail(category)
            try await MobileAppModel.validateRestoredSession(readFileAccess: { _ = try await probe.read() },
                readPhotoAccess: { try await probe.photos() })
            let fileReads = await probe.reads, photoReads = await probe.photoReads
            XCTAssertEqual(fileReads, 1); XCTAssertEqual(photoReads, category == nil ? 0 : 1)
        }
    }

    @MainActor
    func test恢复登录安全或网络错误不改用照片请求() async {
        for category in [AppErrorCategory.authenticationRequired, .tlsUntrusted, .tlsCertificateChanged, .cancelled, .networkUnavailable] {
            let probe = ModuleAccessProbe(); await probe.fail(category)
            do {
                try await MobileAppModel.validateRestoredSession(readFileAccess: { _ = try await probe.read() },
                    readPhotoAccess: { try await probe.photos() })
                XCTFail("不能忽略原连接错误")
            } catch { XCTAssertEqual((error as? AppError)?.category, category) }
            let photoReads = await probe.photoReads; XCTAssertEqual(photoReads, 0)
        }
        let probe = ModuleAccessProbe()
        let issue = DsmCertificateTrustError.changed(.init(host: "example.invalid", subjectSummary: "Synthetic",
            sha256Fingerprint: String(repeating: "0", count: 64), canBePinned: true))
        do {
            try await MobileAppModel.validateRestoredSession(readFileAccess: { throw issue }, readPhotoAccess: { try await probe.photos() })
            XCTFail("证书变化不能恢复登录")
        } catch { XCTAssertTrue(error is DsmCertificateTrustError) }
        let photoReads = await probe.photoReads; XCTAssertEqual(photoReads, 0)
    }

    @MainActor
    func test恢复登录照片拒绝或会话失效不能算作成功() async {
        for category in [AppErrorCategory.permissionDenied, .authenticationRequired, .apiUnavailable] {
            let probe = ModuleAccessProbe(); await probe.fail(.permissionDenied); await probe.failPhotos(category)
            do {
                try await MobileAppModel.validateRestoredSession(readFileAccess: { _ = try await probe.read() },
                    readPhotoAccess: { try await probe.photos() })
                XCTFail("Photos 没有确认会话时不能恢复工作区")
            } catch { XCTAssertEqual((error as? AppError)?.category, category) }
            let photoReads = await probe.photoReads; XCTAssertEqual(photoReads, 1)
        }
    }

    @MainActor
    func test只有照片权限时入口可开启撤权后退出且保留选择() async throws {
        try await withModel { model in
            let probe = ModuleAccessProbe(); await probe.set([.files: false])
            model.moduleAccessReader = reader(probe)
            await model.refreshModuleAccess()
            XCTAssertEqual(model.optionalModulesAvailableForPreference(), [.photos])
            model.setModule(.photos, isVisible: true); model.selectModule(.photos)
            XCTAssertEqual(model.selectedModule, .photos)
            XCTAssertTrue(model.visibleTopLevelDestinations.contains(.photos))
            await probe.set([.files: true]); await probe.failPhotos(.permissionDenied)
            await model.refreshModuleAccess()
            XCTAssertEqual(model.selectedModule, .settings)
            XCTAssertFalse(model.visibleTopLevelDestinations.contains(.photos))
            XCTAssertTrue(model.settingsStore.isVisible(.photos))
            await probe.failPhotos(nil); await model.refreshModuleAccess()
            XCTAssertTrue(model.visibleTopLevelDestinations.contains(.photos))
        }
    }

    func test摘要网络失败保留独立照片授权并显示刷新恢复() async {
        let probe = ModuleAccessProbe()
        await probe.fail(.networkUnavailable)
        let result = await reader(probe).read()
        XCTAssertEqual(result.allowed, [.photos])
        XCTAssertTrue(result.lookupFailed)
    }

    func test证书及会话错误不追加照片请求() async {
        for category in [AppErrorCategory.tlsCertificateChanged, .tlsUntrusted, .authenticationRequired, .cancelled] {
            let probe = ModuleAccessProbe()
            await probe.fail(category)
            let result = await reader(probe).read()
            XCTAssertTrue(result.allowed.isEmpty)
            XCTAssertTrue(result.lookupFailed)
            let photoReads = await probe.photoReads
            XCTAssertEqual(photoReads, 0)
        }
    }

    @MainActor
    private func withModel(_ body: (MobileAppModel) async throws -> Void) async throws {
        let suite = "MobileModuleAccessTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MobileAppModel(defaults: defaults)
        model.activeProfile = try NasProfile(displayName: "Sample", host: "sample.invalid", port: 5001, usernameHint: "first")
        model.isConnected = true
        model.capabilities = Self.capabilities
        try await body(model)
        model.resetModuleAccess()
        model.cancelSelectedModuleLoad()
    }

    @MainActor
    func test默认两入口授权后仍需主动开启并可恢复偏好() async throws {
        try await withModel { model in
            XCTAssertEqual(model.visibleTopLevelDestinations, [.files, .settings])
            model.setModule(.chat, isVisible: true)
            XCTAssertFalse(model.settingsStore.isVisible(.chat))
            model.moduleAccessReader = reader(ModuleAccessProbe())
            await model.refreshModuleAccess()
            XCTAssertEqual(model.optionalModulesAvailableForPreference(), [.photos, .chat, .downloads])
            XCTAssertEqual(model.visibleTopLevelDestinations, [.files, .settings])
            model.setModule(.chat, isVisible: true)
            XCTAssertEqual(model.visibleTopLevelDestinations, [.files, .chat, .settings])
            XCTAssertTrue(MobileSettingsStore(defaults: model.defaults).isVisible(.chat))
        }
    }

    @MainActor
    func test权限撤销整体替换并退出已开启模块但保留偏好() async throws {
        try await withModel { model in
            let probe = ModuleAccessProbe()
            model.moduleAccessReader = reader(probe)
            await model.refreshModuleAccess()
            model.setModule(.downloads, isVisible: true)
            model.selectModule(.downloads)
            await probe.set([:])
            await model.refreshModuleAccess()
            XCTAssertEqual(model.selectedModule, .settings)
            XCTAssertEqual(model.selectedTopLevel, .settings)
            XCTAssertFalse(model.visibleTopLevelDestinations.contains(.downloads))
            XCTAssertTrue(model.settingsStore.isVisible(.downloads))
            model.selectModule(.downloads)
            XCTAssertEqual(model.selectedModule, .settings)
            await probe.set([.downloads: true])
            await model.refreshModuleAccess()
            XCTAssertTrue(model.visibleTopLevelDestinations.contains(.downloads))
        }
    }

    @MainActor
    func test刷新失败关闭原授权并保留文件与设置入口() async throws {
        try await withModel { model in
            let probe = ModuleAccessProbe()
            model.moduleAccessReader = reader(probe)
            await model.refreshModuleAccess()
            model.setModule(.chat, isVisible: true)
            await probe.fail(.authenticationRequired)
            await model.refreshModuleAccess()
            XCTAssertTrue(model.moduleAccessLookupFailed)
            XCTAssertEqual(model.visibleTopLevelDestinations, [.files, .settings])
        }
    }

    @MainActor
    func test新配置读取不被已取消但尚未开始的旧任务抢占() async throws {
        try await withModel { model in
            let old = ModuleAccessProbe()
            let current = ModuleAccessProbe()
            await current.set([.downloads: true])
            await current.failPhotos(.permissionDenied)
            model.configureModuleAccess(reader(old))
            model.configureModuleAccess(reader(current))
            await model.moduleAccessTask?.value
            let oldReads = await old.reads
            let currentReads = await current.reads
            XCTAssertEqual(oldReads, 0)
            XCTAssertEqual(currentReads, 1)
            XCTAssertEqual(model.availableOptionalModules, [.downloads])
            XCTAssertFalse(model.isLoadingModuleAccess)
        }
    }

    @MainActor
    func test切换账号使旧权限迟到结果失效且重复刷新合并() async throws {
        try await withModel { model in
            let probe = ModuleAccessProbe()
            await probe.suspend()
            model.configureModuleAccess(reader(probe))
            while await probe.pending == nil { await Task.yield() }
            await model.refreshModuleAccess()
            let reads = await probe.reads
            XCTAssertEqual(reads, 1)
            let previousTask = model.moduleAccessTask
            model.activeProfile = try NasProfile(id: model.activeProfile!.id, displayName: "Sample", host: "sample.invalid", port: 5001, usernameHint: "second")
            await probe.release()
            await previousTask?.value
            XCTAssertFalse(model.isLoadingModuleAccess)
            XCTAssertTrue(model.availableOptionalModules.isEmpty)
            XCTAssertNil(model.moduleAccessReader)
            XCTAssertEqual(model.visibleTopLevelDestinations, [.files, .settings])
        }
    }
}
