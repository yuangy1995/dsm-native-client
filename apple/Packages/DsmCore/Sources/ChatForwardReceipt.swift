import CryptoKit
import Foundation

/// 转发的最小恢复依据；外层存储还必须绑定 NAS 与账号，不能保存消息正文或附件内容。
public struct ChatForwardReceipt: Codable, Equatable, Sendable {
    public struct Target: Codable, Equatable, Sendable {
        public let conversationID: String
        public let baselineMessageIDs: Set<String>
        public let latestBaselineDate: Date?
        public var confirmedMessageID: String?

        public init(conversationID: String, baseline: [ChatMessage]) {
            self.conversationID = conversationID
            baselineMessageIDs = Set(baseline.map(\.id))
            latestBaselineDate = baseline.map(\.sentAt).max()
        }
    }

    public let clientRequestID: UUID
    public let sourceConversationID: String
    public let sourceMessageID: String
    public let sourceThreadID: String?
    public let currentUserID: String
    public let contentDigest: String
    public let submittedAt: Date
    public var acknowledged: Bool
    public var targets: [Target]

    public init(original: ChatMessage, currentUserID: String, clientRequestID: UUID,
                targets: [Target], submittedAt: Date = Date()) throws {
        self.clientRequestID = clientRequestID
        sourceConversationID = original.conversationID
        sourceMessageID = original.id
        sourceThreadID = original.threadID
        self.currentUserID = currentUserID
        contentDigest = try Self.digest(of: original)
        self.submittedAt = submittedAt
        acknowledged = false
        self.targets = targets
        try validate()
    }

    public var isComplete: Bool { acknowledged && targets.allSatisfy { $0.confirmedMessageID != nil } }

    public func validate() throws {
        func hasID(_ value: String) -> Bool { !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let numericTargets = targets.compactMap { Int($0.conversationID) }
        let confirmedIDs = targets.compactMap(\.confirmedMessageID)
        guard hasID(sourceConversationID), hasID(sourceMessageID), hasID(currentUserID),
              sourceThreadID.map(hasID) ?? true,
              submittedAt.timeIntervalSince1970.isFinite,
              contentDigest.count == 64,
              contentDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              !targets.isEmpty, numericTargets.count == targets.count,
              numericTargets.allSatisfy({ $0 > 0 }), Set(numericTargets).count == targets.count,
              Set(confirmedIDs).count == confirmedIDs.count,
              targets.allSatisfy({ target in
                  Int(target.conversationID).map({ String($0) == target.conversationID }) == true
                      && target.conversationID != sourceConversationID
                      && Int(target.conversationID) != Int(sourceConversationID)
                      && target.baselineMessageIDs.count <= 100 && target.baselineMessageIDs.allSatisfy(hasID)
                      && (target.baselineMessageIDs.isEmpty == (target.latestBaselineDate == nil))
                      && (target.latestBaselineDate?.timeIntervalSince1970.isFinite ?? true)
                      && (target.confirmedMessageID.map { acknowledged && hasID($0) && !target.baselineMessageIDs.contains($0) } ?? true)
              }) else { throw CocoaError(.coderReadCorrupt) }
    }

    /// 只比较转发承诺保留的内容；文件身份会变化，不能将附件描述摘要宣称为字节校验。
    public static func digest(of message: ChatMessage) throws -> String {
        struct Attachment: Encodable {
            let kind: ChatAttachmentKind
            let fileName: String
            let sizeBytes: Int64?
        }
        struct Content: Encodable { let text: String?; let attachments: [Attachment] }
        let value = Content(text: message.text, attachments: message.attachments.map {
            Attachment(kind: $0.kind, fileName: $0.fileName, sizeBytes: $0.sizeBytes)
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
