import AVFoundation
import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatVoiceSheet: View {
    @Bindable var chat: MobileChatModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var isSending = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent(L10n.string("chat.voice.duration")) {
                        Text(Duration.seconds(chat.audio.duration), format: .time(pattern: .minuteSecond))
                            .monospacedDigit().accessibilityIdentifier("chat-voice-duration")
                    }
                    if chat.audio.isRecording {
                        action("chat.voice.stop", image: "stop.circle", id: "chat-voice-stop") { chat.audio.stopRecording() }
                    } else if chat.audio.isRequestingPermission {
                        ProgressView().accessibilityLabel(L10n.string("chat.voice.start"))
                    } else if chat.audio.canSendRecording {
                        action(chat.audio.isPlaying ? "chat.media.pause" : "chat.voice.preview", image: chat.audio.isPlaying ? "pause.circle" : "play.circle", id: "chat-voice-preview") {
                            chat.audio.previewRecording()
                        }
                        action("chat.voice.discard", image: "trash", id: "chat-voice-discard") { chat.audio.discardRecording() }
                    } else {
                        action("chat.voice.start", image: "mic.circle", id: "chat-voice-start") { Task { await chat.startVoiceRecording() } }
                            .disabled(!chat.canRecordVoice)
                    }
                } footer: { Text(L10n.string("chat.voice.limit")) }
                if let key = chat.audio.recordingErrorKey {
                    Section {
                        Text(L10n.string(key))
                        if key == "mobile.chat.voice.permission" {
                            Button(L10n.string("mobile.chat.voice.settings")) {
                                if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                            }.frame(minHeight: 44)
                        }
                    }
                }
                if chat.audio.playbackErrorID == "recording" { Text(L10n.string("mobile.chat.voice.preview-failed")) }
                if let sending = chat.sending, let key = sending.errorKey { Text(L10n.string(key)) }
                Section {
                    Button {
                        isSending = true
                        Task {
                            await chat.sendVoiceRecording()
                            isSending = false
                            if chat.audio.recording == nil { dismiss() }
                        }
                    } label: {
                        if isSending { ProgressView() }
                        else { Label(L10n.string("chat.voice.send"), systemImage: "paperplane") }
                    }
                    .frame(minHeight: 44)
                    .disabled(isSending || !chat.canRecordVoice || !chat.audio.canSendRecording)
                    .accessibilityIdentifier("chat-voice-send")
                }
            }
            .disabled(isSending)
            .navigationTitle(L10n.string("chat.voice.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minHeight: 44).disabled(isSending)
                }
            }
        }
        .interactiveDismissDisabled(isSending)
        .onChange(of: chat.activeProfileID) { _, _ in dismiss() }
        .onChange(of: chat.state.selectedConversationID) { _, _ in dismiss() }
        .onDisappear { chat.audio.reset() }
    }

    private func action(_ key: String, image: String, id: String, perform: @escaping () -> Void) -> some View {
        Button(action: perform) { Label(L10n.string(key), systemImage: image) }
            .frame(minHeight: 44).accessibilityIdentifier(id)
    }
}

struct MobileChatVoicePlaybackButton: View {
    @Bindable var chat: MobileChatModel
    let message: ChatMessage
    let attachment: ChatAttachment
    private var isCurrent: Bool { chat.audio.playbackID == message.id }
    private var loading: Bool { chat.state.remoteAttachmentMessageID == message.id }
    private var validSize: Bool { attachment.sizeBytes.map { $0 > 0 && $0 <= MobileChatAudioModel.maximumPlaybackBytes } == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { chat.toggleVoicePlayback(attachment, in: message) } label: {
                Label(L10n.string(loading ? "chat.media.loading" : isCurrent && chat.audio.isPlaying ? "chat.media.pause" : "chat.media.play"),
                    systemImage: loading ? "hourglass" : isCurrent && chat.audio.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered).frame(minHeight: 44)
            .disabled(!validSize || loading || chat.audio.isRecording || chat.audio.isRequestingPermission || (!isCurrent && !chat.canOpenRemoteAttachment(attachment, in: message)))
            .accessibilityIdentifier("chat-voice-play-\(message.id)")
            if chat.audio.playbackErrorID == message.id {
                Label(L10n.string("chat.media.failed"), systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !validSize || chat.audio.playbackErrorID == message.id {
                Text(L10n.string("chat.media.recovery")).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct MobileChatAudioLifecycle: ViewModifier {
    let chat: MobileChatModel
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .onChange(of: chat.state.availability.supportedFeatures) { _, features in
                if !features.contains(.voiceMessage) { chat.audio.discardRecording() }
                if !features.contains(.attachmentDownload) { chat.interruptChatAudio(); chat.audio.stopPlayback() }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .background { chat.interruptChatAudio() }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) { notification in
                if notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt == AVAudioSession.InterruptionType.began.rawValue {
                    chat.interruptChatAudio()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)) { notification in
                if notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                    chat.interruptChatAudio()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification)) { _ in
                chat.interruptChatAudio()
                chat.audio.stopPlayback()
            }
    }
}

extension View {
    func mobileChatAudioLifecycle(chat: MobileChatModel) -> some View { modifier(MobileChatAudioLifecycle(chat: chat)) }
}
