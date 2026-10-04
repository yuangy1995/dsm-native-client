import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatTimedActionTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChatTimedTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    private func repository(_ transport: MobileChatTimedUITransport, postVersion: Int = 8, includesTimed: Bool = true) throws -> MobileReadOnlyChatRepository {
        let profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        var versions = [DsmAPIName.chatChannel: 2, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: postVersion]
        if includesTimed { versions[DsmAPIName.chatPostReminder] = 1; versions[DsmAPIName.chatPostSchedule] = 1 }
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version, verified: false))
        }))
        return MobileReadOnlyChatRepository(base: try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport))
    }
    private func make(_ transport: MobileChatTimedUITransport, root: URL? = nil, context: String = "fixture-context") async throws -> MobileChatTimedActionModel {
        let repository = try repository(transport)
        let model = MobileChatTimedActionModel(context: context, repository: repository, recovery: MobileChatTimedActionStore(root: try root ?? directory()))
        model.updateAvailability(await repository.availability()); return model
    }
    private var conversation: ChatConversation { ChatConversation(id: "27", kind: .group, title: "Sample chat", memberIDs: ["1", "2"]) }
    private var seed: ChatMessage { ChatMessage(id: "9001", conversationID: "27", senderID: "1", sentAt: .now, text: "Sample message 1") }
    private var future: Date { Date().addingTimeInterval(3_600) }
    private func create(_ model: MobileChatTimedActionModel) async -> Bool { await model.createSchedule(in: conversation, text: " Later sample ", at: future) }

    func test提醒创建修改并取消使用原消息和毫秒时间() async throws {
        let transport = MobileChatTimedUITransport(state: "chat-timed-empty"); let model = try await make(transport)
        let date = future
        let saved = await model.setReminder(for: seed, at: date, replacing: nil)
        XCTAssertTrue(saved); XCTAssertEqual(model.reminders.count, 1)
        let original = try XCTUnwrap(model.reminders.first)
        XCTAssertEqual(original.messageID, "9001"); XCTAssertEqual(original.remindAt.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        let edited = await model.setReminder(for: seed, at: date.addingTimeInterval(60), replacing: original)
        XCTAssertTrue(edited)
        let changed = try XCTUnwrap(model.reminders.first)
        let deleted = await model.deleteReminder(changed, in: "27")
        XCTAssertTrue(deleted); XCTAssertTrue(model.reminders.isEmpty); XCTAssertTrue(model.pending.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, ["reminder-set": 2, "reminder-delete": 1])
    }
    func test定时创建回读完整内容并取消精确对象() async throws {
        let transport = MobileChatTimedUITransport(state: "chat-timed-empty"); let model = try await make(transport)
        let saved = await create(model); XCTAssertTrue(saved)
        let value = try XCTUnwrap(model.schedules.first)
        XCTAssertEqual(value.text, "Later sample"); XCTAssertEqual(value.conversationID, "27"); XCTAssertEqual(value.id, "job-101")
        let deleted = await model.deleteSchedule(value); XCTAssertTrue(deleted); XCTAssertTrue(model.schedules.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, ["schedule-create": 1, "schedule-delete": 1])
    }
    func test定时重复点击只创建一次() async throws {
        let transport = MobileChatTimedUITransport(state: "chat-timed-slow"); let model = try await make(transport)
        let first = Task { await create(model) }
        while await transport.counts().writes["schedule-create"] == nil { await Task.yield() }
        let second = await create(model); XCTAssertFalse(second)
        let result = await first.value; XCTAssertTrue(result)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes["schedule-create"], 1)
    }
    func test提醒丢回执后重启只读取原时间() async throws {
        let root = try directory(); let transport = MobileChatTimedUITransport(state: "chat-timed-unknown"); let model = try await make(transport, root: root)
        await model.loadReminders(in: "27"); let baseline = try XCTUnwrap(model.reminders.first)
        let saved = await model.setReminder(for: seed, at: future, replacing: baseline)
        XCTAssertFalse(saved); XCTAssertEqual(model.pending.count, 1)
        await transport.setReadFailures(false)
        let restarted = try await make(transport, root: root); await restarted.recover()
        XCTAssertTrue(restarted.pending.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes["reminder-set"], 1)
    }
    func test定时创建回执落盘重启按身份正文时间恢复() async throws {
        let root = try directory(); let transport = MobileChatTimedUITransport(state: "chat-timed-read-failure"); let model = try await make(transport, root: root)
        let saved = await create(model); XCTAssertFalse(saved); XCTAssertEqual(model.pending.first?.targetID, "job-101")
        let text = try String(contentsOf: root.appendingPathComponent("timed-actions-v1.json"), encoding: .utf8)
        XCTAssertFalse(text.contains("Later sample")); XCTAssertFalse(text.contains("synthetic")); XCTAssertTrue(text.contains("job-101"))
        await transport.setReadFailures(false)
        let restarted = try await make(transport, root: root); await restarted.recover(); XCTAssertTrue(restarted.pending.isEmpty)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes["schedule-create"], 1)
    }
    func test无定时创建回执时同内容和改内容均不重新发送() async throws {
        let root = try directory(); let transport = MobileChatTimedUITransport(state: "chat-timed-unknown"); let model = try await make(transport, root: root)
        let saved = await create(model); XCTAssertFalse(saved); XCTAssertNil(model.pending.first?.targetID)
        await transport.setReadFailures(false)
        let restarted = try await make(transport, root: root); await restarted.recover()
        let repeated = await restarted.createSchedule(in: conversation, text: "Different", at: future)
        XCTAssertFalse(repeated); XCTAssertEqual(restarted.pending.count, 1)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes["schedule-create"], 1)
    }
    func test其他客户端改变定时内容不得认领创建结果() async throws {
        let transport = MobileChatTimedUITransport(state: "chat-timed-read-failure"); let model = try await make(transport)
        let saved = await create(model); XCTAssertFalse(saved)
        await transport.changeSchedule(); await transport.setReadFailures(false); await model.recover()
        XCTAssertEqual(model.pending.count, 1)
    }
    func test取消提醒前原时间改变则零删除() async throws {
        let transport = MobileChatTimedUITransport(); let model = try await make(transport)
        await model.loadReminders(in: "27"); let original = try XCTUnwrap(model.reminders.first)
        await transport.changeReminder()
        let deleted = await model.deleteReminder(original, in: "27")
        XCTAssertFalse(deleted); XCTAssertEqual(model.errorKey, "mobile.chat.timed.changed")
        let counts = await transport.counts(); XCTAssertTrue(counts.writes.isEmpty)
    }
    func test修改提醒前原时间改变则零覆盖() async throws {
        let transport = MobileChatTimedUITransport(); let model = try await make(transport)
        await model.loadReminders(in: "27"); let original = try XCTUnwrap(model.reminders.first)
        await transport.changeReminder()
        let saved = await model.setReminder(for: seed, at: future, replacing: original)
        XCTAssertFalse(saved); let counts = await transport.counts(); XCTAssertTrue(counts.writes.isEmpty)
    }
    func test取消定时前正文改变则零删除() async throws {
        let transport = MobileChatTimedUITransport(); let model = try await make(transport)
        await model.loadSchedules(in: "27"); let original = try XCTUnwrap(model.schedules.first)
        await transport.changeSchedule()
        let deleted = await model.deleteSchedule(original)
        XCTAssertFalse(deleted); XCTAssertEqual(model.errorKey, "mobile.chat.timed.changed")
        let counts = await transport.counts(); XCTAssertTrue(counts.writes.isEmpty)
    }
    func test取消提醒和定时丢回执后只读恢复且不重复删除() async throws {
        for isReminder in [true, false] {
            let root = try directory(); let transport = MobileChatTimedUITransport(state: "chat-timed-unknown"); let model = try await make(transport, root: root)
            if isReminder {
                await model.loadReminders(in: "27"); let value = try XCTUnwrap(model.reminders.first)
                let first = await model.deleteReminder(value, in: "27"); let repeatResult = await model.deleteReminder(value, in: "27")
                XCTAssertFalse(first); XCTAssertFalse(repeatResult)
            } else {
                await model.loadSchedules(in: "27"); let value = try XCTUnwrap(model.schedules.first)
                let first = await model.deleteSchedule(value); let repeatResult = await model.deleteSchedule(value)
                XCTAssertFalse(first); XCTAssertFalse(repeatResult)
            }
            XCTAssertEqual(model.pending.count, 1); await transport.setReadFailures(false)
            let restarted = try await make(transport, root: root); await restarted.recover(); XCTAssertTrue(restarted.pending.isEmpty)
            let counts = await transport.counts(); XCTAssertEqual(counts.writes.values.reduce(0, +), 1)
        }
    }
    func test超过发送时间后消失不能证明取消成功() async throws {
        let root = try directory(); let transport = MobileChatTimedUITransport(state: "chat-timed-empty"); let model = try await make(transport, root: root)
        let entry = MobileChatTimedActionStore.Entry(id: UUID(), context: model.context, kind: .deleteSchedule, conversationID: "27", targetID: "job-past", time: .distantPast, textDigest: MobileChatInteractionStore.digest("Sample"))
        XCTAssertTrue(model.recovery.reserve(entry)); await model.recover(); XCTAssertEqual(model.pending, [entry])
        let counts = await transport.counts(); XCTAssertTrue(counts.writes.isEmpty)
    }
    func test读取重复身份不得显示成功或删除() async throws {
        let transport = MobileChatTimedUITransport(); let model = try await make(transport)
        await model.loadSchedules(in: "27"); let original = try XCTUnwrap(model.schedules.first)
        await transport.setDuplicates(true); await model.loadReminders(in: "27"); await model.loadSchedules(in: "27")
        XCTAssertEqual(model.reminderState, .error); XCTAssertEqual(model.scheduleState, .error)
        let deleted = await model.deleteSchedule(original); XCTAssertFalse(deleted)
        let counts = await transport.counts(); XCTAssertTrue(counts.writes.isEmpty)
    }
    func test明确拒绝解除四种操作的本地限制() async throws {
        for kind in 0..<4 {
            let transport = MobileChatTimedUITransport(state: "chat-timed-denied"); let model = try await make(transport)
            await model.loadReminders(in: "27"); await model.loadSchedules(in: "27")
            let result: Bool
            switch kind {
            case 0: result = await create(model)
            case 1: result = await model.setReminder(for: seed, at: future, replacing: model.reminders.first)
            case 2: result = await model.deleteReminder(try XCTUnwrap(model.reminders.first), in: "27")
            default: result = await model.deleteSchedule(try XCTUnwrap(model.schedules.first))
            }
            XCTAssertFalse(result); XCTAssertTrue(model.pending.isEmpty); XCTAssertEqual(model.errorKey, "mobile.chat.timed.failed")
        }
    }
    func test会话加密或不可访问时零写入() async throws {
        for encrypted in [true, false] {
            let transport = MobileChatTimedUITransport(); let model = try await make(transport)
            await transport.setAccess(encrypted: encrypted, missing: !encrypted)
            let first = await create(model); let second = await model.setReminder(for: seed, at: future, replacing: nil)
            XCTAssertFalse(first); XCTAssertFalse(second); XCTAssertTrue(model.pending.isEmpty)
            let counts = await transport.counts(); XCTAssertTrue(counts.writes.isEmpty)
        }
    }
    func test过去时间和空正文在提交前拒绝() async throws {
        let transport = MobileChatTimedUITransport(); let model = try await make(transport)
        let a = await model.createSchedule(in: conversation, text: " ", at: future)
        let b = await model.createSchedule(in: conversation, text: "Sample", at: .distantPast)
        let c = await model.setReminder(for: seed, at: .distantPast, replacing: nil)
        XCTAssertFalse(a); XCTAssertFalse(b); XCTAssertFalse(c)
        let counts = await transport.counts(); XCTAssertTrue(counts.writes.isEmpty); XCTAssertEqual(counts.reads, 0)
    }
    func test无消息回读能力不开放提醒且缺定时能力拒绝写入() async throws {
        let transport = MobileChatTimedUITransport(); let old = try repository(transport, postVersion: 4)
        let availability = await old.availability(); XCTAssertFalse(availability.supportedFeatures.contains(.reminder)); XCTAssertFalse(availability.supportedFeatures.contains(.reminderManagement))
        let missing = try repository(transport, includesTimed: false)
        do { _ = try await missing.createScheduledMessage(conversationID: "27", text: "Sample", sendAt: future, clientRequestID: UUID()); XCTFail("不得越过能力边界") }
        catch { XCTAssertTrue(error is MobileReadOnlyChatRepositoryError) }
        let counts = await transport.counts(); XCTAssertTrue(counts.writes.isEmpty)
    }
    func test损坏文件与存储不可写时零提交() async throws {
        for corrupted in [true, false] {
            let root = try directory()
            if corrupted { try Data("broken".utf8).write(to: root.appendingPathComponent("timed-actions-v1.json")) }
            else { try FileManager.default.removeItem(at: root); try Data().write(to: root) }
            let transport = MobileChatTimedUITransport(); let model = try await make(transport, root: root)
            let saved = await create(model); XCTAssertFalse(saved); XCTAssertTrue(model.recovery.failed)
            let counts = await transport.counts(); XCTAssertTrue(counts.writes.isEmpty)
        }
    }
    func test回执保存失败保留原未知记录且不再次创建() async throws {
        let root = try directory()
        let transport = MobileChatTimedUITransport(afterCreate: {
            try FileManager.default.removeItem(at: root); try Data().write(to: root)
        })
        let model = try await make(transport, root: root)
        let saved = await create(model); let repeated = await create(model)
        XCTAssertFalse(saved); XCTAssertFalse(repeated); XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.pending.count, 1)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes["schedule-create"], 1)
    }
    func test其他账号不读取或解除原账号恢复记录() async throws {
        let root = try directory(); let transport = MobileChatTimedUITransport(state: "chat-timed-read-failure"); let model = try await make(transport, root: root)
        let result = await create(model); XCTAssertFalse(result)
        let countsBefore = await transport.counts()
        let other = try await make(transport, root: root, context: "different-account"); await other.recover()
        XCTAssertTrue(other.pending.isEmpty); XCTAssertEqual(other.recovery.entries.count, 1)
        let countsAfter = await transport.counts(); XCTAssertEqual(countsBefore.reads, countsAfter.reads)
        XCTAssertTrue(other.canCreateSchedule(in: conversation))
    }
    func test切换账号后的迟到响应不污染旧页面() async throws {
        let transport = MobileChatTimedUITransport(state: "chat-timed-slow"); let model = try await make(transport)
        let task = Task { await create(model) }
        while await transport.counts().writes["schedule-create"] == nil { await Task.yield() }
        model.invalidate(); let result = await task.value
        XCTAssertFalse(result); XCTAssertTrue(model.schedules.isEmpty); XCTAssertTrue(model.pending.isEmpty)
    }
    func test提交前取消零请求且提交中取消不重放() async throws {
        let beforeTransport = MobileChatTimedUITransport(); let before = try await make(beforeTransport)
        let task = Task { await create(before) }; task.cancel(); let result = await task.value; XCTAssertFalse(result)
        let beforeCounts = await beforeTransport.counts(); XCTAssertTrue(beforeCounts.writes.isEmpty)
        let transport = MobileChatTimedUITransport(state: "chat-timed-slow"); let model = try await make(transport)
        let submitted = Task { await create(model) }
        while await transport.counts().writes["schedule-create"] == nil { await Task.yield() }
        submitted.cancel(); let completed = await submitted.value; XCTAssertFalse(completed); XCTAssertEqual(model.pending.count, 1)
        let repeated = await create(model); XCTAssertFalse(repeated)
        let counts = await transport.counts(); XCTAssertEqual(counts.writes["schedule-create"], 1)
    }
    func test加载空内容和网络失败区分正确() async throws {
        for state in ["chat-timed-empty", "chat-timed-load-error"] {
            let model = try await make(MobileChatTimedUITransport(state: state))
            await model.loadReminders(in: "27"); await model.loadSchedules(in: "27")
            XCTAssertEqual(model.reminderState, state == "chat-timed-empty" ? .empty : .error)
            XCTAssertEqual(model.scheduleState, state == "chat-timed-empty" ? .empty : .error)
        }
    }
    func test切换会话后迟到成功不替换新会话的提醒或定时列表() async throws {
        for reminder in [true, false] {
            let transport = MobileChatTimedUITransport(state: "chat-timed-slow"); let model = try await make(transport)
            await model.loadReminders(in: "27"); await model.loadSchedules(in: "27")
            let baseline = model.reminders.first
            let task = Task { reminder ? await model.setReminder(for: seed, at: future, replacing: baseline) : await create(model) }
            let key = reminder ? "reminder-set" : "schedule-create"
            while await transport.counts().writes[key] == nil { await Task.yield() }
            if reminder { await model.loadReminders(in: "28") } else { await model.loadSchedules(in: "28") }
            let saved = await task.value; XCTAssertTrue(saved); XCTAssertTrue(model.pending.isEmpty)
            if reminder { XCTAssertEqual(model.reminderConversationID, "28"); XCTAssertTrue(model.reminders.isEmpty) }
            else { XCTAssertEqual(model.scheduleConversationID, "28"); XCTAssertTrue(model.schedules.isEmpty) }
        }
    }

    func test原会话迟到错误不显示到新会话() async throws {
        let transport = MobileChatTimedUITransport(state: "chat-timed-slow"); let model = try await make(transport)
        let task = Task { await create(model) }
        while await transport.counts().writes["schedule-create"] == nil { await Task.yield() }
        await model.loadSchedules(in: "28"); await transport.setReadFailures(true)
        let saved = await task.value; XCTAssertFalse(saved)
        XCTAssertNotNil(model.error(in: "27")); XCTAssertNil(model.error(in: "28"))
        XCTAssertEqual(model.scheduleConversationID, "28"); XCTAssertTrue(model.schedules.isEmpty)
    }

}
