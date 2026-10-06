import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class VirtualMachineImageWorkflowTests: XCTestCase, @unchecked Sendable {
    func repository(_ transport: VmmImageWorkflowTransport, publicAPI: Bool = false) throws -> DsmServiceManagementRepository {
        let names = [publicAPI ? DsmAPIName.virtualizationAPIGuestImage : DsmAPIName.virtualizationGuestImage,
                     DsmAPIName.virtualizationGuest, DsmAPIName.virtualizationRepo, DsmAPIName.virtualizationCluster]
        return try DsmServiceManagementRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
                ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .json, selectedVersion: 2))
            })), session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    func test内部删除固定V2和单ID及操作编号() async throws {
        let transport = VmmImageWorkflowTransport(), repository = try repository(transport)
        let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes.first?["version"], "2")
        XCTAssertEqual(writes.first?["id"], #""image-1""#)
        XCTAssertNotNil(writes.first?["synovmm_ui_id"])
        XCTAssertNil(writes.first?["image_id"]); XCTAssertNil(writes.first?["blocking"])
    }
    func test冻结映像清单零删除() async throws {
        let transport = VmmImageWorkflowTransport(mode: .frozen), repository = try repository(transport)
        let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
        XCTAssertFalse(result.submitted)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test停止虚拟机挂载的ISO仍不能删除() async throws {
        let transport = VmmImageWorkflowTransport(mode: .inUse), repository = try repository(transport)
        let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
        XCTAssertFalse(result.submitted)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test内部删除丢回执不能按消失认领成功或重发() async throws {
        let transport = VmmImageWorkflowTransport(mode: .lostReceipt), repository = try repository(transport)
        for _ in 0..<2 {
            let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
            XCTAssertEqual(result.status, .submittedButUnverified)
            XCTAssertEqual(result.counts.unknown, 1)
        }
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test多个存储上的同一映像只删除一次() async throws {
        let transport = VmmImageWorkflowTransport(mode: .replicas), repository = try repository(transport)
        let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test完整来源及副本参与冻结确认() async throws {
        let transport = VmmImageWorkflowTransport(mode: .replicas), repository = try repository(transport)
        let inventory = try await repository.loadVirtualMachineImages(), target = try XCTUnwrap(inventory.images.first)
        XCTAssertEqual(target.copies.count, 2); XCTAssertEqual(target.isInUse, false)
        await transport.setMode(.success)
        do { try await repository.deleteVirtualMachineImage(target) { _ in }; XCTFail("副本发生变化不能沿用旧确认") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test畸形或不完整清单和占用字段零写() async throws {
        for mode in [VmmImageWorkflowTransport.Mode.missingFreeze, .duplicateCopy, .partialList, .missingHost, .badUsage] {
            let transport = VmmImageWorkflowTransport(mode: mode), repository = try repository(transport)
            let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
            XCTAssertFalse(result.submitted, "\(mode)")
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty, "\(mode)")
        }
    }
    func test公开来源保留单ID和V1且不猜内部占用字段() async throws {
        let transport = VmmImageWorkflowTransport(), repository = try repository(transport, publicAPI: true)
        let inventory = try await repository.loadVirtualMachineImages(), target = try XCTUnwrap(inventory.images.first)
        XCTAssertEqual(target.source, .official); XCTAssertNil(target.isInUse)
        try await repository.deleteVirtualMachineImage(target) { _ in }
        let calls = await transport.calls, write = try XCTUnwrap(calls.first { $0["method"] == "delete" })
        XCTAssertTrue(calls.allSatisfy { $0["api"] == DsmAPIName.virtualizationAPIGuestImage && $0["version"] == "1" })
        XCTAssertEqual(write["image_id"], #""image-1""#); XCTAssertNil(write["id"]); XCTAssertNil(write["synovmm_ui_id"])
    }
    func test写前保存失败零写且接受记录失败保留回执恢复() async throws {
        for failedStage in [VirtualMachineControlStage.willSubmit, .accepted] {
            let transport = VmmImageWorkflowTransport(), repository = try repository(transport)
            let inventory = try await repository.loadVirtualMachineImages(), target = try XCTUnwrap(inventory.images.first)
            do {
                try await repository.deleteVirtualMachineImage(target) { stage in if stage == failedStage { throw VmmImageTestError.storage } }
                XCTFail("记录错误应传播")
            } catch VmmImageTestError.storage {}
            if failedStage == .accepted {
                let result = try await repository.deleteVirtualMachineImagesResult(ids: [target.id])
                XCTAssertEqual(result.status, .confirmedSuccess)
            }
            let writes = await transport.writes; XCTAssertEqual(writes.count, failedStage == .willSubmit ? 0 : 1)
        }
    }
    func test拒绝不能由外部删除覆盖且登录失效不追加读取() async throws {
        for mode in [VmmImageWorkflowTransport.Mode.rejectedExternal, .httpUnauthorized] {
            let transport = VmmImageWorkflowTransport(mode: mode), repository = try repository(transport)
            do {
                let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
                XCTAssertEqual(mode, .rejectedExternal); XCTAssertEqual(result.status, .permissionDenied)
            } catch let error as AppError {
                XCTAssertEqual(mode, .httpUnauthorized); XCTAssertEqual(error.category, .authenticationRequired)
            }
            let calls = await transport.calls; XCTAssertEqual(calls.last?["method"], "delete")
        }
    }
    func test接受后刷新只读解除保护而缺回执保持保护() async throws {
        for mode in [VmmImageWorkflowTransport.Mode.lostReceipt, .postReadFailure] {
            let transport = VmmImageWorkflowTransport(mode: mode), repository = try repository(transport)
            let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
            XCTAssertEqual(result.status, .submittedButUnverified)
            await transport.setMode(.success)
            let current = try await repository.loadVirtualMachineImages(); XCTAssertTrue(current.images.isEmpty)
            let next = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
            XCTAssertEqual(next.status, mode == .lostReceipt ? .submittedButUnverified : .confirmedFailure)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }
    func test批次第二项未知不发送第三项() async throws {
        let transport = VmmImageWorkflowTransport(mode: .lostSecond, count: 3), repository = try repository(transport)
        let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1", "image-2", "image-3"])
        XCTAssertEqual(result.status, .partialSuccess); XCTAssertEqual(result.counts.succeeded, 1)
        XCTAssertEqual(result.counts.unknown, 1); XCTAssertEqual(result.counts.failed, 1)
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2)
    }
    func test内部映像未知删除阻止创建引用且不发创建请求() async throws {
        let transport = VmmImageWorkflowTransport(mode: .lostReceipt), repository = try repository(transport)
        _ = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
        let configuration = VirtualMachineCreation(name: "New guest", operatingSystem: .linux,
            storageID: "repo-1", networkID: "", bootImageID: "image-1", cpuCount: 1, memoryMiB: 512, diskGiB: 10)
        do { try await repository.createVirtualMachine(configuration); XCTFail("原映像仍受删除保护") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let calls = await transport.calls; XCTAssertFalse(calls.contains { $0["method"] == "create" })
    }
    func testMac普通刷新仅恢复已接受的映像结果() async throws {
        for mode in [VmmImageWorkflowTransport.Mode.lostReceipt, .postReadFailure] {
            let transport = VmmImageWorkflowTransport(mode: mode), repository = try repository(transport)
            _ = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
            await transport.setMode(.success)
            _ = try await repository.loadVirtualMachineManager()
            let result = try await repository.deleteVirtualMachineImagesResult(ids: ["image-1"])
            XCTAssertEqual(result.status, mode == .postReadFailure ? .confirmedFailure : .submittedButUnverified)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }
}

private enum VmmImageTestError: Error { case storage }

actor VmmImageWorkflowTransport: DsmHTTPTransport {
    enum Mode { case success, frozen, inUse, lostReceipt, replicas, missingFreeze, duplicateCopy, partialList,
                     missingHost, badUsage, rejectedExternal, httpUnauthorized, postReadFailure, lostSecond }
    private var mode: Mode
    private var remaining: Set<String>
    private(set) var writes: [[String: String]] = []
    private(set) var calls: [[String: String]] = []
    init(mode: Mode = .success, count: Int = 1) { self.mode = mode; remaining = Set((1...count).map { "image-\($0)" }) }
    func setMode(_ value: Mode) { mode = value }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let fields = URLComponents(string: "https://example.invalid/?" + body)?.queryItems ?? []
        let wire = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") }); calls.append(wire)
        var data: [String: Any] = [:]
        if wire["method"] == "delete" {
            writes.append(wire)
            let raw = wire["id"] ?? wire["image_id"] ?? ""
            let id = (try? JSONDecoder().decode(String.self, from: Data(raw.utf8))) ?? raw
            remaining.remove(id)
            if mode == .httpUnauthorized { return .init(data: Data(), statusCode: 401) }
            if mode == .rejectedExternal { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
            if mode == .lostReceipt || mode == .lostSecond && writes.count == 2 { throw URLError(.networkConnectionLost) }
        } else if wire["api"] == DsmAPIName.virtualizationGuest {
            if wire["method"] == "get_setting" { data = ["iso_images": mode == .badUsage ? [1, 2] : ["image-1", "unmounted"]] }
            else { data = ["guests": [.inUse, .badUsage].contains(mode) ? [["guest_id": "vm-1", "name": "Guest", "status": "shutdown"]] : []] }
        } else {
            if mode == .postReadFailure && !writes.isEmpty { throw URLError(.notConnectedToInternet) }
            var rows: [[String: Any]] = remaining.sorted().map { ["id": $0, "name": "Installer", "type": "iso", "repo_id": "repo-1",
                "host_id": "host-1", "status": "online", "status_type": "healthy", "image_id": $0, "image_name": "Installer"] }
            if mode == .replicas, let first = rows.first { var other = first; other["repo_id"] = "repo-2"; other["host_id"] = "host-2"; rows.append(other) }
            if mode == .duplicateCopy, let first = rows.first { rows.append(first) }
            if mode == .missingHost && !rows.isEmpty { rows[0]["host_id"] = nil }
            data = ["is_freeze": mode == .frozen, "images": rows]
            if mode == .missingFreeze { data["is_freeze"] = nil }
            if mode == .partialList { data["total"] = rows.count + 1 }
        }
        return DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
}
