import AVFoundation
import DsmCore
import DsmNetwork
import Foundation
import UniformTypeIdentifiers
import XCTest
@testable import DsmMobile

@MainActor
final class MobileChatAudioTests: XCTestCase {
    func test只有主动录制才申请权限且拒绝不会生成文件() async throws {
        let (model, driver, root) = try fixture()
        XCTAssertEqual(driver.permissionRequests, 0)
        driver.permissionGranted = false
        await model.startRecording { true }
        XCTAssertEqual(driver.permissionRequests, 1); XCTAssertEqual(driver.recordCalls, 0)
        XCTAssertEqual(model.recordingErrorKey, "mobile.chat.voice.permission")
        XCTAssertFalse(model.canSendRecording); XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func test权限弹窗期间退出和再次进入不会录制迟到授权() async throws {
        let (model, driver, _) = try fixture()
        driver.delaysPermission = true
        let request = Task { await model.startRecording { true } }
        while driver.permissionContinuation == nil { await Task.yield() }
        XCTAssertTrue(model.isRequestingPermission)
        model.reset(); driver.permissionContinuation?.resume(returning: true)
        await request.value
        XCTAssertEqual(driver.recordCalls, 0); XCTAssertFalse(model.isRecording)
    }

    func test录制重复点击只启动一次且停止后可试听并丢弃() async throws {
        let (model, driver, _) = try fixture()
        await model.startRecording { true }; await model.startRecording { true }
        XCTAssertEqual(driver.recordCalls, 1); XCTAssertEqual(driver.limit, 300)
        XCTAssertFalse(model.canSendRecording)
        let url = try XCTUnwrap(model.recording?.localURL)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertEqual(try model.recording?.directoryURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        model.stopRecording(); XCTAssertTrue(model.canSendRecording); XCTAssertEqual(model.duration, 2)
        model.previewRecording(); XCTAssertTrue(model.isPlaying); XCTAssertEqual(driver.playCalls, 1)
        model.previewRecording(); XCTAssertFalse(model.isPlaying); XCTAssertEqual(driver.pauseCalls, 1)
        model.previewRecording(); XCTAssertTrue(model.isPlaying); XCTAssertEqual(driver.resumeCalls, 1)
        model.previewRecording(); driver.failPlayback = true; model.previewRecording()
        XCTAssertEqual(model.playbackErrorID, "recording")
        model.discardRecording()
        XCTAssertNil(model.playbackErrorID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path)); XCTAssertFalse(model.isPlaying)
    }

    func test过短录音删除临时内容并提供恢复提示() async throws {
        let (model, driver, _) = try fixture()
        driver.recordedDuration = 0.1
        await model.startRecording { true }
        let url = try XCTUnwrap(model.recording?.localURL)
        model.stopRecording()
        XCTAssertFalse(model.canSendRecording); XCTAssertNil(model.recording)
        XCTAssertEqual(model.recordingErrorKey, "mobile.chat.voice.too-short")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test系统录制结束与错误仅接受当前录制回调() async throws {
        let (model, driver, _) = try fixture()
        await model.startRecording { true }
        let oldFinish = try XCTUnwrap(driver.recordingFinished)
        model.discardRecording(); await model.startRecording { true }
        oldFinish(false); XCTAssertTrue(model.isRecording)
        driver.recordingFinished?(true); XCTAssertTrue(model.canSendRecording)
        model.discardRecording(); await model.startRecording { true }
        let url = try XCTUnwrap(model.recording?.localURL)
        driver.recordingFinished?(false)
        XCTAssertNil(model.recording); XCTAssertEqual(model.recordingErrorKey, "chat.voice.failed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test录制启动失败会清理文件且可以重试() async throws {
        let (model, driver, root) = try fixture()
        driver.failRecording = true
        await model.startRecording { true }
        XCTAssertFalse(model.isRecording); XCTAssertNil(model.recording)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 0)
        driver.failRecording = false; await model.startRecording { true }; XCTAssertTrue(model.isRecording)
    }

    func test来电或后台停止录制保留草稿且不会自动恢复() async throws {
        let (model, driver, _) = try fixture()
        await model.startRecording { true }; model.interrupt()
        XCTAssertFalse(model.isRecording); XCTAssertTrue(model.canSendRecording)
        XCTAssertEqual(driver.recordCalls, 1)
        model.previewRecording(); model.interrupt()
        XCTAssertFalse(model.isPlaying); XCTAssertTrue(model.canSendRecording)
        XCTAssertEqual(driver.resumeCalls, 0)
    }

    func test发送移交后离页清理不会删除正在复制的录音() async throws {
        let (model, _, _) = try fixture()
        await model.startRecording { true }; model.stopRecording()
        let (selection, duration) = try XCTUnwrap(model.takeRecording())
        model.reset()
        XCTAssertTrue(FileManager.default.fileExists(atPath: selection.localURL.path))
        model.restoreRecording(selection, duration: duration)
        XCTAssertTrue(model.canSendRecording)
        model.discardRecording(); XCTAssertFalse(FileManager.default.fileExists(atPath: selection.localURL.path))
    }

    func test播放切换清理旧下载且迟到结束不停止新播放() async throws {
        let (model, driver, root) = try fixture()
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        model.play(url: first.appendingPathComponent("voice.wav"), directory: first, id: "1")
        let finish = try XCTUnwrap(driver.playbackFinished)
        model.play(url: second.appendingPathComponent("voice.wav"), directory: second, id: "2")
        finish(false)
        XCTAssertTrue(model.isPlaying); XCTAssertEqual(model.playbackID, "2")
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        model.reset(); XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func test播放与恢复失败清理下载并允许重试() async throws {
        let (model, driver, root) = try fixture()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        driver.failPlayback = true
        model.play(url: root.appendingPathComponent("voice.wav"), directory: root, id: "1")
        XCTAssertEqual(model.playbackErrorID, "1"); XCTAssertNil(model.playbackID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        driver.failPlayback = false
        model.play(url: root.appendingPathComponent("voice.wav"), directory: nil, id: "1")
        XCTAssertNil(model.playbackErrorID); XCTAssertTrue(model.isPlaying)
        model.togglePlayback(); driver.failPlayback = true; model.togglePlayback()
        XCTAssertFalse(model.isPlaying); XCTAssertEqual(model.playbackErrorID, "1")
    }

    func test真实附件读取只下载一次并支持暂停和切换账号清理() async throws {
        let transport = MobileChatAudioUITransport(), driver = ChatAudioDriverStub()
        let model = try await chat(transport, driver)
        let message = try XCTUnwrap(model.state.selectedMessages.messages.first), attachment = try XCTUnwrap(message.attachments.first)
        XCTAssertEqual(attachment.kind, .voice)
        model.toggleVoicePlayback(attachment, in: message)
        for _ in 0..<100 { if model.audio.isPlaying { break }; try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(model.audio.isPlaying)
        model.toggleVoicePlayback(attachment, in: message); XCTAssertFalse(model.audio.isPlaying)
        model.toggleVoicePlayback(attachment, in: message); XCTAssertTrue(model.audio.isPlaying)
        let counts = await transport.counts(); XCTAssertEqual(counts.downloads, 1)
        let url = try XCTUnwrap(driver.playedURL)
        await model.activate(profileID: nil, repository: nil)
        XCTAssertFalse(model.audio.isPlaying); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test取消下载后忽略不响应取消的迟到音频并清理文件() async throws {
        let transport = MobileChatAudioUITransport(state: "chat-audio-loading"), driver = ChatAudioDriverStub()
        let model = try await chat(transport, driver)
        let message = try XCTUnwrap(model.state.selectedMessages.messages.first), attachment = try XCTUnwrap(message.attachments.first)
        model.toggleVoicePlayback(attachment, in: message)
        await transport.waitForDownload(); model.interruptChatAudio(); await transport.releaseDownload()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(driver.playCalls, 0); XCTAssertNil(model.state.remoteAttachmentMessageID)
    }

    func test录音发送使用真实附件请求和持久回执且不消费文字草稿() async throws {
        let transport = MobileChatAudioUITransport(), driver = ChatAudioDriverStub()
        let model = try await chat(transport, driver)
        model.setDraft("Separate text")
        await model.startVoiceRecording(); model.audio.stopRecording()
        let url = try XCTUnwrap(model.audio.recording?.localURL)
        await model.sendVoiceRecording()
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 1)
        XCTAssertEqual(model.sending?.entries.first?.phase, .complete)
        XCTAssertEqual(model.state.selectedDraft, "Separate text")
        XCTAssertNil(model.audio.recording); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test录音提交未知交给原发送记录且不能从录音入口重复提交() async throws {
        let transport = MobileChatAudioUITransport(state: "chat-audio-send-unknown"), driver = ChatAudioDriverStub()
        let model = try await chat(transport, driver)
        await model.startVoiceRecording(); model.audio.stopRecording(); await model.sendVoiceRecording()
        XCTAssertEqual(model.sending?.entries.first?.phase, .submitted)
        XCTAssertEqual(model.sending?.entries.first?.payload?.attachment?.kind, .voice)
        XCTAssertNil(model.audio.recording)
        await model.sendVoiceRecording()
        let counts = await transport.counts(); XCTAssertEqual(counts.writes, 1)
    }

    func test音频附件必须通过语音能力且不借文件能力发送() {
        XCTAssertEqual(MobileChatAttachmentSelection.kind(contentType: .mpeg4Audio, fileName: "voice.aac"), .voice)
        XCTAssertEqual(MobileChatAttachmentSelection.requiredFeature(for: .voice), .voiceMessage)
    }

    func test布局旧详情退出不能清空新详情或停止新页面录音() async throws {
        let driver = ChatAudioDriverStub(), model = try await chat(MobileChatAudioUITransport(), driver)
        let oldOwner = UUID(), newOwner = UUID()
        model.enterConversation("27", ownerID: oldOwner)
        model.enterConversation("27", ownerID: newOwner)
        await model.startVoiceRecording()
        model.leaveConversation("27", ownerID: oldOwner)
        XCTAssertEqual(model.state.visibleConversationID, "27"); XCTAssertTrue(model.audio.isRecording)
        model.leaveConversation("27", ownerID: newOwner)
        XCTAssertNil(model.state.visibleConversationID); XCTAssertFalse(model.audio.isRecording)
    }

    func test录音表单展示中重排保留录音而账号退出仍清理() async throws {
        let driver = ChatAudioDriverStub(), model = try await chat(MobileChatAudioUITransport(), driver)
        let owner = UUID()
        model.enterConversation("27", ownerID: owner)
        await model.startVoiceRecording()
        let url = try XCTUnwrap(model.audio.recording?.localURL)
        model.leaveConversation("27", ownerID: owner, preservingVoiceRecording: true)
        XCTAssertTrue(model.audio.isRecording); XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        model.deactivate()
        XCTAssertFalse(model.audio.isRecording); XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func test合成录制生成可由系统解码的AAC且未请求真实麦克风() async throws {
        let root = try root(), driver = MobileChatAudioUIDriver(), model = MobileChatAudioModel(driver: driver, root: root)
        defer { model.reset() }
        await model.startRecording { true }; model.stopRecording()
        let url = try XCTUnwrap(model.recording?.localURL), file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.settings[AVFormatIDKey] as? UInt32, kAudioFormatMPEG4AAC)
        let player = try AVAudioPlayer(contentsOf: url)
        XCTAssertGreaterThan(player.duration, 9); XCTAssertLessThan(player.duration, 11)
        XCTAssertTrue(player.prepareToPlay())
    }

    func test录音文件声明完整系统保护级别() async throws {
        let (model, _, root) = try fixture()
        await model.startRecording { true }; model.stopRecording()
        #if targetEnvironment(simulator)
        let reference = root.appendingPathComponent("protection-reference")
        try Data([0]).write(to: reference, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: reference.path)
        if try FileManager.default.attributesOfItem(atPath: reference.path)[.protectionKey] == nil {
            throw XCTSkip("PENDING_USER_VALIDATION：独立系统写入未返回保护级别，需在 iPhone/iPad 真机验证录音锁屏保护，不能计作通过。")
        }
        #endif
        let url = try XCTUnwrap(model.recording?.localURL)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? String, FileProtectionType.complete.rawValue)
    }

    func test开始录音取消正在加载的语音且迟到下载不能中断录制() async throws {
        let transport = MobileChatAudioUITransport(state: "chat-audio-loading"), driver = ChatAudioDriverStub()
        let model = try await chat(transport, driver)
        let message = try XCTUnwrap(model.state.selectedMessages.messages.first), attachment = try XCTUnwrap(message.attachments.first)
        model.toggleVoicePlayback(attachment, in: message)
        await transport.waitForDownload()
        await model.startVoiceRecording(); await transport.releaseDownload()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.audio.isRecording); XCTAssertEqual(driver.playCalls, 0)
        XCTAssertNil(model.state.remoteAttachmentMessageID)
    }

    func test录音期间不接受其他播放并清理迟到文件() async throws {
        let (model, driver, root) = try fixture()
        await model.startRecording { true }
        let directory = root.appendingPathComponent("late")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        model.play(url: directory.appendingPathComponent("late.wav"), directory: directory, id: "late")
        XCTAssertTrue(model.isRecording); XCTAssertEqual(driver.playCalls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    private func fixture() throws -> (MobileChatAudioModel, ChatAudioDriverStub, URL) {
        let root = try root(), driver = ChatAudioDriverStub(), model = MobileChatAudioModel(driver: driver, root: root.appendingPathComponent("Audio"))
        addTeardownBlock { @MainActor in model.reset() }
        return (model, driver, root.appendingPathComponent("Audio"))
    }

    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }

    private func chat(_ transport: MobileChatAudioUITransport, _ driver: ChatAudioDriverStub) async throws -> MobileChatModel {
        let root = try root(), profile = try NasProfile(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "fixture")
        let versions = [DsmAPIName.chatChannel: 2, DsmAPIName.chatUser: 1, DsmAPIName.chatPost: 8, DsmAPIName.chatPostFile: 2]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version, verified: false))
        }))
        let repository = try DsmChatRepository(profile: profile, capabilities: capabilities,
            session: .init(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        let model = MobileChatModel(attachmentRootURL: root.appendingPathComponent("Attachments"), interactionRecoveryRoot: root, audioDriver: driver)
        await model.activate(profileID: profile.id, repository: repository)
        await model.selectConversation(try XCTUnwrap(model.state.conversations.first { $0.id == "27" }))
        addTeardownBlock { @MainActor in model.deactivate() }; return model
    }
}

@MainActor
private final class ChatAudioDriverStub: MobileChatAudioDriving {
    var recordedDuration: TimeInterval = 2
    var permissionGranted = true, delaysPermission = false, failRecording = false, failPlayback = false
    var permissionRequests = 0, recordCalls = 0, playCalls = 0, pauseCalls = 0, resumeCalls = 0
    var limit: TimeInterval?
    var playedURL: URL?
    var permissionContinuation: CheckedContinuation<Bool, Never>?
    var recordingFinished: (@MainActor (Bool) -> Void)?
    var playbackFinished: (@MainActor (Bool) -> Void)?
    func requestRecordPermission() async -> Bool {
        permissionRequests += 1
        if delaysPermission { return await withCheckedContinuation { permissionContinuation = $0 } }
        return permissionGranted
    }
    func record(to url: URL, limit: TimeInterval, finished: @escaping @MainActor (Bool) -> Void) throws {
        recordCalls += 1; self.limit = limit
        if failRecording { throw URLError(.unknown) }
        try Data("synthetic audio".utf8).write(to: url); recordingFinished = finished
    }
    func stopRecording() {}
    func play(_ url: URL, finished: @escaping @MainActor (Bool) -> Void) throws {
        playCalls += 1; playedURL = url
        if failPlayback { throw URLError(.unknown) }
        playbackFinished = finished
    }
    func pause() { pauseCalls += 1 }
    func resume() throws { resumeCalls += 1; if failPlayback { throw URLError(.unknown) } }
    func stopPlayback() {}
}
