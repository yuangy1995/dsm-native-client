import DsmCore
import DsmLocalization
import Foundation
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
        let isPinned = model.chatModel.state.isConversationPinned(conversation.id)
        if horizontalSizeClass == .regular {
            Button {
                Task { await model.chatModel.selectConversation(conversation) }
            } label: {
                MobileChatConversationRow(
                    conversation: conversation,
                    isSelected: model.chatModel.state.selectedConversationID == conversation.id,
                    isPinned: isPinned
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(
                model.chatModel.state.selectedConversationID == conversation.id ? .isSelected : []
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                conversationPinButton(conversation, isPinned: isPinned)
            }
        } else {
            NavigationLink(value: conversation) {
                MobileChatConversationRow(
                    conversation: conversation,
                    isSelected: false,
                    isPinned: isPinned
                )
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                conversationPinButton(conversation, isPinned: isPinned)
            }
        }
    }

    private func conversationPinButton(_ conversation: ChatConversation, isPinned: Bool) -> some View {
        Button {
            model.chatModel.toggleConversationPinned(conversation)
        } label: {
            Label(
                conversationPinActionTitle(isPinned: isPinned),
                systemImage: isPinned ? "pin.slash" : "pin"
            )
        }
        .tint(.accentColor)
        .accessibilityLabel(conversationPinActionTitle(isPinned: isPinned))
        .accessibilityHint(L10n.string("mobile.chat.pin.hint"))
    }

    private func conversationPinActionTitle(isPinned: Bool) -> String {
        L10n.string(isPinned ? "mobile.chat.pin.action.unpin" : "mobile.chat.pin.action.pin")
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
    let isPinned: Bool

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
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                    }
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
        let baseLabel: String
        if conversation.isEncrypted, conversation.unreadCount > 0 {
            baseLabel = L10n.string(
                "mobile.chat.conversation.accessibility.encrypted-unread",
                conversation.title,
                conversation.unreadCount
            )
        } else if conversation.isEncrypted {
            baseLabel = L10n.string(
                "mobile.chat.conversation.accessibility.encrypted",
                conversation.title
            )
        } else if conversation.unreadCount > 0 {
            baseLabel = L10n.string(
                "mobile.chat.conversation.accessibility.unread",
                conversation.title,
                conversation.unreadCount
            )
        } else {
            baseLabel = L10n.string("mobile.chat.conversation.accessibility", conversation.title)
        }
        return isPinned
            ? L10n.string("mobile.chat.conversation.accessibility.pinned", baseLabel)
            : baseLabel
    }
}

private struct MobileChatMessagesView: View {
    @Bindable var chat: MobileChatModel
    let conversation: ChatConversation
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var presentsMembers = false
    @State private var presentsAnnouncements = false

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
            chat.enterConversation(conversation.id)
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
            ToolbarItemGroup(placement: .topBarTrailing) {
                if chat.canViewAnnouncements(for: conversation) {
                    Button {
                        presentsAnnouncements = true
                    } label: {
                        Image(systemName: "megaphone")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.string("mobile.chat.announcements.action"))
                    .accessibilityHint(L10n.string("mobile.chat.announcements.hint"))
                }

                if chat.canViewMembers(for: conversation) {
                    Button {
                        presentsMembers = true
                    } label: {
                        Image(systemName: "person.2")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.string("mobile.chat.members.action"))
                    .accessibilityHint(L10n.string("mobile.chat.members.hint"))
                }

                Button {
                    chat.toggleConversationPinned(conversation)
                } label: {
                    Image(systemName: conversationPinSystemImageName)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(conversationPinActionTitle)
                .accessibilityHint(L10n.string("mobile.chat.pin.hint"))

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
        .sheet(isPresented: $presentsMembers) {
            MobileChatMembersSheet(chat: chat, conversation: conversation)
        }
        .sheet(isPresented: $presentsAnnouncements) {
            MobileChatAnnouncementsSheet(chat: chat, conversation: conversation)
        }
        .safeAreaInset(edge: .bottom) {
            if chat.canComposeMessage, !conversation.isEncrypted {
                MobileChatAttachmentComposer(chat: chat)
            }
        }
        .mobileChatRemoteAttachmentPresentation(chat: chat)
    }

    private var conversationPinSystemImageName: String {
        chat.state.isConversationPinned(conversation.id) ? "pin.fill" : "pin"
    }

    private var conversationPinActionTitle: String {
        L10n.string(
            chat.state.isConversationPinned(conversation.id)
                ? "mobile.chat.pin.action.unpin"
                : "mobile.chat.pin.action.pin"
        )
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

private struct MobileChatAnnouncementsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var chat: MobileChatModel
    let conversation: ChatConversation

    var body: some View {
        NavigationStack {
            MobilePageStateView(
                state: chat.state.announcementPageState,
                labels: announcementStateLabels,
                emptySystemImage: "megaphone",
                errorSystemImage: "exclamationmark.bubble",
                retryAction: {
                    Task { await chat.loadConversationAnnouncements(forceRefresh: true) }
                }
            ) {
                List {
                    Section {
                        ForEach(chat.state.selectedConversationAnnouncements) { announcement in
                            announcementRow(announcement)
                        }
                    } header: {
                        Text(
                            L10n.string(
                                "mobile.chat.announcements.count",
                                chat.state.selectedConversationAnnouncements.count
                            )
                        )
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await chat.loadConversationAnnouncements(forceRefresh: true)
                }
            }
            .navigationTitle(L10n.string("mobile.chat.announcements.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.chat.announcements.close")) {
                        chat.cancelConversationAnnouncementLoad()
                        dismiss()
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await chat.loadConversationAnnouncements(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(
                        chat.state.announcementPageState == .loading
                            || chat.state.isRefreshingAnnouncements
                    )
                    .accessibilityLabel(L10n.string("mobile.chat.announcements.refresh"))
                }
            }
            .overlay(alignment: .top) {
                if chat.state.isRefreshingAnnouncements {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: .capsule)
                        .accessibilityLabel(L10n.string("mobile.chat.announcements.loading"))
                }
            }
        }
        .task(id: conversation.id) {
            await chat.loadConversationAnnouncements()
        }
        .onDisappear {
            chat.cancelConversationAnnouncementLoad()
        }
    }

    private func announcementRow(_ announcement: ChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(
                announcement.senderDisplayName
                    ?? L10n.string("mobile.chat.sender.unknown")
            )
            .font(.subheadline.weight(.semibold))
            Text(announcementText(announcement))
                .font(.body)
                .textSelection(.enabled)
            if let pinnedAt = announcement.pinnedAt {
                Text(
                    L10n.string(
                        "mobile.chat.announcements.pinned-at",
                        pinnedAt.formatted(
                            .dateTime
                                .year()
                                .month()
                                .day()
                                .hour()
                                .minute()
                                .locale(L10n.locale)
                        )
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func announcementText(_ announcement: ChatMessage) -> String {
        let text = announcement.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty
            ? L10n.string("mobile.chat.announcements.no-text")
            : text
    }

    private var announcementStateLabels: MobilePageStateLabels {
        MobilePageStateLabels(
            loading: L10n.string("mobile.chat.announcements.loading"),
            emptyTitle: L10n.string("mobile.chat.announcements.empty.title"),
            emptyMessage: L10n.string("mobile.chat.announcements.empty.message"),
            filteredEmptyTitle: L10n.string("mobile.chat.announcements.empty.title"),
            filteredEmptyMessage: L10n.string("mobile.chat.announcements.empty.message"),
            errorTitle: L10n.string("mobile.chat.announcements.error.title"),
            errorMessage: L10n.string("mobile.chat.announcements.error.message"),
            retryTitle: L10n.string("mobile.chat.action.retry")
        )
    }
}

private struct MobileChatMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var chat: MobileChatModel
    let conversation: ChatConversation

    var body: some View {
        NavigationStack {
            MobilePageStateView(
                state: chat.state.memberPageState,
                labels: memberStateLabels,
                emptySystemImage: "person.2",
                errorSystemImage: "person.2.slash",
                retryAction: {
                    Task { await chat.loadConversationMembers(forceRefresh: true) }
                }
            ) {
                List {
                    Section {
                        ForEach(chat.state.selectedConversationMembers) { member in
                            memberRow(member)
                        }
                    } header: {
                        Text(
                            L10n.string(
                                "mobile.chat.members.count",
                                chat.state.selectedConversationMembers.count
                            )
                        )
                    }
                }
                .listStyle(.plain)
                .refreshable {
                    await chat.loadConversationMembers(forceRefresh: true)
                }
            }
            .navigationTitle(L10n.string("mobile.chat.members.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.chat.members.close")) {
                        chat.cancelConversationMemberLoad()
                        dismiss()
                    }
                    .frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await chat.loadConversationMembers(forceRefresh: true) }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 44, height: 44)
                    }
                    .disabled(
                        chat.state.memberPageState == .loading
                            || chat.state.isRefreshingMembers
                    )
                    .accessibilityLabel(L10n.string("mobile.chat.members.refresh"))
                }
            }
            .overlay(alignment: .top) {
                if chat.state.isRefreshingMembers {
                    ProgressView()
                        .controlSize(.small)
                        .padding(8)
                        .background(.regularMaterial, in: .capsule)
                        .accessibilityLabel(L10n.string("mobile.chat.members.loading"))
                }
            }
        }
        .task(id: conversation.id) {
            await chat.loadConversationMembers()
        }
        .onDisappear {
            chat.cancelConversationMemberLoad()
        }
    }

    private func memberRow(_ member: ChatUser) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(member.displayName)
                    .font(.body.weight(.medium))
                if member.isCurrentUser == true {
                    Text(L10n.string("mobile.chat.members.current-user"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if member.isDisabled {
                    Text(L10n.string("mobile.chat.members.disabled"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var memberStateLabels: MobilePageStateLabels {
        MobilePageStateLabels(
            loading: L10n.string("mobile.chat.members.loading"),
            emptyTitle: L10n.string("mobile.chat.members.empty.title"),
            emptyMessage: L10n.string("mobile.chat.members.empty.message"),
            filteredEmptyTitle: L10n.string("mobile.chat.members.empty.title"),
            filteredEmptyMessage: L10n.string("mobile.chat.members.empty.message"),
            errorTitle: L10n.string("mobile.chat.members.error.title"),
            errorMessage: L10n.string("mobile.chat.members.error.message"),
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
