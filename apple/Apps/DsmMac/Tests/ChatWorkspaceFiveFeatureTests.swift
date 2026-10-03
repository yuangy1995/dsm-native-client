import AVFoundation
import DsmCore
import DsmLocalization
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
extension ChatWorkspaceModelTests {
    func test语音点击即播放支持暂停继续且离开后删除临时音频() async throws {
        let data = silentVoiceData()
        let repository = ChatRepositoryStub(conversations: [conversation(id: "one", title: "合成", activity: Date())],
                                            downloadedAttachmentData: data)
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let selection = ChatMediaSelection(message: message(id: "voice", conversationID: "one", date: Date()),
            attachment: ChatAttachment(id: "voice", kind: .voice, fileName: "synthetic.wav", sizeBytes: Int64(data.count)))
        let playback = ChatVoicePlayback()
        defer { playback.stop(); model.cancelAllWork() }
        await playback.toggle(selection, model: model)
        XCTAssertTrue(playback.isPlaying)
        XCTAssertFalse(playback.isLoading)
        XCTAssertNil(playback.errorMessage)
        await playback.toggle(selection, model: model)
        XCTAssertFalse(playback.isPlaying)
        await playback.toggle(selection, model: model)
        XCTAssertTrue(playback.isPlaying)
        let deadline = Date().addingTimeInterval(2)
        while playback.isPlaying && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(playback.isPlaying, "播完后应恢复播放按钮")
        await playback.toggle(selection, model: model)
        XCTAssertTrue(playback.isPlaying, "播完可从头重播")
        let files = await repository.downloadedAttachmentDestinations()
        XCTAssertEqual(files.count, 1, "暂停与继续不重复下载")
        let file = try XCTUnwrap(files.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        playback.stop()
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(playback.selectionID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    func test离开会话会取消正在加载的语音且不会迟到自动播放() async throws {
        let data = silentVoiceData()
        let repository = ChatRepositoryStub(conversations: [conversation(id: "one", title: "合成", activity: Date())],
            downloadedAttachmentData: data, attachmentDownloadDelay: .seconds(5))
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let playback = ChatVoicePlayback()
        let selection = ChatMediaSelection(message: message(id: "voice", conversationID: "one", date: Date()),
            attachment: ChatAttachment(id: "voice", kind: .voice, fileName: "synthetic.wav", sizeBytes: Int64(data.count)))
        let loading = Task { await playback.toggle(selection, model: model) }
        let deadline = Date().addingTimeInterval(1)
        while await repository.downloadedAttachmentDestinations().isEmpty && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(playback.isLoading)
        playback.stop()
        await loading.value
        XCTAssertFalse(playback.isLoading)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertNil(playback.selectionID)
        let files = await repository.downloadedAttachmentDestinations()
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        model.cancelAllWork()
    }

    private func silentVoiceData() -> Data {
        // 一秒静音 PCM，测试不采集麦克风，也不发出提示音。
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(UInt32(32_036)); data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(UInt32(16_000)); append(UInt32(32_000)); append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8)); append(UInt32(32_000)); data.append(Data(repeating: 0, count: 32_000))
        return data
    }

    func test模块启用后不进入页面也保持连接离开页面不停止而关闭模块停止() async throws {
        let repository = ChatRepositoryStub(conversations: [])
        let model = ChatWorkspaceModel(repository: repository)
        model.startBackgroundSync()
        model.startBackgroundSync()
        var deadline = Date().addingTimeInterval(2)
        while await repository.realtimeCounts().started == 0 && Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        var counts = await repository.realtimeCounts()
        XCTAssertEqual(counts.started, 1)
        XCTAssertEqual(counts.stopped, 0)
        model.setChatVisibility(true)
        model.setChatVisibility(false)
        await repository.emitRealtime(.connected)
        deadline = Date().addingTimeInterval(2)
        while !model.isRealtimeConnected && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.isRealtimeConnected)
        counts = await repository.realtimeCounts()
        XCTAssertEqual(counts.stopped, 0)
        model.setModuleEnabled(false)
        await model.stopRealtime()
        XCTAssertFalse(model.isRealtimeConnected)
        counts = await repository.realtimeCounts()
        XCTAssertEqual(counts.stopped, 1)
        model.setModuleEnabled(true)
        deadline = Date().addingTimeInterval(2)
        while await repository.realtimeCounts().started < 2 && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        counts = await repository.realtimeCounts()
        XCTAssertEqual(counts.started, 2)
        model.cancelAllWork()
        await model.stopRealtime()
    }

    func test新消息未呈现到可视区域前不得使用旧的底部状态标记已读() async {
        let date = Date(timeIntervalSince1970: 1_000)
        let conversation = ChatConversation(id: "one", kind: .direct, title: "合成", memberIDs: [], lastActivityAt: date, unreadCount: 1)
        let repository = ChatRepositoryStub(conversations: [conversation], messagesByConversation: ["one": [message(id: "old", conversationID: "one", date: date)]])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.refreshForegroundChat()
        model.isChatWindowActive = true; model.updateVisibleMessage("old")
        await model.synchronizeVisibleReadState()
        await repository.replaceMessages([message(id: "new", conversationID: "one", date: date.addingTimeInterval(60))], in: "one")
        await model.refreshCurrentConversation()
        var marks = await repository.recordedReadMarkers()
        XCTAssertEqual(marks.count, 1)
        model.updateVisibleMessage("new")
        await model.synchronizeVisibleReadState()
        marks = await repository.recordedReadMarkers()
        XCTAssertEqual(marks.count, 2)
        XCTAssertEqual(marks.last?.1, date.addingTimeInterval(60))
    }

    func test其他设备重新标记未读时不被旧的本地已读缓存覆盖() async {
        let date = Date(timeIntervalSince1970: 1_000)
        let value = ChatConversation(id: "one", kind: .direct, title: "合成", memberIDs: [], lastActivityAt: date, unreadCount: 3)
        let repository = ChatRepositoryStub(conversations: [value], messagesByConversation: [value.id: [message(id: "last", conversationID: value.id, date: date)]])
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.refreshForegroundChat()
        model.isChatWindowActive = true; model.updateVisibleMessage(model.messages.last(where: { $0.deliveryState == .sent })?.id)
        await model.synchronizeVisibleReadState()
        XCTAssertEqual(model.totalUnreadCount, 0)
        model.setChatVisibility(false)
        await repository.replaceConversations([value])
        await model.syncWorkspaceChat(isChatVisible: false)
        XCTAssertEqual(model.totalUnreadCount, 3)
        model.cancelAllWork()
    }

    func test合成AAC通过附件准备后可由系统解码且不需要麦克风() async throws {
        // 离线生成的 0.4 秒 440Hz 音频，没有采集任何真实声音。
        let data = try XCTUnwrap(Data(base64Encoded: "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"))
        let active = conversation(id: "one", title: "测试", activity: Date())
        let model = ChatWorkspaceModel(repository: ChatRepositoryStub(conversations: [active], downloadedAttachmentData: data))
        await model.loadIfNeeded()
        let file = try await model.prepareMedia(message: message(id: "aac", conversationID: "one", date: Date()),
            attachment: ChatAttachment(id: "aac", kind: .voice, fileName: "voice.aac", sizeBytes: Int64(data.count)))
        defer { model.discardTemporaryMedia(file) }
        let asset = AVURLAsset(url: file)
        let playable = try await asset.load(.isPlayable)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(playable)
        XCTAssertGreaterThan(duration.seconds, 0.3)
        XCTAssertLessThan(duration.seconds, 1)
    }

    func test已读写失败保留未读并在重新可见时恢复() async {
        let sentAt = Date(timeIntervalSince1970: 1_000)
        let active = ChatConversation(id: "one", kind: .direct, title: "测试", memberIDs: [], lastActivityAt: sentAt, unreadCount: 3)
        let repository = ChatRepositoryStub(conversations: [active], messagesByConversation: [active.id: [message(id: "m1", conversationID: active.id, date: sentAt)]])
        await repository.setReadSyncShouldFail(true)
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        await model.refreshForegroundChat()
        model.isChatWindowActive = true
        model.updateVisibleMessage(model.messages.last(where: { $0.deliveryState == .sent })?.id)
        await model.synchronizeVisibleReadState()
        XCTAssertEqual(model.totalUnreadCount, 3)
        await repository.setReadSyncShouldFail(false)
        model.isChatWindowActive = false
        await model.synchronizeVisibleReadState()
        var writes = await repository.recordedReadMarkers()
        XCTAssertEqual(writes.count, 1)
        model.isChatWindowActive = true
        await model.synchronizeVisibleReadState()
        await model.synchronizeVisibleReadState()
        writes = await repository.recordedReadMarkers()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last?.1, sentAt)
        XCTAssertEqual(model.totalUnreadCount, 0)
    }

    func test通知跳过初始历史本人消息和重复刷新() async {
        let firstTime = Date(timeIntervalSince1970: 1_000)
        func value(_ offset: TimeInterval, unread: Int) -> ChatConversation {
            ChatConversation(id: "one", kind: .direct, title: "测试", memberIDs: [], lastActivityAt: firstTime.addingTimeInterval(offset), unreadCount: unread)
        }
        func post(_ id: String, offset: TimeInterval, mine: Bool) -> ChatMessage {
            ChatMessage(id: id, conversationID: "one", senderID: mine ? "me" : "peer", isFromCurrentUser: mine,
                sentAt: firstTime.addingTimeInterval(offset), text: "合成内容")
        }
        let repository = ChatRepositoryStub(conversations: [value(0, unread: 3)], messagesByConversation: ["one": [post("history", offset: 0, mine: false)]])
        var notices: [(String, String)] = []
        let model = ChatWorkspaceModel(repository: repository, notifyChat: { _, channel, _, message in notices.append((channel, message)) })
        await model.loadIfNeeded()
        await model.syncWorkspaceChat(isChatVisible: false)
        XCTAssertTrue(notices.isEmpty)
        await repository.replaceConversations([value(60, unread: 4)])
        await repository.replaceMessages([post("incoming", offset: 60, mine: false)], in: "one")
        await model.syncWorkspaceChat(isChatVisible: false)
        await model.syncWorkspaceChat(isChatVisible: false)
        XCTAssertEqual(notices.map(\.1), ["incoming"])
        await repository.replaceConversations([value(120, unread: 4)])
        await repository.replaceMessages([post("own", offset: 120, mine: true)], in: "one")
        await model.syncWorkspaceChat(isChatVisible: false)
        XCTAssertEqual(notices.count, 1)
        model.cancelAllWork()
    }

    func test正在阅读最新消息时不发送系统通知但后台会通知() async {
        let firstTime = Date(timeIntervalSince1970: 1_000)
        func conversationAt(_ offset: TimeInterval) -> ChatConversation {
            ChatConversation(id: "one", kind: .direct, title: "测试", memberIDs: [], lastActivityAt: firstTime.addingTimeInterval(offset), unreadCount: 2)
        }
        let first = ChatMessage(id: "first", conversationID: "one", senderID: "peer", isFromCurrentUser: false, sentAt: firstTime, text: "合成")
        let repository = ChatRepositoryStub(conversations: [conversationAt(0)], messagesByConversation: ["one": [first]])
        var notices = 0
        let model = ChatWorkspaceModel(repository: repository, notifyChat: { _, _, _, _ in notices += 1 })
        await model.loadIfNeeded()
        await model.refreshForegroundChat()
        model.isChatWindowActive = true
        model.updateVisibleMessage(model.messages.last(where: { $0.deliveryState == .sent })?.id)
        await repository.replaceConversations([conversationAt(60)])
        await repository.replaceMessages([ChatMessage(id: "visible", conversationID: "one", senderID: "peer", isFromCurrentUser: false, sentAt: firstTime.addingTimeInterval(60), text: "可见")], in: "one")
        await model.syncWorkspaceChat(isChatVisible: true)
        XCTAssertEqual(notices, 0)
        model.isChatWindowActive = false
        await repository.replaceConversations([conversationAt(120)])
        await repository.replaceMessages([ChatMessage(id: "background", conversationID: "one", senderID: "peer", isFromCurrentUser: false, sentAt: firstTime.addingTimeInterval(120), text: "后台")], in: "one")
        await model.syncWorkspaceChat(isChatVisible: true)
        XCTAssertEqual(notices, 1)
        model.cancelAllWork()
    }

    func test媒体只准备本地文件并在关闭后清理且拒绝超限或加密附件() async throws {
        let data = Data("synthetic audio bytes".utf8)
        let active = conversation(id: "one", title: "测试", activity: Date())
        let repository = ChatRepositoryStub(conversations: [active], downloadedAttachmentData: data)
        let model = ChatWorkspaceModel(repository: repository)
        await model.loadIfNeeded()
        let post = message(id: "audio", conversationID: "one", date: Date())
        let attachment = ChatAttachment(id: "audio", kind: .voice, fileName: "voice.aac", sizeBytes: Int64(data.count))
        let file = try await model.prepareMedia(message: post, attachment: attachment)
        XCTAssertTrue(file.isFileURL)
        XCTAssertEqual(try Data(contentsOf: file), data)
        model.discardTemporaryMedia(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let oversized = ChatAttachment(id: "huge", kind: .video, fileName: "large.mp4", sizeBytes: 513 * 1_024 * 1_024)
        do { _ = try await model.prepareMedia(message: post, attachment: oversized); XCTFail("超限不能准备播放") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
        let encrypted = ChatMessage(id: "locked", conversationID: "one", senderID: "peer", sentAt: Date(), text: "", encryptionState: .locked)
        do { _ = try await model.prepareMedia(message: encrypted, attachment: attachment); XCTFail("不能播放加密附件") }
        catch let error as AppError { XCTAssertEqual(error.category, .apiUnavailable) }
    }

    func test语音暂存独立于录音原件且不能删除目录外文件() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("ChatVoiceSource-\(UUID().uuidString).aac")
        try Data("synthetic AAC".utf8).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let model = ChatWorkspaceModel(repository: ChatRepositoryStub(conversations: []))
        let staged = try model.stageVoiceRecording(source)
        defer { model.discardTemporaryMedia(staged) }
        XCTAssertNotEqual(source, staged)
        model.discardTemporaryMedia(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path))
    }

    func test五项功能文案具有双语且不向用户暴露内部流程() {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        let keys = ["chat.search.recovery", "chat.edit.unavailable", "chat.update.pending", "chat.thread.recovery", "chat.vote.recovery",
                    "chat.voice.permission", "chat.voice.failed", "chat.media.recovery", "chat.notification.denied"]
        for language in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = language
            for key in keys {
                let text = L10n.string(key).lowercased()
                XCTAssertNotEqual(text, key)
                for term in ["待确认", "核对", "验证中", "api", "sid", "synotoken", "verification", "check result"] {
                    XCTAssertFalse(text.contains(term), "\(key) 应保持普通用户文案")
                }
            }
        }
    }
}
