import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class RemoteMountRecoveryTests: XCTestCase {
    private let point = "/home/mount"
    private let source = "//server.invalid/share"

    func test创建回执丢失保留无密码记录并只读恢复() async throws {
        let transport = MockHTTPTransport(steps: createPreflight().map { .response($0) } + [
            .urlError(.networkConnectionLost), .response(info(point, mounted: true)), .response(inventory([(point, source)]))
        ])
        let repository = try self.repository(transport); let configuration = self.configuration()
        do { try await repository.createRemoteMount(configuration); XCTFail("丢失回执不能直接成功") } catch {}
        let operation = try await self.pending(repository)
        XCTAssertEqual(operation.stage, .verifyingConnection)
        let setup = try XCTUnwrap(operation.setup)
        XCTAssertEqual(Set(Mirror(reflecting: setup).children.compactMap(\.label)),
            Set(["protocolType", "server", "remotePath", "mountPoint", "username", "domain", "readOnly", "nfsVersion", "nfsTransport"]))
        XCTAssertFalse(Mirror(reflecting: setup).children.contains { ($0.value as? String) == "synthetic-secret" })
        XCTAssertEqual(String(reflecting: operation), "RemoteMountOperation")
        do { try await repository.createRemoteMount(configuration); XCTFail("未知不能重发") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        for target in ["/home/mount/child", "/home"] {
            do { try await repository.createRemoteMount(self.configuration(target)); XCTFail("未知操作还应保护父子路径") }
            catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        }
        let reviewed = try await repository.reviewRemoteMountOperation(id: operation.id)
        XCTAssertEqual(reviewed?.stage, .completed)
        let cached = try await repository.reviewRemoteMountOperation(id: operation.id); XCTAssertEqual(cached, reviewed)
        let remaining = await repository.pendingRemoteMountOperations(); XCTAssertTrue(remaining.isEmpty)
        await assertWrites(transport, mounts: 1, unmounts: 0)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 5)
    }

    func test卸载后回查权限失败不被当作写入明确拒绝() async throws {
        let transport = MockHTTPTransport(responses: oldPreflight() + [success(), rejected(), info(point, mounted: false), inventory()])
        let repository = try self.repository(transport); let baseline = self.baseline(repository)
        do { try await repository.removeRemoteMount(expectedConnection: baseline); XCTFail("回查失败不能成功") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let operation = try await self.pending(repository); XCTAssertEqual(operation.stage, .verifyingDisconnection)
        do { try await repository.removeRemoteMount(expectedConnection: baseline); XCTFail("卸载不能重放") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let reviewed = try await repository.reviewRemoteMountOperation(id: operation.id); XCTAssertEqual(reviewed?.stage, .completed)
        await assertWrites(transport, mounts: 0, unmounts: 1)
    }

    func test同位置断开未知核查后必须明确继续并重新输入密码() async throws {
        let transport = MockHTTPTransport(steps: oldPreflight().map { .response($0) } + [.urlError(.networkConnectionLost)] +
            [info(point, mounted: false), inventory()].map { .response($0) } +
            (createPreflight() + [success(), info(point, mounted: true), inventory([(point, source)])]).map { .response($0) })
        let repository = try self.repository(transport)
        do { try await repository.updateRemoteMount(expectedConnection: baseline(repository), configuration: configuration()); XCTFail("未知不能继续") } catch {}
        let operation = try await self.pending(repository)
        let ready = try await repository.reviewRemoteMountOperation(id: operation.id)
        XCTAssertEqual(ready?.stage, .readyToConnect); await assertWrites(transport, mounts: 0, unmounts: 1)
        do { _ = try await repository.continueRemoteMountOperation(id: operation.id, password: "new-secret", confirmed: false); XCTFail("继续必须确认") } catch {}
        let result = try await repository.continueRemoteMountOperation(id: operation.id, password: " new-secret ", confirmed: true)
        XCTAssertEqual(result?.stage, .completed)
        let cached = try await repository.continueRemoteMountOperation(id: operation.id, password: "ignored", confirmed: true); XCTAssertEqual(cached, result)
        await assertWrites(transport, mounts: 1, unmounts: 1)
        let requests = await transport.recordedRequests(); let mount = try XCTUnwrap(requests.first { field("method", $0) == "mount_remote" })
        XCTAssertEqual(field("passwd", mount), " new-secret ")
    }

    func test换位置继续在未知阶段只核查不卸载旧连接() async throws {
        let next = "/home/new"
        let finish = [inventory([(point, "//old.invalid/share"), (next, source)]), info(point, mounted: true), info(next, mounted: true),
            success(), info(point, mounted: false), inventory([(next, source)]), info(next, mounted: true), inventory([(next, source)])]
        let transport = MockHTTPTransport(steps: oldPreflight(destination: next).map { .response($0) } + [.urlError(.networkConnectionLost)] +
            ([info(next, mounted: true), inventory([(next, source)])] + finish).map { .response($0) })
        let repository = try self.repository(transport)
        do { try await repository.updateRemoteMount(expectedConnection: baseline(repository), configuration: configuration(next)); XCTFail("未知不能自动执行第二步") } catch {}
        let operation = try await self.pending(repository)
        let ready = try await repository.continueRemoteMountOperation(id: operation.id, password: "", confirmed: true)
        XCTAssertEqual(ready?.stage, .readyToDisconnectPrevious); await assertWrites(transport, mounts: 1, unmounts: 0)
        let completed = try await repository.continueRemoteMountOperation(id: operation.id, password: "not-needed", confirmed: true)
        XCTAssertEqual(completed?.stage, .completed); await assertWrites(transport, mounts: 1, unmounts: 1)
    }

    func test第二步明确拒绝保留可继续状态且不重复第一步() async throws {
        let initial = oldPreflight() + [success(), info(point, mounted: false), inventory()] + createPreflight() + [rejected()]
        let transport = MockHTTPTransport(responses: initial + createPreflight() + [success(), info(point, mounted: true), inventory([(point, source)])])
        let repository = try self.repository(transport)
        do { try await repository.updateRemoteMount(expectedConnection: baseline(repository), configuration: configuration()); XCTFail("第二步拒绝不能成功") } catch {}
        let operation = try await self.pending(repository); XCTAssertEqual(operation.stage, .readyToConnect)
        let completed = try await repository.continueRemoteMountOperation(id: operation.id, password: "corrected-password", confirmed: true)
        XCTAssertEqual(completed?.stage, .completed); await assertWrites(transport, mounts: 2, unmounts: 1)
    }

    func test第一次提交明确拒绝不留下永久未知锁() async throws {
        let transport = MockHTTPTransport(responses: createPreflight() + [rejected()] + createPreflight() + [success(), info(point, mounted: true), inventory([(point, source)])])
        let repository = try self.repository(transport)
        do { try await repository.createRemoteMount(configuration()); XCTFail("明确拒绝不能成功") } catch {}
        let pending = await repository.pendingRemoteMountOperations(); XCTAssertTrue(pending.isEmpty)
        try await repository.createRemoteMount(configuration(password: "corrected")); await assertWrites(transport, mounts: 2, unmounts: 0)
    }

    func test已发送后取消仍保留记录且不允许遗忘未知操作() async throws {
        let transport = MockHTTPTransport(steps: createPreflight().map { .response($0) } + [.waitUntilCancelled,
            .response(info(point, mounted: true)), .response(inventory([(point, source)]))])
        let repository = try self.repository(transport); let configuration = self.configuration()
        let task = Task { try await repository.createRemoteMount(configuration) }; defer { task.cancel() }
        for _ in 0..<500 {
            if (await transport.recordedRequests()).count >= 3 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let sent = await transport.recordedRequests(); _ = try XCTUnwrap(sent.first { field("method", $0) == "mount_remote" })
        task.cancel(); do { try await task.value; XCTFail("取消后不能未核查就成功") } catch {}
        let operation = try await self.pending(repository); XCTAssertEqual(operation.stage, .verifyingConnection)
        do { _ = try await repository.abandonRemoteMountOperation(id: operation.id, confirmed: true); XCTFail("未知不能直接遗忘") } catch {}
        let completed = try await repository.reviewRemoteMountOperation(id: operation.id)
        XCTAssertEqual(completed?.stage, .completed); await assertWrites(transport, mounts: 1, unmounts: 0)
    }

    func test待继续可以明确结束且不回滚已经完成的断开() async throws {
        let transport = MockHTTPTransport(responses: oldPreflight() + [success(), info(point, mounted: false), inventory()] + createPreflight() + [rejected()])
        let repository = try self.repository(transport)
        do { try await repository.updateRemoteMount(expectedConnection: baseline(repository), configuration: configuration()); XCTFail("拒绝不能成功") } catch {}
        let operation = try await self.pending(repository)
        do { _ = try await repository.abandonRemoteMountOperation(id: operation.id, confirmed: false); XCTFail("结束修改也需要明确确认") } catch {}
        let stopped = try await repository.abandonRemoteMountOperation(id: operation.id, confirmed: true)
        XCTAssertEqual(stopped?.stage, .cancelled)
        let pending = await repository.pendingRemoteMountOperations(); XCTAssertTrue(pending.isEmpty)
        await assertWrites(transport, mounts: 1, unmounts: 1)
    }

    func test继续前旧来源变化时保留新连接不盲目卸载() async throws {
        let next = "/home/new"
        let transport = MockHTTPTransport(steps: oldPreflight(destination: next).map { .response($0) } + [.urlError(.networkConnectionLost)] +
            [info(next, mounted: true), inventory([(next, source)]), inventory([(point, "//replacement.invalid/share"), (next, source)])].map { .response($0) })
        let repository = try self.repository(transport)
        do { try await repository.updateRemoteMount(expectedConnection: baseline(repository), configuration: configuration(next)); XCTFail("未知不能成功") } catch {}
        let operation = try await self.pending(repository); _ = try await repository.reviewRemoteMountOperation(id: operation.id)
        do { _ = try await repository.continueRemoteMountOperation(id: operation.id, password: "", confirmed: true); XCTFail("不能卸载替换来源") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        let pending = try await self.pending(repository); XCTAssertEqual(pending.stage, .readyToDisconnectPrevious)
        await assertWrites(transport, mounts: 1, unmounts: 0)
    }

    func test旧连接已由外部断开时核对最终状态而不重复卸载() async throws {
        let next = "/home/new"
        let transport = MockHTTPTransport(steps: oldPreflight(destination: next).map { .response($0) } + [.urlError(.networkConnectionLost)] +
            [info(next, mounted: true), inventory([(next, source)]), inventory([(next, source)]),
             info(point, mounted: false), inventory([(next, source)]), info(next, mounted: true), inventory([(next, source)])].map { .response($0) })
        let repository = try self.repository(transport)
        do { try await repository.updateRemoteMount(expectedConnection: baseline(repository), configuration: configuration(next)); XCTFail("未知不能成功") } catch {}
        let operation = try await self.pending(repository); _ = try await repository.reviewRemoteMountOperation(id: operation.id)
        let completed = try await repository.continueRemoteMountOperation(id: operation.id, password: "", confirmed: true)
        XCTAssertEqual(completed?.stage, .completed); await assertWrites(transport, mounts: 1, unmounts: 0)
    }

    func test未知编号和其他Repository不能接管恢复状态() async throws {
        let transport = MockHTTPTransport(steps: createPreflight().map { .response($0) } + [.urlError(.networkConnectionLost)])
        let repository = try self.repository(transport)
        do { try await repository.createRemoteMount(configuration()); XCTFail("未知不能成功") } catch {}
        let operation = try await self.pending(repository)
        let second = try self.repository(transport)
        let foreign = try await second.reviewRemoteMountOperation(id: operation.id); XCTAssertNil(foreign)
        let missing = try await repository.continueRemoteMountOperation(id: UUID(), password: "", confirmed: true); XCTAssertNil(missing)
        let secondPending = await second.pendingRemoteMountOperations(); XCTAssertTrue(secondPending.isEmpty)
        await assertWrites(transport, mounts: 1, unmounts: 0)
    }

    func test恢复配置保留NFS选项和只读意图但不携带密码() {
        let configuration = RemoteMountConfiguration(protocolType: .nfs, server: "server.invalid", remotePath: "share", mountPoint: point,
            readOnly: true, nfsVersion: .v4, nfsTransport: .tcp)
        let setup = RemoteMountSetup(configuration)
        let rebuilt = setup.configuration(password: "must-not-be-kept")
        XCTAssertEqual(rebuilt.nfsVersion, .v4); XCTAssertEqual(rebuilt.nfsTransport, .tcp)
        XCTAssertTrue(rebuilt.readOnly); XCTAssertEqual(rebuilt.password, "")
        XCTAssertEqual(String(reflecting: setup), "RemoteMountSetup")
    }

    func test无效DSM错误码不作为明确拒绝来解除未知锁() async throws {
        let transport = MockHTTPTransport(responses: createPreflight() + [response(["success": false, "error": ["code": 0]])])
        let repository = try self.repository(transport)
        do { try await repository.createRemoteMount(configuration()); XCTFail("错误回执不能成功") } catch {}
        let operation = try await self.pending(repository); XCTAssertEqual(operation.stage, .verifyingConnection)
        do { try await repository.createRemoteMount(configuration()); XCTFail("无效拒绝回执不能允许重发") }
        catch let error as AppError { XCTAssertEqual(error.category, .conflict) }
        await assertWrites(transport, mounts: 1, unmounts: 0)
    }

    private func pending(_ repository: DsmFileRepository) async throws -> RemoteMountOperation {
        let pending = await repository.pendingRemoteMountOperations(); XCTAssertEqual(pending.count, 1); return try XCTUnwrap(pending.first)
    }
    private func repository(_ transport: MockHTTPTransport) throws -> DsmFileRepository {
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001)
        let names = [DsmAPIName.fileStationMount, DsmAPIName.fileStationMountList, DsmAPIName.fileStationList]
        return try DsmFileRepository(profile: profile, capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { name in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: name == DsmAPIName.fileStationList ? 2 : 1,
                requestFormat: .form, selectedVersion: name == DsmAPIName.fileStationList ? 2 : 1))
        })), session: AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func configuration(_ destination: String = "/home/mount", password: String = "synthetic-secret") -> RemoteMountConfiguration {
        RemoteMountConfiguration(protocolType: .smb, server: "server.invalid", remotePath: "share", mountPoint: destination, username: "synthetic-user", password: password)
    }
    private func baseline(_ repository: DsmFileRepository) -> RemoteMountConnection {
        RemoteMountConnection(profileID: repository.profileID, mountPoint: point, source: "//old.invalid/share", protocolType: .smb, automaticMount: false)
    }
    private func createPreflight() -> [DsmHTTPResponse] { [inventory(), info(point, mounted: false)] }
    private func oldPreflight(destination: String? = nil) -> [DsmHTTPResponse] {
        var result = [inventory([(point, "//old.invalid/share")]), info(point, mounted: true)]
        if let destination { result.append(info(destination, mounted: false)) }
        return result
    }
    private func info(_ path: String, mounted: Bool) -> DsmHTTPResponse {
        response(["success": true, "data": ["files": [["name": URL(fileURLWithPath: path).lastPathComponent,
            "path": path, "isdir": true, "additional": ["mount_point_type": mounted ? "remote" : "normal"]]]]])
    }
    private func inventory(_ rows: [(String, String)] = []) -> DsmHTTPResponse {
        response(["success": true, "data": ["mountConfig": ["enable_remote_mount": true],
            "remoteList": rows.map { path, source in ["mount_point": path, "source": source, "type": "CIFS", "auto_mount": false] as [String: Any] }]])
    }
    private func success() -> DsmHTTPResponse { response(["success": true]) }
    private func rejected() -> DsmHTTPResponse { response(["success": false, "error": ["code": 105]]) }
    private func response(_ object: [String: Any]) -> DsmHTTPResponse { DsmHTTPResponse(data: try! JSONSerialization.data(withJSONObject: object), statusCode: 200) }
    private func field(_ key: String, _ request: URLRequest) -> String? {
        URLComponents(string: "?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == key }?.value
    }
    private func assertWrites(_ transport: MockHTTPTransport, mounts: Int, unmounts: Int) async {
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { field("method", $0) == "mount_remote" }.count, mounts)
        XCTAssertEqual(requests.filter { field("method", $0) == "unmount" }.count, unmounts)
    }
}
