import Foundation

/// 仅供当前会话恢复只读核查；不保存凭据，不持久化到磁盘。
public struct FileStationPendingChange: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable { case permissions, iso, connection, general, mountAccess, bandwidth, theme }
    public let id: String
    public let kind: Kind
    public let target: String?
    public init(id: String, kind: Kind, target: String? = nil) {
        self.id = id; self.kind = kind; self.target = target
    }
}
