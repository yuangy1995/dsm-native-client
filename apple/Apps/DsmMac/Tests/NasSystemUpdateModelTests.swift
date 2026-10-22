import DsmCore
import XCTest
@testable import DsmMacExecutable

@MainActor final class NasSystemUpdateModelTests: XCTestCase {
    func test下载安装重启和版本核验完整状态() async throws {
        let repository = SystemUpdateRepositoryFixture(), model = NasSystemUpdateModel(repository: repository)
        await model.refresh(); XCTAssertEqual(model.phase, .available)
        await model.download(); XCTAssertEqual(model.phase, .downloading)
        await repository.setStatus(.init(phase: .ready, canInstall: true))
        await model.refresh(); XCTAssertEqual(model.phase, .ready)
        let prepared = await model.prepareInstallation(); XCTAssertTrue(prepared)
        await model.install(); XCTAssertEqual(model.phase, .installing)
        await repository.setProgress(100)
        await model.refresh(); XCTAssertEqual(model.phase, .reconnecting, "100% 不等于完成")
        await repository.setCurrent("DSM 7.2.1-69057 Update 13")
        await model.refresh(); XCTAssertEqual(model.phase, .completed)
        await model.install()
        let count = await repository.installCount; XCTAssertEqual(count, 1)
    }

    func test断线等待与认证错误区分且不允许重发() async throws {
        let repository = SystemUpdateRepositoryFixture(), model = NasSystemUpdateModel(repository: repository)
        await repository.setStatus(.init(phase: .ready, canInstall: true))
        await model.refresh(); _ = await model.prepareInstallation(); await model.install()
        await repository.setFailure(.networkUnavailable)
        await model.refresh(); XCTAssertEqual(model.phase, .reconnecting); XCTAssertTrue(model.shouldPoll)
        await repository.setFailure(.authenticationRequired)
        await model.refresh(); XCTAssertEqual(model.phase, .attention); XCTAssertFalse(model.shouldPoll)
        await model.install()
        let count = await repository.installCount; XCTAssertEqual(count, 1)
        XCTAssertNotNil(model.errorMessage)
    }

    func test没有完整补丁版本时不宣称成功且证书错误停止轮询() async throws {
        let plan = NasSystemUpdatePlan(version: "DSM 7.2.1-69057 Update 13", build: 69057, update: 13)
        XCTAssertFalse(plan.matchesInstalledVersion("DSM 7.2.1"))
        XCTAssertFalse(plan.matchesInstalledVersion("DSM 7.2.1-69057 Update 12"))
        XCTAssertTrue(plan.matchesInstalledVersion("7.2.1-69057 Update 13"))
        let submittedAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(plan.confirmsCompletion(version: plan.version, uptimeSeconds: 7_200, submittedAt: submittedAt, now: submittedAt.addingTimeInterval(300)))
        XCTAssertFalse(plan.confirmsCompletion(version: plan.version, uptimeSeconds: nil, submittedAt: submittedAt, now: submittedAt.addingTimeInterval(300)))
        XCTAssertTrue(plan.confirmsCompletion(version: plan.version, uptimeSeconds: 30, submittedAt: submittedAt, now: submittedAt.addingTimeInterval(300)))
        let repository = SystemUpdateRepositoryFixture(), model = NasSystemUpdateModel(repository: repository)
        await repository.setFailure(.tlsCertificateChanged)
        await model.refresh(); XCTAssertEqual(model.phase, .attention); XCTAssertFalse(model.shouldPoll)
    }

    func test安装前拒绝不锁死恢复及电源操作() async throws {
        let repository = SystemUpdateRepositoryFixture(), model = NasSystemUpdateModel(repository: repository)
        await repository.setStatus(.init(phase: .ready, canInstall: true))
        await model.refresh(); _ = await model.prepareInstallation()
        await repository.setInstallFailure(.conflict)
        await model.install()
        XCTAssertFalse(model.installationSubmitted); XCTAssertFalse(model.blocksPowerActions)
        await model.refresh(); XCTAssertEqual(model.phase, .ready)
        let prepared = await model.prepareInstallation(); XCTAssertTrue(prepared)
    }
}

actor SystemUpdateRepositoryFixture: NasSettingsRepository {
    var status = NasSystemUpdateStatus(phase: .idle)
    var current = "DSM 7.2.1-69057 Update 12"
    var progress = 5.0
    var failure: AppErrorCategory?
    var installFailure: AppErrorCategory?
    private(set) var installCount = 0
    func setStatus(_ value: NasSystemUpdateStatus) { status = value }
    func setCurrent(_ value: String) {
        current = value
        if installCount > 0 && value.hasSuffix("13") { status = .init(phase: .completed, installedVersion: value) }
    }
    func setProgress(_ value: Double) { progress = value }
    func setFailure(_ value: AppErrorCategory?) { failure = value }
    func setInstallFailure(_ value: AppErrorCategory?) { installFailure = value }
    func checkSystemUpdate() async throws -> NasSystemUpdateInfo {
        if let failure { throw AppError(category: failure, isRetryable: false, safeUserMessage: "Fixture error") }
        return .init(isUpdateAvailable: !current.hasSuffix("13"), currentVersion: current, latestVersion: "DSM 7.2.1-69057 Update 13")
    }
    func loadSystemUpdateStatus() async throws -> NasSystemUpdateStatus {
        if let failure { throw AppError(category: failure, isRetryable: false, safeUserMessage: "Fixture error") }
        return status.phase == .installing ? .init(phase: .installing, percent: progress) : status
    }
    func downloadSystemUpdate(expectedVersion: String) async throws { status = .init(phase: .downloading, percent: 20) }
    func prepareSystemUpdate(expectedVersion: String) async throws -> NasSystemUpdatePlan { .init(version: expectedVersion, build: 69057, update: 13) }
    func installSystemUpdate(plan: NasSystemUpdatePlan) async throws -> NasSystemUpdateSubmission {
        if let installFailure { throw AppError(category: installFailure, isRetryable: false, safeUserMessage: "Fixture rejection") }
        installCount += 1; status = .init(phase: .installing); return .accepted
    }
    func loadSystemUpdateProgress() async throws -> NasSystemUpdateStatus { .init(phase: .installing, percent: progress) }
    private func unavailable() -> AppError { .init(category: .apiUnavailable, isRetryable: false, safeUserMessage: "Fixture unavailable") }
    func loadSystemOverview() async throws -> NasSystemOverview {
        if let failure { throw AppError(category: failure, isRetryable: false, safeUserMessage: "Fixture error") }
        return .init(serverName: "Fixture NAS", version: current)
    }
    func loadPerformanceSnapshot() async throws -> NasPerformanceSnapshot { throw unavailable() }
    func loadStorage() async throws -> NasStorageSnapshot { throw unavailable() }
    func loadPackages() async throws -> [NasPackage] { throw unavailable() }
    func loadScheduledTasks() async throws -> [NasScheduledTask] { throw unavailable() }
    func loadAccountsAndGroups() async throws -> NasAccountDirectory { throw unavailable() }
    func loadSystemProcesses(start: Int, limit: Int) async throws -> NasProcessDirectory { throw unavailable() }
    func loadLogs(offset: Int, limit: Int) async throws -> NasLogPage { throw unavailable() }
    func loadConnections(offset: Int, limit: Int) async throws -> NasConnectionPage { throw unavailable() }
}
