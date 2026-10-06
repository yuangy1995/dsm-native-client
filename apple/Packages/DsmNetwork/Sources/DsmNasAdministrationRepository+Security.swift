import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadSecuritySettings() async throws -> NasSecuritySettings { try await loadSecuritySettings(managed: false) }
    func loadSecuritySettings(managed: Bool) async throws -> NasSecuritySettings {
        if managed, serviceVersion(.autoBlock) == nil { throw unavailableError() }
        let value = try await call(DsmAPIName.coreSecurityAutoBlock, method: "get", version: managed ? 1 : nil)
        if managed {
            guard try serviceBoolean(value, "enable", managed: true) != nil else { throw securityReadError() }
            _ = try securityInteger(value["attempts"], range: 1...9999)
            _ = try securityInteger(value["within_mins"], range: 1...9999999)
            _ = try securityInteger(value["expire_day"], range: 0...999)
        }
        guard let enabled = value.boolean(["enable"]),
              let attempts = value.number(["attempts"]).map(Int.init),
              let withinMinutes = value.number(["within_mins"]).map(Int.init) else {
            throw verificationError(L10n.string("shared.2ab8b77714bc123d"))
        }
        let rawExpiration = value.number(["expire_day"]).map(Int.init) ?? 0
        var dosProtection: [NasDoSProtectionSetting] = []
        let firewall = (managed ? serviceVersion(.firewall) != nil : capabilities[DsmAPIName.coreSecurityFirewall]?.selectedVersion != nil)
            ? try await call(DsmAPIName.coreSecurityFirewall, method: "get", version: managed ? 1 : nil)
            : nil
        let firewallConf =
            (managed ? serviceVersion(.firewallNotifications) != nil : capabilities[DsmAPIName.coreSecurityFirewallConf]?.selectedVersion != nil)
                ? try await call(DsmAPIName.coreSecurityFirewallConf, method: "get", version: managed ? 1 : nil)
                : nil
        if (managed ? capabilitySupports(DsmAPIName.coreNetworkEthernet, version: 2) : capabilities[DsmAPIName.coreNetworkEthernet]?.selectedVersion != nil),
           (managed ? serviceVersion(.denialOfService) != nil : capabilities[DsmAPIName.coreSecurityDoS]?.selectedVersion != nil) {
            let ethernet = try await call(DsmAPIName.coreNetworkEthernet, method: "list", version: managed ? 2 : nil)
            var adapters = ethernet.objects("interfaces")
            if adapters.isEmpty {
                adapters = ethernet.objects("adapters")
            }
            if adapters.isEmpty {
                adapters = ethernet.array?.compactMap(\.object) ?? []
            }
            let adapterIDs = adapters.compactMap {
                $0["id"]?.scalarString
                    ?? $0["ifname"]?.scalarString
                    ?? $0["name"]?.scalarString
            }
            if managed {
                guard let rows = ethernet["interfaces"]?.array ?? ethernet["adapters"]?.array ?? ethernet.array,
                      rows.count == adapters.count, adapterIDs.count == adapters.count,
                      Set(adapterIDs).count == adapterIDs.count, adapterIDs.allSatisfy({ !$0.isEmpty }) else { throw securityReadError() }
            }
            if !adapterIDs.isEmpty {
                let configs = adapterIDs.map { ["adapter": DsmJSONValue.string($0)] }
                let dos = try await call(
                    DsmAPIName.coreSecurityDoS,
                    method: "get",
                    version: 2,
                    parameters: ["configs": .objectArray(configs)]
                )
                var dosObjects = dos.array?.compactMap(\.object) ?? []
                if dosObjects.isEmpty {
                    dosObjects = dos.objects("configs")
                }
                let enabledPairs: [(String, Bool)] = dosObjects.compactMap {
                    guard let id = $0["adapter"]?.scalarString,
                          let enabled = $0["dos_protect_enable"]?.scalarBoolean else {
                        return nil
                    }
                    return (id, enabled)
                }
                if managed {
                    guard let rows = dos.array ?? dos["configs"]?.array, rows.count == dosObjects.count,
                          enabledPairs.count == dosObjects.count,
                          Set(enabledPairs.map(\.0)) == Set(adapterIDs) else { throw securityReadError() }
                    for row in rows {
                        guard try serviceBoolean(row, "dos_protect_enable", managed: true) != nil else { throw securityReadError() }
                    }
                }
                // DSM 的内部接口在部分版本中会重复返回同一网卡，后返回的状态应覆盖旧值。
                let enabledByAdapter = enabledPairs.reduce(into: [String: Bool]()) {
                    $0[$1.0] = $1.1
                }
                dosProtection = adapters.compactMap { adapter in
                    guard let id = adapter["id"]?.scalarString
                            ?? adapter["ifname"]?.scalarString
                            ?? adapter["name"]?.scalarString,
                          let enabled = enabledByAdapter[id] else {
                        return nil
                    }
                    return NasDoSProtectionSetting(
                        id: id,
                        displayName: adapter["display"]?.scalarString
                            ?? adapter["display_name"]?.scalarString
                            ?? id,
                        isEnabled: enabled
                    )
                }
            }
        }
        if managed {
            if let firewall {
                guard firewall.object != nil else { throw securityReadError() }
                _ = try serviceBoolean(firewall, "enable_firewall", managed: true)
                if let profile = firewall["profile_name"], profile != .null, case .string = profile {} else if firewall["profile_name"] != nil, firewall["profile_name"] != .null { throw securityReadError() }
            }
            if let firewallConf {
                guard firewallConf.object != nil else { throw securityReadError() }
                _ = try serviceBoolean(firewallConf, "enable_port_check", managed: true)
            }
        }
        return NasSecuritySettings(
            isAutoBlockEnabled: enabled,
            failedAttempts: attempts,
            withinMinutes: withinMinutes,
            expirationDays: rawExpiration > 0 ? rawExpiration : nil,
            dosProtection: dosProtection,
            isFirewallEnabled: firewall?.boolean(["enable_firewall"]),
            firewallProfileName: firewall?.string(["profile_name"]),
            isPortScanProtectionEnabled: firewallConf?.boolean(["enable_port_check"])
        )
    }

    private func securityInteger(_ raw: DsmDynamicJSON?, range: ClosedRange<Int>) throws -> Int {
        let number: Double?
        switch raw { case .number(let value): number = value; case .string(let value): number = Double(value); default: number = nil }
        guard let number, number.isFinite, number.rounded() == number,
              Double(range.lowerBound) <= number, number <= Double(range.upperBound) else { throw securityReadError() }
        return Int(number)
    }
    func securityReadError() -> AppError { .init(category: .invalidResponse, isRetryable: false, safeUserMessage: L10n.string("security.settings.failed")) }

    func startManagedFirewallProfile(_ profile: String) async throws -> String {
        guard capabilitySupports(DsmAPIName.coreSecurityFirewallProfileApply, version: 1) else { throw unavailableError() }
        let value = try await call(DsmAPIName.coreSecurityFirewallProfileApply, method: "start", version: 1,
            parameters: ["name": .string(profile), "profile_applying": .boolean(false)])
        guard case .string(let taskID) = value["task_id"], !taskID.isEmpty else { throw securityReadError() }
        return taskID
    }
    /// 只查询已保存的原任务，不发起应用或全局清理。
    public func readFirewallApplication(_ taskID: String) async throws -> Bool? {
        guard !taskID.isEmpty, capabilitySupports(DsmAPIName.coreSecurityFirewallProfileApply, version: 1) else { throw unavailableError() }
        let value = try await call(DsmAPIName.coreSecurityFirewallProfileApply, method: "status", version: 1, parameters: ["task_id": .string(taskID)])
        guard value.object != nil else { throw securityReadError() }
        return try serviceBoolean(value, "success", managed: true)
    }
    func cleanCompletedFirewallTask() async throws {
        try await callVoid(DsmAPIName.coreSecurityFirewallProfileApply, method: "stop", version: 1)
    }
}
