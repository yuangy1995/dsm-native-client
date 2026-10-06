import DsmCore
import DsmLocalization
import Foundation

extension DsmNasAdministrationRepository {
    /// 管理读取必须保留完整原配置；不沿用旧展示入口对缺失字段的默认值。
    func loadEthernetForManagement() async throws -> [NasEthernetInterface] {
        guard serviceVersion(.ethernet) != nil else { throw unavailableError() }
        let list = try await call(DsmAPIName.coreNetworkEthernet, method: "list", version: 2)
        let raw = list["interfaces"]?.array ?? list.array
        guard let raw, raw.allSatisfy({ $0.object != nil }) else { throw ethernetReadError() }
        var result: [NasEthernetInterface] = [], ids: Set<String> = []
        for item in raw {
            let row = item.object!
            guard let id = (row["ifname"] ?? row["id"])?.scalarString else { throw ethernetReadError() }
            guard id.hasPrefix("eth") else { continue }
            guard id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45 }),
                  ids.insert(id).inserted else { throw ethernetReadError() }
            let detail = try await call(DsmAPIName.coreNetworkEthernet, method: "get", version: 1, parameters: ["ifname": .string(id)])
            guard detail.object != nil else { throw ethernetReadError() }
            func field(_ name: String) -> DsmDynamicJSON? { detail[name] ?? detail["ethernet_" + name] ?? row[name] ?? row["ethernet_" + name] }
            func text(_ name: String, required: Bool = true) throws -> String {
                guard let value = field(name), value != .null else { if !required { return "" }; throw ethernetReadError() }
                guard case .string(let text) = value else { throw ethernetReadError() }; return text
            }
            func integer(_ value: DsmDynamicJSON?, range: ClosedRange<Int>) throws -> Int {
                if case .boolean = value { throw ethernetReadError() }
                guard let number = value?.scalarNumber, number.isFinite, number.rounded() == number,
                      Double(range.lowerBound) <= number, number <= Double(range.upperBound) else { throw ethernetReadError() }
                return Int(number)
            }
            func boolean(_ name: String) throws -> Bool {
                switch field(name) {
                case .boolean(let value): return value
                case .number(let value) where value == 0 || value == 1: return value == 1
                case .string(let value):
                    switch value.lowercased() { case "true", "yes", "1", "enabled": return true
                    case "false", "no", "0", "disabled": return false; default: break }
                default: break
                }
                throw ethernetReadError()
            }
            if let reported = detail["ifname"], reported.scalarString != id { throw ethernetReadError() }
            let dhcp = try boolean("use_dhcp"), gateway = try boolean("is_default_gateway"), vlan = try boolean("enable_vlan")
            let value = try NasEthernetInterface(id: id, displayName: field("title")?.scalarString ?? field("display")?.scalarString ?? id,
                status: field("status")?.scalarString, usesDHCP: dhcp,
                address: text("ip", required: !dhcp), subnetMask: text("mask", required: !dhcp),
                gateway: text("gateway", required: !dhcp), dnsServers: text("dns", required: !dhcp),
                isDefaultGateway: gateway, mtu: integer(field("mtu") ?? field("mtu_config"), range: 576...9_000),
                isVLANEnabled: vlan, vlanID: vlan ? integer(field("vlan_id"), range: 1...4_094) : nil)
            guard value.isValidForSaving else { throw ethernetReadError() }
            result.append(value)
        }
        return result
    }

    private func ethernetReadError() -> AppError {
        .init(category: .invalidResponse, isRetryable: true, safeUserMessage: L10n.string("network.ethernet.failed"))
    }

    public func loadEthernetInterfaces() async throws -> [NasEthernetInterface] {
        let list = try await call(
            DsmAPIName.coreNetworkEthernet,
            method: "list",
            version: 2
        )
        var rows = list.objects("interfaces")
        if rows.isEmpty {
            rows = list.array?.compactMap(\.object) ?? []
        }
        var result: [NasEthernetInterface] = []
        for row in rows {
            guard let id = row["ifname"]?.scalarString
                    ?? row["id"]?.scalarString,
                  id.hasPrefix("eth") else {
                continue
            }
            let detail = try await call(
                DsmAPIName.coreNetworkEthernet,
                method: "get",
                version: 1,
                parameters: ["ifname": .string(id)]
            )
            guard let item = Self.ethernetInterface(
                from: detail,
                fallback: row,
                id: id
            ) else {
                continue
            }
            result.append(item)
        }
        return result
    }
}
