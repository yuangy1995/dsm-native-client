import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

extension DsmChatRepositoryTests {
    func test提醒写入后必须读回相同消息和时间且同请求不重复写() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"posts":[{"post_id":"target","channel_id":"27","message":"提醒测试","create_at":1700000000}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"reminders":[{"post_id":"target","remind_at":1800000000000}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        _ = try await repository.listMessages(conversationID: "27", before: nil, limit: 50)
        let id = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try await repository.setReminder(messageID: "target", remindAt: time, clientRequestID: id)
        let second = try await repository.setReminder(messageID: "target", remindAt: time, clientRequestID: id)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.remindAt, time)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(try decodeForm(requests[1].httpBody)["method"], "set")
        XCTAssertEqual(try decodeForm(requests[2].httpBody)["method"], "list")
    }

    func test提醒回读时间不符不能构造成功结果且后续只读取() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"posts":[{"post_id":"target","channel_id":"27","message":"提醒测试","create_at":1700000000}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"reminders":[{"post_id":"target","remind_at":1800000100000}]}}"#),
            response(#"{"success":true,"data":{"reminders":[{"post_id":"target","remind_at":1800000000000}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        _ = try await repository.listMessages(conversationID: "27", before: nil, limit: 50)
        let id = UUID(), time = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            _ = try await repository.setReminder(messageID: "target", remindAt: time, clientRequestID: id)
            XCTFail("时间不一致不能显示保存成功")
        } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let reminder = try await repository.setReminder(messageID: "target", remindAt: time, clientRequestID: id)
        XCTAssertEqual(reminder.remindAt, time)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.map { try decodeForm($0.httpBody)["method"] }, ["list", "set", "list", "list"])
    }

    func test定时消息无稳定回执不能认领相同内容也不重新创建() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"schedules":[]}}"#),
            response(#"{"success":true,"data":{}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let id = UUID()
        let sendAt = Date().addingTimeInterval(3_600)
        for _ in 0..<2 {
            do {
                _ = try await repository.createScheduledMessage(conversationID: "27", text: "定时测试",
                    sendAt: sendAt, clientRequestID: id)
                XCTFail("无稳定身份不能显示创建成功")
            } catch let error as AppError {
                XCTAssertEqual(error.category, .partialFailure)
            }
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func test提醒定时和置顶列表异常不伪装为空() async throws {
        for operation in 0..<3 {
            let repository = try makeRepository(transport: MockHTTPTransport(responses: [response(#"{"success":true,"data":{"unexpected":"shape"}}"#)]))
            do {
                switch operation {
                case 0: _ = try await repository.listReminders(conversationID: "27")
                case 1: _ = try await repository.listScheduledMessages(conversationID: "27")
                default: _ = try await repository.listPinnedMessages(conversationID: "27")
                }
                XCTFail("坏列表必须返回错误")
            } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test发送回读缺少本人标记时仍用本次写回执的稳定身份确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"new-post"}}"#),
            response(#"{"success":true,"data":{"posts":[{"post_id":"new-post","channel_id":"27","creator_id":"1","message":"测试正文","create_at":1700000000}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(conversationID: "27", text: "测试正文")
        let outcome = try await repository.sendMessageResult(draft)
        XCTAssertEqual(outcome.result.status, .confirmedSuccess)
        XCTAssertEqual(outcome.confirmedMessage?.id, "new-post")
        XCTAssertEqual(outcome.confirmedMessage?.isFromCurrentUser, true)
    }

    func test发送回读明确属于其他人时不能因昵称相同确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"new-post"}}"#),
            response(#"{"success":true,"data":{"posts":[{"post_id":"new-post","channel_id":"27","creator_id":"other","creator_name":"testaccount","is_my_post":false,"message":"测试正文","create_at":1700000000}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let outcome = try await repository.sendMessageResult(ChatMessageDraft(conversationID: "27", text: "测试正文"))
        XCTAssertEqual(outcome.result.status, .submittedButUnverified)
        XCTAssertNil(outcome.confirmedMessage)
    }

    func test用户目录只通过账号字段识别自己不使用昵称() async throws {
        let repository = try makeRepository(transport: MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"users":[{"user_id":"self","username":"testaccount","nickname":"本人昵称"},{"user_id":"other","username":"another","nickname":"testaccount"}]}}"#)
        ]))
        let users = try await repository.listUsers()
        XCTAssertEqual(users.first { $0.id == "self" }?.isCurrentUser, true)
        XCTAssertEqual(users.first { $0.id == "other" }?.isCurrentUser, false)
    }

    func test已知加密会话拒绝普通发送且不提交请求() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"users":[]}}"#),
            response(#"{"success":true,"data":{"channels":[{"channel_id":"27","encrypted":true}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        _ = try await repository.listConversations()
        do {
            _ = try await repository.sendMessageResult(ChatMessageDraft(conversationID: "27", text: "不可发送"))
            XCTFail("加密会话不得提交普通消息")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .apiUnavailable)
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func test旧附件入口在传输未知后沿用核对状态而不重复上传() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ChatLegacy-\(UUID().uuidString).txt")
        try Data("synthetic".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = MockHTTPTransport(steps: [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(conversationID: "27", text: nil, localAttachmentURLs: [file])
        for _ in 0..<2 {
            do {
                _ = try await repository.sendMessage(draft)
                XCTFail("丢失回执时必须待核对")
            } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        }
        let bodies = await transport.recordedUploadBodies()
        let requests = await transport.recordedRequests()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertEqual(requests.count, 1)
    }

    func test删除旧消息先遍历历史再删除并复查() async throws {
        let newer = (1...100).map { index in
            "{\"post_id\":\"newer-\(index)\",\"channel_id\":\"27\",\"message\":\"新消息\",\"create_at\":\(1_700_000_100 + index)}"
        }.joined(separator: ",")
        let fullPage = response("{\"success\":true,\"data\":{\"posts\":[\(newer)]}}")
        let transport = MockHTTPTransport(responses: deletionAccess() + [
            fullPage,
            response(#"{"success":true,"data":{"posts":[{"post_id":"older","channel_id":"27","creator_id":"1","is_my_post":true,"message":"旧消息","create_at":1700000000},{"post_id":"newer-1","channel_id":"27","message":"新消息","create_at":1700000101}]}}"#),
            response(#"{"success":true}"#)
        ] + deletionAccess() + [
            fullPage,
            response(#"{"success":true,"data":{"posts":[{"post_id":"newer-1","channel_id":"27","message":"新消息","create_at":1700000101}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        try await repository.deleteMessage(conversationID: "27", messageID: "older", clientRequestID: UUID())
        let requests = await transport.recordedRequests()
        let fields = try requests.map { try decodeForm($0.httpBody) }.filter { $0["api"] == DsmAPIName.chatPost }
        XCTAssertEqual(fields.map { $0["method"] }, ["list", "list", "delete", "list", "list"])
        XCTAssertEqual(fields.count, 5)
        XCTAssertEqual(fields.dropFirst().first?["post_id"], "newer-1")
        XCTAssertEqual(fields.first(where: { $0["method"] == "delete" })?["post_id"], "older")
        XCTAssertEqual(fields.last?["post_id"], "newer-1")
    }

    func test历史页结构异常不能当成消息不存在或删除成功() async throws {
        let malformed = [
            #"{"success":true,"data":{"unexpected":"shape"}}"#,
            #"{"success":true,"data":{"posts":{}}}"#,
            #"{"success":true,"data":{"posts":[],"total":-1}}"#,
            #"{"success":true,"data":{"posts":[],"total":0.5}}"#,
            #"{"success":true,"data":{"posts":[{"post_id":"wrong","channel_id":"other","message":"不属于当前会话"}]}}"#
        ]
        for payload in malformed {
            let transport = MockHTTPTransport(responses: deletionAccess() + [response(payload)])
            let repository = try makeRepository(transport: transport)
            do {
                try await repository.deleteMessage(conversationID: "27", messageID: "target", clientRequestID: UUID())
                XCTFail("坏响应不得确认不存在")
            } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 3)
        }
    }

    func test他人昵称等于登录账号也不能通过删除权限预检() async throws {
        let transport = MockHTTPTransport(responses: deletionAccess() + [
            response(#"{"success":true,"data":{"posts":[{"post_id":"target","channel_id":"27","creator_id":"other","creator_name":"testaccount","is_my_post":false,"message":"他人消息","create_at":1700000000}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        do {
            try await repository.deleteMessage(conversationID: "27", messageID: "target", clientRequestID: UUID())
            XCTFail("不能以昵称获得删除权限")
        } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
    }

    func test投票缺少稳定回执时不认领同文消息且同请求不再创建() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{}}"#)])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatPollDraft(conversationID: "27", question: "相同问题", options: ["甲", "乙"],
                                      allowsMultipleSelection: false, isAnonymous: false)
        for _ in 0..<2 {
            do {
                _ = try await repository.createPoll(draft)
                XCTFail("没有稳定身份的投票必须待核对")
            } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func test投票回读普通文字或选项不一致不能确认成功() async throws {
        for poll in ["", #", "vote":{"choices":["甲","不同选项"],"options":{"multiple":false,"anonymous":false}}"#] {
            let payload = "{\"success\":true,\"data\":{\"posts\":[{\"post_id\":\"target\",\"channel_id\":\"27\",\"is_my_post\":true,\"message\":\"测试问题\",\"create_at\":1700000000\(poll)}]}}"
            let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"post_id":"target"}}"#), response(payload)])
            let repository = try makeRepository(transport: transport)
            do {
                _ = try await repository.createPoll(ChatPollDraft(conversationID: "27", question: "测试问题",
                    options: ["甲", "乙"], allowsMultipleSelection: false, isAnonymous: false))
                XCTFail("不能用普通文字或其他投票确认")
            } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        }
    }

    func test转发丢失回执时不重复提交也不冒充完成() async throws {
        let source = response(#"{"success":true,"data":{"posts":[{"post_id":"source","channel_id":"27","creator_id":"1","is_my_post":true,"message":"转发测试","create_at":1700000000}]}}"#)
        let transport = MockHTTPTransport(steps: [
            .response(source),
            .response(response(#"{"success":true,"data":{"current_user_id":"1","users":[]}}"#)),
            .response(response(#"{"success":true,"data":{"channels":[{"channel_id":"27"},{"channel_id":"42"}]}}"#)),
            .response(source),
            .response(response(#"{"success":true,"data":{"posts":[]}}"#)),
            .urlError(.networkConnectionLost)
        ])
        let repository = try makeRepository(transport: transport)
        _ = try await repository.listMessages(conversationID: "27", before: nil, limit: 50)
        let requestID = UUID()
        for _ in 0..<2 {
            do {
                try await repository.forwardMessage(messageID: "source", toConversationIDs: ["42"], clientRequestID: requestID)
                XCTFail("转发丢回执不能确认完成")
            } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        }
        let requests = await transport.recordedRequests()
        let writes = try requests.filter { try decodeForm($0.httpBody)["method"] == "forward" }
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(requests.count, 6)
    }
}
