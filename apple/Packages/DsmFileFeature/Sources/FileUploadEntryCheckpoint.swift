import Foundation

/// 只记录稳定状态；本地来源授权和 NAS 身份由平台适配器持有。
public struct FileUploadEntryCheckpoint: Codable, Sendable {
    public let id: UUID
    public let state: FileUploadItemState
    public let completedBytes: Int64
    public let needsReconciliation: Bool
    public let retryAllowed: Bool

    public init(id: UUID, state: FileUploadItemState, completedBytes: Int64,
                needsReconciliation: Bool, retryAllowed: Bool) {
        self.id = id; self.state = state; self.completedBytes = completedBytes
        self.needsReconciliation = needsReconciliation; self.retryAllowed = retryAllowed
    }
}
