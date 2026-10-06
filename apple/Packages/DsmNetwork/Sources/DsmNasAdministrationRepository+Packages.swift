import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func availablePackageActions() -> [NasPackageAction] {
        guard capabilitySupports(DsmAPIName.corePackage, version: 1), capabilitySupports(DsmAPIName.corePackage, version: 2) else { return [] }
        var actions: [NasPackageAction] = []
        if capabilitySupports(DsmAPIName.corePackageControl, version: 1) { actions += [.start, .stop] }
        if capabilitySupports(DsmAPIName.corePackageUninstallation, version: 1) { actions.append(.uninstall) }
        return actions
    }
    public func loadPackages() async throws -> [NasPackage] {
        try await loadPackages(includingIcons: true)
    }

    public func loadPackagesForManagement() async throws -> [NasPackage] {
        try await loadPackages(includingIcons: false, management: true)
    }

    func loadPackages(
        includingIcons: Bool, management: Bool = false
    ) async throws -> [NasPackage] {
        let value = try await call(
            DsmAPIName.corePackage,
            method: "list",
            version: management ? 2 : nil,
            parameters: [
                "offset": .integer(0),
                "limit": .integer(1_000),
                "additional": .stringArray([
                    "status",
                    "description",
                    "install_type",
                    "startable",
                    "dsm_apps",
                    "available_operation",
                    "ctl_uninstall"
                ])
            ]
        )

        // 写后回读也使用此列表；畸形/截断目录不能被解释为目标已经卸载。
        guard let rows = value["packages"]?.array, rows.count < 1_000 else {
            throw verificationError(L10n.string("nas.packages.response-incomplete"))
        }
        if let total = value["total"], total != .null {
            guard case .number(let count) = total, Int(exactly: count) == rows.count else {
                throw verificationError(L10n.string("nas.packages.response-incomplete"))
            }
        }
        var seenIDs: Set<String> = []
        var upgrades: [String: DsmDynamicJSON] = [:]
        var packages = try rows.map { entry -> NasPackage in
            guard let raw = entry.object, case .string(let id)? = raw["id"],
                  !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  seenIDs.insert(id).inserted else {
                throw verificationError(L10n.string("nas.packages.response-incomplete"))
            }
            let item = DsmDynamicJSON.object(raw)
            let additional = item["additional"] ?? .object([:])
            if management {
                guard additional.object != nil else { throw verificationError(L10n.string("nas.packages.response-incomplete")) }
                for field in [item["version"], additional["status"], additional["status_code"], additional["install_type"]] {
                    if let field, field != .null, case .string = field {} else if field != nil && field != .null {
                        throw verificationError(L10n.string("nas.packages.response-incomplete"))
                    }
                }
                if let timestamp = item["timestamp"], timestamp != .null {
                    guard case .number(let value) = timestamp, value.isFinite, value >= 0 else {
                        throw verificationError(L10n.string("nas.packages.response-incomplete"))
                    }
                }
            }
            let rawStatus = additional.string(["status", "status_code"])
            let rawOrigin = additional.string(["status_origin"])
            let rawDesc = additional.string(["status_description"])
            let isRunning = rawStatus?.lowercased() == "running" || rawStatus?.lowercased() == "active"
            let isStopped = rawStatus?.lowercased() == "stopped" || rawStatus?.lowercased() == "inactive"
            let startable: Bool
            if case .boolean(let flag)? = additional["startable"] { startable = flag } else { startable = false }
            let installType = additional.string(["install_type"])
            let availableOperations = Set(additional.strings(["available_operation"]).map {
                $0.lowercased()
            })
            // DSM 7 的对象只携带升级/修复候选，并不是启动、停止许可清单。
            // 官方页面对启停使用状态与 startable；保留历史数组响应的显式限制。
            let operationDetails = additional["available_operation"]?.object
            let canStart = startable && isStopped
                && (operationDetails != nil || availableOperations.contains("start"))
            let canStop = startable && isRunning
                && (operationDetails != nil || availableOperations.contains("stop"))
            let uninstallAllowed: Bool?
            if case .boolean(let flag)? = additional["ctl_uninstall"] { uninstallAllowed = flag }
            else { uninstallAllowed = additional["ctl_uninstall"] == nil ? nil : false }
            let canUninstall = installType?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false && !["system", "system_hidden"].contains(installType?.lowercased() ?? "")
                && uninstallAllowed != false
                && (uninstallAllowed == true || availableOperations.contains("uninstall"))
            if let upgrade = operationDetails?["upgrade"], upgrade.object != nil { upgrades[id] = upgrade }
            let isUpgradeAvailable = operationDetails?["upgrade"]?.object != nil
                || availableOperations.contains("upgrade")

            let dsmApps: [String]?
            switch additional["dsm_apps"] {
            case .string(let value): dsmApps = value.split(whereSeparator: \.isWhitespace).map(String.init)
            case .array(let values):
                let strings = values.compactMap { value -> String? in if case .string(let text) = value { return text }; return nil }
                dsmApps = strings.count == values.count ? strings : nil
            default: dsmApps = nil
            }

            // 精细化清洗后台底层状态日志，避免暴露英文调试文本
            let formattedStatusDesc = cleanPackageStatusDescription(
                status: rawStatus,
                rawOrigin: rawOrigin,
                rawDesc: rawDesc
            )

            return NasPackage(
                id: id,
                name: item.string(["name"]) ?? id,
                version: item.string(["version"]),
                status: rawStatus,
                statusDescription: formattedStatusDesc,
                packageDescription: additional.string(["description"]),
                installType: installType,
                installedAt: item.number(["timestamp"]).map {
                    Date(timeIntervalSince1970: $0 > 10_000_000_000 ? $0 / 1_000 : $0)
                },
                iconData: nil,
                canStart: canStart,
                canStop: canStop,
                canUninstall: canUninstall,
                isUpgradeAvailable: isUpgradeAvailable,
                // 更新需要安装来源、空间与依赖检查，不能复用列表接口直接触发。
                canUpgrade: false,
                dsmApps: dsmApps
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        packageUpgradeCandidates = upgrades

        guard includingIcons else { return packages }
        guard let iconCapability = capabilities[DsmAPIName.corePackageThumb],
              let iconVersion = iconCapability.selectedVersion else {
            return packages
        }
        for index in packages.indices {
            let key = Self.packageIconCacheKey(packages[index])
            if let cached = packageIconCache[key] {
                packages[index] = Self.package(packages[index], iconData: cached)
            }
        }
        let missingIndices = packages.indices.filter { packages[$0].iconData == nil }
        for batchStart in stride(from: 0, to: missingIndices.count, by: 8) {
            let indices = Array(
                missingIndices[batchStart..<min(batchStart + 8, missingIndices.count)]
            )
            let resolved = await withTaskGroup(
                of: (Int, Data?).self,
                returning: [Int: Data].self
            ) { group in
                for index in indices {
                    let package = packages[index]
                    group.addTask { [client, credential, transport] in
                        let data = await Self.loadPackageIcon(
                            package: package,
                            capability: iconCapability,
                            version: iconVersion,
                            baseURL: client.baseURL,
                            credential: credential,
                            transport: transport
                        )
                        return (index, data)
                    }
                }
                var icons: [Int: Data] = [:]
                for await (index, data) in group {
                    icons[index] = data
                }
                return icons
            }
            for index in indices {
                if let iconData = resolved[index] {
                    packageIconCache[Self.packageIconCacheKey(packages[index])] = iconData
                    packages[index] = Self.package(packages[index], iconData: iconData)
                }
            }
        }
        if packageIconCache.count > 256 {
            let currentKeys = Set(packages.map(Self.packageIconCacheKey))
            packageIconCache = packageIconCache.filter { currentKeys.contains($0.key) }
        }
        return packages
    }
}
