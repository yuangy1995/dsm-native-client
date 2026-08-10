@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

@MainActor
final class MobileChatAttachmentTests: XCTestCase {
    func test选择新附件会替换并清理前一个受控临时文件() async throws {
        let rootURL = try makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let firstURL = try makeSourceFile(named: "first.png")
        let secondURL = try makeSourceFile(named: "second.png")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let conversation = Self.conversation(id: "c1")
        let repository = AttachmentChatRepositoryStub(conversations: [conversation])
        let model = MobileChatModel(attachmentRootURL: rootURL)

        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversation)
        model.prepareFileAttachment(firstURL)
        let selectedFirstAttachment = await waitUntil { model.selectedAttachment != nil }
        XCTAssertTrue(selectedFirstAttachment)
        guard selectedFirstAttachment else { return }
        let firstTemporaryURL = try XCTUnwrap(model.selectedAttachment?.localURL)

        model.prepareFileAttachment(secondURL)
        let selectedReplacementAttachment = await waitUntil {
            model.selectedAttachment?.fileName == secondURL.lastPathComponent
        }
        XCTAssertTrue(selectedReplacementAttachment)
        guard selectedReplacementAttachment else { return }

        XCTAssertFalse(FileManager.default.fileExists(atPath: firstTemporaryURL.path))
        XCTAssertEqual(model.selectedAttachment?.fileName, secondURL.lastPathComponent)
        model.deactivate()
        XCTAssertNil(model.selectedAttachment)
        if FileManager.default.fileExists(atPath: rootURL.path) {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: rootURL.path).isEmpty)
        }
    }

    func test确认成功后使用附件结果并清理临时文件() async throws {
        let rootURL = try makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = try makeSourceFile(named: "photo.png")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let conversation = Self.conversation(id: "c1")
        let repository = AttachmentChatRepositoryStub(conversations: [conversation])
        let model = MobileChatModel(attachmentRootURL: rootURL)

        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversation)
        model.setDraft("说明")
        model.prepareFileAttachment(sourceURL)
        let selectedAttachment = await waitUntil { model.selectedAttachment != nil }
        XCTAssertTrue(selectedAttachment)
        guard selectedAttachment else { return }
        let temporaryURL = try XCTUnwrap(model.selectedAttachment?.localURL)

        await model.sendSelectedMessage()

        let drafts = await repository.attachmentDrafts()
        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].conversationID, conversation.id)
        XCTAssertEqual(drafts[0].text, "说明")
        XCTAssertEqual(drafts[0].localAttachmentURLs.count, 1)
        XCTAssertNil(model.selectedAttachment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporaryURL.path))
        XCTAssertFalse(model.state.isSendingAttachment)
        XCTAssertFalse(model.state.attachmentReviewRequired)
        XCTAssertEqual(model.state.selectedMessages.messages.count, 1)
    }

    func test提交后未确认会移除选择且不会自动重发同一附件() async throws {
        let rootURL = try makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = try makeSourceFile(named: "unverified.png")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        let conversation = Self.conversation(id: "c1")
        let repository = AttachmentChatRepositoryStub(
            conversations: [conversation],
            attachmentStatus: .submittedButUnverified
        )
        let model = MobileChatModel(attachmentRootURL: rootURL)

        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversation)
        model.prepareFileAttachment(sourceURL)
        let selectedAttachment = await waitUntil { model.selectedAttachment != nil }
        XCTAssertTrue(selectedAttachment)
        guard selectedAttachment else { return }

        await model.sendSelectedMessage()
        await model.sendSelectedMessage()

        XCTAssertNil(model.selectedAttachment)
        XCTAssertTrue(model.state.attachmentReviewRequired)
        let attachmentDraftCount = await repository.attachmentDrafts().count
        XCTAssertEqual(attachmentDraftCount, 1)
    }

    func test离开发送中的会话会要求核对且阻止再次选择附件() async throws {
        let rootURL = try makeRootURL()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let sourceURL = try makeSourceFile(named: "late.png")
        let secondURL = try makeSourceFile(named: "second.png")
        defer { try? FileManager.default.removeItem(at: sourceURL) }
        defer { try? FileManager.default.removeItem(at: secondURL) }
        let conversation = Self.conversation(id: "c1")
        let repository = AttachmentChatRepositoryStub(
            conversations: [conversation],
            blocksAttachmentSend: true
        )
        let model = MobileChatModel(attachmentRootURL: rootURL)

        await model.activate(profileID: UUID(), repository: repository)
        await model.selectConversation(conversation)
        model.prepareFileAttachment(sourceURL)
        let selectedAttachment = await waitUntil { model.selectedAttachment != nil }
        XCTAssertTrue(selectedAttachment)
        guard selectedAttachment else { return }

        let sendTask = Task { await model.sendSelectedMessage() }
        await repository.waitUntilAttachmentSendBlocked()
        model.leaveConversation(conversation.id)
        XCTAssertTrue(model.state.attachmentReviewRequired)
        model.prepareFileAttachment(secondURL)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.selectedAttachment)
        await repository.releaseAttachmentSend()
        await sendTask.value

        XCTAssertNil(model.selectedAttachment)
        XCTAssertFalse(model.state.isSendingAttachment)
        XCTAssertTrue(model.state.attachmentReviewRequired)
        XCTAssertTrue(model.state.selectedMessages.messages.isEmpty)
        let attachmentDraftCount = await repository.attachmentDrafts().count
        XCTAssertEqual(attachmentDraftCount, 1)
    }

    private func makeRootURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileChatAttachmentTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeSourceFile(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MobileChatAttachmentTests-\(UUID().uuidString)-\(name)")
        try Data("attachment".utf8).write(to: url, options: .atomic)
        return url
    }

    private func waitUntil(
        _ condition: @MainActor @escaping () -> Bool,
        attempts: Int = 200
    ) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func conversation(id: String) -> ChatConversation {
        ChatConversation(id: id, kind: .group, title: "测试会话", memberIDs: [])
    }
}

private actor AttachmentChatRepositoryStub: ChatRepository {
    private let availabilityValue: ChatAvailability
    private let conversationValues: [ChatConversation]
    private let attachmentStatus: MutationResultStatus
    private let blocksAttachmentSend: Bool
    private var attachmentDraftValues: [ChatMessageDraft] = []
    private var attachmentContinuation: CheckedContinuation<Void, Never>?
    private var attachmentBlockedWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        conversations: [ChatConversation],
        attachmentStatus: MutationResultStatus = .confirmedSuccess,
        blocksAttachmentSend: Bool = false
    ) {
        availabilityValue = ChatAvailability(
            status: .available,
            supportedFeatures: [.textMessage, .imageAttachment, .fileAttachment, .attachmentDownload]
        )
        conversationValues = conversations
        self.attachmentStatus = attachmentStatus
        self.blocksAttachmentSend = blocksAttachmentSend
    }

    func availability() async -> ChatAvailability { availabilityValue }
    func listUsers() async throws -> [ChatUser] { [] }
    func listConversations() async throws -> [ChatConversation] { conversationValues }

    func listMessages(
        conversationID: String,
        before cursor: String?,
        limit: Int
    ) async throws -> ChatMessagePage {
        ChatMessagePage(messages: [], previousCursor: nil, hasMoreBefore: false)
    }

    func openDirectConversation(userID: String, clientRequestID: UUID) async throws -> ChatConversation {
        throw unavailableError()
    }

    func createGroup(_ draft: ChatGroupDraft) async throws -> ChatConversation {
        throw unavailableError()
    }

    func sendMessage(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessage {
        let outcome = try await sendMessageResult(draft, progress: progress)
        guard let message = outcome.confirmedMessage else { throw unavailableError() }
        return message
    }

    func sendMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome {
        let message = ChatMessage(
            id: "text-\(draft.clientRequestID.uuidString)",
            clientRequestID: draft.clientRequestID,
            conversationID: draft.conversationID,
            senderID: "me",
            isFromCurrentUser: true,
            sentAt: Date(),
            text: draft.text
        )
        return try outcome(for: draft, status: .confirmedSuccess, message: message)
    }

    func sendAttachmentMessageResult(
        _ draft: ChatMessageDraft,
        progress: @escaping FileTransferProgress
    ) async throws -> ChatMessageSendOutcome {
        attachmentDraftValues.append(draft)
        attachmentBlockedWaiters.forEach { $0.resume() }
        attachmentBlockedWaiters.removeAll()
        if blocksAttachmentSend {
            await withCheckedContinuation { attachmentContinuation = $0 }
        }
        progress(1, 1)
        let message = attachmentStatus == .confirmedSuccess
            ? ChatMessage(
                id: "attachment-\(draft.clientRequestID.uuidString)",
                clientRequestID: draft.clientRequestID,
                conversationID: draft.conversationID,
                senderID: "me",
                isFromCurrentUser: true,
                sentAt: Date(),
                text: draft.text,
                attachments: [
                    ChatAttachment(
                        id: "attachment",
                        kind: .image,
                        fileName: draft.localAttachmentURLs[0].lastPathComponent
                    )
                ]
            )
            : nil
        return try outcome(for: draft, status: attachmentStatus, message: message)
    }

    func deleteMessage(conversationID: String, messageID: String, clientRequestID: UUID) async throws {
        throw unavailableError()
    }

    func closeConversation(conversationID: String, clientRequestID: UUID) async throws {
        throw unavailableError()
    }

    func listConversationMembers(conversationID: String) async throws -> [ChatUser] {
        throw unavailableError()
    }

    func listPinnedMessages(conversationID: String) async throws -> [ChatMessage] {
        throw unavailableError()
    }

    func setMessagePinned(
        conversationID: String,
        messageID: String,
        isPinned: Bool,
        clientRequestID: UUID
    ) async throws {
        throw unavailableError()
    }

    func forwardMessage(
        messageID: String,
        toConversationIDs: [String],
        clientRequestID: UUID
    ) async throws {
        throw unavailableError()
    }

    func setReminder(
        messageID: String,
        remindAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatReminder {
        throw unavailableError()
    }

    func listReminders(conversationID: String) async throws -> [ChatReminder] {
        throw unavailableError()
    }

    func deleteReminder(
        messageID: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        throw unavailableError()
    }

    func loadAttachmentThumbnail(
        messageID: String,
        size: ChatAttachmentThumbnailSize
    ) async throws -> Data {
        Data()
    }

    func downloadAttachment(
        messageID: String,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws {
        throw unavailableError()
    }

    func listScheduledMessages(conversationID: String) async throws -> [ChatScheduledMessage] {
        throw unavailableError()
    }

    func createScheduledMessage(
        conversationID: String,
        text: String,
        sendAt: Date,
        clientRequestID: UUID
    ) async throws -> ChatScheduledMessage {
        throw unavailableError()
    }

    func deleteScheduledMessage(
        id: String,
        conversationID: String,
        clientRequestID: UUID
    ) async throws {
        throw unavailableError()
    }

    func createPoll(_ draft: ChatPollDraft) async throws -> ChatMessage {
        throw unavailableError()
    }

    func attachmentDrafts() -> [ChatMessageDraft] { attachmentDraftValues }

    func waitUntilAttachmentSendBlocked() async {
        guard attachmentContinuation == nil else { return }
        await withCheckedContinuation { attachmentBlockedWaiters.append($0) }
    }

    func releaseAttachmentSend() {
        attachmentContinuation?.resume()
        attachmentContinuation = nil
    }

    private func outcome(
        for draft: ChatMessageDraft,
        status: MutationResultStatus,
        message: ChatMessage?
    ) throws -> ChatMessageSendOutcome {
        let submitted = status != .cancelledBeforeSubmission
        let unknown = status == .submittedButUnverified ||
            status == .cancellationRequestedAfterSubmission
        let succeeded = status == .confirmedSuccess
        return try ChatMessageSendOutcome(
            result: MutationResult(
                status: status,
                operation: "chatAttachmentSend",
                submitted: submitted,
                requiresRefresh: unknown,
                counts: MutationResultCounts(
                    succeeded: succeeded ? 1 : 0,
                    failed: succeeded || unknown ? 0 : 1,
                    unknown: unknown ? 1 : 0
                ),
                errorCategory: unknown ? .unknown : nil,
                diagnosticTag: "test.chat.attachment"
            ),
            conversationID: draft.conversationID,
            clientRequestID: draft.clientRequestID,
            confirmedMessage: message
        )
    }

    private func unavailableError() -> AppError {
        AppError(category: .apiUnavailable, isRetryable: false, safeUserMessage: "")
    }
}
