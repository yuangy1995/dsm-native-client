import DsmCore
import DsmLocalization
import Foundation
import XCTest
@testable import DsmNetwork

final class DsmChatRepositoryTests: XCTestCase {
    func test能力齐全时启用已接入功能() async throws {
        let repository = try makeRepository(transport: MockHTTPTransport(responses: []))

        let availability = await repository.availability()

        XCTAssertEqual(availability.status, .available)
        XCTAssertTrue(availability.supportedFeatures.contains(.directConversation))
        XCTAssertTrue(availability.supportedFeatures.contains(.groupConversation))
        XCTAssertTrue(availability.supportedFeatures.contains(.textMessage))
        XCTAssertTrue(availability.supportedFeatures.contains(.reminder))
        XCTAssertTrue(availability.supportedFeatures.contains(.poll))
        XCTAssertTrue(availability.supportedFeatures.contains(.deleteOwnMessage))
        XCTAssertTrue(availability.supportedFeatures.contains(.closeConversation))
        XCTAssertTrue(availability.supportedFeatures.contains(.imageAttachment))
        XCTAssertTrue(availability.supportedFeatures.contains(.videoAttachment))
        XCTAssertTrue(availability.supportedFeatures.contains(.fileAttachment))
        XCTAssertTrue(availability.supportedFeatures.contains(.attachmentDownload))
        XCTAssertTrue(availability.supportedFeatures.contains(.reminderManagement))
        XCTAssertTrue(availability.supportedFeatures.contains(.scheduledMessage))
        XCTAssertTrue(availability.supportedFeatures.contains(.messageForward))
        XCTAssertTrue(availability.supportedFeatures.contains(.groupMembers))
        XCTAssertTrue(availability.supportedFeatures.contains(.pinnedMessages))
    }

    func test解析用户与会话并兼容数字和字符串标识() async throws {
        let users = response(#"{"success":true,"data":{"users":[{"user_id":2,"nickname":"林青"},{"user_id":"3","username":"周明"}]}}"#)
        let channels = response(#"{"success":true,"data":{"channels":[{"channel_id":27,"name":"","members":[1,2],"unread":3,"last_post":{"message":"下午见","create_at":"1774166400000"}},{"channel_id":"42","name":"项目组","members":[1,"2","3"],"type":"private"}]}}"#)
        let repository = try makeRepository(
            transport: MockHTTPTransport(responses: [users, channels])
        )

        let conversations = try await repository.listConversations()

        XCTAssertEqual(conversations.count, 2)
        let direct = try XCTUnwrap(conversations.first(where: { $0.id == "27" }))
        XCTAssertEqual(direct.kind, .direct)
        XCTAssertTrue(direct.title.contains("林青"))
        XCTAssertEqual(direct.unreadCount, 3)
        let group = try XCTUnwrap(conversations.first(where: { $0.id == "42" }))
        XCTAssertEqual(group.kind, .group)
        XCTAssertEqual(group.title, "项目组")
    }

    func test用户列表兼容根数组和空用户名() async throws {
        let repository = try makeRepository(transport: MockHTTPTransport(responses: [
            response(#"{"success":true,"data":[{"uid":1,"displayname":" "},{"uid":2,"user_name":"林青","is_avatar_exist":false}]}"#)
        ]))

        let users = try await repository.listUsers()

        XCTAssertEqual(users.map(\.id).sorted(), ["1", "2"])
        XCTAssertEqual(
            users.first(where: { $0.id == "1" })?.displayName,
            L10n.string("shared.806312613840681c", String(describing: 1))
        )
        XCTAssertEqual(users.first(where: { $0.id == "2" })?.displayName, "林青")
    }

    func test用户列表读取已声明头像() async throws {
        let pngPrefix = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"users":[{"user_id":"2","nickname":"林青","has_avatar":true}]}}"#),
            DsmHTTPResponse(
                data: pngPrefix,
                statusCode: 200,
                headers: ["Content-Type": "image/png"]
            )
        ])
        let repository = try makeRepository(
            transport: transport,
            includesAvatarCapability: true
        )

        let users = try await repository.listUsers()

        XCTAssertEqual(users.first?.avatarData, pngPrefix)
        XCTAssertEqual(users.first?.avatarAvailable, true)
        let requests = await transport.recordedRequests()
        let avatarRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(avatarRequest.httpMethod, "GET")
        XCTAssertNil(URLComponents(url: try XCTUnwrap(avatarRequest.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "_sid" }))
    }

    func test解析当前用户和对象成员并从私聊标题排除自己() async throws {
        let users = response(#"{"success":true,"data":{"current_user_id":"1","users":[{"user_id":"1","nickname":"测试账号"},{"user_id":"2","nickname":"林青"}]}}"#)
        let channels = response(#"{"success":true,"data":{"channels":[{"channel_id":"27","name":"","type":"anonymous","members":[{"user_id":"1"},{"user_id":"2"}],"member_count":2}]}}"#)
        let repository = try makeRepository(
            transport: MockHTTPTransport(responses: [users, channels])
        )

        let conversations = try await repository.listConversations()

        let direct = try XCTUnwrap(conversations.first)
        XCTAssertEqual(direct.title, "林青")
        XCTAssertEqual(direct.memberIDs, ["1", "2"])
        XCTAssertEqual(direct.memberCount, 2)
    }

    func test解析嵌套发送者并标记当前用户消息() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"posts":[{"post_id":"9001","channel_id":"27","create_at":"1774166400000","message":"收到","creator":{"user_id":"2","nickname":"林青","is_current_user":false}},{"post_id":"9002","channel_id":"27","create_at":"1774166401000","message":"好的","creator":{"user_id":"1","nickname":"测试账号","is_current_user":true}}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)

        let page = try await repository.listMessages(conversationID: "27", before: nil, limit: 20)

        XCTAssertEqual(page.messages.first?.senderID, "2")
        XCTAssertEqual(page.messages.first?.senderDisplayName, "林青")
        XCTAssertEqual(page.messages.first?.isFromCurrentUser, false)
        XCTAssertEqual(page.messages.last?.isFromCurrentUser, true)
    }

    func test空发送者名称不会覆盖用户目录名称() async throws {
        let users = response(#"{"success":true,"data":{"users":[{"user_id":"2","nickname":"林青"}]}}"#)
        let channels = response(#"{"success":true,"data":{"channels":[]}}"#)
        let posts = response(#"{"success":true,"data":{"posts":[{"post_id":"9001","channel_id":"27","creator_id":"2","creator_name":" ","create_at":1774166400000,"message":"收到"}]}}"#)
        let repository = try makeRepository(
            transport: MockHTTPTransport(responses: [users, channels, posts])
        )

        _ = try await repository.listConversations()
        let page = try await repository.listMessages(conversationID: "27", before: nil, limit: 20)

        XCTAssertEqual(page.messages.first?.senderDisplayName, "林青")
    }

    func test读取历史消息使用正文传递会话和分页() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"posts":[{"post_id":"9001","channel_id":27,"creator_id":2,"create_at":1774166400000,"message":"收到"}],"total":2}}"#)
        ])
        let repository = try makeRepository(transport: transport)

        let page = try await repository.listMessages(
            conversationID: "27",
            before: nil,
            limit: 1
        )

        XCTAssertEqual(page.messages.first?.text, "收到")
        XCTAssertEqual(page.previousCursor, "1")
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let fields = try decodeForm(request.httpBody)
        XCTAssertEqual(fields["api"], DsmAPIName.chatPost)
        XCTAssertEqual(fields["method"], "list")
        XCTAssertEqual(fields["channel_id"], "27")
        XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.query)
    }

    func test附件辅助空记录不会显示且分页仍按服务器记录推进() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"posts":[{"post_id":"aux-1","channel_id":"27","creator_id":"system","create_at":1774166400000,"message":""},{"post_id":"file-1","channel_id":"27","creator_id":"1","create_at":1774166401000,"type":"file","file_props":{"file_id":"f-1","name":"sample.jpg","size":7,"type":"jpg"}}],"total":3}}"#)
        ])
        let repository = try makeRepository(transport: transport)

        let page = try await repository.listMessages(
            conversationID: "27",
            before: nil,
            limit: 2
        )

        XCTAssertEqual(page.messages.map(\.id), ["file-1"])
        XCTAssertEqual(page.messages.first?.attachments.first?.fileName, "sample.jpg")
        XCTAssertEqual(page.previousCursor, "2")
        XCTAssertTrue(page.hasMoreBefore)
    }

    func test相同请求标识只发送一次文字消息() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9002","channel_id":"27","creator_id":"1","create_at":"1774166400000","message":"你好"}}"#),
            response(#"{"success":true,"data":{"posts":[{"post_id":"9002","channel_id":"27","creator":{"user_id":"1","nickname":"测试账号","is_current_user":true},"create_at":"1774166400000","message":"你好"}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let requestID = UUID()
        let draft = try ChatMessageDraft(
            clientRequestID: requestID,
            conversationID: "27",
            text: "你好"
        )

        let first = try await repository.sendMessage(draft)
        let second = try await repository.sendMessage(draft)

        XCTAssertEqual(first, second)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let createFields = try decodeForm(requests[0].httpBody)
        XCTAssertEqual(createFields["version"], "5")
        XCTAssertEqual(createFields["method"], "create")
        let readbackFields = try decodeForm(requests[1].httpBody)
        XCTAssertEqual(readbackFields["method"], "list")
        XCTAssertEqual(first.clientRequestID, requestID)
    }

    func test文字发送结果成功前必须回读确认() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9002","channel_id":"27","creator_id":"1","create_at":"1774166400000","message":"你好"}}"#),
            response(#"{"success":true,"data":{"posts":[{"post_id":"9002","channel_id":"27","creator":{"user_id":"1","is_current_user":true},"create_at":"1774166400000","message":"你好"}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(conversationID: "27", text: "你好")

        let outcome = try await repository.sendMessageResult(draft)

        XCTAssertEqual(outcome.result.status, .confirmedSuccess)
        XCTAssertEqual(outcome.confirmedMessage?.id, "9002")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(try decodeForm(requests[0].httpBody)["version"], "5")
        XCTAssertEqual(try decodeForm(requests[1].httpBody)["method"], "list")
    }

    func test文字发送缺少稳定标识会进入核对且同请求不会重发() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"channel_id":"27"}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(conversationID: "27", text: "你好")

        let first = try await repository.sendMessageResult(draft)
        let second = try await repository.sendMessageResult(draft)

        XCTAssertEqual(first.result.status, .submittedButUnverified)
        XCTAssertEqual(second.result.status, .submittedButUnverified)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(try decodeForm(requests[0].httpBody)["method"], "create")
    }

    func test文字发送回读不匹配会进入核对且后续只回读() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9002","channel_id":"27","creator_id":"1","create_at":"1774166400000","message":"你好"}}"#),
            response(#"{"success":true,"data":{"posts":[]}}"#),
            response(#"{"success":true,"data":{"posts":[{"post_id":"9002","channel_id":"27","creator":{"user_id":"1","is_current_user":true},"create_at":"1774166400000","message":"你好"}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(conversationID: "27", text: "你好")

        let first = try await repository.sendMessageResult(draft)
        let second = try await repository.sendMessageResult(draft)

        XCTAssertEqual(first.result.status, .submittedButUnverified)
        XCTAssertEqual(second.result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(try decodeForm(requests[0].httpBody)["method"], "create")
        XCTAssertEqual(try decodeForm(requests[1].httpBody)["method"], "list")
        XCTAssertEqual(try decodeForm(requests[2].httpBody)["method"], "list")
    }

    func test文字发送能力需要PostV5() async throws {
        let repository = try makeRepository(
            transport: MockHTTPTransport(responses: []),
            chatPostVersion: 4
        )

        let availability = await repository.availability()

        XCTAssertFalse(availability.supportedFeatures.contains(.textMessage))
        XCTAssertFalse(availability.supportedFeatures.contains(.emoji))
    }

    func test首次单聊使用匿名会话接口并在创建后复查() async throws {
        let users = response(#"{"success":true,"data":{"current_user_id":"1","users":[{"user_id":"1","nickname":"测试账号"},{"user_id":"2","nickname":"林青"}]}}"#)
        let emptyChannels = response(#"{"success":true,"data":{"channels":[]}}"#)
        let createdChannels = response(#"{"success":true,"data":{"channels":[{"channel_id":"27","type":"anonymous","members":["1","2"],"member_count":2}]}}"#)
        let transport = MockHTTPTransport(responses: [
            users,
            emptyChannels,
            response(#"{"success":true,"data":{"channel_id":"27"}}"#),
            users,
            createdChannels
        ])
        let repository = try makeRepository(transport: transport)
        let requestID = UUID()

        let first = try await repository.openDirectConversation(userID: "2", clientRequestID: requestID)
        let second = try await repository.openDirectConversation(userID: "2", clientRequestID: requestID)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.id, "27")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 5)
        let fields = try decodeForm(requests[2].httpBody)
        XCTAssertEqual(fields["api"], DsmAPIName.chatChannelAnonymous)
        XCTAssertEqual(fields["version"], "2")
        XCTAssertEqual(fields["method"], "initiate")
        XCTAssertEqual(fields["user_ids"], #"["2"]"#)
        XCTAssertEqual(fields["encrypted"], "false")
        XCTAssertEqual(fields["channel_key_encs"], "[]")
    }

    func test创建投票使用已确认契约并对同一请求去重() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9100","channel_id":"27","creator_id":"1","is_my_post":true,"create_at":1774166400000,"message":"周末去哪？"}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let requestID = UUID()
        let draft = try ChatPollDraft(
            clientRequestID: requestID,
            conversationID: "27",
            question: "周末去哪？",
            options: ["公园", "博物馆"],
            allowsMultipleSelection: true,
            isAnonymous: false
        )

        let first = try await repository.createPoll(draft)
        let second = try await repository.createPoll(draft)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.poll?.question, "周末去哪？")
        XCTAssertEqual(first.poll?.options.map(\.text), ["公园", "博物馆"])
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let fields = try decodeForm(requests[0].httpBody)
        XCTAssertEqual(fields["api"], DsmAPIName.chatPostVote)
        XCTAssertEqual(fields["version"], "1")
        XCTAssertEqual(fields["method"], "create")
        XCTAssertEqual(fields["choices"], #"["公园","博物馆"]"#)
        XCTAssertEqual(fields["options"], #"{"add_option":false,"anonymous":false,"multiple":true}"#)
    }

    func test历史消息解析投票选项和当前用户选择() async throws {
        let repository = try makeRepository(transport: MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"posts":[{"post_id":"9100","channel_id":"27","creator_id":"1","create_at":1774166400000,"message":"周末去哪？","vote":{"vote_id":"vote-1","choices":[{"choice_id":"c1","text":"公园","vote_count":2,"selected":true},{"choice_id":"c2","text":"博物馆","vote_count":1}],"options":"{\"multiple\":false,\"anonymous\":true}"}}]}}"#)
        ]))

        let page = try await repository.listMessages(conversationID: "27", before: nil, limit: 20)

        let poll = try XCTUnwrap(page.messages.first?.poll)
        XCTAssertEqual(poll.id, "vote-1")
        XCTAssertTrue(poll.isAnonymous)
        XCTAssertFalse(poll.allowsMultipleSelection)
        XCTAssertEqual(poll.options.map(\.voteCount), [2, 1])
        XCTAssertEqual(poll.options.first?.isSelectedByCurrentUser, true)
    }

    func test读取和取消提醒后复查结果() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"posts":[{"post_id":"9001","props":{"reminde_at":1774166400000}}]}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"reminders":[]}}"#)
        ])
        let repository = try makeRepository(transport: transport)

        let reminders = try await repository.listReminders(conversationID: "12")
        try await repository.deleteReminder(
            messageID: "9001",
            conversationID: "12",
            clientRequestID: UUID()
        )

        XCTAssertEqual(reminders.first?.messageID, "9001")
        let requests = await transport.recordedRequests()
        let listFields = try decodeForm(requests[0].httpBody)
        XCTAssertEqual(listFields["method"], "list")
        XCTAssertEqual(listFields["channel_id"], "12")
        let deleteFields = try decodeForm(requests[1].httpBody)
        XCTAssertEqual(deleteFields["method"], "delete")
        XCTAssertEqual(deleteFields["post_id"], "9001")
        XCTAssertEqual(try decodeForm(requests[2].httpBody)["method"], "list")
    }

    func test官方服务端转发使用PostForward且不下载附件() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#)
        ])
        let repository = try makeRepository(transport: transport)

        try await repository.forwardMessage(
            messageID: "9001",
            toConversationIDs: ["27", "42"],
            clientRequestID: UUID()
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
        let fields = try decodeForm(requests[0].httpBody)
        XCTAssertEqual(fields["api"], DsmAPIName.chatPost)
        XCTAssertEqual(fields["version"], "5")
        XCTAssertEqual(fields["method"], "forward")
        XCTAssertEqual(fields["post_id"], "9001")
        XCTAssertEqual(fields["channel_ids"], #"[27,42]"#)
    }

    func test读取群成员并使用用户目录补齐名称() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"user_ids":[1,2],"broken_user_ids":[]}}"#),
            response(#"{"success":true,"data":{"users":[{"user_id":1,"nickname":"林青"},{"user_id":2,"nickname":"周明"}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)

        let members = try await repository.listConversationMembers(conversationID: "42")

        XCTAssertEqual(members.map(\.displayName), ["林青", "周明"])
        let requests = await transport.recordedRequests()
        let fields = try decodeForm(requests[0].httpBody)
        XCTAssertEqual(fields["api"], DsmAPIName.chatChannelMember)
        XCTAssertEqual(fields["version"], "1")
        XCTAssertEqual(fields["method"], "get")
        XCTAssertEqual(fields["channel_id"], "42")
    }

    func test设置群公告使用PostPin并复查公告列表() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"search_results":[{"post_id":"9001","channel_id":"42","creator_id":"1","message":"重要通知","create_at":1774166400000,"last_pin_at":1774166500000}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)

        try await repository.setMessagePinned(
            conversationID: "42",
            messageID: "9001",
            isPinned: true,
            clientRequestID: UUID()
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        let pinFields = try decodeForm(requests[0].httpBody)
        XCTAssertEqual(pinFields["api"], DsmAPIName.chatPost)
        XCTAssertEqual(pinFields["version"], "5")
        XCTAssertEqual(pinFields["method"], "pin")
        XCTAssertEqual(pinFields["post_id"], "9001")
        let searchFields = try decodeForm(requests[1].httpBody)
        XCTAssertEqual(searchFields["method"], "search")
        XCTAssertEqual(searchFields["has"], #"["pin"]"#)
    }

    func test附件缩略图使用请求头认证且凭据不进入URL() async throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let transport = MockHTTPTransport(responses: [
            DsmHTTPResponse(data: png, statusCode: 200, headers: ["content-type": "image/png"])
        ])
        let repository = try makeRepository(transport: transport)

        let data = try await repository.loadAttachmentThumbnail(messageID: "9001", size: .small)

        XCTAssertEqual(data, png)
        let requests = await transport.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["method"], "thumbnail")
        XCTAssertEqual(query["post_id"], "9001")
        XCTAssertEqual(query["type"], "sm")
        XCTAssertNil(query["_sid"])
        XCTAssertNil(query["SynoToken"])
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNotNil(request.value(forHTTPHeaderField: "X-SYNO-TOKEN"))
    }

    func test下载附件写入目标并报告进度() async throws {
        let fileData = Data("SANITIZED_ATTACHMENT".utf8)
        let transport = MockHTTPTransport(responses: [
            DsmHTTPResponse(data: fileData, statusCode: 200, headers: ["content-type": "application/octet-stream"])
        ])
        let repository = try makeRepository(transport: transport)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: destination) }
        let progressRecorder = ChatProgressRecorder()

        try await repository.downloadAttachment(messageID: "9001", to: destination) { completed, _ in
            progressRecorder.append(completed)
        }

        XCTAssertEqual(try Data(contentsOf: destination), fileData)
        XCTAssertEqual(progressRecorder.values().last, Int64(fileData.count))
    }

    func test附件错误响应不会覆盖已有文件() async throws {
        let original = Data("ORIGINAL".utf8)
        let transport = MockHTTPTransport(responses: [
            DsmHTTPResponse(
                data: Data(#"{"success":false,"error":{"code":119}}"#.utf8),
                statusCode: 200,
                headers: ["content-type": "application/json"]
            )
        ])
        let repository = try makeRepository(transport: transport)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-existing-\(UUID().uuidString).txt")
        try original.write(to: destination, options: .atomic)
        defer { try? FileManager.default.removeItem(at: destination) }

        do {
            try await repository.downloadAttachment(
                messageID: "9001",
                to: destination,
                progress: { _, _ in }
            )
            XCTFail("错误响应不应被保存为附件")
        } catch {
            XCTAssertEqual(try Data(contentsOf: destination), original)
        }
    }

    func test创建和取消定时消息使用确认契约并复查() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"schedules":[]}}"#),
            response(#"{"success":true,"data":{"cronjob_id":"job-1","channel_id":"27","message":"稍后见","send_at":1800000000000}}"#),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"schedules":[]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let sendAt = Date(timeIntervalSince1970: 1_800_000_000)

        let scheduled = try await repository.createScheduledMessage(
            conversationID: "27",
            text: "稍后见",
            sendAt: sendAt,
            clientRequestID: UUID()
        )
        try await repository.deleteScheduledMessage(
            id: scheduled.id,
            conversationID: "27",
            clientRequestID: UUID()
        )

        XCTAssertEqual(scheduled.id, "job-1")
        let requests = await transport.recordedRequests()
        let initialListFields = try decodeForm(requests[0].httpBody)
        XCTAssertEqual(initialListFields["method"], "list")
        XCTAssertEqual(initialListFields["channel_id"], "27")
        let createFields = try decodeForm(requests[1].httpBody)
        XCTAssertEqual(createFields["api"], DsmAPIName.chatPostSchedule)
        XCTAssertEqual(createFields["method"], "create")
        XCTAssertEqual(createFields["channel_id"], "27")
        XCTAssertEqual(createFields["message"], "稍后见")
        XCTAssertEqual(createFields["send_at"], "1800000000000")
        let deleteFields = try decodeForm(requests[2].httpBody)
        XCTAssertEqual(deleteFields["method"], "delete")
        XCTAssertEqual(deleteFields["cronjob_id"], "job-1")
        let verificationFields = try decodeForm(requests[3].httpBody)
        XCTAssertEqual(verificationFields["method"], "list")
        XCTAssertEqual(verificationFields["channel_id"], "27")
    }

    func test附件使用已验证的ChatPostV5多段上传且报告进度() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9010","channel_id":"27","creator_id":"1","create_at":1774166400000,"message":"测试附件","type":"file","file_props":{"file_id":"f-1","name":"sample.png","size":7,"type":"png"}}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-sample.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: "测试附件",
            localAttachmentURLs: [fileURL]
        )
        let progressRecorder = ChatProgressRecorder()

        let message = try await repository.sendMessage(draft) { completed, _ in
            progressRecorder.append(completed)
        }

        XCTAssertEqual(message.attachments.first?.fileName, "sample.png")
        XCTAssertEqual(message.attachments.first?.kind, .image)
        XCTAssertEqual(message.clientRequestID, draft.clientRequestID)
        XCTAssertFalse(progressRecorder.values().isEmpty)
        let recordedRequests = await transport.recordedRequests()
        let request = try XCTUnwrap(recordedRequests.first)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(
            url: try XCTUnwrap(request.url),
            resolvingAgainstBaseURL: false
        )?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["api"], DsmAPIName.chatPost)
        XCTAssertEqual(query["version"], "5")
        XCTAssertEqual(query["method"], "create")
        XCTAssertNil(query["_sid"])
        XCTAssertNil(query["SynoToken"])
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        let recordedBodies = await transport.recordedUploadBodies()
        let body = try XCTUnwrap(recordedBodies.first)
        let bodyText = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"channel_id\""))
        XCTAssertTrue(bodyText.contains("name=\"type\""))
        XCTAssertTrue(bodyText.contains("filename=\"\(fileURL.lastPathComponent)\""))
        XCTAssertTrue(bodyText.contains("PNGDATA"))
    }

    func test附件发送结果成功前必须稳定回读确认() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-sample.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transport = MockHTTPTransport(responses: [
            response("""
            {"success":true,"data":{"post_id":"9010","channel_id":"27","creator_id":"1","create_at":1774166400000,"message":"测试附件","type":"file","file_props":{"file_id":"f-1","name":"\(fileURL.lastPathComponent)","size":7,"type":"png"}}}
            """),
            response("""
            {"success":true,"data":{"posts":[{"post_id":"9010","channel_id":"27","creator":{"user_id":"1","is_current_user":true},"create_at":1774166400000,"message":"测试附件","type":"file","file_props":{"file_id":"f-1","name":"\(fileURL.lastPathComponent)","size":7,"type":"png"}}]}}
            """)
        ])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: "测试附件",
            localAttachmentURLs: [fileURL]
        )

        let first = try await repository.sendAttachmentMessageResult(draft)
        let second = try await repository.sendAttachmentMessageResult(draft)

        XCTAssertEqual(first.result.status, .confirmedSuccess)
        XCTAssertEqual(first.result.operation, "chatAttachmentSend")
        XCTAssertEqual(first.confirmedMessage?.id, "9010")
        XCTAssertEqual(second.result.status, .confirmedSuccess)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try decodeForm(requests[1].httpBody)["method"], "list")
    }

    func test旧附件发送入口在响应缺少完整消息时使用稳定标识回读() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-legacy-readback.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9010"}}"#),
            response("""
            {"success":true,"data":{"posts":[{"post_id":"9010","channel_id":"27","creator":{"user_id":"1","is_current_user":true},"create_at":1774166400000,"message":"测试附件","type":"file","file_props":{"file_id":"f-1","name":"\(fileURL.lastPathComponent)","size":7,"type":"png"}}]}}
            """)
        ])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: "测试附件",
            localAttachmentURLs: [fileURL]
        )

        let message = try await repository.sendMessage(draft)

        XCTAssertEqual(message.id, "9010")
        XCTAssertEqual(message.attachments.count, 1)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(try decodeForm(requests[1].httpBody)["method"], "list")
    }

    func test附件发送提交前取消不会发起上传() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(transport: transport)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-cancel-before.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: nil,
            localAttachmentURLs: [fileURL]
        )
        let task = Task { () throws -> ChatMessageSendOutcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await repository.sendAttachmentMessageResult(draft)
        }

        let outcome = try await task.value

        XCTAssertEqual(outcome.result.status, .cancelledBeforeSubmission)
        XCTAssertFalse(outcome.result.submitted)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test附件发送提交后取消只进入核对且同请求不重传() async throws {
        let transport = MockHTTPTransport(steps: [.waitUntilCancelled])
        let repository = try makeRepository(transport: transport)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-cancel-after.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: nil,
            localAttachmentURLs: [fileURL]
        )
        let task = Task { try await repository.sendAttachmentMessageResult(draft) }
        var uploadStarted = false
        for _ in 0..<50 {
            if await transport.recordedRequests().count == 1 {
                uploadStarted = true
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard uploadStarted else {
            task.cancel()
            _ = try? await task.value
            XCTFail("附件上传未进入传输层")
            return
        }

        task.cancel()
        let first = try await task.value
        let second = try await repository.sendAttachmentMessageResult(draft)

        XCTAssertEqual(first.result.status, .cancellationRequestedAfterSubmission)
        XCTAssertTrue(first.result.submitted)
        XCTAssertTrue(first.result.requiresRefresh)
        XCTAssertEqual(second.result.status, .submittedButUnverified)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func test附件发送传输失败后同请求不重传() async throws {
        let transport = MockHTTPTransport(steps: [.urlError(.networkConnectionLost)])
        let repository = try makeRepository(transport: transport)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-transport-failure.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: nil,
            localAttachmentURLs: [fileURL]
        )

        let first = try await repository.sendAttachmentMessageResult(draft)
        let second = try await repository.sendAttachmentMessageResult(draft)

        XCTAssertEqual(first.result.status, .submittedButUnverified)
        XCTAssertTrue(first.result.submitted)
        XCTAssertTrue(first.result.requiresRefresh)
        XCTAssertEqual(second.result.status, .submittedButUnverified)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func test附件发送回读不匹配只继续回读不重传() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9010","channel_id":"27","creator_id":"1","create_at":1774166400000,"message":"测试附件","type":"file","file_props":{"file_id":"f-1","name":"sample.png","size":7,"type":"png"}}}"#),
            response(#"{"success":true,"data":{"posts":[]}}"#),
            response(#"{"success":true,"data":{"posts":[{"post_id":"9010","channel_id":"27","creator":{"user_id":"1","is_current_user":true},"create_at":1774166400000,"message":"测试附件"}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-readback-mismatch.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: "测试附件",
            localAttachmentURLs: [fileURL]
        )

        let first = try await repository.sendAttachmentMessageResult(draft)
        let second = try await repository.sendAttachmentMessageResult(draft)

        XCTAssertEqual(first.result.status, .submittedButUnverified)
        XCTAssertEqual(second.result.status, .submittedButUnverified)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(try decodeForm(requests[1].httpBody)["method"], "list")
        XCTAssertEqual(try decodeForm(requests[2].httpBody)["method"], "list")
    }

    func test附件发送回读说明不匹配不会确认() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-caption-mismatch.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9010"}}"#),
            response("""
            {"success":true,"data":{"posts":[{"post_id":"9010","channel_id":"27","creator":{"user_id":"1","is_current_user":true},"create_at":1774166400000,"message":"不同说明","type":"file","file_props":{"file_id":"f-1","name":"\(fileURL.lastPathComponent)","size":7,"type":"png"}}]}}
            """)
        ])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: "原说明",
            localAttachmentURLs: [fileURL]
        )

        let outcome = try await repository.sendAttachmentMessageResult(draft)

        XCTAssertEqual(outcome.result.status, .submittedButUnverified)
        XCTAssertNil(outcome.confirmedMessage)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func test附件发送回读含额外附件不会确认() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-extra-attachment.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9010"}}"#),
            response("""
            {"success":true,"data":{"posts":[{"post_id":"9010","channel_id":"27","creator":{"user_id":"1","is_current_user":true},"create_at":1774166400000,"message":"测试附件","type":"file","files":[{"file_id":"f-1","name":"\(fileURL.lastPathComponent)","size":7,"type":"png"},{"file_id":"f-2","name":"extra.txt","size":1,"type":"txt"}] }]}}
            """)
        ])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: "测试附件",
            localAttachmentURLs: [fileURL]
        )

        let outcome = try await repository.sendAttachmentMessageResult(draft)

        XCTAssertEqual(outcome.result.status, .submittedButUnverified)
        XCTAssertNil(outcome.confirmedMessage)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func test附件发送回读缺少已知文件大小不会确认() async throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-missing-size.png")
        try Data("PNGDATA".utf8).write(to: fileURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"post_id":"9010"}}"#),
            response("""
            {"success":true,"data":{"posts":[{"post_id":"9010","channel_id":"27","creator":{"user_id":"1","is_current_user":true},"create_at":1774166400000,"message":"测试附件","type":"file","file_props":{"file_id":"f-1","name":"\(fileURL.lastPathComponent)","type":"png"}}]}}
            """)
        ])
        let repository = try makeRepository(transport: transport)
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: "测试附件",
            localAttachmentURLs: [fileURL]
        )

        let outcome = try await repository.sendAttachmentMessageResult(draft)

        XCTAssertEqual(outcome.result.status, .submittedButUnverified)
        XCTAssertNil(outcome.confirmedMessage)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 2)
    }

    func test附件发送拒绝多个本地文件且不发起上传() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(transport: transport)
        let firstURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-first.png")
        let secondURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DsmChatRepositoryTests-\(UUID().uuidString)-second.png")
        let draft = try ChatMessageDraft(
            conversationID: "27",
            text: nil,
            localAttachmentURLs: [firstURL, secondURL]
        )

        let outcome = try await repository.sendAttachmentMessageResult(draft)

        XCTAssertEqual(outcome.result.status, .unsupported)
        XCTAssertEqual(outcome.result.operation, "chatAttachmentSend")
        XCTAssertFalse(outcome.result.submitted)
        XCTAssertEqual(outcome.result.counts.failed, 1)
        let requests = await transport.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
    }

    func test删除自己的消息并复查结果且重复请求只执行一次() async throws {
        let ownPost = #"{"success":true,"data":{"posts":[{"post_id":"9001","channel_id":"27","creator_id":"1","creator_name":"testaccount","create_at":1774166400000,"message":"待删除"}]}}"#
        let transport = MockHTTPTransport(responses: [
            response(ownPost),
            response(#"{"success":true}"#),
            response(#"{"success":true,"data":{"posts":[]}}"#)
        ])
        let repository = try makeRepository(transport: transport)
        let requestID = UUID()

        try await repository.deleteMessage(
            conversationID: "27",
            messageID: "9001",
            clientRequestID: requestID
        )
        try await repository.deleteMessage(
            conversationID: "27",
            messageID: "9001",
            clientRequestID: requestID
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 3)
        let deleteFields = try decodeForm(requests[1].httpBody)
        XCTAssertEqual(deleteFields["api"], DsmAPIName.chatPost)
        XCTAssertEqual(deleteFields["method"], "delete")
        XCTAssertEqual(deleteFields["post_id"], "9001")
    }

    func test拒绝删除其他成员发送的消息且不发送写请求() async throws {
        let transport = MockHTTPTransport(responses: [
            response(#"{"success":true,"data":{"posts":[{"post_id":"9001","channel_id":"27","creator_id":"2","creator_name":"other","create_at":1774166400000,"message":"其他成员消息"}]}}"#)
        ])
        let repository = try makeRepository(transport: transport)

        do {
            try await repository.deleteMessage(
                conversationID: "27",
                messageID: "9001",
                clientRequestID: UUID()
            )
            XCTFail("应拒绝删除其他成员的消息")
        } catch let error as AppError {
            XCTAssertEqual(error.category, .permissionDenied)
        }

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func test关闭会话后复查会话已移除() async throws {
        let users = response(#"{"success":true,"data":{"current_user_id":"1","users":[{"user_id":"1","nickname":"testaccount"},{"user_id":"2","nickname":"other"}]}}"#)
        let existingChannels = response(#"{"success":true,"data":{"channels":[{"channel_id":"27","type":"anonymous","members":["1","2"]}]}}"#)
        let emptyChannels = response(#"{"success":true,"data":{"channels":[]}}"#)
        let transport = MockHTTPTransport(responses: [
            users,
            existingChannels,
            response(#"{"success":true}"#),
            users,
            emptyChannels
        ])
        let repository = try makeRepository(transport: transport)
        let requestID = UUID()

        try await repository.closeConversation(
            conversationID: "27",
            clientRequestID: requestID
        )
        try await repository.closeConversation(
            conversationID: "27",
            clientRequestID: requestID
        )

        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 5)
        let closeFields = try decodeForm(requests[2].httpBody)
        XCTAssertEqual(closeFields["api"], DsmAPIName.chatChannel)
        XCTAssertEqual(closeFields["method"], "close")
        XCTAssertEqual(closeFields["channel_id"], "27")
    }

    private func makeRepository(
        transport: MockHTTPTransport,
        includesAvatarCapability: Bool = false,
        chatPostVersion: Int = 8
    ) throws -> DsmChatRepository {
        var names = [
            DsmAPIName.chatChannel: 5,
            DsmAPIName.chatChannelNamed: 1,
            DsmAPIName.chatChannelAnonymous: 2,
            DsmAPIName.chatChannelMember: 1,
            DsmAPIName.chatUser: 3,
            DsmAPIName.chatPost: chatPostVersion,
            DsmAPIName.chatPostFile: 2,
            DsmAPIName.chatPostReminder: 1,
            DsmAPIName.chatPostVote: 1,
            DsmAPIName.chatPostSchedule: 1
        ]
        if includesAvatarCapability {
            names[DsmAPIName.chatUserAvatar] = 1
        }
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { name, version in
            (name, ApiCapability(
                name: name,
                path: "entry.cgi",
                minVersion: 1,
                maxVersion: version,
                requestFormat: .form,
                selectedVersion: version
            ))
        }))
        return try DsmChatRepository(
            profile: NasProfile(
                displayName: "测试设备",
                host: "nas.example.invalid",
                port: 5_001,
                usernameHint: "testaccount"
            ),
            capabilities: capabilities,
            session: AuthSession(
                sid: "SANITIZED_TEST_SID",
                synoToken: "SANITIZED_TEST_TOKEN",
                did: nil,
                isPortalPort: false
            ),
            transport: transport
        )
    }

    private func response(_ json: String) -> DsmHTTPResponse {
        DsmHTTPResponse(data: Data(json.utf8), statusCode: 200)
    }

    private func decodeForm(_ data: Data?) throws -> [String: String] {
        let body = try XCTUnwrap(data.flatMap { String(data: $0, encoding: .utf8) })
        let components = try XCTUnwrap(URLComponents(string: "?\(body)"))
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map {
            ($0.name, $0.value ?? "")
        })
    }
}

private final class ChatProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValues: [Int64] = []

    func append(_ value: Int64) {
        lock.lock()
        recordedValues.append(value)
        lock.unlock()
    }

    func values() -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return recordedValues
    }
}
