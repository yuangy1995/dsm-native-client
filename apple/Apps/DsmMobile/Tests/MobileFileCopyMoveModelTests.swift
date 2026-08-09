@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

private actor FileCopyMoveRepositoryStub: MobileFileCopyMoving {
    enum Reply: Sendable {
        case outcome(FileCopyMoveOutcome)
        case delayed(FileCopyMoveOutcome)
        case failure
    }

    nonisolated let profileID: UUID
    private var pages: [String: FilePage]
    private var reply: Reply?
    private(set) var requests: [FileCopyMoveRequest] = []
    private(set) var listPaths: [String] = []
    private(set) var cancellationObserved = false

    init(profileID: UUID, pages: [String: FilePage], reply: Reply? = nil) {
        self.profileID = profileID
        self.pages = pages
        self.reply = reply
    }

    func listShares(offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        listPaths.append("")
        guard let page = pages[""] else { throw StubError.missingPage }
        return page
    }

    func listFolder(path: String, offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        listPaths.append(path)
        guard let page = pages[path] else { throw StubError.missingPage }
        return page
    }

    func copyMoveResult(
        _ request: FileCopyMoveRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileCopyMoveOutcome {
        requests.append(request)
        progress(5, 10)
        guard let reply else { throw StubError.missingReply }
        switch reply {
        case .outcome(let outcome): return outcome
        case .delayed(let outcome):
            do {
                try await Task.sleep(nanoseconds: 60_000_000)
                return outcome
            } catch {
                cancellationObserved = true
                throw error
            }
        case .failure: throw StubError.failed
        }
    }

    func recordedRequests() -> [FileCopyMoveRequest] { requests }
    func recordedListPaths() -> [String] { listPaths }
    func didObserveCancellation() -> Bool { cancellationObserved }

    enum StubError: Error { case missingPage, missingReply, failed }
}

@MainActor
final class MobileFileCopyMoveModelTests: XCTestCase {
    func test单文件复制冻结请求且overwrite恒为false并只提交一次() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/source/a.txt", .file, size: 10)
        let copied = item(profileID, "a.txt", "/target/a.txt", .file, size: 10)
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            reply: .outcome(try outcome(.confirmedSuccess, .copy, source, "/target", copied))
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        model.begin(
            operation: .copy,
            item: source,
            parentPath: "/source",
            source: .browser,
            visibleItems: [source],
            readOnlyRoots: [],
            repository: repository
        )
        await waitForBrowser(model)
        model.openFolder(item(profileID, "target", "/target", .directory), repository: repository)
        await waitForPath(model, "/target")

        let success = await model.submit(repository: repository)

        XCTAssertEqual(success?.item, copied)
        XCTAssertFalse(model.isPresented)
        let requests = await repository.recordedRequests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.profileID, profileID)
        XCTAssertEqual(request.source, source)
        XCTAssertEqual(request.destinationFolderPath, "/target")
        XCTAssertFalse(request.overwrite)
        XCTAssertEqual(requests.count, 1)
    }

    func test远程回收站目录外profile非当前revision与只读根均零入口零写() async {
        let profileID = UUID()
        let repository = FileCopyMoveRepositoryStub(profileID: profileID, pages: pages(profileID))
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        let file = item(profileID, "a.txt", "/source/a.txt", .file)
        let cases: [(FileItem, String, MobileFileLocationSource, [FileItem], [String])] = [
            (file, "/source", .remote, [file], []),
            (file, "/source", .recycle, [file], []),
            (item(profileID, "dir", "/source/dir", .directory), "/source", .browser, [], []),
            (item(UUID(), "a.txt", "/source/a.txt", .file), "/source", .browser, [], []),
            (file, "/source", .browser, [], []),
            (item(profileID, "unknown.txt", "/source/unknown.txt", .file, size: nil), "/source", .browser, [], []),
            (item(profileID, "a.txt", "/remote/a.txt", .file, mount: "cifs"), "/remote", .browser, [], []),
            (item(profileID, "a.txt", "/future/a.txt", .file, mount: "future_mount"), "/future", .browser, [], []),
            (file, "/source", .browser, [file], ["/source"]),
        ]
        for value in cases {
            model.begin(
                operation: .move,
                item: value.0,
                parentPath: value.1,
                source: value.2,
                visibleItems: value.3,
                readOnlyRoots: value.4,
                repository: repository
            )
            XCTAssertFalse(model.isPresented)
        }
        let requests = await repository.recordedRequests()
        let listPaths = await repository.recordedListPaths()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertTrue(listPaths.isEmpty)
    }

    func test目标浏览只返回普通本地目录并不改变源浏览状态() async {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/source/a.txt", .file)
        let remote = item(profileID, "remote", "/remote", .directory, mount: "nfs")
        let unknown = item(profileID, "future", "/future", .directory, mount: "future_mount")
        let recycle = item(profileID, "#recycle", "/share/#recycle", .directory)
        let file = item(profileID, "not-folder", "/not-folder", .file)
        let local = item(profileID, "target", "/target", .directory)
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: ["": page("", [remote, unknown, recycle, file, local])]
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        model.begin(
            operation: .copy,
            item: source,
            parentPath: "/source",
            source: .browser,
            visibleItems: [source],
            readOnlyRoots: ["/remote"],
            repository: repository
        )
        await waitForBrowser(model)

        XCTAssertEqual(model.presentation?.sourceParentPath, "/source")
        XCTAssertEqual(model.presentation?.destination.path, "")
        XCTAssertEqual(model.presentation?.destination.folders, [local])
    }

    func test未知结果异常与非严格成功建立跨模型blocker并禁止第二次写() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/source/a.txt", .file, size: 10)
        let blocker = MobileFileCopyMoveReviewBlocker()
        let firstRepository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            reply: .outcome(try outcome(.submittedButUnverified, .move, source, "/target", nil))
        )
        let first = MobileFileCopyMoveModel(blocker: blocker)
        first.activate(profileID: profileID, repository: firstRepository)
        await prepare(first, repository: firstRepository, source: source, operation: .move)
        let firstResult = await first.submit(repository: firstRepository)
        XCTAssertNil(firstResult)
        XCTAssertEqual(first.presentation?.phase, .review)

        let secondRepository = FileCopyMoveRepositoryStub(profileID: profileID, pages: pages(profileID))
        let second = MobileFileCopyMoveModel(blocker: blocker)
        second.activate(profileID: profileID, repository: secondRepository)
        await prepare(second, repository: secondRepository, source: source, operation: .move)
        let secondResult = await second.submit(repository: secondRepository)
        XCTAssertNil(secondResult)
        XCTAssertEqual(second.presentation?.phase, .review)
        let secondRequests = await secondRepository.recordedRequests()
        XCTAssertTrue(secondRequests.isEmpty)
    }

    func test仅明确写前取消返回目标浏览且保留目标() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/source/a.txt", .file)
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            reply: .outcome(try outcome(.cancelledBeforeSubmission, .copy, source, "/target", nil))
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        await prepare(model, repository: repository, source: source, operation: .copy)

        let result = await model.submit(repository: repository)
        XCTAssertNil(result)
        XCTAssertEqual(model.presentation?.phase, .browsing)
        XCTAssertEqual(model.presentation?.destination.path, "/target")
    }

    func test异常与伪确认成功均保守进入review且不能再次提交() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/source/a.txt", .file, size: 10)
        let wrong = item(profileID, "a.txt", "/other/a.txt", .file, size: 10)
        let wrongRepository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            reply: .outcome(try outcome(.confirmedSuccess, .copy, source, "/target", wrong))
        )
        let wrongModel = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        wrongModel.activate(profileID: profileID, repository: wrongRepository)
        await prepare(wrongModel, repository: wrongRepository, source: source, operation: .copy)
        let wrongResult = await wrongModel.submit(repository: wrongRepository)
        XCTAssertNil(wrongResult)
        XCTAssertEqual(wrongModel.presentation?.phase, .review)

        let failingRepository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            reply: .failure
        )
        let failingModel = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        failingModel.activate(profileID: profileID, repository: failingRepository)
        await prepare(failingModel, repository: failingRepository, source: source, operation: .move)
        let failure = await failingModel.submit(repository: failingRepository)
        let replay = await failingModel.submit(repository: failingRepository)
        XCTAssertNil(failure)
        XCTAssertNil(replay)
        XCTAssertEqual(failingModel.presentation?.phase, .review)
        let requests = await failingRepository.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func test切profile与离页取消请求且迟到结果零回写() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/source/a.txt", .file, size: 10)
        let copied = item(profileID, "a.txt", "/target/a.txt", .file, size: 10)
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            reply: .delayed(try outcome(.confirmedSuccess, .copy, source, "/target", copied))
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        await prepare(model, repository: repository, source: source, operation: .copy)
        let task = Task { await model.submit(repository: repository) }
        await waitForRequest(repository)

        model.deactivate()

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(model.presentation)
        XCTAssertNil(model.activeProfileID)
        let cancellationObserved = await repository.didObserveCancellation()
        XCTAssertTrue(cancellationObserved)
    }

    func test同profile更换repository也取消旧请求并拒绝迟到回写() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/source/a.txt", .file, size: 10)
        let copied = item(profileID, "a.txt", "/target/a.txt", .file, size: 10)
        let oldRepository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            reply: .delayed(try outcome(.confirmedSuccess, .copy, source, "/target", copied))
        )
        let replacement = FileCopyMoveRepositoryStub(profileID: profileID, pages: pages(profileID))
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: oldRepository)
        await prepare(model, repository: oldRepository, source: source, operation: .copy)
        let task = Task { await model.submit(repository: oldRepository) }
        await waitForRequest(oldRepository)

        model.activate(profileID: profileID, repository: replacement)

        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(model.presentation)
        XCTAssertEqual(model.activeProfileID, profileID)
        let cancellationObserved = await oldRepository.didObserveCancellation()
        XCTAssertTrue(cancellationObserved)
        let replacementRequests = await replacement.recordedRequests()
        XCTAssertTrue(replacementRequests.isEmpty)
    }

    private func prepare(
        _ model: MobileFileCopyMoveModel,
        repository: FileCopyMoveRepositoryStub,
        source: FileItem,
        operation: FileCopyMoveOperation
    ) async {
        model.begin(
            operation: operation,
            item: source,
            parentPath: "/source",
            source: .browser,
            visibleItems: [source],
            readOnlyRoots: [],
            repository: repository
        )
        await waitForBrowser(model)
        model.openFolder(item(repository.profileID, "target", "/target", .directory), repository: repository)
        await waitForPath(model, "/target")
    }

    private func waitForBrowser(_ model: MobileFileCopyMoveModel) async {
        for _ in 0..<100 {
            if model.presentation?.phase == .browsing { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("destination browser did not finish loading")
    }

    private func waitForPath(_ model: MobileFileCopyMoveModel, _ path: String) async {
        for _ in 0..<100 {
            if model.presentation?.phase == .browsing,
               model.presentation?.destination.path == path { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("destination path did not commit")
    }

    private func waitForRequest(_ repository: FileCopyMoveRepositoryStub) async {
        for _ in 0..<100 {
            if await repository.recordedRequests().count == 1 { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("copy or move request did not start")
    }

    private func pages(_ profileID: UUID) -> [String: FilePage] {
        let target = item(profileID, "target", "/target", .directory)
        return ["": page("", [target]), "/target": page("/target", [])]
    }

    private func page(_ path: String, _ items: [FileItem]) -> FilePage {
        FilePage(folderPath: path, items: items, offset: 0, total: items.count, hasMore: false)
    }

    private func outcome(
        _ status: MutationResultStatus,
        _ operation: FileCopyMoveOperation,
        _ source: FileItem,
        _ destination: String,
        _ item: FileItem?
    ) throws -> FileCopyMoveOutcome {
        let submitted = ![.cancelledBeforeSubmission, .permissionDenied, .unsupported].contains(status)
        let review = status == .submittedButUnverified || status == .cancellationRequestedAfterSubmission
        return FileCopyMoveOutcome(
            result: try MutationResult(
                status: status,
                operation: operation.rawValue,
                submitted: submitted,
                requiresRefresh: review,
                counts: try MutationResultCounts(
                    succeeded: status == .confirmedSuccess ? 1 : 0,
                    failed: status == .permissionDenied || status == .unsupported ? 1 : 0,
                    unknown: review ? 1 : 0
                ),
                diagnosticTag: "mobile-file-copy-move-test"
            ),
            sourcePath: source.path,
            destinationPath: destination + "/" + source.name,
            item: item
        )
    }

    private func item(
        _ profileID: UUID,
        _ name: String,
        _ path: String,
        _ kind: FileKind,
        size: Int64? = 10,
        mount: String? = nil
    ) -> FileItem {
        FileItem(
            profileID: profileID,
            name: name,
            path: path,
            kind: kind,
            sizeBytes: size,
            mountPointType: mount
        )
    }
}
