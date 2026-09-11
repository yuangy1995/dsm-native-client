import AppKit
import Combine
import DsmCore
@testable import DsmMacExecutable
import Sparkle
import XCTest

@MainActor
final class AppUpdateTests: XCTestCase {
    private func makeDriver() -> AppUpdateUserDriver {
        AppUpdateUserDriver(presentsWindows: false, fetchNotes: { _ in throw URLError(.notConnectedToInternet) })
    }

    private func waitForNotes(_ driver: AppUpdateUserDriver) async {
        guard driver.isLoadingNotes else { return }
        let completed = expectation(description: "说明加载结束")
        let observation = driver.$isLoadingNotes.filter { !$0 }.first().sink { _ in completed.fulfill() }
        await fulfillment(of: [completed], timeout: 2)
        withExtendedLifetime(observation) {}
    }

    private nonisolated static func notesResponse(_ request: URLRequest, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    private nonisolated static func notesData(version: String = "1.0.8", body: String = "- 修复与改进") -> Data {
        try! JSONSerialization.data(withJSONObject: ["tag_name": "macos/v" + version, "body": body,
                                                   "draft": false, "prerelease": false, "assets": []])
    }

    func test更新源没有正文时自动获取对应版本且不触发下载() async {
        let requested = expectation(description: "获取指定版本")
        let driver = AppUpdateUserDriver(presentsWindows: false, fetchNotes: { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/yuangy1995/dsm-native-client/releases/tags/macos%2Fv1.0.8")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            requested.fulfill()
            return (Self.notesData(), Self.notesResponse(request))
        })
        driver.showAvailable(version: "1.0.8", notes: nil) { _ in XCTFail("加载日志不能下载更新") }
        XCTAssertTrue(driver.isLoadingNotes)
        await waitForNotes(driver)
        await fulfillment(of: [requested], timeout: 1)
        XCTAssertEqual(driver.releaseNotes, "- 修复与改进")
        XCTAssertEqual(driver.version, "1.0.8")
        XCTAssertEqual(driver.primaryKey, "updates.download")
        XCTAssertFalse(driver.notesLoadFailed)
    }

    func test更新源已经附带说明时不再请求网络() async {
        let driver = AppUpdateUserDriver(presentsWindows: false, fetchNotes: { _ in
            XCTFail("已有说明不应重复请求")
            throw URLError(.badURL)
        })
        driver.showAvailable(version: "1.0.8", notes: "<p>已附带的说明</p>") { _ in }
        await Task.yield()
        XCTAssertEqual(driver.releaseNotes, "已附带的说明")
        XCTAssertFalse(driver.isLoadingNotes)
    }

    func test日志加载失败可原位重试且不泄漏错误详情() async {
        let probe = UpdateNotesAttemptProbe()
        let driver = AppUpdateUserDriver(presentsWindows: false, fetchNotes: { request in
            if await probe.next() == 1 { throw NSError(domain: "synthetic-private-details", code: 1) }
            return (Self.notesData(), Self.notesResponse(request))
        })
        driver.showAvailable(version: "1.0.8", notes: " ") { _ in XCTFail("重试日志不能安装") }
        await waitForNotes(driver)
        XCTAssertTrue(driver.notesLoadFailed)
        XCTAssertEqual(driver.primaryKey, "updates.download")
        XCTAssertFalse(driver.releaseNotes?.contains("synthetic-private-details") == true)
        driver.retryReleaseNotes()
        await waitForNotes(driver)
        XCTAssertFalse(driver.notesLoadFailed)
        XCTAssertEqual(driver.releaseNotes, "- 修复与改进")
        let attempts = await probe.count
        XCTAssertEqual(attempts, 2)
    }

    func test拒绝不匹配版本和错误响应但不修改待安装版本() async {
        for status in [200, 403] {
            let driver = AppUpdateUserDriver(presentsWindows: false, fetchNotes: { request in
                (Self.notesData(version: "9.9.9"), Self.notesResponse(request, status: status))
            })
            driver.showAvailable(version: "1.0.8", notes: nil) { _ in }
            await waitForNotes(driver)
            XCTAssertTrue(driver.notesLoadFailed)
            XCTAssertNil(driver.releaseNotes)
            XCTAssertEqual(driver.version, "1.0.8")
        }
        XCTAssertNil(AppUpdateUserDriver.releaseNotesRequest(version: "../../other"))
        XCTAssertNil(AppUpdateUserDriver.releaseNotesRequest(version: "https://example.invalid"))
        XCTAssertTrue(AppUpdateUserDriver.releaseNotesRequest(version: "1.0.8", validation: true)!.url!.absoluteString.contains("macos-validation%2Fv1.0.8"))
    }

    func test开始下载安装包不会取消仍在加载的日志() async {
        let gate = UpdateNotesResponseGate()
        let started = expectation(description: "说明请求已开始")
        let driver = AppUpdateUserDriver(presentsWindows: false, fetchNotes: { request in
            started.fulfill()
            return (await gate.wait(), Self.notesResponse(request))
        })
        driver.showAvailable(version: "1.0.8", notes: nil) { _ in }
        await fulfillment(of: [started], timeout: 1)
        driver.showDownloadInitiated {}
        await gate.release(Self.notesData())
        await waitForNotes(driver)
        XCTAssertEqual(driver.stage, .downloading)
        XCTAssertEqual(driver.version, "1.0.8")
        XCTAssertEqual(driver.releaseNotes, "- 修复与改进")
    }

    func test旧版本请求晚返回不能覆盖新弹窗的说明() async {
        let gate = UpdateNotesResponseGate()
        let started = expectation(description: "旧请求已开始")
        let returned = expectation(description: "旧请求已返回")
        let driver = AppUpdateUserDriver(presentsWindows: false, fetchNotes: { request in
            if request.url!.absoluteString.hasSuffix("v1.0.8") {
                started.fulfill()
                let data = await gate.wait()
                returned.fulfill()
                return (data, Self.notesResponse(request))
            }
            return (Self.notesData(version: "1.0.9", body: "新版本说明"), Self.notesResponse(request))
        })
        driver.showAvailable(version: "1.0.8", notes: nil) { _ in }
        await fulfillment(of: [started], timeout: 1)
        driver.showAvailable(version: "1.0.9", notes: nil) { _ in }
        await waitForNotes(driver)
        await gate.release(Self.notesData(body: "旧说明"))
        await fulfillment(of: [returned], timeout: 1)
        await Task.yield()
        XCTAssertEqual(driver.version, "1.0.9")
        XCTAssertEqual(driver.releaseNotes, "新版本说明")
    }

    func test关闭弹窗后返回的说明不能恢复已关闭状态() async {
        let gate = UpdateNotesResponseGate()
        let started = expectation(description: "说明请求已开始")
        let returned = expectation(description: "请求返回")
        let driver = AppUpdateUserDriver(presentsWindows: false, fetchNotes: { request in
            started.fulfill()
            let data = await gate.wait()
            returned.fulfill()
            return (data, Self.notesResponse(request))
        })
        driver.showAvailable(version: "1.0.8", notes: nil) { _ in }
        await fulfillment(of: [started], timeout: 1)
        driver.dismissUpdateInstallation()
        await gate.release(Self.notesData())
        await fulfillment(of: [returned], timeout: 1)
        await Task.yield()
        XCTAssertFalse(driver.isLoadingNotes)
        XCTAssertNil(driver.releaseNotes)
        XCTAssertNil(driver.primaryKey)
    }

    func test双语发布说明按当前语言展示且不暴露Markdown标记() {
        let notes = "## macOS 1.0.8\n\n- 修复闪退\n\n删除默认关闭。\n\n## English — macOS 1.0.8\n\n- Fixed crashes\n\nDeletion is off by default."
        let chinese = AppUpdateUserDriver.readableNotes(notes, prefersEnglish: false)
        let english = AppUpdateUserDriver.readableNotes(notes, prefersEnglish: true)
        XCTAssertTrue(chinese.contains("• 修复闪退"))
        XCTAssertFalse(chinese.contains("Fixed crashes"))
        XCTAssertTrue(english.contains("• Fixed crashes"))
        XCTAssertFalse(english.contains("修复闪退"))
        XCTAssertFalse(chinese.contains("##"))
        let embedded = AppUpdateUserDriver.plainNotes("<h2>macOS 1.0.8</h2><p>• 修复闪退</p><h2>English — macOS 1.0.8</h2><p>• Fixed crashes</p><script>unsafe()</script>")
        XCTAssertEqual(AppUpdateUserDriver.readableNotes(embedded, prefersEnglish: true), "• Fixed crashes")
    }

    func test预发布说明不能混入正式更新且草稿不展示() throws {
        let preview = try JSONSerialization.data(withJSONObject: ["tag_name": "macos-validation/v1.0.8",
            "body": "Preview", "draft": false, "prerelease": true, "assets": []])
        XCTAssertNil(try AppUpdateUserDriver.macReleaseNotes(from: preview, expectedTag: "macos/v1.0.8"))
        XCTAssertNotNil(try AppUpdateUserDriver.macReleaseNotes(from: preview, expectedTag: "macos-validation/v1.0.8"))
        let draft = try JSONSerialization.data(withJSONObject: ["tag_name": "macos/v1.0.8",
            "body": "Draft", "draft": true, "prerelease": false, "assets": []])
        XCTAssertNil(try AppUpdateUserDriver.macReleaseNotes(from: draft, expectedTag: "macos/v1.0.8"))
    }

    func test关于面板只显示对外版本且显式隐藏构建号() {
        let controller = AppUpdateController(bundle: Bundle(for: Self.self), canRestart: { true })
        XCTAssertEqual(controller.aboutPanelOptions[.applicationVersion] as? String, controller.currentVersion)
        XCTAssertEqual(controller.aboutPanelOptions[.version] as? String, "")
    }
    func test手动更新说明只选正式macOS发布且保留详情() throws {
        let data = Data(###"[{"tag_name":"android-9","body":"Android only","draft":false,"prerelease":false,"assets":[{"name":"app.apk"}]},{"tag_name":"macos-preview","body":"Preview","draft":false,"prerelease":true,"assets":[{"name":"Preview.dmg"}]},{"tag_name":"macos-1.0.3","body":"## Changes\n- Updated Photos","draft":false,"prerelease":false,"assets":[{"name":"LanStash.dmg"}]}]"###.utf8)
        let notes = try XCTUnwrap(AppUpdateUserDriver.macReleaseNotes(from: data))
        XCTAssertEqual(notes.version, "macos-1.0.3")
        XCTAssertTrue(notes.body.contains("Updated Photos"))
        XCTAssertTrue(AppUpdateUserDriver.PresentationStage.information.showsReleaseNotes)
    }
    func test更新窗口保留标题栏系统按钮且系统关闭只取消一次() {
        _ = NSApplication.shared
        let driver = makeDriver()
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
        let driver = makeDriver()
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
        let driver = makeDriver()
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
        let driver = makeDriver()
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
        let driver = makeDriver()
        var cancellations = 0
        driver.showDownloadInitiated { cancellations += 1 }
        driver.performPrimaryAction()
        XCTAssertEqual(driver.stage, .downloading)
        XCTAssertEqual(driver.secondaryKey, "updates.cancel")
        driver.dismissByUser()
        XCTAssertEqual(cancellations, 1)
    }

    func test准备和安装阶段不允许关闭但完成后可确认() {
        let driver = makeDriver()
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
        let driver = makeDriver()
        var choices: [SPUUserUpdateChoice] = []
        driver.showReady { choices.append($0) }
        driver.performSecondaryAction()
        driver.performSecondaryAction()
        driver.performPrimaryAction()
        XCTAssertEqual(choices, [.skip])
    }

    func test未完成工作阻止安装且完成后必须再次确认() {
        let driver = makeDriver()
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
        let driver = makeDriver()
        driver.canRestart = { false }
        var retries = 0
        driver.showInstallingUpdate(withApplicationTerminated: false) { retries += 1 }
        driver.performPrimaryAction()
        XCTAssertEqual(retries, 0)
        XCTAssertEqual(driver.detailKey, "updates.busy")
    }

    func test下载进度和准备阶段不会沿用取消回调() {
        let driver = makeDriver()
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
        let driver = makeDriver()
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

private actor UpdateNotesAttemptProbe {
    private(set) var count = 0
    func next() -> Int { count += 1; return count }
}

private actor UpdateNotesResponseGate {
    private var value: Data?
    private var continuation: CheckedContinuation<Data, Never>?
    func wait() async -> Data {
        if let value { return value }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ data: Data) {
        value = data
        continuation?.resume(returning: data)
        continuation = nil
    }
}
