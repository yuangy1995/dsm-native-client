import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

extension DsmChatRepositoryTests {
    func test置顶搜索按数字会话数组筛选并保留分页() async throws {
        let rows = (0..<100).map { index in
            "{\"post_id\":\"\(index)\",\"channel_id\":27,\"creator_id\":2,\"message\":\"合成置顶\",\"create_at\":1700000000000,\"last_pin_at\":1700000001000}"
        }.joined(separator: ",")
        for format in [DsmRequestFormat.form, .json] {
            let transport = MockHTTPTransport(responses: [
                response("{\"success\":true,\"data\":{\"search_results\":[\(rows)],\"total\":101}}"),
                response(#"{"success":true,"data":{"search_results":[{"post_id":"100","channel_id":27,"creator_id":2,"message":"最后一条合成置顶","create_at":1700000000000,"last_pin_at":1700000002000}],"total":101}}"#)
            ])
            let repository = try makeRepository(transport: transport, chatRequestFormat: format)
            let messages = try await repository.listPinnedMessages(conversationID: "27")
            XCTAssertEqual(messages.count, 101)
            XCTAssertEqual(messages.first?.id, "100")
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 2)
            for (index, request) in requests.enumerated() {
                let fields = try decodeForm(request.httpBody)
                XCTAssertEqual(fields["in"], "[27]")
                XCTAssertNil(fields["channel_id"])
                XCTAssertEqual(fields["has"], #"["pin"]"#)
                XCTAssertEqual(fields["offset"], String(index * 100))
            }
        }
    }

    func test置顶搜索跨会话结果仍拒绝且空结果正常返回() async throws {
        let invalid = try makeRepository(transport: MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"search_results":[{"post_id":"1","channel_id":28,"message":"合成","create_at":1700000000000,"last_pin_at":1700000001000}],"total":1}}"#)
        ]))
        do { _ = try await invalid.listPinnedMessages(conversationID: "27"); XCTFail("不得混入其他会话") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let empty = try makeRepository(transport: MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"search_results":[],"total":0}}"#)
        ]))
        let messages = try await empty.listPinnedMessages(conversationID: "27")
        XCTAssertTrue(messages.isEmpty)
    }

    private var ownChatUser: DsmHTTPResponse {
        response(#"{"success":true,"data":{"users":[{"user_id":1,"username":"testaccount","nickname":"合成用户"}]}}"#)
    }

    private var plainChatChannel: DsmHTTPResponse {
        response(#"{"success":true,"data":{"channels":[{"channel_id":"27","type":"direct","members":[1,2],"encrypted":false}]}}"#)
    }

    private func interactionPost(text: String = "原文", id: String = "9001", thread: String = "0", edited: Bool = false) -> DsmHTTPResponse {
        response("{\"success\":true,\"data\":{\"posts\":[{\"post_id\":\"\(id)\",\"channel_id\":\"27\",\"creator_id\":1,\"is_my_post\":true,\"create_at\":1800000000000,\"update_at\":\(edited ? 1800000001000 : 1800000000000),\"thread_id\":\"\(thread)\",\"type\":\"normal\",\"message\":\"\(text)\"}]}}")
    }

    private func interactionPoll(closed: Bool = false, selected: Bool = false, multiple: Bool = true) -> DsmHTTPResponse {
        response("""
        {"success":true,"data":{"posts":[{"post_id":"9100","channel_id":"27","creator_id":1,"type":"vote","create_at":1800000000000,"message":"合成投票","props":{"vote":{"state":"\(closed ? "close" : "open")","options":{"multiple":\(multiple),"anonymous":false,"expire_at":0},"choices":[{"id":"choice-a","text":"方案甲","count":\(selected ? 1 : 0),"voters":\(selected ? "[1]" : "[]")},{"id":"choice-b","text":"方案乙","count":0,"voters":[]}]}}}]}}
        """)
    }

    func test关键词搜索使用真实搜索容器数字会话数组和独立游标() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"search_results":[{"post_id":"8100","channel_id":27,"creator_id":2,"message":"合成旧消息","create_at":1700000000000,"thread_id":0}],"total":3}}"#)])
        let repository = try makeRepository(transport: transport, chatRequestFormat: .json)
        let page = try await repository.searchMessages(query: " 合成 ", conversationID: "27", cursor: nil, limit: 25)
        XCTAssertEqual(page.messages.first?.text, "合成旧消息")
        XCTAssertEqual(page.nextCursor, "1")
        let recorded = await transport.recordedRequests()
        let request = try XCTUnwrap(recorded.first)
        let fields = try decodeForm(request.httpBody)
        XCTAssertEqual(fields["keyword"], #""合成""#)
        XCTAssertEqual(fields["in"], "[27]")
        XCTAssertEqual(fields["offset"], "0")
        XCTAssertEqual(fields["limit"], "25")
        XCTAssertEqual(fields["version"], "5")
    }

    func test搜索坏容器及跨会话结果不能当成有效消息() async throws {
        for body in [#"{"success":true,"data":{"posts":[],"total":0}}"#,
                     #"{"success":true,"data":{"search_results":[{"post_id":"1","channel_id":"other","message":"合成"}],"total":1}}"#] {
            let repository = try makeRepository(transport: MockHTTPTransport(responses: [response(body)]))
            do { _ = try await repository.searchMessages(query: "合成", conversationID: "27", cursor: nil, limit: 25); XCTFail("必须拒绝异常结果") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test真实历史游标排除定位消息且不再发送offset和limit() async throws {
        let transport = MockHTTPTransport(responses: [response(#"{"success":true,"data":{"posts":[{"post_id":"9001","channel_id":"27","create_at":1800000000000,"message":"定位"},{"post_id":"9000","channel_id":"27","create_at":1799999900000,"message":"更早"}]}}"#)])
        let repository = try makeRepository(transport: transport)
        let page = try await repository.listMessages(conversationID: "27", before: "9001", limit: 1)
        XCTAssertEqual(page.messages.map(\.id), ["9000"])
        XCTAssertEqual(page.previousCursor, "9000")
        let requests = await transport.recordedRequests()
        let fields = try decodeForm(XCTUnwrap(requests.first).httpBody)
        XCTAssertEqual(fields["post_id"], "9001")
        XCTAssertEqual(fields["prev_count"], "1")
        XCTAssertEqual(fields["next_count"], "0")
        XCTAssertNil(fields["offset"])
        XCTAssertNil(fields["limit"])
    }

    func test线程初始页不以根消息定位且拒绝其他线程记录() async throws {
        let transport = MockHTTPTransport(responses: [interactionPost(text: "回复", id: "9002", thread: "9001"), interactionPost(text: "错误线程", id: "9003", thread: "other")])
        let repository = try makeRepository(transport: transport)
        let page = try await repository.listReplies(conversationID: "27", threadID: "9001", before: nil, limit: 25)
        XCTAssertEqual(page.messages.map(\.id), ["9002"])
        let firstRequests = await transport.recordedRequests()
        let fields = try decodeForm(XCTUnwrap(firstRequests.first).httpBody)
        XCTAssertEqual(fields["thread_id"], "9001")
        XCTAssertNil(fields["post_id"])
        do { _ = try await repository.listReplies(conversationID: "27", threadID: "9001", before: nil, limit: 25); XCTFail("不能接受其他线程") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
    }

    func test编辑本人消息要求管理员规则并读回且重复点击不重写() async throws {
        let transport = MockHTTPTransport(responses: [interactionPost()] + [ownChatUser, plainChatChannel, interactionPost(),
            response(#"{"success":true,"data":{"allow_edit_message":true,"allow_edit_message_time_within_min":0}}"#),
            response(#"{"success":true}"#), interactionPost(text: "修改后", edited: true)])
        let repository = try makeRepository(transport: transport, chatRequestFormat: .json, includesFiveFeatureCapabilities: true)
        let originalValue = try await repository.message(conversationID: "27", messageID: "9001", threadID: nil)

        let original = try XCTUnwrap(originalValue)
        let id = UUID()
        let updated = try await repository.editMessage(original, text: "修改后", clientRequestID: id)
        let repeated = try await repository.editMessage(original, text: "修改后", clientRequestID: id)
        XCTAssertEqual(updated, repeated)
        XCTAssertEqual(updated.text, "修改后")
        XCTAssertNotNil(updated.editedAt)
        let requests = await transport.recordedRequests()
        let fields = try requests.map { try decodeForm($0.httpBody) }
        XCTAssertEqual(fields.filter { $0["method"] == "set" }.count, 1)
        XCTAssertEqual(fields.first(where: { $0["method"] == "set" })?["version"], "8")
        XCTAssertEqual(fields.first(where: { $0["method"] == "set" })?["message"], #""修改后""#)
    }

    func test其他设备修改原文后不得覆盖() async throws {
        let transport = MockHTTPTransport(responses: [interactionPost()] + [ownChatUser, plainChatChannel, interactionPost(text: "其他设备修改", edited: true)])
        let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
        let originalValue = try await repository.message(conversationID: "27", messageID: "9001", threadID: nil)

        let original = try XCTUnwrap(originalValue)
        do { _ = try await repository.editMessage(original, text: "我的修改", clientRequestID: UUID()); XCTFail("不得覆盖新内容") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertFalse(try requests.map { try decodeForm($0.httpBody)["method"] }.contains("set"))
    }

    func test编辑响应中断后同请求只读不重放() async throws {
        let transport = MockHTTPTransport(responses: [interactionPost()] + [ownChatUser, plainChatChannel, interactionPost(),
            response(#"{"success":true,"data":{"allow_edit_message":true,"allow_edit_message_time_within_min":0}}"#),
            DsmHTTPResponse(data: Data(), statusCode: 503), interactionPost(), interactionPost(text: "修改后", edited: true)])
        let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
        let originalValue = try await repository.message(conversationID: "27", messageID: "9001", threadID: nil)

        let original = try XCTUnwrap(originalValue)
        let id = UUID()
        do { _ = try await repository.editMessage(original, text: "修改后", clientRequestID: id); XCTFail("旧内容不能确认") }
        catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let result = try await repository.editMessage(original, text: "修改后", clientRequestID: id)
        XCTAssertEqual(result.text, "修改后")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.filter { try decodeForm($0.httpBody)["method"] == "set" }.count, 1)
    }

    func test功能按接口能力开放且不要求读取系统或套件版本() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
        let availability = await repository.availability()
        for feature in [ChatFeature.messageSearch, .messageEditing, .pollVoting, .threadedReplies, .readSynchronization] {
            XCTAssertTrue(availability.supportedFeatures.contains(feature))
        }
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty, "无需管理员可读的套件版本或系统白名单")
    }

    func test开放功能后仍保留实际接口版本要求() async throws {
        let repository = try makeRepository(transport: MockHTTPTransport(responses: []))
        let availability = await repository.availability()
        XCTAssertFalse(availability.supportedFeatures.contains(.messageEditing), "缺少 Post v8 和编辑策略接口不能猜测请求")
        XCTAssertTrue(availability.supportedFeatures.contains(.threadedReplies))
        XCTAssertTrue(availability.supportedFeatures.contains(.pollVoting))
    }

    func test线程发送固定根身份并使用同一线程回读() async throws {
        let transport = MockHTTPTransport(responses: [ownChatUser, plainChatChannel, interactionPost(),
            response(#"{"success":true,"data":{"post_id":"9002"}}"#), interactionPost(text: "回复", id: "9002", thread: "9001")])
        let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
        let draft = try ChatMessageDraft(conversationID: "27", text: "回复", threadID: "9001")
        let result = try await repository.sendMessageResult(draft)
        XCTAssertEqual(result.result.status, .confirmedSuccess)
        XCTAssertEqual(result.confirmedMessage?.threadID, "9001")
        let requests = await transport.recordedRequests()
        let fields = try requests.map { try decodeForm($0.httpBody) }
        XCTAssertEqual(fields.first(where: { $0["method"] == "create" })?["thread_id"], "9001")
        XCTAssertEqual(fields.last?["thread_id"], "9001")
    }

    func test投票从props读取并提交字符串选项及回读本人选择() async throws {
        let choices = response(#"{"success":true,"data":{"choices":[{"id":"choice-a","text":"方案甲","count":1,"voters":[1]},{"id":"choice-b","text":"方案乙","count":0,"voters":[]}]}}"#)
        let transport = MockHTTPTransport(responses: [interactionPoll()] + [ownChatUser, plainChatChannel, interactionPoll(), response(#"{"success":true}"#), interactionPoll(selected: true), choices])
        let repository = try makeRepository(transport: transport, chatRequestFormat: .json, includesFiveFeatureCapabilities: true)
        let originalValue = try await repository.message(conversationID: "27", messageID: "9100", threadID: nil)

        let original = try XCTUnwrap(originalValue)
        XCTAssertNil(original.poll?.closesAt)
        let id = UUID()
        let result = try await repository.vote(original, choiceIDs: ["choice-a"], clientRequestID: id)
        _ = try await repository.vote(original, choiceIDs: ["choice-a"], clientRequestID: id)
        XCTAssertEqual(result.poll?.options.first?.voteCount, 1)
        XCTAssertEqual(result.poll?.options.first?.isSelectedByCurrentUser, true)
        let requests = await transport.recordedRequests()
        let fields = try requests.map { try decodeForm($0.httpBody) }
        XCTAssertEqual(fields.filter { $0["method"] == "vote" }.count, 1)
        XCTAssertEqual(fields.first(where: { $0["method"] == "vote" })?["choice_ids"], #"["choice-a"]"#)
        XCTAssertEqual(fields.last?["method"], "get_choices")
    }

    func test关闭投票和单选多项都不提交() async throws {
        for isClosed in [true, false] {
            let transport = MockHTTPTransport(responses: [interactionPoll(closed: isClosed, multiple: false)] + [ownChatUser, plainChatChannel, interactionPoll(closed: isClosed, multiple: false)])
            let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
            let originalValue = try await repository.message(conversationID: "27", messageID: "9100", threadID: nil)

            let original = try XCTUnwrap(originalValue)
            do { _ = try await repository.vote(original, choiceIDs: isClosed ? ["choice-a"] : ["choice-a", "choice-b"], clientRequestID: UUID()); XCTFail("不可提交") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
            let requests = await transport.recordedRequests()
            XCTAssertFalse(try requests.map { try decodeForm($0.httpBody)["method"] }.contains("vote"))
        }
    }

    func test主会话已读使用实际消息时间并读取服务端标记() async throws {
        let transport = MockHTTPTransport(responses: [interactionPost()] + [response(#"{"success":true}"#), ownChatUser,
            response(#"{"success":true,"data":{"channels":[{"channel_id":"27","type":"direct","members":[1,2],"unread":0,"last_view_at":1800000000000}]}}"#)])
        let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
        let messageValue = try await repository.message(conversationID: "27", messageID: "9001", threadID: nil)

        let message = try XCTUnwrap(messageValue)
        _ = try await repository.markRead(conversationID: "27", through: message.sentAt)
        let requests = await transport.recordedRequests()
        let fields = try requests.map { try decodeForm($0.httpBody) }
        XCTAssertEqual(fields.first(where: { $0["method"] == "view" })?["last_view_at"], "1800000000000")
        XCTAssertEqual(fields.last?["api"], DsmAPIName.chatChannel)
        XCTAssertEqual(fields.last?["method"], "list")
    }

    func test未读取的消息时间不得写为已读() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
        do { _ = try await repository.markRead(conversationID: "27", through: Date()); XCTFail("不得越过实际内容") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 0)
    }

    func testAAC附件映射为语音以接入本地播放器() async throws {
        let repository = try makeRepository(transport: MockHTTPTransport(responses: [response(#"{"success":true,"data":{"posts":[{"post_id":"9001","channel_id":"27","type":"file","create_at":1800000000000,"file_props":{"name":"voice.aac","size":128,"type":"aac"}}]}}"#)]))
        let page = try await repository.listMessages(conversationID: "27", before: nil, limit: 10)
        XCTAssertEqual(page.messages.first?.attachments.first?.kind, .voice)
    }
    func test投票详情只读取且保留当前账号选择() async throws {
        let choices = response(#"{"success":true,"data":{"choices":[{"id":"choice-a","text":"方案甲","count":1,"voters":[1]},{"id":"choice-b","text":"方案乙","count":0,"voters":[]}]}}"#)
        let transport = MockHTTPTransport(responses: [ownChatUser, plainChatChannel, interactionPoll(), choices])
        let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
        let result = try await repository.pollMessage(conversationID: "27", messageID: "9100", threadID: nil)
        XCTAssertEqual(result?.poll?.options.first?.isSelectedByCurrentUser, true)
        XCTAssertEqual(result?.poll?.options.first?.voteCount, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.map { try decodeForm($0.httpBody)["method"] }, ["list", "list", "list", "get_choices"])
    }

    func test投票详情拒绝重复或缺失的选项身份() async throws {
        for rows in [#"{"id":"choice-a","count":1,"voters":[1]}"#,
                     #"{"id":"choice-a","count":1,"voters":[1]},{"id":"choice-a","count":1,"voters":[1]},{"id":"choice-b","count":0,"voters":[]}"#] {
            let transport = MockHTTPTransport(responses: [ownChatUser, plainChatChannel, interactionPoll(), response("{\"success\":true,\"data\":{\"choices\":[\(rows)]}}")])
            let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
            do { _ = try await repository.pollMessage(conversationID: "27", messageID: "9100", threadID: nil); XCTFail("不得显示不完整的投票状态") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 4)
        }
    }

    func test投票创建先保存身份且保存失败后同请求只回读() async throws {
        let transport = MockHTTPTransport(responses: [ownChatUser, plainChatChannel,
            response(#"{"success":true,"data":{"post_id":"9100"}}"#), interactionPoll()])
        let repository = try makeRepository(transport: transport, includesFiveFeatureCapabilities: true)
        _ = try await repository.listConversations()
        let draft = try ChatPollDraft(conversationID: "27", question: "合成投票", options: ["方案甲", "方案乙"], allowsMultipleSelection: true, isAnonymous: false)
        do {
            _ = try await repository.createPoll(draft) { id in
                XCTAssertEqual(id, "9100")
                let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
                throw URLError(.cannotWriteToFile)
            }
            XCTFail("回执保存失败不能宣布完成")
        } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let result = try await repository.createPoll(draft) { id in
            XCTAssertEqual(id, "9100")
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 3)
        }
        XCTAssertEqual(result.id, "9100")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.map { try decodeForm($0.httpBody)["method"] }, ["list", "list", "create", "list"])
    }

    func test定时创建回执保存失败后同请求不重新创建() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"schedules":[]}}"#),
            response(#"{"success":true,"data":{"cronjob_id":"job-1"}}"#),
            response(#"{"success":true,"data":{"schedules":[{"cronjob_id":"job-1","channel_id":"27","message":"合成定时","send_at":1800000000000}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let requestID = UUID(), date = Date(timeIntervalSince1970: 1_800_000_000)
        do {
            _ = try await repository.createScheduledMessage(conversationID: "27", text: "合成定时", sendAt: date, clientRequestID: requestID) { id in
                XCTAssertEqual(id, "job-1")
                let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
                throw URLError(.cannotWriteToFile)
            }
            XCTFail("保存失败不得宣布完成")
        } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure) }
        let result = try await repository.createScheduledMessage(conversationID: "27", text: "合成定时", sendAt: date, clientRequestID: requestID) { id in
            XCTAssertEqual(id, "job-1")
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
        }
        XCTAssertEqual(result.id, "job-1")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try requests.map { try decodeForm($0.httpBody)["method"] }, ["list", "create", "list"])
    }

    func test提醒及定时取消的回读失败保留未知结果() async throws {
        for reminder in [true, false] {
            let transport = MockHTTPTransport(responses: [response(#"{"success":true}"#), DsmHTTPResponse(data: Data(), statusCode: 503)])
            let repository = try makeRepository(transport: transport)
            do {
                if reminder { try await repository.deleteReminder(messageID: "9001", conversationID: "27", clientRequestID: UUID()) }
                else { try await repository.deleteScheduledMessage(id: "job-1", conversationID: "27", clientRequestID: UUID()) }
                XCTFail("不能把提交后的读取失败当作取消失败")
            } catch let error as AppError { XCTAssertEqual(error.category, .partialFailure); XCTAssertFalse(error.isRetryable) }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(try requests.map { try decodeForm($0.httpBody)["method"] }, ["delete", "list"])
        }
    }

    func test提醒及定时取消传输中断后可由空列表恢复且只提交一次() async throws {
        for reminder in [true, false] {
            let transport = MockHTTPTransport(responses: [DsmHTTPResponse(data: Data(), statusCode: 503),
                response(reminder ? #"{"success":true,"data":{"reminders":[]}}"# : #"{"success":true,"data":{"schedules":[]}}"#)])
            let repository = try makeRepository(transport: transport)
            let id = UUID()
            for _ in 0..<2 {
                if reminder { try await repository.deleteReminder(messageID: "9001", conversationID: "27", clientRequestID: id) }
                else { try await repository.deleteScheduledMessage(id: "job-1", conversationID: "27", clientRequestID: id) }
            }
            let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 2)
        }
    }

    func test提醒及定时重复身份列表不可用于确认结果() async throws {
        let reminderRow = #"{"post_id":"9001","remind_at":1800000000000}"#
        let scheduleRow = #"{"cronjob_id":"job-1","channel_id":"27","message":"合成定时","send_at":1800000000000}"#
        for reminder in [true, false] {
            let key = reminder ? "reminders" : "schedules", row = reminder ? reminderRow : scheduleRow
            let transport = MockHTTPTransport(responses: [response("{\"success\":true,\"data\":{\"\(key)\":[\(row),\(row)]}}")])
            let repository = try makeRepository(transport: transport)
            do {
                if reminder { _ = try await repository.listReminders(conversationID: "27") }
                else { _ = try await repository.listScheduledMessages(conversationID: "27") }
                XCTFail("不能接受重复身份")
            } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

}
