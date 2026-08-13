@testable import DsmMobile
import Foundation
import XCTest

final class MobileChatPresentationTests: XCTestCase {
    func test聊天页按SizeClass提供iPhone层级和iPad双栏() throws {
        let source = try chatViewSources()

        XCTAssertTrue(source.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(source.contains("if horizontalSizeClass == .regular"))
        XCTAssertTrue(source.contains("private var compactLayout"))
        XCTAssertTrue(source.contains("private var regularLayout"))
        XCTAssertTrue(source.contains("HStack(spacing: 0)"))
        XCTAssertTrue(source.contains("regularMessageDetail"))
        XCTAssertTrue(source.contains(".navigationDestination(for: ChatConversation.self)"))
        XCTAssertFalse(source.contains("UIDevice.current"))
    }

    func test会话和消息均覆盖五态筛选刷新和更早分页() throws {
        let source = try chatViewSources()

        XCTAssertTrue(source.contains("MobilePageStateView("))
        XCTAssertTrue(source.contains("state.conversationPageState"))
        XCTAssertTrue(source.contains("state.messagePageState"))
        XCTAssertTrue(source.contains(".searchable("))
        XCTAssertTrue(source.contains(".refreshable"))
        XCTAssertTrue(source.contains("chat.loadMoreMessages()"))
        XCTAssertTrue(source.contains("state.loadMoreMessagesFailed"))
        XCTAssertTrue(source.contains("state.selectedMessages.hasMoreBefore"))
        XCTAssertTrue(source.contains("chat.enterConversation(conversation.id)"))
        XCTAssertTrue(source.contains("chat.leaveConversation(conversation.id)"))
        XCTAssertTrue(source.contains("case .unavailable"))
        XCTAssertTrue(source.contains("case .requiresValidation"))
    }

    func test加密会话和附件仍关闭且不开放桌面动作() throws {
        let source = try chatViewSources()

        XCTAssertTrue(source.contains("conversation.isEncrypted"))
        XCTAssertTrue(source.contains("mobile.chat.encrypted.message"))
        XCTAssertTrue(source.contains("mobile.chat.attachment.read-only"))
        XCTAssertTrue(source.contains("mobile.chat.conversation.accessibility.encrypted"))
        for forbidden in [
            "TextEditor(",
            "downloadAttachment(", "startRealtime(", "onHover", "doubleClick"
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func test首次单聊和私人群聊使用原生表单并按尺寸类打开新会话() throws {
        let source = try chatViewSources()
        let model = try sourceFile("Sources/Features/Chat/MobileChatModel.swift")
        let creator = try sourceFile(
            "Sources/Features/Chat/MobileChatConversationCreator.swift"
        )
        let repository = try sourceFile(
            "Sources/Features/Chat/MobileReadOnlyChatRepository.swift"
        )

        XCTAssertTrue(source.contains("MobileChatConversationCreatorSheet"))
        XCTAssertTrue(source.contains("square.and.pencil"))
        XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(source.contains("TextField("))
        XCTAssertTrue(source.contains("ForEach(filteredUsers)"))
        XCTAssertTrue(source.contains("mobile.chat.create.filtered-empty.title"))
        XCTAssertTrue(source.contains("mobile.chat.create.clear-search"))
        XCTAssertTrue(source.contains("selectedUserIDs.count >= 2"))
        XCTAssertTrue(source.contains("creator.requiresReview"))
        XCTAssertTrue(source.contains("mobile.chat.create.review.action"))
        XCTAssertTrue(source.contains(".interactiveDismissDisabled(creator.isSubmitting)"))
        XCTAssertTrue(source.contains(".navigationDestination(item: $createdCompactConversation)"))
        XCTAssertTrue(source.contains("horizontalSizeClass != .regular"))
        XCTAssertTrue(model.contains("sourceProfileID: UUID"))
        XCTAssertTrue(source.contains("sourceProfileID: sourceProfileID"))
        XCTAssertTrue(creator.contains("openDirectConversationResult"))
        XCTAssertTrue(creator.contains("createGroupResult"))
        XCTAssertTrue(creator.contains("pendingDraft"))
        XCTAssertTrue(repository.contains(".directConversation"))
        XCTAssertTrue(repository.contains(".groupConversation"))
        XCTAssertFalse(source.contains(".font(.system(size:"))
        XCTAssertFalse(source.contains("withAnimation"))
    }

    func test文字发送Composer使用原生输入反馈和无障碍标签() throws {
        let source = try chatViewSources()
        let model = try sourceFile("Sources/Features/Chat/MobileChatModel.swift")

        XCTAssertTrue(source.contains("MobileChatAttachmentComposer"))
        XCTAssertTrue(source.contains("TextField("))
        XCTAssertTrue(source.contains("mobile.chat.composer.label"))
        XCTAssertTrue(source.contains("mobile.chat.action.send"))
        XCTAssertTrue(source.contains("mobile.chat.send.failed"))
        XCTAssertTrue(source.contains("mobile.chat.send.review"))
        XCTAssertTrue(source.contains(".submitLabel(.send)"))
        XCTAssertTrue(source.contains(".frame(minWidth: 44, minHeight: 44)"))
        XCTAssertTrue(source.contains(".accessibilityHint(L10n.string(\"mobile.chat.send.hint\"))"))
        XCTAssertTrue(model.contains("sendSelectedMessage()"))
        XCTAssertTrue(model.contains("sendReviewBlockedTextsByConversation"))
    }

    func test触控动态文字VoiceOver和降低动态效果沿用系统组件() throws {
        let source = try chatViewSources()

        XCTAssertTrue(source.contains("frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains("minHeight: 44"))
        XCTAssertTrue(source.contains(".accessibilityLabel("))
        XCTAssertTrue(source.contains(".accessibilityAddTraits("))
        XCTAssertTrue(source.contains("List("))
        XCTAssertTrue(source.contains("NavigationLink(value:"))
        XCTAssertFalse(source.contains(".font(.system(size:"))
        XCTAssertFalse(source.contains("withAnimation"))
    }

    func test本地会话置顶覆盖列表详情和可访问性入口() throws {
        let source = try chatViewSources()
        let model = try sourceFile("Sources/Features/Chat/MobileChatModel.swift")
        let state = try sourceFile("Sources/Features/Chat/MobileChatState.swift")
        let store = try sourceFile("Sources/Features/Chat/MobileChatConversationPinStore.swift")
        let session = try sourceFile("Sources/Session/MobileAppModel+Session.swift")

        XCTAssertTrue(source.contains(".swipeActions(edge: .trailing, allowsFullSwipe: false)"))
        XCTAssertTrue(source.contains("conversationPinButton(conversation, isPinned:"))
        XCTAssertTrue(source.contains("ToolbarItemGroup(placement: .topBarTrailing)"))
        XCTAssertTrue(source.contains("chat.toggleConversationPinned(conversation)"))
        XCTAssertTrue(source.contains("pin.fill"))
        XCTAssertTrue(source.contains("mobile.chat.pin.action.pin"))
        XCTAssertTrue(source.contains("mobile.chat.pin.action.unpin"))
        XCTAssertTrue(source.contains("mobile.chat.pin.hint"))
        XCTAssertTrue(source.contains("mobile.chat.conversation.accessibility.pinned"))
        XCTAssertTrue(model.contains("conversationPinStore"))
        XCTAssertTrue(model.contains("toggleConversationPinned(_ conversation: ChatConversation)"))
        XCTAssertTrue(model.contains("removePersistentPins(profileID: UUID)"))
        XCTAssertTrue(model.contains("normalizedPinnedConversationIDs"))
        XCTAssertTrue(state.contains("pinnedConversationIDs"))
        XCTAssertTrue(state.contains("isConversationPinned(_ conversationID: String)"))
        XCTAssertTrue(store.contains("StoredPinnedConversations"))
        XCTAssertTrue(store.contains("version: 1"))
        XCTAssertTrue(session.contains("chatModel.removePersistentPins(profileID: profile.id)"))
        XCTAssertFalse(model.contains("setMessagePinned"))
    }

    func test群成员仅按能力显示并使用原生Sheet五态和无障碍入口() throws {
        let source = try chatViewSources()
        let model = try sourceFile("Sources/Features/Chat/MobileChatModel.swift")
        let state = try sourceFile("Sources/Features/Chat/MobileChatState.swift")
        let repository = try sourceFile("Sources/Features/Chat/MobileReadOnlyChatRepository.swift")

        XCTAssertTrue(source.contains("if chat.canViewMembers(for: conversation)"))
        XCTAssertTrue(source.contains(".sheet(isPresented: $presentsMembers)"))
        XCTAssertTrue(source.contains("private struct MobileChatMembersSheet: View"))
        XCTAssertTrue(source.contains("List {"))
        XCTAssertTrue(source.contains("chat.state.memberPageState"))
        XCTAssertTrue(source.contains("chat.loadConversationMembers(forceRefresh: true)"))
        XCTAssertTrue(source.contains("chat.cancelConversationMemberLoad()"))
        XCTAssertTrue(source.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, minHeight: 44"))
        for key in [
            "mobile.chat.members.action",
            "mobile.chat.members.hint",
            "mobile.chat.members.title",
            "mobile.chat.members.close",
            "mobile.chat.members.refresh",
            "mobile.chat.members.loading",
            "mobile.chat.members.empty.title",
            "mobile.chat.members.empty.message",
            "mobile.chat.members.error.title",
            "mobile.chat.members.error.message",
            "mobile.chat.members.current-user",
            "mobile.chat.members.disabled",
            "mobile.chat.members.count"
        ] {
            XCTAssertTrue(source.contains(key), key)
        }
        XCTAssertTrue(model.contains("conversation.kind == .group"))
        XCTAssertTrue(model.contains("supportedFeatures.contains(.groupMembers)"))
        XCTAssertTrue(model.contains("memberGeneration"))
        XCTAssertTrue(state.contains("membersByConversation"))
        XCTAssertTrue(repository.contains(".groupMembers"))
        XCTAssertFalse(source.contains("mobile.chat.members.filtered"))
    }

    func test群公告仅按能力显示并使用原生Sheet五态和隐私白名单() throws {
        let source = try chatViewSources()
        let model = try sourceFile("Sources/Features/Chat/MobileChatModel.swift")
        let state = try sourceFile("Sources/Features/Chat/MobileChatState.swift")
        let repository = try sourceFile("Sources/Features/Chat/MobileReadOnlyChatRepository.swift")

        XCTAssertTrue(source.contains("if chat.canViewAnnouncements(for: conversation)"))
        XCTAssertTrue(source.contains(".sheet(isPresented: $presentsAnnouncements)"))
        XCTAssertTrue(source.contains("private struct MobileChatAnnouncementsSheet: View"))
        XCTAssertTrue(source.contains("chat.state.announcementPageState"))
        XCTAssertTrue(source.contains("chat.loadConversationAnnouncements(forceRefresh: true)"))
        XCTAssertTrue(source.contains("chat.cancelConversationAnnouncementLoad()"))
        XCTAssertTrue(source.contains("Image(systemName: \"megaphone\")"))
        XCTAssertTrue(source.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains(".frame(maxWidth: .infinity, minHeight: 44"))
        for key in [
            "mobile.chat.announcements.action",
            "mobile.chat.announcements.hint",
            "mobile.chat.announcements.title",
            "mobile.chat.announcements.close",
            "mobile.chat.announcements.refresh",
            "mobile.chat.announcements.loading",
            "mobile.chat.announcements.empty.title",
            "mobile.chat.announcements.empty.message",
            "mobile.chat.announcements.error.title",
            "mobile.chat.announcements.error.message",
            "mobile.chat.announcements.count",
            "mobile.chat.announcements.no-text",
            "mobile.chat.announcements.pinned-at"
        ] {
            XCTAssertTrue(source.contains(key), key)
        }
        XCTAssertTrue(model.contains("conversation.kind == .group"))
        XCTAssertTrue(model.contains("supportedFeatures.contains(.pinnedMessages)"))
        XCTAssertTrue(model.contains("announcementGeneration"))
        XCTAssertTrue(state.contains("announcementsByConversation"))
        XCTAssertTrue(repository.contains(".pinnedMessages"))
        XCTAssertTrue(repository.contains("attachments: []"))
        XCTAssertFalse(model.contains("setMessagePinned"))
    }

    func test本人消息删除使用原生行菜单二次确认和防重放状态() throws {
        let source = try chatViewSources()
        let model = try sourceFile("Sources/Features/Chat/MobileChatModel.swift")
        let state = try sourceFile("Sources/Features/Chat/MobileChatState.swift")
        let repository = try sourceFile("Sources/Features/Chat/MobileReadOnlyChatRepository.swift")

        XCTAssertTrue(source.contains("private struct MobileChatMessageRow: View"))
        XCTAssertTrue(source.contains(".swipeActions(edge: .trailing, allowsFullSwipe: false)"))
        XCTAssertTrue(source.contains(".contextMenu"))
        XCTAssertTrue(source.contains("MobileChatDeleteAccessibilityAction(isEnabled: chat.canDeleteMessage(message))"))
        XCTAssertTrue(source.contains(".confirmationDialog("))
        XCTAssertTrue(source.contains("Button(L10n.string(\"mobile.chat.message.action.delete\"), role: .destructive)"))
        XCTAssertTrue(source.contains("chat.canDeleteMessage(message)"))
        XCTAssertTrue(source.contains("await chat.deleteMessage(message)"))
        XCTAssertTrue(source.contains("chat.state.deletingMessageID == message.id"))
        XCTAssertTrue(source.contains("chat.state.deleteMessageErrorID == message.id"))
        for key in [
            "mobile.chat.message.action.delete",
            "mobile.chat.message.delete.confirm.title",
            "mobile.chat.message.delete.confirm.message",
            "mobile.chat.message.delete.confirm.cancel",
            "mobile.chat.message.delete.progress",
            "mobile.chat.message.delete.failed"
        ] {
            XCTAssertTrue(source.contains(key), key)
        }
        XCTAssertTrue(model.contains("canDeleteMessage(_ message: ChatMessage)"))
        XCTAssertTrue(model.contains("message.isFromCurrentUser == true"))
        XCTAssertTrue(model.contains("supportedFeatures.contains(.deleteOwnMessage)"))
        XCTAssertTrue(model.contains("deleteReviewBlockedMessageIDsByConversation"))
        XCTAssertTrue(model.contains("messageDeleteGeneration"))
        XCTAssertTrue(state.contains("deletingMessageID"))
        XCTAssertTrue(state.contains("deleteMessageErrorCategory"))
        XCTAssertTrue(repository.contains(".deleteOwnMessage"))
        XCTAssertFalse(source.contains("forwardMessage("))
        XCTAssertFalse(source.contains("closeConversation("))
        XCTAssertFalse(model.contains("setMessagePinned"))
    }

    func testAppModel持有单一聊天模型且生命周期接入配置档和工作区() throws {
        let appModel = try sourceFile("Sources/AppShell/MobileAppModel.swift")
        let workspace = try sourceFile("Sources/AppShell/MobileAppModel+Workspace.swift")
        let workspaceView = try sourceFile("Sources/AppShell/MobileWorkspaceView.swift")
        let session = try sourceFile("Sources/Session/MobileAppModel+Session.swift")

        XCTAssertEqual(appModel.components(separatedBy: "let chatModel = MobileChatModel()").count - 1, 1)
        XCTAssertTrue(workspace.contains("chatModel.activate(profileID: profileID, repository: chatRepository)"))
        XCTAssertTrue(workspace.contains("if selectedModule == .chat, module != .chat"))
        XCTAssertTrue(workspace.contains("chatModel.deactivate()"))
        XCTAssertTrue(session.contains("func clearWorkspace()"))
        XCTAssertTrue(session.contains("chatModel.deactivate()"))
        XCTAssertTrue(appModel.contains("activeProfile?.id != oldValue?.id"))
        XCTAssertTrue(workspaceView.contains("if module != .chat"))
        XCTAssertTrue(session.contains("chatModel.purge(profileID: profile.id)"))
        XCTAssertTrue(session.contains("chatModel.purge(profileID: profileID)"))
        XCTAssertTrue(session.contains("chatModel.removePersistentPins(profileID: profile.id)"))
    }

    func testChat前台实时刷新由Scene和当前模块共同控制() throws {
        let app = try sourceFile("Sources/DsmMobileApp.swift")
        let model = try sourceFile("Sources/Features/Chat/MobileChatModel.swift")
        let repository = try sourceFile("Sources/Features/Chat/MobileReadOnlyChatRepository.swift")

        XCTAssertTrue(app.contains("@Environment(\\.scenePhase)"))
        XCTAssertTrue(app.contains("model.selectedModule == .chat"))
        XCTAssertTrue(app.contains("setForegroundRealtimeActive"))
        XCTAssertTrue(model.contains("case .contentChanged:"))
        XCTAssertTrue(model.contains("await self?.reloadConversations()"))
        XCTAssertTrue(model.contains("await self?.refreshMessages()"))
        XCTAssertFalse(model.contains("loadConversationMembers(forceRefresh: true)"))
        XCTAssertFalse(model.contains("loadConversationAnnouncements(forceRefresh: true)"))
        XCTAssertTrue(repository.contains("await base.realtimeEvents()"))
        XCTAssertTrue(repository.contains("await base.startRealtime()"))
        XCTAssertTrue(repository.contains("await base.stopRealtime()"))
    }

    func testRegular详情不会对已选择会话发起第二次选择且详情工具栏包含置顶和刷新() throws {
        let source = try sourceFile("Sources/Features/Chat/MobileChatView.swift")

        XCTAssertTrue(source.contains("if chat.state.selectedConversationID != conversation.id"))
        XCTAssertTrue(source.contains("if chat.state.selectedConversationID != conversation.id {\n                ProgressView"))
        XCTAssertEqual(source.components(separatedBy: "ToolbarItemGroup(placement: .topBarTrailing)").count - 1, 1)
        XCTAssertTrue(source.contains("chat.toggleConversationPinned(conversation)"))
        XCTAssertTrue(source.contains("chat.refreshMessages()"))
    }

    func test可见文案全部来自英简中资源() throws {
        let source = try chatViewSources()
        let english = try sourceFile("../../Packages/DsmLocalization/Sources/Resources/en.lproj/Localizable.strings")
        let chinese = try sourceFile("../../Packages/DsmLocalization/Sources/Resources/zh-Hans.lproj/Localizable.strings")
        let expression = try NSRegularExpression(pattern: #"L10n\.string\(\"([^\"]+)\""#)
        let range = NSRange(source.startIndex..., in: source)
        let keys = expression.matches(in: source, range: range).compactMap { match -> String? in
            guard let keyRange = Range(match.range(at: 1), in: source) else { return nil }
            return String(source[keyRange])
        }

        XCTAssertFalse(keys.isEmpty)
        for key in Set(keys) {
            XCTAssertTrue(english.contains("\"\(key)\" ="), "English: \(key)")
            XCTAssertTrue(chinese.contains("\"\(key)\" ="), "简体中文: \(key)")
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func chatViewSources() throws -> String {
        try [
            sourceFile("Sources/Features/Chat/MobileChatView.swift"),
            sourceFile("Sources/Features/Chat/MobileChatAttachmentView.swift")
        ].joined(separator: "\n")
    }
}
