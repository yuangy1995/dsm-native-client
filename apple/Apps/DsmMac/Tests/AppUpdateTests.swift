import DsmCore
@testable import DsmMacExecutable
import Sparkle
import XCTest

@MainActor
final class AppUpdateTests: XCTestCase {
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
