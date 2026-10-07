@testable import DsmPhotosFeature
import DsmCore
import DsmLocalization
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class SynologyPhotosModelTests: XCTestCase {
    func test照片保存成功提示自动消失且不关闭预览() async throws {
        let repository = PhotoServiceStub(pages: [], saveData: Data([1, 2, 3]))
        let model = SynologyPhotosModel(repository: repository)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { model.cancel(); try? FileManager.default.removeItem(at: destination) }
        model.showPreview(Self.photo)
        model.save(Self.photo, to: destination)
        for _ in 0..<200 where model.isSaving { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.saveMessage, L10n.string("photos.media.saved"))
        try await Task.sleep(for: .milliseconds(3_150))
        XCTAssertNil(model.saveMessage)
        XCTAssertEqual(model.previewPhoto?.id, Self.photo.id)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
    }

    func test保存失败提示自动消失且从新提示出现时重新计时() async throws {
        let repository = PhotoServiceStub(pages: [], saveData: Data([1, 2, 3]))
        let model = SynologyPhotosModel(repository: repository)
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        defer { model.cancel(); try? FileManager.default.removeItem(at: destination) }
        model.save(Self.photo, to: destination)
        for _ in 0..<200 where model.isSaving { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.saveMessage, L10n.string("photos.media.saved"))
        try await Task.sleep(for: .milliseconds(1_600))
        await repository.failSaving(AppError(category: .invalidResponse, isRetryable: false,
            safeUserMessage: L10n.string("photos.service.invalidResponse")))
        model.save(Self.photo, to: destination)
        for _ in 0..<200 where model.isSaving { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.saveMessage, L10n.string("photos.media.saveFailed"))
        try await Task.sleep(for: .milliseconds(1_600))
        XCTAssertEqual(model.saveMessage, L10n.string("photos.media.saveFailed"), "上一笔提示的计时不能提前清除新错误")
        try await Task.sleep(for: .milliseconds(1_550))
        XCTAssertNil(model.saveMessage)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2, 3]))
    }

    func test局部操作解析失败不误报图库失败且刷新清除过期提示() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        let photos = model.items
        XCTAssertFalse(photos.isEmpty)
        await service.failNextManagementPreparation(error: AppError(category: .invalidResponse, isRetryable: false,
            safeUserMessage: L10n.string("photos.service.invalidResponse")))
        model.submitMutation(.createAlbum(name: "Synthetic album", photos: []))
        await waitForManagement(model)
        XCTAssertEqual(model.managementMessage, L10n.string("photos.manage.failed"))
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items, photos)
        let writes = await service.managementWriteCount
        XCTAssertEqual(writes, 0)
        await model.refresh()
        XCTAssertNil(model.managementMessage)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.items, photos)
    }

    func test刷新不隐藏待确认或需要继续的照片操作() async throws {
        for pending in [true, false] {
            let service = DatePhotoServiceStub()
            await service.enableManagement(pending: pending, partial: !pending)
            let model = SynologyPhotosModel(repository: service, pageSize: 2, deletionReviewDelay: { _ in })
            await model.refresh()
            model.submitMutation(.shiftDates(model.items, seconds: 60))
            await waitForManagement(model)
            let message = try XCTUnwrap(model.managementMessage)
            let operation = model.pendingMutationID
            let remaining = model.retryableManagementMutation
            if pending { XCTAssertNotNil(operation) } else { XCTAssertNotNil(remaining) }
            await model.refresh()
            XCTAssertEqual(model.managementMessage, message)
            XCTAssertEqual(model.pendingMutationID, operation)
            XCTAssertEqual(model.retryableManagementMutation, remaining)
        }
    }

    func test原件保存解析失败仅提示保存错误且刷新后清除() async throws {
        let service = PhotoServiceStub(pages: [[Self.photo], [Self.photo]])
        await service.failSaving(AppError(category: .invalidResponse, isRetryable: false, safeUserMessage: L10n.string("photos.service.invalidResponse")))
        let model = SynologyPhotosModel(repository: service)
        await model.refresh()
        let photo = try XCTUnwrap(model.items.first)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticPhoto-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: file) }
        model.save(photo, to: file)
        for _ in 0..<1000 where model.isSaving { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(model.isSaving)
        XCTAssertEqual(model.saveMessage, L10n.string("photos.media.saveFailed"))
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await model.refresh()
        XCTAssertNil(model.saveMessage)
        XCTAssertFalse(model.items.isEmpty)
    }

    func test相册编辑角色个人提供者可编辑但不取得原件删除搬移权() async throws {
        for provider in [12, 99] {
            let service = PhotoUploadServiceStub(), photo = collaborationPhoto(provider: provider)
            await service.setAlbumPhoto(photo)
            await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
            let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture"))
            XCTAssertEqual(model.canEditSelection([photo], supportsMixedSpaces: false), provider == 12)
            XCTAssertFalse(model.canModifyOriginal(photo)); XCTAssertFalse(model.canTransfer([photo], copying: false))
            model.submitMutation(.edit([photo], .rating(3))); await waitForManagement(model)
            let commands = await service.commands; XCTAssertEqual(commands.count, provider == 12 ? 1 : 0)
        }
    }

    func test预览直接操作固定当前照片而不使用列表多选() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        let photo = try XCTUnwrap(model.items.first), other = try XCTUnwrap(model.items.last)
        XCTAssertNotEqual(photo.id, other.id); model.toggleSelection(other)
        let preview = SynologyPhotoPreview(model: model)
        for kind in [PhotoManagementKind.addAlbum, .createAlbum, .rating, .description, .date, .shiftDates, .tagsCreate, .tagsAdd, .tagsRemove, .move, .copy] {
            XCTAssertTrue(preview.canManage(kind, photo: photo), kind.rawValue)
            let target = preview.managementTarget(kind, photo: photo)
            XCTAssertEqual(target.photos, [photo]); XCTAssertEqual(target.space, photo.id.space)
            XCTAssertTrue(target.folders.isEmpty); XCTAssertNil(target.person); XCTAssertNil(target.concept)
        }
        XCTAssertFalse(preview.canManage(.removeAlbum, photo: photo)); XCTAssertFalse(preview.canManage(.cover, photo: photo))
        let target = preview.managementTarget(.rating, photo: photo)
        model.clearSelection(); model.toggleSelection(other)
        model.submitMutation(.edit(target.photos, .rating(4))); await waitForManagement(model)
        let commands = await service.managementCommands
        XCTAssertEqual(commands, [.edit([photo], .rating(4))]); XCTAssertEqual(model.selectedPhotoIDs, [other.id])
    }

    func test预览直接操作相册移出权限只看当前照片并保留表单上下文() async throws {
        for provider in [12, 99] {
            let service = PhotoUploadServiceStub(), photo = collaborationPhoto(provider: provider)
            await service.setAlbumPhoto(photo)
            await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
            let model = SynologyPhotosModel(repository: service)
            await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
            let preview = SynologyPhotoPreview(model: model)
            XCTAssertTrue(model.selectedPhotos.isEmpty)
            XCTAssertEqual(preview.canManage(.removeAlbum, photo: photo), provider == 12)
            XCTAssertFalse(preview.canManage(.cover, photo: photo)); XCTAssertEqual(preview.canManage(.rating, photo: photo), provider == 12)
            let target = preview.managementTarget(.removeAlbum, photo: photo)
            await model.selectSection(.timeline)
            XCTAssertEqual(target.album?.id, 21); XCTAssertEqual(target.photos, [photo])
        }
    }

    func test预览直接操作移出相册关闭当前预览而保留相册位置() async throws {
        let service = PhotoUploadServiceStub(), photo = collaborationPhoto(provider: 12)
        await service.setAlbumPhoto(photo)
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album")); model.showPreview(photo)
        model.submitMutation(.removeFromAlbum(id: 21, photos: [photo])); await waitForManagement(model)
        XCTAssertNil(model.previewPhoto); XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.selectedAlbum?.id, 21); XCTAssertEqual(model.section, .albums)
    }

    func test预览直接操作人物移出只关闭已确认移出的当前照片() async throws {
        for removesCurrent in [false, true] {
            let service = DatePhotoServiceStub(); await service.enableManagement(pending: true)
            let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            await model.refresh(); await model.selectSection(.albums); await model.openCategory(.person)
            let person = try XCTUnwrap(model.collections.first); await model.open(person)
            let photo = try XCTUnwrap(model.items.first), other = try XCTUnwrap(model.items.last)
            model.showPreview(photo); model.toggleSelection(other)
            let preview = SynologyPhotoPreview(model: model), target = preview.managementTarget(.removeFaces, photo: photo)
            XCTAssertEqual(target.person, person); XCTAssertTrue(preview.canManage(.personCover, photo: photo))
            let removed = removesCurrent ? photo : other
            let faces = try await model.personFaces(personID: person.id, photos: [removed])
            model.submitMutation(.removePersonFaces(person: person, faces: faces)); await waitForManagement(model)
            XCTAssertEqual(model.previewPhoto?.id, photo.id); XCTAssertNotNil(model.pendingMutationID)
            XCTAssertFalse(preview.canManage(.removeFaces, photo: photo))
            await service.enableManagement(); model.reviewPendingMutation(); await waitForManagement(model)
            XCTAssertEqual(model.previewPhoto?.id, removesCurrent ? nil : photo.id)
            XCTAssertEqual(model.selectedCategoryItem?.id, person.id); XCTAssertEqual(model.selectedCategory, .person)
            XCTAssertFalse(model.items.contains { $0.id == removed.id })
            model.closePreview()
        }
    }

    func test预览直接操作目录移动关闭而复制保留当前照片() async throws {
        for copying in [false, true] {
            let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            await model.refresh(); await model.selectSection(.folders)
            let photo = try XCTUnwrap(model.items.first), history = model.folderHistory
            model.showPreview(photo)
            model.submitMutation(copying ? .copy([photo], folderID: 20) : .move([photo], folderID: 20))
            await waitForManagement(model)
            XCTAssertEqual(model.previewPhoto?.id, copying ? photo.id : nil)
            XCTAssertEqual(model.items.contains { $0.id == photo.id }, copying)
            XCTAssertEqual(model.folderHistory, history); model.closePreview()
        }
    }

    func test预览角色相册贡献者与下载者冻结及空间关闭分开判断() async throws {
        for mode in ["provider", "download", "frozen", "space"] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service)
            let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 128,
                takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo",
                albumContext: .init(albumID: 21, ownerUserID: 99, providerUserID: mode == "download" ? 98 : 12))
            let album = SynologyPhotoCollection(id: 21, name: "Fixture album", isFrozen: mode == "frozen")
            await service.configureLists([album]); await service.setAlbumPhoto(photo)
            await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
            if mode == "space" { await service.setSpaces([]) }
            await model.selectSection(.albums); await model.open(album)
            XCTAssertEqual(model.canRegeneratePreviews([photo]), mode == "provider" || mode == "frozen", mode)
            XCTAssertEqual(model.canRegeneratePreviews([photo], fromPreview: true), mode == "provider", mode)
            XCTAssertFalse(model.canModifyOriginal(photo), "提供者重建预览不能扩大原件编辑权")
            XCTAssertFalse(model.canRegeneratePreviews([]))
        }
    }

    func test冻结相册读取不写入且恢复前禁止上传() async throws {
        let service = FrozenPhotoServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.selectSection(.albums)
        let album = try XCTUnwrap(model.collections.first); await model.open(album)
        let snapshot = try await model.frozenAlbum(id: album.id)
        XCTAssertEqual(snapshot.album.id, album.id); XCTAssertFalse(model.canUploadPhotos)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test冻结相册普通恢复更新所选相册与上传权限而不重载照片() async throws {
        let service = FrozenPhotoServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(try XCTUnwrap(model.collections.first))
        let snapshot = try await model.frozenAlbum(id: 21), reads = await service.photoReads
        model.submitMutation(.unfreezeAlbum(snapshot)); try await waitFor { !model.isManaging }
        XCTAssertEqual(model.selectedAlbum?.isFrozen, false); XCTAssertTrue(model.canUploadPhotos)
        let after = await service.photoReads; XCTAssertEqual(after, reads)
        XCTAssertNil(model.pendingMutationID)
    }

    func test冻结相册重建完成从原详情前往新相册() async throws {
        let service = FrozenPhotoServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(try XCTUnwrap(model.collections.first))
        let snapshot = try await model.frozenAlbum(id: 21)
        model.submitMutation(.rebuildFrozenAlbum(snapshot, name: "Rebuilt fixture", condition: try XCTUnwrap(snapshot.rebuildCondition)))
        try await waitFor { !model.isManaging }
        XCTAssertEqual(model.selectedAlbum?.id, 31); XCTAssertEqual(model.selectedAlbum?.isConditional, true)
        XCTAssertFalse(model.canUploadPhotos); XCTAssertNil(model.pendingMutationID)
    }

    func test冻结相册重建列表只在确认旧册移除后替换() async throws {
        for state in [SynologyPhotosMutationResult.State.confirmed, .partial] {
            let service = FrozenPhotoServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            await service.setOutcome(state); await model.selectSection(.albums)
            let snapshot = try await model.frozenAlbum(id: 21)
            model.submitMutation(.rebuildFrozenAlbum(snapshot, name: "Rebuilt fixture", condition: try XCTUnwrap(snapshot.rebuildCondition)))
            try await waitFor { !model.isManaging }
            XCTAssertEqual(Set(model.collections.map(\.id)), state == .confirmed ? [31] : [21, 31])
            XCTAssertNil(model.selectedAlbum)
            if state == .partial { XCTAssertEqual(model.managementMessage, L10n.string("photos.frozen.partial")) }
        }
    }

    func test冻结相册待核对不重复提交且切换页面后不抢回新相册() async throws {
        let service = FrozenPhotoServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(try XCTUnwrap(model.collections.first))
        await service.setOutcome(.pendingReview)
        let snapshot = try await model.frozenAlbum(id: 21)
        let command = SynologyPhotosMutation.rebuildFrozenAlbum(snapshot, name: "Rebuilt fixture", condition: try XCTUnwrap(snapshot.rebuildCondition))
        model.submitMutation(command); try await waitFor { !model.isManaging }
        XCTAssertNotNil(model.pendingMutationID)
        model.submitMutation(command)
        await model.selectSection(.timeline); await service.setOutcome(.confirmed)
        model.reviewPendingMutation(); try await waitFor { !model.isManaging }
        XCTAssertEqual(model.section, .timeline); XCTAssertNil(model.selectedAlbum); XCTAssertNil(model.pendingMutationID)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test冻结相册禁用后不能提交且不支持重建的快照只允许普通恢复() async throws {
        let service = FrozenPhotoServiceStub(), model = SynologyPhotosModel(repository: service)
        await service.configure(bare: true); await model.refresh()
        let snapshot = try await model.frozenAlbum(id: 21)
        model.submitMutation(.rebuildFrozenAlbum(snapshot, name: "Invalid", condition: .init()))
        model.setModuleEnabled(false); model.submitMutation(.unfreezeAlbum(snapshot))
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test后台任务只读不改变当前月份照片与选择() async throws {
        let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
        let photo = try XCTUnwrap(model.items.first); model.toggleSelection(photo)
        let selected = model.selectedPhotoIDs, month = model.selectedTimelineMonthID, reads = await service.photoReads
        let tasks = try await model.backgroundTasks(), task = try XCTUnwrap(tasks.first)
        let errors = try await model.backgroundTaskErrors(task)
        XCTAssertEqual(tasks.count, 1); XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(model.selectedPhotoIDs, selected); XCTAssertEqual(model.selectedTimelineMonthID, month)
        let afterReads = await service.photoReads, commands = await service.commands
        XCTAssertEqual(afterReads, reads); XCTAssertTrue(commands.isEmpty)
    }

    func test后台任务取消与原搬移独立保留操作编号且未知状态不能重复发送() async throws {
        let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await service.setPending(general: true, background: true)
        model.submitMutation(.copy([try XCTUnwrap(model.items.first)], folderID: 9))
        try await waitFor { !model.isManaging }
        let originalID = try XCTUnwrap(model.pendingMutationID), task = await service.fixture()
        model.submitMutation(.cancelBackgroundTask(task)); model.submitMutation(.cancelBackgroundTask(task))
        try await waitFor { !model.isManagingBackgroundTask }
        XCTAssertNotNil(model.pendingBackgroundMutationID); XCTAssertEqual(model.pendingMutationID, originalID)
        model.submitMutation(.cancelBackgroundTask(task))
        var commands = await service.commands; XCTAssertEqual(commands.count, 2)
        await service.setPending(general: true, background: false)
        model.reviewBackgroundMutation(); try await waitFor { !model.isManagingBackgroundTask && !model.isManaging }
        XCTAssertNil(model.pendingBackgroundMutationID); XCTAssertEqual(model.pendingMutationID, originalID)
        await service.setPending(general: false, background: false)
        model.reviewPendingMutation(); try await waitFor { !model.isManaging }
        XCTAssertNil(model.pendingMutationID)
        commands = await service.commands; XCTAssertEqual(commands.count, 2)
    }

    func test后台任务清理冻结快照且不触碰图库或后来完成的任务() async throws {
        let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let first = await service.fixture(id: 42, status: .done), later = await service.fixture(id: 43, status: .done)
        await service.setTasks([first]); await model.refresh()
        let before = model.items, month = model.selectedTimelineMonthID
        let snapshot = try await model.backgroundTasks()
        await service.setTasks([first, later]); model.submitMutation(.clearBackgroundTasks(snapshot))
        try await waitFor { !model.isManagingBackgroundTask }
        let remaining = try await model.backgroundTasks(); XCTAssertEqual(remaining.map(\.id), [43])
        XCTAssertEqual(model.items, before); XCTAssertEqual(model.selectedTimelineMonthID, month)
        XCTAssertNil(model.pendingBackgroundMutationID); XCTAssertEqual(model.backgroundTaskRevision, 1)
        let commands = await service.commands; XCTAssertEqual(commands, [.clearBackgroundTasks([first])])
    }

    func test后台任务目标跳转按完整个人共享父链打开() async throws {
        for shared in [false, true] {
            let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service)
            let task = await service.fixture(status: .done, shared: shared)
            await service.setTasks([task]); await model.refresh()
            let opened = await model.openBackgroundTask(task)
            XCTAssertTrue(opened); XCTAssertEqual(model.section, .folders)
            XCTAssertEqual(model.selectedSpace, shared ? .shared : .personal)
            XCTAssertEqual(model.folderHistory.map(\.id), shared ? [101, 109] : [1, 9])
            XCTAssertNil(model.backgroundNavigationError)
        }
    }

    func test后台任务目标失权或父链循环不扰动当前图库() async throws {
        for cycle in [false, true] {
            let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service)
            await service.configureFolders(fails: !cycle, cycle: cycle); await model.refresh()
            let before = model.items, task = await service.fixture(), month = model.selectedTimelineMonthID
            let opened = await model.openBackgroundTask(task)
            XCTAssertFalse(opened); XCTAssertEqual(model.section, .timeline); XCTAssertEqual(model.items, before)
            XCTAssertEqual(model.selectedTimelineMonthID, month); XCTAssertNotNil(model.backgroundNavigationError)
        }
    }

    func test后台任务目标读取晚到不能在禁用后重新打开图库() async throws {
        let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.refresh(); await service.configureFolders(held: true)
        let task = await service.fixture()
        let opening = Task { await model.openBackgroundTask(task) }
        await service.waitForHeldFolder(); model.setModuleEnabled(false); await service.releaseFolder()
        let opened = await opening.value
        XCTAssertFalse(opened); XCTAssertTrue(model.items.isEmpty); XCTAssertTrue(model.folderHistory.isEmpty)
        XCTAssertNil(model.backgroundNavigationError)
    }

    func test后台任务禁用和不适用命令不会发送() async throws {
        let service = BackgroundPhotoServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.refresh()
        let active = await service.fixture(), done = await service.fixture(status: .done)
        model.submitMutation(.clearBackgroundTasks([active])); model.submitMutation(.cancelBackgroundTask(done))
        model.setModuleEnabled(false); model.submitMutation(.cancelBackgroundTask(active))
        do { _ = try await model.backgroundTasks(); XCTFail() } catch { }
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        XCTAssertNil(model.pendingBackgroundMutationID)
    }

    func test预览旋转只更新当前照片并保持月份选择且刷新图像() async throws {
        let service = SlideshowPhotoServiceStub()
        await service.enableRotation()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
        let photo = try XCTUnwrap(model.items.first), before = model.items.map(\.id)
        model.selectGroup(model.items)
        let selected = model.selectedPhotoIDs, reads = await service.reads.count
        model.showPreview(photo)
        try await waitFor { !model.isPreparingPreview }
        XCTAssertTrue(model.canRotatePreview)
        model.rotatePreview(); model.rotatePreview()
        await waitForManagement(model)
        try await waitFor { !model.isPreparingPreview }
        XCTAssertEqual(model.previewPhoto?.orientation, 8)
        XCTAssertEqual(model.previewData, Data([2]))
        XCTAssertEqual(model.items.map(\.id), before)
        XCTAssertEqual(model.items.first?.orientation, 8)
        XCTAssertEqual(model.selectedPhotoIDs, selected)
        let afterReads = await service.reads.count, writes = await service.rotationWrites, previews = await service.previewReads
        XCTAssertEqual(afterReads, reads); XCTAssertEqual(writes, 1); XCTAssertEqual(previews, 2)
        XCTAssertNil(model.pendingMutationID)
    }

    func test旋转核对期间切换照片不会重新打开旧预览且未知状态不能重复写入() async throws {
        let service = SlideshowPhotoServiceStub()
        await service.enableRotation(pending: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        model.showPreview(try XCTUnwrap(model.items.first)); try await waitFor { !model.isPreparingPreview }
        model.rotatePreview(); await waitForManagement(model)
        XCTAssertNotNil(model.pendingMutationID); XCTAssertFalse(model.canRotatePreview)
        model.rotatePreview()
        model.closePreview()
        await service.resolveRotation()
        model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.previewPhoto); XCTAssertNil(model.previewData)
        let writes = await service.rotationWrites; XCTAssertEqual(writes, 1)
    }

    func test实况旋转后隐藏动态播放恢复原方向后仍可播放() async throws {
        var photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 1), filename: "Fixture.heic", sizeBytes: 128,
            takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "live", orientation: 8)
        photo.originalOrientation = 1
        XCTAssertTrue(photo.supportsRotation); XCTAssertFalse(photo.canPlayMotion)
        photo.originalOrientation = 8; XCTAssertTrue(photo.canPlayMotion)
    }

    private func photoDragFixture() async throws -> (PhotoUploadServiceStub, SynologyPhotosModel, SynologyPhoto, [SynologyPhotoCollection]) {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service)
        let folders = [10, 11].map { SynologyPhotoCollection(id: $0, name: "Child\($0)", parentID: 1, path: "/Child\($0)") }
        for folder in folders { await service.addFolder(folder) }
        let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
            takenAt: .distantPast, indexedAt: .distantPast, folderID: 1, mediaType: "photo")
        await service.setFolderPhotos([photo]); await model.refresh(); await model.selectSection(.folders)
        XCTAssertNil(model.errorMessage)
        return (service, model, photo, folders)
    }

    func test拖动已选照片固定混合快照且落下不会立即写入() async throws {
        let (service, model, photo, folders) = try await photoDragFixture()
        model.toggleSelection(photo); model.toggleFolderSelection(folders[0])
        let token = try XCTUnwrap(model.beginPhotoDrag(photo: photo))
        model.clearSelection()
        XCTAssertFalse(model.canDropPhotos(to: folders[0])); XCTAssertFalse(model.canDropPhotos(to: try XCTUnwrap(model.folderHistory.first)))
        XCTAssertTrue(model.canDropPhotos(to: folders[1]))
        XCTAssertNil(model.takePhotoDrop(token: UUID(), to: folders[1]))
        let snapshot = try XCTUnwrap(model.takePhotoDrop(token: token, to: folders[1]))
        XCTAssertEqual(snapshot.photos, [photo]); XCTAssertEqual(snapshot.folders, [folders[0]])
        XCTAssertNil(model.takePhotoDrop(token: token, to: folders[1])); XCTAssertNil(model.dragSelection)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test未选目录拖动只带当前项且新的拖动替换旧标识() async throws {
        let (_, model, photo, folders) = try await photoDragFixture()
        model.toggleSelection(photo)
        let old = try XCTUnwrap(model.beginPhotoDrag(photo: photo)), token = try XCTUnwrap(model.beginPhotoDrag(folder: folders[0]))
        XCTAssertNil(model.takePhotoDrop(token: old, to: folders[1]))
        let snapshot = try XCTUnwrap(model.takePhotoDrop(token: token, to: folders[1]))
        XCTAssertTrue(snapshot.photos.isEmpty); XCTAssertEqual(snapshot.folders, [folders[0]])
        XCTAssertEqual(model.selectedPhotos, [photo])
    }

    func test拖放拒绝外来目标刷新后的旧选择和非目录界面() async throws {
        let (_, model, photo, folders) = try await photoDragFixture()
        let token = try XCTUnwrap(model.beginPhotoDrag(photo: photo))
        XCTAssertFalse(model.canDropPhotos(to: .init(id: 99, name: "Foreign", parentID: 1, path: "/Foreign")))
        XCTAssertFalse(model.canDropPhotos(to: .init(id: 11, name: "Child11", parentID: 1, path: "/Child11", space: .shared)))
        await model.refresh()
        XCTAssertNil(model.takePhotoDrop(token: token, to: folders[1]))
        await model.selectSection(.timeline)
        XCTAssertNil(model.beginPhotoDrag(photo: photo)); XCTAssertNil(model.beginPhotoDrag(folder: folders[0]))
    }

    func test拖放上级目录与路径导航保留对应层级() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSection(.folders)
        let root = try XCTUnwrap(model.folderHistory.first), parent = try XCTUnwrap(model.collections.first)
        await model.open(parent)
        let child = try XCTUnwrap(model.collections.first), photo = try XCTUnwrap(model.items.first)
        _ = try XCTUnwrap(model.beginPhotoDrag(photo: photo))
        XCTAssertFalse(model.canDropPhotos(to: parent)); XCTAssertTrue(model.canDropPhotos(to: root)); XCTAssertTrue(model.canDropPhotos(to: child))
        XCTAssertEqual(model.photoDropPath(to: child), [root, parent, child]); XCTAssertEqual(model.photoDropPath(to: root), [root])
        await model.open(child); await model.navigateToFolder(root)
        XCTAssertEqual(model.folderHistory, [root]); XCTAssertFalse(model.canGoBack)
    }

    func test拖放数据仅含随机标识且无效拖动不公开数据类型() async throws {
        let token = UUID(), provider = PhotoDragItemProvider.make(token: token)
        XCTAssertEqual(provider.registeredTypeIdentifiers, [PhotoDragItemProvider.typeIdentifier])
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: PhotoDragItemProvider.typeIdentifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
        XCTAssertEqual(String(data: data, encoding: .utf8), token.uuidString)
        XCTAssertTrue(PhotoDragItemProvider.make(token: nil).registeredTypeIdentifiers.isEmpty)
    }

    func test幻灯片独立分页循环且保持月份选择与图库范围() async throws {
        let service = SlideshowPhotoServiceStub(), clock = SlideshowTestClock()
        let model = SynologyPhotosModel(repository: service, pageSize: 1, slideshowDelay: { try await clock.wait() })
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
        model.selectGroup(model.items)
        let original = model.items, selected = model.selectedPhotoIDs
        model.startSlideshow(); model.toggleSlideshowPlayback()
        XCTAssertEqual(model.previewPhoto?.id.unitID, 2)
        model.advanceSlideshow(1); try await waitForSlideshow(model, id: 3)
        model.advanceSlideshow(1); try await waitForSlideshow(model, id: 1)
        model.advanceSlideshow(-1); try await waitForSlideshow(model, id: 3)
        XCTAssertEqual(model.items, original); XCTAssertEqual(model.selectedPhotoIDs, selected)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertFalse(model.isSlideshowPlaying)
        model.stopSlideshow(); XCTAssertEqual(model.previewPhoto?.id.unitID, 3)
        XCTAssertFalse(model.isSlideshowPresented)
        let queries = await service.reads
        XCTAssertTrue(queries.allSatisfy { $0.0 == .personal })
        XCTAssertTrue(queries.contains { $0.1 == 2 })
    }

    func test幻灯片自动推进暂停取消计时并恢复且关闭不再读取() async throws {
        let service = SlideshowPhotoServiceStub(), clock = SlideshowTestClock()
        let model = SynologyPhotosModel(repository: service, slideshowDelay: { try await clock.wait() })
        await model.refresh(); model.startSlideshow()
        for _ in 0..<1000 { if await clock.pending > 0 { break }; await Task.yield() }
        model.toggleSlideshowPlayback()
        for _ in 0..<1000 { if await clock.pending == 0 { break }; await Task.yield() }
        await clock.tick(); XCTAssertEqual(model.previewPhoto?.id.unitID, 1)
        model.toggleSlideshowPlayback()
        for _ in 0..<1000 { if await clock.pending > 0 { break }; await Task.yield() }
        await clock.tick(); try await waitForSlideshow(model, id: 2)
        model.closePreview(); await clock.tick()
        XCTAssertNil(model.previewPhoto); XCTAssertFalse(model.isSlideshowPlaying)
        let pending = await clock.pending; XCTAssertEqual(pending, 0)
    }

    func test幻灯片视频等待结束并且暂停时不跳到下一项() async throws {
        let service = SlideshowPhotoServiceStub(video: true), clock = SlideshowTestClock()
        let model = SynologyPhotosModel(repository: service, slideshowDelay: { try await clock.wait() })
        await model.refresh(); model.startSlideshow()
        try await waitForSlideshow(model, id: 1)
        XCTAssertNotNil(model.previewSource)
        let pending = await clock.pending; XCTAssertEqual(pending, 0)
        model.toggleSlideshowPlayback(); model.slideshowVideoEnded()
        XCTAssertEqual(model.previewPhoto?.id.unitID, 1)
        model.toggleSlideshowPlayback(); try await waitForSlideshow(model, id: 2)
        XCTAssertNil(model.previewSource); model.closePreview()
    }

    func test幻灯片分页失败停在当前照片且可继续不跳过失败页面() async throws {
        let service = SlideshowPhotoServiceStub(), clock = SlideshowTestClock()
        let model = SynologyPhotosModel(repository: service, slideshowDelay: { try await clock.wait() })
        await model.refresh(); model.startSlideshow(); await service.setFailure(true)
        model.advanceSlideshow(1)
        for _ in 0..<1000 where model.slideshowError == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertNotNil(model.slideshowError); XCTAssertFalse(model.isSlideshowPlaying)
        XCTAssertEqual(model.previewPhoto?.id.unitID, 1)
        await service.setFailure(false); model.toggleSlideshowPlayback()
        for _ in 0..<1000 { if await clock.pending > 0 { break }; await Task.yield() }
        await clock.tick(); try await waitForSlideshow(model, id: 2)
        XCTAssertNil(model.slideshowError); model.closePreview()
    }

    func test幻灯片读取期间离开忽略迟到结果且不恢复播放() async throws {
        let service = SlideshowPhotoServiceStub(), clock = SlideshowTestClock()
        let model = SynologyPhotosModel(repository: service, slideshowDelay: { try await clock.wait() })
        await model.refresh(); model.startSlideshow(); await service.holdNext()
        model.advanceSlideshow(1)
        for _ in 0..<1000 { if await service.isHeld { break }; await Task.yield() }
        model.leaveGallery(); await service.release()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(model.previewPhoto); XCTAssertFalse(model.isSlideshowPresented)
        XCTAssertFalse(model.isLoadingSlideshow); XCTAssertNil(model.slideshowError)
    }

    private func waitForSlideshow(_ model: SynologyPhotosModel, id: Int) async throws {
        for _ in 0..<1000 where model.previewPhoto?.id.unitID != id || model.isPreparingPreview || model.isLoadingSlideshow {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(model.previewPhoto?.id.unitID, id)
        XCTAssertFalse(model.isPreparingPreview); XCTAssertFalse(model.isLoadingSlideshow)
    }

    func test相似组幻灯片只在组内切换不把组代表当全部成员() async throws {
        let service = SharedCategoryServiceStub(), clock = SlideshowTestClock()
        let model = SynologyPhotosModel(repository: service, slideshowDelay: { try await clock.wait() })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        model.showPreview(try XCTUnwrap(model.items.first))
        for _ in 0..<1000 where model.isLoadingSimilarPreview || model.isPreparingPreview { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(model.previewSimilarDetail?.photos.count, 2)
        model.startSlideshow(); model.toggleSlideshowPlayback()
        model.advanceSlideshow(1); try await waitForSlideshow(model, id: 8)
        model.advanceSlideshow(1); try await waitForSlideshow(model, id: 7)
        XCTAssertEqual(model.items.count, 1); XCTAssertEqual(model.previewSimilarDetail?.photos.count, 2)
        model.closePreview()
    }

    func test实况播放中进入幻灯片恢复静态图且读取完成前不计时() async throws {
        let service = SlideshowPhotoServiceStub(live: true), clock = SlideshowTestClock()
        let model = SynologyPhotosModel(repository: service, slideshowDelay: { try await clock.wait() })
        await model.refresh(); await service.holdPreview(); model.startSlideshow()
        for _ in 0..<20 { await Task.yield() }
        let pending = await clock.pending; XCTAssertEqual(pending, 0)
        XCTAssertTrue(model.isPreparingPreview)
        await service.releasePreview(); try await waitForSlideshow(model, id: 1)
        model.stopSlideshow(); model.playMotion()
        for _ in 0..<1000 where model.previewSource == nil { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(model.isPlayingMotion); XCTAssertNotNil(model.previewSource)
        model.startSlideshow()
        XCTAssertFalse(model.isPlayingMotion); XCTAssertNil(model.previewSource); XCTAssertNotNil(model.previewData)
        await model.refresh()
        XCTAssertFalse(model.isSlideshowPresented); XCTAssertNil(model.previewPhoto)
    }

    func test混选下载固定全部目标并保留目录选择且不刷新图库() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service)
        let folders = [10, 11].map { SynologyPhotoCollection(id: $0, name: "Child\($0)", parentID: 1, path: "/Child\($0)") }
        for folder in folders { await service.addFolder(folder) }
        let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
            takenAt: .distantPast, indexedAt: .distantPast, folderID: 1, mediaType: "photo")
        await service.setFolderPhotos([photo]); await model.refresh(); await model.selectSection(.folders)
        XCTAssertNil(model.selectedArchive)
        model.selectLoadedItems()
        let target = try XCTUnwrap(model.selectedArchive), reads = await service.pageReads
        XCTAssertEqual(target, .selection(photos: [photo], folders: folders)); XCTAssertTrue(model.canDownloadArchive(target))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        model.saveArchive(target, format: .optimizedJPEG, to: file)
        for _ in 0..<1000 where model.isSaving { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(model.isSaving); XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(model.selectedArchive, target); XCTAssertEqual(model.currentArchive?.target, .folder(id: 1, space: .personal))
        let after = await service.pageReads; XCTAssertEqual(after, reads)
        model.clearSelection(); XCTAssertNil(model.selectedArchive)
        model.saveArchive(target, format: .original, to: file)
        for _ in 0..<1000 where model.isSaving { try await Task.sleep(for: .milliseconds(1)) }
        let calls = await service.archiveCalls; XCTAssertEqual(calls.map { $0.0 }, [target, target], "保存窗口使用开启时的选择快照")
    }

    func test混选归档取消及失败保留旧文件且不改变当前选择() async throws {
        for cancelled in [false, true] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service)
            let folder = SynologyPhotoCollection(id: 10, name: "Child10", parentID: 1, path: "/Child10")
            await service.addFolder(folder); await service.configureArchive(fails: !cancelled, waits: cancelled)
            await model.refresh(); await model.selectSection(.folders); model.toggleFolderSelection(folder)
            let target = try XCTUnwrap(model.selectedArchive)
            XCTAssertFalse(model.canDownloadArchive(.selection(photos: [], folders: [])))
            XCTAssertFalse(model.canDownloadArchive(.selection(photos: [], folders: [.init(id: 10, name: "Shared", parentID: 1, space: .shared)])))
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let original = Data("previous".utf8); try original.write(to: file)
            model.saveArchive(target, format: .original, to: file); model.saveArchive(target, format: .original, to: file)
            if cancelled {
                for _ in 0..<1000 { if await !service.archiveCalls.isEmpty { break }; await Task.yield() }
                model.cancelSave()
            }
            for _ in 0..<1000 where model.isSaving { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertFalse(model.isSaving); XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertEqual(model.selectedArchive, target); XCTAssertEqual(model.saveMessage == nil, cancelled)
            let calls = await service.archiveCalls; XCTAssertEqual(calls.count, 1)
        }
    }

    func test整册下载固定集合而不是已加载照片并保持当前页面() async throws {
        let service = PhotoUploadServiceStub()
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: true, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service)
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("old".utf8).write(to: file)
        let items = model.items, before = await service.pageReads
        let target = try XCTUnwrap(model.currentArchive?.target); XCTAssertEqual(target, .album(id: 21))
        model.saveArchive(target, format: .optimizedJPEG, to: file)
        for _ in 0..<1000 where model.isSaving { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(model.isSaving); XCTAssertEqual(try Data(contentsOf: file), Data([0x50, 0x4b, 5, 6] + Array(repeating: 0, count: 18)))
        let calls = await service.archiveCalls; XCTAssertEqual(calls.map { $0.0 }, [.album(id: 21)]); XCTAssertEqual(calls.first?.1, .optimizedJPEG)
        XCTAssertEqual(model.items, items); XCTAssertEqual(model.selectedAlbum?.id, 21)
        let after = await service.pageReads; XCTAssertEqual(after, before)
    }

    func test归档失败或取消保留原文件且同一时间不重复下载() async throws {
        for cancelled in [false, true] {
            let service = PhotoUploadServiceStub(); await service.configureArchive(fails: !cancelled, waits: cancelled)
            let model = SynologyPhotosModel(repository: service); await model.refresh()
            let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: file) }
            let original = Data("keep-existing-archive".utf8); try original.write(to: file)
            let target = SynologyPhotoArchiveTarget.folder(id: 1, space: .personal)
            model.saveArchive(target, format: .original, to: file)
            model.saveArchive(target, format: .original, to: file)
            if cancelled {
                for _ in 0..<1000 { if await !service.archiveCalls.isEmpty { break }; await Task.yield() }
                model.cancelSave()
            }
            for _ in 0..<1000 where model.isSaving { try await Task.sleep(for: .milliseconds(1)) }
            XCTAssertFalse(model.isSaving); XCTAssertEqual(try Data(contentsOf: file), original)
            let calls = await service.archiveCalls; XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(model.saveMessage == nil, cancelled)
        }
    }

    func test整册无下载权不能用本人贡献照片权限代替且目录目标保留空间() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([.personal, .shared])
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: false, canContribute: true))
        let model = SynologyPhotosModel(repository: service)
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
        XCTAssertFalse(model.canDownloadArchive(.album(id: 21)))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        model.saveArchive(.album(id: 21), format: .original, to: file)
        XCTAssertFalse(model.isSaving); XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let calls = await service.archiveCalls; XCTAssertTrue(calls.isEmpty)
        await model.selectSpace(.shared); await model.selectSection(.folders)
        XCTAssertEqual(model.currentArchive?.target, .folder(id: 101, space: .shared))
    }

    func test目录排序保存后当前图库重排且再次打开沿已保存顺序() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.folders)
        let folder = SynologyPhotoCollection(id: 9, name: "Fixture", path: "/Fixture"), sort = SynologyPhotoSort(field: .filesize, direction: .descending)
        await model.open(folder)
        model.submitMutation(.setFolderSort(folder: folder, sort: sort)); await waitForManagement(model)
        XCTAssertEqual(model.section, .folders); XCTAssertEqual(model.currentCoverFolder?.id, 9); XCTAssertEqual(model.currentCoverFolder?.sort, sort)
        XCTAssertFalse(model.items.isEmpty)
        await model.refresh()
        let reads = await service.photoReads, directions = await service.folderDirections
        XCTAssertEqual(reads.last?.0, .folder(id: 9, sort: sort)); XCTAssertEqual(directions.last, .descending)
        let child = SynologyPhotoCollection(id: 10, name: "Child", path: "/Fixture/Child")
        model.submitMutation(.setFolderSort(folder: child, sort: .init(field: .filename))); await waitForManagement(model)
        let later = await service.photoReads; XCTAssertEqual(later.count, reads.count)
        XCTAssertEqual(model.currentCoverFolder?.id, 9)
    }

    func test目录权限提交固定快照且完成不刷新图库或更改空间() async throws {
        let service = FolderSharingServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        let folder = SynologyPhotoCollection(id: 9, name: "Fixture", parentID: 1, path: "/Fixture", space: .shared)
        let original = try await model.folderSharing(folder), reads = await service.timelineReads
        let command = SynologyPhotosMutation.setFolderSharing(original: original, access: .download, members: [], password: nil, appliesToSubfolders: false)
        model.submitMutation(command); await waitForManagement(model)
        let commands = await service.commands, after = await service.timelineReads
        XCTAssertEqual(commands, [command]); XCTAssertEqual(after, reads); XCTAssertEqual(model.selectedSpace, .personal)
        XCTAssertNil(model.pendingMutationID)
    }

    func test目录权限未知自动核对并阻止重提且恢复只读确认() async throws {
        let service = FolderSharingServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await service.setOutcome(.pendingReview)
        let folder = SynologyPhotoCollection(id: 9, name: "Fixture", parentID: 1, path: "/Fixture", space: .shared)
        let original = try await model.folderSharing(folder)
        let command = SynologyPhotosMutation.setFolderSharing(original: original, access: .view, members: nil, password: nil, appliesToSubfolders: true)
        model.submitMutation(command); await waitForManagement(model)
        XCTAssertNotNil(model.pendingMutationID)
        let reviews = await service.reviews; XCTAssertEqual(reviews, 6)
        model.submitMutation(command); await waitForManagement(model)
        let writes = await service.writes; XCTAssertEqual(writes, 1)
        await service.setOutcome(.confirmed); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID)
        let finalWrites = await service.writes; XCTAssertEqual(finalWrites, 1)
    }

    func test共享目录权限入口仅完整共享访问的前两层且读取固定原目标() async throws {
        let service = FolderSharingServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.refresh()
        let folder = SynologyPhotoCollection(id: 9, name: "Fixture", parentID: 1, path: "/Fixture", space: .shared)
        XCTAssertTrue(model.canInspectFolderSharing(folder))
        XCTAssertFalse(model.canInspectFolderSharing(.init(id: 1, name: "Root", path: "/", space: .shared)))
        XCTAssertFalse(model.canInspectFolderSharing(.init(id: 10, name: "Child", path: "/A/B/C", space: .shared)))
        XCTAssertFalse(model.canInspectFolderSharing(.init(id: 9, name: "Fixture", path: "/Fixture")))
        let state = try await model.folderSharing(folder); XCTAssertEqual(state.folder, folder)
        let targets = await service.targets; XCTAssertEqual(targets, [folder])
        let writes = await service.writes; XCTAssertEqual(writes, 0)
    }

    func test目录混合移动完成原地更新复制保留来源且选择空间固定() async throws {
        for copying in [false, true] {
            let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            await model.refresh(); await model.selectSection(.folders); model.selectLoadedItems()
            let photos = model.selectedPhotos, folders = model.selectedFolders, reads = await service.photoReads
            XCTAssertTrue(model.canTransfer(photos, copying: copying, folders: folders))
            let command: SynologyPhotosMutation = copying ? .copy(photos, folderID: 20, folders: folders) : .move(photos, folderID: 20, folders: folders)
            model.submitMutation(command); await waitForManagement(model)
            XCTAssertEqual(model.collections.count, copying ? 1 : 0); XCTAssertEqual(model.items.count, copying ? 1 : 0)
            XCTAssertEqual(model.folderHistory.last?.id, 1); XCTAssertEqual(model.section, .folders)
            let after = await service.photoReads; XCTAssertEqual(after.count, reads.count)
            let commands = await service.commands; XCTAssertEqual(commands, [command])
        }
    }

    func test目录移动核对期间进入来源目录完成后回到原父目录() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.folders)
        let folder = try XCTUnwrap(model.collections.first)
        await service.setSortPending(true)
        model.submitMutation(.move([], folderID: 20, folders: [folder])); await waitForManagement(model)
        XCTAssertNotNil(model.pendingMutationID); await model.open(folder)
        await service.setSortPending(false); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.folderHistory.last?.id, 1); XCTAssertEqual(model.section, .folders); XCTAssertTrue(model.collections.isEmpty)
    }

    func test目录移动迟到结果不移除同编号相册且共享方向与目录冲突一致() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.folders)
        let folder = try XCTUnwrap(model.collections.first)
        await service.setSortPending(true); model.submitMutation(.move([], folderID: 20, folders: [folder])); await waitForManagement(model)
        await model.selectSection(.albums); let albums = model.collections
        await service.setSortPending(false); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.collections, albums)
        let shared = SynologyPhotoCollection(id: 9, name: "Fixture", parentID: 1, path: "/Fixture", space: .shared)
        XCTAssertEqual(model.transferDestinationSpaces(for: [], copying: false, folders: [shared]), [.shared])
        XCTAssertEqual(Set(model.transferDestinationSpaces(for: [], copying: true, folders: [shared])), [.personal, .shared])
        let command = SynologyPhotosMutation.move([], folderID: 20, folders: [folder])
        XCTAssertFalse(command.acceptsTransferDestination(.init(id: 20, name: "Child", path: "/Fixture/Child")))
        XCTAssertFalse(command.acceptsTransferDestination(.init(id: 1, name: "Root", path: "/")))
        XCTAssertTrue(command.acceptsTransferDestination(.init(id: 20, name: "Other", path: "/FixtureOther")))
    }

    func test目录与照片混合选择删除完成保留父目录且只移除已确认目标() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.folders)
        let folder = try XCTUnwrap(model.collections.first)
        model.toggleFolderSelection(folder); XCTAssertTrue(model.isSelecting); XCTAssertEqual(model.selectedFolders, [folder])
        model.selectLoadedItems(); XCTAssertEqual(model.selectedItemCount, model.items.count + model.collections.count)
        let photos = model.selectedPhotos, reads = await service.photoReads
        XCTAssertTrue(model.canDeleteSelection); XCTAssertFalse(model.canManageSelection)
        model.submitMutation(.deleteFolderItems(photos: photos, folders: model.selectedFolders)); await waitForManagement(model)
        XCTAssertTrue(model.collections.isEmpty); XCTAssertTrue(model.items.isEmpty); XCTAssertEqual(model.selectedItemCount, 0)
        XCTAssertEqual(model.folderHistory.last?.id, 1); XCTAssertEqual(model.section, .folders)
        let after = await service.photoReads; XCTAssertEqual(after.count, reads.count)
    }

    func test目录选择全选取消和导航不污染其他空间或相册() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSection(.folders)
        model.selectLoadedItems(); XCTAssertFalse(model.selectedFolders.isEmpty)
        model.selectLoadedItems(); XCTAssertEqual(model.selectedItemCount, 0)
        model.toggleFolderSelection(try XCTUnwrap(model.collections.first)); model.clearSelection()
        XCTAssertTrue(model.selectedFolderIDs.isEmpty); XCTAssertFalse(model.isSelecting)
        model.selectLoadedItems(); await model.selectSection(.albums)
        XCTAssertTrue(model.selectedFolders.isEmpty); XCTAssertTrue(model.selectedFolderIDs.isEmpty)
    }

    func test删除核对期间进入目标目录完成后退回父目录而不是时间线() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.folders)
        let folder = try XCTUnwrap(model.collections.first)
        await service.setSortPending(true)
        model.submitMutation(.deleteFolderItems(photos: [], folders: [folder])); await waitForManagement(model)
        XCTAssertEqual(model.automaticMutationReviewID, model.pendingMutationID)
        XCTAssertNotNil(model.automaticMutationReviewID)
        XCTAssertEqual(model.managementMessage, L10n.string("photos.selection.reviewContinuing"))
        await model.open(folder); XCTAssertEqual(model.folderHistory.last?.id, folder.id)
        await service.setSortPending(false); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.section, .folders); XCTAssertEqual(model.folderHistory.last?.id, 1)
        XCTAssertTrue(model.collections.isEmpty); XCTAssertTrue(model.items.allSatisfy { $0.folderID == 1 }); XCTAssertNil(model.pendingMutationID)
    }

    func test目录删除迟到确认不移除同编号相册() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.folders)
        let folder = try XCTUnwrap(model.collections.first)
        await service.setSortPending(true)
        model.submitMutation(.deleteFolderItems(photos: [], folders: [folder])); await waitForManagement(model)
        XCTAssertNotNil(model.pendingMutationID); await model.selectSection(.albums); let albums = model.collections
        await service.setSortPending(false); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID); XCTAssertEqual(model.collections, albums)
    }

    func test列表排序范围分页与返回读取保持独立偏好() async throws {
        let service = PhotoUploadServiceStub(), fixtures = (1...5).map { SynologyPhotoCollection(id: $0, name: "Fixture \($0)") }
        await service.setSpaces([]); await service.configureLists(fixtures)
        let model = SynologyPhotosModel(repository: service, pageSize: 2, deletionReviewDelay: { _ in })
        await model.selectSection(.albums)
        XCTAssertEqual(model.albumListScope, .albums); XCTAssertEqual(model.albumListDisplay, .all)
        model.changeAlbumListDisplay(.mine); await waitForManagement(model)
        let sort = SynologyPhotoAlbumListSort(field: .created, direction: .descending)
        model.changeAlbumListSort(sort); await waitForManagement(model); await model.loadMoreCollections()
        XCTAssertEqual(model.collections, Array(fixtures.prefix(4))); XCTAssertEqual(model.albumListDisplay, .mine)
        let calls = await service.listCalls
        XCTAssertEqual(calls.last?.0, .albums); XCTAssertEqual(calls.last?.1, .mine); XCTAssertEqual(calls.last?.2, sort); XCTAssertEqual(calls.last?.3, 2)
        await model.selectSection(.sharing)
        XCTAssertEqual(model.albumListScope, .withMe); XCTAssertEqual(model.albumListSort?.field, .name); XCTAssertNil(model.albumListDisplay)
        let shared = SynologyPhotoAlbumListSort(field: .shareModified, direction: .ascending)
        model.changeAlbumListSort(shared); await waitForManagement(model); await model.loadMoreCollections()
        XCTAssertEqual(model.sharedEntries.count, 4)
        await model.selectShareScope(.withOthers); XCTAssertEqual(model.albumListScope, .byMe); XCTAssertEqual(model.albumListSort?.field, .name)
        await model.selectShareScope(.withMe); XCTAssertEqual(model.albumListSort, shared)
        await model.selectSection(.albums); XCTAssertEqual(model.albumListSort, sort); XCTAssertEqual(model.albumListDisplay, .mine)
        let commands = await service.commands; XCTAssertEqual(commands.count, 3)
        model.changeAlbumListSort(sort); await waitForManagement(model)
        let repeated = await service.commands; XCTAssertEqual(repeated, commands)
    }

    func test列表偏好迟到响应不覆盖新导航范围() async throws {
        let service = PhotoUploadServiceStub(); await service.configureLists([.init(id: 21, name: "Fixture")]); await service.holdNextListPreferences()
        let model = SynologyPhotosModel(repository: service)
        let loading = Task { await model.selectSection(.albums) }
        await service.waitUntilPageHeld()
        await model.selectSection(.sharing); await model.selectShareScope(.requests)
        XCTAssertNil(model.albumListScope); XCTAssertNil(model.albumListSort)
        await service.releasePage(); await loading.value
        XCTAssertEqual(model.section, .sharing); XCTAssertEqual(model.shareScope, .requests)
        XCTAssertNil(model.albumListSort); XCTAssertNil(model.albumListDisplay)
    }

    func test列表偏好读取失败仍可浏览且收集及相册内容无列表入口() async throws {
        let service = PhotoUploadServiceStub(); await service.configureLists([.init(id: 21, name: "Fixture")], fails: true)
        let model = SynologyPhotosModel(repository: service)
        await model.selectSection(.albums)
        XCTAssertEqual(model.collections.count, 1); XCTAssertNil(model.albumListSort); XCTAssertNil(model.albumListDisplay)
        XCTAssertNotNil(model.managementMessage); XCTAssertNil(model.errorMessage)
        let calls = await service.listCalls; XCTAssertNil(calls.last?.1); XCTAssertNil(calls.last?.2)
        await model.open(.init(id: 21, name: "Fixture")); XCTAssertNil(model.albumListScope)
        await model.selectSection(.sharing); await model.selectShareScope(.requests); XCTAssertNil(model.albumListScope); XCTAssertNil(model.albumListSort)
    }

    func test相册读取保存分页排序保留选择且重复点击不重写() async throws {
        let service = PhotoUploadServiceStub(), originals = mixedAlbumFixtures()
        await service.setSpaces([.personal, .shared]); await service.setAlbumPhotos(originals)
        await service.configureAlbumSort(.init(field: .filesize, direction: .ascending))
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: false, canContribute: false))
        let model = SynologyPhotosModel(repository: service, pageSize: 2, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture"))
        XCTAssertEqual(model.currentSortAlbum?.sort, .init(field: .filesize, direction: .ascending))
        model.toggleSelection(originals[0]); let selection = model.selectedPhotoIDs
        let sorted = Array(originals.reversed()), order = SynologyPhotoSort(field: .filename, direction: .descending)
        await service.setAlbumPhotos(sorted)
        model.changeCurrentAlbumSort(order); await waitForManagement(model)
        XCTAssertEqual(model.items, Array(sorted.prefix(2))); XCTAssertEqual(model.selectedPhotoIDs, selection)
        XCTAssertEqual(model.selectedAlbum?.id, 21); XCTAssertEqual(model.currentSortAlbum?.sort, order)
        await model.loadMore(); XCTAssertEqual(model.items, Array(sorted.prefix(4)))
        let calls = await service.spaceQueries
        XCTAssertEqual(Array(calls.suffix(2)).map(\.1), [.album(id: 21, sort: order), .album(id: 21, sort: order)])
        model.changeCurrentAlbumSort(order); await waitForManagement(model)
        let commands = await service.commands
        XCTAssertEqual(commands, [.setAlbumSort(id: 21, original: .init(field: .filesize, direction: .ascending), sort: order)])
        await model.refresh(); XCTAssertEqual(model.currentSortAlbum?.sort, order)
        await model.selectSection(.timeline); XCTAssertNil(model.currentSortAlbum)
    }

    func test相册排序个人空间关闭仍开放且读取失败不阻断照片() async throws {
        for fails in [false, true] {
            let service = PhotoUploadServiceStub(), photo = collaborationPhoto(provider: 99)
            await service.setSpaces([]); await service.setAlbumPhoto(photo)
            await service.configureAlbumSort(.init(field: .itemType), fails: fails)
            await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: false, canContribute: false))
            let model = SynologyPhotosModel(repository: service)
            await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture"))
            XCTAssertEqual(model.items, [photo]); XCTAssertNil(model.errorMessage)
            XCTAssertNotNil(model.currentSortAlbum)
            XCTAssertEqual(model.currentSortAlbum?.sort, fails ? .init(direction: .descending) : .init(field: .itemType))
            if fails { XCTAssertNotNil(model.managementMessage) }
        }
    }

    func test相册上传后使用当前排序回读而非按拍摄时间重排() async throws {
        let service = PhotoUploadServiceStub(), photo = collaborationPhoto(provider: 12)
        await service.setSpaces([]); await service.setAlbumPhoto(photo)
        let order = SynologyPhotoSort(field: .filename)
        await service.configureAlbumSort(order)
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture")); model.toggleSelection(photo)
        model.enqueueUploads(makeUploadFiles(), album: model.selectedAlbum, folder: nil); await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed]); XCTAssertFalse(model.needsAlbumRefresh)
        XCTAssertEqual(model.items.count, 3); XCTAssertEqual(model.items.first, photo)
        XCTAssertTrue(model.selectedPhotoIDs.isEmpty, "开始上传沿用退出选择模式的既有行为"); XCTAssertEqual(model.currentSortAlbum?.sort, order)
        let calls = await service.spaceQueries
        XCTAssertTrue(calls.suffix(2).allSatisfy { $0.1 == .album(id: 21, sort: order) })
    }

    func test主页面排序支持根目录且保留当前目录和选择并忽略重复设置() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); XCTAssertNil(model.currentSortFolder)
        await model.selectSection(.folders)
        XCTAssertEqual(model.currentSortFolder?.folder.id, 1)
        let sort = SynologyPhotoSort(field: .filename, direction: .descending)
        model.selectGroup(model.items); let selected = model.selectedPhotoIDs
        model.changeCurrentFolderSort(sort); await waitForManagement(model)
        XCTAssertEqual(model.currentSortFolder?.sort, sort); XCTAssertEqual(model.currentSortFolder?.folder.id, 1)
        XCTAssertEqual(model.selectedPhotoIDs, selected); XCTAssertEqual(model.section, .folders)
        model.changeCurrentFolderSort(sort); await waitForManagement(model)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        await model.selectSection(.timeline); XCTAssertNil(model.currentSortFolder)
        model.changeCurrentFolderSort(.init()); let after = await service.commands; XCTAssertEqual(after, commands)
    }

    func test新建目录重读分页保持照片选择并支持个人共享空间() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let service = FolderCoverServiceStub()
            await service.setFolderFixtures((0..<5).map { .init(id: 20 + $0, name: "Folder \($0)", parentID: 1, space: space) })
            let model = SynologyPhotosModel(repository: service, pageSize: 2, deletionReviewDelay: { _ in })
            await model.refresh(); await model.selectSpace(space); await model.selectSection(.folders)
            await model.loadMoreCollections()
            XCTAssertEqual(model.collections.count, 4)
            let parent = try XCTUnwrap(model.currentCreationFolder)
            let photos = model.items; model.selectGroup(photos)
            let selection = model.selectedPhotoIDs, reads = await service.photoReads.count
            model.submitMutation(.createFolder(parentID: parent.id, name: "A new folder", space: parent.space))
            await waitForManagement(model)
            XCTAssertEqual(model.collections.map(\.name), ["A new folder", "Folder 0", "Folder 1", "Folder 2"])
            XCTAssertEqual(model.items, photos); XCTAssertEqual(model.selectedPhotoIDs, selection)
            XCTAssertEqual(model.currentCreationFolder, parent)
            let after = await service.photoReads.count; XCTAssertEqual(after, reads)
            await model.loadMoreCollections(); await model.loadMoreCollections()
            XCTAssertEqual(model.collections.map(\.name), ["A new folder", "Folder 0", "Folder 1", "Folder 2", "Folder 3", "Folder 4"])
            XCTAssertFalse(model.hasMoreCollections)
        }
    }

    func test新建目录待核对不重复提交且迟到确认不覆盖相册() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.folders)
        await service.setSortPending(true)
        let command = SynologyPhotosMutation.createFolder(parentID: 1, name: "New folder")
        model.submitMutation(command); await waitForManagement(model)
        XCTAssertNotNil(model.automaticMutationReviewID)
        model.submitMutation(command); await waitForManagement(model)
        await model.selectSection(.albums); let albums = model.collections
        XCTAssertNil(model.currentCreationFolder)
        await service.setSortPending(false); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID); XCTAssertEqual(model.collections, albums)
        let commands = await service.commands; XCTAssertEqual(commands, [command])
    }

    func test新建目录成功但列表失败不要求重新创建() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.folders)
        let photos = model.items
        await service.configure(.failure)
        model.submitMutation(.createFolder(parentID: 1, name: "New folder")); await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID); XCTAssertEqual(model.items, photos)
        XCTAssertEqual(model.managementMessage, L10n.string("photos.folder.createdRefreshFailed"))
        await service.configure(.normal); await model.loadMoreCollections()
        XCTAssertTrue(model.collections.contains { $0.name == "New folder" })
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test目录重命名只更新固定目录和后代路径不重读图库且保持选择() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.folders)
        let folder = try XCTUnwrap(model.collections.first)
        model.submitMutation(.renameFolder(folder: folder, name: "Renamed")); await waitForManagement(model)
        XCTAssertEqual(model.collections.first?.name, "Renamed"); XCTAssertEqual(model.collections.first?.path, "/Renamed")
        await model.open(folder); model.selectGroup(model.items)
        let ids = model.selectedPhotoIDs, reads = await service.photoReads
        model.submitMutation(.renameFolder(folder: folder, name: "Renamed")); await waitForManagement(model)
        XCTAssertEqual(model.folderHistory.last?.name, "Renamed"); XCTAssertEqual(model.collections.first?.path, "/Renamed/Child")
        XCTAssertEqual(model.selectedPhotoIDs, ids); XCTAssertEqual(model.section, .folders)
        let after = await service.photoReads; XCTAssertEqual(after.count, reads.count)
    }

    func test目录重命名迟到确认不覆盖同编号相册且保留月份() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); await service.setSortPending(true)
        model.submitMutation(.renameFolder(folder: .init(id: 9, name: "Fixture", path: "/Fixture"), name: "Renamed"))
        await waitForManagement(model); XCTAssertNotNil(model.pendingMutationID); XCTAssertEqual(model.selectedTimelineMonthID, 202003)
        await model.selectSection(.albums); let albums = model.collections
        await service.setSortPending(false); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.collections, albums); XCTAssertNil(model.pendingMutationID)
    }

    func test目录排序迟到确认不会覆盖同编号相册() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await service.setSortPending(true)
        model.submitMutation(.setFolderSort(folder: .init(id: 9, name: "Fixture folder", path: "/Fixture"), sort: .init(field: .filename)))
        await waitForManagement(model); XCTAssertNotNil(model.pendingMutationID)
        await model.selectSection(.albums)
        let albums = model.collections; XCTAssertEqual(albums.map(\.name), ["Fixture album"])
        await service.setSortPending(false); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID); XCTAssertEqual(model.collections, albums); XCTAssertEqual(model.section, .albums)
    }

    func test封面排序分页及子目录读取沿固定空间和排序且不保存() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
        let selected = model.selectedPhotoIDs, folder = SynologyPhotoCollection(id: 9, name: "Fixture", path: "/Fixture", space: .shared)
        let sort = SynologyPhotoSort(field: .itemType, direction: .descending)
        _ = try await model.folderCoverPage(folder, offset: 100, sort: sort)
        _ = try await model.folderCoverChildren(folder, direction: sort.direction)
        let reads = await service.photoReads, commands = await service.commands, directions = await service.folderDirections
        XCTAssertEqual(reads.last?.0, .folder(id: 9, sort: sort)); XCTAssertEqual(reads.last?.1, 100); XCTAssertEqual(directions.last, .descending)
        XCTAssertTrue(commands.isEmpty); XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.selectedPhotoIDs, selected)
    }

    func test目录封面完成只更新封面版本并保留图库月份选择和原目标() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
        let ids = model.selectedPhotoIDs, photo = try XCTUnwrap(model.items.first), revision = model.folderCoverRevision
        let target = SynologyPhotoCollection(id: 9, name: "Fixture", path: "/Fixture")
        model.submitMutation(.setFolderCover(folder: target, photo: photo))
        for _ in 0..<1000 where model.isManaging { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(model.isManaging); XCTAssertEqual(model.folderCoverRevision, revision + 1)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.selectedPhotoIDs, ids)
        let commands = await service.commands; XCTAssertEqual(commands, [.setFolderCover(folder: target, photo: photo)])
        await model.selectSection(.folders); XCTAssertNil(model.currentCoverFolder)
        await model.open(target); XCTAssertEqual(model.currentCoverFolder?.id, 9)
    }

    func test目录封面选择数据固定空间且读取不会提交写操作() async throws {
        let service = FolderCoverServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.refresh()
        let folder = SynologyPhotoCollection(id: 9, name: "Fixture", path: "/Fixture", space: .shared)
        let page = try await model.folderCoverPage(folder, offset: 0), children = try await model.folderCoverChildren(folder)
        XCTAssertEqual(page.items.first?.id.space, .shared); XCTAssertTrue(children.allSatisfy { $0.space == .shared && $0.parentID == 9 })
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        let images = try await model.folderCoverImages(folder); XCTAssertTrue(images.isEmpty)
    }

    func test原尺寸JPEG保存保留月份且只允许实际能力下单选并正确命名() async throws {
        let service = SharedCategoryServiceStub(), model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
        let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.HEIC", sizeBytes: 128,
            takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertFalse(model.canDownloadOriginalSizeJPEG(photo))
        model.savePhotos([photo], to: directory, format: .originalSizeJPEG); XCTAssertFalse(model.isSaving)
        await service.setOriginalSizeJPEG(true); await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
        XCTAssertTrue(model.canDownloadOriginalSizeJPEG(photo))
        model.savePhotos([photo, photo], to: directory, format: .originalSizeJPEG); XCTAssertFalse(model.isSaving)
        model.savePhotos([photo], to: directory, format: .originalSizeJPEG, includingSimilarMembers: true); XCTAssertFalse(model.isSaving)
        let previous = Data("preserve".utf8); try previous.write(to: directory.appendingPathComponent("fixture.jpg"))
        model.savePhotos([photo], to: directory, format: .originalSizeJPEG)
        for _ in 0..<1000 where model.isSaving { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(model.isSaving); XCTAssertEqual(model.selectedTimelineMonthID, 202003)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["fixture.jpg", "fixture (1).jpg"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("fixture.jpg")), previous)
        let calls = await service.downloadRequests; XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?.1, .originalSizeJPEG)
        await service.setOriginalSizeJPEG(false); await model.refresh(); XCTAssertFalse(model.canDownloadOriginalSizeJPEG(photo))
    }

    func test原尺寸JPEG格式范围与协作相册下载权限() async throws {
        let supported = ["HEIC", "heif", "hif", "tif", "tiff", "arw", "srf", "sr2", "dcr", "k25", "kdc", "cr2", "cr3", "crw", "nef", "mrw", "ptx", "pef", "raf", "3fr", "erf", "mef", "mos", "orf", "rw2", "dng", "x3f", "raw"]
        for ext in supported + ["jpg", "jpeg", "png", "gif", "webp", "mov"] {
            let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.\(ext)", sizeBytes: 128,
                takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo")
            XCTAssertEqual(photo.supportsOriginalSizeJPEG, supported.contains(ext))
        }
        let service = SharedCategoryServiceStub(), model = SynologyPhotosModel(repository: service)
        await service.setOriginalSizeJPEG(true); await model.refresh()
        let foreign = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.heic", sizeBytes: 128,
            takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: "photo", albumContext: .init(albumID: 21, ownerUserID: 88))
        XCTAssertFalse(model.canDownloadOriginalSizeJPEG(foreign))
        model.setModuleEnabled(false); XCTAssertFalse(model.canDownloadOriginalSizeJPEG(foreign))
    }

    func test压缩保存按实际格式命名且不覆盖已有文件() async throws {
        let service = SharedCategoryServiceStub()
        let subject = SynologyPhotosModel(repository: service)
        await subject.refresh()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let previous = Data("preserve".utf8); try previous.write(to: folder.appendingPathComponent("fixture.jpg"))
        let photos = [(7, "fixture.heic", "photo"), (8, "clip.mov", "video")].map { id, name, type in
            SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: id), filename: name, sizeBytes: 128,
                takenAt: .distantPast, indexedAt: .distantPast, folderID: 9, mediaType: type)
        }
        subject.savePhotos(photos, to: folder, format: .optimizedJPEG)
        for _ in 0..<1000 where subject.isSaving { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(subject.isSaving)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: folder.path)), ["fixture.jpg", "fixture (1).jpg", "clip.mov"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("fixture.jpg")), previous)
        let requests = await service.downloadRequests
        XCTAssertEqual(requests.map { $0.0 }, [7, 8]); XCTAssertTrue(requests.allSatisfy { $0.1 == .optimizedJPEG })
        XCTAssertNotNil(subject.saveMessage)
    }

    func test下载相似组包含全部成员且保持月份和原选择() async throws {
        let service = SharedCategoryServiceStub()
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
        let selected = model.selectedPhotoIDs
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.saveSelection(to: folder)
        for _ in 0..<1000 where model.isSaving { try await Task.sleep(for: .milliseconds(1)) }
        let requests = await service.downloadRequests
        XCTAssertEqual(requests.map { $0.0 }, [7, 8]); XCTAssertTrue(requests.allSatisfy { $0.1 == .original })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 2)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.selectedPhotoIDs, selected)
    }

    func test相似批量核对失败不自动继续且可以取消剩余组() async throws {
        let service = SharedCategoryServiceStub()
        await service.enableSecondSimilarGroup(); await service.enableAutomaticSimilarMutations(pendingReviews: 6)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        model.selectGroup(model.items)
        let prepared = await model.prepareSelectedSimilarGroups(), groups = try XCTUnwrap(prepared)
        model.ungroupSimilarSelection(groups); await waitForManagement(model)
        await service.configurePendingSimilarResult(.init(state: .rejected))
        model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID); XCTAssertTrue(model.hasSimilarBatchToContinue)
        let calls = await service.similarCommands; XCTAssertEqual(calls.count, 1)
        model.cancelRemainingSimilarGroups()
        XCTAssertFalse(model.hasSimilarBatchToContinue); XCTAssertEqual(model.items.count, 2)
    }

    func test相似多组拆分一次确认顺序处理且撤销全部已完成组() async throws {
        let service = SharedCategoryServiceStub()
        await service.enableSecondSimilarGroup(); await service.enableAutomaticSimilarMutations()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        await model.jumpToMonth(.init(year: 2020, month: 3))
        model.selectGroup(model.items)
        let prepared = await model.prepareSelectedSimilarGroups(), groups = try XCTUnwrap(prepared)
        XCTAssertEqual(groups.count, 2)
        model.ungroupSimilarSelection(groups); await waitForManagement(model)
        XCTAssertTrue(model.items.isEmpty); XCTAssertNotNil(model.similarUndoMutation)
        model.undoSimilarChanges(); await waitForManagement(model)
        XCTAssertEqual(Set(model.items.map { $0.similarGroup?.id }), [31, 32]); XCTAssertNil(model.similarUndoMutation)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003)
        let calls = await service.similarCommands; XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.prefix(2), groups.map { .editSimilarGroup($0, .ungroup) }[...])
    }

    func test相似批量遇未知暂停后续并只核对当前项后继续() async throws {
        let service = SharedCategoryServiceStub()
        await service.enableSecondSimilarGroup(); await service.enableAutomaticSimilarMutations(pendingReviews: 6)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        model.selectGroup(model.items)
        let prepared = await model.prepareSelectedSimilarGroups(), groups = try XCTUnwrap(prepared)
        model.ungroupSimilarSelection(groups); await waitForManagement(model)
        XCTAssertNotNil(model.pendingMutationID); XCTAssertFalse(model.hasSimilarBatchToContinue)
        let first = await service.similarCommands; XCTAssertEqual(first.count, 1)
        model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID); XCTAssertTrue(model.items.isEmpty)
        let after = await service.similarCommands; XCTAssertEqual(after.count, 2)
        model.undoSimilarChanges(); await waitForManagement(model)
        XCTAssertEqual(model.items.count, 2); XCTAssertNil(model.similarUndoMutation)
    }

    func test相似保留所选删除固定其余照片并在原月份移除解散组() async throws {
        let service = SharedCategoryServiceStub()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        await model.jumpToMonth(.init(year: 2020, month: 3))
        model.showPreview(try XCTUnwrap(model.items.first))
        for _ in 0..<100 where model.isPreparingPreview || model.isLoadingSimilarPreview { try await Task.sleep(nanoseconds: 1_000_000) }
        let detail = try XCTUnwrap(model.previewSimilarDetail), kept = try XCTUnwrap(model.previewSimilarDetail?.photos.first)
        model.requestSimilarCleanup(detail, keeping: [kept.id])
        for _ in 0..<100 where model.isCheckingDeletion { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(model.deletionKeptCount, 1); XCTAssertEqual(model.deletionCandidates.map { $0.id.unitID }, [8])
        let before = await service.similarDeletedIDs; XCTAssertTrue(before.isEmpty)
        let fixed = model.deletionCandidates
        model.similarSelectedIDs = [fixed[0].id]
        model.confirmDeletion(fixed)
        for _ in 0..<100 where model.isDeleting { try await Task.sleep(nanoseconds: 1_000_000) }
        let deleted = await service.similarDeletedIDs; XCTAssertEqual(deleted.map { $0.unitID }, [8])
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertTrue(model.items.isEmpty); XCTAssertNil(model.similarRefreshError)
    }

    func test相似清理刷新失败只重试分组且保留两张时更新数量() async throws {
        let service = SharedCategoryServiceStub()
        await service.configureSimilarMembers([7, 8, 9])
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        model.showPreview(try XCTUnwrap(model.items.first))
        for _ in 0..<100 where model.isPreparingPreview || model.isLoadingSimilarPreview { try await Task.sleep(nanoseconds: 1_000_000) }
        let detail = try XCTUnwrap(model.previewSimilarDetail)
        model.requestSimilarCleanup(detail, keeping: Set(detail.photos.prefix(2).map { $0.id }))
        for _ in 0..<100 where model.isCheckingDeletion { try await Task.sleep(nanoseconds: 1_000_000) }
        let targets = model.deletionCandidates; XCTAssertEqual(targets.count, 1)
        await service.configureSimilarRefresh(fails: true)
        model.confirmDeletion(targets)
        for _ in 0..<100 where model.isDeleting { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNotNil(model.similarRefreshError)
        await service.configureSimilarRefresh(fails: false)
        await model.refreshAffectedSimilarGroups()
        XCTAssertNil(model.similarRefreshError); XCTAssertEqual(model.items.first?.similarGroup?.photoIDs, [7, 8])
        let deleted = await service.similarDeletedIDs; XCTAssertEqual(deleted.map { $0.unitID }, [9])
    }

    func test相似清理拒绝空选择全选择与已改变成员() async throws {
        let service = SharedCategoryServiceStub()
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        model.showPreview(try XCTUnwrap(model.items.first))
        for _ in 0..<100 where model.isPreparingPreview || model.isLoadingSimilarPreview { try await Task.sleep(nanoseconds: 1_000_000) }
        let detail = try XCTUnwrap(model.previewSimilarDetail)
        model.requestSimilarCleanup(detail, keeping: []); XCTAssertFalse(model.isCheckingDeletion)
        model.requestSimilarCleanup(detail, keeping: Set(detail.photos.map { $0.id })); XCTAssertFalse(model.isCheckingDeletion)
        await service.configureSimilarMembers([7, 8, 9])
        model.requestSimilarCleanup(detail, keeping: [detail.photos[0].id])
        for _ in 0..<100 where model.isCheckingDeletion { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertTrue(model.deletionCandidates.isEmpty); XCTAssertNotNil(model.similarPreviewError)
        let deleted = await service.similarDeletedIDs; XCTAssertTrue(deleted.isEmpty)
    }

    func test相似状态仅在分类读取且离开后清理() async throws {
        let service = SharedCategoryServiceStub()
        let subject = SynologyPhotosModel(repository: service)
        await subject.refresh(); await subject.refreshSimilarStatus(); XCTAssertNil(subject.similarStatus)
        await subject.selectSection(.albums); await subject.openCategory(.similar)
        await service.configureSimilarStatus(.init(waitingCount: 12, stage: "running", migrationComplete: true))
        await subject.refreshSimilarStatus(); XCTAssertTrue(subject.similarStatus?.isRunning == true)
        await subject.selectSection(.timeline); await subject.refreshSimilarStatus(); XCTAssertNil(subject.similarStatus)
    }

    func test相似拆组与撤销原位更新月份且不重新加载图库() async throws {
        let service = SharedCategoryServiceStub()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        await model.jumpToMonth(.init(year: 2020, month: 3))
        model.showPreview(try XCTUnwrap(model.items.first))
        for _ in 0..<100 where model.isPreparingPreview || model.isLoadingSimilarPreview { try await Task.sleep(nanoseconds: 1_000_000) }
        let original = try XCTUnwrap(model.previewSimilarDetail)
        let removed = original.photos.map { photo in var updated = photo; updated.similarGroup = nil; return updated }
        await service.configureSimilarMutation(.init(state: .confirmed, photos: removed, completedCount: 1))
        model.submitMutation(.editSimilarGroup(original, .ungroup)); await waitForManagement(model)
        XCTAssertTrue(model.items.isEmpty); XCTAssertNotNil(model.previewPhoto); XCTAssertNil(model.previewSimilarDetail)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003)
        let undo = try XCTUnwrap(model.similarUndoMutation)
        await service.configureSimilarMutation(.init(state: .confirmed, photos: original.photos, completedCount: 1, similarGroup: original.group))
        model.submitMutation(undo); await waitForManagement(model)
        XCTAssertEqual(model.items.count, 1); XCTAssertEqual(model.items.first?.id.unitID, 8)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertNil(model.similarUndoMutation)
        XCTAssertEqual(model.previewSimilarDetail?.group, original.group)
        let commands = await service.similarCommands; XCTAssertEqual(commands.count, 2)
    }

    func test相似拆组后切换月份再撤销不插入旧月份照片() async throws {
        let service = SharedCategoryServiceStub()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        await model.jumpToMonth(.init(year: 2020, month: 3))
        model.showPreview(try XCTUnwrap(model.items.first))
        for _ in 0..<100 where model.isPreparingPreview || model.isLoadingSimilarPreview { try await Task.sleep(nanoseconds: 1_000_000) }
        let original = try XCTUnwrap(model.previewSimilarDetail)
        let removed = original.photos.map { photo in var updated = photo; updated.similarGroup = nil; return updated }
        await service.configureSimilarMutation(.init(state: .confirmed, photos: removed, completedCount: 1))
        model.submitMutation(.editSimilarGroup(original, .ungroup)); await waitForManagement(model)
        let undo = try XCTUnwrap(model.similarUndoMutation)
        model.closePreview(); await service.configure(empty: true)
        await model.jumpToMonth(.init(year: 2020, month: 4))
        await service.configureSimilarMutation(.init(state: .confirmed, photos: original.photos, completedCount: 1, similarGroup: original.group))
        model.submitMutation(undo); await waitForManagement(model)
        XCTAssertTrue(model.items.isEmpty); XCTAssertEqual(model.selectedTimelineMonthID, 202004)
    }

    func test相似推荐更新不改变预览照片且原位更新代表照片() async throws {
        let service = SharedCategoryServiceStub()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.similar)
        model.showPreview(try XCTUnwrap(model.items.first))
        for _ in 0..<100 where model.isPreparingPreview || model.isLoadingSimilarPreview { try await Task.sleep(nanoseconds: 1_000_000) }
        let original = try XCTUnwrap(model.previewSimilarDetail)
        let group = SynologyPhotoSimilarGroup(profileID: original.group.profileID, space: original.group.space, id: original.group.id, photoIDs: original.group.photoIDs, topPickID: 7)
        let photos = original.photos.map { photo in var updated = photo; updated.similarGroup = group; return updated }
        await service.configureSimilarMutation(.init(state: .confirmed, photos: photos, completedCount: 1, similarGroup: group))
        model.submitMutation(.editSimilarGroup(original, .topPick(7))); await waitForManagement(model)
        XCTAssertEqual(model.previewPhoto?.id.unitID, 7); XCTAssertEqual(model.previewSimilarDetail?.group.topPickID, 7)
        XCTAssertEqual(model.items.first?.id.unitID, 7); XCTAssertNil(model.similarUndoMutation)
    }

    func test相似照片按月份跳转并在组内切换预览且保留位置() async throws {
        let service = SharedCategoryServiceStub()
        let subject = SynologyPhotosModel(repository: service)
        await subject.refresh(); await subject.selectSection(.albums); await subject.openCategory(.similar)
        await subject.jumpToMonth(.init(year: 2020, month: 3))
        let original = try XCTUnwrap(subject.items.first)
        subject.showPreview(original)
        for _ in 0..<100 where subject.isPreparingPreview || subject.isLoadingSimilarPreview { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(subject.previewSimilarDetail?.photos.count, 2)
        XCTAssertEqual(subject.previewSimilarDetail?.group.topPickID, 8)
        subject.adjacentPreview(1)
        for _ in 0..<100 where subject.isPreparingPreview { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(subject.previewPhoto?.id.unitID, 8)
        XCTAssertEqual(subject.selectedTimelineMonthID, 202003)
        XCTAssertEqual(subject.selectedCategory, .similar); XCTAssertEqual(subject.items.first?.id, original.id)
        let reads = await service.similarReads; XCTAssertEqual(reads, 1)
        subject.closePreview(); XCTAssertNil(subject.previewSimilarDetail)
        XCTAssertEqual(subject.selectedTimelineMonthID, 202003)
    }

    func test相似预览读取失败可重试且关闭后迟到结果丢弃() async throws {
        let service = SharedCategoryServiceStub()
        let subject = SynologyPhotosModel(repository: service)
        await subject.refresh(); await subject.selectSection(.albums); await subject.openCategory(.similar)
        let photo = try XCTUnwrap(subject.items.first)
        await service.configureSimilar(fails: true)
        subject.showPreview(photo)
        for _ in 0..<100 where subject.isPreparingPreview || subject.isLoadingSimilarPreview { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertNotNil(subject.similarPreviewError); XCTAssertNotNil(subject.previewData); XCTAssertNil(subject.previewError)
        await service.configureSimilar(fails: false)
        await subject.retrySimilarPreview(); XCTAssertNotNil(subject.previewSimilarDetail)
        await service.configureSimilar(hold: true)
        subject.showPreview(photo); await service.waitForSimilar()
        subject.closePreview(); await service.releaseSimilar()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(subject.previewSimilarDetail); XCTAssertNil(subject.previewPhoto); XCTAssertFalse(subject.isLoadingSimilarPreview)
    }

    func test相似分类搜索离开分组并保留搜索关键词() async throws {
        let service = SharedCategoryServiceStub()
        let subject = SynologyPhotosModel(repository: service)
        await subject.refresh(); await subject.selectSection(.albums); await subject.openCategory(.similar)
        subject.searchText = "sample"; await subject.refresh()
        XCTAssertNil(subject.selectedCategory); XCTAssertEqual(subject.searchText, "sample"); XCTAssertTrue(subject.isFiltering)
        XCTAssertNil(subject.items.first?.similarGroup)
    }

    func test分类拼图固定当前空间且不能读取未展示类别() async throws {
        let service = SharedCategoryServiceStub()
        await service.configurePreviews([Data([1]), Data([2])])
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSpace(.shared); await model.selectSection(.albums)
        let images = try await model.categoryPreviewImages(.person, in: .shared)
        XCTAssertEqual(images, [Data([1]), Data([2])])
        do { _ = try await model.categoryPreviewImages(.person, in: .personal); XCTFail("拒绝过时来源") }
        catch is CancellationError { }
        await model.openCategory(.person)
        do { _ = try await model.categoryPreviewImages(.person, in: .shared); XCTFail("离开首页不再读卡片") }
        catch is CancellationError { }
        let reads = await service.previewReads
        XCTAssertEqual(reads.count, 1); XCTAssertEqual(reads.first?.1, .shared)
    }

    func test分类拼图迟到结果不能覆盖新空间或阻断分类浏览() async throws {
        let service = SharedCategoryServiceStub()
        await service.configurePreviews([Data([1])], hold: true)
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSection(.albums)
        let pending = Task { try await model.categoryPreviewImages(.tags, in: .personal) }
        await service.waitForPreview()
        await model.selectSpace(.shared)
        await service.releasePreview()
        do { _ = try await pending.value; XCTFail("旧空间图片必须丢弃") }
        catch is CancellationError { }
        await service.configurePreviews([], fails: true)
        do { _ = try await model.categoryPreviewImages(.tags, in: .shared); XCTFail("封面读取失败") }
        catch { }
        XCTAssertNil(model.errorMessage)
        await model.openCategory(.tags)
        XCTAssertEqual(model.collections.count, 2); XCTAssertTrue(model.collections.allSatisfy { $0.space == .shared })
    }

    func test共享人物改名隐藏与恢复原位更新且读取同一空间() async throws {
        let service = DatePhotoServiceStub(space: .shared)
        await service.configureRequestAccess(spaces: [.shared], manager: true); await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.person)
        let original = try XCTUnwrap(model.collections.first)
        XCTAssertEqual(original.space, .shared)
        let before = await service.requests.count
        model.submitMutation(.renamePerson(original, name: "Shared name")); await waitForManagement(model)
        XCTAssertEqual(model.collections.first?.name, "Shared name"); XCTAssertEqual(model.collections.first?.space, .shared)
        let states = try await model.peopleVisibility(in: .shared)
        model.submitMutation(.setPeopleVisibility(states, visible: false)); await waitForManagement(model)
        XCTAssertTrue(model.collections.isEmpty)
        let hidden = try await model.peopleVisibility(in: .shared)
        model.submitMutation(.setPeopleVisibility(hidden, visible: true)); await waitForManagement(model)
        XCTAssertEqual(model.collections.count, 2); XCTAssertTrue(model.collections.allSatisfy { $0.space == .shared })
        XCTAssertEqual(model.selectedSpace, .shared); XCTAssertEqual(model.selectedCategory, .person)
        let commands = await service.managementCommands, reads = await service.peopleReadSpaces, after = await service.requests.count
        XCTAssertEqual(commands.count, 3); XCTAssertTrue(commands.allSatisfy { $0.space == .shared })
        XCTAssertEqual(reads, [.shared, .shared]); XCTAssertEqual(before, after)
    }

    func test共享人物移出人脸保留当前月份与原照片() async throws {
        let service = DatePhotoServiceStub(space: .shared)
        await service.configureRequestAccess(spaces: [.shared], manager: true); await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.person)
        let person = try XCTUnwrap(model.collections.first)
        await model.open(person); await model.jumpToMonth(.init(year: 2014, month: 8))
        let photo = try XCTUnwrap(model.items.first), before = await service.requests.count
        let faces = try await model.personFaces(personID: person.id, photos: [photo])
        model.submitMutation(.removePersonFaces(person: person, faces: faces)); await waitForManagement(model)
        XCTAssertEqual(model.selectedSpace, .shared); XCTAssertEqual(model.selectedCategoryItem?.space, .shared)
        XCTAssertEqual(model.selectedTimelineMonthID, 201408); XCTAssertFalse(model.items.contains { $0.id == photo.id })
        let after = await service.requests.count; XCTAssertEqual(before, after)
        await model.selectSection(.timeline); await model.jumpToMonth(.init(year: 2014, month: 8))
        XCTAssertTrue(model.items.contains { $0.id == photo.id })
    }

    func test共享人物结果不覆盖个人空间同编号卡片() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.openCategory(.person)
        let original = try XCTUnwrap(model.collections.first)
        let shared = SynologyPhotoCollection(id: original.id, name: original.name, itemCount: original.itemCount, space: .shared)
        model.submitMutation(.renamePerson(shared, name: "Shared change")); await waitForManagement(model)
        XCTAssertEqual(model.collections.first, original); XCTAssertTrue(model.options.people.isEmpty)
    }

    func test相册来源未开放仍可浏览且不接收另一个相册的项目() async throws {
        for spaces: [SynologyPhotoSpace] in [[.personal], []] {
            for sourceAlbum in [21, 22] {
                let service = PhotoUploadServiceStub(); await service.setSpaces(spaces)
                let shared = SynologyPhoto(id: .init(profileID: UUID(), space: .shared, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
                    takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
                    albumContext: .init(albumID: sourceAlbum, ownerUserID: 0))
                await service.setAlbumPhoto(shared)
                let model = SynologyPhotosModel(repository: service)
                await model.refresh(); await model.selectSection(.albums)
                await model.open(.init(id: 21, name: "Fixture"))
                if sourceAlbum == 21 {
                    XCTAssertNil(model.errorMessage); XCTAssertEqual(model.items, [shared])
                } else {
                    XCTAssertNotNil(model.errorMessage); XCTAssertTrue(model.items.isEmpty)
                }
                XCTAssertEqual(model.selectedAlbum?.id, 21)
                XCTAssertEqual(model.selectedSpace, .personal)
            }
        }
    }

    func test没有照片空间仍可从与我共享进入相册() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([])
        let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
            takenAt: Date(), indexedAt: Date(), folderID: 9, mediaType: "photo", albumContext: .init(albumID: 21, ownerUserID: 99))
        await service.setAlbumPhoto(photo)
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSection(.sharing)
        await model.openSharedAlbum(.init(id: "21", title: "Fixture", albumID: 21))
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.items, [photo]); XCTAssertEqual(model.selectedAlbum?.id, 21)
        XCTAssertTrue(model.managementFeatures.isEmpty)
    }

    func test条件来源选项沿权限且统一相册保留共享照片身份() async throws {
        let service = PhotoUploadServiceStub()
        await service.setSpaces([.personal, .shared]); await service.setConditionSpace(.shared)
        let shared = SynologyPhoto(id: .init(profileID: UUID(), space: .shared, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
            takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo")
        await service.setAlbumPhoto(shared)
        let model = SynologyPhotosModel(repository: service)
        await model.refresh()
        XCTAssertEqual(model.conditionSourceSpaces, [.personal, .shared])
        let condition = try await model.albumCondition(id: 21); XCTAssertEqual(condition.sourceSpace, .shared)
        _ = try await model.conditionSuggestions(keyword: "Fixture", in: .shared)
        let reads = await service.conditionSuggestionSpaces; XCTAssertEqual(reads, [.shared])
        await model.selectSection(.albums)
        await model.open(.init(id: 21, name: "Fixture rule album", isConditional: true))
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.items, [shared]); XCTAssertEqual(model.selectedSpace, .personal)
        let entryService = PhotoUploadServiceStub(); await entryService.setSpaces([.personal, .shared])
        let entryModel = SynologyPhotosModel(repository: entryService); await entryModel.refresh()
        XCTAssertEqual(entryModel.conditionSourceSpaces, [.personal])
    }

    func test共享分类保持来源且相册沿统一入口读取() async throws {
        let service = SharedCategoryServiceStub()
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSpace(.shared); await model.selectSection(.albums)
        XCTAssertEqual(model.selectedSpace, .shared); XCTAssertTrue(model.showsCategories)
        let initialAlbumReads = await service.albumReads; XCTAssertEqual(initialAlbumReads, 1)
        await model.openCategory(.tags)
        let shared = try XCTUnwrap(model.collections.first)
        XCTAssertEqual(shared.space, .shared)
        await model.open(shared)
        XCTAssertEqual(model.items.first?.id.space, .shared)
        await model.goBack()
        XCTAssertEqual(model.selectedCategory, .tags); XCTAssertEqual(model.collections.first?.space, .shared)
        await model.goBack(); XCTAssertTrue(model.showsCategories)
        await model.selectSpace(.personal); await model.openCategory(.tags)
        XCTAssertEqual(model.collections.first?.id, shared.id)
        XCTAssertEqual(model.collections.first?.space, .personal)
        XCTAssertNotEqual(model.collections.first, shared)
        await model.open(shared)
        XCTAssertNil(model.selectedCategoryItem, "过时卡片不能把共享编号传给个人照片读取")
    }

    func test共享目录成员仍能浏览相册但不读取全局分类() async throws {
        let service = SharedCategoryServiceStub()
        let album = SynologyPhotoCollection(id: 21, name: "Fixture album")
        await service.configure(manager: false); await service.setAlbums([album])
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSpace(.shared); await model.selectSection(.albums)
        XCTAssertEqual(model.collections, [album]); XCTAssertFalse(model.showsCategories)
        XCTAssertFalse(model.conditionSourceSpaces.contains(.shared))
        let categories = await service.categoryReads; XCTAssertEqual(categories, 0)
        await model.open(album)
        XCTAssertEqual(model.selectedAlbum, album); XCTAssertEqual(model.items.first?.id.space, .shared)
        XCTAssertNil(model.errorMessage)
    }

    func test共享分类权限撤回清除分类筛选和照片但保留共享空间() async throws {
        let service = SharedCategoryServiceStub()
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSpace(.shared); await model.selectSection(.albums)
        await model.openCategory(.person); await model.open(try XCTUnwrap(model.collections.first))
        XCTAssertNotNil(model.filter.personID)
        await service.configure(manager: false)
        await model.refresh()
        XCTAssertTrue(model.sharedCategoriesRequireManagement); XCTAssertEqual(model.selectedSpace, .shared)
        XCTAssertNil(model.selectedCategory); XCTAssertNil(model.filter.personID)
        XCTAssertTrue(model.items.isEmpty); XCTAssertTrue(model.collections.isEmpty)
        XCTAssertNil(model.errorMessage)
    }

    func test共享分类分页切换空间后丢弃晚到页面() async throws {
        let service = SharedCategoryServiceStub()
        await service.configure(paged: true)
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSpace(.shared); await model.selectSection(.albums); await model.openCategory(.tags)
        XCTAssertTrue(model.hasMoreCollections)
        let page = Task { await model.loadMoreCollections() }
        await service.waitForPage()
        await model.selectSpace(.personal)
        await service.releasePage()
        await page.value
        XCTAssertEqual(model.selectedSpace, .personal)
        XCTAssertNil(model.selectedCategory); XCTAssertTrue(model.collections.isEmpty)
        XCTAssertTrue(model.showsCategories)
    }

    func test分类读取失败不保留上次入口并可刷新恢复() async {
        let service = SharedCategoryServiceStub()
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSpace(.shared); await model.selectSection(.albums)
        XCTAssertTrue(model.showsCategories)
        await service.configure(fails: true); await model.refresh()
        XCTAssertTrue(model.availableCategories.isEmpty); XCTAssertNotNil(model.errorMessage)
        await service.configure(fails: false); await model.refresh()
        XCTAssertTrue(model.showsCategories); XCTAssertNil(model.errorMessage)
    }

    func test共享分类列表拒绝其他来源的同编号卡片() async {
        let service = SharedCategoryServiceStub()
        await service.configure(wrongSource: true)
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSpace(.shared); await model.selectSection(.albums); await model.openCategory(.tags)
        XCTAssertTrue(model.collections.isEmpty); XCTAssertNotNil(model.errorMessage)
    }

    func test共享照片批量编辑与删除自动核对后保持月份和空间() async throws {
        let service = DatePhotoServiceStub(space: .shared)
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, pageSize: 6, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.jumpToMonth(.init(year: 2014, month: 8))
        XCTAssertEqual(model.selectedSpace, .shared)
        model.selectGroup(Array(model.items.prefix(2)))
        model.submitMutation(.edit(model.selectedPhotos, .rating(4)))
        await waitForManagement(model)
        XCTAssertEqual(model.items.prefix(2).map(\.rating), [4, 4])
        XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        XCTAssertEqual(model.selectedPhotos.count, 2, "编辑完成后仍保留原选择")
        model.requestDeletion(model.selectedPhotos)
        for _ in 0..<2000 where model.isCheckingDeletion { await Task.yield() }
        XCTAssertEqual(model.deletionCandidates.count, 2)
        model.confirmDeletion(model.deletionCandidates)
        for _ in 0..<2000 where model.isDeleting { await Task.yield() }
        XCTAssertFalse(model.isDeleting)
        XCTAssertTrue(model.pendingDeletionPhotos.isEmpty)
        XCTAssertEqual(model.items.map(\.id.unitID), [6])
        XCTAssertTrue(model.items.allSatisfy { $0.id.space == .shared })
        XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        let commands = await service.managementCommands, deletes = await service.deleteIDs, requests = await service.requests
        XCTAssertTrue(commands.allSatisfy { $0.space == .shared })
        XCTAssertEqual(deletes, [4, 5]); XCTAssertEqual(requests.count, 2)
    }

    func test主题封面与误分类移出保留月份和原件且清理所移出预览() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for partial in [false, true] {
                let service = DatePhotoServiceStub(space: space)
                await service.configureRequestAccess(spaces: [space], manager: true); await service.enableManagement()
                await service.configureConcepts(count: 2)
                let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.refresh(); await model.selectSection(.albums); await model.openCategory(.concept)
                await model.open(try XCTUnwrap(model.collections.first))
                await model.jumpToMonth(try XCTUnwrap(model.timelineMonths.last))
                let photo = try XCTUnwrap(model.items.first), month = model.selectedTimelineMonthID
                var concept = try await model.conceptState(try XCTUnwrap(model.selectedCategoryItem))
                let before = await service.requests.count, originalItems = model.items
                model.submitMutation(.setConceptCover(concept: concept, photo: photo)); await waitForManagement(model)
                XCTAssertEqual(model.selectedCategoryItem?.thumbnail?.unitID, photo.id.unitID)
                XCTAssertEqual(model.items, originalItems); XCTAssertEqual(model.selectedTimelineMonthID, month)
                XCTAssertTrue(model.collections.isEmpty)
                concept = try await model.conceptState(try XCTUnwrap(model.selectedCategoryItem))
                await service.enableManagement(partial: partial)
                let selected = Array(model.items.prefix(partial ? 2 : 1))
                model.toggleSelection(photo); model.showPreview(photo)
                model.submitMutation(.removeConceptItems(concept: concept, photos: selected)); await waitForManagement(model)
                XCTAssertEqual(model.items.map(\.id), originalItems.dropFirst().map(\.id))
                XCTAssertNil(model.previewPhoto); XCTAssertFalse(model.selectedPhotoIDs.contains(photo.id))
                XCTAssertEqual(model.selectedTimelineMonthID, month); XCTAssertEqual(model.selectedCategoryItem?.id, concept.id)
                XCTAssertEqual(model.selectedCategoryItem?.itemCount, 1)
                XCTAssertFalse(model.collections.contains { $0.id == concept.id })
                let after = await service.requests.count, deletes = await service.deleteIDs
                XCTAssertEqual(before, after); XCTAssertTrue(deletes.isEmpty)
            }
        }
    }

    func test主题移出核对期间跳转图库不会移除原图库照片() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement(pending: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.selectSection(.albums); await model.openCategory(.concept)
        await model.open(try XCTUnwrap(model.collections.first))
        let photo = try XCTUnwrap(model.items.first), concept = try await model.conceptState(try XCTUnwrap(model.selectedCategoryItem))
        model.submitMutation(.removeConceptItems(concept: concept, photos: [photo])); await waitForManagement(model)
        await model.selectSection(.timeline)
        let before = model.items
        await service.enableManagement(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.items, before); XCTAssertNil(model.selectedCategory)
        let writes = await service.managementWriteCount
        XCTAssertEqual(writes, 1)
    }

    func test主题显示隐藏双空间部分成功与恢复保持位置() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            for partial in [false, true] {
                let service = DatePhotoServiceStub(space: space)
                await service.configureRequestAccess(spaces: [space], manager: true); await service.enableManagement(partial: partial)
                let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.refresh(); await model.selectSection(.albums); await model.openCategory(.concept)
                let states = try await model.conceptVisibility(in: space)
                let before = await service.requests.count
                model.submitMutation(.setConceptVisibility(states, visible: false)); await waitForManagement(model)
                XCTAssertEqual(model.collections.map(\.id), partial ? [42] : [])
                XCTAssertEqual(model.selectedCategory, .concept); XCTAssertEqual(model.selectedSpace, space)
                let hidden = try await model.conceptVisibility(in: space).filter { !$0.isVisible }
                await service.enableManagement()
                model.submitMutation(.setConceptVisibility(hidden, visible: true)); await waitForManagement(model)
                XCTAssertEqual(Set(model.collections.map(\.id)), [41, 42])
                let after = await service.requests.count, deletions = await service.deleteIDs
                XCTAssertEqual(before, after); XCTAssertTrue(deletions.isEmpty); XCTAssertNil(model.pendingMutationID)
            }
        }
    }

    func test主题保存期间切换到人物不污染人物列表() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement(pending: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.openCategory(.concept)
        let states = try await model.conceptVisibility(in: .personal)
        model.submitMutation(.setConceptVisibility(states, visible: false)); await waitForManagement(model)
        await model.openCategory(.person)
        let people = model.collections
        await service.enableManagement(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.collections, people); XCTAssertEqual(model.selectedCategory, .person)
    }

    func test人物隐藏恢复和部分结果只更新人物不刷新照片() async throws {
        for partial in [false, true] {
            let service = DatePhotoServiceStub()
            await service.enableManagement(partial: partial)
            let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            await model.refresh(); await model.openCategory(.person)
            let states = try await model.peopleVisibility()
            let beforeRequests = await service.requests.count
            model.submitMutation(.setPeopleVisibility(states, visible: false))
            await waitForManagement(model)
            XCTAssertEqual(model.collections.map(\.id), partial ? [32] : [])
            XCTAssertEqual(model.selectedCategory, .person)
            let hidden = try await model.peopleVisibility().filter { !$0.isVisible }
            XCTAssertEqual(hidden.count, partial ? 1 : 2)
            await service.enableManagement()
            model.submitMutation(.setPeopleVisibility(hidden, visible: true))
            await waitForManagement(model)
            XCTAssertEqual(Set(model.collections.map(\.id)), [31, 32])
            let afterRequests = await service.requests.count
            XCTAssertEqual(beforeRequests, afterRequests)
            XCTAssertNil(model.pendingMutationID)
        }
    }

    func test手工人脸保存后保持当前月份选择和预览照片() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
        let photo = try XCTUnwrap(model.items.first)
        model.selectGroup([photo]); model.showPreview(photo)
        let before = await service.requests.count
        model.submitMutation(.editPhotoFaces(photo: photo, changes: [.remove(.init(id: 71, personID: 31, name: "Fixture", bounds: .init(x: 0.1, y: 0.2, width: 0.2, height: 0.2)))]))
        await waitForManagement(model)
        XCTAssertEqual(model.selectedTimelineMonthID, 201408); XCTAssertEqual(model.previewPhoto?.id, photo.id)
        XCTAssertEqual(model.selectedPhotoIDs, [photo.id]); XCTAssertTrue(model.items.contains { $0.id == photo.id })
        let after = await service.requests.count
        XCTAssertEqual(before, after); XCTAssertNil(model.pendingMutationID)
    }

    func test恢复预览固定所选空间和照片且部分成功仅继续剩余项() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement(partial: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        let targets = Array(model.items.prefix(2)); XCTAssertEqual(targets.count, 2)
        await service.setPreviewRecovery(targets, in: .personal)
        let pending = try await model.pendingPreviewRegenerations(in: .personal)
        XCTAssertEqual(pending, targets)
        model.submitMutation(.regeneratePreviews(pending, resuming: true)); await waitForManagement(model)
        XCTAssertEqual(model.retryableManagementMutation, .regeneratePreviews([targets[1]]))
        model.toggleSelection(targets[0])
        model.continuePartialManagement(); await waitForManagement(model)
        let commands = await service.managementCommands
        XCTAssertEqual(commands, [.regeneratePreviews(targets, resuming: true), .regeneratePreviews([targets[1]])])
        XCTAssertNil(model.retryableManagementMutation)
    }

    func test预览重建完成后保留月份选择并更新当前照片() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        await service.enablePreviewDetails()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
        let photo = try XCTUnwrap(model.items.first)
        model.selectGroup([photo]); model.showPreview(photo)
        for _ in 0..<1000 where model.isPreparingPreview { await Task.yield() }
        let before = await service.requests.count
        model.submitMutation(.regeneratePreviews([photo]))
        await waitForManagement(model)
        for _ in 0..<1000 where model.isPreparingPreview { await Task.yield() }
        XCTAssertEqual(model.selectedTimelineMonthID, 201408); XCTAssertEqual(model.previewPhoto?.id, photo.id)
        XCTAssertEqual(model.selectedPhotoIDs, [photo.id]); XCTAssertNil(model.pendingMutationID)
        let requests = await service.requests.count; let writes = await service.managementWriteCount
        XCTAssertEqual(before, requests); XCTAssertEqual(writes, 1)
        let previews = await service.previewDetailReads
        XCTAssertEqual(previews, 2)
    }

    func test空间切换清除目录筛选选择和预览并读取新根目录() async throws {
        let service = PhotoUploadServiceStub()
        await service.setSpaces([.personal, .shared])
        let model = SynologyPhotosModel(repository: service)
        await model.selectSection(.folders)
        await model.open(.init(id: 9, name: "Personal child", parentID: 1))
        model.filter.personID = 31; model.searchText = "personal query"; model.showsFilters = true
        model.showPreview(Self.photo)
        await model.selectSpace(.shared)
        XCTAssertEqual(model.selectedSpace, .shared)
        XCTAssertEqual(model.folderHistory.map(\.id), [101])
        XCTAssertFalse(model.canGoBack)
        XCTAssertFalse(model.filter.isActive)
        XCTAssertFalse(model.isFiltering)
        XCTAssertEqual(model.searchText, "")
        XCTAssertFalse(model.showsFilters)
        XCTAssertNil(model.previewPhoto)
        XCTAssertTrue(model.selectedPhotoIDs.isEmpty)
        let queries = await service.spaceQueries
        XCTAssertEqual(queries.last?.0, .shared)
        XCTAssertEqual(queries.last?.1, .folder(id: 101))
    }

    func test权限回退同样丢弃旧空间目录且无空间时清空操作能力() async throws {
        let service = PhotoUploadServiceStub()
        let model = SynologyPhotosModel(repository: service)
        await model.selectSection(.folders)
        await model.open(.init(id: 9, name: "Personal child", parentID: 1))
        await service.setSpaces([.shared])
        await model.refresh()
        XCTAssertEqual(model.selectedSpace, .shared)
        XCTAssertEqual(model.folderHistory.map(\.id), [101])
        await service.setSpaces([])
        await model.refresh()
        XCTAssertTrue(model.folderHistory.isEmpty)
        XCTAssertTrue(model.managementFeatures.isEmpty)
        XCTAssertTrue(model.hasLoaded)
    }

    func test共享上传队列在切换到个人空间后仍保持原上传目标() async throws {
        let service = PhotoUploadServiceStub()
        await service.setSpaces([.personal, .shared])
        await service.holdFirstUpload()
        let model = SynologyPhotosModel(repository: service)
        await model.refresh()
        await model.selectSpace(.shared)
        model.enqueueUploads(makeUploadFiles(), album: nil, folder: .init(id: 9, name: "Shared target"))
        await service.waitUntilHeld()
        await model.selectSpace(.personal)
        await service.releaseUpload()
        await waitForManagement(model)
        XCTAssertEqual(model.selectedSpace, .personal)
        XCTAssertTrue(model.uploadQueue.allSatisfy { $0.space == .shared && $0.uploadedPhoto?.id.space == .shared && $0.state == .completed })
        XCTAssertTrue(model.items.isEmpty, "共享上传结果不能插入个人图库")
        let commands = await service.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.allSatisfy { $0.space == .shared })
    }

    func test收集请求保存删除局部更新列表且自动核对不整页刷新() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.selectShareScope(.requests)
        await model.selectSection(.sharing)
        XCTAssertEqual(model.sharedEntries.map(\.id), ["fixture-request"])
        let reads = await service.requestListReads
        let original = try await service.photoRequest(id: "fixture-request")
        var changed = original.settings; changed.subject = "Edited collection"
        model.submitMutation(.updatePhotoRequest(original: original, settings: changed))
        await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID)
        XCTAssertEqual(model.sharedEntries.first?.title, "Edited collection")
        let updated = try await service.photoRequest(id: "fixture-request")
        model.submitMutation(.deletePhotoRequest(updated))
        await waitForManagement(model)
        XCTAssertTrue(model.sharedEntries.isEmpty)
        XCTAssertEqual(model.section, .sharing); XCTAssertEqual(model.shareScope, .requests)
        model.submitMutation(.createPhotoRequest(changed))
        await waitForManagement(model)
        XCTAssertEqual(model.sharedEntries.map(\.title), ["Edited collection"])
        let finalReads = await service.requestListReads
        XCTAssertEqual(finalReads, reads, "结果应就地更新，不刷新整个照片库")
        let writes = await service.managementWriteCount
        XCTAssertEqual(writes, 3)
    }

    func test收集默认空间遵循个人优先且共享目录只按明确管理权限() async throws {
        let service = DatePhotoServiceStub(space: .shared)
        let model = SynologyPhotosModel(repository: service)
        for (spaces, manager, expected) in [
            ([SynologyPhotoSpace.shared, .personal], true, SynologyPhotoSpace.personal),
            ([.shared], true, .shared), ([.shared], false, .shared)
        ] {
            await service.configureRequestAccess(spaces: spaces, manager: manager)
            await model.refresh()
            XCTAssertEqual(model.defaultPhotoRequestSpace, expected)
            XCTAssertEqual(model.canUseDefaultRequestFolder(in: .shared), manager)
            XCTAssertEqual(model.canUseDefaultRequestFolder(in: .personal), spaces.contains(.personal))
            let sheet = PhotoManagementSheet(kind: .createRequest, photos: [], space: .shared)
            XCTAssertEqual(sheet.initialRequestSettings(defaultSpace: model.defaultPhotoRequestSpace).space, expected)
        }
        let folder = SynologyPhotoCollection(id: 9, name: "Fixture", path: "/Fixture")
        let explicit = PhotoManagementSheet(kind: .createRequest, photos: [], folder: folder, space: .shared)
            .initialRequestSettings(defaultSpace: .personal)
        XCTAssertEqual(explicit.space, .shared)
        XCTAssertEqual(explicit.folderID, 9)
        model.setModuleEnabled(false)
        XCTAssertNil(model.defaultPhotoRequestSpace)
        XCTAssertFalse(model.canUseDefaultRequestFolder(in: .shared))
    }

    func test默认收集路径与网页字符替换一致() {
        for (subject, expected) in [("  Trip:2020/Day\\One  ", "/PhotoRequest/Trip_2020_Day_One"), (".hidden.", "/PhotoRequest/_hidden_"), ("@eaDir", "/PhotoRequest/_"), ("#recycle", "/PhotoRequest/_"), ("相册", "/PhotoRequest/相册"), ("", "/PhotoRequest")] {
            XCTAssertEqual(SynologyPhotoRequestSettings.defaultFolderPath(subject: subject), expected)
        }
    }

    func test从文件夹相册发起收集保留目标快照并填入默认标题() {
        let folder = SynologyPhotoCollection(id: 9, name: "Trip", path: "/Trip")
        let album = SynologyPhotoCollection(id: 3, name: "Fixture album")
        let now = Date(timeIntervalSince1970: 1_600_000_000)
        let fromFolder = PhotoManagementSheet(kind: .createRequest, photos: [], folder: folder, space: .shared).initialRequestSettings(now: now)
        XCTAssertEqual(fromFolder.space, .shared)
        XCTAssertEqual(fromFolder.folderID, 9); XCTAssertEqual(fromFolder.folderPath, "/Trip")
        XCTAssertNil(fromFolder.albumID)
        XCTAssertFalse(fromFolder.subject.isEmpty); XCTAssertLessThanOrEqual(fromFolder.subject.utf16.count, 50)
        let fromAlbum = PhotoManagementSheet(kind: .createRequest, photos: [], album: album).initialRequestSettings(now: now)
        XCTAssertEqual(fromAlbum.albumID, 3); XCTAssertNil(fromAlbum.folderID)
        XCTAssertEqual(fromAlbum.subject, fromFolder.subject)
        XCTAssertEqual(fromAlbum.expiration, 0); XCTAssertEqual(fromAlbum.sizeLimit, 0)
    }

    func test收集搜索覆盖后续页且清空不刷新列表() async throws {
        let service = DatePhotoServiceStub()
        await service.configureRequestTitles(["First", "Second", "Café trip", "Last"])
        let model = SynologyPhotosModel(repository: service, pageSize: 2)
        await model.selectShareScope(.requests)
        await model.selectSection(.sharing)
        let reads = await service.requestListReads
        model.requestSearchText = "  CAFE  "
        XCTAssertTrue(model.visibleSharedEntries.isEmpty)
        XCTAssertTrue(model.hasMoreCollections)
        await model.loadNextPageAutomatically()
        XCTAssertEqual(model.visibleSharedEntries.map(\.title), ["Café trip"])
        await model.loadNextPageAutomatically()
        XCTAssertFalse(model.hasMoreCollections)
        model.requestSearchText = "no match"
        XCTAssertTrue(model.visibleSharedEntries.isEmpty)
        model.requestSearchText = ""
        XCTAssertEqual(model.visibleSharedEntries.count, 4)
        XCTAssertTrue(model.searchText.isEmpty)
        let finalReads = await service.requestListReads
        XCTAssertEqual(finalReads, reads + 2)
    }

    func test临时分享创建中取消待确认后自动清理且保持月份() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement(pending: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
        let photos = Array(model.items.prefix(2)), items = model.items
        model.submitMutation(.createTemporaryAlbum(name: "Temporary", photos: photos)) { _ in XCTFail("已关闭表单不再收到分享设置回调") }
        model.cancelTemporaryAlbumCreation()
        await waitForManagement(model); XCTAssertNotNil(model.automaticMutationReviewID)
        await service.enableManagement(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID); XCTAssertFalse(model.hasTemporarySharingCleanup)
        XCTAssertEqual(model.selectedTimelineMonthID, 201408); XCTAssertEqual(model.items, items)
        let commands = await service.managementCommands
        XCTAssertEqual(commands.count, 3)
        guard case .createTemporaryAlbum = commands[0], case .shareAlbum(9, .disabled, _, _, _, _) = commands[1],
              case .deleteTemporaryAlbum(9, _, nil) = commands[2] else { return XCTFail("创建确认后只停止并清理固定临时相册") }
    }

    func test由我共享快捷目标限定当前列表且未知停止不提前移除() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement(pending: true)
        let sort = SynologyPhotoAlbumListSort(field: .shareModified, direction: .descending)
        await service.configureSharedAlbumSort(sort)
        let entries = (1...205).map { SynologyPhotoSharedEntry(id: String($0), title: "Shared \($0)", albumID: $0) }
        await service.configureSharedAlbumEntries(entries)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.sharing)
        XCTAssertNil(model.sharingManagementTarget(for: entries[8]))
        await model.selectShareScope(.withOthers); await model.loadMoreCollections()
        XCTAssertEqual(model.sharingManagementTarget(for: entries[8])?.id, 9)
        XCTAssertNil(model.sharingManagementTarget(for: .init(id: "missing", title: "Missing", albumID: 999)))
        let original = try await model.albumSharing(id: 9)
        model.submitMutation(.shareAlbum(id: 9, access: .disabled, original: original)); await waitForManagement(model)
        XCTAssertNotNil(model.automaticMutationReviewID); XCTAssertEqual(model.sharedEntries.count, 200)
        let before = await service.sharedAlbumReads; XCTAssertEqual(before, [0, 100])
        await service.configureSharedAlbumEntries(entries.filter { $0.albumID != 9 }); await service.enableManagement()
        model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.section, .sharing); XCTAssertEqual(model.shareScope, .withOthers); XCTAssertNil(model.selectedAlbum)
        XCTAssertEqual(model.sharedEntries.count, 200); XCTAssertFalse(model.sharedEntries.contains { $0.albumID == 9 })
        XCTAssertEqual(model.sharedEntries.last?.albumID, 201); XCTAssertTrue(model.hasMoreCollections)
        let reads = await service.sharedAlbumReads; XCTAssertEqual(reads, [0, 100, 0, 100])
        let sorts = await service.sharedAlbumSortRequests; XCTAssertTrue(sorts.allSatisfy { $0 == sort })
        XCTAssertEqual(model.albumListSort, sort)
        let writes = await service.managementWriteCount; XCTAssertEqual(writes, 1)
    }

    func test分享成功列表刷新失败保留内容且重试不重复写入() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement()
        let entry = SynologyPhotoSharedEntry(id: "9", title: "Shared", albumID: 9)
        await service.configureSharedAlbumEntries([entry])
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.sharing); await model.selectShareScope(.withOthers)
        let original = try await model.albumSharing(id: 9)
        await service.configureSharedAlbumEntries([], fail: true)
        model.submitMutation(.shareAlbum(id: 9, access: .disabled, original: original)); await waitForManagement(model)
        XCTAssertTrue(model.needsSharedListRefresh); XCTAssertEqual(model.sharedEntries, [entry])
        XCTAssertNil(model.pendingMutationID); XCTAssertFalse(model.hasMoreCollections)
        await service.configureSharedAlbumEntries([]); await model.retrySharedListRefresh()
        XCTAssertFalse(model.needsSharedListRefresh); XCTAssertTrue(model.sharedEntries.isEmpty)
        let writes = await service.managementWriteCount; XCTAssertEqual(writes, 1)
    }

    func test分享待确认期间切换历史月份不被迟到列表覆盖() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement(pending: true)
        await service.configureSharedAlbumEntries([.init(id: "9", title: "Shared", albumID: 9)])
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.sharing); await model.selectShareScope(.withOthers)
        model.submitMutation(.shareAlbum(id: 9, access: .view, original: try await model.albumSharing(id: 9)))
        await waitForManagement(model)
        await model.selectSection(.timeline); await model.jumpToMonth(.init(year: 2014, month: 8)); let items = model.items
        await service.enableManagement(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.section, .timeline); XCTAssertEqual(model.selectedTimelineMonthID, 201408); XCTAssertEqual(model.items, items)
        let reads = await service.sharedAlbumReads; XCTAssertEqual(reads, [0])
        XCTAssertFalse(model.needsSharedListRefresh)
    }

    func test分享刷新跨页发生重排重复时保留完整旧列表并只读恢复() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement()
        let entries = (1...205).map { SynologyPhotoSharedEntry(id: String($0), title: "Shared \($0)", albumID: $0) }
        await service.configureSharedAlbumEntries(entries)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.sharing); await model.selectShareScope(.withOthers); await model.loadMoreCollections()
        let loaded = model.sharedEntries
        var changed = entries; changed[100] = changed[0]
        await service.configureSharedAlbumEntries(changed)
        model.submitMutation(.shareAlbum(id: 9, access: .view, original: try await model.albumSharing(id: 9)))
        await waitForManagement(model)
        XCTAssertTrue(model.needsSharedListRefresh); XCTAssertEqual(model.sharedEntries, loaded)
        await service.configureSharedAlbumEntries(entries); await model.retrySharedListRefresh()
        XCTAssertFalse(model.needsSharedListRefresh); XCTAssertEqual(model.sharedEntries, loaded)
        let writes = await service.managementWriteCount; XCTAssertEqual(writes, 1)
    }

    func test临时分享停止保留副本顺序正确且重复点击不重入() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement(); await service.configureTemporarySharing()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8)); let items = model.items
        XCTAssertTrue(model.stopTemporarySharing(.init(id: 9, name: "Temporary"), keepCopy: true))
        XCTAssertFalse(model.stopTemporarySharing(.init(id: 9, name: "Temporary"), keepCopy: true))
        await waitForManagement(model)
        let commands = await service.managementCommands; XCTAssertEqual(commands.count, 3)
        guard case .copyTemporaryAlbum(9, "Temporary", _) = commands[0], case .shareAlbum(9, .disabled, _, _, _, _) = commands[1],
              case .deleteTemporaryAlbum(9, _, .some(10)) = commands[2] else { return XCTFail("保留确认后的副本编号并用于清理前复查") }
        XCTAssertEqual(model.items, items); XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        XCTAssertEqual(model.managementMessage, L10n.string("photos.temporary.kept"))
    }

    func test临时分享副本未确认不停止且迟到结果不删除同编号文件夹() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement(pending: true); await service.configureTemporarySharing()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        model.stopTemporarySharing(.init(id: 9, name: "Temporary"), keepCopy: true)
        await waitForManagement(model); XCTAssertNotNil(model.automaticMutationReviewID)
        let first = await service.managementCommands; XCTAssertEqual(first.count, 1)
        await model.selectSection(.folders); let folders = model.collections
        await service.enableManagement(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.section, .folders); XCTAssertEqual(model.collections, folders)
        XCTAssertFalse(model.hasTemporarySharingCleanup)
    }

    func test临时分享副本明确失败保留来源且重试继续() async throws {
        let service = DatePhotoServiceStub(); await service.enableManagement(); await service.configureTemporarySharing(rejectCopy: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in }); await model.refresh()
        model.stopTemporarySharing(.init(id: 9, name: "Temporary"), keepCopy: true); await waitForManagement(model)
        XCTAssertTrue(model.temporarySharingCleanupNeedsRetry); XCTAssertNil(model.pendingMutationID)
        let first = await service.managementCommands; XCTAssertEqual(first.count, 1)
        await service.configureTemporarySharing(); model.retryTemporarySharingCleanup(); await waitForManagement(model)
        XCTAssertFalse(model.hasTemporarySharingCleanup)
        let commands = await service.managementCommands; XCTAssertEqual(commands.count, 4)
    }

    func test临时分享已停止直接清理且普通相册不进入清理() async throws {
        for temporary in [true, false] {
            let service = DatePhotoServiceStub(); await service.enableManagement(); await service.configureSharing(.disabled)
            if temporary { await service.configureTemporarySharing(access: .disabled) }
            let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in }); await model.refresh()
            model.stopTemporarySharing(.init(id: 9, name: "Temporary"), keepCopy: false); await waitForManagement(model)
            let commands = await service.managementCommands
            XCTAssertEqual(commands.count, temporary ? 1 : 0)
            XCTAssertEqual(model.temporarySharingCleanupNeedsRetry, !temporary)
        }
    }

    func test临时分享明确失败可以保留现有相册但未知结果不能放弃核对() async throws {
        for pending in [false, true] {
            let service = DatePhotoServiceStub(); await service.enableManagement(pending: pending)
            await service.configureTemporarySharing(rejectCopy: !pending)
            let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in }); await model.refresh()
            model.stopTemporarySharing(.init(id: 9, name: "Temporary"), keepCopy: true)
            await waitForManagement(model)
            model.keepTemporarySharingAlbums()
            XCTAssertEqual(model.hasTemporarySharingCleanup, pending)
            XCTAssertEqual(model.pendingMutationID != nil, pending)
            XCTAssertFalse(model.temporarySharingCleanupNeedsRetry)
            if !pending { XCTAssertEqual(model.managementMessage, L10n.string("photos.temporary.cleanupCancelled")) }
            let commands = await service.managementCommands
            XCTAssertEqual(commands.count, 1, "保留现有相册不会停止分享、删除或再次复制")
        }
    }

    func test表单内创建相册核对后只回调一次且不重复创建() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement(pending: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        var albums: [SynologyPhotoCollection] = []
        model.submitMutation(.createAlbum(name: "New target", photos: [])) { result in
            if let album = result.album { albums.append(album) }
        }
        await waitForManagement(model)
        XCTAssertTrue(albums.isEmpty); XCTAssertNotNil(model.pendingMutationID)
        model.submitMutation(.createAlbum(name: "Duplicate", photos: [])) { _ in XCTFail("未知结果不能再次创建") }
        await service.enableManagement()
        model.reviewPendingMutation()
        await waitForManagement(model)
        XCTAssertEqual(albums.map(\.name), ["New target"])
        XCTAssertNil(model.pendingMutationID)
        model.reviewPendingMutation()
        let writes = await service.managementWriteCount
        XCTAssertEqual(writes, 1); XCTAssertEqual(albums.count, 1)
        await service.failNextManagementPreparation()
        model.submitMutation(.createAlbum(name: "Rejected", photos: [])) { _ in XCTFail("预检失败不能选择新相册") }
        await waitForManagement(model)
        model.submitMutation(.createAlbum(name: "Later", photos: []))
        await waitForManagement(model)
        XCTAssertEqual(albums.count, 1)
    }

    func test选片分享相册自动核对固定照片且保持历史月份() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement(pending: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
        let photos = Array(model.items.prefix(2)), ids = model.items.map(\.id), month = model.selectedTimelineMonthID
        XCTAssertEqual(photos.count, 2)
        var created: [SynologyPhotoCollection] = []
        model.submitMutation(.createAlbum(name: "Selected photos", photos: photos)) { result in
            if result.state == .confirmed, let album = result.album { created.append(album) }
        }
        await waitForManagement(model)
        XCTAssertNotNil(model.automaticMutationReviewID)
        XCTAssertTrue(created.isEmpty)
        model.clearSelection()
        model.submitMutation(.createAlbum(name: "Duplicate", photos: []))
        await service.enableManagement()
        model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(created.map(\.name), ["Selected photos"])
        XCTAssertNil(model.automaticMutationReviewID)
        XCTAssertEqual(model.items.map(\.id), ids); XCTAssertEqual(model.selectedTimelineMonthID, month)
        XCTAssertNil(model.selectedAlbum)
        let commands = await service.managementCommands
        XCTAssertEqual(commands, [.createAlbum(name: "Selected photos", photos: photos)])
    }

    func test文件夹内创建收集目标相册不覆盖同编号文件夹() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.folders)
        let folders = model.collections
        XCTAssertEqual(folders.map(\.id), [9])
        var created: SynologyPhotoCollection?
        model.submitMutation(.createAlbum(name: "New target", photos: [])) { created = $0.album }
        await waitForManagement(model)
        XCTAssertEqual(created?.id, 9)
        XCTAssertEqual(model.collections, folders)
        XCTAssertEqual(model.section, .folders)
        XCTAssertNil(model.selectedAlbum)
    }

    func test共享照片上传后加入普通相册不切换来源或重复上传() async throws {
        let service = PhotoUploadServiceStub()
        await service.setSpaces([.personal, .shared]); await service.setConditionSpace(.shared)
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSpace(.shared)
        model.enqueueUploads([makeUploadFiles()[0]], album: .init(id: 3, name: "Fixture"), folder: nil)
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.first?.state, .completed)
        let commands = await service.commands
        guard commands.count == 2 else { return XCTFail("应仅上传一次并加入相册一次，实际\(commands.count)项") }
        guard case .upload(_, _, _, _, let space, _) = commands[0], case .addToAlbum(let album, let photos) = commands[1] else { return XCTFail("应先上传再加入相册") }
        XCTAssertEqual(space, .shared); XCTAssertEqual(album, 3); XCTAssertEqual(photos.first?.id.space, .shared)
        XCTAssertEqual(model.selectedSpace, .shared)
    }

    func test共享目录上传按共享根目录建立层级且相册页保持共享作用域() async throws {
        let service = PhotoUploadServiceStub()
        await service.setSpaces([.personal, .shared])
        let model = SynologyPhotosModel(repository: service)
        await model.refresh(); await model.selectSpace(.shared)
        var file = makeUploadFiles()[0]; file.directoryComponents = ["Fixture directory"]
        model.enqueueUploads([file], album: nil, folder: nil, preserveDirectories: true)
        await waitForManagement(model)
        let commands = await service.commands
        guard case .createFolder(let parent, _, let space) = commands.first else { return XCTFail("先创建共享目录") }
        XCTAssertEqual(parent, 101); XCTAssertEqual(space, .shared)
        XCTAssertTrue(commands.allSatisfy { $0.space == .shared })
        await model.selectSection(.albums)
        XCTAssertEqual(model.selectedSpace, .shared)
        await model.selectSection(.timeline)
        XCTAssertEqual(model.selectedSpace, .shared, "返回图库恢复用户选择的空间")
    }

    func test新空间拒绝混入其他空间返回的照片() async {
        let service = PhotoServiceStub(pages: [[Self.photo]], spaces: [.shared])
        let model = SynologyPhotosModel(repository: service)
        await model.refresh()
        XCTAssertEqual(model.selectedSpace, .shared)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    func test分享密码草稿保留设置且不修剪新密码() {
        var draft = PhotoSharingPasswordDraft()
        XCTAssertNil(draft.change(hasPassword: true))
        XCTAssertNil(draft.change(hasPassword: nil))
        draft.choice = .newPassword
        XCTAssertFalse(draft.isValid); XCTAssertNil(draft.change(hasPassword: true))
        draft.password = "  synthetic 密码 & +  "
        XCTAssertTrue(draft.isValid)
        XCTAssertEqual(draft.change(hasPassword: true), draft.password)
        draft.choice = .unchanged
        XCTAssertNil(draft.change(hasPassword: true))
        draft.choice = .remove
        XCTAssertEqual(draft.change(hasPassword: true), "")
        XCTAssertEqual(draft.change(hasPassword: nil), "")
        XCTAssertNil(draft.change(hasPassword: false))
    }

    func test分享有效期草稿保持原秒数并仅发送主动更改() throws {
        var draft = PhotoSharingExpirationDraft(expiration: 100)
        XCTAssertEqual(draft.choice, .date)
        XCTAssertNil(draft.change(from: 100))
        XCTAssertTrue(draft.isValid, "旧日期不妨碍其他分享修改")
        draft.choice = .unlimited; draft.edited = true
        XCTAssertEqual(draft.change(from: 100), 0)
        XCTAssertNil(draft.change(from: 0))
        let unknown = PhotoSharingExpirationDraft()
        XCTAssertEqual(unknown.choice, .unchanged)
        XCTAssertNil(unknown.change(from: nil))
    }

    func test分享到期日使用本地日末并覆盖夏令时切换() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let noon = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
            var draft = PhotoSharingExpirationDraft()
            draft.choice = .date; draft.date = noon; draft.edited = true
            let timestamp = try XCTUnwrap(draft.change(from: nil, calendar: calendar))
            let end = Date(timeIntervalSince1970: Double(timestamp))
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)
            XCTAssertEqual(parts.year, 2026); XCTAssertEqual(parts.month, month); XCTAssertEqual(parts.day, day)
            XCTAssertEqual(parts.hour, 23); XCTAssertEqual(parts.minute, 59); XCTAssertEqual(parts.second, 59)
            XCTAssertEqual(end.timeIntervalSince(calendar.startOfDay(for: noon)) + 1, Double(hours * 3600))
        }
    }

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

    func test人脸移出原位更新当前人物不刷新或删除原图() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        await model.selectSection(.albums)
        await model.openCategory(.person)
        let person = try XCTUnwrap(model.collections.first)
        await model.open(person)
        let originalIDs = model.items.map(\.id)
        let photo = try XCTUnwrap(model.items.first)
        let faces = try await model.personFaces(personID: person.id, photos: [photo])
        let count = await service.requests.count
        model.submitMutation(.removePersonFaces(person: person, faces: faces))
        while model.isManaging { await Task.yield() }
        XCTAssertEqual(model.selectedCategoryItem?.id, person.id)
        XCTAssertEqual(model.selectedCategory, .person)
        XCTAssertEqual(model.items.map(\.id), originalIDs.filter { $0 != photo.id })
        let after = await service.requests.count
        XCTAssertEqual(after, count)
        XCTAssertNil(model.pendingMutationID)
        let commands = await service.managementCommands
        XCTAssertEqual(commands.count, 1)
        await model.selectSection(.timeline)
        XCTAssertTrue(model.items.contains { $0.id == photo.id }, "移出人物不删除原照片")
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
        guard case .createFolder(let parent, let name, _) = commands[0] else { return XCTFail("应先建立首层目录") }
        XCTAssertEqual(parent, 9); XCTAssertEqual(name, "Trip")
        guard case .createFolder(let nestedParent, let nestedName, _) = commands[1] else { return XCTFail("应建立第二层目录") }
        XCTAssertEqual(nestedParent, 1001); XCTAssertEqual(nestedName, "Day")
        for command in commands.suffix(2) {
            guard case .upload(_, _, _, let folder, _, _) = command else { return XCTFail("目录只建立一次") }
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
        guard case .upload(_, _, _, let firstFolder, _, _) = commands[0] else { return XCTFail("已有目录不应重建") }
        XCTAssertEqual(firstFolder, 40)
        guard case .createFolder(let parent, _, _) = commands[1] else { return XCTFail("新目标独立解析") }
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
        guard case .createFolder(let parent, _, _) = before[0] else { return XCTFail("先创建目录") }
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
        guard case .upload(_, _, _, let folder, _, _) = commands[0] else { return XCTFail("汇总不建目录") }
        XCTAssertEqual(folder, 9)
    }

    func test上传忽略重复项保留相册后续操作且沿确认策略() async throws {
        let service = PhotoUploadServiceStub()
        await service.ignoreUploadDuplicate(); await service.holdFirstUpload()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        model.enqueueUploads(makeUploadFiles(), album: .init(id: 30, name: "Fixture"), folder: nil, duplicate: .ignore)
        await service.waitUntilHeld()
        await service.setDuplicateDefaults(.init(upload: .rename, transfer: .overwrite))
        await service.releaseUpload(); await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.skipped, .skipped])
        let commands = await service.commands
        XCTAssertEqual(commands.count, 4)
        for command in [commands[0], commands[2]] {
            guard case .upload(_, _, _, _, _, let duplicate) = command else { return XCTFail("应为上传") }
            XCTAssertEqual(duplicate, .ignore)
        }
        XCTAssertEqual(commands.filter { if case .addToAlbum = $0 { true } else { false } }.count, 2)
        model.clearFinishedUploads(); XCTAssertTrue(model.uploadQueue.isEmpty)
    }

    func test自动预览设置保存保持月份和照片选择() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        await service.configureDisplay(.init(), photos: [photo]); await service.configureAutomatic(enabled: false, tasks: [])
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
        let reads = await service.pageReads, items = model.items, selection = model.selectedPhotoIDs
        model.submitMutation(.setAutomaticPreview(original: false, enabled: true)); await waitForManagement(model)
        XCTAssertEqual(model.automaticPreviewEnabled, true); XCTAssertNil(model.pendingMutationID)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.items, items); XCTAssertEqual(model.selectedPhotoIDs, selection)
        let after = await service.pageReads; XCTAssertEqual(after, reads)
        XCTAssertFalse(model.showsAutomaticPreviewStatus, "开启开关本身不显示空闲状态栏")
        model.pauseAutomaticPreviews(); XCTAssertTrue(model.showsAutomaticPreviewStatus)
        model.submitMutation(.setAutomaticPreview(original: true, enabled: false)); await waitForManagement(model)
        XCTAssertFalse(model.showsAutomaticPreviewStatus, "关闭功能后不保留此前的暂停状态栏")
    }

    func test自动预览串行优先当前照片且不刷新时间线或重复已完成项() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        let profile = UUID()
        let photos = [1, 2].map { id in SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: id), filename: "Fixture-\(id).jpg", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo", thumbnail: .init(unitID: 700 + id, revision: "old")) }
        let tasks = photos.map { SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: $0.thumbnail!.unitID, filename: $0.filename, typeCode: 0, needsThumbnail: true, needsVideo: false) }
        await service.configureDisplay(.init(), photos: photos); await service.configureAutomatic(enabled: true, tasks: tasks)
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
        model.setPreviewVisible(photos[1], visible: true, source: UUID())
        let reads = await service.pageReads, selected = model.selectedPhotoIDs
        await model.processAutomaticPreview(); await model.processAutomaticPreview(); await model.processAutomaticPreview()
        let commands = await service.commands
        XCTAssertEqual(commands, [.generateAutomaticPreview(tasks[1], support: .init(hevc: true, vc1: false, video: true)), .generateAutomaticPreview(tasks[0], support: .init(hevc: true, vc1: false, video: true))])
        XCTAssertEqual(model.automaticPreviewCompleted, 2)
        XCTAssertFalse(model.showsAutomaticPreviewStatus, "完成的预览不继续占用图库底部")
        XCTAssertEqual(model.automaticPreviewRevision(for: photos[0]), 1); XCTAssertEqual(model.automaticPreviewRevision(for: photos[1]), 1)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.selectedPhotoIDs, selected)
        let after = await service.pageReads; XCTAssertEqual(after, reads)
        XCTAssertNil(model.pendingMutationID)
    }

    func test自动预览同级先当前再网页完整相邻范围最后可见照片() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        defer { model.cancel() }
        let profile = UUID()
        let photos = (1...5).map { id in SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: id), filename: "Fixture-\(id).jpg", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo", thumbnail: .init(unitID: 700 + id, revision: "old")) }
        let tasks = photos.map { SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: $0.thumbnail!.unitID, filename: $0.filename, typeCode: 0, needsThumbnail: true, needsVideo: false) }
        await service.configureDisplay(.init(), photos: photos); await service.configureAutomatic(enabled: true, tasks: tasks)
        await model.refresh()
        model.setPreviewVisible(photos[0], visible: true, source: UUID())
        model.showPreview(photos[2])
        for _ in photos { await model.processAutomaticPreview() }
        let commands = await service.commands
        XCTAssertEqual(commands, [2, 3, 4, 0, 1].map { .generateAutomaticPreview(tasks[$0], support: .init(hevc: true, vc1: false, video: true)) })
        XCTAssertEqual(model.automaticPreviewCompleted, 5)
    }

    func test自动预览完整相邻窗口小集合缩减和视频排除不扩张范围() async throws {
        for (count, current, video, expected) in [
            (8, 3, -1, [3, 4, 5, 6, 1, 2]),
            (8, 3, 4, [3, 5, 6, 1, 2]),
            (5, 2, -1, [2, 3, 4, 0, 1]),
            (4, 2, -1, [2, 3, 0, 1]),
            (3, 1, -1, [1, 2, 0]),
            (1, 0, -1, [0])
        ] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
                previewConversionSupport: .init(hevc: true, vc1: true, video: true))
            defer { model.cancel() }
            let profile = UUID()
            let photos = (0..<count).map { i in SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: i + 1),
                filename: "Fixture-\(i).jpg", sizeBytes: 8, takenAt: Date(timeIntervalSince1970: 1583107200),
                indexedAt: .distantPast, folderID: 9, mediaType: i == video ? "video360" : "photo", thumbnail: .init(unitID: 701 + i, revision: "old")) }
            let tasks = photos.map { SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: $0.thumbnail!.unitID,
                filename: $0.filename, typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: $0) }
            await service.configureDisplay(.init(), photos: photos); await service.configureAutomatic(enabled: true, tasks: [])
            for i in photos.indices { await service.configureVisibleAutomatic(photos[i], tasks: [tasks[i]]) }
            await model.refresh(); model.showPreview(photos[current])
            let readsBefore = await service.pageReads, originalItems = model.items
            for _ in 0...expected.count { await model.processAutomaticPreview(now: Date().addingTimeInterval(3)) }
            let commands = await service.commands, reads = await service.visibleAutomaticReads, readsAfter = await service.pageReads
            XCTAssertEqual(commands, expected.map { .generateAutomaticPreview(tasks[$0], support: .init(hevc: true, vc1: true, video: true)) }, "count=\(count)")
            XCTAssertTrue(Set(reads).isSubset(of: Set(expected.map { photos[$0].id })))
            XCTAssertEqual(model.items, originalItems); XCTAssertEqual(readsBefore, readsAfter)
        }
    }

    func test自动预览格式等级优先于当前照片且同级保持当前相邻可见顺序() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: true, video: true))
        defer { model.cancel() }
        let profile = UUID()
        let photos = (0..<8).map { i in SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: i + 1),
            filename: "Fixture-\(i).jpg", sizeBytes: 8, takenAt: Date(timeIntervalSince1970: 1583107200),
            indexedAt: .distantPast, folderID: 9, mediaType: [0, 3].contains(i) ? "video" : "photo", thumbnail: .init(unitID: 701 + i, revision: "old")) }
        let priorities: [SynologyPhotoAutomaticPreviewPriority] = [.hevcOrLiveVideo, .standard, .standard, .vc1, .standard, .standard, .standard, .background]
        let tasks = photos.indices.map { i in SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal,
            unitID: 701 + i, filename: photos[i].filename, typeCode: [0, 3].contains(i) ? 1 : 0, needsThumbnail: true, needsVideo: false,
            sourcePhoto: i == 7 ? nil : photos[i], priority: priorities[i]) }
        await service.configureDisplay(.init(), photos: photos); await service.configureAutomatic(enabled: true, tasks: [tasks[7]])
        for i in 0..<7 { await service.configureVisibleAutomatic(photos[i], tasks: [tasks[i]]) }
        await model.refresh(); model.showPreview(photos[3]); model.setPreviewVisible(photos[0], visible: true, source: UUID())
        for _ in 0..<9 { await model.processAutomaticPreview(now: Date().addingTimeInterval(3)) }
        let commands = await service.commands
        XCTAssertEqual(commands, [4, 5, 6, 1, 2, 0, 3, 7].map { .generateAutomaticPreview(tasks[$0], support: .init(hevc: true, vc1: true, video: true)) })
    }

    func test自动预览未加载页边界不循环不主动加载下一页() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, pageSize: 6,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        defer { model.cancel() }
        let profile = UUID()
        let photos = (0..<8).map { i in SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: i + 1),
            filename: "Fixture-\(i).jpg", sizeBytes: 8, takenAt: Date(timeIntervalSince1970: 1583107200),
            indexedAt: .distantPast, folderID: 9, mediaType: "photo", thumbnail: .init(unitID: 701 + i, revision: "old")) }
        await service.configureDisplay(.init(), photos: photos); await service.configureAutomatic(enabled: true, tasks: [])
        await model.refresh(); model.showPreview(photos[4]); XCTAssertTrue(model.hasMore)
        let before = await service.pageReads
        await model.processAutomaticPreview(now: Date().addingTimeInterval(3))
        let reads = await service.visibleAutomaticReads, after = await service.pageReads
        XCTAssertEqual(reads, [photos[4].id, photos[3].id])
        XCTAssertEqual(before, after); XCTAssertEqual(model.items.count, 6); XCTAssertTrue(model.hasMore)
    }

    func test自动预览同照片多个可见位置独立注销且切换预览立即改变优先级() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        defer { model.cancel() }
        let profile = UUID()
        let photos = (1...4).map { id in SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: id), filename: "Fixture-\(id).jpg", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo", thumbnail: .init(unitID: 700 + id, revision: "old")) }
        let tasks = photos.map { SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: $0.thumbnail!.unitID, filename: $0.filename, typeCode: 0, needsThumbnail: true, needsVideo: false) }
        await service.configureDisplay(.init(), photos: photos); await service.configureAutomatic(enabled: true, tasks: tasks)
        await model.refresh()
        let grid = UUID(), strip = UUID()
        model.setPreviewVisible(photos[3], visible: true, source: grid)
        model.setPreviewVisible(photos[3], visible: true, source: strip)
        model.setPreviewVisible(photos[3], visible: false, source: strip)
        await model.processAutomaticPreview()
        model.showPreview(photos[0]); model.showPreview(photos[2])
        await model.processAutomaticPreview()
        let commands = await service.commands
        XCTAssertEqual(commands, [3, 2].map { .generateAutomaticPreview(tasks[$0], support: .init(hevc: true, vc1: false, video: true)) })
    }

    func test可见自动预览共享普通目录在两秒后领取且不扫描整个空间() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        defer { model.cancel() }
        let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .shared, unitID: 7), filename: "Fixture.heic", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo", thumbnail: .init(unitID: 701, revision: "old"))
        let task = SynologyPhotoAutomaticPreviewTask(profileID: photo.id.profileID, space: .shared, unitID: 701, filename: photo.filename, typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: photo)
        await service.setSpaces([.shared]); await service.configureDisplay(.init(), photos: [photo]); await service.configureAutomatic(enabled: true, tasks: [])
        await service.configureVisibleAutomatic(photo, tasks: [task]); await model.refresh()
        model.setPreviewVisible(photo, visible: true, source: UUID())
        await model.processAutomaticPreview()
        var commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        await model.processAutomaticPreview(now: Date().addingTimeInterval(3))
        commands = await service.commands
        XCTAssertEqual(commands, [.generateAutomaticPreview(task, support: .init(hevc: true, vc1: false, video: true))])
        let scans = await service.automaticScans; XCTAssertTrue(scans.isEmpty)
        XCTAssertFalse(model.canManageSharedSpace)
    }

    func test可见自动预览与后台候选同单元跨来源去重() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        defer { model.cancel() }
        let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "Fixture.heic", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo", thumbnail: .init(unitID: 701, revision: "old"))
        let task = SynologyPhotoAutomaticPreviewTask(profileID: photo.id.profileID, space: .personal, unitID: 701, filename: photo.filename, typeCode: 0, needsThumbnail: true, needsVideo: false, sourcePhoto: photo)
        let background = SynologyPhotoAutomaticPreviewTask(profileID: photo.id.profileID, space: .personal, unitID: 701, filename: photo.filename, typeCode: 0, needsThumbnail: true, needsVideo: false)
        await service.configureDisplay(.init(), photos: [photo]); await service.configureAutomatic(enabled: true, tasks: [background])
        await service.configureVisibleAutomatic(photo, tasks: [task]); await model.refresh()
        let source = UUID(); model.setPreviewVisible(photo, visible: true, source: source)
        await model.processAutomaticPreview(now: Date().addingTimeInterval(3))
        model.setPreviewVisible(photo, visible: false, source: source)
        await model.processAutomaticPreview(now: Date().addingTimeInterval(3))
        let commands = await service.commands
        XCTAssertEqual(commands, [.generateAutomaticPreview(task, support: .init(hevc: true, vc1: false, video: true))])
    }

    func test可见自动预览相邻视频不预取但当前实况包含视频单元() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        defer { model.cancel() }
        let profile = UUID()
        let photos = ["photo", "live", "video"].enumerated().map { index, type in
            SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: index + 1), filename: "Fixture-\(index).heic", sizeBytes: 8,
                takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: type,
                thumbnail: .init(unitID: 701 + index, revision: "old"))
        }
        let tasks = [702, 704].enumerated().map { index, unit in SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: unit,
            filename: index == 0 ? photos[1].filename : "Fixture.mov", typeCode: index, needsThumbnail: index == 0, needsVideo: index != 0, sourcePhoto: photos[1]) }
        let backgroundVideo = SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: 704,
            filename: "Fixture.mov", typeCode: 5, needsThumbnail: false, needsVideo: true)
        await service.configureDisplay(.init(), photos: photos); await service.configureAutomatic(enabled: true, tasks: [backgroundVideo])
        await service.configureVisibleAutomatic(photos[1], tasks: tasks); await model.refresh(); model.showPreview(photos[1])
        for _ in 0..<3 { await model.processAutomaticPreview(now: Date().addingTimeInterval(3)) }
        let commands = await service.commands, reads = await service.visibleAutomaticReads
        XCTAssertEqual(commands, tasks.map { .generateAutomaticPreview($0, support: .init(hevc: true, vc1: false, video: true)) })
        XCTAssertFalse(reads.contains(photos[2].id)); XCTAssertTrue(reads.contains(photos[0].id))
    }

    func test自动预览暂停关闭及无转换能力均不领取新任务() async throws {
        for mode in ["paused", "disabled", "unsupported", "changed"] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
                previewConversionSupport: .init(hevc: mode != "unsupported", vc1: false, video: false))
            let task = SynologyPhotoAutomaticPreviewTask(profileID: UUID(), space: .personal, unitID: 701, filename: "Fixture.heic", typeCode: 0, needsThumbnail: true, needsVideo: false)
            await service.configureAutomatic(enabled: mode != "disabled", tasks: [task]); await model.refresh()
            if mode == "paused" { model.pauseAutomaticPreviews() }
            if mode == "changed" { await service.configureAutomatic(enabled: false, tasks: [task]) }
            await model.processAutomaticPreview()
            let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
            let scans = await service.automaticScans; XCTAssertTrue(scans.isEmpty)
        }
    }

    func test自动预览未知结果只回读并退避且暂停后仍确认已提交结果() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        let task = SynologyPhotoAutomaticPreviewTask(profileID: UUID(), space: .personal, unitID: 701, filename: "Fixture.heic", typeCode: 0, needsThumbnail: true, needsVideo: false)
        await service.configureAutomatic(enabled: true, tasks: [task]); await service.makeFirstUploadPending(); await model.refresh()
        let now = Date()
        await model.processAutomaticPreview(now: now)
        let id = model.pendingMutationID; XCTAssertNotNil(id)
        XCTAssertTrue(model.showsAutomaticPreviewStatus, "结果未确定时保留进度和控制")
        await model.processAutomaticPreview(now: now.addingTimeInterval(1))
        var reads = await service.automaticReviews; XCTAssertEqual(reads, 0)
        model.pauseAutomaticPreviews()
        await model.processAutomaticPreview(now: now.addingTimeInterval(6))
        reads = await service.automaticReviews; XCTAssertEqual(reads, 1); XCTAssertEqual(model.pendingMutationID, id)
        await service.resolveUpload()
        await model.processAutomaticPreview(now: now.addingTimeInterval(12))
        XCTAssertNil(model.pendingMutationID); XCTAssertEqual(model.automaticPreviewCompleted, 1)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test自动预览共享扫描只在真实管理权限下执行() async throws {
        for manager in [false, true] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
                previewConversionSupport: .init(hevc: true, vc1: false, video: true))
            await service.setSpaces([.personal, .shared])
            if manager { await service.setConditionSpace(.shared) }
            let task = SynologyPhotoAutomaticPreviewTask(profileID: UUID(), space: .shared, unitID: 701, filename: "Fixture.heic", typeCode: 0, needsThumbnail: true, needsVideo: false)
            await service.configureAutomatic(enabled: true, tasks: [task]); await model.refresh()
            await model.processAutomaticPreview()
            let scans = await service.automaticScans; XCTAssertEqual(scans.contains(.shared), manager)
            let commands = await service.commands; XCTAssertEqual(commands.count, manager ? 1 : 0)
        }
    }

    func test自动预览处理时可浏览且暂停取消后继续核对而不重复提交() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        let task = SynologyPhotoAutomaticPreviewTask(profileID: UUID(), space: .personal, unitID: 701, filename: "Fixture.heic", typeCode: 0, needsThumbnail: true, needsVideo: false)
        await service.configureAutomatic(enabled: true, tasks: [task]); await service.holdFirstUpload(); await service.makeFirstUploadPending()
        let photo = SynologyPhoto(id: .init(profileID: task.profileID, space: .personal, unitID: 7), filename: task.filename, sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo", thumbnail: .init(unitID: 701, revision: "old"))
        await service.configureDisplay(.init(), photos: [photo])
        await model.refresh()
        let now = Date(), worker = Task { await model.processAutomaticPreview(now: now) }
        await service.waitUntilHeld()
        XCTAssertTrue(model.isGeneratingAutomaticPreview); XCTAssertFalse(model.isBrowsingBlocked)
        XCTAssertTrue(model.showsAutomaticPreviewStatus)
        model.selectGroup(model.items); XCTAssertFalse(model.selectedPhotoIDs.isEmpty)
        await model.processAutomaticPreview(now: now)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        model.pauseAutomaticPreviews(); await service.releaseUpload(); await worker.value
        XCTAssertTrue(model.automaticPreviewPaused); XCTAssertFalse(model.isManaging); XCTAssertTrue(model.hasPendingAutomaticPreview)
        await service.resolveUpload(); await model.processAutomaticPreview(now: now.addingTimeInterval(10))
        XCTAssertEqual(model.automaticPreviewCompleted, 1); XCTAssertNil(model.pendingMutationID)
        let final = await service.commands; XCTAssertEqual(final.count, 1)
    }

    func test自动预览打开设置暂停领取及单项失败后继续其他项() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        let profile = UUID(), tasks = [701, 702].map { SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: $0, filename: "Fixture-\($0).heic", typeCode: 0, needsThumbnail: true, needsVideo: false) }
        await service.configureAutomatic(enabled: true, tasks: tasks); await model.refresh()
        model.setAutomaticPreviewSettingsVisible(true); await model.processAutomaticPreview()
        var commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        model.setAutomaticPreviewSettingsVisible(false); await service.rejectFirstPreparation()
        await model.processAutomaticPreview(); XCTAssertNotNil(model.automaticPreviewError)
        await model.processAutomaticPreview()
        commands = await service.commands
        XCTAssertEqual(commands, [.generateAutomaticPreview(tasks[1], support: .init(hevc: true, vc1: false, video: true))])
        model.resumeAutomaticPreviews(); defer { model.cancel() }
        await model.processAutomaticPreview()
        commands = await service.commands; XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(model.automaticPreviewCompleted, 2)
    }

    func test自动预览已同步失败不计成功不跳月份并继续其他照片() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service,
            previewConversionSupport: .init(hevc: true, vc1: false, video: true))
        defer { model.cancel() }
        let profile = UUID(), tasks = [701, 702].map { SynologyPhotoAutomaticPreviewTask(profileID: profile, space: .personal, unitID: $0,
            filename: "Fixture-\($0).heic", typeCode: 0, needsThumbnail: true, needsVideo: false) }
        let photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: 7), filename: tasks[0].filename, sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        await service.configureDisplay(.init(), photos: [photo]); await service.configureAutomatic(enabled: true, tasks: tasks)
        await service.recordNextAutomaticFailure(); await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
        model.selectGroup(model.items); let items = model.items, selection = model.selectedPhotoIDs, reads = await service.pageReads
        await model.processAutomaticPreview()
        XCTAssertEqual(model.automaticPreviewCompleted, 0); XCTAssertNil(model.pendingMutationID)
        XCTAssertEqual(model.automaticPreviewError, L10n.string("photos.automatic.failureRecorded", tasks[0].filename))
        XCTAssertTrue(model.showsAutomaticPreviewStatus, "失败后保留恢复入口")
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.items, items); XCTAssertEqual(model.selectedPhotoIDs, selection)
        await model.processAutomaticPreview()
        XCTAssertEqual(model.automaticPreviewCompleted, 1)
        let commands = await service.commands, finalReads = await service.pageReads
        XCTAssertEqual(finalReads, reads); XCTAssertEqual(commands, tasks.map { .generateAutomaticPreview($0, support: .init(hevc: true, vc1: false, video: true)) })
    }

    func test新格式生成和稍后均保持历史月份选择且只生成一次() async throws {
        for generate in [true, false] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            defer { model.cancel() }
            let prompt = SynologyPhotoCodecPrompt(profileID: UUID(), userID: 12, isAdministrator: true, shouldShow: true, personalSpaceEnabled: true)
            let photo = SynologyPhoto(id: .init(profileID: prompt.profileID, space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 8,
                takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo")
            await service.configureCodec(prompt); await service.configureDisplay(.init(), photos: [photo])
            await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
            let items = model.items, selection = model.selectedPhotoIDs, reads = await service.pageReads
            let loaded = try await model.codecPrompt(); XCTAssertEqual(loaded, prompt)
            let command = SynologyPhotosMutation.respondToCodecPrompt(prompt, generate: generate)
            await service.makeFirstUploadPending(); model.submitMutation(command); await waitForManagement(model)
            XCTAssertNotNil(model.automaticMutationReviewID); XCTAssertEqual(model.managementMessage, L10n.string("photos.codec.pending"))
            model.submitMutation(command); await waitForManagement(model)
            await service.failNextReview(); model.reviewPendingMutation(); await waitForManagement(model)
            XCTAssertNotNil(model.pendingMutationID)
            await service.resolveUpload(); model.reviewPendingMutation(); await waitForManagement(model)
            XCTAssertNil(model.automaticMutationReviewID); XCTAssertNil(model.pendingMutationID)
            XCTAssertEqual(model.managementMessage, generate ? L10n.string("photos.codec.submitted") : nil)
            XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.items, items); XCTAssertEqual(model.selectedPhotoIDs, selection)
            let finalReads = await service.pageReads, commands = await service.commands
            XCTAssertEqual(finalReads, reads); XCTAssertEqual(commands, [command])
        }
    }

    func test新格式生成部分成功继续只保存提示状态() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        defer { model.cancel() }
        let prompt = SynologyPhotoCodecPrompt(profileID: UUID(), userID: 12, isAdministrator: true, shouldShow: true, personalSpaceEnabled: true)
        await service.configureCodec(prompt, partial: true); await model.refresh()
        model.submitMutation(.respondToCodecPrompt(prompt, generate: true)); await waitForManagement(model)
        XCTAssertEqual(model.managementMessage, L10n.string("photos.codec.partial"))
        XCTAssertEqual(model.retryableManagementMutation, .respondToCodecPrompt(prompt, generate: false))
        model.continuePartialManagement(); await waitForManagement(model)
        XCTAssertNil(model.retryableManagementMutation); XCTAssertNil(model.managementMessage)
        let commands = await service.commands
        XCTAssertEqual(commands, [.respondToCodecPrompt(prompt, generate: true), .respondToCodecPrompt(prompt, generate: false)])
    }

    func test新格式已提交或个人空间关闭不能重复生成但可以稍后() async throws {
        for submitted in [true, false] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service)
            defer { model.cancel() }
            let prompt = SynologyPhotoCodecPrompt(profileID: UUID(), userID: 12, isAdministrator: false, shouldShow: true,
                personalSpaceEnabled: submitted, generationAlreadySubmitted: submitted)
            await service.configureCodec(prompt); await model.refresh()
            model.submitMutation(.respondToCodecPrompt(prompt, generate: true)); await waitForManagement(model)
            let before = await service.commands; XCTAssertTrue(before.isEmpty)
            model.submitMutation(.respondToCodecPrompt(prompt, generate: false)); await waitForManagement(model)
            let after = await service.commands; XCTAssertEqual(after, [.respondToCodecPrompt(prompt, generate: false)])
        }
    }

    func test整库维护保留历史月份选择且持续自动核对不重复提交() async throws {
        for action in SynologyPhotoLibraryMaintenanceStatus.Action.allCases {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            defer { model.cancel() }
            let original = SynologyPhotoLibraryMaintenanceStatus(profileID: UUID(), userID: 12, space: .personal,
                indexingCount: 0, previewCount: 0, supportsPreviewGeneration: true)
            let photo = SynologyPhoto(id: .init(profileID: original.profileID, space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 8,
                takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo")
            await service.configureMaintenance(original); await service.configureDisplay(.init(), photos: [photo])
            await service.makeFirstUploadPending(); await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
            model.selectGroup(model.items)
            let selection = model.selectedPhotoIDs, items = model.items, reads = await service.pageReads
            let command = SynologyPhotosMutation.maintainLibrary(original, action)
            model.submitMutation(command); await waitForManagement(model)
            XCTAssertNotNil(model.automaticMutationReviewID); XCTAssertEqual(model.managementMessage, L10n.string("photos.maintenance.pending"))
            model.submitMutation(command); await waitForManagement(model)
            await service.failNextReview(); model.reviewPendingMutation(); await waitForManagement(model)
            XCTAssertNotNil(model.automaticMutationReviewID)
            await service.resolveUpload(); model.reviewPendingMutation(); await waitForManagement(model)
            XCTAssertNil(model.automaticMutationReviewID); XCTAssertNil(model.pendingMutationID)
            XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.items, items); XCTAssertEqual(model.selectedPhotoIDs, selection)
            let finalReads = await service.pageReads, commands = await service.commands
            XCTAssertEqual(finalReads, reads); XCTAssertEqual(commands, [command])
        }
    }

    func test整库维护状态读取无写入且拒绝不同空间及正在维护的命令() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service)
        defer { model.cancel() }
        let original = SynologyPhotoLibraryMaintenanceStatus(profileID: UUID(), userID: 12, space: .personal,
            indexingCount: 2, previewCount: 0, supportsPreviewGeneration: false)
        await service.configureMaintenance(original); await model.refresh()
        let status = try await model.libraryMaintenanceStatus(in: .personal)
        XCTAssertEqual(status, original)
        model.submitMutation(.maintainLibrary(original, .reindex)); model.submitMutation(.maintainLibrary(original, .previews))
        let shared = SynologyPhotoLibraryMaintenanceStatus(profileID: original.profileID, userID: 12, space: .shared,
            indexingCount: 0, previewCount: 0, supportsPreviewGeneration: true)
        model.submitMutation(.maintainLibrary(shared, .reindex)); await waitForManagement(model)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    private func globalFixture() -> SynologyPhotoGlobalSettings {
        .init(profileID: UUID(), administratorID: 12, values: [.person: true, .concept: true, .similar: true, .originalJPEG: true, .userSharing: true, .guestInfo: false],
            excludedExtensions: [], hasHEVC: true, personalRecognition: [.person: true, .concept: true, .similar: true], sharedRecognition: [.person: true, .concept: true, .similar: true],
            personalSpaceEnabled: true, sharedSpaceEnabled: true, sharedRole: .management)
    }

    func test全局设置与缓存保存保留历史月份选择已加载照片和下载能力更新() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let original = globalFixture()
        let photo = SynologyPhoto(id: .init(profileID: original.profileID, space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        await service.configureDisplay(.init(), photos: [photo]); await service.configureGlobal(original)
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
        let selection = model.selectedPhotoIDs, items = model.items, reads = await service.pageReads
        model.submitMutation(.setGlobalSettings(original: original, enabled: original.enabled.subtracting([.person, .originalJPEG]), excludedExtensions: ["RAW"]))
        await waitForManagement(model); XCTAssertFalse(model.supportsOriginalSizeJPEG)
        model.submitMutation(.clearConversionCache(.init(profileID: original.profileID, administratorID: 12, sizeBytes: 10, isClearing: false)))
        await waitForManagement(model)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.items, items); XCTAssertEqual(model.selectedPhotoIDs, selection)
        let finalReads = await service.pageReads; XCTAssertEqual(finalReads, reads)
        XCTAssertNil(model.pendingMutationID); XCTAssertNil(model.automaticMutationReviewID)
        let commands = await service.commands; XCTAssertEqual(commands.count, 2)
    }

    func test全局设置部分保存按实际关闭分类返回相册并保留剩余设置可编辑() async throws {
        for space in [SynologyPhotoSpace.personal, .shared] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            let original = globalFixture()
            await service.configureGlobal(original, partial: true); await service.configureLists([.init(id: 9, name: "Fixture album")])
            await model.refresh(); await model.selectSpace(space); await model.selectSection(.albums); await model.openCategory(.person)
            XCTAssertEqual(model.selectedCategory, .person)
            model.submitMutation(.setGlobalSettings(original: original, enabled: original.enabled.subtracting([.person]), excludedExtensions: original.excludedExtensions))
            await waitForManagement(model)
            XCTAssertNil(model.selectedCategory); XCTAssertEqual(model.selectedSpace, space)
            XCTAssertFalse(model.availableCategories.contains(.person)); XCTAssertTrue(model.availableCategories.contains(.concept))
            XCTAssertEqual(model.collections.map(\.id), [9]); XCTAssertNil(model.pendingMutationID)
            XCTAssertEqual(model.managementMessage, L10n.string("photos.global.partial"))
            let current = try await service.globalSettings(); XCTAssertTrue(current.canSave(enabled: current.enabled, excludedExtensions: current.excludedExtensions))
        }
    }

    func test全局缓存未知结果保留自动核对编号且复查不重发写入() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let original = globalFixture(); await service.configureGlobal(original); await service.makeFirstUploadPending()
        await model.refresh()
        let command = SynologyPhotosMutation.clearConversionCache(.init(profileID: original.profileID, administratorID: 12, sizeBytes: 10, isClearing: false))
        model.submitMutation(command); await waitForManagement(model)
        XCTAssertNotNil(model.automaticMutationReviewID); XCTAssertEqual(model.managementMessage, L10n.string("photos.global.pending"))
        await service.failNextReview(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNotNil(model.automaticMutationReviewID); XCTAssertEqual(model.managementMessage, L10n.string("photos.global.pending"))
        await service.resolveUpload(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.automaticMutationReviewID); XCTAssertNil(model.pendingMutationID)
        let commands = await service.commands; XCTAssertEqual(commands, [command])
    }

    func test共享成员保存及部分完成均保留个人历史月份与选择() async throws {
        for partial in [false, true] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            let profile = UUID(), recipient = SynologyPhotoShareRecipient(id: .init(type: "user", value: .integer(12)), name: "Fixture member")
            let member = SynologyPhotoSharedMember(recipient: recipient, role: .management)
            let original = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: [member])
            let permissions = SynologyPhotoSharedSpaceSettings(profileID: profile, administratorID: 12, isEnabled: true,
                personalSpaceEnabled: true, role: .entry, values: [:], globallyEnabled: [])
            let photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 8,
                takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo")
            await service.configureDisplay(.init(), photos: [photo]); await service.configureSharedSettings(permissions)
            await service.configureMembers(original, partial: partial, resultSettings: permissions)
            await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
            let reads = await service.pageReads, selected = model.selectedPhotoIDs
            model.submitMutation(.setSharedMembers(original: original, members: [member.changingRole(to: .entry)], folderEdits: []))
            await waitForManagement(model)
            XCTAssertEqual(model.items, [photo]); XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.selectedPhotoIDs, selected)
            let finalReads = await service.pageReads; XCTAssertEqual(finalReads, reads)
            XCTAssertNil(model.pendingMutationID); XCTAssertFalse(model.canManageSharedSpace)
            XCTAssertEqual(model.managementMessage, L10n.string(partial ? "photos.members.partial" : "photos.manage.completed"))
        }
    }

    func test共享成员未知保存自动核对且断线不重复提交() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let member = SynologyPhotoSharedMember(recipient: .init(id: .init(type: "user", value: .integer(12)), name: "Fixture"), role: .management)
        let original = SynologyPhotoSharedMembers(profileID: UUID(), administratorID: 12, isEnabled: true, members: [member])
        await service.configureMembers(original); await service.makeFirstUploadPending(); await model.refresh()
        let command = SynologyPhotosMutation.setSharedMembers(original: original, members: [member.changingRole(to: .entry)], folderEdits: [])
        model.submitMutation(command); await waitForManagement(model)
        XCTAssertNotNil(model.automaticMutationReviewID); XCTAssertEqual(model.managementMessage, L10n.string("photos.members.pending"))
        await service.failNextReview(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.managementMessage, L10n.string("photos.members.pending"))
        model.submitMutation(command); await waitForManagement(model)
        await service.resolveUpload(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertNil(model.pendingMutationID); XCTAssertNil(model.automaticMutationReviewID)
        let commands = await service.commands; XCTAssertEqual(commands, [command])
    }

    func test共享成员降级重新读取共享历史月份并移除失效选择() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let profile = UUID(), member = SynologyPhotoSharedMember(recipient: .init(id: .init(type: "user", value: .integer(12)), name: "Fixture"), role: .management)
        let original = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: [member])
        let permissions = SynologyPhotoSharedSpaceSettings(profileID: profile, administratorID: 12, isEnabled: true,
            personalSpaceEnabled: true, role: .entry, values: [:], globallyEnabled: [])
        let photos = [7, 8].map { SynologyPhoto(id: .init(profileID: profile, space: .shared, unitID: $0), filename: "Fixture.jpg", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo") }
        await service.configureDisplay(.init(), photos: photos); await service.setSpaces([.personal, .shared]); await service.setConditionSpace(.shared)
        await service.configureMembers(original, resultSettings: permissions)
        await model.refresh(); await model.selectSpace(.shared); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
        XCTAssertTrue(model.canManageSharedSpace); XCTAssertEqual(model.items.count, 2)
        await service.configureDisplay(.init(), photos: [photos[1]])
        model.submitMutation(.setSharedMembers(original: original, members: [member.changingRole(to: .entry)], folderEdits: [])); await waitForManagement(model)
        XCTAssertEqual(model.items, [photos[1]]); XCTAssertEqual(model.selectedPhotoIDs, [photos[1].id]); XCTAssertEqual(model.selectedTimelineMonthID, 202003)
        XCTAssertEqual(model.selectedSpace, .shared); XCTAssertFalse(model.canManageSharedSpace)
    }

    func test共享成员撤权后丢弃先前在途的共享分页响应() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, pageSize: 1, deletionReviewDelay: { _ in })
        let profile = UUID(), member = SynologyPhotoSharedMember(recipient: .init(id: .init(type: "user", value: .integer(12)), name: "Fixture"), role: .management)
        let original = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: [member])
        let permissions = SynologyPhotoSharedSpaceSettings(profileID: profile, administratorID: 12, isEnabled: true,
            personalSpaceEnabled: false, role: .entry, values: [:], globallyEnabled: [])
        let photos = [7, 8].map { SynologyPhoto(id: .init(profileID: profile, space: .shared, unitID: $0), filename: "Fixture.jpg", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo") }
        await service.configureDisplay(.init(), photos: photos); await service.setSpaces([.shared]); await service.setConditionSpace(.shared)
        await service.configureMembers(original, resultSettings: permissions)
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
        XCTAssertEqual(model.items, [photos[0]]); XCTAssertTrue(model.hasMore)
        await service.holdNextPage(result: .init(items: [photos[1]], offset: 1, nextOffset: 2, hasMore: false))
        let loading = Task { await model.loadMore() }; await service.waitUntilPageHeld()
        await service.configureDisplay(.init(), photos: [photos[0]])
        model.submitMutation(.setSharedMembers(original: original, members: [member.changingRole(to: .entry)], folderEdits: []))
        await waitForManagement(model); await service.releasePage(); await loading.value
        XCTAssertEqual(model.items, [photos[0]]); XCTAssertFalse(model.hasMore); XCTAssertFalse(model.isLoadingMore)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.spaces, [.shared])
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test共享成员失去共享访问退出旧空间且部分结果也更新权限() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let profile = UUID(), member = SynologyPhotoSharedMember(recipient: .init(id: .init(type: "user", value: .integer(12)), name: "Fixture"), role: .management)
        let original = SynologyPhotoSharedMembers(profileID: profile, administratorID: 12, isEnabled: true, members: [member])
        let permissions = SynologyPhotoSharedSpaceSettings(profileID: profile, administratorID: 12, isEnabled: true,
            personalSpaceEnabled: true, role: .none, values: [:], globallyEnabled: [])
        await service.setSpaces([.personal, .shared]); await service.setConditionSpace(.shared)
        await service.configureMembers(original, partial: true, resultSettings: permissions)
        await model.refresh(); await model.selectSpace(.shared)
        model.submitMutation(.setSharedMembers(original: original, members: [], folderEdits: [])); await waitForManagement(model)
        XCTAssertEqual(model.selectedSpace, .personal); XCTAssertFalse(model.spaces.contains(.shared)); XCTAssertFalse(model.canManageSharedSpace)
        XCTAssertNil(model.previewPhoto); XCTAssertEqual(model.managementMessage, L10n.string("photos.members.partial"))
    }

    func test共享目录草稿连续批量保留先前变化并清理父目录撤权子项() throws {
        let profile = UUID(), member = SynologyPhotoShareRecipient.ID(type: "user", value: .integer(12))
        func folder(_ id: Int, parent: Int, role: String?, depth: Int = 0, privacy: String = "private") -> SynologyPhotoMemberFolder {
            .init(profileID: profile, memberID: member, rootID: 1,
                folder: .init(id: id, name: "Fixture", parentID: parent, space: .shared), depth: depth, privacy: privacy, directRole: role, revision: "fixture")
        }
        let root = folder(9, parent: 1, role: "view"), child = folder(10, parent: 9, role: "view", depth: 1), other = folder(11, parent: 1, role: nil)
        var edit = SynologyPhotoMemberFolderEdit(memberID: member, original: [root, child, other])
        edit.applyDraftBatch(.init(action: .checkAll, role: .manage))
        edit.applyDraftBatch(.init(action: .uncheckAll, role: .manage))
        XCTAssertEqual(edit.expectedRole(for: root), "upload"); XCTAssertEqual(edit.expectedRole(for: other), "upload")
        edit.setDraftRole(.download, for: child); XCTAssertEqual(edit.expectedRole(for: child), "download")
        edit.setDraftRole(nil, for: root)
        XCTAssertFalse(edit.canEditFolder(child)); XCTAssertNil(edit.expectedRole(for: child)); XCTAssertFalse(edit.changes.contains { $0.folderID == child.id })
        edit.setDraftRole(.manage, for: child); XCTAssertNil(edit.expectedRole(for: child)); XCTAssertTrue(edit.canSave)
        let publicRoot = folder(20, parent: 1, role: nil, privacy: "public-download"), publicChild = folder(21, parent: 20, role: nil, depth: 1)
        var publicEdit = SynologyPhotoMemberFolderEdit(memberID: member, original: [publicRoot, publicChild])
        XCTAssertTrue(publicEdit.canEditFolder(publicChild)); publicEdit.setDraftRole(.view, for: publicChild); XCTAssertTrue(publicEdit.canSave)
    }

    func test共享设置保存保留个人历史月份选择和已加载照片() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let original = SynologyPhotoSharedSpaceSettings(profileID: UUID(), administratorID: 12, isEnabled: true, personalSpaceEnabled: true,
            role: .management, values: [.person: true, .concept: true, .publicRoot: false], globallyEnabled: [.person, .concept])
        let photo = SynologyPhoto(id: .init(profileID: original.profileID, space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        await service.configureDisplay(.init(), photos: [photo]); await service.configureSharedSettings(original)
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
        let selection = model.selectedPhotoIDs, items = model.items, reads = await service.pageReads
        for index in 0..<2 {
            let current = try await service.sharedSpaceSettings()
            let command: SynologyPhotosMutation = index == 0 ? .setSharedSpaceSettings(original: current, enabled: [.concept]) : .setSharedSpaceEnabled(original: current, enabled: false)
            model.submitMutation(command); await waitForManagement(model)
            XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.items, items); XCTAssertEqual(model.selectedPhotoIDs, selection)
            let finalReads = await service.pageReads; XCTAssertEqual(finalReads, reads)
            XCTAssertNil(model.pendingMutationID)
        }
        XCTAssertFalse(model.spaces.contains(.shared)); XCTAssertFalse(model.canManageSharedSpace)
    }

    func test共享设置关闭正在浏览的共享空间退出旧位置() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let original = SynologyPhotoSharedSpaceSettings(profileID: UUID(), administratorID: 12, isEnabled: true, personalSpaceEnabled: true,
            role: .management, values: [.person: true], globallyEnabled: [.person])
        await service.configureSharedSettings(original); await model.refresh(space: .shared)
        XCTAssertEqual(model.selectedSpace, .shared)
        model.submitMutation(.setSharedSpaceEnabled(original: original, enabled: false)); await waitForManagement(model)
        XCTAssertEqual(model.selectedSpace, .personal); XCTAssertFalse(model.spaces.contains(.shared))
        XCTAssertNil(model.selectedCategory); XCTAssertTrue(model.folderHistory.isEmpty)
        XCTAssertFalse(model.canManageSharedSpace); XCTAssertNil(model.pendingMutationID)
    }

    func test共享设置关闭当前识别分类返回相册而其他空间不受影响() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let original = SynologyPhotoSharedSpaceSettings(profileID: UUID(), administratorID: 12, isEnabled: true, personalSpaceEnabled: true,
            role: .management, values: [.person: true, .concept: true], globallyEnabled: [.person, .concept])
        await service.configureSharedSettings(original); await service.configureLists([.init(id: 9, name: "Fixture album")])
        await model.refresh(); await model.selectSpace(.shared); await model.selectSection(.albums); await model.openCategory(.person)
        XCTAssertEqual(model.selectedCategory, .person); XCTAssertEqual(model.selectedSpace, .shared)
        model.submitMutation(.setSharedSpaceSettings(original: original, enabled: [.concept])); await waitForManagement(model)
        XCTAssertNil(model.selectedCategory); XCTAssertEqual(model.selectedSpace, .shared)
        XCTAssertFalse(model.availableCategories.contains(.person)); XCTAssertTrue(model.availableCategories.contains(.concept))
        XCTAssertEqual(model.collections.map(\.id), [9]); XCTAssertNil(model.pendingMutationID)
    }

    func test个人识别保存保留时间线位置选择且不重新读取照片() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let original = SynologyPhotoRecognitionSettings(values: [.person: true, .concept: true, .similar: true], globallyEnabled: [.person, .concept, .similar], personalSpaceEnabled: true)
        let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "Fixture.jpg", sizeBytes: 8,
            takenAt: Date(timeIntervalSince1970: 1583107200), indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        await service.configureDisplay(.init(), photos: [photo]); await service.configureRecognition(original)
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3)); model.selectGroup(model.items)
        let selection = model.selectedPhotoIDs, items = model.items, reads = await service.pageReads
        model.submitMutation(.setRecognitionSettings(original: original, enabled: [.person])); await waitForManagement(model)
        XCTAssertEqual(model.selectedTimelineMonthID, 202003); XCTAssertEqual(model.items, items); XCTAssertEqual(model.selectedPhotoIDs, selection)
        let finalReads = await service.pageReads; XCTAssertEqual(finalReads, reads)
        let saved = try await service.recognitionSettings(); XCTAssertEqual(saved.enabled, [.person])
        XCTAssertNil(model.pendingMutationID)
    }

    func test关闭当前个人分类返回相册首页而不保留失效分类() async throws {
        for kind in [SynologyPhotoRecognitionSettings.Kind.person, .concept] {
            let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
            let original = SynologyPhotoRecognitionSettings(values: [.person: true, .concept: true, .similar: true], globallyEnabled: [.person, .concept, .similar], personalSpaceEnabled: true)
            await service.configureRecognition(original)
            await service.configureLists([.init(id: 9, name: "Fixture album")])
            await model.refresh(); await model.selectSection(.albums); await model.openCategory(kind.category)
            XCTAssertEqual(model.collections.first?.id, 88)
            model.submitMutation(.setRecognitionSettings(original: original, enabled: original.enabled.subtracting([kind])))
            await waitForManagement(model)
            XCTAssertEqual(model.section, .albums); XCTAssertNil(model.selectedCategory); XCTAssertNil(model.selectedCategoryItem)
            XCTAssertFalse(model.availableCategories.contains(kind.category)); XCTAssertTrue(model.availableCategories.contains(.videos))
            XCTAssertEqual(model.collections.map(\.id), [9]); XCTAssertTrue(model.items.isEmpty)
        }
    }

    func test显示设置保存更新分组但保留月份选择和分页() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        let calendar = Calendar(identifier: .gregorian), profile = UUID()
        let photos = [3, 2, 1].map { day in
            SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: day), filename: "Fixture-\(day).jpg", sizeBytes: 12,
                takenAt: calendar.date(from: .init(year: 2020, month: 3, day: day, hour: 13, minute: 5))!, indexedAt: .distantPast, folderID: 9, mediaType: "photo")
        }
        let original = SynologyPhotoDisplaySettings()
        await service.configureDisplay(original, photos: photos)
        await model.refresh(); await model.jumpToMonth(.init(year: 2020, month: 3))
        model.selectGroup(model.items)
        let month = model.selectedTimelineMonthID, selection = model.selectedPhotoIDs, pagination = model.paginationIdentity
        let reads = await service.pageReads
        XCTAssertEqual(model.datedGroups.count, 3)
        let updated = SynologyPhotoDisplaySettings(grouping: .month, dateFormat: .daySlash, clock: .twelve, defaultSort: .init(field: .filename, direction: .descending), showsPreviewInfo: true)
        model.submitMutation(.setDisplaySettings(original: original, updated: updated)); await waitForManagement(model)
        XCTAssertEqual(model.displayPreferences, updated)
        XCTAssertEqual(model.datedGroups.count, 1); XCTAssertEqual(model.datedGroups.first?.photos.count, 3)
        XCTAssertEqual(model.selectedTimelineMonthID, month); XCTAssertEqual(model.selectedPhotoIDs, selection)
        // 写入代次应作废旧请求，但不能清空已加载位置。
        XCTAssertEqual(model.paginationIdentity.split(separator: ":").dropFirst(), pagination.split(separator: ":").dropFirst())
        let finalReads = await service.pageReads; XCTAssertEqual(finalReads, reads)
        XCTAssertEqual(model.formattedPhotoDate(photos[0].takenAt, group: true), "03/2020")
        XCTAssertTrue(model.formattedPhotoDate(photos[0].takenAt, includesTime: true).contains("1:05"))
        await model.refresh(); XCTAssertEqual(model.displayPreferences, updated)
    }

    func test显示日期格式公历年和全部分隔符不使用周所属年() async throws {
        let previous = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = previous }
        AppLanguageStore.shared.selection = .english
        let calendar = Calendar(identifier: .gregorian), date = calendar.date(from: .init(year: 2019, month: 12, day: 31, hour: 13, minute: 5))!
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service)
        for format in SynologyPhotoDisplaySettings.DateFormat.allCases {
            await service.configureDisplay(.init(grouping: .month, dateFormat: format))
            await model.refresh()
            let text = model.formattedPhotoDate(date)
            XCTAssertTrue(text.contains("2019")); XCTAssertFalse(text.contains("2020"))
            XCTAssertTrue(text.contains("12")); XCTAssertTrue(text.contains("31"))
            XCTAssertFalse(model.formattedPhotoDate(date, group: true).contains("31"))
            XCTAssertTrue(model.formattedPhotoDate(date, includesTime: true).contains("13:05"))
        }
        await service.configureDisplay(nil); await model.refresh(); XCTAssertNil(model.displayPreferences)
    }

    func test重复项设置保存使用冻结快照且不刷新图库() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        let original = try await model.duplicateSettings(), reads = await service.pageReads
        let updated = SynologyPhotoDuplicateSettings(upload: .ignore, transfer: .overwrite)
        model.submitMutation(.setDuplicateSettings(original: original, updated: updated))
        await waitForManagement(model)
        let settings = try await model.duplicateSettings(), after = await service.pageReads
        XCTAssertEqual(settings, updated); XCTAssertEqual(reads, after)
        XCTAssertNil(model.pendingMutationID)
    }

    func test上传单项取消和清理不影响当前及后续文件() async throws {
        let service = PhotoUploadServiceStub(); await service.holdFirstUpload()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh()
        let files = makeUploadFiles() + [PhotoUploadFile(url: URL(fileURLWithPath: "/synthetic/third.png"), size: 128, modifiedAt: .distantPast)]
        model.enqueueUploads(files, album: nil, folder: nil)
        await service.waitUntilHeld()
        XCTAssertFalse(model.canClearUpload(files[0].id)); XCTAssertFalse(model.canCancelUpload(files[0].id))
        model.clearUpload(files[0].id); model.cancelUpload(files[0].id)
        XCTAssertTrue(model.canCancelUpload(files[1].id)); model.cancelUpload(files[1].id)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.uploading, .cancelled, .queued])
        model.clearUpload(files[1].id)
        await service.releaseUpload(); await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.id), [files[0].id, files[2].id])
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed])
        let commands = await service.commands; XCTAssertEqual(commands.count, 2)
        model.clearUpload(files[0].id)
        XCTAssertEqual(model.uploadQueue.map(\.id), [files[2].id])
        let after = await service.commands.count; XCTAssertEqual(after, 2, "移除记录不删除照片")
    }

    func test上传中移除前一条完成记录不破坏当前索引或回执() async throws {
        let service = PhotoUploadServiceStub(); await service.holdFirstUpload()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); let files = makeUploadFiles()
        model.enqueueUploads(files, album: nil, folder: nil)
        await service.waitUntilHeld(); await service.holdFirstUpload(); await service.releaseUpload()
        await service.waitUntilHeld()
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .uploading])
        model.clearUpload(files[0].id)
        XCTAssertEqual(model.uploadQueue.map(\.id), [files[1].id])
        await service.releaseUpload(); await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.first?.state, .completed)
        XCTAssertEqual(model.uploadQueue.first?.uploadedPhoto?.filename, files[1].url.lastPathComponent)
        let commands = await service.commands.count; XCTAssertEqual(commands, 2)
    }

    func test上传未知结果不能移除或打开且排队项仍可单独取消() async throws {
        let service = PhotoUploadServiceStub(); await service.makeFirstUploadPending()
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); model.enqueueUploads(makeUploadFiles(), album: nil, folder: nil); await waitForManagement(model)
        let first = try XCTUnwrap(model.uploadQueue.first), last = try XCTUnwrap(model.uploadQueue.last)
        XCTAssertEqual(first.state, .pendingReview)
        XCTAssertFalse(model.canClearUpload(first.id)); XCTAssertFalse(model.canCancelUpload(first.id))
        XCTAssertFalse(model.canOpenUpload(first.id, destination: .folder))
        model.clearUpload(first.id); model.cancelUpload(last.id)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.pendingReview, .cancelled])
        let writes = await service.commands.count; XCTAssertEqual(writes, 1)
        model.cancel()
    }

    func test上传打开位置使用当前子目录和完整路径且不改变队列() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([.personal, .shared])
        let root = SynologyPhotoCollection(id: 101, name: "/", parentID: 0, path: "/", space: .shared)
        let parent = SynologyPhotoCollection(id: 102, name: "Parent", parentID: 101, path: "/Parent", space: .shared)
        let child = SynologyPhotoCollection(id: 103, name: "Child", parentID: 102, path: "/Parent/Child", space: .shared)
        for folder in [root, parent, child] { await service.addFolder(folder) }
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); model.enqueueUploads([makeUploadFiles()[0]], album: nil, folder: parent, space: .shared)
        await waitForManagement(model)
        await service.setNavigationPhotoFolder(103)
        let entry = try XCTUnwrap(model.uploadQueue.first)
        let opened = await model.openUpload(entry.id, destination: .folder)
        XCTAssertTrue(opened); XCTAssertEqual(model.section, .folders); XCTAssertEqual(model.selectedSpace, .shared)
        XCTAssertEqual(model.folderHistory.map(\.id), [101, 102, 103]); XCTAssertEqual(model.uploadQueue.first?.state, .completed)
        let reads = await service.navigationFolderReads; XCTAssertEqual(reads, [103, 102, 101])
        let writes = await service.commands.count; XCTAssertEqual(writes, 1)
    }

    func test上传目录导航失败及循环保留原页面并可重试() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.refresh(); model.enqueueUploads([makeUploadFiles()[0]], album: nil, folder: nil); await waitForManagement(model)
        let entry = try XCTUnwrap(model.uploadQueue.first)
        let failed = await model.openUpload(entry.id, destination: .folder)
        XCTAssertFalse(failed); XCTAssertEqual(model.section, .timeline); XCTAssertNotNil(model.uploadNavigationError)
        await service.addFolder(.init(id: 9, name: "Loop", parentID: 9, path: "/Loop"))
        let cycle = await model.openUpload(entry.id, destination: .folder)
        XCTAssertFalse(cycle); XCTAssertEqual(model.section, .timeline)
        await service.replaceNavigationFolders([.init(id: 9, name: "Root", parentID: 0, path: "/")])
        let retried = await model.openUpload(entry.id, destination: .folder)
        XCTAssertTrue(retried); XCTAssertNil(model.uploadNavigationError)
        let writes = await service.commands.count; XCTAssertEqual(writes, 1)
    }

    func test上传目录迟到读取不能覆盖已经切换的页面() async throws {
        let service = PhotoUploadServiceStub(), model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await service.addFolder(.init(id: 9, name: "Root", parentID: 0, path: "/"))
        await model.refresh(); model.enqueueUploads([makeUploadFiles()[0]], album: nil, folder: nil); await waitForManagement(model)
        let entry = try XCTUnwrap(model.uploadQueue.first)
        await service.holdNavigationFolder()
        let navigation = Task { await model.openUpload(entry.id, destination: .folder) }
        await service.waitUntilNavigationHeld()
        await model.selectSection(.albums)
        await service.releaseNavigationFolder()
        let opened = await navigation.value
        XCTAssertFalse(opened); XCTAssertEqual(model.section, .albums); XCTAssertTrue(model.folderHistory.isEmpty)
        XCTAssertEqual(model.uploadQueue.count, 1); XCTAssertNil(model.uploadNavigationError)
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
        guard case .upload(let url, _, _, nil, _, _) = commands[0] else { return XCTFail("先上传原件") }
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
        XCTAssertTrue(model.canOpenUpload(entry.id, destination: .folder))
        XCTAssertFalse(model.canOpenUpload(entry.id, destination: .album))
        XCTAssertTrue(model.canClearUpload(entry.id))
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
            guard case .upload(_, _, _, let folder, _, _) = command else { return XCTFail("仅上传") }
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
            guard case .upload(_, _, _, let folder, _, _) = command else { return XCTFail("只应上传") }
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

    func test相册角色决定下载上传与移除但不授予他人原件修改权() async throws {
        for (download, contribute) in [(false, false), (true, false), (true, true)] {
            for provider in [12, 99] {
                let service = PhotoUploadServiceStub(); await service.setSpaces([])
                let photo = collaborationPhoto(provider: provider)
                await service.setAlbumPhoto(photo)
                await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: download, canContribute: contribute))
                let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
                model.toggleSelection(photo)
                XCTAssertEqual(model.items, [photo]); XCTAssertNil(model.errorMessage)
                XCTAssertEqual(model.canUploadPhotos, contribute)
                XCTAssertEqual(model.canDownload(photo), download)
                XCTAssertEqual(model.canRemoveAlbumSelection, contribute && provider == 12)
                XCTAssertFalse(model.canModifyOriginal(photo)); XCTAssertFalse(model.canDeleteSelection)
                model.requestDeletion(photo)
                XCTAssertFalse(model.isCheckingDeletion); XCTAssertTrue(model.deletionCandidates.isEmpty)
                model.submitMutation(.removeFromAlbum(id: 21, photos: [photo]))
                await waitForManagement(model)
                let commands = await service.commands
                XCTAssertEqual(commands.count, contribute && provider == 12 ? 1 : 0)
            }
        }
    }

    func test相册权限读取失败不阻断浏览且不会沿用之前的写入权限() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([])
        let photo = collaborationPhoto(provider: 12); await service.setAlbumPhoto(photo)
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service)
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture"))
        XCTAssertTrue(model.canUploadPhotos)
        await service.setAlbumAccess(nil); await model.refresh()
        XCTAssertEqual(model.items, [photo]); XCTAssertNil(model.errorMessage)
        XCTAssertNotNil(model.managementMessage); XCTAssertNil(model.selectedAlbumAccess)
        XCTAssertFalse(model.canUploadPhotos); XCTAssertFalse(model.canDownload(photo))
        model.enqueueUploads(makeUploadFiles(), album: model.selectedAlbum, folder: nil)
        XCTAssertTrue(model.uploadQueue.isEmpty)
    }

    func test贡献者无原空间直接上传相册并在切页后保持队列目标() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([]); await service.holdFirstUpload()
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Target"))
        XCTAssertTrue(model.canUploadPhotos); XCTAssertTrue(model.managementFeatures.isEmpty)
        model.enqueueUploads(makeUploadFiles(), album: model.selectedAlbum, folder: nil)
        await service.waitUntilHeld()
        await model.open(.init(id: 22, name: "Other"))
        await service.releaseUpload(); await waitForManagement(model)
        XCTAssertEqual(model.selectedAlbum?.id, 22); XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed])
        let commands = await service.commands, folderReads = await service.conditionFolderSpaces
        XCTAssertEqual(commands.count, 2); XCTAssertTrue(folderReads.isEmpty)
        let entry = try XCTUnwrap(model.uploadQueue.first)
        XCTAssertFalse(model.canOpenUpload(entry.id, destination: .folder))
        XCTAssertTrue(model.canOpenUpload(entry.id, destination: .album))
        let opened = await model.openUpload(entry.id, destination: .album)
        XCTAssertTrue(opened); XCTAssertEqual(model.selectedAlbum?.id, 21)
        let afterNavigation = await service.commands.count; XCTAssertEqual(afterNavigation, 2)
        for command in commands {
            guard case .uploadToAlbum(_, _, _, let albumID, _) = command else { return XCTFail("直接上传，不重复加入相册或建立原空间目录") }
            XCTAssertEqual(albumID, 21)
        }
    }

    func test相册上传结果未知只回读不重复上传并继续队列() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([]); await service.makeFirstUploadPending()
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Target"))
        model.enqueueUploads(makeUploadFiles(), album: model.selectedAlbum, folder: nil)
        await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.pendingReview, .queued])
        model.retryUpload(model.uploadQueue[0].id)
        let before = await service.commands.count; XCTAssertEqual(before, 1)
        await service.resolveUpload(); model.reviewPendingMutation(); await waitForManagement(model)
        XCTAssertEqual(model.uploadQueue.map(\.state), [.completed, .completed])
        let commands = await service.commands
        XCTAssertEqual(commands.count, 2)
        XCTAssertTrue(commands.allSatisfy { if case .uploadToAlbum = $0 { true } else { false } })
        XCTAssertEqual(model.items.count, 2)
    }

    func test条件相册禁止手工上传而所有者可移除别人提供的成员() async throws {
        let service = PhotoUploadServiceStub(); let photo = collaborationPhoto(provider: 99)
        await service.setAlbumPhoto(photo)
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: true, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Owned"))
        model.toggleSelection(photo); XCTAssertTrue(model.canRemoveAlbumSelection)
        XCTAssertFalse(model.canModifyOriginal(photo))
        model.submitMutation(.removeFromAlbum(id: 21, photos: [photo])); await waitForManagement(model)
        XCTAssertTrue(model.items.isEmpty)
        await model.open(.init(id: 21, name: "Rule", isConditional: true))
        XCTAssertFalse(model.canUploadPhotos)
        model.enqueueUploads(makeUploadFiles(), album: model.selectedAlbum, folder: nil)
        XCTAssertTrue(model.uploadQueue.isEmpty)
    }

    func test相册转加按提供者而不是原件所有者决定入口() async throws {
        for spaces: [SynologyPhotoSpace] in [[.personal], []] {
            for provider in [12, 99] {
                let service = PhotoUploadServiceStub(); await service.setSpaces(spaces)
                let photo = collaborationPhoto(provider: provider); await service.setAlbumPhoto(photo)
                await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
                let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
                await model.selectSection(.albums); await model.open(.init(id: 21, name: "Source"))
                XCTAssertEqual(model.canAddToAlbum([photo]), !spaces.isEmpty && provider == 12)
                XCTAssertFalse(model.canModifyOriginal(photo), "添加到相册不赋予他人原件修改权")
                model.submitMutation(.addToAlbum(id: 22, photos: [photo])); await waitForManagement(model)
                let commands = await service.commands
                XCTAssertEqual(commands.count, !spaces.isEmpty && provider == 12 ? 1 : 0)
                XCTAssertEqual(model.selectedAlbum?.id, 21); XCTAssertEqual(model.items, [photo])
            }
        }
    }

    func test共享相册混合来源添加遵循两空间及共享管理权限() async throws {
        for manager in [false, true] {
            let service = PhotoUploadServiceStub(); await service.setSpaces([.personal, .shared])
            if manager { await service.setConditionSpace(.shared) }
            await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: false, canDownload: true, canContribute: true))
            let personal = collaborationPhoto(provider: 12)
            let shared = SynologyPhoto(id: .init(profileID: personal.id.profileID, space: .shared, unitID: 8), filename: "shared.jpg", sizeBytes: 128,
                takenAt: personal.takenAt, indexedAt: personal.indexedAt, folderID: 9, mediaType: "photo",
                albumContext: .init(albumID: 21, ownerUserID: 0, providerUserID: 12))
            let model = SynologyPhotosModel(repository: service)
            await model.selectSection(.albums); await model.open(.init(id: 21, name: "Source"))
            XCTAssertTrue(model.canAddToAlbum([shared]))
            XCTAssertEqual(model.canAddToAlbum([personal, shared]), manager)
        }
    }

    private func collaborationPhoto(provider: Int) -> SynologyPhoto {
        .init(id: .init(profileID: UUID(), space: .personal, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
              takenAt: Date(timeIntervalSince1970: 50), indexedAt: Date(timeIntervalSince1970: 60), folderID: 9, mediaType: "photo",
              albumContext: .init(albumID: 21, ownerUserID: 99, providerUserID: provider))
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

    func test搬移后原相册按已加载范围更新新身份而不全量刷新() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([.personal, .shared])
        let originals = mixedAlbumFixtures(), moved = movedAlbumFixture(originals[1])
        var updated = originals; updated[1] = moved
        await service.setAlbumPhotos(originals); await service.setMovedAlbumPhotos(updated)
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: true, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, pageSize: 2, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album")); await model.loadMore()
        XCTAssertEqual(model.items, Array(originals.prefix(4))); XCTAssertTrue(model.hasMore)
        model.toggleSelection(originals[2])
        let access = await service.accessReads, pages = await service.pageReads
        model.submitMutation(.move([originals[1]], folderID: 109, destinationSpace: .shared)); await waitForManagement(model)
        XCTAssertEqual(model.items, Array(updated.prefix(4))); XCTAssertEqual(model.selectedAlbum?.id, 21)
        XCTAssertEqual(model.selectedPhotoIDs, [originals[2].id]); XCTAssertTrue(model.hasMore)
        XCTAssertFalse(model.needsAlbumRefresh); XCTAssertNil(model.errorMessage)
        let afterAccess = await service.accessReads, afterPages = await service.pageReads, offsets = await service.albumPageOffsets
        XCTAssertEqual(afterAccess, access); XCTAssertEqual(afterPages - pages, 2); XCTAssertEqual(Array(offsets.suffix(2)), [0, 2])
        await model.loadMore(); XCTAssertEqual(model.items, updated); XCTAssertFalse(model.hasMore)
    }

    func test搬移后相册读取短暂失败自动重试不重新移动() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([.personal, .shared])
        let originals = Array(mixedAlbumFixtures().prefix(2)), moved = movedAlbumFixture(originals[0])
        await service.setAlbumPhotos(originals); await service.setMovedAlbumPhotos([moved, originals[1]], failures: 1)
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: true, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
        model.submitMutation(.move([originals[0]], folderID: 109, destinationSpace: .shared)); await waitForManagement(model)
        XCTAssertEqual(model.items, [moved, originals[1]]); XCTAssertFalse(model.needsAlbumRefresh)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test搬移完成但相册刷新失败可重试读取且保留当前照片() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([.personal, .shared])
        let originals = Array(mixedAlbumFixtures().prefix(2)), moved = movedAlbumFixture(originals[0])
        await service.setAlbumPhotos(originals); await service.setMovedAlbumPhotos([moved, originals[1]], failures: 3)
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: true, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
        model.submitMutation(.move([originals[0]], folderID: 109, destinationSpace: .shared)); await waitForManagement(model)
        XCTAssertEqual(model.items, originals); XCTAssertTrue(model.needsAlbumRefresh); XCTAssertNotNil(model.errorMessage)
        XCTAssertNil(model.pendingMutationID)
        await model.retryAlbumRefresh()
        XCTAssertEqual(model.items, [moved, originals[1]]); XCTAssertFalse(model.needsAlbumRefresh); XCTAssertNil(model.errorMessage)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test取消相册读取时不把旧页面结果写回() async throws {
        let service = PhotoUploadServiceStub(); await service.setSpaces([.personal, .shared])
        let originals = Array(mixedAlbumFixtures().prefix(2))
        await service.setAlbumPhotos(originals); await service.setMovedAlbumPhotos([movedAlbumFixture(originals[0]), originals[1]])
        await service.setAlbumAccess(.init(albumID: 21, currentUserID: 12, isOwner: true, canDownload: true, canContribute: true))
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in })
        await model.selectSection(.albums); await model.open(.init(id: 21, name: "Fixture album"))
        await service.holdNextPage()
        model.submitMutation(.move([originals[0]], folderID: 109, destinationSpace: .shared))
        await service.waitUntilPageHeld(); model.cancel(); await service.releasePage(); await waitForManagement(model)
        XCTAssertEqual(model.items, originals); XCTAssertFalse(model.needsAlbumRefresh)
    }

    func test混合评级部分完成后只继续剩余照片且不替换选区目标() async throws {
        let service = DatePhotoServiceStub(); await service.configureRequestAccess(spaces: [.personal, .shared], manager: true); await service.enableManagement(partial: true)
        let model = SynologyPhotosModel(repository: service, deletionReviewDelay: { _ in }); await model.refresh()
        let personal = try XCTUnwrap(model.items.first), shared = movedAlbumFixture(personal, albumID: nil)
        XCTAssertTrue(model.canEditSelection([personal, shared], supportsMixedSpaces: true))
        XCTAssertFalse(model.canEditSelection([personal, shared], supportsMixedSpaces: false))
        model.submitMutation(.edit([personal, shared], .rating(4))); await waitForManagement(model)
        guard case .edit(let remaining, let edit) = model.retryableManagementMutation else { return XCTFail("应保留剩余共享照片") }
        XCTAssertEqual(remaining, [shared]); XCTAssertEqual(edit, .rating(4))
        model.toggleSelection(personal); model.continuePartialManagement(); await waitForManagement(model)
        let commands = await service.managementCommands
        XCTAssertEqual(commands, [.edit([personal, shared], .rating(4)), .edit([shared], .rating(4))])
        XCTAssertNil(model.retryableManagementMutation)
    }

    private func mixedAlbumFixtures() -> [SynologyPhoto] {
        let profile = UUID()
        return (1...5).map { id in .init(id: .init(profileID: profile, space: .personal, unitID: id), filename: "Fixture-\(id).jpg", sizeBytes: 128,
            takenAt: Date(timeIntervalSince1970: Double(1583020800 - id)), indexedAt: Date(timeIntervalSince1970: 1583020800), folderID: 9, mediaType: "photo",
            albumContext: .init(albumID: 21, ownerUserID: 12, providerUserID: 12)) }
    }

    private func movedAlbumFixture(_ photo: SynologyPhoto, albumID: Int? = 21) -> SynologyPhoto {
        .init(id: .init(profileID: photo.id.profileID, space: .shared, unitID: photo.id.unitID + 100), filename: photo.filename, sizeBytes: photo.sizeBytes,
            takenAt: photo.takenAt, indexedAt: photo.indexedAt, folderID: 109, mediaType: photo.mediaType,
            albumContext: albumID.map { .init(albumID: $0, ownerUserID: 0, providerUserID: 12) })
    }

    func test跨空间搬移保留月份与其他项目且复制不移除来源() async throws {
        for move in [false, true] {
            for partial in [false, true] {
                let service = DatePhotoServiceStub()
                await service.enableManagement(partial: partial); await service.configureRequestAccess(spaces: [.personal, .shared], manager: false)
                let model = SynologyPhotosModel(repository: service, pageSize: 2, deletionReviewDelay: { _ in })
                await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
                let original = model.items, reads = await service.requests.count
                let photo = try XCTUnwrap(original.first)
                let command: SynologyPhotosMutation = move ? .move([photo], folderID: 91, destinationSpace: .shared) : .copy([photo], folderID: 91, destinationSpace: .shared)
                model.submitMutation(command); await waitForManagement(model)
                XCTAssertEqual(model.selectedTimelineMonthID, 201408)
                XCTAssertEqual(model.items, move && !partial ? Array(original.dropFirst()) : original)
                let afterReads = await service.requests.count, writes = await service.managementCommands
                XCTAssertEqual(afterReads, reads); XCTAssertEqual(writes, [command])
            }
        }
    }

    func test目标空间选择符合网页方向且拒绝混合来源批量() async throws {
        let service = DatePhotoServiceStub()
        await service.enableManagement(); await service.configureRequestAccess(spaces: [.personal, .shared], manager: false)
        let model = SynologyPhotosModel(repository: service); await model.refresh()
        let photo = try XCTUnwrap(model.items.first)
        let shared = SynologyPhoto(id: .init(profileID: photo.id.profileID, space: .shared, unitID: photo.id.unitID), filename: photo.filename,
            sizeBytes: photo.sizeBytes, takenAt: photo.takenAt, indexedAt: photo.indexedAt, folderID: photo.folderID, mediaType: photo.mediaType)
        XCTAssertEqual(model.transferDestinationSpaces(for: [photo], copying: false), [.personal, .shared])
        XCTAssertEqual(model.transferDestinationSpaces(for: [shared], copying: false), [.shared])
        XCTAssertEqual(model.transferDestinationSpaces(for: [shared], copying: true), [.personal, .shared])
        XCTAssertTrue(model.transferDestinationSpaces(for: [photo, shared], copying: true).isEmpty)
        model.submitMutation(.move([shared], folderID: 91, destinationSpace: .personal)); await waitForManagement(model)
        let writes = await service.managementCommands; XCTAssertTrue(writes.isEmpty)
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
        XCTAssertNil(model.deletionMessage, "删除成功不留下常驻状态文字")
        XCTAssertEqual(model.deletionSuccessMessage, L10n.string("photos.selection.deleted", 2))
        model.deletionSuccessMessage = nil
        await model.continueAutomaticDeletionReview()
        XCTAssertNil(model.deletionSuccessMessage, "关闭成功提示后不会再次弹出")
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

    func test删除超过首轮等待后自动恢复不需要手动核对且保持月份() async throws {
        let repository = DatePhotoServiceStub()
        await repository.failDeletionReviewCount(8)
        let model = SynologyPhotosModel(repository: repository, pageSize: 2, deletionReviewDelay: { _ in await Task.yield() })
        defer { model.cancel() }
        await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
        let target = model.items[0]
        model.confirmDeletion(target); try await waitFor { !model.isDeleting }
        let early = await repository.reviewIDs; XCTAssertEqual(early.count, 6)
        XCTAssertTrue(model.hasAutomaticDeletionReview)
        XCTAssertEqual(model.deletionMessage, L10n.string("photos.selection.reviewContinuing"))
        XCTAssertNil(model.deletionSuccessMessage, "等待确认时不能提前提示删除成功")
        await model.continueAutomaticDeletionReview()
        XCTAssertFalse(model.hasAutomaticDeletionReview); XCTAssertNil(model.pendingDeletionPhoto)
        XCTAssertNil(model.deletionMessage)
        XCTAssertEqual(model.deletionSuccessMessage, L10n.string("photos.selection.deleted", 1))
        XCTAssertEqual(model.items.map(\.id.unitID), [5]); XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        let deletes = await repository.deleteIDs, reviews = await repository.reviewIDs, reads = await repository.requests
        XCTAssertEqual(deletes, [4]); XCTAssertEqual(reviews.count, 10); XCTAssertEqual(reads.count, 2)
        await model.loadMore(); XCTAssertEqual(model.items.map(\.id.unitID), [5, 6])
    }

    func test删除后台核对离开或禁用后丢弃晚到结果重新进入继续() async throws {
        for disable in [false, true] {
            let repository = DatePhotoServiceStub()
            await repository.failReviews(true)
            let model = SynologyPhotosModel(repository: repository, pageSize: 2, deletionReviewDelay: { _ in await Task.yield() })
            defer { model.cancel() }
            await model.refresh(); let target = model.items[0]
            model.confirmDeletion(target); try await waitFor { !model.isDeleting }
            await repository.failReviews(false); await repository.holdConfirmedDeletionReview()
            let worker = Task { await model.continueAutomaticDeletionReview() }
            await repository.waitForHeldDeletionReview()
            XCTAssertFalse(model.isDeleting, "后台只读核对不应锁住图库浏览")
            if disable { model.setModuleEnabled(false) } else { model.leaveGallery() }
            await repository.releaseDeletionReview(); await worker.value
            XCTAssertEqual(model.pendingDeletionPhoto, target, "离开之后的晚到结果不能更新旧视图")
            if disable { XCTAssertTrue(model.items.isEmpty); XCTAssertFalse(model.hasAutomaticDeletionReview); model.setModuleEnabled(true) }
            await model.refresh(); await model.continueAutomaticDeletionReview()
            XCTAssertNil(model.pendingDeletionPhoto)
            let deletes = await repository.deleteIDs; XCTAssertEqual(deletes, [1])
        }
    }

    func test删除后台确认使旧偏移在途分页失效下一页不漏照片() async throws {
        let repository = DatePhotoServiceStub(); await repository.failReviews(true)
        let model = SynologyPhotosModel(repository: repository, pageSize: 2, deletionReviewDelay: { _ in await Task.yield() })
        defer { model.cancel() }
        await model.refresh(); await model.jumpToMonth(.init(year: 2014, month: 8))
        model.confirmDeletion(model.items[0]); try await waitFor { !model.isDeleting }
        await repository.failReviews(false); await repository.holdConfirmedDeletionReview()
        let review = Task { await model.continueAutomaticDeletionReview() }
        await repository.waitForHeldDeletionReview(); await repository.holdNextDatePage()
        let loading = Task { await model.loadMore() }
        await repository.waitForHeldDatePage()
        await repository.releaseDeletionReview(); await review.value
        XCTAssertFalse(model.isLoadingMore); XCTAssertEqual(model.items.map(\.id.unitID), [5])
        await repository.releaseDatePage(); await loading.value
        XCTAssertEqual(model.items.map(\.id.unitID), [5], "旧偏移响应必须丢弃")
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.id.unitID), [5, 6]); XCTAssertEqual(model.selectedTimelineMonthID, 201408)
        let requests = await repository.requests; XCTAssertEqual(requests.map(\.offset), [0, 0, 2, 1])
        let deletes = await repository.deleteIDs; XCTAssertEqual(deletes, [4])
    }

    func test删除后台核对取消与重复唤醒不重复读取在途目标() async throws {
        let repository = DatePhotoServiceStub(); await repository.failReviews(true)
        let model = SynologyPhotosModel(repository: repository, pageSize: 2, deletionReviewDelay: { _ in await Task.yield() })
        defer { model.cancel() }
        await model.refresh(); let target = model.items[0]
        model.confirmDeletion(target); try await waitFor { !model.isDeleting }
        await repository.failReviews(false); await repository.holdConfirmedDeletionReview()
        let first = Task { await model.continueAutomaticDeletionReview() }
        await repository.waitForHeldDeletionReview()
        let other = Task { await model.continueAutomaticDeletionReview() }
        for _ in 0..<20 { await Task.yield() }
        let reads = await repository.reviewIDs; XCTAssertEqual(reads.count, 7)
        first.cancel(); other.cancel(); await repository.releaseDeletionReview()
        await first.value; await other.value
        XCTAssertEqual(model.pendingDeletionPhoto, target)
        await model.continueAutomaticDeletionReview(); XCTAssertNil(model.pendingDeletionPhoto)
        let deletes = await repository.deleteIDs; XCTAssertEqual(deletes, [1])
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
        XCTAssertEqual(model.availableCategories, Set(SynologyPhotoCategory.allCases))
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
    private var sharedAlbumSort: SynologyPhotoAlbumListSort?
    var sharedAlbumSortRequests: [SynologyPhotoAlbumListSort?] = []
    func configureSharedAlbumSort(_ sort: SynologyPhotoAlbumListSort) { sharedAlbumSort = sort }
    func albumListSort(_ scope: SynologyPhotoAlbumListScope) async throws -> SynologyPhotoAlbumListSort {
        guard let sharedAlbumSort else { throw CapabilitySelectionError.unsupported(apiName: "Photos.AlbumListSort") }
        return sharedAlbumSort
    }
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int, sort: SynologyPhotoAlbumListSort?) async throws -> [SynologyPhotoSharedEntry] {
        sharedAlbumSortRequests.append(sort)
        return try await sharedEntries(scope, offset: offset, limit: limit)
    }
    private var sharedAlbumEntries: [SynologyPhotoSharedEntry] = []
    private var sharedAlbumListFails = false
    var sharedAlbumReads: [Int] = []
    func configureSharedAlbumEntries(_ entries: [SynologyPhotoSharedEntry], fail: Bool = false) {
        sharedAlbumEntries = entries; sharedAlbumListFails = fail
    }
    var previewRecoveryReads: [SynologyPhotoSpace] = []
    private var previewRecoveryPhotos: [SynologyPhotoSpace: [SynologyPhoto]] = [:]
    private var previewRecoveryFailure = false
    private var previewRecoveryDelay: Duration?
    func setPreviewRecovery(_ photos: [SynologyPhoto], in space: SynologyPhotoSpace, failure: Bool = false, delay: Duration? = nil) {
        previewRecoveryPhotos[space] = photos; previewRecoveryFailure = failure; previewRecoveryDelay = delay
    }
    func pendingPreviewRegenerations(in space: SynologyPhotoSpace) async throws -> [SynologyPhoto] {
        previewRecoveryReads.append(space)
        if let previewRecoveryDelay { try await Task.sleep(for: previewRecoveryDelay) }
        if previewRecoveryFailure { throw URLError(.notConnectedToInternet) }
        return previewRecoveryPhotos[space] ?? []
    }
    var previewDetailReads = 0
    private var previewDetailsEnabled = false
    func enablePreviewDetails() { previewDetailsEnabled = true }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto {
        guard previewDetailsEnabled else { throw CapabilitySelectionError.unsupported(apiName: "Photos.Item") }
        previewDetailReads += 1
        return photo
    }
    private let librarySpace: SynologyPhotoSpace
    private var requestAccess: SynologyPhotosAccess?
    func configureRequestAccess(spaces: [SynologyPhotoSpace], manager: Bool) {
        requestAccess = .init(spaces: spaces, packageVersion: "fixture", canManageSharedSpace: manager)
    }
    init(space: SynologyPhotoSpace = .personal) {
        librarySpace = space; collectionSettings.space = space
        people = people.map { .init(id: $0.id, name: $0.name, itemCount: $0.itemCount, space: space) }
    }
    private var collectionSettings = SynologyPhotoRequestSettings(subject: "Fixture collection", description: "Synthetic description", folderPath: "/Sample", folderID: 9)
    private var collectionDeleted = false
    private var collectionReadFails = false
    private var collectionAlbumsFail = false
    private var collectionFolderValid = true
    var requestListReads = 0
    private var requestTitles: [String]?
    func configureRequestTitles(_ titles: [String]) { requestTitles = titles }
    func configureRequests(fails: Bool = false, albumsFail: Bool = false, invalidFolder: Bool = false) {
        collectionReadFails = fails; collectionAlbumsFail = albumsFail; collectionFolderValid = !invalidFolder
    }
    func photoRequest(id: String) async throws -> SynologyPhotoRequest {
        if collectionReadFails || collectionDeleted { throw URLError(.cannotLoadFromNetwork) }
        return .init(id: id, profileID: profileID, settings: collectionSettings, isFolderValid: collectionFolderValid, url: URL(string: "https://example.invalid/request/fixture"))
    }
    func photoRequestAlbums() async throws -> [SynologyPhotoRequestAlbum] {
        if collectionAlbumsFail { throw URLError(.cannotLoadFromNetwork) }
        return [.init(albumID: 3, name: "Fixture private album", shared: false), .init(passphrase: "fixture-album", name: "Fixture shared album", shared: true)]
    }
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int) async throws -> [SynologyPhotoSharedEntry] {
        if scope != .requests {
            if scope == .withMe { return [] }
            sharedAlbumReads.append(offset)
            if sharedAlbumListFails { throw URLError(.notConnectedToInternet) }
            return Array(sharedAlbumEntries.dropFirst(offset).prefix(limit))
        }
        requestListReads += 1
        if collectionReadFails { throw URLError(.cannotLoadFromNetwork) }
        if let requestTitles {
            return requestTitles.enumerated().dropFirst(offset).prefix(limit).map { .init(id: "request-\($0.offset)", title: $0.element) }
        }
        return collectionDeleted || offset > 0 ? [] : [.init(id: "fixture-request", title: collectionSettings.subject, url: URL(string: "https://example.invalid/request/fixture"))]
    }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: 1, name: "Fixture root", path: "/") }
    func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort { folder.sort ?? .init() }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        parentID == 1 && offset == 0 ? [.init(id: 9, name: "Sample", parentID: 1, path: "/Sample")] : []
    }
    private var temporaryAlbumIDs: Set<Int> = []
    private var rejectsTemporaryCopy = false
    func configureTemporarySharing(access: SynologyPhotoLinkAccess = .invited, rejectCopy: Bool = false) {
        temporaryAlbumIDs.insert(9); sharingAccess = access; rejectsTemporaryCopy = rejectCopy
    }
    private var sharingAccess: SynologyPhotoLinkAccess = .download
    private var sharingReadFails = false
    private var sharingRole = "view"
    private var sharingRecipientsFail = false
    private var sharingMembersEmpty = false
    private var sharingExpiration: Int? = 2_000_000_000
    func configureSharing(_ access: SynologyPhotoLinkAccess, fails: Bool = false, role: String = "view", recipientsFail: Bool = false, empty: Bool = false, expiration: Int? = 2_000_000_000) {
        sharingAccess = access; sharingReadFails = fails; sharingRole = role; sharingRecipientsFail = recipientsFail; sharingMembersEmpty = empty; sharingExpiration = expiration
    }
    func albumSharing(id: Int) async throws -> SynologyPhotoSharingState {
        if sharingReadFails { throw URLError(.notConnectedToInternet) }
        return .init(access: sharingAccess, url: sharingAccess == .disabled ? nil : URL(string: "https://example.invalid/share/fixture"),
                     hasPassword: true, hasExpiration: sharingExpiration.map { $0 > 0 }, revision: "fixture-revision", members: sharingMembersEmpty ? [] : [.init(recipient: .init(id: .init(type: "user", value: .integer(22)), name: "Fixture member"), role: sharingRole)], expiration: sharingExpiration, isTemporary: temporaryAlbumIDs.contains(id))
    }
    func sharingRecipients() async throws -> [SynologyPhotoShareRecipient] {
        if sharingRecipientsFail { throw URLError(.notConnectedToInternet) }
        return [.init(id: .init(type: "user", value: .integer(22)), name: "Fixture member"),
         .init(id: .init(type: "group", value: .integer(22)), name: "Fixture group")]
    }
    private var people: [SynologyPhotoCollection] = [.init(id: 31, name: "Fixture person", itemCount: 2), .init(id: 32, name: "Another person", itemCount: 1)]
    private var hiddenPeople: Set<Int> = []
    private var hiddenConcepts: Set<Int> = []
    private var conceptStates: [Int: SynologyPhotoConceptVisibility] = [:]
    private var conceptCount = 5
    private var conceptsEmpty = false
    private var conceptsFail = false
    func configureConcepts(empty: Bool = false, fails: Bool = false, count: Int = 5) { conceptsEmpty = empty; conceptsFail = fails; conceptCount = count }
    func conceptVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoConceptVisibility] {
        guard space == librarySpace else { throw URLError(.noPermissionsToReadFile) }
        if conceptsFail { throw URLError(.notConnectedToInternet) }
        return conceptsEmpty ? [] : [41, 42].map { conceptStates[$0] ?? .init(concept: .init(id: $0, name: "Fixture topic \($0)", itemCount: conceptCount, space: space), isVisible: !hiddenConcepts.contains($0), displayThreshold: 2) }
    }
    func conceptState(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoConceptVisibility {
        guard let value = try await conceptVisibility(in: space).first(where: { $0.id == id }) else { throw URLError(.fileDoesNotExist) }
        return value
    }
    private var peopleReadFails = false
    private var faceListEmpty = false
    func photoFaces(for photo: SynologyPhoto) async throws -> [SynologyPhotoFaceRegion] {
        if peopleReadFails { throw URLError(.notConnectedToInternet) }
        if faceListEmpty { return [] }
        return [.init(id: 71, personID: 31, name: "Fixture person", bounds: .init(x: 0.15, y: 0.2, width: 0.25, height: 0.25))]
    }
    func configureFaces(empty: Bool) { faceListEmpty = empty }
    func personFaces(personID: Int, photos: [SynologyPhoto]) async throws -> [SynologyPhotoFace] {
        if peopleReadFails { throw URLError(.notConnectedToInternet) }
        if faceListEmpty { return [] }
        return photos.map { .init(id: $0.id.unitID + 70, personID: personID, photo: $0) }
    }
    func thumbnail(for face: SynologyPhotoFace) async throws -> Data { Data() }
    func filteredTimeline(in space: SynologyPhotoSpace, filter: SynologyPhotoFilter) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }

    func configurePeople(empty: Bool = false, fails: Bool = false) { if empty { people = [] }; peopleReadFails = fails }
    var peopleReadSpaces: [SynologyPhotoSpace] = []
    func peopleVisibility(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoPersonVisibility] {
        peopleReadSpaces.append(space)
        guard space == librarySpace else { throw URLError(.noPermissionsToReadFile) }
        return try await peopleVisibility()
    }
    func managementPeople(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoCollection] {
        peopleReadSpaces.append(space)
        guard space == librarySpace else { throw URLError(.noPermissionsToReadFile) }
        return try await managementPeople()
    }
    func categoryItems(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        guard space == librarySpace else { throw URLError(.noPermissionsToReadFile) }
        return try await categoryItems(category, offset: offset, limit: limit)
    }
    func categoryTimeline(_ category: SynologyPhotoCategory, id: Int, in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func peopleVisibility() async throws -> [SynologyPhotoPersonVisibility] {
        if peopleReadFails { throw URLError(.notConnectedToInternet) }
        return people.map { .init(person: $0, isVisible: !hiddenPeople.contains($0.id)) }
    }
    func managementPeople() async throws -> [SynologyPhotoCollection] {
        if peopleReadFails { throw URLError(.notConnectedToInternet) }
        return people
    }
    func categoryItems(_ category: SynologyPhotoCategory, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        if category == .concept { return try await conceptVisibility(in: librarySpace).filter(\.isVisible).map(\.concept) }
        return category == .person ? Array(people.filter { !hiddenPeople.contains($0.id) }.dropFirst(offset).prefix(limit)) : []
    }
    private var features: Set<SynologyPhotosManagementFeature> = []
    private var pendingManagement = false
    private var sharingOnlyPersonal = false
    func limitSharingToPersonal() { sharingOnlyPersonal = true }
    var managementWriteCount = 0
    private var managementCommand: SynologyPhotosMutation?
    var managementCommands: [SynologyPhotosMutation] = []
    private var partialManagement = false
    private var failsManagementPreparation = false
    private var managementPreparationError: AppError?
    func failNextManagementPreparation(error: AppError? = nil) { failsManagementPreparation = true; managementPreparationError = error }
    func enableManagement(pending: Bool = false, partial: Bool = false) { features = Set(SynologyPhotosManagementFeature.allCases); pendingManagement = pending; partialManagement = partial }
    func managementFeatures() async -> Set<SynologyPhotosManagementFeature> { sharingOnlyPersonal && librarySpace == .shared ? features.subtracting([.sharing]) : features }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> {
        guard requestAccess?.spaces.contains(space) ?? (space == librarySpace) else { return [] }
        return sharingOnlyPersonal && space == .shared ? features.subtracting([.sharing]) : features
    }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws {
        if failsManagementPreparation {
            failsManagementPreparation = false
            if let error = managementPreparationError { managementPreparationError = nil; throw error }
            throw URLError(.notConnectedToInternet)
        }
    }
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        managementWriteCount += 1; managementCommand = mutation; managementCommands.append(mutation)
        return .init(state: .pendingReview)
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        guard !pendingManagement, let command = managementCommand else { return .init(state: .pendingReview) }
        switch command {
        case .move(let photos, _, _, _, _), .copy(let photos, _, _, _, _):
            return .init(state: partialManagement ? .partial : .confirmed, completedCount: partialManagement ? 0 : photos.count)
        case .regeneratePreviews(let photos, _):
            if partialManagement { partialManagement = false; return .init(state: .partial, photos: Array(photos.prefix(1)), completedCount: 1) }
            return .init(state: .confirmed, photos: photos, completedCount: photos.count)
        case .editPhotoFaces(let photo, let changes):
            return .init(state: .confirmed, photos: [photo], completedCount: changes.count)
        case .setConceptCover(let original, let photo):
            let collection = SynologyPhotoCollection(id: original.id, name: original.concept.name, itemCount: original.concept.itemCount,
                thumbnail: .init(unitID: photo.id.unitID, revision: "new-cover"), space: original.concept.space)
            let state = SynologyPhotoConceptVisibility(concept: collection, isVisible: original.isVisible, displayThreshold: original.displayThreshold)
            conceptStates[original.id] = state
            return .init(state: .confirmed, conceptVisibility: [state])
        case .removeConceptItems(let original, let photos):
            let removed = partialManagement ? Array(photos.prefix(1)) : photos
            let collection = SynologyPhotoCollection(id: original.id, name: original.concept.name,
                itemCount: (original.concept.itemCount ?? 0) - removed.count, thumbnail: nil, space: original.concept.space)
            let state = SynologyPhotoConceptVisibility(concept: collection, isVisible: original.isVisible, displayThreshold: original.displayThreshold)
            conceptStates[original.id] = state
            return .init(state: partialManagement ? .partial : .confirmed, conceptVisibility: [state], removedFromConceptPhotoIDs: removed.map(\.id))
        case .setConceptVisibility(let originals, let visible):
            let completed = partialManagement ? Array(originals.prefix(1)) : originals
            for original in completed {
                if visible { hiddenConcepts.remove(original.id) } else { hiddenConcepts.insert(original.id) }
            }
            return .init(state: partialManagement ? .partial : .confirmed, conceptVisibility: completed.map { .init(concept: $0.concept, isVisible: visible) })
        case .setPeopleVisibility(let originals, let visible):
            let completed = partialManagement ? Array(originals.prefix(1)) : originals
            for original in completed {
                if visible { hiddenPeople.remove(original.id) } else { hiddenPeople.insert(original.id) }
            }
            return .init(state: partialManagement ? .partial : .confirmed, personVisibility: completed.map { .init(person: $0.person, isVisible: visible) })
        case .createTemporaryAlbum(let name, _):
            temporaryAlbumIDs.insert(9); sharingAccess = .invited
            return .init(state: .confirmed, album: .init(id: 9, name: name))
        case .copyTemporaryAlbum(_, let name, _):
            return rejectsTemporaryCopy ? .init(state: .rejected) : .init(state: .confirmed, album: .init(id: 10, name: name))
        case .deleteTemporaryAlbum(let id, _, _):
            temporaryAlbumIDs.remove(id)
            return .init(state: .confirmed)
        case .createAlbum(let name, _):
            return .init(state: .confirmed, album: .init(id: 9, name: name))
        case .shareAlbum(_, let access, _, _, _, _):
            sharingAccess = access
            return .init(state: .confirmed, sharingURL: access == .disabled ? nil : URL(string: "https://example.invalid/share/fixture"))
        case .createPhotoRequest(let settings), .updatePhotoRequest(_, let settings):
            collectionSettings = settings; collectionDeleted = false
            let request = try await photoRequest(id: "fixture-request")
            return .init(state: .confirmed, sharingURL: request.url, photoRequest: request)
        case .deletePhotoRequest:
            collectionDeleted = true
            return .init(state: .confirmed)
        default: break
        }
        if case .removePersonFaces(let person, let faces) = command {
            return .init(state: .confirmed, person: .init(id: person.id, name: person.name, itemCount: max(0, (person.itemCount ?? 0) - 1), space: person.space), removedFromPersonPhotoIDs: faces.map { $0.photo.id })
        }
        if case .renamePerson(let original, let name) = command {
            let person = SynologyPhotoCollection(id: original.id, name: name, itemCount: original.itemCount, space: original.space)
            if let index = people.firstIndex(where: { $0.id == person.id }) { people[index] = person }
            return .init(state: .confirmed, person: person)
        }
        if case .mergePeople(let target, let sources, let name) = command {
            let person = SynologyPhotoCollection(id: target.id, name: name, itemCount: 2, space: target.space)
            people.removeAll { entry in sources.contains { $0.id == entry.id } }
            if let index = people.firstIndex(where: { $0.id == person.id }) { people[index] = person }
            return .init(state: .confirmed, person: person, removedPersonIDs: sources.map(\.id))
        }
        var photos = command.photos
        if case .edit(_, .rating(let value)) = command {
            for index in photos.indices { photos[index].rating = value }
            if partialManagement { partialManagement = false; return .init(state: .partial, photos: Array(photos.prefix(1)), completedCount: 1) }
        }
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
        if case .createTag(let name, _, _) = command {
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
    private var holdsDatePage = false
    private var heldDatePage: CheckedContinuation<Void, Never>?
    private var datePageReady: CheckedContinuation<Void, Never>?
    func holdNextDatePage() { holdsDatePage = true }
    func waitForHeldDatePage() async {
        if heldDatePage != nil { return }
        await withCheckedContinuation { datePageReady = $0 }
    }
    func releaseDatePage() { heldDatePage?.resume(); heldDatePage = nil }
    private var remainingReviewFailures = 0
    private var holdDeletionReview = false
    private var heldDeletionReview: CheckedContinuation<Void, Never>?
    private var deletionReviewReady: CheckedContinuation<Void, Never>?
    func failDeletionReviewCount(_ count: Int) { remainingReviewFailures = count }
    func holdConfirmedDeletionReview() { holdDeletionReview = true }
    func waitForHeldDeletionReview() async {
        if heldDeletionReview != nil { return }
        await withCheckedContinuation { deletionReviewReady = $0 }
    }
    func releaseDeletionReview() { heldDeletionReview?.resume(); heldDeletionReview = nil }
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
        if remainingReviewFailures > 0 { remainingReviewFailures -= 1; throw URLError(.notConnectedToInternet) }
        if holdDeletionReview {
            holdDeletionReview = false; reviews[id] = 1
            await withCheckedContinuation { heldDeletionReview = $0; deletionReviewReady?.resume(); deletionReviewReady = nil }
        }
        reviews[id, default: 0] += 1
        if reviews[id, default: 0] < 2 { return .pendingReview }
        deleted.insert(id)
        return .confirmed
    }
    private var failsNext = false
    private let profileID = UUID()
    func failNextPage() { failsNext = true }
    func access() async throws -> SynologyPhotosAccess {
        requestAccess ?? .init(spaces: [librarySpace], packageVersion: "1.8.2-10090")
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
        case .filtered(_, let lower, let upper), .category(_, _, let lower, let upper): (start, end, keyword) = (lower, upper, nil)
        default: throw URLError(.badURL)
        }
        requests.append(.init(start: start, end: end, offset: offset, keyword: keyword))
        let calendar = Calendar(identifier: .gregorian)
        let all = (1...6).map { index in
            let date = calendar.date(from: DateComponents(year: index <= 3 ? 2026 : 2014, month: index <= 3 ? 9 : 8, day: 1, hour: 12))!
            return SynologyPhoto(id: .init(profileID: profileID, space: space, unitID: index),
                                 filename: "sample-\(index).jpg", sizeBytes: 128,
                                 takenAt: date, indexedAt: date, folderID: 9, mediaType: "photo")
        }
        let matches = all.filter { !deleted.contains($0.id.unitID) && (start...end).contains(Int($0.takenAt.timeIntervalSince1970)) }
        let page = Array(matches.dropFirst(offset).prefix(limit))
        if holdsDatePage {
            holdsDatePage = false
            await withCheckedContinuation { heldDatePage = $0; datePageReady?.resume(); datePageReady = nil }
        }
        return .init(items: page, offset: offset, nextOffset: offset + page.count, hasMore: page.count == limit)
    }
    private var previewFixture = Data()
    func setPreviewFixture(_ data: Data) { previewFixture = data }
    func previewImage(for photo: SynologyPhoto) async throws -> Data { previewFixture }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }
}

private actor PhotoServiceStub: SynologyPhotosServing {
    private let spaces: [SynologyPhotoSpace]
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
        saveData: Data? = nil, spaces: [SynologyPhotoSpace] = [.personal]
    ) {
        self.pages = pages
        self.holdsFirstPage = holdsFirstPage
        self.days = days
        self.failsFirstAccess = failsFirstAccess
        self.saveData = saveData
        self.spaces = spaces
    }

    func access() async throws -> SynologyPhotosAccess {
        if failsFirstAccess {
            failsFirstAccess = false
            throw URLError(.notConnectedToInternet)
        }
        return SynologyPhotosAccess(spaces: spaces, packageVersion: "1.8.2-10090")
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

    private var savingError: AppError?
    func failSaving(_ error: AppError) { savingError = error }
    func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        savedURLs.append(destination)
        if let savingError { throw savingError }
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
    private var previewFixture: Data?
    func setPreviewFixture(_ data: Data) { previewFixture = data }
    func previewImage(for photo: SynologyPhoto) async throws -> Data {
        guard let previewFixture else { throw CapabilitySelectionError.unsupported(apiName: "Photos.Thumbnail") }
        return previewFixture
    }
    func downloadOriginal(_ photo: SynologyPhoto, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        guard let previewFixture else { throw CapabilitySelectionError.unsupported(apiName: "Photos.Download") }
        try previewFixture.write(to: destination)
        progress(Int64(previewFixture.count), Int64(previewFixture.count))
    }
    private var automaticFailureRecorded = false
    func recordNextAutomaticFailure() { automaticFailureRecorded = true }
    private var automaticEnabled: Bool?
    private var automaticTasks: [SynologyPhotoAutomaticPreviewTask] = []
    private var visibleAutomaticTasks: [SynologyPhotoID: [SynologyPhotoAutomaticPreviewTask]] = [:]
    var visibleAutomaticReads: [SynologyPhotoID] = []
    func configureVisibleAutomatic(_ photo: SynologyPhoto, tasks: [SynologyPhotoAutomaticPreviewTask]) { visibleAutomaticTasks[photo.id] = tasks }
    func automaticPreviewTasks(for photo: SynologyPhoto, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask] {
        visibleAutomaticReads.append(photo.id); return visibleAutomaticTasks[photo.id] ?? []
    }

    var automaticScans: [SynologyPhotoSpace] = []
    var automaticReviews = 0
    func configureAutomatic(enabled: Bool, tasks: [SynologyPhotoAutomaticPreviewTask]) { automaticEnabled = enabled; automaticTasks = tasks }
    private var automaticReadFails = false
    private var automaticReadHeld = false
    func configureAutomaticRead(fails: Bool, held: Bool = false) { automaticReadFails = fails; automaticReadHeld = held }
    func automaticPreviewEnabled() async throws -> Bool {
        if automaticReadFails { throw URLError(.networkConnectionLost) }
        if automaticReadHeld {
            automaticReadHeld = false
            await withCheckedContinuation { heldPage = $0; pageReady?.resume(); pageReady = nil }
        }
        return automaticEnabled ?? false
    }
    func automaticPreviewTasks(in space: SynologyPhotoSpace, support: SynologyPhotoPreviewConversionSupport) async throws -> [SynologyPhotoAutomaticPreviewTask] {
        automaticScans.append(space); return automaticTasks.filter { $0.space == space }
    }

    private var listPreferencesEnabled = false
    private var holdsListPreferences = false
    func holdNextListPreferences() { holdsListPreferences = true }
    private var listReadFails = false
    private var listOrders: [SynologyPhotoAlbumListScope: SynologyPhotoAlbumListSort] = [:]
    private var listDisplay: SynologyPhotoAlbumDisplay = .all
    private var listFixtures: [SynologyPhotoCollection] = []
    var listCalls: [(SynologyPhotoAlbumListScope, SynologyPhotoAlbumDisplay?, SynologyPhotoAlbumListSort?, Int)] = []
    func configureLists(_ fixtures: [SynologyPhotoCollection], fails: Bool = false) { listPreferencesEnabled = true; listFixtures = fixtures; listReadFails = fails }
    func albumListSort(_ scope: SynologyPhotoAlbumListScope) async throws -> SynologyPhotoAlbumListSort {
        if !listPreferencesEnabled || listReadFails { throw URLError(.networkConnectionLost) }
        let sort = listOrders[scope] ?? .init(field: .name, direction: .ascending)
        if holdsListPreferences {
            holdsListPreferences = false
            await withCheckedContinuation { heldPage = $0; pageReady?.resume(); pageReady = nil }
        }
        return sort
    }
    func albumListDisplay() async throws -> SynologyPhotoAlbumDisplay {
        if !listPreferencesEnabled || listReadFails { throw URLError(.networkConnectionLost) }
        return listDisplay
    }
    func albums(offset: Int, limit: Int, display: SynologyPhotoAlbumDisplay?, sort: SynologyPhotoAlbumListSort?) async throws -> [SynologyPhotoCollection] {
        listCalls.append((.albums, display, sort, offset))
        return Array(listFixtures.dropFirst(offset).prefix(limit))
    }
    func sharedEntries(_ scope: SynologyPhotoShareScope, offset: Int, limit: Int, sort: SynologyPhotoAlbumListSort?) async throws -> [SynologyPhotoSharedEntry] {
        if scope == .requests { return [] }
        listCalls.append((scope == .withMe ? .withMe : .byMe, nil, sort, offset))
        return Array(listFixtures.dropFirst(offset).prefix(limit)).map { .init(id: String($0.id), title: $0.name, albumID: $0.id) }
    }

    private var albumOrder = SynologyPhotoSort(direction: .descending)
    private var explicitAlbumSorting = false
    private var albumSortFails = false
    func configureAlbumSort(_ sort: SynologyPhotoSort, fails: Bool = false) { albumOrder = sort; explicitAlbumSorting = true; albumSortFails = fails }
    func albumSort(id: Int) async throws -> SynologyPhotoSort {
        if albumSortFails { throw URLError(.networkConnectionLost) }
        return albumOrder
    }

    private var codecDefaults: SynologyPhotoCodecPrompt?
    private var codecReadFails = false
    private var codecReadHeld = false
    private var codecPartial = false
    func configureCodec(_ prompt: SynologyPhotoCodecPrompt, fails: Bool = false, held: Bool = false, partial: Bool = false) {
        codecDefaults = prompt; codecReadFails = fails; codecReadHeld = held; codecPartial = partial
    }
    func codecPrompt() async throws -> SynologyPhotoCodecPrompt {
        if codecReadHeld { codecReadHeld = false; await withCheckedContinuation { heldPage = $0 } }
        guard !codecReadFails, let codecDefaults else { throw URLError(.notConnectedToInternet) }
        return codecDefaults
    }

    private var maintenanceDefaults: SynologyPhotoLibraryMaintenanceStatus?
    private var maintenanceReadFails = false
    private var maintenanceReadHeld = false
    func configureMaintenance(_ status: SynologyPhotoLibraryMaintenanceStatus, fails: Bool = false, held: Bool = false) {
        maintenanceDefaults = status; maintenanceReadFails = fails; maintenanceReadHeld = held
    }
    func libraryMaintenanceStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoLibraryMaintenanceStatus {
        if maintenanceReadHeld { maintenanceReadHeld = false; await withCheckedContinuation { heldPage = $0 } }
        guard !maintenanceReadFails, let maintenanceDefaults, maintenanceDefaults.space == space else { throw URLError(.notConnectedToInternet) }
        return maintenanceDefaults
    }

    private var globalDefaults: SynologyPhotoGlobalSettings?
    private var globalReadFails = false
    private var globalReadHeld = false
    private var globalPartial = false
    private var cacheDefaults: SynologyPhotoConversionCache?
    private var cacheReadFails = false
    func configureGlobal(_ settings: SynologyPhotoGlobalSettings, fails: Bool = false, held: Bool = false, partial: Bool = false) {
        globalDefaults = settings; globalReadFails = fails; globalReadHeld = held; globalPartial = partial
        spaces = settings.personalSpaceEnabled ? [.personal] : []
        if settings.sharedSpaceEnabled, settings.sharedRole != .none { spaces.append(.shared) }
        conditionSpace = settings.sharedSpaceEnabled && settings.sharedRole == .management ? .shared : .personal
    }
    func configureCache(_ cache: SynologyPhotoConversionCache?, fails: Bool = false) { cacheDefaults = cache; cacheReadFails = fails }
    func globalSettings() async throws -> SynologyPhotoGlobalSettings {
        if globalReadHeld { globalReadHeld = false; await withCheckedContinuation { heldPage = $0 } }
        guard !globalReadFails, let globalDefaults else { throw URLError(.notConnectedToInternet) }
        return globalDefaults
    }
    func conversionCache() async throws -> SynologyPhotoConversionCache {
        guard !cacheReadFails, let cacheDefaults else { throw URLError(.notConnectedToInternet) }
        return cacheDefaults
    }

    private var memberDefaults: SynologyPhotoSharedMembers?
    private var memberCandidates: [SynologyPhotoShareRecipient] = []
    private var memberFolders: [SynologyPhotoMemberFolder] = []
    private var memberReadFails = false
    private var memberCandidatesFail = false
    private var memberFoldersFail = false
    private var memberFoldersHeld = false
    private var memberReadHeld = false
    private var memberPartial = false
    private var memberResultSettings: SynologyPhotoSharedSpaceSettings?
    func configureMembers(_ original: SynologyPhotoSharedMembers, candidates: [SynologyPhotoShareRecipient] = [],
                          folders: [SynologyPhotoMemberFolder] = [], fails: Bool = false, candidatesFail: Bool = false,
                          foldersFail: Bool = false, foldersHeld: Bool = false, held: Bool = false, partial: Bool = false,
                          resultSettings: SynologyPhotoSharedSpaceSettings? = nil) {
        memberDefaults = original; memberCandidates = candidates; memberFolders = folders
        memberReadFails = fails; memberCandidatesFail = candidatesFail; memberFoldersFail = foldersFail
        memberReadHeld = held; memberFoldersHeld = foldersHeld; memberPartial = partial; memberResultSettings = resultSettings
    }
    func sharedSpaceMembers() async throws -> SynologyPhotoSharedMembers {
        if memberReadHeld { memberReadHeld = false; await withCheckedContinuation { heldPage = $0 } }
        guard !memberReadFails, let memberDefaults else { throw URLError(.notConnectedToInternet) }
        return memberDefaults
    }
    func sharedSpaceMemberCandidates() async throws -> [SynologyPhotoShareRecipient] {
        if memberCandidatesFail { throw URLError(.notConnectedToInternet) }
        return memberCandidates
    }
    func sharedSpaceMemberFolderSnapshot(for member: SynologyPhotoShareRecipient.ID) async throws -> [SynologyPhotoMemberFolder] {
        if memberFoldersHeld { memberFoldersHeld = false; await withCheckedContinuation { heldPage = $0 } }
        if memberFoldersFail { throw URLError(.notConnectedToInternet) }
        return memberFolders.filter { $0.memberID == member }
    }

    private var sharedDefaults: SynologyPhotoSharedSpaceSettings?
    private var sharedReadFails = false
    private var sharedReadHeld = false
    func configureSharedSettings(_ settings: SynologyPhotoSharedSpaceSettings, fails: Bool = false, held: Bool = false) {
        sharedDefaults = settings; sharedReadFails = fails; sharedReadHeld = held
        spaces = settings.personalSpaceEnabled ? [.personal] : []
        if settings.canAccess { spaces.append(.shared) }
        conditionSpace = settings.canAccess && settings.role == .management ? .shared : .personal
    }
    func sharedSpaceSettings() async throws -> SynologyPhotoSharedSpaceSettings {
        if sharedReadHeld { sharedReadHeld = false; await withCheckedContinuation { heldPage = $0 } }
        guard !sharedReadFails, let sharedDefaults else { throw URLError(.notConnectedToInternet) }
        return sharedDefaults
    }

    private var recognitionDefaults: SynologyPhotoRecognitionSettings?
    private var recognitionReadFails = false
    func configureRecognition(_ settings: SynologyPhotoRecognitionSettings, fails: Bool = false) { recognitionDefaults = settings; recognitionReadFails = fails }
    func recognitionSettings() async throws -> SynologyPhotoRecognitionSettings {
        guard !recognitionReadFails, let recognitionDefaults else { throw URLError(.notConnectedToInternet) }
        return recognitionDefaults
    }
    func categories(in space: SynologyPhotoSpace) async throws -> Set<SynologyPhotoCategory> {
        if let globalDefaults {
            let state = globalDefaults.recognition(in: space)
            return Set(state.enabled.intersection(state.globallyEnabled).map(\.category)).union([.videos])
        }
        if space == .shared, let state = sharedDefaults { return Set(state.enabled.intersection(state.globallyEnabled).compactMap(\.category)).union([.videos]) }
        guard let state = recognitionDefaults else { return [] }
        if space == .shared { return [.person, .concept, .similar, .videos] }
        return Set(state.enabled.intersection(state.globallyEnabled).map(\.category)).union([.videos])
    }
    func categoryItems(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        offset == 0 ? [.init(id: 88, name: "Fixture category", space: space)] : []
    }

    private var displayDefaults: SynologyPhotoDisplaySettings?
    private var displayReadFails = false
    private var displayPhotos: [SynologyPhoto]?
    func configureDisplay(_ settings: SynologyPhotoDisplaySettings?, photos: [SynologyPhoto]? = nil, fails: Bool = false) {
        displayDefaults = settings; displayPhotos = photos; displayReadFails = fails
    }
    func displaySettings() async throws -> SynologyPhotoDisplaySettings {
        guard !displayReadFails, let displayDefaults else { throw URLError(.notConnectedToInternet) }
        return displayDefaults
    }

    private var duplicateDefaults = SynologyPhotoDuplicateSettings(upload: .rename, transfer: .skip)
    private var duplicateReadFails = false
    private var ignoreUploadedDuplicate = false
    func setDuplicateDefaults(_ settings: SynologyPhotoDuplicateSettings) { duplicateDefaults = settings }
    func failDuplicateRead(_ fails: Bool) { duplicateReadFails = fails }
    func ignoreUploadDuplicate() { ignoreUploadedDuplicate = true }
    func duplicateSettings() async throws -> SynologyPhotoDuplicateSettings {
        if duplicateReadFails { throw URLError(.notConnectedToInternet) }
        return duplicateDefaults
    }

    private var folderPhotos: [SynologyPhoto] = []
    func setFolderPhotos(_ photos: [SynologyPhoto]) { folderPhotos = photos }
    var archiveCalls: [(SynologyPhotoArchiveTarget, SynologyPhotoDownloadFormat)] = []
    private var archiveFails = false
    private var archiveWaits = false
    func configureArchive(fails: Bool, waits: Bool) { archiveFails = fails; archiveWaits = waits }
    func downloadArchive(_ target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws {
        archiveCalls.append((target, format))
        if archiveWaits {
            do { try await Task.sleep(for: .seconds(30)) }
            catch { throw URLError(.cancelled) } // 模拟URLSession取消返回，不能显示下载失败。
        }
        if archiveFails { throw URLError(.notConnectedToInternet) }
        try Data([0x50, 0x4b, 5, 6] + Array(repeating: 0, count: 18)).write(to: destination)
    }
    private var spaces: [SynologyPhotoSpace] = [.personal]
    var spaceQueries: [(SynologyPhotoSpace, SynologyPhotoQuery)] = []
    func setSpaces(_ spaces: [SynologyPhotoSpace]) { self.spaces = spaces }
    private var conditionReadFails = false
    private var conditionSpace: SynologyPhotoSpace = .personal
    var conditionSuggestionSpaces: [SynologyPhotoSpace] = []
    var conditionFolderSpaces: [SynologyPhotoSpace] = []
    private var albumPhotos: [SynologyPhoto]?
    private var movedAlbumPhotos: [SynologyPhoto]?
    private var moveRefreshFailures = 0
    private var albumReadFailures = 0
    var albumPageOffsets: [Int] = []
    func setAlbumPhotos(_ photos: [SynologyPhoto]) { albumPhotos = photos }
    func setMovedAlbumPhotos(_ photos: [SynologyPhoto], failures: Int = 0) { movedAlbumPhotos = photos; moveRefreshFailures = failures }
    private var albumPhoto: SynologyPhoto?
    private var addableAlbumFixtures: [SynologyPhotoCollection] = []
    var addableAlbumReads = 0
    func setAddableAlbums(_ albums: [SynologyPhotoCollection]) { addableAlbumFixtures = albums }
    func addableAlbums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        addableAlbumReads += 1
        return Array(addableAlbumFixtures.dropFirst(offset).prefix(limit))
    }
    private var albumRights: SynologyPhotoAlbumAccess?
    func setAlbumAccess(_ rights: SynologyPhotoAlbumAccess?) { albumRights = rights }
    func albumAccess(id: Int) async throws -> SynologyPhotoAlbumAccess {
        guard let albumRights, albumRights.albumID == id else { throw URLError(.noPermissionsToReadFile) }
        return albumRights
    }
    func setAlbumPhoto(_ photo: SynologyPhoto) { albumPhoto = photo }
    func setConditionSpace(_ space: SynologyPhotoSpace) { conditionSpace = space }
    func conditionSuggestions(keyword: String, in space: SynologyPhotoSpace) async throws -> [String: [SynologyPhotoConditionOption]] {
        conditionSuggestionSpaces.append(space)
        return try await conditionSuggestions(keyword: keyword)
    }
    func failConditionRead() { conditionReadFails = true }
    func albumCondition(id: Int) async throws -> SynologyPhotoAlbumCondition {
        if conditionReadFails { throw URLError(.notConnectedToInternet) }
        return .init(fields: ["user_id": .integer(conditionSpace == .shared ? 0 : 12), "item_type": .array([.integer(-1)]), "keyword": .array([.string("Fixture trip")]), "keyword_policy": .string("and"),
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
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto {
        guard let folder = navigationPhotoFolder else { return photo }
        return .init(id: photo.id, filename: photo.filename, sizeBytes: photo.sizeBytes, takenAt: photo.takenAt,
                     indexedAt: photo.indexedAt, folderID: folder, mediaType: photo.mediaType, albumContext: photo.albumContext)
    }
    var navigationFolderReads: [Int] = []
    private var navigationPhotoFolder: Int?
    private var holdsNavigationFolder = false
    private var navigationHeld: CheckedContinuation<Void, Never>?
    private var navigationReady: CheckedContinuation<Void, Never>?
    func setNavigationPhotoFolder(_ id: Int) { navigationPhotoFolder = id }
    func replaceNavigationFolders(_ folders: [SynologyPhotoCollection]) { directoryFixtures = folders }
    func holdNavigationFolder() { holdsNavigationFolder = true }
    func waitUntilNavigationHeld() async {
        if navigationHeld != nil { return }
        await withCheckedContinuation { navigationReady = $0 }
    }
    func releaseNavigationFolder() { navigationHeld?.resume(); navigationHeld = nil }
    func folder(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection {
        navigationFolderReads.append(id)
        if holdsNavigationFolder {
            holdsNavigationFolder = false
            await withCheckedContinuation { navigationHeld = $0; navigationReady?.resume(); navigationReady = nil }
        }
        guard let folder = directoryFixtures.first(where: { $0.id == id && $0.space == space }) else { throw URLError(.noPermissionsToReadFile) }
        return folder
    }

    func addFolder(_ folder: SynologyPhotoCollection) { directoryFixtures.append(folder) }
    var pageReads = 0
    var accessReads = 0
    private var holdsPage = false
    private var heldPageResult: SynologyPhotoPage?
    func holdNextPage(result: SynologyPhotoPage) { holdsPage = true; heldPageResult = result }
    private var heldPage: CheckedContinuation<Void, Never>?
    private var pageReady: CheckedContinuation<Void, Never>?
    func holdNextPage() { holdsPage = true }
    func waitUntilPageHeld() async {
        if heldPage != nil { return }
        await withCheckedContinuation { pageReady = $0 }
    }
    func releasePage() { heldPage?.resume(); heldPage = nil }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { conditionFolderSpaces.append(space); return .init(id: space == .shared ? 101 : 1, name: "Fixture root", path: "/", space: space) }
    func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort { .init() }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { Array(directoryFixtures.filter { $0.parentID == parentID }.dropFirst(offset).prefix(limit)) }
    private var rejectAlbum = false
    private var rejectPrepare = false
    private var pending = false
    private var nextReviewFails = false
    func failNextReview() { nextReviewFails = true }
    private var shouldHold = false
    private var held: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    private var results: [UUID: SynologyPhotosMutationResult] = [:]
    let profile: UUID
    private var recoveryUserID = 12
    var restoredUploadIDs: [UUID] = []
    init(profile: UUID = UUID()) { self.profile = profile }
    func setRecoveryUser(_ id: Int) { recoveryUserID = id }
    func uploadRecoveryIdentity() async throws -> String { "\(profile.uuidString):\(recoveryUserID)" }
    func performRecoverableUpload(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress,
                                 checkpoint: @escaping @Sendable (SynologyPhotosUploadCheckpoint) throws -> Void) async throws -> SynologyPhotosMutationResult {
        var saved = try SynologyPhotosUploadCheckpoint(mutation: mutation, operationID: operationID, profileID: profile, userID: recoveryUserID)
        try checkpoint(saved)
        let result = try await performMutation(mutation, operationID: operationID, progress: progress)
        saved.itemID = results[operationID]?.photos.first?.id.unitID
        saved.folderID = results[operationID]?.folder?.id
        saved.uploadAction = ignoreUploadedDuplicate ? "ignore" : "rename"
        saved.rejected = results[operationID]?.state == .rejected
        try checkpoint(saved)
        return result
    }
    func restoreUploadMutation(_ saved: SynologyPhotosUploadCheckpoint) async throws {
        guard saved.profileID == profile, saved.userID == recoveryUserID else { throw CocoaError(.fileReadNoPermission) }
        restoredUploadIDs.append(saved.operationID)
        let mutation = try saved.reviewMutation()
        if saved.rejected { results[saved.operationID] = .init(state: .rejected); return }
        switch mutation {
        case .upload(let source, let size, let modified, let folder, let space, _):
            if let id = saved.itemID {
                results[saved.operationID] = .init(state: .confirmed, photos: [.init(id: .init(profileID: profile, space: space, unitID: id),
                    filename: source.lastPathComponent, sizeBytes: size, takenAt: modified, indexedAt: modified, folderID: folder ?? 9, mediaType: "photo")])
            }
        case .uploadToAlbum(let source, let size, let modified, let album, _):
            if let id = saved.itemID {
                results[saved.operationID] = .init(state: .confirmed, photos: [.init(id: .init(profileID: profile, space: .personal, unitID: id),
                    filename: source.lastPathComponent, sizeBytes: size, takenAt: modified, indexedAt: modified, folderID: 9, mediaType: "photo",
                    albumContext: .init(albumID: album, ownerUserID: 99, providerUserID: recoveryUserID))])
            }
        case .createFolder(let parent, let name, let space):
            if let id = saved.folderID { results[saved.operationID] = .init(state: .confirmed, folder: .init(id: id, name: name, parentID: parent, space: space)) }
        case .addToAlbum: results[saved.operationID] = .init(state: .confirmed, completedCount: 1)
        default: throw CocoaError(.coderInvalidValue)
        }
    }
    func forgetUploadMutation(operationID: UUID) async throws { results.removeValue(forKey: operationID) }

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
    func access() async throws -> SynologyPhotosAccess { accessReads += 1; return .init(spaces: spaces, packageVersion: "fixture", canManageSharedSpace: conditionSpace == .shared, displaySettings: displayDefaults, automaticPreviewEnabled: automaticEnabled) }
    func managementFeatures() async -> Set<SynologyPhotosManagementFeature> { Set(SynologyPhotosManagementFeature.allCases) }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> {
        guard spaces.contains(space) else { return Set<SynologyPhotosManagementFeature>(explicitAlbumSorting ? [.albumSorting] : []).union(listPreferencesEnabled ? [.albumListSorting, .albumListDisplay] : []) }
        return space == .personal ? Set(SynologyPhotosManagementFeature.allCases) : Set<SynologyPhotosManagementFeature>([.upload, .folders, .albums, .conditionAlbums, .automaticPreview, .automaticPreviewSettings]).union(sharedDefaults == nil ? [] : [.sharedSpaceSettings]).union(memberDefaults == nil ? [] : [.sharedMembers]).union(globalDefaults == nil ? [] : [.globalSettings, .conversionCache])
    }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        if let displayPhotos {
            let calendar = Calendar(identifier: .gregorian)
            return displayPhotos.map { photo in
                let c = calendar.dateComponents([.year, .month, .day], from: photo.takenAt)
                return .init(year: c.year!, month: c.month!, day: c.day!, itemCount: 1)
            }
        }
        return [.init(year: 2020, month: 3, day: 1, itemCount: 1)]
    }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        pageReads += 1
        spaceQueries.append((space, query))
        if holdsPage {
            holdsPage = false
            let saved = heldPageResult; heldPageResult = nil
            await withCheckedContinuation { heldPage = $0; pageReady?.resume(); pageReady = nil }
            if let saved { return saved }
        }
        if case .timeline(let start, let end) = query, let displayPhotos {
            let all = displayPhotos.filter { Int($0.takenAt.timeIntervalSince1970) >= start && Int($0.takenAt.timeIntervalSince1970) <= end }
            let page = Array(all.dropFirst(offset).prefix(limit))
            return .init(items: page, offset: offset, nextOffset: offset + page.count, hasMore: offset + page.count < all.count)
        }
        if case .album = query, let albumPhotos {
            albumPageOffsets.append(offset)
            if albumReadFailures > 0 { albumReadFailures -= 1; throw URLError(.networkConnectionLost) }
            let page = Array(albumPhotos.dropFirst(offset).prefix(limit))
            return .init(items: page, offset: offset, nextOffset: offset + page.count, hasMore: offset + page.count < albumPhotos.count)
        }
        if case .album = query, let albumPhoto, offset == 0 { return .init(items: [albumPhoto], offset: 0, nextOffset: 1, hasMore: false) }
        if case .folder(let id, _) = query {
            let all = folderPhotos.filter { $0.folderID == id && $0.id.space == space }, page = Array(all.dropFirst(offset).prefix(limit))
            return .init(items: page, offset: offset, nextOffset: offset + page.count, hasMore: offset + page.count < all.count)
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
        if case .upload(let file, let size, let date, let folder, let space, _) = mutation {
            let photo = SynologyPhoto(id: .init(profileID: profile, space: space, unitID: commands.count + 100),
                filename: file.lastPathComponent, sizeBytes: size, takenAt: date, indexedAt: date,
                folderID: folder ?? 9, mediaType: "photo")
            result = .init(state: .confirmed, photos: [photo], completedCount: ignoreUploadedDuplicate ? 0 : 1, skippedCount: ignoreUploadedDuplicate ? 1 : 0)
            progress(size, size)
            if shouldHold {
                shouldHold = false
                await withCheckedContinuation { held = $0; ready?.resume(); ready = nil }
            }
        } else if case .uploadToAlbum(let file, let size, let date, let albumID, _) = mutation {
            let photo = SynologyPhoto(id: .init(profileID: profile, space: .personal, unitID: commands.count + 100),
                filename: file.lastPathComponent, sizeBytes: size, takenAt: date, indexedAt: date,
                folderID: 9, mediaType: "photo", albumContext: .init(albumID: albumID, ownerUserID: 99, providerUserID: 12))
            result = .init(state: .confirmed, photos: [photo], completedCount: ignoreUploadedDuplicate ? 0 : 1, skippedCount: ignoreUploadedDuplicate ? 1 : 0)
            progress(size, size)
            if shouldHold {
                shouldHold = false
                await withCheckedContinuation { held = $0; ready?.resume(); ready = nil }
            }
        } else if case .setAlbumListSort(let scope, _, let sort) = mutation {
            listOrders[scope] = sort; result = .init(state: .confirmed, completedCount: 1)
        } else if case .setAlbumListDisplay(_, let display) = mutation {
            listDisplay = display; result = .init(state: .confirmed, completedCount: 1)
        } else if case .setAlbumSort(_, _, let sort) = mutation {
            albumOrder = sort
            result = .init(state: .confirmed, completedCount: 1)
        } else if case .generateAutomaticPreview = mutation {
            if automaticFailureRecorded { result = .init(state: .rejected, automaticPreviewFailureRecorded: true); automaticFailureRecorded = false }
            else { result = .init(state: .confirmed, completedCount: 1) }
            if shouldHold {
                shouldHold = false
                await withCheckedContinuation { held = $0; ready?.resume(); ready = nil }
            }
        } else if case .setAutomaticPreview(_, let enabled) = mutation {
            automaticEnabled = enabled; result = .init(state: .confirmed, completedCount: 1)
        } else if case .respondToCodecPrompt(_, let generate) = mutation {
            result = .init(state: codecPartial && generate ? .partial : .confirmed, completedCount: 1)
        } else if case .maintainLibrary = mutation {
            result = .init(state: .confirmed, completedCount: 1)
        } else if case .setGlobalSettings(let original, let enabled, let excluded) = mutation {
            var updated = original.applying(enabled: enabled, excludedExtensions: excluded)
            if globalPartial { updated.personalRecognition = original.personalRecognition; updated.sharedRecognition = original.sharedRecognition }
            globalDefaults = updated
            result = .init(state: globalPartial ? .partial : .confirmed, completedCount: 1, globalSettings: updated)
        } else if case .clearConversionCache(let original) = mutation {
            cacheDefaults = .init(profileID: original.profileID, administratorID: original.administratorID, sizeBytes: 0, isClearing: false)
            result = .init(state: .confirmed, completedCount: 1, conversionCache: cacheDefaults)
        } else if case .setSharedMembers(let original, let members, _) = mutation {
            memberDefaults = .init(profileID: original.profileID, administratorID: original.administratorID, isEnabled: original.isEnabled, members: members)
            if let memberResultSettings { configureSharedSettings(memberResultSettings) }
            result = .init(state: memberPartial ? .partial : .confirmed, completedCount: 1,
                sharedSpaceSettings: memberResultSettings ?? sharedDefaults, sharedMembers: memberDefaults)
        } else if case .setSharedSpaceSettings(var original, let enabled) = mutation {
            for kind in original.values.keys { original.values[kind] = enabled.contains(kind) }
            configureSharedSettings(original)
            result = .init(state: .confirmed, completedCount: 1, sharedSpaceSettings: original)
        } else if case .setSharedSpaceEnabled(var original, let enabled) = mutation {
            original.isEnabled = enabled; configureSharedSettings(original)
            result = .init(state: .confirmed, completedCount: 1, sharedSpaceSettings: original)
        } else if case .setRecognitionSettings(let original, let enabled) = mutation {
            recognitionDefaults = .init(values: Dictionary(uniqueKeysWithValues: original.values.keys.map { ($0, enabled.contains($0)) }), globallyEnabled: original.globallyEnabled, personalSpaceEnabled: original.personalSpaceEnabled)
            result = .init(state: .confirmed, completedCount: 1)
        } else if case .setDisplaySettings(_, let updated) = mutation {
            displayDefaults = updated
            result = .init(state: .confirmed, completedCount: 1)
        } else if case .setDuplicateSettings(_, let updated) = mutation {
            duplicateDefaults = updated
            result = .init(state: .confirmed, completedCount: 1)
        } else if case .move = mutation {
            if let movedAlbumPhotos { albumPhotos = movedAlbumPhotos; albumReadFailures = moveRefreshFailures }
            result = .init(state: .confirmed, completedCount: mutation.photos.count)
        } else if case .createConditionAlbum(let name, _) = mutation {
            result = .init(state: .confirmed, album: .init(id: 21, name: name, isConditional: true))
        } else if case .setAlbumCondition(let id, _, _) = mutation {
            result = .init(state: .confirmed, album: .init(id: id, name: "Fixture rule album", isConditional: true))
        } else if case .createFolder(let parent, let name, _) = mutation {
            let folder = SynologyPhotoCollection(id: 1000 + commands.count, name: name, parentID: parent)
            directoryFixtures.append(folder)
            result = .init(state: .confirmed, folder: folder)
        } else if case .addToAlbum = mutation, rejectAlbum {
            rejectAlbum = false
            result = .init(state: .rejected)
        } else { result = .init(state: .confirmed, completedCount: mutation.photos.count) }
        if result.state == .confirmed {
            let additions: [SynologyPhoto]
            if case .uploadToAlbum = mutation { additions = result.photos }
            else if case .addToAlbum(let id, let photos) = mutation {
                additions = photos.map { .init(id: $0.id, filename: $0.filename, sizeBytes: $0.sizeBytes,
                    takenAt: $0.takenAt, indexedAt: $0.indexedAt, folderID: $0.folderID, mediaType: $0.mediaType,
                    albumContext: .init(albumID: id, ownerUserID: 12, providerUserID: 12)) }
            } else { additions = [] }
            if !additions.isEmpty {
                var current = albumPhotos ?? albumPhoto.map { [$0] } ?? []
                current.append(contentsOf: additions.filter { photo in !current.contains { $0.id == photo.id } })
                albumPhotos = current
            }
        }
        results[operationID] = result
        return pending ? .init(state: .pendingReview) : result
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        if nextReviewFails { nextReviewFails = false; throw URLError(.notConnectedToInternet) }
        automaticReviews += 1
        return pending ? .init(state: .pendingReview) : results[operationID] ?? .init(state: .pendingReview)
    }
}

/// 合成共享分类只读服务：同编号跨空间、延迟分页和权限撤回均不连接NAS。
actor SharedCategoryServiceStub: SynologyPhotosServing {
    private var originalSizeJPEG = false
    func setOriginalSizeJPEG(_ value: Bool) { originalSizeJPEG = value }
    var downloadRequests: [(Int, SynologyPhotoDownloadFormat)] = []
    func download(_ photo: SynologyPhoto, format: SynologyPhotoDownloadFormat, to destination: URL, progress: @escaping FileTransferProgress) async throws -> SynologyPhotoDownloadFormat {
        downloadRequests.append((photo.id.unitID, format))
        try Data("synthetic-download".utf8).write(to: destination)
        return format != .original && photo.id.unitID != 8 ? format : .original
    }
    var previewReads: [(SynologyPhotoCategory, SynologyPhotoSpace)] = []
    private var previewImages: [Data] = []
    private var previewFailure = false
    private var previewDelay: UInt64 = 0
    private var holdsPreview = false
    private var previewHeld: CheckedContinuation<Void, Never>?
    private var previewReady: CheckedContinuation<Void, Never>?
    func configurePreviews(_ images: [Data], fails: Bool = false, delay: UInt64 = 0, hold: Bool = false) {
        previewImages = images; previewFailure = fails; previewDelay = delay; holdsPreview = hold
    }
    func waitForPreview() async { if previewHeld == nil { await withCheckedContinuation { previewReady = $0 } } }
    func releasePreview() { previewHeld?.resume(); previewHeld = nil }
    func categoryPreviewImages(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace) async throws -> [Data] {
        previewReads.append((category, space))
        if holdsPreview { await withCheckedContinuation { previewHeld = $0; previewReady?.resume(); previewReady = nil } }
        if previewDelay > 0 { try await Task.sleep(nanoseconds: previewDelay) }
        if previewFailure { throw URLError(.notConnectedToInternet) }
        return previewImages
    }
    var similarDeletedIDs: [SynologyPhotoID] = []
    var similarGroupRefreshReads = 0
    private var similarGroupRefreshFails = false
    private var similarMembers = [7, 8]
    private var secondSimilarGroup = false
    func enableSecondSimilarGroup() { secondSimilarGroup = true }
    private var automaticSimilarMutations = false
    private var pendingSimilarReviews = 0
    private var pendingSimilarResult: SynologyPhotosMutationResult?
    func configurePendingSimilarResult(_ result: SynologyPhotosMutationResult) { pendingSimilarResult = result }
    func enableAutomaticSimilarMutations(pendingReviews: Int = 0) { automaticSimilarMutations = true; pendingSimilarReviews = pendingReviews }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        if pendingSimilarReviews > 0 { pendingSimilarReviews -= 1; return .init(state: .pendingReview) }
        return pendingSimilarResult ?? .init(state: .rejected)
    }

    private var statusValue = SynologyPhotoSimilarStatus(waitingCount: 0, stage: "waiting", migrationComplete: true)
    func configureSimilarRefresh(fails: Bool) { similarGroupRefreshFails = fails }
    func configureSimilarMembers(_ ids: [Int]) { similarMembers = ids }
    func configureSimilarStatus(_ value: SynologyPhotoSimilarStatus) { statusValue = value }
    func similarStatus(in space: SynologyPhotoSpace) async throws -> SynologyPhotoSimilarStatus { statusValue }
    func prepareDeletion(_ photo: SynologyPhoto) async throws {}
    func deletePhoto(_ photo: SynologyPhoto, operationID: UUID) async throws -> SynologyPhotoDeletionResult {
        similarDeletedIDs.append(photo.id); return .confirmed
    }
    func similarGroupDetails(_ group: SynologyPhotoSimilarGroup) async throws -> SynologyPhotoSimilarDetail? {
        similarGroupRefreshReads += 1
        if similarGroupRefreshFails { throw URLError(.networkConnectionLost) }
        let remaining = similarMembers.filter { id in !similarDeletedIDs.contains { $0.unitID == id && $0.space == group.space } }
        guard remaining.count >= 2 else { return nil }
        let current = SynologyPhotoSimilarGroup(profileID: profileID, space: group.space, id: 31, photoIDs: remaining, topPickID: remaining.contains(8) ? 8 : remaining[0])
        return .init(group: current, photos: remaining.map { id in
            var photo = SynologyPhoto(id: .init(profileID: profileID, space: group.space, unitID: id), filename: "fixture-" + String(id) + ".jpg", sizeBytes: 128,
                takenAt: Date(timeIntervalSince1970: 1583020800), indexedAt: Date(timeIntervalSince1970: 1583020800), folderID: 9, mediaType: "photo")
            photo.similarGroup = current; return photo
        })
    }
    var similarCommands: [SynologyPhotosMutation] = []
    private var similarMutationResult: SynologyPhotosMutationResult?
    func configureSimilarMutation(_ result: SynologyPhotosMutationResult) { similarMutationResult = result }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> { [.similarGroups] }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws {}
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        if automaticSimilarMutations, case .editSimilarGroup(let detail, let edit) = mutation {
            similarCommands.append(mutation)
            let result: SynologyPhotosMutationResult
            if case .undo = edit { result = .init(state: .confirmed, photos: detail.photos, completedCount: 1, similarGroup: detail.group) }
            else { result = .init(state: .confirmed, photos: detail.photos.map { photo in var copy = photo; copy.similarGroup = nil; return copy }, completedCount: 1) }
            if pendingSimilarReviews > 0, similarCommands.count == 1 { pendingSimilarResult = result; return .init(state: .pendingReview) }
            return result
        }
        guard let result = similarMutationResult else { throw URLError(.badServerResponse) }
        similarCommands.append(mutation); return result
    }
    var similarReads = 0
    private var similarFailure = false
    private var holdsSimilar = false
    private var similarHeld: CheckedContinuation<Void, Never>?
    private var similarReady: CheckedContinuation<Void, Never>?
    func configureSimilar(fails: Bool = false, hold: Bool = false) { similarFailure = fails; holdsSimilar = hold }
    func waitForSimilar() async { if similarHeld == nil { await withCheckedContinuation { similarReady = $0 } } }
    func releaseSimilar() { similarHeld?.resume(); similarHeld = nil }
    func similarTimeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        [.init(year: 2020, month: 4, day: 1, itemCount: 1), .init(year: 2020, month: 3, day: 1, itemCount: 1)]
    }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto { photo }
    func previewImage(for photo: SynologyPhoto) async throws -> Data { previewImages.first ?? Data([1]) }
    func similarPhotos(for photo: SynologyPhoto) async throws -> SynologyPhotoSimilarDetail {
        similarReads += 1
        if holdsSimilar { await withCheckedContinuation { similarHeld = $0; similarReady?.resume(); similarReady = nil } }
        if similarFailure { throw URLError(.networkConnectionLost) }
        let group = photo.similarGroup ?? SynologyPhotoSimilarGroup(profileID: profileID, space: photo.id.space, id: 31, photoIDs: similarMembers, topPickID: 8)
        return .init(group: group, photos: group.photoIDs.map { id in
            var member = SynologyPhoto(id: .init(profileID: profileID, space: photo.id.space, unitID: id), filename: "fixture-\(id).jpg", sizeBytes: 128,
                takenAt: photo.takenAt, indexedAt: photo.indexedAt, folderID: 9, mediaType: "photo")
            member.similarGroup = group; return member
        })
    }
    private var manager = true
    private var fails = false
    private var empty = false
    private var paged = false
    private var wrongSource = false
    private var held: CheckedContinuation<Void, Never>?
    private var ready: CheckedContinuation<Void, Never>?
    var albumReads = 0
    private let profileID = UUID()
    func configure(manager: Bool? = nil, fails: Bool? = nil, empty: Bool? = nil, paged: Bool? = nil, wrongSource: Bool? = nil) {
        if let manager { self.manager = manager }; if let fails { self.fails = fails }; if let empty { self.empty = empty }
        if let paged { self.paged = paged }; if let wrongSource { self.wrongSource = wrongSource }
    }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal, .shared], packageVersion: "fixture", canManageSharedSpace: manager, supportsOriginalSizeJPEG: originalSizeJPEG) }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [.init(year: 2020, month: 3, day: 1, itemCount: 1)] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func filteredTimeline(in space: SynologyPhotoSpace, filter: SynologyPhotoFilter) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func categoryTimeline(_ category: SynologyPhotoCategory, id: Int, in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func categories(in space: SynologyPhotoSpace) async throws -> Set<SynologyPhotoCategory> {
        categoryReads += 1
        if fails { throw URLError(.notConnectedToInternet) }
        return empty ? [] : Set(SynologyPhotoCategory.allCases)
    }
    private var albumFixtures: [SynologyPhotoCollection] = []
    var categoryReads = 0
    func setAlbums(_ albums: [SynologyPhotoCollection]) { albumFixtures = albums }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { albumReads += 1; return Array(albumFixtures.dropFirst(offset).prefix(limit)) }
    func categoryItems(_ category: SynologyPhotoCategory, in space: SynologyPhotoSpace, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        if fails { throw URLError(.notConnectedToInternet) }
        if paged, offset > 0 {
            await withCheckedContinuation { held = $0; ready?.resume(); ready = nil }
        }
        return empty ? [] : (0..<(paged ? limit : 2)).map { .init(id: offset + $0 + 1, name: "Fixture \(space.rawValue) \($0 + 1)", itemCount: 1, space: wrongSource ? .personal : space) }
    }
    func waitForPage() async { if held == nil { await withCheckedContinuation { ready = $0 } } }
    func releasePage() { held?.resume(); held = nil }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        var photo = SynologyPhoto(id: .init(profileID: profileID, space: space, unitID: 7), filename: "fixture.jpg", sizeBytes: 128,
            takenAt: Date(timeIntervalSince1970: 1583020800), indexedAt: Date(timeIntervalSince1970: 1583020800), folderID: 9, mediaType: "photo")
        if case .similar = query { photo.similarGroup = .init(profileID: profileID, space: space, id: 31, photoIDs: similarMembers, topPickID: 8) }
        var list = offset == 0 && !empty ? [photo] : []
        if secondSimilarGroup, case .similar = query, !list.isEmpty {
            var second = SynologyPhoto(id: .init(profileID: profileID, space: space, unitID: 17), filename: "fixture-second.jpg", sizeBytes: 128,
                takenAt: photo.takenAt, indexedAt: photo.indexedAt, folderID: 9, mediaType: "photo")
            second.similarGroup = .init(profileID: profileID, space: space, id: 32, photoIDs: [17, 18], topPickID: 18)
            list.append(second)
        }
        return .init(items: list, offset: offset, nextOffset: offset + list.count, hasMore: false)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { previewImages.first ?? Data() }
}


/// 可控时钟验证取消，不依赖真实三秒等待或不断轮询推进照片。
actor SlideshowTestClock {
    private var waits: [UUID: CheckedContinuation<Void, Error>] = [:]
    var pending: Int { waits.count }
    func wait() async throws {
        let id = UUID()
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waits[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
    }
    private func cancel(_ id: UUID) { waits.removeValue(forKey: id)?.resume(throwing: CancellationError()) }
    func tick() {
        let current = waits; waits = [:]
        for continuation in current.values { continuation.resume() }
    }
}

actor SlideshowPhotoServiceStub: SynologyPhotosServing {
    private let displayPreferences: SynologyPhotoDisplaySettings?
    private var rotationEnabled = false
    private var rotationPending = false
    private var rotationPhoto: SynologyPhoto?
    private var rotatedPhotos: [SynologyPhotoID: SynologyPhoto] = [:]
    var rotationWrites = 0
    var previewReads = 0
    private var rotatedImage = Data([2])
    func enableRotation(pending: Bool = false) { rotationEnabled = true; rotationPending = pending }
    func resolveRotation() { rotationPending = false }
    func setRotatedImage(_ data: Data) { rotatedImage = data }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> { rotationEnabled ? [.rotation] : [] }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws { }
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        guard case .rotatePhoto(let photo) = mutation else { throw URLError(.unsupportedURL) }
        rotationWrites += 1; rotationPhoto = photo
        return .init(state: .pendingReview)
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        guard !rotationPending, let photo = rotationPhoto else { return .init(state: .pendingReview) }
        let updated = SynologyPhoto(id: photo.id, filename: photo.filename, sizeBytes: photo.sizeBytes, takenAt: photo.takenAt,
            indexedAt: photo.indexedAt, folderID: photo.folderID, mediaType: photo.mediaType, width: photo.height, height: photo.width, orientation: photo.counterClockwiseOrientation)
        rotatedPhotos[photo.id] = updated
        return .init(state: .confirmed, photos: [updated], completedCount: 1)
    }
    private let profile = UUID()
    private let video: Bool
    private let live: Bool
    private var failure = false
    private var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }
    var reads: [(SynologyPhotoSpace, Int)] = []
    private var image = Data([1])
    private var previewHold = false
    private var previewContinuation: CheckedContinuation<Void, Never>?
    func holdPreview() { previewHold = true }
    func releasePreview() { previewHold = false; previewContinuation?.resume(); previewContinuation = nil }
    init(video: Bool = false, live: Bool = false, displayPreferences: SynologyPhotoDisplaySettings? = nil) { self.video = video; self.live = live; self.displayPreferences = displayPreferences }
    func setImage(_ data: Data) { image = data }
    func setFailure(_ value: Bool) { failure = value }
    func holdNext() { hold = true }
    func release() { continuation?.resume(); continuation = nil }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal], packageVersion: "fixture", displaySettings: displayPreferences) }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] {
        [.init(year: 2021, month: 1, day: 1, itemCount: 1), .init(year: 2020, month: 3, day: 1, itemCount: 1), .init(year: 2020, month: 2, day: 1, itemCount: 1)]
    }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        reads.append((space, offset))
        if hold { hold = false; await withCheckedContinuation { continuation = $0 } }
        if failure { throw URLError(.notConnectedToInternet) }
        let dates = [1609459200, 1583020800, 1580515200]
        var photos = dates.enumerated().map { i, date in
            SynologyPhoto(id: .init(profileID: profile, space: space, unitID: i + 1), filename: "Fixture-\(i + 1).\(video && i == 0 ? "mov" : "jpg")",
                sizeBytes: 128, takenAt: Date(timeIntervalSince1970: Double(date)), indexedAt: .distantPast, folderID: 9,
                mediaType: i == 0 ? (video ? "video" : (live ? "live" : "photo")) : "photo",
                width: rotationEnabled ? 160 : nil, height: rotationEnabled ? 120 : nil, orientation: rotationEnabled ? 1 : nil)
        }
        if case .timeline(let start, let end) = query { photos = photos.filter { Int($0.takenAt.timeIntervalSince1970) >= start && Int($0.takenAt.timeIntervalSince1970) <= end } }
        let page = Array(photos.dropFirst(offset).prefix(limit))
        return .init(items: page, offset: offset, nextOffset: offset + page.count, hasMore: offset + page.count < photos.count)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { image }
    func details(for photo: SynologyPhoto) async throws -> SynologyPhoto {
        var result = rotatedPhotos[photo.id] ?? photo
        if displayPreferences != nil { result.description = "Fixture description"; result.addressComponents = ["Fixture city", "Fixture district"] }
        return result
    }
    func previewImage(for photo: SynologyPhoto) async throws -> Data {
        previewReads += 1
        if previewHold { await withCheckedContinuation { previewContinuation = $0 } }
        return rotatedPhotos[photo.id] == nil ? image : rotatedImage
    }
    func videoSource(for photo: SynologyPhoto) async throws -> MediaStreamSource {
        .init(request: URLRequest(url: URL(string: "https://example.invalid/fixture.mov")!), fileExtension: "mov", expectedContentLength: 128,
            expectedHost: "example.invalid", pinnedCertificateSHA256: nil)
    }
}


/// 合成目录封面选择器，权限与请求行为由Repository测试覆盖。
actor FolderCoverServiceStub: SynologyPhotosServing {
    enum Mode: Sendable { case normal, empty, failure, loading }
    private let profile = UUID()
    private var folderFixtures: [SynologyPhotoCollection]?
    func setFolderFixtures(_ folders: [SynologyPhotoCollection]) { folderFixtures = folders }
    private var sortPending = false
    func setSortPending(_ value: Bool) { sortPending = value }
    private var mode: Mode = .normal
    private var image = Data()
    private var held: CheckedContinuation<Void, Never>?
    var commands: [SynologyPhotosMutation] = []
    private var deletedFolderIDs: [SynologyPhotoSpace: Set<Int>] = [:]
    private var movedFolders: [UUID: [SynologyPhotoCollection]] = [:]
    var sorts: [Int: SynologyPhotoSort] = [:]
    var photoReads: [(SynologyPhotoQuery, Int)] = []
    var folderDirections: [SynologyPhotoSort.Direction] = []
    private var results: [UUID: SynologyPhotosMutationResult] = [:]
    func configure(_ mode: Mode, image: Data = Data()) { self.mode = mode; self.image = image }
    func release() { held?.resume(); held = nil }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal, .shared], packageVersion: "fixture") }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> { [.folders, .folderDeletion, .folderCover, .folderSorting, .fileTransfer] }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [.init(year: 2020, month: 3, day: 1, itemCount: 1)] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        photoReads.append((query, offset))
        if mode == .loading { await withCheckedContinuation { held = $0 } }
        if mode == .failure { throw URLError(.notConnectedToInternet) }
        let folder: Int = if case .folder(let id, _) = query { id } else { 9 }
        let photo = SynologyPhoto(id: .init(profileID: profile, space: space, unitID: folder == 9 ? 7 : 8), filename: "fixture.jpg", sizeBytes: 128,
            takenAt: Date(timeIntervalSince1970: 1583020800), indexedAt: .distantPast, folderID: folder, mediaType: "photo")
        let list = mode == .empty || offset > 0 ? [] : [photo]
        return .init(items: list, offset: offset, nextOffset: offset + list.count, hasMore: false)
    }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: 1, name: "Root", path: "/", space: space) }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        if mode == .failure { throw URLError(.notConnectedToInternet) }
        if let folderFixtures {
            return Array(folderFixtures.filter { $0.space == space && $0.parentID == parentID }.sorted { $0.name < $1.name }.dropFirst(offset).prefix(limit))
        }
        guard mode != .empty, offset == 0, parentID != 10 else { return [] }
        let folder = SynologyPhotoCollection(id: parentID == 1 ? 9 : 10, name: "Fixture child", parentID: parentID, path: parentID == 1 ? "/Fixture" : "/Fixture/Child", space: space)
        return deletedFolderIDs[space, default: []].contains(folder.id) ? [] : [folder]
    }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { offset == 0 ? [.init(id: 9, name: "Fixture album")] : [] }
    func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort { sorts[folder.id] ?? .init() }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int, direction: SynologyPhotoSort.Direction) async throws -> [SynologyPhotoCollection] {
        folderDirections.append(direction)
        return try await folders(in: space, parentID: parentID, offset: offset, limit: limit)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { image }
    func folderCoverImages(_ folder: SynologyPhotoCollection) async throws -> [Data] { image.isEmpty ? [] : [image] }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws { }
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        commands.append(mutation)
        if mutation.feature == .fileTransfer {
            let result = SynologyPhotosMutationResult(state: .confirmed, completedCount: mutation.photos.count + mutation.transferFolders.count)
            results[operationID] = result
            if case .move = mutation {
                movedFolders[operationID] = mutation.transferFolders
                if !sortPending { for folder in mutation.transferFolders { deletedFolderIDs[folder.space, default: []].insert(folder.id) } }
            }
            return sortPending ? .init(state: .pendingReview) : result
        }
        if case .deleteFolderItems(let photos, let folders) = mutation {
            let result = SynologyPhotosMutationResult(state: .confirmed, completedCount: photos.count + folders.count, deletedFolders: folders, deletedPhotoIDs: photos.map(\.id))
            results[operationID] = result
            if !sortPending { for folder in folders { deletedFolderIDs[folder.space, default: []].insert(folder.id) } }
            return sortPending ? .init(state: .pendingReview) : result
        }
        let folder: SynologyPhotoCollection
        switch mutation {
        case .createFolder(let parent, let name, let space):
            folder = .init(id: 1000 + commands.count, name: name, parentID: parent, space: space)
            if folderFixtures == nil { folderFixtures = [.init(id: 9, name: "Fixture child", parentID: 1, path: "/Fixture", space: space)] }
            folderFixtures?.append(folder)
        case .setFolderCover(let target, _): folder = target
        case .renameFolder(let target, let name):
            folder = .init(id: target.id, name: name, parentID: target.parentID,
                path: ((target.path! as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name), space: target.space)
        case .setFolderSort(let target, let sort):
            sorts[target.id] = sort
            folder = .init(id: target.id, name: target.name, path: target.path, space: target.space, sort: sort)
        default: return .init(state: .rejected)
        }
        let result = SynologyPhotosMutationResult(state: .confirmed, folder: folder)
        results[operationID] = result
        if sortPending { return .init(state: .pendingReview) }
        return result
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        let result = sortPending ? SynologyPhotosMutationResult(state: .pendingReview) : results[operationID] ?? .init(state: .pendingReview)
        for folder in result.deletedFolders { deletedFolderIDs[folder.space, default: []].insert(folder.id) }
        if result.state == .confirmed { for folder in movedFolders[operationID] ?? [] { deletedFolderIDs[folder.space, default: []].insert(folder.id) } }
        return result
    }
}


actor FolderSharingServiceStub: SynologyPhotosServing {
    enum Mode: Sendable { case normal, empty, unreadableMembers, parentRestricted, failure }
    private let mode: Mode
    var targets: [SynologyPhotoCollection] = []
    var writes = 0
    var reviews = 0
    var timelineReads = 0
    var commands: [SynologyPhotosMutation] = []
    private var outcome: SynologyPhotosMutationResult.State = .confirmed
    func setOutcome(_ value: SynologyPhotosMutationResult.State) { outcome = value }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> { space == .shared ? [.folderSharing] : [] }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws { }
    init(mode: Mode = .normal) { self.mode = mode }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal, .shared], packageVersion: "fixture", canManageSharedSpace: true) }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { timelineReads += 1; return [] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { [] }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage { .init(items: [], offset: offset, nextOffset: offset, hasMore: false) }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: 1, name: "Root", path: "/", space: space) }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }
    func folderSharing(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoFolderSharingState {
        targets.append(folder)
        if mode == .failure { throw URLError(.notConnectedToInternet) }
        let members: [SynologyPhotoShareGrant]? = mode == .unreadableMembers ? nil : mode == .empty ? [] : [
            .init(recipient: .init(id: .init(type: "user", value: .integer(20)), name: "Fixture user"), role: "manage"),
            .init(recipient: .init(id: .init(type: "group", value: .string("20")), name: "Fixture group"), role: "download")]
        return .init(folder: folder, access: mode == .parentRestricted ? .management : .invited, url: URL(string: "https://example.invalid/folder")!,
            hasPassword: mode == .unreadableMembers ? nil : true, members: members, parentIsShared: mode != .parentRestricted, appliesToSubfolders: true, revision: "fixture")
    }
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        writes += 1; commands.append(mutation); return .init(state: outcome)
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult { reviews += 1; return .init(state: outcome) }
}


/// 任务中心专用合成服务；与图库写操作分别保留核对结果。
actor BackgroundPhotoServiceStub: SynologyPhotosServing {
    let profileID = UUID()
    var commands: [SynologyPhotosMutation] = []
    var photoReads = 0
    var taskReads = 0
    private var tasks: [SynologyPhotoBackgroundTask]?
    private var listFails = false
    private var errorsFail = false
    private var emptyErrors = false
    private var holdList = false
    private var listContinuation: CheckedContinuation<Void, Never>?
    private var folderFails = false
    private var folderCycle = false
    private var holdFolder = false
    private var folderContinuation: CheckedContinuation<Void, Never>?
    private var folderReady: CheckedContinuation<Void, Never>?
    private var pendingGeneral = false
    private var pendingBackground = false
    private var operations: [UUID: SynologyPhotosMutation] = [:]
    func fixture(id: Int = 42, status: SynologyPhotoBackgroundTask.Status = .processing, shared: Bool = false) -> SynologyPhotoBackgroundTask {
        .init(profileID: profileID, userID: 12, id: id, operation: "copy", status: status, total: 5,
              completion: status == .done ? 5 : 2, errors: 1, skipped: 0, overwritten: 0, createdAt: 1_700_000_000,
              targetFolderID: shared ? 109 : 9, targetOwnerID: shared ? 0 : 12)
    }
    func setTasks(_ value: [SynologyPhotoBackgroundTask]) { tasks = value }
    func configureList(fails: Bool = false, held: Bool = false) { listFails = fails; holdList = held }
    func releaseList() { listContinuation?.resume(); listContinuation = nil }
    func configureErrors(fails: Bool = false, empty: Bool = false) { errorsFail = fails; emptyErrors = empty }
    func setPending(general: Bool, background: Bool) { pendingGeneral = general; pendingBackground = background }
    func configureFolders(fails: Bool = false, cycle: Bool = false, held: Bool = false) { folderFails = fails; folderCycle = cycle; holdFolder = held }
    func waitForHeldFolder() async { if folderContinuation == nil { await withCheckedContinuation { folderReady = $0 } } }
    func releaseFolder() { folderContinuation?.resume(); folderContinuation = nil }
    func backgroundTasks() async throws -> [SynologyPhotoBackgroundTask] {
        taskReads += 1
        if holdList { holdList = false; await withCheckedContinuation { listContinuation = $0 } }
        if listFails { throw URLError(.notConnectedToInternet) }
        return tasks ?? [fixture()]
    }
    func backgroundTaskErrors(_ task: SynologyPhotoBackgroundTask) async throws -> [SynologyPhotoBackgroundTaskError] {
        if errorsFail { throw URLError(.notConnectedToInternet) }
        return emptyErrors ? [] : [.init(kind: .item, itemID: 7, reason: .quota, name: "Synthetic Photo.jpg", folderPath: "/Synthetic Photos")]
    }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal, .shared], packageVersion: "fixture") }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> { [.backgroundTasks, .fileTransfer] }
    func managementFeatures() async -> Set<SynologyPhotosManagementFeature> { [.backgroundTasks, .fileTransfer] }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [.init(year: 2020, month: 3, day: 1, itemCount: 1)] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { try await timeline(in: space) }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        photoReads += 1
        let photo = SynologyPhoto(id: .init(profileID: profileID, space: space, unitID: 7), filename: "Synthetic Photo.jpg", sizeBytes: 128,
            takenAt: Date(timeIntervalSince1970: 1_583_020_800), indexedAt: Date(timeIntervalSince1970: 1_583_020_800), folderID: 1, mediaType: "photo")
        return .init(items: offset == 0 ? [photo] : [], offset: offset, nextOffset: 1, hasMore: false)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: space == .personal ? 1 : 101, name: "Root", path: "/", space: space) }
    func folder(id: Int, in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection {
        if holdFolder { holdFolder = false; await withCheckedContinuation { folderContinuation = $0; folderReady?.resume(); folderReady = nil } }
        if folderFails { throw URLError(.noPermissionsToReadFile) }
        let root = space == .personal ? 1 : 101
        if id == root { return try await rootFolder(in: space) }
        return .init(id: id, name: "Synthetic Photos", parentID: folderCycle ? id : root, path: "/Synthetic Photos", space: space)
    }
    func folderSort(_ folder: SynologyPhotoCollection) async throws -> SynologyPhotoSort { .init() }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws { }
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        commands.append(mutation); operations[operationID] = mutation
        return finish(mutation)
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        guard let command = operations[operationID] else { return .init(state: .rejected) }
        return finish(command)
    }
    private func finish(_ command: SynologyPhotosMutation) -> SynologyPhotosMutationResult {
        if command.feature == .backgroundTasks {
            if pendingBackground { return .init(state: .pendingReview) }
            if case .clearBackgroundTasks(let targets) = command { tasks = (tasks ?? [fixture()]).filter { entry in !targets.contains { $0.id == entry.id } } }
            if case .cancelBackgroundTask(let target) = command { tasks = (tasks ?? [fixture()]).map { $0.id == target.id ? fixture(id: target.id, status: .done, shared: target.targetSpace == .shared) : $0 } }
            return .init(state: .confirmed)
        }
        return .init(state: pendingGeneral ? .pendingReview : .partial)
    }
}


/// 冻结相册的合成服务，仅用于模型与原生UI测试。
actor FrozenPhotoServiceStub: SynologyPhotosServing {
    let profileID = UUID()
    var commands: [SynologyPhotosMutation] = []
    var photoReads = 0
    var frozen = true
    private var outcome: SynologyPhotosMutationResult.State = .confirmed
    private var operations: [UUID: SynologyPhotosMutation] = [:]
    private var fails = false
    private var bare = false
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var newAlbum: SynologyPhotoCollection?
    private var removed = false
    func configure(fails: Bool = false, bare: Bool = false, held: Bool = false) { self.fails = fails; self.bare = bare; self.held = held }
    func release() { continuation?.resume(); continuation = nil }
    func setOutcome(_ state: SynologyPhotosMutationResult.State) { outcome = state }
    func fixture() -> SynologyPhotoCollection { .init(id: 21, name: "Synthetic frozen album", itemCount: 2, isFrozen: frozen) }
    func frozenAlbum(id: Int) async throws -> SynologyPhotoFrozenAlbum {
        if held { held = false; await withCheckedContinuation { continuation = $0 } }
        if fails { throw URLError(.notConnectedToInternet) }
        return .init(profileID: profileID, userID: 12, album: fixture(),
            rawCondition: bare ? ["user_id": .integer(0)] : ["user_id": .integer(12), "item_type": .array([])],
            unsupportedConditions: bare ? [:] : ["people": .boolean(true), "recently_add": .boolean(true)],
            rebuildCondition: .init(fields: ["user_id": .integer(bare ? 0 : 12), "item_type": .array([])]), sharingRevision: "fixture", isShared: false)
    }
    func access() async throws -> SynologyPhotosAccess { .init(spaces: [.personal], packageVersion: "fixture") }
    func managementFeatures() async -> Set<SynologyPhotosManagementFeature> { [.frozenAlbums, .conditionAlbums, .albums, .upload] }
    func managementFeatures(in space: SynologyPhotoSpace) async -> Set<SynologyPhotosManagementFeature> { await managementFeatures() }
    func timeline(in space: SynologyPhotoSpace) async throws -> [SynologyPhotoDay] { [] }
    func searchTimeline(in space: SynologyPhotoSpace, keyword: String) async throws -> [SynologyPhotoDay] { [] }
    func photos(in space: SynologyPhotoSpace, query: SynologyPhotoQuery, offset: Int, limit: Int) async throws -> SynologyPhotoPage {
        photoReads += 1; return .init(items: [], offset: offset, nextOffset: offset, hasMore: false)
    }
    func thumbnail(for photo: SynologyPhoto) async throws -> Data { Data() }
    func rootFolder(in space: SynologyPhotoSpace) async throws -> SynologyPhotoCollection { .init(id: 1, name: "Synthetic root", path: "/", space: space) }
    func folders(in space: SynologyPhotoSpace, parentID: Int, offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] { [] }
    func albums(offset: Int, limit: Int) async throws -> [SynologyPhotoCollection] {
        (removed ? [] : [fixture()]) + (newAlbum.map { [$0] } ?? [])
    }
    func albumAccess(id: Int) async throws -> SynologyPhotoAlbumAccess {
        .init(albumID: id, currentUserID: 12, isOwner: true, canDownload: true, canContribute: id == 21 && !frozen)
    }
    func conditionSuggestions(keyword: String, in space: SynologyPhotoSpace) async throws -> [String: [SynologyPhotoConditionOption]] { [:] }
    func conditionItemCount(_ condition: SynologyPhotoAlbumCondition) async throws -> Int { 2 }
    func prepareMutation(_ mutation: SynologyPhotosMutation) async throws { }
    func performMutation(_ mutation: SynologyPhotosMutation, operationID: UUID, progress: @escaping FileTransferProgress) async throws -> SynologyPhotosMutationResult {
        commands.append(mutation); operations[operationID] = mutation; return result(mutation)
    }
    func reviewMutation(operationID: UUID) async throws -> SynologyPhotosMutationResult {
        guard let command = operations[operationID] else { return .init(state: .rejected) }; return result(command)
    }
    private func result(_ mutation: SynologyPhotosMutation) -> SynologyPhotosMutationResult {
        guard outcome != .pendingReview && outcome != .rejected else { return .init(state: outcome) }
        switch mutation {
        case .unfreezeAlbum: frozen = false; return .init(state: outcome, album: fixture())
        case .rebuildFrozenAlbum(_, let name, _):
            newAlbum = .init(id: 31, name: name, itemCount: 2, isConditional: true)
            removed = outcome == .confirmed; return .init(state: outcome, album: newAlbum)
        default: return .init(state: .rejected)
        }
    }
}
