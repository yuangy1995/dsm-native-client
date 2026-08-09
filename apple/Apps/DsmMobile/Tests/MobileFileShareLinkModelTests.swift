import DsmCore
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileFileShareLinkModelTests: XCTestCase {
    func test确认成功后才允许复制和系统分享且有效期使用确定公历() async throws {
        let profileID = UUID()
        let item = Self.item(profileID: profileID)
        let link = FileShareLink(
            id: "confirmed-link",
            name: item.name,
            path: item.path,
            url: "https://share.example.invalid/confirmed",
            hasPassword: true,
            expiresAt: "2027-01-01"
        )
        let repository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.confirmedSuccess, link: link)]
        )
        let clipboard = ClipboardProbe()
        let model = MobileFileShareLinkModel(
            clipboard: clipboard,
            now: { Date(timeIntervalSince1970: 1_798_761_600) } // 2027-01-01 UTC
        )
        model.activate(profileID: profileID, repository: repository)
        model.begin(for: item)
        model.setPassword("keep spaces ")
        model.setExpiration(.sevenDays)

        model.submit()
        try await waitUntil { model.state.phase == .confirmedSuccess }

        let requests = await repository.requests()
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].password, "keep spaces ")
        XCTAssertEqual(requests[0].expiresOn?.iso8601, "2027-01-08")
        XCTAssertEqual(model.state.password, "")

        model.copyConfirmedLink()
        XCTAssertEqual(clipboard.urls, [URL(string: link.url)!])
        model.presentSystemShare()
        XCTAssertEqual(model.state.sharePresentation?.url, URL(string: link.url))
    }

    func test超过十六字符不静默截断且契约拒绝时零请求() async throws {
        let profileID = UUID()
        let repository = ShareLinkRepositoryStub(profileID: profileID, outcomes: [])
        let model = MobileFileShareLinkModel()
        model.activate(profileID: profileID, repository: repository)
        model.begin(for: Self.item(profileID: profileID))
        let password = String(repeating: "a", count: 17)

        model.setPassword(password)
        XCTAssertFalse(model.canSubmit)
        model.submit()

        XCTAssertEqual(model.state.password, password)
        XCTAssertEqual(model.state.phase, .form)
        let requestCount = await repository.requests().count
        XCTAssertEqual(requestCount, 0)
    }

    func test提交未知不允许重试复制或分享且再次打开同目标仍要求核对() async throws {
        let profileID = UUID()
        let item = Self.item(profileID: profileID)
        let repository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.submittedButUnverified)]
        )
        let clipboard = ClipboardProbe()
        let model = MobileFileShareLinkModel(clipboard: clipboard)
        model.activate(profileID: profileID, repository: repository)
        model.begin(for: item)
        model.submit()
        try await waitUntil { model.state.phase == .reviewRequired }

        model.copyConfirmedLink()
        model.presentSystemShare()
        XCTAssertTrue(clipboard.urls.isEmpty)
        XCTAssertNil(model.state.sharePresentation)
        XCTAssertFalse(model.state.canRetry)

        model.dismiss()
        model.begin(for: item)
        XCTAssertEqual(model.state.phase, .reviewRequired)
        let requestCount = await repository.requests().count
        XCTAssertEqual(requestCount, 1)
    }

    func test同Profile替换Repository会阻止旧目标重放并只接受新绑定() async throws {
        let profileID = UUID()
        let item = Self.item(profileID: profileID)
        let otherItem = FileItem(
            profileID: profileID,
            name: "Other.pdf",
            path: "/home/Other.pdf",
            kind: .file,
            sizeBytes: 7
        )
        let oldRepository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.confirmedSuccess, link: Self.link(for: item))],
            blocksFirst: true
        )
        let newRepository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.confirmedFailure)]
        )
        let model = MobileFileShareLinkModel()
        model.activate(profileID: profileID, repository: oldRepository)
        model.begin(for: item)
        model.submit()
        await oldRepository.waitUntilBlocked()

        model.activate(profileID: profileID, repository: newRepository)
        await oldRepository.release()
        await Task.yield()

        XCTAssertFalse(model.state.isPresented)
        XCTAssertNil(model.state.confirmedLink)
        model.begin(for: item)
        XCTAssertEqual(model.state.phase, .reviewRequired)
        model.dismiss()
        model.begin(for: otherItem)
        model.submit()
        try await waitUntil { model.state.phase == .confirmedFailure }
        let requestCount = await newRepository.requests().count
        XCTAssertEqual(requestCount, 1)
    }

    func test创建中Dismiss只请求取消且不能立刻重放() async throws {
        let profileID = UUID()
        let item = Self.item(profileID: profileID)
        let repository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.cancellationRequestedAfterSubmission)],
            blocksFirst: true
        )
        let model = MobileFileShareLinkModel()
        model.activate(profileID: profileID, repository: repository)
        model.begin(for: item)
        model.submit()
        await repository.waitUntilBlocked()

        model.dismiss()
        model.begin(for: item)
        model.submit()
        var requestCount = await repository.requests().count
        XCTAssertEqual(requestCount, 1)

        await repository.release()
        try await waitUntil { model.state.phase == .reviewRequired }
        requestCount = await repository.requests().count
        XCTAssertEqual(requestCount, 1)
    }

    func test提交前取消等待明确结果后才允许重试() async throws {
        let profileID = UUID()
        let item = Self.item(profileID: profileID)
        let repository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.cancelledBeforeSubmission)],
            blocksFirst: true
        )
        let model = MobileFileShareLinkModel()
        model.activate(profileID: profileID, repository: repository)
        model.begin(for: item)
        model.submit()
        await repository.waitUntilBlocked()

        model.requestCancellation()
        XCTAssertEqual(model.state.phase, .creating)
        XCTAssertFalse(model.state.canRetry)

        await repository.release()
        try await waitUntil { model.state.phase == .confirmedFailure }
        XCTAssertTrue(model.state.canRetry)
        XCTAssertEqual(model.state.failure, .generic)
    }

    func test冲突确认失败必须刷新后再试而不提供旧基线重试() async throws {
        let profileID = UUID()
        let repository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.confirmedFailure)]
        )
        let model = MobileFileShareLinkModel()
        model.activate(profileID: profileID, repository: repository)
        model.begin(for: Self.item(profileID: profileID))

        model.submit()
        try await waitUntil { model.state.phase == .confirmedFailure }

        XCTAssertEqual(model.state.failure, .changed)
        XCTAssertFalse(model.state.canRetry)
    }

    func test非法URL确认成功保留核对门且重新打开不重放() async throws {
        let profileID = UUID()
        let item = Self.item(profileID: profileID)
        let malformedLink = FileShareLink(
            id: "reported-success",
            name: item.name,
            path: item.path,
            url: "https://user@share.example.invalid/malformed"
        )
        let repository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.confirmedSuccess, link: malformedLink)]
        )
        let model = MobileFileShareLinkModel()
        model.activate(profileID: profileID, repository: repository)
        model.begin(for: item)
        model.submit()
        try await waitUntil { model.state.phase == .reviewRequired }

        model.dismiss()
        model.begin(for: item)

        XCTAssertEqual(model.state.phase, .reviewRequired)
        let requestCount = await repository.requests().count
        XCTAssertEqual(requestCount, 1)
    }

    func test有效期按用户负时区当前公历日派生而非UTC日期() async throws {
        let profileID = UUID()
        let item = Self.item(profileID: profileID)
        let repository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.confirmedFailure)]
        )
        let model = MobileFileShareLinkModel(
            now: { Date(timeIntervalSince1970: 1_798_765_200) }, // 2027-01-01 01:00 UTC
            timeZone: { TimeZone(secondsFromGMT: -8 * 3_600)! }
        )
        model.activate(profileID: profileID, repository: repository)
        model.begin(for: item)
        model.setExpiration(.sevenDays)

        model.submit()
        try await waitUntil { model.state.phase == .confirmedFailure }

        let recordedRequest = await repository.requests().first
        let request = try XCTUnwrap(recordedRequest)
        XCTAssertEqual(request.expiresOn?.iso8601, "2027-01-07")
    }

    func test创建中拒绝切换到不同目标且不覆盖当前提交() async throws {
        let profileID = UUID()
        let item = Self.item(profileID: profileID)
        let otherItem = FileItem(
            profileID: profileID,
            name: "Other.pdf",
            path: "/home/Other.pdf",
            kind: .file,
            sizeBytes: 7
        )
        let repository = ShareLinkRepositoryStub(
            profileID: profileID,
            outcomes: [Self.outcome(.cancellationRequestedAfterSubmission)],
            blocksFirst: true
        )
        let model = MobileFileShareLinkModel()
        model.activate(profileID: profileID, repository: repository)
        model.begin(for: item)
        model.submit()
        await repository.waitUntilBlocked()

        model.begin(for: otherItem)

        XCTAssertEqual(model.state.phase, .creating)
        XCTAssertEqual(model.state.target?.path, item.path)
        let requestCount = await repository.requests().count
        XCTAssertEqual(requestCount, 1)
        model.requestCancellation()
        await repository.release()
        try await waitUntil { model.state.phase == .reviewRequired }
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ predicate: @escaping @MainActor () -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while !predicate() {
            if ContinuousClock.now - start > .nanoseconds(Int64(timeoutNanoseconds)) {
                XCTFail("等待分享链接状态超时")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private static func item(profileID: UUID) -> FileItem {
        FileItem(
            profileID: profileID,
            name: "Report.pdf",
            path: "/home/Report.pdf",
            kind: .file,
            sizeBytes: 42
        )
    }

    private static func link(for item: FileItem) -> FileShareLink {
        FileShareLink(
            id: "confirmed-link",
            name: item.name,
            path: item.path,
            url: "https://share.example.invalid/confirmed"
        )
    }

    private static func outcome(
        _ status: MutationResultStatus,
        link: FileShareLink? = nil
    ) -> FileShareLinkCreateOutcome {
        let submitted = ![.cancelledBeforeSubmission, .unsupported].contains(status)
        let requiresRefresh = [.submittedButUnverified, .cancellationRequestedAfterSubmission, .partialSuccess].contains(status)
        let succeeded = status == .confirmedSuccess ? 1 : 0
        let failed = [.confirmedFailure, .permissionDenied, .unsupported].contains(status) ? 1 : 0
        let unknown = requiresRefresh ? 1 : 0
        return FileShareLinkCreateOutcome(
            result: try! MutationResult(
                status: status,
                operation: "shareLinkCreate",
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                counts: try! MutationResultCounts(succeeded: succeeded, failed: failed, unknown: unknown),
                errorCategory: status == .confirmedFailure ? .conflict : nil,
                diagnosticTag: "file-station.share-link.test"
            ),
            confirmedLink: link
        )
    }
}

@MainActor
private final class ClipboardProbe: MobileClipboardWriting {
    private(set) var urls: [URL] = []
    func copySensitiveURL(_ url: URL) { urls.append(url) }
}

private actor ShareLinkRepositoryStub: MobileFileShareLinkServing {
    nonisolated let profileID: UUID
    nonisolated let fileShareLinkAvailability = FileShareLinkAvailability(
        status: .available,
        resolvedVersion: 3
    )
    private var outcomes: [FileShareLinkCreateOutcome]
    private var recordedRequests: [FileShareLinkCreateRequest] = []
    private let blocksFirst: Bool
    private var didBlock = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    init(profileID: UUID, outcomes: [FileShareLinkCreateOutcome], blocksFirst: Bool = false) {
        self.profileID = profileID
        self.outcomes = outcomes
        self.blocksFirst = blocksFirst
    }

    func createShareLinkResult(
        _ request: FileShareLinkCreateRequest
    ) async throws -> FileShareLinkCreateOutcome {
        recordedRequests.append(request)
        if blocksFirst, !didBlock {
            didBlock = true
            observer?.resume()
            observer = nil
            await withCheckedContinuation { continuation = $0 }
        }
        return outcomes.removeFirst()
    }

    func requests() -> [FileShareLinkCreateRequest] { recordedRequests }

    func waitUntilBlocked() async {
        guard continuation == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
