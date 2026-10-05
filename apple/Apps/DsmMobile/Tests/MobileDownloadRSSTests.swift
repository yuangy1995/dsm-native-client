@testable import DsmMobile
import DsmCore
import DsmNetwork
import Foundation
import XCTest

@MainActor
final class MobileDownloadRSSTests: XCTestCase {
    private func root() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadRSSTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }; return root
    }
    private func profile() throws -> NasProfile { try NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001, usernameHint: "synthetic") }
    private func repository(_ transport: RSSTransport, profile: NasProfile, supported: Bool = true) throws -> DsmServiceManagementRepository {
        let names = supported ? [DsmAPIName.downloadStationRSSSite, DsmAPIName.downloadStationRSSFeed] : []
        return try DsmServiceManagementRepository(profile: profile, capabilities: .init(Dictionary(uniqueKeysWithValues: names.map {
            ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 1, requestFormat: .form, selectedVersion: 1))
        })), session: .init(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func model(_ transport: RSSTransport, root: URL? = nil, profile: NasProfile? = nil, supported: Bool = true) throws -> MobileDownloadRSSModel {
        let profile = try profile ?? self.profile(), model = MobileDownloadRSSModel(root: root ?? self.root())
        model.configure(profile: profile, repository: try repository(transport, profile: profile, supported: supported)); return model
    }

    func test读取已有订阅与条目且不直接访问来源地址() async throws {
        let transport = RSSTransport(), model = try model(transport)
        await model.load(); let site = try XCTUnwrap(model.sites?.first)
        await model.loadFeeds(site)
        XCTAssertEqual(model.feeds?.first?.title, "Synthetic item"); XCTAssertEqual(model.feeds?.first?.sizeBytes, 4096)
        XCTAssertTrue(model.canUpdate(site)); XCTAssertFalse(model.isLoading); XCTAssertFalse(model.isLoadingFeeds)
        let requests = await transport.requests
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "nas.example.invalid" })
        XCTAssertTrue(requests.filter { RSSTransport.field("api", $0) == DsmAPIName.downloadStationRSSFeed }.allSatisfy { RSSTransport.field("id", $0) == "7" })
    }

    func test接受回执不等于订阅已更新且重复点击只发送一次() async throws {
        let transport = RSSTransport(), model = try model(transport)
        await model.load(); let site = try XCTUnwrap(model.sites?.first)
        model.update(site, activation: model.activation); let operation = model.operation
        model.update(site, activation: model.activation); await operation?.value
        XCTAssertEqual(model.entry(for: site)?.phase, .accepted); XCTAssertFalse(model.canUpdate(site))
        await model.load(); model.update(site, activation: model.activation)
        let writes = await transport.writes; XCTAssertEqual(writes, 1)
    }

    func test日期前进但仍更新中不提前结束记录() async throws {
        let transport = RSSTransport(), model = try model(transport)
        await model.load(); let site = try XCTUnwrap(model.sites?.first)
        model.update(site, activation: model.activation); await model.operation?.value
        await transport.setTime(1001, updating: true); await model.load()
        XCTAssertEqual(model.entries.first?.phase, .accepted)
        XCTAssertFalse(model.canUpdate(try XCTUnwrap(model.sites?.first)))
        await transport.setTime(1001, updating: false); await model.load()
        XCTAssertEqual(model.entries.first?.phase, .updated)
        XCTAssertTrue(model.canUpdate(try XCTUnwrap(model.sites?.first)))
    }

    func test未知写重启只读恢复原订阅并不重发() async throws {
        let root = root(), profile = try profile(), transport = RSSTransport(unknown: true)
        let first = try model(transport, root: root, profile: profile)
        await first.load(); let site = try XCTUnwrap(first.sites?.first)
        first.update(site, activation: first.activation); await first.operation?.value
        XCTAssertEqual(first.entries.first?.phase, .submitted); XCTAssertFalse(first.canUpdate(site))
        await transport.reconnect(); await transport.setTime(1001, updating: false)
        let restored = try model(transport, root: root, profile: profile)
        await restored.load()
        XCTAssertEqual(restored.entries.first?.phase, .updated)
        let writes = await transport.writes; XCTAssertEqual(writes, 1)
    }

    func test替换站点身份与缺失订阅不能证明原更新成功() async throws {
        let transport = RSSTransport(), model = try model(transport)
        await model.load(); let site = try XCTUnwrap(model.sites?.first)
        model.update(site, activation: model.activation); await model.operation?.value
        await transport.replaceSite(); await transport.setTime(2000, updating: false); await model.load()
        XCTAssertEqual(model.entries.first?.phase, .accepted)
        await model.loadFeeds(site); XCTAssertNil(model.feeds); XCTAssertEqual(model.feedErrorKey, "download.rss.changed")
        await transport.setEmpty(true); await model.load()
        XCTAssertEqual(model.sites, []); XCTAssertEqual(model.entries.first?.phase, .accepted)
        let writes = await transport.writes; XCTAssertEqual(writes, 1)
    }

    func test实际拒绝权限保留可恢复说明但不要求管理员身份() async throws {
        let transport = RSSTransport(denied: true), model = try model(transport)
        await model.load(); let site = try XCTUnwrap(model.sites?.first)
        XCTAssertTrue(model.canUpdate(site)); model.update(site, activation: model.activation); await model.operation?.value
        XCTAssertEqual(model.entries.first?.phase, .denied)
        let requests = await transport.requests
        XCTAssertFalse(requests.contains { RSSTransport.field("api", $0) == DsmAPIName.downloadStationInfo })
    }

    func test旧连接的迟到回执只归原记录且旧页面不能再次提交() async throws {
        let root = root(), profile = try profile(), transport = RSSTransport(holdWrite: true)
        let model = try model(transport, root: root, profile: profile)
        await model.load(); let site = try XCTUnwrap(model.sites?.first), activation = model.activation
        model.update(site, activation: activation); let operation = model.operation
        await transport.waitUntilHeld()
        model.configure(profile: profile, repository: try repository(transport, profile: profile))
        await transport.release(); await operation?.value
        XCTAssertNil(model.sites); XCTAssertFalse(model.isUpdating); XCTAssertNil(model.errorKey)
        XCTAssertEqual(model.entries.first?.phase, .accepted)
        await model.load(); model.update(site, activation: activation)
        let writes = await transport.writes; XCTAssertEqual(writes, 1)
    }

    func test切换账号隔离原更新且同UUID换用户仍隔离() async throws {
        let root = root(), original = try profile(), transport = RSSTransport()
        let model = try model(transport, root: root, profile: original)
        await model.load(); let site = try XCTUnwrap(model.sites?.first)
        model.update(site, activation: model.activation); await model.operation?.value
        let changed = try NasProfile(id: original.id, displayName: original.displayName,
            host: original.host, port: original.port, usernameHint: "another-synthetic")
        model.configure(profile: changed, repository: try repository(transport, profile: changed)); await model.load()
        XCTAssertTrue(model.entries.isEmpty); XCTAssertEqual(model.recovery.entries.count, 1)
        XCTAssertTrue(model.canUpdate(try XCTUnwrap(model.sites?.first)))
    }

    func test恢复记录不包含订阅或条目秘密且目录排除备份() async throws {
        let root = root(), transport = RSSTransport(), model = try model(transport, root: root)
        await model.load(); let site = try XCTUnwrap(model.sites?.first)
        model.update(site, activation: model.activation); await model.operation?.value
        let text = try String(contentsOf: root.appendingPathComponent("rss-v1.json"), encoding: .utf8)
        for privateValue in ["Synthetic subscription", "Synthetic item", "example.invalid", "synthetic-owner", "secret", "REDACTED_SESSION", "sid", "download_uri"] {
            XCTAssertFalse(text.contains(privateValue))
        }
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        XCTAssertEqual(MobileDownloadRSSStore(root: root).entries.first?.phase, .accepted)
    }

    func test损坏记录或目录不可写均保留原件并零提交() async throws {
        for corrupt in [false, true] {
            let root = root(), original = Data("synthetic broken record".utf8)
            let file = corrupt ? root.appendingPathComponent("rss-v1.json") : root
            if corrupt { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
            try original.write(to: file)
            let transport = RSSTransport(), model = try model(transport, root: root)
            await model.load(); let site = try XCTUnwrap(model.sites?.first)
            model.update(site, activation: model.activation); await model.operation?.value
            XCTAssertTrue(model.recovery.failed); XCTAssertFalse(model.canUpdate(site))
            XCTAssertEqual(try Data(contentsOf: file), original)
            let writes = await transport.writes; XCTAssertEqual(writes, 0)
        }
    }

    func test不支持与读取错误不伪装为空且断开清理页面() async throws {
        let unsupported = try model(RSSTransport(), supported: false)
        await unsupported.load(); XCTAssertNil(unsupported.sites); XCTAssertEqual(unsupported.errorKey, "download.rss.unsupported")
        let denied = try model(RSSTransport(readDenied: true))
        await denied.load(); XCTAssertNil(denied.sites); XCTAssertEqual(denied.errorKey, "download.rss.read-permission")
        let transport = RSSTransport(), model = try model(transport)
        await transport.disconnect(); await model.load()
        XCTAssertNil(model.sites); XCTAssertEqual(model.errorKey, "download.rss.load-error")
        await transport.reconnect(); await transport.setEmpty(true); await model.load()
        XCTAssertEqual(model.sites, []); XCTAssertNil(model.errorKey)
        model.configure(profile: nil, repository: nil)
        XCTAssertNil(model.sites); XCTAssertNil(model.feeds); XCTAssertFalse(model.isLoading); XCTAssertTrue(model.entries.isEmpty)
    }
}

private actor RSSTransport: DsmHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var writes = 0
    private var time = 1000
    private var updating = false
    private var empty = false
    private var url = "https://source.example.invalid/?secret=synthetic"
    private var disconnected = false
    private let unknown: Bool
    private let denied: Bool
    private let readDenied: Bool
    private let holdWrite: Bool
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(unknown: Bool = false, denied: Bool = false, holdWrite: Bool = false, readDenied: Bool = false) {
        self.unknown = unknown; self.denied = denied; self.holdWrite = holdWrite; self.readDenied = readDenied
    }
    func setTime(_ value: Int, updating: Bool) { time = value; self.updating = updating }
    func replaceSite() { url = "https://source.example.invalid/replaced" }
    func setEmpty(_ value: Bool) { empty = value }
    func reconnect() { disconnected = false }
    func disconnect() { disconnected = true }
    func waitUntilHeld() async { if !held { await withCheckedContinuation { waiters.append($0) } } }
    func release() { continuation?.resume(); continuation = nil }
    nonisolated static func field(_ name: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)?.queryItems?.first { $0.name == name }?.value
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        if disconnected { throw URLError(.notConnectedToInternet) }
        if readDenied && Self.field("method", request) == "list" {
            return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200)
        }
        if Self.field("method", request) == "refresh" {
            writes += 1
            if holdWrite { held = true; waiters.forEach { $0.resume() }; waiters = []; await withCheckedContinuation { continuation = $0 } }
            if denied { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
            if unknown { disconnected = true; throw URLError(.timedOut) }
            return .init(data: Data(#"{"success":true}"#.utf8), statusCode: 200)
        }
        let data: [String: Any]
        if Self.field("api", request) == DsmAPIName.downloadStationRSSSite {
            let items: [[String: Any]] = empty ? [] : [["id": 7, "title": "Synthetic subscription", "url": url,
                "username": "synthetic-owner", "is_updating": updating, "last_update": time]]
            data = ["sites": items, "offset": 0, "total": items.count]
        } else {
            data = ["feeds": [["title": "Synthetic item", "time": 1000, "size": "4096",
                "download_uri": "https://files.example.invalid/synthetic.torrent", "external_link": "https://page.example.invalid"]], "offset": 0, "total": 1]
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
}
