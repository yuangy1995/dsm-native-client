import DsmCore
import DsmLocalization
import SwiftUI

struct MobileChatView: View {
    @Bindable var model: MobileAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
    }

    private var compactLayout: some View {
        conversationList
            .navigationDestination(for: ChatConversation.self) { conversation in
                MobileChatMessagesView(chat: model.chatModel, conversation: conversation)
                    .navigationTitle(conversation.title)
                    .navigationBarTitleDisplayMode(.inline)
            }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            conversationList
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 380)
            Divider()
            regularMessageDetail
        }
    }

    @ViewBuilder
    private var regularMessageDetail: some View {
        if let conversation = model.chatModel.state.selectedConversation {
            MobileChatMessagesView(chat: model.chatModel, conversation: conversation)
                .navigationTitle(conversation.title)
        } else {
            ContentUnavailableView(
                L10n.string("mobile.chat.select.title"),
                systemImage: "bubble.left.and.bubble.right",
                description: Text(L10n.string("mobile.chat.select.message"))
            )
            .fillsAvailableContentArea()
        }
    }

    @ViewBuilder
    private var conversationList: some View {
        let state = model.chatModel.state
        if state.conversationPageState == .loading {
            MobilePageStateView(
                state: .loading,
                labels: conversationStateLabels,
                retryAction: {}
            ) {
                EmptyView()
            }
        } else {
            switch state.availability.status {
        case .unavailable:
            availabilityView(
                title: L10n.string("mobile.chat.unavailable.title"),
                message: L10n.string("mobile.chat.unavailable.message")
            )
        case .requiresValidation:
            availabilityView(
                title: L10n.string("mobile.chat.validation.title"),
                message: L10n.string("mobile.chat.validation.message")
            )
        case .available:
            MobilePageStateView(
                state: state.conversationPageState,
                labels: conversationStateLabels,
                emptySystemImage: "bubble.left.and.bubble.right",
                retryAction: { Task { await model.chatModel.reloadConversations() } }
            ) {
                List(state.visibleConversations) { conversation in
                    conversationDestination(conversation)
                }
                .listStyle(.plain)
                .refreshable { await model.chatModel.reloadConversations() }
            }
            .searchable(
                text: conversationFilterBinding,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: L10n.string("mobile.chat.search.placeholder")
            )
            .safeAreaInset(edge: .top) {
                Label(
                    L10n.string("mobile.chat.read-only.notice"),
                    systemImage: "eye"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
                .accessibilityElement(children: .combine)
            }
            .overlay(alignment: .top) {
                if state.isRefreshingConversations {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: .capsule)
                        .accessibilityLabel(L10n.string("mobile.chat.loading.conversations"))
                }
            }
            }
        }
    }

    private func availabilityView(title: String, message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "bubble.left.and.exclamationmark.bubble.right")
        } description: {
            Text(message)
        } actions: {
            Button(L10n.string("mobile.chat.action.retry")) {
                Task { await model.chatModel.reloadConversations() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
        }
        .fillsAvailableContentArea()
    }

    @ViewBuilder
    private func conversationDestination(_ conversation: ChatConversation) -> some View {
        if horizontalSizeClass == .regular {
            Button {
                Task { await model.chatModel.selectConversation(conversation) }
            } label: {
                MobileChatConversationRow(
                    conversation: conversation,
                    isSelected: model.chatModel.state.selectedConversationID == conversation.id
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(
                model.chatModel.state.selectedConversationID == conversation.id ? .isSelected : []
            )
        } else {
            NavigationLink(value: conversation) {
                MobileChatConversationRow(conversation: conversation, isSelected: false)
            }
        }
    }

    private var conversationFilterBinding: Binding<String> {
        Binding(
            get: { model.chatModel.state.conversationFilter },
            set: { model.chatModel.setConversationFilter($0) }
        )
    }

    private var conversationStateLabels: MobilePageStateLabels {
        MobilePageStateLabels(
            loading: L10n.string("mobile.chat.loading.conversations"),
            emptyTitle: L10n.string("mobile.chat.empty.title"),
            emptyMessage: L10n.string("mobile.chat.empty.message"),
            filteredEmptyTitle: L10n.string("mobile.chat.search.empty.title"),
            filteredEmptyMessage: L10n.string("mobile.chat.search.empty.message"),
            errorTitle: L10n.string("mobile.chat.error.title"),
            errorMessage: L10n.string("mobile.chat.error.message"),
            retryTitle: L10n.string("mobile.chat.action.retry")
        )
    }
}

private struct MobileChatConversationRow: View {
    let conversation: ChatConversation
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: conversation.kind == .group ? "person.2.circle.fill" : "person.circle.fill")
                .font(.title)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if let date = conversation.lastActivityAt {
                        Text(date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    if conversation.isEncrypted {
                        Image(systemName: "lock.fill")
                            .accessibilityLabel(L10n.string("mobile.chat.encrypted.label"))
                    }
                    Text(conversation.lastMessageSummary ?? L10n.string("mobile.chat.summary.unavailable"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    if conversation.unreadCount > 0 {
                        Text(conversation.unreadCount, format: .number)
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.tint, in: .capsule)
                            .accessibilityLabel(
                                L10n.string("mobile.chat.unread.count", conversation.unreadCount)
                            )
                    }
                }
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(conversationAccessibilityLabel)
    }

    private var conversationAccessibilityLabel: String {
        if conversation.isEncrypted, conversation.unreadCount > 0 {
            return L10n.string(
                "mobile.chat.conversation.accessibility.encrypted-unread",
                conversation.title,
                conversation.unreadCount
            )
        }
        if conversation.isEncrypted {
            return L10n.string(
                "mobile.chat.conversation.accessibility.encrypted",
                conversation.title
            )
        }
        if conversation.unreadCount > 0 {
            return L10n.string(
                "mobile.chat.conversation.accessibility.unread",
                conversation.title,
                conversation.unreadCount
            )
        }
        return L10n.string("mobile.chat.conversation.accessibility", conversation.title)
    }
}

private struct MobileChatMessagesView: View {
    @Bindable var chat: MobileChatModel
    let conversation: ChatConversation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if chat.state.selectedConversationID != conversation.id {
                ProgressView(L10n.string("mobile.chat.loading.messages"))
                    .fillsAvailableContentArea()
                    .accessibilityElement(children: .combine)
            } else if conversation.isEncrypted {
                ContentUnavailableView(
                    L10n.string("mobile.chat.encrypted.title"),
                    systemImage: "lock.fill",
                    description: Text(L10n.string("mobile.chat.encrypted.message"))
                )
                .fillsAvailableContentArea()
            } else {
                messageContent
            }
        }
        .task(id: conversation.id) {
            if chat.state.selectedConversationID != conversation.id {
                await chat.selectConversation(conversation)
            }
        }
        .onDisappear {
            chat.leaveConversation(conversation.id)
        }
        .safeAreaInset(edge: .top) {
            if horizontalSizeClass != .regular,
               !chat.canComposeMessage {
                Label(
                    L10n.string("mobile.chat.read-only.notice"),
                    systemImage: "eye"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial)
                .accessibilityElement(children: .combine)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await chat.refreshMessages() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .frame(width: 44, height: 44)
                }
                .disabled(conversation.isEncrypted || chat.state.isRefreshingMessages)
                .accessibilityLabel(L10n.string("mobile.chat.action.refresh-messages"))
            }
        }
        .safeAreaInset(edge: .bottom) {
            if chat.canComposeMessage, !conversation.isEncrypted {
                MobileChatAttachmentComposer(chat: chat)
            }
        }
        .mobileChatRemoteAttachmentPresentation(chat: chat)
    }

    private var messageContent: some View {
        let state = chat.state
        return MobilePageStateView(
            state: state.messagePageState,
            labels: messageStateLabels,
            emptySystemImage: "bubble.left",
            retryAction: { Task { await chat.refreshMessages() } }
        ) {
            List {
                loadEarlierSection(state)
                ForEach(state.selectedMessages.messages) { message in
                    MobileChatMessageRow(chat: chat, message: message)
                }
            }
            .listStyle(.plain)
            .refreshable { await chat.refreshMessages() }
        }
        .overlay(alignment: .top) {
            if state.isRefreshingMessages {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: .capsule)
                    .accessibilityLabel(L10n.string("mobile.chat.loading.messages"))
            }
        }
    }

    @ViewBuilder
    private func loadEarlierSection(_ state: MobileChatProfileState) -> some View {
        if state.isLoadingMoreMessages {
            HStack {
                Spacer()
                ProgressView(L10n.string("mobile.chat.loading.earlier"))
                Spacer()
            }
            .frame(minHeight: 44)
        } else if state.loadMoreMessagesFailed {
            Button(L10n.string("mobile.chat.load-earlier.failed")) {
                Task { await chat.loadMoreMessages() }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        } else if state.selectedMessages.hasMoreBefore {
            Button(L10n.string("mobile.chat.action.load-earlier")) {
                Task { await chat.loadMoreMessages() }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var messageStateLabels: MobilePageStateLabels {
        MobilePageStateLabels(
            loading: L10n.string("mobile.chat.loading.messages"),
            emptyTitle: L10n.string("mobile.chat.messages.empty.title"),
            emptyMessage: L10n.string("mobile.chat.messages.empty.message"),
            filteredEmptyTitle: L10n.string("mobile.chat.messages.empty.title"),
            filteredEmptyMessage: L10n.string("mobile.chat.messages.empty.message"),
            errorTitle: L10n.string("mobile.chat.error.title"),
            errorMessage: L10n.string("mobile.chat.messages.error.message"),
            retryTitle: L10n.string("mobile.chat.action.retry")
        )
    }
}

private struct MobileChatMessageRow: View {
    @Bindable var chat: MobileChatModel
    let message: ChatMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(message.senderDisplayName ?? L10n.string("mobile.chat.sender.unknown"))
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                Text(message.sentAt, style: .time)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let text = message.text, !text.isEmpty {
                Text(text)
                    .font(.body)
                    .textSelection(.enabled)
            }
            ForEach(message.attachments) { attachment in
                MobileChatRemoteAttachmentRow(
                    chat: chat,
                    message: message,
                    attachment: attachment
                )
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: 680, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

}
