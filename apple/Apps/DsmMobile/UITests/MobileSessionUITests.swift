import XCTest

/// 只操作空白连接表单与语言菜单，不登录或访问任何 NAS。
@MainActor
final class MobileSessionUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() async throws {
        await MainActor.run {
            continueAfterFailure = false
            app = XCUIApplication()
            app.launch()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            app.terminate()
            app = nil
        }
    }

    func test空地址有恢复提示且语言切换不保留旧语言错误() {
        chooseLanguage("简体中文")
        let connect = element("mobile.login.connect")
        XCTAssertTrue(connect.waitForExistence(timeout: 5))
        connect.tap()
        let error = element("mobile.login.error")
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("请输入 NAS 地址"))
        chooseLanguage("English")
        XCTAssertFalse(error.exists)
        connect.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("Please enter the NAS address"))
        attachScreenshot("Login error — English")
    }

    func test英文选择在重启后保留且字段可访问() {
        chooseLanguage("English")
        app.terminate()
        app.launch()
        XCTAssertTrue(element("mobile.login.username").waitForExistence(timeout: 5))
        XCTAssertEqual(element("mobile.login.username").placeholderValue, "Username")
        XCTAssertTrue(element("mobile.login.host").isHittable)
        XCTAssertTrue(element("mobile.login.password").isHittable)
        XCTAssertEqual(element("mobile.login.connect").label, "Connect")
        attachScreenshot("Login — English")
    }

    private func chooseLanguage(_ title: String) {
        let menu = element("mobile.login.language")
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let choice = app.buttons[title]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
