import AppKit
import AVFoundation
import AVKit
import DsmCore
import DsmLocalization
import Observation
import SwiftUI

@MainActor
@Observable
final class ChatVoiceRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var isRequestingAccess = false
    private(set) var fileURL: URL?
    private(set) var duration: TimeInterval = 0
    private(set) var errorMessage: String?
    @ObservationIgnored private var recorder: AVAudioRecorder?
    @ObservationIgnored private var clockTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LanStashChatVoice-\(UUID().uuidString)", isDirectory: true)

    func start() async {
        guard !isRecording, !isRequestingAccess else { return }
        discard()
        let request = generation
        isRequestingAccess = true
        defer { isRequestingAccess = false }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard request == generation else { return }
        guard allowed else { errorMessage = L10n.string("chat.voice.permission"); return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let file = directory.appendingPathComponent("voice.aac")
            let recording = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000
            ])
            recording.delegate = self
            guard recording.prepareToRecord(), recording.record(forDuration: 300) else {
                throw CocoaError(.fileWriteUnknown)
            }
            recorder = recording
            fileURL = file
            isRecording = true
            clockTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(250))
                    guard let self, self.isRecording else { return }
                    self.duration = self.recorder?.currentTime ?? self.duration
                }
            }
        } catch {
            discard()
            errorMessage = L10n.string("chat.voice.failed")
        }
    }

    func stop() {
        duration = recorder?.currentTime ?? duration
        recorder?.stop()
        recorder = nil
        isRecording = false
        clockTask?.cancel()
        clockTask = nil
    }

    func discard() {
        generation = UUID()
        stop()
        fileURL = nil
        duration = 0
        errorMessage = nil
        try? FileManager.default.removeItem(at: directory)
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.isRecording else { return }
            self.stop()
            if !flag { self.discard(); self.errorMessage = L10n.string("chat.voice.failed") }
        }
    }

    deinit {
        clockTask?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

struct ChatVoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatWorkspaceModel
    let conversation: ChatConversation
    @State private var recorder = ChatVoiceRecorder()
    @State private var player: AVPlayer?
    @State private var error: String?
    @State private var isSending = false

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text(L10n.string("chat.voice.title")).font(.headline)
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            Text(conversation.title).foregroundStyle(.secondary)
            Image(systemName: recorder.isRecording ? "waveform" : "mic.fill")
                .font(.system(size: 44)).foregroundStyle(.tint).accessibilityHidden(true)
            Text(Duration.seconds(recorder.duration).formatted(.time(pattern: .minuteSecond)))
                .font(.title2.monospacedDigit())
                .accessibilityLabel(L10n.string("chat.voice.duration"))
            if let message = recorder.errorMessage ?? error {
                Text(message).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if recorder.isRecording {
                Text(L10n.string("chat.voice.limit")).font(.caption).foregroundStyle(.secondary)
                Button(L10n.string("chat.voice.stop"), systemImage: "stop.fill") { recorder.stop() }
            } else if let file = recorder.fileURL {
                HStack {
                    Button(L10n.string("chat.voice.preview"), systemImage: "play.fill") {
                        player?.pause()
                        player = AVPlayer(url: file)
                        player?.play()
                    }
                    Button(L10n.string("chat.voice.discard"), systemImage: "trash") {
                        player?.pause(); player = nil; recorder.discard()
                    }
                    Spacer()
                    Button(L10n.string("chat.voice.send"), systemImage: "paperplane.fill") {
                        isSending = true
                        player?.pause()
                        Task {
                            guard model.canRecordVoice, model.selectedConversationID == conversation.id,
                                  !model.isPerformingAction else {
                                error = L10n.string("chat.feature.unavailable"); isSending = false; return
                            }
                            do {
                                let staged = try model.stageVoiceRecording(file)
                                // 交给现有发送状态保存；关闭录音窗口不会删除待恢复附件。
                                _ = await model.send(text: nil, attachmentURLs: [staged], conversationID: conversation.id)
                                dismiss()
                            } catch {
                                self.error = L10n.string("chat.voice.failed")
                                isSending = false
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(recorder.duration < 0.5 || !model.canRecordVoice || model.selectedConversationID != conversation.id)
                }
                .disabled(isSending || model.isPerformingAction)
            } else {
                Button(L10n.string("chat.voice.start"), systemImage: "record.circle") {
                    Task { await recorder.start() }
                }
                .disabled(recorder.isRequestingAccess)
                if recorder.isRequestingAccess { ProgressView() }
            }
        }
        .padding(24).frame(width: 480, alignment: .topLeading)
        .onDisappear { player?.pause(); player = nil; recorder.discard() }
    }
}

struct ChatMediaSelection: Identifiable {
    let message: ChatMessage
    let attachment: ChatAttachment
    var id: String { message.id + ":" + attachment.id }
}

struct ChatMediaSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: ChatWorkspaceModel
    let selection: ChatMediaSelection
    @State private var player: AVPlayer?
    @State private var localFile: URL?
    @State private var error: String?
    @State private var attempt = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selection.attachment.fileName).font(.headline).lineLimit(2)
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(16)
            Divider()
            if let player {
                VideoPlayer(player: player)
                    .accessibilityLabel(L10n.string("chat.media.player"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                ContentUnavailableView {
                    Label(L10n.string("chat.media.failed"), systemImage: "play.slash")
                } description: { Text(error) } actions: {
                    Button(L10n.string("ui.b8784c8dd5636ff2")) { attempt += 1 }
                }.fillsAvailableContentArea()
            } else {
                VStack {
                    ProgressView(value: model.attachmentDownloadProgress(for: selection.message.id))
                    Text(L10n.string("chat.media.loading"))
                }.padding(30).fillsAvailableContentArea()
            }
        }
        .frame(width: 680, height: selection.attachment.kind == .video ? 480 : 260)
        .task(id: attempt) {
            error = nil
            do {
                let file = try await model.prepareMedia(message: selection.message, attachment: selection.attachment)
                localFile = file
                let asset = AVURLAsset(url: file)
                guard try await asset.load(.isPlayable) else { throw CocoaError(.fileReadCorruptFile) }
                try Task.checkCancellation()
                player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            } catch is CancellationError {
                cleanUp()
            } catch {
                cleanUp()
                self.error = L10n.string("chat.media.recovery")
            }
        }
        .onDisappear { cleanUp() }
    }

    private func cleanUp() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        if let file = localFile { model.discardTemporaryMedia(file) }
        localFile = nil
    }
}
