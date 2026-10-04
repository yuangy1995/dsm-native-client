import Foundation

/// 群聊创建的三个步骤分别保存；同名或相同成员不能代替创建返回的群聊编号。
public struct ChatGroupCreateReceipt: Codable, Equatable, Sendable {
    public enum Stage: String, Codable, Sendable { case ready, submitted, completed, rejected }

    public let clientRequestID: UUID
    public let currentUserID: String
    public let titleDigest: String
    public let memberIDs: [String]
    public var candidateConversationID: String?
    public var create: Stage
    public var join: Stage
    public var invite: Stage
    public var revision: Int
    public var lastError: MutationErrorCategory?

    public init(draft: ChatGroupDraft, currentUserID: String) throws {
        guard !draft.isEncrypted else { throw CocoaError(.coderInvalidValue) }
        clientRequestID = draft.clientRequestID
        self.currentUserID = currentUserID
        titleDigest = ChatMessageSendReceipt.digest(text: draft.title)
        memberIDs = draft.memberIDs
        candidateConversationID = nil
        create = .submitted; join = .ready; invite = .ready; revision = 0
        lastError = nil
        try validate()
    }

    public func validate() throws {
        func hasID(_ value: String) -> Bool {
            !value.isEmpty && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard hasID(currentUserID), currentUserID != "unknown", memberIDs.count >= 2,
              memberIDs.allSatisfy(hasID), memberIDs == Array(Set(memberIDs)).sorted(),
              !memberIDs.contains(currentUserID), candidateConversationID.map(hasID) ?? true,
              titleDigest.count == 64, titleDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              revision >= 0, revision < Int.max, create != .ready,
              (create == .completed) == (candidateConversationID != nil),
              create == .completed || (join == .ready && invite == .ready),
              join == .completed || invite == .ready else { throw CocoaError(.coderReadCorrupt) }
    }

    public func matches(_ draft: ChatGroupDraft) -> Bool {
        clientRequestID == draft.clientRequestID && !draft.isEncrypted
            && titleDigest == ChatMessageSendReceipt.digest(text: draft.title) && memberIDs == draft.memberIDs
    }

    public func hasSameIdentity(as other: Self) -> Bool {
        clientRequestID == other.clientRequestID && currentUserID == other.currentUserID
            && titleDigest == other.titleDigest && memberIDs == other.memberIDs
    }

    /// 只代表有未提交或明确被拒绝的后续步骤；继续前仍须重新读取账号、群聊和成员。
    public var canContinue: Bool {
        create == .completed && (join == .ready || join == .rejected
            || (join == .completed && (invite == .ready || invite == .rejected)))
    }
}
