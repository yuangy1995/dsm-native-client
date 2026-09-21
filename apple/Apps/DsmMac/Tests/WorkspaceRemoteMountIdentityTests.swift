import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class WorkspaceRemoteMountIdentityTests: XCTestCase {
    func test确认前读取来源且确认后替换来源拒绝断开() async throws {
        let (model, profile, transport, _) = try makeModel()
        defer { cleanPreferences(profile.id) }
        let item = FileItem(profileID: profile.id, name: "mount", path: "/home/mount", kind: .directory)
        let prepared = await model.prepareRemoteMountConnection(item)
        let identity = try XCTUnwrap(prepared)
        XCTAssertEqual(identity.source, "//old.invalid/share"); XCTAssertEqual(identity.profileID, profile.id)
        await transport.replaceSource()
        let succeeded = await model.removeRemoteMount(identity)
        XCTAssertFalse(succeeded); XCTAssertTrue(model.statusIsError)
        let writes = await transport.writes; XCTAssertEqual(writes, 0)
        let requests = await transport.requestCount; XCTAssertEqual(requests, 2)
    }

    func test绑定身份可以完成断开且重复旧确认不再次卸载() async throws {
        let (model, profile, transport, _) = try makeModel()
        defer { cleanPreferences(profile.id) }
        let prepared = await model.prepareRemoteMountConnection(FileItem(profileID: profile.id, name: "mount", path: "/home/mount", kind: .directory))
        let identity = try XCTUnwrap(prepared)
        let first = await model.removeRemoteMount(identity); XCTAssertTrue(first)
        let second = await model.removeRemoteMount(identity); XCTAssertFalse(second)
        let writes = await transport.writes; XCTAssertEqual(writes, 1)
    }

    func test其他设备条目不能读取或提交当前连接() async throws {
        let (model, profile, transport, _) = try makeModel()
        defer { cleanPreferences(profile.id) }
        let foreignID = UUID()
        let prepared = await model.prepareRemoteMountConnection(FileItem(profileID: foreignID, name: "mount", path: "/home/mount", kind: .directory))
        XCTAssertNil(prepared)
        let foreign = RemoteMountConnection(profileID: foreignID, mountPoint: "/home/mount", source: "//old.invalid/share", protocolType: .smb, automaticMount: false)
        let succeeded = await model.removeRemoteMount(foreign)
        XCTAssertFalse(succeeded)
        let requests = await transport.requestCount; XCTAssertEqual(requests, 0)
    }

    func test预检缺少所选连接时不给确认窗口错误替代目标() async throws {
        let (model, profile, transport, _) = try makeModel()
        defer { cleanPreferences(profile.id) }
        let prepared = await model.prepareRemoteMountConnection(FileItem(profileID: profile.id, name: "missing", path: "/home/missing", kind: .directory))
        XCTAssertNil(prepared); XCTAssertTrue(model.statusIsError); XCTAssertFalse(model.isManagingRemoteMount)
        let writes = await transport.writes; XCTAssertEqual(writes, 0)
    }

    func test写后断网在重建工作区模型后仍可只读核查() async throws {
        let (model, profile, transport, repository) = try makeModel()
        defer { cleanPreferences(profile.id) }
        let prepared = await model.prepareRemoteMountConnection(FileItem(profileID: profile.id, name: "mount", path: "/home/mount", kind: .directory))
        let identity = try XCTUnwrap(prepared)
        await transport.failNextUnmountReadback()
        let result = await model.removeRemoteMount(identity); XCTAssertFalse(result)
        XCTAssertEqual(model.remoteMountOperations.count, 1)
        let reopened = WorkspaceModel(profile: profile, repository: repository, transferNotifier: NoopTransferNotifier(), preparePreviewCache: {})
        reopened.isFileModuleEnabled = true
        await reopened.refreshRemoteMountOperations()
        let operation = try XCTUnwrap(reopened.remoteMountOperations.first)
        XCTAssertEqual(operation.stage, .verifyingDisconnection)
        await reopened.continueRemoteMountOperation(operation, password: "", confirmed: false)
        let before = await transport.writes; XCTAssertEqual(before, 1)
        await reopened.reviewRemoteMountOperation(operation)
        XCTAssertTrue(reopened.remoteMountOperations.isEmpty); XCTAssertFalse(reopened.statusIsError)
        let after = await transport.writes; XCTAssertEqual(after, 1)
    }

    func test恢复阶段文案区分继续与最终完成() {
        XCTAssertNotEqual(WorkspaceModel.remoteMountStageResourceKey(.readyToConnect), WorkspaceModel.remoteMountStageResourceKey(.completed))
        XCTAssertNotEqual(WorkspaceModel.remoteMountStageResourceKey(.readyToDisconnectPrevious), WorkspaceModel.remoteMountStageResourceKey(.completed))
        XCTAssertNotEqual(WorkspaceModel.remoteMountStageResourceKey(.cancelled), WorkspaceModel.remoteMountStageResourceKey(.completed))
        XCTAssertEqual(WorkspaceModel.remoteMountStageResourceKey(.verifyingConnection), "remote-mount.recovery.unknown")
    }

    private func makeModel() throws -> (WorkspaceModel, NasProfile, RemoteIdentityTransport, DsmFileRepository) {
        let profile = try NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001)
        let transport = RemoteIdentityTransport()
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: [DsmAPIName.fileStationMount, DsmAPIName.fileStationMountList, DsmAPIName.fileStationList].map { name in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: name == DsmAPIName.fileStationList ? 2 : 1,
                requestFormat: .form, selectedVersion: name == DsmAPIName.fileStationList ? 2 : 1))
        }))
        let repository = try DsmFileRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        let model = WorkspaceModel(profile: profile, repository: repository, transferNotifier: NoopTransferNotifier(), preparePreviewCache: {})
        return (model, profile, transport, repository)
    }
    private func cleanPreferences(_ profileID: UUID) {
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasSuffix(profileID.uuidString) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private actor RemoteIdentityTransport: DsmBinaryHTTPTransport {
    private var source = "//old.invalid/share"
    private var mounted = true
    private var failReadAfterUnmount = false
    private var failNextInfo = false
    private(set) var writes = 0
    private(set) var requestCount = 0
    func replaceSource() { source = "//replacement.invalid/share" }
    func failNextUnmountReadback() { failReadAfterUnmount = true }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requestCount += 1
        let fields = URLComponents(string: "?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems ?? []
        guard let method = fields.first(where: { $0.name == "method" })?.value else { throw URLError(.badServerResponse) }
        let data: [String: Any]
        switch method {
        case "get":
            data = ["mountConfig": ["enable_remote_mount": true], "remoteList": mounted ?
                [["mount_point": "/home/mount", "source": source, "type": "CIFS", "auto_mount": false]] : []]
        case "getinfo":
            if failNextInfo { failNextInfo = false; throw URLError(.timedOut) }
            data = ["files": [["name": "mount", "path": "/home/mount", "isdir": true, "additional": ["mount_point_type": mounted ? "remote" : "normal"]]]]
        case "unmount": writes += 1; mounted = false; failNextInfo = failReadAfterUnmount; failReadAfterUnmount = false; data = [:]
        case "list_share": data = ["shares": [], "total": 0, "offset": 0]
        default: throw URLError(.unsupportedURL)
        }
        let object: [String: Any] = ["success": true, "data": data]
        return DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
}
