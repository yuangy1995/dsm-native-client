import AppKit
import DsmCore
import Foundation
import ImageIO
import Observation
import DsmLocalization

@MainActor
@Observable
final class ChatWorkspaceModel {
    private(set) var availability = ChatAvailability(status: .requiresValidation)
    private(set) var conversations: [ChatConversation] = []
    private(set) var users: [ChatUser] = []
    private(set) var messages: [ChatMessage] = [] {
        didSet {
            if let latest = messages.last(where: { $0.deliveryState == .sent }) {
                conversationPreviewMessages[latest.conversationID] = latest
            } else if let selectedConversationID {
                conversationPreviewMessages.removeValue(forKey: selectedConversationID)
            }
        }
    }
    private var conversationPreviewMessages: [String: ChatMessage] = [:]
    private(set) var selectedConversationID: String?
    private(set) var isLoading = false
    private(set) var isLoadingMessages = false
    private(set) var messageLoadError: String?
    private(set) var isLoadingEarlierMessages = false
    private(set) var isRefreshingMessages = false
    private(set) var isRefreshingConversations = false
    private(set) var hasMoreMessagesBefore = false
    private(set) var newMessageCount = 0
    private(set) var isPerformingAction = false
    private(set) var statusMessage: String?
    private(set) var statusIsError = false
    private(set) var activeToast: ToastMessage?
    private(set) var uploadProgressByMessageID: [String: Double] = [:]
    private(set) var attachmentDownloadProgressByMessageID: [String: Double] = [:]
    private(set) var attachmentThumbnailsByMessageID: [String: Data] = [:]
    private(set) var loadingAttachmentThumbnailIDs: Set<String> = []
    private(set) var reminders: [ChatReminder] = []
    private(set) var isLoadingReminders = false
    private(set) var scheduledMessages: [ChatScheduledMessage] = []
    private(set) var isLoadingScheduledMessages = false
    private(set) var reminderLoadError: String?
    private(set) var scheduledMessageLoadError: String?
    private(set) var conversationMembers: [ChatUser] = []
    private(set) var isLoadingConversationMembers = false
    private(set) var conversationMemberLoadError: String?
    private(set) var pinnedMessages: [ChatMessage] = []
    private(set) var isLoadingPinnedMessages = false
    private(set) var pinnedMessageLoadError: String?
    private(set) var isRealtimeConnected = false
    private(set) var pinnedConversationIDs: [String] = []
    private(set) var isModuleEnabled = true
    private(set) var editPolicy = ChatEditingPolicy(allowsEditing: false)
    private(set) var isConversationAtBottom = false
    private var visibleMessageID: String?
    var isChatWindowActive = false
    let notificationScope = UUID().uuidString
    @ObservationIgnored private let notificationStartedAt = Date()
    @ObservationIgnored private var notificationBaseline: [String: Date]?
    @ObservationIgnored private var readSyncInFlight: Set<String> = []
    @ObservationIgnored private var synchronizedReadThrough: [String: Date] = [:]
    struct EditingDraft {
        let original: ChatMessage
        let text: String
        let requestID: UUID
    }
    private(set) var editingDrafts: [String: EditingDraft] = [:]
    struct VotingDraft {
        let message: ChatMessage
        let choices: Set<String>
        let requestID: UUID
    }
    private(set) var votingDrafts: [String: VotingDraft] = [:]
    private(set) var replyDrafts: [String: ChatMessageDraft] = [:]


    @ObservationIgnored private let notifyChat: @MainActor (String, String, String, String) -> Void
    @ObservationIgnored private let repository: any ChatRepository
    @ObservationIgnored private let currentAccountName: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pinStorageKey: String?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var previousMessageCursor: String?
    @ObservationIgnored private var toastDismissTask: Task<Void, Never>?
    @ObservationIgnored private var sendTasksByMessageID: [String: Task<ChatMessageSendOutcome, Error>] = [:]
    @ObservationIgnored private var sendOperationIDs: [String: UUID] = [:]
    @ObservationIgnored private var activeSendOperationID: UUID?
    @ObservationIgnored private var attachmentDownloadTasksByMessageID: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var isChatVisible = false
    @ObservationIgnored private var realtimeGeneration = UUID()
    @ObservationIgnored private var isStartingRealtime = false
    @ObservationIgnored private var backgroundSyncTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeEventTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var realtimeStopTask: Task<Void, Never>?
    @ObservationIgnored private let attachmentPreviewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LanStashChatPreview-\(UUID().uuidString)", isDirectory: true)
    private var draftsByConversationID: [String: String] = [:]
    private var attachmentsByConversationID: [String: [URL]] = [:]
    private var failedMessageErrorsByID: [String: String] = [:]
    private var messageResultsByID: [String: MutationResult] = [:]
    private var localOutgoingMessagesByConversationID: [String: [ChatMessage]] = [:]
    private var draftsByLocalMessageID: [String: ChatMessageDraft] = [:]
    @ObservationIgnored private var conversationLoadGeneration = UUID()
    @ObservationIgnored private var pendingDirectRequests: [String: UUID] = [:]
    private(set) var pendingGroupDraft: ChatGroupDraft?
    private var pendingPollDrafts: [String: ChatPollDraft] = [:]
    private struct ScheduledDraft {
        let text: String
        let sendAt: Date
        let requestID: UUID
    }
    private var pendingScheduledDrafts: [String: ScheduledDraft] = [:]
    private struct ReminderRequestKey: Hashable {
        let messageID: String
        let remindAt: Date
    }
    private var reminderRequests: [ReminderRequestKey: UUID] = [:]
    private struct ForwardRequestKey: Hashable {
        let messageID: String
        let targets: [String]
    }
    private var forwardRequests: [ForwardRequestKey: UUID] = [:]

    init(
        repository: any ChatRepository,
        currentAccountName: String? = nil,
        profileID: UUID? = nil,
        defaults: UserDefaults = .standard,
        notifyChat: @escaping @MainActor (String, String, String, String) -> Void = ChatNotificationService.post
    ) {
        self.repository = repository
        self.notifyChat = notifyChat
        self.currentAccountName = Self.normalizedIdentityName(currentAccountName)
        self.defaults = defaults
        let storageKey = profileID.map {
            "LanStash_ChatPinnedConversations_\($0.uuidString)"
        }
        pinStorageKey = storageKey
        if let storageKey,
           let savedIDs = defaults.stringArray(forKey: storageKey) {
            var seen = Set<String>()
            pinnedConversationIDs = savedIDs.prefix(500).compactMap { value in
                let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, seen.insert(id).inserted else { return nil }
                return id
            }
        }
    }

    deinit {
        backgroundSyncTask?.cancel()
        realtimeEventTask?.cancel()
        realtimeRefreshTask?.cancel()
        realtimeStopTask?.cancel()
        try? FileManager.default.removeItem(at: attachmentPreviewDirectory)
    }

    var selectedConversation: ChatConversation? {
        guard let selectedConversationID else { return nil }
        return conversations.first { $0.id == selectedConversationID }
    }

    var totalUnreadCount: Int {
        conversations.reduce(0) { $0 + $1.unreadCount }
    }

    func conversationSummary(_ conversation: ChatConversation) -> String {
        if let message = conversationPreviewMessages[conversation.id] {
            if message.encryptionState == .notEncrypted || message.encryptionState == .unlocked {
                if let text = message.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
                if let poll = message.poll { return poll.question }
                if !message.attachments.isEmpty { return L10n.string("chat.preview.attachment") }
            }
        }
        if let summary = conversation.lastMessageSummary, !summary.isEmpty { return summary }
        // 未提供摘要不代表没有历史消息，不能将缺失字段当作空会话。
        return L10n.string("chat.preview.open")
    }

    var workspaceSyncIntervalSeconds: Int {
        isRealtimeConnected ? 30 : 5
    }

    func isConversationPinned(_ id: String) -> Bool {
        pinnedConversationIDs.contains(id)
    }

    func toggleConversationPin(id: String) {
        guard conversations.contains(where: { $0.id == id }) else { return }
        if let index = pinnedConversationIDs.firstIndex(of: id) {
            pinnedConversationIDs.remove(at: index)
            showToast(L10n.string("ui.b45a48730dd4f8ba"), icon: "pin.slash")
        } else {
            pinnedConversationIDs.insert(id, at: 0)
            showToast(L10n.string("ui.b1bade10a9e4aa94"), icon: "pin.fill")
        }
        persistPinnedConversations()
        conversations = sortedConversations(conversations)
    }

    var currentUserID: String? {
        if let explicitUserID = users.first(where: { $0.isCurrentUser == true })?.id {
            return explicitUserID
        }
        return messages.first {
            $0.isFromCurrentUser == true && $0.senderID != "current" && $0.senderID != "unknown"
        }?.senderID
    }

    func displayName(for userID: String) -> String? {
        users.first(where: { $0.id == userID })?.displayName
    }

    func isCurrentUser(_ message: ChatMessage) -> Bool {
        if let declared = message.isFromCurrentUser { return declared }
        return currentUserID == message.senderID
    }

    private static func normalizedIdentityName(_ value: String?) -> String? {
        let normalized = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    func memberSummary(for conversation: ChatConversation) -> String {
        guard conversation.kind == .group else { return L10n.string("ui.23f0220786ea1d90") }
        let names = conversation.memberIDs.compactMap(displayName(for:))
        let count = conversation.memberCount ?? conversation.memberIDs.count
        if !names.isEmpty {
            let prefix = count > 0
                ? L10n.string("chat.members.prefix", String(count))
                : ""
            return prefix + names.prefix(4).joined(separator: "、")
                + (names.count > 4 ? L10n.string("ui.8ab274ae26fa1765") : "")
        }
        return count > 0
            ? L10n.string("chat.members.count", String(count))
            : L10n.string("ui.35b49ee58a4a0e82")
    }

    var canUseMessaging: Bool {
        isModuleEnabled && availability.status == .available
    }

    var canCreateDirectConversation: Bool {
        canUseMessaging && availability.supportedFeatures.contains(.directConversation)
    }

    var canCreateGroupConversation: Bool {
        canUseMessaging && availability.supportedFeatures.contains(.groupConversation)
    }

    var canSendText: Bool {
        canUseSelectedConversation && availability.supportedFeatures.contains(.textMessage)
    }

    private var canUseSelectedConversation: Bool {
        canUseMessaging && selectedConversation?.isEncrypted == false
    }

    var canSendAttachments: Bool {
        let features = availability.supportedFeatures
        return canUseSelectedConversation && (
            features.contains(.imageAttachment)
                || features.contains(.videoAttachment)
                || features.contains(.fileAttachment)
        )
    }

    var canDownloadAttachments: Bool {
        canUseSelectedConversation && availability.supportedFeatures.contains(.attachmentDownload)
    }

    var canManageReminders: Bool {
        canUseSelectedConversation && availability.supportedFeatures.contains(.reminderManagement)
    }

    var canScheduleMessages: Bool {
        canUseSelectedConversation && availability.supportedFeatures.contains(.scheduledMessage)
    }

    var canCreatePoll: Bool {
        canUseSelectedConversation && availability.supportedFeatures.contains(.poll)
    }

    var canForwardMessages: Bool {
        canUseSelectedConversation && availability.supportedFeatures.contains(.messageForward)
    }

    var canViewGroupMembers: Bool {
        canUseMessaging && availability.supportedFeatures.contains(.groupMembers)
    }

    var canManagePinnedMessages: Bool {
        canUseSelectedConversation && availability.supportedFeatures.contains(.pinnedMessages)
    }

    var canDeleteOwnMessages: Bool {
        canUseSelectedConversation && availability.supportedFeatures.contains(.deleteOwnMessage)
    }

    var canCloseConversations: Bool {
        canUseMessaging && availability.supportedFeatures.contains(.closeConversation)
    }

    func canDelete(_ message: ChatMessage) -> Bool {
        canDeleteOwnMessages && message.deliveryState == .sent && isCurrentUser(message)
            && message.conversationID == selectedConversationID && message.encryptionState == .notEncrypted
    }

    func canForward(_ message: ChatMessage) -> Bool {
        guard canForwardMessages,
              selectedConversation?.isEncrypted == false,
              message.deliveryState == .sent, message.encryptionState == .notEncrypted else {
            return false
        }
        let hasText = message.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return message.poll == nil && (hasText || !message.attachments.isEmpty)
    }

    func canPin(_ message: ChatMessage) -> Bool {
        canManagePinnedMessages
            && selectedConversation?.kind == .group
            && selectedConversation?.isEncrypted == false
            && message.deliveryState == .sent
            && message.encryptionState == .notEncrypted
    }

    var canSearchMessages: Bool { canUseMessaging && availability.supportedFeatures.contains(.messageSearch) }
    var canReply: Bool { canUseSelectedConversation && availability.supportedFeatures.contains(.threadedReplies) }
    var canVote: Bool { canUseSelectedConversation && availability.supportedFeatures.contains(.pollVoting) }
    var canRecordVoice: Bool { canSendAttachments && availability.supportedFeatures.contains(.voiceMessage) }

    func canEdit(_ message: ChatMessage) -> Bool {
        canUseMessaging && availability.supportedFeatures.contains(.messageEditing) && editPolicy.permits(message)
    }

    func loadEditPolicy() async {
        guard availability.supportedFeatures.contains(.messageEditing) else { return }
        do { editPolicy = try await repository.editingPolicy() }
        catch { editPolicy = ChatEditingPolicy(allowsEditing: false) }
    }

    func searchMessages(query: String, conversationID: String?, cursor: String?) async throws -> ChatSearchPage {
        guard canSearchMessages else { throw chatFeatureError() }
        return try await repository.searchMessages(query: query, conversationID: conversationID, cursor: cursor, limit: 25)
    }

    func loadMessage(_ message: ChatMessage) async throws -> ChatMessage? {
        try await repository.message(conversationID: message.conversationID, messageID: message.id, threadID: message.threadID)
    }

    func loadDiscussionRoot(_ message: ChatMessage) async throws -> ChatMessage? {
        try await repository.message(conversationID: message.conversationID,
            messageID: message.threadID ?? message.id, threadID: nil)
    }

    func loadReplies(for root: ChatMessage, before: String?) async throws -> ChatMessagePage {
        try await repository.listReplies(conversationID: root.conversationID, threadID: root.id, before: before, limit: 50)
    }

    func editMessage(_ original: ChatMessage, text: String) async -> ChatMessage? {
        guard canUseMessaging, !isPerformingAction else { return nil }
        let draft = editingDrafts[original.id] ?? EditingDraft(original: original, text: text, requestID: UUID())
        editingDrafts[original.id] = draft
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let result = try await repository.editMessage(draft.original, text: draft.text, clientRequestID: draft.requestID)
            editingDrafts[original.id] = nil
            updateExistingMessage(result)
            return result
        } catch {
            if (error as? AppError)?.category != .partialFailure { editingDrafts[original.id] = nil }
            show(error)
            return nil
        }
    }

    func vote(_ message: ChatMessage, choices: Set<String>) async -> ChatMessage? {
        guard canUseMessaging, !isPerformingAction else { return nil }
        let draft = votingDrafts[message.id] ?? VotingDraft(message: message, choices: choices, requestID: UUID())
        votingDrafts[message.id] = draft
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let result = try await repository.vote(draft.message, choiceIDs: draft.choices, clientRequestID: draft.requestID)
            votingDrafts[message.id] = nil
            updateExistingMessage(result)
            return result
        } catch {
            if (error as? AppError)?.category != .partialFailure { votingDrafts[message.id] = nil }
            show(error)
            return nil
        }
    }

    func sendReply(to root: ChatMessage, text: String) async -> ChatMessage? {
        guard canReply, !isPerformingAction, selectedConversationID == root.conversationID else { return nil }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let draft = try replyDrafts[root.id] ?? ChatMessageDraft(conversationID: root.conversationID, text: text, threadID: root.id)
            replyDrafts[root.id] = draft
            let outcome = try await repository.sendMessageResult(draft)
            if outcome.result.status == .confirmedSuccess, let result = outcome.confirmedMessage,
               result.conversationID == root.conversationID, result.threadID == root.id {
                replyDrafts[root.id] = nil
                await refreshCurrentConversation()
                return result
            }
            if !(outcome.result.submitted && outcome.result.requiresRefresh) { replyDrafts[root.id] = nil }
            statusMessage = messageResultDescription(outcome.result)
            statusIsError = true
        } catch { show(error) }
        return nil
    }

    private func updateExistingMessage(_ value: ChatMessage) {
        if let index = messages.firstIndex(where: { $0.id == value.id && $0.conversationID == value.conversationID }) {
            messages[index] = value
        }
        if let index = pinnedMessages.firstIndex(where: { $0.id == value.id }) { pinnedMessages[index] = value }
    }

    private func chatFeatureError() -> AppError {
        AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: L10n.string("chat.feature.unavailable"))
    }

    func stageVoiceRecording(_ source: URL) throws -> URL {
        try FileManager.default.createDirectory(at: attachmentPreviewDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let destination = attachmentPreviewDirectory.appendingPathComponent("voice-\(UUID().uuidString).aac")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    func discardTemporaryMedia(_ file: URL) {
        guard file.deletingLastPathComponent() == attachmentPreviewDirectory else { return }
        try? FileManager.default.removeItem(at: file)
    }

    func prepareMedia(message: ChatMessage, attachment: ChatAttachment) async throws -> URL {
        let limit: Int64 = 512 * 1_024 * 1_024
        guard canUseMessaging, availability.supportedFeatures.contains(.attachmentDownload),
              message.encryptionState == .notEncrypted,
              attachment.kind == .video || attachment.kind == .voice,
              let size = attachment.sizeBytes, size > 0, size <= limit,
              attachmentDownloadTasksByMessageID[message.id] == nil else { throw chatFeatureError() }
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: attachmentPreviewDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let ext = URL(fileURLWithPath: attachment.fileName).pathExtension
        let file = attachmentPreviewDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        let progress: FileTransferProgress = { [weak self] received, total in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if received > limit || (total ?? 0) > limit { self.cancelAttachmentDownload(messageID: message.id) }
                if let total, total > 0 { self.attachmentDownloadProgressByMessageID[message.id] = Double(received) / Double(total) }
            }
        }
        let task = Task { [repository] in
            try await repository.downloadAttachment(messageID: message.id, to: file, progress: progress)
        }
        attachmentDownloadTasksByMessageID[message.id] = task
        defer {
            attachmentDownloadTasksByMessageID[message.id] = nil
            attachmentDownloadProgressByMessageID[message.id] = nil
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            let actual = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard actual > 0, actual <= limit else { throw CocoaError(.fileReadCorruptFile) }
            return file
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    func updateVisibleMessage(_ id: String?) {
        visibleMessageID = id
        isConversationAtBottom = id != nil
    }

    func synchronizeVisibleReadState() async {
        guard isModuleEnabled, isChatVisible, isChatWindowActive, isConversationAtBottom,
              availability.supportedFeatures.contains(.readSynchronization),
              let id = selectedConversationID, selectedConversation?.isEncrypted == false,
              let latest = messages.last(where: { $0.deliveryState == .sent }), latest.id == visibleMessageID,
              latest.sentAt > (synchronizedReadThrough[id] ?? .distantPast),
              readSyncInFlight.insert(id).inserted else { return }
        let through = latest.sentAt
        defer { readSyncInFlight.remove(id) }
        do {
            let updated = try await repository.markRead(conversationID: id, through: through)
            guard isModuleEnabled, updated.id == id else { return }
            synchronizedReadThrough[id] = through
            if let index = conversations.firstIndex(where: { $0.id == id }) { conversations[index] = updated }
            if selectedConversationID == id, updated.unreadCount == 0 { newMessageCount = 0 }
        } catch {
            // 保留原未读数，下一次前台同步重试；不以本地清零伪装跨设备成功。
        }
    }

    func synchronizeThreadRead(_ root: ChatMessage, lastMessageID: String?, isVisible: Bool) async {
        guard isModuleEnabled, isVisible, let lastMessageID,
              availability.supportedFeatures.contains(.readSynchronization) else { return }
        do { try await repository.markThreadRead(conversationID: root.conversationID, threadID: root.id, lastMessageID: lastMessageID) }
        catch { /* 线程正文仍可阅读；下次可见刷新继续尝试。 */ }
    }

    private func processConversationNotifications(_ values: [ChatConversation]) async {
        let current = Dictionary(values.compactMap { value in value.lastActivityAt.map { (value.id, $0) } }, uniquingKeysWith: max)
        let baseline = notificationBaseline
        notificationBaseline = current
        guard let baseline else { return }
        for conversation in values where conversation.unreadCount > 0 && !conversation.isEncrypted {
            guard let activity = conversation.lastActivityAt,
                  activity > (baseline[conversation.id] ?? notificationStartedAt),
                  !(isChatVisible && isChatWindowActive && isConversationAtBottom && selectedConversationID == conversation.id) else { continue }
            guard let page = try? await repository.listMessages(conversationID: conversation.id, before: nil, limit: 1),
                  let latest = page.messages.last, !isCurrentUser(latest), latest.isFromCurrentUser == false,
                  isModuleEnabled else { continue }
            notifyChat(conversation.title, conversation.id, notificationScope, latest.id)
        }
    }

    func draftText(for conversationID: String) -> String {
        draftsByConversationID[conversationID] ?? ""
    }

    func updateDraft(_ text: String, for conversationID: String) {
        if text.isEmpty {
            draftsByConversationID[conversationID] = nil
        } else {
            draftsByConversationID[conversationID] = text
        }
    }

    func attachmentURLs(for conversationID: String) -> [URL] {
        attachmentsByConversationID[conversationID] ?? []
    }

    func updateAttachments(_ urls: [URL], for conversationID: String) {
        attachmentsByConversationID[conversationID] = urls.isEmpty ? nil : urls
    }

    func isAwaitingMessageConfirmation(_ id: String) -> Bool {
        guard let result = messageResultsByID[id] else { return false }
        return result.status == .submittedButUnverified
            || result.status == .cancellationRequestedAfterSubmission
            || result.status == .partialSuccess
    }

    func pendingPollDraft(for conversationID: String) -> ChatPollDraft? {
        pendingPollDrafts[conversationID]
    }

    func sendFailureMessage(for messageID: String) -> String? {
        failedMessageErrorsByID[messageID]
    }

    func uploadProgress(for messageID: String) -> Double? {
        uploadProgressByMessageID[messageID]
    }

    func attachmentDownloadProgress(for messageID: String) -> Double? {
        attachmentDownloadProgressByMessageID[messageID]
    }

    func thumbnailData(for messageID: String) -> Data? {
        attachmentThumbnailsByMessageID[messageID]
    }

    func reminder(for messageID: String) -> ChatReminder? {
        reminders.first { $0.messageID == messageID }
    }

    func loadAttachmentThumbnail(
        messageID: String,
        attachment: ChatAttachment
    ) async {
        guard canDownloadAttachments,
              attachmentThumbnailsByMessageID[messageID] == nil,
              !loadingAttachmentThumbnailIDs.contains(messageID) else { return }
        loadingAttachmentThumbnailIDs.insert(messageID)
        defer { loadingAttachmentThumbnailIDs.remove(messageID) }
        do {
            let data = try await repository.loadAttachmentThumbnail(
                messageID: messageID,
                size: .small
            )
            if let displayData = Self.displayThumbnailData(from: data) {
                attachmentThumbnailsByMessageID[messageID] = displayData
                return
            }
        } catch {
            // NAS 可能不为 HEIC/HEIF 生成缩略图，下面使用原文件做受限的本机兜底。
        }
        await loadLocalAttachmentThumbnailFallback(messageID: messageID, attachment: attachment)
    }

    func downloadAttachment(
        messageID: String,
        attachment: ChatAttachment,
        to destinationURL: URL,
        announcesSuccess: Bool = true
    ) async -> Bool {
        guard canDownloadAttachments, !isPerformingAction else { return false }
        isPerformingAction = true
        attachmentDownloadProgressByMessageID[messageID] = 0
        defer {
            isPerformingAction = false
            attachmentDownloadProgressByMessageID[messageID] = nil
            attachmentDownloadTasksByMessageID[messageID] = nil
        }
        do {
            let downloadTask = Task {
                try await repository.downloadAttachment(messageID: messageID, to: destinationURL) {
                    [weak self] completed, total in
                    guard let total, total > 0 else { return }
                    Task { @MainActor [weak self] in
                        self?.attachmentDownloadProgressByMessageID[messageID] = min(
                            max(Double(completed) / Double(total), 0),
                            1
                        )
                    }
                }
            }
            attachmentDownloadTasksByMessageID[messageID] = downloadTask
            try await downloadTask.value
            if announcesSuccess {
                showToast(L10n.string("ui.85d535ca829260ca", String(describing: attachment.fileName)), icon: "arrow.down.circle.fill")
            }
            return true
        } catch is CancellationError {
            showToast(L10n.string("ui.9c68e3c7422d3700"), icon: "xmark.circle", style: .info)
            return false
        } catch {
            show(error)
            return false
        }
    }

    func cancelAttachmentDownload(messageID: String) {
        attachmentDownloadTasksByMessageID[messageID]?.cancel()
    }

    func loadAttachmentPreview(messageID: String, attachment: ChatAttachment) async -> NSImage? {
        let maximumBytes: Int64 = 64 * 1_024 * 1_024
        guard canDownloadAttachments, attachment.kind == .image,
              let size = attachment.sizeBytes, size > 0, size <= maximumBytes else {
            showToast(L10n.string("chat.preview.unavailable"), style: .info)
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: attachmentPreviewDirectory,
                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let file = attachmentPreviewDirectory.appendingPathComponent("preview-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: file) }
            try await repository.downloadAttachment(messageID: messageID, to: file) { _, _ in }
            try Task.checkCancellation()
            guard let actualSize = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  actualSize <= maximumBytes,
                  let image = NSImage(data: try Data(contentsOf: file)) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return image
        } catch is CancellationError {
            return nil
        } catch {
            showToast(L10n.string("chat.preview.unavailable"), style: .info)
            return nil
        }
    }

    private func loadLocalAttachmentThumbnailFallback(
        messageID: String,
        attachment: ChatAttachment
    ) async {
        let maximumPreviewBytes: Int64 = 64 * 1_024 * 1_024
        guard attachment.kind == .image,
              attachment.sizeBytes.map({ $0 <= maximumPreviewBytes }) ?? true else { return }
        do {
            try FileManager.default.createDirectory(
                at: attachmentPreviewDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let safeName = URL(fileURLWithPath: attachment.fileName).lastPathComponent
            let sourceURL = attachmentPreviewDirectory
                .appendingPathComponent("thumbnail-\(UUID().uuidString)-\(safeName)")
            defer { try? FileManager.default.removeItem(at: sourceURL) }
            try await repository.downloadAttachment(messageID: messageID, to: sourceURL) { _, _ in }
            let fileSize = try FileManager.default.attributesOfItem(atPath: sourceURL.path)[.size] as? NSNumber
            let downloadedBytes = fileSize?.int64Value ?? 0
            guard downloadedBytes <= maximumPreviewBytes else { return }
            let thumbnail = await Task.detached(priority: .utility) { () -> Data? in
                guard let data = try? Data(contentsOf: sourceURL, options: .mappedIfSafe) else { return nil }
                return Self.displayThumbnailData(from: data)
            }.value
            if let thumbnail {
                attachmentThumbnailsByMessageID[messageID] = thumbnail
            }
        } catch {
            // 图片预览是辅助内容，兜底失败时仍保留打开和另存为入口。
        }
    }

    nonisolated private static func displayThumbnailData(from sourceData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSBitmapImageRep(cgImage: image).representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.84]
        )
    }

    func loadReminders() async {
        guard canManageReminders, !isLoadingReminders,
              let conversationID = selectedConversationID else { return }
        let generation = conversationLoadGeneration
        isLoadingReminders = true
        reminderLoadError = nil
        defer { if conversationLoadGeneration == generation { isLoadingReminders = false } }
        do {
            let loaded = try await repository.listReminders(conversationID: conversationID)
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            reminders = loaded
        } catch {
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            reminderLoadError = Self.safeMessage(for: error)
        }
    }

    func setReminder(messageID: String, remindAt: Date) async -> Bool {
        guard canManageReminders, !isPerformingAction, let conversationID = selectedConversationID else { return false }
        isPerformingAction = true
        defer { isPerformingAction = false }
        let key = ReminderRequestKey(messageID: messageID, remindAt: remindAt)
        let requestID = reminderRequests[key] ?? UUID()
        reminderRequests[key] = requestID
        do {
            let reminder = try await repository.setReminder(
                messageID: messageID,
                remindAt: remindAt,
                clientRequestID: requestID
            )
            reminderRequests[key] = nil
            guard selectedConversationID == conversationID else { return true }
            reminders.removeAll { $0.messageID == messageID }
            reminders.append(reminder)
            reminders.sort { $0.remindAt < $1.remindAt }
            showToast(L10n.string("ui.16c4c8ad6b7443e3"), icon: "bell.fill")
            return true
        } catch {
            if (error as? AppError)?.category != .partialFailure { reminderRequests[key] = nil }
            if selectedConversationID == conversationID { show(error) }
            return false
        }
    }

    func deleteReminder(messageID: String) async -> Bool {
        guard canManageReminders, !isPerformingAction,
              let conversationID = selectedConversationID else { return false }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await repository.deleteReminder(
                messageID: messageID,
                conversationID: conversationID,
                clientRequestID: UUID()
            )
            guard selectedConversationID == conversationID else { return true }
            reminders.removeAll { $0.messageID == messageID }
            showToast(L10n.string("ui.b70ea5d26374d398"), icon: "bell.slash.fill")
            return true
        } catch {
            if selectedConversationID == conversationID { show(error) }
            return false
        }
    }

    func loadScheduledMessages() async {
        guard canScheduleMessages, !isLoadingScheduledMessages,
              let conversationID = selectedConversationID else { return }
        let generation = conversationLoadGeneration
        isLoadingScheduledMessages = true
        scheduledMessageLoadError = nil
        defer { if conversationLoadGeneration == generation { isLoadingScheduledMessages = false } }
        do {
            let loaded = try await repository.listScheduledMessages(conversationID: conversationID)
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            scheduledMessages = loaded
        } catch {
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            scheduledMessageLoadError = Self.safeMessage(for: error)
        }
    }

    func pendingScheduledMessage(for conversationID: String) -> (text: String, sendAt: Date)? {
        pendingScheduledDrafts[conversationID].map { ($0.text, $0.sendAt) }
    }

    func createScheduledMessage(text: String, sendAt: Date) async -> Bool {
        guard canScheduleMessages, !isPerformingAction,
              let conversationID = selectedConversationID else { return false }
        let draft = pendingScheduledDrafts[conversationID]
            ?? ScheduledDraft(text: text.trimmingCharacters(in: .whitespacesAndNewlines), sendAt: sendAt, requestID: UUID())
        guard draft.text == text.trimmingCharacters(in: .whitespacesAndNewlines), draft.sendAt == sendAt else {
            statusIsError = true
            statusMessage = L10n.string("chat.schedule.unavailable")
            return false
        }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let scheduled = try await repository.createScheduledMessage(
                conversationID: conversationID, text: draft.text, sendAt: draft.sendAt, clientRequestID: draft.requestID
            )
            pendingScheduledDrafts[conversationID] = nil
            guard selectedConversationID == conversationID else { return true }
            scheduledMessages.removeAll { $0.id == scheduled.id }
            scheduledMessages.append(scheduled)
            scheduledMessages.sort { $0.sendAt < $1.sendAt }
            showToast(L10n.string("ui.e1d902552ebf8ace"), icon: "clock.badge.checkmark")
            return true
        } catch {
            if (error as? AppError)?.category == .partialFailure { pendingScheduledDrafts[conversationID] = draft }
            if selectedConversationID == conversationID { show(error) }
            return false
        }
    }

    func deleteScheduledMessage(id: String) async -> Bool {
        guard canScheduleMessages, !isPerformingAction,
              let conversationID = selectedConversationID else { return false }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await repository.deleteScheduledMessage(
                id: id,
                conversationID: conversationID,
                clientRequestID: UUID()
            )
            guard selectedConversationID == conversationID else { return true }
            scheduledMessages.removeAll { $0.id == id }
            showToast(L10n.string("ui.70e0315cbc11f517"), icon: "clock.badge.xmark")
            return true
        } catch {
            if selectedConversationID == conversationID { show(error) }
            return false
        }
    }

    func loadConversationMembers() async {
        guard canViewGroupMembers,
              selectedConversation?.kind == .group,
              !isLoadingConversationMembers,
              let conversationID = selectedConversationID else { return }
        let generation = conversationLoadGeneration
        isLoadingConversationMembers = true
        conversationMemberLoadError = nil
        defer { if conversationLoadGeneration == generation { isLoadingConversationMembers = false } }
        do {
            let loaded = try await repository.listConversationMembers(
                conversationID: conversationID
            )
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            conversationMembers = loaded
        } catch {
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            conversationMemberLoadError = Self.safeMessage(for: error)
        }
    }

    func loadPinnedMessages() async {
        guard canManagePinnedMessages,
              !isLoadingPinnedMessages,
              let conversationID = selectedConversationID else { return }
        let generation = conversationLoadGeneration
        isLoadingPinnedMessages = true
        pinnedMessageLoadError = nil
        defer { if conversationLoadGeneration == generation { isLoadingPinnedMessages = false } }
        do {
            let loaded = try await repository.listPinnedMessages(
                conversationID: conversationID
            )
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            pinnedMessages = loaded
        } catch {
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            pinnedMessageLoadError = Self.safeMessage(for: error)
        }
    }

    func setMessagePinned(_ message: ChatMessage, isPinned: Bool) async -> Bool {
        guard canPin(message), !isPerformingAction,
              let conversationID = selectedConversationID else { return false }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            try await repository.setMessagePinned(
                conversationID: conversationID,
                messageID: message.id,
                isPinned: isPinned,
                clientRequestID: UUID()
            )
            await refreshCurrentConversation()
            pinnedMessages = try await repository.listPinnedMessages(
                conversationID: conversationID
            )
            showToast(
                isPinned ? L10n.string("ui.a2219064fe9014bd") : L10n.string("ui.7d2bc752fbb71ed2"),
                icon: isPinned ? "pin.fill" : "pin.slash"
            )
            return true
        } catch {
            show(error)
            return false
        }
    }

    func loadIfNeeded() async {
        guard isModuleEnabled, !hasLoaded else { return }
        await reload()
    }

    func reload() async {
        guard isModuleEnabled, !isLoading else { return }
        isLoading = true
        statusMessage = nil
        statusIsError = false
        defer {
            isLoading = false
            if isModuleEnabled {
                hasLoaded = true
            }
        }

        let discoveredAvailability = await repository.availability()
        guard isModuleEnabled else { return }
        availability = discoveredAvailability
        guard discoveredAvailability.status == .available else {
            conversations = []
            users = []
            messages = []
            selectedConversationID = nil
            statusMessage = availabilityMessage(for: discoveredAvailability.status)
            return
        }

        do {
            async let loadedConversations = repository.listConversations()
            async let loadedUsers = repository.listUsers()
            let loadedConversationValues = try await loadedConversations
            let loadedUserValues = try await loadedUsers
            guard isModuleEnabled else { return }
            self.conversations = sortedConversations(loadedConversationValues)
            self.users = loadedUserValues
                .filter { !$0.isDisabled }
                .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }

            if let selectedConversationID,
               self.conversations.contains(where: { $0.id == selectedConversationID }) {
                await refreshCurrentConversation()
                if let messageLoadError {
                    statusIsError = true
                    statusMessage = messageLoadError
                }
            } else if let first = self.conversations.first {
                await selectConversation(id: first.id)
            } else {
                selectedConversationID = nil
                messages = []
            }
        } catch {
            show(error)
        }
    }

    func selectConversation(id: String?) async {
        guard canUseMessaging else { return }
        let generation = UUID()
        conversationLoadGeneration = generation
        messageLoadError = nil
        updateVisibleMessage(nil)
        isLoadingEarlierMessages = false
        isRefreshingMessages = false
        isLoadingReminders = false
        isLoadingScheduledMessages = false
        isLoadingConversationMembers = false
        isLoadingPinnedMessages = false
        reminders = []
        scheduledMessages = []
        conversationMembers = []
        pinnedMessages = []
        reminderLoadError = nil
        scheduledMessageLoadError = nil
        conversationMemberLoadError = nil
        pinnedMessageLoadError = nil
        guard let id else {
            selectedConversationID = nil
            isLoadingMessages = false
            messages = []
            previousMessageCursor = nil
            hasMoreMessagesBefore = false
            newMessageCount = 0
            return
        }
        guard conversations.contains(where: { $0.id == id }) else { return }
        selectedConversationID = id
        previousMessageCursor = nil
        hasMoreMessagesBefore = false
        newMessageCount = 0
        guard selectedConversation?.isEncrypted == false else {
            messages = []
            isLoadingMessages = false
            return
        }
        isLoadingMessages = true
        statusMessage = nil
        statusIsError = false
        defer {
            if conversationLoadGeneration == generation { isLoadingMessages = false }
        }
        do {
            let page = try await repository.listMessages(
                conversationID: id,
                before: nil,
                limit: 50
            )
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            messages = Self.mergedMessages(
                page.messages,
                localOutgoingMessagesByConversationID[id] ?? []
            )
            previousMessageCursor = page.previousCursor
            hasMoreMessagesBefore = page.hasMoreBefore
            newMessageCount = 0
            isLoadingMessages = false
            await loadEditPolicy()
            guard conversationLoadGeneration == generation else { return }
            await reviewPendingMessages(in: id)
        } catch {
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            messages = []
            previousMessageCursor = nil
            hasMoreMessagesBefore = false
            newMessageCount = 0
            messageLoadError = Self.safeMessage(for: error)
        }
    }

    /// 读取更早的消息并插入列表顶部。返回分页前的首条消息 ID，供界面保持滚动位置。
    func loadEarlierMessages() async -> String? {
        guard canUseMessaging, !isLoadingEarlierMessages, hasMoreMessagesBefore,
              let conversationID = selectedConversationID,
              let cursor = previousMessageCursor else { return nil }
        let anchorID = messages.first?.id
        let generation = conversationLoadGeneration
        isLoadingEarlierMessages = true
        defer {
            if conversationLoadGeneration == generation { isLoadingEarlierMessages = false }
        }
        do {
            let page = try await repository.listMessages(
                conversationID: conversationID,
                before: cursor,
                limit: 50
            )
            guard isModuleEnabled, conversationLoadGeneration == generation else { return nil }
            messages = Self.mergedMessages(page.messages, messages)
            previousMessageCursor = page.previousCursor
            hasMoreMessagesBefore = page.hasMoreBefore
            return anchorID
        } catch {
            guard isModuleEnabled, conversationLoadGeneration == generation else { return nil }
            show(error)
            return nil
        }
    }

    /// 前台轻量刷新当前会话，只合并最新消息，不清空历史和本地发送状态。
    func refreshCurrentConversation() async {
        guard canUseSelectedConversation, !isRefreshingMessages, !isLoadingMessages,
              let conversationID = selectedConversationID else { return }
        let generation = conversationLoadGeneration
        let snapshotIDs = Set(messages.filter { $0.deliveryState == .sent }.map(\.id))
        isRefreshingMessages = true
        defer {
            if conversationLoadGeneration == generation { isRefreshingMessages = false }
        }
        do {
            let page = try await repository.listMessages(
                conversationID: conversationID,
                before: nil,
                limit: 50
            )
            guard isModuleEnabled, conversationLoadGeneration == generation else { return }
            let existingIDs = Set(messages.map(\.id))
            let added = page.messages.filter { !existingIDs.contains($0.id) }
            // 只替换此次读取确实覆盖的时间段；更早历史、发送草稿及读取期间确认的新消息保留。
            let oldest = page.messages.first?.sentAt
            let retained = messages.filter { message in
                if message.deliveryState != .sent || !snapshotIDs.contains(message.id) { return true }
                guard page.hasMoreBefore else { return false }
                return oldest.map { message.sentAt <= $0 } ?? true
            }
            messages = Self.mergedMessages(retained, page.messages)
            messageLoadError = nil
            newMessageCount += added.filter { !isCurrentUser($0) }.count
            if previousMessageCursor == nil {
                previousMessageCursor = page.previousCursor
                hasMoreMessagesBefore = page.hasMoreBefore
            }
            await synchronizeVisibleReadState()
            await reviewPendingMessages(in: conversationID)
        } catch {
            // 定时刷新失败不打断阅读；用户主动刷新时仍会获得完整错误提示。
            if isModuleEnabled, conversationLoadGeneration == generation {
                messageLoadError = Self.safeMessage(for: error)
            }
        }
    }

    /// 用户主动进入消息页时立即回读一次，避免等待下一次实时通知或定时校准。
    func refreshForegroundChat() async {
        guard isModuleEnabled, !Task.isCancelled else { return }
        isChatVisible = true
        await refreshConversationList()
        await refreshCurrentConversation()
    }

    /// 生命周期属于已连接的 NAS，而不是某个页面；隐藏或切换工作区时保留连接。
    func startBackgroundSync() {
        guard isModuleEnabled, backgroundSyncTask == nil else { return }
        backgroundSyncTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let interval = await self?.backgroundSyncCycle() else { return }
                do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            }
        }
    }

    private func backgroundSyncCycle() async -> Int? {
        guard isModuleEnabled, !Task.isCancelled else { return nil }
        await syncWorkspaceChat(isChatVisible: isChatVisible)
        return workspaceSyncIntervalSeconds
    }

    func setChatVisibility(_ visible: Bool) {
        isChatVisible = visible
        if !visible { isChatWindowActive = false; updateVisibleMessage(nil) }
    }

    /// 工作区级同步在用户查看文件或照片时也持续运行，并为侧边栏更新未读数。
    func syncWorkspaceChat(isChatVisible: Bool) async {
        let generation = realtimeGeneration
        guard isModuleEnabled, !Task.isCancelled else { return }
        self.isChatVisible = isChatVisible
        if availability.status != .available {
            availability = await repository.availability()
        }
        guard isModuleEnabled, !Task.isCancelled, realtimeGeneration == generation else { return }
        guard availability.status == .available else {
            await stopRealtime()
            return
        }
        await startRealtimeIfNeeded()
        await refreshConversationList()
        if isChatVisible {
            await refreshCurrentConversation()
        }
    }

    func stopRealtime() async {
        realtimeGeneration = UUID()
        isStartingRealtime = false
        realtimeEventTask?.cancel()
        realtimeEventTask = nil
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = nil
        isRealtimeConnected = false
        let stopTask = scheduleRealtimeStop()
        await stopTask.value
    }

    /// 模块关闭后立即断开实时连接，并终止发送、下载和刷新任务。
    func setModuleEnabled(_ enabled: Bool) {
        guard isModuleEnabled != enabled else { return }
        isModuleEnabled = enabled
        if !enabled {
            cancelAllWork()
        } else {
            startBackgroundSync()
        }
    }

    func cancelAllWork() {
        backgroundSyncTask?.cancel()
        backgroundSyncTask = nil
        realtimeGeneration = UUID()
        isStartingRealtime = false
        notificationBaseline = nil
        conversationLoadGeneration = UUID()
        toastDismissTask?.cancel()
        toastDismissTask = nil
        activeToast = nil
        realtimeEventTask?.cancel()
        realtimeEventTask = nil
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = nil
        sendTasksByMessageID.values.forEach { $0.cancel() }
        sendTasksByMessageID.removeAll()
        sendOperationIDs.removeAll()
        activeSendOperationID = nil
        attachmentDownloadTasksByMessageID.values.forEach { $0.cancel() }
        attachmentDownloadTasksByMessageID.removeAll()
        attachmentDownloadProgressByMessageID.removeAll()
        uploadProgressByMessageID.removeAll()
        loadingAttachmentThumbnailIDs.removeAll()
        isRealtimeConnected = false
        isChatVisible = false
        isLoading = false
        isLoadingMessages = false
        isLoadingEarlierMessages = false
        isRefreshingMessages = false
        isRefreshingConversations = false
        isPerformingAction = false
        isLoadingReminders = false
        isLoadingScheduledMessages = false
        isLoadingConversationMembers = false
        isLoadingPinnedMessages = false
        _ = scheduleRealtimeStop()
    }

    private func startRealtimeIfNeeded() async {
        guard isModuleEnabled, !Task.isCancelled, realtimeEventTask == nil, !isStartingRealtime else { return }
        let generation = realtimeGeneration
        isStartingRealtime = true
        defer { if realtimeGeneration == generation { isStartingRealtime = false } }
        if let realtimeStopTask {
            await realtimeStopTask.value
            self.realtimeStopTask = nil
        }
        guard isModuleEnabled, !Task.isCancelled, realtimeGeneration == generation else { return }
        let events = await repository.realtimeEvents()
        guard isModuleEnabled, !Task.isCancelled, realtimeGeneration == generation else { return }
        realtimeEventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, self?.realtimeGeneration == generation else { break }
                self?.handleRealtimeEvent(event)
            }
        }
        await repository.startRealtime()
    }

    private func scheduleRealtimeStop() -> Task<Void, Never> {
        if let realtimeStopTask {
            return realtimeStopTask
        }
        let task = Task { [repository] in
            await repository.stopRealtime()
        }
        realtimeStopTask = task
        return task
    }

    private func handleRealtimeEvent(_ event: ChatRealtimeEvent) {
        guard isModuleEnabled else { return }
        switch event {
        case .connected:
            isRealtimeConnected = true
        case .disconnected:
            isRealtimeConnected = false
        case .contentChanged:
            realtimeRefreshTask?.cancel()
            realtimeRefreshTask = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(200))
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                await self.refreshConversationList()
                if self.isChatVisible {
                    await self.refreshCurrentConversation()
                }
            }
        }
    }

    private func refreshConversationList() async {
        guard canUseMessaging, !isRefreshingConversations, !isLoading else { return }
        let generation = realtimeGeneration
        isRefreshingConversations = true
        defer { if realtimeGeneration == generation { isRefreshingConversations = false } }
        do {
            let refreshed = try await repository.listConversations()
            guard isModuleEnabled, !Task.isCancelled, realtimeGeneration == generation else { return }
            await processConversationNotifications(refreshed)
            guard isModuleEnabled, !Task.isCancelled, realtimeGeneration == generation else { return }
            conversations = sortedConversations(refreshed)
        } catch {
            // 前台轻量刷新失败不遮挡当前消息，下一轮自动重试。
        }
    }

    func clearNewMessageIndicator() {
        newMessageCount = 0
    }

    var pendingDirectUserID: String? { pendingDirectRequests.keys.sorted().first }

    var hasPendingConversationCreation: Bool {
        pendingGroupDraft != nil || pendingDirectUserID != nil
    }

    func openDirectConversation(userID: String) async -> Bool {
        guard canCreateDirectConversation, !isPerformingAction else { return false }
        isPerformingAction = true
        defer { isPerformingAction = false }
        let requestID = pendingDirectRequests[userID] ?? UUID()
        do {
            let outcome = try await repository.openDirectConversationResult(userID: userID, clientRequestID: requestID)
            if outcome.result.status == .confirmedSuccess, let conversation = outcome.confirmedConversation {
                pendingDirectRequests[userID] = nil
                merge(conversation)
                await selectConversation(id: conversation.id)
                return true
            }
            if outcome.result.counts.unknown > 0 {
                pendingDirectRequests[userID] = requestID
            } else {
                pendingDirectRequests[userID] = nil
            }
            statusIsError = true
            statusMessage = conversationResultDescription(outcome.result)
            return false
        } catch {
            show(error)
            return false
        }
    }

    func createGroup(title: String, memberIDs: [String], isEncrypted: Bool) async -> Bool {
        guard canCreateGroupConversation, !isPerformingAction, !isEncrypted else { return false }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let draft: ChatGroupDraft
            if let pending = pendingGroupDraft {
                guard pending.title == title.trimmingCharacters(in: .whitespacesAndNewlines),
                      Set(pending.memberIDs) == Set(memberIDs) else {
                    statusIsError = true
                    statusMessage = L10n.string("chat.conversation.unconfirmed")
                    return false
                }
                draft = pending
            } else {
                draft = try ChatGroupDraft(title: title, memberIDs: memberIDs.sorted(), isEncrypted: false)
            }
            let outcome = try await repository.createGroupResult(draft)
            if outcome.result.status == .confirmedSuccess, let conversation = outcome.confirmedConversation {
                pendingGroupDraft = nil
                merge(conversation)
                await selectConversation(id: conversation.id)
                return true
            }
            pendingGroupDraft = outcome.result.counts.unknown > 0 ? draft : nil
            statusIsError = true
            statusMessage = conversationResultDescription(outcome.result)
            return false
        } catch {
            show(error)
            return false
        }
    }

    private func conversationResultDescription(_ result: MutationResult) -> String {
        if result.counts.unknown > 0 { return L10n.string("chat.conversation.unconfirmed") }
        return messageResultDescription(result)
    }

    func createPoll(
        question: String,
        options: [String],
        allowsMultipleSelection: Bool,
        isAnonymous: Bool
    ) async -> Bool {
        guard canCreatePoll, !isPerformingAction,
              let conversationID = selectedConversationID else { return false }
        let draft: ChatPollDraft
        do {
            let input = try ChatPollDraft(conversationID: conversationID, question: question, options: options,
                                         allowsMultipleSelection: allowsMultipleSelection, isAnonymous: isAnonymous)
            if let pending = pendingPollDrafts[conversationID] {
                guard pending.question == input.question, pending.options == input.options,
                      pending.allowsMultipleSelection == input.allowsMultipleSelection,
                      pending.isAnonymous == input.isAnonymous else {
                    statusIsError = true
                    statusMessage = L10n.string("chat.poll.unconfirmed")
                    return false
                }
                draft = pending
            } else { draft = input }
        } catch { show(error); return false }
        isPerformingAction = true
        defer { isPerformingAction = false }
        do {
            let message = try await repository.createPoll(draft)
            pendingPollDrafts[conversationID] = nil
            guard selectedConversationID == conversationID else { return true }
            messages = Self.mergedMessages(messages, [message])
            showToast(L10n.string("ui.8c6ec0e6eb0022db"), icon: "chart.bar.fill")
            return true
        } catch {
            if (error as? AppError)?.category == .partialFailure {
                pendingPollDrafts[conversationID] = draft
            }
            show(error)
            return false
        }
    }

    func send(
        text: String?,
        attachmentURLs: [URL] = [],
        conversationID expectedConversationID: String? = nil
    ) async -> Bool {
        guard let selectedConversationID, !isPerformingAction,
              expectedConversationID == nil || expectedConversationID == selectedConversationID,
              canUseSelectedConversation else { return false }
        guard attachmentURLs.isEmpty ? canSendText : canSendAttachments else { return false }
        let draft: ChatMessageDraft
        do {
            draft = try ChatMessageDraft(
                conversationID: selectedConversationID,
                text: text,
                localAttachmentURLs: attachmentURLs
            )
        } catch {
            show(error)
            return false
        }

        let localMessage = ChatMessage(
            id: "local-\(draft.clientRequestID.uuidString)",
            clientRequestID: draft.clientRequestID,
            conversationID: selectedConversationID,
            senderID: currentUserID ?? "current",
            senderDisplayName: currentAccountName,
            isFromCurrentUser: true,
            sentAt: Date(),
            text: draft.text,
            attachments: draft.localAttachmentURLs.map(Self.localAttachment),
            deliveryState: .sending
        )
        messages.append(localMessage)
        messages.sort(by: Self.messageSort)
        localOutgoingMessagesByConversationID[selectedConversationID, default: []].append(localMessage)
        draftsByLocalMessageID[localMessage.id] = draft
        draftsByConversationID[selectedConversationID] = nil
        attachmentsByConversationID[selectedConversationID] = nil
        return await performMessageSend(draft, localID: localMessage.id)
    }

    private func performMessageSend(_ draft: ChatMessageDraft, localID: String) async -> Bool {
        guard isModuleEnabled, sendTasksByMessageID[localID] == nil else { return false }
        let operationID = UUID()
        sendOperationIDs[localID] = operationID
        activeSendOperationID = operationID
        isPerformingAction = true
        let task = Task { [repository, weak self] in
            let progress: FileTransferProgress = { [weak self] completed, total in
                guard let total, total > 0 else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.isModuleEnabled,
                          self.draftsByLocalMessageID[localID] != nil else { return }
                    self.uploadProgressByMessageID[localID] = min(max(Double(completed) / Double(total), 0), 1)
                }
            }
            if draft.localAttachmentURLs.isEmpty {
                return try await repository.sendMessageResult(draft, progress: progress)
            }
            return try await repository.sendAttachmentMessageResult(draft, progress: progress)
        }
        sendTasksByMessageID[localID] = task
        defer {
            if sendOperationIDs[localID] == operationID {
                sendOperationIDs[localID] = nil
                sendTasksByMessageID[localID] = nil
                uploadProgressByMessageID[localID] = nil
            }
            if activeSendOperationID == operationID {
                activeSendOperationID = nil
                isPerformingAction = false
            }
        }
        do {
            let outcome = try await task.value
            guard draftsByLocalMessageID[localID] == draft,
                  sendOperationIDs[localID] == nil || sendOperationIDs[localID] == operationID else { return false }
            messageResultsByID[localID] = outcome.result
            switch outcome.result.status {
            case .confirmedSuccess:
                guard let sent = outcome.confirmedMessage,
                      sent.conversationID == draft.conversationID else {
                    replaceDeliveryState(for: localID, with: .failed)
                    failedMessageErrorsByID[localID] = L10n.string("chat.send.unconfirmed")
                    return false
                }
                replaceLocalMessage(localID: localID, with: sent)
                for file in draft.localAttachmentURLs { discardTemporaryMedia(file) }
                return true
            case .cancelledBeforeSubmission:
                removeLocalMessage(id: localID, conversationID: draft.conversationID)
                if draftText(for: draft.conversationID).isEmpty {
                    updateDraft(draft.text ?? "", for: draft.conversationID)
                }
                if self.attachmentURLs(for: draft.conversationID).isEmpty {
                    updateAttachments(draft.localAttachmentURLs, for: draft.conversationID)
                }
                return false
            default:
                replaceDeliveryState(for: localID, with: .failed)
                failedMessageErrorsByID[localID] = messageResultDescription(outcome.result)
                return false
            }
        } catch {
            replaceDeliveryState(for: localID, with: .failed)
            failedMessageErrorsByID[localID] = Self.safeMessage(for: error)
            return false
        }
    }

    private func messageResultDescription(_ result: MutationResult) -> String {
        switch result.status {
        case .submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess:
            return L10n.string("chat.send.unconfirmed")
        case .permissionDenied:
            return L10n.string("chat.send.permissionDenied")
        case .unsupported:
            return L10n.string("chat.send.unsupported")
        default:
            return L10n.string(result.errorCategory == .authentication
                ? "chat.send.authenticationRequired" : "chat.send.failed")
        }
    }

    /// 只继续 Adapter 已保存的原请求，绝不按相似正文或时间将另一条消息认领为本次发送。
    private func reviewPendingMessages(in conversationID: String) async {
        guard !isPerformingAction, isModuleEnabled else { return }
        let drafts = draftsByLocalMessageID.filter {
            $0.value.conversationID == conversationID && isAwaitingMessageConfirmation($0.key)
        }
        for (id, draft) in drafts {
            guard isModuleEnabled, !isPerformingAction else { return }
            _ = await performMessageSend(draft, localID: id)
        }
    }

    func forwardMessages(
        ids: Set<String>,
        to targetConversationIDs: Set<String>,
        newDirectUserIDs: Set<String> = []
    ) async -> Bool {
        guard !isPerformingAction else { return false }
        let existingTargetIDs = targetConversationIDs
            .filter { targetID in
                targetID != selectedConversationID
                    && conversations.contains(where: { $0.id == targetID && !$0.isEncrypted })
            }
        let directUserIDs = newDirectUserIDs.filter { userID in
            users.contains {
                $0.id == userID
                    && $0.id != currentUserID
                    && $0.isCurrentUser != true
                    && !$0.isDisabled
            }
        }
        let sourceMessages = messages
            .filter { ids.contains($0.id) && canForward($0) }
            .sorted(by: Self.messageSort)
        guard (!existingTargetIDs.isEmpty || !directUserIDs.isEmpty),
              existingTargetIDs.count == targetConversationIDs.count,
              directUserIDs.count == newDirectUserIDs.count,
              sourceMessages.count == ids.count else {
            statusIsError = true
            statusMessage = L10n.string("ui.200a7e5fbb2b9bc3")
            return false
        }

        isPerformingAction = true
        statusMessage = nil
        statusIsError = false
        defer { isPerformingAction = false }

        var resolvedTargetIDs = existingTargetIDs
        do {
            // 尚未聊天的联系人需要先取得对应的一对一会话，再交给 NAS 直接转发原消息。
            for userID in directUserIDs.sorted() {
                let requestID = pendingDirectRequests[userID] ?? UUID()
                pendingDirectRequests[userID] = requestID
                let conversation = try await repository.openDirectConversation(
                    userID: userID,
                    clientRequestID: requestID
                )
                pendingDirectRequests[userID] = nil
                merge(conversation)
                if conversation.id != selectedConversationID {
                    resolvedTargetIDs.insert(conversation.id)
                }
            }
        } catch {
            show(error)
            return false
        }
        let targetIDs = resolvedTargetIDs.sorted()
        guard !targetIDs.isEmpty else {
            statusIsError = true
            statusMessage = L10n.string("ui.46fa3f872c997417")
            return false
        }

        var completedCount = 0
        var failedCount = 0
        var lastError: Error?

        for message in sourceMessages {
            do {
                let key = ForwardRequestKey(messageID: message.id, targets: targetIDs)
                let requestID = forwardRequests[key] ?? UUID()
                forwardRequests[key] = requestID
                try await repository.forwardMessage(
                    messageID: message.id,
                    toConversationIDs: targetIDs,
                    clientRequestID: requestID
                )
                completedCount += 1
            } catch {
                failedCount += 1
                lastError = error
            }
        }

        await refreshConversationList()
        if failedCount > 0, let lastError {
            showBatchFailure(
                completedCount: completedCount,
                failedCount: failedCount,
                noun: L10n.string("ui.4ec8d920c4fc522a"),
                lastError: lastError
            )
            return false
        }

        for message in sourceMessages {
            forwardRequests[ForwardRequestKey(messageID: message.id, targets: targetIDs)] = nil
        }
        showToast(
            sourceMessages.count == 1
                ? L10n.string("ui.47bb06634893688d", String(describing: targetIDs.count))
                : L10n.string("ui.6fed19067a9ae071", String(describing: sourceMessages.count), String(describing: targetIDs.count)),
            icon: "arrowshape.turn.up.right.fill"
        )
        return true
    }

    func retryMessage(id: String) async {
        guard canUseSelectedConversation, !isPerformingAction,
              let message = messages.first(where: { $0.id == id }),
              message.deliveryState == .failed,
              let draft = draftsByLocalMessageID[id] else { return }
        if isAwaitingMessageConfirmation(id) {
            await refreshCurrentConversation()
            return
        }
        replaceDeliveryState(for: id, with: .sending)
        failedMessageErrorsByID[id] = nil
        _ = await performMessageSend(draft, localID: id)
    }

    func removeFailedMessage(id: String) {
        guard let message = messages.first(where: { $0.id == id }),
              message.deliveryState == .failed,
              !isAwaitingMessageConfirmation(id) else { return }
        messages.removeAll { $0.id == id }
        localOutgoingMessagesByConversationID[message.conversationID]?.removeAll { $0.id == id }
        failedMessageErrorsByID[id] = nil
        draftsByLocalMessageID[id] = nil
        messageResultsByID[id] = nil
        uploadProgressByMessageID[id] = nil
    }

    func cancelMessageSend(id: String) {
        sendTasksByMessageID[id]?.cancel()
    }

    @discardableResult
    func deleteMessages(ids: Set<String>) async -> Int {
        guard canDeleteOwnMessages, !isPerformingAction, !ids.isEmpty,
              let conversationID = selectedConversationID else { return 0 }
        let targets = messages.filter { ids.contains($0.id) }
        guard targets.count == ids.count, targets.allSatisfy(canDelete) else {
            statusIsError = true
            statusMessage = L10n.string("ui.66a12c2de716c8cf")
            return 0
        }

        isPerformingAction = true
        statusMessage = nil
        statusIsError = false
        var deletedCount = 0
        var deletedIDs: Set<String> = []
        var lastError: Error?
        for message in targets {
            do {
                try await repository.deleteMessage(
                    conversationID: conversationID,
                    messageID: message.id,
                    clientRequestID: UUID()
                )
                deletedCount += 1
                deletedIDs.insert(message.id)
            } catch {
                lastError = error
            }
        }
        // Repository 已经完成服务端回读校验，直接同步本地列表，避免再次刷新失败
        // 覆盖“删除成功”的结果，也减少一次不必要的历史消息请求。
        if selectedConversationID == conversationID, !deletedIDs.isEmpty {
            messages.removeAll { deletedIDs.contains($0.id) }
        }
        isPerformingAction = false
        if let lastError {
            showBatchFailure(
                completedCount: deletedCount,
                failedCount: targets.count - deletedCount,
                noun: L10n.string("ui.3b5110664aa4cadb"),
                lastError: lastError
            )
        } else {
            statusMessage = nil
            statusIsError = false
            showToast(
                deletedCount == 1 ? L10n.string("ui.8a92b54dacdaccad") : L10n.string("ui.b60d233a7f488b7e", String(describing: deletedCount)),
                icon: "trash.fill"
            )
        }
        return deletedCount
    }

    @discardableResult
    func closeConversations(ids: Set<String>) async -> Int {
        guard canCloseConversations, !isPerformingAction, !ids.isEmpty else { return 0 }
        let targets = conversations.filter { ids.contains($0.id) }
        guard targets.count == ids.count else { return 0 }

        isPerformingAction = true
        statusMessage = nil
        statusIsError = false
        var closedCount = 0
        var closedIDs: Set<String> = []
        var lastError: Error?
        for conversation in targets {
            do {
                try await repository.closeConversation(
                    conversationID: conversation.id,
                    clientRequestID: UUID()
                )
                closedCount += 1
                closedIDs.insert(conversation.id)
            } catch {
                lastError = error
            }
        }
        // 关闭接口内部已经复查会话列表。这里直接更新本地状态，避免额外的全量刷新
        // 将已经成功的关闭操作错误显示成失败。
        if !closedIDs.isEmpty {
            conversations.removeAll { closedIDs.contains($0.id) }
            pinnedConversationIDs.removeAll { closedIDs.contains($0) }
            persistPinnedConversations()
            for id in closedIDs {
                draftsByConversationID[id] = nil
                attachmentsByConversationID[id] = nil
                localOutgoingMessagesByConversationID[id] = nil
            }
            if let selectedConversationID, closedIDs.contains(selectedConversationID) {
                self.selectedConversationID = nil
                messages = []
            }
        }
        isPerformingAction = false
        if let lastError {
            showBatchFailure(
                completedCount: closedCount,
                failedCount: targets.count - closedCount,
                noun: L10n.string("ui.0ef703f76a8da8f6"),
                lastError: lastError
            )
        } else {
            statusMessage = nil
            statusIsError = false
            showToast(
                closedCount == 1 ? L10n.string("ui.97f6a92c69ab9f4e") : L10n.string("ui.027eaf484175e27a", String(describing: closedCount)),
                icon: "archivebox.fill"
            )
        }
        return closedCount
    }

    func showToast(
        _ text: String,
        icon: String = "checkmark.circle.fill",
        style: ToastMessage.Style = .success
    ) {
        toastDismissTask?.cancel()
        activeToast = ToastMessage(text: text, icon: icon, style: style)
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.activeToast = nil
        }
    }

    func showAttachmentUnavailable() {
        showToast(
            L10n.string("ui.e19b010fb03f1d59"),
            icon: "paperclip",
            style: .info
        )
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        activeToast = nil
    }

    func clearStatus() {
        statusMessage = nil
        statusIsError = false
    }

    private func replaceLocalMessage(localID: String, with message: ChatMessage) {
        localOutgoingMessagesByConversationID[message.conversationID]?.removeAll { $0.id == localID }
        failedMessageErrorsByID[localID] = nil
        draftsByLocalMessageID[localID] = nil
        messageResultsByID[localID] = nil
        uploadProgressByMessageID[localID] = nil
        guard selectedConversationID == message.conversationID else { return }
        messages.removeAll { $0.id == localID || $0.id == message.id }
        messages.append(message)
        messages.sort(by: Self.messageSort)
    }

    private func removeLocalMessage(id: String, conversationID: String) {
        localOutgoingMessagesByConversationID[conversationID]?.removeAll { $0.id == id }
        if selectedConversationID == conversationID {
            messages.removeAll { $0.id == id }
        }
        failedMessageErrorsByID[id] = nil
        draftsByLocalMessageID[id] = nil
        messageResultsByID[id] = nil
        uploadProgressByMessageID[id] = nil
    }

    private func replaceDeliveryState(for id: String, with state: ChatMessageDeliveryState) {
        guard let conversationID = draftsByLocalMessageID[id]?.conversationID,
              let localIndex = localOutgoingMessagesByConversationID[conversationID]?.firstIndex(where: { $0.id == id }),
              let message = localOutgoingMessagesByConversationID[conversationID]?[localIndex] else { return }
        let updated = ChatMessage(
            id: message.id,
            clientRequestID: message.clientRequestID,
            conversationID: message.conversationID,
            senderID: message.senderID,
            senderDisplayName: message.senderDisplayName,
            isFromCurrentUser: message.isFromCurrentUser,
            sentAt: message.sentAt,
            text: message.text,
            attachments: message.attachments,
            poll: message.poll,
            deliveryState: state,
            encryptionState: message.encryptionState,
            pinnedAt: message.pinnedAt, kind: message.kind, threadID: message.threadID,
            replyCount: message.replyCount, editedAt: message.editedAt
        )
        localOutgoingMessagesByConversationID[conversationID]?[localIndex] = updated
        if selectedConversationID == conversationID,
           let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index] = updated
        }
    }

    private static func mergedMessages(_ first: [ChatMessage], _ second: [ChatMessage]) -> [ChatMessage] {
        var messagesByID: [String: ChatMessage] = [:]
        for message in first { messagesByID[message.id] = message }
        for message in second { messagesByID[message.id] = message }
        return messagesByID.values.sorted(by: messageSort)
    }

    private static func messageSort(_ lhs: ChatMessage, _ rhs: ChatMessage) -> Bool {
        if lhs.sentAt != rhs.sentAt { return lhs.sentAt < rhs.sentAt }
        return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
    }

    private static func safeMessage(for error: Error) -> String {
        if let appError = error as? AppError { return appError.safeUserMessage }
        if let localizedError = error as? LocalizedError,
           let description = localizedError.errorDescription {
            return description
        }
        return L10n.string("ui.46c613a2fccce12e")
    }

    private static func localAttachment(from url: URL) -> ChatAttachment {
        let ext = url.pathExtension.lowercased()
        let kind: ChatAttachmentKind
        if ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff"].contains(ext) {
            kind = .image
        } else if ["mov", "mp4", "m4v", "avi", "mkv", "3gp", "webm"].contains(ext) {
            kind = .video
        } else if ["aac", "mp3", "m4a", "wav", "aiff", "aif", "caf", "flac", "ogg"].contains(ext) {
            kind = .voice
        } else {
            kind = .file
        }
        let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
        return ChatAttachment(
            id: "local-attachment-\(UUID().uuidString)",
            kind: kind,
            fileName: url.lastPathComponent,
            sizeBytes: size ?? nil,
            thumbnailAvailable: false
        )
    }

    private func merge(_ conversation: ChatConversation) {
        conversations.removeAll { $0.id == conversation.id }
        conversations.append(conversation)
        conversations = sortedConversations(conversations)
    }

    private func show(_ error: Error) {
        statusIsError = true
        statusMessage = Self.safeMessage(for: error)
    }

    private func showBatchFailure(
        completedCount: Int,
        failedCount: Int,
        noun: String,
        lastError: Error
    ) {
        statusIsError = true
        let detail: String
        if let appError = lastError as? AppError {
            detail = appError.safeUserMessage
        } else if let localizedError = lastError as? LocalizedError,
                  let description = localizedError.errorDescription {
            detail = description
        } else {
            detail = L10n.string("ui.5448ceb91a80e260")
        }
        if completedCount > 0 {
            statusMessage = L10n.string("ui.7f0fd6ab737e3331", String(describing: completedCount), String(describing: noun), String(describing: failedCount), String(describing: noun), String(describing: detail))
        } else {
            statusMessage = detail
        }
    }

    private func availabilityMessage(for status: ChatAvailabilityStatus) -> String {
        switch status {
        case .available:
            L10n.string("ui.4bb0024f2b966457")
        case .requiresValidation:
            L10n.string("ui.9984c9276092ef03")
        case .unavailable:
            L10n.string("ui.8680d55b0f6fff71")
        }
    }

    private func persistPinnedConversations() {
        guard let pinStorageKey else { return }
        defaults.set(pinnedConversationIDs, forKey: pinStorageKey)
    }

    private func sortedConversations(_ values: [ChatConversation]) -> [ChatConversation] {
        let ranks = Dictionary(
            uniqueKeysWithValues: pinnedConversationIDs.enumerated().map { ($1, $0) }
        )
        return values.sorted { lhs, rhs in
            switch (ranks[lhs.id], ranks[rhs.id]) {
            case let (left?, right?) where left != right:
                return left < right
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return Self.conversationActivitySort(lhs, rhs)
            }
        }
    }

    private static func conversationActivitySort(
        _ lhs: ChatConversation,
        _ rhs: ChatConversation
    ) -> Bool {
        switch (lhs.lastActivityAt, rhs.lastActivityAt) {
        case let (left?, right?) where left != right:
            left > right
        case (nil, _?):
            false
        case (_?, nil):
            true
        default:
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}
