import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatSendRecordsSheet: View {
    @Bindable var sending: MobileChatSendModel
    let conversations: [ChatConversation]
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if sending.recovery.failed {
                    ContentUnavailableView(L10n.string("mobile.chat.send.records"), systemImage: "exclamationmark.triangle",
                        description: Text(L10n.string("mobile.chat.interaction.storage-error"))).fillsAvailableContentArea()
                } else if sending.entries.isEmpty {
                    ContentUnavailableView(L10n.string("mobile.chat.send.empty"), systemImage: "paperplane",
                        description: Text(L10n.string("mobile.chat.send.empty.message"))).fillsAvailableContentArea()
                } else {
                    List(sending.entries.reversed()) { entry in
                        NavigationLink {
                            MobileChatSendResultView(sending: sending, id: entry.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(conversations.first { $0.id == entry.conversationID }?.title ?? L10n.string("mobile.chat.send.conversation-unavailable"))
                                    .font(.headline)
                                Text(L10n.string(kind(entry.kind)))
                                Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                                Text(L10n.string(status(entry))).font(.subheadline).foregroundStyle(.secondary)
                            }.frame(minHeight: 44).accessibilityElement(children: .combine)
                        }.accessibilityIdentifier("chat-send-record-\(entry.id)")
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.chat.send.records"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("files.common.close")) { dismiss() } } }
        }
    }
}

private struct MobileChatSendResultView: View {
    @Bindable var sending: MobileChatSendModel
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Group {
            if let entry = sending.entry(id) {
                List {
                    Section {
                        Text(L10n.string(status(entry))).accessibilityIdentifier("chat-send-status")
                        Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute()).foregroundStyle(.secondary)
                        if let text = entry.payload?.text { Text(text).textSelection(.enabled) }
                        if let attachment = entry.payload?.attachment { Label(attachment.fileName, systemImage: "paperclip") }
                    }
                    if sending.recovery.failed { Text(L10n.string("mobile.chat.interaction.storage-error")).foregroundStyle(.orange) }
                    else if sending.errorConversationID == entry.conversationID, let key = sending.errorKey,
                            !["mobile.chat.send.failed", "mobile.chat.send.pending", status(entry)].contains(key) {
                        Text(L10n.string(key)).foregroundStyle(.orange)
                    }
                    if sending.recovery.isExecuting(id) {
                        ProgressView(L10n.string("mobile.chat.sending"))
                        Button(L10n.string("mobile.chat.send.stop")) { sending.cancel() }.frame(minHeight: 44)
                    } else {
                        if entry.phase == .submitted {
                            Button(L10n.string("mobile.chat.send.refresh")) { Task { await sending.run(id, sendPrepared: false) } }
                                .accessibilityIdentifier("chat-send-refresh").frame(minHeight: 44).disabled(sending.isBusy)
                        }
                        if entry.phase == .prepared {
                            Button(L10n.string("mobile.chat.action.send")) { Task { await sending.run(id, sendPrepared: true) } }
                                .accessibilityIdentifier("chat-send-continue").frame(minHeight: 44).disabled(!sending.canSendPrepared(entry))
                            Button(L10n.string("mobile.chat.send.cancel")) { sending.cancelPrepared(id) }
                                .accessibilityIdentifier("chat-send-cancel").frame(minHeight: 44)
                        }
                        if [.failed, .cancelled].contains(entry.phase) {
                            Button(L10n.string("mobile.chat.send.retry")) { Task { await sending.retry(id); if sending.entry(id) == nil { dismiss() } } }
                                .accessibilityIdentifier("chat-send-retry").frame(minHeight: 44)
                                .disabled(!sending.canSend(conversationID: entry.conversationID, threadID: entry.threadID,
                                    text: entry.payload?.text, attachmentKind: entry.payload?.attachment?.kind))
                        }
                        if !entry.hasUnfinished {
                            Button(L10n.string("mobile.chat.send.remove")) { sending.remove(id); if sending.entry(id) == nil { dismiss() } }
                                .accessibilityIdentifier("chat-send-remove").frame(minHeight: 44)
                        }
                    }
                }.disabled(sending.recovery.failed)
            } else { ContentUnavailableView(L10n.string("mobile.chat.send.empty"), systemImage: "paperplane").fillsAvailableContentArea() }
        }
        .navigationTitle(L10n.string("mobile.chat.send.details"))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func status(_ entry: MobileChatSendStore.Entry) -> String {
    if entry.failure == .attachmentChanged { return "mobile.chat.send.attachment-changed" }
    if entry.failure == .denied { return "mobile.chat.send.denied" }
    switch entry.phase {
    case .prepared: return "mobile.chat.send.status.prepared"
    case .submitted: return "mobile.chat.send.status.submitted"
    case .complete: return "mobile.chat.send.status.complete"
    case .failed: return "mobile.chat.send.status.failed"
    case .cancelled: return "mobile.chat.send.status.cancelled"
    }
}

private func kind(_ value: MobileChatSendStore.Kind) -> String {
    switch value {
    case .text: "mobile.chat.send.kind.text"
    case .reply: "mobile.chat.send.kind.reply"
    case .attachment: "mobile.chat.send.kind.attachment"
    }
}
