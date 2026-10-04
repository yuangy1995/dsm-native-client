import DsmCore
import DsmLocalization
import Foundation
import SwiftUI
import UIKit

struct MobileChatView: View {
    @Bindable var model: MobileAppModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var availableWidth: CGFloat = 0
    @State private var presentsConversationManagement = false
    @State private var managementDismissalGeneration = 0
    @State private var presentsConversationCreator = false
    @State private var presentedConversation: ChatConversation?
    @State private var presentsMessageSearch = false
    @State private var presentsForwardRecords = false
    @State private var presentsDeletionRecords = false
    @State private var presentsSendRecords = false
    @State private var presentsVoiceRecorder = false
    @State private var notificationDestination: MobileChatNotifications.Destination?

    var body: some View {
        ZStack {
            if usesColumns {
                regularLayout(conversation: nil)
            } else {
                compactLayout
            }
        }
        .background(MobileChatViewportWidth { availableWidth = $0 })
        .onChange(of: model.chatModel.activeProfileID) { _, _ in presentedConversation = nil }
        .mobileChatAudioLifecycle(chat: model.chatModel)
        .task(id: model.chatModel.notifications.destination) {
            if let destination = model.chatModel.notifications.destination {
                notificationDestination = destination
                model.chatModel.notifications.clearDestination()
            }
        }
        .sheet(item: $notificationDestination) { destination in
            MobileChatNotificationMessageView(chat: model.chatModel, destination: destination)
        }
        .toolbar {
            if let sending = model.chatModel.sending, (!sending.entries.isEmpty || sending.recovery.failed), model.chatModel.state.visibleConversationID == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { presentsSendRecords = true } label: { Image(systemName: "paperplane").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("mobile.chat.send.records")).accessibilityIdentifier("chat-send-records")
                }
            }
            if let deletion = model.chatModel.deletion, (!deletion.entries.isEmpty || deletion.recovery.failed), model.chatModel.state.visibleConversationID == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { presentsDeletionRecords = true } label: { Image(systemName: "trash").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("mobile.chat.deletion.records")).accessibilityIdentifier("chat-deletion-records")
                }
            }
            if let forwarding = model.chatModel.forwarding, (!forwarding.entries.isEmpty || forwarding.recovery.failed), model.chatModel.state.visibleConversationID == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { presentsForwardRecords = true } label: { Image(systemName: "arrowshape.turn.up.right").frame(width: 44, height: 44) }
                        .accessibilityLabel(L10n.string("mobile.chat.forward.records")).accessibilityIdentifier("chat-forward-records")
                }
            }
            if model.chatModel.management?.canManageConversations == true, model.chatModel.state.visibleConversationID == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { presentsConversationManagement = true } label: {
                        Image(systemName: "checklist").frame(width: 44, height: 44)
                    }.accessibilityLabel(L10n.string("mobile.chat.close.manage")).accessibilityIdentifier("chat-manage-conversations")
                }
            }
            if model.chatModel.interaction?.canSearch == true, model.chatModel.state.visibleConversationID == nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { presentsMessageSearch = true } label: {
                        Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.string("chat.search.title"))
                    .accessibilityIdentifier("chat-search-all")
                }
            }
            if model.chatModel.canCreateConversation {
                ToolbarItem(placement: .topBarTrailing) {
                    let hasPending = model.chatModel.conversationCreator?.requiresReview == true
                    Button {
                        presentsConversationCreator = true
                    } label: {
                        Image(systemName: hasPending ? "arrow.clockwise" : "square.and.pencil")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.string(hasPending ? "mobile.chat.create.review.action" : "mobile.chat.create.action"))
                    .accessibilityHint(L10n.string(hasPending ? "mobile.chat.create.review.message" : "mobile.chat.create.hint"))
                    .accessibilityIdentifier("chat-create-conversation")
                }
            }
        }
        .sheet(isPresented: $presentsConversationManagement, onDismiss: { managementDismissalGeneration &+= 1 }) {
            if let management = model.chatModel.management {
                MobileChatConversationManagementSheet(chat: model.chatModel, management: management)
                    .id(ObjectIdentifier(management))
            }
        }
        .sheet(isPresented: $presentsVoiceRecorder) { MobileChatVoiceSheet(chat: model.chatModel) }
        .sheet(isPresented: $presentsSendRecords) {
            if let sending = model.chatModel.sending {
                MobileChatSendRecordsSheet(sending: sending, conversations: model.chatModel.state.conversations).id(ObjectIdentifier(sending))
            }
        }
        .sheet(isPresented: $presentsDeletionRecords) {
            if let deletion = model.chatModel.deletion {
                MobileChatDeletionRecordsSheet(deletion: deletion).id(ObjectIdentifier(deletion))
            }
        }
        .sheet(isPresented: $presentsForwardRecords) {
            if let forwarding = model.chatModel.forwarding {
                MobileChatForwardRecordsSheet(forwarding: forwarding).id(ObjectIdentifier(forwarding))
            }
        }
        .sheet(isPresented: $presentsMessageSearch) {
            if let interaction = model.chatModel.interaction {
                MobileChatSearchSheet(chat: model.chatModel, interaction: interaction, conversationID: nil)
            }
        }
        .sheet(isPresented: $presentsConversationCreator) {
            if let creator = model.chatModel.conversationCreator,
               let sourceProfileID = model.chatModel.activeProfileID {
                let sourceGeneration = creator.repositoryGeneration
                MobileChatConversationCreatorSheet(creator: creator) { conversation in
                    let accepted = await model.chatModel.acceptCreatedConversation(
                        conversation,
                        sourceProfileID: sourceProfileID,
                        sourceCreator: creator,
                        sourceGeneration: sourceGeneration
                    )
                    if accepted {
                        presentedConversation = conversation
                    }
                    return accepted
                }
                .id(ObjectIdentifier(creator))
            }
        }
        .navigationDestination(item: $presentedConversation) { conversation in
            ZStack {
                if usesColumns { regularLayout(conversation: conversation) }
                else { messageDetail(conversation) }
            }
            .navigationTitle(conversation.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(usesColumns)
            .background(MobileChatViewportWidth { availableWidth = $0 })
        }
    }

    private var compactLayout: some View {
        conversationList.accessibilityIdentifier("chat-single-column")
    }

    private var usesColumns: Bool {
        horizontalSizeClass == .regular && availableWidth >= 760 && !dynamicTypeSize.isAccessibilitySize
    }

    private func regularLayout(conversation: ChatConversation?) -> some View {
        HStack(spacing: 0) {
            conversationList
                .frame(width: min(320, availableWidth * 0.36))
            Divider()
            regularMessageDetail(conversation)
        }
        .accessibilityIdentifier("chat-two-columns")
    }

    @ViewBuilder
    private func regularMessageDetail(_ conversation: ChatConversation?) -> some View {
        if let conversation {
            messageDetail(conversation)
        } else {
            ContentUnavailableView(
                L10n.string("mobile.chat.select.title"),
                systemImage: "bubble.left.and.bubble.right",
                description: Text(L10n.string("mobile.chat.select.message"))
            )
            .fillsAvailableContentArea()
        }
    }

    private func messageDetail(_ conversation: ChatConversation) -> some View {
        MobileChatMessagesView(chat: model.chatModel, conversation: conversation,
            manageConversations: { presentsConversationManagement = true }, isManagingConversations: presentsConversationManagement,
            managementDismissalGeneration: managementDismissalGeneration,
            recordVoice: { presentsVoiceRecorder = true }, preservesVoiceRecording: $presentsVoiceRecorder)
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
        if usesColumns {
            Button {
                presentedConversation = conversation
            } label: {
                MobileChatConversationRow(
                    conversation: conversation,
                    isSelected: presentedConversation?.id == conversation.id,
                    isPinned: isPinned
                )
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(
                presentedConversation?.id == conversation.id ? .isSelected : []
            )
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                conversationPinButton(conversation, isPinned: isPinned)
            }
        } else {
            Button { presentedConversation = conversation } label: {
                HStack {
                    MobileChatConversationRow(conversation: conversation, isSelected: false, isPinned: isPinned)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
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

/// 从当前可见的 UIKit 页面读取安全区域；导航根隐藏后不再依赖其旧布局宽度。
private struct MobileChatViewportWidth: UIViewRepresentable {
    let onWidth: (CGFloat) -> Void
    func makeUIView(context: Context) -> WidthView {
        let view = WidthView()
        view.isUserInteractionEnabled = false
        view.onWidth = onWidth
        return view
    }
    func updateUIView(_ view: WidthView, context: Context) { view.onWidth = onWidth; view.report() }
    final class WidthView: UIView {
        var onWidth: ((CGFloat) -> Void)?
        private var lastWidth: CGFloat?
        override func layoutSubviews() { super.layoutSubviews(); report() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        func report() {
            guard window != nil else { return }
            let width = safeAreaLayoutGuide.layoutFrame.width
            guard width > 0, width != lastWidth else { return }
            lastWidth = width
            Task { @MainActor [weak self] in
                guard let self, self.window != nil else { return }
                self.onWidth?(self.safeAreaLayoutGuide.layoutFrame.width)
            }
        }
    }
}

private struct MobileChatConversationCreatorSheet: View {
    @Bindable var creator: MobileChatConversationCreator
    let onCreated: @MainActor (ChatConversation) async -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .direct
    @State private var groupTitle = ""
    @State private var selectedUserIDs: Set<String> = []
    @State private var userSearchText = ""
    @State private var isSearching = false
    @State private var presentsGroupRecords = false

    var body: some View {
        NavigationStack {
            searchableContent
                .navigationTitle(L10n.string("mobile.chat.create.title"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !creator.groupEntries.isEmpty, creator.pendingDirectUserID == nil {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { presentsGroupRecords = true } label: { Image(systemName: "clock.arrow.circlepath").frame(width: 44, height: 44) }
                                .accessibilityLabel(L10n.string("mobile.chat.group.records"))
                                .accessibilityIdentifier("chat-group-records").disabled(creator.isSubmitting)
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("mobile.chat.create.close")) { dismiss() }
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(submitTitle) { Task { await submit() } }
                            .disabled(!canSubmit)
                            .frame(minWidth: 44, minHeight: 44)
                            .accessibilityIdentifier("chat-create-submit")
                    }
                }
        }
        .interactiveDismissDisabled(creator.isSubmitting)
        .sheet(isPresented: $presentsGroupRecords) {
            MobileChatGroupCreationRecordsSheet(creator: creator, onSelect: restorePendingDraft)
        }
        .task(id: creator.repositoryGeneration) {
            restorePendingDraft()
            if creator.pageState == .loading || creator.users.isEmpty {
                await creator.loadUsers()
            }
        }
    }

    @ViewBuilder
    private var searchableContent: some View {
        if creator.pageState == .content, !creator.requiresReview, !creator.isSubmitting, !creator.storageFailed {
            content.searchable(text: $userSearchText, isPresented: $isSearching,
                prompt: L10n.string("mobile.chat.create.search.placeholder"))
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if creator.storageFailed {
            ContentUnavailableView {
                Label(L10n.string("mobile.chat.create.storage-error.title"), systemImage: "exclamationmark.circle")
            } description: {
                Text(L10n.string("mobile.chat.interaction.storage-error"))
            }
            .fillsAvailableContentArea()
        } else if creator.isSubmitting {
            ProgressView(L10n.string("mobile.chat.create.opening"))
                .fillsAvailableContentArea()
        } else if creator.pendingIsGroup, let entry = creator.groupEntry {
            MobileChatGroupCreationProgressView(creator: creator, entry: entry, onOutcome: handleOutcome) {
                groupTitle = ""; selectedUserIDs = []; userSearchText = ""
                restorePendingDraft()
                if creator.users.isEmpty { Task { await creator.loadUsers() } }
            }
        } else if creator.requiresReview {
            ContentUnavailableView {
                Label(L10n.string("mobile.chat.create.review.title"), systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(L10n.string("mobile.chat.create.review.message"))
            }
            .fillsAvailableContentArea()
        } else {
            switch creator.pageState {
            case .loading:
                ProgressView(L10n.string("mobile.chat.create.loading"))
                    .fillsAvailableContentArea()
                    .accessibilityElement(children: .combine)
            case .empty:
                ContentUnavailableView {
                    Label(
                        L10n.string("mobile.chat.create.empty.title"),
                        systemImage: "person.crop.circle.badge.questionmark"
                    )
                } description: {
                    Text(L10n.string("mobile.chat.create.empty.message"))
                } actions: {
                    retryButton
                }
                .fillsAvailableContentArea()
            case .error:
                ContentUnavailableView {
                    Label(
                        L10n.string("mobile.chat.create.load-error.title"),
                        systemImage: "wifi.exclamationmark"
                    )
                } description: {
                    Text(L10n.string("mobile.chat.create.load-error.message"))
                } actions: {
                    retryButton
                }
                .fillsAvailableContentArea()
            case .content:
                if filteredUsers.isEmpty && !normalizedSearchText.isEmpty {
                    ContentUnavailableView {
                        Label(
                            L10n.string("mobile.chat.create.filtered-empty.title"),
                            systemImage: "person.crop.circle.badge.questionmark"
                        )
                    } description: {
                        Text(L10n.string("mobile.chat.create.filtered-empty.message"))
                    } actions: {
                        Button(L10n.string("mobile.chat.create.clear-search")) {
                            userSearchText = ""
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(minWidth: 44, minHeight: 44)
                    }
                    .fillsAvailableContentArea()
                } else {
                    creationForm
                }
            }
        }
    }

    private var creationForm: some View {
        Form {
            if creator.canCreateDirect && creator.canCreateGroup {
                Section(L10n.string("mobile.chat.create.type")) {
                    Picker(L10n.string("mobile.chat.create.type"), selection: $mode) {
                        if creator.canCreateDirect {
                            Text(L10n.string("mobile.chat.create.direct")).tag(Mode.direct)
                        }
                        if creator.canCreateGroup {
                            Text(L10n.string("mobile.chat.create.group")).tag(Mode.group)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(creator.isSubmitting || creator.requiresReview)
                }
            }

            if mode == .group {
                Section(L10n.string("mobile.chat.create.group-name")) {
                    TextField(
                        L10n.string("mobile.chat.create.group-name.placeholder"),
                        text: $groupTitle
                    )
                    .textInputAutocapitalization(.sentences)
                    .accessibilityIdentifier("chat-create-group-name")
                    .disabled(creator.isSubmitting || creator.requiresReview)
                }
            }

            Section(memberSectionTitle) {
                ForEach(filteredUsers) { user in
                    Button {
                        toggleSelection(user.id)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                            Text(user.displayName)
                                .foregroundStyle(.primary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            if selectedUserIDs.contains(user.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                                    .accessibilityHidden(true)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(creator.isSubmitting || creator.requiresReview)
                    .accessibilityLabel(user.displayName)
                    .accessibilityIdentifier("chat-create-user-\(user.id)")
                    .accessibilityAddTraits(
                        selectedUserIDs.contains(user.id) ? .isSelected : []
                    )
                }
            }

            if creator.errorCategory != nil {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                        .accessibilityElement(children: .combine)
                }
            }
        }
        .onChange(of: mode) { _, _ in
            guard !creator.requiresReview else { return }
            selectedUserIDs.removeAll()
        }
    }

    private var retryButton: some View {
        Button(L10n.string("mobile.chat.create.retry")) {
            Task { await creator.loadUsers() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(minWidth: 44, minHeight: 44)
    }

    private var normalizedSearchText: String {
        userSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredUsers: [ChatUser] {
        guard !normalizedSearchText.isEmpty else { return creator.users }
        return creator.users.filter {
            $0.displayName.localizedStandardContains(normalizedSearchText)
        }
    }

    private var canSubmit: Bool {
        guard !creator.isSubmitting, !creator.storageFailed else { return false }
        if let entry = creator.groupEntry { return entry.receipt != nil || creator.canContinueGroup }
        if creator.requiresReview { return true }
        guard creator.pageState == .content else { return false }
        return mode == .direct
            ? selectedUserIDs.count == 1
            : !groupTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && selectedUserIDs.count >= 2
    }

    private var submitTitle: String {
        if let entry = creator.groupEntry {
            return L10n.string(entry.receipt == nil ? "mobile.chat.group.continue" : "mobile.chat.group.refresh")
        }
        if creator.canResumeDirectCreation { return L10n.string("mobile.chat.create.open") }
        return L10n.string(
            creator.requiresReview
                ? "mobile.chat.create.review.action"
                : (mode == .direct ? "mobile.chat.create.open" : "mobile.chat.create.submit")
        )
    }

    private var memberSectionTitle: String {
        L10n.string(
            mode == .direct
                ? "mobile.chat.create.direct-member"
                : "mobile.chat.create.group-members"
        )
    }

    private var errorMessage: String {
        switch creator.errorCategory {
        case .permissionDenied:
            return L10n.string("mobile.chat.create.permission")
        case .authenticationRequired:
            return L10n.string("mobile.chat.create.authentication")
        case .apiUnavailable, .versionUnsupported:
            return L10n.string("mobile.chat.create.unsupported")
        default:
            return L10n.string("mobile.chat.create.failed")
        }
    }

    private func toggleSelection(_ userID: String) {
        if mode == .direct {
            selectedUserIDs = [userID]
            isSearching = false
        } else if selectedUserIDs.contains(userID) {
            selectedUserIDs.remove(userID)
        } else {
            selectedUserIDs.insert(userID)
        }
    }

    private func restorePendingDraft() {
        guard creator.requiresReview else {
            if !creator.canCreateDirect, creator.canCreateGroup { mode = .group }
            return
        }
        mode = creator.pendingIsGroup ? .group : .direct
        groupTitle = creator.pendingGroupTitle ?? ""
        selectedUserIDs = Set(
            creator.pendingIsGroup
                ? creator.pendingGroupMemberIDs
                : creator.pendingDirectUserID.map { [$0] } ?? []
        )
    }

    private func submit() async {
        if let entry = creator.groupEntry {
            await handleOutcome(entry.receipt == nil ? creator.continueGroup() : creator.refreshGroup())
            return
        }
        let outcome = mode == .direct
            ? await creator.openDirectConversation(userID: selectedUserIDs.first ?? "")
            : await creator.createGroup(
                title: groupTitle,
                memberIDs: Array(selectedUserIDs)
            )
        await handleOutcome(outcome)
    }

    private func handleOutcome(_ outcome: ChatConversationCreateOutcome?) async {
        guard outcome?.result.status == .confirmedSuccess,
              let conversation = outcome?.confirmedConversation else { return }
        if await onCreated(conversation) {
            dismiss()
        }
    }

    private enum Mode: Hashable {
        case direct
        case group
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
        .accessibilityIdentifier("chat-conversation-\(conversation.id)")
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
    let manageConversations: () -> Void
    let isManagingConversations: Bool
    let managementDismissalGeneration: Int
    let recordVoice: () -> Void
    @Binding var preservesVoiceRecording: Bool
    @State private var visibilityOwner = UUID()
    @Environment(\.dismiss) private var dismiss
    @State private var presentsMembers = false
    @State private var presentsAnnouncements = false
    @State private var presentsMessageSearch = false
    @State private var presentsPollCreation = false
    @State private var timedList: MobileChatTimedListKind?
    @State private var presentsForwardSelection = false
    @State private var presentsDeletionSelection = false
    @State private var presentsForwardRecords = false
    @State private var presentsDeletionRecords = false
    @State private var presentsSendRecords = false

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
        .task(id: "\(chat.activeProfileID?.uuidString ?? "")/\(conversation.id)") {
            visibilityOwner = UUID()
            chat.enterConversation(conversation.id, ownerID: visibilityOwner)
            if chat.state.selectedConversationID != conversation.id {
                await chat.selectConversation(conversation)
            }
            await chat.interaction?.loadPolicy()
            await chat.interaction?.recoverEdits()
            await chat.polls?.recover()
            await chat.timedActions?.recover()
            await chat.management?.recover()
        }
        .onDisappear {
            chat.leaveConversation(conversation.id, ownerID: visibilityOwner, preservingVoiceRecording: preservesVoiceRecording)
        }
        .onChange(of: chat.management?.closeResults[conversation.id] == .closed) { _, closed in
            if closed, !isManagingConversations { dismiss() }
        }
        .onChange(of: managementDismissalGeneration) { _, _ in
            if chat.management?.closeResults[conversation.id] == .closed { dismiss() }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !conversation.isEncrypted, chat.polls?.availability.supportedFeatures.contains(.poll) == true {
                    Button { presentsPollCreation = true } label: {
                        Image(systemName: "chart.bar.xaxis").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.string("mobile.chat.poll.create"))
                    .accessibilityIdentifier("chat-poll-create")
                }
                if !conversation.isEncrypted, chat.interaction?.canSearch == true {
                    Button { presentsMessageSearch = true } label: {
                        Image(systemName: "magnifyingglass").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel(L10n.string("chat.search.title"))
                    .accessibilityIdentifier("chat-search-current")
                }
                Menu {
                    if let sending = chat.sending, !sending.entries.isEmpty || sending.recovery.failed {
                        Button { presentsSendRecords = true } label: { Label(L10n.string("mobile.chat.send.records"), systemImage: "paperplane") }
                            .accessibilityIdentifier("chat-send-records")
                    }
                    if !conversation.isEncrypted, chat.deletion?.canDelete == true {
                        Button { presentsDeletionSelection = true } label: { Label(L10n.string("mobile.chat.deletion.select"), systemImage: "trash") }
                            .accessibilityIdentifier("chat-deletion-select")
                    }
                    if let deletion = chat.deletion, !deletion.entries.isEmpty || deletion.recovery.failed {
                        Button { presentsDeletionRecords = true } label: { Label(L10n.string("mobile.chat.deletion.records"), systemImage: "list.bullet") }
                            .accessibilityIdentifier("chat-deletion-records")
                    }
                    if !conversation.isEncrypted, chat.forwarding?.canForward == true {
                        Button { presentsForwardSelection = true } label: { Label(L10n.string("mobile.chat.forward.select"), systemImage: "arrowshape.turn.up.right") }
                            .accessibilityIdentifier("chat-forward-select")
                    }
                    if let forwarding = chat.forwarding, !forwarding.entries.isEmpty || forwarding.recovery.failed {
                        Button { presentsForwardRecords = true } label: { Label(L10n.string("mobile.chat.forward.records"), systemImage: "list.bullet") }
                            .accessibilityIdentifier("chat-forward-records")
                    }
                    if chat.management?.canManageConversations == true {
                        Button { manageConversations() } label: { Label(L10n.string("mobile.chat.close.manage"), systemImage: "checklist") }
                            .accessibilityIdentifier("chat-manage-conversations")
                    }
                    if !conversation.isEncrypted, chat.timedActions?.canManageReminders == true {
                        Button { timedList = .reminders } label: { Label(L10n.string("mobile.chat.reminder.list"), systemImage: "bell") }
                            .accessibilityIdentifier("chat-reminders-list")
                    }
                    if !conversation.isEncrypted, chat.timedActions?.canManageSchedules == true {
                        Button { timedList = .schedules } label: { Label(L10n.string("mobile.chat.schedule.list"), systemImage: "clock") }
                            .accessibilityIdentifier("chat-schedules-list")
                    }
                    if chat.canViewAnnouncements(for: conversation) {
                        Button { presentsAnnouncements = true } label: { Label(L10n.string("mobile.chat.announcements.action"), systemImage: "megaphone") }
                            .accessibilityHint(L10n.string("mobile.chat.announcements.hint"))
                            .accessibilityIdentifier("chat-announcements-list")
                    }
                    if chat.canViewMembers(for: conversation) {
                        Button { presentsMembers = true } label: { Label(L10n.string("mobile.chat.members.action"), systemImage: "person.2") }
                            .accessibilityHint(L10n.string("mobile.chat.members.hint"))
                    }
                    Button { chat.toggleConversationPinned(conversation) } label: {
                        Label(conversationPinActionTitle, systemImage: conversationPinSystemImageName)
                    }.accessibilityHint(L10n.string("mobile.chat.pin.hint"))
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                .accessibilityLabel(L10n.string("mobile.chat.timed.more"))
                .accessibilityIdentifier("chat-more")

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
        .sheet(item: $timedList) { kind in
            if let timed = chat.timedActions { MobileChatTimedListSheet(timed: timed, chat: chat, conversation: conversation, kind: kind) }
        }
        .sheet(isPresented: $presentsDeletionSelection) {
            if let deletion = chat.deletion {
                MobileChatDeletionSheet(chat: chat, deletion: deletion).id(ObjectIdentifier(deletion))
            }
        }
        .sheet(isPresented: $presentsSendRecords) {
            if let sending = chat.sending {
                MobileChatSendRecordsSheet(sending: sending, conversations: chat.state.conversations).id(ObjectIdentifier(sending))
            }
        }
        .sheet(isPresented: $presentsDeletionRecords) {
            if let deletion = chat.deletion {
                MobileChatDeletionRecordsSheet(deletion: deletion).id(ObjectIdentifier(deletion))
            }
        }
        .sheet(isPresented: $presentsForwardSelection) {
            if let forwarding = chat.forwarding {
                MobileChatForwardSheet(forwarding: forwarding, messages: chat.state.selectedMessages.messages.filter(MobileChatForwardModel.permits))
                    .id(ObjectIdentifier(forwarding))
            }
        }
        .sheet(isPresented: $presentsForwardRecords) {
            if let forwarding = chat.forwarding {
                MobileChatForwardRecordsSheet(forwarding: forwarding).id(ObjectIdentifier(forwarding))
            }
        }
        .sheet(isPresented: $presentsPollCreation) {
            if let polls = chat.polls { MobileChatCreatePollSheet(polls: polls, conversation: conversation) }
        }
        .sheet(isPresented: $presentsMembers) {
            MobileChatMembersSheet(chat: chat, conversation: conversation)
        }
        .sheet(isPresented: $presentsMessageSearch) {
            if let interaction = chat.interaction {
                MobileChatSearchSheet(chat: chat, interaction: interaction, conversationID: conversation.id)
            }
        }
        .sheet(isPresented: $presentsAnnouncements) {
            MobileChatAnnouncementsSheet(chat: chat, conversation: conversation)
        }
        .safeAreaInset(edge: .bottom) {
            if chat.canComposeMessage, !conversation.isEncrypted {
                MobileChatAttachmentComposer(chat: chat, recordVoice: recordVoice)
            }
        }
        .mobileChatRemoteAttachmentPresentation(chat: chat,
            isEnabled: !presentsAnnouncements && !presentsMessageSearch && chat.interaction?.root == nil)
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
        let readOwner = visibilityOwner
        return MobilePageStateView(
            state: state.messagePageState,
            labels: messageStateLabels,
            emptySystemImage: "bubble.left",
            retryAction: { Task { await chat.refreshMessages() } }
        ) {
            ScrollViewReader { proxy in
                List {
                    loadEarlierSection(state)
                    ForEach(state.selectedMessages.messages) { message in
                        MobileChatMessageRow(chat: chat, message: message)
                            .id(message.id)
                            .background(alignment: .bottom) {
                                if message.id == state.selectedMessages.messages.last(where: { $0.deliveryState == .sent })?.id {
                                    MobileChatReadVisibility(identity: message.id) { visible in
                                        chat.updateVisibleMessage(message.id, isVisible: visible,
                                            conversationID: conversation.id, ownerID: readOwner)
                                    }.frame(height: 2)
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .refreshable { await chat.refreshMessages() }
                .onChange(of: state.selectedMessages.messages.last?.id) { old, latest in
                    if let latest, old == chat.visibleReadMessageID || state.selectedMessages.messages.last?.isFromCurrentUser == true {
                        proxy.scrollTo(latest, anchor: .bottom)
                    }
                }
                .safeAreaInset(edge: .bottom, alignment: .trailing, spacing: 0) {
                    if !state.selectedMessages.messages.isEmpty,
                       chat.visibleReadMessageID == nil || (state.selectedConversation?.lastActivityAt ?? .distantPast) > (state.selectedMessages.messages.last?.sentAt ?? .distantPast) {
                        Button {
                            Task {
                                let profileID = chat.activeProfileID
                                await chat.refreshMessages()
                                guard chat.activeProfileID == profileID, chat.state.selectedConversationID == conversation.id else { return }
                                if let latest = chat.state.selectedMessages.messages.last?.id { proxy.scrollTo(latest, anchor: .bottom) }
                            }
                        } label: { Label(L10n.string("mobile.chat.latest"), systemImage: "arrow.down") }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(state.isRefreshingMessages)
                        .accessibilityIdentifier("chat-scroll-latest").padding(12)
                    }
                }
            }
            .accessibilityElement(children: .contain)
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
    @State private var query = ""
    private var filtered: [ChatMessage] {
        let values = chat.state.selectedConversationAnnouncements
        return query.isEmpty ? values : values.filter {
            ($0.text ?? "").localizedStandardContains(query) || $0.attachments.contains { $0.fileName.localizedStandardContains(query) }
        }
    }
    private var pageState: MobilePageState {
        chat.state.announcementPageState == .content && filtered.isEmpty ? .filteredEmpty : chat.state.announcementPageState
    }
    var body: some View {
        NavigationStack {
            MobilePageStateView(state: pageState, labels: announcementStateLabels,
                emptySystemImage: "megaphone", errorSystemImage: "exclamationmark.bubble",
                retryAction: { Task { await refresh() } }) {
                List {
                    Section(L10n.string("mobile.chat.announcements.count", filtered.count)) {
                        ForEach(filtered) { announcement in
                            MobileChatMessageRow(chat: chat, message: announcement, showsAnnouncementBadge: false)
                                .accessibilityIdentifier("chat-announcement-row-\(announcement.id)")
                        }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("chat-announcements-content")
                .refreshable { await refresh() }
            }
            .navigationTitle(L10n.string("mobile.chat.announcements.title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: L10n.string("mobile.chat.timed.search"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.chat.announcements.close")) {
                        chat.cancelConversationAnnouncementLoad(); dismiss()
                    }.frame(minWidth: 44, minHeight: 44)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Task { await refresh() } } label: {
                        Image(systemName: "arrow.clockwise").frame(width: 44, height: 44)
                    }
                    .disabled(chat.state.announcementPageState == .loading || chat.state.isRefreshingAnnouncements)
                    .accessibilityLabel(L10n.string("mobile.chat.announcements.refresh"))
                }
            }
        }
        .task(id: conversation.id) { await refresh() }
        .onDisappear { chat.cancelConversationAnnouncementLoad() }
        .mobileChatRemoteAttachmentPresentation(chat: chat, isEnabled: chat.interaction?.root == nil)
    }
    private func refresh() async { await chat.management?.recover(); await chat.loadConversationAnnouncements(forceRefresh: true) }
    private var announcementStateLabels: MobilePageStateLabels {
        MobilePageStateLabels(
            loading: L10n.string("mobile.chat.announcements.loading"),
            emptyTitle: L10n.string("mobile.chat.announcements.empty.title"),
            emptyMessage: L10n.string("mobile.chat.announcements.empty.message"),
            filteredEmptyTitle: L10n.string("mobile.chat.timed.filtered"),
            filteredEmptyMessage: L10n.string("mobile.chat.timed.filtered-message"),
            errorTitle: L10n.string("mobile.chat.announcements.error.title"),
            errorMessage: L10n.string("mobile.chat.announcements.error.message"),
            retryTitle: L10n.string("mobile.chat.action.retry"))
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

struct MobileChatMessageRow: View {
    @Bindable var chat: MobileChatModel
    let message: ChatMessage
    var allowsThreadNavigation = true
    var showsAnnouncementBadge = true
    @State private var confirmsDelete = false
    @State private var deletionConfirmation: ChatMessage?
    @State private var presentsEdit = false
    @State private var presentsPoll = false
    @State private var presentsThread = false
    @State private var presentsReminder = false
    @State private var presentsForward = false
    @State private var presentsDeletionRecords = false

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
            if let poll = message.poll {
                if poll.isClosed { Text(L10n.string("chat.vote.closed")).font(.caption).foregroundStyle(.secondary) }
                if chat.polls?.hasVoting == true {
                    Button { presentsPoll = true } label: {
                        Label(L10n.string("chat.vote.results"), systemImage: "chart.bar.xaxis")
                    }
                    .buttonStyle(.borderless).frame(minHeight: 44)
                    .accessibilityIdentifier("chat-poll-open-\(message.id)")
                }
            }
            ForEach(message.attachments) { attachment in
                MobileChatRemoteAttachmentRow(
                    chat: chat,
                    message: message,
                    attachment: attachment
                )
            }
            if message.editedAt != nil {
                Text(L10n.string("chat.edit.edited")).font(.caption).foregroundStyle(.secondary)
            }
            if allowsThreadNavigation, message.encryptionState == .notEncrypted,
               chat.interaction?.availability.supportedFeatures.contains(.threadedReplies) == true {
                Button { presentsThread = true } label: {
                    Label(L10n.string("chat.thread.reply"), systemImage: "bubble.left.and.bubble.right")
                }
                .buttonStyle(.borderless).frame(minHeight: 44)
                .accessibilityIdentifier("chat-thread-\(message.id)")
            }
            if let interaction = chat.interaction,
               interaction.pending.contains(where: { $0.kind == .edit && $0.conversationID == message.conversationID && $0.messageID == message.id }) {
                Text(L10n.string("mobile.chat.interaction.edit-pending")).font(.footnote).foregroundStyle(.secondary)
            }
            if message.isPinned {
                if message.text?.isEmpty != false && message.attachments.isEmpty && message.poll == nil {
                    Text(L10n.string("mobile.chat.announcements.no-text"))
                }
                if let date = message.pinnedAt {
                    Text(L10n.string("mobile.chat.announcements.pinned-at", date.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale))))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if showsAnnouncementBadge {
                    Label(L10n.string("mobile.chat.announcement.badge"), systemImage: "pin.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let management = chat.management {
                if management.pending.contains(where: { $0.kind != .close && $0.conversationID == message.conversationID && $0.messageID == message.id }) {
                    Text(L10n.string("mobile.chat.announcement.pending")).font(.footnote).foregroundStyle(.secondary)
                } else if let key = management.error(for: message) {
                    Text(L10n.string(key)).font(.footnote).foregroundStyle(.orange)
                }
            }
            deleteStatus
        }
        .padding(.vertical, 6)
        .frame(maxWidth: 680, minHeight: 44, alignment: .leading)
        .accessibilityElement(children: .combine)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            deleteActionButton
        }
        .contextMenu {
            if chat.forwarding?.canSelect(message) == true {
                Button { presentsForward = true } label: { Label(L10n.string("mobile.chat.forward.action"), systemImage: "arrowshape.turn.up.right") }
                    .accessibilityIdentifier("chat-forward-\(message.id)")
            }
            if let management = chat.management, management.canPin(message) {
                Button { Task { _ = await management.setPinned(message, isPinned: !message.isPinned) } } label: {
                    Label(L10n.string(message.isPinned ? "mobile.chat.announcement.unpin" : "mobile.chat.announcement.pin"),
                        systemImage: message.isPinned ? "pin.slash" : "pin")
                }.accessibilityIdentifier("chat-pin-\(message.id)")
            }
            if chat.timedActions?.availability.supportedFeatures.contains(.reminder) == true, message.encryptionState == .notEncrypted {
                Button { presentsReminder = true } label: { Label(L10n.string("mobile.chat.reminder.action"), systemImage: "bell") }
                    .accessibilityIdentifier("chat-reminder-\(message.id)")
            }
            if chat.interaction?.canEdit(message) == true {
                Button { presentsEdit = true } label: {
                    Label(L10n.string("chat.edit.action"), systemImage: "pencil")
                }
                .accessibilityIdentifier("chat-edit-\(message.id)")
            }
            deleteActionButton
        }
        .sheet(isPresented: $presentsReminder) {
            if let timed = chat.timedActions { MobileChatReminderEditor(timed: timed, original: message) }
        }
        .sheet(isPresented: $presentsDeletionRecords) {
            if let deletion = chat.deletion {
                MobileChatDeletionRecordsSheet(deletion: deletion).id(ObjectIdentifier(deletion))
            }
        }
        .sheet(isPresented: $presentsForward) {
            if let forwarding = chat.forwarding {
                MobileChatForwardSheet(forwarding: forwarding, messages: [message], initialSelection: [message.id])
                    .id(ObjectIdentifier(forwarding))
            }
        }
        .sheet(isPresented: $presentsPoll) {
            if let polls = chat.polls { MobileChatPollSheet(polls: polls, original: message) }
        }
        .sheet(isPresented: $presentsEdit) {
            if let interaction = chat.interaction { MobileChatEditSheet(interaction: interaction, original: message) }
        }
        .sheet(isPresented: $presentsThread) {
            if let interaction = chat.interaction {
                NavigationStack {
                    MobileChatDiscussionView(chat: chat, interaction: interaction, message: message)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(L10n.string("files.common.close")) { presentsThread = false }
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                        }
                }
            }
        }
        .modifier(MobileChatDeleteAccessibilityAction(isEnabled: chat.canDeleteMessage(message)) {
            deletionConfirmation = message; confirmsDelete = true
        })
        .confirmationDialog(
            L10n.string("mobile.chat.message.delete.confirm.title"),
            isPresented: $confirmsDelete,
            titleVisibility: .visible
        ) {
            Button(L10n.string("mobile.chat.message.action.delete"), role: .destructive) {
                if let original = deletionConfirmation { Task { await chat.deleteMessage(original) } }
            }
            Button(L10n.string("mobile.chat.message.delete.confirm.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("mobile.chat.message.delete.confirm.message"))
        }
    }

    @ViewBuilder
    private var deleteActionButton: some View {
        if chat.canDeleteMessage(message) {
            Button(role: .destructive) {
                deletionConfirmation = message; confirmsDelete = true
            } label: {
                Label(
                    L10n.string("mobile.chat.message.action.delete"),
                    systemImage: "trash"
                )
            }
        }
    }

    private struct MobileChatDeleteAccessibilityAction: ViewModifier {
        let isEnabled: Bool
        let action: () -> Void

        func body(content: Content) -> some View {
            content.accessibilityActions {
                if isEnabled {
                    Button(L10n.string("mobile.chat.message.action.delete"), action: action)
                }
            }
        }
    }

    @ViewBuilder
    private var deleteStatus: some View {
        if chat.state.deletingMessageID == message.id {
            Label(
                L10n.string("mobile.chat.message.delete.progress"),
                systemImage: "trash"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if let key = chat.deletion?.status(for: message) {
            Button { presentsDeletionRecords = true } label: {
                Label(L10n.string(key), systemImage: "list.bullet")
            }
            .font(.footnote).foregroundStyle(.orange).frame(minHeight: 44)
            .accessibilityIdentifier("chat-deletion-status-\(message.id)")
        }
    }
}
