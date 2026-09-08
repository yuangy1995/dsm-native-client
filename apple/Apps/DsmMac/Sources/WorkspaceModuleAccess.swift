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
    let modules: [WorkspaceModule: WorkspaceModuleAccess]
    var lookupFailed = false
}

/// 一次读取权限摘要；不再用业务列表加载试探应用权限。
struct WorkspaceModuleAccessReader: Sendable {
    let files: any FileRepository
    let capabilities: CapabilitySet
    let readPrivileges: @Sendable () async throws -> DsmDesktopAppPrivileges

    func read() async -> WorkspaceModuleAccessSnapshot {
        do {
            let privileges = try await readPrivileges()
            return Self.resolve(privileges, capabilities: capabilities)
        } catch {
            // 摘要不可读不等于文件会话失效；只核实文件，其他套件保持关闭。
            // 安全错误和取消不额外发出网络请求，交由连接恢复入口处理。
            if Task.isCancelled { return WorkspaceModuleAccessSnapshot(modules: [:], lookupFailed: true) }
            if let issue = error as? AppError,
               [.tlsUntrusted, .tlsCertificateChanged, .cancelled].contains(issue.category) {
                return WorkspaceModuleAccessSnapshot(modules: [:], lookupFailed: true)
            }
            do {
                _ = try await files.listShares(offset: 0, limit: 1)
                return WorkspaceModuleAccessSnapshot(modules: [.files: .available], lookupFailed: true)
            } catch {
                return WorkspaceModuleAccessSnapshot(modules: [.files: .result(for: error)], lookupFailed: true)
            }
        }
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
            // 当前照片是 File Station 的文件视图，不请求 Synology Photos 内部接口。
            .photos: files,
            .chat: granted(.chat) && supports(DsmAPIName.chatChannel) && supports(DsmAPIName.chatUser),
            .downloads: granted(.downloads) && supports(DsmAPIName.downloadStationTask, DsmAPIName.downloadStation2Task),
            .virtualMachines: granted(.virtualMachines) && supports(DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuest),
            .containers: administratorEntry(.containers) && supports(DsmAPIName.dockerContainer),
            .nasSettings: administratorEntry(.nasSettings) && supports(DsmAPIName.coreSystem)
        ]
        return WorkspaceModuleAccessSnapshot(modules: allowed.mapValues { $0 ? .available : .denied })
    }
}
