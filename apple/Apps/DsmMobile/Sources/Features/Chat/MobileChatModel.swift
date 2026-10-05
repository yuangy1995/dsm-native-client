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
    private(set) var interaction: MobileChatInteractionModel?
    private(set) var management: MobileChatManagementModel?
    private let managementRecovery: MobileChatManagementStore
    private(set) var timedActions: MobileChatTimedActionModel?
    private let timedActionRecovery: MobileChatTimedActionStore
    private(set) var polls: MobileChatPollModel?
    private let pollRecovery: MobileChatPollStore
    private let interactionRecovery: MobileChatInteractionStore
    private let conversationCreationRecovery: MobileChatConversationCreationStore
    private let groupCreationRecovery: MobileChatGroupCreationStore
    private(set) var forwarding: MobileChatForwardModel?
    private let forwardRecovery: MobileChatForwardStore
    private(set) var deletion: MobileChatDeletionModel?
    private let deletionRecovery: MobileChatDeletionStore
    private(set) var sending: MobileChatSendModel?
    private let sendRecovery: MobileChatSendStore
    let audio: MobileChatAudioModel
    let notifications: MobileChatNotifications

    @ObservationIgnored private var repositories: [UUID: any ChatRepository] = [:]
    @ObservationIgnored private var conversationTask: Task<Void, Never>?
    @ObservationIgnored private var messageTask: Task<Void, Never>?
    @ObservationIgnored private var memberTask: Task<Void, Never>?
    @ObservationIgnored private var announcementTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeTask: Task<Void, Never>?
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeSyncTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeStopTask: Task<Void, Never>?
    @ObservationIgnored private var conversationGeneration = 0
    @ObservationIgnored private var messageGeneration = 0
    @ObservationIgnored private var memberGeneration = 0
    @ObservationIgnored private var announcementGeneration = 0
    @ObservationIgnored private var realtimeGeneration = 0
    @ObservationIgnored private var foregroundRealtimeRequested = false
    @ObservationIgnored private var conversationVisibilityOwner: UUID?
    @ObservationIgnored private var readTask: Task<Void, Never>?
    @ObservationIgnored private var readGeneration = 0
    private(set) var visibleReadMessageID: String?
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
        realtimeDebounceIntervalNanoseconds: UInt64 = 200_000_000,
        interactionRecoveryRoot: URL? = nil,
        audioDriver: (any MobileChatAudioDriving)? = nil,
        notifications: MobileChatNotifications = MobileChatNotifications()
    ) {
        self.notifications = notifications
        self.audio = MobileChatAudioModel(driver: audioDriver ?? MobileSystemChatAudioDriver(),
            root: attachmentFileManager.temporaryDirectory.appendingPathComponent("LanStashChatAudio", isDirectory: true))
        self.interactionRecovery = MobileChatInteractionStore(root: interactionRecoveryRoot)
        self.conversationCreationRecovery = MobileChatConversationCreationStore(root: interactionRecoveryRoot)
        self.groupCreationRecovery = MobileChatGroupCreationStore(root: interactionRecoveryRoot)
        self.forwardRecovery = MobileChatForwardStore(root: interactionRecoveryRoot)
        self.deletionRecovery = MobileChatDeletionStore(root: interactionRecoveryRoot)
        self.sendRecovery = MobileChatSendStore(root: interactionRecoveryRoot)
        self.pollRecovery = MobileChatPollStore(root: interactionRecoveryRoot)
        self.managementRecovery = MobileChatManagementStore(root: interactionRecoveryRoot)
        self.timedActionRecovery = MobileChatTimedActionStore(root: interactionRecoveryRoot)
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
        var value = profiles[activeProfileID] ?? MobileChatProfileState()
        value.isSendingMessage = sending?.isBusy == true && sending?.runningKind != .attachment
        value.isSendingAttachment = sending?.isBusy == true && sending?.runningKind == .attachment
        value.attachmentProgressFraction = sending?.progressFraction
        value.selectedDraftRequiresReview = sending?.pendingText(value.selectedDraft, conversationID: value.selectedConversationID ?? "") == true
        value.attachmentReviewRequired = sending?.entries.contains { $0.phase == .submitted && $0.kind == .attachment
            && $0.conversationID == value.selectedConversationID } == true
        return value
    }

    var conversationCreator: MobileChatConversationCreator? {
        guard let activeProfileID else { return nil }
        return conversationCreators[activeProfileID]
    }

    var canCreateConversation: Bool {
        conversationCreator?.requiresReview == true
            || conversationCreator?.groupEntries.isEmpty == false || conversationCreator?.storageFailed == true
            || conversationCreator?.canCreateDirect == true || conversationCreator?.canCreateGroup == true
    }

    var canSelectAttachment: Bool {
        attachmentModel.canSelectAttachment && !audio.isRecording && !audio.isRequestingPermission
    }

    var canRecordVoice: Bool {
        canSelectAttachment && selectedAttachment == nil && state.availability.supportedFeatures.contains(.voiceMessage)
    }

    func startVoiceRecording() async {
        guard canRecordVoice else { return }
        attachmentModel.cancelRemoteAttachmentDownload()
        await audio.startRecording { [weak self] in self?.canRecordVoice == true }
    }

    func sendVoiceRecording() async {
        guard canRecordVoice, let sender = sending, let profileID = activeProfileID,
              let conversationID = state.selectedConversationID, let (recording, duration) = audio.takeRecording() else { return }
        let oldIDs = Set(sender.entries.map(\.id))
        let completed = await sender.send(conversationID: conversationID, text: nil, attachment: recording)
        let saved = sender.entries.contains { !oldIDs.contains($0.id) }
        if !completed, !saved, activeProfileID == profileID, sending === sender, state.selectedConversationID == conversationID {
            audio.restoreRecording(recording, duration: duration)
        } else {
            try? attachmentFileManager.removeItem(at: recording.directoryURL)
        }
    }

    func toggleVoicePlayback(_ attachment: ChatAttachment, in message: ChatMessage) {
        guard canUseRemoteAttachment(attachment, in: message), attachment.kind == .voice,
              !audio.isRecording, !audio.isRequestingPermission else { return }
        if audio.playbackID == message.id { audio.togglePlayback() }
        else {
            audio.stopPlayback()
            attachmentModel.playVoiceAttachment(attachment, in: message)
        }
    }

    func interruptChatAudio() {
        audio.interrupt()
        attachmentModel.cancelRemoteAttachmentDownload()
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

    func canDeleteMessage(_ message: ChatMessage) -> Bool { deletion?.canSelect(message) == true }

    func activate(profileID: UUID?, repository: (any ChatRepository)?, context: String? = nil) async {
        if let activeProfileID {
            profiles[activeProfileID]?.visibleConversationID = nil
        }
        cancelAllWork()
        guard let profileID else {
            notifications.configure(context: nil)
            activeProfileID = nil
            return
        }
        guard let repository else {
            notifications.configure(context: nil)
            repositories[profileID] = nil
            activeProfileID = nil
            return
        }

        activeProfileID = profileID
        notifications.configure(context: context ?? profileID.uuidString)
        let mobileRepository = MobileReadOnlyChatRepository(base: repository)
        repositories[profileID] = mobileRepository
        let sender = MobileChatSendModel(context: context ?? profileID.uuidString, repository: mobileRepository,
            recovery: sendRecovery, copier: attachmentCopier, owner: self)
        sending = sender
        sender.updateAvailability(profiles[profileID]?.availability ?? ChatAvailability(status: .requiresValidation))
        interaction = MobileChatInteractionModel(context: context ?? profileID.uuidString,
            repository: mobileRepository, recovery: interactionRecovery, sending: sender, owner: self)
        interaction?.updateAvailability(profiles[profileID]?.availability ?? ChatAvailability(status: .requiresValidation))
        polls = MobileChatPollModel(context: context ?? profileID.uuidString, repository: mobileRepository, recovery: pollRecovery, owner: self)
        polls?.updateAvailability(profiles[profileID]?.availability ?? ChatAvailability(status: .requiresValidation))
        management = MobileChatManagementModel(context: context ?? profileID.uuidString, repository: mobileRepository, recovery: managementRecovery, owner: self)
        management?.updateAvailability(profiles[profileID]?.availability ?? ChatAvailability(status: .requiresValidation))
        timedActions = MobileChatTimedActionModel(context: context ?? profileID.uuidString, repository: mobileRepository, recovery: timedActionRecovery, owner: self)
        timedActions?.updateAvailability(profiles[profileID]?.availability ?? ChatAvailability(status: .requiresValidation))
        forwarding = MobileChatForwardModel(context: context ?? profileID.uuidString, repository: mobileRepository, recovery: forwardRecovery, owner: self)
        forwarding?.updateAvailability(profiles[profileID]?.availability ?? ChatAvailability(status: .requiresValidation))
        deletion = MobileChatDeletionModel(context: context ?? profileID.uuidString, repository: mobileRepository, recovery: deletionRecovery, owner: self)
        deletion?.updateAvailability(profiles[profileID]?.availability ?? ChatAvailability(status: .requiresValidation))
        let creationContext = context ?? profileID.uuidString
        if let creator = conversationCreators[profileID], creator.context == creationContext {
            creator.rebind(
                repository: mobileRepository,
                availability: profiles[profileID]?.availability
                    ?? ChatAvailability(status: .requiresValidation)
            )
        } else {
            conversationCreators[profileID] = MobileChatConversationCreator(
                repository: mobileRepository,
                availability: profiles[profileID]?.availability
                    ?? ChatAvailability(status: .requiresValidation),
                context: creationContext,
                recovery: conversationCreationRecovery,
                groupRecovery: groupCreationRecovery,
                owner: self
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
        notifications.configure(context: nil)
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
            notifications.configure(context: nil)
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

    var isForegroundActive: Bool { foregroundRealtimeRequested }

    /// 当前账号允许聊天时在 App 前台运行；后台停止，不承诺挂起后即时到达。
    func setForegroundRealtimeActive(_ isActive: Bool) async {
        foregroundRealtimeRequested = isActive
        notifications.isForeground = isActive
        if isActive {
            await waitForForegroundRealtimeStop()
            startForegroundRealtimeIfNeeded()
        } else {
            visibleReadMessageID = nil
            interaction?.clearVisibleReply()
            cancelReadSynchronization()
            scheduleForegroundRealtimeStop()
            await waitForForegroundRealtimeStop()
        }
    }

    func leaveChatPage() {
        conversationVisibilityOwner = nil
        visibleReadMessageID = nil
        cancelReadSynchronization()
        updateActive { $0.visibleConversationID = nil }
        interaction?.closeDiscussion()
        attachmentModel.cancelAllWork()
    }

    func notificationMessage(_ destination: MobileChatNotifications.Destination) async throws -> ChatMessage? {
        guard notifications.enabled, notifications.scope == destination.scope,
              let profileID = activeProfileID, let repository = repositories[profileID] else { throw CancellationError() }
        let conversations = try await repository.listConversations()
        guard activeProfileID == profileID, notifications.scope == destination.scope,
              conversations.contains(where: { $0.id == destination.conversationID && !$0.isEncrypted }) else { return nil }
        let value = try await repository.message(conversationID: destination.conversationID, messageID: destination.messageID, threadID: nil)
        guard activeProfileID == profileID, notifications.scope == destination.scope, !Task.isCancelled else { throw CancellationError() }
        guard let value, value.conversationID == destination.conversationID, value.id == destination.messageID,
              value.encryptionState == .notEncrypted else { return nil }
        return value
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
            self?.notifications.configure(context: availability.status == .available ? self?.sending?.context : nil)
            self?.notifications.isForeground = self?.foregroundRealtimeRequested == true
            self?.sending?.updateAvailability(availability)
            self?.interaction?.updateAvailability(availability)
            self?.polls?.updateAvailability(availability)
            self?.timedActions?.updateAvailability(availability)
            self?.management?.updateAvailability(availability)
            self?.forwarding?.updateAvailability(availability)
            self?.deletion?.updateAvailability(availability)
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
        if isCurrentConversation(profileID: profileID, generation: requestGeneration) {
            await management?.recover()
            guard isCurrentConversation(profileID: profileID, generation: requestGeneration) else { return }
            await notifications.processIncoming(state.conversations, repository: repository) { [weak self] id in
                self?.state.visibleConversationID == id && self?.visibleReadMessageID != nil
            }
            guard isCurrentConversation(profileID: profileID, generation: requestGeneration),
                  state.availability.supportedFeatures.contains(.reminderManagement) else { return }
            await notifications.refreshReminders(conversations: state.conversations, repository: repository)
        }
    }

    func selectConversation(_ conversation: ChatConversation) async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let canonical = state.conversations.first(where: { $0.id == conversation.id }) else {
            return
        }
        attachmentModel.cancelAllWork()
        visibleReadMessageID = nil
        cancelReadSynchronization()
        cancelMessageWork()
        cancelMemberWork()
        cancelAnnouncementWork()
        updateActive { profile in
            profile.selectedConversationID = canonical.id
            profile.messageErrorCategory = nil
            profile.memberErrorCategory = nil
            profile.announcementErrorCategory = nil
            profile.sendErrorCategory = nil
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
        sourceProfileID: UUID,
        sourceCreator: MobileChatConversationCreator,
        sourceGeneration: Int
    ) async -> Bool {
        guard activeProfileID == sourceProfileID, !conversation.isEncrypted,
              conversationCreator === sourceCreator,
              sourceCreator.repositoryGeneration == sourceGeneration else { return false }
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
            && conversationCreator === sourceCreator
            && sourceCreator.repositoryGeneration == sourceGeneration
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

    func refreshMessages(preservingHistory: Bool = false) async {
        guard let profileID = activeProfileID,
              let repository = repositories[profileID],
              let conversation = state.selectedConversation,
              !conversation.isEncrypted else { return }
        await replaceMessages(
            conversationID: conversation.id,
            profileID: profileID,
            repository: repository,
            preservesContent: !state.selectedMessages.messages.isEmpty,
            preservingHistory: preservingHistory
        )
        if activeProfileID == profileID {
            await interaction?.recoverEdits()
            guard activeProfileID == profileID else { return }
            await polls?.recover()
            await timedActions?.recover()
            await management?.recover()
        }
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
        if selectedAttachment != nil { await attachmentModel.sendSelectedAttachment(); return }
        guard canSendSelectedDraft, let sending, let conversation = state.selectedConversation else { return }
        await sending.send(conversationID: conversation.id, text: state.selectedDraft)
    }

    func deleteMessage(_ message: ChatMessage) async {
        guard let deletion, let id = deletion.createBatch([message]) else { return }
        await deletion.run(id, continuePlanned: true)
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

    func leaveConversation(_ conversationID: String, ownerID: UUID? = nil, preservingVoiceRecording: Bool = false) {
        guard conversationVisibilityOwner == ownerID else { return }
        conversationVisibilityOwner = nil
        visibleReadMessageID = nil
        cancelReadSynchronization()
        updateActive { profile in
            if profile.visibleConversationID == conversationID {
                profile.visibleConversationID = nil
            }
        }
        attachmentModel.leaveConversation(conversationID, preservingAudio: preservingVoiceRecording)
    }

    func enterConversation(_ conversationID: String, ownerID: UUID? = nil) {
        guard state.conversations.contains(where: { $0.id == conversationID }) else { return }
        conversationVisibilityOwner = ownerID
        updateActive { profile in
            profile.visibleConversationID = conversationID
        }
    }

    /// 只接收当前页面实例、当前最新消息的实际可见位置；预加载不会推进已读。
    func updateVisibleMessage(_ messageID: String, isVisible: Bool, conversationID: String, ownerID: UUID? = nil) {
        guard conversationVisibilityOwner == ownerID,
              state.visibleConversationID == conversationID,
              state.selectedConversationID == conversationID,
              state.selectedMessages.messages.last(where: { $0.deliveryState == .sent })?.id == messageID else { return }
        visibleReadMessageID = isVisible ? messageID : nil
        if isVisible { requestReadSynchronization() }
        else { cancelReadSynchronization() }
    }

    private func requestReadSynchronization() {
        guard readTask == nil, foregroundRealtimeRequested,
              let profileID = activeProfileID, let repository = repositories[profileID],
              let conversation = state.selectedConversation, !conversation.isEncrypted,
              state.visibleConversationID == conversation.id,
              state.availability.supportedFeatures.contains(.readSynchronization),
              let latest = state.selectedMessages.messages.last(where: { $0.deliveryState == .sent }),
              latest.id == visibleReadMessageID,
              latest.sentAt > max(state.synchronizedReadThroughByConversationID[conversation.id] ?? .distantPast,
                  conversation.lastViewedAt ?? .distantPast) else { return }
        let generation = readGeneration
        readTask = Task { [weak self] in
            defer { if self?.readGeneration == generation { self?.readTask = nil } }
            do {
                let updated = try await repository.markRead(conversationID: conversation.id, through: latest.sentAt)
                try Task.checkCancellation()
                guard let self, self.activeProfileID == profileID, self.readGeneration == generation,
                      updated.id == conversation.id, updated.lastViewedAt.map({ $0 >= latest.sentAt }) == true else { return }
                self.updateActive { profile in
                    profile.synchronizedReadThroughByConversationID[conversation.id] = latest.sentAt
                    guard let index = profile.conversations.firstIndex(where: { $0.id == conversation.id }) else { return }
                    // 同步期间可能已有新活动；旧回读不能覆盖更晚的会话摘要或未读。
                    if (updated.lastActivityAt ?? .distantPast) >= (profile.conversations[index].lastActivityAt ?? .distantPast) {
                        profile.conversations[index] = updated
                        Self.applyConversationFilter(to: &profile)
                    }
                }
            } catch {
                // 保留原未读；下一次可见刷新重试，不把本机清零当作跨设备成功。
            }
        }
    }

    private func cancelReadSynchronization() {
        readGeneration &+= 1
        readTask?.cancel()
        readTask = nil
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
        conversationVisibilityOwner = nil
        visibleReadMessageID = nil
        cancelReadSynchronization()
        sending?.invalidate()
        sending = nil
        deletion?.invalidate()
        deletion = nil
        forwarding?.invalidate()
        forwarding = nil
        conversationCreator?.invalidate()
        management?.invalidate()
        management = nil
        timedActions?.invalidate()
        timedActions = nil
        polls?.invalidate()
        polls = nil
        interaction?.invalidate()
        interaction = nil
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
              pollingTask == nil,
              let profileID = activeProfileID,
              let repository = repositories[profileID],
              state.availability.status == .available else { return }

        realtimeGeneration &+= 1
        let generation = realtimeGeneration
        realtimeConnected = false
        startPollingIfNeeded(profileID: profileID, repository: repository, generation: generation)
        requestRealtimeSync(profileID: profileID, generation: generation, waitsForDebounce: true)
        #if DEBUG
        // 显式 UI 测试使用合成服务和轮询；不启动独立的真实 Socket 连接。
        if MobileUIFixture.isEnabled { return }
        #endif
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
            requestRealtimeSync(profileID: profileID, generation: generation, waitsForDebounce: true)
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
        guard pollingTask == nil,
              isCurrentRealtime(profileID: profileID, generation: generation) else { return }
        let interval = realtimePollingIntervalNanoseconds
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return
                }
                guard self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else { return }
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
                await self?.refreshVisibleMessages()
                guard self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else { break }
                await self?.interaction?.refreshVisibleDiscussion()
                self?.requestReadSynchronization()
            }
            guard self?.isCurrentRealtime(profileID: profileID, generation: generation) == true else {
                return
            }
            self?.realtimeSyncTask = nil
        }
    }

    private func refreshVisibleMessages() async {
        // 阅读历史时保留页面和分页游标；新活动仍更新会话列表，回到最新消息后再取新页。
        guard state.visibleConversationID == state.selectedConversationID,
              !state.isLoadingMoreMessages, !state.isRefreshingMessages,
              state.selectedMessages.messages.isEmpty || visibleReadMessageID != nil else { return }
        await refreshMessages(preservingHistory: true)
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
              let (repository, tasks) = cancelForegroundRealtimeTasks() else { return }
        realtimeStopTask = Task {
            // 取消只是发出停止请求；等刷新及其子请求结束后再完成前台停止。
            for task in tasks { await task.value }
            await repository.stopRealtime()
        }
    }

    private func waitForForegroundRealtimeStop() async {
        guard let realtimeStopTask else { return }
        await realtimeStopTask.value
        self.realtimeStopTask = nil
    }

    private func cancelForegroundRealtimeTasks() -> ((any ChatRepository), [Task<Void, Never>])? {
        let repository = activeProfileID.flatMap { repositories[$0] }
        let tasks = [realtimeTask, realtimeSyncTask].compactMap { $0 }
        realtimeGeneration &+= 1
        realtimeTask?.cancel()
        realtimeTask = nil
        pollingTask?.cancel()
        pollingTask = nil
        realtimeDebounceTask?.cancel()
        realtimeDebounceTask = nil
        realtimeSyncTask?.cancel()
        if realtimeSyncTask != nil {
            conversationTask?.cancel(); conversationTask = nil; conversationGeneration &+= 1
            cancelMessageWork()
            updateActive { $0.isRefreshingConversations = false }
        }
        realtimeSyncTask = nil
        pendingRealtimeSync = false
        realtimeConnected = false
        guard let repository else { return nil }
        return (repository, tasks)
    }

    private func replaceMessages(
        conversationID: String,
        profileID: UUID,
        repository: any ChatRepository,
        preservesContent: Bool,
        preservingHistory: Bool = false
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
                    generation: requestGeneration,
                    preservingHistory: preservingHistory
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
            profile.conversations = Self.normalizedConversations(
                conversations,
                pinnedConversationIDs: profile.pinnedConversationIDs
            )
            let availableConversationIDs = Set(profile.conversations.map(\.id))
            profile.synchronizedReadThroughByConversationID =
                profile.synchronizedReadThroughByConversationID.filter {
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
        startForegroundRealtimeIfNeeded()
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
        generation: Int,
        preservingHistory: Bool = false
    ) {
        guard isCurrentMessage(profileID: profileID, generation: generation),
              state.selectedConversationID == conversationID,
              state.selectedConversation?.isEncrypted == false else { return }
        updateActive { profile in
            let cached = profile.messagesByConversation[conversationID]
            let incoming = Self.normalizedMessages(page.messages.filter { $0.conversationID == conversationID })
            let incomingIDs = Set(incoming.map(\.id))
            let overlapsHistory = cached?.messages.contains(where: { incomingIDs.contains($0.id) }) == true
            if preservingHistory, page.hasMoreBefore, !overlapsHistory, cached?.messages.isEmpty == false {
                // 新页与已读历史之间有缺口时保留当前位置；用户通过“最新消息”重新定位。
                profile.isRefreshingMessages = false
                return
            }
            let older = preservingHistory && page.hasMoreBefore && overlapsHistory
                ? (cached?.messages ?? []).filter { $0.sentAt < (incoming.first?.sentAt ?? .distantPast) }
                : []
            let existing = appending
                ? profile.messagesByConversation[conversationID]?.messages ?? []
                : older
            let messages = Self.normalizedMessages(
                existing + incoming
            )
            profile.messagesByConversation[conversationID] = MobileChatMessageCache(
                messages: messages,
                previousCursor: older.isEmpty ? page.previousCursor : cached?.previousCursor,
                hasMoreBefore: older.isEmpty ? page.hasMoreBefore : cached?.hasMoreBefore == true
            )
            profile.messagePageState = messages.isEmpty ? .empty : .content
            profile.isRefreshingMessages = false
            profile.isLoadingMoreMessages = false
            profile.loadMoreMessagesFailed = false
            profile.messageErrorCategory = nil
        }
        messageTask = nil
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

    func updateActive(_ update: (inout MobileChatProfileState) -> Void) {
        guard let activeProfileID else { return }
        var profile = profiles[activeProfileID] ?? MobileChatProfileState()
        update(&profile)
        profiles[activeProfileID] = profile
    }

    func applyPollMessage(_ message: ChatMessage, created: Bool) {
        if let interaction { interaction.update(message) }
        else { applyInteractionMessage(message) }
        if created {
            updateActive { profile in
                guard var cache = profile.messagesByConversation[message.conversationID],
                      !cache.messages.contains(where: { $0.id == message.id }) else { return }
                cache.messages.append(message)
                cache.messages.sort { $0.sentAt < $1.sentAt }
                profile.messagesByConversation[message.conversationID] = cache
            }
        }
    }

    func applyInteractionMessage(_ message: ChatMessage) {
        updateActive { profile in
            if let index = profile.messagesByConversation[message.conversationID]?.messages.firstIndex(where: { $0.id == message.id }) {
                profile.messagesByConversation[message.conversationID]?.messages[index] = message
            }
            if let index = profile.announcementsByConversation[message.conversationID]?.firstIndex(where: { $0.id == message.id }) {
                profile.announcementsByConversation[message.conversationID]?[index] = message
            }
        }
    }

    func applySentMessage(_ message: ChatMessage, text: String?) {
        guard message.threadID == nil else { return }
        if state.selectedConversationID == message.conversationID { cancelMessageWork() }
        updateActive { profile in
            var cache = profile.messagesByConversation[message.conversationID] ?? MobileChatMessageCache()
            cache.messages = Self.normalizedMessages(cache.messages + [message])
            profile.messagesByConversation[message.conversationID] = cache
            if profile.draftsByConversation[message.conversationID]?.trimmingCharacters(in: .whitespacesAndNewlines) == (text ?? "") {
                profile.draftsByConversation[message.conversationID] = ""
            }
            if profile.selectedConversationID == message.conversationID { profile.messagePageState = .content }
            profile.sendErrorCategory = nil
        }
    }

    func applyMessageDeletion(_ source: ChatMessageDeletionSnapshot) {
        if state.selectedConversationID == source.conversationID {
            cancelMessageWork(); cancelAnnouncementWork()
        }
        updateActive { profile in
            profile.messagesByConversation[source.conversationID]?.messages.removeAll { $0.id == source.messageID }
            profile.announcementsByConversation[source.conversationID]?.removeAll { $0.id == source.messageID }
            if profile.selectedConversationID == source.conversationID {
                profile.messagePageState = profile.selectedMessages.messages.isEmpty ? .empty : .content
                profile.announcementPageState = profile.selectedConversationAnnouncements.isEmpty ? .empty : .content
            }
        }
        interaction?.removeMessage(source)
    }

    func hasUnfinishedChatWrite(in conversationID: String) -> Bool {
        (state.selectedConversationID == conversationID && (state.isSendingMessage || state.isSendingAttachment || state.isPreparingAttachment || state.deletingMessageID != nil))
            || sending?.hasUnfinished(in: conversationID) == true
            || interaction?.isMutating == true || polls?.isMutating == true || timedActions?.isMutating == true
            || interaction?.pending.contains(where: { $0.conversationID == conversationID }) == true
            || polls?.pending.contains(where: { $0.conversationID == conversationID }) == true
            || timedActions?.pending.contains(where: { $0.conversationID == conversationID }) == true
            || forwarding?.hasUnfinished(in: conversationID) == true
            || deletion?.hasUnfinished(in: conversationID) == true
    }

    func refreshManagementMessages(in conversationID: String) async {
        guard state.selectedConversationID == conversationID, let profileID = activeProfileID,
              let repository = repositories[profileID] else { return }
        await replaceMessages(conversationID: conversationID, profileID: profileID, repository: repository,
            preservesContent: !state.selectedMessages.messages.isEmpty)
        guard activeProfileID == profileID, state.selectedConversationID == conversationID else { return }
        await loadConversationAnnouncements(forceRefresh: true)
    }

    func applyClosedConversation(_ id: String) {
        if state.selectedConversationID == id {
            cancelMessageWork(); cancelMemberWork(); cancelAnnouncementWork(); attachmentModel.cancelAllWork()
        }
        updateActive { profile in
            profile.conversations.removeAll { $0.id == id }
            profile.pinnedConversationIDs.removeAll { $0 == id }
            profile.messagesByConversation[id] = nil; profile.announcementsByConversation[id] = nil
            profile.membersByConversation[id] = nil
            if profile.selectedConversationID == id { profile.selectedConversationID = nil; profile.messagePageState = .empty }
            if profile.visibleConversationID == id { profile.visibleConversationID = nil }
            Self.applyConversationFilter(to: &profile)
        }
        if let activeProfileID { conversationPinStore.savePinnedConversationIDs(state.pinnedConversationIDs, profileID: activeProfileID) }
    }

    func containsVisibleMessage(conversationID: String, messageID: String) -> Bool {
        (state.selectedConversationID == conversationID && state.selectedConversation?.isEncrypted == false
            && state.selectedMessages.messages.contains { $0.id == messageID })
            || (state.selectedConversationID == conversationID && state.selectedConversation?.isEncrypted == false
                && state.selectedConversationAnnouncements.contains { $0.id == messageID })
            || interaction?.containsFocusedMessage(conversationID: conversationID, messageID: messageID) == true
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
