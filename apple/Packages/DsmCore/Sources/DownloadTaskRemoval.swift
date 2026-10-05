import CryptoKit
import Foundation

/// 两种操作都移除下载任务；forceComplete 的含义是移出未完成文件，绝不是删除文件。
public struct DownloadTaskRemoval: Codable, Equatable, Sendable {
    public let taskID: String
    public let identityDigest: String
    public let forceComplete: Bool

    public init(task: DownloadStationTask, forceComplete: Bool) {
        taskID = task.id; identityDigest = Self.digest(task); self.forceComplete = forceComplete
    }
    public var isValid: Bool {
        !taskID.isEmpty && taskID == taskID.trimmingCharacters(in: .whitespacesAndNewlines)
            && !taskID.contains(",") && !taskID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && identityDigest.count == 64 && identityDigest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    public func matches(_ task: DownloadStationTask) -> Bool { taskID == task.id && identityDigest == Self.digest(task) }
    private static func digest(_ task: DownloadStationTask) -> String {
        let parts: [String?] = [task.id, task.title, task.sizeBytes.map(String.init), task.destination]
        let text = parts.map { $0.map { "\($0.utf8.count):\($0)" } ?? "-:" }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum DownloadTaskRemovalOutcome: Equatable, Sendable {
    /// 仅确认任务不再出现在完整清单中，不代表文件已移动或删除。
    case removed, pending, changed, denied, rejected, cancelledBeforeSubmission
}
