@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoAdministrationTests: XCTestCase {
    private func fixture(_ state: String = "photo-admin") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-admin-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待照片管理员操作超时")
    }
    private func open(_ page: MobilePhotoAdministrationModel.Page, in session: MobileSynologyPhotosSession) async throws -> MobilePhotoAdministrationModel {
        let value = try XCTUnwrap(session.administration); value.begin(page)
        try await wait { !value.isLoading && !value.cacheLoading && !value.candidatesLoading }; return value
    }

    func test共享启停取消确认最后图库与普通偏好保存() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.shared, in: session)
        value.confirmSharedSwitch(); XCTAssertTrue(value.showsConfirmation); value.cancelConfirmation()
        let before = await service.commands; XCTAssertTrue(before.isEmpty)
        value.sharedEnabled.remove(.person); XCTAssertTrue(value.save()); try await wait { !session.model.isManaging }
        _ = try await open(.shared, in: session); XCTAssertFalse(value.sharedEnabled.contains(.person))
        value.confirmSharedSwitch(); XCTAssertTrue(value.confirmSave()); XCTAssertFalse(value.confirmSave())
        try await wait { !session.model.isManaging }; let shared = try await service.sharedSpaceSettings(); XCTAssertFalse(shared.isEnabled)
        XCTAssertFalse(session.model.spaces.contains(.shared))
        let (lastRoot, _, _, lastSession) = try await fixture("photo-admin-last"); defer { try? FileManager.default.removeItem(at: lastRoot) }
        let last = try await open(.shared, in: lastSession); last.confirmSharedSwitch(); XCTAssertFalse(last.showsConfirmation)
    }

    func test公开分享必须确认且旧草稿变更后不可保存() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.shared, in: session); value.sharedEnabled.insert(.publicRoot)
        XCTAssertFalse(value.save()); XCTAssertTrue(value.showsConfirmation)
        value.sharedEnabled.remove(.concept); XCTAssertFalse(value.confirmSave()); XCTAssertNotNil(value.error)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test全局排除格式保留未知值与具体风险确认() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.global, in: session); XCTAssertEqual(value.excluded, ["LEGACY"])
        value.excluded?.insert("RAW"); value.globalEnabled.remove(.person); value.globalEnabled.insert(.guestInfo)
        XCTAssertFalse(value.save()); XCTAssertTrue(value.showsConfirmation); XCTAssertTrue(value.confirmSave())
        try await wait { !session.model.isManaging }
        let result = try await service.globalSettings(); XCTAssertEqual(result.excludedExtensions, ["LEGACY", "RAW"])
        XCTAssertEqual(result.personalRecognition[.person], false); XCTAssertEqual(result.sharedRecognition[.person], false)
        XCTAssertEqual(result.values[.guestInfo], true)
    }

    func test全局无风险开关直接保存但不支持的编码选项不可修改() async throws {
        let (root, _, _, session) = try await fixture("photo-admin-restricted"); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.global, in: session)
        value.globalEnabled.remove(.originalJPEG); XCTAssertNil(value.mutation)
        value.globalEnabled.insert(.originalJPEG); value.globalEnabled.insert(.similar)
        XCTAssertTrue(value.save()); XCTAssertFalse(value.showsConfirmation); try await wait { !session.model.isManaging }
    }

    func test缓存清理取消及重复确认只提交一次忙碌不得清理() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.global, in: session)
        XCTAssertEqual(value.cache?.sizeBytes, 2048); value.confirmClearCache(); XCTAssertTrue(value.showsConfirmation)
        value.cancelConfirmation(); let empty = await service.commands; XCTAssertTrue(empty.isEmpty)
        value.confirmClearCache(); XCTAssertTrue(value.confirmSave()); XCTAssertFalse(value.confirmSave()); try await wait { !session.model.isManaging }
        _ = try await open(.global, in: session); XCTAssertEqual(value.cache?.sizeBytes, 0); value.confirmClearCache(); XCTAssertFalse(value.showsConfirmation)
        let (busyRoot, _, _, busySession) = try await fixture("photo-admin-busy"); defer { try? FileManager.default.removeItem(at: busyRoot) }
        let busy = try await open(.global, in: busySession); XCTAssertEqual(busy.cache?.isClearing, true); busy.confirmClearCache(); XCTAssertFalse(busy.showsConfirmation)
    }

    func test成员保护未知角色和候选身份不可顺带改写() async throws {
        let (root, _, _, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.members, in: session), original = value.members
        for member in original where !member.canEdit {
            value.remove(member); value.changeRole(member, to: .entry); value.setBackup(member, enabled: true)
        }
        XCTAssertEqual(value.members, original); XCTAssertNil(value.mutation)
        value.add(.init(id: .init(type: "user", value: .integer(999)), name: "Unknown"), role: .management); XCTAssertEqual(value.members, original)
        let member = try XCTUnwrap(value.members.first(where: \.canEdit)); value.setAllBackup(true)
        XCTAssertEqual(value.members.first(where: { $0.id == member.id })?.autoBackup, true)
        XCTAssertFalse(value.save()); XCTAssertTrue(value.confirmSave()); try await wait { !session.model.isManaging }
    }

    func test添加自定义成员与降级取消不留下成员或目录草稿() async throws {
        let (root, _, _, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.members, in: session), original = value.members
        let candidate = try XCTUnwrap(value.availableCandidates.first); value.add(candidate, role: .entry)
        try await wait { !value.folderLoading }; XCTAssertNotNil(value.folderTarget); XCTAssertEqual(value.members, original)
        value.cancelFolders(); XCTAssertEqual(value.members, original); XCTAssertNil(value.mutation)
        value.add(candidate, role: .management); let new = try XCTUnwrap(value.members.last)
        XCTAssertTrue(new.autoBackup); value.changeRole(new, to: .entry); try await wait { !value.folderLoading }
        value.cancelFolders(); XCTAssertEqual(value.members.last?.role, "management")
        value.changeRole(new, to: .entry); try await wait { !value.folderLoading }; XCTAssertTrue(value.finishFolders())
        XCTAssertEqual(value.members.last?.role, "entry"); XCTAssertEqual(value.members.last?.autoBackup, true)
    }

    func test目录草稿父目录撤权阻止子目录且公开下限保留() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.members, in: session), member = try XCTUnwrap(value.members.first(where: \.canEdit))
        value.beginFolders(member); try await wait { !value.folderLoading }
        let initial = try XCTUnwrap(value.folderDraft), parent = try XCTUnwrap(initial.original.first(where: { $0.id == 9 })), child = try XCTUnwrap(initial.original.first(where: { $0.id == 10 }))
        value.setFolderRole(nil, for: parent); XCTAssertEqual(value.folderDraft?.canEditFolder(child), false)
        value.setFolderRole(.manage, for: child); XCTAssertNil(value.folderDraft?.expectedRole(for: child))
        XCTAssertTrue(value.finishFolders()); XCTAssertFalse(value.save()); XCTAssertTrue(value.confirmSave()); try await wait { !session.model.isManaging }
        let folders = try await service.sharedSpaceMemberFolderSnapshot(for: member.id)
        XCTAssertNil(folders.first(where: { $0.id == 9 })?.directRole); XCTAssertNil(folders.first(where: { $0.id == 10 })?.directRole)
        XCTAssertEqual(folders.first(where: { $0.id == 11 })?.effectiveRole, .download)
    }

    func test连续目录批量修改保持草稿结果且只在主表单保存() async throws {
        let (root, _, service, session) = try await fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.members, in: session), member = try XCTUnwrap(value.members.first(where: \.canEdit))
        value.beginFolders(member); try await wait { !value.folderLoading }
        value.applyFolderBatch(.init(action: .checkAll, role: .manage)); value.applyFolderBatch(.init(action: .uncheckAll, role: .upload))
        XCTAssertTrue(value.finishFolders()); let before = await service.commands; XCTAssertTrue(before.isEmpty)
        XCTAssertFalse(value.save()); value.cancelConfirmation(); XCTAssertNotNil(value.mutation)
        XCTAssertFalse(value.save()); XCTAssertTrue(value.confirmSave()); try await wait { !session.model.isManaging }
        let folders = try await service.sharedSpaceMemberFolderSnapshot(for: member.id); XCTAssertTrue(folders.allSatisfy { $0.effectiveRole == .download })
    }

    func test管理员空内容读取失败禁用共享和无能力状态() async throws {
        for state in ["photo-admin-empty", "photo-admin-error", "photo-admin-disabled", "photo-admin-readonly", "photo-admin-folders-error", "photo-admin-candidates-error"] {
            let (root, _, _, session) = try await fixture(state); defer { try? FileManager.default.removeItem(at: root) }
            let value = try await open(.members, in: session)
            if state.hasSuffix("empty") { XCTAssertTrue(value.members.isEmpty); XCTAssertNil(value.mutation) }
            else if state == "photo-admin-error" { XCTAssertNotNil(value.error); XCTAssertFalse(value.editable) }
            else if state.hasSuffix("disabled") { XCTAssertEqual(value.originalMembers?.isEnabled, false); XCTAssertNil(value.mutation) }
            else if state.hasSuffix("readonly") { XCTAssertNil(value.draft); XCTAssertFalse(value.canOpen(.global)) }
            else if state == "photo-admin-candidates-error" {
                XCTAssertNotNil(value.candidatesError); let member = try XCTUnwrap(value.members.first(where: \.canEdit)); value.setBackup(member, enabled: true)
                XCTAssertNotNil(value.mutation, "候选读取失败不阻止既有成员编辑")
            } else {
                let member = try XCTUnwrap(value.members.first(where: \.canEdit)); value.beginFolders(member); try await wait { !value.folderLoading }
                XCTAssertNotNil(value.folderError); XCTAssertFalse(value.finishFolders()); XCTAssertNil(value.mutation)
            }
        }
    }

    func test管理员迟到读取不得回填另一会话() async throws {
        let (root, _, service, session) = try await fixture("photo-admin-held"); defer { try? FileManager.default.removeItem(at: root) }
        let value = try XCTUnwrap(session.administration); value.begin(.shared)
        for _ in 0..<100 { if await service.isControlHeld { break }; await Task.yield() }
        let held = await service.isControlHeld; XCTAssertTrue(held)
        session.configure(MobilePhotosUIService(state: "photo-admin")); await service.releaseControl(); await session.activate()
        for _ in 0..<10 { await Task.yield() }; XCTAssertNil(value.originalShared); XCTAssertNil(value.draft)
    }

    func test管理员三类未知保存重启仅查询恢复并阻止重复提交() async throws {
        for page in MobilePhotoAdministrationModel.Page.allCases {
            let (root, storage, service, session) = try await fixture("photo-admin-unknown"); defer { try? FileManager.default.removeItem(at: root) }
            let value = try await open(page, in: session)
            switch page {
            case .shared: value.sharedEnabled.insert(.publicRoot)
            case .global: value.globalEnabled.insert(.guestInfo)
            case .members: value.setAllBackup(true)
            }
            XCTAssertFalse(value.save()); XCTAssertTrue(value.confirmSave()); try await wait { !session.model.isManaging }; XCTAssertNotNil(session.model.pendingMutationID)
            session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
            let reopened = try await open(page, in: session); XCTAssertFalse(reopened.editable); XCTAssertNil(reopened.mutation)
            await service.setPending(false); session.model.reviewPendingMutation(); try await wait { !session.model.isManaging }
            XCTAssertNil(session.model.pendingMutationID); let commands = await service.commands; XCTAssertEqual(commands.count, 1)
        }
    }

    func test全局部分保存后新表单从最新快照继续() async throws {
        let (root, _, _, session) = try await fixture("photo-admin-partial"); defer { try? FileManager.default.removeItem(at: root) }
        let value = try await open(.global, in: session); value.globalEnabled.remove(.person)
        XCTAssertFalse(value.save()); XCTAssertTrue(value.confirmSave()); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); XCTAssertNotNil(session.model.managementMessage)
        _ = try await open(.global, in: session); XCTAssertEqual(value.originalGlobal?.values[.person], false)
        XCTAssertEqual(value.originalGlobal?.personalRecognition[.person], true); XCTAssertNotNil(value.mutation)
    }
}
