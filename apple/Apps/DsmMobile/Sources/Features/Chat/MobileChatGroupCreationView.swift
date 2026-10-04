import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatGroupCreationProgressView: View {
    @Bindable var creator: MobileChatConversationCreator
    let entry: MobileChatGroupCreationStore.Entry
    let onOutcome: @MainActor (ChatConversationCreateOutcome?) async -> Void
    let onStartAnother: @MainActor () -> Void

    var body: some View {
        List {
            Section(entry.title) {
                step(L10n.string("mobile.chat.group.step.create"), stage: entry.receipt?.create ?? .ready,
                     completed: L10n.string("mobile.chat.group.created"), id: "chat-group-create-status")
                step(L10n.string("mobile.chat.group.step.join"), stage: entry.receipt?.join ?? .ready,
                     completed: L10n.string("mobile.chat.group.joined"), id: "chat-group-join-status")
                step(L10n.string("mobile.chat.group.step.invite"), stage: entry.receipt?.invite ?? .ready,
                     completed: L10n.string("mobile.chat.group.invited"), id: "chat-group-invite-status")
            }
            if let receipt = entry.receipt {
                if receipt.lastError == .permission {
                    Text(L10n.string("mobile.chat.group.permission")).foregroundStyle(.orange)
                } else if receipt.lastError == .authentication {
                    Text(L10n.string("mobile.chat.group.authentication")).foregroundStyle(.orange)
                } else if !receipt.canContinue {
                    Text(L10n.string("mobile.chat.group.pending")).foregroundStyle(.secondary)
                }
                if creator.canContinueGroup {
                    Button(L10n.string("mobile.chat.group.continue")) {
                        Task { await onOutcome(creator.continueGroup()) }
                    }.frame(minHeight: 44).accessibilityIdentifier("chat-group-continue")
                }
            } else {
                Button(L10n.string("mobile.chat.group.cancel")) { creator.cancelPreparedGroup() }
                    .frame(minHeight: 44).accessibilityIdentifier("chat-group-cancel")
            }
            Button(L10n.string("mobile.chat.group.another")) {
                creator.startAnotherConversation(); onStartAnother()
            }.frame(minHeight: 44).accessibilityIdentifier("chat-group-another")
        }
    }

    private func step(_ title: String, stage: ChatGroupCreateReceipt.Stage, completed: String, id: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
            Spacer(minLength: 16)
            Text(status(stage, completed: completed)).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }.accessibilityElement(children: .combine).accessibilityIdentifier(id)
    }

    private func status(_ stage: ChatGroupCreateReceipt.Stage, completed: String) -> String {
        switch stage {
        case .ready: L10n.string("mobile.chat.group.ready")
        case .submitted: L10n.string("mobile.chat.group.interrupted")
        case .completed: completed
        case .rejected: L10n.string("mobile.chat.group.rejected")
        }
    }
}

struct MobileChatGroupCreationRecordsSheet: View {
    @Bindable var creator: MobileChatConversationCreator
    let onSelect: @MainActor () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(creator.groupEntries) { entry in
                Button {
                    creator.selectGroupEntry(entry.id); onSelect(); dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.title).foregroundStyle(.primary)
                        Text(entry.createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("chat-group-record-\(entry.id)")
            }
            .navigationTitle(L10n.string("mobile.chat.group.records"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(L10n.string("files.common.close")) { dismiss() } } }
        }
    }
}
