import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasPackagePreferenceFlowTests: XCTestCase {
    func test管理读取保留未知策略且不把缺字段当手动更新覆盖() async throws {
        let transport = MockHTTPTransport(responses: [response(settings()), response(packages(unknown: true))]), repo = try repository(transport)
        let value = try await repo.loadPackagePreferencesForManagement()
        XCTAssertEqual(value.unknownUpdateIDs, ["Demo"])
        var selected = value.settings; selected.updatePolicy = .selected
        XCTAssertFalse(value.canSave(selected)); XCTAssertFalse(NasPackagePreferenceChange.settings(original: value, desired: selected).isValid)
        selected.updatePolicy = .manual; selected.emailNotifications = true; XCTAssertTrue(value.canSave(selected))
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { field("version", $0) }, ["1", "2"])
        XCTAssertEqual(field("limit", calls[1]), "1000")
        XCTAssertEqual(json("additional", calls[1]) as? [String], ["silent_upgrade", "autoupdate", "status"])
    }
    func test截断目录与畸形策略字段拒绝成为管理快照() async throws {
        for raw in [packages(total: 2), packages(invalid: true)] {
            let transport = MockHTTPTransport(responses: [response(settings()), response(raw)]), repo = try repository(transport)
            do { _ = try await repo.loadPackagePreferencesForManagement(); XCTFail() } catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
        }
    }
    func test默认位置缺省合法而错误类型不能变成默认空值() async throws {
        var absent = settings(); absent.removeValue(forKey: "default_vol")
        let transport = MockHTTPTransport(responses: [response(absent), response(packages())]), repo = try repository(transport)
        let value = try await repo.loadPackagePreferencesForManagement(); XCTAssertEqual(value.settings.defaultVolumeID, "")
        var malformed = settings(); malformed["default_vol"] = false
        let invalid = MockHTTPTransport(responses: [response(malformed)]), other = try repository(invalid)
        do { _ = try await other.loadPackagePreferencesForManagement(); XCTFail() } catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
        let calls = await invalid.recordedRequests(); XCTAssertEqual(calls.count, 1)
    }
    func test普通设置保存复用参数且只有完整回读才成功() async throws {
        let transport = MockHTTPTransport(responses: [response(settings()), response(packages()), response([:]), response(settings(email: true)), response(packages())]), repo = try repository(transport), log = PackagePreferenceCheckpoints()
        let before = baseline(); var after = before.settings; after.emailNotifications = true
        let result = try await repo.changePackagePreferencesResult(.settings(original: before, desired: after)) { await log.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.recordedRequests(), stages = await log.values
        XCTAssertEqual(calls.map { field("method", $0) }, ["get", "list", "set", "get", "list"])
        XCTAssertEqual(field("update_channel", calls[2]), "stable"); XCTAssertEqual(field("enable_email", calls[2]), "true")
        XCTAssertNil(field("default_vol", calls[2])); XCTAssertNil(field("packages", calls[2])); XCTAssertEqual(stages, [.willSubmit, .accepted])
    }
    func test按套件选择使用JSON文本且未知策略零写入() async throws {
        let transport = MockHTTPTransport(responses: [response(settings()), response(packages()), response([:]), response(settings(selected: true)), response(packages(latest: true))]), repo = try repository(transport, format: .json)
        let before = baseline(); var after = before.settings; after.updatePolicy = .selected; after.packageUpdates[0].policy = .latest
        let result = try await repo.changePackagePreferencesResult(.settings(original: before, desired: after)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.recordedRequests()
        let encoded = try XCTUnwrap(json("packages", calls[2]) as? String)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String], ["Demo"])
        let unknown = NasPackagePreferencesSnapshot(settings: before.settings, unknownUpdateIDs: ["Demo"])
        let denied = MockHTTPTransport(responses: []), other = try repository(denied)
        let blocked = try await other.changePackagePreferencesResult(.settings(original: unknown, desired: after)) { _ in XCTFail() }
        XCTAssertFalse(blocked.submitted); let noCalls = await denied.recordedRequests(); XCTAssertTrue(noCalls.isEmpty)
    }
    func test原设置变化在提交前停止() async throws {
        var changed = settings(); changed["enable_dsm"] = false
        let transport = MockHTTPTransport(responses: [response(changed), response(packages())]), repo = try repository(transport)
        let original = baseline(); var after = original.settings; after.emailNotifications = true
        let result = try await repo.changePackagePreferencesResult(.settings(original: original, desired: after)) { _ in XCTFail() }
        XCTAssertFalse(result.submitted); let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }
    func test保存后新增手动更新套件不改变已选自动更新清单() async throws {
        let before = baseline(); var after = before.settings; after.updatePolicy = .selected; after.packageUpdates[0].policy = .latest
        var newPackages = packages(latest: true)
        var rows = try XCTUnwrap(newPackages["packages"] as? [[String: Any]])
        rows.append(["id": "Other", "name": "Other", "additional": ["silent_upgrade": true, "autoupdate": false, "autoupdate_important": false, "status": "stopped"]])
        newPackages["packages"] = rows; newPackages["total"] = 2
        let transport = MockHTTPTransport(responses: [response(settings()), response(packages()), response([:]), response(settings(selected: true)), response(newPackages)]), repo = try repository(transport)
        let result = try await repo.changePackagePreferencesResult(.settings(original: before, desired: after)) { _ in }
        XCTAssertEqual(result.status, .confirmedSuccess)
    }
    func test来源添加编辑删除复用JSON文本并回读原始地址() async throws {
        for format in [DsmRequestFormat.form, .json] {
            for action in 0..<3 {
                let old = NasPackageSource(name: "Old", url: "https://packages.example.invalid/old"), new = NasPackageSource(name: "New", url: "https://packages.example.invalid/new")
                let change: NasPackagePreferenceChange = action == 0 ? .saveSource(new, replacing: nil) : action == 1 ? .saveSource(new, replacing: old) : .removeSource(old)
                let before = action == 0 ? [] : [old], after = action == 2 ? [] : [new]
                let transport = MockHTTPTransport(responses: [response(sources(before)), response([:]), response(sources(after))]), repo = try repository(transport, format: format), log = PackagePreferenceCheckpoints()
                let result = try await repo.changePackagePreferencesResult(change) { await log.append($0) }
                XCTAssertEqual(result.status, .confirmedSuccess)
                let calls = await transport.recordedRequests(), stages = await log.values
                XCTAssertEqual(calls.map { field("method", $0) }, ["list", ["add", "set", "delete"][action], "list"])
                XCTAssertTrue(calls.allSatisfy { field("version", $0) == "1" }); XCTAssertEqual(stages, [.willSubmit, .accepted])
                let raw = format == .json ? try XCTUnwrap(json("list", calls[1]) as? String) : try XCTUnwrap(field("list", calls[1]))
                let value = try JSONSerialization.jsonObject(with: Data(raw.utf8))
                if action == 2 { XCTAssertEqual(value as? [String], [old.url]) }
                else { XCTAssertEqual((value as? [String: String])?["feed"], new.url); XCTAssertEqual((value as? [String: String])?["orifeed"], action == 1 ? old.url : nil) }
            }
        }
    }
    func test来源URL无效或原来源变化均零写入() async throws {
        for url in ["ftp://packages.example.invalid", "https://user:password@packages.example.invalid", "https://packages.example.invalid/#part", "https://"] {
            let transport = MockHTTPTransport(responses: []), repo = try repository(transport)
            let result = try await repo.changePackagePreferencesResult(.saveSource(.init(name: "New", url: url), replacing: nil)) { _ in XCTFail() }
            XCTAssertFalse(result.submitted); let calls = await transport.recordedRequests(); XCTAssertTrue(calls.isEmpty)
        }
        let old = source(), changed = NasPackageSource(name: "Changed", url: source().url)
        let transport = MockHTTPTransport(responses: [response(sources([changed]))]), repo = try repository(transport)
        let result = try await repo.changePackagePreferencesResult(.removeSource(old)) { _ in XCTFail() }; XCTAssertFalse(result.submitted)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
    }
    func test部分或重复来源目录不能证明已删除() async throws {
        for raw in [sources([source()], total: 2), sources([source(), source()])] {
            let transport = MockHTTPTransport(responses: [response(raw)]), repo = try repository(transport)
            do { _ = try await repo.loadPackageSourcesForManagement(); XCTFail() } catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
        }
    }
    func test丢回执保持未知且不自动重放来源修改() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(sources([]))), .urlError(.timedOut)]), repo = try repository(transport), log = PackagePreferenceCheckpoints()
        let result = try await repo.changePackagePreferencesResult(.saveSource(source(), replacing: nil)) { await log.append($0) }
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertTrue(result.submitted)
        let calls = await transport.recordedRequests(), stages = await log.values
        XCTAssertEqual(calls.map { field("method", $0) }, ["list", "add"]); XCTAssertEqual(stages, [.willSubmit])
    }
    func test明确拒绝不继续读取匹配目标冒充成功() async throws {
        let transport = MockHTTPTransport(responses: [response(sources([])), denied(), response(sources([source()]))]), repo = try repository(transport)
        let result = try await repo.changePackagePreferencesResult(.saveSource(source(), replacing: nil)) { _ in }
        XCTAssertEqual(result.status, .permissionDenied); let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }
    func test接受后的回读权限失败保留未知而不是写入被拒绝() async throws {
        let transport = MockHTTPTransport(responses: [response(sources([])), response([:]), denied()]), repo = try repository(transport), log = PackagePreferenceCheckpoints()
        let result = try await repo.changePackagePreferencesResult(.saveSource(source(), replacing: nil)) { await log.append($0) }
        XCTAssertEqual(result.status, .submittedButUnverified); let stages = await log.values; XCTAssertEqual(stages, [.willSubmit, .accepted])
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.filter { field("method", $0) == "add" }.count, 1)
    }
    func test检查点写失败停止后续请求() async throws {
        for accepted in [false, true] {
            let transport = MockHTTPTransport(responses: [response(sources([])), response([:])]), repo = try repository(transport)
            let result = try await repo.changePackagePreferencesResult(.saveSource(source(), replacing: nil)) { stage in
                if stage == (accepted ? .accepted : .willSubmit) { throw PackagePreferenceJournalFailure() }
            }
            XCTAssertEqual(result.status, accepted ? .submittedButUnverified : .confirmedFailure)
            let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, accepted ? 2 : 1)
        }
    }
    func test写前取消不发送且旧入口共享互斥() async throws {
        let transport = MockHTTPTransport(responses: [response(sources([]))]), repo = try repository(transport), target = source()
        let task = Task {
            try await repo.changePackagePreferencesResult(.saveSource(target, replacing: nil)) { stage in
                if stage == .willSubmit {
                    do { _ = try await repo.savePackageSource(target, replacing: nil); XCTFail() } catch { }
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let result = try await task.value; XCTAssertEqual(result.status, .cancelledBeforeSubmission)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 1)
    }
    func test来源写证书异常透传且不继续读取() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(sources([]))), .urlError(.serverCertificateUntrusted)]), repo = try repository(transport)
        do { _ = try await repo.changePackagePreferencesResult(.saveSource(source(), replacing: nil)) { _ in }; XCTFail() }
        catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.count, 2)
    }
    func test低套件列表版本不降级保存但来源读取独立可用() async throws {
        let transport = MockHTTPTransport(responses: [response(settings()), response(sources([]))]), repo = try repository(transport, packageVersion: 1)
        do { _ = try await repo.loadPackagePreferencesForManagement(); XCTFail() } catch { XCTAssertEqual((error as? AppError)?.category, .apiUnavailable) }
        let values = try await repo.loadPackageSourcesForManagement(); XCTAssertTrue(values.isEmpty)
        let calls = await transport.recordedRequests(); XCTAssertEqual(calls.map { field("api", $0) }, [DsmAPIName.corePackageSetting, DsmAPIName.corePackageFeed])
    }
    private func baseline() -> NasPackagePreferencesSnapshot {
        .init(settings: .init(betaEnabled: false, emailNotifications: false, desktopNotifications: true, updatePolicy: .manual,
            defaultVolumeID: "/volume1", volumes: [.init(id: "/volume1", name: "Volume 1")], packageUpdates: [.init(id: "Demo", name: "Demo", canUpdateAutomatically: true, policy: .manual)]))
    }
    private func settings(email: Bool = false, selected: Bool = false) -> [String: Any] {
        ["update_channel": false, "enable_email": email, "enable_dsm": true, "enable_autoupdate": selected, "autoupdateall": false,
         "autoupdateimportant": false, "default_vol": "/volume1", "volume_list": [["mount_point": "/volume1", "display": "Volume 1"]]]
    }
    private func packages(latest: Bool = false, unknown: Bool = false, invalid: Bool = false, total: Int = 1) -> [String: Any] {
        var info: [String: Any] = ["silent_upgrade": true, "autoupdate": latest, "autoupdate_important": false, "status": "stopped"]
        if unknown { info.removeValue(forKey: "autoupdate"); info.removeValue(forKey: "autoupdate_important") }
        if invalid { info["autoupdate"] = "false" }
        return ["packages": [["id": "Demo", "name": "Demo", "additional": info]], "total": total]
    }
    private func source() -> NasPackageSource { .init(name: "Demo", url: "https://packages.example.invalid/feed") }
    private func sources(_ values: [NasPackageSource], total: Int? = nil) -> [String: Any] { ["items": values.map { ["name": $0.name, "feed": $0.url] }, "total": total ?? values.count] }
    private func response(_ value: [String: Any]) -> DsmHTTPResponse { .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": value]), statusCode: 200) }
    private func denied() -> DsmHTTPResponse { .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
    private func repository(_ transport: any DsmHTTPTransport, format: DsmRequestFormat = .form, packageVersion: Int = 2) throws -> DsmNasAdministrationRepository {
        let versions = [DsmAPIName.corePackage: packageVersion, DsmAPIName.corePackageSetting: 1, DsmAPIName.corePackageFeed: 1]
        return try .init(profile: .init(displayName: "Synthetic", host: "fixture.example.invalid", port: 5001, usernameHint: "operator"),
            capabilities: .init(Dictionary(uniqueKeysWithValues: versions.map { key, version in
                (key, ApiCapability(name: key, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: format, selectedVersion: version))
            })), session: .init(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func field(_ key: String, _ request: URLRequest) -> String? {
        var parts = URLComponents(); parts.percentEncodedQuery = String(data: request.httpBody ?? Data(), encoding: .utf8)
        return parts.queryItems?.first { $0.name == key }?.value
    }
    private func json(_ key: String, _ request: URLRequest) -> Any? { field(key, request).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) } }
}
private struct PackagePreferenceJournalFailure: Error { }
private actor PackagePreferenceCheckpoints { private(set) var values: [NasPackagePreferenceCheckpoint] = []; func append(_ value: NasPackagePreferenceCheckpoint) { values.append(value) } }
