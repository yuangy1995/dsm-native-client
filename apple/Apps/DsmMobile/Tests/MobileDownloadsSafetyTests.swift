@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

final class MobileDownloadsSafetyTests: XCTestCase {
    @MainActor
    func test单任务暂停成功会更新当前快照且显示成功反馈() async throws {
        let suiteName = "MobileDownloadsSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MobileAppModel(defaults: defaults)
        let profile = try NasProfile(
            displayName: "测试设备",
            host: "nas.example.invalid",
            port: 5_001
        )
        let task = DownloadStationTask(id: "task-1", title: "示例任务", status: "downloading")
        model.activeProfile = profile
        model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [task])
        model.downloadStationControlOverride = { request in
            XCTAssertEqual(request.task.id, "task-1")
            XCTAssertEqual(request.action, .pause)
            return try DownloadTaskControlOutcome(
                result: MutationResult(
                    status: .confirmedSuccess,
                    operation: "downloadPause",
                    submitted: true,
                    requiresRefresh: true,
                    counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0)
                ),
                taskID: "task-1",
                task: DownloadStationTask(id: "task-1", title: "示例任务", status: "paused")
            )
        }

        model.controlDownloadTask(task, action: .pause)
        for _ in 0..<50 where model.downloadControlFeedback?.kind != .success {
            await Task.yield()
        }

        XCTAssertEqual(model.downloadTask(id: "task-1")?.status, "paused")
        XCTAssertEqual(model.downloadControlFeedback?.kind, .success)
    }

    @MainActor
    func test链接创建成功会插入确认任务并显示成功反馈() async throws {
        let suiteName = "MobileDownloadsSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MobileAppModel(defaults: defaults)
        let profile = try NasProfile(
            displayName: "测试设备",
            host: "nas.example.invalid",
            port: 5_001
        )
        model.activeProfile = profile
        model.downloadSnapshot = DownloadStationSnapshot(
            source: .official,
            tasks: [],
            defaultDestination: "/downloads"
        )
        model.downloadStationCreateOverride = { request in
            XCTAssertEqual(request.uri, "magnet:?xt=urn:btih:test")
            XCTAssertEqual(request.destination, "/downloads")
            return try DownloadTaskCreateOutcome(
                result: MutationResult(
                    status: .confirmedSuccess,
                    operation: "downloadCreate",
                    submitted: true,
                    requiresRefresh: true,
                    counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0)
                ),
                taskID: "created-1",
                task: DownloadStationTask(
                    id: "created-1",
                    title: "新任务",
                    status: "waiting",
                    destination: "/downloads"
                )
            )
        }

        model.createDownloadTask(uri: " magnet:?xt=urn:btih:test ")
        for _ in 0..<50 where model.downloadCreateFeedback?.kind != .success {
            await Task.yield()
        }

        XCTAssertEqual(model.downloadCreateFeedback?.kind, .success)
        XCTAssertEqual(model.downloadSnapshot?.tasks.first?.id, "created-1")
    }

    @MainActor
    func test单任务删除成功只移除任务且不删除已下载文件() async throws {
        let suiteName = "MobileDownloadsSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MobileAppModel(defaults: defaults)
        let profile = try NasProfile(
            displayName: "测试设备",
            host: "nas.example.invalid",
            port: 5_001
        )
        let task = DownloadStationTask(id: "task-1", title: "示例任务", status: "finished")
        model.activeProfile = profile
        model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [task])
        model.downloadStationDeleteOverride = { ids, removeData in
            XCTAssertEqual(ids, ["task-1"])
            XCTAssertFalse(removeData)
            return try MutationResult(
                status: .confirmedSuccess,
                operation: "downloadTaskDelete",
                submitted: true,
                requiresRefresh: true,
                counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0)
            )
        }

        model.deleteDownloadTask(task)
        for _ in 0..<50 where model.downloadDeleteFeedback?.kind != .success {
            await Task.yield()
        }

        XCTAssertNil(model.downloadTask(id: "task-1"))
        XCTAssertEqual(model.downloadDeleteFeedback?.kind, .success)
    }

    @MainActor
    func test单任务删除未知结果保留任务并要求核对() async throws {
        let suiteName = "MobileDownloadsSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MobileAppModel(defaults: defaults)
        let profile = try NasProfile(
            displayName: "测试设备",
            host: "nas.example.invalid",
            port: 5_001
        )
        let task = DownloadStationTask(id: "task-1", title: "示例任务", status: "finished")
        model.activeProfile = profile
        model.downloadSnapshot = DownloadStationSnapshot(source: .official, tasks: [task])
        model.downloadStationDeleteOverride = { ids, removeData in
            XCTAssertEqual(ids, ["task-1"])
            XCTAssertFalse(removeData)
            return try MutationResult(
                status: .submittedButUnverified,
                operation: "downloadTaskDelete",
                submitted: true,
                requiresRefresh: true,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 1),
                errorCategory: .network,
                localizationKey: "download-task.delete.unverified",
                diagnosticTag: "download-task.delete.unverified"
            )
        }

        model.deleteDownloadTask(task)
        for _ in 0..<50 where model.downloadDeleteFeedback?.kind != .needsReview {
            await Task.yield()
        }

        XCTAssertNotNil(model.downloadTask(id: "task-1"))
        XCTAssertEqual(model.downloadDeleteFeedback?.kind, .needsReview)
    }

    func test下载页面和模型仅开放单链接创建单任务暂停继续和删除入口() throws {
        let view = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadsView.swift"
        )
        let model = try sourceFile(
            "Sources/Features/Services/Downloads/MobileAppModel+Downloads.swift"
        )

        for forbidden in [
            "createDownloadTask(fileURL", "controlDownloadTasks", "deleteDownloadTasks(",
            "saveDownloadStationSettings", "removeData: true",
            "force_complete", "unzipPassword", "DownloadStation2"
        ] {
            XCTAssertFalse(view.contains(forbidden), "View: \(forbidden)")
            XCTAssertFalse(model.contains(forbidden), "Model: \(forbidden)")
        }
        XCTAssertTrue(view.contains("MobileDownloadCreateTaskView"))
        XCTAssertTrue(view.contains("TextField("))
        XCTAssertTrue(view.contains("model.createDownloadTask(uri: uri)"))
        XCTAssertTrue(view.contains("model.controlDownloadTask(task, action: .pause)"))
        XCTAssertTrue(view.contains("model.controlDownloadTask(task, action: .resume)"))
        XCTAssertTrue(view.contains("model.deleteDownloadTask(task)"))
        XCTAssertTrue(view.contains("confirmationDialog("))
        XCTAssertTrue(model.contains("createDownloadTask(uri rawURI: String)"))
        XCTAssertTrue(model.contains("DownloadTaskCreateRequest("))
        XCTAssertTrue(model.contains("controlDownloadTask(_ task: DownloadStationTask"))
        XCTAssertTrue(model.contains("DownloadTaskControlRequest(task: task, action: action)"))
        XCTAssertTrue(model.contains("deleteDownloadTask(_ task: DownloadStationTask)"))
        XCTAssertTrue(model.contains("deleteDownloadTasksResult("))
        XCTAssertTrue(model.contains("removeData: false"))
    }

    func test下载页面保留四态受限控制列表和详情选择() throws {
        let view = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadsView.swift"
        )
        let model = try sourceFile(
            "Sources/Features/Services/Downloads/MobileAppModel+Downloads.swift"
        )

        XCTAssertTrue(view.contains("MobilePageStateView("))
        XCTAssertTrue(view.contains("state: model.downloadPageState"))
        XCTAssertTrue(view.contains("List {"))
        XCTAssertTrue(view.contains(".sheet(item: $selectedTask)"))
        XCTAssertTrue(view.contains("MobileDownloadTaskDetailView"))
        XCTAssertTrue(view.contains("mobile.downloads.control.section"))
        XCTAssertTrue(model.contains("return .loading"))
        XCTAssertTrue(model.contains("return message == nil ? .loading : .error"))
        XCTAssertTrue(model.contains("return downloadSnapshot.tasks.isEmpty ? .empty : .content"))
    }

    func test受限控制说明触控和VoiceOver语义保持稳定() throws {
        let view = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadsView.swift"
        )

        XCTAssertTrue(view.contains("mobile.downloads.read-only.notice"))
        XCTAssertTrue(view.contains("mobile.downloads.create.url.label"))
        XCTAssertTrue(view.contains("mobile.downloads.create.url.help"))
        XCTAssertTrue(view.contains("interactiveDismissDisabled(model.isCreatingDownloadTask)"))
        XCTAssertTrue(view.contains("mobile.downloads.control.pause.hint"))
        XCTAssertTrue(view.contains("mobile.downloads.control.resume.hint"))
        XCTAssertTrue(view.contains("mobile.downloads.delete.action.hint"))
        XCTAssertTrue(view.contains("mobile.downloads.delete.confirm.message"))
        XCTAssertTrue(view.contains("mobile.downloads.control.in-progress.message"))
        XCTAssertTrue(view.contains("mobile.downloads.delete.deleting.message"))
        XCTAssertTrue(view.contains("MobileMetrics.minimumTouchTarget"))
        XCTAssertTrue(view.contains(".accessibilityHint("))
        XCTAssertTrue(view.contains(".accessibilityLabel("))
        XCTAssertTrue(view.contains(".accessibilityValue("))
        XCTAssertTrue(view.contains(".accessibilityHidden(true)"))
        XCTAssertFalse(view.contains(".font(.system(size:"))
        XCTAssertFalse(view.contains("withAnimation"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: appRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
