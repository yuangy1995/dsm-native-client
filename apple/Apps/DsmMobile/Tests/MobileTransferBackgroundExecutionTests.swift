@testable import DsmMobile
import XCTest

@MainActor
final class MobileTransferBackgroundExecutionTests: XCTestCase {
    func test系统拒绝持续执行时保留有限时间且到期只取消一次() async {
        let driver = BackgroundDriverFixture()
        driver.rejectsSubmission = true
        let model = MobileTransferBackgroundExecution(driver: driver)
        let id = UUID()
        var expirations = 0
        let token = model.begin(taskID: id, activity: .upload) { expirations += 1 }
        XCTAssertEqual(model.modes[id], .limited)
        let expire = driver.limitedExpirations[0]
        await expire(); await expire()
        model.finish(token, success: true)
        XCTAssertEqual(expirations, 1)
        XCTAssertNil(model.modes[id])
        XCTAssertEqual(driver.limited[0].completions, [false])
    }

    func test系统授予持续执行后承接真实进度并结束有限时间() async {
        let driver = BackgroundDriverFixture()
        let model = MobileTransferBackgroundExecution(driver: driver)
        let id = UUID()
        let token = model.begin(taskID: id, activity: .download) {}
        model.update(token, completed: 12, total: 48)
        let continuous = BackgroundLeaseFixture()
        driver.jobs[0].started(continuous)
        XCTAssertEqual(model.modes[id], .continuous)
        XCTAssertEqual(driver.limited[0].completions, [true])
        XCTAssertEqual(continuous.progress.last?.completed, 12)
        XCTAssertEqual(continuous.progress.last?.total, 48)
        model.update(token, completed: 48, total: 48)
        model.finish(token, success: true)
        model.finish(token, success: false)
        XCTAssertEqual(continuous.completions, [true])
        XCTAssertNil(model.modes[id])
    }

    func test有限时间迟到的到期通知不取消已取得的持续资格() async {
        let driver = BackgroundDriverFixture()
        let model = MobileTransferBackgroundExecution(driver: driver)
        let id = UUID()
        var expired = false
        let token = model.begin(taskID: id, activity: .upload) { expired = true }
        let continuous = BackgroundLeaseFixture()
        driver.jobs[0].started(continuous)
        await driver.limitedExpirations[0]()
        XCTAssertFalse(expired)
        XCTAssertEqual(model.modes[id], .continuous)
        XCTAssertTrue(continuous.completions.isEmpty)
        model.finish(token, success: true)
    }

    func test任务先结束后系统才回调时归还资格且不重新执行() async {
        let driver = BackgroundDriverFixture()
        let model = MobileTransferBackgroundExecution(driver: driver)
        let id = UUID()
        var expirations = 0
        let token = model.begin(taskID: id, activity: .download) { expirations += 1 }
        model.finish(token, success: true)
        let continuous = BackgroundLeaseFixture()
        driver.jobs[0].started(continuous)
        await driver.jobs[0].expiration()
        XCTAssertEqual(driver.cancelled, [driver.jobs[0].identifier])
        XCTAssertEqual(continuous.completions, [false])
        XCTAssertEqual(expirations, 0)
        XCTAssertNil(model.modes[id])
    }

    func test旧执行到期不会取消同一任务后来的主动继续() async {
        let driver = BackgroundDriverFixture()
        let model = MobileTransferBackgroundExecution(driver: driver)
        let id = UUID()
        var oldExpired = false
        var newExpired = false
        let old = model.begin(taskID: id, activity: .upload) { oldExpired = true }
        model.finish(old, success: false)
        let current = model.begin(taskID: id, activity: .upload) { newExpired = true }
        XCTAssertNotEqual(driver.jobs[0].identifier, driver.jobs[1].identifier)
        await driver.jobs[0].expiration(); await driver.limitedExpirations[0]()
        XCTAssertFalse(oldExpired)
        XCTAssertFalse(newExpired)
        XCTAssertEqual(model.modes[id], .limited)
        await driver.jobs[1].expiration()
        XCTAssertTrue(newExpired)
        XCTAssertNil(model.modes[id])
        model.finish(current, success: false)
    }

    func test系统结束前先执行取消与保存恢复状态() async {
        let driver = BackgroundDriverFixture()
        let model = MobileTransferBackgroundExecution(driver: driver)
        var saved = false
        _ = model.begin(taskID: UUID(), activity: .upload) {
            XCTAssertTrue(driver.limited[0].completions.isEmpty)
            saved = true
        }
        await driver.limitedExpirations[0]()
        XCTAssertTrue(saved)
        XCTAssertEqual(driver.limited[0].completions, [false])
    }

    func test没有系统资格时不宣称可后台传输且不伪造进度() async {
        let driver = BackgroundDriverFixture()
        driver.offersLimited = false
        driver.rejectsSubmission = true
        let model = MobileTransferBackgroundExecution(driver: driver)
        let id = UUID()
        let token = model.begin(taskID: id, activity: .download) {}
        XCTAssertEqual(model.modes[id], .unavailable)
        model.update(token, completed: 34, total: nil)
        XCTAssertTrue(driver.limited.isEmpty)
        model.finish(token, success: false)
        XCTAssertNil(model.modes[id])
    }
}

@MainActor
final class BackgroundLeaseFixture: MobileTransferBackgroundLease {
    var progress: [(completed: Int64, total: Int64?)] = []
    var completions: [Bool] = []
    func update(completed: Int64, total: Int64?) { progress.append((completed, total)) }
    func finish(success: Bool) { completions.append(success) }
}

@MainActor
final class BackgroundDriverFixture: MobileTransferBackgroundDriving {
    struct Job {
        let identifier: String
        let activity: MobileTransferBackgroundActivity
        let started: @MainActor @Sendable (any MobileTransferBackgroundLease) -> Void
        let expiration: @MainActor @Sendable () async -> Void
    }
    var jobs: [Job] = []
    var limited: [BackgroundLeaseFixture] = []
    var limitedExpirations: [@MainActor @Sendable () async -> Void] = []
    var cancelled: [String] = []
    var rejectsSubmission = false
    var offersLimited = true
    var onSubmit: (@MainActor () -> Void)?

    func beginLimited(expiration: @escaping @MainActor @Sendable () async -> Void) -> (any MobileTransferBackgroundLease)? {
        guard offersLimited else { return nil }
        let lease = BackgroundLeaseFixture()
        limited.append(lease); limitedExpirations.append(expiration)
        return lease
    }
    func submit(identifier: String, activity: MobileTransferBackgroundActivity,
                started: @escaping @MainActor @Sendable (any MobileTransferBackgroundLease) -> Void,
                expiration: @escaping @MainActor @Sendable () async -> Void) throws -> Bool {
        jobs.append(Job(identifier: identifier, activity: activity, started: started, expiration: expiration))
        onSubmit?()
        if rejectsSubmission { throw CocoaError(.featureUnsupported) }
        return true
    }
    func cancelPending(identifier: String) { cancelled.append(identifier) }
}
