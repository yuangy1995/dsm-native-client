@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoControlTests: XCTestCase {
    private func fixture(_ state: String) async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-controls-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待照片权限或任务结束超时")
    }
    private func openSharing(_ session: MobileSynologyPhotosSession, folderID: Int = 2) async throws -> MobilePhotoFolderSharingModel {
        await session.model.selectSpace(.shared); await session.model.selectSection(.folders)
        if folderID == 200 { await session.model.open(try XCTUnwrap(session.model.collections.first { $0.id == 2 })) }
        let sharing = try XCTUnwrap(session.folderSharing), folder = try XCTUnwrap(session.model.collections.first { $0.id == folderID })
        sharing.begin(folder); try await wait { !sharing.isLoading }; return sharing
    }
    private func openTasks(_ session: MobileSynologyPhotosSession) async throws -> MobilePhotoTasksModel {
        let tasks = try XCTUnwrap(session.tasks); tasks.begin(); await tasks.refresh(); return tasks
    }
    private func taskStore(_ storage: MobilePhotoUploadStorage) -> PhotoAlbumRecoveryStore {
        .init(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/tasks-v1.json"))
    }

    func test文件夹扩大权限先确认取消后可再提交且密码草稿清理() async throws {
        let (root, _, service, session) = try await fixture("photo-folder-sharing"); defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await openSharing(session)
        XCTAssertNil(sharing.mutation); sharing.access = .download; sharing.password.choice = .newPassword; sharing.password.password = "synthetic-only"
        XCTAssertFalse(sharing.save()); XCTAssertTrue(sharing.showsConfirmation)
        let before = await service.commands; XCTAssertTrue(before.isEmpty)
        sharing.cancelConfirmation(); XCTAssertNotNil(sharing.mutation)
        XCTAssertFalse(sharing.save()); XCTAssertTrue(sharing.confirmSave()); XCTAssertFalse(sharing.confirmSave())
        XCTAssertEqual(sharing.password.password, ""); XCTAssertNil(sharing.draft)
        try await wait { !session.model.isManaging }; XCTAssertNil(session.model.pendingMutationID)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .setFolderSharing(let original, let access, _, let password, _) = commands[0] else { return XCTFail() }
        XCTAssertEqual(original.folder.id, 2); XCTAssertEqual(access, .download); XCTAssertEqual(password, "synthetic-only")
    }

    func test文件夹普通收紧保存不追加确认且草稿变化废弃旧确认() async throws {
        let (root, _, service, session) = try await fixture("photo-folder-sharing"); defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await openSharing(session); sharing.access = .management
        XCTAssertFalse(sharing.needsConfirmation); XCTAssertTrue(sharing.save()); try await wait { !session.model.isManaging }
        sharing.begin(try XCTUnwrap(session.model.collections.first { $0.id == 2 })); try await wait { !sharing.isLoading }
        sharing.access = .view; XCTAssertFalse(sharing.save()); sharing.access = .download
        XCTAssertFalse(sharing.confirmSave()); XCTAssertNotNil(sharing.error)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test文件夹成员搜索保留用户群组身份并阻止伪造与重复() async throws {
        let (root, _, _, session) = try await fixture("photo-folder-sharing"); defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await openSharing(session); sharing.loadRecipients(); try await wait { !sharing.loadingRecipients }
        XCTAssertEqual(sharing.availableRecipients.count, 2); sharing.search = "group"
        let group = try XCTUnwrap(sharing.availableRecipients.first); sharing.add(group); sharing.add(group)
        XCTAssertEqual(sharing.members.count, 1); XCTAssertEqual(sharing.members[0].id.type, "group")
        sharing.members[0].role = "manage"; XCTAssertNotNil(sharing.mutation); XCTAssertTrue(sharing.needsConfirmation)
        sharing.members.append(.init(recipient: .init(id: .init(type: "user", value: .integer(999)), name: "Unexpected"), role: "view"))
        XCTAssertNil(sharing.mutation)
    }

    func test文件夹继承限制权限缺失及成员无法读取保持边界() async throws {
        for state in ["photo-folder-sharing-parent", "photo-folder-sharing-noaccess", "photo-folder-sharing-readonly", "photo-folder-sharing-members-unreadable"] {
            let (root, _, _, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            if state == "photo-folder-sharing-noaccess" {
                await session.model.selectSpace(.shared); await session.model.selectSection(.folders)
                let editor = try XCTUnwrap(session.folderSharing); XCTAssertFalse(editor.canOpen(try XCTUnwrap(session.model.collections.first))); continue
            }
            let sharing = try await openSharing(session, folderID: state == "photo-folder-sharing-parent" ? 200 : 2)
            sharing.access = .view
            if state == "photo-folder-sharing-members-unreadable" {
                XCTAssertNil(sharing.original?.members)
                guard case .setFolderSharing(_, _, let members, _, _) = sharing.mutation else { return XCTFail() }; XCTAssertNil(members)
            } else { XCTAssertFalse(sharing.editable); XCTAssertNil(sharing.mutation) }
        }
    }

    func test文件夹子目录覆盖明确确认第二层不能改变默认选项() async throws {
        let (root, _, _, session) = try await fixture("photo-folder-sharing"); defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await openSharing(session); sharing.appliesToSubfolders = true
        XCTAssertTrue(sharing.needsConfirmation); XCTAssertFalse(sharing.save()); sharing.cancel()
        _ = try await openSharing(session, folderID: 200); sharing.appliesToSubfolders = true; sharing.access = .view
        XCTAssertNil(sharing.mutation)
    }

    func test文件夹权限未知重启仅恢复查询且记录不含密码或链接() async throws {
        let (root, storage, service, session) = try await fixture("photo-folder-sharing-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await openSharing(session); sharing.access = .view; sharing.password.choice = .newPassword; sharing.password.password = "synthetic-secret"
        XCTAssertFalse(sharing.save()); XCTAssertTrue(sharing.confirmSave()); try await wait { !session.model.isManaging }
        let store = PhotoAlbumRecoveryStore(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
        let text = try String(contentsOf: store.url, encoding: .utf8); XCTAssertFalse(text.contains("synthetic-secret")); XCTAssertFalse(text.contains("example.invalid"))
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        XCTAssertNotNil(session.model.pendingMutationID); await service.setPending(false); session.model.reviewPendingMutation()
        try await wait { !session.model.isManaging }; XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(try store.load())
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test文件夹权限取消后迟到读取不会回填其他会话() async throws {
        let (root, _, service, session) = try await fixture("photo-folder-sharing-held"); defer { try? FileManager.default.removeItem(at: root) }
        await session.model.selectSpace(.shared); await session.model.selectSection(.folders)
        let sharing = try XCTUnwrap(session.folderSharing); sharing.begin(try XCTUnwrap(session.model.collections.first))
        for _ in 0..<100 { if await service.isControlHeld { break }; await Task.yield() }
        let held = await service.isControlHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-folder-sharing")); await service.releaseControl(); await session.activate()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(sharing.original); XCTAssertNil(sharing.draft); XCTAssertNil(session.folderSharing?.original)
    }

    func test文件夹权限与成员加载错误和空成员各自可恢复() async throws {
        for state in ["photo-folder-sharing-error", "photo-folder-sharing-members-error", "photo-folder-sharing-members-empty"] {
            let (root, _, _, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            let sharing = try await openSharing(session)
            if state == "photo-folder-sharing-error" { XCTAssertNotNil(sharing.error); XCTAssertNil(sharing.mutation) }
            else {
                sharing.loadRecipients(); try await wait { !sharing.loadingRecipients }
                XCTAssertEqual(sharing.recipientError != nil, state.hasSuffix("-error")); XCTAssertTrue(sharing.availableRecipients.isEmpty)
                sharing.access = .management; XCTAssertNotNil(sharing.mutation)
            }
        }
    }

    func test照片任务筛选错误详情和取消保留已完成结果() async throws {
        let (root, _, service, session) = try await fixture("photo-tasks"); defer { try? FileManager.default.removeItem(at: root) }
        let tasks = try await openTasks(session); XCTAssertEqual(tasks.visibleTasks.count, 3)
        tasks.filter = .active; XCTAssertEqual(tasks.visibleTasks.map(\.id), [41])
        tasks.requestCancel(try XCTUnwrap(tasks.visibleTasks.first)); XCTAssertTrue(tasks.showsConfirmation)
        let before = await service.commands; XCTAssertTrue(before.isEmpty); tasks.cancelConfirmation()
        tasks.requestCancel(try XCTUnwrap(tasks.visibleTasks.first)); XCTAssertTrue(tasks.confirm()); XCTAssertFalse(tasks.confirm())
        try await wait { !session.model.isManagingBackgroundTask }; await tasks.refresh(); XCTAssertTrue(tasks.visibleTasks.isEmpty)
        tasks.filter = .finished; XCTAssertEqual(tasks.visibleTasks.count, 3)
        let cancelled = try XCTUnwrap(tasks.tasks.first { $0.id == 41 }); XCTAssertTrue(cancelled.isCancelled); XCTAssertEqual(cancelled.completion, 2)
        tasks.showErrors(try XCTUnwrap(tasks.tasks.first { $0.id == 42 })); try await wait { !tasks.loadingErrors }
        XCTAssertEqual(tasks.entries.first?.reason, .quota); tasks.closeErrors(); XCTAssertNil(tasks.errorTask)
    }

    func test照片任务清除固定确认范围不扩展到新完成项() async throws {
        let (root, _, service, session) = try await fixture("photo-tasks"); defer { try? FileManager.default.removeItem(at: root) }
        let tasks = try await openTasks(session); tasks.requestClear()
        let extra = SynologyPhotoBackgroundTask(profileID: service.profileID, userID: 12, id: 44, operation: "copy", status: .done,
            total: 1, completion: 1, errors: 0, skipped: 0, overwritten: 0, createdAt: 1_700_000_044, targetFolderID: 3, targetOwnerID: 12)
        await service.seedTasks(tasks.tasks + [extra]); await tasks.refresh()
        XCTAssertTrue(tasks.confirm()); try await wait { !session.model.isManagingBackgroundTask }; await tasks.refresh()
        XCTAssertEqual(Set(tasks.tasks.map(\.id)), [41, 44])
        let commands = await service.commands; guard case .clearBackgroundTasks(let originals) = commands.last else { return XCTFail() }
        XCTAssertEqual(Set(originals.map(\.id)), [42, 43])
    }

    func test照片任务身份变化废弃确认且无写入() async throws {
        let (root, _, service, session) = try await fixture("photo-tasks"); defer { try? FileManager.default.removeItem(at: root) }
        let tasks = try await openTasks(session); tasks.requestCancel(try XCTUnwrap(tasks.tasks.first))
        await service.seedTasks([]); await tasks.refresh(); XCTAssertFalse(tasks.confirm()); XCTAssertNotNil(tasks.error)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test照片任务未知重启独立恢复不重发() async throws {
        let (root, storage, service, session) = try await fixture("photo-tasks-unknown"); defer { try? FileManager.default.removeItem(at: root) }
        let tasks = try await openTasks(session); tasks.requestCancel(try XCTUnwrap(tasks.tasks.first)); XCTAssertTrue(tasks.confirm())
        try await wait { !session.model.isManagingBackgroundTask }; XCTAssertNotNil(session.model.pendingBackgroundMutationID)
        let stored = try XCTUnwrap(taskStore(storage).load()); XCTAssertNotNil(stored.backgroundDetails)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        XCTAssertEqual(session.model.pendingBackgroundMutationID, stored.operationID); XCTAssertNil(session.model.pendingMutationID)
        await service.setPending(false); await session.model.retryBackgroundRecovery(); try await wait { !session.model.isManagingBackgroundTask }
        XCTAssertNil(session.model.pendingBackgroundMutationID); XCTAssertNil(try taskStore(storage).load())
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test照片任务部分清除不自动重复整批() async throws {
        let (root, _, service, session) = try await fixture("photo-tasks-partial"); defer { try? FileManager.default.removeItem(at: root) }
        let tasks = try await openTasks(session); tasks.requestClear(); XCTAssertTrue(tasks.confirm())
        try await wait { !session.model.isManagingBackgroundTask }; await tasks.refresh()
        XCTAssertNil(session.model.pendingBackgroundMutationID); XCTAssertEqual(Set(tasks.tasks.map(\.id)), [41, 43])
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test照片任务恢复文件损坏阻止再次控制且可重试() async throws {
        let (root, storage, service, session) = try await fixture("photo-tasks"); defer { try? FileManager.default.removeItem(at: root) }
        let store = taskStore(storage)
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: store.url)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        let tasks = try await openTasks(session); XCTAssertNotNil(session.model.backgroundRecoveryError); XCTAssertFalse(tasks.canControl)
        tasks.requestClear(); XCTAssertNil(tasks.confirmation)
        try FileManager.default.removeItem(at: store.url); await session.model.retryBackgroundRecovery()
        XCTAssertNil(session.model.backgroundRecoveryError); XCTAssertTrue(tasks.canControl)
    }

    func test照片原操作记录损坏时不能清除唯一任务证据() async throws {
        let (root, storage, service, session) = try await fixture("photo-tasks"); defer { try? FileManager.default.removeItem(at: root) }
        let url = storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("invalid".utf8).write(to: url)
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        let tasks = try await openTasks(session); XCTAssertNotNil(session.model.albumRecoveryError); XCTAssertFalse(tasks.canControl)
        tasks.requestClear(); XCTAssertNil(tasks.confirmation)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test照片任务打开原目标目录并拒绝未知来源() async throws {
        let (root, _, _, session) = try await fixture("photo-tasks"); defer { try? FileManager.default.removeItem(at: root) }
        let tasks = try await openTasks(session), target = try XCTUnwrap(tasks.tasks.first { $0.id == 43 })
        XCTAssertTrue(tasks.canOpenDestination(target)); let opened = await tasks.openDestination(target); XCTAssertTrue(opened)
        XCTAssertFalse(tasks.isPresented); XCTAssertEqual(session.model.folderHistory.last?.id, 3)
    }

    func test照片任务加载错误空内容和离开后迟到响应() async throws {
        for state in ["photo-tasks-error", "photo-tasks-empty", "photo-tasks-held"] {
            let (root, _, service, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            let tasks = try XCTUnwrap(session.tasks); tasks.begin()
            if state == "photo-tasks-held" {
                let load = Task { await tasks.refresh() }
                for _ in 0..<100 { if await service.isControlHeld { break }; await Task.yield() }
                tasks.cancel(); await service.releaseControl(); await load.value
                XCTAssertFalse(tasks.isPresented); XCTAssertTrue(tasks.tasks.isEmpty)
            } else {
                await tasks.refresh(); XCTAssertTrue(tasks.tasks.isEmpty); XCTAssertEqual(tasks.error != nil, state.hasSuffix("-error"))
            }
        }
    }
}
