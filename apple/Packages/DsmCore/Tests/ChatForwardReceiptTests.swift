import Foundation
import XCTest
@testable import DsmCore

final class ChatForwardReceiptTests: XCTestCase {
    func test转发记录可恢复但不保存正文附件名或作者名() throws {
        let source = message()
        var receipt = try ChatForwardReceipt(original: source, currentUserID: "1", clientRequestID: UUID(),
                                             targets: [.init(conversationID: "42", baseline: [])])
        receipt.acknowledged = true; receipt.targets[0].confirmedMessageID = "new-42"
        let data = try JSONEncoder().encode(receipt)
        let restored = try JSONDecoder().decode(ChatForwardReceipt.self, from: data)
        try restored.validate(); XCTAssertEqual(restored, receipt); XCTAssertTrue(restored.isComplete)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("合成正文")); XCTAssertFalse(text.contains("sample.m4a")); XCTAssertFalse(text.contains("合成作者"))
    }

    func test转发内容摘要忽略新的对象编号但保留种类名称大小() throws {
        let original = try ChatForwardReceipt.digest(of: message())
        XCTAssertEqual(original, try ChatForwardReceipt.digest(of: message(id: "other", fileID: "new-file")))
        XCTAssertNotEqual(original, try ChatForwardReceipt.digest(of: message(kind: .file)))
        XCTAssertNotEqual(original, try ChatForwardReceipt.digest(of: message(size: 8)))
        XCTAssertNotEqual(original, try ChatForwardReceipt.digest(of: message(text: "不同正文")))
    }

    func test转发记录拒绝重复数字身份来源目标和无回执完成() throws {
        for ids in [["42", "42"], ["42", "042"], ["27"], [""], ["0"], []] {
            XCTAssertThrowsError(try ChatForwardReceipt(original: message(), currentUserID: "1", clientRequestID: UUID(),
                targets: ids.map { .init(conversationID: $0, baseline: []) }))
        }
        var receipt = try ChatForwardReceipt(original: message(), currentUserID: "1", clientRequestID: UUID(),
                                             targets: [.init(conversationID: "42", baseline: [])])
        receipt.targets[0].confirmedMessageID = "new-42"
        XCTAssertThrowsError(try receipt.validate()); XCTAssertFalse(receipt.isComplete)
    }

    func test转发记录拒绝基线中的完成身份和重复目标消息() throws {
        let baseline = ChatMessage(id: "old", conversationID: "42", senderID: "1", sentAt: Date(), text: "旧内容")
        var receipt = try ChatForwardReceipt(original: message(), currentUserID: "1", clientRequestID: UUID(),
            targets: [.init(conversationID: "42", baseline: [baseline]), .init(conversationID: "43", baseline: [])])
        receipt.acknowledged = true; receipt.targets[0].confirmedMessageID = "old"
        XCTAssertThrowsError(try receipt.validate())
        receipt.targets[0].confirmedMessageID = "new"; receipt.targets[1].confirmedMessageID = "new"
        XCTAssertThrowsError(try receipt.validate())
    }

    private func message(id: String = "source", fileID: String = "file", kind: ChatAttachmentKind = .voice,
                         size: Int64 = 7, text: String = "合成正文") -> ChatMessage {
        ChatMessage(id: id, conversationID: "27", senderID: "1", senderDisplayName: "合成作者", sentAt: Date(), text: text,
                    attachments: [.init(id: fileID, kind: kind, fileName: "sample.m4a", sizeBytes: size)])
    }
}
