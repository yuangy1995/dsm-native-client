import Foundation

public enum NasSystemActionKind: String, Codable, Sendable { case disconnect, shutdown, reboot }
public enum NasSystemActionCheckpoint: Equatable, Sendable { case willSubmit, accepted }

/// 仅用于当次用户确认；连接明文和会话凭据不得写入操作记录。
public enum NasSystemAction: Equatable, Sendable {
    case disconnect(NasConnection)
    case power(NasPowerAction)

    public var kind: NasSystemActionKind {
        switch self { case .disconnect: .disconnect; case .power(.shutdown): .shutdown; case .power(.reboot): .reboot }
    }
    public var connection: NasConnection? { if case .disconnect(let value) = self { return value }; return nil }
}

extension NasConnectionPage {
    /// 达到读取上限时，即使 total 恰等于行数也不能排除后续连接。
    public var isCompleteForManagement: Bool { connections.count < 500 && total <= connections.count }
}

extension NasConnection {
    public var isWebConnection: Bool { type?.uppercased() == "HTTP/HTTPS" }
    public var hasDisconnectIdentity: Bool {
        (isWebConnection ? deviceID : processID)?.isEmpty == false && type?.isEmpty == false
            && source != nil && (!isWebConnection || description != nil)
    }
    public func hasSameManagementTarget(as other: NasConnection) -> Bool {
        processID == other.processID && deviceID == other.deviceID && account == other.account
            && source == other.source && type == other.type && description == other.description
            && connectedAt == other.connectedAt && protocolName == other.protocolName
            && location == other.location && isCurrentConnection == other.isCurrentConnection
    }
    public func mayRemain(in current: NasConnection) -> Bool {
        let expected = isWebConnection ? deviceID : processID
        let actual = isWebConnection ? current.deviceID : current.processID
        if expected?.isEmpty != false || expected == actual { return true }
        if actual?.isEmpty == false { return false }
        // 原始标识缺失的相似条目不能因派生行号或本机时区解析的时间变化而被视为消失。
        return current.account == account
            && (current.source == nil || source == nil || current.source == source)
            && (current.description == nil || description == nil || current.description == description)
    }
}
