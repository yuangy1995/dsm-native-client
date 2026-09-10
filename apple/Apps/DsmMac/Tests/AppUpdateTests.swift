import AppKit
import DsmCore
@testable import DsmMacExecutable
import Sparkle
import XCTest

@MainActor
final class AppUpdateTests: XCTestCase {
    func test手动更新说明只选正式macOS发布且保留详情() throws {
        let data = Data(###"[{"tag_name":"android-9","body":"Android only","draft":false,"prerelease":false,"assets":[{"name":"app.apk"}]},{"tag_name":"macos-preview","body":"Preview","draft":false,"prerelease":true,"assets":[{"name":"Preview.dmg"}]},{"tag_name":"macos-1.0.3","body":"## Changes\n- Updated Photos","draft":false,"prerelease":false,"assets":[{"name":"LanStash.dmg"}]}]"###.utf8)
        let notes = try XCTUnwrap(AppUpdateUserDriver.macReleaseNotes(from: data))
        XCTAssertEqual(notes.version, "macos-1.0.3")
        XCTAssertTrue(notes.body.contains("Updated Photos"))
        XCTAssertTrue(AppUpdateUserDriver.PresentationStage.information.showsReleaseNotes)
    }
    func test更新窗口保留标题栏系统按钮且系统关闭只取消一次() {
        _ = NSApplication.shared
        let driver = AppUpdateUserDriver(presentsWindows: false)
        var cancellations = 0
        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        let window = AppUpdateWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                                     styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.delegate = driver
        defer { window.close() }
        XCTAssertTrue(window.isMovable)
        XCTAssertNotNil(window.standardWindowButton(.closeButton))
        XCTAssertNotNil(window.standardWindowButton(.miniaturizeButton))
        XCTAssertGreaterThan(window.frame.height, 200)
        window.performClose(nil)
        window.performClose(nil)
        XCTAssertEqual(cancellations, 1)

        driver.showDownloadDidStartExtractingUpdate()
        window.performClose(nil)
        XCTAssertEqual(driver.stage, .preparing)
        XCTAssertTrue(driver.isWorking)
        XCTAssertEqual(cancellations, 1)
    }

    func test更新说明只显示文本且新检查清除旧版本资料() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        driver.showAvailable(version: "0.3.0", notes: "<p>修复 &amp; 优化</p><p>第二项</p>") { _ in
            XCTFail("呈现更新说明不能触发安装")
        }
        XCTAssertEqual(driver.version, "0.3.0")
        XCTAssertEqual(driver.releaseNotes, "修复 & 优化\n第二项")
        driver.showDownloadInitiated {}
        XCTAssertEqual(driver.version, "0.3.0")
        driver.showUserInitiatedUpdateCheck {}
        XCTAssertNil(driver.version)
        XCTAssertNil(driver.releaseNotes)
    }

    func test确认下载后重复点击不清除新阶段取消操作() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        var choices: [SPUUserUpdateChoice] = []
        var cancellations = 0
        driver.showAvailable(version: "0.3.0", notes: nil) { choice in
            choices.append(choice)
            driver.showDownloadInitiated { cancellations += 1 }
        }
        XCTAssertNil(driver.releaseNotes)
        driver.performPrimaryAction()
        driver.performPrimaryAction()
        XCTAssertEqual(choices, [.install])
        XCTAssertEqual(driver.stage, .downloading)
        driver.performSecondaryAction()
        XCTAssertEqual(cancellations, 1)
    }

    func test检查关闭只取消一次并清理进度() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        var cancellations = 0
        driver.showUserInitiatedUpdateCheck { cancellations += 1 }
        XCTAssertEqual(driver.stage, .checking)
        XCTAssertTrue(driver.canDismiss)
        driver.dismissByUser()
        driver.dismissByUser()
        XCTAssertEqual(cancellations, 1)
        XCTAssertFalse(driver.isWorking)
        XCTAssertFalse(driver.canDismiss)
    }

    func test无主操作时的重复点击不能清除下载取消入口() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        var cancellations = 0
        driver.showDownloadInitiated { cancellations += 1 }
        driver.performPrimaryAction()
        XCTAssertEqual(driver.stage, .downloading)
        XCTAssertEqual(driver.secondaryKey, "updates.cancel")
        driver.dismissByUser()
        XCTAssertEqual(cancellations, 1)
    }

    func test准备和安装阶段不允许关闭但完成后可确认() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        driver.showDownloadDidStartExtractingUpdate()
        XCTAssertEqual(driver.stage, .preparing)
        XCTAssertFalse(driver.canDismiss)
        driver.dismissByUser()
        XCTAssertTrue(driver.isWorking)
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady { choices.append($0) }
        XCTAssertEqual(driver.stage, .ready)
        XCTAssertTrue(driver.canDismiss)
        driver.performPrimaryAction()
        XCTAssertEqual(driver.stage, .installing)
        XCTAssertTrue(driver.isRestartRequested)
        XCTAssertFalse(driver.canDismiss)
        driver.dismissByUser()
        XCTAssertEqual(choices, [.install])
        var acknowledgements = 0
        driver.showUpdateInstalledAndRelaunched(true) { acknowledgements += 1 }
        XCTAssertEqual(driver.stage, .completed)
        XCTAssertFalse(driver.isWorking)
        driver.dismissByUser()
        driver.dismissByUser()
        XCTAssertEqual(acknowledgements, 1)
    }

    func test在线升级只有显式启用且公钥和来源正确时可用() {
        let valid: [String: Any] = [
            "LanStashOnlineUpdatesEnabled": true,
            "SUFeedURL": AppUpdateController.feedURL,
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()
        ]
        XCTAssertTrue(AppUpdateController.isConfigured(valid))
        var validation = valid
        validation["SUFeedURL"] = AppUpdateController.validationFeedURL
        XCTAssertTrue(AppUpdateController.isConfigured(validation))
        for (key, value) in [
            ("LanStashOnlineUpdatesEnabled", false as Any),
            ("SUFeedURL", "https://example.invalid/update.xml"),
            ("SUPublicEDKey", "$(SPARKLE_PUBLIC_ED_KEY)"),
            ("SUPublicEDKey", Data(repeating: 1, count: 31).base64EncodedString())
        ] {
            var invalid = valid
            invalid[key] = value
            XCTAssertFalse(AppUpdateController.isConfigured(invalid))
        }
        XCTAssertFalse(AppUpdateController.isConfigured([:]))
    }

    func test准备安装时取消不得留下退出后自动安装() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady { choices.append($0) }
        driver.performSecondaryAction()
        driver.performSecondaryAction()
        driver.performPrimaryAction()
        XCTAssertEqual(choices, [.skip])
    }

    func test未完成工作阻止安装且完成后必须再次确认() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        var choices: [SPUUserUpdateChoice] = []
        driver.canRestart = { false }
        driver.showReady { choices.append($0) }
        driver.performPrimaryAction()
        XCTAssertTrue(choices.isEmpty)
        XCTAssertEqual(driver.detailKey, "updates.busy")
        driver.canRestart = { true }
        XCTAssertTrue(choices.isEmpty)
        driver.performPrimaryAction()
        driver.performPrimaryAction()
        XCTAssertEqual(choices, [.install])
    }

    func test重试重启同样不能中断工作() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        driver.canRestart = { false }
        var retries = 0
        driver.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        driver.performPrimaryAction()
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(driver.detailKey, "updates.busy")
    }

    func test下载进度和准备阶段不会沿用取消回调() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        var cancellations = 0
        driver.showDownloadInitiated { cancellations += 1 }
        driver.showDownloadDidReceiveExpectedContentLength(100)
        driver.showDownloadDidReceiveData(ofLength: 50)
        XCTAssertEqual(driver.progress, 0.5)
        driver.showDownloadDidReceiveData(ofLength: 80)
        XCTAssertEqual(driver.progress, 1)
        driver.showDownloadDidStartExtractingUpdate()
        driver.performSecondaryAction()
        XCTAssertEqual(cancellations, 0)
        XCTAssertNil(driver.progress)
        XCTAssertNil(driver.secondaryKey)
    }

    func test检查和错误确认只执行一次且不泄漏底层错误() {
        let driver = AppUpdateUserDriver(presentsWindows: false)
        var acknowledgements = 0
        driver.showUpdaterError(NSError(domain: "test", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "SID=synthetic-secret /private/example"
        ])) { acknowledgements += 1 }
        XCTAssertEqual(driver.detailKey, "updates.failed.detail")
        driver.performPrimaryAction()
        driver.performPrimaryAction()
        XCTAssertEqual(acknowledgements, 1)
    }

    func test所有未结束的传输状态都阻止更新重启() {
        for state in [ActivityState.queued, .running, .paused, .cancelling, .succeeded, .failed, .cancelled] {
            let task = ActivityTask(kind: .upload, displayName: "fixture", remotePath: "/fixture", state: state)
            XCTAssertEqual(AppUpdateController.hasUnfinishedTransfers([task]),
                           ![.succeeded, .failed, .cancelled].contains(state))
        }
        XCTAssertFalse(AppUpdateController.hasUnfinishedTransfers([]))
    }
}
