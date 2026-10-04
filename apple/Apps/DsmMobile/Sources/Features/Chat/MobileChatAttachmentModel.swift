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
    @ObservationIgnored var thumbnailTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var remoteDownloadTask: Task<Void, Never>?
    @ObservationIgnored private var preparationGeneration = 0
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
              owner.management?.blocksWrites(in: owner.state.selectedConversationID ?? "") != true,
              !owner.state.isPreparingAttachment,
              !owner.state.isSendingMessage,
              !owner.state.isSendingAttachment,
              owner.sending?.recovery.failed == false else {
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
        guard let owner, let sending = owner.sending,
              owner.management?.blocksWrites(in: owner.state.selectedConversationID ?? "") != true else { return false }
        if let selectedAttachment {
            return canSelectAttachment &&
                owner.state.availability.supportedFeatures.contains(selectedAttachment.requiredFeature)
        }
        return owner.state.canSendSelectedDraft && sending.canSend(conversationID: owner.state.selectedConversationID ?? "", text: owner.state.selectedDraft)
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
        owner?.sending?.cancel()
    }

    func leaveConversation(_ conversationID: String) {
        guard owner?.state.selectedConversationID == conversationID else { return }
        cancelAllWork()
    }

    func sendSelectedAttachment() async {
        guard let owner, let sending = owner.sending, canSendSelectedDraft,
              let conversation = owner.state.selectedConversation, let attachment = selectedAttachment else { return }
        let text = owner.state.selectedDraft
        selectedAttachment = nil
        // 副本准备结束前保留输入；离页不清理正在复制的文件。
        defer { cleanup(attachment) }
        await sending.send(conversationID: conversation.id, text: text, attachment: attachment)
    }

    func cancelAllWork() {
        preparationTask?.cancel()
        preparationTask = nil
        preparationGeneration &+= 1
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks = [:]
        remoteDownloadTask?.cancel()
        remoteDownloadTask = nil
        remoteDownloadGeneration &+= 1
        dismissRemoteAttachmentPresentation()
        releaseSelectedAttachment()
        owner?.updateActive { profile in
            profile.isPreparingAttachment = false
            profile.isSendingAttachment = false
            profile.attachmentProgressFraction = nil
            profile.loadingAttachmentThumbnailIDs = []
            profile.remoteAttachmentMessageID = nil
            profile.remoteAttachmentProgressFraction = nil
            profile.remoteAttachmentErrorMessageID = nil
            profile.remoteAttachmentErrorCategory = nil
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

}
