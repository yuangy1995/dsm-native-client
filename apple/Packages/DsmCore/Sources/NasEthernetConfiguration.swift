import Foundation

extension NasEthernetInterface {
    /// 只比较实际配置；DHCP 租约、连接状态和显示名称不属于用户保存的字段。
    public var configurationFields: [String] {
        [id, String(usesDHCP), usesDHCP ? "" : address, usesDHCP ? "" : subnetMask,
         usesDHCP ? "" : gateway, usesDHCP ? "" : dnsServers, String(isDefaultGateway),
         String(mtu), String(isVLANEnabled), isVLANEnabled ? vlanID.map(String.init) ?? "" : ""]
    }

    public var isValidForSaving: Bool {
        guard id.hasPrefix("eth"), id.utf8.allSatisfy({
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 || $0 == 45
        }), (576...9_000).contains(mtu), !isVLANEnabled || vlanID.map({ (1...4_094).contains($0) }) == true else { return false }
        return usesDHCP || Self.isIPv4(address) && Self.isIPv4(subnetMask) && (gateway.isEmpty || Self.isIPv4(gateway))
    }

    private static func isIPv4(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {
            !$0.isEmpty && $0.count <= 3 && $0.utf8.allSatisfy { (48...57).contains($0) } && Int($0).map { (0...255).contains($0) } == true
        }
    }
}
