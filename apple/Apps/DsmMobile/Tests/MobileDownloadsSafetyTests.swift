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
    func test任务文件创建成功会使用当前默认目标并插入确认任务() async throws {
        let suiteName = "MobileDownloadsSafetyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = MobileAppModel(defaults: defaults)
        let profile = try NasProfile(
            displayName: "测试设备",
            host: "nas.example.invalid",
            port: 5_001
        )
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mobile-task-\(UUID().uuidString).torrent")
        try Data("d4:infod4:name4:testee".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        model.activeProfile = profile
        model.downloadSnapshot = DownloadStationSnapshot(
            source: .official,
            tasks: [],
            defaultDestination: "/downloads"
        )
        model.downloadStationCreateFileOverride = { request in
            XCTAssertEqual(request.fileURL, fileURL)
            XCTAssertEqual(request.destination, "/downloads")
            XCTAssertNil(request.unzipPassword)
            return try DownloadTaskCreateOutcome(
                result: MutationResult(
                    status: .confirmedSuccess,
                    operation: "downloadCreate",
                    submitted: true,
                    requiresRefresh: true,
                    counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0)
                ),
                taskID: "file-created-1",
                task: DownloadStationTask(
                    id: "file-created-1",
                    title: "种子任务",
                    status: "waiting",
                    destination: "/downloads"
                )
            )
        }

        model.createDownloadTask(fileURL: fileURL)
        try await waitForDownloadCreateFeedback(on: model, kind: .success)

        XCTAssertEqual(model.downloadCreateFeedback?.kind, .success)
        XCTAssertEqual(model.downloadSnapshot?.tasks.first?.id, "file-created-1")
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

    func test下载页面和模型仅开放单链接和任务文件创建单任务暂停继续和删除入口() throws {
        let view = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadsView.swift"
        )
        let model = try sourceFile(
            "Sources/Features/Services/Downloads/MobileAppModel+Downloads.swift"
        )

        for forbidden in [
            "repository.createDownloadTask(fileURL:", "controlDownloadTasks", "deleteDownloadTasks(",
            "saveDownloadStationSettings", "removeData: true",
            "force_complete", "unzipPassword", "DownloadStation2"
        ] {
            XCTAssertFalse(view.contains(forbidden), "View: \(forbidden)")
            XCTAssertFalse(model.contains(forbidden), "Model: \(forbidden)")
        }
        XCTAssertTrue(view.contains("MobileDownloadCreateTaskView"))
        XCTAssertTrue(view.contains(".fileImporter("))
        XCTAssertTrue(view.contains("UTType(filenameExtension: \"torrent\")"))
        XCTAssertTrue(view.contains("UTType(filenameExtension: \"nzb\")"))
        XCTAssertTrue(view.contains("UTType(filenameExtension: \"txt\")"))
        XCTAssertTrue(view.contains("TextField("))
        XCTAssertTrue(view.contains("model.createDownloadTask(uri: uri)"))
        XCTAssertTrue(view.contains("model.createDownloadTask(fileURL: url)"))
        XCTAssertTrue(view.contains("model.controlDownloadTask(task, action: .pause)"))
        XCTAssertTrue(view.contains("model.controlDownloadTask(task, action: .resume)"))
        XCTAssertTrue(view.contains("model.deleteDownloadTask(task)"))
        XCTAssertTrue(view.contains("confirmationDialog("))
        XCTAssertTrue(model.contains("createDownloadTask(uri rawURI: String)"))
        XCTAssertTrue(model.contains("createDownloadTask(fileURL: URL)"))
        XCTAssertTrue(model.contains("DownloadTaskCreateRequest("))
        XCTAssertTrue(model.contains("DownloadTaskFileCreateRequest("))
        XCTAssertTrue(model.contains("createDownloadTaskFileResult(request)"))
        XCTAssertTrue(model.contains("controlDownloadTask(_ task: DownloadStationTask"))
        XCTAssertTrue(model.contains("DownloadTaskControlRequest(task: task, action: action)"))
        XCTAssertTrue(model.contains("deleteDownloadTask(_ task: DownloadStationTask)"))
        XCTAssertTrue(model.contains("deleteDownloadTasksResult("))
        XCTAssertTrue(model.contains("removeData: false"))
    }

    @MainActor
    func testBT搜索入口受能力门约束且复用单链接创建链路() throws {
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
            hasBTSearch: false
        )
        XCTAssertFalse(model.canSearchDownloadBT)

        model.downloadSnapshot = DownloadStationSnapshot(
            source: .official,
            tasks: [],
            hasBTSearch: true
        )
        XCTAssertFalse(model.canSearchDownloadBT, "没有服务仓储时不得显示可用搜索入口")

        let view = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadsView.swift"
        )
        let searchView = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadBTSearchView.swift"
        )

        XCTAssertTrue(view.contains("MobileDownloadBTSearchView"))
        XCTAssertTrue(view.contains("model.downloadSnapshot?.hasBTSearch == true"))
        XCTAssertTrue(view.contains(".disabled(!model.canSearchDownloadBT)"))
        XCTAssertTrue(searchView.contains("loadDownloadBTSearchCatalog()"))
        XCTAssertTrue(searchView.contains("searchDownloadBT(request)"))
        XCTAssertTrue(searchView.contains("titleFilter"))
        XCTAssertTrue(searchView.contains("selectedModuleIDs.isSubset(of: catalogModuleIDs)"))
        XCTAssertTrue(searchView.contains("model.createDownloadTask(uri: result.downloadURI)"))
        XCTAssertTrue(searchView.contains(".task(id: searchRepositoryIdentity)"))
        XCTAssertFalse(searchView.contains("UserDefaults"))
        XCTAssertFalse(searchView.contains("@AppStorage"))
        XCTAssertFalse(searchView.contains("@SceneStorage"))
    }

    func testBT搜索双语资源键完整且数量一致() throws {
        let en = try sourceFile(
            "../../Packages/DsmLocalization/Sources/Resources/en.lproj/Localizable.strings"
        )
        let zh = try sourceFile(
            "../../Packages/DsmLocalization/Sources/Resources/zh-Hans.lproj/Localizable.strings"
        )
        let enKeys = Set(Self.btSearchKeys(in: en))
        let zhKeys = Set(Self.btSearchKeys(in: zh))

        XCTAssertFalse(enKeys.isEmpty)
        XCTAssertEqual(enKeys, zhKeys)
        XCTAssertEqual(enKeys.count, 48)
    }

    @MainActor
    func testBT搜索只允许当前目录中的有效筛选并始终可关闭() throws {
        let searchModel = MobileDownloadBTSearchModel()
        searchModel.catalog = DownloadBTSearchCatalog(
            modules: [
                DownloadBTSearchModule(id: "enabled", title: "Enabled", isEnabled: true),
                DownloadBTSearchModule(id: "disabled", title: "Disabled", isEnabled: false)
            ],
            categories: [DownloadBTSearchCategory(id: "books", title: "Books")]
        )
        searchModel.keyword = "linux"
        XCTAssertTrue(searchModel.canSearch)

        searchModel.keyword = String(repeating: "a", count: 201)
        XCTAssertFalse(searchModel.canSearch)
        XCTAssertTrue(searchModel.hasInvalidKeyword)
        searchModel.keyword = "\nlinux"
        XCTAssertFalse(searchModel.canSearch)
        XCTAssertTrue(searchModel.hasInvalidKeyword)
        searchModel.keyword = "linux"
        searchModel.titleFilter = "line\nbreak"
        XCTAssertTrue(searchModel.hasInvalidTitleFilter)
        XCTAssertFalse(searchModel.canSearch)
        searchModel.titleFilter = "guide\t"
        XCTAssertTrue(searchModel.hasInvalidTitleFilter)
        XCTAssertFalse(searchModel.canSearch)
        searchModel.titleFilter = ""
        searchModel.moduleMode = .selected
        searchModel.selectedModuleIDs = ["stale"]
        XCTAssertFalse(searchModel.canSearch)
        searchModel.selectedModuleIDs = ["enabled"]
        XCTAssertTrue(searchModel.canSearch)
        searchModel.selectedCategoryID = "stale"
        XCTAssertFalse(searchModel.canSearch)
        searchModel.selectedCategoryID = "books"
        XCTAssertTrue(searchModel.canSearch)

        searchModel.hasSearched = true
        searchModel.results = [
            DownloadBTSearchResult(
                title: "Linux",
                sizeBytes: 1,
                downloadURI: "magnet:?xt=urn:btih:synthetic",
                peers: 1,
                seeds: 1,
                leeches: 0,
                provider: "Synthetic"
            )
        ]
        searchModel.keyword = "bsd"
        XCTAssertFalse(searchModel.hasSearched)
        XCTAssertTrue(searchModel.results.isEmpty, "条件变化后不得保留旧请求结果")

        searchModel.isSearching = true
        searchModel.close()
        XCTAssertFalse(searchModel.isSearching, "搜索期间关闭仍须立即取消并清理本地输入")

        let source = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadBTSearchView.swift"
        )
        XCTAssertFalse(source.contains(".interactiveDismissDisabled(searchModel.isSearching)"))
        XCTAssertTrue(source.contains(".disabled(searchModel.isSearching)"))
        XCTAssertTrue(source.contains("mobile.downloads.bt-search.catalog.empty.title"))
        XCTAssertTrue(source.contains("mobile.downloads.bt-search.catalog.empty.message"))
        XCTAssertTrue(source.contains("mobile.downloads.bt-search.input.invalid"))
        XCTAssertTrue(source.contains("safeUserMessage"))
        XCTAssertTrue(source.contains("catalog.categories.filter { $0.id != \"_allcat_\" }"))
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
        XCTAssertTrue(view.contains("MobileDownloadActivitySummaryView"))
        XCTAssertTrue(view.contains("mobile.downloads.activity.title"))
        XCTAssertTrue(view.contains("mobile.downloads.activity.emule-download"))
        XCTAssertTrue(view.contains("ui.3b14d1af77ab3e3e"))
        XCTAssertTrue(model.contains("hasActivitySummary: snapshot.hasActivitySummary"))
        XCTAssertTrue(model.contains("emuleDownloadBytesPerSecond: snapshot.emuleDownloadBytesPerSecond"))
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
        XCTAssertTrue(view.contains("mobile.downloads.create.file.action.hint"))
        XCTAssertTrue(view.contains("mobile.downloads.create.menu.hint"))
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

    private static func btSearchKeys(in source: String) -> [String] {
        source
            .split(separator: "\n")
            .compactMap { line -> String? in
                guard line.contains("\"mobile.downloads.bt-search.") else { return nil }
                return line.split(separator: "\"", maxSplits: 2).first.map(String.init)
            }
    }

    @MainActor
    private func waitForDownloadCreateFeedback(
        on model: MobileAppModel,
        kind: MobileDownloadCreateFeedbackKind,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        for _ in 0..<100 {
            if model.downloadCreateFeedback?.kind == kind {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for download create feedback \(kind)", file: file, line: line)
    }
}
