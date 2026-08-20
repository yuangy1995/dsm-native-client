import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadPackages() async throws -> [NasPackage] {
        try await loadPackages(includingIcons: true)
    }

    func loadPackages(
        includingIcons: Bool
    ) async throws -> [NasPackage] {
        let value = try await call(
            DsmAPIName.corePackage,
            method: "list",
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

        var metadata: [String: PackageControlMetadata] = [:]
        var packages = value.objects("packages").compactMap { raw -> NasPackage? in
            let item = DsmDynamicJSON.object(raw)
            guard let id = item.string(["id", "name"]) else { return nil }
            let additional = item["additional"] ?? .object([:])
            let rawStatus = additional.string(["status", "status_code"])
            let rawOrigin = additional.string(["status_origin"])
            let rawDesc = additional.string(["status_description"])
            let isRunning = (rawStatus?.lowercased() == "running" || rawStatus?.lowercased() == "active" || rawOrigin?.lowercased().contains("active") == true)
            let startable = additional.boolean(["startable"]) ?? true
            let installType = additional.string(["install_type"])
            let availableOperations = Set(additional.strings(["available_operation"]).map {
                $0.lowercased()
            })
            let hasOperationList = !availableOperations.isEmpty
            let canStart = startable && !isRunning
                && (!hasOperationList || availableOperations.contains("start"))
            let canStop = startable && isRunning
                && (!hasOperationList || availableOperations.contains("stop"))
            let canUninstall = installType?.lowercased() != "system"
                && (additional.boolean(["ctl_uninstall"]) ?? true)
                && (!hasOperationList || availableOperations.contains("uninstall"))
            let isUpgradeAvailable = availableOperations.contains("upgrade")

            metadata[id] = PackageControlMetadata(
                dsmApps: additional.strings(["dsm_apps"])
            )

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
                canUpgrade: false
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        packageControlMetadata = metadata

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
