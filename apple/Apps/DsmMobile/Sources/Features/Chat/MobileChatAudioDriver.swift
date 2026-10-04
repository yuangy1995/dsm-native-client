import AVFoundation
import Foundation

/// 系统音频边界。测试替身只能生成合成音频，不向现场麦克风请求权限。
@MainActor
protocol MobileChatAudioDriving: AnyObject {
    var recordedDuration: TimeInterval { get }
    func requestRecordPermission() async -> Bool
    func record(to url: URL, limit: TimeInterval, finished: @escaping @MainActor (Bool) -> Void) throws
    func stopRecording()
    func play(_ url: URL, finished: @escaping @MainActor (Bool) -> Void) throws
    func pause()
    func resume() throws
    func stopPlayback()
}

@MainActor
final class MobileSystemChatAudioDriver: NSObject, MobileChatAudioDriving, AVAudioRecorderDelegate, AVAudioPlayerDelegate {
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingFinished: (@MainActor (Bool) -> Void)?
    private var playbackFinished: (@MainActor (Bool) -> Void)?
    var recordedDuration: TimeInterval { recorder?.currentTime ?? 0 }

    func requestRecordPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func record(to url: URL, limit: TimeInterval, finished: @escaping @MainActor (Bool) -> Void) throws {
        stopPlayback()
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
            try session.setActive(true)
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record(forDuration: limit) else { throw AudioError.recording }
            self.recorder = recorder
            recordingFinished = finished
        } catch {
            deactivateSession()
            throw error
        }
    }

    func stopRecording() {
        recordingFinished = nil
        recorder?.delegate = nil
        recorder?.stop()
        recorder = nil
        deactivateSession()
    }

    func play(_ url: URL, finished: @escaping @MainActor (Bool) -> Void) throws {
        stopPlayback()
        do {
            try activatePlayback()
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            guard player.prepareToPlay(), player.play() else { throw AudioError.playback }
            self.player = player
            playbackFinished = finished
        } catch {
            deactivateSession()
            throw error
        }
    }

    func pause() { player?.pause(); deactivateSession() }

    func resume() throws {
        try activatePlayback()
        guard player?.play() == true else { deactivateSession(); throw AudioError.playback }
    }

    func stopPlayback() {
        playbackFinished = nil
        player?.delegate = nil
        player?.stop()
        player = nil
        deactivateSession()
    }

    private func activatePlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    private func deactivateSession() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let identity = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == identity else { return }
            self.recordingFinished?(flag)
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: (any Error)?) {
        audioRecorderDidFinishRecording(recorder, successfully: false)
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, let current = self.player, ObjectIdentifier(current) == identity else { return }
            current.currentTime = 0
            self.deactivateSession()
            self.playbackFinished?(flag)
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        audioPlayerDidFinishPlaying(player, successfully: false)
    }

    private enum AudioError: Error { case recording, playback }
}
