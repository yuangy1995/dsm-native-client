import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatSearchSheet: View {
    @Bindable var chat: MobileChatModel
    @Bindable var interaction: MobileChatInteractionModel
    let conversationID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var searchesAll = false

    private var scope: String? { searchesAll ? nil : conversationID }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if conversationID != nil {
                    Picker(L10n.string("chat.search.scope"), selection: $searchesAll) {
                        Text(L10n.string("chat.search.current")).tag(false)
                        Text(L10n.string("chat.search.all")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding()
                    .onChange(of: searchesAll) { _, _ in Task { await runSearch() } }
                }
                searchContent
            }
            .searchable(text: $query, prompt: L10n.string("chat.search.placeholder"))
            .onSubmit(of: .search) { Task { await runSearch() } }
            .navigationTitle(L10n.string("chat.search.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }
                        .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.string("chat.search.action")) { Task { await runSearch() } }
                        .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || interaction.isSearching)
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("chat-search-submit")
                }
            }
            .navigationDestination(for: ChatMessage.self) { message in
                MobileChatDiscussionView(chat: chat, interaction: interaction, message: message)
            }
            .task { await interaction.search("", conversationID: scope) }
        }
    }

    @ViewBuilder
    private var searchContent: some View {
        if interaction.isSearching && interaction.searchMessages.isEmpty {
            ProgressView(L10n.string("chat.search.loading")).fillsAvailableContentArea()
        } else if interaction.searchError && interaction.searchMessages.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("chat.search.failed"), systemImage: "magnifyingglass")
            } description: { Text(L10n.string("chat.search.recovery")) }
            actions: { Button(L10n.string("mobile.chat.action.retry")) { Task { await runSearch() } } }
                .fillsAvailableContentArea()
        } else if interaction.searchMessages.isEmpty {
            ContentUnavailableView(interaction.hasSearched ? L10n.string("chat.search.empty") : L10n.string("chat.search.title"),
                systemImage: "magnifyingglass", description: Text(L10n.string(interaction.hasSearched ? "chat.search.tryOther" : "chat.search.placeholder")))
                .fillsAvailableContentArea()
        } else {
            List {
                ForEach(interaction.searchMessages) { message in
                    NavigationLink(value: message) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(chat.state.conversations.first { $0.id == message.conversationID }?.title ?? L10n.string("chat.search.conversation"))
                                .font(.caption).foregroundStyle(.secondary)
                            Text(message.senderDisplayName ?? L10n.string("mobile.chat.sender.unknown")).font(.subheadline.weight(.semibold))
                            Text(message.text ?? L10n.string("mobile.chat.interaction.attachment")).lineLimit(5)
                            Text(message.sentAt, format: .dateTime.year().month().day().hour().minute()).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("chat-search-result-\(message.id)")
                }
                if interaction.isSearching { ProgressView(L10n.string("chat.search.loading")) }
                else if interaction.searchCursor != nil {
                    Button(L10n.string(interaction.searchError ? "mobile.chat.action.retry" : "chat.search.more")) {
                        Task { await interaction.search(interaction.searchQuery, conversationID: interaction.searchConversationID, more: true) }
                    }
                    .frame(minHeight: 44)
                }
            }
            .listStyle(.plain)
        }
    }

    private func runSearch() async { await interaction.search(query, conversationID: scope) }
}

struct MobileChatDiscussionView: View {
    @Bindable var chat: MobileChatModel
    @Bindable var interaction: MobileChatInteractionModel
    let message: ChatMessage
    @State private var presentsSendRecords = false
    @State private var reply = ""

    var body: some View {
        Group {
            if interaction.isLoadingThread && interaction.root == nil {
                ProgressView(L10n.string("mobile.chat.loading.messages")).fillsAvailableContentArea()
            } else if interaction.missingMessage {
                ContentUnavailableView(L10n.string("mobile.chat.interaction.missing"), systemImage: "bubble.left",
                    description: Text(L10n.string("mobile.chat.interaction.missing-help"))).fillsAvailableContentArea()
            } else if interaction.root == nil {
                ContentUnavailableView {
                    Label(L10n.string("chat.thread.failed"), systemImage: "exclamationmark.bubble")
                } description: { Text(L10n.string("chat.thread.recovery")) }
                actions: { Button(L10n.string("mobile.chat.action.retry")) { Task { await interaction.open(message) } } }
                    .fillsAvailableContentArea()
            } else {
                threadContent
            }
        }
        .navigationTitle(L10n.string("chat.thread.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await interaction.open(message) } } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                }
                .accessibilityLabel(L10n.string("mobile.chat.action.refresh-messages"))
                .disabled(interaction.isLoadingThread || interaction.isMutating)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if interaction.root != nil, interaction.availability.supportedFeatures.contains(.threadedReplies) {
                replyComposer
            }
        }
        .task(id: message.id) { await interaction.open(message) }
        .onDisappear {
            interaction.closeDiscussion()
            chat.cancelRemoteAttachmentDownload()
            chat.dismissRemoteAttachmentPresentation()
        }
        .mobileChatRemoteAttachmentPresentation(chat: chat)
        .sheet(isPresented: $presentsSendRecords) {
            MobileChatSendRecordsSheet(sending: interaction.sending, conversations: chat.state.conversations)
        }
    }

    private var threadContent: some View {
        List {
            if let root = interaction.root {
                MobileChatMessageRow(chat: chat, message: root, allowsThreadNavigation: false)
            }
            if let focused = interaction.focusedMessage, focused.id != interaction.root?.id,
               !interaction.replies.messages.contains(where: { $0.id == focused.id }) {
                Section(L10n.string("mobile.chat.interaction.selected-message")) {
                    MobileChatMessageRow(chat: chat, message: focused, allowsThreadNavigation: false)
                }
            }
            Section(L10n.string("chat.thread.title")) {
                if interaction.replies.hasMoreBefore {
                    Button(L10n.string("chat.thread.earlier")) { Task { await interaction.loadReplies(more: true) } }
                        .disabled(interaction.isLoadingThread).frame(minHeight: 44)
                }
                ForEach(interaction.replies.messages) { reply in
                    MobileChatMessageRow(chat: chat, message: reply, allowsThreadNavigation: false)
                        .background(alignment: .bottom) {
                            if reply.id == interaction.replies.messages.last?.id {
                                MobileChatReadVisibility(identity: reply.id) { visible in
                                    interaction.synchronizeVisibleReply(reply.id, isVisible: visible)
                                }.frame(height: 2)
                            }
                        }
                }
                if interaction.isLoadingThread { ProgressView(L10n.string("mobile.chat.loading.messages")) }
                else if interaction.threadError {
                    Text(L10n.string("chat.thread.recovery")).foregroundStyle(.secondary)
                    Button(L10n.string("mobile.chat.action.retry")) { Task { await interaction.loadReplies(more: interaction.replies.hasMoreBefore) } }
                } else if interaction.replies.messages.isEmpty {
                    Text(L10n.string("chat.thread.empty")).foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await interaction.open(message) }
    }

    private var replyComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if interaction.sending.recovery.failed {
                Text(L10n.string("mobile.chat.interaction.storage-error")).foregroundStyle(.orange)
            } else if let error = interaction.mutationErrorKey {
                Text(L10n.string(error)).foregroundStyle(.orange)
            } else if interaction.sending.entries.contains(where: { $0.hasUnfinished && $0.kind == .reply && $0.conversationID == interaction.root?.conversationID && $0.threadID == interaction.root?.id }) {
                Text(L10n.string("mobile.chat.send.pending")).foregroundStyle(.secondary)
            }
            if interaction.sending.entries.contains(where: { $0.hasUnfinished && $0.threadID == interaction.root?.id
                && $0.conversationID == interaction.root?.conversationID }) {
                Button(L10n.string("mobile.chat.send.records")) { presentsSendRecords = true }.frame(minHeight: 44)
                    .accessibilityIdentifier("chat-thread-send-records")
            }
            HStack(alignment: .bottom) {
                TextField(L10n.string("chat.thread.placeholder"), text: $reply, axis: .vertical)
                    .lineLimit(1...6).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("chat-reply-text")
                Button {
                    let submittedText = reply
                    Task { if await interaction.sendReply(submittedText), reply == submittedText { reply = "" } }
                } label: {
                    if interaction.isMutating { ProgressView().frame(width: 44, height: 44) }
                    else { Image(systemName: "arrow.up.circle.fill").frame(width: 44, height: 44) }
                }
                .accessibilityLabel(L10n.string("chat.thread.send"))
                .accessibilityIdentifier("chat-reply-send")
                .disabled(!interaction.canSendReply(reply))
            }
        }
        .font(.footnote)
        .padding().background(.bar)
    }
}

struct MobileChatEditSheet: View {
    @Bindable var interaction: MobileChatInteractionModel
    let original: ChatMessage
    @Environment(\.dismiss) private var dismiss
    @State private var text: String

    init(interaction: MobileChatInteractionModel, original: ChatMessage) {
        self.interaction = interaction; self.original = original
        _text = State(initialValue: original.text ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L10n.string("chat.edit.text")) {
                    TextField(L10n.string("chat.edit.text"), text: $text, axis: .vertical)
                        .lineLimit(4...16).accessibilityIdentifier("chat-edit-text")
                }
                if interaction.recovery.failed { Text(L10n.string("mobile.chat.interaction.storage-error")).foregroundStyle(.orange) }
                else if let error = interaction.mutationErrorKey { Text(L10n.string(error)).foregroundStyle(.orange) }
                if interaction.pending.contains(where: { $0.kind == .edit && $0.conversationID == original.conversationID && $0.messageID == original.id }) {
                    Button(L10n.string("mobile.chat.action.refresh-messages")) {
                        Task {
                            await interaction.recoverEdits()
                            if !interaction.recovery.failed,
                               !interaction.pending.contains(where: { $0.kind == .edit && $0.conversationID == original.conversationID && $0.messageID == original.id }) { dismiss() }
                        }
                    }.disabled(interaction.isRecovering || interaction.isMutating)
                }
            }
            .navigationTitle(L10n.string("chat.edit.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("files.common.close")) { dismiss() }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("chat.edit.save")) {
                        Task { if await interaction.edit(original, text: text) { dismiss() } }
                    }
                    .disabled(!interaction.canEdit(original) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text == original.text)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("chat-edit-save")
                }
            }
            .interactiveDismissDisabled(interaction.isMutating)
        }
    }
}
