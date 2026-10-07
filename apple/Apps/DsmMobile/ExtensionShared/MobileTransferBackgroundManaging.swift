import Foundation

enum MobileTransferDirection: String, Codable, CaseIterable, Sendable {
    case upload
    case download
}

/// 仅用于系统正在进行的活动，不写入传输恢复记录。
enum MobileTransferBackgroundActivity: Sendable {
    case upload, download, crossNASCopy, crossNASRemoval
}

/// 分享扩展复用上传队列，但不能申请主 App 的后台执行时间。
@MainActor
protocol MobileTransferBackgroundManaging: AnyObject {
    func begin(taskID: UUID, activity: MobileTransferBackgroundActivity,
               expiration: @escaping @MainActor @Sendable () async -> Void) -> UUID
    func update(_ token: UUID, completed: Int64, total: Int64?)
    func finish(_ token: UUID, success: Bool)
}
