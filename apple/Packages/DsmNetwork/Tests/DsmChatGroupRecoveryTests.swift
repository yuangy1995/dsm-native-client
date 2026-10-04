import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

extension DsmChatRepositoryTests {
    func test持久建群每步写前和回执先保存并保持两种请求编码() async throws {
        for format in [DsmRequestFormat.form, .json] {
            let transport = MockHTTPTransport(responses: [groupUsers(), groupCreated(), groupOK(), groupOK()] + groupRead())
            let repository = try makeRepository(transport: transport, chatRequestFormat: format), recorder = GroupReceiptRecorder()
            let draft = try groupDraft()
            let outcome = try await repository.createGroupResult(draft) { receipt in
                let requests = await transport.recordedRequests()
                let expected = [1, 2, 2, 3, 3, 4]
                XCTAssertEqual(requests.count, expected[receipt.revision])
                await recorder.append(receipt)
            }
            XCTAssertEqual(outcome.result.status, .confirmedSuccess); XCTAssertEqual(outcome.confirmedConversation?.id, "42")
            let values = await recorder.values
            XCTAssertEqual(values.count, 6); XCTAssertEqual(values.map(\.revision), [0, 1, 2, 3, 4, 5])
            XCTAssertEqual(values[0].create, .submitted); XCTAssertNil(values[0].candidateConversationID)
            XCTAssertEqual(values[1].candidateConversationID, "42"); XCTAssertEqual(values[2].join, .submitted)
            XCTAssertEqual(values[3].join, .completed); XCTAssertEqual(values[4].invite, .submitted)
            XCTAssertEqual(values[5].invite, .completed)
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 7)
            let fields = try requests[1...3].map { try decodeForm($0.httpBody) }
            XCTAssertEqual(fields.map { $0["method"] }, ["create", "join", "invite"])
            XCTAssertTrue(fields.allSatisfy { $0["version"] == "1" })
            XCTAssertEqual(fields[0]["name"], format == .json ? #""合成群聊""# : "合成群聊")
            XCTAssertEqual(fields[1]["channel_id"], format == .json ? #""42""# : "42")
            XCTAssertEqual(fields[2]["user_ids"], #"["2","3"]"#); XCTAssertEqual(fields[2]["channel_key_encs"], "[]")
        }
    }

    func test持久建群创建丢回执重启不凭同名或成员认领也不重发() async throws {
        let transport = MockHTTPTransport(steps: [.response(groupUsers()), .urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport: transport), recorder = GroupReceiptRecorder(), draft = try groupDraft()
        let first = try await repository.createGroupResult(draft) { await recorder.append($0) }
        XCTAssertEqual(first.result.status, .submittedButUnverified)
        let values = await recorder.values, receipt = try XCTUnwrap(values.last)
        let restoredTransport = MockHTTPTransport(responses: groupRead()), restored = try makeRepository(transport: restoredTransport)
        let recovered = try await restored.recoverGroupCreation(receipt, recordProgress: { _ in })
        let repeated = try await restored.createGroupResult(draft)
        let continued = try await restored.continueGroupCreation(draft, receipt: receipt, recordProgress: { _ in })
        for value in [recovered, repeated, continued] {
            XCTAssertEqual(value.result.status, .submittedButUnverified); XCTAssertNil(value.confirmedConversation)
        }
        let requests = await restoredTransport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
    }

    func test持久建群加入未知只能读取证实后主动继续邀请() async throws {
        let transport = MockHTTPTransport(steps: [.response(groupUsers()), .response(groupCreated()), .urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport: transport), recorder = GroupReceiptRecorder(), draft = try groupDraft()
        _ = try await repository.createGroupResult(draft) { await recorder.append($0) }
        let before = await recorder.values, receipt = try XCTUnwrap(before.last)
        XCTAssertEqual(receipt.join, .submitted)
        let restoredTransport = MockHTTPTransport(responses: groupRead(members: ["1"]) + groupRead(members: ["1"])
            + [groupUsers(), groupOK()] + groupRead())
        let restored = try makeRepository(transport: restoredTransport), recoveredRecorder = GroupReceiptRecorder()
        let result = try await restored.recoverGroupCreation(receipt) { await recoveredRecorder.append($0) }
        XCTAssertEqual(result.result.status, .submittedButUnverified)
        let readRequests = await restoredTransport.recordedRequests(); XCTAssertEqual(readRequests.count, 3)
        let updated = await recoveredRecorder.values
        XCTAssertEqual(updated.last?.join, .completed); XCTAssertEqual(updated.last?.invite, .ready)
        let complete = try await restored.continueGroupCreation(draft, receipt: receipt, recordProgress: { _ in })
        XCTAssertEqual(complete.result.status, .confirmedSuccess)
        let methods = try await groupWriteMethods(restoredTransport); XCTAssertEqual(methods, ["invite"])
    }

    func test持久建群未知加入没有本人或未知邀请缺成员均不能继续写() async throws {
        for joining in [true, false] {
            var receipt = try groupReceipt()
            receipt.join = joining ? .submitted : .completed
            receipt.invite = joining ? .ready : .submitted
            let members = joining ? ["2", "3"] : ["1", "2"]
            let transport = MockHTTPTransport(responses: groupRead(members: members) + groupRead(members: members))
            let repository = try makeRepository(transport: transport)
            let read = try await repository.recoverGroupCreation(receipt, recordProgress: { _ in })
            let continued = try await repository.continueGroupCreation(groupDraft(id: receipt.clientRequestID), receipt: receipt, recordProgress: { _ in })
            XCTAssertEqual(read.result.status, .submittedButUnverified); XCTAssertEqual(continued.result.status, .submittedButUnverified)
            let methods = try await groupWriteMethods(transport); XCTAssertTrue(methods.isEmpty)
        }
    }

    func test持久建群未知邀请完整回读可完成且不重复邀请() async throws {
        var receipt = try groupReceipt(); receipt.join = .completed; receipt.invite = .submitted
        let transport = MockHTTPTransport(responses: groupRead()), repository = try makeRepository(transport: transport), recorder = GroupReceiptRecorder()
        let result = try await repository.recoverGroupCreation(receipt) { await recorder.append($0) }
        XCTAssertEqual(result.result.status, .confirmedSuccess)
        let values = await recorder.values; XCTAssertEqual(values.last?.invite, .completed)
        let methods = try await groupWriteMethods(transport); XCTAssertTrue(methods.isEmpty)
    }

    func test持久建群邀请明确拒绝后只补缺少成员不重建不重入群() async throws {
        let transport = MockHTTPTransport(responses: [groupUsers(), groupCreated(), groupOK(), response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport: transport), recorder = GroupReceiptRecorder(), draft = try groupDraft()
        let first = try await repository.createGroupResult(draft) { await recorder.append($0) }
        XCTAssertEqual(first.result.status, .submittedButUnverified); XCTAssertEqual(first.result.errorCategory, .permission)
        let values = await recorder.values, receipt = try XCTUnwrap(values.last)
        XCTAssertEqual(receipt.invite, .rejected)
        let resumedTransport = MockHTTPTransport(responses: groupRead(members: ["1", "2"]) + [groupUsers(), groupOK()] + groupRead())
        let resumed = try makeRepository(transport: resumedTransport)
        let complete = try await resumed.continueGroupCreation(draft, receipt: receipt, recordProgress: { _ in })
        XCTAssertEqual(complete.result.status, .confirmedSuccess)
        let requests = await resumedTransport.recordedRequests(), write = try decodeForm(requests[4].httpBody)
        XCTAssertEqual(write["method"], "invite"); XCTAssertEqual(write["user_ids"], #"["3"]"#)
        let methods = try await groupWriteMethods(resumedTransport); XCTAssertEqual(methods, ["invite"])
    }

    func test持久建群明确创建拒绝跨重启仍为终态() async throws {
        let transport = MockHTTPTransport(responses: [groupUsers(), response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport: transport), recorder = GroupReceiptRecorder(), draft = try groupDraft()
        let denied = try await repository.createGroupResult(draft) { await recorder.append($0) }
        XCTAssertEqual(denied.result.status, .permissionDenied)
        let values = await recorder.values, receipt = try XCTUnwrap(values.last)
        let restoredTransport = MockHTTPTransport(responses: []), restored = try makeRepository(transport: restoredTransport)
        let outcome = try await restored.recoverGroupCreation(receipt, recordProgress: { _ in })
        let repeated = try await restored.createGroupResult(draft, recordProgress: { _ in })
        XCTAssertEqual(outcome.result.status, .permissionDenied); XCTAssertEqual(repeated, outcome)
        let requests = await restoredTransport.recordedRequests(); XCTAssertTrue(requests.isEmpty)
    }

    func test持久建群各步骤写前保存失败零该步骤请求() async throws {
        for stoppedRevision in [0, 2, 4] {
            let responses = [groupUsers(), groupCreated(), groupOK(), groupOK()] + groupRead()
            let transport = MockHTTPTransport(responses: responses), repository = try makeRepository(transport: transport)
            do {
                _ = try await repository.createGroupResult(groupDraft()) { receipt in
                    if receipt.revision == stoppedRevision { throw CocoaError(.fileWriteNoPermission) }
                }
                XCTFail("写前保存失败必须终止")
            } catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteNoPermission) }
            let methods = try await groupWriteMethods(transport)
            XCTAssertEqual(methods, Array(["create", "join"].prefix(stoppedRevision / 2)))
        }
    }

    func test持久建群收到编号保存失败不执行加入且旧副本可补保存() async throws {
        let transport = MockHTTPTransport(responses: [groupUsers(), groupCreated()] + groupRead(members: ["1"]))
        let repository = try makeRepository(transport: transport), recorder = GroupReceiptRecorder(), draft = try groupDraft()
        do {
            _ = try await repository.createGroupResult(draft) { receipt in
                if receipt.candidateConversationID != nil { throw CocoaError(.fileWriteNoPermission) }
                await recorder.append(receipt)
            }
            XCTFail("收到编号必须先保存")
        } catch let error as CocoaError { XCTAssertEqual(error.code, .fileWriteNoPermission) }
        let values = await recorder.values, old = try XCTUnwrap(values.last)
        XCTAssertNil(old.candidateConversationID)
        _ = try await repository.recoverGroupCreation(old) { await recorder.append($0) }
        let refreshed = await recorder.values; XCTAssertEqual(refreshed.last?.candidateConversationID, "42")
        let methods = try await groupWriteMethods(transport); XCTAssertEqual(methods, ["create"])
    }

    func test持久建群恢复拒绝同名异编号加密群错账号和标题变化() async throws {
        let cases = [groupRead(channel: "43"), groupRead(encrypted: true), groupRead(user: "4"), groupRead(title: "另一个群")]
        for responses in cases {
            let receipt = try groupReceipt(), transport = MockHTTPTransport(responses: responses)
            let repository = try makeRepository(transport: transport)
            let outcome = try await repository.continueGroupCreation(groupDraft(id: receipt.clientRequestID), receipt: receipt, recordProgress: { _ in })
            XCTAssertEqual(outcome.result.status, .submittedButUnverified); XCTAssertNil(outcome.confirmedConversation)
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
            let methods = try await groupWriteMethods(transport); XCTAssertTrue(methods.isEmpty)
        }
    }

    func test持久建群已完成加入被移出不会重加或邀请() async throws {
        var receipt = try groupReceipt(); receipt.join = .completed
        let transport = MockHTTPTransport(responses: groupRead(members: ["2"])), repository = try makeRepository(transport: transport)
        let outcome = try await repository.continueGroupCreation(groupDraft(id: receipt.clientRequestID), receipt: receipt, recordProgress: { _ in })
        XCTAssertEqual(outcome.result.status, .submittedButUnverified)
        let methods = try await groupWriteMethods(transport); XCTAssertTrue(methods.isEmpty)
    }

    func test持久建群重复编号不接受改变草稿账号或候选() async throws {
        let transport = MockHTTPTransport(responses: groupRead(members: ["1"])), repository = try makeRepository(transport: transport)
        let receipt = try groupReceipt()
        _ = try await repository.recoverGroupCreation(receipt, recordProgress: { _ in })
        let wrongDraft = try ChatGroupDraft(clientRequestID: receipt.clientRequestID, title: "另一个群", memberIDs: ["2", "3"], isEncrypted: false)
        do { _ = try await repository.createGroupResult(wrongDraft, recordProgress: { _ in }); XCTFail("不能改变草稿") } catch is AppError {}
        let legacy = try await repository.createGroupResult(wrongDraft)
        XCTAssertEqual(legacy.result.errorCategory, .validation)
        var wrongCandidate = receipt; wrongCandidate.candidateConversationID = "43"
        do { _ = try await repository.recoverGroupCreation(wrongCandidate, recordProgress: { _ in }); XCTFail("不能替换群聊") } catch is AppError {}
        var wrongUser = try ChatGroupCreateReceipt(draft: groupDraft(id: receipt.clientRequestID), currentUserID: "4")
        wrongUser.create = .completed; wrongUser.candidateConversationID = "42"
        do { _ = try await repository.recoverGroupCreation(wrongUser, recordProgress: { _ in }); XCTFail("不能替换账号") } catch is AppError {}
        let methods = try await groupWriteMethods(transport); XCTAssertTrue(methods.isEmpty)
    }

    func test持久建群当前用户缺失不借旧缓存通过预检() async throws {
        let transport = MockHTTPTransport(responses: [groupUsers(), groupUsers(user: nil)])
        let repository = try makeRepository(transport: transport)
        _ = try await repository.listUsers()
        do {
            _ = try await repository.createGroupResult(groupDraft()) { _ in XCTFail("不能保存提交身份") }
            XCTFail("当前用户不明确必须拒绝")
        } catch is AppError {}
        let methods = try await groupWriteMethods(transport); XCTAssertTrue(methods.isEmpty)
    }

    func test持久建群加入117继续但邀请117不能当作完成() async throws {
        let already = response(#"{"success":false,"error":{"code":117}}"#)
        for joinAlready in [true, false] {
            let responses = [groupUsers(), groupCreated(), joinAlready ? already : groupOK(), joinAlready ? groupOK() : already]
                + (joinAlready ? groupRead() : [])
            let transport = MockHTTPTransport(responses: responses), repository = try makeRepository(transport: transport)
            let result = try await repository.createGroupResult(groupDraft(), recordProgress: { _ in })
            XCTAssertEqual(result.result.status, joinAlready ? .confirmedSuccess : .submittedButUnverified)
            let methods = try await groupWriteMethods(transport); XCTAssertEqual(methods, ["create", "join", "invite"])
        }
    }

    func test持久建群回读权限丢失不能变为创建失败() async throws {
        let transport = MockHTTPTransport(responses: [groupUsers(), groupCreated(), groupOK(), groupOK(), response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport: transport), recorder = GroupReceiptRecorder()
        let outcome = try await repository.createGroupResult(groupDraft()) { await recorder.append($0) }
        XCTAssertEqual(outcome.result.status, .submittedButUnverified); XCTAssertEqual(outcome.result.counts.failed, 0)
        let values = await recorder.values; XCTAssertEqual(values.last?.invite, .completed)
    }

    func test持久建群各步保存期间取消没有该步写入并保留可恢复进度() async throws {
        for stoppedRevision in [0, 2, 4] {
            let transport = MockHTTPTransport(responses: [groupUsers(), groupCreated(), groupOK(), groupOK()] + groupRead())
            let repository = try makeRepository(transport: transport), gate = GroupSubmissionGate(), recorder = GroupReceiptRecorder(), draft = try groupDraft()
            let task = Task {
                try await repository.createGroupResult(draft) { receipt in
                    await recorder.append(receipt)
                    if receipt.revision == stoppedRevision { await gate.pause() }
                }
            }
            await gate.waitUntilPaused(); task.cancel(); await gate.resume()
            let result = try await task.value
            XCTAssertEqual(result.result.status, stoppedRevision == 0 ? .cancelledBeforeSubmission : .cancellationRequestedAfterSubmission)
            let methods = try await groupWriteMethods(transport)
            XCTAssertEqual(methods, Array(["create", "join"].prefix(stoppedRevision / 2)))
            if stoppedRevision > 0 {
                let values = await recorder.values, last = try XCTUnwrap(values.last)
                XCTAssertTrue(last.canContinue)
                XCTAssertEqual(stoppedRevision == 2 ? last.join : last.invite, .ready)
            }
        }
    }

    func test持久建群并发重复调用只提交一组且后一次只回读() async throws {
        let transport = MockHTTPTransport(responses: [groupUsers(), groupCreated(), groupOK(), groupOK()] + groupRead() + groupRead())
        let repository = try makeRepository(transport: transport), gate = GroupSubmissionGate(), draft = try groupDraft()
        let first = Task {
            try await repository.createGroupResult(draft) { receipt in
                if receipt.revision == 0 { await gate.pause() }
            }
        }
        await gate.waitUntilPaused()
        let second = Task { try await repository.createGroupResult(draft, recordProgress: { _ in }) }
        await Task.yield(); await gate.resume()
        let results = try await [first.value, second.value]
        XCTAssertTrue(results.allSatisfy { $0.result.status == .confirmedSuccess })
        let methods = try await groupWriteMethods(transport); XCTAssertEqual(methods, ["create", "join", "invite"])
    }

    func test持久建群写能力撤回后仍可只读完成但不可继续未完步骤() async throws {
        var receipt = try groupReceipt(); receipt.join = .completed; receipt.invite = .submitted
        let transport = MockHTTPTransport(responses: groupRead()), repository = try makeRepository(transport: transport, includesChatNamedCapability: false)
        let complete = try await repository.recoverGroupCreation(receipt, recordProgress: { _ in })
        XCTAssertEqual(complete.result.status, .confirmedSuccess)
        let ready = try groupReceipt(), otherTransport = MockHTTPTransport(responses: groupRead(members: ["1"]))
        let other = try makeRepository(transport: otherTransport, includesChatNamedCapability: false)
        let pending = try await other.continueGroupCreation(groupDraft(id: ready.clientRequestID), receipt: ready, recordProgress: { _ in })
        XCTAssertEqual(pending.result.status, .submittedButUnverified)
        let methods = try await groupWriteMethods(otherTransport); XCTAssertTrue(methods.isEmpty)
    }

    func test持久建群未执行加入时可续建且全部成员已在群内无需再邀请() async throws {
        let receipt = try groupReceipt(), transport = MockHTTPTransport(responses: groupRead(members: ["2", "3"])
            + [groupUsers(), groupOK()] + groupRead())
        let repository = try makeRepository(transport: transport)
        let result = try await repository.continueGroupCreation(groupDraft(id: receipt.clientRequestID), receipt: receipt, recordProgress: { _ in })
        XCTAssertEqual(result.result.status, .confirmedSuccess)
        let methods = try await groupWriteMethods(transport); XCTAssertEqual(methods, ["join"])
    }

    private func groupDraft(id: UUID = UUID()) throws -> ChatGroupDraft {
        try ChatGroupDraft(clientRequestID: id, title: "合成群聊", memberIDs: ["2", "3"], isEncrypted: false)
    }
    private func groupReceipt() throws -> ChatGroupCreateReceipt {
        var value = try ChatGroupCreateReceipt(draft: groupDraft(), currentUserID: "1")
        value.create = .completed; value.candidateConversationID = "42"; value.revision = 1
        return value
    }
    private func groupOK() -> DsmHTTPResponse { response(#"{"success":true}"#) }
    private func groupCreated() -> DsmHTTPResponse { response(#"{"success":true,"data":{"channel_id":"42"}}"#) }
    private func groupUsers(user: String? = "1") -> DsmHTTPResponse {
        let identity = user.map { "\"current_user_id\":\"\($0)\"," } ?? ""
        return response("{\"success\":true,\"data\":{\(identity)\"users\":[{\"user_id\":\"1\"},{\"user_id\":\"2\"},{\"user_id\":\"3\"},{\"user_id\":\"4\"}]}}")
    }
    private func groupRead(channel: String = "42", members: [String] = ["1", "2", "3"], user: String? = "1",
                           encrypted: Bool = false, title: String = "合成群聊") -> [DsmHTTPResponse] {
        let ids = String(decoding: try! JSONEncoder().encode(members), as: UTF8.self)
        return [groupUsers(user: user), response("{\"success\":true,\"data\":{\"channels\":[{\"channel_id\":\"\(channel)\",\"type\":\"private\",\"name\":\"\(title)\",\"encrypted\":\(encrypted)}]}}"),
                response("{\"success\":true,\"data\":{\"user_ids\":\(ids)}}")]
    }
    private func groupWriteMethods(_ transport: MockHTTPTransport) async throws -> [String] {
        try await transport.recordedRequests().compactMap { try decodeForm($0.httpBody)["method"] }
            .filter { ["create", "join", "invite"].contains($0) }
    }
}

private actor GroupReceiptRecorder {
    private(set) var values: [ChatGroupCreateReceipt] = []
    func append(_ value: ChatGroupCreateReceipt) { values.append(value) }
}

private actor GroupSubmissionGate {
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
