import CryptoKit
import Foundation

/// 删除确认时的最小内容快照；外层记录必须另行绑定 NAS、账号及操作阶段。
public struct ChatMessageDeletionSnapshot: Codable, Equatable, Sendable {
    public let conversationID: String
    public let messageID: String
    public let senderID: String
    public let sentAt: Date
    public let editedAt: Date?
    public let contentDigest: String

    public init(_ message: ChatMessage) throws {
        guard message.deliveryState == .sent, message.encryptionState == .notEncrypted,
              message.isFromCurrentUser != false, message.threadID == nil else {
            throw CocoaError(.coderInvalidValue)
        }
        conversationID = message.conversationID
        messageID = message.id
        senderID = message.senderID
        sentAt = message.sentAt
        editedAt = message.editedAt
        contentDigest = try Self.digest(message)
        try validate()
    }

    public func validate() throws {
        func validID(_ value: String) -> Bool {
            !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard validID(conversationID), validID(messageID), validID(senderID), senderID != "unknown",
              sentAt.timeIntervalSince1970.isFinite, editedAt?.timeIntervalSince1970.isFinite ?? true,
              contentDigest.count == 64,
              contentDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CocoaError(.coderReadCorrupt)
        }
    }

    public func matches(_ message: ChatMessage) -> Bool {
        (try? Self(message)) == self
    }

    private static func digest(_ message: ChatMessage) throws -> String {
        struct Attachment: Encodable {
            let id: String
            let kind: ChatAttachmentKind
            let name: String
            let mediaType: String?
            let size: Int64?
            let duration: Int64?
        }
        struct Option: Encodable { let id: String; let text: String }
        struct Poll: Encodable {
            let id: String
            let question: String
            let multiple: Bool
            let anonymous: Bool
            let closesAt: Date?
            let options: [Option]
        }
        struct Content: Encodable {
            let text: String?
            let attachments: [Attachment]
            let poll: Poll?
            let kind: ChatMessageKind
        }
        // 票数、已读、置顶、回复数及缩略图生成状态不是作者确认删除的内容。
        let value = Content(text: message.text, attachments: message.attachments.map {
            Attachment(id: $0.id, kind: $0.kind, name: $0.fileName, mediaType: $0.mediaType,
                       size: $0.sizeBytes, duration: $0.durationMilliseconds)
        }, poll: message.poll.map {
            Poll(id: $0.id, question: $0.question, multiple: $0.allowsMultipleSelection,
                 anonymous: $0.isAnonymous, closesAt: $0.closesAt,
                 options: $0.options.map { Option(id: $0.id, text: $0.text) })
        }, kind: message.kind ?? (message.poll != nil ? .vote : (message.attachments.isEmpty ? .normal : .file)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
}
