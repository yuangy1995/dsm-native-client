import Foundation

/// 管理快照保留未知的单套件策略，不能把缺失字段当作手动更新后覆盖整表。
public struct NasPackagePreferencesSnapshot: Equatable, Sendable {
    public let settings: NasPackageCenterSettings
    public let unknownUpdateIDs: Set<String>
    public init(settings: NasPackageCenterSettings, unknownUpdateIDs: Set<String> = []) {
        self.settings = settings; self.unknownUpdateIDs = unknownUpdateIDs
    }
    public func canSave(_ desired: NasPackageCenterSettings) -> Bool {
        desired.volumes == settings.volumes
            && (desired.defaultVolumeID.isEmpty || settings.volumes.contains { $0.id == desired.defaultVolumeID })
            && desired.packageUpdates.count == settings.packageUpdates.count
            && Set(desired.packageUpdates.map(\.id)) == Set(settings.packageUpdates.map(\.id))
            && (desired.updatePolicy != .selected || unknownUpdateIDs.isEmpty)
            && desired.packageUpdates.allSatisfy { value in
                settings.packageUpdates.contains { $0.id == value.id && ($0.canUpdateAutomatically || $0.policy == value.policy) }
            }
    }
    public func matches(_ desired: NasPackageCenterSettings) -> Bool {
        guard desired.betaEnabled == settings.betaEnabled, desired.emailNotifications == settings.emailNotifications,
              desired.desktopNotifications == settings.desktopNotifications, desired.updatePolicy == settings.updatePolicy,
              desired.defaultVolumeID == settings.defaultVolumeID else { return false }
        guard desired.updatePolicy == .selected else { return true }
        let expected = desired.packageUpdates.filter { $0.policy != .manual }, actual = settings.packageUpdates.filter { $0.policy != .manual }
        // 保存的是两个自动更新清单；新出现且仍手动更新的套件不改变该选择。
        return unknownUpdateIDs.isEmpty && expected.count == actual.count
            && expected.allSatisfy { value in actual.contains { $0.id == value.id && $0.policy == value.policy } }
    }
}

public enum NasPackagePreferenceKind: String, Codable, Sendable { case settings, saveSource, removeSource }
public enum NasPackagePreferenceCheckpoint: Equatable, Sendable { case willSubmit, accepted }
public enum NasPackagePreferenceChange: Equatable, Sendable {
    case settings(original: NasPackagePreferencesSnapshot, desired: NasPackageCenterSettings)
    case saveSource(NasPackageSource, replacing: NasPackageSource?)
    case removeSource(NasPackageSource)

    public var kind: NasPackagePreferenceKind {
        switch self { case .settings: .settings; case .saveSource: .saveSource; case .removeSource: .removeSource }
    }
    public var isValid: Bool {
        switch self {
        case .settings(let original, let desired): original.settings != desired && original.canSave(desired)
        case .saveSource(let source, let old): source.normalizedForEditing.map { $0 != old } == true
        case .removeSource(let source): !source.url.isEmpty
        }
    }
    public var enablesAutomaticUpdates: Bool {
        guard case .settings(let original, let desired) = self, desired.updatePolicy != .manual else { return false }
        if original.settings.updatePolicy != desired.updatePolicy { return true }
        return desired.updatePolicy == .selected && desired.packageUpdates.contains { value in
            value.policy != .manual && original.settings.packageUpdates.first { $0.id == value.id }?.policy != value.policy
        }
    }
}

public extension NasPackageSource {
    var normalizedForEditing: NasPackageSource? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines), address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let value = URLComponents(string: address), ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              value.host?.isEmpty == false, value.user == nil, value.password == nil, value.fragment == nil else { return nil }
        return .init(name: name, url: address)
    }
}
