import Foundation
import XCTest
@testable import DsmCore

final class ChatMessageDeletionSnapshotTests: XCTestCase {
    func test删除快照只保存身份时间和摘要且可往返() throws {
        let value = try ChatMessageDeletionSnapshot(message())
        let data = try JSONEncoder().encode(value)
        let restored = try JSONDecoder().decode(ChatMessageDeletionSnapshot.self, from: data)
        try restored.validate()
        XCTAssertEqual(value, restored)
        for secret in ["合成正文", "sample.txt", "合成作者"] {
            XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(secret))
        }
        XCTAssertTrue(restored.matches(message()))
    }

    func test删除快照比较内容编辑时间及附件身份() throws {
        let value = try ChatMessageDeletionSnapshot(message())
        XCTAssertFalse(value.matches(message(text: "新正文")))
        XCTAssertFalse(value.matches(message(fileID: "other")))
        XCTAssertFalse(value.matches(message(editedAt: Date(timeIntervalSince1970: 1_700_000_001))))
        XCTAssertFalse(value.matches(message(senderID: "2")))
    }

    func test删除快照不因投票人数变化而改变原作者内容() throws {
        let value = try ChatMessageDeletionSnapshot(message(pollVotes: 1))
        XCTAssertTrue(value.matches(message(pollVotes: 10)))
        XCTAssertFalse(value.matches(message(pollVotes: 10, pollOption: "不同选项")))
    }

    func test删除快照拒绝线程加密他人及损坏记录() throws {
        XCTAssertThrowsError(try ChatMessageDeletionSnapshot(message(senderID: "unknown")))
        XCTAssertThrowsError(try ChatMessageDeletionSnapshot(message(threadID: "root")))
        XCTAssertThrowsError(try ChatMessageDeletionSnapshot(message(encryption: .locked)))
        XCTAssertThrowsError(try ChatMessageDeletionSnapshot(message(own: false)))
        let encoded = try JSONEncoder().encode(ChatMessageDeletionSnapshot(message()))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["contentDigest"] = "invalid"
        let damaged = try JSONDecoder().decode(ChatMessageDeletionSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try damaged.validate())
    }

    private func message(text: String = "合成正文", fileID: String = "file", editedAt: Date? = nil,
                         senderID: String = "1", threadID: String? = nil,
                         encryption: ChatEncryptionState = .notEncrypted, own: Bool = true,
                         pollVotes: Int? = nil, pollOption: String = "选项") -> ChatMessage {
        ChatMessage(id: "target", conversationID: "27", senderID: senderID, senderDisplayName: "合成作者",
            isFromCurrentUser: own, sentAt: Date(timeIntervalSince1970: 1_700_000_000), text: text,
            attachments: [.init(id: fileID, kind: .file, fileName: "sample.txt", sizeBytes: 8)],
            poll: pollVotes.map { .init(id: "poll", question: "问题", allowsMultipleSelection: false,
                                       isAnonymous: false, options: [.init(id: "1", text: pollOption, voteCount: $0)]) },
            encryptionState: encryption, threadID: threadID, editedAt: editedAt)
    }
}
