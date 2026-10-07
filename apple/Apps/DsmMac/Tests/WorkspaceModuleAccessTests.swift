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
        XCTAssertEqual(Set(result.modules.filter { $0.value.isVisible }.keys), [.files, .chat])
        XCTAssertEqual(result.modules[.photos], .denied, "应用摘要不能代替 Photos 自身授权")
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
            capabilities: capabilities, readPrivileges: { DsmDesktopAppPrivileges(applications: [:], isAdministrator: false) },
            readPhotoAccess: { XCTFail("缺少照片能力时不能读取照片权限") })
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
            capabilities: capabilities, readPrivileges: { throw URLError(.cannotConnectToHost) },
            readPhotoAccess: { XCTFail("缺少照片能力时不能读取照片权限") })
        let snapshot = await reader.read()
        XCTAssertTrue(snapshot.lookupFailed)
        XCTAssertEqual(snapshot.modules, [.files: .available, .photos: .unavailable])
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertTrue(String(decoding: try XCTUnwrap(calls[0].httpBody), as: UTF8.self).contains("method=list_share"))
    }

    func test照片授权与文件应用授权及文件能力相互独立() async throws {
        for applications in [[DsmDesktopApplication.files: true], [.files: false], [:]] {
            for includesFiles in [true, false] {
                let profile = try profile(), transport = AccessTransport(), photos = PhotoAccessProbe()
                let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: photoCapabilities.all
                    .filter { includesFiles || $0.name != DsmAPIName.fileStationList }.map { ($0.name, $0) }))
                let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: transport),
                    capabilities: capabilities, readPrivileges: { .init(applications: applications, isAdministrator: false) },
                    readPhotoAccess: { try await photos.read() })
                let snapshot = await reader.read()
                XCTAssertEqual(snapshot.modules[.photos], .available)
                XCTAssertEqual(snapshot.modules[.files], applications[.files] == true && includesFiles ? .available : .denied)
                XCTAssertFalse(snapshot.lookupFailed)
                let photoReads = await photos.reads, fileCalls = await transport.requests
                XCTAssertEqual(photoReads, 1); XCTAssertTrue(fileCalls.isEmpty)
            }
        }
    }

    func test真实能力发现与照片授权决定入口且不依赖自动选版() async throws {
        for enabled in [true, false] {
            for filesGranted in [true, false] {
                let profile = try profile()
                defer { cleanPreferences(profile.id) }
                let transport = PhotoDiscoveryTransport(enabled: enabled)
                let client = DsmAPIClient(baseURL: try XCTUnwrap(URL(string: "https://example.invalid:5001")), transport: transport)
                let discovered = try await DsmCapabilityDiscovery(client: client).discover()
                for name in PhotoDiscoveryTransport.accessAPIs {
                    let capability = try XCTUnwrap(discovered[name])
                    XCTAssertNil(capability.selectedVersion, "Photos 按具体方法指定版本，不使用全局自动选版")
                    XCTAssertEqual(capability.requestFormat, .json)
                }
                let photos = try SynologyPhotosRepository(profile: profile, capabilities: discovered,
                    session: session(), transport: transport)
                let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: AccessTransport()),
                    capabilities: discovered,
                    readPrivileges: { .init(applications: [.files: filesGranted], isAdministrator: false) },
                    readPhotoAccess: { _ = try await photos.access() })
                let model = try makeModel(profile: profile) { await reader.read() }
                await model.refreshModuleAccess()
                XCTAssertEqual(model.isModuleVisible(.photos), enabled, "功能设置必须根据 Photos 自身授权显示照片开关")
                XCTAssertEqual(model.isPhotosModuleEnabled, enabled, "侧栏照片入口不能被未使用的选版字段隐藏")
                XCTAssertEqual(model.canActivate(.photos(.timeline)), enabled)
                XCTAssertEqual(model.isModuleVisible(.files), filesGranted)
                XCTAssertFalse(model.moduleAccessLookupFailed)
                let calls = await transport.calls
                let accessCalls = enabled ? PhotoDiscoveryTransport.accessAPIs : ["SYNO.Foto.UserInfo"]
                XCTAssertEqual(calls, ["SYNO.API.Info:1:query"] + accessCalls.map {
                    "\($0):1:\($0 == "SYNO.Foto.UserInfo" ? "me" : "get")"
                }, "仅读取已约定的访问设置；拒绝时不继续读取其他设置")
            }
        }
    }

    func test照片访问设置缺少接口版本或JSON支持时不发请求() async throws {
        for name in PhotoDiscoveryTransport.accessAPIs {
            let unsupported: [ApiCapability?] = [nil,
                ApiCapability(name: name, path: "entry.cgi", minVersion: 2, maxVersion: 2, requestFormat: .json),
                ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form)]
            for replacement in unsupported {
                var entries = Dictionary(uniqueKeysWithValues: photoCapabilities.all.map { ($0.name, $0) })
                entries[name] = replacement
                let profile = try profile(), photos = PhotoAccessProbe()
                let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: AccessTransport()),
                    capabilities: CapabilitySet(entries),
                    readPrivileges: { .init(applications: [.files: true], isAdministrator: false) },
                    readPhotoAccess: { try await photos.read() })
                let snapshot = await reader.read()
                XCTAssertEqual(snapshot.modules[.photos], .unavailable)
                XCTAssertEqual(snapshot.modules[.files], .available)
                let reads = await photos.reads
                XCTAssertEqual(reads, 0)
            }
        }
    }

    func test文件已授权不覆盖照片明确拒绝或缺少能力() async throws {
        let profile = try profile(), transport = AccessTransport(), photos = PhotoAccessProbe(failure: .permissionDenied)
        let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: transport),
            capabilities: photoCapabilities, readPrivileges: { .init(applications: [.files: true], isAdministrator: false) },
            readPhotoAccess: { try await photos.read() })
        let denied = await reader.read()
        XCTAssertEqual(denied.modules[.files], .available); XCTAssertEqual(denied.modules[.photos], .denied)
        XCTAssertFalse(denied.lookupFailed)
        let missing = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: transport),
            capabilities: capabilities, readPrivileges: { .init(applications: [.files: true], isAdministrator: false) },
            readPhotoAccess: { XCTFail("照片能力缺失不应发请求") })
        let unavailable = await missing.read()
        XCTAssertEqual(unavailable.modules[.files], .available); XCTAssertEqual(unavailable.modules[.photos], .unavailable)
        let calls = await transport.requests; XCTAssertTrue(calls.isEmpty)
    }

    func test摘要失败和文件拒绝不替代独立照片授权() async throws {
        for errorCode in [nil, 105] as [Int?] {
            let profile = try profile(), transport = AccessTransport(errorCode: errorCode), photos = PhotoAccessProbe()
            let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: transport),
                capabilities: photoCapabilities, readPrivileges: { throw URLError(.cannotConnectToHost) },
                readPhotoAccess: { try await photos.read() })
            let snapshot = await reader.read()
            XCTAssertTrue(snapshot.lookupFailed); XCTAssertEqual(snapshot.modules[.photos], .available)
            XCTAssertEqual(snapshot.modules[.files], errorCode == nil ? .available : .denied)
            let photoReads = await photos.reads, fileCalls = await transport.requests
            XCTAssertEqual(photoReads, 1); XCTAssertEqual(fileCalls.count, 1)
        }
    }

    func test摘要安全错误与文件会话失效不继续读取照片() async throws {
        var failures: [any Error] = [AppErrorCategory.tlsUntrusted, .tlsCertificateChanged, .authenticationRequired, .cancelled]
            .map { AppError(category: $0, isRetryable: false, safeUserMessage: "") }
        failures.append(CancellationError())
        failures.append(DsmCertificateTrustError.changed(.init(host: "example.invalid", subjectSummary: "Synthetic",
            sha256Fingerprint: String(repeating: "0", count: 64), canBePinned: true)))
        for failure in failures {
            let profile = try profile(), transport = AccessTransport(), photos = PhotoAccessProbe()
            let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: transport),
                capabilities: photoCapabilities, readPrivileges: { throw failure }, readPhotoAccess: { try await photos.read() })
            let snapshot = await reader.read()
            XCTAssertTrue(snapshot.lookupFailed); XCTAssertNil(snapshot.modules[.photos])
            let photoReads = await photos.reads, fileCalls = await transport.requests
            XCTAssertEqual(photoReads, 0); XCTAssertTrue(fileCalls.isEmpty)
        }
        let profile = try profile(), transport = AccessTransport(errorCode: 119), photos = PhotoAccessProbe()
        let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: transport),
            capabilities: photoCapabilities, readPrivileges: { throw URLError(.notConnectedToInternet) },
            readPhotoAccess: { try await photos.read() })
        let snapshot = await reader.read()
        guard case .authenticationRequired = snapshot.modules[.files] else { return XCTFail("必须保留文件会话失效") }
        let photoReads = await photos.reads; XCTAssertEqual(photoReads, 0)
    }

    func test照片读取失败不冒充拒绝也不影响已授权文件() async throws {
        let profile = try profile(), transport = AccessTransport(), photos = PhotoAccessProbe(failure: .networkUnavailable)
        let reader = WorkspaceModuleAccessReader(files: try fileRepository(profile: profile, transport: transport),
            capabilities: photoCapabilities, readPrivileges: { .init(applications: [.files: true], isAdministrator: false) },
            readPhotoAccess: { try await photos.read() })
        let snapshot = await reader.read()
        XCTAssertEqual(snapshot.modules[.files], .available); XCTAssertEqual(snapshot.modules[.photos], .failed)
        XCTAssertTrue(snapshot.lookupFailed)
    }

    func test照片会话失效进入重新登录且不先启动模块() async throws {
        let profile = try profile(); defer { cleanPreferences(profile.id) }
        let issue = AppError(category: .authenticationRequired, isRetryable: false, safeUserMessage: "private-response",
                             dsmCode: 119, httpStatus: 200)
        let model = try makeModel(profile: profile) {
            WorkspaceModuleAccessSnapshot(modules: [.files: .denied, .photos: .authenticationRequired(issue)], lookupFailed: true)
        }
        await model.startEnabledModules()
        XCTAssertTrue(model.requiresReauthentication)
        XCTAssertEqual(model.statusMessage, L10n.string("connection.session.rejected"))
        XCTAssertEqual(model.section, .settings)
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
        for destination in [WorkspaceSection.photos(.timeline), .chat, .nasSettings, .downloadStation,
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
        for allowed in [[WorkspaceModule.files, .photos, .virtualMachines], [.photos], [.files, .virtualMachines], [.virtualMachines]] {
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

    private var photoCapabilities: CapabilitySet {
        let photos = ["SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.TeamSpace"].map {
            ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .json)
        }
        return CapabilitySet(Dictionary(uniqueKeysWithValues: (capabilities.all + photos).map { ($0.name, $0) }))
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
    private let errorCode: Int?
    init(errorCode: Int? = nil) { self.errorCode = errorCode }
    private(set) var requests: [URLRequest] = []
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        if let errorCode { return DsmHTTPResponse(data: Data("{\"success\":false,\"error\":{\"code\":\(errorCode)}}".utf8), statusCode: 200) }
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

private actor PhotoAccessProbe {
    let failure: AppErrorCategory?
    private(set) var reads = 0
    init(failure: AppErrorCategory? = nil) { self.failure = failure }
    func read() throws {
        reads += 1
        if let failure { throw AppError(category: failure, isRetryable: false, safeUserMessage: "") }
    }
}

/// 使用合成响应经过真实能力解析与 Photos Repository，避免手造选版结果掩盖入口回归。
private actor PhotoDiscoveryTransport: DsmHTTPTransport {
    static let accessAPIs = ["SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.TeamSpace"]
    let enabled: Bool
    private(set) var calls: [String] = []
    init(enabled: Bool) { self.enabled = enabled }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let parameters = URLComponents(string: "?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems ?? []
        let api = parameters.first { $0.name == "api" }?.value ?? ""
        let version = parameters.first { $0.name == "version" }?.value ?? ""
        let method = parameters.first { $0.name == "method" }?.value ?? ""
        calls.append("\(api):\(version):\(method)")
        let payload: [String: Any]
        switch api {
        case "SYNO.API.Info":
            let queried = Set((parameters.first { $0.name == "query" }?.value ?? "").split(separator: ",").map(String.init))
            guard Set(Self.accessAPIs).isSubset(of: queried) else { throw URLError(.badServerResponse) }
            var capabilities = Dictionary(uniqueKeysWithValues: Self.accessAPIs.map {
                ($0, ["path": "entry.cgi", "minVersion": 1, "maxVersion": 1, "requestFormat": "JSON"] as [String: Any])
            })
            capabilities[DsmAPIName.fileStationList] = ["path": "entry.cgi", "minVersion": 1, "maxVersion": 2, "requestFormat": "FORM"]
            payload = capabilities
        case "SYNO.Foto.UserInfo": payload = ["enabled": enabled, "is_admin": false, "id": 7]
        case "SYNO.Foto.Setting.User": payload = ["enable_home_service": true, "team_space_permission": "none"]
        case "SYNO.Foto.Setting.Admin": payload = ["package_version": "1.0.synthetic"]
        case "SYNO.Foto.Setting.TeamSpace": payload = ["enabled": false]
        default: throw URLError(.unsupportedURL)
        }
        return DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": payload]), statusCode: 200)
    }
}
