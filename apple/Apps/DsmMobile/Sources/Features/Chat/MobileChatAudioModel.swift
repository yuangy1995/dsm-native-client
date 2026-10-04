import DsmCore
import Foundation
import Observation

/// 当前聊天的单一播放器与临时录音；退出账号/会话后不接收迟到的权限或系统回调。
@MainActor
@Observable
final class MobileChatAudioModel {
    static let maximumDuration: TimeInterval = 300
    static let maximumPlaybackBytes: Int64 = 512 * 1_024 * 1_024
    private(set) var recording: MobileChatAttachmentSelection?
    private(set) var isRecording = false
    private(set) var isRequestingPermission = false
    private(set) var duration: TimeInterval = 0
    private(set) var recordingErrorKey: String?
    private(set) var playbackID: String?
    private(set) var isPlaying = false
    private(set) var playbackErrorID: String?
    @ObservationIgnored private let driver: any MobileChatAudioDriving
    @ObservationIgnored private let root: URL
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var playbackGeneration = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var playbackDirectory: URL?

    init(driver: any MobileChatAudioDriving, root: URL) { self.driver = driver; self.root = root }
    var canSendRecording: Bool { recording != nil && !isRecording && !isRequestingPermission && duration >= 0.5 }

    func startRecording(ifAllowed: @escaping @MainActor () -> Bool) async {
        guard !isRecording, !isRequestingPermission, recording == nil, ifAllowed() else { return }
        stopPlayback()
        recordingErrorKey = nil
        generation &+= 1
        let current = generation
        isRequestingPermission = true
        let granted = await driver.requestRecordPermission()
        guard generation == current else { return }
        isRequestingPermission = false
        guard ifAllowed() else { return }
        guard granted else { recordingErrorKey = "mobile.chat.voice.permission"; return }
        let directory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("voice.aac")
        do {
            try MobileTransferRecoveryStore.prepareDirectory(directory)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try Data().write(to: url, options: .completeFileProtection)
            try driver.record(to: url, limit: Self.maximumDuration) { [weak self] success in
                guard let self, self.generation == current, self.isRecording else { return }
                self.stopRecording()
                if !success { self.discardRecording(); self.recordingErrorKey = "chat.voice.failed" }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600, .protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            recording = .init(id: UUID(), localURL: url, directoryURL: directory, fileName: "voice.aac", kind: .voice, byteCount: nil)
            isRecording = true
            duration = 0
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                    guard let self, self.isRecording, self.generation == current else { return }
                    self.duration = min(Self.maximumDuration, self.driver.recordedDuration)
                }
            }
        } catch {
            driver.stopRecording()
            try? FileManager.default.removeItem(at: directory)
            recordingErrorKey = "chat.voice.failed"
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        duration = min(Self.maximumDuration, max(duration, driver.recordedDuration))
        driver.stopRecording()
        isRecording = false
        timer?.cancel(); timer = nil
        if duration < 0.5 { discardRecording(); recordingErrorKey = "mobile.chat.voice.too-short" }
    }

    func discardRecording() {
        generation &+= 1
        isRequestingPermission = false
        if isRecording { driver.stopRecording() }
        isRecording = false
        timer?.cancel(); timer = nil
        if playbackID == "recording" { stopPlayback() }
        if playbackErrorID == "recording" { playbackErrorID = nil }
        if let recording { try? FileManager.default.removeItem(at: recording.directoryURL) }
        recording = nil; duration = 0; recordingErrorKey = nil
    }

    /// 发送复制期间文件交由调用者持有，离页清理不能删掉正在复制的录音。
    func takeRecording() -> (MobileChatAttachmentSelection, TimeInterval)? {
        guard canSendRecording, let recording else { return nil }
        stopPlayback()
        let result = (recording, duration)
        self.recording = nil; duration = 0
        return result
    }

    func restoreRecording(_ selection: MobileChatAttachmentSelection, duration: TimeInterval) {
        recording = selection; self.duration = duration
    }

    func previewRecording() {
        guard canSendRecording, let recording else { return }
        if playbackID == "recording" { togglePlayback(); return }
        play(url: recording.localURL, directory: nil, id: "recording")
    }

    /// 下载目录的所有权在完成回调中移交；切换到另一条语音即删除旧副本。
    func play(url: URL, directory: URL?, id: String) {
        guard !isRecording, !isRequestingPermission else {
            if let directory { try? FileManager.default.removeItem(at: directory) }
            return
        }
        stopPlayback()
        playbackID = id; playbackDirectory = directory; playbackErrorID = nil
        let current = playbackGeneration
        do {
            try driver.play(url) { [weak self] success in
                guard let self, self.playbackGeneration == current else { return }
                self.isPlaying = false
                if !success { self.playbackErrorID = id; self.stopPlayback() }
            }
            isPlaying = true
        } catch { playbackErrorID = id; stopPlayback() }
    }

    func togglePlayback() {
        guard playbackID != nil else { return }
        if isPlaying { driver.pause(); isPlaying = false }
        else {
            do { try driver.resume(); isPlaying = true }
            catch { playbackErrorID = playbackID; stopPlayback() }
        }
    }

    func stopPlayback() {
        playbackGeneration &+= 1
        driver.stopPlayback()
        isPlaying = false; playbackID = nil
        if let playbackDirectory { try? FileManager.default.removeItem(at: playbackDirectory) }
        playbackDirectory = nil
    }

    func interrupt() {
        generation &+= 1
        isRequestingPermission = false
        stopRecording()
        if isPlaying { driver.pause(); isPlaying = false }
    }

    func reset() { discardRecording(); stopPlayback(); playbackErrorID = nil }
}
