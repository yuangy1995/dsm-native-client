import CryptoKit
import Foundation

/// 发送恢复只保存原账号、目标和内容摘要；缺少创建回执时不能按相同正文认领消息。
public struct ChatMessageSendReceipt: Codable, Equatable, Sendable {
    public let clientRequestID: UUID
    public let conversationID: String
    public let threadID: String?
    public let currentUserID: String
    public let textDigest: String
    public let attachmentDigest: String?
    public let submittedAt: Date
    public var candidateMessageID: String?

    public init(draft: ChatMessageDraft, currentUserID: String, attachmentSize: Int64? = nil, attachmentFileName: String? = nil,
                submittedAt: Date = Date()) throws {
        guard draft.localAttachmentURLs.count <= 1,
              draft.localAttachmentURLs.isEmpty == (attachmentSize == nil),
              draft.localAttachmentURLs.isEmpty || draft.threadID == nil,
              !draft.localAttachmentURLs.isEmpty || attachmentFileName == nil else { throw CocoaError(.coderInvalidValue) }
        clientRequestID = draft.clientRequestID
        conversationID = draft.conversationID
        threadID = draft.threadID
        self.currentUserID = currentUserID
        textDigest = Self.digest(text: draft.text)
        attachmentDigest = try draft.localAttachmentURLs.first.map {
            try Self.digest(fileName: attachmentFileName ?? $0.lastPathComponent, size: attachmentSize!)
        }
        self.submittedAt = submittedAt
        candidateMessageID = nil
        try validate()
    }

    public func validate() throws {
        func hasID(_ value: String) -> Bool { !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines) }
        func isDigest(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard hasID(conversationID), hasID(currentUserID), currentUserID != "unknown",
              threadID.map(hasID) ?? true, candidateMessageID.map(hasID) ?? true,
              submittedAt.timeIntervalSince1970.isFinite, isDigest(textDigest),
              attachmentDigest.map(isDigest) ?? true,
              attachmentDigest == nil || threadID == nil else { throw CocoaError(.coderReadCorrupt) }
    }

    public func matches(_ message: ChatMessage) -> Bool {
        guard candidateMessageID == message.id, message.conversationID == conversationID,
              message.threadID == threadID, message.senderID == currentUserID,
              message.isFromCurrentUser != false, message.encryptionState == .notEncrypted,
              message.deliveryState == .sent, message.poll == nil,
              Self.digest(text: message.text) == textDigest else { return false }
        guard let attachmentDigest else { return message.attachments.isEmpty }
        guard message.attachments.count == 1, let attachment = message.attachments.first,
              let size = attachment.sizeBytes else { return false }
        return (try? Self.digest(fileName: attachment.fileName, size: size)) == attachmentDigest
    }

    /// 仅核对附件名称和大小；远端未提供字节摘要，不能表述为内容完整性校验。
    private static func digest(fileName: String, size: Int64) throws -> String {
        guard !fileName.isEmpty, size >= 0 else { throw CocoaError(.coderInvalidValue) }
        struct Description: Encodable { let fileName: String; let size: Int64 }
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return hash(try encoder.encode(Description(fileName: fileName, size: size)))
    }

    public static func digest(text: String?) -> String {
        // nil 与空串不参与业务比较：Chat 将无正文的附件读为 nil。
        hash(Data((text ?? "").utf8))
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
