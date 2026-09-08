import DsmCore
import DsmLocalization
import DsmNetwork
import XCTest
@testable import DsmMacExecutable

@MainActor
final class WorkspaceModuleAccessTests: XCTestCase {
    private let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: [
        DsmAPIName.fileStationList, DsmAPIName.chatChannel, DsmAPIName.chatUser,
        DsmAPIName.downloadStationTask, DsmAPIName.dockerContainer,
        DsmAPIName.virtualizationGuest, DsmAPIName.coreSystem
    ].map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1,
                              requestFormat: .form, selectedVersion: 1)) }))

    func test普通用户仅显示明确授权且管理设置始终关闭() {
        let result = WorkspaceModuleAccessReader.resolve(
            DsmDesktopAppPrivileges(applications: [.files: true, .chat: true, .downloads: false,
                                                  .nasSettings: true, .containers: true], isAdministrator: false),
            capabilities: capabilities)
        XCTAssertEqual(Set(result.modules.filter { $0.value.isVisible }.keys), [.files, .photos, .chat])
        XCTAssertEqual(result.modules[.nasSettings], .denied)
        XCTAssertEqual(result.modules[.containers], .denied)
        XCTAssertEqual(result.modules[.virtualMachines], .denied)
    }

    func test管理员管理入口缺少应用键仍显示但不绕过明确拒绝和VMM授权() {
        let role = DsmDesktopAppPrivileges(applications: [.files: true, .downloads: false], isAdministrator: true)
        let result = WorkspaceModuleAccessReader.resolve(role, capabilities: capabilities)
        XCTAssertEqual(result.modules[.containers], .available)
        XCTAssertEqual(result.modules[.nasSettings], .available)
        XCTAssertEqual(result.modules[.downloads], .denied)
        XCTAssertEqual(result.modules[.virtualMachines], .denied)
        let denied = WorkspaceModuleAccessReader.resolve(
            DsmDesktopAppPrivileges(applications: [.containers: false, .nasSettings: false, .virtualMachines: true],
                                    isAdministrator: true), capabilities: capabilities)
        XCTAssertEqual(denied.modules[.containers], .denied)
        XCTAssertEqual(denied.modules[.nasSettings], .denied)
        XCTAssertEqual(denied.modules[.virtualMachines], .available)
    }

    func test接口能力缺失不显示且不按安装来源或机型判断() {
        let result = WorkspaceModuleAccessReader.resolve(
            DsmDesktopAppPrivileges(applications: Dictionary(uniqueKeysWithValues: DsmDesktopApplication.allCases.map { ($0, true) }),
                                    isAdministrator: true), capabilities: CapabilitySet([:]))
        XCTAssertFalse(result.modules.values.contains(where: \.isVisible))
    }

    func test权限未确认时不提前显示或启动任何模块() throws {
        let profile = try profile()
        defer { cleanPreferences(profile.id) }
        let model = try makeModel(profile: profile) { WorkspaceModuleAccessSnapshot(modules: [.files: .available]) }
        for module in WorkspaceModule.allCases { XCTAssertFalse(model.isModuleVisible(module)) }
        XCTAssertFalse(model.chat.isModuleEnabled)
        XCTAssertFalse(model.nasSettings.isModuleEnabled)
    }

    func test单次摘要读取不触发任何组件业务请求且空授权不探测文件() async throws {
        let profile = try profile()
        let transport = AccessTransport()
        let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: transport),
            capabilities: capabilities, readPrivileges: { DsmDesktopAppPrivileges(applications: [:], isAdministrator: false) })
        let snapshot = await reader.read()
        XCTAssertFalse(snapshot.lookupFailed)
        XCTAssertFalse(snapshot.modules.values.contains(where: \.isVisible))
        let calls = await transport.requests
        XCTAssertTrue(calls.isEmpty, "空权限表已是有效结果，不能用业务调用试探")
    }

    func test摘要失败只核实文件而不启动其他套件() async throws {
        let profile = try profile()
        let transport = AccessTransport()
        let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: transport),
            capabilities: capabilities, readPrivileges: { throw URLError(.cannotConnectToHost) })
        let snapshot = await reader.read()
        XCTAssertTrue(snapshot.lookupFailed)
        XCTAssertEqual(snapshot.modules, [.files: .available])
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(String(decoding: try XCTUnwrap(calls[0].httpBody), as: UTF8.self).contains("method=list_share"))
    }

    func test文件认证失败保留原始错误且诊断不包含私密文本() async throws {
        let profile = try profile()
        defer { cleanPreferences(profile.id) }
        let issue = AppError(category: .authenticationRequired, isRetryable: false,
                             safeUserMessage: "private-response", dsmCode: 119, httpStatus: 200)
        let model = try makeModel(profile: profile) {
            WorkspaceModuleAccessSnapshot(modules: [.files: .authenticationRequired(issue)], lookupFailed: true)
        }
        await model.startEnabledModules()
        XCTAssertTrue(model.requiresReauthentication)
        XCTAssertTrue(model.statusIsError)
        XCTAssertTrue(model.moduleAccessLookupFailed)
        let message = try XCTUnwrap(model.statusMessage)
        XCTAssertEqual(message, L10n.string("connection.session.rejected"))
        for secret in [profile.displayName, profile.host, issue.safeUserMessage, issue.requestID.uuidString] {
            XCTAssertFalse(message.contains(secret))
        }
        XCTAssertFalse(model.isChatModuleEnabled)
    }

    func test权限撤回关闭后台模型并禁止导航且不改用户偏好() async throws {
        let profile = try profile()
        defer { cleanPreferences(profile.id) }
        let state = AccessSnapshots()
        let model = try makeModel(profile: profile) { await state.read() }
        model.isNasSettingsModuleEnabled = true
        model.isChatModuleEnabled = true
        model.isContainerManagerModuleEnabled = true
        await model.refreshModuleAccess()
        XCTAssertTrue(model.isChatModuleEnabled)
        XCTAssertTrue(model.isContainerManagerModuleEnabled)
        await state.set([.files: .available])
        await model.refreshModuleAccess()
        XCTAssertFalse(model.chat.isModuleEnabled)
        XCTAssertFalse(model.nasSettings.isModuleEnabled)
        XCTAssertFalse(model.photoLibrary.isModuleEnabled)
        for destination in [WorkspaceSection.chat, .nasSettings, .downloadStation,
                            .containerManager(.images), .virtualMachineManager(.networks)] {
            XCTAssertFalse(model.canActivate(destination))
            model.section = destination
            await model.activate(destination)
            XCTAssertEqual(model.section, .settings)
        }
        await state.set(Dictionary(uniqueKeysWithValues: WorkspaceModule.allCases.map { ($0, .available) }))
        await model.refreshModuleAccess()
        XCTAssertTrue(model.isChatModuleEnabled)
        XCTAssertTrue(model.isNasSettingsModuleEnabled)
        XCTAssertTrue(model.isContainerManagerModuleEnabled)
        model.isDownloadStationModuleEnabled = false
        await model.refreshModuleAccess()
        XCTAssertFalse(model.isDownloadStationModuleEnabled)
    }

    func test多NAS权限独立且每次刷新只读取一次摘要() async throws {
        let firstProfile = try profile(), secondProfile = try profile()
        defer { cleanPreferences(firstProfile.id); cleanPreferences(secondProfile.id) }
        let state = AccessSnapshots()
        let first = try makeModel(profile: firstProfile) { WorkspaceModuleAccessSnapshot(modules: [:]) }
        let second = try makeModel(profile: secondProfile) { await state.read() }
        await first.refreshModuleAccess()
        await second.refreshModuleAccess()
        await second.refreshModuleAccess()
        let count = await state.count
        XCTAssertEqual(count, 2)
        XCTAssertFalse(first.isFileModuleEnabled)
        XCTAssertTrue(second.isFileModuleEnabled)
        XCTAssertFalse(second.needsModuleAccessCheck)
    }

    func test隐藏套件即使收到旧页面加载和操作回调也不发请求() async throws {
        let profile = try profile()
        defer { cleanPreferences(profile.id) }
        let transport = AccessTransport()
        let services = try DsmServiceManagementRepository(profile: profile, capabilities: capabilities,
            session: session(), transport: transport)
        let model = WorkspaceModel(profile: profile, repository: try fileRepository(profile: profile, transport: transport),
            serviceManagementRepository: services, transferNotifier: NoopTransferNotifier(), preparePreviewCache: {},
            moduleAccessLoader: { WorkspaceModuleAccessSnapshot(modules: [.files: .available]) })
        await model.refreshModuleAccess()
        for module in ServiceManagementModel.Module.allCases { await model.serviceManagement.activate(module, force: true) }
        model.serviceManagement.containerSelection = ["synthetic"]
        let deletion = await model.serviceManagement.deleteContainers()
        let console = await model.serviceManagement.openVirtualMachineConsole(id: "synthetic")
        XCTAssertFalse(deletion)
        XCTAssertNil(console)
        let calls = await transport.requests
        XCTAssertTrue(calls.isEmpty)
    }

    func test首次NAS只默认启用已授权文件照片并保存默认选择() async throws {
        for allowed in [[WorkspaceModule.files, .photos, .virtualMachines], [.files, .virtualMachines], [.virtualMachines]] {
            let profile = try profile()
            defer { cleanPreferences(profile.id) }
            let values = Dictionary(uniqueKeysWithValues: allowed.map { ($0, WorkspaceModuleAccess.available) })
            let model = try makeModel(profile: profile) { WorkspaceModuleAccessSnapshot(modules: values) }
            await model.refreshModuleAccess()
            XCTAssertEqual(model.isFileModuleEnabled, allowed.contains(.files))
            XCTAssertEqual(model.isPhotosModuleEnabled, allowed.contains(.photos))
            XCTAssertFalse(model.isVirtualMachineManagerModuleEnabled)
            XCTAssertFalse(model.isChatModuleEnabled)
            XCTAssertFalse(model.isContainerManagerModuleEnabled)
            let reopened = try makeModel(profile: profile) { WorkspaceModuleAccessSnapshot(modules: values) }
            await reopened.refreshModuleAccess()
            XCTAssertFalse(reopened.isVirtualMachineManagerModuleEnabled, "第二次登录不能变回旧版默认开启")
        }
    }

    func test用户手动选择跨工作区重建保留且权限恢复沿用选择() async throws {
        let profile = try profile()
        defer { cleanPreferences(profile.id) }
        let state = AccessSnapshots()
        let model = try makeModel(profile: profile) { await state.read() }
        await model.refreshModuleAccess()
        model.isVirtualMachineManagerModuleEnabled = true
        model.isPhotosModuleEnabled = false
        let reopened = try makeModel(profile: profile) { await state.read() }
        await reopened.refreshModuleAccess()
        XCTAssertTrue(reopened.isVirtualMachineManagerModuleEnabled)
        XCTAssertFalse(reopened.isPhotosModuleEnabled)
        await state.set([.files: .available])
        await reopened.refreshModuleAccess()
        XCTAssertFalse(reopened.isVirtualMachineManagerModuleEnabled)
        await state.set([.files: .available, .photos: .available, .virtualMachines: .available])
        await reopened.refreshModuleAccess()
        XCTAssertTrue(reopened.isVirtualMachineManagerModuleEnabled)
        XCTAssertFalse(reopened.isPhotosModuleEnabled)
    }

    func test已登录旧NAS保留显式设置和旧默认而新NAS不继承全局开关() async throws {
        let existing = try profile(), fresh = try profile()
        defer { cleanPreferences(existing.id); cleanPreferences(fresh.id) }
        let global = "LanStash_Module_Chat"
        let previous = UserDefaults.standard.object(forKey: global)
        defer {
            if let previous { UserDefaults.standard.set(previous, forKey: global) }
            else { UserDefaults.standard.removeObject(forKey: global) }
        }
        UserDefaults.standard.set(true, forKey: global)
        UserDefaults.standard.set(false, forKey: "LanStash_Module_NASSettings_\(existing.id.uuidString)")
        UserDefaults.standard.set(false, forKey: "LanStash_Module_VirtualMachineManager_\(existing.id.uuidString)")
        let state = AccessSnapshots()
        let old = try makeModel(profile: existing) { await state.read() }
        let new = try makeModel(profile: fresh) { await state.read() }
        await old.refreshModuleAccess()
        await new.refreshModuleAccess()
        XCTAssertTrue(old.isChatModuleEnabled)
        XCTAssertTrue(old.isContainerManagerModuleEnabled, "旧版未改动过的默认开启也应保留")
        XCTAssertFalse(old.isVirtualMachineManagerModuleEnabled)
        XCTAssertFalse(old.isNasSettingsModuleEnabled)
        XCTAssertFalse(new.isChatModuleEnabled, "旧全局偏好不能覆盖首次 NAS 的新默认")
        XCTAssertFalse(new.isContainerManagerModuleEnabled)
    }

    func test关闭文件后仍可进入传输中心且不会发起文件读取() async throws {
        let profile = try profile()
        defer { cleanPreferences(profile.id) }
        let transport = AccessTransport()
        let model = WorkspaceModel(profile: profile, repository: try fileRepository(profile: profile, transport: transport),
                                   transferNotifier: NoopTransferNotifier(), preparePreviewCache: {})
        model.isFileModuleEnabled = false
        XCTAssertTrue(model.canActivate(.transfers))
        XCTAssertFalse(WorkspaceSection.transfers.belongsToFileModule)
        model.section = .transfers
        await model.activate(.transfers)
        XCTAssertEqual(model.section, .transfers)
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    private func profile() throws -> NasProfile {
        try NasProfile(displayName: "Synthetic NAS", host: "example.invalid", port: 5001)
    }
    private func session() -> AuthSession {
        AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false)
    }
    private func fileRepository(profile: NasProfile, transport: AccessTransport) throws -> DsmFileRepository {
        try DsmFileRepository(profile: profile, capabilities: capabilities, session: session(), transport: transport)
    }
    private func makeModel(profile: NasProfile,
                           loader: @escaping @Sendable () async -> WorkspaceModuleAccessSnapshot) throws -> WorkspaceModel {
        let files = try fileRepository(profile: profile, transport: AccessTransport())
        return WorkspaceModel(profile: profile, repository: files, transferNotifier: NoopTransferNotifier(),
                              preparePreviewCache: {}, moduleAccessLoader: loader)
    }
    private func cleanPreferences(_ profileID: UUID) {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasSuffix(profileID.uuidString) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private actor AccessSnapshots {
    private var values = Dictionary(uniqueKeysWithValues: WorkspaceModule.allCases.map { ($0, WorkspaceModuleAccess.available) })
    private(set) var count = 0
    func set(_ values: [WorkspaceModule: WorkspaceModuleAccess]) { self.values = values }
    func read() -> WorkspaceModuleAccessSnapshot { count += 1; return WorkspaceModuleAccessSnapshot(modules: values) }
}

private actor AccessTransport: DsmBinaryHTTPTransport {
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        return DsmHTTPResponse(data: Data(#"{"success":true,"data":{"shares":[],"files":[],"total":0}}"#.utf8), statusCode: 200)
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        requests.append(request)
        throw URLError(.unsupportedURL)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        requests.append(request)
        throw URLError(.unsupportedURL)
    }
}
