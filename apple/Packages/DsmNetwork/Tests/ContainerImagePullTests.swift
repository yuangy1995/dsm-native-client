import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class ContainerImagePullTests: XCTestCase {
    func test启动与状态固定V1且保留字符串或整数任务编号() async throws {
        for format in [DsmRequestFormat.form, .json] {
            for numeric in [false, true] {
                let transport = MockHTTPTransport(responses: [reply(tags), reply(images),
                    reply("{\"success\":true,\"data\":{\"task_id\":\(numeric ? "42" : "\"synthetic-task\"")}}"),
                    reply(status()), reply(status(finished: true)), reply(images)])
                let repository = try makeRepository(transport, format: format)
                let request = makeRequest()
                let first = try await repository.startContainerImagePull(request)
                XCTAssertEqual(first.stage, .downloading); XCTAssertEqual(first.percentage, 25)
                let final = try await repository.reviewContainerImagePull(id: request.id)
                XCTAssertEqual(final?.stage, .ready)
                let repeated = try await repository.startContainerImagePull(request)
                XCTAssertEqual(repeated, final)
                let calls = await transport.recordedRequests()
                let start = try XCTUnwrap(calls.first { parameter("method", $0) == "pull_start" })
                let encodedRepository = try XCTUnwrap(parameter("repository", start))
                let decodedRepository = format == .json
                    ? try JSONDecoder().decode(String.self, from: Data(encodedRepository.utf8))
                    : encodedRepository
                XCTAssertEqual(decodedRepository, "synthetic/web")
                XCTAssertEqual(parameter("tag", start), format == .json ? "\"stable\"" : "stable")
                let statusRequest = try XCTUnwrap(calls.first { parameter("method", $0) == "pull_status" })
                XCTAssertEqual(parameter("task_id", statusRequest), numeric ? "42" : format == .json ? "\"synthetic-task\"" : "synthetic-task")
                XCTAssertTrue(calls.allSatisfy { parameter("version", $0) == "1" })
                XCTAssertEqual(calls.filter { parameter("method", $0) == "pull_start" }.count, 1)
            }
        }
    }

    func test旧标签与100百分比不能确认未结束任务() async throws {
        let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply(receipt), reply(status(current: 100))])
        let repository = try makeRepository(transport)
        let result = try await repository.startContainerImagePull(makeRequest())
        XCTAssertEqual(result.stage, .downloading); XCTAssertEqual(result.percentage, 100)
        XCTAssertEqual(result.outcome.status, .submittedButUnverified)
    }

    func test无回执和不安全数字任务编号不得猜测或重发() async throws {
        for taskID in ["null", "true", "-1", "9007199254740993"] {
            let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply("{\"success\":true,\"data\":{\"task_id\":\(taskID)}}")])
            let repository = try makeRepository(transport); let original = makeRequest()
            let result = try await repository.startContainerImagePull(original)
            let again = try await repository.startContainerImagePull(original)
            let conflicting = try await repository.startContainerImagePull(makeRequest())
            XCTAssertEqual(result.stage, .awaitingReceipt); XCTAssertEqual(again.stage, .awaitingReceipt)
            XCTAssertFalse(conflicting.outcome.submitted); XCTAssertEqual(conflicting.outcome.errorCategory, .conflict)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
        }
    }

    func test回执丢失保存未知记录且独立核查不重放() async throws {
        let transport = MockHTTPTransport(steps: [.response(reply(tags)), .response(reply(images)), .urlError(.timedOut)])
        let repository = try makeRepository(transport); let request = makeRequest()
        let result = try await repository.startContainerImagePull(request)
        let pending = try await repository.loadContainerImagePulls()
        let reviewed = try await repository.reviewContainerImagePull(id: request.id)
        XCTAssertEqual(result.stage, .awaitingReceipt); XCTAssertEqual(pending.count, 1); XCTAssertEqual(reviewed?.stage, .awaitingReceipt)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
    }

    func test完成必须有原生结束标记回显绑定和标签回读() async throws {
        for scenario in ["flag", "name", "tag", "missing-image", "partial-list"] {
            var taskStatus = status(finished: true)
            if scenario == "flag" { taskStatus = taskStatus.replacingOccurrences(of: "\"finished\":true", with: "\"finished\":\"true\"") }
            if scenario == "name" { taskStatus = taskStatus.replacingOccurrences(of: "docker.io/synthetic/web", with: "other/web") }
            if scenario == "tag" { taskStatus = taskStatus.replacingOccurrences(of: "stable", with: "latest") }
            let finalImages = scenario == "missing-image" ? "{\"success\":true,\"data\":{\"images\":[]}}" :
                scenario == "partial-list" ? images.replacingOccurrences(of: "\"total\":1", with: "\"total\":2") : images
            let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply(receipt), reply(taskStatus), reply(finalImages)])
            let repository = try makeRepository(transport)
            let result = try await repository.startContainerImagePull(makeRequest())
            XCTAssertEqual(result.stage, .needsReview)
            XCTAssertNotEqual(result.outcome.status, .confirmedSuccess)
        }
    }

    func test明确权限拒绝缓存为终态且不会回读成成功() async throws {
        let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply("{\"success\":false,\"error\":{\"code\":105}}")])
        let repository = try makeRepository(transport); let request = makeRequest()
        let result = try await repository.startContainerImagePull(request)
        let repeated = try await repository.startContainerImagePull(request)
        XCTAssertEqual(result.stage, .rejected); XCTAssertEqual(result.outcome.status, .permissionDenied); XCTAssertEqual(result, repeated)
        let pending = try await repository.loadContainerImagePulls(); XCTAssertTrue(pending.isEmpty)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
    }

    func test缺确认或无效目标不得读取或启动() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(transport)
        for request in [ContainerImagePullRequest(repository: "synthetic/web", tag: "stable"),
                        ContainerImagePullRequest(repository: "user@registry.invalid", tag: "stable", isConfirmed: true)] {
            let result = try await repository.startContainerImagePull(request)
            XCTAssertFalse(result.outcome.submitted)
        }
        let calls = await transport.recordedRequests(); XCTAssertTrue(calls.isEmpty)
    }

    func test查询失败后重试只核查同一任务() async throws {
        let transport = MockHTTPTransport(steps: [.response(reply(tags)), .response(reply(images)), .response(reply(receipt)), .urlError(.networkConnectionLost),
            .response(reply(status(finished: true))), .response(reply(images))])
        let repository = try makeRepository(transport); let request = makeRequest()
        let first = try await repository.startContainerImagePull(request)
        let last = try await repository.reviewContainerImagePull(id: request.id)
        XCTAssertEqual(first.stage, .needsReview); XCTAssertEqual(last?.stage, .ready)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { parameter("method", $0) == "pull_start" }.count, 1)
    }

    func test启动后取消保留未知任务并且不发送取消接口() async throws {
        let transport = MockHTTPTransport(steps: [.response(reply(tags)), .response(reply(images)), .waitUntilCancelled])
        let repository = try makeRepository(transport); let request = makeRequest()
        let task = Task { try await repository.startContainerImagePull(request) }
        let deadline = Date().addingTimeInterval(2)
        while await transport.recordedRequests().count < 3 && Date() < deadline { await Task.yield() }
        task.cancel(); let result = try await task.value
        XCTAssertEqual(result.outcome.status, .cancellationRequestedAfterSubmission)
        let pending = try await repository.loadContainerImagePulls(); XCTAssertEqual(pending.count, 1)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
    }

    func test预检读取时取消不启动也不登记未知任务() async throws {
        let transport = MockHTTPTransport(steps: [.waitUntilCancelled])
        let repository = try makeRepository(transport); let request = makeRequest()
        let task = Task { try await repository.startContainerImagePull(request) }
        let deadline = Date().addingTimeInterval(2)
        while await transport.recordedRequests().isEmpty && Date() < deadline { await Task.yield() }
        task.cancel(); let result = try await task.value
        XCTAssertEqual(result.outcome.status, .cancelledBeforeSubmission); XCTAssertFalse(result.outcome.submitted)
        let pending = try await repository.loadContainerImagePulls(); XCTAssertTrue(pending.isEmpty)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
    }

    func test同标签下载与删除互斥() async throws {
        let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply(receipt), reply(status()), reply(images)])
        let repository = try makeRepository(transport)
        _ = try await repository.startContainerImagePull(makeRequest())
        let result = try await repository.deleteContainerImagesResult(ids: [ContainerImage.selectionID(imageID: "synthetic-id", repository: "synthetic/web", tag: "stable")])
        XCTAssertFalse(result.submitted); XCTAssertEqual(result.errorCategory, .conflict)
        let calls = await transport.recordedRequests(); XCTAssertFalse(calls.contains { parameter("method", $0) == "delete" })
    }

    private var tags: String { "{\"success\":true,\"data\":{\"tags\":[\"stable\"]}}" }
    private var images: String { "{\"success\":true,\"data\":{\"offset\":0,\"total\":1,\"images\":[{\"id\":\"synthetic-id\",\"repository\":\"synthetic/web\",\"tags\":[\"stable\"]}]}}" }
    private var receipt: String { "{\"success\":true,\"data\":{\"task_id\":\"synthetic-task\"}}" }
    private func status(finished: Bool = false, current: Int = 25) -> String {
        "{\"success\":true,\"data\":{\"finished\":\(finished),\"repository\":\"docker.io/synthetic/web\",\"tag\":\"stable\",\"current\":\(current),\"total\":100}}"
    }
    private func makeRequest() -> ContainerImagePullRequest { .init(repository: "synthetic/web", tag: "stable", isConfirmed: true) }
    private func reply(_ json: String) -> DsmHTTPResponse { .init(data: Data(json.utf8), statusCode: 200) }
    private func makeRepository(_ transport: any DsmHTTPTransport, format: DsmRequestFormat = .form) throws -> DsmServiceManagementRepository {
        let values = [DsmAPIName.dockerImage, DsmAPIName.dockerRegistry, DsmAPIName.dockerContainer].map { name in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: format, selectedVersion: 2))
        }
        return try DsmServiceManagementRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: values)),
            session: AuthSession(sid: "SYNTHETIC_SESSION", synoToken: "SYNTHETIC_TOKEN", did: nil, isPortalPort: false), transport: transport)
    }
    private func parameter(_ name: String, _ request: URLRequest) -> String? {
        guard let body = request.httpBody, let text = String(data: body, encoding: .utf8) else { return nil }
        return URLComponents(string: "https://fixture.invalid/?" + text)?.queryItems?.first { $0.name == name }?.value
    }
}
