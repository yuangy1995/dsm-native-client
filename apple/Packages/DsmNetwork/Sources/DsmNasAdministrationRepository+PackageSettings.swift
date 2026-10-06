import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadPackageCenterSettings() async throws -> NasPackageCenterSettings {
        let result = try await readPackageCenterSettings()
        if !packageInstallationRequestActive { packageSettingsNeedRefresh = false }
        return result
    }

    func readPackageCenterSettings() async throws -> NasPackageCenterSettings {
        try await readPackagePreferencesSnapshot(management: false).settings
    }

    public func loadPackagePreferencesForManagement() async throws -> NasPackagePreferencesSnapshot {
        let value = try await readPackagePreferencesSnapshot(management: true)
        if !packageInstallationRequestActive { packageSettingsNeedRefresh = false }
        return value
    }

    func readPackagePreferencesSnapshot(management: Bool) async throws -> NasPackagePreferencesSnapshot {
        let value = try await call(DsmAPIName.corePackageSetting, method: "get", version: 1)
        // get 返回布尔开关；set 使用 stable / beta 字符串，两端格式不同。
        guard case .boolean(let betaEnabled)? = value["update_channel"],
              case .boolean(let email)? = value["enable_email"], case .boolean(let desktop)? = value["enable_dsm"],
              case .boolean(let automatic)? = value["enable_autoupdate"], case .boolean(let latest)? = value["autoupdateall"],
              case .boolean(let important)? = value["autoupdateimportant"] else {
            throw packageCenterError("package.center.incomplete")
        }
        let volumes = try packageVolumes(value["volume_list"])
        if management, let volume = value["default_vol"], volume != .null {
            guard case .string = volume else { throw packageCenterError("package.center.incomplete") }
        }
        // 沿用已记录的附加信息组，不把响应中的子字段猜作新的请求选择器。
        var listParameters: [String: DsmParameterValue] = ["additional": .stringArray(["silent_upgrade", "autoupdate", "status"])]
        if management { listParameters["offset"] = .integer(0); listParameters["limit"] = .integer(1_000) }
        let packageResponse = try await call(DsmAPIName.corePackage, method: "list", version: 2, parameters: listParameters)
        guard let packages = packageResponse["packages"]?.array else { throw packageCenterError("package.center.incomplete") }
        if management {
            guard packages.count < 1_000 else { throw packageCenterError("package.center.incomplete") }
            if let total = packageResponse["total"], total != .null {
                guard case .number(let count) = total, Int(exactly: count) == packages.count else { throw packageCenterError("package.center.incomplete") }
            }
        }
        var seen = Set<String>()
        var unknownUpdateIDs: Set<String> = []
        let preferences = try packages.map { package -> NasPackageUpdatePreference in
            guard let id = package.string(["id"]), let name = package.string(["name"]), seen.insert(id).inserted,
                  let info = package["additional"] else { throw packageCenterError("package.center.incomplete") }
            if management {
                guard case .string(let rawID)? = package["id"], !rawID.isEmpty,
                      case .string? = package["name"], info.object != nil else { throw packageCenterError("package.center.incomplete") }
                for key in ["autoupdate", "autoupdate_important", "silent_upgrade"] {
                    if let value = info[key], value != .null, case .boolean = value {} else if info[key] != nil && info[key] != .null {
                        throw packageCenterError("package.center.incomplete")
                    }
                }
                for key in ["status", "limit_type"] {
                    if let value = info[key], value != .null, case .string = value {} else if info[key] != nil && info[key] != .null {
                        throw packageCenterError("package.center.incomplete")
                    }
                }
                if info["autoupdate"] != .boolean(true), info.boolean(["autoupdate"]) == nil || info.boolean(["autoupdate_important"]) == nil { unknownUpdateIDs.insert(id) }
            }
            let latest = info.boolean(["autoupdate"]) == true
            let important = info.boolean(["autoupdate_important"]) == true
            let status = info.string(["status"]), limit = info.string(["limit_type"])
            let canUpdate = info.boolean(["silent_upgrade"]) == true
                && (status != "version_limit" || (limit != "non" && limit != "system"))
            return NasPackageUpdatePreference(id: id, name: name, canUpdateAutomatically: canUpdate,
                policy: latest ? .latest : important ? .important : .manual)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let defaultVolume = value.string(["default_vol"]) ?? "no_default_vol"
        let settings = NasPackageCenterSettings(betaEnabled: betaEnabled, emailNotifications: email,
            desktopNotifications: desktop, updatePolicy: !automatic ? .manual : latest ? .latest : important ? .important : .selected,
            defaultVolumeID: defaultVolume == "no_default_vol" ? "" : defaultVolume, volumes: volumes, packageUpdates: preferences)
        return .init(settings: settings, unknownUpdateIDs: unknownUpdateIDs)
    }

    public func savePackageCenterSettings(_ settings: NasPackageCenterSettings, replacing baseline: NasPackageCenterSettings) async throws -> NasPackageCenterSettings {
        try await savePackageCenterSettings(settings, replacing: baseline, expectedUnknownIDs: nil, checkpoint: nil)
    }
    func savePackageCenterSettings(_ settings: NasPackageCenterSettings, replacing baseline: NasPackageCenterSettings,
        expectedUnknownIDs: Set<String>?, checkpoint: (@Sendable (NasPackagePreferenceCheckpoint) async throws -> Void)?) async throws -> NasPackageCenterSettings {
        try requirePackageInstallationIdle()
        guard !packageSettingsNeedRefresh else { throw packageCenterError("package.center.settings-unverified") }
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        let snapshot = try await readPackagePreferencesSnapshot(management: expectedUnknownIDs != nil)
        if let expectedUnknownIDs {
            guard snapshot.unknownUpdateIDs == expectedUnknownIDs, snapshot.canSave(settings) else { throw packageCenterError("package.center.changed") }
        }
        let current = snapshot.settings
        guard current == baseline, settings.volumes == baseline.volumes,
              settings.defaultVolumeID.isEmpty || current.volumes.contains(where: { $0.id == settings.defaultVolumeID }),
              Set(settings.packageUpdates.map(\.id)) == Set(current.packageUpdates.map(\.id)),
              settings.packageUpdates.count == current.packageUpdates.count else { throw packageCenterError("package.center.changed") }
        for preference in settings.packageUpdates {
            guard let old = current.packageUpdates.first(where: { $0.id == preference.id }),
                  old.canUpdateAutomatically || old.policy == preference.policy else { throw packageCenterError("package.center.changed") }
        }
        if settings == baseline { return current }
        var parameters: [String: DsmParameterValue] = ["update_channel": .string(settings.betaEnabled ? "beta" : "stable"),
            "enable_email": .boolean(settings.emailNotifications), "enable_dsm": .boolean(settings.desktopNotifications),
            "enable_autoupdate": .boolean(settings.updatePolicy != .manual), "autoupdateall": .boolean(settings.updatePolicy == .latest),
            "autoupdateimportant": .boolean(settings.updatePolicy == .important)]
        if settings.defaultVolumeID != baseline.defaultVolumeID { parameters["default_vol"] = .string(settings.defaultVolumeID.isEmpty ? "no_default_vol" : settings.defaultVolumeID) }
        if settings.updatePolicy == .selected {
            let latest = settings.packageUpdates.filter { $0.policy == .latest }.map(\.id)
            let important = settings.packageUpdates.filter { $0.policy == .important }.map(\.id)
            parameters["packages"] = .string(String(decoding: try JSONEncoder().encode(latest), as: UTF8.self))
            parameters["packages_important"] = .string(String(decoding: try JSONEncoder().encode(important), as: UTF8.self))
        }
        try Task.checkCancellation()
        try await checkpoint?(.willSubmit)
        try Task.checkCancellation()
        packageSettingsNeedRefresh = true
        do {
            try await callVoid(DsmAPIName.corePackageSetting, method: "set", version: 1, parameters: parameters)
            try await checkpoint?(.accepted)
            let actualSnapshot = try await readPackagePreferencesSnapshot(management: expectedUnknownIDs != nil)
            let actual = actualSnapshot.settings
            if expectedUnknownIDs != nil, !actualSnapshot.matches(settings) { throw packageCenterError("package.center.settings-unverified") }
            guard actual.betaEnabled == settings.betaEnabled, actual.emailNotifications == settings.emailNotifications,
                  actual.desktopNotifications == settings.desktopNotifications, actual.updatePolicy == settings.updatePolicy,
                  actual.defaultVolumeID == settings.defaultVolumeID,
                  expectedUnknownIDs != nil || settings.updatePolicy != .selected || actual.packageUpdates == settings.packageUpdates else {
                throw packageCenterError("package.center.settings-unverified")
            }
            packageSettingsNeedRefresh = false
            return actual
        } catch {
            if checkpoint != nil, Self.packagePreferenceTrustFailure(error) { throw error }
            if let appError = error as? AppError, appError.dsmCode != nil { packageSettingsNeedRefresh = false; throw appError }
            throw packageCenterError("package.center.settings-unverified", category: .unknown)
        }
    }

    public func loadPackageSources() async throws -> [NasPackageSource] {
        let sources = try await readPackageSources()
        if !packageInstallationRequestActive { packageSourcesNeedRefresh = false }
        return sources
    }
    func readPackageSources() async throws -> [NasPackageSource] {
        try await readPackageSources(management: false)
    }
    public func loadPackageSourcesForManagement() async throws -> [NasPackageSource] {
        let value = try await readPackageSources(management: true)
        if !packageInstallationRequestActive { packageSourcesNeedRefresh = false }
        return value
    }
    func readPackageSources(management: Bool) async throws -> [NasPackageSource] {
        let value = try await call(DsmAPIName.corePackageFeed, method: "list", version: 1)
        guard let rows = value["items"]?.array else { throw packageCenterError("package.center.incomplete") }
        if management, let total = value["total"], total != .null {
            guard case .number(let count) = total, Int(exactly: count) == rows.count else { throw packageCenterError("package.center.incomplete") }
        }
        var seen = Set<String>()
        return try rows.map { row in
            guard let name = row.string(["name"]), let url = row.string(["feed"]), seen.insert(url).inserted else {
                throw packageCenterError("package.center.incomplete")
            }
            if management {
                guard case .string? = row["name"], case .string? = row["feed"], !name.isEmpty, !url.isEmpty else { throw packageCenterError("package.center.incomplete") }
            }
            return NasPackageSource(name: name, url: url)
        }.sorted { $0.url < $1.url }
    }
    public func savePackageSource(_ source: NasPackageSource, replacing baseline: NasPackageSource?) async throws -> [NasPackageSource] {
        try await savePackageSource(source, replacing: baseline, checkpoint: nil)
    }
    func savePackageSource(_ source: NasPackageSource, replacing baseline: NasPackageSource?,
        checkpoint: (@Sendable (NasPackagePreferenceCheckpoint) async throws -> Void)?) async throws -> [NasPackageSource] {
        try requirePackageInstallationIdle()
        guard !packageSourcesNeedRefresh else { throw packageCenterError("package.center.settings-unverified") }
        guard let target = source.normalizedForEditing else { throw packageCenterError("package.center.source-invalid") }
        let name = target.name, address = target.url
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        let current = try await readPackageSources(management: checkpoint != nil)
        if let baseline, !current.contains(baseline) { throw packageCenterError("package.center.changed") }
        guard !current.contains(where: { ($0.url == address || $0.name == name) && $0.id != baseline?.id }) else { throw packageCenterError("package.center.source-duplicate") }
        if target == baseline { return current }
        var fields: [String: String] = ["name": name, "feed": address]
        if let baseline { fields["orifeed"] = baseline.url }
        let list = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        return try await performPackageSourceWrite(method: baseline == nil ? "add" : "set", list: list, checkpoint: checkpoint) { actual in
            actual.contains(target) && (baseline == nil || baseline?.url == target.url || !actual.contains(where: { $0.id == baseline?.id }))
        }
    }
    public func deletePackageSource(_ source: NasPackageSource) async throws -> [NasPackageSource] {
        try await deletePackageSource(source, checkpoint: nil)
    }
    func deletePackageSource(_ source: NasPackageSource,
        checkpoint: (@Sendable (NasPackagePreferenceCheckpoint) async throws -> Void)?) async throws -> [NasPackageSource] {
        try requirePackageInstallationIdle()
        guard !packageSourcesNeedRefresh else { throw packageCenterError("package.center.settings-unverified") }
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        let current = try await readPackageSources(management: checkpoint != nil)
        guard current.contains(source) else { throw packageCenterError("package.center.changed") }
        let list = String(decoding: try JSONEncoder().encode([source.url]), as: UTF8.self)
        return try await performPackageSourceWrite(method: "delete", list: list, checkpoint: checkpoint) { actual in !actual.contains(where: { $0.id == source.id }) }
    }
    private func performPackageSourceWrite(method: String, list: String,
        checkpoint: (@Sendable (NasPackagePreferenceCheckpoint) async throws -> Void)?,
        matches: ([NasPackageSource]) -> Bool) async throws -> [NasPackageSource] {
        try Task.checkCancellation()
        try await checkpoint?(.willSubmit)
        try Task.checkCancellation()
        packageSourcesNeedRefresh = true
        do {
            try await callVoid(DsmAPIName.corePackageFeed, method: method, version: 1, parameters: ["list": .string(list)])
            try await checkpoint?(.accepted)
            let actual = try await readPackageSources(management: checkpoint != nil)
            guard matches(actual) else { throw packageCenterError("package.center.settings-unverified") }
            packageSourcesNeedRefresh = false
            return actual
        } catch {
            if checkpoint != nil, Self.packagePreferenceTrustFailure(error) { throw error }
            if let appError = error as? AppError, appError.dsmCode != nil { packageSourcesNeedRefresh = false; throw appError }
            throw packageCenterError("package.center.settings-unverified", category: .unknown)
        }
    }
    nonisolated static func packagePreferenceTrustFailure(_ error: Error) -> Bool {
        error is DsmCertificateTrustError || (error as? AppError).map { [.tlsUntrusted, .tlsCertificateChanged].contains($0.category) } == true
    }
}
