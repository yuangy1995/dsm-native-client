import AppKit
import DsmCore
import SwiftUI
import UniformTypeIdentifiers
import DsmLocalization

struct ChatWorkspaceView: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Bindable var model: ChatWorkspaceModel
    @State private var presentsNewConversation = false
    @State private var selectedConversationIDs: Set<String> = []
    @State private var pendingConversationDeletion: Set<String> = []
    @State private var presentsConversationDeletionConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            MacPageHeader(title: L10n.string("ui.4da199fae933d4fa")) {
                Button {
                    Task { await model.reload() }
                } label: {
                    Label(L10n.string("ui.a4d302df47192b25"), systemImage: "arrow.clockwise")
                }
                .disabled(model.isLoading)
                .help(L10n.string("ui.550b0751f537f74e"))
            }
            if model.canUseMessaging, model.statusIsError, let statusMessage = model.statusMessage {
                ChatActionStatusBanner(
                    message: statusMessage,
                    isError: model.statusIsError,
                    onDismiss: model.clearStatus
                )
            }
            HSplitView {
                conversationColumn
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                conversationDetail
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if let toast = model.activeToast {
                InAppToastOverlayView(toast: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(10)
                    .onTapGesture {
                        model.dismissToast()
                    }
                    .accessibilityHint(L10n.string("ui.4fdf8b59f329f5ba"))
            }
        }
        .animation(
            reducesMotion ? nil : .spring(response: 0.3, dampingFraction: 0.82),
            value: model.activeToast?.id
        )
        .task {
            await model.loadIfNeeded()
            await model.refreshForegroundChat()
        }
        .sheet(isPresented: $presentsNewConversation) {
            NewChatSheet(model: model)
        }
        .alert(
            pendingConversationDeletion.count == 1 ? L10n.string("ui.aea0944d46f20836") : L10n.string("ui.bfa1f429dab3881b", String(describing: pendingConversationDeletion.count)),
            isPresented: $presentsConversationDeletionConfirmation
        ) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("ui.d51250d14a5142e5"), role: .destructive) {
                let ids = pendingConversationDeletion
                pendingConversationDeletion = []
                Task {
                    _ = await model.closeConversations(ids: ids)
                    selectedConversationIDs.subtract(ids)
                }
            }
            .disabled(model.isPerformingAction)
        } message: {
            Text(L10n.string("ui.89d21bc75f46d321"))
        }
        .onChange(of: model.selectedConversationID) { _, selectedID in
            guard selectedConversationIDs.count <= 1 else { return }
            selectedConversationIDs = selectedID.map { [$0] } ?? []
        }
    }

    private var newConversationHelp: String {
        if model.canCreateDirectConversation || model.canCreateGroupConversation {
            return L10n.string("ui.c9f2141af12cca30")
        }
        return L10n.string("ui.a6a7346a19011239")
    }

    private var conversationColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L10n.string("ui.a63280253f17d440"))
                    .font(.headline)
                Button {
                    presentsNewConversation = true
                } label: {
                    Label(L10n.string("ui.08d90be0bab08c36"), systemImage: "plus")
                        .labelStyle(.iconOnly)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(MacToolbarButtonStyle())
                .disabled(!model.canCreateDirectConversation && !model.canCreateGroupConversation)
                .help(newConversationHelp)
                .accessibilityLabel(L10n.string("ui.08d90be0bab08c36"))
                Spacer()
                if model.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(L10n.string("ui.fc34c019b007657d"))
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(MacGlassSurface(role: .toolbar))

            Divider()

            if !model.canUseMessaging {
                ChatServiceStateView(
                    status: model.availability.status,
                    message: model.statusMessage,
                    isLoading: model.isLoading,
                    onRetry: { Task { await model.reload() } }
                )
            } else if model.conversations.isEmpty, !model.isLoading {
                ContentUnavailableView {
                    Label(L10n.string("ui.fa8376c2939150e8"), systemImage: "bubble.left.and.bubble.right")
                } description: {
                    Text(L10n.string("ui.7e7926db0d47d6e0"))
                } actions: {
                    Button(L10n.string("ui.08d90be0bab08c36")) {
                        presentsNewConversation = true
                    }
                    .disabled(!model.canCreateDirectConversation && !model.canCreateGroupConversation)
                }
                .fillsAvailableContentArea()
            } else {
                List(selection: conversationSelection) {
                    ForEach(model.conversations) { conversation in
                        ConversationRow(
                            conversation: conversation,
                            summary: model.conversationSummary(conversation),
                            users: model.users,
                            currentUserID: model.currentUserID,
                            isPinned: model.isConversationPinned(conversation.id)
                        )
                            .tag(conversation.id)
                            .padding(.vertical, 6)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button {
                                    model.toggleConversationPin(id: conversation.id)
                                } label: {
                                    Label(
                                        model.isConversationPinned(conversation.id)
                                            ? L10n.string("ui.c92179b74af61689")
                                            : L10n.string("ui.1fd17bddc21bff44"),
                                        systemImage: model.isConversationPinned(conversation.id)
                                            ? "pin.slash"
                                            : "pin"
                                    )
                                }

                                Divider()

                                Button(role: .destructive) {
                                    requestConversationDeletion(from: conversation.id)
                                } label: {
                                    Label(conversationDeletionTitle(for: conversation.id), systemImage: "trash")
                                }
                                .disabled(!model.canCloseConversations || model.isPerformingAction)
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .onDeleteCommand {
                    requestConversationDeletion(ids: selectedConversationIDs)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(MacGlassSurface(role: .sidebar))
    }

    private var conversationSelection: Binding<Set<String>> {
        Binding(
            get: { selectedConversationIDs },
            set: { ids in
                selectedConversationIDs = ids
                let selectedID: String?
                if let current = model.selectedConversationID, ids.contains(current) {
                    selectedID = current
                } else {
                    selectedID = ids.first
                }
                Task { await model.selectConversation(id: selectedID) }
            }
        )
    }

    private func conversationDeletionTargets(from conversationID: String) -> Set<String> {
        selectedConversationIDs.contains(conversationID) && selectedConversationIDs.count > 1
            ? selectedConversationIDs
            : [conversationID]
    }

    private func conversationDeletionTitle(for conversationID: String) -> String {
        let count = conversationDeletionTargets(from: conversationID).count
        return count == 1 ? L10n.string("ui.d51250d14a5142e5") : L10n.string("ui.ebf1ed6fef62420a", String(describing: count))
    }

    private func requestConversationDeletion(from conversationID: String) {
        requestConversationDeletion(ids: conversationDeletionTargets(from: conversationID))
    }

    private func requestConversationDeletion(ids: Set<String>) {
        guard model.canCloseConversations, !model.isPerformingAction, !ids.isEmpty else { return }
        pendingConversationDeletion = ids
        presentsConversationDeletionConfirmation = true
    }

    @ViewBuilder
    private var conversationDetail: some View {
        if let conversation = model.selectedConversation {
            ChatConversationView(model: model, conversation: conversation)
        } else if model.canUseMessaging {
            ContentUnavailableView(
                L10n.string("ui.4fc5349db1ff0c87"),
                systemImage: "bubble.left",
                description: Text(L10n.string("ui.62de39c2c4ba2300"))
            )
            .fillsAvailableContentArea()
        } else {
            ChatUnavailableDetail(status: model.availability.status)
        }
    }
}

private struct ChatActionStatusBanner: View {
    let message: String
    let isError: Bool
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
                Label(L10n.string("ui.d301bc1258334c7c"), systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.string("ui.d301bc1258334c7c"))
        }
        .foregroundStyle(isError ? Color.red : Color.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(isError ? Color.red.opacity(0.08) : Color.accentColor.opacity(0.08))
    }
}

private struct ConversationRow: View {
    let conversation: ChatConversation
    let summary: String
    let users: [ChatUser]
    let currentUserID: String?
    let isPinned: Bool

    private var directUser: ChatUser? {
        guard conversation.kind == .direct else { return nil }
        let otherID = conversation.memberIDs.first { $0 != currentUserID }
        return users.first { $0.id == otherID }
    }

    var body: some View {
        HStack(spacing: 10) {
            if let directUser {
                ChatAvatar(name: directUser.displayName, imageData: directUser.avatarData)
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: conversation.kind == .group ? "person.2.fill" : "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(conversation.title)
                        .font(.headline)
                        .lineLimit(1)
                    if conversation.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.string("ui.85a68e03fe6e6789"))
                    }
                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.string("ui.fb47db5e65ff7fa0"))
                    }
                    Spacer(minLength: 4)
                    if let lastActivityAt = conversation.lastActivityAt {
                        Text(lastActivityAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if conversation.unreadCount > 0 {
                        Text("\(conversation.unreadCount)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint, in: Capsule())
                            .accessibilityLabel(L10n.string("ui.d03793ec01fb7aee", String(describing: conversation.unreadCount)))
                    }
                }
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct ChatServiceStateView: View {
    let status: ChatAvailabilityStatus
    let message: String?
    let isLoading: Bool
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: status == .unavailable ? "bubble.left.and.exclamationmark.bubble.right" : "checkmark.shield")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(status == .unavailable ? L10n.string("ui.4bb23165e9cfcb54") : L10n.string("ui.ac42be48e1fe5bdd"))
                .font(.headline)
            Text(message ?? L10n.string("ui.bb4dbbe3d77db669"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onRetry()
            } label: {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Text(L10n.string("ui.c25fb86b1e96e063"))
                }
            }
            .disabled(isLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct ChatUnavailableDetail: View {
    let status: ChatAvailabilityStatus

    var body: some View {
        ContentUnavailableView {
            Label(
                status == .unavailable ? L10n.string("ui.4b7c1ba33c604c88") : L10n.string("ui.005661966fc924b6"),
                systemImage: status == .unavailable ? "exclamationmark.bubble" : "lock.shield"
            )
        } description: {
            Text(
                status == .unavailable
                    ? L10n.string("ui.b1da68b82fb50f16")
                    : L10n.string("ui.c54a3dbc28e361c3")
            )
        }
        .fillsAvailableContentArea()
    }
}

private struct ChatConversationView: View {
    @Bindable var model: ChatWorkspaceModel
    let conversation: ChatConversation
    @State private var attachmentURLs: [URL] = []
    @State private var presentsFileImporter = false
    @State private var presentsPollComposer = false
    @State private var presentsReminderList = false
    @State private var presentsGroupMembers = false
    @State private var presentsPinnedMessages = false
    @State private var reminderMessage: ChatMessage?
    @State private var presentsScheduledMessageComposer = false
    @State private var presentsScheduledMessageList = false
    @State private var selectedMessageIDs: Set<String> = []
    @State private var presentsForwardSheet = false
    @State private var pendingMessageDeletion: Set<String> = []
    @State private var presentsMessageDeletionConfirmation = false
    @State private var scrollToLatestRequest = 0
    @State private var presentsImagePreview = false
    @State private var previewedImage: NSImage?
    @FocusState private var isComposerFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            conversationHeader
            Divider()

            if model.isLoadingMessages {
                ProgressView(L10n.string("ui.68e4421f9ccf609d"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.messages.isEmpty {
                emptyConversationState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            if model.hasMoreMessagesBefore {
                                Button {
                                    Task {
                                        if let anchorID = await model.loadEarlierMessages() {
                                            proxy.scrollTo(anchorID, anchor: .top)
                                        }
                                    }
                                } label: {
                                    if model.isLoadingEarlierMessages {
                                        ProgressView(L10n.string("ui.9f4249261605e43b"))
                                            .controlSize(.small)
                                    } else {
                                        Label(L10n.string("ui.1843f002069657ae"), systemImage: "arrow.up.circle")
                                    }
                                }
                                .buttonStyle(.borderless)
                                .disabled(model.isLoadingEarlierMessages)
                                .padding(.vertical, 6)
                            }

                            ForEach(Array(model.messages.enumerated()), id: \.element.id) { index, message in
                                if shouldShowDateSeparator(at: index) {
                                    ChatDateSeparator(date: message.sentAt)
                                        .padding(.vertical, index == 0 ? 2 : 10)
                                }
                                ChatMessageRow(
                                    message: message,
                                    users: model.users,
                                    isCurrentUser: model.isCurrentUser(message),
                                    showsSender: conversation.kind == .group,
                                    isSelected: selectedMessageIDs.contains(message.id),
                                    failureMessage: model.sendFailureMessage(for: message.id),
                                    uploadProgress: model.uploadProgress(for: message.id),
                                    downloadProgress: model.attachmentDownloadProgress(for: message.id),
                                    thumbnailData: model.thumbnailData(for: message.id),
                                    canDownloadAttachments: model.canDownloadAttachments,
                                    onCancel: { model.cancelMessageSend(id: message.id) },
                                    onRetry: { Task { await model.retryMessage(id: message.id) } },
                                    onCancelDownload: {
                                        model.cancelAttachmentDownload(messageID: message.id)
                                    },
                                    onLoadThumbnail: { attachment in
                                        Task {
                                            await model.loadAttachmentThumbnail(
                                                messageID: message.id,
                                                attachment: attachment
                                            )
                                        }
                                    },
                                    onPreviewImage: { attachment in
                                        presentImagePreview(message: message, attachment: attachment)
                                    },
                                    onSaveAttachment: { attachment in
                                        saveAttachment(message: message, attachment: attachment)
                                    }
                                )
                                    .id(message.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selectMessage(message)
                                    }
                                    .contextMenu {
                                        if message.deliveryState == .failed {
                                            Button {
                                                Task { await model.retryMessage(id: message.id) }
                                            } label: {
                                                Label(L10n.string("ui.9287ac799e545bb0"), systemImage: "arrow.clockwise")
                                            }
                                            .disabled(model.isPerformingAction)
                                            Button(role: .destructive) {
                                                model.removeFailedMessage(id: message.id)
                                            } label: {
                                                Label(L10n.string("ui.a07bcb96af2f3182"), systemImage: "trash")
                                            }
                                        } else if message.deliveryState == .sending {
                                            Button(role: .destructive) {
                                                model.cancelMessageSend(id: message.id)
                                            } label: {
                                                Label(L10n.string("ui.554bfa5fa81c82cb"), systemImage: "xmark.circle")
                                            }
                                        } else {
                                            if let attachment = message.attachments.first,
                                               model.canDownloadAttachments {
                                                if attachment.kind == .image {
                                                    Button {
                                                        presentImagePreview(message: message, attachment: attachment)
                                                    } label: {
                                                        Label(L10n.string("ui.de078ce976cebdbd"), systemImage: "photo")
                                                    }
                                                }
                                                Button {
                                                    saveAttachment(message: message, attachment: attachment)
                                                } label: {
                                                    Label(L10n.string("ui.f0ab22db233be1f5"), systemImage: "square.and.arrow.down")
                                                }
                                                Divider()
                                            }
                                            if model.canManageReminders {
                                                Button {
                                                    reminderMessage = message
                                                } label: {
                                                    Label(
                                                        model.reminder(for: message.id) == nil ? L10n.string("ui.d6171a625a79e798") : L10n.string("ui.908ae6359d3ff66e"),
                                                        systemImage: "bell"
                                                    )
                                                }
                                                .disabled(model.isPerformingAction)
                                            }
                                            if model.canPin(message) {
                                                Button {
                                                    Task {
                                                        _ = await model.setMessagePinned(
                                                            message,
                                                            isPinned: !message.isPinned
                                                        )
                                                    }
                                                } label: {
                                                    Label(
                                                        message.isPinned ? L10n.string("ui.02bf53bf7b24aff8") : L10n.string("ui.9948214d915ca840"),
                                                        systemImage: message.isPinned ? "pin.slash" : "pin"
                                                    )
                                                }
                                                .disabled(model.isPerformingAction)
                                            }
                                            if model.canForward(message) {
                                                Divider()
                                                Button {
                                                    toggleMessageSelection(message.id)
                                                } label: {
                                                    Label(
                                                        selectedMessageIDs.contains(message.id) ? L10n.string("ui.74966e20df2ea9fd") : L10n.string("ui.b8b9e1bf1a8c4d99"),
                                                        systemImage: selectedMessageIDs.contains(message.id) ? "checkmark.circle.fill" : "circle"
                                                    )
                                                }
                                                Button {
                                                    presentForwardSheet(from: message.id)
                                                } label: {
                                                    Label(L10n.string("ui.31e2b7f36595d8a5"), systemImage: "arrowshape.turn.up.right")
                                                }
                                                .disabled(model.isPerformingAction)
                                            }
                                            if model.canDelete(message) {
                                                Divider()
                                                Button(role: .destructive) {
                                                    requestMessageDeletion(from: message.id)
                                                } label: {
                                                    Label(messageDeletionTitle(for: message.id), systemImage: "trash")
                                                }
                                                .disabled(model.isPerformingAction)
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .task(id: conversation.id) {
                        await Task.yield()
                        if let lastID = model.messages.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                    .onChange(of: model.messages.last?.id) { _, lastID in
                        guard let lastID,
                              let lastMessage = model.messages.last,
                              model.isCurrentUser(lastMessage) else { return }
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                    .onChange(of: scrollToLatestRequest) { _, _ in
                        guard let lastID = model.messages.last?.id else { return }
                        proxy.scrollTo(lastID, anchor: .bottom)
                        model.clearNewMessageIndicator()
                    }
                }
            }

            if !selectedMessageIDs.isEmpty {
                selectionBar
            }
            Divider()
            composer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .fileImporter(
            isPresented: $presentsFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result {
                attachmentURLs = Array(urls.prefix(1))
            }
        }
        .sheet(isPresented: $presentsPollComposer) {
            CreatePollSheet(model: model, conversation: conversation)
        }
        .sheet(isPresented: $presentsReminderList) {
            ReminderListSheet(model: model)
        }
        .sheet(isPresented: $presentsGroupMembers) {
            GroupMembersSheet(model: model, conversation: conversation)
        }
        .sheet(isPresented: $presentsPinnedMessages) {
            PinnedMessagesSheet(model: model, conversation: conversation)
        }
        .sheet(isPresented: $presentsScheduledMessageComposer) {
            ScheduledMessageComposerSheet(model: model, conversation: conversation)
        }
        .sheet(isPresented: $presentsScheduledMessageList) {
            ScheduledMessageListSheet(model: model)
        }
        .sheet(item: $reminderMessage) { message in
            ReminderEditorSheet(model: model, message: message)
        }
        .sheet(isPresented: $presentsImagePreview) {
            ChatImagePreviewSheet(image: previewedImage)
        }
        .sheet(isPresented: $presentsForwardSheet) {
            ForwardMessagesSheet(
                model: model,
                messageIDs: selectedMessageIDs
            ) {
                selectedMessageIDs = []
            }
        }
        .alert(
            pendingMessageDeletion.count == 1 ? L10n.string("ui.7d4bf0c7c1ff1a7e") : L10n.string("ui.cbcd5916d736a88e", String(describing: pendingMessageDeletion.count)),
            isPresented: $presentsMessageDeletionConfirmation
        ) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("ui.053d6b4dd1f3b718"), role: .destructive) {
                let ids = pendingMessageDeletion
                pendingMessageDeletion = []
                Task {
                    _ = await model.deleteMessages(ids: ids)
                    selectedMessageIDs.subtract(ids)
                }
            }
            .disabled(model.isPerformingAction)
        } message: {
            Text(L10n.string("ui.e7f653c71078a6ce"))
        }
        .onChange(of: conversation.id) { _, _ in
            selectedMessageIDs = []
            presentsForwardSheet = false
            presentsImagePreview = false
            previewedImage = nil
        }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Label(
                L10n.string("ui.abe7ab8cbde4908f", String(describing: selectedMessageIDs.count)),
                systemImage: "checkmark.circle.fill"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)

            Spacer()

            Button {
                presentsForwardSheet = true
            } label: {
                Label(L10n.string("ui.02107ba378e21710"), systemImage: "arrowshape.turn.up.right")
            }
            .buttonStyle(.borderedProminent)
            .disabled(
                selectedMessages.count != selectedMessageIDs.count
                    || !selectedMessages.allSatisfy(model.canForward)
                    || model.isPerformingAction
            )

            if selectedMessages.count == selectedMessageIDs.count,
               selectedMessages.allSatisfy(model.canDelete) {
                Button(role: .destructive) {
                    requestMessageDeletion(for: selectedMessageIDs)
                } label: {
                    Label(L10n.string("ui.2f9daa828907b93f"), systemImage: "trash")
                }
                .disabled(model.isPerformingAction)
            }

            Button(L10n.string("ui.74966e20df2ea9fd")) {
                selectedMessageIDs = []
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(MacGlassSurface(role: .toolbar))
    }

    private var selectedMessages: [ChatMessage] {
        model.messages.filter { selectedMessageIDs.contains($0.id) }
    }

    private var conversationHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: conversation.kind == .group ? "person.2.fill" : "person.crop.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(conversation.title)
                    .font(.headline)
                Text(model.memberSummary(for: conversation))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.newMessageCount > 0 {
                Button {
                    scrollToLatestRequest += 1
                } label: {
                    Label(L10n.string("ui.b20347ae4157386f", String(describing: model.newMessageCount)), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderless)
                    .help(L10n.string("ui.e15f7624e326b635"))
            }
            if conversation.kind == .group, model.canViewGroupMembers {
                Button {
                    presentsGroupMembers = true
                } label: {
                    Label(L10n.string("ui.9d8692671d208b74"), systemImage: "person.2")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("ui.6003a1eadb5754b1"))
                .accessibilityLabel(L10n.string("ui.6003a1eadb5754b1"))
            }
            if conversation.kind == .group, model.canManagePinnedMessages {
                Button {
                    presentsPinnedMessages = true
                } label: {
                    Label(L10n.string("ui.99728d0e0224c355"), systemImage: "pin")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("ui.b1ada05af7dc3716"))
                .accessibilityLabel(L10n.string("ui.b1ada05af7dc3716"))
            }
            if model.canManageReminders {
                Button {
                    presentsReminderList = true
                } label: {
                    Label(L10n.string("ui.8f29b3132ccf2182"), systemImage: model.reminders.isEmpty ? "bell" : "bell.badge")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("ui.3f7aab4e272aa227"))
                .accessibilityLabel(L10n.string("ui.3f7aab4e272aa227"))
            }
            if model.canScheduleMessages {
                Button {
                    presentsScheduledMessageList = true
                } label: {
                    Label(
                        L10n.string("ui.582feae291691f33"),
                        systemImage: model.scheduledMessages.isEmpty ? "clock" : "clock.badge"
                    )
                    .labelStyle(.iconOnly)
                    .frame(width: 28, height: 28)
                }
                .buttonStyle(.borderless)
                .help(L10n.string("ui.9a57b15141045f99"))
                .accessibilityLabel(L10n.string("ui.9a57b15141045f99"))
            }
            if conversation.isEncrypted {
                Label(L10n.string("ui.b66975fbd35fa85d"), systemImage: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(MacGlassSurface(role: .toolbar))
    }

    private var emptyConversationState: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)

            VStack(spacing: 14) {
                Image(systemName: conversation.kind == .group
                    ? "person.2.fill"
                    : "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundStyle(.tint)
                    .frame(width: 64, height: 64)
                    .background(Color.accentColor.opacity(0.10), in: Circle())
                    .accessibilityHidden(true)

                VStack(spacing: 6) {
                    Text(emptyConversationTitle)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(L10n.string("ui.15a3dea878ee9537"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.canSendText {
                    Button {
                        isComposerFocused = true
                    } label: {
                        Label(L10n.string("ui.bf35b31e17d057e6"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(model.isPerformingAction)
                    .accessibilityHint(L10n.string("ui.a492b178304eda98"))
                }
            }
            .frame(maxWidth: 380)
            .padding(.horizontal, 32)
            .padding(.vertical, 28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .accessibilityElement(children: .contain)
    }

    private var emptyConversationTitle: String {
        switch conversation.kind {
        case .direct:
            L10n.string("ui.639159cf49a082cc", String(describing: conversation.title))
        case .group:
            L10n.string("ui.13bcea0b712e2b0c", String(describing: conversation.title))
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachmentURLs.isEmpty {
                HStack {
                    Label(attachmentURLs.first?.lastPathComponent ?? L10n.string("ui.31eb2ab65ee4aeb6"), systemImage: "paperclip")
                        .font(.caption)
                    Spacer()
                    Button(L10n.string("ui.7ee8b2d0ae7ade97")) {
                        attachmentURLs = []
                    }
                    .buttonStyle(.borderless)
                }
            }

            TextField(L10n.string("ui.a410452649b38b31"), text: draftText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
                .focused($isComposerFocused)
                .disabled(!model.canSendText || model.isPerformingAction)
                .onSubmit(send)

            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    if model.canSendAttachments {
                        presentsFileImporter = true
                    } else {
                        model.showAttachmentUnavailable()
                    }
                } label: {
                    Label(L10n.string("ui.c8a47d0018480abe"), systemImage: "paperclip")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .disabled(!model.canUseMessaging || model.isPerformingAction)
                .help(model.canSendAttachments ? L10n.string("ui.92ef78e381a90762") : L10n.string("ui.e19b010fb03f1d59"))
                .accessibilityLabel(L10n.string("ui.c8a47d0018480abe"))

                Button {
                    isComposerFocused = true
                    DispatchQueue.main.async {
                        NSApp.orderFrontCharacterPalette(nil)
                    }
                } label: {
                    Label(L10n.string("ui.d405f59076940eb3"), systemImage: "face.smiling")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .disabled(!model.canSendText || model.isPerformingAction)
                .help(L10n.string("ui.9692543077ef0182"))
                .accessibilityLabel(L10n.string("ui.d405f59076940eb3"))

                Button {
                    presentsPollComposer = true
                } label: {
                    Label(L10n.string("ui.54f9e511a851c7da"), systemImage: "chart.bar.xaxis")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .disabled(!model.canCreatePoll || model.isPerformingAction)
                .help(model.canCreatePoll ? L10n.string("ui.54f9e511a851c7da") : L10n.string("ui.073b8283ad1a2e59"))
                .accessibilityLabel(L10n.string("ui.54f9e511a851c7da"))

                Button {
                    presentsScheduledMessageComposer = true
                } label: {
                    Label(L10n.string("ui.33e4b16591ac7cba"), systemImage: "calendar.badge.clock")
                        .labelStyle(.iconOnly)
                        .frame(width: 28, height: 28)
                }
                .disabled(!model.canScheduleMessages || model.isPerformingAction)
                .help(model.canScheduleMessages ? L10n.string("ui.d8c36838861566a9") : L10n.string("ui.91b646fc9336888c"))
                .accessibilityLabel(L10n.string("ui.d8c36838861566a9"))

                Spacer(minLength: 8)

                Button(action: send) {
                    if model.isPerformingAction {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 28, height: 28)
                    } else {
                        Label(L10n.string("ui.edecf0ae6e5144f9"), systemImage: "paperplane.fill")
                            .frame(minWidth: 52, minHeight: 28)
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .buttonStyle(MacToolbarButtonStyle())
        }
        .padding(12)
        .background(MacGlassSurface(role: .toolbar))
    }

    private var canSend: Bool {
        !model.isPerformingAction
            && ((model.canSendText && !model.draftText(for: conversation.id).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                || (model.canSendAttachments && !attachmentURLs.isEmpty))
    }

    private func send() {
        guard canSend else { return }
        let text = model.draftText(for: conversation.id)
        let urls = attachmentURLs
        Task {
            if await model.send(text: text, attachmentURLs: urls) {
                attachmentURLs = []
            }
        }
    }

    private var draftText: Binding<String> {
        Binding(
            get: { model.draftText(for: conversation.id) },
            set: { model.updateDraft($0, for: conversation.id) }
        )
    }

    private func shouldShowDateSeparator(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !Calendar.current.isDate(
            model.messages[index - 1].sentAt,
            inSameDayAs: model.messages[index].sentAt
        )
    }

    private func selectMessage(_ message: ChatMessage) {
        guard model.canForward(message), !model.isPerformingAction else { return }
        if NSEvent.modifierFlags.contains(.command) {
            toggleMessageSelection(message.id)
        } else {
            selectedMessageIDs = [message.id]
        }
    }

    private func toggleMessageSelection(_ messageID: String) {
        if selectedMessageIDs.contains(messageID) {
            selectedMessageIDs.remove(messageID)
        } else {
            selectedMessageIDs.insert(messageID)
        }
    }

    private func messageDeletionTargets(from messageID: String) -> Set<String> {
        guard selectedMessageIDs.contains(messageID) else { return [messageID] }
        let deletableIDs = Set(
            model.messages
                .filter { selectedMessageIDs.contains($0.id) && model.canDelete($0) }
                .map(\.id)
        )
        return deletableIDs.contains(messageID) ? deletableIDs : [messageID]
    }

    private func messageDeletionTitle(for messageID: String) -> String {
        let count = messageDeletionTargets(from: messageID).count
        return count == 1 ? L10n.string("ui.053d6b4dd1f3b718") : L10n.string("ui.f435464807a3dd7d", String(describing: count))
    }

    private func requestMessageDeletion(from messageID: String) {
        requestMessageDeletion(for: messageDeletionTargets(from: messageID))
    }

    private func requestMessageDeletion(for ids: Set<String>) {
        let selectedMessages = model.messages.filter { ids.contains($0.id) }
        guard selectedMessages.count == ids.count,
              selectedMessages.allSatisfy(model.canDelete),
              !model.isPerformingAction else { return }
        pendingMessageDeletion = ids
        presentsMessageDeletionConfirmation = true
    }

    private func presentForwardSheet(from messageID: String) {
        if !selectedMessageIDs.contains(messageID) {
            selectedMessageIDs = [messageID]
        }
        presentsForwardSheet = true
    }

    private func presentImagePreview(message: ChatMessage, attachment: ChatAttachment) {
        guard attachment.kind == .image,
              model.canDownloadAttachments,
              !model.isPerformingAction,
              let image = model.thumbnailData(for: message.id).flatMap(NSImage.init(data:)) else { return }
        previewedImage = image
        presentsImagePreview = true
    }

    private func saveAttachment(message: ChatMessage, attachment: ChatAttachment) {
        guard model.canDownloadAttachments, !model.isPerformingAction else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = URL(fileURLWithPath: attachment.fileName).lastPathComponent
        panel.canCreateDirectories = true
        panel.title = L10n.string("ui.f6c71ae760ba11e7")
        panel.prompt = L10n.string("ui.a3030bf8f16dc63c")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                _ = await model.downloadAttachment(
                    messageID: message.id,
                    attachment: attachment,
                    to: destination
                )
            }
        }
    }
}

struct ChatImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.ba8b49f3fd10b338"))
                    .font(.headline)
                Spacer()
                Button { dismiss() } label: {
                    Label(L10n.string("ui.1eb05d3115088bdf"), systemImage: "xmark")
                }
                .buttonStyle(MacToolbarButtonStyle())
                .keyboardShortcut(.cancelAction)
                .help(L10n.string("ui.1eb05d3115088bdf"))
            }
            .padding(16)
            .background(MacGlassSurface(role: .toolbar))
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(20)
                        .accessibilityLabel(L10n.string("ui.ba8b49f3fd10b338"))
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .accessibilityLabel(L10n.string("ui.facec40ad268aefe"))
                }
            }
            .fillsAvailableContentArea()
            .background(MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).previewCanvas)
        }
        .frame(minWidth: 720, idealWidth: 960, minHeight: 520, idealHeight: 720)
    }
}

struct ForwardMessagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ChatWorkspaceModel
    let messageIDs: Set<String>
    let onComplete: () -> Void
    @State private var selectedConversationIDs: Set<String> = []
    @State private var selectedUserIDs: Set<String> = []
    @State private var searchText = ""
    @State private var forwardErrorMessage: String?

    private var conversationCandidates: [ChatConversation] {
        model.conversations.filter { conversation in
            guard conversation.id != model.selectedConversationID else { return false }
            let query = normalizedSearchText
            return query.isEmpty
                || conversation.title.localizedCaseInsensitiveContains(query)
        }
    }

    private var contactCandidates: [ChatUser] {
        let existingDirectUserIDs = Set(
            model.conversations
                .filter { $0.kind == .direct }
                .flatMap(\.memberIDs)
        )
        return model.users.filter { user in
            guard user.isCurrentUser != true,
                  user.id != model.currentUserID,
                  !user.isDisabled,
                  !existingDirectUserIDs.contains(user.id) else {
                return false
            }
            return normalizedSearchText.isEmpty
                || user.displayName.localizedCaseInsensitiveContains(normalizedSearchText)
                || user.id.localizedCaseInsensitiveContains(normalizedSearchText)
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTargetCount: Int {
        selectedConversationIDs.count + selectedUserIDs.count
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("ui.119f4645f840e0f0"))
                        .font(.title2.bold())
                    Text(L10n.string("ui.5515ea66b67846d1", String(describing: messageIDs.count)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
            Divider()

            TextField(L10n.string("ui.404de5b870b3e6a2"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

            if conversationCandidates.isEmpty, contactCandidates.isEmpty {
                ContentUnavailableView(
                    normalizedSearchText.isEmpty ? L10n.string("ui.9e060cfc78fbe2a5") : L10n.string("ui.c4132456f663ee3b"),
                    systemImage: normalizedSearchText.isEmpty ? "person.2.slash" : "magnifyingglass",
                    description: Text(normalizedSearchText.isEmpty ? L10n.string("ui.38c00260f7d51dda") : L10n.string("ui.5a7c1c3bbad8e5a8"))
                )
                .fillsAvailableContentArea()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if !conversationCandidates.isEmpty {
                            recipientSectionTitle(L10n.string("ui.fe4bfec108f7cd07"))
                            ForEach(conversationCandidates) { conversation in
                                recipientButton(
                                    title: conversation.title,
                                    subtitle: model.memberSummary(for: conversation),
                                    systemImage: conversation.kind == .group
                                        ? "person.2.fill"
                                        : "person.crop.circle.fill",
                                    isSelected: selectedConversationIDs.contains(conversation.id)
                                ) {
                                    toggleConversationSelection(conversation.id)
                                }
                            }
                        }

                        if !contactCandidates.isEmpty {
                            recipientSectionTitle(L10n.string("ui.3303b56982a00fd1"))
                                .padding(.top, conversationCandidates.isEmpty ? 0 : 10)
                            ForEach(contactCandidates) { user in
                                recipientButton(
                                    title: user.displayName,
                                    subtitle: L10n.string("ui.4da59d59da8a6a6d"),
                                    systemImage: "person.crop.circle.badge.plus",
                                    isSelected: selectedUserIDs.contains(user.id)
                                ) {
                                    toggleUserSelection(user.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                }
            }

            if let forwardErrorMessage {
                Label(forwardErrorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 8)
            }

            Divider()

            HStack {
                Text(selectedTargetCount == 0
                    ? L10n.string("ui.4b7a63cb61fc5c74")
                    : L10n.string("ui.2b1630ff83287eb8", String(describing: selectedTargetCount)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                Button {
                    Task {
                        forwardErrorMessage = nil
                        let succeeded = await model.forwardMessages(
                            ids: messageIDs,
                            to: selectedConversationIDs,
                            newDirectUserIDs: selectedUserIDs
                        )
                        if succeeded {
                            onComplete()
                            dismiss()
                        } else {
                            forwardErrorMessage = model.statusMessage
                                ?? L10n.string("ui.b72286c6d758db40")
                        }
                    }
                } label: {
                    if model.isPerformingAction {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L10n.string("ui.02107ba378e21710"), systemImage: "arrowshape.turn.up.right")
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(selectedTargetCount == 0 || model.isPerformingAction)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
        }
        .frame(minWidth: 480, idealWidth: 520, minHeight: 480, idealHeight: 600)
        .background(MacGlassSurface(role: .sidebar))
    }

    private func recipientSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .accessibilityAddTraits(.isHeader)
    }

    private func recipientButton(
        title: String,
        subtitle: String,
        systemImage: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(
                isSelected ? Color.accentColor.opacity(0.10) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            L10n.string(
                "chat.target.accessibility",
                title,
                subtitle,
                isSelected ? L10n.string("selection.selected") : L10n.string("selection.not_selected")
            )
        )
        .accessibilityValue(isSelected ? L10n.string("ui.3f4ebc4aad9793b6") : L10n.string("ui.1182c5454f113db5"))
    }

    private func toggleConversationSelection(_ id: String) {
        if selectedConversationIDs.contains(id) {
            selectedConversationIDs.remove(id)
        } else {
            selectedConversationIDs.insert(id)
        }
    }

    private func toggleUserSelection(_ id: String) {
        if selectedUserIDs.contains(id) {
            selectedUserIDs.remove(id)
        } else {
            selectedUserIDs.insert(id)
        }
    }
}

struct GroupMembersSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ChatWorkspaceModel
    let conversation: ChatConversation

    var body: some View {
        VStack(spacing: 0) {
            sheetHeader(
                title: L10n.string("ui.9d8692671d208b74"),
                subtitle: L10n.string("ui.11d084f57f81c408", String(describing: conversation.title), String(describing: model.conversationMembers.count))
            )
            Divider()

            if model.isLoadingConversationMembers {
                ProgressView(L10n.string("ui.82c870073f68d0ca"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.conversationMemberLoadError {
                retryState(
                    title: L10n.string("ui.2237485372f84189"),
                    message: error,
                    systemImage: "person.2.slash"
                ) {
                    Task { await model.loadConversationMembers() }
                }
            } else if model.conversationMembers.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.2b66ff22025ce6d0"),
                    systemImage: "person.2",
                    description: Text(L10n.string("ui.11cf9b18b7bf28d2"))
                )
                .fillsAvailableContentArea()
            } else {
                List(model.conversationMembers) { member in
                    HStack(spacing: 12) {
                        ChatAvatar(name: member.displayName, imageData: member.avatarData, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName)
                                .font(.body.weight(.medium))
                            if member.isCurrentUser == true {
                                Text(L10n.string("ui.a0c7716669b5ded0"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if member.isDisabled {
                            Text(L10n.string("ui.a8c3698b5b8c485d"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 460, minHeight: 420)
        .scrollContentBackground(.hidden)
        .background(MacGlassSurface(role: .sidebar))
        .task { await model.loadConversationMembers() }
    }

    private func sheetHeader(title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title2.bold())
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L10n.string("ui.c0b3fbff51ccc40b")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
        .buttonStyle(MacToolbarButtonStyle())
        .background(MacGlassSurface(role: .toolbar))
    }

    private func retryState(
        title: String,
        message: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            Button(L10n.string("ui.b8784c8dd5636ff2"), action: action)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PinnedMessagesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ChatWorkspaceModel
    let conversation: ChatConversation

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("ui.99728d0e0224c355"))
                        .font(.title2.bold())
                    Text(conversation.title)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("ui.c0b3fbff51ccc40b")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
            Divider()

            if model.isLoadingPinnedMessages {
                ProgressView(L10n.string("ui.45cfae641f1cd044"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.pinnedMessageLoadError {
                ContentUnavailableView {
                    Label(L10n.string("ui.d93afe72592b384f"), systemImage: "pin.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button(L10n.string("ui.b8784c8dd5636ff2")) {
                        Task { await model.loadPinnedMessages() }
                    }
                }
                .fillsAvailableContentArea()
            } else if model.pinnedMessages.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.7b938afe1c9cbc79"),
                    systemImage: "pin",
                    description: Text(L10n.string("ui.2abb6d1e3b1abe9e"))
                )
                .fillsAvailableContentArea()
            } else {
                List(model.pinnedMessages) { message in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(messageSummary(message))
                                .lineLimit(3)
                            HStack(spacing: 6) {
                                Text(message.senderDisplayName ?? model.displayName(for: message.senderID) ?? L10n.string("ui.9d8692671d208b74"))
                                if let pinnedAt = message.pinnedAt {
                                    Text("·")
                                    Text(Self.formatter.string(from: pinnedAt))
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task {
                                _ = await model.setMessagePinned(message, isPinned: false)
                            }
                        } label: {
                            Label(L10n.string("ui.02bf53bf7b24aff8"), systemImage: "pin.slash")
                                .labelStyle(.iconOnly)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.string("ui.02bf53bf7b24aff8"))
                        .accessibilityLabel(L10n.string("ui.02bf53bf7b24aff8"))
                        .disabled(model.isPerformingAction)
                    }
                    .padding(.vertical, 5)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .scrollContentBackground(.hidden)
        .background(MacGlassSurface(role: .sidebar))
        .task { await model.loadPinnedMessages() }
    }

    private func messageSummary(_ message: ChatMessage) -> String {
        if let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let attachment = message.attachments.first {
            return L10n.string("ui.b04b74f55264f515", String(describing: attachment.fileName))
        }
        return L10n.string("ui.ea0959a31f383a54")
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

struct ScheduledMessageComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ChatWorkspaceModel
    let conversation: ChatConversation
    @State private var text = ""
    @State private var sendAt = Date().addingTimeInterval(3_600)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("ui.33e4b16591ac7cba"))
                        .font(.title2.bold())
                    Text(L10n.string("ui.21fd7ed36d3cd598", String(describing: conversation.title)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField(L10n.string("ui.387278213e791913"), text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .textFieldStyle(.roundedBorder)

                    DatePicker(
                        L10n.string("ui.4b474d377140ad84"),
                        selection: $sendAt,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.field)

                    Text(L10n.string("ui.8eab5ec981463240"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button {
                    Task {
                        if await model.createScheduledMessage(text: text, sendAt: sendAt) {
                            dismiss()
                        }
                    }
                } label: {
                    if model.isPerformingAction {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.string("ui.5246400327a69731"))
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(
                    text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || sendAt <= Date()
                        || model.isPerformingAction
                )
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(MacGlassSurface(role: .toolbar))
        }
        .frame(minWidth: 460, minHeight: 300)
        .background(MacGlassSurface(role: .sidebar))
    }
}

struct ScheduledMessageListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ChatWorkspaceModel
    @State private var pendingDeletion: ChatScheduledMessage?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.582feae291691f33"))
                    .font(.title2.bold())
                Spacer()
                Button(L10n.string("ui.c0b3fbff51ccc40b")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
            Divider()

            if model.isLoadingScheduledMessages {
                ProgressView(L10n.string("ui.9ccea420a6e6866f"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.scheduledMessageLoadError {
                ContentUnavailableView {
                    Label(L10n.string("ui.e9a0f7a382024630"), systemImage: "clock.badge.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button(L10n.string("ui.b8784c8dd5636ff2")) {
                        Task { await model.loadScheduledMessages() }
                    }
                }
                .fillsAvailableContentArea()
            } else if model.scheduledMessages.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.ed8995abb028578c"),
                    systemImage: "clock",
                    description: Text(L10n.string("ui.9b05e363d99f9af4"))
                )
                .fillsAvailableContentArea()
            } else {
                List(model.scheduledMessages) { scheduled in
                    HStack(spacing: 12) {
                        Image(systemName: "clock.badge.checkmark")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(scheduled.text)
                                .lineLimit(2)
                            Text(Self.formatter.string(from: scheduled.sendAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pendingDeletion = scheduled
                        } label: {
                            Label(L10n.string("ui.4a9551f5bd002309"), systemImage: "xmark.circle")
                                .labelStyle(.iconOnly)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.string("ui.4a9551f5bd002309"))
                        .accessibilityLabel(L10n.string("ui.4a9551f5bd002309"))
                        .disabled(model.isPerformingAction)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
        .scrollContentBackground(.hidden)
        .background(MacGlassSurface(role: .sidebar))
        .task { await model.loadScheduledMessages() }
        .alert(L10n.string("ui.a4b22aa18e0da772"), isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button(L10n.string("ui.36745810fb80f3eb"), role: .cancel) { pendingDeletion = nil }
            Button(L10n.string("ui.554bfa5fa81c82cb"), role: .destructive) {
                guard let scheduled = pendingDeletion else { return }
                pendingDeletion = nil
                Task { _ = await model.deleteScheduledMessage(id: scheduled.id) }
            }
        } message: {
            Text(L10n.string("ui.25a625319ec21c9b"))
        }
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

struct ReminderEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ChatWorkspaceModel
    let message: ChatMessage
    @State private var remindAt = Date().addingTimeInterval(3_600)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.reminder(for: message.id) == nil ? L10n.string("ui.b505f2e67d2915cf") : L10n.string("ui.a1515bb44f9169e6"))
                        .font(.title2.bold())
                    Text(message.text?.isEmpty == false ? message.text! : L10n.string("ui.402c881d6d0b5320"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DatePicker(
                        L10n.string("ui.98b552661af4ee50"),
                        selection: $remindAt,
                        in: Date()...,
                        displayedComponents: [.date, .hourAndMinute]
                    )
                    .datePickerStyle(.field)

                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                if model.reminder(for: message.id) != nil {
                    Button(L10n.string("ui.74b01f2e5a7e5b67"), role: .destructive) {
                        Task {
                            if await model.deleteReminder(messageID: message.id) {
                                dismiss()
                            }
                        }
                    }
                    .disabled(model.isPerformingAction)
                }
                Spacer()
                Button {
                    Task {
                        if await model.setReminder(messageID: message.id, remindAt: remindAt) {
                            dismiss()
                        }
                    }
                } label: {
                    if model.isPerformingAction {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.string("ui.e1be3a5c3ec6c09b"))
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(remindAt <= Date() || model.isPerformingAction)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
        }
        .frame(minWidth: 420, minHeight: 220)
        .background(MacGlassSurface(role: .sidebar))
        .onAppear {
            if let existing = model.reminder(for: message.id) {
                remindAt = max(existing.remindAt, Date().addingTimeInterval(60))
            }
        }
    }
}

struct ReminderListSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ChatWorkspaceModel
    @State private var pendingDeletion: ChatReminder?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.03671d6ddf237f70"))
                    .font(.title2.bold())
                Spacer()
                Button(L10n.string("ui.c0b3fbff51ccc40b")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))
            Divider()

            if model.isLoadingReminders {
                ProgressView(L10n.string("ui.482e8b32018b86a4"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.reminderLoadError {
                ContentUnavailableView {
                    Label(L10n.string("ui.db9f66b5649c8570"), systemImage: "bell.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button(L10n.string("ui.b8784c8dd5636ff2")) {
                        Task { await model.loadReminders() }
                    }
                }
                .fillsAvailableContentArea()
            } else if model.reminders.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.b95a48f81673658c"),
                    systemImage: "bell.slash",
                    description: Text(L10n.string("ui.a6e6b58600449352"))
                )
                .fillsAvailableContentArea()
            } else {
                List(model.reminders) { reminder in
                    HStack(spacing: 12) {
                        Image(systemName: "bell.fill")
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(messageSummary(for: reminder))
                                .lineLimit(2)
                            Text(Self.formatter.string(from: reminder.remindAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) {
                            pendingDeletion = reminder
                        } label: {
                            Label(L10n.string("ui.f3b07169f705a135"), systemImage: "bell.slash")
                                .labelStyle(.iconOnly)
                                .frame(width: 28, height: 28)
                        }
                        .buttonStyle(.borderless)
                        .help(L10n.string("ui.f3b07169f705a135"))
                        .accessibilityLabel(L10n.string("ui.f3b07169f705a135"))
                        .disabled(model.isPerformingAction)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 360)
        .scrollContentBackground(.hidden)
        .background(MacGlassSurface(role: .sidebar))
        .task { await model.loadReminders() }
        .alert(L10n.string("ui.b755927d881bc4f6"), isPresented: Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )) {
            Button(L10n.string("ui.b4c72ea3ea038146"), role: .cancel) { pendingDeletion = nil }
            Button(L10n.string("ui.f3b07169f705a135"), role: .destructive) {
                guard let reminder = pendingDeletion else { return }
                pendingDeletion = nil
                Task { _ = await model.deleteReminder(messageID: reminder.messageID) }
            }
        } message: {
            Text(L10n.string("ui.00e7cde017aeb344"))
        }
    }

    private func messageSummary(for reminder: ChatReminder) -> String {
        guard let message = model.messages.first(where: { $0.id == reminder.messageID }) else {
            return L10n.string("ui.b8c17ea4bc20f1ae")
        }
        return message.text?.isEmpty == false
            ? message.text!
            : message.attachments.first?.fileName ?? L10n.string("ui.b8c17ea4bc20f1ae")
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

struct CreatePollSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ChatWorkspaceModel
    let conversation: ChatConversation
    @State private var question = ""
    @State private var options = ["", ""]
    @State private var allowsMultipleSelection = false
    @State private var isAnonymous = false
    @FocusState private var focusedField: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string("ui.54f9e511a851c7da"))
                        .font(.title2.bold())
                    Text(L10n.string("ui.21fd7ed36d3cd598", String(describing: conversation.title)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(20)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar))

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TextField(L10n.string("ui.9717eea92267e626"), text: $question, axis: .vertical)
                        .lineLimit(1...3)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("ui.bb7486f4410fd370"))
                            .font(.headline)
                        ForEach(options.indices, id: \.self) { index in
                            HStack {
                                TextField(L10n.string("ui.042274cf3d451290", String(describing: index + 1)), text: $options[index])
                                    .focused($focusedField, equals: index)
                                if options.count > 2 {
                                    Button {
                                        options.remove(at: index)
                                    } label: {
                                        Label(L10n.string("ui.c484cd17875d55d1", String(describing: index + 1)), systemImage: "minus.circle")
                                            .labelStyle(.iconOnly)
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        if options.count < 10 {
                            Button {
                                options.append("")
                                focusedField = options.count - 1
                            } label: {
                                Label(L10n.string("ui.d063937855cf99a7"), systemImage: "plus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    Toggle(L10n.string("ui.1fddd507a67e1366"), isOn: $allowsMultipleSelection)
                    Toggle(L10n.string("ui.55edffe99178b192"), isOn: $isAnonymous)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text(L10n.string("ui.83abddba8f54950a"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task {
                        if await model.createPoll(
                            question: question,
                            options: options,
                            allowsMultipleSelection: allowsMultipleSelection,
                            isAnonymous: isAnonymous
                        ) {
                            dismiss()
                        }
                    }
                } label: {
                    if model.isPerformingAction {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(L10n.string("ui.82c4fa27cdb5f875"))
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(!canSubmit || model.isPerformingAction)
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(MacGlassSurface(role: .toolbar))
        }
        .frame(minWidth: 460, minHeight: 390)
        .background(MacGlassSurface(role: .sidebar))
    }

    private var canSubmit: Bool {
        let normalizedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedOptions = options
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let canonical = normalizedOptions.map { $0.lowercased() }
        return !normalizedQuestion.isEmpty
            && normalizedOptions.count >= 2
            && Set(canonical).count == normalizedOptions.count
    }
}

private struct ChatMessageRow: View {
    let message: ChatMessage
    let users: [ChatUser]
    let isCurrentUser: Bool
    let showsSender: Bool
    let isSelected: Bool
    let failureMessage: String?
    let uploadProgress: Double?
    let downloadProgress: Double?
    let thumbnailData: Data?
    let canDownloadAttachments: Bool
    let onCancel: () -> Void
    let onRetry: () -> Void
    let onCancelDownload: () -> Void
    let onLoadThumbnail: (ChatAttachment) -> Void
    let onPreviewImage: (ChatAttachment) -> Void
    let onSaveAttachment: (ChatAttachment) -> Void

    private var senderName: String {
        if isCurrentUser { return L10n.string("ui.a0c7716669b5ded0") }
        return message.senderDisplayName
            ?? users.first(where: { $0.id == message.senderID })?.displayName
            ?? L10n.string("ui.4b947c53d3a318fa", String(describing: message.senderID))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if isCurrentUser { Spacer(minLength: 72) }

            VStack(alignment: isCurrentUser ? .trailing : .leading, spacing: 6) {
                metadata
                messageBubble
                deliveryStatus
            }
            .frame(maxWidth: 560, alignment: isCurrentUser ? .trailing : .leading)

            if !isCurrentUser { Spacer(minLength: 72) }
        }
        .frame(maxWidth: .infinity, alignment: isCurrentUser ? .trailing : .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            isSelected ? Color.accentColor.opacity(0.09) : Color.clear,
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(alignment: isCurrentUser ? .topLeading : .topTrailing) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .background(Color(nsColor: .textBackgroundColor), in: Circle())
                    .padding(8)
                    .accessibilityHidden(true)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.65), lineWidth: 1)
            }
        }
        .accessibilityElement(children: message.attachments.isEmpty ? .combine : .contain)
        .accessibilityLabel(
            L10n.string(
                "chat.message.accessibility",
                senderName,
                Self.fullDateTimeFormatter.string(from: message.sentAt),
                deliveryAccessibilityText
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            if !isCurrentUser {
                senderAvatar
                if showsSender || message.senderID == "unknown" {
                    Text(senderName)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 4) {
                Text(Self.fullDateTimeFormatter.string(from: message.sentAt))
                    .monospacedDigit()
                if message.encryptionState == .unlocked {
                    Image(systemName: "lock.fill")
                        .accessibilityLabel(L10n.string("ui.aed642276d2b2cc9"))
                }
                if message.isPinned {
                    Image(systemName: "pin.fill")
                        .accessibilityLabel(L10n.string("ui.99728d0e0224c355"))
                }
            }

            if isCurrentUser {
                Text(L10n.string("ui.a0c7716669b5ded0"))
                    .fontWeight(.semibold)
                senderAvatar
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var senderAvatar: some View {
        ChatAvatar(
            name: senderName,
            imageData: users.first(where: {
                isCurrentUser ? $0.isCurrentUser == true : $0.id == message.senderID
            })?.avatarData,
            size: 24
        )
    }

    private var messageBubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let text = message.text {
                Text(text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(message.attachments) { attachment in
                attachmentCard(attachment)
            }

            if let poll = message.poll {
                VStack(alignment: .leading, spacing: 7) {
                    Text(poll.question)
                        .font(.headline)
                    ForEach(poll.options) { option in
                        Label(
                            L10n.string("ui.1fcd1b2f7b5527d9", String(describing: option.text), String(describing: option.voteCount)),
                            systemImage: option.isSelectedByCurrentUser ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.callout)
                    }
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .foregroundStyle(isCurrentUser ? Color.white : Color.primary)
        .background(
            isCurrentUser ? Color.accentColor : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            if !isCurrentUser {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
            }
        }
        .help(Self.fullDateTimeFormatter.string(from: message.sentAt))
    }

    private func attachmentCard(_ attachment: ChatAttachment) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if canDownloadAttachments,
               attachment.kind == .image,
               let thumbnailData,
               let image = NSImage(data: thumbnailData) {
                Button {
                    onPreviewImage(attachment)
                } label: {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300, maxHeight: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(L10n.string("ui.e201b318efc4814d", String(describing: attachment.fileName)))
                .accessibilityLabel(L10n.string("ui.d4c051bc4e2432c0", String(describing: attachment.fileName)))
            }
            HStack(spacing: 8) {
                Label(attachment.fileName, systemImage: attachmentIcon(attachment.kind))
                    .font(.callout)
                    .lineLimit(2)
                if canDownloadAttachments {
                    Spacer(minLength: 8)
                    Button {
                        onSaveAttachment(attachment)
                    } label: {
                        Label(L10n.string("ui.f6c71ae760ba11e7"), systemImage: "square.and.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .help(L10n.string("ui.a985840bfc1565dd"))
                    .accessibilityLabel(L10n.string("ui.a985840bfc1565dd"))
                }
            }
            if let downloadProgress {
                HStack(spacing: 8) {
                    ProgressView(value: downloadProgress)
                        .progressViewStyle(.linear)
                        .accessibilityLabel(L10n.string("ui.78be84b1df57bc4e"))
                        .accessibilityValue("\(Int((downloadProgress * 100).rounded()))%")
                    Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancelDownload)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: 380)
        .padding(9)
        .background(
            isCurrentUser ? Color.white.opacity(0.16) : Color(nsColor: .windowBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .task(id: message.id) {
            if canDownloadAttachments, attachment.kind == .image, thumbnailData == nil {
                onLoadThumbnail(attachment)
            }
        }
    }

    @ViewBuilder
    private var deliveryStatus: some View {
        if message.deliveryState == .sending {
            VStack(alignment: .trailing, spacing: 5) {
                if let uploadProgress {
                    ProgressView(value: uploadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 140)
                        .accessibilityLabel(L10n.string("ui.09ea0803f63d0de2"))
                        .accessibilityValue("\(Int((uploadProgress * 100).rounded()))%")
                }
                HStack(spacing: 7) {
                    if uploadProgress == nil {
                        ProgressView()
                            .controlSize(.mini)
                    }
                    Text(uploadProgress.map { L10n.string("ui.9e26bbb23d1672d3", String(describing: Int(($0 * 100).rounded()))) } ?? L10n.string("ui.2d88d503d0ffb609"))
                    Button(L10n.string("ui.2cd0f3be8738a86c"), action: onCancel)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        } else if message.deliveryState == .failed {
            VStack(alignment: .trailing, spacing: 4) {
                Label(L10n.string("ui.ac77953a1e064ed6"), systemImage: "exclamationmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                if let failureMessage {
                    Text(failureMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                }
                Button(L10n.string("ui.9287ac799e545bb0"), action: onRetry)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }

    private var deliveryAccessibilityText: String {
        switch message.deliveryState {
        case .sending: L10n.string("ui.2d88d503d0ffb609")
        case .sent: L10n.string("ui.60823aaec73bd5db")
        case .failed: L10n.string("ui.ac77953a1e064ed6")
        }
    }

    private static var fullDateTimeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }

    private func attachmentIcon(_ kind: ChatAttachmentKind) -> String {
        switch kind {
        case .image: "photo"
        case .video: "film"
        case .file: "doc"
        case .voice: "waveform"
        }
    }
}

private struct ChatAvatar: View {
    let name: String
    var imageData: Data? = nil
    var size: CGFloat = 30

    var body: some View {
        Group {
            if let imageData, let image = NSImage(data: imageData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.14))
                    Text(String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased())
                        .font(.system(size: max(10, size * 0.4), weight: .semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .accessibilityHidden(true)
    }
}

private struct ChatDateSeparator: View {
    let date: Date

    var body: some View {
        HStack(spacing: 10) {
            Rectangle().fill(.separator).frame(height: 1)
            Text(Self.formatter.string(from: date))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle().fill(.separator).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMMMEEEEd")
        return formatter
    }
}

struct NewChatSheet: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case direct
        case group

        var id: Self { self }
        var title: String { self == .direct ? L10n.string("ui.a3e47aadd86c332b") : L10n.string("ui.35b49ee58a4a0e82") }
    }

    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ChatWorkspaceModel
    @State private var mode: Mode = .direct
    @State private var selectedUserIDs: Set<String> = []
    @State private var groupTitle = ""
    @State private var createsEncryptedConversation = false
    @State private var userSearchText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L10n.string("ui.08d90be0bab08c36"))
                    .font(.title2.bold())
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            .buttonStyle(MacToolbarButtonStyle())
            .background(MacGlassSurface(role: .toolbar).clipShape(RoundedRectangle(cornerRadius: 12)))

            Picker(L10n.string("ui.4821f9f7af0425b0"), selection: $mode) {
                ForEach(availableModes) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            if mode == .group {
                TextField(L10n.string("ui.12633e741c9ab2ed"), text: $groupTitle)
                Text(L10n.string("ui.b97d05b835c3cfc8"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(L10n.string("ui.64291b91ee7e76d4"), text: $userSearchText)
                    .textFieldStyle(.plain)
                if !userSearchText.isEmpty {
                    Button {
                        userSearchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L10n.string("ui.5c5418a623489e17"))
                    .help(L10n.string("ui.ee32f25f70508f9c"))
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))

            if filteredUsers.isEmpty {
                ContentUnavailableView {
                    Label(userSearchText.isEmpty ? L10n.string("ui.b7b405d8cf32c2de") : L10n.string("ui.77936eef94b251bd"), systemImage: "person.crop.circle.badge.questionmark")
                } description: {
                    Text(
                        userSearchText.isEmpty
                            ? L10n.string("ui.42107622c9bbf85c")
                            : L10n.string("ui.4e6788f38e6553a5")
                    )
                }
                .frame(minHeight: 80, maxHeight: .infinity)
            } else {
                List(filteredUsers) { user in
                    Button {
                        toggleSelection(for: user.id)
                    } label: {
                        HStack(spacing: 10) {
                            ChatAvatar(name: user.displayName, imageData: user.avatarData)
                            Text(user.displayName)
                            Spacer()
                            if selectedUserIDs.contains(user.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .contentShape(Rectangle())
                        .frame(minHeight: 34)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(user.displayName)
                    .accessibilityValue(selectedUserIDs.contains(user.id) ? L10n.string("ui.3f4ebc4aad9793b6") : L10n.string("ui.1182c5454f113db5"))
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80, maxHeight: .infinity)
            }

            if mode == .group,
               model.availability.supportedFeatures.contains(.encryptedConversation) {
                Toggle(L10n.string("ui.d33475f3928dbe36"), isOn: $createsEncryptedConversation)
            }

            HStack {
                if model.users.isEmpty {
                    Label(L10n.string("ui.dfdb295f749db3a5"), systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    createConversation()
                } label: {
                    if model.isPerformingAction {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text(mode == .direct ? L10n.string("ui.b263cff274346402") : L10n.string("ui.675ee6eef7be449d"))
                    }
                }
                .buttonStyle(MacToolbarButtonStyle(prominent: true))
                .disabled(!canSubmit || model.isPerformingAction)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 460)
        .background(MacGlassSurface(role: .sidebar))
        .onChange(of: mode) { _, _ in
            selectedUserIDs = []
            createsEncryptedConversation = false
            userSearchText = ""
        }
        .onAppear {
            if !availableModes.contains(mode), let firstMode = availableModes.first {
                mode = firstMode
            }
        }
    }

    private var availableModes: [Mode] {
        var modes: [Mode] = []
        if model.canCreateDirectConversation { modes.append(.direct) }
        if model.canCreateGroupConversation { modes.append(.group) }
        return modes
    }

    private var canSubmit: Bool {
        switch mode {
        case .direct:
            selectedUserIDs.count == 1
        case .group:
            selectedUserIDs.count >= 2
                && !groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var filteredUsers: [ChatUser] {
        let candidates = model.users.filter { $0.isCurrentUser != true }
        let query = userSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return candidates }
        return candidates.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    private func createConversation() {
        Task {
            let succeeded: Bool
            switch mode {
            case .direct:
                guard let userID = selectedUserIDs.first else { return }
                succeeded = await model.openDirectConversation(userID: userID)
            case .group:
                succeeded = await model.createGroup(
                    title: groupTitle,
                    memberIDs: Array(selectedUserIDs),
                    isEncrypted: createsEncryptedConversation
                )
            }
            if succeeded { dismiss() }
        }
    }

    private func toggleSelection(for userID: String) {
        if selectedUserIDs.contains(userID) {
            selectedUserIDs.remove(userID)
        } else if mode == .direct {
            selectedUserIDs = [userID]
        } else {
            selectedUserIDs.insert(userID)
        }
    }
}
