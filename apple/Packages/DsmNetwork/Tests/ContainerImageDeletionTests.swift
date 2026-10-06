import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class ContainerImageDeletionTests: XCTestCase {
    func test选择读取保留标签身份并标出停止容器占用() async throws {
        let transport = MockHTTPTransport(responses: [reply(images()), reply(#"{"success":true,"data":{"containers":[{"image":"docker.io/sample/web:stable","status":"stopped"}]}}"#)])
        let values = try await repository(transport).loadContainerImageDeletionTargets()
        XCTAssertEqual(values.count, 2)
        XCTAssertTrue(values.first { $0.tag == "stable" }?.isInUse == true)
        XCTAssertFalse(try XCTUnwrap(values.first { $0.tag == "latest" }).isInUse)
        XCTAssertTrue(values.allSatisfy { ContainerImageDeletionTarget($0) != nil })
    }
    func test固定多标签只发送一次且逐项保留删除结果() async throws {
        let transport = MockHTTPTransport(responses: [reply(images()), reply(containers), reply(#"{"success":true}"#), reply(images(tags: ["latest"]))])
        let request = makeRequest(["stable", "latest"]), probe = ImageDeletionProbe()
        let result = try await repository(transport).deleteContainerImages(request) { await probe.capture($0) }
        XCTAssertEqual(result.outcome.status, .partialSuccess)
        XCTAssertEqual(result.removedTargetIDs, [request.recovery.targets[0].id])
        let points = await probe.points; XCTAssertEqual(points, ["willSubmit", "accepted"])
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
        let parameters = fields(calls[2]); XCTAssertEqual(parameters["version"], "1"); XCTAssertNil(parameters["id"])
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(parameters["images"]).utf8)) as? [[String: Any]])
        XCTAssertEqual(objects.count, 1); XCTAssertEqual(objects[0]["repository"] as? String, "sample/web")
        XCTAssertEqual(Set(objects[0]["tags"] as? [String] ?? []), ["stable", "latest"])
    }
    func test目标替换或尚未确认时零写入() async throws {
        let transport = MockHTTPTransport(responses: [reply(images(id: "replacement"))])
        let adapter = try repository(transport), request = makeRequest()
        let result = try await adapter.deleteContainerImages(request) { _ in XCTFail("预检失败不产生写前检查点") }
        XCTAssertFalse(result.outcome.submitted)
        do {
            _ = try await adapter.deleteContainerImages(.init(targets: request.targets)) { _ in }
            XCTFail("必须明确确认")
        } catch { }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
    }
    func test写前保存失败零提交() async throws {
        let transport = MockHTTPTransport(responses: [reply(images()), reply(containers)])
        do {
            _ = try await repository(transport).deleteContainerImages(makeRequest()) { _ in throw ImageDeletionStorageError() }
            XCTFail("应抛出存储失败")
        } catch { XCTAssertTrue(error is ImageDeletionStorageError) }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
        XCTAssertFalse(calls.contains { fields($0)["method"] == "delete" })
    }
    func test接受回执保存失败不继续读取且恢复不重发() async throws {
        let transport = MockHTTPTransport(responses: [reply(images()), reply(containers), reply(#"{"success":true}"#), reply(images(tags: ["latest"]))])
        let adapter = try repository(transport), request = makeRequest()
        do {
            _ = try await adapter.deleteContainerImages(request) { point in if case .accepted = point { throw ImageDeletionStorageError() } }
            XCTFail("应抛出存储失败")
        } catch { XCTAssertTrue(error is ImageDeletionStorageError) }
        let before = await transport.recordedRequests(); XCTAssertEqual(before.count, 3)
        let result = try await adapter.restoreContainerImageDeletion(request.recovery)
        XCTAssertEqual(result.outcome.status, .confirmedSuccess)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
        XCTAssertEqual(calls.filter { fields($0)["method"] == "delete" }.count, 1)
    }
    func test明确拒绝检查点失败不吞错且不能被外部消失覆盖() async throws {
        let transport = MockHTTPTransport(responses: [reply(images()), reply(containers), reply(#"{"success":false,"error":{"code":105}}"#)])
        let adapter = try repository(transport), request = makeRequest()
        do {
            _ = try await adapter.deleteContainerImages(request) { point in if case .rejected = point { throw ImageDeletionStorageError() } }
            XCTFail("应抛出存储失败")
        } catch { XCTAssertTrue(error is ImageDeletionStorageError) }
        let result = try await adapter.restoreContainerImageDeletion(request.recovery)
        XCTAssertEqual(result.outcome.status, .permissionDenied)
        XCTAssertTrue(result.removedTargetIDs.isEmpty)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 3)
    }
    func test重建仓库恢复仅读取原标签且不依赖容器列表() async throws {
        let request = makeRequest(), transport = MockHTTPTransport(responses: [reply(images(tags: ["latest"]))])
        let encoded = try JSONEncoder().encode(request.recovery)
        let recovery = try JSONDecoder().decode(ContainerImageDeletionRecovery.self, from: encoded)
        let result = try await repository(transport, containerCapability: false).restoreContainerImageDeletion(recovery)
        XCTAssertEqual(result.outcome.status, .confirmedSuccess)
        XCTAssertEqual(result.removedTargetIDs, request.recovery.targetIDs)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { fields($0)["method"] }, ["list"])
        let text = String(decoding: encoded, as: UTF8.self)
        for value in ["sample/web", "synthetic-image", "stable", "latest"] { XCTAssertFalse(text.contains(value)) }
    }
    func test标签换ID仍未知且恢复后的相同地址不能再删() async throws {
        let transport = MockHTTPTransport(responses: [reply(images(id: "replacement")), reply(images(id: "replacement"))])
        let adapter = try repository(transport), original = makeRequest()
        let result = try await adapter.restoreContainerImageDeletion(original.recovery)
        XCTAssertEqual(result.outcome.status, .submittedButUnverified); XCTAssertTrue(result.removedTargetIDs.isEmpty)
        let changed = makeRequest(id: "replacement")
        let next = try await adapter.deleteContainerImages(changed) { _ in XCTFail("不能再提交") }
        XCTAssertFalse(next.outcome.submitted); XCTAssertEqual(next.outcome.errorCategory, .conflict)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }
    func test无标签恢复须整个原ID消失且阻止对应下载() async throws {
        let original = makeRequest(["<none>"])
        let transport = MockHTTPTransport(responses: [reply(images()), reply(#"{"success":true,"data":{"tags":["stable"]}}"#), reply(images())])
        let adapter = try repository(transport)
        let result = try await adapter.restoreContainerImageDeletion(original.recovery)
        XCTAssertEqual(result.outcome.status, .submittedButUnverified)
        let pull = try await adapter.startContainerImagePull(.init(repository: "sample/web", tag: "stable", isConfirmed: true))
        XCTAssertFalse(pull.outcome.submitted); XCTAssertEqual(pull.outcome.errorCategory, .conflict)
        let calls = await transport.recordedRequests(); XCTAssertFalse(calls.contains { fields($0)["method"] == "pull_start" })
    }
    func test已结束请求再次调用返回原结果而不会删除重建标签() async throws {
        let transport = MockHTTPTransport(responses: [reply(images()), reply(containers), reply(#"{"success":true}"#), reply(images(tags: ["latest"]))])
        let adapter = try repository(transport), request = makeRequest()
        let first = try await adapter.deleteContainerImages(request) { _ in }
        let repeated = try await adapter.deleteContainerImages(request) { _ in XCTFail("已结束请求不再写入") }
        XCTAssertEqual(repeated, first)
        let changed = ContainerImageDeletionRequest(id: request.id, targets: makeRequest(["latest"]).targets, isConfirmed: true)
        do { _ = try await adapter.deleteContainerImages(changed) { _ in }; XCTFail("原编号不能绑定新目标") } catch { }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 4)
    }
    func test恢复拒绝损坏摘要与同编号不同目标() async throws {
        let transport = MockHTTPTransport(responses: [reply(images())]), adapter = try repository(transport), original = makeRequest()
        let encoded = String(decoding: try JSONEncoder().encode(original.recovery), as: UTF8.self)
        let invalid = try JSONDecoder().decode(ContainerImageDeletionRecovery.self,
            from: Data(encoded.replacingOccurrences(of: original.recovery.targets[0].reference, with: "bad").utf8))
        do { _ = try await adapter.restoreContainerImageDeletion(invalid); XCTFail("损坏摘要必须拒绝") } catch { }
        _ = try await adapter.restoreContainerImageDeletion(original.recovery)
        let changed = ContainerImageDeletionRecovery(id: original.id, targets: makeRequest(["latest"]).recovery.targets)
        do { _ = try await adapter.restoreContainerImageDeletion(changed); XCTFail("不能重绑") } catch { }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
    }
    func test证书失败停止预检提交与回读链路() async throws {
        for step in [0, 2, 3] {
            let before: [MockHTTPTransport.Step] = [.response(reply(images())), .response(reply(containers)), .response(reply(#"{"success":true}"#))]
            let transport = MockHTTPTransport(steps: Array(before.prefix(step)) + [.urlError(.serverCertificateUntrusted)])
            do { _ = try await repository(transport).deleteContainerImages(makeRequest()) { _ in }; XCTFail("应保留证书错误") }
            catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, step + 1)
        }
    }
    private var containers: String { #"{"success":true,"data":{"containers":[]}}"# }
    private func images(id: String = "synthetic-image", tags: [String] = ["latest", "stable"]) -> String {
        let list = tags.map { "\"\($0)\"" }.joined(separator: ",")
        return "{\"success\":true,\"data\":{\"images\":[{\"id\":\"\(id)\",\"repository\":\"sample/web\",\"tags\":[\(list)]}]}}"
    }
    private func makeRequest(_ tags: [String] = ["stable"], id: String = "synthetic-image") -> ContainerImageDeletionRequest {
        .init(targets: tags.map { ContainerImage(id: ContainerImage.selectionID(imageID: id, repository: "sample/web", tag: $0),
            repository: "sample/web", tag: $0, sourceImageID: id) }, isConfirmed: true)
    }
    private func reply(_ json: String) -> DsmHTTPResponse { .init(data: Data(json.utf8), statusCode: 200) }
    private func fields(_ request: URLRequest) -> [String: String] {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        return Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    private func repository(_ transport: any DsmHTTPTransport, containerCapability: Bool = true) throws -> DsmServiceManagementRepository {
        let names = [DsmAPIName.dockerImage, DsmAPIName.dockerRegistry] + (containerCapability ? [DsmAPIName.dockerContainer] : [])
        return try .init(profile: .init(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001),
            capabilities: .init(Dictionary(uniqueKeysWithValues: names.map { ($0, .init(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .form, selectedVersion: 2)) })),
            session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
}

private struct ImageDeletionStorageError: Error { }
private actor ImageDeletionProbe {
    var points: [String] = []
    func capture(_ point: ContainerImageDeletionCheckpoint) {
        switch point { case .willSubmit: points.append("willSubmit"); case .accepted: points.append("accepted"); case .rejected: points.append("rejected") }
    }
}
