import DsmCore
import DsmNetwork
import Foundation

/// 仅在当前工作区内使用；权限结果不覆盖用户保存的功能偏好。
enum WorkspaceModule: String, CaseIterable, Hashable, Sendable {
    case files, photos, chat, nasSettings, downloads, containers, virtualMachines
}

enum WorkspaceModuleAccess: Equatable, Sendable {
    case available
    case denied
    case unavailable
    case failed
    case authenticationRequired(AppError)

    var isVisible: Bool {
        switch self {
        case .available, .failed, .authenticationRequired: true
        case .denied, .unavailable: false
        }
    }

    static func result(for error: Error) -> Self {
        guard let error = error as? AppError else { return .failed }
        switch error.category {
        case .permissionDenied: return .denied
        case .apiUnavailable, .versionUnsupported: return .unavailable
        case .authenticationRequired: return .authenticationRequired(error)
        default: return .failed
        }
    }
}

struct WorkspaceModuleAccessSnapshot: Sendable {
    var modules: [WorkspaceModule: WorkspaceModuleAccess]
    var lookupFailed = false
}

/// 读取应用权限摘要与独立的 Photos 访问设置，不用套件业务列表试探权限。
struct WorkspaceModuleAccessReader: Sendable {
    let files: any FileRepository
    let capabilities: CapabilitySet
    let readPrivileges: @Sendable () async throws -> DsmDesktopAppPrivileges
    let readPhotoAccess: @Sendable () async throws -> Void

    func read() async -> WorkspaceModuleAccessSnapshot {
        var snapshot: WorkspaceModuleAccessSnapshot
        do {
            let privileges = try await readPrivileges()
            snapshot = Self.resolve(privileges, capabilities: capabilities)
        } catch {
            // 摘要不可读不等于文件或 Photos 会话失效；两者分别核实，其他套件保持关闭。
            // 安全错误和取消不额外发出网络请求，交由连接恢复入口处理。
            if Task.isCancelled || Self.stopsFurtherReads(error) {
                let modules: [WorkspaceModule: WorkspaceModuleAccess] = (error as? AppError)?.category == .authenticationRequired
                    ? [.files: .result(for: error)] : [:]
                return WorkspaceModuleAccessSnapshot(modules: modules, lookupFailed: true)
            }
            do {
                _ = try await files.listShares(offset: 0, limit: 1)
                snapshot = WorkspaceModuleAccessSnapshot(modules: [.files: .available], lookupFailed: true)
            } catch {
                snapshot = WorkspaceModuleAccessSnapshot(modules: [.files: .result(for: error)], lookupFailed: true)
                if Self.stopsFurtherReads(error) { return snapshot }
            }
        }
        guard !Task.isCancelled else { return WorkspaceModuleAccessSnapshot(modules: [:], lookupFailed: true) }
        // Photos 按方法固定使用 v1，不参与全局自动选版；与 access() 的接口要求保持一致。
        guard ["SYNO.Foto.UserInfo", "SYNO.Foto.Setting.User", "SYNO.Foto.Setting.Admin", "SYNO.Foto.Setting.TeamSpace"]
            .allSatisfy({ name in
                guard let capability = capabilities[name] else { return false }
                return capability.minVersion <= 1 && capability.maxVersion >= 1 && capability.requestFormat == .json
            }) else {
            snapshot.modules[.photos] = .unavailable
            return snapshot
        }
        do {
            try await readPhotoAccess()
            snapshot.modules[.photos] = .available
        } catch {
            snapshot.modules[.photos] = .result(for: error)
            if snapshot.modules[.photos] != .denied && snapshot.modules[.photos] != .unavailable { snapshot.lookupFailed = true }
        }
        return snapshot
    }

    private static func stopsFurtherReads(_ error: Error) -> Bool {
        if error is CancellationError || error is DsmCertificateTrustError { return true }
        guard let error = error as? AppError else { return false }
        return [.tlsUntrusted, .tlsCertificateChanged, .cancelled, .authenticationRequired].contains(error.category)
    }

    static func resolve(_ privileges: DsmDesktopAppPrivileges, capabilities: CapabilitySet) -> WorkspaceModuleAccessSnapshot {
        func supports(_ names: String...) -> Bool {
            names.contains { capabilities[$0]?.selectedVersion != nil }
        }
        func granted(_ application: DsmDesktopApplication) -> Bool {
            privileges.applications[application] == true
        }
        func administratorEntry(_ application: DsmDesktopApplication) -> Bool {
            privileges.isAdministrator && privileges.applications[application] != false
        }
        let files = granted(.files) && supports(DsmAPIName.fileStationList)
        let allowed: [WorkspaceModule: Bool] = [
            .files: files,
            // Photos 必须由自身访问设置明确授权，不能继承 File Station 权限。
            .photos: false,
            .chat: granted(.chat) && supports(DsmAPIName.chatChannel) && supports(DsmAPIName.chatUser),
            .downloads: granted(.downloads) && supports(DsmAPIName.downloadStationTask, DsmAPIName.downloadStation2Task),
            .virtualMachines: granted(.virtualMachines) && supports(DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuest),
            .containers: administratorEntry(.containers) && supports(DsmAPIName.dockerContainer),
            .nasSettings: administratorEntry(.nasSettings) && supports(DsmAPIName.coreSystem)
        ]
        return WorkspaceModuleAccessSnapshot(modules: allowed.mapValues { $0 ? .available : .denied })
    }
}
