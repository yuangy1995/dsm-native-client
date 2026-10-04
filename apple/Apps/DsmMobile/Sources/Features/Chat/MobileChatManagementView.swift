import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatConversationManagementSheet: View {
    @Bindable var chat: MobileChatModel
    @Bindable var management: MobileChatManagementModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []
    @State private var query = ""
    @State private var confirmed: [ChatConversation] = []
    @State private var presentsConfirmation = false
    @State private var submitted: [ChatConversation] = []

    private var values: [ChatConversation] {
        let values = chat.state.conversations + submitted.filter { item in !chat.state.conversations.contains { $0.id == item.id } }
        return query.isEmpty ? values : values.filter { $0.title.localizedStandardContains(query) }
    }
    private var selected: [ChatConversation] { chat.state.conversations.filter { selection.contains($0.id) } }
    var body: some View {
        NavigationStack {
            List {
                if management.isMutating { ProgressView(L10n.string("mobile.chat.close.progress")) }
                if chat.state.isRefreshingConversations { ProgressView(L10n.string("mobile.chat.loading.conversations")) }
                if chat.state.conversationErrorCategory != nil { Text(L10n.string("mobile.chat.error.message")).foregroundStyle(.orange) }
                if management.recovery.failed { Text(L10n.string("mobile.chat.interaction.storage-error")).foregroundStyle(.orange) }
                if values.isEmpty {
                    ContentUnavailableView(L10n.string(query.isEmpty ? "mobile.chat.empty.title" : "mobile.chat.search.empty.title"),
                        systemImage: "bubble.left.and.bubble.right", description: Text(L10n.string(query.isEmpty ? "mobile.chat.empty.message" : "mobile.chat.search.empty.message")))
                }
                ForEach(values) { conversation in
                    if management.closeResults[conversation.id] == .closed {
                        rowLabel(conversation)
                    } else {
                        Button {
                            if selection.contains(conversation.id) { selection.remove(conversation.id) } else { selection.insert(conversation.id) }
                        } label: { rowLabel(conversation) }
                        .buttonStyle(.plain)
                        .disabled(!management.canClose(conversation))
                        .accessibilityIdentifier("chat-close-select-\(conversation.id)")
                        .accessibilityAddTraits(selection.contains(conversation.id) ? .isSelected : [])
                    }
                }
            }
            .navigationTitle(L10n.string("mobile.chat.close.manage"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: L10n.string("mobile.chat.search.placeholder"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button { Task { await management.recover(); await chat.reloadConversations() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }.disabled(management.isBusy).accessibilityLabel(L10n.string("mobile.chat.action.retry"))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button(role: .destructive) {
                    confirmed = selected; presentsConfirmation = true
                } label: {
                    Text(L10n.string("mobile.chat.close.action")).frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || !selected.allSatisfy { management.canClose($0) })
                .padding().background(.bar)
                .accessibilityIdentifier("chat-close-submit")
            }
            .alert(L10n.string("mobile.chat.close.confirm.title"), isPresented: $presentsConfirmation) {
                Button(L10n.string("mobile.chat.close.action"), role: .destructive) {
                    let originals = confirmed; submitted = originals; selection = []
                    Task { await management.close(originals) }
                }
                Button(L10n.string("mobile.chat.message.delete.confirm.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.string("mobile.chat.close.confirm.message", confirmed.map(\.title).joined(separator: "\n")))
            }
        }
        .task { await management.recover() }
        .interactiveDismissDisabled(management.isMutating)
    }
    private func rowLabel(_ conversation: ChatConversation) -> some View {
        HStack(spacing: 12) {
            Image(systemName: management.closeResults[conversation.id] == .closed ? "checkmark.circle" : (selection.contains(conversation.id) ? "checkmark.circle.fill" : "circle"))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text(conversation.title).foregroundStyle(.primary)
                if let result = management.closeResults[conversation.id] {
                    Text(L10n.string(resultKey(result))).font(.footnote).foregroundStyle(.secondary)
                } else if let pending = management.pending.first(where: { $0.conversationID == conversation.id }) {
                    Text(L10n.string(MobileChatManagementModel.pendingKey(pending.kind))).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
    }
    private func resultKey(_ result: MobileChatManagementModel.CloseResult) -> String {
        switch result {
        case .closed: "mobile.chat.close.done"
        case .failed: "mobile.chat.management.failed"
        case .pending: "mobile.chat.close.pending"
        }
    }
}
