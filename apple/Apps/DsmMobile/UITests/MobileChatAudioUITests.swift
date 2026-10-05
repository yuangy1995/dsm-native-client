import XCTest
import UIKit

@MainActor
final class MobileChatAudioUITests: XCTestCase {
    func test语音消息一次点击播放暂停并在旋转后保留会话() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(); openChat(app)
        let play = element("chat-voice-play-9400", app)
        XCTAssertTrue(play.waitForExistence(timeout: 8)); play.tap()
        XCTAssertTrue(play.waitForLabel(containing: "Pause")); play.tap()
        XCTAssertTrue(play.waitForLabel(containing: "Play"))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(element("chat-two-columns", app).waitForExistence(timeout: 8))
            XCTAssertTrue(app.staticTexts["Another chat"].firstMatch.isHittable)
        }
        play.tap(); XCTAssertTrue(play.waitForLabel(containing: "Pause")); play.tap()
        let field = element("chat-compose-text", app)
        XCTAssertFalse(element("chat-search-all", app).exists)
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertTrue(element("chat-two-columns", app).exists)
            XCTAssertTrue(app.staticTexts["Another chat"].firstMatch.isHittable)
        }
        XCTAssertGreaterThan(field.frame.width, 120)
        screenshot(app, "Chat landscape keeps the current conversation")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(play.waitForExistence(timeout: 8))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCTAssertFalse(element("chat-two-columns", app).waitForExistence(timeout: 2))
        }
        play.tap(); XCTAssertTrue(play.waitForLabel(containing: "Pause")); play.tap()
        XCTAssertFalse(element("chat-search-all", app).exists)
        XCTAssertGreaterThan(field.frame.width, 120)
        screenshot(app, "Chat portrait uses available width")
    }

    func test合成录音停止试听暂停发送后显示语音附件() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = launch(); openChat(app)
        element("chat-compose-voice", app).tap()
        let start = element("chat-voice-start", app)
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        let stop = element("chat-voice-stop", app)
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = .landscapeLeft
            XCTAssertTrue(stop.waitForExistence(timeout: 8))
        }
        stop.tap()
        let preview = element("chat-voice-preview", app)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(preview.waitForExistence(timeout: 8)); preview.tap()
        XCTAssertTrue(preview.waitForLabel(containing: "Pause")); preview.tap()
        XCTAssertTrue(preview.waitForLabel(containing: "Listen"))
        screenshot(app, "Synthetic voice recording ready to send")
        let send = element("chat-voice-send", app)
        XCTAssertTrue(send.isEnabled); send.tap()
        XCTAssertTrue(app.staticTexts["voice.aac"].firstMatch.waitForExistence(timeout: 8))
        let received = element("chat-voice-play-9401", app)
        XCTAssertTrue(received.exists); received.tap()
        XCTAssertTrue(received.waitForLabel(containing: "Pause")); received.tap()
        screenshot(app, "Voice message sent through the attachment workflow")
    }

    func test麦克风拒绝中文深色大字给出设置入口且不发送() {
        let app = launch(state: "chat-audio-permission-denied", chinese: true); openChat(app, chinese: true)
        element("chat-compose-voice", app).tap()
        let start = element("chat-voice-start", app)
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        XCTAssertTrue(app.staticTexts["麦克风访问未开启。请打开设置，允许岚仓访问麦克风后重新录制。"].waitForExistence(timeout: 5))
        let settings = app.buttons["打开设置"]
        for _ in 0..<3 { if settings.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(settings.isHittable)
        XCTAssertFalse(element("chat-voice-send", app).isEnabled)
        screenshot(app, "Chinese dark large-text microphone recovery")
    }

    func test播放损坏音频显示恢复提示并允许重新加载() {
        let app = launch(state: "chat-audio-invalid"); openChat(app)
        let play = element("chat-voice-play-9400", app)
        play.tap()
        XCTAssertTrue(app.staticTexts["Could not play this file"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Playback supports files up to 512 MB. Check your connection and try again, or save the file and open it in another player."].waitForExistence(timeout: 5))
        XCTAssertTrue(play.isEnabled)
        screenshot(app, "Invalid voice media keeps retry and save actions")
    }

    func test语音发送断网保留记录并关闭原录音发送入口() {
        let app = launch(state: "chat-audio-send-unknown"); openChat(app)
        element("chat-compose-voice", app).tap()
        let start = element("chat-voice-start", app)
        XCTAssertTrue(start.waitForExistence(timeout: 5)); start.tap()
        let stop = element("chat-voice-stop", app)
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        let send = element("chat-voice-send", app), compose = element("chat-compose-voice", app)
        send.tap()
        // iPad 弹窗后方的录音入口仍存在；等待原面板关闭且底层入口恢复可点击。
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !send.exists && compose.exists && compose.isHittable
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 8), .completed)
        XCTAssertFalse(send.exists)
        element("chat-more", app).tap(); element("chat-send-records", app).tap()
        XCTAssertTrue(app.navigationBars["Sent messages"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "chat-send-record-")).count, 1)
        screenshot(app, "Uncertain voice send has one recovery record")
    }

    private func launch(state: String = "chat-audio-content", chinese: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["--ui-fixture", "-lanstash.app-language.v1", chinese ? "zh-Hans" : "en"]
        if chinese { app.launchArguments += ["-lanstash.mobile.settings.appearance.v1", "dark",
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["LANSTASH_UI_STATE"] = state; app.launch(); return app
    }
    private func openChat(_ app: XCUIApplication, chinese: Bool = false) {
        XCTAssertTrue(app.staticTexts["Sample folder"].waitForExistence(timeout: 8))
        navigate("settings", chinese ? "App 设置" : "App settings", app)
        let toggle = element("mobile.settings.module.chat", app)
        for _ in 0..<5 { if toggle.exists && toggle.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.switches.firstMatch.tap()
        navigate("chat", chinese ? "聊天" : "Chat", app)
        let conversation = app.staticTexts["Sample chat"].firstMatch
        XCTAssertTrue(conversation.waitForExistence(timeout: 8)); conversation.tap()
        XCTAssertTrue(element("chat-voice-play-9400", app).waitForExistence(timeout: 8))
    }
    private func navigate(_ id: String, _ title: String, _ app: XCUIApplication) {
        MobileUITestNavigation.open(app, destination: id, title: title, test: self)
    }
    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func screenshot(_ app: XCUIApplication, _ name: String) {
        // 捕获整个设备显示，避免旋转后的应用窗口边界使横屏附件被裁切。
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

@MainActor
private extension XCUIElement {
    func waitForLabel(containing text: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text), object: self)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
