import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    public func loadSecuritySettings() async throws -> NasSecuritySettings {
        let value = try await call(DsmAPIName.coreSecurityAutoBlock, method: "get")
        guard let enabled = value.boolean(["enable"]),
              let attempts = value.number(["attempts"]).map(Int.init),
              let withinMinutes = value.number(["within_mins"]).map(Int.init) else {
            throw verificationError(L10n.string("shared.2ab8b77714bc123d"))
        }
        let rawExpiration = value.number(["expire_day"]).map(Int.init) ?? 0
        var dosProtection: [NasDoSProtectionSetting] = []
        let firewall = capabilities[DsmAPIName.coreSecurityFirewall]?.selectedVersion != nil
            ? try await call(DsmAPIName.coreSecurityFirewall, method: "get")
            : nil
        let firewallConf =
            capabilities[DsmAPIName.coreSecurityFirewallConf]?.selectedVersion != nil
                ? try await call(DsmAPIName.coreSecurityFirewallConf, method: "get")
                : nil
        if capabilities[DsmAPIName.coreNetworkEthernet]?.selectedVersion != nil,
           capabilities[DsmAPIName.coreSecurityDoS]?.selectedVersion != nil {
            let ethernet = try await call(DsmAPIName.coreNetworkEthernet, method: "list")
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
}
