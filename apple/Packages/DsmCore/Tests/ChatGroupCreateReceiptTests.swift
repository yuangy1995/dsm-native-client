import DsmCore
import Foundation
import XCTest

final class ChatGroupCreateReceiptTests: XCTestCase {
    func test群聊回执不含标题正文且绑定规范化草稿与本人() throws {
        let draft = try ChatGroupDraft(title: " 合成群聊 ", memberIDs: ["3", "2", "2"], isEncrypted: false)
        let receipt = try ChatGroupCreateReceipt(draft: draft, currentUserID: "1")
        XCTAssertTrue(receipt.matches(draft)); XCTAssertEqual(receipt.memberIDs, ["2", "3"])
        let data = try JSONEncoder().encode(receipt)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("合成群聊"))
        XCTAssertEqual(try JSONDecoder().decode(ChatGroupCreateReceipt.self, from: data), receipt)
        XCTAssertThrowsError(try ChatGroupCreateReceipt(draft: draft, currentUserID: "2"))
        XCTAssertThrowsError(try ChatGroupCreateReceipt(draft: draft, currentUserID: "unknown"))
        XCTAssertFalse(receipt.matches(try ChatGroupDraft(clientRequestID: draft.clientRequestID,
            title: "另一个群", memberIDs: ["2", "3"], isEncrypted: false)))
    }

    func test群聊回执拒绝跳过步骤和伪造编号组合() throws {
        let original = try ChatGroupCreateReceipt(draft: ChatGroupDraft(title: "合成群聊", memberIDs: ["2", "3"], isEncrypted: false), currentUserID: "1")
        var value = original; value.candidateConversationID = "42"
        XCTAssertThrowsError(try value.validate())
        value = original; value.join = .completed
        XCTAssertThrowsError(try value.validate())
        value = original; value.create = .completed
        XCTAssertThrowsError(try value.validate())
        value.candidateConversationID = "42"; value.invite = .submitted
        XCTAssertThrowsError(try value.validate())
        value.join = .completed
        XCTAssertNoThrow(try value.validate())
        value.revision = Int.max
        XCTAssertThrowsError(try value.validate())
    }

    func test仅可继续未提交或明确拒绝的后续步骤() throws {
        var value = try ChatGroupCreateReceipt(draft: ChatGroupDraft(title: "合成群聊", memberIDs: ["2", "3"], isEncrypted: false), currentUserID: "1")
        XCTAssertFalse(value.canContinue)
        value.create = .completed; value.candidateConversationID = "42"
        XCTAssertTrue(value.canContinue)
        value.join = .submitted; XCTAssertFalse(value.canContinue)
        value.join = .rejected; XCTAssertTrue(value.canContinue)
        value.join = .completed; value.invite = .submitted; XCTAssertFalse(value.canContinue)
        value.invite = .rejected; XCTAssertTrue(value.canContinue)
        value.invite = .completed; XCTAssertFalse(value.canContinue)
    }
}
