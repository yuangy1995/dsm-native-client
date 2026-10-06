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

    func test搜索固定官方V1且保留原生JSON参数() async throws {
        for format in [DsmRequestFormat.form, .json] {
            let transport = MockHTTPTransport(responses: [reply(#"{"success":true,"data":{"data":[{"name":"synthetic/web","registry":"docker.io","is_official":true}],"total":1}}"#)])
            let repository = try makeRepository(transport, format: format)
            let result = try await repository.searchContainerImages(query: "synthetic")
            XCTAssertEqual(result.map(\.name), ["synthetic/web"])
            let requests = await transport.recordedRequests()
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(parameter("version", request), "1")
            XCTAssertEqual(parameter("q", request), format == .json ? #""synthetic""# : "synthetic")
            XCTAssertEqual(requests.count, 1)
        }
    }

    func test搜索格式错误不能伪装成没有结果() async throws {
        for payload in [#"{}"#, #"{"data":null}"#, #"{"data":[null]}"#, #"{"data":[{}]}"#, #"{"data":[{"name":""}]}"#] {
            let transport = MockHTTPTransport(responses: [reply("{\"success\":true,\"data\":\(payload)}")])
            let repository = try makeRepository(transport)
            do { _ = try await repository.searchContainerImages(query: "synthetic"); XCTFail("畸形结果必须显示读取失败") }
            catch { XCTAssertNotNil(error as? AppError) }
        }
        let transport = MockHTTPTransport(responses: [reply(#"{"success":true,"data":{"data":[],"total":0}}"#)])
        let empty = try await makeRepository(transport).searchContainerImages(query: "synthetic")
        XCTAssertTrue(empty.isEmpty)
    }

    func test状态连续失败保持原任务并且不会误报旧镜像可用() async throws {
        let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply(receipt),
            reply(#"{"success":false,"error":{"code":150}}"#), reply(#"{"success":false,"error":{"code":117,"errors":508}}"#),
            reply(status()), reply(status(finished: true)), reply(images)])
        let repository = try makeRepository(transport); let request = makeRequest()
        let first = try await repository.startContainerImagePull(request)
        let second = try await repository.reviewContainerImagePull(id: request.id)
        XCTAssertEqual(first.stage, .needsReview); XCTAssertEqual(second?.stage, .needsReview)
        let third = try await repository.reviewContainerImagePull(id: request.id)
        XCTAssertEqual(third?.stage, .downloading)
        let final = try await repository.reviewContainerImagePull(id: request.id)
        XCTAssertEqual(final?.stage, .ready)
        let calls = await transport.recordedRequests()
        XCTAssertEqual(calls.filter { parameter("method", $0) == "pull_start" }.count, 1)
        XCTAssertTrue(calls.filter { parameter("method", $0) == "pull_status" }.allSatisfy { parameter("task_id", $0) == "synthetic-task" })
    }

    func test已绑定任务明确下载失败后停止轮询且不重复启动() async throws {
        let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply(receipt), reply(status()),
            reply(#"{"success":false,"error":{"code":1202}}"#)])
        let repository = try makeRepository(transport); let request = makeRequest()
        _ = try await repository.startContainerImagePull(request)
        let failure = try await repository.reviewContainerImagePull(id: request.id)
        XCTAssertEqual(failure?.stage, .rejected)
        XCTAssertEqual(failure?.outcome.status, .confirmedFailure)
        XCTAssertEqual(failure?.outcome.errorCategory, .server)
        let repeated = try await repository.startContainerImagePull(request)
        XCTAssertEqual(repeated, failure)
        let pending = try await repository.loadContainerImagePulls()
        XCTAssertTrue(pending.isEmpty)
        let calls = await transport.recordedRequests()
        XCTAssertEqual(calls.count, 5)
        XCTAssertEqual(calls.filter { parameter("method", $0) == "pull_start" }.count, 1)
    }

    func test完成后的镜像列表错误不能误报任务下载失败() async throws {
        let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply(receipt), reply(status(finished: true)),
            reply(#"{"success":false,"error":{"code":1202}}"#)])
        let result = try await makeRepository(transport).startContainerImagePull(makeRequest())
        XCTAssertEqual(result.stage, .needsReview)
        XCTAssertEqual(result.outcome.status, .submittedButUnverified)
    }

    func test提交前存储失败不得启动下载() async throws {
        let transport = MockHTTPTransport(responses: [reply(tags), reply(images)])
        let repository = try makeRepository(transport)
        do {
            _ = try await repository.startContainerImagePull(makeRequest()) { _ in throw PullStorageError() }
            XCTFail("应返回存储失败")
        } catch { XCTAssertTrue(error is PullStorageError) }
        let calls = await transport.recordedRequests()
        XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls.contains { parameter("method", $0) == "pull_start" })
    }

    func test回执保存失败必须停止后续读取且保留原任务() async throws {
        let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply(receipt)])
        let repository = try makeRepository(transport), probe = PullCheckpointProbe()
        do {
            _ = try await repository.startContainerImagePull(makeRequest()) { point in
                await probe.capture(point)
                if case .accepted = point { throw PullStorageError() }
            }
            XCTFail("应返回存储失败")
        } catch { XCTAssertTrue(error is PullStorageError) }
        let recovery = await probe.accepted
        XCTAssertEqual(recovery?.taskID, .text("synthetic-task"))
        XCTAssertEqual(recovery?.baselineImageIDs, [ContainerImagePullRecovery.digest("synthetic-id")])
        let calls = await transport.recordedRequests()
        XCTAssertEqual(calls.count, 3)
        let pending = try await repository.loadContainerImagePulls()
        XCTAssertEqual(pending.count, 1)
    }

    func test明确拒绝检查点失败不能吞成未知或回读() async throws {
        let transport = MockHTTPTransport(responses: [reply(tags), reply(images), reply(#"{"success":false,"error":{"code":105}}"#)])
        do {
            _ = try await makeRepository(transport).startContainerImagePull(makeRequest()) { point in
                if case .rejected = point { throw PullStorageError() }
            }
            XCTFail("应返回存储失败")
        } catch { XCTAssertTrue(error is PullStorageError) }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
    }

    func test重建仓库仅原任务读取保留编号类型且不依赖Registry() async throws {
        for taskID in [ContainerImagePullRecovery.TaskID.text("synthetic-task"), .integer(42)] {
            let transport = MockHTTPTransport(responses: [reply(status()), reply(status(finished: true)), reply(images)])
            let repository = try makeRepository(transport, format: .json, registry: false)
            let recovery = makeRecovery(taskID: taskID)
            let first = try await repository.restoreContainerImagePull(recovery)
            XCTAssertEqual(first.stage, .downloading); XCTAssertEqual(first.percentage, 25)
            XCTAssertEqual(first.repository, "docker.io/synthetic/web")
            let final = try await repository.restoreContainerImagePull(recovery)
            XCTAssertEqual(final.stage, .ready)
            let repeated = try await repository.restoreContainerImagePull(recovery)
            XCTAssertEqual(repeated, final)
            let calls = await transport.recordedRequests()
            XCTAssertEqual(calls.count, 3)
            XCTAssertTrue(calls.allSatisfy { parameter("method", $0) != "pull_start" })
            XCTAssertEqual(parameter("task_id", calls[0]), taskID == .integer(42) ? "42" : #""synthetic-task""#)
        }
    }

    func test无回执恢复零请求且保护原目标不认领旧映像() async throws {
        let transport = MockHTTPTransport(responses: [])
        let repository = try makeRepository(transport), recovery = makeRecovery(taskID: nil)
        let first = try await repository.restoreContainerImagePull(recovery)
        XCTAssertEqual(first.stage, .awaitingReceipt)
        XCTAssertTrue(first.repository.isEmpty)
        let retry = try await repository.startContainerImagePull(makeRequest())
        XCTAssertFalse(retry.outcome.submitted); XCTAssertEqual(retry.outcome.errorCategory, .conflict)
        let calls = await transport.recordedRequests(); XCTAssertTrue(calls.isEmpty)
    }

    func test恢复回显不匹配不得读取清单或覆盖目标() async throws {
        let transport = MockHTTPTransport(responses: [reply(status(finished: true).replacingOccurrences(of: "stable", with: "latest"))])
        let result = try await makeRepository(transport).restoreContainerImagePull(makeRecovery())
        XCTAssertEqual(result.stage, .needsReview); XCTAssertTrue(result.repository.isEmpty)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
    }

    func test恢复任务明确失败结束而读取权限拒绝保留保护() async throws {
        for code in [1202, 105] {
            let transport = MockHTTPTransport(responses: [reply("{\"success\":false,\"error\":{\"code\":\(code)}}")])
            let result = try await makeRepository(transport).restoreContainerImagePull(makeRecovery())
            XCTAssertEqual(result.stage, code == 1202 ? .rejected : .needsReview)
            XCTAssertEqual(result.outcome.errorCategory, code == 1202 ? .server : .permission)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
        }
    }

    func test恢复仍保护原标签和裸映像删除() async throws {
        for bare in [false, true] {
            let payload = bare ? images.replacingOccurrences(of: "stable", with: "<none>") : images
            let transport = MockHTTPTransport(responses: [reply(payload)])
            let repository = try makeRepository(transport)
            _ = try await repository.restoreContainerImagePull(makeRecovery(taskID: nil))
            let result = try await repository.deleteContainerImagesResult(ids: [ContainerImage.selectionID(imageID: "synthetic-id", repository: "synthetic/web", tag: bare ? "<none>" : "stable")])
            XCTAssertFalse(result.submitted); XCTAssertEqual(result.errorCategory, .conflict)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
        }
    }

    func test损坏恢复记录不得读取且同编号不能替换目标() async throws {
        let transport = MockHTTPTransport(responses: []), id = UUID()
        let repository = try makeRepository(transport)
        for recovery in [ContainerImagePullRecovery(id: id, target: "bad", baselineImageIDs: []),
                         ContainerImagePullRecovery(id: id, target: makeRecovery().target, baselineImageIDs: [], taskID: .integer(-1))] {
            do { _ = try await repository.restoreContainerImagePull(recovery); XCTFail("损坏记录必须拒绝") } catch { }
        }
        let original = makeRecovery(taskID: nil)
        _ = try await repository.restoreContainerImagePull(original)
        let changed = ContainerImagePullRecovery(id: original.id, target: ContainerImagePullRecovery.digest("other"), baselineImageIDs: [])
        do { _ = try await repository.restoreContainerImagePull(changed); XCTFail("不得替换目标") } catch { }
        let calls = await transport.recordedRequests(); XCTAssertTrue(calls.isEmpty)
    }

    func test管理路径证书失败直接抛出且不继续读取() async throws {
        for step in [0, 2, 3] {
            var steps: [MockHTTPTransport.Step] = [.response(reply(tags)), .response(reply(images)), .response(reply(receipt))]
            steps = Array(steps.prefix(step)); steps.append(.urlError(.serverCertificateUntrusted))
            let transport = MockHTTPTransport(steps: steps)
            do {
                _ = try await makeRepository(transport).startContainerImagePull(makeRequest()) { _ in }
                XCTFail("证书错误不得降级为普通网络结果")
            } catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, step + 1)
        }
        let transport = MockHTTPTransport(steps: [.urlError(.serverCertificateUntrusted)])
        do { _ = try await makeRepository(transport).restoreContainerImagePull(makeRecovery()); XCTFail("恢复同样保留证书失败") }
        catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
    }

    private func makeRecovery(taskID: ContainerImagePullRecovery.TaskID? = .text("synthetic-task")) -> ContainerImagePullRecovery {
        .init(id: UUID(), target: ContainerImagePullRecovery.target(repository: "synthetic/web", tag: "stable"),
              baselineImageIDs: [ContainerImagePullRecovery.digest("synthetic-id")], taskID: taskID)
    }
    private var tags: String { "{\"success\":true,\"data\":{\"tags\":[\"stable\"]}}" }
    private var images: String { "{\"success\":true,\"data\":{\"offset\":0,\"total\":1,\"images\":[{\"id\":\"synthetic-id\",\"repository\":\"synthetic/web\",\"tags\":[\"stable\"]}]}}" }
    private var receipt: String { "{\"success\":true,\"data\":{\"task_id\":\"synthetic-task\"}}" }
    private func status(finished: Bool = false, current: Int = 25) -> String {
        "{\"success\":true,\"data\":{\"finished\":\(finished),\"repository\":\"docker.io/synthetic/web\",\"tag\":\"stable\",\"current\":\(current),\"total\":100}}"
    }
    private func makeRequest() -> ContainerImagePullRequest { .init(repository: "synthetic/web", tag: "stable", isConfirmed: true) }
    private func reply(_ json: String) -> DsmHTTPResponse { .init(data: Data(json.utf8), statusCode: 200) }
    private func makeRepository(_ transport: any DsmHTTPTransport, format: DsmRequestFormat = .form, registry: Bool = true) throws -> DsmServiceManagementRepository {
        let names = registry ? [DsmAPIName.dockerImage, DsmAPIName.dockerRegistry, DsmAPIName.dockerContainer] : [DsmAPIName.dockerImage]
        let values = names.map { name in
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

private struct PullStorageError: Error { }
private actor PullCheckpointProbe {
    var accepted: ContainerImagePullRecovery?
    func capture(_ checkpoint: ContainerImagePullCheckpoint) {
        if case .accepted(let value) = checkpoint { accepted = value }
    }
}
