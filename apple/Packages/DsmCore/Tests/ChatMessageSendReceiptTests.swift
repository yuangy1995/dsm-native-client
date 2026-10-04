import Foundation
import XCTest
@testable import DsmCore

final class ChatMessageSendReceiptTests: XCTestCase {
    func test发送回执往返只存身份和摘要不含正文附件名或本机路径() throws {
        let draft = try ChatMessageDraft(conversationID: "27", text: "私密正文",
                                         localAttachmentURLs: [URL(fileURLWithPath: "/synthetic/private-file.txt")])
        var receipt = try ChatMessageSendReceipt(draft: draft, currentUserID: "1", attachmentSize: 7)
        receipt.candidateMessageID = "9001"
        let data = try JSONEncoder().encode(receipt), text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("私密正文")); XCTAssertFalse(text.contains("private-file")); XCTAssertFalse(text.contains("synthetic"))
        XCTAssertEqual(try JSONDecoder().decode(ChatMessageSendReceipt.self, from: data), receipt)
    }

    func test正文身份作者线程和附件必须全部一致() throws {
        var receipt = try ChatMessageSendReceipt(draft: ChatMessageDraft(conversationID: "27", text: "正文", threadID: "root"), currentUserID: "1")
        receipt.candidateMessageID = "9001"
        XCTAssertTrue(receipt.matches(message(threadID: "root")))
        for value in [message(id: "other", threadID: "root"), message(conversationID: "other", threadID: "root"),
                      message(sender: "2", threadID: "root"), message(text: "变化", threadID: "root"),
                      message(), message(threadID: "other"), message(threadID: "root", own: false),
                      message(threadID: "root", encrypted: true), message(threadID: "root", attachments: [attachment()])] {
            XCTAssertFalse(receipt.matches(value))
        }
    }

    func test附件必须存在完整名称大小且普通正文不能冒充() throws {
        var receipt = try ChatMessageSendReceipt(draft: ChatMessageDraft(conversationID: "27", text: "正文",
            localAttachmentURLs: [URL(fileURLWithPath: "/synthetic/sample.txt")]), currentUserID: "1", attachmentSize: 7)
        receipt.candidateMessageID = "9001"
        XCTAssertTrue(receipt.matches(message(attachments: [attachment()])))
        for values in [[], [attachment(size: nil)], [attachment(size: 8)], [attachment(name: "other.txt")], [attachment(), attachment()]] {
            XCTAssertFalse(receipt.matches(message(attachments: values)))
        }
        receipt.candidateMessageID = nil
        XCTAssertFalse(receipt.matches(message(attachments: [attachment()])))
    }

    func test损坏回执与不支持输入不能成为恢复依据() throws {
        let draft = try ChatMessageDraft(conversationID: "27", text: "正文")
        XCTAssertThrowsError(try ChatMessageSendReceipt(draft: draft, currentUserID: "unknown"))
        XCTAssertThrowsError(try ChatMessageSendReceipt(draft: draft, currentUserID: "1", attachmentSize: 7))
        let receipt = try ChatMessageSendReceipt(draft: draft, currentUserID: "1")
        for pair in [("conversationID", " "), ("currentUserID", "unknown"), ("textDigest", String(repeating: "z", count: 64)), ("candidateMessageID", " ")] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt)) as? [String: Any])
            object[pair.0] = pair.1
            let invalid = try JSONDecoder().decode(ChatMessageSendReceipt.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertThrowsError(try invalid.validate())
        }
    }

    private func attachment(name: String = "sample.txt", size: Int64? = 7) -> ChatAttachment {
        ChatAttachment(id: "file", kind: .file, fileName: name, sizeBytes: size)
    }
    private func message(id: String = "9001", conversationID: String = "27", sender: String = "1", text: String = "正文",
                         threadID: String? = nil, own: Bool? = true, encrypted: Bool = false,
                         attachments: [ChatAttachment] = []) -> ChatMessage {
        ChatMessage(id: id, conversationID: conversationID, senderID: sender, senderDisplayName: "合成账号", isFromCurrentUser: own,
                    sentAt: Date(timeIntervalSince1970: 1_800_000_000), text: text, attachments: attachments,
                    encryptionState: encrypted ? .locked : .notEncrypted, threadID: threadID)
    }
}
