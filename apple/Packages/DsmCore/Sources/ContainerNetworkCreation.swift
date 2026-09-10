import Foundation
import Network

/// 创建网络的表单配置；自动 IPv4 和关闭 IPv6 时不提交相应地址字段。
public struct ContainerNetworkCreation: Equatable, Sendable {
    public var name: String
    public var usesManualIPv4 = false
    public var subnet = ""
    public var ipRange = ""
    public var gateway = ""
    public var isIPv6Enabled = false
    public var ipv6Subnet = ""
    public var ipv6Range = ""
    public var ipv6Gateway = ""
    public var disableMasquerade = false

    public init(name: String = "") { self.name = name }

    public enum ValidationIssue: String, Error, Sendable {
        case name = "container.network.validation.name"
        case ipv4 = "container.network.validation.ipv4"
        case ipv6 = "container.network.validation.ipv6"
        case outsideSubnet = "container.network.validation.outsideSubnet"
    }

    public var validationIssue: ValidationIssue? {
        guard let range = name.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_.-]*$", options: .regularExpression),
              range == name.startIndex..<name.endIndex else { return .name }
        if usesManualIPv4 {
            if let issue = Self.validate(subnet: subnet, range: ipRange, gateway: gateway, ipv6: false) { return issue }
        }
        if isIPv6Enabled {
            if let issue = Self.validate(subnet: ipv6Subnet, range: ipv6Range, gateway: ipv6Gateway, ipv6: true) { return issue }
        }
        return nil
    }

    private static func validate(subnet: String, range: String, gateway: String, ipv6: Bool) -> ValidationIssue? {
        let invalid: ValidationIssue = ipv6 ? .ipv6 : .ipv4
        guard let network = cidr(subnet, ipv6: ipv6), let gatewayBytes = address(gateway, ipv6: ipv6) else { return invalid }
        if !ipv6, !(1...223).contains(Int(gatewayBytes[0])) { return invalid }
        guard contains(gatewayBytes, in: network) else { return .outsideSubnet }
        if !range.isEmpty {
            guard let pool = cidr(range, ipv6: ipv6) else { return invalid }
            guard pool.prefix >= network.prefix, contains(pool.bytes, in: network) else { return .outsideSubnet }
        }
        return nil
    }

    private static func address(_ text: String, ipv6: Bool) -> [UInt8]? {
        guard !text.contains("%") else { return nil }
        if ipv6 { return IPv6Address(text).map { Array($0.rawValue) } }
        // 与官方 IPv4 表单一致，不接受省略段或带前导零的十进制段。
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ part in
            guard let value = Int(part), (0...255).contains(value) else { return false }
            return String(value) == part
        }) else { return nil }
        return IPv4Address(text).map { Array($0.rawValue) }
    }

    private static func cidr(_ text: String, ipv6: Bool) -> (bytes: [UInt8], prefix: Int)? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let prefix = Int(parts[1]), String(prefix) == parts[1],
              (0...(ipv6 ? 128 : 32)).contains(prefix), let bytes = address(String(parts[0]), ipv6: ipv6) else { return nil }
        return (bytes, prefix)
    }

    private static func contains(_ bytes: [UInt8], in network: (bytes: [UInt8], prefix: Int)) -> Bool {
        for index in bytes.indices {
            let bits = min(8, max(0, network.prefix - index * 8))
            let mask: UInt8 = bits == 0 ? 0 : UInt8(255 << (8 - bits) & 255)
            if bytes[index] & mask != network.bytes[index] & mask { return false }
        }
        return true
    }
}
