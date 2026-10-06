import Foundation

public enum ContainerNetworkMutationStage: Sendable { case willSubmit, accepted, rejected, verified }
public typealias ContainerNetworkMutationObserver = @Sendable (ContainerNetworkMutationStage) async throws -> Void
public enum ContainerNetworkCreationOutcome: Sendable, Equatable { case created, existing, pending }

/// 恢复只保留摘要，不保存网络名称、地址或可重新提交的配置。
public struct ContainerNetworkCreationIdentity: Codable, Equatable, Sendable {
    public let name: String
    public let configuration: String
    public let ipv4: String?
    public let ipv6Enabled: Bool
    public init(_ value: ContainerNetworkCreation) {
        name = ContainerImagePullRecovery.digest(value.name)
        ipv4 = value.usesManualIPv4 ? Self.digest([value.subnet, value.ipRange, value.gateway]) : nil
        ipv6Enabled = value.isIPv6Enabled
        configuration = Self.digest([value.name, String(value.usesManualIPv4), ipv4 ?? "", String(value.isIPv6Enabled),
            value.isIPv6Enabled ? value.ipv6Subnet : "", value.isIPv6Enabled ? value.ipv6Range : "",
            value.isIPv6Enabled ? value.ipv6Gateway : "", String(value.disableMasquerade)])
    }
    public var isValid: Bool { [name, configuration].allSatisfy(Self.validDigest) && (ipv4.map(Self.validDigest) ?? true) }
    public func matchesName(_ network: ContainerNetwork) -> Bool { name == ContainerImagePullRecovery.digest(network.name) }
    public func matches(_ network: ContainerNetwork) -> Bool {
        matchesName(network) && network.driver == "bridge" && network.isIPv6Enabled == ipv6Enabled
            && (ipv4 == nil || ipv4 == Self.digest([network.subnet ?? "", network.ipRange ?? "", network.gateway ?? ""]))
    }
    public static func validDigest(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func digest(_ fields: [String]) -> String {
        ContainerImagePullRecovery.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }
}

public struct ContainerNetworkDeletionIdentity: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public init(_ network: ContainerNetwork) {
        id = ContainerImagePullRecovery.digest(network.id)
        name = ContainerImagePullRecovery.digest(network.name)
    }
    public var isValid: Bool { [id, name].allSatisfy(ContainerNetworkCreationIdentity.validDigest) }
    public func remains(_ network: ContainerNetwork) -> Bool { id == ContainerImagePullRecovery.digest(network.id) }
}
