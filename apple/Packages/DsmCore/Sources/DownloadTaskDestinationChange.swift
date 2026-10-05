import CryptoKit
import Foundation

/// 保存位置与稳定身份分开：回读新位置不能让原任务身份失效。
public struct DownloadTaskDestinationChange: Codable, Equatable, Sendable {
    public let taskID: String
    public let identityDigest: String
    public let original: String
    public let desired: String

    public init(task: DownloadStationTask, destination: String) {
        taskID = task.id; identityDigest = Self.digest(task)
        original = task.destination ?? ""; desired = destination
    }
    public var isValid: Bool {
        !taskID.isEmpty && taskID == taskID.trimmingCharacters(in: .whitespacesAndNewlines)
            && !taskID.contains(",") && !taskID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && identityDigest.count == 64 && identityDigest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
            && Self.validDestination(original) && Self.validDestination(desired) && original != desired
    }
    public func matchesIdentity(_ task: DownloadStationTask) -> Bool {
        taskID == task.id && identityDigest == Self.digest(task)
    }
    public static func validDestination(_ path: String) -> Bool {
        !path.isEmpty && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }
    private static func digest(_ task: DownloadStationTask) -> String {
        let parts: [String?] = [task.id, task.title, task.sizeBytes.map(String.init)]
        let text = parts.map { $0.map { "\($0.utf8.count):\($0)" } ?? "-:" }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum DownloadTaskDestinationOutcome: Equatable, Sendable {
    case complete(DownloadStationTask), pending, changed, denied, rejected, cancelledBeforeSubmission
}
