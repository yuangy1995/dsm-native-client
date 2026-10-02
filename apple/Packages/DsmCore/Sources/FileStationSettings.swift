import Foundation

public enum FileStationAccessScope: String, CaseIterable, Codable, Sendable { case administrators = "admin", everyone, selected = "per_user" }
public enum FileStationMountAccessScope: String, CaseIterable, Codable, Sendable { case administrators = "admin", everyone = "all", selected = "custom" }
public enum FileStationBandwidthPolicy: String, CaseIterable, Codable, Sendable { case disabled, enabled, scheduled }

public struct FileStationPolicyAccountID: Hashable, Comparable, Sendable {
    public let kind: FileStationPrincipal.Kind
    public let value: Int
    public init(kind: FileStationPrincipal.Kind, value: Int) { self.kind = kind; self.value = value }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.kind == rhs.kind ? lhs.value < rhs.value : lhs.kind.rawValue < rhs.kind.rawValue
    }
}
public struct FileStationPolicyAccount: Identifiable, Equatable, Sendable {
    public let id: FileStationPolicyAccountID
    public let name: String
    public let isAdministrator: Bool
    public init(id: FileStationPolicyAccountID, name: String, isAdministrator: Bool) {
        self.id = id; self.name = name; self.isAdministrator = isAdministrator
    }
}
public struct FileStationPolicyAccountPage: Sendable {
    public let items: [FileStationPolicyAccount]
    public let total: Int
    public let nextOffset: Int
    public init(items: [FileStationPolicyAccount], total: Int, nextOffset: Int) {
        self.items = items; self.total = total; self.nextOffset = nextOffset
    }
}

public struct FileStationSettings: Equatable, Sendable {
    public let profileID: UUID
    public var recordsTransfers: Bool
    public var usesDefaultPermissions: Bool
    public var showsAccounts: Bool
    public var sharing: FileStationAccessScope
    public var fileRequests: FileStationAccessScope
    public var remoteMounts: FileStationAccessScope
    public var isoMounts: FileStationAccessScope
    public var sharingAccounts: Set<FileStationPolicyAccountID>
    public var requestAccounts: Set<FileStationPolicyAccountID>
    public var defaultLinkLimit: Int
    public var bandwidth: FileStationBandwidthPolicy
    public var schedule: String
    public var usesCustomSharingPage: Bool?
    public init(profileID: UUID, recordsTransfers: Bool, usesDefaultPermissions: Bool, showsAccounts: Bool,
                sharing: FileStationAccessScope, fileRequests: FileStationAccessScope, remoteMounts: FileStationAccessScope,
                isoMounts: FileStationAccessScope, sharingAccounts: Set<FileStationPolicyAccountID>, requestAccounts: Set<FileStationPolicyAccountID>,
                defaultLinkLimit: Int, bandwidth: FileStationBandwidthPolicy, schedule: String, usesCustomSharingPage: Bool? = nil) {
        self.profileID = profileID; self.recordsTransfers = recordsTransfers; self.usesDefaultPermissions = usesDefaultPermissions
        self.showsAccounts = showsAccounts; self.sharing = sharing; self.fileRequests = fileRequests
        self.remoteMounts = remoteMounts; self.isoMounts = isoMounts; self.sharingAccounts = sharingAccounts
        self.requestAccounts = requestAccounts; self.defaultLinkLimit = defaultLinkLimit; self.bandwidth = bandwidth; self.schedule = schedule
        self.usesCustomSharingPage = usesCustomSharingPage
    }
}

public struct FileStationBandwidthEntry: Identifiable, Equatable, Sendable {
    public enum OwnerType: String, CaseIterable, Codable, Sendable {
        case localUser = "local_user", localGroup = "local_group", ldapUser = "ldap_user", ldapGroup = "ldap_group"
        case domainUser = "domain_user", domainGroup = "domain_group"
    }
    public let profileID: UUID
    public let name: String
    public let ownerType: OwnerType
    public var policy: FileStationBandwidthPolicy
    public var schedule: String
    public var uploadLimit: Int
    public var downloadLimit: Int
    public var alternateUploadLimit: Int
    public var alternateDownloadLimit: Int
    public var id: String { ownerType.rawValue + ":" + name }
    public init(profileID: UUID, name: String, ownerType: OwnerType, policy: FileStationBandwidthPolicy, schedule: String,
                uploadLimit: Int, downloadLimit: Int, alternateUploadLimit: Int, alternateDownloadLimit: Int) {
        self.profileID = profileID; self.name = name; self.ownerType = ownerType; self.policy = policy; self.schedule = schedule
        self.uploadLimit = uploadLimit; self.downloadLimit = downloadLimit
        self.alternateUploadLimit = alternateUploadLimit; self.alternateDownloadLimit = alternateDownloadLimit
    }
}
public struct FileStationBandwidthPage: Sendable {
    public let items: [FileStationBandwidthEntry]
    public let total: Int
    public let nextOffset: Int
    public init(items: [FileStationBandwidthEntry], total: Int, nextOffset: Int) { self.items = items; self.total = total; self.nextOffset = nextOffset }
}

public struct FileStationSharingTheme: Equatable, Sendable {
    public enum LogoPosition: String, CaseIterable, Codable, Sendable { case topRight = "rightup", topLeft = "leftup", bottomRight = "rightbottom", bottomLeft = "leftbottom" }
    public enum BackgroundPosition: String, CaseIterable, Codable, Sendable { case center, fill, fit, stretch, tile }
    public let profileID: UUID
    public var customLogo: Bool
    public var customBackground: Bool
    public var logoPosition: LogoPosition
    public var backgroundPosition: BackgroundPosition
    public var backgroundColor: String
    public var footer: String
    public var footerUsesHTML: Bool
    public let logoSequence: String?
    public let backgroundSequence: String?
    public var logoImage: FileStationThemeImage?
    public var backgroundImage: FileStationThemeImage?
    public init(profileID: UUID, customLogo: Bool, customBackground: Bool, logoPosition: LogoPosition,
                backgroundPosition: BackgroundPosition, backgroundColor: String, footer: String, footerUsesHTML: Bool,
                logoSequence: String? = nil, backgroundSequence: String? = nil,
                logoImage: FileStationThemeImage? = nil, backgroundImage: FileStationThemeImage? = nil) {
        self.profileID = profileID; self.customLogo = customLogo; self.customBackground = customBackground
        self.logoPosition = logoPosition; self.backgroundPosition = backgroundPosition; self.backgroundColor = backgroundColor
        self.footer = footer; self.footerUsesHTML = footerUsesHTML
        self.logoSequence = logoSequence; self.backgroundSequence = backgroundSequence
        self.logoImage = logoImage; self.backgroundImage = backgroundImage
    }
}

public enum FileStationSettingsChange: Equatable, Sendable {
    case general(baseline: FileStationSettings, updated: FileStationSettings)
    case mountAccess(baseline: FileStationMountAccessScope, updated: FileStationMountAccessScope, profileID: UUID)
    case mountAccount(baseline: FileStationMountAccount, enabled: Bool)
    case bandwidth(baseline: FileStationBandwidthEntry, updated: FileStationBandwidthEntry)
    case theme(baseline: FileStationSharingTheme, updated: FileStationSharingTheme)
}

/// 目录来源只用于读取名单与绑定确认快照；保存仍提交 NAS 返回的 uid/gid。
public enum FileStationMountAccountSource: Hashable, Sendable {
    case local, ldap, domain(String)
    public var type: String { switch self { case .local: "local"; case .ldap: "ldap"; case .domain: "domain" } }
    public var id: String { switch self { case .domain(let value): "domain:" + value; default: type } }
}
public struct FileStationMountDirectory: Identifiable, Equatable, Sendable {
    public let source: FileStationMountAccountSource
    public let name: String
    public var id: String { source.id }
    public init(source: FileStationMountAccountSource, name: String) { self.source = source; self.name = name }
}
public struct FileStationMountDirectories: Sendable {
    public let items: [FileStationMountDirectory]
    public let hasUnavailableSources: Bool
    public init(items: [FileStationMountDirectory], hasUnavailableSources: Bool) {
        self.items = items; self.hasUnavailableSources = hasUnavailableSources
    }
}

public struct FileStationMountAccount: Identifiable, Equatable, Sendable {
    public let profileID: UUID
    public let source: FileStationMountAccountSource
    public let id: FileStationPolicyAccountID
    public let name: String
    public let enabled: Bool
    public let canModify: Bool
    public init(profileID: UUID, id: FileStationPolicyAccountID, name: String, enabled: Bool, canModify: Bool, source: FileStationMountAccountSource = .local) {
        self.source = source; self.profileID = profileID; self.id = id; self.name = name; self.enabled = enabled; self.canModify = canModify
    }
}
public struct FileStationMountAccountPage: Sendable {
    public let items: [FileStationMountAccount]
    public let total: Int
    public let nextOffset: Int
    public init(items: [FileStationMountAccount], total: Int, nextOffset: Int) {
        self.items = items; self.total = total; self.nextOffset = nextOffset
    }
}

public enum FileStationWeeklySchedule {
    /// 官方时间表按星期日至星期六、每天 0…23 时排列；0 不限速，1 默认限速，2 自定义限速。
    public static func isValid(_ value: String, perAccount: Bool) -> Bool {
        value.utf8.count == 168 && value.utf8.allSatisfy { (48...(perAccount ? 50 : 49)).contains($0) }
    }
    public static func index(day: Int, hour: Int) -> Int? {
        guard (0..<7).contains(day), (0..<24).contains(hour) else { return nil }
        return day * 24 + hour
    }
}
