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
        let value = try await call(DsmAPIName.corePackageSetting, method: "get", version: 1)
        // get 返回布尔开关；set 使用 stable / beta 字符串，两端格式不同。
        guard case .boolean(let betaEnabled)? = value["update_channel"],
              case .boolean(let email)? = value["enable_email"], case .boolean(let desktop)? = value["enable_dsm"],
              case .boolean(let automatic)? = value["enable_autoupdate"], case .boolean(let latest)? = value["autoupdateall"],
              case .boolean(let important)? = value["autoupdateimportant"] else {
            throw packageCenterError("package.center.incomplete")
        }
        let volumes = try packageVolumes(value["volume_list"])
        let packageResponse = try await call(DsmAPIName.corePackage, method: "list", version: 2,
            parameters: ["additional": .stringArray(["silent_upgrade", "autoupdate", "status"])])
        guard let packages = packageResponse["packages"]?.array else { throw packageCenterError("package.center.incomplete") }
        var seen = Set<String>()
        let preferences = try packages.map { package -> NasPackageUpdatePreference in
            guard let id = package.string(["id"]), let name = package.string(["name"]), seen.insert(id).inserted,
                  let info = package["additional"] else { throw packageCenterError("package.center.incomplete") }
            let latest = info.boolean(["autoupdate"]) == true
            let important = info.boolean(["autoupdate_important"]) == true
            let status = info.string(["status"]), limit = info.string(["limit_type"])
            let canUpdate = info.boolean(["silent_upgrade"]) == true
                && (status != "version_limit" || (limit != "non" && limit != "system"))
            return NasPackageUpdatePreference(id: id, name: name, canUpdateAutomatically: canUpdate,
                policy: latest ? .latest : important ? .important : .manual)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let defaultVolume = value.string(["default_vol"]) ?? "no_default_vol"
        return NasPackageCenterSettings(betaEnabled: betaEnabled, emailNotifications: email,
            desktopNotifications: desktop, updatePolicy: !automatic ? .manual : latest ? .latest : important ? .important : .selected,
            defaultVolumeID: defaultVolume == "no_default_vol" ? "" : defaultVolume, volumes: volumes, packageUpdates: preferences)
    }

    public func savePackageCenterSettings(_ settings: NasPackageCenterSettings, replacing baseline: NasPackageCenterSettings) async throws -> NasPackageCenterSettings {
        try requirePackageInstallationIdle()
        guard !packageSettingsNeedRefresh else { throw packageCenterError("package.center.settings-unverified") }
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        let current = try await readPackageCenterSettings()
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
        packageSettingsNeedRefresh = true
        do {
            try await callVoid(DsmAPIName.corePackageSetting, method: "set", version: 1, parameters: parameters)
            let actual = try await readPackageCenterSettings()
            guard actual.betaEnabled == settings.betaEnabled, actual.emailNotifications == settings.emailNotifications,
                  actual.desktopNotifications == settings.desktopNotifications, actual.updatePolicy == settings.updatePolicy,
                  actual.defaultVolumeID == settings.defaultVolumeID,
                  settings.updatePolicy != .selected || actual.packageUpdates == settings.packageUpdates else {
                throw packageCenterError("package.center.settings-unverified")
            }
            packageSettingsNeedRefresh = false
            return actual
        } catch {
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
        let value = try await call(DsmAPIName.corePackageFeed, method: "list", version: 1)
        guard let rows = value["items"]?.array else { throw packageCenterError("package.center.incomplete") }
        var seen = Set<String>()
        return try rows.map { row in
            guard let name = row.string(["name"]), let url = row.string(["feed"]), seen.insert(url).inserted else {
                throw packageCenterError("package.center.incomplete")
            }
            return NasPackageSource(name: name, url: url)
        }.sorted { $0.url < $1.url }
    }
    public func savePackageSource(_ source: NasPackageSource, replacing baseline: NasPackageSource?) async throws -> [NasPackageSource] {
        try requirePackageInstallationIdle()
        guard !packageSourcesNeedRefresh else { throw packageCenterError("package.center.settings-unverified") }
        let name = source.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let address = source.url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let url = URLComponents(string: address), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil else {
            throw packageCenterError("package.center.source-invalid")
        }
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        let current = try await readPackageSources()
        if let baseline, !current.contains(baseline) { throw packageCenterError("package.center.changed") }
        guard !current.contains(where: { ($0.url == address || $0.name == name) && $0.id != baseline?.id }) else { throw packageCenterError("package.center.source-duplicate") }
        let target = NasPackageSource(name: name, url: address)
        if target == baseline { return current }
        var fields: [String: String] = ["name": name, "feed": address]
        if let baseline { fields["orifeed"] = baseline.url }
        let list = String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
        return try await performPackageSourceWrite(method: baseline == nil ? "add" : "set", list: list) { actual in
            actual.contains(target) && (baseline == nil || baseline?.url == target.url || !actual.contains(where: { $0.id == baseline?.id }))
        }
    }
    public func deletePackageSource(_ source: NasPackageSource) async throws -> [NasPackageSource] {
        try requirePackageInstallationIdle()
        guard !packageSourcesNeedRefresh else { throw packageCenterError("package.center.settings-unverified") }
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        let current = try await readPackageSources()
        guard current.contains(source) else { throw packageCenterError("package.center.changed") }
        let list = String(decoding: try JSONEncoder().encode([source.url]), as: UTF8.self)
        return try await performPackageSourceWrite(method: "delete", list: list) { actual in !actual.contains(where: { $0.id == source.id }) }
    }
    private func performPackageSourceWrite(method: String, list: String,
        matches: ([NasPackageSource]) -> Bool) async throws -> [NasPackageSource] {
        try Task.checkCancellation()
        packageSourcesNeedRefresh = true
        do {
            try await callVoid(DsmAPIName.corePackageFeed, method: method, version: 1, parameters: ["list": .string(list)])
            let actual = try await readPackageSources()
            guard matches(actual) else { throw packageCenterError("package.center.settings-unverified") }
            packageSourcesNeedRefresh = false
            return actual
        } catch {
            if let appError = error as? AppError, appError.dsmCode != nil { packageSourcesNeedRefresh = false; throw appError }
            throw packageCenterError("package.center.settings-unverified", category: .unknown)
        }
    }
}
