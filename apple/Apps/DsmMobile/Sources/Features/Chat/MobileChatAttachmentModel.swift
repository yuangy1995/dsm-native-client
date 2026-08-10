import DsmCore
import Foundation
import Observation

/// 聊天附件的短生命周期状态机。
///
/// 本类型只保留当前编辑器或正在执行的任务所需的临时文件引用；它不会把本地 URL
/// 写入配置档状态、持久化存储或诊断信息。
@MainActor
@Observable
final class MobileChatAttachmentModel {
    // 远端附件操作扩展位于独立文件，以下引用仅供该内部实现共享。
    weak var owner: MobileChatModel?
    let fileManager: FileManager
    private let copier: any MobileDocumentImportCopying
    let rootURL: URL

    private(set) var selectedAttachment: MobileChatAttachmentSelection?
    var remoteAttachmentPresentation: MobileChatRemoteAttachmentPresentation?

    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored var thumbnailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var remoteDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var inFlightAttachments: [UUID: MobileChatAttachmentSelection] = [:]
    @ObservationIgnored private var preparationGeneration = 0
    @ObservationIgnored private var sendGeneration = 0
    @ObservationIgnored var remoteDownloadGeneration = 0

    init(
        owner: MobileChatModel,
        fileManager: FileManager,
        copier: any MobileDocumentImportCopying,
        rootURL: URL
    ) {
        self.owner = owner
        self.fileManager = fileManager
        self.copier = copier
        self.rootURL = rootURL
    }

    var canSelectAttachment: Bool {
        guard let owner,
              owner.state.selectedConversation?.isEncrypted == false,
              !owner.state.isPreparingAttachment,
              !owner.state.isSendingMessage,
              !owner.state.isSendingAttachment,
              !owner.state.attachmentReviewRequired else {
            return false
        }
        return supportedFeatures.contains { owner.state.availability.supportedFeatures.contains($0) }
    }

    var canComposeMessage: Bool {
        guard let owner, owner.state.selectedConversation?.isEncrypted == false else {
            return false
        }
        return owner.state.availability.supportedFeatures.contains(.textMessage) ||
            supportedFeatures.contains { owner.state.availability.supportedFeatures.contains($0) }
    }

    var canSendSelectedDraft: Bool {
        guard let owner, !owner.state.attachmentReviewRequired else { return false }
        if let selectedAttachment {
            return canSelectAttachment &&
                owner.state.availability.supportedFeatures.contains(selectedAttachment.requiredFeature)
        }
        return owner.state.canSendSelectedDraft && !owner.state.isSendingAttachment
    }

    func preparePhotoAttachment(_ item: any MobilePhotosPickerItemServing) {
        guard let context = beginPreparation() else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let artifact = try await item.loadArtifact()
                defer { artifact.release() }
                let selection = try await self.makeSelection(from: artifact.url)
                self.finishPreparation(
                    selection,
                    profileID: context.profileID,
                    conversationID: context.conversationID,
                    generation: context.generation
                )
            } catch is CancellationError {
                self.finishPreparationCancellation(
                    profileID: context.profileID,
                    conversationID: context.conversationID,
                    generation: context.generation
                )
            } catch {
                self.finishPreparationFailure(
                    error,
                    profileID: context.profileID,
                    conversationID: context.conversationID,
                    generation: context.generation
                )
            }
        }
        preparationTask = task
    }

    func prepareFileAttachment(_ sourceURL: URL) {
        guard let context = beginPreparation() else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let selection = try await self.makeSelection(from: sourceURL)
                self.finishPreparation(
                    selection,
                    profileID: context.profileID,
                    conversationID: context.conversationID,
                    generation: context.generation
                )
            } catch is CancellationError {
                self.finishPreparationCancellation(
                    profileID: context.profileID,
                    conversationID: context.conversationID,
                    generation: context.generation
                )
            } catch {
                self.finishPreparationFailure(
                    error,
                    profileID: context.profileID,
                    conversationID: context.conversationID,
                    generation: context.generation
                )
            }
        }
        preparationTask = task
    }

    func rejectAttachmentSelection() {
        guard let owner,
              owner.state.selectedConversation?.isEncrypted == false else {
            return
        }
        owner.updateActive { $0.attachmentErrorCategory = .invalidResponse }
    }

    func removeSelectedAttachment() {
        guard let owner,
              !owner.state.isPreparingAttachment,
              !owner.state.isSendingAttachment else {
            return
        }
        releaseSelectedAttachment()
        owner.updateActive { profile in
            profile.attachmentErrorCategory = nil
            profile.attachmentProgressFraction = nil
        }
    }

    func cancelSelectedAttachmentSend() {
        guard owner?.state.isSendingAttachment == true else { return }
        sendTask?.cancel()
    }

    func leaveConversation(_ conversationID: String) {
        guard owner?.state.selectedConversationID == conversationID else { return }
        cancelAllWork()
    }

    func sendSelectedAttachment() async {
        guard let owner,
              let profileID = owner.activeProfileID,
              let repository = owner.attachmentRepository(for: profileID),
              let conversation = owner.state.selectedConversation,
              !conversation.isEncrypted,
              !owner.state.attachmentReviewRequired,
              let attachment = selectedAttachment,
              !owner.state.isPreparingAttachment,
              !owner.state.isSendingMessage,
              !owner.state.isSendingAttachment,
              owner.state.availability.supportedFeatures.contains(attachment.requiredFeature) else {
            if selectedAttachment != nil {
                owner?.updateActive { $0.attachmentErrorCategory = .apiUnavailable }
            }
            return
        }

        let draft: ChatMessageDraft
        do {
            draft = try ChatMessageDraft(
                conversationID: conversation.id,
                text: owner.state.selectedDraft,
                localAttachmentURLs: [attachment.localURL]
            )
        } catch {
            owner.updateActive { $0.attachmentErrorCategory = Self.category(for: error) }
            return
        }

        selectedAttachment = nil
        inFlightAttachments[draft.clientRequestID] = attachment
        let generation = beginSend { profile in
            profile.isSendingAttachment = true
            profile.attachmentProgressFraction = nil
            profile.attachmentErrorCategory = nil
            profile.attachmentReviewRequired = false
        }
        let task = Task { [weak self] in
            do {
                let outcome = try await repository.sendAttachmentMessageResult(
                    draft,
                    progress: { [weak self] completedBytes, totalBytes in
                        let fraction = Self.progressFraction(
                            completedBytes: completedBytes,
                            totalBytes: totalBytes
                        )
                        Task { @MainActor [weak self] in
                            self?.updateSendProgress(
                                fraction,
                                profileID: profileID,
                                conversationID: conversation.id,
                                generation: generation
                            )
                        }
                    }
                )
                self?.finishSendOutcome(
                    outcome,
                    draft: draft,
                    profileID: profileID,
                    conversationID: conversation.id,
                    generation: generation
                )
            } catch is CancellationError {
                self?.finishSendReview(
                    profileID: profileID,
                    conversationID: conversation.id,
                    clientRequestID: draft.clientRequestID,
                    generation: generation
                )
            } catch {
                self?.finishSendFailure(
                    error,
                    profileID: profileID,
                    conversationID: conversation.id,
                    clientRequestID: draft.clientRequestID,
                    generation: generation
                )
            }
        }
        sendTask = task
        await task.value
    }

    func clearReviewAfterMessageRefresh() {
        owner?.updateActive { profile in
            profile.attachmentReviewRequired = false
            profile.attachmentErrorCategory = nil
        }
    }

    func cancelAllWork() {
        let shouldRequireSendReview = owner?.state.isSendingAttachment == true && !inFlightAttachments.isEmpty
        let inFlightAttachmentsToClean = Array(inFlightAttachments.values)
        inFlightAttachments = [:]
        preparationTask?.cancel()
        preparationTask = nil
        preparationGeneration &+= 1
        sendTask?.cancel()
        sendTask = nil
        sendGeneration &+= 1
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks = [:]
        remoteDownloadTask?.cancel()
        remoteDownloadTask = nil
        remoteDownloadGeneration &+= 1
        dismissRemoteAttachmentPresentation()
        releaseSelectedAttachment()
        inFlightAttachmentsToClean.forEach(cleanup)
        owner?.updateActive { profile in
            profile.isPreparingAttachment = false
            profile.isSendingAttachment = false
            profile.attachmentProgressFraction = nil
            profile.loadingAttachmentThumbnailIDs = []
            profile.remoteAttachmentMessageID = nil
            profile.remoteAttachmentProgressFraction = nil
            profile.remoteAttachmentErrorMessageID = nil
            profile.remoteAttachmentErrorCategory = nil
            if shouldRequireSendReview {
                profile.attachmentReviewRequired = true
                profile.attachmentErrorCategory = .partialFailure
            }
        }
    }

    private var supportedFeatures: Set<ChatFeature> {
        [.imageAttachment, .videoAttachment, .fileAttachment]
    }

    private func beginPreparation() -> (profileID: UUID, conversationID: String, generation: Int)? {
        guard let owner,
              let profileID = owner.activeProfileID,
              let conversation = owner.state.selectedConversation,
              !conversation.isEncrypted,
              canSelectAttachment else {
            return nil
        }
        preparationTask?.cancel()
        preparationTask = nil
        preparationGeneration &+= 1
        releaseSelectedAttachment()
        let generation = preparationGeneration
        owner.updateActive { profile in
            profile.isPreparingAttachment = true
            profile.attachmentErrorCategory = nil
            profile.attachmentProgressFraction = nil
        }
        return (profileID, conversation.id, generation)
    }

    private func makeSelection(from sourceURL: URL) async throws -> MobileChatAttachmentSelection {
        let directoryURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationURL = directoryURL.appendingPathComponent(
            MobileDocumentTransferController.safeLeafName(sourceURL.lastPathComponent),
            isDirectory: false
        )
        do {
            try await copier.copySecurityScopedFile(
                from: sourceURL,
                to: destinationURL,
                in: directoryURL
            )
            try Task.checkCancellation()
            let values = try destinationURL.resourceValues(forKeys: [
                .contentTypeKey,
                .fileSizeKey,
                .isRegularFileKey
            ])
            guard values.isRegularFile != false else {
                throw MobileChatAttachmentSelectionError.invalidSelection
            }
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
            return MobileChatAttachmentSelection(
                id: UUID(),
                localURL: destinationURL,
                directoryURL: directoryURL,
                fileName: destinationURL.lastPathComponent,
                kind: MobileChatAttachmentSelection.kind(
                    contentType: values.contentType,
                    fileName: destinationURL.lastPathComponent
                ),
                byteCount: values.fileSize.map(Int64.init)
            )
        } catch {
            cleanupDirectory(directoryURL)
            throw error
        }
    }

    private func finishPreparation(
        _ selection: MobileChatAttachmentSelection,
        profileID: UUID,
        conversationID: String,
        generation: Int
    ) {
        guard let owner,
              isCurrentPreparation(
                profileID: profileID,
                conversationID: conversationID,
                generation: generation
              ) else {
            cleanup(selection)
            return
        }
        guard owner.state.availability.supportedFeatures.contains(selection.requiredFeature) else {
            cleanup(selection)
            owner.updateActive { profile in
                profile.isPreparingAttachment = false
                profile.attachmentErrorCategory = .apiUnavailable
            }
            preparationTask = nil
            return
        }
        releaseSelectedAttachment()
        selectedAttachment = selection
        owner.updateActive { profile in
            profile.isPreparingAttachment = false
            profile.attachmentErrorCategory = nil
        }
        preparationTask = nil
    }

    private func finishPreparationFailure(
        _ error: Error,
        profileID: UUID,
        conversationID: String,
        generation: Int
    ) {
        guard let owner,
              isCurrentPreparation(
                profileID: profileID,
                conversationID: conversationID,
                generation: generation
              ) else {
            return
        }
        owner.updateActive { profile in
            profile.isPreparingAttachment = false
            profile.attachmentErrorCategory = Self.category(for: error)
        }
        preparationTask = nil
    }

    private func finishPreparationCancellation(
        profileID: UUID,
        conversationID: String,
        generation: Int
    ) {
        guard let owner,
              isCurrentPreparation(
                profileID: profileID,
                conversationID: conversationID,
                generation: generation
              ) else {
            return
        }
        owner.updateActive { $0.isPreparingAttachment = false }
        preparationTask = nil
    }

    private func beginSend(_ update: (inout MobileChatProfileState) -> Void) -> Int {
        sendTask?.cancel()
        sendTask = nil
        sendGeneration &+= 1
        owner?.updateActive(update)
        return sendGeneration
    }

    private func updateSendProgress(
        _ fraction: Double?,
        profileID: UUID,
        conversationID: String,
        generation: Int
    ) {
        guard isCurrentSend(
            profileID: profileID,
            conversationID: conversationID,
            generation: generation
        ) else { return }
        owner?.updateActive { $0.attachmentProgressFraction = fraction }
    }

    private func finishSendOutcome(
        _ outcome: ChatMessageSendOutcome,
        draft: ChatMessageDraft,
        profileID: UUID,
        conversationID: String,
        generation: Int
    ) {
        guard outcome.clientRequestID == draft.clientRequestID,
              outcome.conversationID == conversationID else {
            finishSendReview(
                profileID: profileID,
                conversationID: conversationID,
                clientRequestID: draft.clientRequestID,
                generation: generation
            )
            return
        }
        switch outcome.result.status {
        case .confirmedSuccess:
            guard let message = outcome.confirmedMessage else {
                finishSendReview(
                    profileID: profileID,
                    conversationID: conversationID,
                    clientRequestID: draft.clientRequestID,
                    generation: generation
                )
                return
            }
            finishSendSuccess(
                message,
                draft: draft,
                profileID: profileID,
                conversationID: conversationID,
                generation: generation
            )
        case .cancelledBeforeSubmission:
            finishSendCancellationBeforeSubmission(
                profileID: profileID,
                conversationID: conversationID,
                clientRequestID: draft.clientRequestID,
                generation: generation
            )
        case .submittedButUnverified, .cancellationRequestedAfterSubmission:
            finishSendReview(
                profileID: profileID,
                conversationID: conversationID,
                clientRequestID: draft.clientRequestID,
                generation: generation
            )
        case .permissionDenied, .confirmedFailure, .partialSuccess, .unsupported:
            finishSendFailure(
                Self.appError(for: outcome.result),
                profileID: profileID,
                conversationID: conversationID,
                clientRequestID: draft.clientRequestID,
                generation: generation
            )
        }
    }

    private func finishSendSuccess(
        _ message: ChatMessage,
        draft: ChatMessageDraft,
        profileID: UUID,
        conversationID: String,
        generation: Int
    ) {
        guard let owner,
              let attachment = takeInFlight(
                clientRequestID: draft.clientRequestID,
                profileID: profileID,
                conversationID: conversationID,
                generation: generation
              ) else {
            return
        }
        cleanup(attachment)
        guard message.conversationID == conversationID else {
            finishSendReviewState()
            return
        }
        owner.updateActive { profile in
            let existing = profile.messagesByConversation[conversationID]?.messages ?? []
            let messages = MobileChatModel.normalizedMessages(existing + [message])
            let previous = profile.messagesByConversation[conversationID]
            profile.messagesByConversation[conversationID] = MobileChatMessageCache(
                messages: messages,
                previousCursor: previous?.previousCursor,
                hasMoreBefore: previous?.hasMoreBefore ?? false
            )
            profile.messagePageState = messages.isEmpty ? .empty : .content
            if let text = draft.text,
               profile.draftsByConversation[conversationID]?.trimmingCharacters(in: .whitespacesAndNewlines) == text {
                profile.draftsByConversation[conversationID] = ""
            }
            profile.isSendingAttachment = false
            profile.attachmentProgressFraction = nil
            profile.attachmentReviewRequired = false
            profile.attachmentErrorCategory = nil
        }
        sendTask = nil
    }

    private func finishSendCancellationBeforeSubmission(
        profileID: UUID,
        conversationID: String,
        clientRequestID: UUID,
        generation: Int
    ) {
        guard let owner,
              let attachment = takeInFlight(
                clientRequestID: clientRequestID,
                profileID: profileID,
                conversationID: conversationID,
                generation: generation
              ) else {
            return
        }
        releaseSelectedAttachment()
        selectedAttachment = attachment
        owner.updateActive { profile in
            profile.isSendingAttachment = false
            profile.attachmentProgressFraction = nil
            profile.attachmentErrorCategory = nil
        }
        sendTask = nil
    }

    private func finishSendReview(
        profileID: UUID,
        conversationID: String,
        clientRequestID: UUID,
        generation: Int
    ) {
        guard let attachment = takeInFlight(
            clientRequestID: clientRequestID,
            profileID: profileID,
            conversationID: conversationID,
            generation: generation
        ) else { return }
        cleanup(attachment)
        finishSendReviewState()
    }

    private func finishSendReviewState() {
        owner?.updateActive { profile in
            profile.isSendingAttachment = false
            profile.attachmentProgressFraction = nil
            profile.attachmentReviewRequired = true
            profile.attachmentErrorCategory = .partialFailure
        }
        sendTask = nil
    }

    private func finishSendFailure(
        _ error: Error,
        profileID: UUID,
        conversationID: String,
        clientRequestID: UUID,
        generation: Int
    ) {
        guard let owner,
              let attachment = takeInFlight(
                clientRequestID: clientRequestID,
                profileID: profileID,
                conversationID: conversationID,
                generation: generation
              ) else {
            return
        }
        releaseSelectedAttachment()
        selectedAttachment = attachment
        owner.updateActive { profile in
            profile.isSendingAttachment = false
            profile.attachmentProgressFraction = nil
            profile.attachmentErrorCategory = Self.category(for: error)
        }
        sendTask = nil
    }

    private func takeInFlight(
        clientRequestID: UUID,
        profileID: UUID,
        conversationID: String,
        generation: Int
    ) -> MobileChatAttachmentSelection? {
        guard let attachment = inFlightAttachments.removeValue(forKey: clientRequestID) else {
            return nil
        }
        guard isCurrentSend(
            profileID: profileID,
            conversationID: conversationID,
            generation: generation
        ) else {
            cleanup(attachment)
            return nil
        }
        return attachment
    }

    private func releaseSelectedAttachment() {
        guard let selectedAttachment else { return }
        self.selectedAttachment = nil
        cleanup(selectedAttachment)
    }

    func cleanupDirectory(_ directoryURL: URL) {
        guard directoryURL.deletingLastPathComponent().standardizedFileURL == rootURL.standardizedFileURL else {
            return
        }
        try? fileManager.removeItem(at: directoryURL)
    }

    private func cleanup(_ attachment: MobileChatAttachmentSelection) {
        cleanupDirectory(attachment.directoryURL)
    }

    private func isCurrentPreparation(
        profileID: UUID,
        conversationID: String,
        generation: Int
    ) -> Bool {
        guard let owner else { return false }
        return owner.activeProfileID == profileID &&
            owner.state.selectedConversationID == conversationID &&
            preparationGeneration == generation
    }

    private func isCurrentSend(
        profileID: UUID,
        conversationID: String,
        generation: Int
    ) -> Bool {
        guard let owner else { return false }
        return owner.activeProfileID == profileID &&
            owner.state.selectedConversationID == conversationID &&
            sendGeneration == generation
    }

    nonisolated static func progressFraction(
        completedBytes: Int64,
        totalBytes: Int64?
    ) -> Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(completedBytes) / Double(totalBytes)))
    }

    static func category(for error: Error) -> AppErrorCategory {
        if let error = error as? MobileChatAttachmentSelectionError {
            switch error {
            case .unavailable, .unsupportedType:
                return .apiUnavailable
            case .invalidSelection:
                return .invalidResponse
            }
        }
        if error is MobilePhotosPickerFailure { return .invalidResponse }
        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain,
           cocoaError.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return .localStorageFull
        }
        return (error as? AppError)?.category ?? .unknown
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
