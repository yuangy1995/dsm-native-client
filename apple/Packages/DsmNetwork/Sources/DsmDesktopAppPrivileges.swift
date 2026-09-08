import DsmCore
import DsmLocalization
import Foundation

/// 仅登记客户端已有模块；不根据第三方应用名构造 API 请求。
public enum DsmDesktopApplication: String, CaseIterable, CodingKey, Sendable {
    case files = "SYNO.SDS.App.FileStation3.Instance"
    case chat = "SYNO.SDS.Chat.Application"
    case downloads = "SYNO.SDS.DownloadStation.Application"
    case containers = "SYNO.SDS.ContainerManager.Application"
    case virtualMachines = "SYNO.SDS.Virtualization.Application"
    case nasSettings = "SYNO.SDS.AdminCenter.Application"
}

/// 只解码应用授权白名单与管理员布尔值；不保留 Session/UserSettings 中的其他数据。
public struct DsmDesktopAppPrivileges: Decodable, Sendable {
    public let applications: [DsmDesktopApplication: Bool]
    public let isAdministrator: Bool

    public init(applications: [DsmDesktopApplication: Bool], isAdministrator: Bool) {
        self.applications = applications
        self.isAdministrator = isAdministrator
    }

    private enum CodingKeys: String, CodingKey {
        case applications = "AppPrivilege"
        case session = "Session"
    }
    private struct SessionRole: Decodable {
        let is_admin: Bool?
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let values = try container.nestedContainer(keyedBy: DsmDesktopApplication.self, forKey: .applications)
        var applications: [DsmDesktopApplication: Bool] = [:]
        for application in DsmDesktopApplication.allCases where values.contains(application) {
            applications[application] = try values.decode(Bool.self, forKey: application)
        }
        self.applications = applications
        isAdministrator = try container.decodeIfPresent(SessionRole.self, forKey: .session)?.is_admin == true
    }
}

/// 内部只读 API，依据 2026-09-09 官方桌面观察；失败时由调用方限制套件入口。
public struct DsmDesktopAppPrivilegesService: Sendable {
    private let client: DsmAPIClient

    public init(client: DsmAPIClient) {
        self.client = client
    }

    public init(profile: NasProfile, transport: any DsmHTTPTransport) throws {
        client = DsmAPIClient(baseURL: try DsmEndpoint.baseURL(for: profile), transport: transport)
    }

    public func read(capabilities: CapabilitySet, session: AuthSession) async throws -> DsmDesktopAppPrivileges {
        guard let capability = capabilities[DsmAPIName.desktopInitData], capability.selectedVersion == 1 else {
            throw AppError(category: .apiUnavailable, isRetryable: false,
                           safeUserMessage: L10n.string("workspace.modules.unavailable"))
        }
        do {
            return try await client.call(
                path: capability.path, api: capability.name, version: 1,
                method: "get_user_service", requestFormat: .form,
                parameters: ["launch_app": .string("null")],
                credential: DsmSessionCredential(sid: session.sid, synoToken: session.synoToken),
                httpMethod: "GET", as: DsmDesktopAppPrivileges.self
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }
}
