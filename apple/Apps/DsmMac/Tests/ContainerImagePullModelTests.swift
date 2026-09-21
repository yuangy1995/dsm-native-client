import DsmCore
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class ContainerImagePullModelTests: XCTestCase {
    private func ready() async -> (ServiceManagementRepositoryStub, ContainerImagePullModel) {
        let repository = ServiceManagementRepositoryStub(); let model = ContainerImagePullModel(repository: repository)
        await model.activate(); model.setTarget(repository: "synthetic/web", tag: "stable")
        return (repository, model)
    }

    func test确认绑定目标并且重复点击不重复下载() async {
        let (repository, model) = await ready()
        await model.submit(); let before = await repository.pullRequests; XCTAssertTrue(before.isEmpty)
        model.confirm(true); model.setTarget(repository: "synthetic/web", tag: "latest"); XCTAssertFalse(model.canSubmit)
        model.confirm(true); await model.submit(); await model.submit()
        let calls = await repository.pullRequests
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?.tag, "latest"); XCTAssertEqual(calls.first?.isConfirmed, true)
        XCTAssertFalse(model.canConfirm); XCTAssertTrue(model.hasPollableTasks)
        model.deactivate()
    }

    func test自动核查保留其他目标确认且终态停止轮询() async {
        let (repository, model) = await ready()
        model.confirm(true); await model.submit()
        model.setTarget(repository: "synthetic/other", tag: "stable"); model.confirm(true)
        await repository.configurePull(stage: .ready); await model.refresh(automatic: true)
        XCTAssertTrue(model.isConfirmed); XCTAssertFalse(model.hasPollableTasks)
        let before = await repository.pullReviewCalls; await model.refresh(automatic: true)
        let after = await repository.pullReviewCalls; XCTAssertEqual(before, after)
        XCTAssertEqual(model.results.first?.stage, .ready)
        await model.refresh(); XCTAssertFalse(model.isConfirmed); model.deactivate()
    }

    func test异常保留未确认占位并禁止同目标再次提交() async {
        let (repository, model) = await ready(); await repository.configurePull(fail: true)
        model.confirm(true); await model.submit(); await model.refresh(); await model.submit()
        XCTAssertEqual(model.results.first?.stage, .awaitingReceipt)
        XCTAssertFalse(model.canConfirm); XCTAssertFalse(model.hasPollableTasks)
        let calls = await repository.pullRequests; XCTAssertEqual(calls.count, 1)
        model.deactivate()
    }

    func test关闭后重开只读恢复且关闭时不再查询() async {
        let (repository, model) = await ready(); model.confirm(true); await model.submit(); model.deactivate()
        let before = await repository.pullReviewCalls; await model.refresh(automatic: true)
        let after = await repository.pullReviewCalls; XCTAssertEqual(before, after)
        await model.activate(); XCTAssertEqual(model.results.count, 1); XCTAssertTrue(model.hasPollableTasks)
        let calls = await repository.pullRequests; XCTAssertEqual(calls.count, 1); model.deactivate()
    }

    func test关闭后的迟到启动结果保留但不覆盖新窗口状态() async throws {
        let (repository, model) = await ready(); await repository.configurePull(hold: true)
        model.confirm(true); let task = Task { await model.submit() }
        let deadline = Date().addingTimeInterval(2)
        while await repository.pullRequests.isEmpty && Date() < deadline { await Task.yield() }
        model.deactivate(); await model.activate()
        try await repository.finishHeldPull(stage: .ready); await task.value
        XCTAssertTrue(model.isVisible); XCTAssertFalse(model.isBusy); XCTAssertEqual(model.results.first?.stage, .ready)
        await repository.overrideCachedPullStage(.downloading); await model.refresh()
        XCTAssertEqual(model.results.first?.stage, .ready)
        model.deactivate()
    }

    func test只读能力不开放启动但仍可核查() async {
        let (repository, model) = await ready(); model.deactivate(); await repository.configurePull(supported: false)
        await model.activate(); model.setTarget(repository: "synthetic/web", tag: "stable"); model.confirm(true); await model.submit()
        XCTAssertFalse(model.isAvailable); XCTAssertFalse(model.canSubmit); XCTAssertTrue(model.canReview)
        let calls = await repository.pullRequests; XCTAssertTrue(calls.isEmpty); model.deactivate()
    }

    func test可见任务自动刷新且取消观察立即退出() async {
        let (repository, model) = await ready(); model.confirm(true); await model.submit(); model.deactivate()
        let watching = Task { await model.watch(interval: .milliseconds(1)) }
        let deadline = Date().addingTimeInterval(2)
        while await repository.pullReviewCalls < 2 && Date() < deadline { await Task.yield() }
        watching.cancel(); await watching.value
        XCTAssertFalse(model.isVisible); XCTAssertFalse(model.isBusy)
        let reviews = await repository.pullReviewCalls; XCTAssertGreaterThanOrEqual(reviews, 2)
        let calls = await repository.pullRequests; XCTAssertEqual(calls.count, 1)
    }
}
