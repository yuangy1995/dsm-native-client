import Foundation
import DsmLocalization

public struct NasPackageCatalogEntry: Identifiable, Equatable, Sendable {
    public var id: String { packageID + (isBeta ? ":beta" : ":stable") }
    public let packageID: String
    public let name: String
    public let version: String
    public let description: String
    public let releaseNotes: String
    public let publisher: String
    public let categories: [String]
    public let isBeta: Bool
    public let isOfficial: Bool
    public let sizeBytes: Int64?
    public let installedVersion: String?
    public let isUpdateAvailable: Bool
    public init(packageID: String, name: String, version: String, description: String = "",
                releaseNotes: String = "", publisher: String = "", categories: [String] = [],
                isBeta: Bool = false, isOfficial: Bool = true, sizeBytes: Int64? = nil,
                installedVersion: String? = nil, isUpdateAvailable: Bool = false) {
        self.packageID = packageID; self.name = name; self.version = version
        self.description = description; self.releaseNotes = releaseNotes; self.publisher = publisher
        self.categories = categories; self.isBeta = isBeta; self.isOfficial = isOfficial
        self.sizeBytes = sizeBytes; self.installedVersion = installedVersion
        self.isUpdateAvailable = isUpdateAvailable
    }
}

public struct NasPackageCategory: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct NasPackageCatalog: Equatable, Sendable {
    public let entries: [NasPackageCatalogEntry]
    public let categories: [NasPackageCategory]
    public let communityAvailable: Bool
    public init(entries: [NasPackageCatalogEntry], categories: [NasPackageCategory] = [], communityAvailable: Bool = true) {
        self.entries = entries; self.categories = categories; self.communityAvailable = communityAvailable
    }
}

public struct NasPackageInstallVolume: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct NasPackageInstallItem: Identifiable, Equatable, Sendable {
    public var id: String { package.id }
    public let package: NasPackageCatalogEntry
    public let volumes: [NasPackageInstallVolume]
    public let defaultVolumeID: String
    public init(package: NasPackageCatalogEntry, volumes: [NasPackageInstallVolume] = [], defaultVolumeID: String = "") {
        self.package = package; self.volumes = volumes; self.defaultVolumeID = defaultVolumeID
    }
}

public struct NasPackageInstallPlan: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let items: [NasPackageInstallItem]
    public let affectedPackages: [String]
    public init(id: UUID = UUID(), items: [NasPackageInstallItem], affectedPackages: [String] = []) {
        self.id = id; self.items = items; self.affectedPackages = affectedPackages
    }
}

public enum NasPackageOptionValue: Equatable, Sendable {
    case text(String)
    case flag(Bool)
}

public struct NasPackageInstallField: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case text, password, toggle, radio, choice, description }
    public let id: String
    public let label: String
    public let kind: Kind
    public let defaultValue: NasPackageOptionValue
    public let choices: [NasPackageCategory]
    public let group: String?
    public let required: Bool
    public let minimumLength: Int?
    public let maximumLength: Int?
    public init(id: String, label: String, kind: Kind, defaultValue: NasPackageOptionValue = .text(""),
                choices: [NasPackageCategory] = [], group: String? = nil, required: Bool = false,
                minimumLength: Int? = nil, maximumLength: Int? = nil) {
        self.id = id; self.label = label; self.kind = kind; self.defaultValue = defaultValue
        self.choices = choices; self.group = group; self.required = required
        self.minimumLength = minimumLength; self.maximumLength = maximumLength
    }
}

public struct NasPackageInstallConfiguration: Equatable, Sendable {
    public let packageName: String
    public let version: String
    public let license: String?
    public let fields: [NasPackageInstallField]
    public let volumes: [NasPackageInstallVolume]
    public let defaultVolumeID: String
    public let canStart: Bool
    public let requiresRestart: Bool
    public init(packageName: String, version: String, license: String? = nil,
                fields: [NasPackageInstallField] = [], volumes: [NasPackageInstallVolume] = [],
                defaultVolumeID: String = "", canStart: Bool = true, requiresRestart: Bool = false) {
        self.packageName = packageName; self.version = version; self.license = license
        self.fields = fields; self.volumes = volumes; self.defaultVolumeID = defaultVolumeID
        self.canStart = canStart; self.requiresRestart = requiresRestart
    }
    public func accepts(_ values: [String: NasPackageOptionValue]) -> Bool {
        guard Set(values.keys).isSubset(of: Set(fields.filter { $0.kind != .description }.map(\.id))) else { return false }
        for field in fields where field.kind != .description {
            let value = values[field.id] ?? field.defaultValue
            switch (field.kind, value) {
            case (.toggle, .flag), (.radio, .flag): break
            case (.text, .text(let text)), (.password, .text(let text)), (.choice, .text(let text)):
                if field.required && text.isEmpty { return false }
                if let minimum = field.minimumLength, text.count < minimum { return false }
                if let maximum = field.maximumLength, text.count > maximum { return false }
                if field.kind == .choice && !field.choices.contains(where: { $0.id == text }) { return false }
            default: return false
            }
        }
        for group in Set(fields.compactMap(\.group)) {
            let selected = fields.filter { $0.group == group && (values[$0.id] ?? $0.defaultValue) == .flag(true) }
            if selected.count != 1 { return false }
        }
        return true
    }
}

public struct NasPackageInstallProgress: Identifiable, Equatable, Sendable {
    public enum Phase: String, Sendable {
        case downloading, installing, needsOptions, completed, failed, unverified, cancelled
        public var isActive: Bool { self == .downloading || self == .installing }
    }
    public let id: UUID
    public let packageName: String
    public let completedCount: Int
    public let totalCount: Int
    public let phase: Phase
    public let fraction: Double?
    public let configuration: NasPackageInstallConfiguration?
    public let messageKey: String?
    public let canCancel: Bool
    public init(id: UUID, packageName: String, completedCount: Int, totalCount: Int, phase: Phase,
                fraction: Double? = nil, configuration: NasPackageInstallConfiguration? = nil, messageKey: String? = nil, canCancel: Bool = false) {
        self.id = id; self.packageName = packageName; self.completedCount = completedCount
        self.totalCount = totalCount; self.phase = phase; self.fraction = fraction
        self.configuration = configuration; self.messageKey = messageKey; self.canCancel = canCancel
    }
}

public extension NasSettingsRepository {
    func loadPackageCatalog() async throws -> NasPackageCatalog { throw packageCenterUnavailable() }
    func preparePackageInstallation(catalogIDs: [String]) async throws -> NasPackageInstallPlan { throw packageCenterUnavailable() }
    func startPackageInstallation(planID: UUID, volumes: [String: String], startAfterInstall: Bool) async throws -> NasPackageInstallProgress { throw packageCenterUnavailable() }
    func advancePackageInstallation(id: UUID) async throws -> NasPackageInstallProgress { throw packageCenterUnavailable() }
    func configurePackageInstallation(id: UUID, volumeID: String, startAfterInstall: Bool, licenseAccepted: Bool, values: [String: NasPackageOptionValue]) async throws -> NasPackageInstallProgress { throw packageCenterUnavailable() }
    func cancelPackageInstallation(id: UUID) async throws -> NasPackageInstallProgress { throw packageCenterUnavailable() }
    func uploadPackageForInstallation(fileURL: URL) async throws -> NasPackageInstallProgress { throw packageCenterUnavailable() }
    private func packageCenterUnavailable() -> AppError {
        AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: L10n.string("package.center.unavailable"))
    }
}

public struct NasPackageUpdatePreference: Identifiable, Equatable, Sendable {
    public enum Policy: String, CaseIterable, Sendable { case manual, important, latest }
    public let id: String
    public let name: String
    public let canUpdateAutomatically: Bool
    public var policy: Policy
    public init(id: String, name: String, canUpdateAutomatically: Bool, policy: Policy) {
        self.id = id; self.name = name; self.canUpdateAutomatically = canUpdateAutomatically; self.policy = policy
    }
}

public struct NasPackageCenterSettings: Equatable, Sendable {
    public enum UpdatePolicy: String, CaseIterable, Sendable { case manual, important, latest, selected }
    public var betaEnabled: Bool
    public var emailNotifications: Bool
    public var desktopNotifications: Bool
    public var updatePolicy: UpdatePolicy
    public var defaultVolumeID: String
    public let volumes: [NasPackageInstallVolume]
    public var packageUpdates: [NasPackageUpdatePreference]
    public init(betaEnabled: Bool, emailNotifications: Bool, desktopNotifications: Bool,
                updatePolicy: UpdatePolicy, defaultVolumeID: String, volumes: [NasPackageInstallVolume],
                packageUpdates: [NasPackageUpdatePreference] = []) {
        self.betaEnabled = betaEnabled; self.emailNotifications = emailNotifications
        self.desktopNotifications = desktopNotifications; self.updatePolicy = updatePolicy
        self.defaultVolumeID = defaultVolumeID; self.volumes = volumes; self.packageUpdates = packageUpdates
    }
}

public struct NasPackageSource: Identifiable, Equatable, Sendable {
    public var id: String { url }
    public var name: String
    public var url: String
    public init(name: String, url: String) { self.name = name; self.url = url }
}

public extension NasSettingsRepository {
    func loadPackageCenterSettings() async throws -> NasPackageCenterSettings { throw packageCenterUnavailable() }
    func savePackageCenterSettings(_ settings: NasPackageCenterSettings, replacing baseline: NasPackageCenterSettings) async throws -> NasPackageCenterSettings { throw packageCenterUnavailable() }
    func loadPackageSources() async throws -> [NasPackageSource] { throw packageCenterUnavailable() }
    func savePackageSource(_ source: NasPackageSource, replacing baseline: NasPackageSource?) async throws -> [NasPackageSource] { throw packageCenterUnavailable() }
    func deletePackageSource(_ source: NasPackageSource) async throws -> [NasPackageSource] { throw packageCenterUnavailable() }
}
