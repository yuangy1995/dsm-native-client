import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

extension DsmChatRepositoryTests {
    func test持久文字发送写前与回执先保存且按稳定编号读取() async throws {
        for format in [DsmRequestFormat.form, .json] {
            let transport = MockHTTPTransport(responses: sendAccess() + [sendCreated()] + sendAccess() + [sendPosts()])
            let repository = try makeRepository(transport: transport, chatRequestFormat: format), recorder = SendReceiptRecorder()
            let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文")
            let result = try await repository.sendMessageResult(draft, progress: { _, _ in }) { value in
                let requests = await transport.recordedRequests()
                XCTAssertEqual(requests.count, value.candidateMessageID == nil ? 2 : 3)
                await recorder.append(value)
            }
            XCTAssertEqual(result.result.status, .confirmedSuccess)
            XCTAssertEqual(result.confirmedMessage?.clientRequestID, draft.clientRequestID)
            let receipts = await recorder.values
            XCTAssertEqual(receipts.count, 2); XCTAssertNil(receipts[0].candidateMessageID); XCTAssertEqual(receipts[1].candidateMessageID, "9001")
            let requests = await transport.recordedRequests(), create = try decodeForm(requests[2].httpBody)
            XCTAssertEqual(create["api"], DsmAPIName.chatPost); XCTAssertEqual(create["version"], "5")
            XCTAssertEqual(create["channel_id"], format == .json ? #""27""# : "27")
            let read = try decodeForm(XCTUnwrap(requests.last).httpBody)
            XCTAssertEqual(read["post_id"], format == .json ? #""9001""# : "9001")
            XCTAssertEqual(read["prev_count"], "0"); XCTAssertEqual(read["next_count"], "0")
        }
    }

    func test持久附件发送同一上传流程先保存再上传并验证名称大小() async throws {
        let file = try sendFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let transport = MockHTTPTransport(responses: sendAccess() + [sendCreated()] + sendAccess() + [sendPosts(attachment: true)])
        let repository = try makeRepository(transport: transport), recorder = SendReceiptRecorder()
        let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文", localAttachmentURLs: [file])
        let result = try await repository.sendAttachmentMessageResult(draft, progress: { _, _ in }) { value in
            let uploads = await transport.recordedUploadBodies()
            XCTAssertEqual(uploads.count, value.candidateMessageID == nil ? 0 : 1)
            XCTAssertNotNil(value.attachmentDigest)
            await recorder.append(value)
        }
        XCTAssertEqual(result.result.status, .confirmedSuccess)
        let bodies = await transport.recordedUploadBodies()
        let body = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"sample.txt\""))
        XCTAssertTrue(body.contains("DATA123")); XCTAssertEqual(bodies.count, 1)
        let receipts = await recorder.values; XCTAssertEqual(receipts.count, 2)
        try FileManager.default.removeItem(at: file)
        let restored = try makeRepository(transport: MockHTTPTransport(responses: sendAccess() + [sendPosts(attachment: true)]))
        let recovered = try await restored.recoverMessageSend(XCTUnwrap(receipts.last))
        XCTAssertEqual(recovered.result.status, .confirmedSuccess, "恢复不再依赖本机附件")
    }

    func test持久发送写前保存失败取消零写且允许原操作随后继续() async throws {
        let file = try sendFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for attachment in [false, true] {
            for cancelled in [false, true] {
                let transport = MockHTTPTransport(responses: sendAccess() + sendAccess() + [sendCreated()] + sendAccess() + [sendPosts(attachment: attachment)])
                let repository = try makeRepository(transport: transport)
                let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文", localAttachmentURLs: attachment ? [file] : [])
                let save: @Sendable (ChatMessageSendReceipt) async throws -> Void = { _ in
                    if cancelled { throw CancellationError() }
                    throw CocoaError(.fileWriteNoPermission)
                }
                do {
                    let result = try await attachment
                        ? repository.sendAttachmentMessageResult(draft, progress: { _, _ in }, recordProgress: save)
                        : repository.sendMessageResult(draft, progress: { _, _ in }, recordProgress: save)
                    XCTAssertTrue(attachment); XCTAssertFalse(result.result.submitted)
                } catch { XCTAssertFalse(attachment) }
                let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
                let result = try await attachment
                    ? repository.sendAttachmentMessageResult(draft, progress: { _, _ in }, recordProgress: { _ in })
                    : repository.sendMessageResult(draft, progress: { _, _ in }, recordProgress: { _ in })
                XCTAssertEqual(result.result.status, .confirmedSuccess)
            }
        }
    }

    func test丢失创建回执重建后不凭相同正文认领且同编号不能重发() async throws {
        let transport = MockHTTPTransport(steps: sendAccess().map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport: transport), recorder = SendReceiptRecorder()
        let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文")
        let result = try await repository.sendMessageResult(draft, progress: { _, _ in }) { await recorder.append($0) }
        XCTAssertEqual(result.result.status, .submittedButUnverified)
        let values = await recorder.values, receipt = try XCTUnwrap(values.last)
        XCTAssertNil(receipt.candidateMessageID)
        let newTransport = MockHTTPTransport(responses: [sendPosts()]), restored = try makeRepository(transport: newTransport)
        let recovered = try await restored.recoverMessageSend(receipt)
        let repeated = try await restored.sendMessageResult(draft)
        XCTAssertEqual(recovered.result.status, .submittedButUnverified); XCTAssertEqual(repeated.result.status, .submittedButUnverified)
        let requests = await newTransport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
        let originalRequests = await transport.recordedRequests(); XCTAssertEqual(originalRequests.count, 3)
    }

    func test收到回执后保存失败不丢编号重复调用只补保存与读取() async throws {
        let file = try sendFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for attachment in [false, true] {
            let transport = MockHTTPTransport(responses: sendAccess() + [sendCreated()] + sendAccess() + [sendPosts(attachment: attachment)])
            let repository = try makeRepository(transport: transport), recorder = SendReceiptRecorder()
            let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文", localAttachmentURLs: attachment ? [file] : [])
            let save: @Sendable (ChatMessageSendReceipt) async throws -> Void = { value in
                if value.candidateMessageID != nil { throw CocoaError(.fileWriteNoPermission) }
                await recorder.append(value)
            }
            do {
                _ = try await attachment
                    ? repository.sendAttachmentMessageResult(draft, progress: { _, _ in }, recordProgress: save)
                    : repository.sendMessageResult(draft, progress: { _, _ in }, recordProgress: save)
                XCTFail("回执未保存不能继续读并宣布完成")
            } catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteNoPermission) }
            let before = await transport.recordedRequests(); XCTAssertEqual(before.count, 3)
            let result = try await attachment
                ? repository.sendAttachmentMessageResult(draft, progress: { _, _ in }, recordProgress: { await recorder.append($0) })
                : repository.sendMessageResult(draft, progress: { _, _ in }, recordProgress: { await recorder.append($0) })
            XCTAssertEqual(result.result.status, .confirmedSuccess)
            let values = await recorder.values; XCTAssertEqual(values.count, 2); XCTAssertEqual(values.last?.candidateMessageID, "9001")
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 6)
        }
    }

    func test创建后读取权限拒绝保持未知重启恢复只读() async throws {
        let transport = MockHTTPTransport(responses: sendAccess() + [sendCreated(), response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport: transport), recorder = SendReceiptRecorder()
        let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文")
        let result = try await repository.sendMessageResult(draft, progress: { _, _ in }) { await recorder.append($0) }
        XCTAssertEqual(result.result.status, .submittedButUnverified); XCTAssertEqual(result.result.counts.failed, 0)
        let values = await recorder.values, receipt = try XCTUnwrap(values.last)
        let newTransport = MockHTTPTransport(responses: sendAccess() + [sendPosts()]), restored = try makeRepository(transport: newTransport)
        let recovered = try await restored.recoverMessageSend(receipt)
        XCTAssertEqual(recovered.result.status, .confirmedSuccess)
        let requests = await newTransport.recordedRequests()
        XCTAssertEqual(try requests.map { try decodeForm($0.httpBody)["method"] }, ["list", "list", "list"])
    }

    func test原账号缺失或会话加密不可见时不发送且旧缓存不充当当前本人() async throws {
        for setup in [sendAccess(user: nil), sendAccess(encrypted: true), sendAccess(channel: "42")] {
            let transport = MockHTTPTransport(responses: sendAccess() + setup), repository = try makeRepository(transport: transport)
            _ = try await repository.listConversations()
            do {
                _ = try await repository.sendMessageResult(ChatMessageDraft(conversationID: "27", text: "合成正文"), progress: { _, _ in }, recordProgress: { _ in XCTFail("不可准备发送") })
                XCTFail("权限和本人不明必须拒绝")
            } catch is AppError {}
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        }
    }

    func test回执正文作者线程对象和附件不一致全部保留未知() async throws {
        var receipt = try ChatMessageSendReceipt(draft: ChatMessageDraft(conversationID: "27", text: "合成正文"), currentUserID: "1")
        receipt.candidateMessageID = "9001"
        for post in [sendPosts(id: "other"), sendPosts(sender: "2"), sendPosts(text: "变化"), sendPosts(channel: "42"),
                     sendPosts(thread: "root"), sendPosts(attachment: true), sendPosts(own: false),
                     response(#"{"success":true,"data":{"posts":[]}}"#), response(#"{"success":true,"data":{"posts":{}}}"#)] {
            let transport = MockHTTPTransport(responses: sendAccess() + [post]), repository = try makeRepository(transport: transport)
            let result = try await repository.recoverMessageSend(receipt)
            XCTAssertEqual(result.result.status, .submittedButUnverified); XCTAssertNil(result.confirmedMessage)
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
        }
        let other = try makeRepository(transport: MockHTTPTransport(responses: sendAccess(user: "2")))
        let otherResult = try await other.recoverMessageSend(receipt); XCTAssertEqual(otherResult.result.status, .submittedButUnverified)
    }

    func test线程发送回执保存后按原线程读取不能混入主会话() async throws {
        let transport = MockHTTPTransport(responses: sendAccess() + [sendPosts(id: "root"), sendCreated()] + sendAccess() + [sendPosts(thread: "root")])
        let repository = try makeRepository(transport: transport), recorder = SendReceiptRecorder()
        let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文", threadID: "root")
        let outcome = try await repository.sendMessageResult(draft, progress: { _, _ in }) { await recorder.append($0) }
        XCTAssertEqual(outcome.result.status, .confirmedSuccess); XCTAssertEqual(outcome.confirmedMessage?.threadID, "root")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try decodeForm(requests[3].httpBody)["thread_id"], "root")
        XCTAssertEqual(try decodeForm(XCTUnwrap(requests.last).httpBody)["thread_id"], "root")
    }

    func test同操作编号不能换正文目标或候选消息且明确拒绝不会重发() async throws {
        let transport = MockHTTPTransport(responses: sendAccess() + [response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport: transport), draft = try ChatMessageDraft(conversationID: "27", text: "合成正文")
        let first = try await repository.sendMessageResult(draft, progress: { _, _ in }, recordProgress: { _ in })
        let second = try await repository.sendMessageResult(draft)
        XCTAssertEqual(first.result.status, .permissionDenied); XCTAssertEqual(first, second)
        for replacement in [try ChatMessageDraft(clientRequestID: draft.clientRequestID, conversationID: "42", text: "合成正文"),
                            try ChatMessageDraft(clientRequestID: draft.clientRequestID, conversationID: "27", text: "改动")] {
            do { _ = try await repository.sendMessageResult(replacement); XCTFail("同编号不可换内容") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
        let original = try ChatMessageSendReceipt(draft: draft, currentUserID: "1")
        let emptyTransport = MockHTTPTransport(responses: []), restored = try makeRepository(transport: emptyTransport)
        _ = try await restored.recoverMessageSend(original)
        var altered = original; altered.candidateMessageID = "first"
        _ = try await restored.recoverMessageSend(altered)
        altered.candidateMessageID = "second"
        do { _ = try await restored.recoverMessageSend(altered); XCTFail("候选身份不能替换") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
    }

    func test持久发送提交后取消保留未知且无任何第二次创建() async throws {
        let file = try sendFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for attachment in [false, true] {
            let transport = MockHTTPTransport(steps: sendAccess().map(MockHTTPTransport.Step.response) + [.waitUntilCancelled])
            let repository = try makeRepository(transport: transport), recorder = SendReceiptRecorder()
            let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文", localAttachmentURLs: attachment ? [file] : [])
            let task = Task {
                try await attachment
                    ? repository.sendAttachmentMessageResult(draft, progress: { _, _ in }, recordProgress: { await recorder.append($0) })
                    : repository.sendMessageResult(draft, progress: { _, _ in }, recordProgress: { await recorder.append($0) })
            }
            for _ in 0..<100 {
                if await transport.recordedRequests().count == 3 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let before = await transport.recordedRequests(); XCTAssertEqual(before.count, 3)
            task.cancel()
            let result = try await task.value; XCTAssertEqual(result.result.status, .cancellationRequestedAfterSubmission)
            let values = await recorder.values, receipt = try XCTUnwrap(values.last)
            let recovered = try await repository.recoverMessageSend(receipt)
            XCTAssertEqual(recovered.result.status, .submittedButUnverified)
            let after = await transport.recordedRequests(); XCTAssertEqual(after.count, 3)
        }
    }

    func test写前保存挂起时同编号的发送与恢复不会并发() async throws {
        let transport = MockHTTPTransport(responses: sendAccess() + [sendCreated()] + sendAccess() + [sendPosts()])
        let repository = try makeRepository(transport: transport), gate = SendReceiptGate()
        let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文")
        let task = Task { try await repository.sendMessageResult(draft, progress: { _, _ in }) { await gate.save($0) } }
        let receipt = await gate.waitForReceipt()
        do { _ = try await repository.sendMessageResult(draft); XCTFail("不能并发发送") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        do { _ = try await repository.recoverMessageSend(receipt); XCTFail("不能并发恢复") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let before = await transport.recordedRequests(); XCTAssertEqual(before.count, 2)
        await gate.release()
        let result = try await task.value; XCTAssertEqual(result.result.status, .confirmedSuccess)
    }

    func test旧文字发送回读越过最新百条且读取拒绝不释放重发() async throws {
        let newer = (1...100).map { "{\"post_id\":\"new-\($0)\",\"channel_id\":\"27\",\"message\":\"新消息\",\"create_at\":\(1_800_000_000 + $0)}" }.joined(separator: ",")
        let transport = MockHTTPTransport(responses: [sendCreated(), response(#"{"success":false,"error":{"code":105}}"#),
            response("{\"success\":true,\"data\":{\"posts\":[\(newer)]}}"), sendPosts()])
        let repository = try makeRepository(transport: transport), draft = try ChatMessageDraft(conversationID: "27", text: "合成正文")
        let first = try await repository.sendMessageResult(draft); XCTAssertEqual(first.result.status, .submittedButUnverified)
        let second = try await repository.sendMessageResult(draft); XCTAssertEqual(second.result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.map { try decodeForm($0.httpBody)["method"] }, ["create", "list", "list", "list"])
    }

    func test过期落盘回执恢复先补保存已收到编号且不依赖附件副本() async throws {
        let file = try sendFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let transport = MockHTTPTransport(responses: sendAccess() + [sendCreated()] + sendAccess() + [sendPosts(attachment: true)])
        let repository = try makeRepository(transport: transport), recorder = SendReceiptRecorder()
        let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文", localAttachmentURLs: [file])
        do {
            _ = try await repository.sendAttachmentMessageResult(draft, progress: { _, _ in }) { receipt in
                if receipt.candidateMessageID != nil { throw CocoaError(.fileWriteNoPermission) }
                await recorder.append(receipt)
            }
            XCTFail("回执保存失败不能返回成功")
        } catch is CocoaError {}
        try FileManager.default.removeItem(at: file)
        let values = await recorder.values, old = try XCTUnwrap(values.last)
        let outcome = try await repository.recoverMessageSend(old) { value in
            XCTAssertEqual(value.candidateMessageID, "9001")
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
            await recorder.append(value)
        }
        XCTAssertEqual(outcome.result.status, .confirmedSuccess)
        let final = await recorder.values; XCTAssertEqual(final.count, 2)
    }

    func test保存完成后实际提交前取消返回明确未发送() async throws {
        let transport = MockHTTPTransport(responses: sendAccess()), repository = try makeRepository(transport: transport)
        let gate = SendReceiptGate(), draft = try ChatMessageDraft(conversationID: "27", text: "合成正文")
        let task = Task { try await repository.sendMessageResult(draft, progress: { _, _ in }) { await gate.save($0) } }
        _ = await gate.waitForReceipt(); task.cancel(); await gate.release()
        let result = try await task.value
        XCTAssertEqual(result.result.status, .cancelledBeforeSubmission); XCTAssertFalse(result.result.submitted)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
    }

    func test附件创建明确拒绝同编号不重传而HTTP失败保留未知() async throws {
        let file = try sendFile(); defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        for rejected in [false, true] {
            let failure = rejected ? response(#"{"success":false,"error":{"code":105}}"#) : DsmHTTPResponse(data: Data(), statusCode: 503)
            let transport = MockHTTPTransport(responses: sendAccess() + [failure]), repository = try makeRepository(transport: transport)
            let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文", localAttachmentURLs: [file])
            let first = try await repository.sendAttachmentMessageResult(draft, progress: { _, _ in }, recordProgress: { _ in })
            let second = try await repository.sendAttachmentMessageResult(draft)
            XCTAssertEqual(first.result.status, rejected ? .permissionDenied : .submittedButUnverified)
            XCTAssertEqual(second.result.status, first.result.status)
            let uploads = await transport.recordedUploadBodies(); XCTAssertEqual(uploads.count, 1)
        }
    }

    func test附件回执使用实际传输名称避免引号转义后永久未知() async throws {
        let original = try sendFile(); defer { try? FileManager.default.removeItem(at: original.deletingLastPathComponent()) }
        let file = original.deletingLastPathComponent().appendingPathComponent("sample\"name.txt")
        try FileManager.default.moveItem(at: original, to: file)
        for durable in [false, true] {
            let transport = MockHTTPTransport(responses: (durable ? sendAccess() : []) + [sendCreated()] +
                (durable ? sendAccess() : []) + [sendPosts(attachment: true, attachmentName: "sample'name.txt")])
            let repository = try makeRepository(transport: transport)
            let draft = try ChatMessageDraft(conversationID: "27", text: "合成正文", localAttachmentURLs: [file])
            let result = try await durable
                ? repository.sendAttachmentMessageResult(draft, progress: { _, _ in }, recordProgress: { _ in })
                : repository.sendAttachmentMessageResult(draft)
            XCTAssertEqual(result.result.status, .confirmedSuccess)
            let bodies = await transport.recordedUploadBodies()
            XCTAssertTrue(String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self).contains("filename=\"sample'name.txt\""))
        }
    }

    private func sendAccess(user: String? = "1", channel: String = "27", encrypted: Bool = false) -> [DsmHTTPResponse] {
        [response("{\"success\":true,\"data\":{\"users\":[]\(user.map { ",\"current_user_id\":\"\($0)\"" } ?? "")}}"),
         response("{\"success\":true,\"data\":{\"channels\":[{\"channel_id\":\"\(channel)\",\"encrypted\":\(encrypted)}]}}")]
    }
    private func sendCreated() -> DsmHTTPResponse { response(#"{"success":true,"data":{"post_id":"9001"}}"#) }
    private func sendPosts(id: String = "9001", sender: String = "1", text: String = "合成正文", channel: String = "27",
                           thread: String? = nil, attachment: Bool = false, own: Bool = true, attachmentName: String = "sample.txt") -> DsmHTTPResponse {
        let threadField = thread.map { ",\"thread_id\":\"\($0)\"" } ?? ""
        let attachmentField = attachment ? #", "type":"file","file_props":{"file_id":"f-1","name":"\#(attachmentName)","size":7,"type":"txt"}"# : ""
        return response("{\"success\":true,\"data\":{\"posts\":[{\"post_id\":\"\(id)\",\"channel_id\":\"\(channel)\",\"creator_id\":\"\(sender)\",\"is_my_post\":\(own),\"message\":\"\(text)\",\"create_at\":1700000000\(threadField)\(attachmentField)}]}}")
    }
    private func sendFile() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ChatSendTest-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("sample.txt"); try Data("DATA123".utf8).write(to: file)
        return file
    }
}

private actor SendReceiptRecorder {
    var values: [ChatMessageSendReceipt] = []
    func append(_ value: ChatMessageSendReceipt) { values.append(value) }
}

private actor SendReceiptGate {
    private var receipt: ChatMessageSendReceipt?
    private var observer: CheckedContinuation<ChatMessageSendReceipt, Never>?
    private var barrier: CheckedContinuation<Void, Never>?
    func save(_ value: ChatMessageSendReceipt) async {
        guard value.candidateMessageID == nil else { return }
        receipt = value; observer?.resume(returning: value); observer = nil
        await withCheckedContinuation { barrier = $0 }
    }
    func waitForReceipt() async -> ChatMessageSendReceipt {
        if let receipt { return receipt }
        return await withCheckedContinuation { observer = $0 }
    }
    func release() { barrier?.resume(); barrier = nil }
}
