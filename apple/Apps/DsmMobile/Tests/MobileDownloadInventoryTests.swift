@testable import DsmMobile
import DsmCore
import DsmLocalization
import Foundation
import XCTest

@MainActor
final class MobileDownloadInventoryTests: XCTestCase {
    func test筛选搜索与排序保持原始状态语义() throws {
        let model = try makeModel()
        model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [
            task("one", "Archive 10", "paused"), task("two", "Archive 2", "downloading"),
            task("three", "Video", "seeding"), task("four", "Unknown", "new-status")
        ], isComplete: true)
        XCTAssertEqual(model.visibleTasks.map(\.id), ["two", "one", "four", "three"])
        model.taskFilter = .active
        XCTAssertEqual(model.visibleTasks.map(\.id), ["two", "three"])
        model.searchText = "ARCHIVE"
        XCTAssertEqual(model.visibleTasks.map(\.id), ["two"])
        model.searchText = "missing"
        XCTAssertEqual(model.downloadPageState, .filteredEmpty)
        model.resetPresentation()
        XCTAssertEqual(model.downloadPageState, .content)
        XCTAssertEqual(model.visibleTasks.count, 4)
    }

    func test分页读取失败保留旧列表并允许重试() async throws {
        let model = try makeModel()
        model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [task()], isComplete: true)
        model.downloadStationLoadOverride = { throw URLError(.networkConnectionLost) }
        await model.load()
        XCTAssertEqual(model.downloadSnapshot?.tasks.count, 1)
        XCTAssertNotNil(model.message)
        XCTAssertFalse(model.isLoading)
        model.downloadStationLoadOverride = { DownloadStationSnapshot(source: .official, tasks: [], isComplete: true) }
        await model.load()
        XCTAssertEqual(model.downloadPageState, .empty)
        XCTAssertNil(model.message)
    }

    func test缺失速度显示横线但已知零不当作未知() {
        XCTAssertEqual(MobileDownloadPresentation.speed(nil), "--")
        XCTAssertEqual(MobileDownloadPresentation.speed(-1), "--")
        XCTAssertNotEqual(MobileDownloadPresentation.speed(0), "--")
        XCTAssertEqual(MobileDownloadPresentation.remaining(task()), "--")
        XCTAssertEqual(MobileDownloadPresentation.status("seeding"), MobileDownloadFilter.seeding.title)
        XCTAssertNotEqual(MobileDownloadPresentation.status("new-status"), "new-status")
    }

    func test详情替换同一任务并保留目录与缺失统计标记() async throws {
        let model = try makeModel()
        model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [task()],
            isComplete: true, statistics: DownloadStationStatistics(downloadBytesPerSecond: 0))
        model.downloadDetailsOverride = { _ in DownloadStationTaskDetails(task: DownloadStationTask(
            id: "one", title: "Updated", status: "paused", sizeBytes: 123)) }
        _ = try await model.loadDetails(id: "one")
        XCTAssertEqual(model.downloadTask(id: "one")?.title, "Updated")
        XCTAssertEqual(model.downloadSnapshot?.isComplete, true)
        XCTAssertNil(model.downloadSnapshot?.statistics?.uploadBytesPerSecond)
    }

    func test详情迟到不能进入其他账号() async throws {
        let model = try makeModel()
        model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [task()], isComplete: true)
        let gate = DownloadDetailsGate()
        model.downloadDetailsOverride = { _ in await gate.wait(); return DownloadStationTaskDetails(task: DownloadStationTask(id: "one", title: "Old", status: "paused")) }
        let operation = Task { try await model.loadDetails(id: "one") }
        await gate.started()
        model.configure(profile: try NasProfile(displayName: "Other", host: "other.example.invalid", port: 5001), repository: nil)
        await gate.finish()
        do { _ = try await operation.value; XCTFail("旧账号详情必须被丢弃") }
        catch is CancellationError {} catch { XCTFail("错误应为取消") }
        XCTAssertNil(model.downloadSnapshot)
    }

    func test控制期间迟到详情不能覆盖新任务状态() async throws {
        let model = try makeModel()
        model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [task("one", "Current")], isComplete: true)
        let gate = DownloadDetailsGate()
        model.downloadDetailsOverride = { _ in await gate.wait(); return DownloadStationTaskDetails(task: DownloadStationTask(id: "one", title: "Old", status: "paused")) }
        let operation = Task { try await model.loadDetails(id: "one") }
        await gate.started()
        model.downloadStationControlOverride = { request in
            XCTAssertEqual(request.action, .resume)
            return try DownloadTaskControlOutcome(result: MutationResult(status: .confirmedSuccess,
                operation: "downloadResume", submitted: true, requiresRefresh: true,
                counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0)), taskID: "one",
                task: DownloadStationTask(id: "one", title: "Current", status: "downloading"))
        }
        model.controlDownloadTask(task("one", "Current"), action: .resume)
        await model.downloadControlTask?.value
        await gate.finish()
        do { _ = try await operation.value; XCTFail("提交前的旧读取不得覆盖写后状态") }
        catch is CancellationError {} catch { XCTFail("错误应为取消") }
        XCTAssertEqual(model.downloadTask(id: "one")?.title, "Current")
        XCTAssertEqual(model.downloadTask(id: "one")?.status, "downloading")
    }

    func test不同任务的详情不能覆盖列表() async throws {
        let model = try makeModel()
        model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [task()], isComplete: true)
        model.downloadDetailsOverride = { _ in DownloadStationTaskDetails(task: DownloadStationTask(id: "other", title: "Other", status: "paused")) }
        do { _ = try await model.loadDetails(id: "one"); XCTFail("不能接受其他任务") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        XCTAssertEqual(model.downloadTask(id: "one")?.title, "Sample")
    }

    func test控制执行中开始的列表与详情读取也不能覆盖最终状态() async throws {
        for loadsDetails in [false, true] {
            let model = try makeModel()
            // 暂停和继续不改变身份；旧读取另外保留过时标题与状态。
            let original = task("one", "Current"), stale = task("one", "Old")
            model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [original], isComplete: true)
            let writeGate = DownloadDetailsGate(), readGate = DownloadDetailsGate()
            model.downloadStationControlOverride = { _ in
                await writeGate.wait()
                return try DownloadTaskControlOutcome(result: MutationResult(status: .confirmedSuccess,
                    operation: "downloadResume", submitted: true, requiresRefresh: true,
                    counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0)), taskID: "one",
                    task: DownloadStationTask(id: "one", title: "Current", status: "downloading"))
            }
            model.downloadDetailsOverride = { _ in await readGate.wait(); return DownloadStationTaskDetails(task: stale) }
            model.downloadStationLoadOverride = { await readGate.wait(); return DownloadStationSnapshot(source: .official, tasks: [stale], isComplete: true) }
            model.controlDownloadTask(original, action: .resume)
            let write = model.downloadControlTask
            await writeGate.started()
            let read = Task {
                if loadsDetails {
                    do { _ = try await model.loadDetails(id: "one"); XCTFail("操作中开始的旧详情必须丢弃") }
                    catch is CancellationError {} catch { XCTFail("应丢弃旧详情") }
                } else { await model.load() }
            }
            await readGate.started()
            await writeGate.finish(); await write?.value
            await readGate.finish(); await read.value
            XCTAssertEqual(model.downloadTask(id: "one")?.status, "downloading")
            XCTAssertEqual(model.downloadTask(id: "one")?.title, "Current")
        }
    }

    func test创建与移除执行中开始的旧列表不能恢复旧集合() async throws {
        for removesTask in [false, true] {
            let model = try makeModel(), original = task()
            model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [original], isComplete: true)
            let writeGate = DownloadDetailsGate(), readGate = DownloadDetailsGate()
            model.downloadStationCreateOverride = { _ in
                await writeGate.wait()
                return try DownloadTaskCreateOutcome(result: MutationResult(status: .confirmedSuccess,
                    operation: "downloadCreate", submitted: true, requiresRefresh: true,
                    counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0)), taskID: "new",
                    task: DownloadStationTask(id: "new", title: "New", status: "waiting"))
            }
            model.downloadStationDeleteOverride = { _, _ in
                await writeGate.wait()
                return try MutationResult(status: .confirmedSuccess, operation: "downloadDelete",
                    submitted: true, requiresRefresh: true,
                    counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0))
            }
            model.downloadStationLoadOverride = { await readGate.wait(); return DownloadStationSnapshot(source: .official, tasks: [original], isComplete: true) }
            if removesTask { model.deleteDownloadTask(original) }
            else { model.createDownloadTask(uri: "https://files.example.invalid/sample.zip") }
            let write = removesTask ? model.downloadDeleteTask : model.downloadCreateTask
            await writeGate.started()
            let read = Task { await model.load() }; await readGate.started()
            await writeGate.finish(); await write?.value
            await readGate.finish(); await read.value
            XCTAssertEqual(Set(model.downloadSnapshot?.tasks.map(\.id) ?? []), removesTask ? [] : ["one", "new"])
        }
    }

    private func makeModel() throws -> MobileDownloadsModel {
        let model = MobileDownloadsModel(transferCoordinator: MobileTransferCoordinator())
        model.configure(profile: try NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001), repository: nil)
        return model
    }

    private func task(_ id: String = "one", _ title: String = "Sample", _ status: String = "paused") -> DownloadStationTask {
        DownloadStationTask(id: id, title: title, status: status)
    }
}

private actor DownloadDetailsGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var startedWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { waiting = $0; startedWaiter?.resume(); startedWaiter = nil }
    }
    func started() async {
        if waiting != nil { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func finish() { waiting?.resume(); waiting = nil }
}
