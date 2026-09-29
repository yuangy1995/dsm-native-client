import DsmCore
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class SynologyPhotosModelTests: XCTestCase {
    func test人物合并更新当前人物列表和筛选而不跳回时间轴() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.selectSection(.albums)
        await model.openCategory(.person)
        let target = try XCTUnwrap(model.collections.first)
        let sources = Array(model.collections.dropFirst())
        let before = await service.requests.count
        model.submitMutation(.mergePeople(target: target, sources: sources, name: "Combined"))
        while model.isManaging { await Task.yield() }
        XCTAssertEqual(model.selectedCategory, .person)
        XCTAssertEqual(model.section, .albums)
        XCTAssertEqual(model.collections.map(\.id), [31])
        XCTAssertEqual(model.collections.first?.name, "Combined")
        XCTAssertEqual(model.options.people.first?.id, 31)
        XCTAssertNil(model.pendingMutationID)
        let after = await service.requests.count
        XCTAssertEqual(before, after, "人物列表更新不重新请求最新照片")
    }

    func test人物改名原位更新卡片不插入相册() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.selectSection(.albums)
        await model.openCategory(.person)
        let original = try XCTUnwrap(model.collections.first)
        model.submitMutation(.renamePerson(original, name: "After"))
        while model.isManaging { await Task.yield() }
        XCTAssertEqual(model.collections.count, 2)
        XCTAssertEqual(model.collections.first?.id, original.id)
        XCTAssertEqual(model.collections.first?.name, "After")
        XCTAssertNil(model.selectedAlbum)
    }

    func test条件相册创建插入列表并保留条件类型() async throws {
        let service = PhotoUploadServiceStub()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.selectSection(.albums)
        model.submitMutation(.createConditionAlbum(name: "Fixture rule album", condition: .init()))
        while model.isManaging { await Task.yield() }
        XCTAssertEqual(model.collections.first?.id, 21)
        XCTAssertEqual(model.collections.first?.isConditional, true)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
    }

    func test条件规则读取与数量预览不提交修改() async throws {
        let service = PhotoUploadServiceStub()
        let model = SynologyPhotosModel(repository: service)
        await model.refresh()
        let condition = try await model.albumCondition(id: 21)
        let count = try await model.conditionItemCount(condition)
        let suggestions = try await model.conditionSuggestions(keyword: "Fixture")
        XCTAssertEqual(count, 3)
        XCTAssertEqual(suggestions["general_tag"]?.count, 1)
        let commands = await service.commands
        XCTAssertTrue(commands.isEmpty)
    }

    func test目录导入过滤去重且保留原始来源授权() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested")
        let hidden = root.appendingPathComponent(".hidden")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        let photo = nested.appendingPathComponent("photo.png")
        let movie = root.appendingPathComponent("movie.mov")
        for url in [photo, movie, root.appendingPathComponent("notes.txt"), hidden.appendingPathComponent("private.png")] {
            try Data([1, 2, 3]).write(to: url)
        }
        try Data().write(to: root.appendingPathComponent("empty.png"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.png"), withDestinationURL: photo)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        let result = try PhotoUploadPreparation.prepare([root, nested, photo])
        XCTAssertEqual(Set(result.files.map { $0.url.resolvingSymlinksInPath() }), Set([photo, movie].map { $0.resolvingSymlinksInPath() }))
        XCTAssertEqual(result.files.count, 2)
        XCTAssertEqual(result.skippedCount, 4)
        XCTAssertTrue(result.includesDirectory)
        XCTAssertEqual(result.files.first { $0.url.lastPathComponent == "photo.png" }?.directoryComponents, [root.lastPathComponent, "nested"])
        XCTAssertTrue(result.files.allSatisfy { $0.size == 3 && $0.sourceAccess?.url == root })
        XCTAssertTrue(result.files[0].sourceAccess === result.files[1].sourceAccess)
        var retained: PhotoUploadFile? = result.files.first
        weak var access = retained?.sourceAccess
        XCTAssertNotNil(access)
        retained = nil
        XCTAssertNotNil(access, "原始确认快照仍持有授权")
    }

    func test目录导入不完整读取失败且空目录不产生上传() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = try PhotoUploadPreparation.prepare([root])
        XCTAssertTrue(empty.files.isEmpty)
        XCTAssertTrue(empty.includesDirectory)
        XCTAssertThrowsError(try PhotoUploadPreparation.prepare([root.appendingPathComponent("missing.png")]))
        XCTAssertThrowsError(try PhotoUploadPreparation.prepare([URL(string: "https://example.invalid/fixture.png")!]))
    }

    func test导入来源授权随最后一个队列快照释放() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: root.appendingPathComponent("photo.png"))
        var prepared: PhotoUploadPreparation? = try PhotoUploadPreparation.prepare([root])
        weak var access = prepared?.files.first?.sourceAccess
        var queued = prepared?.files.first
        prepared = nil
        XCTAssertEqual(queued?.sourceAccess?.url, root)
        XCTAssertNotNil(access)
        queued = nil
        XCTAssertNil(access)
    }

    func test目录上传逐级创建且同批文件复用目录() async throws {
        let service = PhotoUploadServiceStub()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        var files = makeUploadFiles()
        for index in files.indices { files[index].directoryComponents = ["Trip", "Day"] }
        model.isSelecting = true
        model.enqueueUploads(files, album: nil, folder: .init(id: 9, name: "Target"), preserveDirectories: true)
        XCTAssertFalse(model.isSelecting, "上传后允许正常打开照片预览")
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed])
        let commands = await service.commands
        XCTAssertEqual(commands.count, 4)
        guard case .createFolder(let parent, let name) = commands[0] else { return XCTFail("应先建立首层目录") }
        XCTAssertEqual(parent, 9); XCTAssertEqual(name, "Trip")
        guard case .createFolder(let nestedParent, let nestedName) = commands[1] else { return XCTFail("应建立第二层目录") }
        XCTAssertEqual(nestedParent, 1001); XCTAssertEqual(nestedName, "Day")
        for command in commands.suffix(2) {
            guard case .upload(_, _, _, let folder) = command else { return XCTFail("目录只建立一次") }
            XCTAssertEqual(folder, 1002)
        }
    }

    func test目录上传复用同名子目录且不同批次不串目标() async throws {
        let service = PhotoUploadServiceStub()
        await service.addFolder(.init(id: 40, name: "Trip", parentID: 9))
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        var file = makeUploadFiles()[0]
        file.directoryComponents = ["Trip"]
        model.enqueueUploads([file], album: nil, folder: .init(id: 9, name: "Target"), preserveDirectories: true)
        await waitForManagement(model)
        model.enqueueUploads([file], album: nil, folder: .init(id: 88, name: "Other"), preserveDirectories: true)
        await waitForManagement(model)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 3)
        guard case .upload(_, _, _, let firstFolder) = commands[0] else { return XCTFail("已有目录不应重建") }
        XCTAssertEqual(firstFolder, 40)
        guard case .createFolder(let parent, _) = commands[1] else { return XCTFail("新目标独立解析") }
        XCTAssertEqual(parent, 88)
    }

    func test目录创建未知只核对后继续且不会提前上传() async throws {
        let service = PhotoUploadServiceStub()
        await service.makeFirstUploadPending()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        var file = makeUploadFiles()[0]
        file.directoryComponents = ["Trip"]
        model.enqueueUploads([file], album: .init(id: 30, name: "Album"), folder: nil, preserveDirectories: true)
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.first?.state, .pendingReview)
        let before = await service.commands
        XCTAssertEqual(before.count, 1)
        guard case .createFolder(let parent, _) = before[0] else { return XCTFail("先创建目录") }
        XCTAssertEqual(parent, 1)
        await service.resolveUpload()
        model.reviewPendingMutation()
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.first?.state, .completed)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 3)
        XCTAssertEqual(commands.filter { if case .createFolder = $0 { true } else { false } }.count, 1)
        guard case .addToAlbum(let album, _) = commands.last else { return XCTFail("最终加入相册") }
        XCTAssertEqual(album, 30)
    }

    func test关闭层级选项继续使用汇总上传() async throws {
        let service = PhotoUploadServiceStub()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        var file = makeUploadFiles()[0]
        file.directoryComponents = ["Trip"]
        model.enqueueUploads([file], album: nil, folder: .init(id: 9, name: "Target"))
        await waitForManagement(model)
        let commands = await service.commands
        XCTAssertEqual(commands.count, 1)
        guard case .upload(_, _, _, let folder) = commands[0] else { return XCTFail("汇总不建目录") }
        XCTAssertEqual(folder, 9)
    }

    func test多文件上传逐项加入同一相册且不刷新时间轴() async throws {
        let service = PhotoUploadServiceStub()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        let before = await service.pageReads
        let files = makeUploadFiles()
        let album = SynologyPhotoCollection(id: 30, name: "Fixture album")
        model.enqueueUploads(files, album: album, folder: nil)
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed])
        XCTAssertEqual(model.uploadQueue.map(\.progress), [1, 1])
        let commands = await service.commands
        XCTAssertEqual(commands.count, 4)
        guard case .upload(let url, _, _, nil) = commands[0] else { return XCTFail("先上传原件") }
        XCTAssertEqual(url, files[0].url)
        guard case .addToAlbum(let id, let photos) = commands[1] else { return XCTFail("上传后加入相册") }
        XCTAssertEqual(id, 30)
        XCTAssertEqual(photos.first?.id, model.uploadQueue.first?.uploadedPhoto?.id)
        let after = await service.pageReads
        XCTAssertEqual(before, after)
        XCTAssertNil(model.pendingMutationID)
    }

    func test加入相册失败后只重试加入不重复上传() async throws {
        let service = PhotoUploadServiceStub()
        await service.rejectNextAlbumAddition()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        model.enqueueUploads([makeUploadFiles()[0]], album: .init(id: 30, name: "Fixture"), folder: nil)
        await waitForManagement(model)
        let entry = try XCTUnwrap(model.uploadQueue.first)
        XCTAssertEqual(entry.state, .failed)
        XCTAssertNotNil(entry.uploadedPhoto)
        model.retryUpload(entry.id)
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.first?.state, .completed)
        let commands = await service.commands
        XCTAssertEqual(commands.filter { if case .upload = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(commands.filter { if case .addToAlbum = $0 { true } else { false } }.count, 2)
    }

    func test上传未知只核对成功后自动继续后续文件() async throws {
        let service = PhotoUploadServiceStub()
        await service.makeFirstUploadPending()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        model.enqueueUploads(makeUploadFiles(), album: nil, folder: .init(id: 9, name: "Fixture folder"))
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.pendingReview, .queued])
        model.retryUpload(model.uploadQueue[0].id)
        let initialWrites = await service.commands.count
        XCTAssertEqual(initialWrites, 1)
        await service.resolveUpload()
        model.reviewPendingMutation()
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed])
        let commands = await service.commands
        XCTAssertEqual(commands.count, 2, "核对不重新上传第一项")
        for command in commands {
            guard case .upload(_, _, _, let folder) = command else { return XCTFail("仅上传") }
            XCTAssertEqual(folder, 9)
        }
    }

    func test停止队列完成当前文件且未开始项可重试() async throws {
        let service = PhotoUploadServiceStub()
        await service.holdFirstUpload()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        model.enqueueUploads(makeUploadFiles(), album: nil, folder: nil)
        await service.waitUntilHeld()
        model.stopUploadQueue()
        let reads = await service.pageReads
        let accessReads = await service.accessReads
        await model.refresh()
        let refreshedReads = await service.pageReads
        let unchangedAccessReads = await service.accessReads
        XCTAssertEqual(reads + 1, refreshedReads, "上传时允许刷新图库内容")
        XCTAssertEqual(accessReads, unchangedAccessReads, "上传时刷新不能清空访问状态")
        await service.releaseUpload()
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .cancelled])
        let count = await service.commands.count
        XCTAssertEqual(count, 1)
        model.retryUpload(model.uploadQueue[1].id)
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed])
        model.clearFinishedUploads()
        XCTAssertTrue(model.uploadQueue.isEmpty)
    }

    func test上传期间离开图库重新浏览不取消队列或改变上传目标() async throws {
        let service = PhotoUploadServiceStub()
        await service.holdFirstUpload()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        model.enqueueUploads(makeUploadFiles(), album: nil, folder: .init(id: 9, name: "Fixture target"))
        await service.waitUntilHeld()
        XCTAssertFalse(model.isBrowsingBlocked)
        model.leaveGallery()
        await model.selectSection(.folders)
        await model.open(.init(id: 88, name: "Other fixture folder"))
        XCTAssertEqual(model.folderHistory.last?.id, 88)
        let accessReads = await service.accessReads
        XCTAssertEqual(accessReads, 1)
        XCTAssertTrue(model.isUploading)
        await service.releaseUpload()
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed])
        XCTAssertTrue(model.items.isEmpty, "上传到原目标的照片不能插入正在浏览的其他文件夹")
        let commands = await service.commands
        XCTAssertEqual(commands.count, 2)
        for command in commands {
            guard case .upload(_, _, _, let folder) = command else { return XCTFail("只应上传") }
            XCTAssertEqual(folder, 9)
        }
    }

    func test上传下一文件不使在途图库读取失效() async throws {
        let service = PhotoUploadServiceStub()
        await service.holdFirstUpload()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        model.enqueueUploads(makeUploadFiles(), album: nil, folder: nil)
        await service.waitUntilHeld()
        await service.holdNextPage()
        let read = Task { await model.refresh() }
        await service.waitUntilPageHeld()
        await service.releaseUpload()
        await waitForManagement(model)
        XCTAssertTrue(model.isLoading)
        await service.releasePage()
        await read.value
        XCTAssertFalse(model.isLoading)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed])
    }

    func test单项上传预检失败不阻断其他文件() async throws {
        let service = PhotoUploadServiceStub()
        await service.rejectFirstPreparation()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        model.enqueueUploads(makeUploadFiles(), album: nil, folder: nil)
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.failed, .completed])
        XCTAssertNil(model.pendingMutationID)
        let count = await service.commands.count
        XCTAssertEqual(count, 1)
    }

    private func makeUploadFiles() -> [PhotoUploadFile] {
        (1...2).map { index in
            PhotoUploadFile(url: URL(fileURLWithPath: "/synthetic/fixture-\(index).png"), size: 128,
                            modifiedAt: Date(timeIntervalSince1970: 100))
        }
    }

    private func waitForManagement(_ model: SynologyPhotosModel) async {
        for _ in 0..<2000 where model.isManaging { await Task.yield() }
        XCTAssertFalse(model.isManaging)
    }

    func test相对时间部分完成继续只处理原目标剩余照片() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement(partial: true)
        let model = SynologyPhotosModel(repository: service, pageSize: 2, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        let original = model.items
        model.submitMutation(.shiftDates(original, seconds: 3_600))
        await waitForManagement(model)
        XCTAssertEqual(model.items[0].takenAt, original[0].takenAt.addingTimeInterval(3_600))
        XCTAssertEqual(model.items[1].takenAt, original[1].takenAt)
        guard case .shiftDates(let remaining, let seconds) = model.retryableManagementMutation else { return XCTFail("保留剩余目标") }
        XCTAssertEqual(remaining.map(\.id), [original[1].id])
        XCTAssertEqual(seconds, 3_600)
        model.selectGroup([model.items[0]])
        model.continuePartialManagement()
        await waitForManagement(model)
        XCTAssertEqual(model.items.map(\.takenAt), original.map { $0.takenAt.addingTimeInterval(3_600) })
        XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        XCTAssertNil(model.retryableManagementMutation)
        let commands = await service.managementCommands
        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands.last?.photos.map(\.id), [original[1].id])
    }

    func test继续剩余照片预检失败仍保留原目标供再次继续() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement(partial: true)
        let model = SynologyPhotosModel(repository: service, pageSize: 2, deletionReviewDelay: { _ in })
        await model.refresh()
        model.submitMutation(.shiftDates(model.items, seconds: 60))
        await waitForManagement(model)
        let expected = try XCTUnwrap(model.retryableManagementMutation)
        await service.failNextManagementPreparation()
        model.continuePartialManagement()
        await waitForManagement(model)
        XCTAssertEqual(model.retryableManagementMutation, expected)
        model.continuePartialManagement()
        await waitForManagement(model)
        XCTAssertNil(model.retryableManagementMutation)
        let commands = await service.managementCommands
        XCTAssertEqual(commands.count, 2, "预检失败不能发写请求")
        XCTAssertEqual(commands.last, expected)
    }

    func test新标签部分应用后继续不再创建且更新已有标签列表() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement(partial: true)
        let model = SynologyPhotosModel(repository: service, pageSize: 2, deletionReviewDelay: { _ in })
        await model.refresh()
        model.submitMutation(.createTag(name: "Fixture tag", photos: model.items))
        await waitForManagement(model)
        XCTAssertEqual(model.options.tags, [.init(id: 8, name: "Fixture tag")])
        guard case .addTags(let remaining, let ids) = model.retryableManagementMutation else { return XCTFail("继续只应用已有标签") }
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(ids, [8])
        model.continuePartialManagement()
        await waitForManagement(model)
        let commands = await service.managementCommands
        XCTAssertEqual(commands.filter { if case .createTag = $0 { true } else { false } }.count, 1)
        XCTAssertEqual(commands.filter { if case .addTags = $0 { true } else { false } }.count, 1)
        XCTAssertNil(model.retryableManagementMutation)
    }

    func test编辑自动回读不刷新月份且保留选择() async throws {
        let repository = DatePhotoServiceStub()
        await repository.enableManagement()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        model.selectGroup(model.items)
        let targets = model.selectedPhotos
        let requestsBefore = await repository.requests.count
        model.submitMutation(.edit(targets, .rating(4)))
        for _ in 0..<1000 where model.isManaging { await Task.yield() }
        XCTAssertFalse(model.isManaging)
        XCTAssertNil(model.pendingMutationID)
        XCTAssertEqual(model.items.map(\.rating), [4, 4])
        XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        XCTAssertEqual(model.selectedPhotos.map(\.id), targets.map(\.id))
        let requestsAfter = await repository.requests.count
        XCTAssertEqual(requestsBefore, requestsAfter)
        let writes = await repository.managementWriteCount
        XCTAssertEqual(writes, 1)
    }

    func test新增写入未知结果只保留核查而不会重复执行() async throws {
        let repository = DatePhotoServiceStub()
        await repository.enableManagement(pending: true)
        let model = SynologyPhotosModel(repository: repository, pageSize: 2, deletionReviewDelay: { _ in })
        await model.refresh()
        model.submitMutation(.edit(model.items, .rating(3)))
        for _ in 0..<1000 where model.isManaging { await Task.yield() }
        XCTAssertNotNil(model.pendingMutationID)
        model.submitMutation(.edit(model.items, .rating(2)))
        model.reviewPendingMutation()
        for _ in 0..<1000 where model.isManaging { await Task.yield() }
        let writes = await repository.managementWriteCount
        XCTAssertEqual(writes, 1)
        XCTAssertNotNil(model.pendingMutationID)
    }

    func test批量保存遇到同名原件不覆盖且不刷新图库() async throws {
        let photo = Self.photo
        let data = Data("original-fixture".utf8)
        let repository = PhotoServiceStub(pages: [[photo]], saveData: data)
        let model = SynologyPhotosModel(repository: repository)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let existing = directory.appendingPathComponent(photo.filename)
        let previous = Data("keep-existing".utf8)
        try previous.write(to: existing)
        await model.refresh()
        model.selectGroup(model.items)
        model.saveSelection(to: directory)
        for _ in 0..<1000 where model.isSaving { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(try Data(contentsOf: existing), previous)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(files.first { $0 != existing })), data)
        let requests = await repository.pageRequestCount
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(model.items.map(\.id), [photo.id])
    }

    func test时间轴按日期定位且不依赖时间轴数量() async {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2)
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        XCTAssertEqual(model.items.map(\.id.unitID), [4, 5])
        await model.jumpToMonth(.init(year: 2026, month: 9))
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2])
        let requests = await repository.requests
        XCTAssertEqual(requests.map(\.offset), [0, 0, 0])
        XCTAssertEqual(requests[1].end, Self.timestamp(2014, 9, 1) - 1)
        XCTAssertFalse(model.hasPrevious)
    }

    func test向上按时间补齐同月多页且向下继续原来的分页() async {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2)
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        await model.loadPreviousPage()
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2, 3, 4, 5])
        XCTAssertFalse(model.hasPrevious)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2, 3, 4, 5, 6])
        let requests = await repository.requests
        XCTAssertEqual(requests.map(\.offset), [0, 0, 0, 2, 2])
        XCTAssertEqual(requests[2].start, Self.timestamp(2014, 9, 1))
        XCTAssertEqual(requests[2].end, min(requests[0].end, Self.timestamp(2026, 10, 1) - 1))
        XCTAssertEqual(requests[4].end, requests[1].end)
    }

    func test搜索跳转与向上加载保留关键词() async {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2)
        model.searchText = "sample"
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        XCTAssertEqual(model.items.first?.id.unitID, 4)
        await model.loadPreviousPage()
        let requests = await repository.requests
        XCTAssertTrue(requests.allSatisfy { $0.keyword == "sample" })
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2, 3, 4, 5])
    }

    func test向前失败保留时间边界且重试不重复照片() async {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2)
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        await repository.failNextPage()
        await model.loadPreviousPage()
        XCTAssertNotNil(model.previousPageErrorMessage)
        XCTAssertEqual(model.previousMonthID, 201408)
        XCTAssertEqual(model.items.map(\.id.unitID), [4, 5])
        await model.loadPreviousPage()
        XCTAssertNil(model.previousPageErrorMessage)
        XCTAssertEqual(model.items.map(\.id.unitID), [1, 2, 3, 4, 5])
    }

    func test向前分页迟到不能覆盖刷新结果且并发触发只请求一次() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], [], []], days: [
            .init(year: 2026, month: 9, day: 1, itemCount: 1),
            .init(year: 2013, month: 1, day: 1, itemCount: 1)
        ])
        let model = SynologyPhotosModel(repository: repository, pageSize: 1)
        await model.refresh()
        await model.jumpToMonth(.init(year: 2013, month: 1))
        await repository.holdNextPage()
        let request = Task { await model.loadPreviousPage() }
        await repository.waitForHeldPage()
        await model.loadPreviousPage()
        let count = await repository.pageRequestCount
        XCTAssertEqual(count, 3)
        await model.refresh()
        await repository.releasePage([Self.photo])
        await request.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasPrevious)
        XCTAssertFalse(model.isLoadingPrevious)
    }

    func test批量勾选支持范围日期组且跳转清空选择() async {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 6)
        await model.refresh()
        model.toggleSelection(model.items[1])
        model.toggleSelection(model.items[4], extending: true)
        XCTAssertEqual(Set(model.selectedPhotos.map(\.id.unitID)), [2, 3, 4, 5])
        model.selectGroup(Array(model.items.prefix(3)))
        XCTAssertEqual(Set(model.selectedPhotos.map(\.id.unitID)), [1, 2, 3, 4, 5])
        model.selectGroup(Array(model.items.prefix(3)))
        XCTAssertEqual(Set(model.selectedPhotos.map(\.id.unitID)), [4, 5])
        await model.jumpToMonth(.init(year: 2014, month: 8))
        XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
        XCTAssertFalse(model.isSelecting)
    }

    func test批量删除自动核对保留月份并修正下一页偏移() async throws {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        let targets = model.items
        model.requestDeletion(targets)
        try await waitFor { !model.isCheckingDeletion }
        XCTAssertEqual(model.deletionCandidates, targets)
        let before = await repository.deleteIDs
        XCTAssertTrue(before.isEmpty, "确认之前不能删除")
        model.confirmDeletion(targets)
        model.confirmDeletion(targets)
        try await waitFor { !model.isDeleting }
        XCTAssertNil(model.pendingDeletionPhoto)
        XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        XCTAssertEqual(model.previousMonthID, 201408)
        XCTAssertTrue(model.items.isEmpty)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id.unitID), [6], "删除两项后不跳过下一张")
        let requests = await repository.requests
        XCTAssertEqual(requests.map(\.offset), [0, 0, 0], "不得刷新到最新照片")
        let deletes = await repository.deleteIDs
        XCTAssertEqual(deletes, [4, 5], "每项只提交一次")
        let reviews = await repository.reviewIDs
        XCTAssertEqual(reviews, [4, 5, 4, 5])
    }

    func test删除向上补入照片不减少原分页偏移() async throws {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        await model.loadPreviousPage()
        model.confirmDeletion(model.items[0])
        try await waitFor { !model.isDeleting }
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id.unitID), [2, 3, 4, 5, 6])
        let requests = await repository.requests
        XCTAssertEqual(requests.last?.offset, 2)
        XCTAssertEqual(model.selectedTimelineMonthID, 201408)
    }

    func test批量确认绑定预检快照而不是后来的选择() async throws {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 6, deletionReviewDelay: { _ in })
        await model.refresh()
        let targets = Array(model.items.prefix(2))
        model.requestDeletion(targets)
        try await waitFor { !model.isCheckingDeletion }
        model.toggleSelection(model.items[4])
        model.confirmDeletion([model.items[4]])
        XCTAssertFalse(model.isDeleting)
        model.confirmDeletion(targets)
        try await waitFor { !model.isDeleting }
        let deletes = await repository.deleteIDs
        XCTAssertEqual(deletes, [1, 2])
        XCTAssertTrue(model.items.contains { $0.id.unitID == 5 })
    }

    func test批量预检任一目标失败不会写入() async throws {
        let repository = DatePhotoServiceStub()
        await repository.rejectPreparation(2)
        let model = SynologyPhotosModel(repository: repository, pageSize: 6, deletionReviewDelay: { _ in })
        await model.refresh()
        model.requestDeletion(Array(model.items.prefix(2)))
        try await waitFor { !model.isCheckingDeletion }
        XCTAssertTrue(model.deletionCandidates.isEmpty)
        XCTAssertNotNil(model.deletionError)
        let deletes = await repository.deleteIDs
        XCTAssertTrue(deletes.isEmpty)
    }

    func test持续核对失败保留原件且只重试读取() async throws {
        let repository = DatePhotoServiceStub()
        await repository.failReviews(true)
        let model = SynologyPhotosModel(repository: repository, pageSize: 2, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        let target = model.items[0]
        model.confirmDeletion(target)
        try await waitFor { !model.isDeleting }
        XCTAssertEqual(model.pendingDeletionPhoto, target)
        XCTAssertTrue(model.items.contains(target))
        XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        model.confirmDeletion(target)
        XCTAssertFalse(model.isDeleting)
        await repository.failReviews(false)
        await model.reviewPendingDeletion()
        XCTAssertNil(model.pendingDeletionPhoto)
        XCTAssertEqual(model.items.map(\.id.unitID), [5])
        XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        let deletes = await repository.deleteIDs
        XCTAssertEqual(deletes, [4])
        let requests = await repository.requests
        XCTAssertEqual(requests.count, 2)
    }

    func test批量中途拒绝保留未提交项并确认已提交项() async throws {
        let repository = DatePhotoServiceStub()
        await repository.rejectDeletion(2)
        let model = SynologyPhotosModel(repository: repository, pageSize: 6, deletionReviewDelay: { _ in })
        await model.refresh()
        let targets = Array(model.items.prefix(3))
        model.requestDeletion(targets)
        try await waitFor { !model.isCheckingDeletion }
        model.confirmDeletion(targets)
        try await waitFor { !model.isDeleting }
        XCTAssertEqual(model.items.map(\.id.unitID), [2, 3, 4, 5, 6])
        XCTAssertNotNil(model.deletionError)
        let deletes = await repository.deleteIDs
        XCTAssertEqual(deletes, [1, 2])
        XCTAssertNil(model.pendingDeletionPhoto)
    }

    func test关闭模块停止核对且保留待核对目标不重复写入() async throws {
        let repository = DatePhotoServiceStub()
        let model = SynologyPhotosModel(repository: repository, pageSize: 2,
            deletionReviewDelay: { _ in try await Task.sleep(for: .seconds(60)) })
        await model.refresh()
        let target = model.items[0]
        model.confirmDeletion(target)
        try await waitFor { model.pendingDeletionPhoto != nil }
        await model.selectSection(.folders)
        XCTAssertEqual(model.section, .timeline, "删除期间不能把原图库切换为另一查询")
        model.setModuleEnabled(false)
        try await waitFor { !model.isDeleting }
        XCTAssertEqual(model.pendingDeletionPhoto, target)
        XCTAssertTrue(model.items.isEmpty)
        let deletes = await repository.deleteIDs
        let reviews = await repository.reviewIDs
        XCTAssertEqual(deletes, [1])
        XCTAssertTrue(reviews.isEmpty)
    }

    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<1000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("异步照片操作未在限定时间完成")
    }

    private static func timestamp(_ year: Int, _ month: Int, _ day: Int) -> Int {
        Int(Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: month, day: day))!.timeIntervalSince1970)
    }

    func test筛选候选失败不污染照片列表的错误状态() async {
        let repository = PhotoServiceStub(pages: [[Self.photo]])
        let model = SynologyPhotosModel(repository: repository)
        await model.refresh()
        await model.loadFilterOptions()
        XCTAssertNotNil(model.filterOptionsErrorMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.isLoadingFilterOptions)
        XCTAssertEqual(model.items, [Self.photo])
    }
    func test自动分页每次只读取下一页且重复结果停住() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], [Self.photo], []])
        let model = SynologyPhotosModel(repository: repository, pageSize: 1)
        await model.loadIfNeeded()
        let initialCount = await repository.pageRequestCount
        XCTAssertEqual(initialCount, 1)
        await model.loadNextPageAutomatically()
        XCTAssertNotNil(model.errorMessage)
        await model.loadNextPageAutomatically()
        let count = await repository.pageRequestCount
        XCTAssertEqual(count, 2)
    }

    func test时间线按日期分组且没有普通相册也显示系统分类() async {
        let repository = PhotoServiceStub(pages: [[Self.photo]])
        let model = SynologyPhotosModel(repository: repository)
        await model.refresh()
        XCTAssertEqual(model.datedGroups.count, 1)
        XCTAssertEqual(model.datedGroups.first?.photos, [Self.photo])
        await model.selectSection(.albums)
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertEqual(model.availableCategories.count, 6)
        XCTAssertTrue(model.showsCategories)
    }
    func test刷新清除已删除照片而不是按数量合并() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], []])
        let model = SynologyPhotosModel(repository: repository)
        await model.refresh()
        XCTAssertEqual(model.items, [Self.photo])
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.errorMessage)
    }

    func test旧刷新迟到不能恢复已删除照片() async {
        let repository = PhotoServiceStub(pages: [[]], holdsFirstPage: true)
        let model = SynologyPhotosModel(repository: repository)
        let first = Task { await model.refresh() }
        await repository.waitForHeldPage()
        await model.refresh()
        XCTAssertTrue(model.items.isEmpty)
        await repository.releasePage([Self.photo])
        await first.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func test离开页面后旧请求不得写回() async {
        let repository = PhotoServiceStub(pages: [], holdsFirstPage: true)
        let model = SynologyPhotosModel(repository: repository)
        let request = Task { await model.refresh() }
        await repository.waitForHeldPage()
        model.cancel()
        await repository.releasePage([Self.photo])
        await request.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
    }

    func test空时间线不额外扫描或读取媒体() async {
        let repository = PhotoServiceStub(pages: [], days: [])
        let model = SynologyPhotosModel(repository: repository)
        await model.refresh()
        let count = await repository.pageRequestCount
        XCTAssertEqual(count, 0)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertTrue(model.items.isEmpty)
    }

    func test翻页沿用套件偏移而不是去重后数量() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], [Self.photo], []])
        let model = SynologyPhotosModel(repository: repository, pageSize: 1)
        await model.refresh()
        await model.loadMore()
        XCTAssertEqual(model.items.count, 1)
        await model.loadMore()
        let offsets = await repository.requestedOffsets
        XCTAssertEqual(offsets, [0, 1, 2])
        XCTAssertFalse(model.hasMore)
    }

    func test未加载失败可以重试() async {
        let repository = PhotoServiceStub(pages: [[Self.photo]], failsFirstAccess: true)
        let model = SynologyPhotosModel(repository: repository)
        await model.loadIfNeeded()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.hasLoaded)
        await model.loadIfNeeded()
        XCTAssertEqual(model.items, [Self.photo])
        XCTAssertNil(model.errorMessage)
    }

    func test重新进入页面重新核对而不永久保留旧照片() async {
        let repository = PhotoServiceStub(pages: [[Self.photo], []])
        let model = SynologyPhotosModel(repository: repository)
        await model.loadIfNeeded()
        XCTAssertEqual(model.items.count, 1)
        model.cancel()
        await model.loadIfNeeded()
        XCTAssertTrue(model.items.isEmpty)
        let count = await repository.pageRequestCount
        XCTAssertEqual(count, 2)
    }

    func test保存先写临时副本且面板确认后可替换已有文件() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("photo.jpg")
        try Data("old".utf8).write(to: destination)
        let expected = Data(repeating: 0x7f, count: 128)
        let repository = PhotoServiceStub(pages: [], saveData: expected)
        let model = SynologyPhotosModel(repository: repository)
        model.save(Self.photo, to: destination)
        for _ in 0..<200 where model.isSaving { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(try Data(contentsOf: destination), expected)
        let requested = await repository.savedURLs
        XCTAssertEqual(requested.count, 1)
        XCTAssertNotEqual(requested.first, destination)
        XCTAssertEqual(requested.first?.deletingLastPathComponent().standardizedFileURL, FileManager.default.temporaryDirectory.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(requested.first).path))
    }

    func test照片下载失败不覆盖用户原文件() async throws {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data("old".utf8).write(to: destination)
        defer { try? FileManager.default.removeItem(at: destination) }
        let repository = PhotoServiceStub(pages: [])
        let model = SynologyPhotosModel(repository: repository)
        model.save(Self.photo, to: destination)
        for _ in 0..<200 where model.isSaving { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(try Data(contentsOf: destination), Data("old".utf8))
    }

    private static let photo = SynologyPhoto(
        id: SynologyPhotoID(profileID: UUID(), space: .personal, unitID: 7),
        filename: "sample.jpg", sizeBytes: 128,
        takenAt: Date(timeIntervalSince1970: 10), indexedAt: Date(timeIntervalSince1970: 20),
        folderID: 9, mediaType: "photo"
    )
}

/// 根据实际时间区间和页内偏移筛选，数量故意不等于列表条数，防止再次按数量定位。
actor DatePhotoServiceStub: SynologyPhotosServing {
    private var sharingAccess: SynologyPhotoLinkAccess = .download
    private var sharingReadFails = false
    private var sharingRole = "view"
    private var sharingRecipientsFail = false
    private var sharingMembersEmpty = false
    func configureSharing(_ access: SynologyPhotoLinkAccess, fails: Bool = false, role: String = "view", recipientsFail: Bool = false, empty: Bool = false) {
        sharingAccess = access; sharingReadFails = fails; sharingRole = role; sharingRecipientsFail = recipientsFail; sharingMembersEmpty = empty
    }
    func albumSharing(id: Int) async throws -> SynologyPhotoSharingState {
        if sharingReadFails { throw URLError(.notConnectedToInternet) }
        return .init(access: sharingAccess, url: sharingAccess == .disabled ? nil : URL(string: "https://example.invalid/share/fixture"),
                     hasPassword: true, hasExpiration: true, revision: "fixture-revision", members: sharingMembersEmpty ? [] : [.init(recipient: .init(id: .init(type: "user", value: .integer(22)), name: "Fixture member"), role: sharingRole)])
    }
    func sharingRecipients() async throws -> [SynologyPhotoShareRecipient] {
        if sharingRecipientsFail { throw URLError(.notConnectedToInternet) }
        return [.init(id: .init(type: "user", value: .integer(22)), name: "Fixture member"),
         .init(id: .init(type: "group", value: .integer(22)), name: "Fixture group")]
    }
    private var people: [SynologyPhotoCollection] = [.init(id: 31, name: "Fixture person", itemCount: 2), .init(id: 32, name: "Another person", itemCount: 1)]
    private var peopleReadFails = false
    func configurePeople(empty: Bool = false, fails: Bool = false) { if empty { people = [] }; peopleReadFails = fails }
    func managementPeople() async throws -> [SynologyPhotoCollection] {
        if peopleReadFails { throw URLError(.notConnectedToInternet) }
        return people
    }
    func categoryItems(_ category: SynologyPhotoCategory, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        category == .person ? Array(people.dropFirst(offset).prefix(limit)) : []
    }
    private var features: Set<SynologyPhotosManagementFeature> = []
    private var pendingManagement = false
    var managementWriteCount = 0
    private var managementCommand: SynologyPhotosMutation?
    var managementCommands: [SynologyPhotosMutation] = []
    private var partialManagement = false
    private var failsManagementPreparation = false
    func failNextManagementPreparation() { failsManagementPreparation = true }
    func enableManagement(pending: Bool = false, partial: Bool = false) { features = Set(SynologyPhotosManagementFeature.allCases); pendingManagement = pending; partialManagement = partial }
    func managementFeatures() async -> Set<SynologyPhotosManagementFeature> { features }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws {
        if failsManagementPreparation { failsManagementPreparation = false; throw URLError(.notConnectedToInternet) }
    }
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        managementWriteCount += 1; managementCommand = mutation; managementCommands.append(mutation)
        return .init(state: .pendingReview)
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        guard !pendingManagement, let command = managementCommand else { return .init(state: .pendingReview) }
        if case .renamePerson(let original, let name) = command {
            let person = SynologyPhotoCollection(id: original.id, name: name, itemCount: original.itemCount)
            if let index = people.firstIndex(where: { $0.id == person.id }) { people[index] = person }
            return .init(state: .confirmed, person: person)
        }
        if case .mergePeople(let target, let sources, let name) = command {
            let person = SynologyPhotoCollection(id: target.id, name: name, itemCount: 2)
            people.removeAll { entry in sources.contains { $0.id == entry.id } }
            if let index = people.firstIndex(where: { $0.id == person.id }) { people[index] = person }
            return .init(state: .confirmed, person: person, removedPersonIDs: sources.map(\.id))
        }
        var photos = command.photos
        if case .edit(_, .rating(let value)) = command { for index in photos.indices { photos[index].rating = value } }
        if case .shiftDates(_, let seconds) = command {
            photos = photos.map { photo in
                SynologyPhoto(id: photo.id, filename: photo.filename, sizeBytes: photo.sizeBytes,
                    takenAt: photo.takenAt.addingTimeInterval(Double(seconds)), indexedAt: photo.indexedAt,
                    folderID: photo.folderID, mediaType: photo.mediaType)
            }
            if partialManagement {
                partialManagement = false
                return .init(state: .partial, photos: Array(photos.prefix(1)), completedCount: 1)
            }
        }
        if case .createTag(let name, _) = command {
            let tag = SynologyPhotoFilterChoice(id: 8, name: name)
            if partialManagement { partialManagement = false; return .init(state: .partial, tag: tag) }
            for index in photos.indices { photos[index].tags = [tag] }
            return .init(state: .confirmed, photos: photos, completedCount: photos.count, tag: tag)
        }
        return .init(state: .confirmed, photos: photos, completedCount: photos.count)
    }
    struct Request {
        let start: Int
        let end: Int
        let offset: Int
        let keyword: String?
    }
    var requests: [Request] = []
    var deleteIDs: [Int] = []
    var reviewIDs: [Int] = []
    private var deleted: Set<Int> = []
    private var reviews: [Int: Int] = [:]
    private var rejectedPreparation: Int?
    private var rejectedDeletion: Int?
    private var failingReviews = false
    func rejectPreparation(_ id: Int) { rejectedPreparation = id }
    func rejectDeletion(_ id: Int) { rejectedDeletion = id }
    func failReviews(_ value: Bool) { failingReviews = value }
    func prepareDeletion(_ photo: SynologyPhoto) async throws {
        if photo.id.unitID == rejectedPreparation { throw URLError(.noPermissionsToReadFile) }
    }
    func deletePhoto(_ photo: SynologyPhoto, operationID: UUID) async throws -> SynologyPhotoDeletionResult {
        deleteIDs.append(photo.id.unitID)
        if photo.id.unitID == rejectedDeletion { throw URLError(.noPermissionsToReadFile) }
        return .pendingReview
    }
    func reviewDeletion(_ photo: SynologyPhoto) async throws -> SynologyPhotoDeletionResult {
        let id = photo.id.unitID
        reviewIDs.append(id)
        if failingReviews { throw URLError(.notConnectedToInternet) }
        reviews[id, default: 0] += 1
        if reviews[id, default: 0] < 2 { return .pendingReview }
        deleted.insert(id)
        return .confirmed
    }
    private var failsNext = false
    private let profileID = UUID()
    func failNextPage() { failsNext = true }
    func access() async throws -> SynologyPhotosAccess {
        .init(spaces: [.personal], packageVersion: "1.8.2-10090")
    }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        [.init(year: 2026, month: 9, day: 1, itemCount: 9000),
         .init(year: 2014, month: 8, day: 1, itemCount: 8000)]
    }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] {
        try await timeline(in: space)
    }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        if failsNext { failsNext = false; throw URLError(.notConnectedToInternet) }
        let start: Int, end: Int, keyword: String?
        switch query {
        case .timeline(let lower, let upper): (start, end, keyword) = (lower, upper, nil)
        case .search(let text, let lower, let upper): (start, end, keyword) = (lower, upper, text)
        default: throw URLError(.badURL)
        }
        requests.append(.init(start: start, end: end, offset: offset, keyword: keyword))
        let calendar = Calendar(identifier: .gregorian)
        let all = (1...6).map { index in
            let date = calendar.date(from: DateComponents(year: index <= 3 ? 2026 : 2014, month: index <= 3 ? 9 : 8, day: 1, hour: 12))!
            return SynologyPhoto(id: .init(profileID: profileID, space: .personal, unitID: index),
                                 filename: "sample-\(index).jpg", sizeBytes: 128,
                                 takenAt: date, indexedAt: date, folderID: 9, mediaType: "photo")
        }
        let matches = all.filter { !deleted.contains($0.id.unitID) && (start...end).contains(Int($0.takenAt.timeIntervalSince1970)) }
        let page = Array(matches.dropFirst(offset).prefix(limit))
        return .init(items: page, offset: offset, nextOffset: offset + page.count, hasMore: page.count == limit)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }
}

private actor PhotoServiceStub: SynologyPhotosServing {
    private let saveData: Data?
    var savedURLs: [URL] = []
    var pageRequestCount = 0
    var requestedOffsets: [Int] = []
    var requestedQueries: [SynologyPhotoQuery] = []
    private var pages: [[SynologyPhoto]]
    private let days: [SynologyPhotoDay]
    private var holdsFirstPage: Bool
    private var failsFirstAccess: Bool
    private var held: CheckedContinuation<[SynologyPhoto], Never>?
    private var ready: CheckedContinuation<Void, Never>?

    init(
        pages: [[SynologyPhoto]], holdsFirstPage: Bool = false,
        days: [SynologyPhotoDay] = [SynologyPhotoDay(year: 2020, month: 1, day: 1, itemCount: 1)],
        failsFirstAccess: Bool = false,
        saveData: Data? = nil
    ) {
        self.pages = pages
        self.holdsFirstPage = holdsFirstPage
        self.days = days
        self.failsFirstAccess = failsFirstAccess
        self.saveData = saveData
    }

    func access() async throws -> SynologyPhotosAccess {
        if failsFirstAccess {
            failsFirstAccess = false
            throw URLError(.notConnectedToInternet)
        }
        return SynologyPhotosAccess(spaces: [.personal], packageVersion: "1.8.2-10090")
    }

    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { days }
    func categories() async throws -> Set<SynologyPhotoCategory> { Set(SynologyPhotoCategory.allCases) }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { days }

    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        pageRequestCount += 1
        requestedOffsets.append(offset)
        requestedQueries.append(query)
        let items: [SynologyPhoto]
        if holdsFirstPage {
            holdsFirstPage = false
            items = await withCheckedContinuation { continuation in
                held = continuation
                ready?.resume()
                ready = nil
            }
        } else {
            items = pages.isEmpty ? [] : pages.removeFirst()
        }
        return SynologyPhotoPage(items: items, offset: offset, nextOffset: offset + items.count, hasMore: items.count == limit)
    }

    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }

    func waitForHeldPage() async {
        if held != nil { return }
        await withCheckedContinuation { ready = $0 }
    }

    func holdNextPage() { holdsFirstPage = true }

    func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        savedURLs.append(destination)
        guard let saveData else { throw URLError(.networkConnectionLost) }
        try saveData.write(to: destination)
        progress(Int64(saveData.count), Int64(saveData.count))
    }

    func releasePage(_ items: [SynologyPhoto]) {
        held?.resume(returning: items)
        held = nil
    }
}

/// 不接触真实文件或 NAS，分别模拟上传回执、加入相册失败和等待中的结果。
actor PhotoUploadServiceStub: SynologyPhotosServing {
    private var conditionReadFails = false
    func failConditionRead() { conditionReadFails = true }
    func albumCondition(id: Int) async throws -> SynologyPhotoAlbumCondition {
        if conditionReadFails { throw URLError(.notConnectedToInternet) }
        return .init(fields: ["item_type": .array([.integer(-1)]), "keyword": .array([.string("Fixture trip")]), "keyword_policy": .string("and"),
            "general_tag": .array([.integer(8)]), "general_tag_policy": .string("or"),
            "time": .array([.object(["start_time": .integer(1583020800), "end_time": .integer(1585699199)])])],
            names: ["general_tag": [.init(name: "Fixture tag", value: .integer(8))]])
    }
    func conditionSuggestions(keyword: String) async throws -> [String: [SynologyPhotoConditionOption]] {
        ["general_tag": [.init(name: "Fixture tag", value: .integer(8))]]
    }
    func conditionItemCount(_ condition: SynologyPhotoAlbumCondition) async throws -> Int { 3 }

    var commands: [SynologyPhotosMutation] = []
    private var directoryFixtures: [SynologyPhotoCollection] = []
    func addFolder(_ folder: SynologyPhotoCollection) { directoryFixtures.append(folder) }
    var pageReads = 0
    var accessReads = 0
    private var holdsPage = false
    private var heldPage: CheckedContinuation<Void, Never>?
    private var pageReady: CheckedContinuation<Void, Never>?
    func holdNextPage() { holdsPage = true }
    func waitUntilPageHeld() async {
        if heldPage != nil { return }
        await withCheckedContinuation { pageReady = $0 }
    }
    func releasePage() { heldPage?.resume(); heldPage = nil }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: 1, name: "Fixture root") }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { Array(directoryFixtures.filter { $0.parentID == parentID }.dropFirst(offset).prefix(limit)) }
    private var rejectAlbum = false
    private var rejectPrepare = false
    private var pending = false
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    private var results: [UUID: SynologyPhotosMutationResult] = [:]
    private let profile = UUID()
    func rejectNextAlbumAddition() { rejectAlbum = true }
    func rejectFirstPreparation() { rejectPrepare = true }
    func makeFirstUploadPending() { pending = true }
    func resolveUpload() { pending = false }
    func holdFirstUpload() { shouldHold = true }
    func waitUntilHeld() async {
        if held != nil { return }
        await withCheckedContinuation { ready = $0 }
    }
    func releaseUpload() { held?.resume(); held = nil }
    func access() async throws -> SynologyPhotosAccess { accessReads += 1; return .init(spaces: [.personal], packageVersion: "fixture") }
    func managementFeatures() async -> Set<SynologyPhotosManagementFeature> { Set(SynologyPhotosManagementFeature.allCases) }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [.init(year: 2020, month: 3, day: 1, itemCount: 1)] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        pageReads += 1
        if holdsPage {
            holdsPage = false
            await withCheckedContinuation { heldPage = $0; pageReady?.resume(); pageReady = nil }
        }
        return .init(items: [], offset: offset, nextOffset: offset, hasMore: false)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws {
        if rejectPrepare { rejectPrepare = false; throw URLError(.noPermissionsToReadFile) }
    }
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        commands.append(mutation)
        let result: SynologyPhotosMutationResult
        if case .upload(let file, let size, let date, let folder) = mutation {
            let photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: commands.count + 100),
                filename: file.lastPathComponent, sizeBytes: size, takenAt: date, indexedAt: date,
                folderID: folder ?? 9, mediaType: "photo")
            result = .init(state: .confirmed, photos: [photo], completedCount: 1)
            progress(size, size)
            if shouldHold {
                shouldHold = false
                await withCheckedContinuation { held = $0; ready?.resume(); ready = nil }
            }
        } else if case .createConditionAlbum(let name, _) = mutation {
            result = .init(state: .confirmed, album: .init(id: 21, name: name, isConditional: true))
        } else if case .setAlbumCondition(let id, _, _) = mutation {
            result = .init(state: .confirmed, album: .init(id: id, name: "Fixture rule album", isConditional: true))
        } else if case .createFolder(let parent, let name) = mutation {
            let folder = SynologyPhotoCollection(id: 1000 + commands.count, name: name, parentID: parent)
            directoryFixtures.append(folder)
            result = .init(state: .confirmed, folder: folder)
        } else if case .addToAlbum = mutation, rejectAlbum {
            rejectAlbum = false
            result = .init(state: .rejected)
        } else { result = .init(state: .confirmed, completedCount: mutation.photos.count) }
        results[operationID] = result
        return pending ? .init(state: .pendingReview) : result
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        pending ? .init(state: .pendingReview) : results[operationID] ?? .init(state: .pendingReview)
    }
}
