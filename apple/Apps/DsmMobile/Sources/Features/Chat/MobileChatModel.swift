import DsmCore
import Foundation
import Observation

@MainActor
@Observable
final class MobileChatModel {
    static let messagePageSize = 50

    private(set) var activeProfileID: UUID?
    private(set) var profiles: [UUID: MobileChatProfileState] = [:]
    private(set) var conversationCreators: [UUID: MobileChatConversationCreator] = [:]

    @ObservationIgnored private var repositories: [UUID: any ChatRepository] = [:]
    @ObservationIgnored private var conversationTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var memberTask: Task<Void, Never>?
    @ObservationIgnored private var announcementTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private var messageDeleteTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeSyncTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeStopTask: Task<Void, Never>?
    @ObservationIgnored private var conversationGeneration = 0
    @ObservationIgnored private var messageGeneration = 0
    @ObservationIgnored private var memberGeneration = 0
    @ObservationIgnored private var announcementGeneration = 0
    @ObservationIgnored private var sendGeneration = 0
    @ObservationIgnored private var messageDeleteGeneration = 0
    @ObservationIgnored private var realtimeGeneration = 0
    @ObservationIgnored private var foregroundRealtimeRequested = false
    @ObservationIgnored private var realtimeConnected = false
    @ObservationIgnored private var pendingRealtimeSync = false
    @ObservationIgnored private let conversationPinStore: any MobileChatConversationPinStore
    @ObservationIgnored private let realtimePollingIntervalNanoseconds: UInt64
    @ObservationIgnored private let realtimeDebounceIntervalNanoseconds: UInt64
    private let attachmentFileManager: FileManager
    private let attachmentCopier: any MobileDocumentImportCopying
    private let attachmentRootURL: URL
    @ObservationIgnored private lazy var attachmentModel = MobileChatAttachmentModel(
        owner: self,
        fileManager: attachmentFileManager,
        copier: attachmentCopier,
        rootURL: attachmentRootURL
    )

    init(
        attachmentFileManager: FileManager = .default,
        attachmentCopier: any MobileDocumentImportCopying = MobileSecurityScopedDocumentCopier(),
        attachmentRootURL: URL? = nil,
        conversationPinStore: any MobileChatConversationPinStore = UserDefaultsMobileChatConversationPinStore(),
        realtimePollingIntervalNanoseconds: UInt64 = 30_000_000_000,
        realtimeDebounceIntervalNanoseconds: UInt64 = 200_000_000
    ) {
        self.conversationPinStore = conversationPinStore
        self.attachmentFileManager = attachmentFileManager
        self.attachmentCopier = attachmentCopier
        self.attachmentRootURL = attachmentRootURL ?? attachmentFileManager.temporaryDirectory
            .appendingPathComponent("LanStashChatAttachments", isDirectory: true)
        self.realtimePollingIntervalNanoseconds = max(realtimePollingIntervalNanoseconds, 1_000_000)
        self.realtimeDebounceIntervalNanoseconds = max(realtimeDebounceIntervalNanoseconds, 1_000_000)
    }

    /// 附件临时文件只由附件状态机持有，不写入配置档状态。
    var selectedAttachment: MobileChatAttachmentSelection? {
        attachmentModel.selectedAttachment
    }

    var remoteAttachmentPresentation: MobileChatRemoteAttachmentPresentation? {
        attachmentModel.remoteAttachmentPresentation
    }

    var state: MobileChatProfileState {
        guard let activeProfileID else { return MobileChatProfileState() }
        return profiles[activeProfileID] ?? MobileChatProfileState()
    }

    var conversationCreator: MobileChatConversationCreator? {
        guard let activeProfileID else { return nil }
        return conversationCreators[activeProfileID]
    }

    var canCreateConversation: Bool {
        conversationCreator?.canCreateDirect == true || conversationCreator?.canCreateGroup == true
    }

    var canSelectAttachment: Bool {
        attachmentModel.canSelectAttachment
    }

    var canComposeMessage: Bool {
        attachmentModel.canComposeMessage
    }

    var canSendSelectedDraft: Bool {
        attachmentModel.canSendSelectedDraft
    }

    func canViewMembers(for conversation: ChatConversation) -> Bool {
        state.selectedConversationID == conversation.id
            && conversation.kind == .group
            && state.availability.status == .available
            && state.availability.supportedFeatures.contains(.groupMembers)
    }

    func canViewAnnouncements(for conversation: ChatConversation) -> Bool {
        state.selectedConversationID == conversation.id
            && conversation.kind == .group
            && !conversation.isEncrypted
            && state.availability.status == .available
            && state.availability.supportedFeatures.contains(.pinnedMessages)
    }

    func canDeleteMessage(_ message: ChatMessage) -> Bool {
        guard let conversation = state.selectedConversation,
              conversation.id == message.conversationID,
              !conversation.isEncrypted,
              message.deliveryState == .sent,
              message.encryptionState == .notEncrypted,
              message.isFromCurrentUser == true,
              state.availability.status == .available,
              state.availability.supportedFeatures.contains(.deleteOwnMessage),
              state.deletingMessageID == nil,
              state.deleteReviewBlockedMessageIDsByConversation[message.conversationID]?.contains(message.id) != true
        else {
            return false
        }
        return state.selectedMessages.messages.contains(where: { $0.id == message.id })
    }

    func activate(profileID: UUID?, repository: (any ChatRepository)?) async {
        if let activeProfileID {
            profiles[activeProfileID]?.visibleConversationID = nil
        }
        cancelAllWork()
        guard let profileID else {
            activeProfileID = nil
            return
        }
        guard let repository else {
            repositories[profileID] = nil
            activeProfileID = nil
            return
        }

        activeProfileID = profileID
        let mobileRepository = MobileReadOnlyChatRepository(base: repository)
        repositories[profileID] = mobileRepository
        if let creator = conversationCreators[profileID] {
            creator.rebind(
                repository: mobileRepository,
                availability: profiles[profileID]?.availability
                    ?? ChatAvailability(status: .requiresValidation)
            )
        } else {
            conversationCreators[profileID] = MobileChatConversationCreator(
                repository: mobileRepository,
                availability: profiles[profileID]?.availability
                    ?? ChatAvailability(status: .requiresValidation)
            )
        }
        if profiles[profileID] == nil {
            var profile = MobileChatProfileState()
            profile.pinnedConversationIDs = Self.normalizedPinnedConversationIDs(
                conversationPinStore.loadPinnedConversationIDs(profileID: profileID)
            )
            profiles[profileID] = profile
            await reloadConversations()
        }
    }

    func deactivate() {
        let profileID = activeProfileID
        foregroundRealtimeRequested = false
        cancelAllWork()
        if let profileID {
            profiles[profileID]?.visibleConversationID = nil
            repositories[profileID] = nil
        }
        activeProfileID = nil
    }

    /// 用户明确退出或删除配置档时，清除该配置档关联的会话与消息明文缓存。
    func purge(profileID: UUID) {
        if activeProfileID == profileID {
            foregroundRealtimeRequested = false
            cancelAllWork()
            activeProfileID = nil
        }
        repositories[profileID] = nil
        profiles[profileID] = nil
        conversationCreators[profileID] = nil
    }

    /// 删除配置档时清除对应的本地置顶偏好；普通退出只清内存态，保留本机偏好。
    func removePersistentPins(profileID: UUID) {
        conversationPinStore.removePinnedConversationIDs(profileID: profileID)
    }

    func setConversationFilter(_ value: String) {
        updateActive { profile in
            profile.conversationFilter = value
            Self.applyConversationFilter(to: &profile)
        }
    }

    /// 实时刷新只在 Chat 可见且 App 位于前台时运行；后台不保活也不承诺即时到达。
    func setForegroundRealtimeActive(_ isActive: Bool) async {
        foregroundRealtimeRequested = isActive
        if isActive {
            await waitForForegroundRealtimeStop()
            startForegroundRealtimeIfNeeded()
        } else {
            scheduleForegroundRealtimeStop()
            await waitForForegroundRealtimeStop()
        }
    }

    func toggleConversationPinned(_ conversation: ChatConversation) {
        guard let profileID = activeProfileID else { return }
        var pinnedConversationIDs: [String] = []
        var shouldSave = false
        updateActive { profile in
            let conversationID = conversation.id
            guard profile.conversations.contains(where: { $0.id == conversationID }) else { return }
            if profile.pinnedConversationIDs.contains(conversationID) {
                profile.pinnedConversationIDs.removeAll { $0 == conversationID }
            } else {
                profile.pinnedConversationIDs.append(conversationID)
            }
            profile.pinnedConversationIDs = Self.normalizedPinnedConversationIDs(profile.pinnedConversationIDs)
            profile.conversations = Self.normalizedConversations(
                profile.conversations,
                pinnedConversationIDs: profile.pinnedConversationIDs
            )
            Self.applyConversationFilter(to: &profile)
            pinnedConversationIDs = profile.pinnedConversationIDs
            shouldSave = true
        }
        if shouldSave {
            conversationPinStore.savePinnedConversationIDs(pinnedConversationIDs, profileID: profileID)
        }
    }

    func setDraft(_ value: String) {
        guard let conversationID = state.selectedConversationID else { return }
        updateActive { profile in
            profile.draftsByConversation[conversationID] = value
            if !profile.selectedDraftRequiresReview {
                profile.sendErrorCategory = nil
            }
        }
    }

    func reloadConversations() async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID] else { return }
        let preservesContent = !state.conversations.isEmpty
        let requestGeneration = beginConversationRequest { profile in
            profile.isRefreshingConversations = preservesContent
            profile.conversationErrorCategory = nil
            if !preservesContent {
                profile.conversationPageState = .loading
            }
        }

        let task = Task { [weak self] in
            let availability = await repository.availability()
            guard !Task.isCancelled,
                  self?.isCurrentConversation(
                    profileID: profileID,
                    generation: requestGeneration
                  ) == true else {
                return
            }
            self?.updateActive { $0.availability = availability }
            self?.conversationCreators[profileID]?.updateAvailability(availability)
            guard availability.status == .available else {
                self?.finishUnavailable(profileID: profileID, generation: requestGeneration)
                return
            }

            do {
                let conversations = try await repository.listConversations()
                try Task.checkCancellation()
                self?.finishConversations(
                    conversations,
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch is CancellationError {
                self?.finishConversationCancellation(
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch {
                self?.finishConversationFailure(
                    error,
                    preservesContent: preservesContent,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        conversationTask = task
        await task.value
    }

    func selectConversation(_ conversation: ChatConversation) async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let canonical = state.conversations.first(where: { $0.id == conversation.id }) else {
            return
        }
        attachmentModel.cancelAllWork()
        cancelMessageWork()
        cancelMemberWork()
        cancelAnnouncementWork()
        updateActive { profile in
            profile.selectedConversationID = canonical.id
            profile.messageErrorCategory = nil
            profile.memberErrorCategory = nil
            profile.announcementErrorCategory = nil
            profile.sendErrorCategory = nil
            profile.deleteMessageErrorCategory = nil
            profile.deleteMessageErrorID = nil
            profile.loadMoreMessagesFailed = false
            if let cachedMembers = profile.membersByConversation[canonical.id] {
                profile.memberPageState = cachedMembers.isEmpty ? .empty : .content
            } else {
                profile.memberPageState = .empty
            }
            if let cachedAnnouncements = profile.announcementsByConversation[canonical.id] {
                profile.announcementPageState = cachedAnnouncements.isEmpty ? .empty : .content
            } else {
                profile.announcementPageState = .empty
            }
            if canonical.isEncrypted {
                // 加密消息在当前只读切片中不进入内存缓存，避免正文意外泄漏。
                profile.messagesByConversation[canonical.id] = nil
                profile.messagePageState = .empty
            } else if let cached = profile.messagesByConversation[canonical.id] {
                profile.messagePageState = cached.messages.isEmpty ? .empty : .content
            } else {
                profile.messagePageState = .loading
            }
        }
        guard !canonical.isEncrypted,
              state.messagesByConversation[canonical.id] == nil else { return }
        await replaceMessages(
            conversationID: canonical.id,
            profileID: profileID,
            repository: repository,
            preservesContent: false
        )
    }

    func acceptCreatedConversation(
        _ conversation: ChatConversation,
        sourceProfileID: UUID
    ) async -> Bool {
        guard activeProfileID == sourceProfileID, !conversation.isEncrypted else { return false }
        updateActive { profile in
            profile.conversations = Self.normalizedConversations(
                profile.conversations
                    .filter { $0.id != conversation.id }
                    + [conversation],
                pinnedConversationIDs: profile.pinnedConversationIDs
            )
            Self.applyConversationFilter(to: &profile)
            profile.conversationPageState = .content
            profile.conversationErrorCategory = nil
        }
        guard activeProfileID == sourceProfileID else { return false }
        await selectConversation(conversation)
        return activeProfileID == sourceProfileID
            && state.selectedConversationID == conversation.id
    }

    func loadConversationMembers(forceRefresh: Bool = false) async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let conversation = state.selectedConversation,
              canViewMembers(for: conversation),
              memberTask == nil else { return }

        let conversationID = conversation.id
        if !forceRefresh,
           let cachedMembers = state.membersByConversation[conversationID] {
            updateActive {
                $0.memberPageState = cachedMembers.isEmpty ? .empty : .content
                $0.memberErrorCategory = nil
            }
            return
        }

        let preservesContent = state.membersByConversation[conversationID] != nil
        let requestGeneration = beginMemberRequest { profile in
            profile.isRefreshingMembers = preservesContent
            profile.memberErrorCategory = nil
            if !preservesContent {
                profile.memberPageState = .loading
            }
        }
        let task = Task { [weak self] in
            do {
                let members = try await repository.listConversationMembers(
                    conversationID: conversationID
                )
                try Task.checkCancellation()
                self?.finishConversationMembers(
                    members,
                    conversationID: conversationID,
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch is CancellationError {
                self?.finishMemberCancellation(
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch {
                self?.finishMemberFailure(
                    error,
                    conversationID: conversationID,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        memberTask = task
        await task.value
    }

    func cancelConversationMemberLoad() {
        cancelMemberWork()
    }

    func loadConversationAnnouncements(forceRefresh: Bool = false) async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let conversation = state.selectedConversation,
              canViewAnnouncements(for: conversation),
              announcementTask == nil else { return }

        let conversationID = conversation.id
        if !forceRefresh,
           let cached = state.announcementsByConversation[conversationID] {
            updateActive {
                $0.announcementPageState = cached.isEmpty ? .empty : .content
                $0.announcementErrorCategory = nil
            }
            return
        }

        let preservesContent = state.announcementsByConversation[conversationID] != nil
        let requestGeneration = beginAnnouncementRequest { profile in
            profile.isRefreshingAnnouncements = preservesContent
            profile.announcementErrorCategory = nil
            if !preservesContent {
                profile.announcementPageState = .loading
            }
        }
        let task = Task { [weak self] in
            do {
                let announcements = try await repository.listPinnedMessages(
                    conversationID: conversationID
                )
                try Task.checkCancellation()
                self?.finishConversationAnnouncements(
                    announcements,
                    conversationID: conversationID,
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch is CancellationError {
                self?.finishAnnouncementCancellation(
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch {
                self?.finishAnnouncementFailure(
                    error,
                    conversationID: conversationID,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        announcementTask = task
        await task.value
    }

    func cancelConversationAnnouncementLoad() {
        cancelAnnouncementWork()
    }

    func refreshMessages() async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let conversation = state.selectedConversation,
              !conversation.isEncrypted else { return }
        await replaceMessages(
            conversationID: conversation.id,
            profileID: profileID,
            repository: repository,
            preservesContent: !state.selectedMessages.messages.isEmpty
        )
    }

    func loadMoreMessages() async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let conversation = state.selectedConversation,
              !conversation.isEncrypted,
              state.selectedMessages.hasMoreBefore,
              !state.isRefreshingMessages,
              !state.isLoadingMoreMessages else { return }

        let conversationID = conversation.id
        let cursor = state.selectedMessages.previousCursor
        let requestGeneration = beginMessageRequest { profile in
            profile.isLoadingMoreMessages = true
            profile.loadMoreMessagesFailed = false
            profile.messageErrorCategory = nil
        }
        let task = Task { [weak self] in
            do {
                let page = try await repository.listMessages(
                    conversationID: conversationID,
                    before: cursor,
                    limit: Self.messagePageSize
                )
                try Task.checkCancellation()
                self?.finishMessages(
                    page,
                    conversationID: conversationID,
                    appending: true,
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch is CancellationError {
                self?.finishMessageCancellation(
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch {
                self?.finishLoadMoreFailure(
                    error,
                    conversationID: conversationID,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        messageTask = task
        await task.value
    }

    func sendSelectedMessage() async {
        if selectedAttachment != nil {
            await attachmentModel.sendSelectedAttachment()
            return
        }
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let conversation = state.selectedConversation,
              !conversation.isEncrypted,
              state.availability.supportedFeatures.contains(.textMessage),
              !state.isPreparingAttachment,
              !state.isSendingAttachment,
              !state.attachmentReviewRequired,
              !state.isSendingMessage else {
            return
        }
        let text = state.selectedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        guard state.sendReviewBlockedTextsByConversation[conversation.id]?.contains(text) != true else {
            updateActive { $0.sendErrorCategory = .partialFailure }
            return
        }

        let draft: ChatMessageDraft
        do {
            draft = try ChatMessageDraft(conversationID: conversation.id, text: text)
        } catch {
            updateActive { $0.sendErrorCategory = Self.category(for: error) }
            return
        }

        let requestGeneration = beginSendRequest { profile in
            profile.isSendingMessage = true
            profile.sendErrorCategory = nil
        }
        let task = Task { [weak self] in
            do {
                let outcome = try await repository.sendMessageResult(draft)
                self?.finishSendOutcome(
                    outcome,
                    sentText: text,
                    conversationID: conversation.id,
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch is CancellationError {
                self?.finishSendCancellation(profileID: profileID, generation: requestGeneration)
            } catch {
                self?.finishSendFailure(
                    error,
                    sentText: text,
                    conversationID: conversation.id,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        sendTask = task
        await task.value
    }

    func deleteMessage(_ message: ChatMessage) async {
        guard canDeleteMessage(message),
              let profileID = activeProfileID,
              let repository = repositories[profileID],
              state.selectedConversationID == message.conversationID else { return }

        let requestGeneration = beginMessageDeleteRequest { profile in
            profile.deletingMessageID = message.id
            profile.deleteMessageErrorCategory = nil
            profile.deleteMessageErrorID = nil
        }
        let task = Task { [weak self] in
            do {
                try await repository.deleteMessage(
                    conversationID: message.conversationID,
                    messageID: message.id,
                    clientRequestID: UUID()
                )
                try Task.checkCancellation()
                self?.finishMessageDeleteSuccess(
                    message,
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch is CancellationError {
                self?.finishMessageDeleteCancellation(
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch {
                self?.finishMessageDeleteFailure(
                    error,
                    message: message,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        messageDeleteTask = task
        await task.value
    }

    // MARK: - 附件状态机接线

    func preparePhotoAttachment(_ item: any MobilePhotosPickerItemServing) {
        attachmentModel.preparePhotoAttachment(item)
    }

    func prepareFileAttachment(_ sourceURL: URL) {
        attachmentModel.prepareFileAttachment(sourceURL)
    }

    func rejectAttachmentSelection() {
        attachmentModel.rejectAttachmentSelection()
    }

    func removeSelectedAttachment() {
        attachmentModel.removeSelectedAttachment()
    }

    func cancelSelectedAttachmentSend() {
        attachmentModel.cancelSelectedAttachmentSend()
    }

    func leaveConversation(_ conversationID: String) {
        updateActive { profile in
            if profile.visibleConversationID == conversationID {
                profile.visibleConversationID = nil
            }
        }
        attachmentModel.leaveConversation(conversationID)
    }

    func enterConversation(_ conversationID: String) {
        updateActive { profile in
            guard let conversation = profile.conversations.first(where: { $0.id == conversationID }) else {
                return
            }
            profile.visibleConversationID = conversationID
            if !conversation.isEncrypted,
               let cached = profile.messagesByConversation[conversationID] {
                Self.markConversationReadLocally(
                    in: &profile,
                    conversationID: conversationID,
                    through: cached.messages.map(\.sentAt).max()
                )
            }
        }
    }

    func loadAttachmentThumbnail(for message: ChatMessage) {
        attachmentModel.loadAttachmentThumbnail(for: message)
    }

    func previewRemoteAttachment(_ attachment: ChatAttachment, in message: ChatMessage) {
        attachmentModel.previewRemoteAttachment(attachment, in: message)
    }

    func saveRemoteAttachment(_ attachment: ChatAttachment, in message: ChatMessage) {
        attachmentModel.saveRemoteAttachment(attachment, in: message)
    }

    func dismissRemoteAttachmentPresentation() {
        attachmentModel.dismissRemoteAttachmentPresentation()
    }

    func cancelRemoteAttachmentDownload() {
        attachmentModel.cancelRemoteAttachmentDownload()
    }

    func canOpenRemoteAttachment(_ attachment: ChatAttachment, in message: ChatMessage) -> Bool {
        attachmentModel.canOpenRemoteAttachment(attachment, in: message)
    }

    func canUseRemoteAttachment(_ attachment: ChatAttachment, in message: ChatMessage) -> Bool {
        attachmentModel.canUseRemoteAttachment(attachment, in: message)
    }

    func cancelAllWork() {
        stopForegroundRealtimeSoon()
        conversationTask?.cancel()
        conversationTask = nil
        conversationGeneration &+= 1
        messageTask?.cancel()
        messageTask = nil
        messageGeneration &+= 1
        memberTask?.cancel()
        memberTask = nil
        memberGeneration &+= 1
        announcementTask?.cancel()
        announcementTask = nil
        announcementGeneration &+= 1
        sendTask?.cancel()
        sendTask = nil
        sendGeneration &+= 1
        messageDeleteTask?.cancel()
        messageDeleteTask = nil
        messageDeleteGeneration &+= 1
        attachmentModel.cancelAllWork()
        updateActive {
            $0.isRefreshingConversations = false
            $0.isRefreshingMessages = false
            $0.isRefreshingMembers = false
            $0.isRefreshingAnnouncements = false
            $0.isLoadingMoreMessages = false
            $0.isSendingMessage = false
            $0.deletingMessageID = nil
        }
    }

    private func startForegroundRealtimeIfNeeded() {
        guard foregroundRealtimeRequested,
              realtimeTask == nil,
              let profileID = activeProfileID,
              let repository = repositories[profileID],
              state.availability.status == .available else { return }

        realtimeGeneration &+= 1
        let generation = realtimeGeneration
        realtimeConnected = false
        startPollingIfNeeded(profileID: profileID, repository: repository, generation: generation)
        realtimeTask = Task { [weak self] in
            let events = await repository.realtimeEvents()
            guard self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else {
                return
            }
            await repository.startRealtime()
            guard self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else {
                await repository.stopRealtime()
                return
            }
            for await event in events {
                guard !Task.isCancelled,
                      self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else {
                    break
                }
                self?.handleRealtimeEvent(
                    event,
                    profileID: profileID,
                    repository: repository,
                    generation: generation
                )
            }
            guard self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else {
                return
            }
            self?.realtimeTask = nil
            self?.realtimeConnected = false
            self?.startPollingIfNeeded(
                profileID: profileID,
                repository: repository,
                generation: generation
            )
        }
    }

    private func handleRealtimeEvent(
        _ event: ChatRealtimeEvent,
        profileID: UUID,
        repository: any ChatRepository,
        generation: Int
    ) {
        switch event {
        case .connected:
            realtimeConnected = true
            pollingTask?.cancel()
            pollingTask = nil
        case .contentChanged:
            requestRealtimeSync(
                profileID: profileID,
                generation: generation,
                waitsForDebounce: true
            )
        case .disconnected:
            realtimeConnected = false
            startPollingIfNeeded(profileID: profileID, repository: repository, generation: generation)
        }
    }

    private func startPollingIfNeeded(
        profileID: UUID,
        repository: any ChatRepository,
        generation: Int
    ) {
        guard !realtimeConnected,
              pollingTask == nil,
              isCurrentRealtime(profileID: profileID, generation: generation) else { return }
        let interval = realtimePollingIntervalNanoseconds
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard self?.isCurrentRealtime(profileID: profileID, generation: generation) == true,
                      self?.realtimeConnected == false else { return }
                self?.requestRealtimeSync(
                    profileID: profileID,
                    generation: generation,
                    waitsForDebounce: false
                )
            }
        }
    }

    private func requestRealtimeSync(
        profileID: UUID,
        generation: Int,
        waitsForDebounce: Bool
    ) {
        guard isCurrentRealtime(profileID: profileID, generation: generation) else { return }
        if waitsForDebounce {
            realtimeDebounceTask?.cancel()
            let interval = realtimeDebounceIntervalNanoseconds
            realtimeDebounceTask = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else {
                    return
                }
                self?.realtimeDebounceTask = nil
                self?.enqueueRealtimeSync(profileID: profileID, generation: generation)
            }
            return
        }
        enqueueRealtimeSync(profileID: profileID, generation: generation)
    }

    private func enqueueRealtimeSync(profileID: UUID, generation: Int) {
        guard isCurrentRealtime(profileID: profileID, generation: generation) else { return }
        pendingRealtimeSync = true
        guard realtimeSyncTask == nil else { return }
        realtimeSyncTask = Task { [weak self] in
            while self?.consumePendingRealtimeSync(
                profileID: profileID,
                generation: generation
            ) == true {
                await self?.reloadConversations()
                guard !Task.isCancelled,
                      self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else {
                    break
                }
                await self?.refreshMessages()
            }
            guard self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else {
                return
            }
            self?.realtimeSyncTask = nil
        }
    }

    private func consumePendingRealtimeSync(profileID: UUID, generation: Int) -> Bool {
        guard pendingRealtimeSync,
              isCurrentRealtime(profileID: profileID, generation: generation) else { return false }
        pendingRealtimeSync = false
        return true
    }

    private func stopForegroundRealtimeSoon() {
        scheduleForegroundRealtimeStop()
    }

    private func scheduleForegroundRealtimeStop() {
        guard realtimeStopTask == nil,
              let (repository, eventTask) = cancelForegroundRealtimeTasks() else { return }
        realtimeStopTask = Task {
            await eventTask?.value
            await repository.stopRealtime()
        }
    }

    private func waitForForegroundRealtimeStop() async {
        guard let realtimeStopTask else { return }
        await realtimeStopTask.value
        self.realtimeStopTask = nil
    }

    private func cancelForegroundRealtimeTasks() -> ((any ChatRepository), Task<Void, Never>?)? {
        let repository = activeProfileID.flatMap { repositories[$0] }
        let eventTask = realtimeTask
        realtimeGeneration &+= 1
        realtimeTask?.cancel()
        realtimeTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        realtimeDebounceTask?.cancel()
        realtimeDebounceTask = nil
        realtimeSyncTask?.cancel()
        realtimeSyncTask = nil
        pendingRealtimeSync = false
        realtimeConnected = false
        guard let repository else { return nil }
        return (repository, eventTask)
    }

    private func replaceMessages(
        conversationID: String,
        profileID: UUID,
        repository: any ChatRepository,
        preservesContent: Bool
    ) async {
        let requestGeneration = beginMessageRequest { profile in
            profile.isRefreshingMessages = preservesContent
            profile.isLoadingMoreMessages = false
            profile.loadMoreMessagesFailed = false
            profile.messageErrorCategory = nil
            if !preservesContent {
                profile.messagePageState = .loading
            }
        }
        let task = Task { [weak self] in
            do {
                let page = try await repository.listMessages(
                    conversationID: conversationID,
                    before: nil,
                    limit: Self.messagePageSize
                )
                try Task.checkCancellation()
                self?.finishMessages(
                    page,
                    conversationID: conversationID,
                    appending: false,
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch is CancellationError {
                self?.finishMessageCancellation(
                    profileID: profileID,
                    generation: requestGeneration
                )
            } catch {
                self?.finishMessageFailure(
                    error,
                    conversationID: conversationID,
                    preservesContent: preservesContent,
                    profileID: profileID,
                    generation: requestGeneration
                )
            }
        }
        messageTask = task
        await task.value
    }

    private func beginConversationRequest(
        _ update: (inout MobileChatProfileState) -> Void
    ) -> Int {
        conversationTask?.cancel()
        conversationTask = nil
        conversationGeneration &+= 1
        updateActive(update)
        return conversationGeneration
    }

    private func beginMessageRequest(
        _ update: (inout MobileChatProfileState) -> Void
    ) -> Int {
        messageTask?.cancel()
        messageTask = nil
        messageGeneration &+= 1
        updateActive(update)
        return messageGeneration
    }

    private func beginSendRequest(
        _ update: (inout MobileChatProfileState) -> Void
    ) -> Int {
        sendTask?.cancel()
        sendTask = nil
        sendGeneration &+= 1
        updateActive(update)
        return sendGeneration
    }

    private func beginMessageDeleteRequest(
        _ update: (inout MobileChatProfileState) -> Void
    ) -> Int {
        messageDeleteTask?.cancel()
        messageDeleteTask = nil
        messageDeleteGeneration &+= 1
        updateActive(update)
        return messageDeleteGeneration
    }

    private func beginMemberRequest(
        _ update: (inout MobileChatProfileState) -> Void
    ) -> Int {
        memberTask?.cancel()
        memberTask = nil
        memberGeneration &+= 1
        updateActive(update)
        return memberGeneration
    }

    private func beginAnnouncementRequest(
        _ update: (inout MobileChatProfileState) -> Void
    ) -> Int {
        announcementTask?.cancel()
        announcementTask = nil
        announcementGeneration &+= 1
        updateActive(update)
        return announcementGeneration
    }

    private func cancelMessageWork() {
        messageTask?.cancel()
        messageTask = nil
        messageGeneration &+= 1
        updateActive {
            $0.isRefreshingMessages = false
            $0.isLoadingMoreMessages = false
        }
    }

    private func cancelMemberWork() {
        memberTask?.cancel()
        memberTask = nil
        memberGeneration &+= 1
        updateActive { profile in
            profile.isRefreshingMembers = false
            if let conversationID = profile.selectedConversationID,
               let cachedMembers = profile.membersByConversation[conversationID] {
                profile.memberPageState = cachedMembers.isEmpty ? .empty : .content
            } else {
                profile.memberPageState = .empty
            }
        }
    }

    private func cancelAnnouncementWork() {
        announcementTask?.cancel()
        announcementTask = nil
        announcementGeneration &+= 1
        updateActive { profile in
            profile.isRefreshingAnnouncements = false
            if let conversationID = profile.selectedConversationID,
               let cached = profile.announcementsByConversation[conversationID] {
                profile.announcementPageState = cached.isEmpty ? .empty : .content
            } else {
                profile.announcementPageState = .empty
            }
        }
    }

    private func finishConversations(
        _ conversations: [ChatConversation],
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentConversation(profileID: profileID, generation: generation) else { return }
        var invalidatesMessageLane = false
        var pinnedConversationIDsToSave: [String]?
        updateActive { profile in
            let locallyAdjusted = conversations.map {
                Self.applyingLocalReadState($0, profile: profile)
            }
            profile.conversations = Self.normalizedConversations(
                locallyAdjusted,
                pinnedConversationIDs: profile.pinnedConversationIDs
            )
            let availableConversationIDs = Set(profile.conversations.map(\.id))
            profile.locallyReadThroughActivityByConversationID =
                profile.locallyReadThroughActivityByConversationID.filter {
                    availableConversationIDs.contains($0.key)
                }
            let prunedPinnedConversationIDs = profile.pinnedConversationIDs.filter {
                availableConversationIDs.contains($0)
            }
            if prunedPinnedConversationIDs != profile.pinnedConversationIDs {
                profile.pinnedConversationIDs = prunedPinnedConversationIDs
                pinnedConversationIDsToSave = prunedPinnedConversationIDs
            }
            let encryptedIDs = Set(
                profile.conversations.lazy.filter(\.isEncrypted).map(\.id)
            )
            for conversationID in encryptedIDs {
                profile.messagesByConversation[conversationID] = nil
                profile.announcementsByConversation[conversationID] = nil
            }
            if let selectedID = profile.selectedConversationID,
               !profile.conversations.contains(where: { $0.id == selectedID }) {
                profile.selectedConversationID = nil
                if profile.visibleConversationID == selectedID {
                    profile.visibleConversationID = nil
                }
                profile.messagePageState = .empty
                invalidatesMessageLane = true
            } else if profile.selectedConversation?.isEncrypted == true {
                profile.messagePageState = .empty
                invalidatesMessageLane = true
            }
            Self.applyConversationFilter(to: &profile)
            profile.isRefreshingConversations = false
            profile.conversationErrorCategory = nil
        }
        if invalidatesMessageLane {
            cancelMessageWork()
            cancelMemberWork()
            cancelAnnouncementWork()
            attachmentModel.cancelAllWork()
        }
        if let pinnedConversationIDsToSave {
            conversationPinStore.savePinnedConversationIDs(pinnedConversationIDsToSave, profileID: profileID)
        }
        conversationTask = nil
    }

    private func finishUnavailable(profileID: UUID, generation: Int) {
        guard isCurrentConversation(profileID: profileID, generation: generation) else { return }
        updateActive { profile in
            profile.conversations = []
            profile.visibleConversations = []
            profile.selectedConversationID = nil
            profile.visibleConversationID = nil
            profile.messagesByConversation = [:]
            profile.membersByConversation = [:]
            profile.announcementsByConversation = [:]
            profile.conversationPageState = .empty
            profile.messagePageState = .empty
            profile.isRefreshingConversations = false
            profile.conversationErrorCategory = nil
        }
        cancelMessageWork()
        cancelMemberWork()
        cancelAnnouncementWork()
        attachmentModel.cancelAllWork()
        conversationTask = nil
    }

    private func finishMessages(
        _ page: ChatMessagePage,
        conversationID: String,
        appending: Bool,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentMessage(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID,
              state.selectedConversation?.isEncrypted == false else { return }
        updateActive { profile in
            let existing = appending
                ? profile.messagesByConversation[conversationID]?.messages ?? []
                : []
            let messages = Self.normalizedMessages(
                existing + page.messages.filter { $0.conversationID == conversationID }
            )
            profile.messagesByConversation[conversationID] = MobileChatMessageCache(
                messages: messages,
                previousCursor: page.previousCursor,
                hasMoreBefore: page.hasMoreBefore
            )
            profile.messagePageState = messages.isEmpty ? .empty : .content
            profile.isRefreshingMessages = false
            profile.isLoadingMoreMessages = false
            profile.loadMoreMessagesFailed = false
            profile.messageErrorCategory = nil
            if !appending, profile.visibleConversationID == conversationID {
                Self.markConversationReadLocally(
                    in: &profile,
                    conversationID: conversationID,
                    through: messages.map(\.sentAt).max()
                )
            }
            if !appending {
                profile.sendReviewBlockedTextsByConversation[conversationID] = nil
                profile.sendErrorCategory = nil
                profile.deleteReviewBlockedMessageIDsByConversation[conversationID] = nil
                profile.deleteMessageErrorCategory = nil
                profile.deleteMessageErrorID = nil
            }
        }
        messageTask = nil
        if !appending {
            attachmentModel.clearReviewAfterMessageRefresh()
        }
    }

    private func finishSendSuccess(
        _ message: ChatMessage,
        sentText: String,
        conversationID: String,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentSend(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID,
              state.selectedConversation?.isEncrypted == false,
              message.conversationID == conversationID else { return }
        updateActive { profile in
            let existing = profile.messagesByConversation[conversationID]?.messages ?? []
            let messages = Self.normalizedMessages(existing + [message])
            let previous = profile.messagesByConversation[conversationID]
            profile.messagesByConversation[conversationID] = MobileChatMessageCache(
                messages: messages,
                previousCursor: previous?.previousCursor,
                hasMoreBefore: previous?.hasMoreBefore ?? false
            )
            profile.messagePageState = messages.isEmpty ? .empty : .content
            if profile.draftsByConversation[conversationID]?.trimmingCharacters(in: .whitespacesAndNewlines) == sentText {
                profile.draftsByConversation[conversationID] = ""
            }
            profile.sendReviewBlockedTextsByConversation[conversationID]?.remove(sentText)
            profile.isSendingMessage = false
            profile.sendErrorCategory = nil
        }
        sendTask = nil
    }

    private func finishMessageDeleteSuccess(
        _ message: ChatMessage,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentMessageDelete(profileID: profileID, generation: generation),
              state.selectedConversationID == message.conversationID else { return }
        updateActive { profile in
            let previous = profile.messagesByConversation[message.conversationID]
            let messages = previous?.messages.filter { $0.id != message.id } ?? []
            profile.messagesByConversation[message.conversationID] = MobileChatMessageCache(
                messages: messages,
                previousCursor: previous?.previousCursor,
                hasMoreBefore: previous?.hasMoreBefore ?? false
            )
            profile.messagePageState = messages.isEmpty ? .empty : .content
            profile.deletingMessageID = nil
            profile.deleteMessageErrorCategory = nil
            profile.deleteMessageErrorID = nil
            if var blockedIDs = profile.deleteReviewBlockedMessageIDsByConversation[message.conversationID] {
                blockedIDs.remove(message.id)
                profile.deleteReviewBlockedMessageIDsByConversation[message.conversationID] =
                    blockedIDs.isEmpty ? nil : blockedIDs
            }
        }
        messageDeleteTask = nil
    }

    private func finishConversationMembers(
        _ members: [ChatUser],
        conversationID: String,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentMember(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID else { return }
        updateActive {
            $0.membersByConversation[conversationID] = members
            $0.memberPageState = members.isEmpty ? .empty : .content
            $0.isRefreshingMembers = false
            $0.memberErrorCategory = nil
        }
        memberTask = nil
    }

    private func finishConversationAnnouncements(
        _ announcements: [ChatMessage],
        conversationID: String,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentAnnouncement(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID,
              state.selectedConversation?.isEncrypted == false else { return }
        updateActive {
            $0.announcementsByConversation[conversationID] = announcements
            $0.announcementPageState = announcements.isEmpty ? .empty : .content
            $0.isRefreshingAnnouncements = false
            $0.announcementErrorCategory = nil
        }
        announcementTask = nil
    }

    private func finishSendFailure(
        _ error: Error,
        sentText: String,
        conversationID: String,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentSend(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID else { return }
        updateActive {
            $0.isSendingMessage = false
            $0.sendErrorCategory = Self.category(for: error)
            $0.sendReviewBlockedTextsByConversation[conversationID, default: []].insert(sentText)
        }
        sendTask = nil
    }

    private func finishMessageDeleteFailure(
        _ error: Error,
        message: ChatMessage,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentMessageDelete(profileID: profileID, generation: generation),
              state.selectedConversationID == message.conversationID else { return }
        let category = Self.category(for: error)
        updateActive {
            $0.deletingMessageID = nil
            $0.deleteMessageErrorCategory = category
            $0.deleteMessageErrorID = message.id
            if category == .partialFailure {
                $0.deleteReviewBlockedMessageIDsByConversation[message.conversationID, default: []]
                    .insert(message.id)
            }
        }
        messageDeleteTask = nil
    }

    private func finishSendOutcome(
        _ outcome: ChatMessageSendOutcome,
        sentText: String,
        conversationID: String,
        profileID: UUID,
        generation: Int
    ) {
        switch outcome.result.status {
        case .confirmedSuccess:
            guard let message = outcome.confirmedMessage else {
                finishSendReview(
                    sentText: sentText,
                    conversationID: conversationID,
                    profileID: profileID,
                    generation: generation
                )
                return
            }
            finishSendSuccess(
                message,
                sentText: sentText,
                conversationID: conversationID,
                profileID: profileID,
                generation: generation
            )
        case .cancelledBeforeSubmission:
            finishSendCancellation(profileID: profileID, generation: generation)
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            finishSendReview(
                sentText: sentText,
                conversationID: conversationID,
                profileID: profileID,
                generation: generation
            )
        case .permissionDenied, .confirmedFailure, .partialSuccess, .unsupported:
            finishSendFailure(
                Self.appError(for: outcome.result),
                sentText: sentText,
                conversationID: conversationID,
                profileID: profileID,
                generation: generation
            )
        }
    }

    private func finishSendReview(
        sentText: String,
        conversationID: String,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentSend(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID else { return }
        updateActive {
            $0.isSendingMessage = false
            $0.sendErrorCategory = .partialFailure
            $0.sendReviewBlockedTextsByConversation[conversationID, default: []].insert(sentText)
        }
        sendTask = nil
    }

    private func finishConversationFailure(
        _ error: Error,
        preservesContent: Bool,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentConversation(profileID: profileID, generation: generation) else { return }
        updateActive {
            $0.isRefreshingConversations = false
            $0.conversationErrorCategory = Self.category(for: error)
            if !preservesContent { $0.conversationPageState = .error }
        }
        conversationTask = nil
    }

    private func finishMessageFailure(
        _ error: Error,
        conversationID: String,
        preservesContent: Bool,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentMessage(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID else { return }
        updateActive {
            $0.isRefreshingMessages = false
            $0.messageErrorCategory = Self.category(for: error)
            if !preservesContent { $0.messagePageState = .error }
        }
        messageTask = nil
    }

    private func finishLoadMoreFailure(
        _ error: Error,
        conversationID: String,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentMessage(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID else { return }
        updateActive {
            $0.isLoadingMoreMessages = false
            $0.loadMoreMessagesFailed = true
            $0.messageErrorCategory = Self.category(for: error)
        }
        messageTask = nil
    }

    private func finishMemberFailure(
        _ error: Error,
        conversationID: String,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentMember(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID else { return }
        updateActive {
            $0.memberPageState = .error
            $0.isRefreshingMembers = false
            $0.memberErrorCategory = Self.category(for: error)
        }
        memberTask = nil
    }

    private func finishAnnouncementFailure(
        _ error: Error,
        conversationID: String,
        profileID: UUID,
        generation: Int
    ) {
        guard isCurrentAnnouncement(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID else { return }
        updateActive {
            $0.announcementPageState = .error
            $0.isRefreshingAnnouncements = false
            $0.announcementErrorCategory = Self.category(for: error)
        }
        announcementTask = nil
    }

    private func finishConversationCancellation(profileID: UUID, generation: Int) {
        guard isCurrentConversation(profileID: profileID, generation: generation) else { return }
        updateActive {
            $0.isRefreshingConversations = false
        }
        conversationTask = nil
    }

    private func finishMessageCancellation(profileID: UUID, generation: Int) {
        guard isCurrentMessage(profileID: profileID, generation: generation) else { return }
        updateActive {
            $0.isRefreshingMessages = false
            $0.isLoadingMoreMessages = false
        }
        messageTask = nil
    }

    private func finishMemberCancellation(profileID: UUID, generation: Int) {
        guard isCurrentMember(profileID: profileID, generation: generation) else { return }
        updateActive { $0.isRefreshingMembers = false }
        memberTask = nil
    }

    private func finishAnnouncementCancellation(profileID: UUID, generation: Int) {
        guard isCurrentAnnouncement(profileID: profileID, generation: generation) else { return }
        updateActive { $0.isRefreshingAnnouncements = false }
        announcementTask = nil
    }

    private func finishSendCancellation(profileID: UUID, generation: Int) {
        guard isCurrentSend(profileID: profileID, generation: generation) else { return }
        updateActive {
            $0.isSendingMessage = false
        }
        sendTask = nil
    }

    private func finishMessageDeleteCancellation(profileID: UUID, generation: Int) {
        guard isCurrentMessageDelete(profileID: profileID, generation: generation) else { return }
        updateActive {
            $0.deletingMessageID = nil
        }
        messageDeleteTask = nil
    }

    func updateActive(_ update: (inout MobileChatProfileState) -> Void) {
        guard let activeProfileID else { return }
        var profile = profiles[activeProfileID] ?? MobileChatProfileState()
        update(&profile)
        profiles[activeProfileID] = profile
    }

    func attachmentRepository(for profileID: UUID) -> (any ChatRepository)? {
        repositories[profileID]
    }

    private func isCurrentConversation(profileID: UUID, generation: Int) -> Bool {
        activeProfileID == profileID && conversationGeneration == generation
    }

    private func isCurrentMessage(profileID: UUID, generation: Int) -> Bool {
        activeProfileID == profileID && messageGeneration == generation
    }

    private func isCurrentMember(profileID: UUID, generation: Int) -> Bool {
        activeProfileID == profileID && memberGeneration == generation
    }

    private func isCurrentAnnouncement(profileID: UUID, generation: Int) -> Bool {
        activeProfileID == profileID && announcementGeneration == generation
    }

    private func isCurrentSend(profileID: UUID, generation: Int) -> Bool {
        activeProfileID == profileID && sendGeneration == generation
    }

    private func isCurrentMessageDelete(profileID: UUID, generation: Int) -> Bool {
        activeProfileID == profileID && messageDeleteGeneration == generation
    }

    private func isCurrentRealtime(profileID: UUID, generation: Int) -> Bool {
        foregroundRealtimeRequested
            && activeProfileID == profileID
            && realtimeGeneration == generation
            && repositories[profileID] != nil
    }

    private static func applyConversationFilter(to profile: inout MobileChatProfileState) {
        let query = profile.conversationFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            profile.visibleConversations = profile.conversations
        } else {
            profile.visibleConversations = profile.conversations.filter {
                $0.title.localizedStandardContains(query)
            }
        }
        if profile.visibleConversations.isEmpty {
            profile.conversationPageState = query.isEmpty ? .empty : .filteredEmpty
        } else {
            profile.conversationPageState = .content
        }
    }

    private static func normalizedConversations(
        _ conversations: [ChatConversation],
        pinnedConversationIDs: [String] = []
    ) -> [ChatConversation] {
        var valuesByID: [String: ChatConversation] = [:]
        for conversation in conversations { valuesByID[conversation.id] = conversation }
        var pinnedRanks: [String: Int] = [:]
        for conversationID in pinnedConversationIDs where pinnedRanks[conversationID] == nil {
            pinnedRanks[conversationID] = pinnedRanks.count
        }
        return valuesByID.values.sorted { lhs, rhs in
            switch (pinnedRanks[lhs.id], pinnedRanks[rhs.id]) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                break
            }
            switch (lhs.lastActivityAt, rhs.lastActivityAt) {
            case let (left?, right?) where left != right:
                return left > right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.id < rhs.id
            }
        }
    }

    private static func normalizedPinnedConversationIDs(_ conversationIDs: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for conversationID in conversationIDs {
            let trimmed = conversationID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
            seen.insert(trimmed)
            result.append(trimmed)
        }
        return result
    }

    private static func markConversationReadLocally(
        in profile: inout MobileChatProfileState,
        conversationID: String,
        through activity: Date?
    ) {
        guard let activity else { return }
        let existing = profile.locallyReadThroughActivityByConversationID[conversationID]
            ?? .distantPast
        profile.locallyReadThroughActivityByConversationID[conversationID] = max(existing, activity)
        guard let index = profile.conversations.firstIndex(where: { $0.id == conversationID }) else {
            return
        }
        let conversation = profile.conversations[index]
        if let conversationActivity = conversation.lastActivityAt,
           conversationActivity > activity {
            return
        }
        profile.conversations[index] = Self.conversation(conversation, unreadCount: 0)
        applyConversationFilter(to: &profile)
    }

    private static func applyingLocalReadState(
        _ conversation: ChatConversation,
        profile: MobileChatProfileState
    ) -> ChatConversation {
        guard let readThrough = profile.locallyReadThroughActivityByConversationID[conversation.id],
              let activity = conversation.lastActivityAt,
              activity <= readThrough else {
            return conversation
        }
        return self.conversation(conversation, unreadCount: 0)
    }

    private static func conversation(
        _ value: ChatConversation,
        unreadCount: Int
    ) -> ChatConversation {
        ChatConversation(
            id: value.id,
            kind: value.kind,
            title: value.title,
            memberIDs: value.memberIDs,
            memberCount: value.memberCount,
            lastMessageSummary: value.lastMessageSummary,
            lastActivityAt: value.lastActivityAt,
            unreadCount: unreadCount,
            isEncrypted: value.isEncrypted
        )
    }

    static func normalizedMessages(_ messages: [ChatMessage]) -> [ChatMessage] {
        var valuesByID: [String: ChatMessage] = [:]
        for message in messages { valuesByID[message.id] = message }
        return valuesByID.values.sorted {
            $0.sentAt == $1.sentAt ? $0.id < $1.id : $0.sentAt < $1.sentAt
        }
    }

    private static func category(for error: Error) -> AppErrorCategory {
        (error as? AppError)?.category ?? .unknown
    }

    private static func appError(for result: MutationResult) -> AppError {
        AppError(
            category: appErrorCategory(for: result.errorCategory),
            isRetryable: result.status != .unsupported && result.status != .permissionDenied,
            safeUserMessage: ""
        )
    }

    private static func appErrorCategory(for category: MutationErrorCategory?) -> AppErrorCategory {
        switch category {
        case .authentication: .authenticationRequired
        case .permission: .permissionDenied
        case .conflict: .conflict
        case .network: .networkUnavailable
        case .server: .serverBusy
        case .unsupported: .apiUnavailable
        case .validation: .invalidResponse
        case .unknown, nil: .unknown
        }
    }
}
