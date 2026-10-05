import Foundation

public enum NasDDNSAction: String, Codable, CaseIterable, Sendable {
    case test, save, delete, updateAddress
}

/// 回调分别位于唯一写请求之前和成功回执之后；凭据从不进入检查点。
public enum NasDDNSCheckpoint: Sendable { case willSubmit, accepted }

/// 确认绑定服务商的原始配置，地址和状态等自行变化的数据不作为冲突条件。
public enum NasDDNSChange: Equatable, Sendable {
    case test(original: NasDDNSRecord?, draft: NasDDNSDraft)
    case save(original: NasDDNSRecord?, draft: NasDDNSDraft)
    case delete(NasDDNSRecord)
    case updateAddress(providerIDs: Set<String>)

    public var action: NasDDNSAction {
        switch self { case .test: .test; case .save: .save; case .delete: .delete; case .updateAddress: .updateAddress }
    }
    public var original: NasDDNSRecord? {
        switch self { case .test(let value, _), .save(let value, _): value; case .delete(let value): value; case .updateAddress: nil }
    }
    public var draft: NasDDNSDraft? {
        switch self { case .test(_, let value), .save(_, let value): value; default: nil }
    }
    public var providerID: String? { original?.providerID ?? draft?.normalizedProviderID }

    public func matches(_ directory: NasDDNSDirectory) -> Bool {
        if case .updateAddress(let ids) = self {
            return !ids.isEmpty && Set(directory.records.map(\.providerID)) == ids
        }
        guard let providerID, directory.providers.contains(where: { $0.id == providerID }) else { return false }
        if let draft {
            guard draft.isValidForSubmission, draft.normalizedProviderID == providerID,
                  draft.originalProviderID == original?.providerID else { return false }
        }
        let current = directory.records.first { $0.providerID == providerID }
        if let original {
            guard let current else { return false }
            return original.hasSameConfiguration(as: current)
        }
        return current == nil
    }
}

public extension NasDDNSRecord {
    func hasSameConfiguration(as other: NasDDNSRecord) -> Bool {
        providerID == other.providerID && hostname.lowercased() == other.hostname.lowercased()
            && username == other.username && isEnabled == other.isEnabled && heartbeat == other.heartbeat
            && networkType == other.networkType && interfaceV4 == other.interfaceV4 && interfaceV6 == other.interfaceV6
    }
}
