import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileNasReadTests: XCTestCase {
    private let pages: [MobileNasAdministrationDestination] = [.externalStorage, .processes, .shareAccess, .zram, .powerSchedule]

    func test五页通过真实适配器只读取且按需加载() async throws {
        let transport = NasReadTransport()
        let model = try makeModel(transport)
        let initial = await transport.recorded()
        XCTAssertTrue(initial.isEmpty)
        for page in pages { await model.loadIfNeeded(page) }
        XCTAssertEqual(model.state.externalStorage.phase, .content)
        XCTAssertEqual(model.state.externalStorage.value?.devices.first?.displayName, "Sample USB")
        XCTAssertEqual(model.state.processes.value?.processes.first?.processID, "42")
        XCTAssertEqual(model.state.shareAccess.value?.shares.map(\.name), ["First share", "Second share"])
        XCTAssertTrue(model.state.shareAccess.value?.shares.allSatisfy { $0.accessLevel == .unknown && !$0.canDelete } == true)
        XCTAssertEqual(model.state.zram.value?.isEnabled, true)
        XCTAssertEqual(model.state.powerSchedule.value?.entries.count, 2)
        XCTAssertEqual(model.state.powerSchedule.value?.timeZoneIdentifier, "Asia/Taipei")
        XCTAssertFalse(model.state.isRefreshing)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.count, 8)
        XCTAssertTrue(requests.allSatisfy { ["list", "get", "load", "list_share"].contains($0.method) })
        let processes = try XCTUnwrap(requests.first { $0.api == DsmAPIName.coreSystemProcess })
        XCTAssertEqual(processes.fields["start"], "0")
        XCTAssertEqual(processes.fields["limit"], "500")
        let shareOffsets = requests.filter { $0.method == "list_share" }.map { $0.fields["offset"] }
        XCTAssertEqual(shareOffsets, ["0", "1"])
        for page in pages { await model.loadIfNeeded(page) }
        let afterCachedLoad = await transport.recorded()
        XCTAssertEqual(afterCachedLoad.count, requests.count)
    }

    func test成功空列表与未知开关独立表达() async throws {
        let transport = NasReadTransport(state: "nas-read-empty")
        let model = try makeModel(transport)
        for page in pages { await model.refresh(page) }
        XCTAssertEqual(model.state.externalStorage.phase, .empty)
        XCTAssertEqual(model.state.processes.phase, .empty)
        XCTAssertEqual(model.state.shareAccess.phase, .empty)
        XCTAssertEqual(model.state.powerSchedule.phase, .empty)
        await transport.setState("nas-read-unknown")
        await model.refresh(.zram)
        XCTAssertEqual(model.state.zram.phase, .content)
        XCTAssertNil(model.state.zram.value?.isEnabled)
        XCTAssertNil(model.state.zram.value?.configuredBytes)
        XCTAssertEqual(model.state.zram.value?.algorithm, .unknown)
        XCTAssertNotEqual(MobileNasReadFormatting.enabled(nil), MobileNasReadFormatting.enabled(false))
    }

    func test读取失败不冒充空清单且刷新可恢复() async throws {
        let transport = NasReadTransport(state: "nas-read-error")
        let model = try makeModel(transport)
        for page in pages { await model.refresh(page) }
        XCTAssertEqual(model.state.externalStorage.phase, .error)
        XCTAssertEqual(model.state.processes.phase, .error)
        XCTAssertEqual(model.state.shareAccess.phase, .error)
        XCTAssertEqual(model.state.zram.phase, .error)
        XCTAssertEqual(model.state.powerSchedule.phase, .error)
        await transport.setState("nas-read-content")
        await model.refreshLoadedSections()
        XCTAssertEqual(model.state.externalStorage.phase, .content)
        XCTAssertEqual(model.state.processes.phase, .content)
        XCTAssertEqual(model.state.shareAccess.phase, .content)
        XCTAssertEqual(model.state.zram.phase, .content)
        XCTAssertEqual(model.state.powerSchedule.phase, .content)
    }

    func test缺少能力不猜测请求() async throws {
        let transport = NasReadTransport()
        let model = try makeModel(transport, supportsReads: false)
        for page in pages { await model.refresh(page) }
        XCTAssertEqual(model.state.externalStorage.phase, .unavailable)
        XCTAssertEqual(model.state.processes.phase, .unavailable)
        XCTAssertEqual(model.state.shareAccess.phase, .unavailable)
        XCTAssertEqual(model.state.zram.phase, .unavailable)
        XCTAssertEqual(model.state.powerSchedule.phase, .unavailable)
        let requests = await transport.recorded()
        XCTAssertTrue(requests.isEmpty)
    }

    func test局部来源失败保留设备与进程且明确不完整() async throws {
        let model = try makeModel(NasReadTransport(state: "nas-read-partial"))
        await model.refresh(.externalStorage)
        await model.refresh(.processes)
        XCTAssertEqual(model.state.externalStorage.phase, .content)
        XCTAssertEqual(model.state.externalStorage.value?.devices.count, 1)
        XCTAssertEqual(model.state.externalStorage.value?.unavailableConnections, [.eSATA])
        XCTAssertEqual(model.state.processes.phase, .content)
        XCTAssertEqual(model.state.processes.value?.groupsAreUnavailable, true)
        XCTAssertEqual(model.state.processes.value?.processes.count, 1)
    }

    func test后续失败保留原快照并标记刷新失败() async throws {
        let transport = NasReadTransport()
        let model = try makeModel(transport)
        for page in pages { await model.refresh(page) }
        let before = model.state
        await transport.setState("nas-read-error")
        await model.refreshLoadedSections()
        XCTAssertEqual(model.state.externalStorage.value, before.externalStorage.value)
        XCTAssertEqual(model.state.processes.value, before.processes.value)
        XCTAssertEqual(model.state.shareAccess.value, before.shareAccess.value)
        XCTAssertEqual(model.state.zram.value, before.zram.value)
        XCTAssertEqual(model.state.powerSchedule.value, before.powerSchedule.value)
        XCTAssertTrue(model.state.externalStorage.hasRefreshError)
        XCTAssertTrue(model.state.processes.hasRefreshError)
        XCTAssertTrue(model.state.shareAccess.hasRefreshError)
        XCTAssertTrue(model.state.zram.hasRefreshError)
        XCTAssertTrue(model.state.powerSchedule.hasRefreshError)
        XCTAssertFalse(model.state.isRefreshing)
    }

    func test五页加载取消均拒绝迟到响应() async throws {
        let apiByPage: [MobileNasAdministrationDestination: String] = [
            .externalStorage: DsmAPIName.coreExternalStorageUSB, .processes: DsmAPIName.coreSystemProcess,
            .shareAccess: DsmAPIName.fileStationList, .zram: DsmAPIName.coreHardwareZRAM,
            .powerSchedule: DsmAPIName.coreHardwarePowerSchedule]
        for page in pages {
            let transport = NasReadTransport(blockedAPI: apiByPage[page])
            let model = try makeModel(transport)
            let operation = Task { await model.refresh(page) }
            await transport.waitUntilBlocked()
            XCTAssertTrue(model.state.isRefreshing)
            model.cancel(page)
            XCTAssertFalse(model.state.isRefreshing)
            await transport.release()
            await operation.value
            XCTAssertEqual(model.state, MobileNasDetailsState())
        }
    }

    func test同一配置重新绑定不接收旧会话结果() async throws {
        let profileID = UUID()
        let old = NasReadTransport(blockedAPI: DsmAPIName.coreHardwareZRAM)
        let model = try makeModel(old, profileID: profileID)
        let request = Task { await model.refresh(.zram) }
        await old.waitUntilBlocked()
        let replacement = try makeRepository(NasReadTransport(state: "nas-read-unknown"), profileID: profileID)
        model.activate(profileID: profileID, repository: replacement)
        await model.refresh(.zram)
        await old.release()
        await request.value
        XCTAssertEqual(model.state.zram.phase, .content)
        XCTAssertNil(model.state.zram.value?.isEnabled)
    }

    func test未提供文件访问时只影响共享页() async throws {
        let transport = NasReadTransport()
        let model = try makeModel(transport, includeFileRepository: false)
        await model.refresh(.shareAccess)
        XCTAssertEqual(model.state.shareAccess.phase, .unavailable)
        await model.refresh(.zram)
        XCTAssertEqual(model.state.zram.phase, .content)
        let requests = await transport.recorded()
        XCTAssertEqual(requests.map(\.api), [DsmAPIName.coreHardwareZRAM])
    }

    func test电源开关筛选不把未知当关闭() {
        XCTAssertTrue(MobileNasScheduleFilter.all.includes(nil))
        XCTAssertFalse(MobileNasScheduleFilter.enabled.includes(nil))
        XCTAssertFalse(MobileNasScheduleFilter.disabled.includes(nil))
        XCTAssertTrue(MobileNasScheduleFilter.enabled.includes(true))
        XCTAssertTrue(MobileNasScheduleFilter.disabled.includes(false))
    }

    func test时间按语言格式化且不按设备时区转换() {
        let old = NSTimeZone.default
        defer { NSTimeZone.default = old }
        for identifier in ["America/Los_Angeles", "Asia/Shanghai", "Pacific/Auckland"] {
            NSTimeZone.default = TimeZone(identifier: identifier)!
            XCTAssertEqual(MobileNasReadFormatting.time(hour: 8, minute: 15, locale: Locale(identifier: "en_GB")), "08:15")
            XCTAssertEqual(MobileNasReadFormatting.time(hour: 22, minute: 30, locale: Locale(identifier: "en_GB")), "22:30")
        }
    }

    func test搜索可清空且保留未知和零容量区别() {
        XCTAssertTrue(MobileNasReadFormatting.matches("  ", values: [nil]))
        XCTAssertTrue(MobileNasReadFormatting.matches(" SAMPLE ", values: ["Sample process", nil]))
        XCTAssertFalse(MobileNasReadFormatting.matches("unmatched", values: ["Sample process", nil]))
        XCTAssertNotEqual(MobileNasReadFormatting.bytes(nil), MobileNasReadFormatting.bytes(0))
    }

    private func makeModel(_ transport: NasReadTransport, profileID: UUID = UUID(), supportsReads: Bool = true,
                           includeFileRepository: Bool = true) throws -> MobileNasDetailsModel {
        let model = MobileNasDetailsModel()
        model.activate(profileID: profileID, repository: try makeRepository(transport, profileID: profileID,
            supportsReads: supportsReads, includeFileRepository: includeFileRepository))
        return model
    }

    private func makeRepository(_ transport: NasReadTransport, profileID: UUID, supportsReads: Bool = true,
                                includeFileRepository: Bool = true) throws -> MobileReadOnlyNasDetailsRepository {
        let profile = try NasProfile(id: profileID, displayName: "Synthetic NAS", host: "nas.example.invalid", port: 5001)
        let names = supportsReads ? MobileNasReadUIFixture.apiNames + [DsmAPIName.fileStationList] : []
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { name in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: 2,
                                 requestFormat: .form, selectedVersion: 1, verified: false))
        }))
        let session = AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false)
        let base = try DsmNasAdministrationRepository(profile: profile, capabilities: capabilities, session: session, transport: transport)
        let file = try DsmFileRepository(profile: profile, capabilities: capabilities, session: session, transport: transport)
        return MobileReadOnlyNasDetailsRepository(profileID: profileID, base: base, fileRepository: includeFileRepository ? file : nil)
    }
}

private actor NasReadTransport: DsmBinaryHTTPTransport {
    struct Request: Sendable { let api: String; let method: String; let fields: [String: String] }
    private var requests: [Request] = []
    private var state: String
    private let blockedAPI: String?
    private var didBlock = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?

    init(state: String = "nas-read-content", blockedAPI: String? = nil) {
        self.state = state; self.blockedAPI = blockedAPI
    }

    func setState(_ state: String) { self.state = state }
    func recorded() -> [Request] { requests }
    func waitUntilBlocked() async {
        if waiting != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { waiting?.resume(); waiting = nil }

    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        XCTFail("NAS 读取不得触发文件下载")
        throw URLError(.unsupportedURL)
    }

    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        XCTFail("NAS 读取不得触发上传")
        throw URLError(.unsupportedURL)
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let body = request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? request.url?.query ?? ""
        let query = URLComponents(string: "https://synthetic.invalid/?" + body)?.queryItems ?? []
        let fields = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        let api = fields["api"] ?? "", method = fields["method"] ?? ""
        requests.append(Request(api: api, method: method, fields: fields))
        if api == blockedAPI, !didBlock {
            didBlock = true
            await withCheckedContinuation { waiting = $0; started?.resume(); started = nil }
        }
        if state == "nas-read-error" || (state == "nas-read-partial" && [DsmAPIName.coreExternalStorageESATA, DsmAPIName.coreSystemProcessGroup].contains(api)) {
            throw URLError(.notConnectedToInternet)
        }
        let result: [String: Any]
        if api == DsmAPIName.fileStationList, method == "list_share" {
            let empty = state == "nas-read-empty", offset = Int(fields["offset"] ?? "0") ?? 0
            result = ["offset": offset, "total": empty ? 0 : 2,
                      "shares": empty ? [] : [["name": offset == 0 ? "First share" : "Second share", "path": offset == 0 ? "/first" : "/second", "isdir": true]]]
        } else if let value = MobileNasReadUIFixture.response(api: api, method: method, state: state) {
            result = value
        } else { throw URLError(.unsupportedURL) }
        return DsmHTTPResponse(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": result]), statusCode: 200)
    }
}
