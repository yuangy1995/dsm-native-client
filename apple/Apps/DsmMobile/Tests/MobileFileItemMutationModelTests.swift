@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

private actor FileItemMutationRepositoryStub: MobileFileItemMutating {
    enum Reply: Sendable {
        case outcome(FileItemMutationOutcome)
        case failure(StubError)
        case delayed(FileItemMutationOutcome)
    }

    enum StubError: Error, Sendable {
        case unexpected
    }

    nonisolated let profileID: UUID
    private var replies: [Reply]
    private(set) var calls: [String] = []

    init(profileID: UUID, replies: [Reply]) {
        self.profileID = profileID
        self.replies = replies
    }

    func createFolderResult(
        parentPath: String,
        name: String
    ) async throws -> FileItemMutationOutcome {
        calls.append("create:\(parentPath)/\(name)")
        return try await nextReply()
    }

    func renameResult(
        path: String,
        newName: String
    ) async throws -> FileItemMutationOutcome {
        calls.append("rename:\(path)->\(newName)")
        return try await nextReply()
    }

    func recordedCalls() -> [String] { calls }

    private func nextReply() async throws -> FileItemMutationOutcome {
        guard !replies.isEmpty else { throw StubError.unexpected }
        switch replies.removeFirst() {
        case .outcome(let outcome):
            return outcome
        case .failure(let error):
            throw error
        case .delayed(let outcome):
            try? await Task.sleep(nanoseconds: 50_000_000)
            return outcome
        }
    }
}

@MainActor
final class MobileFileItemMutationModelTests: XCTestCase {
    func test新建严格冻结profileRepository父目录并只提交一次() async throws {
        let profileID = UUID()
        let confirmed = item(profileID: profileID, name: "资料", path: "/share/资料", directory: true)
        let repository = FileItemMutationRepositoryStub(
            profileID: profileID,
            replies: [.outcome(try outcome(.confirmedSuccess, item: confirmed))]
        )
        let model = MobileFileItemMutationModel()
        model.activate(profileID: profileID, repository: repository)
        model.beginCreateFolder(parentPath: "/share", source: .browser, repository: repository)
        model.setName("资料")

        let success = await model.submit(repository: repository)

        XCTAssertEqual(success?.item, confirmed)
        XCTAssertEqual(success?.parentPath, "/share")
        XCTAssertFalse(model.isPresented)
        let calls = await repository.recordedCalls()
        XCTAssertEqual(calls, ["create:/share/资料"])
    }

    func test非法名称只读位置回收站与共享虚拟根均零写() async throws {
        let profileID = UUID()
        let repository = FileItemMutationRepositoryStub(profileID: profileID, replies: [])
        let model = MobileFileItemMutationModel()
        model.activate(profileID: profileID, repository: repository)

        for (path, source) in [
            ("", MobileFileLocationSource.shares),
            ("/share/#recycle", .browser),
            ("/remote", .remote),
            ("/share", .recycle),
        ] {
            model.beginCreateFolder(parentPath: path, source: source, repository: repository)
            XCTAssertFalse(model.isPresented)
        }
        model.beginCreateFolder(
            parentPath: "/remote/nested",
            source: .favorite,
            readOnlyRoots: ["/remote"],
            repository: repository
        )
        XCTAssertFalse(model.isPresented)
        model.beginCreateFolder(parentPath: "/share", source: .browser, repository: repository)
        for name in ["", " name", "name ", ".", "..", "a/b", "a\\b"] {
            model.setName(name)
            let result = await model.submit(repository: repository)
            XCTAssertNil(result, name)
            XCTAssertEqual(model.presentation?.feedback, .invalidName)
        }
        let calls = await repository.recordedCalls()
        XCTAssertTrue(calls.isEmpty)
    }

    func test确认成功仍须精确匹配profile路径名称与类型() async throws {
        let profileID = UUID()
        let wrong = item(profileID: profileID, name: "资料", path: "/share/其他", directory: true)
        let repository = FileItemMutationRepositoryStub(
            profileID: profileID,
            replies: [.outcome(try outcome(.confirmedSuccess, item: wrong))]
        )
        let model = MobileFileItemMutationModel()
        model.activate(profileID: profileID, repository: repository)
        model.beginCreateFolder(parentPath: "/share", source: .browser, repository: repository)
        model.setName("资料")

        let firstResult = await model.submit(repository: repository)
        XCTAssertNil(firstResult)
        XCTAssertEqual(model.presentation?.phase, .review)
        XCTAssertEqual(model.presentation?.name, "")
        let secondResult = await model.submit(repository: repository)
        XCTAssertNil(secondResult)
        let calls = await repository.recordedCalls()
        XCTAssertEqual(calls.count, 1)
    }

    func test未知结果提交后取消与意外异常都进入不可重试核对态() async throws {
        let profileID = UUID()
        let unverifiedRepository = FileItemMutationRepositoryStub(
            profileID: profileID,
            replies: [.outcome(try outcome(.submittedButUnverified))]
        )
        let unverifiedModel = MobileFileItemMutationModel()
        unverifiedModel.activate(profileID: profileID, repository: unverifiedRepository)
        unverifiedModel.beginCreateFolder(parentPath: "/share", source: .browser, repository: unverifiedRepository)
        unverifiedModel.setName("资料")
        let unverifiedResult = await unverifiedModel.submit(repository: unverifiedRepository)
        XCTAssertNil(unverifiedResult)
        XCTAssertEqual(unverifiedModel.presentation?.phase, .review)

        let throwingRepository = FileItemMutationRepositoryStub(
            profileID: profileID,
            replies: [.failure(.unexpected)]
        )
        let throwingModel = MobileFileItemMutationModel()
        throwingModel.activate(profileID: profileID, repository: throwingRepository)
        throwingModel.beginCreateFolder(parentPath: "/share", source: .browser, repository: throwingRepository)
        throwingModel.setName("资料")
        let throwingResult = await throwingModel.submit(repository: throwingRepository)
        XCTAssertNil(throwingResult)
        XCTAssertEqual(throwingModel.presentation?.phase, .review)
    }

    func test明确写前取消返回表单而不是核对态() async throws {
        let profileID = UUID()
        let repository = FileItemMutationRepositoryStub(
            profileID: profileID,
            replies: [.outcome(try outcome(.cancelledBeforeSubmission))]
        )
        let model = MobileFileItemMutationModel()
        model.activate(profileID: profileID, repository: repository)
        model.beginCreateFolder(parentPath: "/share", source: .browser, repository: repository)
        model.setName("资料")

        let result = await model.submit(repository: repository)
        XCTAssertNil(result)
        XCTAssertEqual(model.presentation?.phase, .editing)
        XCTAssertEqual(model.presentation?.name, "资料")
    }

    func test离页或切换profile会清空名称并拒绝迟到结果回写() async throws {
        let profileID = UUID()
        let confirmed = item(profileID: profileID, name: "资料", path: "/share/资料", directory: true)
        let repository = FileItemMutationRepositoryStub(
            profileID: profileID,
            replies: [.delayed(try outcome(.confirmedSuccess, item: confirmed))]
        )
        let model = MobileFileItemMutationModel()
        model.activate(profileID: profileID, repository: repository)
        model.beginCreateFolder(parentPath: "/share", source: .browser, repository: repository)
        model.setName("资料")
        let task = Task { await model.submit(repository: repository) }
        await Task.yield()

        model.deactivate()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(model.presentation)
        XCTAssertNil(model.activeProfileID)
    }

    func test重命名拒绝不同profile远程与非当前父目录项目() async {
        let profileID = UUID()
        let repository = FileItemMutationRepositoryStub(profileID: profileID, replies: [])
        let model = MobileFileItemMutationModel()
        model.activate(profileID: profileID, repository: repository)

        let remote = item(
            profileID: profileID,
            name: "remote",
            path: "/share/remote",
            directory: true,
            mountPointType: "cifs"
        )
        model.beginRename(item: remote, parentPath: "/share", source: .browser, repository: repository)
        XCTAssertFalse(model.isPresented)
        let foreign = item(profileID: UUID(), name: "a", path: "/share/a", directory: false)
        model.beginRename(item: foreign, parentPath: "/share", source: .browser, repository: repository)
        XCTAssertFalse(model.isPresented)
        let nested = item(profileID: profileID, name: "a", path: "/share/nested/a", directory: false)
        model.beginRename(item: nested, parentPath: "/share", source: .browser, repository: repository)
        XCTAssertFalse(model.isPresented)
    }

    private func outcome(
        _ status: MutationResultStatus,
        item: FileItem? = nil
    ) throws -> FileItemMutationOutcome {
        let submitted = ![.cancelledBeforeSubmission, .permissionDenied, .unsupported].contains(status)
        let requiresRefresh = status == .submittedButUnverified ||
            status == .cancellationRequestedAfterSubmission
        return FileItemMutationOutcome(
            result: try MutationResult(
                status: status,
                operation: "createFolder",
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                counts: MutationResultCounts(
                    succeeded: status == .confirmedSuccess ? 1 : 0,
                    failed: status == .permissionDenied || status == .unsupported ? 1 : 0,
                    unknown: requiresRefresh ? 1 : 0
                ),
                diagnosticTag: "mobile-file-item-mutation-test"
            ),
            item: item
        )
    }

    private func item(
        profileID: UUID,
        name: String,
        path: String,
        directory: Bool,
        mountPointType: String? = nil
    ) -> FileItem {
        FileItem(
            profileID: profileID,
            name: name,
            path: path,
            kind: directory ? .directory : .file,
            mountPointType: mountPointType
        )
    }
}
