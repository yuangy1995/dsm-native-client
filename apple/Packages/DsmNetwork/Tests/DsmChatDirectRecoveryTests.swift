import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

extension DsmChatRepositoryTests {
    func test单聊提交回调在只读预检后且写入前执行() async throws {
        let transport = MockHTTPTransport(responses: directCreateSetup() + [response(#"{"success":true,"data":{"channel_id":"27"}}"#)] + directRecoverySetup())
        let repository = try makeRepository(transport: transport)
        let observer = DirectSubmissionObserver()
        let result = try await repository.openDirectConversationResult(userID: "2", clientRequestID: UUID()) {
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 3)
            await observer.record()
        }
        XCTAssertEqual(result.result.status, .confirmedSuccess)
        XCTAssertEqual(result.confirmedConversation?.id, "27")
        let callbacks = await observer.count; XCTAssertEqual(callbacks, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.filter { try decodeForm($0.httpBody)["method"] == "initiate" }.count, 1)
    }

    func test单聊保存提交阶段失败零写入且显式重试可继续() async throws {
        let transport = MockHTTPTransport(responses: directCreateSetup() + directCreateSetup() + [response(#"{"success":true,"data":{"channel_id":"27"}}"#)] + directRecoverySetup())
        let repository = try makeRepository(transport: transport), id = UUID()
        do {
            _ = try await repository.openDirectConversationResult(userID: "2", clientRequestID: id) { throw CocoaError(.fileWriteNoPermission) }
            XCTFail("不能越过保存失败")
        } catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteNoPermission) }
        let before = await transport.recordedRequests()
        XCTAssertEqual(before.count, 3)
        XCTAssertFalse(try before.contains { try decodeForm($0.httpBody)["method"] == "initiate" })
        let result = try await repository.openDirectConversationResult(userID: "2", clientRequestID: id, willSubmit: {})
        XCTAssertEqual(result.result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.filter { try decodeForm($0.httpBody)["method"] == "initiate" }.count, 1)
    }

    func test单聊恢复导入未知后普通调用也仅回读() async throws {
        let transport = MockHTTPTransport(responses: directRecoverySetup(channels: "[]") + directRecoverySetup())
        let repository = try makeRepository(transport: transport), id = UUID()
        let unknown = try await repository.recoverDirectConversation(userID: "2", clientRequestID: id)
        XCTAssertEqual(unknown.result.status, .submittedButUnverified)
        let confirmed = try await repository.openDirectConversationResult(userID: "2", clientRequestID: id) { XCTFail("恢复不能再次进入写前回调") }
        XCTAssertEqual(confirmed.confirmedConversation?.id, "27")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertFalse(try requests.contains { try decodeForm($0.httpBody)["method"] == "initiate" })
    }

    func test单聊恢复不接受加密多余成员缺当前用户或错误成员数() async throws {
        let values = [
            #"[{"channel_id":"27","type":"anonymous","members":["1","2"],"encrypted":true}]"#,
            #"[{"channel_id":"27","type":"anonymous","members":["1","2","3"]}]"#,
            #"[{"channel_id":"27","type":"anonymous","members":["2"]}]"#,
            #"[{"channel_id":"27","type":"anonymous","members":["1","2"],"member_count":3}]"#
        ]
        for channels in values {
            let transport = MockHTTPTransport(responses: directRecoverySetup(channels: channels))
            let repository = try makeRepository(transport: transport)
            let outcome = try await repository.recoverDirectConversation(userID: "2", clientRequestID: UUID())
            XCTAssertEqual(outcome.result.status, .submittedButUnverified)
            XCTAssertNil(outcome.confirmedConversation)
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
        }
    }

    func test已有正确普通单聊直接打开且不保存提交阶段() async throws {
        let transport = MockHTTPTransport(responses: [directUsers()] + directRecoverySetup())
        let repository = try makeRepository(transport: transport)
        let outcome = try await repository.openDirectConversationResult(userID: "2", clientRequestID: UUID()) { XCTFail("复用已有会话不应准备写入") }
        XCTAssertEqual(outcome.confirmedConversation?.id, "27")
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
    }

    func test单聊保存期间取消仍在提交前退出且释放创建互斥() async throws {
        let transport = MockHTTPTransport(responses: directCreateSetup() + directCreateSetup() + [response(#"{"success":true,"data":{"channel_id":"27"}}"#)] + directRecoverySetup())
        let repository = try makeRepository(transport: transport), gate = DirectSubmissionGate()
        let task = Task { try await repository.openDirectConversationResult(userID: "2", clientRequestID: UUID()) { await gate.pause() } }
        await gate.waitUntilPaused(); task.cancel(); await gate.resume()
        let cancelled = try await task.value
        XCTAssertEqual(cancelled.result.status, .cancelledBeforeSubmission)
        XCTAssertFalse(cancelled.result.submitted)
        let before = await transport.recordedRequests(); XCTAssertEqual(before.count, 3)
        let result = try await repository.openDirectConversationResult(userID: "2", clientRequestID: UUID(), willSubmit: {})
        XCTAssertEqual(result.result.status, .confirmedSuccess)
    }

    private func directUsers() -> DsmHTTPResponse {
        response(#"{"success":true,"data":{"current_user_id":"1","users":[{"user_id":"1","is_current_user":true},{"user_id":"2"}]}}"#)
    }

    private func directCreateSetup() -> [DsmHTTPResponse] {
        [directUsers(), directUsers(), response(#"{"success":true,"data":{"channels":[]}}"#)]
    }

    private func directRecoverySetup(channels: String = #"[{"channel_id":"27","type":"anonymous","members":["1","2"],"member_count":2}]"#) -> [DsmHTTPResponse] {
        [directUsers(), response("{\"success\":true,\"data\":{\"channels\":\(channels)}}")]
    }
}

private actor DirectSubmissionObserver {
    private(set) var count = 0
    func record() { count += 1 }
}

private actor DirectSubmissionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func pause() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            waiters.forEach { $0.resume() }; waiters.removeAll()
        }
    }
    func waitUntilPaused() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}
