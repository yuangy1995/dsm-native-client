@testable import DsmMobile
import DsmCore
import DsmNetwork
import Foundation
import XCTest

@MainActor
final class MobileDownloadSettingsTests: XCTestCase {
    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadSettingsTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    private func profile() throws -> NasProfile { try NasProfile(displayName: "合成设备", host: "nas.example.invalid", port: 5001, usernameHint: "synthetic") }
    private func model(_ root: URL, transport: DownloadSettingsTransport, profile: NasProfile? = nil) throws -> MobileDownloadSettingsModel {
        let profile = try profile ?? self.profile(), model = MobileDownloadSettingsModel(root: root)
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: [(DsmAPIName.downloadStationInfo, 2), (DsmAPIName.downloadStationSchedule, 1)].map { name, version in
            (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version))
        }))
        let repository = try DsmServiceManagementRepository(profile: profile, capabilities: capabilities,
            session: AuthSession(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
        model.configure(profile: profile, repository: repository); return model
    }
    private func editBoth(_ model: MobileDownloadSettingsModel) {
        model.set(.autoExtract, to: .flag(true)); model.set(.schedule, to: .flag(true))
    }
    func test实际仓库分步差量保存以及快速重复点击不会重复请求() async throws {
        let root = root(), transport = DownloadSettingsTransport(), model = try model(root, transport: transport)
        await model.load(); editBoth(model); model.set(.ftpDownload, to: .number(32))
        model.chooseFolder("/folder with spaces ", activation: model.activation)
        XCTAssertEqual(model.draft[.destination], .text("folder with spaces "))
        XCTAssertEqual(model.draft[.httpDownload], .number(32))
        model.save(); let operation = model.operation; model.save(); await operation?.value
        XCTAssertEqual(model.entry?.steps.map(\.phase), [.complete, .complete]); XCTAssertFalse(model.canSave)
        let writes = await transport.writes
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0]["default_destination"], "folder with spaces ")
        XCTAssertEqual(writes[0]["http_max_download"], "32"); XCTAssertEqual(writes[0]["ftp_max_download"], "32")
        XCTAssertNil(writes[0]["bt_max_download"]); XCTAssertEqual(writes[1]["enabled"], "true")
        XCTAssertNil(writes[1]["emule_enabled"])
        let restored = MobileDownloadSettingsStore(root: root); XCTAssertEqual(restored.entries.first?.steps.map(\.phase), [.complete, .complete])
        let data = try String(contentsOf: root.appendingPathComponent("settings-v1.json"), encoding: .utf8)
        for forbidden in ["nas.example.invalid", "REDACTED_SESSION", "\"synthetic\"", "synoToken"] { XCTAssertFalse(data.contains(forbidden)) }
        let flags = try root.resourceValues(forKeys: [.isExcludedFromBackupKey]); XCTAssertEqual(flags.isExcludedFromBackup, true)
    }
    func test已确认保存后附加刷新失败仍更新本机基线避免重复保存() async throws {
        let transport = DownloadSettingsTransport(failConfigRead: 4), model = try model(root(), transport: transport)
        await model.load(); model.set(.autoExtract, to: .flag(true)); model.save(); await model.operation?.value
        XCTAssertEqual(model.entry?.steps.first?.phase, .complete)
        XCTAssertEqual(model.snapshot?.values[.autoExtract], .flag(true)); XCTAssertEqual(model.draft[.autoExtract], .flag(true))
        XCTAssertFalse(model.canSave); XCTAssertNil(model.errorKey)
        model.save(); let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
    }
    func test未知结果重启后只读原步骤显式继续才保存计划() async throws {
        let root = root(), profile = try profile(), transport = DownloadSettingsTransport(unknownWrite: true)
        let first = try model(root, transport: transport, profile: profile)
        await first.load(); editBoth(first); first.save(); await first.operation?.value
        XCTAssertEqual(first.entry?.steps.map(\.phase), [.submitted, .planned]); XCTAssertFalse(first.canEdit)
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
        await transport.reconnect()
        let restored = try model(root, transport: transport, profile: profile)
        await restored.load(); await restored.operation?.value
        XCTAssertEqual(restored.entry?.steps.map(\.phase), [.complete, .planned])
        let recoveredCount = await transport.writes.count; XCTAssertEqual(recoveredCount, 1)
        restored.run(continuePlanned: true); await restored.operation?.value
        XCTAssertEqual(restored.entry?.steps.map(\.phase), [.complete, .complete])
        let writes = await transport.writes; XCTAssertEqual(writes.count, 2); XCTAssertEqual(writes.last?["method"], "setconfig")
    }
    func test取消剩余部分立即落盘并保留未知部分不能被重启复活() async throws {
        let root = root(), profile = try profile(), transport = DownloadSettingsTransport(unknownWrite: true)
        let first = try model(root, transport: transport, profile: profile)
        await first.load(); editBoth(first); first.save(); await first.operation?.value
        first.cancelRemaining()
        XCTAssertEqual(MobileDownloadSettingsStore(root: root).entries.first?.steps.map(\.phase), [.submitted, .cancelled])
        await transport.reconnect()
        let restored = try model(root, transport: transport, profile: profile)
        await restored.load(); await restored.operation?.value
        XCTAssertEqual(restored.entry?.steps.map(\.phase), [.complete, .cancelled]); XCTAssertTrue(restored.canEdit)
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
    }
    func test提交时取消剩余步骤以及切换账号保留原账号未知记录() async throws {
        let root = root(), profile = try profile(), transport = DownloadSettingsTransport(holdWrite: true)
        let first = try model(root, transport: transport, profile: profile)
        await first.load(); editBoth(first); first.save(); let operation = first.operation
        await transport.waitUntilHeld(); first.cancelRemaining()
        first.configure(profile: nil, repository: nil)
        await transport.release(); await operation?.value
        XCTAssertNil(first.snapshot); XCTAssertNil(first.entry); XCTAssertNil(first.errorKey)
        XCTAssertEqual(MobileDownloadSettingsStore(root: root).entries.first?.steps.map(\.phase), [.submitted, .cancelled])
        let count = await transport.writes.count; XCTAssertEqual(count, 1)
        let restored = try model(root, transport: transport, profile: profile)
        await restored.load(); await restored.operation?.value
        XCTAssertEqual(restored.entry?.steps.map(\.phase), [.complete, .cancelled])
    }
    func test写前取消立即保存决定且零写不显示虚假错误() async throws {
        let root = root(), transport = DownloadSettingsTransport(holdConfigRead: 2), model = try model(root, transport: transport)
        await model.load(); editBoth(model); model.save(); let operation = model.operation
        await transport.waitUntilHeld(); model.cancelRemaining(); await transport.release(); await operation?.value
        XCTAssertEqual(model.entry?.steps.map(\.phase), [.cancelled, .cancelled]); XCTAssertNil(model.errorKey)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        XCTAssertEqual(MobileDownloadSettingsStore(root: root).entries.first?.steps.map(\.phase), [.cancelled, .cancelled])
    }
    func test退出连接后旧读取结果不能覆盖新上下文() async throws {
        let transport = DownloadSettingsTransport(holdConfigRead: 1), model = try model(root(), transport: transport)
        let operation = Task { await model.load() }
        await transport.waitUntilHeld(); model.configure(profile: nil, repository: nil)
        await transport.release(); await operation.value
        XCTAssertNil(model.snapshot); XCTAssertTrue(model.draft.isEmpty); XCTAssertFalse(model.isLoading); XCTAssertNil(model.errorKey)
    }
    func test写前权限撤销或并发修改导致零写且显示可恢复错误() async throws {
        for permission in [false, true] {
            let transport = DownloadSettingsTransport(), model = try model(root(), transport: transport)
            await model.load(); model.set(.autoExtract, to: .flag(true))
            if permission { await transport.setManager(false) } else { await transport.set(.autoExtract, .flag(true)) }
            model.save(); await model.operation?.value
            XCTAssertEqual(model.entry?.steps.first?.phase, .failed)
            XCTAssertEqual(model.entry?.steps.first?.failure, permission ? .denied : .changed)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }
    func test缺失字段和不一致网页限速不可修改且未知权限保持只读() async throws {
        let transport = DownloadSettingsTransport()
        await transport.set(.autoExtract, nil); await transport.set(.httpDownload, .number(10)); await transport.setManager(nil)
        let model = try model(root(), transport: transport)
        await model.load(); XCTAssertFalse(model.canEdit)
        model.set(.autoExtract, to: .flag(true)); XCTAssertNil(model.draft[.autoExtract]); model.save()
        await transport.setManager(true); await model.load()
        model.set(.ftpDownload, to: .number(20)); XCTAssertEqual(model.draft[.ftpDownload], .number(0))
        model.set(.btDownload, to: .number(-1)); XCTAssertEqual(model.draft[.btDownload], .number(0))
        XCTAssertFalse(model.canSave)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test旧文件选择回调不能更改新账号草稿() async throws {
        let transport = DownloadSettingsTransport(), model = try model(root(), transport: transport)
        await model.load(); let token = model.activation
        model.configure(profile: nil, repository: nil)
        model.chooseFolder("/synthetic-folder", activation: token); XCTAssertTrue(model.draft.isEmpty)
    }
    func test损坏恢复记录保留原文件且禁止新保存() async throws {
        let root = root(); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("settings-v1.json"), original = Data("corrupt synthetic record".utf8)
        try original.write(to: file)
        let transport = DownloadSettingsTransport(), model = try model(root, transport: transport)
        await model.load(); XCTAssertTrue(model.recovery.failed); XCTAssertFalse(model.canEdit)
        model.set(.autoExtract, to: .flag(true)); model.save()
        XCTAssertEqual(try Data(contentsOf: file), original)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test恢复目录不可写时不发送设置且保持错误() async throws {
        let root = root(); try Data("synthetic file".utf8).write(to: root)
        let transport = DownloadSettingsTransport(), model = try model(root, transport: transport)
        await model.load(); model.set(.autoExtract, to: .flag(true)); model.save(); await model.operation?.value
        XCTAssertTrue(model.recovery.failed); XCTAssertEqual(model.errorKey, "download.settings.storage-error")
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }
    func test重复未完成上下文和跨分区伪造记录不能替换原文件() throws {
        let store = MobileDownloadSettingsStore(root: root()), context = String(repeating: "a", count: 64)
        let change = DownloadSettingsChange(group: .general, original: [.autoExtract: .flag(false)], desired: [.autoExtract: .flag(true)])
        let entry = MobileDownloadSettingsStore.Entry(id: UUID(), context: context, createdAt: Date(), steps: [.init(change: change)])
        try store.reserve(entry)
        XCTAssertThrowsError(try store.reserve(.init(id: UUID(), context: context, createdAt: Date(), steps: [.init(change: change)])))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertTrue(store.begin(entry.id)); XCTAssertFalse(store.begin(entry.id))
        try store.progress(entry.id, group: .general, phase: .submitted)
        XCTAssertThrowsError(try store.progress(entry.id, group: .general, phase: .planned))
        try store.cancelRemaining(entry.id); XCTAssertEqual(store.entry(entry.id)?.steps.first?.phase, .submitted)
        store.end(entry.id)
    }
}

private actor DownloadSettingsTransport: DsmHTTPTransport {
    var writes: [[String: String]] = []
    private var values: [DownloadSettingsField: DownloadSettingsValue] = [
        .destination: .text("synthetic-downloads"), .autoExtract: .flag(false), .emule: .flag(false),
        .btDownload: .number(0), .btUpload: .number(0), .httpDownload: .number(0), .ftpDownload: .number(0),
        .schedule: .flag(false), .emuleSchedule: .flag(false)]
    private var manager: Bool? = true
    private var unknownWrite: Bool
    private var disconnected = false
    private var holdWrite: Bool
    private var configReads = 0
    private let holdConfigRead: Int?
    private let failConfigRead: Int?
    private var held = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(unknownWrite: Bool = false, holdWrite: Bool = false, holdConfigRead: Int? = nil, failConfigRead: Int? = nil) {
        self.unknownWrite = unknownWrite; self.holdWrite = holdWrite; self.holdConfigRead = holdConfigRead
        self.failConfigRead = failConfigRead
    }
    func setManager(_ value: Bool?) { manager = value }
    func set(_ field: DownloadSettingsField, _ value: DownloadSettingsValue?) { values[field] = value }
    func reconnect() { disconnected = false; unknownWrite = false }
    func waitUntilHeld() async { if !held { await withCheckedContinuation { waiters.append($0) } } }
    func release() { holdWrite = false; continuation?.resume(); continuation = nil }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let fields = URLComponents(string: "https://example.invalid/?" + String(data: request.httpBody ?? Data(), encoding: .utf8)!)!.queryItems!
        let parameters = Dictionary(uniqueKeysWithValues: fields.map { ($0.name, $0.value ?? "") })
        let group: DownloadSettingsField.Group = parameters["api"] == DsmAPIName.downloadStationSchedule ? .schedule : .general
        if disconnected { throw URLError(.notConnectedToInternet) }
        var data: [String: Any] = [:]
        switch parameters["method"] {
        case "getinfo": if let manager { data["is_manager"] = manager }
        case "getconfig":
            if group == .general {
                configReads += 1
                if configReads == failConfigRead { throw URLError(.notConnectedToInternet) }
                if configReads == holdConfigRead {
                    held = true; waiters.forEach { $0.resume() }; waiters = []
                    await withCheckedContinuation { continuation = $0 }
                }
            }
            for (field, value) in values where field.group == group {
                switch value {
                case .text(let text): data[field.parameter] = text
                case .flag(let flag): data[field.parameter] = flag
                case .number(let number): data[field.parameter] = number
                }
            }
        case "setserverconfig", "setconfig":
            writes.append(parameters)
            for (field, old) in values where field.group == group {
                guard let value = parameters[field.parameter] else { continue }
                switch old {
                case .text: values[field] = .text(value)
                case .flag: values[field] = .flag(value == "true")
                case .number: values[field] = .number(Int(value)!)
                }
            }
            if holdWrite {
                held = true; waiters.forEach { $0.resume() }; waiters = []
                await withCheckedContinuation { continuation = $0 }
            }
            if unknownWrite { disconnected = true; throw URLError(.timedOut) }
        default: throw URLError(.badServerResponse)
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
}
