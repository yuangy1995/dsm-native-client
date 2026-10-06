import DsmCore
import DsmLocalization
import Foundation

struct PackageCatalogCandidate: Equatable, Sendable {
    let entry: NasPackageCatalogEntry
    let raw: DsmDynamicJSON
    var quick: Bool {
        entry.isOfficial && raw.boolean([entry.installedVersion == nil ? "qinst" : "qupgrade"]) != false
            && raw["info"]?.boolean(["blqinst"]) != false
    }
}

struct PackageInstallationPlanState: Sendable {
    let plan: NasPackageInstallPlan
    let requestedIDs: [String]
    let candidates: [PackageCatalogCandidate]
    let queue: DsmDynamicJSON
    let installedVersions: [String: String]
}

struct PackageInstallationJobState: Sendable {
    let id: UUID
    let candidates: [PackageCatalogCandidate]
    let items: [NasPackageInstallItem]
    var volumes: [String: String]
    var startAfterInstall: Bool
    var index = 0
    var phase: NasPackageInstallProgress.Phase = .installing
    var taskID: String?
    var fraction: Double?
    var configuration: NasPackageInstallConfiguration?
    var checkedPackage: DsmDynamicJSON?
    var messageKey: String?
    var manual = false
    var finalInstallationSubmitted = false
    var cancelRequested = false
    var isWriteOutcomeUnknown = false
    var checkpoint: NasPackageInstallationObserver?
    var current: PackageCatalogCandidate { candidates[min(index, candidates.count - 1)] }
    var progress: NasPackageInstallProgress {
        NasPackageInstallProgress(id: id, packageName: current.entry.name, completedCount: index,
            totalCount: candidates.count, phase: phase, fraction: fraction, configuration: configuration, messageKey: messageKey,
            canCancel: (checkpoint == nil || !cancelRequested) && (phase == .downloading || phase == .needsOptions || (phase == .unverified && checkedPackage != nil && !finalInstallationSubmitted)))
    }
}

extension DsmNasAdministrationRepository {
    public func loadPackageCatalog() async throws -> NasPackageCatalog { try await loadPackageCatalog(management: false) }
    public func loadPackageCatalogForManagement() async throws -> NasPackageCatalog { try await loadPackageCatalog(management: true) }
    func loadPackageCatalog(management: Bool) async throws -> NasPackageCatalog {
        let installed = try await loadPackages(includingIcons: false, management: management)
        let official = try await call(DsmAPIName.corePackageServer, method: "list", version: 2,
            parameters: ["blforcereload": .boolean(false), "blloadothers": .boolean(false)])
        guard let stable = official["packages"]?.array, let beta = official["beta_packages"]?.array else {
            throw packageCenterError("package.center.incomplete")
        }
        var rows = stable + beta
        // 已配置来源由 NAS 访问，客户端不向目录中的外部地址附带会话或发起下载。
        var communityAvailable = true
        do {
            let others = try await call(DsmAPIName.corePackageServer, method: "list", version: 2,
                parameters: ["blforcereload": .boolean(false), "blloadothers": .boolean(true)])
            guard let community = others["packages"]?.array else { throw packageCenterError("package.center.incomplete") }
            rows += community
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if management, Self.packagePreferenceTrustFailure(error) { throw error }
            // 第三方来源失败不隐藏官方目录；界面单独提示该分类不可用。
            communityAvailable = false
        }
        var candidates: [String: PackageCatalogCandidate] = [:]
        for row in rows {
            let candidate = try packageCandidate(row, installed: installed)
            if let previous = candidates[candidate.entry.id], previous.raw != candidate.raw {
                // 官方源优先，已安装套件的更新元数据在下方按 DSM 的可用操作覆盖。
                if previous.entry.isOfficial { continue }
            }
            candidates[candidate.entry.id] = candidate
        }
        for (id, row) in packageUpgradeCandidates {
            let candidate = try packageCandidate(row, installed: installed, expectedID: id, explicitUpgrade: true)
            candidates[candidate.entry.id] = candidate
        }
        let categories = try (official["categories"]?.array ?? []).map { row -> NasPackageCategory in
            guard let id = row.string(["id"]), let name = row.string(["dname"]) else {
                throw packageCenterError("package.center.incomplete")
            }
            return NasPackageCategory(id: id, name: name)
        }
        packageCatalogCandidates = candidates
        return NasPackageCatalog(entries: candidates.values.map(\.entry).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }, categories: categories, communityAvailable: communityAvailable)
    }

    public func preparePackageInstallation(catalogIDs: [String]) async throws -> NasPackageInstallPlan {
        try await preparePackageInstallation(catalogIDs: catalogIDs, management: false)
    }
    public func preparePackageInstallationForManagement(catalogIDs: [String]) async throws -> NasPackageInstallPlan {
        try await preparePackageInstallation(catalogIDs: catalogIDs, management: true)
    }
    private func preparePackageInstallation(catalogIDs: [String], management: Bool) async throws -> NasPackageInstallPlan {
        try requirePackageInstallationIdle()
        packageInstallationRequestActive = true
        defer { packageInstallationRequestActive = false }
        _ = try await loadPackageCatalog(management: management)
        try Task.checkCancellation()
        let requested = try catalogIDs.map { id -> PackageCatalogCandidate in
            guard let candidate = packageCatalogCandidates[id],
                  candidate.entry.installedVersion == nil || candidate.entry.isUpdateAvailable else {
                throw packageCenterError("package.center.changed")
            }
            return candidate
        }
        guard !requested.isEmpty, Set(catalogIDs).count == catalogIDs.count else {
            throw packageCenterError("package.center.changed")
        }
        let state = try await buildPackageInstallPlan(requested: requested, management: management)
        try Task.checkCancellation()
        packageInstallPlan = state
        return state.plan
    }

    func buildPackageInstallPlan(requested: [PackageCatalogCandidate], management: Bool = false) async throws -> PackageInstallationPlanState {
        if requested.contains(where: { $0.entry.isBeta }) { try await requirePackageBetaAgreement() }
        try await packageInstallFeasibility(requested.map { $0.entry.packageID })
        let queue = try await installationQueue(requested)
        guard let steps = queue["queue"]?.array, !steps.isEmpty else { throw packageCenterError("package.center.incomplete") }
        let missing = try packageStringArray(queue, "non_exist_pkgs")
        let conflicts = try packageStringArray(queue, "conflicted_pkgs", acceptObjects: true)
        guard missing.isEmpty, conflicts.isEmpty else { throw packageCenterError("package.center.dependencies") }
        let affected = try ["broken_pkgs", "replaced_pkgs", "paused_pkgs"].flatMap { try packageStringArray(queue, $0) }
        var candidates: [PackageCatalogCandidate] = []
        var items: [NasPackageInstallItem] = []
        for step in steps {
            try Task.checkCancellation()
            guard let id = step.string(["pkg"]), case .boolean(let beta)? = step["beta"],
                  let candidate = packageCatalogCandidates[id + (beta ? ":beta" : ":stable")],
                  !candidates.contains(where: { $0.entry.packageID == id }) else {
                throw packageCenterError("package.center.incomplete")
            }
            if let version = step.string(["version"]), version != candidate.entry.version {
                throw packageCenterError("package.center.changed")
            }
            candidates.append(candidate)
            items.append(try await packageInstallationEnvironment(candidate))
        }
        guard requested.allSatisfy({ request in candidates.contains(where: { $0.entry.id == request.entry.id }) }) else {
            throw packageCenterError("package.center.incomplete")
        }
        let installed = try await loadPackages(includingIcons: false, management: management)
        return PackageInstallationPlanState(plan: NasPackageInstallPlan(items: items, affectedPackages: Array(Set(affected)).sorted()),
            requestedIDs: requested.map { $0.entry.id }, candidates: candidates, queue: queue,
            installedVersions: Dictionary(uniqueKeysWithValues: installed.map { ($0.id, $0.version ?? "") }))
    }

    func installationQueue(_ candidates: [PackageCatalogCandidate]) async throws -> DsmDynamicJSON {
        try await call(DsmAPIName.corePackageInstallation, method: "get_queue", version: 1,
            parameters: ["pkgs": .objectArray(candidates.map { candidate in
                ["pkg": .string(candidate.entry.packageID), "operation": .string("install"),
                 "version": .string(candidate.entry.version), "beta": .boolean(candidate.entry.isBeta)]
            })])
    }

    func packageInstallationEnvironment(_ candidate: PackageCatalogCandidate) async throws -> NasPackageInstallItem {
        var parameters: [String: DsmParameterValue] = ["id": .string(candidate.entry.packageID),
            "ver": .string(candidate.entry.version), "blupgrade": .boolean(candidate.entry.installedVersion != nil),
            "blCheckDep": .boolean(false)]
        for key in ["depsers", "deppkgs", "conflictpkgs", "breakpkgs", "replacepkgs", "size", "install_type", "install_on_cold_storage"] {
            if let value = candidate.raw[key], let parameter = packageParameter(value) { parameters[key] = parameter }
        }
        let data = try await call(DsmAPIName.corePackageInstallation, method: "check", version: 2, parameters: parameters)
        guard data["is_occupied"] == .boolean(false) else { throw packageCenterError("package.center.busy") }
        let isSystemPackage = ["system", "system_hidden"].contains(candidate.raw.string(["install_type"]) ?? "")
        // 系统套件的安装位置由 DSM 管理，官方检查允许不返回普通存储空间列表。
        let volumes = isSystemPackage && (data["volume_list"] == nil || data["volume_list"] == .null)
            ? [] : try packageVolumes(data["volume_list"])
        let defaultVolume = data.string(["volume_path"]) ?? (volumes.count == 1 ? volumes[0].id : "")
        guard !volumes.isEmpty || isSystemPackage else {
            throw packageCenterError("package.center.no-volume")
        }
        return NasPackageInstallItem(package: candidate.entry, volumes: volumes, defaultVolumeID: defaultVolume)
    }

    func requirePackageBetaAgreement() async throws {
        let info = try await call(DsmAPIName.corePackageInfo, method: "get", version: 1)
        guard info["prerelease"]?["success"] == .boolean(true), info["prerelease"]?["agreed"] == .boolean(true) else {
            throw packageCenterError("package.center.beta-agreement")
        }
    }

    func packageInstallFeasibility(_ ids: [String]) async throws {
        // DSM 的成功预检只有 success，不返回 data；不能把成功当作响应损坏。
        try await callVoid(DsmAPIName.corePackage, method: "feasibility_check", version: 1,
            parameters: ["type": .string("install_check"), "packages": .stringArray(ids)])
    }

    func packageCandidate(_ raw: DsmDynamicJSON, installed: [NasPackage], expectedID: String? = nil,
                          explicitUpgrade: Bool = false) throws -> PackageCatalogCandidate {
        guard let id = raw.string(["id"]), !id.isEmpty, id == (expectedID ?? id),
              let name = raw.string(["dname", "name"]), let version = raw.string(["version"]), !version.isEmpty,
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw packageCenterError("package.center.incomplete")
        }
        let current = installed.first { $0.id == id }
        let entry = NasPackageCatalogEntry(packageID: id, name: name, version: version,
            description: raw.string(["desc", "description"]) ?? "", releaseNotes: raw.string(["changelog"]) ?? "",
            publisher: raw.string(["distributor", "maintainer"]) ?? "", categories: raw.strings(["category"]),
            isBeta: raw.boolean(["beta"]) == true, isOfficial: raw.string(["source"]) == "syno",
            sizeBytes: packageInteger(raw["size"]), installedVersion: current?.version,
            isUpdateAvailable: current != nil && current?.version != version && explicitUpgrade)
        return PackageCatalogCandidate(entry: entry, raw: raw)
    }

    func packageVolumes(_ value: DsmDynamicJSON?) throws -> [NasPackageInstallVolume] {
        guard let rows = value?.array else { throw packageCenterError("package.center.incomplete") }
        var seen = Set<String>()
        return try rows.map { row in
            guard let id = row.string(["mount_point"]), let name = row.string(["display"]), seen.insert(id).inserted else {
                throw packageCenterError("package.center.incomplete")
            }
            return NasPackageInstallVolume(id: id, name: name)
        }
    }

    func packageStringArray(_ data: DsmDynamicJSON, _ key: String, acceptObjects: Bool = false) throws -> [String] {
        guard let values = data[key]?.array else { throw packageCenterError("package.center.incomplete") }
        return try values.map { value in
            if case .string(let text) = value { return text }
            if acceptObjects, value.object != nil { return key }
            throw packageCenterError("package.center.incomplete")
        }
    }

    func requirePackageInstallationIdle() throws {
        guard !packageInstallationRequestActive, activePackageMutationIDs.isEmpty,
              packageInstallJob == nil || [.completed, .failed, .cancelled].contains(packageInstallJob!.phase) else {
            throw packageCenterError("package.center.busy")
        }
    }

    func packageCenterError(_ key: String, category: AppErrorCategory = .invalidResponse) -> AppError {
        AppError(category: category, isRetryable: false, safeUserMessage: L10n.string(key))
    }

    func packageInteger(_ value: DsmDynamicJSON?) -> Int64? {
        guard case .number(let number) = value, let integer = Int64(exactly: number), integer >= 0 else { return nil }
        return integer
    }

    func packageInstallType(_ data: DsmDynamicJSON) throws -> Int {
        guard let raw = data["type"], raw != .null else { return 0 }
        guard let value = packageInteger(raw), let integer = Int(exactly: value) else { throw packageCenterError("package.center.incomplete") }
        return integer
    }

    func packageParameter(_ value: DsmDynamicJSON) -> DsmParameterValue? {
        switch value {
        case .string(let text): .string(text)
        case .boolean(let flag): .boolean(flag)
        case .number(let number): Int(exactly: number).map(DsmParameterValue.integer)
        case .object(let object): .object(object.mapValues(packageJSON))
        case .array(let values) where values.allSatisfy({ $0.object != nil }): .objectArray(values.map { $0.object!.mapValues(packageJSON) })
        default: nil
        }
    }

    func packageJSON(_ value: DsmDynamicJSON) -> DsmJSONValue {
        switch value {
        case .object(let object): .object(object.mapValues(packageJSON))
        case .array(let values): .array(values.map(packageJSON))
        case .string(let text): .string(text)
        case .number(let number): .decimal(number)
        case .boolean(let flag): .boolean(flag)
        case .null: .null
        }
    }
}
