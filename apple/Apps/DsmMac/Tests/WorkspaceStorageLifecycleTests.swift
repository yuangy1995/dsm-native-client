import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor
final class WorkspaceStorageLifecycleTests: XCTestCase {
    func test切走NAS中断容量后重新进入补读且两台结果和会话隔离() async throws {
        let firstTransport = StorageLifecycleTransport(total: 1_000, remaining: 250)
        let secondTransport = StorageLifecycleTransport(total: 2_000, remaining: 800)
        let first = try makeModel(host: "first.example.invalid", sid: "synthetic-first", transport: firstTransport)
        let second = try makeModel(host: "second.example.invalid", sid: "synthetic-second", transport: secondTransport)
        defer { clean(first); clean(second) }
        await firstTransport.holdNextCapacity()
        let opening = Task { await first.startEnabledModules() }
        try await waitUntilHeld(firstTransport)
        XCTAssertFalse(first.shares.isEmpty)
        opening.cancel()
        await opening.value
        XCTAssertNil(first.storageSpaceSummary)
        XCTAssertFalse(first.isLoadingStorageSpace)

        await second.startEnabledModules()
        XCTAssertEqual(second.storageSpaceSummary?.totalBytes, 2_000)
        await first.startEnabledModules()
        XCTAssertEqual(first.storageSpaceSummary?.totalBytes, 1_000)
        XCTAssertEqual(first.storageSpaceSummary?.remainingBytes, 250)
        XCTAssertEqual(second.storageSpaceSummary?.remainingBytes, 800)
        for (transport, host, sid) in [(firstTransport, "first.example.invalid", "synthetic-first"),
                                      (secondTransport, "second.example.invalid", "synthetic-second")] {
            let requests = await transport.requests
            XCTAssertFalse(requests.isEmpty)
            XCTAssertTrue(requests.allSatisfy { $0.url?.host == host })
            XCTAssertTrue(requests.allSatisfy { StorageLifecycleTransport.parameter("_sid", in: $0) == sid })
        }
    }

    func test容量刷新被取消保留该NAS旧值且关闭文件模块不读容量() async throws {
        let transport = StorageLifecycleTransport(total: 1_000, remaining: 250)
        let model = try makeModel(host: "first.example.invalid", sid: "synthetic-first", transport: transport)
        defer { clean(model) }
        await model.startEnabledModules()
        XCTAssertEqual(model.storageSpaceSummary?.totalBytes, 1_000)
        await transport.holdNextCapacity()
        let refresh = Task { await model.loadStorageSpace() }
        try await waitUntilHeld(transport)
        refresh.cancel()
        await refresh.value
        XCTAssertEqual(model.storageSpaceSummary?.remainingBytes, 250)
        XCTAssertFalse(model.isLoadingStorageSpace)
        model.isFileModuleEnabled = false
        let before = await transport.requests.count
        await model.loadStorageSpace()
        let after = await transport.requests.count
        XCTAssertEqual(after, before)
    }

    private func makeModel(host: String, sid: String, transport: StorageLifecycleTransport) throws -> WorkspaceModel {
        let profile = try NasProfile(displayName: "Synthetic NAS", host: host, port: 5001)
        let capability = ApiCapability(name: DsmAPIName.fileStationList, path: "entry.cgi", minVersion: 1,
                                       maxVersion: 2, requestFormat: .form, selectedVersion: 2)
        let repository = try DsmFileRepository(profile: profile, capabilities: .init([capability.name: capability]),
            session: AuthSession(sid: sid, synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        return WorkspaceModel(profile: profile, repository: repository, transferNotifier: NoopTransferNotifier(),
                              preparePreviewCache: {})
    }

    private func waitUntilHeld(_ transport: StorageLifecycleTransport) async throws {
        for _ in 0..<200 {
            if await transport.isHeld { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("容量请求未进入合成等待点")
    }

    private func clean(_ model: WorkspaceModel) {
        model.cancelAllWork()
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasSuffix(model.profile.id.uuidString) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}

private actor StorageLifecycleTransport: DsmBinaryHTTPTransport {
    let total: Int64
    let remaining: Int64
    private var holdsNextCapacity = false
    private(set) var isHeld = false
    private(set) var requests: [URLRequest] = []
    init(total: Int64, remaining: Int64) { self.total = total; self.remaining = remaining }
    func holdNextCapacity() { holdsNextCapacity = true }

    nonisolated static func parameter(_ name: String, in request: URLRequest) -> String? {
        var components = URLComponents()
        components.percentEncodedQuery = request.httpBody.map { String(decoding: $0, as: UTF8.self) }
        return components.queryItems?.first { $0.name == name }?.value
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        guard Self.parameter("method", in: request) == "list_share" else { throw URLError(.unsupportedURL) }
        if Self.parameter("limit", in: request) == "500", holdsNextCapacity {
            holdsNextCapacity = false; isHeld = true
            defer { isHeld = false }
            try await Task.sleep(for: .seconds(30))
            XCTFail("合成容量请求应在切换 NAS 时取消")
        }
        let body = #"{"success":true,"data":{"offset":0,"total":1,"shares":[{"name":"sample","path":"/sample","isdir":true,"additional":{"real_path":"/volume1/sample","volume_status":{"totalspace":\#(total),"freespace":\#(remaining)}}}]}}"#
        return DsmHTTPResponse(data: Data(body.utf8), statusCode: 200)
    }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        throw URLError(.unsupportedURL)
    }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        throw URLError(.unsupportedURL)
    }
}
