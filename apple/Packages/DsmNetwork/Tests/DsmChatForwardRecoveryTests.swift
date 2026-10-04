import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

extension DsmChatRepositoryTests {
    func test转发逐目标保存进度且JSON请求保持数字接收数组() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup(targets: ["42", "43"]) + [
            response(#"{"success":true}"#), forwardPosts([forwardPost(id: "new-42", channel: "42")]),
            forwardPosts([forwardPost(id: "new-43", channel: "43")])
        ])
        let repository = try makeRepository(transport: transport, chatRequestFormat: .json)
        let recorder = ForwardReceiptRecorder()
        let result = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["43", "42"], clientRequestID: UUID()) { value in
            let requests = await transport.recordedRequests()
            let writes = requests.filter {
                let body = $0.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return URLComponents(string: "?" + body)?.queryItems?.contains { $0.name == "method" && $0.value == "forward" } == true
            }
            XCTAssertEqual(writes.count, value.acknowledged ? 1 : 0)
            await recorder.record(value)
        }
        XCTAssertTrue(result.isComplete)
        let values = await recorder.values
        XCTAssertEqual(values.map(\.acknowledged), [false, true, true, true])
        XCTAssertEqual(values.map { $0.targets.compactMap(\.confirmedMessageID).count }, [0, 0, 1, 2])
        let requests = await transport.recordedRequests()
        let fields = try decodeForm(XCTUnwrap(requests.first { try decodeForm($0.httpBody)["method"] == "forward" }).httpBody)
        XCTAssertEqual(fields["post_id"], #""source""#)
        XCTAssertEqual(fields["channel_ids"], "[42,43]")
    }

    func test转发写前保存失败零请求写且不保留内存未知() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup() + forwardSetup() + [
            response(#"{"success":true}"#), forwardPosts([forwardPost()])
        ])
        let repository = try makeRepository(transport: transport); let id = UUID()
        do {
            _ = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: id) { _ in
                throw CocoaError(.fileWriteNoPermission)
            }
            XCTFail("保存失败必须阻止提交")
        } catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteNoPermission) }
        var requests = await transport.recordedRequests()
        XCTAssertFalse(try requests.contains { try decodeForm($0.httpBody)["method"] == "forward" })
        let value = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: id, recordProgress: { _ in })
        XCTAssertTrue(value.isComplete)
        requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.filter { try decodeForm($0.httpBody)["method"] == "forward" }.count, 1)
    }

    func test转发成功回执保存失败后同实例仅补保存与回读() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup() + [response(#"{"success":true}"#)] +
            forwardReadSetup() + [forwardPosts([forwardPost()])])
        let repository = try makeRepository(transport: transport); let recorder = ForwardReceiptRecorder()
        do {
            _ = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: UUID()) { value in
                if value.acknowledged { throw CocoaError(.fileWriteNoPermission) }
                await recorder.record(value)
            }
            XCTFail("不能越过回执保存失败")
        } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure); XCTAssertFalse(error.isRetryable) }
        let savedValues = await recorder.values; let saved = try XCTUnwrap(savedValues.last)
        XCTAssertFalse(saved.acknowledged)
        let result = try await repository.recoverForward(saved) { await recorder.record($0) }
        XCTAssertTrue(result.isComplete)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.filter { try decodeForm($0.httpBody)["method"] == "forward" }.count, 1)
    }

    func test转发丢回执或保存前重启不认领同内容也不重发() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup() + [DsmHTTPResponse(data: Data(), statusCode: 503)])
        let repository = try makeRepository(transport: transport); let recorder = ForwardReceiptRecorder()
        do {
            _ = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: UUID()) { await recorder.record($0) }
            XCTFail("必须保留未知")
        } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let values = await recorder.values; let saved = try XCTUnwrap(values.last)
        let freshTransport = MockHTTPTransport(responses: [])
        let fresh = try makeRepository(transport: freshTransport)
        for repo in [repository, fresh] {
            do { _ = try await repo.recoverForward(saved, recordProgress: { _ in }); XCTFail("无回执不作内容认领") }
            catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        }
        for id in [saved.clientRequestID, UUID()] {
            do { _ = try await fresh.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: id, recordProgress: { _ in }); XCTFail("导入未知记录后新编号也不能重发") }
            catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        }
        let requests = await transport.recordedRequests(), freshRequests = await freshTransport.recordedRequests()
        XCTAssertEqual(try requests.filter { try decodeForm($0.httpBody)["method"] == "forward" }.count, 1)
        XCTAssertTrue(freshRequests.isEmpty)
    }

    func test转发部分完成重启只读剩余目标且已关闭完成目标不阻塞() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup(targets: ["42", "43"]) + [
            response(#"{"success":true}"#), forwardPosts([forwardPost()]), DsmHTTPResponse(data: Data(), statusCode: 503)
        ])
        let repository = try makeRepository(transport: transport); let recorder = ForwardReceiptRecorder()
        do {
            _ = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42", "43"], clientRequestID: UUID()) { await recorder.record($0) }
            XCTFail("第二个目标未完成")
        } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let values = await recorder.values
        let saved = try JSONDecoder().decode(ChatForwardReceipt.self, from: JSONEncoder().encode(XCTUnwrap(values.last)))
        XCTAssertEqual(saved.targets[0].confirmedMessageID, "new-42"); XCTAssertNil(saved.targets[1].confirmedMessageID)
        let freshTransport = MockHTTPTransport(responses: forwardReadSetup(targets: ["43"]) + [forwardPosts([forwardPost(id: "new-43", channel: "43")])])
        let fresh = try makeRepository(transport: freshTransport)
        let result = try await fresh.recoverForward(saved, recordProgress: { _ in })
        XCTAssertTrue(result.isComplete)
        let requests = await freshTransport.recordedRequests(); XCTAssertEqual(requests.count, 3)
        let fields = try requests.map { try decodeForm($0.httpBody) }
        XCTAssertFalse(fields.contains { $0["method"] == "forward" })
        XCTAssertEqual(fields.last?["channel_id"], "43")
    }

    func test转发目标超过最新百条仍可恢复原消息() async throws {
        let now = Date(); let receipt = try forwardReceipt(now: now)
        let newest = (0..<100).map { forwardPost(id: "busy-\($0)", text: "无关消息", at: now.addingTimeInterval(Double($0 + 1))) }
        let transport = MockHTTPTransport(responses: forwardReadSetup() + [forwardPosts(newest), forwardPosts([forwardPost(at: now)])])
        let repository = try makeRepository(transport: transport)
        let result = try await repository.recoverForward(receipt, recordProgress: { _ in })
        XCTAssertEqual(result.targets[0].confirmedMessageID, "new-42")
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(try decodeForm(requests.last?.httpBody)["post_id"], "busy-0")
    }

    func test转发跨页同内容不唯一不得提前认领最新页() async throws {
        let now = Date(); let receipt = try forwardReceipt(now: now)
        var newest = (0..<99).map { forwardPost(id: "busy-\($0)", text: "无关消息", at: now.addingTimeInterval(Double($0 + 1))) }
        newest.append(forwardPost(id: "candidate-1", at: now.addingTimeInterval(2)))
        let transport = MockHTTPTransport(responses: forwardReadSetup() + [forwardPosts(newest), forwardPosts([forwardPost(id: "candidate-2", at: now)])])
        let repository = try makeRepository(transport: transport)
        do { _ = try await repository.recoverForward(receipt, recordProgress: { _ in }); XCTFail("两个候选不能猜测") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
    }

    func test转发回读排除旧消息其他人投票加密和附件种类不符() async throws {
        let now = Date()
        var foreign = forwardPost(at: now); foreign["creator_id"] = "2"
        var encrypted = forwardPost(at: now); encrypted["is_encrypted"] = true
        var poll = forwardPost(at: now); poll["props"] = ["vote": ["choices": [["id": "0", "text": "甲"], ["id": "1", "text": "乙"]]]]
        var attachment = forwardPost(at: now); attachment["file_props"] = ["file_id": "new-file", "name": "sample.png", "size": 7, "type": "png"]
        let cases = [foreign, encrypted, poll, attachment, forwardPost(at: now.addingTimeInterval(-181)), forwardPost(at: now.addingTimeInterval(181))]
        for post in cases {
            let transport = MockHTTPTransport(responses: forwardReadSetup() + [forwardPosts([post])])
            let repository = try makeRepository(transport: transport)
            do { _ = try await repository.recoverForward(forwardReceipt(now: now), recordProgress: { _ in }); XCTFail("错误内容不应被认领") }
            catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        }
    }

    func test转发历史基线以外但时间更早或相同的消息不能认领() async throws {
        let now = Date(), baselineDate = Date().addingTimeInterval(-60)
        let baseline = ChatMessage(id: "baseline", conversationID: "42", senderID: "1", sentAt: baselineDate, text: "旧内容")
        for date in [baselineDate, baselineDate.addingTimeInterval(-1)] {
            var receipt = try ChatForwardReceipt(original: forwardOriginal(), currentUserID: "1", clientRequestID: UUID(),
                targets: [.init(conversationID: "42", baseline: [baseline])], submittedAt: now)
            receipt.acknowledged = true
            let transport = MockHTTPTransport(responses: forwardReadSetup() + [forwardPosts([forwardPost(at: date)])])
            let repository = try makeRepository(transport: transport)
            do { _ = try await repository.recoverForward(receipt, recordProgress: { _ in }); XCTFail("旧基线之外并不等于新写") }
            catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        }
    }

    func test转发明确拒绝不保留待恢复且同请求可安全重新提交() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup() + [response(#"{"success":false,"error":{"code":105}}"#)] +
            forwardSetup() + [response(#"{"success":true}"#), forwardPosts([forwardPost()])])
        let repository = try makeRepository(transport: transport); let id = UUID()
        do { _ = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: id, recordProgress: { _ in }); XCTFail("应拒绝") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let result = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: id, recordProgress: { _ in })
        XCTAssertTrue(result.isComplete)
    }

    func test转发回执绑定当前账号且坏记录不读取或写入() async throws {
        let receipt = try forwardReceipt()
        let transport = MockHTTPTransport(responses: forwardReadSetup(userID: "9"))
        let repository = try makeRepository(transport: transport)
        do { _ = try await repository.recoverForward(receipt, recordProgress: { _ in }); XCTFail("不能恢复别人的操作") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        var broken = receipt; broken.targets = []
        do { _ = try await repository.recoverForward(broken, recordProgress: { _ in }); XCTFail("坏记录必须拒绝") }
        catch is CocoaError { }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
    }

    func test转发旧能力来源内容变化和受保护目标均零写() async throws {
        let unsupported = MockHTTPTransport(responses: [])
        let old = try makeRepository(transport: unsupported, chatPostVersion: 4)
        do { _ = try await old.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: UUID(), recordProgress: { _ in }); XCTFail("旧版本不可写") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let unsupportedRequests = await unsupported.recordedRequests(); XCTAssertTrue(unsupportedRequests.isEmpty)
        for setup in [forwardReadSetup() + [forwardPosts([forwardPost(id: "source", channel: "27", text: "已变化")])], forwardReadSetup(encrypted: true)] {
            let transport = MockHTTPTransport(responses: setup)
            let repository = try makeRepository(transport: transport)
            do { _ = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: UUID(), recordProgress: { _ in }); XCTFail("目标变化不可提交") }
            catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let requests = await transport.recordedRequests()
            XCTAssertFalse(try requests.contains { try decodeForm($0.httpBody)["method"] == "forward" })
        }
    }

    func test转发已完成请求拒绝改变来源或接收人且重试不写() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup() + [response(#"{"success":true}"#), forwardPosts([forwardPost()])])
        let repository = try makeRepository(transport: transport); let id = UUID()
        for _ in 0..<2 {
            let result = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: id, recordProgress: { _ in })
            XCTAssertTrue(result.isComplete)
        }
        do { _ = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["43"], clientRequestID: id, recordProgress: { _ in }); XCTFail("不能改目标复用编号") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let changed = ChatMessage(id: "source", conversationID: "27", senderID: "1", sentAt: Date(), text: "已改变")
        do { _ = try await repository.forwardMessage(changed, toConversationIDs: ["42"], clientRequestID: id, recordProgress: { _ in }); XCTFail("不能改正文复用编号") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 6)
    }

    func test转发线程来源使用原线程重读且保存前取消零写() async throws {
        let source = forwardOriginal(threadID: "root")
        var post = forwardPost(id: "source", channel: "27", at: source.sentAt); post["thread_id"] = "root"
        let transport = MockHTTPTransport(responses: forwardReadSetup() + [forwardPosts([post]), forwardPosts([])])
        let repository = try makeRepository(transport: transport)
        do {
            _ = try await repository.forwardMessage(source, toConversationIDs: ["42"], clientRequestID: UUID()) { _ in throw CancellationError() }
            XCTFail("取消不允许写入")
        } catch is CancellationError { }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try decodeForm(requests[2].httpBody)["thread_id"], "root")
        XCTAssertFalse(try requests.contains { try decodeForm($0.httpBody)["method"] == "forward" })
    }

    func test转发保存中重复点击与并发恢复均不越过原操作() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup() + [response(#"{"success":true}"#), forwardPosts([forwardPost()])])
        let repository = try makeRepository(transport: transport), source = forwardOriginal()
        let gate = ForwardReceiptGate()
        let work = Task {
            try await repository.forwardMessage(source, toConversationIDs: ["42"], clientRequestID: UUID()) { value in
                if !value.acknowledged { await gate.pause(value) }
            }
        }
        let pending = await gate.waitUntilPaused()
        do { _ = try await repository.forwardMessage(source, toConversationIDs: ["42"], clientRequestID: UUID(), recordProgress: { _ in }); XCTFail("重复点击不能新发") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        do { _ = try await repository.recoverForward(pending, recordProgress: { _ in }); XCTFail("请求执行中不能提前恢复") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        await gate.resume()
        let result = try await work.value; XCTAssertTrue(result.isComplete)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 6)
    }

    func test转发保存后实际取消仍是零写且可安全重新开始() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup() + forwardSetup() + [response(#"{"success":true}"#), forwardPosts([forwardPost()])])
        let repository = try makeRepository(transport: transport), source = forwardOriginal(), id = UUID()
        let gate = ForwardReceiptGate()
        let work = Task {
            try await repository.forwardMessage(source, toConversationIDs: ["42"], clientRequestID: id) { value in await gate.pause(value) }
        }
        _ = await gate.waitUntilPaused(); work.cancel(); await gate.resume()
        do { _ = try await work.value; XCTFail("已取消不能发送") } catch is CancellationError { }
        let firstRequests = await transport.recordedRequests()
        XCTAssertFalse(try firstRequests.contains { try decodeForm($0.httpBody)["method"] == "forward" })
        let result = try await repository.forwardMessage(source, toConversationIDs: ["42"], clientRequestID: id, recordProgress: { _ in })
        XCTAssertTrue(result.isComplete)
    }

    func test转发回读首个目标坏分页仍保存其他目标成功() async throws {
        let now = Date()
        var receipt = try ChatForwardReceipt(original: forwardOriginal(), currentUserID: "1", clientRequestID: UUID(),
            targets: [.init(conversationID: "42", baseline: []), .init(conversationID: "43", baseline: [])], submittedAt: now)
        receipt.acknowledged = true
        let first = (0..<100).map { forwardPost(id: "busy-\($0)", text: "无关", at: now.addingTimeInterval(Double($0 + 1))) }
        let transport = MockHTTPTransport(responses: forwardReadSetup(targets: ["42", "43"]) + [forwardPosts(first),
            forwardPosts([forwardPost(id: "busy-1", at: now)]), forwardPosts([forwardPost(id: "new-43", channel: "43", at: now)])])
        let repository = try makeRepository(transport: transport), recorder = ForwardReceiptRecorder()
        do { _ = try await repository.recoverForward(receipt) { await recorder.record($0) }; XCTFail("坏分页不能误报全部完成") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let values = await recorder.values; let saved = try XCTUnwrap(values.last)
        XCTAssertNil(saved.targets[0].confirmedMessageID); XCTAssertEqual(saved.targets[1].confirmedMessageID, "new-43")
    }

    func test转发最终进度保存失败后补存释放来源占用() async throws {
        let transport = MockHTTPTransport(responses: forwardSetup() + [response(#"{"success":true}"#), forwardPosts([forwardPost()])] +
            forwardSetup() + [response(#"{"success":true}"#), forwardPosts([forwardPost(id: "new-again")])])
        let repository = try makeRepository(transport: transport); let id = UUID()
        do {
            _ = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: id) { value in
                if value.isComplete { throw CocoaError(.fileWriteNoPermission) }
            }
            XCTFail("最终记录未保存不能结束")
        } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        _ = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: id, recordProgress: { _ in })
        let second = try await repository.forwardMessage(forwardOriginal(), toConversationIDs: ["42"], clientRequestID: UUID(), recordProgress: { _ in })
        XCTAssertEqual(second.targets[0].confirmedMessageID, "new-again")
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 12)
    }

    private func forwardOriginal(threadID: String? = nil) -> ChatMessage {
        ChatMessage(id: "source", conversationID: "27", senderID: "1", isFromCurrentUser: true,
                    sentAt: Date(timeIntervalSince1970: 1_700_000_000), text: "转发示例", threadID: threadID)
    }
    private func forwardReceipt(now: Date = Date()) throws -> ChatForwardReceipt {
        var value = try ChatForwardReceipt(original: forwardOriginal(), currentUserID: "1", clientRequestID: UUID(),
                                           targets: [.init(conversationID: "42", baseline: [])], submittedAt: now)
        value.acknowledged = true; return value
    }
    private func forwardPost(id: String = "new-42", channel: String = "42", text: String = "转发示例", at: Date = Date()) -> [String: Any] {
        ["post_id": id, "channel_id": channel, "creator_id": "1", "is_my_post": true, "message": text,
         "create_at": Int64(at.timeIntervalSince1970 * 1_000)]
    }
    private func forwardPosts(_ posts: [[String: Any]]) -> DsmHTTPResponse {
        DsmHTTPResponse(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["posts": posts]]), statusCode: 200)
    }
    private func forwardReadSetup(targets: [String] = ["42"], userID: String = "1", encrypted: Bool = false) -> [DsmHTTPResponse] {
        [response("{\"success\":true,\"data\":{\"current_user_id\":\"\(userID)\",\"users\":[]}}"),
         DsmHTTPResponse(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": ["channels":
             (["27"] + targets).map { ["channel_id": $0, "is_encrypted": encrypted && $0 != "27"] }]]), statusCode: 200)]
    }
    private func forwardSetup(targets: [String] = ["42"]) -> [DsmHTTPResponse] {
        forwardReadSetup(targets: targets) + [forwardPosts([forwardPost(id: "source", channel: "27", at: forwardOriginal().sentAt)])] + targets.map { _ in forwardPosts([]) }
    }
}

private actor ForwardReceiptRecorder {
    var values: [ChatForwardReceipt] = []
    func record(_ value: ChatForwardReceipt) { values.append(value) }
}

private actor ForwardReceiptGate {
    private var value: ChatForwardReceipt?
    private var observer: CheckedContinuation<ChatForwardReceipt, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func pause(_ value: ChatForwardReceipt) async {
        self.value = value; observer?.resume(returning: value); observer = nil
        await withCheckedContinuation { waiter = $0 }
    }
    func waitUntilPaused() async -> ChatForwardReceipt {
        if let value { return value }
        return await withCheckedContinuation { observer = $0 }
    }
    func resume() { waiter?.resume(); waiter = nil }
}
