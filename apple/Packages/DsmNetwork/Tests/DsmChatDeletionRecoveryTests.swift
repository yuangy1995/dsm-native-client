import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

extension DsmChatRepositoryTests {
    func test删除写前保存且FORM和JSON均固定v5及原消息身份() async throws {
        for format in [DsmRequestFormat.form, .json] {
            let transport = MockHTTPTransport(responses: deletionAccess() + [deletionPosts([deletionPost()]),
                response(#"{"success":true}"#)] + deletionAccess() + [deletionPosts([])])
            let repository = try makeRepository(transport: transport, chatRequestFormat: format)
            let id = UUID(), original = try deletionSnapshot()
            try await repository.deleteMessage(original, clientRequestID: id) {
                let requests = await transport.recordedRequests()
                XCTAssertEqual(requests.count, 3)
            }
            try await repository.deleteMessage(original, clientRequestID: id) { XCTFail("完成后不再准备提交") }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 7)
            let fields = try decodeForm(requests[3].httpBody)
            XCTAssertEqual(fields["api"], DsmAPIName.chatPost)
            XCTAssertEqual(fields["version"], "5")
            XCTAssertEqual(fields["method"], "delete")
            XCTAssertEqual(fields["post_id"], format == .json ? #""target""# : "target")
        }
    }

    func test删除写前保存失败及取消都零写且原编号可在未提交后继续() async throws {
        for cancellation in [false, true] {
            let setup = deletionAccess() + [deletionPosts([deletionPost()])]
            let transport = MockHTTPTransport(responses: setup + setup + [response(#"{"success":true}"#)] + deletionAccess() + [deletionPosts([])])
            let repository = try makeRepository(transport: transport), id = UUID(), original = try deletionSnapshot()
            do {
                try await repository.deleteMessage(original, clientRequestID: id) {
                    if cancellation { throw CancellationError() }
                    throw CocoaError(.fileWriteNoPermission)
                }
                XCTFail("写前保存失败必须结束")
            } catch is CancellationError { XCTAssertTrue(cancellation) }
            catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteNoPermission) }
            let before = await transport.recordedRequests()
            XCTAssertEqual(try before.filter { try decodeForm($0.httpBody)["method"] == "delete" }.count, 0)
            try await repository.deleteMessage(original, clientRequestID: id, willSubmit: {})
            let after = await transport.recordedRequests()
            XCTAssertEqual(try after.filter { try decodeForm($0.httpBody)["method"] == "delete" }.count, 1)
        }
    }

    func test删除丢回执而完整历史已不存在可以确认完成() async throws {
        let steps = (deletionAccess() + [deletionPosts([deletionPost()])]).map(MockHTTPTransport.Step.response)
            + [.urlError(.networkConnectionLost)] + (deletionAccess() + [deletionPosts([])]).map(MockHTTPTransport.Step.response)
        let transport = MockHTTPTransport(steps: steps), original = try deletionSnapshot()
        let repository = try makeRepository(transport: transport)
        try await repository.deleteMessage(original, clientRequestID: UUID(), willSubmit: {})
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.filter { try decodeForm($0.httpBody)["method"] == "delete" }.count, 1)
    }

    func test删除未知同编号仅回读且换编号不能绕过() async throws {
        let transport = MockHTTPTransport(responses: deletionAccess() + [deletionPosts([deletionPost()]),
            DsmHTTPResponse(data: Data(), statusCode: 503)] + deletionAccess() + [deletionPosts([deletionPost()])]
            + deletionAccess() + [deletionPosts([deletionPost()])])
        let repository = try makeRepository(transport: transport), original = try deletionSnapshot(), id = UUID()
        for _ in 0..<2 {
            do { try await repository.deleteMessage(original, clientRequestID: id, willSubmit: {}); XCTFail("消息仍在不能成功") }
            catch let error as AppError { XCTAssertEqual(error.category, .partialFailure); XCTAssertFalse(error.isRetryable) }
        }
        do { try await repository.deleteMessage(original, clientRequestID: UUID(), willSubmit: {}); XCTFail("未知期间不能换编号重删") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.filter { try decodeForm($0.httpBody)["method"] == "delete" }.count, 1)
        XCTAssertEqual(requests.count, 10)
    }

    func test删除重建后只读恢复不依赖旧实例并禁止重复提交() async throws {
        let original = try deletionSnapshot(), id = UUID()
        let transport = MockHTTPTransport(responses: deletionAccess() + [deletionPosts([deletionPost()])]
            + deletionAccess() + [deletionPosts([])])
        let repository = try makeRepository(transport: transport)
        let first = try await repository.recoverMessageDeletion(original, clientRequestID: id)
        XCTAssertFalse(first)
        do { try await repository.deleteMessage(original, clientRequestID: UUID(), willSubmit: {}); XCTFail("导入记录必须锁住原目标") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let final = try await repository.recoverMessageDeletion(original, clientRequestID: id)
        XCTAssertTrue(final)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 6)
        XCTAssertFalse(try requests.contains { try decodeForm($0.httpBody)["method"] == "delete" })
    }

    func test删除恢复丢失权限更换账号加密会话都不能把空列表当成功() async throws {
        for access in [deletionAccess(userID: "2"), deletionAccess(visible: false), deletionAccess(encrypted: true)] {
            let transport = MockHTTPTransport(responses: access + [deletionPosts([])])
            let repository = try makeRepository(transport: transport)
            do { _ = try await repository.recoverMessageDeletion(deletionSnapshot(), clientRequestID: UUID()); XCTFail("访问原会话前不能确认删除") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 2)
        }
    }

    func test删除回读失败统一未知而明确拒绝为终态且不重放() async throws {
        let unavailable = DsmHTTPResponse(data: Data(), statusCode: 503)
        let unknown = MockHTTPTransport(responses: deletionAccess() + [deletionPosts([deletionPost()]), response(#"{"success":true}"#), unavailable])
        do { try await makeRepository(transport: unknown).deleteMessage(deletionSnapshot(), clientRequestID: UUID(), willSubmit: {}); XCTFail("回读失败不能普通重试") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure); XCTAssertFalse(error.isRetryable) }
        let rejected = MockHTTPTransport(responses: deletionAccess() + [deletionPosts([deletionPost()]), response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport: rejected), id = UUID(), original = try deletionSnapshot()
        for _ in 0..<2 {
            do { try await repository.deleteMessage(original, clientRequestID: id, willSubmit: {}); XCTFail("权限拒绝") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        }
        let requests = await rejected.recordedRequests()
        XCTAssertEqual(requests.count, 4)
    }

    func test删除内容编辑时间变化和非本人都不触发提交() async throws {
        for post in [deletionPost(text: "已修改"), deletionPost(editedAt: 1_700_000_001_000), deletionPost(senderID: "2")] {
            let transport = MockHTTPTransport(responses: deletionAccess() + [deletionPosts([post])])
            let repository = try makeRepository(transport: transport)
            do { try await repository.deleteMessage(deletionSnapshot(), clientRequestID: UUID()) { XCTFail("变化后不得准备写入") }; XCTFail("原内容不符") }
            catch let error as AppError { XCTAssertTrue([AppErrorCategory.conflict, .permissionDenied].contains(error.category)) }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
        }
    }

    func test删除恢复目标在第一百条之后且坏分页或空辅助记录不误报() async throws {
        let first = (1...100).map { deletionPost(id: "new-\($0)", at: 1_700_000_000_000 + $0 * 1_000) }
        let cursorPost = deletionPost(id: "new-1", at: 1_700_000_001_000)
        let secondPages = [
            deletionPosts([deletionPost(), cursorPost]),
            deletionPosts([deletionPost(id: "new-2", at: 1_700_000_002_000)]),
            deletionPosts([["post_id": "target", "channel_id": "27"]]),
            response(#"{"success":true,"data":{"unexpected":[]}}"#)
        ]
        for (index, second) in secondPages.enumerated() {
            let transport = MockHTTPTransport(responses: deletionAccess() + [deletionPosts(first), second])
            let repository = try makeRepository(transport: transport)
            do {
                let result = try await repository.recoverMessageDeletion(deletionSnapshot(), clientRequestID: UUID())
                XCTAssertEqual(index, 0); XCTAssertFalse(result)
            } catch let error as AppError { XCTAssertGreaterThan(index, 0); XCTAssertEqual(error.category, .invalidResponse) }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 4)
            XCTAssertEqual(try decodeForm(requests[3].httpBody)["post_id"], "new-1")
        }
    }

    func test删除完成身份不能被新内容或新目标复用() async throws {
        let transport = MockHTTPTransport(responses: deletionAccess() + [deletionPosts([deletionPost()]), response(#"{"success":true}"#)]
            + deletionAccess() + [deletionPosts([])])
        let repository = try makeRepository(transport: transport), id = UUID()
        try await repository.deleteMessage(deletionSnapshot(), clientRequestID: id, willSubmit: {})
        for original in [try deletionSnapshot(text: "不同"), try deletionSnapshot(id: "other")] {
            do { try await repository.deleteMessage(original, clientRequestID: id, willSubmit: {}); XCTFail("不能变更原操作") }
            catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 7)
    }

    func test删除写前等待时并发删除及恢复不能越过原请求() async throws {
        let transport = MockHTTPTransport(responses: deletionAccess() + [deletionPosts([deletionPost()]), response(#"{"success":true}"#)]
            + deletionAccess() + [deletionPosts([])])
        let repository = try makeRepository(transport: transport), id = UUID(), original = try deletionSnapshot()
        let gate = MessageDeletionGate()
        let work = Task { try await repository.deleteMessage(original, clientRequestID: id) { await gate.pause() } }
        await gate.waitUntilPaused()
        do { try await repository.deleteMessage(original, clientRequestID: UUID(), willSubmit: {}); XCTFail("并发删除不能开始") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        do { _ = try await repository.recoverMessageDeletion(original, clientRequestID: id); XCTFail("原请求未完成不能恢复") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        await gate.resume(); try await work.value
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 7)
    }

    func test删除提交后取消保留未知且恢复只读() async throws {
        let steps = (deletionAccess() + [deletionPosts([deletionPost()])]).map(MockHTTPTransport.Step.response)
            + [.waitUntilCancelled] + (deletionAccess() + [deletionPosts([])]).map(MockHTTPTransport.Step.response)
        let transport = MockHTTPTransport(steps: steps), repository = try makeRepository(transport: transport)
        let original = try deletionSnapshot(), id = UUID()
        let work = Task { try await repository.deleteMessage(original, clientRequestID: id, willSubmit: {}) }
        while await transport.recordedRequests().count < 4 { await Task.yield() }
        work.cancel()
        do { try await work.value; XCTFail("提交后取消须保持未知") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let result = try await repository.recoverMessageDeletion(original, clientRequestID: id)
        XCTAssertTrue(result)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.filter { try decodeForm($0.httpBody)["method"] == "delete" }.count, 1)
    }

    func deletionAccess(userID: String = "1", visible: Bool = true, encrypted: Bool = false) -> [DsmHTTPResponse] {
        [response("{\"success\":true,\"data\":{\"current_user_id\":\"\(userID)\",\"users\":[]}}"),
         response("{\"success\":true,\"data\":{\"channels\":\(visible ? "[{\"channel_id\":\"27\",\"type\":\"named\",\"name\":\"合成会话\",\"is_encrypted\":\(encrypted)}]" : "[]")}}")]
    }

    private func deletionSnapshot(id: String = "target", text: String = "合成消息") throws -> ChatMessageDeletionSnapshot {
        try ChatMessageDeletionSnapshot(ChatMessage(id: id, conversationID: "27", senderID: "1", isFromCurrentUser: true,
            sentAt: Date(timeIntervalSince1970: 1_700_000_000), text: text))
    }

    private func deletionPost(id: String = "target", text: String = "合成消息", senderID: String = "1",
                              editedAt: Int? = nil, at: Int = 1_700_000_000_000) -> [String: Any] {
        var value: [String: Any] = ["post_id": id, "channel_id": "27", "creator_id": senderID,
                                  "is_my_post": senderID == "1", "message": text, "create_at": at]
        value["update_at"] = editedAt
        return value
    }

    private func deletionPosts(_ posts: [[String: Any]]) -> DsmHTTPResponse {
        DsmHTTPResponse(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["posts": posts]]), statusCode: 200)
    }
}

private actor MessageDeletionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            observers.forEach { $0.resume() }; observers.removeAll()
        }
    }
    func waitUntilPaused() async {
        if continuation != nil { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
