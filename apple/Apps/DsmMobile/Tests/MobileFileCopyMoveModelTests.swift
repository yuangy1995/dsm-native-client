@testable import DsmMobile
import DsmCore
import Foundation
import XCTest

private actor FileCopyMoveRepositoryStub: MobileFileCopyMoving {
    enum Reply: Sendable {
        case outcome(FileCopyMoveOutcome)
        case delayed(FileCopyMoveOutcome)
        case ignoresCancellation(FileCopyMoveOutcome)
        case failure
    }

    nonisolated let profileID: UUID
    private var pages: [String: FilePage]
    private var replies: [Reply]
    private(set) var requests: [FileCopyMoveRequest] = []
    private(set) var listPaths: [String] = []
    private(set) var cancellationObserved = false
    private(set) var offsets: [Int] = []

    init(profileID: UUID, pages: [String: FilePage], reply: Reply? = nil) {
        self.profileID = profileID
        self.pages = pages
        replies = reply.map { [$0] } ?? []
    }

    init(profileID: UUID, pages: [String: FilePage], replies: [Reply]) {
        self.profileID = profileID
        self.pages = pages
        self.replies = replies
    }

    func listShares(offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        listPaths.append("")
        offsets.append(offset)
        guard let page = pages["@\(offset)"] ?? pages[""] else { throw StubError.missingPage }
        return page
    }

    func listFolder(path: String, offset: Int, limit: Int, options: FileListOptions) async throws -> FilePage {
        listPaths.append(path)
        offsets.append(offset)
        guard let page = pages["\(path)@\(offset)"] ?? pages[path] else { throw StubError.missingPage }
        return page
    }

    func copyMoveResult(
        _ request: FileCopyMoveRequest,
        progress: @escaping FileTransferProgress
    ) async throws -> FileCopyMoveOutcome {
        requests.append(request)
        progress(5, 10)
        guard !replies.isEmpty else { throw StubError.missingReply }
        let reply = replies.removeFirst()
        switch reply {
        case .outcome(let outcome): return outcome
        case .ignoresCancellation(let outcome):
            try? await Task.sleep(nanoseconds: 100_000_000)
            return outcome
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

    func test单文件夹复制不依赖目录大小且复用同一写链路() async throws {
        let profileID = UUID()
        let source = item(profileID, "folder", "/source/folder", .directory, size: nil)
        let copied = item(profileID, "folder", "/target/folder", .directory, size: 999)
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
        let request = requests.first
        XCTAssertEqual(request?.source, source)
        XCTAssertEqual(request?.destinationFolderPath, "/target")
        XCTAssertFalse(request?.overwrite ?? true)
    }

    func test文件夹目标浏览排除源目录子树且源父目录不可提交() async {
        let profileID = UUID()
        let source = item(profileID, "folder", "/source/folder", .directory, size: nil)
        let sourceRoot = item(profileID, "source", "/source", .directory)
        let sibling = item(profileID, "sibling", "/source/sibling", .directory)
        let target = item(profileID, "target", "/target", .directory)
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: [
                "": page("", [sourceRoot, target]),
                "/source": page("/source", [source, sibling]),
                "/target": page("/target", []),
            ]
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        model.begin(
            operation: .move,
            item: source,
            parentPath: "/source",
            source: .browser,
            visibleItems: [source],
            readOnlyRoots: [],
            repository: repository
        )
        await waitForBrowser(model)
        model.openFolder(sourceRoot, repository: repository)
        await waitForPath(model, "/source")

        XCTAssertEqual(model.presentation?.destination.folders, [sibling])
        XCTAssertEqual(model.presentation?.canSubmitDestination, false)
        let result = await model.submit(repository: repository)
        XCTAssertNil(result)
        XCTAssertEqual(model.presentation?.feedback, .invalidDestination)
        let requests = await repository.recordedRequests()
        XCTAssertTrue(requests.isEmpty)
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

    func test单项明确失败保持旧浏览态与反馈() async throws {
        let profileID = UUID()
        let source = item(profileID, "a.txt", "/source/a.txt", .file)
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            reply: .outcome(try outcome(.confirmedFailure, .move, source, "/target", nil))
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        await prepare(model, repository: repository, source: source, operation: .move)

        let success = await model.submit(repository: repository)

        XCTAssertNil(success)
        XCTAssertEqual(model.presentation?.phase, .browsing)
        XCTAssertEqual(model.presentation?.feedback, .failed)
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

    func test批次入口冻结顺序去重并拒绝空批次超限与任一非法项() async {
        let profileID = UUID()
        let first = item(profileID, "a.txt", "/source/a.txt", .file, size: 1)
        let second = item(profileID, "b.txt", "/source/b.txt", .file, size: 2)
        let invalid = item(profileID, "link", "/source/link", .symlink)
        let repository = FileCopyMoveRepositoryStub(profileID: profileID, pages: pages(profileID))
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)

        model.begin(
            operation: .copy,
            items: [second, first, second],
            parentPath: "/source",
            source: .browser,
            visibleItems: [first, second, invalid],
            readOnlyRoots: [],
            repository: repository
        )
        XCTAssertEqual(model.presentation?.sources, [second, first])
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.notStarted, .notStarted])
        XCTAssertEqual(model.presentation?.batchCounts.total, 2)
        model.dismiss()

        model.begin(
            operation: .move,
            items: [],
            parentPath: "/source",
            source: .browser,
            visibleItems: [first],
            readOnlyRoots: [],
            repository: repository
        )
        XCTAssertNil(model.presentation)

        let tooMany = (0...20).map { item(profileID, "\($0).txt", "/source/\($0).txt", .file) }
        model.begin(
            operation: .move,
            items: tooMany,
            parentPath: "/source",
            source: .browser,
            visibleItems: tooMany,
            readOnlyRoots: [],
            repository: repository
        )
        XCTAssertNil(model.presentation)

        model.begin(
            operation: .move,
            items: [first, invalid],
            parentPath: "/source",
            source: .browser,
            visibleItems: [first, invalid],
            readOnlyRoots: [],
            repository: repository
        )
        XCTAssertNil(model.presentation)
    }

    func test批次严格串行明确失败继续并返回全部确认刷新项() async throws {
        let profileID = UUID()
        let sources = [
            item(profileID, "a.txt", "/source/a.txt", .file, size: 1),
            item(profileID, "b.txt", "/source/b.txt", .file, size: 2),
            item(profileID, "c.txt", "/source/c.txt", .file, size: 3),
            item(profileID, "d.txt", "/source/d.txt", .file, size: 4),
        ]
        let confirmed = item(profileID, "b.txt", "/target/b.txt", .file, size: 2)
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            replies: [
                .outcome(try outcome(.confirmedFailure, .copy, sources[0], "/target", nil)),
                .outcome(try outcome(.confirmedSuccess, .copy, sources[1], "/target", confirmed)),
                .outcome(try outcome(.permissionDenied, .copy, sources[2], "/target", nil)),
                .outcome(try outcome(.unsupported, .copy, sources[3], "/target", nil)),
            ]
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        await prepareBatch(model, repository: repository, sources: sources, operation: .copy)

        let success = await model.submit(repository: repository)

        XCTAssertEqual(success?.confirmedItems, [confirmed])
        XCTAssertEqual(model.presentation?.phase, .completed)
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.failed, .confirmed, .failed, .failed])
        XCTAssertEqual(
            model.presentation?.batchCounts,
            MobileFileCopyMoveBatchCounts(confirmed: 1, failed: 3, pendingReview: 0, cancelled: 0, notStarted: 0)
        )
        let requests = await repository.recordedRequests()
        XCTAssertEqual(requests.map(\.source), sources)
        XCTAssertTrue(requests.allSatisfy { !$0.overwrite && $0.destinationFolderPath == "/target" })
    }

    func test批次未知结果停止余项建立稳定目标blocker且绝不重放() async throws {
        let profileID = UUID()
        let sources = [
            item(profileID, "a.txt", "/source/a.txt", .file, size: 1),
            item(profileID, "b.txt", "/source/b.txt", .file, size: 2),
            item(profileID, "c.txt", "/source/c.txt", .file, size: 3),
        ]
        let confirmed = item(profileID, "a.txt", "/target/a.txt", .file, size: 1)
        let blocker = MobileFileCopyMoveReviewBlocker()
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            replies: [
                .outcome(try outcome(.confirmedSuccess, .move, sources[0], "/target", confirmed)),
                .outcome(try outcome(.submittedButUnverified, .move, sources[1], "/target", nil)),
                .outcome(try outcome(.confirmedSuccess, .move, sources[2], "/target", nil)),
            ]
        )
        let model = MobileFileCopyMoveModel(blocker: blocker)
        model.activate(profileID: profileID, repository: repository)
        await prepareBatch(model, repository: repository, sources: sources, operation: .move)

        let success = await model.submit(repository: repository)
        let replay = await model.submit(repository: repository)

        XCTAssertEqual(success?.confirmedItems, [confirmed])
        XCTAssertNil(replay)
        XCTAssertEqual(model.presentation?.phase, .review)
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.confirmed, .pendingReview, .notStarted])
        XCTAssertEqual(model.presentation?.batchCounts.total, sources.count)
        let requests = await repository.recordedRequests()
        XCTAssertEqual(requests.map(\.source), Array(sources.prefix(2)))

        let blockedRepository = FileCopyMoveRepositoryStub(profileID: profileID, pages: pages(profileID))
        let refreshedBlockedSource = item(
            profileID,
            "b.txt",
            "/source/b.txt",
            .file,
            size: 200
        )
        let blockedModel = MobileFileCopyMoveModel(blocker: blocker)
        blockedModel.activate(profileID: profileID, repository: blockedRepository)
        await prepareBatch(
            blockedModel,
            repository: blockedRepository,
            sources: [refreshedBlockedSource, sources[2]],
            operation: .move
        )
        let blockedSuccess = await blockedModel.submit(repository: blockedRepository)
        XCTAssertNil(blockedSuccess)
        XCTAssertEqual(blockedModel.presentation?.phase, .review)
        XCTAssertEqual(blockedModel.presentation?.itemStates.map(\.status), [.pendingReview, .notStarted])
        let blockedRequests = await blockedRepository.recordedRequests()
        XCTAssertTrue(blockedRequests.isEmpty)
    }

    func test批次所有提交后不确定状态均只进入review并停止余项() async throws {
        for status in [
            MutationResultStatus.submittedButUnverified,
            .cancellationRequestedAfterSubmission,
            .partialSuccess,
        ] {
            let profileID = UUID()
            let sources = [
                item(profileID, "a.txt", "/source/a.txt", .file),
                item(profileID, "b.txt", "/source/b.txt", .file),
            ]
            let repository = FileCopyMoveRepositoryStub(
                profileID: profileID,
                pages: pages(profileID),
                replies: [
                    .outcome(try outcome(status, .copy, sources[0], "/target", nil)),
                    .outcome(try outcome(.confirmedSuccess, .copy, sources[1], "/target", nil)),
                ]
            )
            let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
            model.activate(profileID: profileID, repository: repository)
            await prepareBatch(model, repository: repository, sources: sources, operation: .copy)

            let success = await model.submit(repository: repository)

            XCTAssertNil(success, "status: \(status)")
            XCTAssertEqual(model.presentation?.phase, .review, "status: \(status)")
            XCTAssertEqual(
                model.presentation?.itemStates.map(\.status),
                [.pendingReview, .notStarted],
                "status: \(status)"
            )
            let requestCount = await repository.recordedRequests().count
            XCTAssertEqual(requestCount, 1, "status: \(status)")
        }
    }

    func test批次写前取消停止余项并保持结果守恒() async throws {
        let profileID = UUID()
        let sources = [
            item(profileID, "a.txt", "/source/a.txt", .file),
            item(profileID, "b.txt", "/source/b.txt", .file),
            item(profileID, "c.txt", "/source/c.txt", .file),
        ]
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            replies: [
                .outcome(try outcome(.cancelledBeforeSubmission, .copy, sources[0], "/target", nil)),
                .outcome(try outcome(.confirmedSuccess, .copy, sources[1], "/target", nil)),
            ]
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        await prepareBatch(model, repository: repository, sources: sources, operation: .copy)

        let success = await model.submit(repository: repository)
        XCTAssertNil(success)
        XCTAssertEqual(model.presentation?.phase, .completed)
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.cancelled, .notStarted, .notStarted])
        XCTAssertEqual(
            model.presentation?.batchCounts,
            MobileFileCopyMoveBatchCounts(confirmed: 0, failed: 0, pendingReview: 0, cancelled: 1, notStarted: 2)
        )
        let requests = await repository.recordedRequests()
        XCTAssertEqual(requests.count, 1)
    }

    func test批次全明确失败仍进入完成摘要且不返回刷新项() async throws {
        let profileID = UUID()
        let sources = [
            item(profileID, "a.txt", "/source/a.txt", .file),
            item(profileID, "b.txt", "/source/b.txt", .file),
        ]
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            replies: [
                .outcome(try outcome(.permissionDenied, .move, sources[0], "/target", nil)),
                .outcome(try outcome(.confirmedFailure, .move, sources[1], "/target", nil)),
            ]
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        await prepareBatch(model, repository: repository, sources: sources, operation: .move)

        let success = await model.submit(repository: repository)

        XCTAssertNil(success)
        XCTAssertEqual(model.presentation?.phase, .completed)
        XCTAssertEqual(
            model.presentation?.batchCounts,
            MobileFileCopyMoveBatchCounts(confirmed: 0, failed: 2, pendingReview: 0, cancelled: 0, notStarted: 0)
        )
        let requestCount = await repository.recordedRequests().count
        XCTAssertEqual(requestCount, 2)
    }

    func test批次异常记待核对并停止且切换repository隔离迟到结果() async throws {
        let profileID = UUID()
        let sources = [
            item(profileID, "a.txt", "/source/a.txt", .file),
            item(profileID, "b.txt", "/source/b.txt", .file),
        ]
        let repository = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            replies: [.failure, .outcome(try outcome(.confirmedSuccess, .move, sources[1], "/target", nil))]
        )
        let model = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        model.activate(profileID: profileID, repository: repository)
        await prepareBatch(model, repository: repository, sources: sources, operation: .move)

        let success = await model.submit(repository: repository)
        XCTAssertNil(success)
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.pendingReview, .notStarted])
        let failedRequestCount = await repository.recordedRequests().count
        XCTAssertEqual(failedRequestCount, 1)

        let delayed = FileCopyMoveRepositoryStub(
            profileID: profileID,
            pages: pages(profileID),
            reply: .delayed(try outcome(.confirmedSuccess, .copy, sources[0], "/target", item(profileID, "a.txt", "/target/a.txt", .file)))
        )
        let replacement = FileCopyMoveRepositoryStub(profileID: profileID, pages: pages(profileID))
        let lateModel = MobileFileCopyMoveModel(blocker: MobileFileCopyMoveReviewBlocker())
        lateModel.activate(profileID: profileID, repository: delayed)
        await prepareBatch(lateModel, repository: delayed, sources: sources, operation: .copy)
        let task = Task { await lateModel.submit(repository: delayed) }
        await waitForRequest(delayed)
        XCTAssertEqual(lateModel.presentation?.currentItemIndex, 0)
        XCTAssertEqual(lateModel.presentation?.currentItemNumber, 1)
        XCTAssertEqual(lateModel.presentation?.currentSource, sources[0])
        XCTAssertEqual(lateModel.presentation?.completedBytes, 5)
        XCTAssertEqual(lateModel.presentation?.totalBytes, 10)
        lateModel.activate(profileID: profileID, repository: replacement)

        let lateSuccess = await task.value
        XCTAssertNil(lateSuccess)
        XCTAssertNil(lateModel.presentation)
        let delayedRequestCount = await delayed.recordedRequests().count
        let cancellationObserved = await delayed.didObserveCancellation()
        XCTAssertEqual(delayedRequestCount, 1)
        XCTAssertTrue(cancellationObserved)
    }

    func test批次混合文件和无大小目录逐项提交并保留全部结果() async throws {
        let id = UUID(), folder = item(UUID(), "unused", "/unused", .directory)
        let sources = [item(id, "Folder", "/source/Folder", .directory, size: nil), item(id, "a.txt", "/source/a.txt", .file)]
        let outputs = [item(id, "Folder", "/target/Folder", .directory, size: nil), item(id, "a.txt", "/target/a.txt", .file)]
        let repository = FileCopyMoveRepositoryStub(profileID: id, pages: pages(id), replies: try zip(sources, outputs).map {
            .outcome(try outcome(.confirmedSuccess, .copy, $0.0, "/target", $0.1))
        })
        let model = MobileFileCopyMoveModel(blocker: .init()); model.activate(profileID: id, repository: repository)
        await prepareBatch(model, repository: repository, sources: sources, operation: .copy)
        let success = await model.submit(repository: repository)
        XCTAssertEqual(success?.confirmedItems, outputs)
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.confirmed, .confirmed])
        let requests = await repository.recordedRequests()
        XCTAssertEqual(requests.map(\.source), sources); XCTAssertTrue(requests.allSatisfy { !$0.overwrite })
        XCTAssertFalse(MobileFileCopyMoveModel.canBeginBatchItem(item: folder, parentPath: "/source", source: .browser,
            visibleItems: [folder], readOnlyRoots: [], profileID: id))
    }

    func test目标第一页和中间页都无可选目录仍可加载后续目录() async {
        let id = UUID()
        let original = item(id, "a.txt", "/source/a.txt", .file)
        let excluded = item(id, "remote", "/remote", .directory, mount: "cifs")
        let file = item(id, "file", "/file", .file)
        let folder = item(id, "target", "/target", .directory)
        let repository = FileCopyMoveRepositoryStub(profileID: id, pages: [
            "@0": FilePage(folderPath: "/", items: [excluded], offset: 0, total: 3, hasMore: true),
            "@1": FilePage(folderPath: "/", items: [file], offset: 1, total: 3, hasMore: true),
            "@2": FilePage(folderPath: "/", items: [folder], offset: 2, total: 3, hasMore: false)
        ])
        let model = MobileFileCopyMoveModel(blocker: .init()); model.activate(profileID: id, repository: repository)
        model.begin(operation: .copy, item: original, parentPath: "/source", source: .browser,
            visibleItems: [original], readOnlyRoots: [], repository: repository)
        await waitForBrowser(model)
        XCTAssertEqual(model.presentation?.destination.pageState, .content)
        XCTAssertEqual(model.presentation?.destination.folders, [])
        model.loadMore(repository: repository)
        for _ in 0..<100 where model.presentation?.destination.isLoadingMore == true { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(model.presentation?.destination.nextOffset, 2)
        XCTAssertEqual(model.presentation?.destination.loadMoreFailed, false)
        model.loadMore(repository: repository)
        for _ in 0..<100 where model.presentation?.destination.isLoadingMore == true { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertEqual(model.presentation?.destination.folders, [folder])
        XCTAssertEqual(model.presentation?.destination.hasMore, false)
        let offsets = await repository.offsets; XCTAssertEqual(offsets, [0, 1, 2])
    }

    func test提交前落盘且中断重启保留限制不能重放() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let source = item(id, "a.txt", "/source/a.txt", .file)
        let repository = FileCopyMoveRepositoryStub(profileID: id, pages: pages(id), reply:
            .delayed(try outcome(.submittedButUnverified, .move, source, "/target", nil)))
        let model = MobileFileCopyMoveModel(blocker: .init(rootURL: root)); model.activate(profileID: id, repository: repository, context: "account-a")
        await prepare(model, repository: repository, source: source, operation: .move)
        let task = Task { await model.submit(repository: repository) }; await waitForRequest(repository)
        let data = try Data(contentsOf: root.appendingPathComponent("pending-v1.json"))
        XCTAssertFalse(data.isEmpty); XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("password"))
        model.deactivate(); _ = await task.value
        let second = FileCopyMoveRepositoryStub(profileID: id, pages: pages(id))
        let restored = MobileFileCopyMoveModel(blocker: .init(rootURL: root)); restored.activate(profileID: id, repository: second, context: "account-a")
        await prepare(restored, repository: second, source: source, operation: .move)
        let result = await restored.submit(repository: second)
        XCTAssertNil(result); XCTAssertEqual(restored.presentation?.phase, .review)
        let requests = await second.recordedRequests(); XCTAssertTrue(requests.isEmpty)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("pending-v1.json")), data)
    }

    func test持久限制绑定账号并阻止改目标和源子树但不阻止其他文件() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), other = UUID()
        func key(_ source: String, _ target: String = "/target", context: String = "account-a", profile: UUID? = nil) -> MobileFileCopyMoveReviewKey {
            .init(profileID: profile ?? id, context: context, operation: .move, sourcePath: source, destinationFolderPath: target)
        }
        let first = MobileFileCopyMoveReviewBlocker(rootURL: root)
        XCTAssertTrue(first.insert(key("/source/Folder")))
        XCTAssertTrue(first.insert(key("/other/a", profile: other)))
        let restored = MobileFileCopyMoveReviewBlocker(rootURL: root)
        XCTAssertTrue(restored.contains(key("/source/Folder", "/another")))
        XCTAssertTrue(restored.contains(key("/source/Folder/a")))
        XCTAssertTrue(restored.contains(key("/target/Folder/a")))
        XCTAssertFalse(restored.contains(key("/source/Folder", context: "account-b")))
        XCTAssertFalse(restored.contains(key("/source/Folder2")))
        restored.purge(profileID: id)
        let remaining = MobileFileCopyMoveReviewBlocker(rootURL: root)
        XCTAssertFalse(remaining.contains(key("/source/Folder")))
        XCTAssertTrue(remaining.contains(key("/other/a", profile: other)))
    }

    func test损坏或不可写恢复记录保留原件并零请求() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let bad = parent.appendingPathComponent("bad"), blocked = parent.appendingPathComponent("blocked")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        let original = Data("not-json".utf8); try original.write(to: bad.appendingPathComponent("pending-v1.json")); try original.write(to: blocked)
        for root in [bad, blocked] {
            let id = UUID()
            let entry = item(id, "a.txt", "/source/a.txt", .file)
            let repository = FileCopyMoveRepositoryStub(profileID: id, pages: pages(id))
            let model = MobileFileCopyMoveModel(blocker: .init(rootURL: root)); model.activate(profileID: id, repository: repository)
            await prepare(model, repository: repository, source: entry, operation: .copy)
            let result = await model.submit(repository: repository)
            XCTAssertNil(result); XCTAssertEqual(model.presentation?.feedback, .recovery)
            let requests = await repository.recordedRequests(); XCTAssertTrue(requests.isEmpty)
        }
        XCTAssertEqual(try Data(contentsOf: bad.appendingPathComponent("pending-v1.json")), original)
        XCTAssertEqual(try Data(contentsOf: blocked), original)
    }

    func test取消后当前项明确成功仍停止未开始项且清除完成记录() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let entries = ["a.txt", "b.txt"].map { item(id, $0, "/source/" + $0, .file) }
        let copied = item(id, "a.txt", "/target/a.txt", .file)
        let repository = FileCopyMoveRepositoryStub(profileID: id, pages: pages(id), reply:
            .ignoresCancellation(try outcome(.confirmedSuccess, .copy, entries[0], "/target", copied)))
        let model = MobileFileCopyMoveModel(blocker: .init(rootURL: root)); model.activate(profileID: id, repository: repository)
        await prepareBatch(model, repository: repository, sources: entries, operation: .copy)
        let task = Task { await model.submit(repository: repository) }; await waitForRequest(repository); model.requestCancellation()
        let result = await task.value
        XCTAssertEqual(result?.confirmedItems, [copied]); XCTAssertEqual(model.presentation?.phase, .completed)
        XCTAssertEqual(model.presentation?.itemStates.map(\.status), [.confirmed, .notStarted])
        let requests = await repository.recordedRequests(); XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(MobileFileCopyMoveReviewBlocker(rootURL: root).contains(.init(profileID: id, context: id.uuidString,
            operation: .copy, sourcePath: entries[0].path, destinationFolderPath: "/target")))
    }

    func test迟到成功只清理原记录不改写新界面且旧按钮无新写() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let entry = item(id, "a.txt", "/source/a.txt", .file), copied = item(id, "a.txt", "/target/a.txt", .file)
        let repository = FileCopyMoveRepositoryStub(profileID: id, pages: pages(id), reply:
            .ignoresCancellation(try outcome(.confirmedSuccess, .copy, entry, "/target", copied)))
        let model = MobileFileCopyMoveModel(blocker: .init(rootURL: root)); model.activate(profileID: id, repository: repository)
        await prepare(model, repository: repository, source: entry, operation: .copy)
        let token = model.activation, task = Task { await model.submit(repository: repository) }; await waitForRequest(repository)
        let replacement = FileCopyMoveRepositoryStub(profileID: id, pages: pages(id))
        model.activate(profileID: id, repository: replacement, context: "other-account")
        let oldResult = await task.value; XCTAssertNil(oldResult); XCTAssertNil(model.presentation)
        XCTAssertFalse(MobileFileCopyMoveReviewBlocker(rootURL: root).contains(.init(profileID: id, context: id.uuidString,
            operation: .copy, sourcePath: entry.path, destinationFolderPath: "/target")))
        await prepare(model, repository: replacement, source: entry, operation: .copy)
        let stale = await model.submit(repository: replacement, expectedActivation: token)
        XCTAssertNil(stale); let writes = await replacement.recordedRequests(); XCTAssertTrue(writes.isEmpty)
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

    private func prepareBatch(
        _ model: MobileFileCopyMoveModel,
        repository: FileCopyMoveRepositoryStub,
        sources: [FileItem],
        operation: FileCopyMoveOperation
    ) async {
        model.begin(
            operation: operation,
            items: sources,
            parentPath: "/source",
            source: .browser,
            visibleItems: sources,
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
        FilePage(folderPath: path.isEmpty ? "/" : path, items: items, offset: 0, total: items.count, hasMore: false)
    }

    private func outcome(
        _ status: MutationResultStatus,
        _ operation: FileCopyMoveOperation,
        _ source: FileItem,
        _ destination: String,
        _ item: FileItem?
    ) throws -> FileCopyMoveOutcome {
        let submitted = ![.cancelledBeforeSubmission, .permissionDenied, .unsupported].contains(status)
        let review = status == .submittedButUnverified || status == .cancellationRequestedAfterSubmission || status == .partialSuccess
        let failed = status == .permissionDenied || status == .unsupported || status == .confirmedFailure
        return FileCopyMoveOutcome(
            result: try MutationResult(
                status: status,
                operation: operation.rawValue,
                submitted: submitted,
                requiresRefresh: review,
                counts: try MutationResultCounts(
                    succeeded: status == .confirmedSuccess || status == .partialSuccess ? 1 : 0,
                    failed: failed ? 1 : 0,
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
