@testable import DsmMobile
import DsmCore
import DsmPhotosFeature
import Foundation
import XCTest

@MainActor
final class MobilePhotoSharingTests: XCTestCase {
    private func fixture(_ state: String = "photo-sharing") async throws -> (URL, MobilePhotoUploadStorage, MobilePhotosUIService, MobileSynologyPhotosSession) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mobile-photo-sharing-\(UUID().uuidString)")
        let storage = MobilePhotoUploadStorage(recordURL: root.appendingPathComponent("queue.json"))
        let service = MobilePhotosUIService(state: state), session = MobileSynologyPhotosSession()
        session.configure(service, uploadStorage: storage, reviewDelay: { _ in }); await session.activate()
        await session.model.selectSection(.albums)
        await session.model.open(try XCTUnwrap(session.model.collections.first))
        return (root, storage, service, session)
    }
    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<300 { if condition() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("等待分享操作结束超时")
    }
    private func open(_ session: MobileSynologyPhotosSession) async throws -> MobilePhotoSharingModel {
        let sharing = try XCTUnwrap(session.sharing); sharing.begin()
        try await wait { !sharing.isLoading && !sharing.loadingRecipients }
        return sharing
    }

    func test分享读取无更改零写且确认后密码原样只提交一次() async throws {
        let (root, storage, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await open(session)
        XCTAssertNotNil(sharing.original); XCTAssertNil(sharing.mutation); XCTAssertFalse(sharing.requestSave())
        sharing.access = .download; sharing.password.choice = .newPassword; sharing.password.password = " Synthetic 密码 "
        XCTAssertFalse(sharing.requestSave()); XCTAssertEqual(sharing.confirmationRisks, [.publicDownload])
        var commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        XCTAssertTrue(sharing.confirmSave()); XCTAssertFalse(sharing.confirmSave()); XCTAssertEqual(sharing.password.password, "")
        try await wait { !session.model.isManaging }
        commands = await service.commands; XCTAssertEqual(commands.count, 1)
        guard case .shareAlbum(let id, let access, let original, let members, let expiry, let password) = try XCTUnwrap(commands.first) else { return XCTFail("必须保存原相册分享") }
        XCTAssertEqual(id, 21); XCTAssertEqual(access, .download); XCTAssertEqual(original?.revision, "original")
        XCTAssertNil(members); XCTAssertNil(expiry); XCTAssertEqual(password, " Synthetic 密码 ")
        XCTAssertNotNil(session.model.managementLink)
        let store = PhotoAlbumRecoveryStore(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
        XCTAssertNil(try store.load())
    }

    func test数字用户与字符串群组分别加入且条件相册不能授予上传() async throws {
        for conditional in [false, true] {
            let (root, _, service, session) = try await fixture(conditional ? "photo-sharing-conditional" : "photo-sharing")
            defer { try? FileManager.default.removeItem(at: root) }
            let sharing = try await open(session)
            sharing.search = "No matching recipient"; XCTAssertTrue(sharing.availableRecipients.isEmpty); sharing.search = ""
            for recipient in sharing.recipients { sharing.add(recipient) }
            XCTAssertEqual(sharing.members.count, 2)
            sharing.members[0].role = "upload"
            XCTAssertEqual(sharing.mutation == nil, conditional)
            sharing.members[0].role = "download"
            XCTAssertFalse(sharing.requestSave()); XCTAssertEqual(sharing.confirmationRisks, [.memberAccess])
            XCTAssertTrue(sharing.confirmSave()); try await wait { !session.model.isManaging }
            let commands = await service.commands
            guard case .shareAlbum(_, .disabled, _, let members, _, _) = try XCTUnwrap(commands.first) else { return XCTFail("仅保存成员不能开启分享") }
            XCTAssertEqual(members?.map(\.id.type), ["user", "group"])
            XCTAssertEqual(members?.map(\.id.value), [.integer(31), .string("31")])
        }
    }

    func test原成员未知不作为空名单覆盖且未知保护须显式选择() async throws {
        let (root, _, service, session) = try await fixture("photo-sharing-members-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await open(session)
        XCTAssertNil(sharing.original?.members); XCTAssertTrue(sharing.recipients.isEmpty)
        sharing.access = .view
        XCTAssertFalse(sharing.requestSave()); XCTAssertTrue(sharing.confirmSave())
        try await wait { !session.model.isManaging }
        let commands = await service.commands
        guard case .shareAlbum(_, _, _, let members, let expiration, let password) = try XCTUnwrap(commands.first) else { return XCTFail("需要分享命令") }
        XCTAssertNil(members); XCTAssertNil(expiration); XCTAssertNil(password)
    }

    func test移除密码需明确确认且取消确认仍可继续编辑() async throws {
        let (root, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await open(session)
        sharing.password.choice = .remove
        XCTAssertFalse(sharing.requestSave()); XCTAssertEqual(sharing.confirmationRisks, [.passwordRemoved])
        sharing.cancelConfirmation(); XCTAssertNotNil(sharing.draft)
        XCTAssertFalse(sharing.confirmSave()); let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        sharing.cancel()
        XCTAssertNil(sharing.original); XCTAssertNil(sharing.draft); XCTAssertEqual(sharing.password.password, "")
    }

    func test确认后草稿变化不能提交旧权限或密码() async throws {
        let (root, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await open(session)
        sharing.access = .view; XCTAssertFalse(sharing.requestSave())
        sharing.access = .download
        XCTAssertFalse(sharing.confirmSave()); XCTAssertNotNil(sharing.error)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test旧账号表单与候选迟到读取不能改新会话() async throws {
        let (root, _, service, session) = try await fixture("photo-sharing-members-loading")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try XCTUnwrap(session.sharing); sharing.begin(); try await wait { !sharing.isLoading }
        XCTAssertTrue(sharing.loadingRecipients)
        sharing.password.choice = .newPassword; sharing.password.password = "draft-secret"
        session.configure(MobilePhotosUIService(state: "photo-sharing")); await session.activate()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(sharing.draft); XCTAssertEqual(sharing.password.password, ""); XCTAssertTrue(sharing.recipients.isEmpty)
        XCTAssertFalse(sharing.requestSave()); XCTAssertNil(session.sharing?.draft)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test分享提交前快照变化拒绝且不写入() async throws {
        let (root, _, service, session) = try await fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await open(session)
        sharing.expiration.choice = .date; sharing.expiration.date = Date().addingTimeInterval(172800); sharing.expiration.edited = true
        await service.changeSharing(.init(access: .view, revision: "changed", members: []))
        XCTAssertTrue(sharing.requestSave()); try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(session.model.managementLink)
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test分享未知跨重启保留原任务且不保存秘密或重放() async throws {
        let (root, storage, service, session) = try await fixture("photo-sharing-unknown")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await open(session)
        sharing.access = .view; sharing.password.choice = .newPassword; sharing.password.password = "draft-secret"
        XCTAssertFalse(sharing.requestSave()); XCTAssertTrue(sharing.confirmSave()); try await wait { !session.model.isManaging }
        let id = try XCTUnwrap(session.model.pendingMutationID)
        let store = PhotoAlbumRecoveryStore(url: storage.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json"))
        XCTAssertEqual(try store.load()?.version, 2)
        let text = try String(contentsOf: store.url, encoding: .utf8)
        XCTAssertFalse(text.contains("draft-secret")); XCTAssertFalse(text.contains("https://"))
        session.deactivate()
        let nextService = MobilePhotosUIService(profileID: service.profileID, state: "photo-sharing-unknown"), next = MobileSynologyPhotosSession()
        next.configure(nextService, uploadStorage: storage, reviewDelay: { _ in }); await next.activate()
        XCTAssertEqual(next.model.pendingMutationID, id); XCTAssertFalse(try XCTUnwrap(next.sharing).canOpen())
        next.model.reviewPendingMutation(); try await wait { !next.model.isManaging }
        XCTAssertEqual(next.model.pendingMutationID, id)
        let commands = await nextService.commands; XCTAssertTrue(commands.isEmpty)
    }

    func test分享部分完成保持关闭且用户可重新读取后修改() async throws {
        let (root, _, service, session) = try await fixture("photo-sharing-partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let sharing = try await open(session)
        sharing.access = .download; XCTAssertFalse(sharing.requestSave()); XCTAssertTrue(sharing.confirmSave())
        try await wait { !session.model.isManaging }
        XCTAssertNil(session.model.pendingMutationID); XCTAssertNil(session.model.managementLink)
        XCTAssertNil(session.model.retryableManagementMutation)
        let reopened = try await open(session); XCTAssertEqual(reopened.original?.access, .disabled)
        let commands = await service.commands; XCTAssertEqual(commands.count, 1)
    }

    func test分享现状与成员加载错误可以重试而只读贡献者不可编辑() async throws {
        for state in ["photo-sharing-error", "photo-sharing-members-error", "photo-sharing-members-empty", "photo-sharing-readonly", "photo-sharing-contributor"] {
            let (root, _, service, session) = try await fixture(state)
            defer { try? FileManager.default.removeItem(at: root) }
            let sharing = try await open(session)
            if ["photo-sharing-readonly", "photo-sharing-contributor"].contains(state) { XCTAssertNil(sharing.draft) }
            else if ["photo-sharing-error"].contains(state) { XCTAssertNotNil(sharing.error); XCTAssertNil(sharing.mutation) }
            else {
                XCTAssertTrue(sharing.recipients.isEmpty)
                XCTAssertEqual(sharing.recipientError != nil, state == "photo-sharing-members-error")
                sharing.access = .view; XCTAssertNotNil(sharing.mutation)
            }
            let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
        }
    }

    func test分享列表入口冻结原项目且切换范围后不能保存() async throws {
        let (root, _, service, session) = try await fixture("photo-sharing-existing")
        defer { try? FileManager.default.removeItem(at: root) }
        await session.model.selectSection(.sharing); await session.model.selectShareScope(.withOthers)
        let entry = try XCTUnwrap(session.model.sharedEntries.first), sharing = try XCTUnwrap(session.sharing)
        XCTAssertTrue(sharing.canOpen(entry: entry)); sharing.begin(entry: entry)
        try await wait { !sharing.isLoading }
        sharing.access = .disabled
        await session.model.selectShareScope(.withMe)
        XCTAssertNil(sharing.mutation); XCTAssertFalse(sharing.requestSave())
        let commands = await service.commands; XCTAssertTrue(commands.isEmpty)
    }
}
