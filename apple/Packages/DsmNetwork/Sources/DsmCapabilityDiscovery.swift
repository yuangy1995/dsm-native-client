import DsmCore
import Foundation
import DsmLocalization

public enum DsmAPIName {
    public static let authentication = "SYNO.API.Auth"
    /// DSM 桌面内部权限摘要；只使用 get_user_service，不加载各套件业务数据。
    public static let desktopInitData = "SYNO.Core.Desktop.Initdata"
    public static let fileStationInfo = "SYNO.FileStation.Info"
    public static let fileStationList = "SYNO.FileStation.List"
    public static let fileStationThumbnail = "SYNO.FileStation.Thumb"
    public static let fileStationCheckPermission = "SYNO.FileStation.CheckPermission"
    public static let fileStationDownload = "SYNO.FileStation.Download"
    public static let fileStationUpload = "SYNO.FileStation.Upload"
    public static let fileStationDelete = "SYNO.FileStation.Delete"
    public static let fileStationCreateFolder = "SYNO.FileStation.CreateFolder"
    public static let fileStationRename = "SYNO.FileStation.Rename"
    public static let fileStationCopyMove = "SYNO.FileStation.CopyMove"
    public static let fileStationCompress = "SYNO.FileStation.Compress"
    public static let fileStationExtract = "SYNO.FileStation.Extract"
    public static let fileStationSearch = "SYNO.FileStation.Search"
    public static let fileStationMD5 = "SYNO.FileStation.MD5"
    /// File Station 官方目录大小任务；固定使用 v2 的 start/status/stop 工作流。
    public static let fileStationDirSize = "SYNO.FileStation.DirSize"
    public static let fileStationFavorite = "SYNO.FileStation.Favorite"
    public static let fileStationSharing = "SYNO.FileStation.Sharing"
    public static let fileStationVirtualFolder = "SYNO.FileStation.VirtualFolder"
    /// File Station 官方只读后台任务列表；客户端不接入清理等写方法。
    public static let fileStationBackgroundTask = "SYNO.FileStation.BackgroundTask"
    /// DSM File Station 的未公开挂载接口；只在能力发现明确返回时启用。
    public static let fileStationMount = "SYNO.FileStation.Mount"
    /// Synology Chat 套件内部接口；仅在 DSM 能力发现明确返回时启用。
    public static let chatChannel = "SYNO.Chat.Channel"
    /// Synology Chat 命名会话内部接口；用于创建群聊和邀请成员。
    public static let chatChannelNamed = "SYNO.Chat.Channel.Named"
    /// Synology Chat 匿名会话内部接口；用于首次创建一对一会话。
    public static let chatChannelAnonymous = "SYNO.Chat.Channel.Anonymous"
    /// Synology Chat 会话成员内部接口；用于读取当前账号可见的群成员。
    public static let chatChannelMember = "SYNO.Chat.Channel.Member"
    /// Synology Chat 用户目录内部接口。
    public static let chatUser = "SYNO.Chat.User"
    /// Synology Chat 用户头像内部接口；仅用于读取当前账号可见的头像。
    public static let chatUserAvatar = "SYNO.Chat.User.Avatar"
    /// Synology Chat 消息内部接口。
    public static let chatPost = "SYNO.Chat.Post"
    /// Synology Chat 附件读取内部接口；当前只登记能力，不在界面暴露协议细节。
    public static let chatPostFile = "SYNO.Chat.Post.File"
    /// Synology Chat 消息提醒内部接口。
    public static let chatPostReminder = "SYNO.Chat.Post.Reminder"
    /// Synology Chat 投票内部接口。
    public static let chatPostVote = "SYNO.Chat.Post.Vote"
    /// Synology Chat 定时消息内部接口。
    public static let chatPostSchedule = "SYNO.Chat.Post.Schedule"
    // Download Station 公开接口。
    public static let downloadStationInfo = "SYNO.DownloadStation.Info"
    public static let downloadStationSchedule = "SYNO.DownloadStation.Schedule"
    public static let downloadStationTask = "SYNO.DownloadStation.Task"
    public static let downloadStationStatistic = "SYNO.DownloadStation.Statistic"
    public static let downloadStationRSSSite = "SYNO.DownloadStation.RSS.Site"
    public static let downloadStationRSSFeed = "SYNO.DownloadStation.RSS.Feed"
    public static let downloadStationBTSearch = "SYNO.DownloadStation.BTSearch"
    // Download Station 2 套件内部接口，只在公开接口不可用时降级使用。
    public static let downloadStation2Task = "SYNO.DownloadStation2.Task"
    public static let downloadStation2Statistic = "SYNO.DownloadStation2.Task.Statistic"
    public static let downloadStation2Location = "SYNO.DownloadStation2.Settings.Location"
    public static let downloadStation2RSSFeed = "SYNO.DownloadStation2.RSS.Feed"
    // Virtual Machine Manager 公开接口。
    public static let virtualizationAPIGuest = "SYNO.Virtualization.API.Guest"
    public static let virtualizationAPIGuestAction = "SYNO.Virtualization.API.Guest.Action"
    public static let virtualizationAPIGuestImage = "SYNO.Virtualization.API.Guest.Image"
    public static let virtualizationAPITaskInfo = "SYNO.Virtualization.API.Task.Info"
    public static let virtualizationAPIHost = "SYNO.Virtualization.API.Host"
    public static let virtualizationAPIStorage = "SYNO.Virtualization.API.Storage"
    public static let virtualizationAPINetwork = "SYNO.Virtualization.API.Network"
    // VMM 当前网页使用的内部接口。
    public static let virtualizationGuest = "SYNO.Virtualization.Guest"
    public static let virtualizationGuestAction = "SYNO.Virtualization.Guest.Action"
    public static let virtualizationGuestImage = "SYNO.Virtualization.Guest.Image"
    public static let virtualizationHost = "SYNO.Virtualization.Host"
    public static let virtualizationRepo = "SYNO.Virtualization.Repo"
    public static let virtualizationNetwork = "SYNO.Virtualization.Network"
    public static let virtualizationProtectionPlan = "SYNO.Virtualization.GuestProtect.Plan"
    public static let virtualizationLog = "SYNO.Virtualization.Log"
    // Container Manager 仅有内部接口，必须逐项能力发现。
    public static let dockerContainer = "SYNO.Docker.Container"
    public static let dockerImage = "SYNO.Docker.Image"
    public static let dockerRegistry = "SYNO.Docker.Registry"
    public static let dockerNetwork = "SYNO.Docker.Network"
    public static let dockerProject = "SYNO.Docker.Project"
    public static let dockerLog = "SYNO.Docker.Log"
    // 以下均为 DSM 内部只读接口，仅在能力发现明确返回时使用。
    public static let coreSystem = "SYNO.Core.System"
    public static let coreSystemUtilization = "SYNO.Core.System.Utilization"
    /// DSM 资源监控内部进程列表；只读取经过白名单筛选的最小字段。
    public static let coreSystemProcess = "SYNO.Core.System.Process"
    /// DSM 资源监控内部服务进程组；`service_info` 尚未接入。
    public static let coreSystemProcessGroup = "SYNO.Core.System.ProcessGroup"
    public static let storageOverview = "SYNO.Storage.CGI.Storage"
    public static let storageSmart = "SYNO.Storage.CGI.Smart"
    public static let storageVolume = "SYNO.Core.Storage.Volume"
    /// DSM 存储管理器内部硬盘检测接口；仅在能力发现明确返回时启用。
    public static let coreStorageDisk = "SYNO.Core.Storage.Disk"
    public static let corePackage = "SYNO.Core.Package"
    /// DSM 套件启停内部接口。
    public static let corePackageControl = "SYNO.Core.Package.Control"
    /// DSM 套件卸载内部接口。
    public static let corePackageUninstallation = "SYNO.Core.Package.Uninstallation"
    /// DSM 已安装套件图标内部接口。
    public static let corePackageThumb = "SYNO.Core.Package.Thumb"
    public static let coreTaskScheduler = "SYNO.Core.TaskScheduler"
    /// DSM 计划任务运行结果内部接口。
    public static let coreEventScheduler = "SYNO.Core.EventScheduler"
    /// DSM 系统更新检查内部接口；客户端只读取可用更新，不执行下载或安装。
    public static let coreUpgradeServer = "SYNO.Core.Upgrade.Server"
    public static let coreUser = "SYNO.Core.User"
    public static let coreGroup = "SYNO.Core.Group"
    public static let coreCurrentConnection = "SYNO.Core.CurrentConnection"
    public static let coreSystemLog = "SYNO.Core.SyslogClient.Log"
    public static let logCenterHistory = "SYNO.LogCenter.History"
    /// DSM 控制面板内部接口：终端服务。
    public static let coreTerminal = "SYNO.Core.Terminal"
    /// DSM 控制面板内部接口：SMB 文件服务。
    public static let coreFileServiceSMB = "SYNO.Core.FileServ.SMB"
    /// DSM 控制面板内部接口：NFS 文件服务。
    public static let coreFileServiceNFS = "SYNO.Core.FileServ.NFS"
    /// DSM 控制面板内部接口：FTP/FTPS 文件服务。
    public static let coreFileServiceFTP = "SYNO.Core.FileServ.FTP"
    /// DSM 控制面板内部接口：SFTP 文件服务。
    public static let coreFileServiceSFTP = "SYNO.Core.FileServ.FTP.SFTP"
    /// DSM 控制面板内部接口：互联网代理。
    public static let coreNetworkProxy = "SYNO.Core.Network.Proxy"
    /// DSM 控制面板内部接口：断电恢复。
    public static let coreHardwarePowerRecovery = "SYNO.Core.Hardware.PowerRecovery"
    /// DSM 控制面板内部内存压缩；当前客户端仅启用只读 `get`。
    public static let coreHardwareZRAM = "SYNO.Core.Hardware.ZRAM"
    /// DSM 控制面板内部电源计划；当前客户端仅启用只读 `load`。
    public static let coreHardwarePowerSchedule = "SYNO.Core.Hardware.PowerSchedule"
    /// DSM 控制面板内部 USB 存储列表；`eject` 尚未接入。
    public static let coreExternalStorageUSB = "SYNO.Core.ExternalDevice.Storage.USB"
    /// DSM 控制面板内部 eSATA 存储列表。
    public static let coreExternalStorageESATA = "SYNO.Core.ExternalDevice.Storage.eSATA"
    /// DSM 控制面板内部接口：设备灯光亮度。
    public static let coreHardwareLEDBrightness = "SYNO.Core.Hardware.Led.Brightness"
    /// DSM 控制面板内部接口：风扇模式。
    public static let coreHardwareFanSpeed = "SYNO.Core.Hardware.FanSpeed"
    /// DSM 控制面板内部接口：设备提示音。
    public static let coreHardwareBeepControl = "SYNO.Core.Hardware.BeepControl"
    /// DSM 控制面板内部接口：硬盘休眠与自动关机。
    public static let coreHardwareHibernation = "SYNO.Core.Hardware.Hibernation"
    /// DSM 控制面板内部接口：QuickConnect 基础设置。
    public static let coreQuickConnect = "SYNO.Core.QuickConnect"
    /// DSM 控制面板内部接口：QuickConnect 路由器自动配置。
    public static let coreQuickConnectUPnP = "SYNO.Core.QuickConnect.Upnp"
    /// DSM 控制面板内部接口：登录失败自动封锁。
    public static let coreSecurityAutoBlock = "SYNO.Core.Security.AutoBlock"
    /// DSM 控制面板内部接口：局域网设备发现。
    public static let coreWebDSM = "SYNO.Core.Web.DSM"
    /// DSM 控制面板内部接口：文件服务发现。
    public static let coreFileServiceDiscovery = "SYNO.Core.FileServ.ServiceDiscovery"
    /// DSM 控制面板内部接口：网卡列表。
    public static let coreNetworkEthernet = "SYNO.Core.Network.Ethernet"
    /// DSM 控制面板内部接口：按网卡配置拒绝服务攻击防护。
    public static let coreSecurityDoS = "SYNO.Core.Security.DoS"
    /// DSM 控制面板内部接口：区域、时区与网络校时。
    public static let coreRegionNTP = "SYNO.Core.Region.NTP"
    /// DSM 控制面板内部接口：DDNS 服务提供商与记录。
    public static let coreDDNSProvider = "SYNO.Core.DDNS.Provider"
    public static let coreDDNSRecord = "SYNO.Core.DDNS.Record"
    /// DSM 控制面板内部接口：UPS 安全关机设置。
    public static let coreExternalDeviceUPS = "SYNO.Core.ExternalDevice.UPS"
    /// DSM 控制面板内部接口：防火墙启停、端口扫描防护与配置应用。
    public static let coreSecurityFirewall = "SYNO.Core.Security.Firewall"
    public static let coreSecurityFirewallConf = "SYNO.Core.Security.Firewall.Conf"
    public static let coreSecurityFirewallProfileApply =
        "SYNO.Core.Security.Firewall.Profile.Apply"
}

private struct CapabilityPayload: Decodable, Sendable {
    let path: String
    let minVersion: Int
    let maxVersion: Int
    let requestFormat: DsmRequestFormat

    private enum CodingKeys: String, CodingKey {
        case path
        case minVersion
        case maxVersion
        case requestFormat
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        minVersion = try container.decode(Int.self, forKey: .minVersion)
        maxVersion = try container.decode(Int.self, forKey: .maxVersion)

        let rawFormat = try container.decodeIfPresent(String.self, forKey: .requestFormat)
        requestFormat = DsmRequestFormat(rawValue: rawFormat?.uppercased() ?? "FORM") ?? .form
    }
}

public struct DsmCapabilityDiscovery: Sendable {
    public static let initialAPIs = [
        DsmAPIName.authentication,
        DsmAPIName.desktopInitData,
        DsmAPIName.fileStationInfo,
        DsmAPIName.fileStationList,
        DsmAPIName.fileStationThumbnail,
        DsmAPIName.fileStationCheckPermission,
        DsmAPIName.fileStationDownload,
        DsmAPIName.fileStationUpload,
        DsmAPIName.fileStationDelete,
        DsmAPIName.fileStationCreateFolder,
        DsmAPIName.fileStationRename,
        DsmAPIName.fileStationCopyMove,
        DsmAPIName.fileStationCompress,
        DsmAPIName.fileStationExtract,
        DsmAPIName.fileStationSearch,
        DsmAPIName.fileStationMD5,
        DsmAPIName.fileStationDirSize,
        DsmAPIName.fileStationFavorite,
        DsmAPIName.fileStationSharing,
        DsmAPIName.fileStationVirtualFolder,
        DsmAPIName.fileStationMount,
        DsmAPIName.fileStationBackgroundTask,
        DsmAPIName.chatChannel,
        DsmAPIName.chatChannelNamed,
        DsmAPIName.chatChannelAnonymous,
        DsmAPIName.chatChannelMember,
        DsmAPIName.chatUser,
        DsmAPIName.chatUserAvatar,
        DsmAPIName.chatPost,
        DsmAPIName.chatPostFile,
        DsmAPIName.chatPostReminder,
        DsmAPIName.chatPostVote,
        DsmAPIName.chatPostSchedule,
        DsmAPIName.downloadStationTask,
        DsmAPIName.downloadStationInfo,
        DsmAPIName.downloadStationSchedule,
        DsmAPIName.downloadStationStatistic,
        DsmAPIName.downloadStationRSSSite,
        DsmAPIName.downloadStationRSSFeed,
        DsmAPIName.downloadStationBTSearch,
        DsmAPIName.downloadStation2Task,
        DsmAPIName.downloadStation2Statistic,
        DsmAPIName.downloadStation2Location,
        DsmAPIName.downloadStation2RSSFeed,
        DsmAPIName.virtualizationAPIGuest,
        DsmAPIName.virtualizationAPIGuestAction,
        DsmAPIName.virtualizationAPIGuestImage,
        DsmAPIName.virtualizationAPITaskInfo,
        DsmAPIName.virtualizationAPIHost,
        DsmAPIName.virtualizationAPIStorage,
        DsmAPIName.virtualizationAPINetwork,
        DsmAPIName.virtualizationGuest,
        DsmAPIName.virtualizationGuestAction,
        DsmAPIName.virtualizationGuestImage,
        DsmAPIName.virtualizationHost,
        DsmAPIName.virtualizationRepo,
        DsmAPIName.virtualizationNetwork,
        DsmAPIName.virtualizationProtectionPlan,
        DsmAPIName.virtualizationLog,
        DsmAPIName.dockerContainer,
        DsmAPIName.dockerImage,
        DsmAPIName.dockerRegistry,
        DsmAPIName.dockerNetwork,
        DsmAPIName.dockerProject,
        DsmAPIName.dockerLog,
        DsmAPIName.coreSystem,
        DsmAPIName.coreSystemUtilization,
        DsmAPIName.coreSystemProcess,
        DsmAPIName.coreSystemProcessGroup,
        DsmAPIName.storageOverview,
        DsmAPIName.storageSmart,
        DsmAPIName.storageVolume,
        DsmAPIName.coreStorageDisk,
        DsmAPIName.corePackage,
        DsmAPIName.corePackageControl,
        DsmAPIName.corePackageUninstallation,
        DsmAPIName.corePackageThumb,
        DsmAPIName.coreTaskScheduler,
        DsmAPIName.coreEventScheduler,
        DsmAPIName.coreUpgradeServer,
        DsmAPIName.coreUser,
        DsmAPIName.coreGroup,
        DsmAPIName.coreCurrentConnection,
        DsmAPIName.coreSystemLog,
        DsmAPIName.logCenterHistory,
        DsmAPIName.coreTerminal,
        DsmAPIName.coreFileServiceSMB,
        DsmAPIName.coreFileServiceNFS,
        DsmAPIName.coreFileServiceFTP,
        DsmAPIName.coreFileServiceSFTP,
        DsmAPIName.coreNetworkProxy,
        DsmAPIName.coreHardwarePowerRecovery,
        DsmAPIName.coreHardwareZRAM,
        DsmAPIName.coreHardwarePowerSchedule,
        DsmAPIName.coreExternalStorageUSB,
        DsmAPIName.coreExternalStorageESATA,
        DsmAPIName.coreHardwareLEDBrightness,
        DsmAPIName.coreHardwareFanSpeed,
        DsmAPIName.coreHardwareBeepControl,
        DsmAPIName.coreHardwareHibernation,
        DsmAPIName.coreQuickConnect,
        DsmAPIName.coreQuickConnectUPnP,
        DsmAPIName.coreSecurityAutoBlock,
        DsmAPIName.coreWebDSM,
        DsmAPIName.coreFileServiceDiscovery,
        DsmAPIName.coreNetworkEthernet,
        DsmAPIName.coreSecurityDoS,
        DsmAPIName.coreRegionNTP,
        DsmAPIName.coreDDNSProvider,
        DsmAPIName.coreDDNSRecord,
        DsmAPIName.coreExternalDeviceUPS,
        DsmAPIName.coreSecurityFirewall,
        DsmAPIName.coreSecurityFirewallConf,
        DsmAPIName.coreSecurityFirewallProfileApply
    ]

    private let client: DsmAPIClient
    private let apiNames: [String]

    public init(
        client: DsmAPIClient,
        apiNames: [String] = DsmCapabilityDiscovery.initialAPIs
    ) {
        self.client = client
        self.apiNames = apiNames
    }

    public func discover() async throws -> CapabilitySet {
        do {
            let payloads = try await query(path: "entry.cgi")
            return try makeCapabilitySet(from: payloads)
        } catch let error as DsmNetworkError where Self.shouldUseLegacyEndpoint(after: error) {
            do {
                let payloads = try await query(path: "query.cgi")
                return try makeCapabilitySet(from: payloads)
            } catch let fallbackError as DsmNetworkError {
                throw DsmErrorMapper.map(fallbackError)
            }
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private func query(path: String) async throws -> [String: CapabilityPayload] {
        try await client.call(
            path: path,
            api: "SYNO.API.Info",
            version: 1,
            method: "query",
            requestFormat: .form,
            parameters: ["query": .string(apiNames.joined(separator: ","))],
            as: [String: CapabilityPayload].self
        )
    }

    private func makeCapabilitySet(
        from payloads: [String: CapabilityPayload]
    ) throws -> CapabilitySet {
        var capabilities: [String: ApiCapability] = [:]
        for (name, payload) in payloads {
            guard payload.minVersion > 0,
                  payload.maxVersion >= payload.minVersion,
                  let path = DsmEndpoint.normalizeAPIPath(payload.path) else {
                throw AppError(
                    category: .invalidResponse,
                    isRetryable: false,
                    safeUserMessage: L10n.string("shared.5503b9b2eb669c4e")
                )
            }

            var capability = ApiCapability(
                name: name,
                path: path,
                minVersion: payload.minVersion,
                maxVersion: payload.maxVersion,
                requestFormat: payload.requestFormat
            )

            if let supportedRange = Self.supportedRanges[name] {
                capability = (try? capability.selectingVersion(in: supportedRange)) ?? capability
            }
            capabilities[name] = capability
        }
        return CapabilitySet(capabilities)
    }

    private static func shouldUseLegacyEndpoint(after error: DsmNetworkError) -> Bool {
        switch error {
        case .httpStatus(let code, _):
            return code == 404 || code == 410
        case .api(let code, _):
            return code == 102 || code == 103
        default:
            return false
        }
    }

    private static let supportedRanges: [String: ClosedRange<Int>] = [
        DsmAPIName.authentication: 3...6,
        DsmAPIName.desktopInitData: 1...1,
        DsmAPIName.fileStationInfo: 1...2,
        DsmAPIName.fileStationList: 1...2,
        DsmAPIName.fileStationThumbnail: 1...2,
        DsmAPIName.fileStationCheckPermission: 1...3,
        DsmAPIName.fileStationDownload: 1...2,
        DsmAPIName.fileStationUpload: 1...2,
        DsmAPIName.fileStationDelete: 1...2,
        DsmAPIName.fileStationCreateFolder: 1...2,
        DsmAPIName.fileStationRename: 1...2,
        DsmAPIName.fileStationCopyMove: 1...3,
        DsmAPIName.fileStationCompress: 3...3,
        DsmAPIName.fileStationExtract: 2...2,
        DsmAPIName.fileStationSearch: 1...2,
        DsmAPIName.fileStationMD5: 1...2,
        DsmAPIName.fileStationDirSize: 2...2,
        DsmAPIName.fileStationFavorite: 1...2,
        DsmAPIName.fileStationSharing: 1...3,
        DsmAPIName.fileStationVirtualFolder: 2...2,
        DsmAPIName.fileStationMount: 1...1,
        DsmAPIName.fileStationBackgroundTask: 3...3,
        // Chat Server 没有公开普通用户聊天契约，范围按运行时返回值与已验证实现取交集。
        DsmAPIName.chatChannel: 1...5,
        DsmAPIName.chatChannelNamed: 1...1,
        DsmAPIName.chatChannelAnonymous: 1...2,
        DsmAPIName.chatChannelMember: 1...1,
        DsmAPIName.chatUser: 1...3,
        DsmAPIName.chatUserAvatar: 1...1,
        DsmAPIName.chatPost: 1...8,
        DsmAPIName.chatPostFile: 1...2,
        DsmAPIName.chatPostReminder: 1...1,
        DsmAPIName.chatPostVote: 1...1,
        DsmAPIName.chatPostSchedule: 1...1,
        DsmAPIName.downloadStationTask: 1...3,
        DsmAPIName.downloadStationInfo: 1...2,
        DsmAPIName.downloadStationSchedule: 1...1,
        DsmAPIName.downloadStationStatistic: 1...1,
        DsmAPIName.downloadStationRSSSite: 1...1,
        DsmAPIName.downloadStationRSSFeed: 1...1,
        DsmAPIName.downloadStationBTSearch: 1...1,
        DsmAPIName.downloadStation2Task: 1...2,
        DsmAPIName.downloadStation2Statistic: 1...1,
        DsmAPIName.downloadStation2Location: 1...1,
        DsmAPIName.downloadStation2RSSFeed: 1...1,
        DsmAPIName.virtualizationAPIGuest: 1...1,
        DsmAPIName.virtualizationAPIGuestAction: 1...1,
        DsmAPIName.virtualizationAPIGuestImage: 1...1,
        DsmAPIName.virtualizationAPITaskInfo: 1...1,
        DsmAPIName.virtualizationAPIHost: 1...1,
        DsmAPIName.virtualizationAPIStorage: 1...1,
        DsmAPIName.virtualizationAPINetwork: 1...1,
        DsmAPIName.virtualizationGuest: 1...2,
        DsmAPIName.virtualizationGuestAction: 1...1,
        DsmAPIName.virtualizationGuestImage: 1...2,
        DsmAPIName.virtualizationHost: 1...2,
        DsmAPIName.virtualizationRepo: 1...2,
        DsmAPIName.virtualizationNetwork: 1...2,
        DsmAPIName.virtualizationProtectionPlan: 1...2,
        DsmAPIName.virtualizationLog: 1...1,
        DsmAPIName.dockerContainer: 1...1,
        DsmAPIName.dockerImage: 1...1,
        DsmAPIName.dockerRegistry: 1...1,
        DsmAPIName.dockerNetwork: 1...1,
        DsmAPIName.dockerProject: 1...1,
        DsmAPIName.dockerLog: 1...1,
        // 内部接口版本以运行时能力发现为准；这里仅限制已知的兼容区间。
        DsmAPIName.coreSystem: 1...3,
        DsmAPIName.coreSystemUtilization: 1...1,
        // 静态目录尚未给出版本矩阵；客户端仅接受最小 v1 范围并要求运行时发现。
        DsmAPIName.coreSystemProcess: 1...1,
        DsmAPIName.coreSystemProcessGroup: 1...1,
        DsmAPIName.storageOverview: 1...1,
        DsmAPIName.storageSmart: 1...1,
        DsmAPIName.storageVolume: 1...1,
        DsmAPIName.coreStorageDisk: 1...1,
        DsmAPIName.corePackage: 1...2,
        DsmAPIName.corePackageControl: 1...1,
        DsmAPIName.corePackageUninstallation: 1...1,
        DsmAPIName.corePackageThumb: 1...1,
        DsmAPIName.coreTaskScheduler: 1...4,
        DsmAPIName.coreEventScheduler: 1...1,
        DsmAPIName.coreUpgradeServer: 1...4,
        DsmAPIName.coreUser: 1...1,
        DsmAPIName.coreGroup: 1...1,
        DsmAPIName.coreCurrentConnection: 1...1,
        DsmAPIName.coreSystemLog: 1...1,
        DsmAPIName.logCenterHistory: 1...1,
        DsmAPIName.coreTerminal: 1...3,
        DsmAPIName.coreFileServiceSMB: 1...3,
        DsmAPIName.coreFileServiceNFS: 1...3,
        DsmAPIName.coreFileServiceFTP: 1...1,
        DsmAPIName.coreFileServiceSFTP: 1...1,
        DsmAPIName.coreNetworkProxy: 1...1,
        DsmAPIName.coreHardwarePowerRecovery: 1...1,
        DsmAPIName.coreHardwareZRAM: 1...1,
        // 静态目录尚未给出版本矩阵；客户端仅接受最小 v1 范围并要求运行时发现。
        DsmAPIName.coreHardwarePowerSchedule: 1...1,
        DsmAPIName.coreExternalStorageUSB: 1...1,
        DsmAPIName.coreExternalStorageESATA: 1...1,
        DsmAPIName.coreHardwareLEDBrightness: 1...1,
        DsmAPIName.coreHardwareFanSpeed: 1...1,
        DsmAPIName.coreHardwareBeepControl: 1...1,
        DsmAPIName.coreHardwareHibernation: 1...1,
        DsmAPIName.coreQuickConnect: 1...3,
        DsmAPIName.coreQuickConnectUPnP: 1...1,
        DsmAPIName.coreSecurityAutoBlock: 1...1,
        DsmAPIName.coreWebDSM: 1...2,
        DsmAPIName.coreFileServiceDiscovery: 1...1,
        DsmAPIName.coreNetworkEthernet: 1...2,
        DsmAPIName.coreSecurityDoS: 1...2,
        DsmAPIName.coreRegionNTP: 1...3,
        DsmAPIName.coreDDNSProvider: 1...1,
        DsmAPIName.coreDDNSRecord: 1...1,
        DsmAPIName.coreExternalDeviceUPS: 1...1,
        DsmAPIName.coreSecurityFirewall: 1...1,
        DsmAPIName.coreSecurityFirewallConf: 1...1,
        DsmAPIName.coreSecurityFirewallProfileApply: 1...1
    ]
}
