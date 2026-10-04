import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

extension DsmChatRepositoryTests {
    func test置顶提交后的读取失败保留未知且不可普通重试() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true}"#), DsmHTTPResponse(data: Data(), statusCode: 503)])
        let repository = try makeRepository(transport: transport)
        do { try await repository.setMessagePinned(conversationID: "27", messageID: "9001", isPinned: true, clientRequestID: UUID()); XCTFail("不能误报成功") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure); XCTAssertFalse(error.isRetryable) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
    }
    func test取消置顶写入丢回执仍按列表确认且同请求不重复() async throws {
        let transport = MockHTTPTransport(responses: [DsmHTTPResponse(data: Data(), statusCode: 503), response(#"{"success":true,"data":{"search_results":[],"total":0}}"#)])
        let repository = try makeRepository(transport: transport); let id = UUID()
        for _ in 0..<2 { try await repository.setMessagePinned(conversationID: "27", messageID: "9001", isPinned: false, clientRequestID: id) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try decodeForm(requests[0].httpBody)["method"], "unpin")
    }
    func test关闭提交后的回读失败不能变为未提交() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"users":[]}}"#),
            response(#"{"success":true,"data":{"channels":[{"channel_id":"27","type":"named","name":"Sample"}]}}"#),
            response(#"{"success":true}"#),
            DsmHTTPResponse(data: Data(), statusCode: 503)
        ])
        let repository = try makeRepository(transport: transport)
        do { try await repository.closeConversation(conversationID: "27", clientRequestID: UUID()); XCTFail("回读失败必须保留未知") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure); XCTAssertFalse(error.isRetryable) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(try decodeForm(requests[2].httpBody)["version"], "5")
    }
    func test关闭写入丢回执可按完整列表确认且同请求零重放() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"users":[]}}"#),
            response(#"{"success":true,"data":{"channels":[{"channel_id":"27","type":"named","name":"Sample"}]}}"#),
            DsmHTTPResponse(data: Data(), statusCode: 503),
            response(#"{"success":true,"data":{"users":[]}}"#),
            response(#"{"success":true,"data":{"channels":[]}}"#)
        ])
        let repository = try makeRepository(transport: transport); let id = UUID()
        for _ in 0..<2 { try await repository.closeConversation(conversationID: "27", clientRequestID: id) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 5)
    }
    func test关闭预读重复会话身份时零提交() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"users":[]}}"#),
            response(#"{"success":true,"data":{"channels":[{"channel_id":"27","type":"named","name":"Sample"},{"channel_id":"27","type":"named","name":"Sample"}]}}"#)])
        let repository = try makeRepository(transport: transport)
        do { try await repository.closeConversation(conversationID: "27", clientRequestID: UUID()); XCTFail("重复身份不得写入") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
    }
}
