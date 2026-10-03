import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileFileSharingExpansionTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() { roots.forEach { try? FileManager.default.removeItem(at: $0) }; roots = []; super.tearDown() }

    func test批量创建去重并保留成功链接和未知结果() async throws {
        let repository = SharingExpansionRepository()
        let first = item(repository.profileID, "first"), second = item(repository.profileID, "second")
        await repository.setCreateStatuses([.confirmedSuccess, .submittedButUnverified])
        let clipboard = SharingClipboard()
        let model = make(repository, clipboard: clipboard)
        model.begin(for: [first, second, first]); model.setPassword("synthetic-only"); model.submit(); model.submit()
        try await wait { model.state.phase == .batchResults }
        XCTAssertEqual(model.state.itemResults.map(\.status), [.confirmedSuccess, .submittedButUnverified])
        XCTAssertEqual(model.state.password, "")
        let calls = await repository.created
        XCTAssertEqual(calls.map(\.target.path), [first.path, second.path])
        model.copyLinks(model.state.itemResults.compactMap(\.link))
        XCTAssertEqual(clipboard.urls.count, 1)
        model.dismiss(); model.begin(for: second)
        XCTAssertEqual(model.state.phase, .reviewRequired)
    }

    func test文件收集需要可写目录及实际权限并携带日期和说明() async throws {
        let repository = SharingExpansionRepository()
        let model = make(repository)
        model.begin(for: item(repository.profileID, "folder", directory: true))
        try await wait { model.canCreateFileRequest }
        model.setFileRequest(true); model.setRequestName("Synthetic collection"); model.setRequestMessage("Synthetic message")
        let start = Date(timeIntervalSince1970: 1_798_761_600)
        model.setAvailableOn(start); model.setExpiration(.custom); model.setCustomExpiration(start.addingTimeInterval(86_400))
        XCTAssertTrue(model.canSubmit); model.submit()
        try await wait { model.state.phase == .confirmedSuccess }
        let calls = await repository.created
        XCTAssertEqual(calls.first?.fileRequest?.name, "Synthetic collection")
        XCTAssertEqual(calls.first?.fileRequest?.message, "Synthetic message")
        XCTAssertEqual(calls.first?.availableOn?.iso8601, "2027-01-01")
        XCTAssertEqual(calls.first?.expiresOn?.iso8601, "2027-01-02")
    }

    func test普通文件不可变为文件收集且日期倒置零请求() async throws {
        let repository = SharingExpansionRepository(), model = make(SharingExpansionRepository())
        model.activate(profileID: repository.profileID, repository: repository)
        model.begin(for: item(repository.profileID, "file")); model.setFileRequest(true)
        XCTAssertFalse(model.state.isFileRequest)
        model.setAvailableOn(Date(timeIntervalSince1970: 100_000)); model.setExpiration(.custom)
        model.setCustomExpiration(Date(timeIntervalSince1970: 0))
        XCTAssertFalse(model.canSubmit); model.submit()
        let calls = await repository.created
        XCTAssertTrue(calls.isEmpty)
    }

    func test未知创建重启后仍阻止重放且不保存密码() async throws {
        let repository = SharingExpansionRepository(), root = newRoot()
        await repository.setCreateStatuses([.submittedButUnverified])
        let target = item(repository.profileID, "pending")
        let first = make(repository, root: root)
        first.begin(for: target); first.setPassword("synthetic-only"); first.submit()
        try await wait { first.state.phase == .reviewRequired }
        let content = try String(contentsOf: root.appendingPathComponent("sharing-v1.json"), encoding: .utf8)
        XCTAssertFalse(content.contains("synthetic-only")); XCTAssertFalse(content.contains("password")); XCTAssertFalse(content.contains("https"))
        let restored = make(repository, root: root); restored.begin(for: target); restored.submit()
        XCTAssertEqual(restored.state.phase, .reviewRequired)
        let count = await repository.created.count
        XCTAssertEqual(count, 1)
    }

    func test损坏恢复文件保留且阻止提交() async throws {
        let repository = SharingExpansionRepository(), root = newRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("sharing-v1.json"), original = Data("corrupt synthetic record".utf8)
        try original.write(to: url)
        let model = make(repository, root: root)
        model.begin(for: item(repository.profileID, "file"))
        XCTAssertFalse(model.canSubmit); model.submit()
        XCTAssertEqual(model.state.phase, .confirmedFailure); XCTAssertEqual(model.state.failure, .recovery)
        XCTAssertEqual(try Data(contentsOf: url), original)
        let count = await repository.created.count
        XCTAssertEqual(count, 0)
    }

    func test相同配置标识的新账号上下文不继承旧账号待处理目标() async throws {
        let repository = SharingExpansionRepository()
        await repository.setCreateStatuses([.submittedButUnverified])
        let model = make(repository), target = item(repository.profileID, "file")
        model.begin(for: target); model.submit(); try await wait { model.state.phase == .reviewRequired }
        model.activate(profileID: repository.profileID, repository: repository, context: "different-account-context")
        model.begin(for: target)
        XCTAssertEqual(model.state.phase, .form)
    }

    func test全部链接完整读取超过旧五千条限制() async throws {
        let repository = SharingExpansionRepository()
        let links = (0..<5_001).map { link(String($0)) }
        await repository.setLinks(links)
        let model = make(repository); model.beginManagement()
        try await wait { model.state.phase == .managementContent }
        XCTAssertEqual(model.state.managedLinks.count, 5_001)
        XCTAssertFalse(model.state.managedLinksTruncated)
        let offsets = await repository.offsets
        XCTAssertEqual(offsets, stride(from: 0, through: 5_000, by: 500).map { $0 })
    }

    func test分页总量变化不当作完整列表() async throws {
        let repository = SharingExpansionRepository()
        await repository.setLinks((0..<501).map { link(String($0)) })
        await repository.setChangedTotal(true)
        let model = make(repository); model.beginManagement()
        try await wait { model.state.phase == .managementError }
        XCTAssertTrue(model.state.managedLinks.isEmpty)
    }

    func test批量编辑保留日期和原对象且未知结果阻止重启重放() async throws {
        let repository = SharingExpansionRepository(), root = newRoot(), original = link("editable")
        await repository.setLinks([original]); await repository.setEditStatuses([.submittedButUnverified])
        let model = make(repository, root: root); model.beginManagement()
        try await wait { model.state.phase == .managementContent }
        let request = try FileShareLinkEditRequest(baseline: original, password: .set("synthetic-only"), availableOn: nil,
                                                  expiresOn: nil, keepsAvailableDate: true, keepsExpirationDate: true)
        model.editManagedLinks([request]); model.editManagedLinks([request])
        try await wait { model.state.phase == .batchResults }
        XCTAssertEqual(model.state.itemResults.first?.status, .submittedButUnverified)
        let calls = await repository.edited
        XCTAssertEqual(calls.count, 1); XCTAssertEqual(calls.first?.baseline, original)
        XCTAssertEqual(calls.first?.keepsAvailableDate, true); XCTAssertEqual(calls.first?.keepsExpirationDate, true)
        let restored = make(repository, root: root); restored.beginManagement()
        try await wait { restored.state.phase == .managementContent }
        XCTAssertTrue(restored.state.blockedLinkIDs.contains(original.id))
        restored.editManagedLinks([request]); restored.beginDeleteManagedLink(original)
        XCTAssertEqual(restored.state.phase, .managementContent)
        let after = await repository.edited.count; XCTAssertEqual(after, 1)
    }

    func test编辑返回不同链接不能发布成功或复制() async throws {
        let repository = SharingExpansionRepository(), original = link("original")
        await repository.setLinks([original]); await repository.setWrongEditLink(link("other"))
        let clipboard = SharingClipboard(), model = make(repository, clipboard: clipboard)
        model.beginManagement(); try await wait { model.state.phase == .managementContent }
        model.editManagedLinks([try .init(baseline: original, availableOn: nil, expiresOn: nil)])
        try await wait { model.state.phase == .batchResults }
        XCTAssertEqual(model.state.itemResults.first?.status, .submittedButUnverified)
        XCTAssertNil(model.state.itemResults.first?.link)
        model.copyLinks(model.state.itemResults.compactMap(\.link)); XCTAssertTrue(clipboard.urls.isEmpty)
    }

    func test批量撤销只移除确实成功的项目() async throws {
        let repository = SharingExpansionRepository(), first = link("first"), second = link("second")
        await repository.setLinks([first, second]); await repository.setDeleteStatuses([.confirmedSuccess, .submittedButUnverified])
        let model = make(repository); model.beginManagement(); try await wait { model.state.phase == .managementContent }
        model.deleteManagedLinks([first, second]); model.deleteManagedLinks([first, second])
        try await wait { model.state.phase == .batchResults }
        XCTAssertEqual(model.state.managedLinks, [second])
        XCTAssertEqual(model.state.itemResults.map(\.status), [.confirmedSuccess, .submittedButUnverified])
        XCTAssertTrue(model.state.blockedLinkIDs.contains(second.id))
        let calls = await repository.deleted; XCTAssertEqual(calls, [first, second])
    }

    func test完整原快照不匹配时零编辑和撤销() async throws {
        let repository = SharingExpansionRepository(), original = link("same")
        await repository.setLinks([original])
        let model = make(repository); model.beginManagement(); try await wait { model.state.phase == .managementContent }
        let changed = FileShareLink(id: original.id, name: original.name, path: original.path, url: original.url,
                                   availableAt: "2027-01-01", status: .expired)
        model.beginDeleteManagedLink(changed)
        model.editManagedLinks([try .init(baseline: changed, availableOn: nil, expiresOn: nil)])
        XCTAssertEqual(model.state.phase, .managementContent)
        let edits = await repository.edited, deletes = await repository.deleted
        XCTAssertTrue(edits.isEmpty); XCTAssertTrue(deletes.isEmpty)
    }

    func test高级成员与访问限制原样绑定且不修改日期密码() async throws {
        let repository = SharingExpansionRepository(), original = link("advanced")
        await repository.setLinks([original])
        let model = make(repository); model.beginManagement(); try await wait { model.state.phase == .managementContent }
        let member = FileStationPrincipal(name: "synthetic-user", kind: .user)
        model.editManagedLinks([try .init(baseline: original, availableOn: nil, expiresOn: nil,
            advanced: .init(audience: .principals([member]), maximumAccesses: 5), keepsAvailableDate: true, keepsExpirationDate: true)])
        try await wait { model.state.phase == .batchResults }
        let request = await repository.edited.first
        XCTAssertEqual(request?.advanced?.maximumAccesses, 5)
        guard let request, case .keep = request.password, case .principals(let members) = request.advanced?.audience else {
            return XCTFail("必须保留密码意图与所选成员")
        }
        XCTAssertEqual(members, [member])
    }

    func test二维码在本机生成且批量复制保持全部链接() async throws {
        XCTAssertNotNil(MobileFileShareQRCodeView.image(for: "https://share.example.invalid/synthetic"))
        let repository = SharingExpansionRepository(), links = [link("one"), link("two")], clipboard = SharingClipboard()
        await repository.setLinks(links)
        let model = make(repository, clipboard: clipboard); model.beginManagement()
        try await wait { model.state.phase == .managementContent }
        model.copyLinks(links)
        XCTAssertEqual(clipboard.urls.map(\.absoluteString), links.map(\.url))
    }

    func test提交前权限拒绝可重新打开且不遗留未知阻断() async throws {
        let repository = SharingExpansionRepository(), model = make(SharingExpansionRepository())
        await repository.setCreateFailure(.permissionDenied)
        model.activate(profileID: repository.profileID, repository: repository)
        let target = item(repository.profileID, "permission")
        model.begin(for: target); model.submit()
        try await wait { model.state.phase == .confirmedFailure }
        XCTAssertEqual(model.state.failure, .permission)
        model.dismiss(); model.begin(for: target)
        XCTAssertEqual(model.state.phase, .form)
    }

    func test提交前取消重试返回表单且不会静默创建无密码链接() async throws {
        let repository = SharingExpansionRepository(), model = make(SharingExpansionRepository())
        await repository.setCreateStatuses([.cancelledBeforeSubmission])
        model.activate(profileID: repository.profileID, repository: repository)
        model.begin(for: item(repository.profileID, "cancel")); model.setPassword("synthetic-only"); model.submit()
        try await wait { model.state.phase == .confirmedFailure }
        model.retryCreation()
        XCTAssertEqual(model.state.phase, .form); XCTAssertEqual(model.state.password, "")
        let count = await repository.created.count
        XCTAssertEqual(count, 1)
    }

    func test撤销未知在完整列表缺失后解除阻断且重启保留结果() async throws {
        let repository = SharingExpansionRepository(), root = newRoot(), original = link("deleted")
        await repository.setLinks([original]); await repository.setDeleteStatuses([.submittedButUnverified])
        let model = make(repository, root: root); model.beginManagement(); try await wait { model.state.phase == .managementContent }
        model.beginDeleteManagedLink(original); model.confirmDeleteManagedLink()
        try await wait { model.state.phase == .deletionReviewRequired }
        await repository.setLinks([]); model.returnToManagement()
        try await wait { model.state.phase == .managementEmpty }
        let restored = make(repository, root: root); restored.beginManagement()
        try await wait { restored.state.phase == .managementEmpty }
        XCTAssertFalse(restored.state.blockedLinkIDs.contains(original.id))
        let count = await repository.deleted.count
        XCTAssertEqual(count, 1)
    }

    func test旧账号编辑迟到结果不会写入新账号展示() async throws {
        let old = SharingExpansionRepository(), current = SharingExpansionRepository(), original = link("old")
        await old.setLinks([original]); await old.setBlocksEdit(true)
        let model = make(old); model.beginManagement(); try await wait { model.state.phase == .managementContent }
        model.editManagedLinks([try .init(baseline: original, availableOn: nil, expiresOn: nil)])
        for _ in 0..<100 {
            if await old.editIsBlocked { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let blocked = await old.editIsBlocked; XCTAssertTrue(blocked)
        let replacement = link("current"); await current.setLinks([replacement])
        model.activate(profileID: current.profileID, repository: current); model.beginManagement()
        try await wait { model.state.phase == .managementContent }
        await old.releaseEdit(); await Task.yield()
        XCTAssertEqual(model.state.managedLinks, [replacement]); XCTAssertTrue(model.state.itemResults.isEmpty)
        let count = await current.edited.count; XCTAssertEqual(count, 0)
    }

    func test移除配置只清理该配置的恢复阻断() async throws {
        let first = SharingExpansionRepository(), second = SharingExpansionRepository(), root = newRoot()
        await first.setCreateStatuses([.submittedButUnverified]); await second.setCreateStatuses([.submittedButUnverified])
        let model = make(first, root: root)
        model.begin(for: item(first.profileID, "first")); model.submit(); try await wait { model.state.phase == .reviewRequired }
        model.activate(profileID: second.profileID, repository: second)
        model.begin(for: item(second.profileID, "second")); model.submit(); try await wait { model.state.phase == .reviewRequired }
        model.purge(profileID: first.profileID, removeRecovery: true)
        let restored = make(first, root: root); restored.begin(for: item(first.profileID, "first"))
        XCTAssertEqual(restored.state.phase, .form)
        restored.activate(profileID: second.profileID, repository: second); restored.begin(for: item(second.profileID, "second"))
        XCTAssertEqual(restored.state.phase, .reviewRequired)
    }

    func test批量包含旧未知目标时只提交其他新目标() async throws {
        let repository = SharingExpansionRepository(), model = make(SharingExpansionRepository())
        await repository.setCreateStatuses([.submittedButUnverified, .confirmedSuccess])
        model.activate(profileID: repository.profileID, repository: repository)
        let pending = item(repository.profileID, "pending"), next = item(repository.profileID, "next")
        model.begin(for: pending); model.submit(); try await wait { model.state.phase == .reviewRequired }
        model.dismiss(); model.begin(for: [pending, next]); model.submit()
        try await wait { model.state.phase == .batchResults }
        XCTAssertEqual(model.state.itemResults.map(\.status), [.submittedButUnverified, .confirmedSuccess])
        let calls = await repository.created
        XCTAssertEqual(calls.map(\.target.path), [pending.path, next.path])
        XCTAssertNil(model.state.target)
    }

    private func newRoot() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SharingExpansion-\(UUID())")
        roots.append(url); return url
    }
    private func make(_ repository: SharingExpansionRepository, root: URL? = nil, clipboard: any MobileClipboardWriting = SharingClipboard()) -> MobileFileShareLinkModel {
        let model = MobileFileShareLinkModel(clipboard: clipboard, rootURL: root ?? newRoot(), timeZone: { TimeZone(secondsFromGMT: 0)! })
        model.activate(profileID: repository.profileID, repository: repository); return model
    }
    private func item(_ profile: UUID, _ name: String, directory: Bool = false) -> FileItem {
        .init(profileID: profile, name: name, path: "/synthetic/" + name, kind: directory ? .directory : .file,
              permissions: .init(canRead: true, canWrite: true, canDelete: true, posixMode: nil))
    }
    private func link(_ id: String) -> FileShareLink {
        .init(id: id, name: id, path: "/synthetic/" + id, url: "https://share.example.invalid/" + id)
    }
    private func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        XCTFail("分享状态未完成")
    }
}

@MainActor
private final class SharingClipboard: MobileClipboardWriting {
    var urls: [URL] = []
    func copySensitiveURL(_ url: URL) { urls = [url] }
    func copySensitiveURLs(_ urls: [URL]) { self.urls = urls }
}

private actor SharingExpansionRepository: MobileFileShareLinkServing {
    nonisolated let profileID = UUID()
    nonisolated let fileShareLinkAvailability = FileShareLinkAvailability(status: .available, resolvedVersion: 3)
    var links: [FileShareLink] = []
    var created: [FileShareLinkCreateRequest] = []
    var edited: [FileShareLinkEditRequest] = []
    var deleted: [FileShareLink] = []
    var offsets: [Int] = []
    private var createStatuses: [MutationResultStatus] = []
    private var editStatuses: [MutationResultStatus] = []
    private var deleteStatuses: [MutationResultStatus] = []
    private var changedTotal = false
    private var wrongEditLink: FileShareLink?
    private var createFailure: AppErrorCategory?
    private var blocksEdit = false
    private var editContinuation: CheckedContinuation<Void, Never>?
    var editIsBlocked: Bool { editContinuation != nil }
    func setCreateFailure(_ value: AppErrorCategory) { createFailure = value }
    func setBlocksEdit(_ value: Bool) { blocksEdit = value }
    func releaseEdit() { editContinuation?.resume(); editContinuation = nil }
    func setLinks(_ value: [FileShareLink]) { links = value }
    func setCreateStatuses(_ value: [MutationResultStatus]) { createStatuses = value }
    func setEditStatuses(_ value: [MutationResultStatus]) { editStatuses = value }
    func setDeleteStatuses(_ value: [MutationResultStatus]) { deleteStatuses = value }
    func setChangedTotal(_ value: Bool) { changedTotal = value }
    func setWrongEditLink(_ value: FileShareLink) { wrongEditLink = value }
    func listShareLinksPage(offset: Int, limit: Int) async throws -> FileShareLinkPage {
        offsets.append(offset)
        let values = Array(links.dropFirst(offset).prefix(limit))
        return .init(links: values, offset: offset, total: links.count + (changedTotal && offset > 0 ? 1 : 0), hasMore: offset + values.count < links.count)
    }
    func loadFileStationAdvancedAccess() async throws -> FileStationAdvancedAccess { .init(isAdministrator: false, writesEnabled: true) }
    func listFileStationPrincipals(prefix: String, offset: Int, limit: Int) async throws -> FileStationPrincipalPage {
        .init(items: [], total: 0, nextOffset: 0)
    }
    func createShareLinkResult(_ request: FileShareLinkCreateRequest) async throws -> FileShareLinkCreateOutcome {
        created.append(request)
        if let createFailure { throw AppError(category: createFailure, isRetryable: false, safeUserMessage: "Synthetic failure") }
        let status = createStatuses.isEmpty ? .confirmedSuccess : createStatuses.removeFirst()
        let link = FileShareLink(id: request.target.name, name: request.target.name, path: request.target.path,
                                url: "https://share.example.invalid/" + request.target.name)
        if status == .confirmedSuccess { links.append(link) }
        return .init(result: try result(status), confirmedLink: status == .confirmedSuccess ? link : nil)
    }
    func editShareLink(_ request: FileShareLinkEditRequest) async throws -> FileShareLinkEditOutcome {
        edited.append(request)
        if blocksEdit { await withCheckedContinuation { editContinuation = $0 } }
        let status = editStatuses.isEmpty ? .confirmedSuccess : editStatuses.removeFirst()
        return .init(result: try result(status), confirmedLink: status == .confirmedSuccess ? wrongEditLink ?? request.baseline : nil)
    }
    func deleteShareLinkResult(_ link: FileShareLink) async throws -> MutationResult {
        deleted.append(link)
        let status = deleteStatuses.isEmpty ? .confirmedSuccess : deleteStatuses.removeFirst()
        if status == .confirmedSuccess { links.removeAll { $0.id == link.id } }
        return try result(status)
    }
    private func result(_ status: MutationResultStatus) throws -> MutationResult {
        let unknown = [.submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess].contains(status)
        return try .init(status: status, operation: "shareLinkCreate", submitted: status != .cancelledBeforeSubmission, requiresRefresh: unknown,
            counts: .init(succeeded: status == .confirmedSuccess ? 1 : 0, failed: status == .confirmedFailure ? 1 : 0, unknown: unknown ? 1 : 0),
            diagnosticTag: "synthetic.sharing")
    }
}
