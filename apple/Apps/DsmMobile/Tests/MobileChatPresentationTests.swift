@testable import DsmMobile
import Foundation
import XCTest

final class MobileChatPresentationTests: XCTestCase {
    func test聊天页按SizeClass提供iPhone层级和iPad双栏() throws {
        let source = try sourceFile("Sources/Features/Chat/MobileChatView.swift")

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
        let source = try sourceFile("Sources/Features/Chat/MobileChatView.swift")

        XCTAssertTrue(source.contains("MobilePageStateView("))
        XCTAssertTrue(source.contains("state.conversationPageState"))
        XCTAssertTrue(source.contains("state.messagePageState"))
        XCTAssertTrue(source.contains(".searchable("))
        XCTAssertTrue(source.contains(".refreshable"))
        XCTAssertTrue(source.contains("chat.loadMoreMessages()"))
        XCTAssertTrue(source.contains("state.loadMoreMessagesFailed"))
        XCTAssertTrue(source.contains("state.selectedMessages.hasMoreBefore"))
        XCTAssertTrue(source.contains("case .unavailable"))
        XCTAssertTrue(source.contains("case .requiresValidation"))
    }

    func test加密会话和附件只有说明没有桌面或写入动作() throws {
        let source = try sourceFile("Sources/Features/Chat/MobileChatView.swift")

        XCTAssertTrue(source.contains("conversation.isEncrypted"))
        XCTAssertTrue(source.contains("mobile.chat.encrypted.message"))
        XCTAssertTrue(source.contains("mobile.chat.attachment.read-only"))
        XCTAssertTrue(source.contains("mobile.chat.read-only.notice"))
        XCTAssertTrue(source.contains("mobile.chat.conversation.accessibility.encrypted"))
        for forbidden in [
            "TextEditor(", "sendMessage(", "openDirectConversation(", "createGroup(",
            "downloadAttachment(", "startRealtime(", "contextMenu", "onHover", "doubleClick"
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func test触控动态文字VoiceOver和降低动态效果沿用系统组件() throws {
        let source = try sourceFile("Sources/Features/Chat/MobileChatView.swift")

        XCTAssertTrue(source.contains("frame(width: 44, height: 44)"))
        XCTAssertTrue(source.contains("minHeight: 44"))
        XCTAssertTrue(source.contains(".accessibilityLabel("))
        XCTAssertTrue(source.contains(".accessibilityAddTraits("))
        XCTAssertTrue(source.contains("List("))
        XCTAssertTrue(source.contains("NavigationLink(value:"))
        XCTAssertFalse(source.contains(".font(.system(size:"))
        XCTAssertFalse(source.contains("withAnimation"))
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
    }

    func testRegular详情不会对已选择会话发起第二次选择且详情只有消息刷新() throws {
        let source = try sourceFile("Sources/Features/Chat/MobileChatView.swift")

        XCTAssertTrue(source.contains("if chat.state.selectedConversationID != conversation.id"))
        XCTAssertTrue(source.contains("if chat.state.selectedConversationID != conversation.id {\n                ProgressView"))
        XCTAssertEqual(source.components(separatedBy: "ToolbarItem(placement: .topBarTrailing)").count - 1, 1)
        XCTAssertTrue(source.contains("chat.refreshMessages()"))
    }

    func test可见文案全部来自英简中资源() throws {
        let source = try sourceFile("Sources/Features/Chat/MobileChatView.swift")
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
}
