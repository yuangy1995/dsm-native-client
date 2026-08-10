import DsmCore
import Foundation

/// 已接收消息附件的按需缩略图、系统预览与用户触发的安全导出。
///
/// 远端文件始终下载到每次操作独占的临时目录，且服务端文件名只会作为经净化后的叶文件名使用。
extension MobileChatAttachmentModel {
    func loadAttachmentThumbnail(for message: ChatMessage) {
        guard let owner,
              let profileID = owner.activeProfileID,
              let repository = owner.attachmentRepository(for: profileID),
              messageCanUseTransport(message),
              let attachment = message.attachments.first,
              attachment.kind == .image,
              attachment.thumbnailAvailable != false,
              owner.state.attachmentThumbnailsByMessageID[message.id] == nil,
              !owner.state.loadingAttachmentThumbnailIDs.contains(message.id) else {
            return
        }
        let messageID = message.id
        owner.updateActive { $0.loadingAttachmentThumbnailIDs.insert(messageID) }
        let task = Task { [weak self] in
            do {
                let data = try await repository.loadAttachmentThumbnail(
                    messageID: messageID,
                    size: .small
                )
                try Task.checkCancellation()
                self?.finishThumbnail(data, messageID: messageID, profileID: profileID)
            } catch is CancellationError {
                self?.finishThumbnailCancellation(messageID: messageID, profileID: profileID)
            } catch {
                self?.finishThumbnailFailure(messageID: messageID, profileID: profileID)
            }
        }
        thumbnailTasks[messageID] = task
    }

    func previewRemoteAttachment(_ attachment: ChatAttachment, in message: ChatMessage) {
        beginRemoteDownload(attachment, in: message, intent: .preview)
    }

    func saveRemoteAttachment(_ attachment: ChatAttachment, in message: ChatMessage) {
        beginRemoteDownload(attachment, in: message, intent: .exportCopy)
    }

    func dismissRemoteAttachmentPresentation() {
        guard let presentation = remoteAttachmentPresentation else { return }
        remoteAttachmentPresentation = nil
        cleanupDirectory(presentation.directoryURL)
    }

    func cancelRemoteAttachmentDownload() {
        guard owner?.state.remoteAttachmentMessageID != nil else { return }
        remoteDownloadTask?.cancel()
    }

    func canOpenRemoteAttachment(_ attachment: ChatAttachment, in message: ChatMessage) -> Bool {
        canUseRemoteAttachment(attachment, in: message) &&
            owner?.state.remoteAttachmentMessageID == nil &&
            remoteAttachmentPresentation == nil
    }

    func canUseRemoteAttachment(_ attachment: ChatAttachment, in message: ChatMessage) -> Bool {
        messageCanUseTransport(message) && message.attachments.first?.id == attachment.id
    }

    private func beginRemoteDownload(
        _ attachment: ChatAttachment,
        in message: ChatMessage,
        intent: MobileChatRemoteAttachmentPresentationIntent
    ) {
        guard let owner,
              let profileID = owner.activeProfileID,
              let repository = owner.attachmentRepository(for: profileID),
              canOpenRemoteAttachment(attachment, in: message) else {
            return
        }
        let directoryURL = rootURL.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destinationURL = directoryURL.appendingPathComponent(
            MobileDocumentTransferController.safeLeafName(attachment.fileName),
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            owner.updateActive { profile in
                profile.remoteAttachmentErrorCategory = Self.category(for: error)
                profile.remoteAttachmentErrorMessageID = message.id
            }
            return
        }

        remoteDownloadTask?.cancel()
        remoteDownloadTask = nil
        remoteDownloadGeneration &+= 1
        let generation = remoteDownloadGeneration
        owner.updateActive { profile in
            profile.remoteAttachmentMessageID = message.id
            profile.remoteAttachmentProgressFraction = nil
            profile.remoteAttachmentErrorCategory = nil
            profile.remoteAttachmentErrorMessageID = nil
        }
        let task = Task { [weak self] in
            do {
                try await repository.downloadAttachment(
                    messageID: message.id,
                    to: destinationURL,
                    progress: { [weak self] completedBytes, totalBytes in
                        let fraction = Self.progressFraction(
                            completedBytes: completedBytes,
                            totalBytes: totalBytes
                        )
                        Task { @MainActor [weak self] in
                            self?.updateRemoteProgress(
                                fraction,
                                profileID: profileID,
                                conversationID: message.conversationID,
                                messageID: message.id,
                                generation: generation
                            )
                        }
                    }
                )
                try Task.checkCancellation()
                guard let self else {
                    try? FileManager.default.removeItem(at: directoryURL)
                    return
                }
                try self.fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destinationURL.path
                )
                self.finishRemoteDownload(
                    title: attachment.fileName,
                    directoryURL: directoryURL,
                    destinationURL: destinationURL,
                    intent: intent,
                    profileID: profileID,
                    conversationID: message.conversationID,
                    messageID: message.id,
                    generation: generation
                )
            } catch is CancellationError {
                guard let self else {
                    try? FileManager.default.removeItem(at: directoryURL)
                    return
                }
                self.finishRemoteDownloadFailure(
                    directoryURL: directoryURL,
                    error: nil,
                    profileID: profileID,
                    conversationID: message.conversationID,
                    messageID: message.id,
                    generation: generation
                )
            } catch {
                guard let self else {
                    try? FileManager.default.removeItem(at: directoryURL)
                    return
                }
                self.finishRemoteDownloadFailure(
                    directoryURL: directoryURL,
                    error: error,
                    profileID: profileID,
                    conversationID: message.conversationID,
                    messageID: message.id,
                    generation: generation
                )
            }
        }
        remoteDownloadTask = task
    }

    private func finishThumbnail(_ data: Data, messageID: String, profileID: UUID) {
        guard let owner,
              owner.activeProfileID == profileID,
              owner.state.selectedMessages.messages.contains(where: { $0.id == messageID }) else {
            return
        }
        owner.updateActive { profile in
            profile.attachmentThumbnailsByMessageID[messageID] = data
            profile.loadingAttachmentThumbnailIDs.remove(messageID)
        }
        thumbnailTasks[messageID] = nil
    }

    private func finishThumbnailCancellation(messageID: String, profileID: UUID) {
        guard let owner, owner.activeProfileID == profileID else { return }
        owner.updateActive { $0.loadingAttachmentThumbnailIDs.remove(messageID) }
        thumbnailTasks[messageID] = nil
    }

    private func finishThumbnailFailure(messageID: String, profileID: UUID) {
        guard let owner, owner.activeProfileID == profileID else { return }
        owner.updateActive { $0.loadingAttachmentThumbnailIDs.remove(messageID) }
        thumbnailTasks[messageID] = nil
    }

    private func updateRemoteProgress(
        _ fraction: Double?,
        profileID: UUID,
        conversationID: String,
        messageID: String,
        generation: Int
    ) {
        guard isCurrentRemoteDownload(
            profileID: profileID,
            conversationID: conversationID,
            messageID: messageID,
            generation: generation
        ) else { return }
        owner?.updateActive { $0.remoteAttachmentProgressFraction = fraction }
    }

    private func finishRemoteDownload(
        title: String,
        directoryURL: URL,
        destinationURL: URL,
        intent: MobileChatRemoteAttachmentPresentationIntent,
        profileID: UUID,
        conversationID: String,
        messageID: String,
        generation: Int
    ) {
        guard let owner,
              isCurrentRemoteDownload(
                profileID: profileID,
                conversationID: conversationID,
                messageID: messageID,
                generation: generation
              ) else {
            cleanupDirectory(directoryURL)
            return
        }
        remoteAttachmentPresentation = MobileChatRemoteAttachmentPresentation(
            id: UUID(),
            title: title,
            localURL: destinationURL,
            directoryURL: directoryURL,
            intent: intent
        )
        owner.updateActive { profile in
            profile.remoteAttachmentMessageID = nil
            profile.remoteAttachmentProgressFraction = nil
            profile.remoteAttachmentErrorCategory = nil
            profile.remoteAttachmentErrorMessageID = nil
        }
        remoteDownloadTask = nil
    }

    private func finishRemoteDownloadFailure(
        directoryURL: URL,
        error: Error?,
        profileID: UUID,
        conversationID: String,
        messageID: String,
        generation: Int
    ) {
        cleanupDirectory(directoryURL)
        guard let owner,
              isCurrentRemoteDownload(
                profileID: profileID,
                conversationID: conversationID,
                messageID: messageID,
                generation: generation
              ) else {
            return
        }
        owner.updateActive { profile in
            profile.remoteAttachmentMessageID = nil
            profile.remoteAttachmentProgressFraction = nil
            if let error {
                profile.remoteAttachmentErrorCategory = Self.category(for: error)
                profile.remoteAttachmentErrorMessageID = messageID
            }
        }
        remoteDownloadTask = nil
    }

    private func messageCanUseTransport(_ message: ChatMessage) -> Bool {
        guard let owner,
              owner.state.selectedConversationID == message.conversationID,
              owner.state.selectedConversation?.isEncrypted == false,
              message.attachments.count == 1,
              owner.state.availability.supportedFeatures.contains(.attachmentDownload) else {
            return false
        }
        return true
    }

    private func isCurrentRemoteDownload(
        profileID: UUID,
        conversationID: String,
        messageID: String,
        generation: Int
    ) -> Bool {
        guard let owner else { return false }
        return owner.activeProfileID == profileID &&
            owner.state.selectedConversationID == conversationID &&
            owner.state.remoteAttachmentMessageID == messageID &&
            remoteDownloadGeneration == generation
    }
}
