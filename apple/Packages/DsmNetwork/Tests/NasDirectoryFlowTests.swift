import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasDirectoryFlowTests: XCTestCase {
    func test账号新建编辑删除固定版本并保存每个写边界() async throws {
        let transport = DirectoryFlowTransport(), repository = try repository(transport), checkpoints = DirectoryCheckpointLog()
        let create = NasDirectoryChange.saveUser(original: nil, draft: .init(name: "new-user", description: "New", email: "new@example.invalid", password: "synthetic-only", passwordConfirmation: "synthetic-only"), groups: nil)
        var result = try await repository.changeDirectoryResult(create) { await checkpoints.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let directory = try await repository.loadAccountDirectoryForManagement(), account = try XCTUnwrap(directory.users.first { $0.name == "new-user" })
        result = try await repository.changeDirectoryResult(.saveUser(original: account, draft: draft(account, description: "Edited"), groups: nil)) { await checkpoints.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let updated = try await repository.loadAccountDirectoryForManagement().users.first { $0.name == "new-user" }
        result = try await repository.changeDirectoryResult(.delete(try XCTUnwrap(updated))) { await checkpoints.append($0) }
        XCTAssertEqual(result.status, .confirmedSuccess)
        let writes = await transport.writes
        XCTAssertEqual(writes.map { $0["method"] }, ["create", "set", "delete"])
        XCTAssertTrue(writes.allSatisfy { $0["version"] == "1" })
        XCTAssertEqual(writes[0]["password"], "synthetic-only"); XCTAssertNil(writes[1]["password"]); XCTAssertNil(writes[1]["groups"])
        XCTAssertEqual(writes[2]["name"], "[\"new-user\"]")
        let stages = await checkpoints.values; XCTAssertEqual(stages, ["willSubmit", "accepted", "willSubmit", "accepted", "willSubmit", "accepted"])
    }

    func test群组新建编辑删除不混入账号字段() async throws {
        let transport = DirectoryFlowTransport(), repository = try repository(transport)
        let create = NasDirectoryChange.saveGroup(original: nil, draft: .init(name: "new-group", description: "New group"))
        let created = try await repository.changeDirectoryResult(create) { _ in }; XCTAssertEqual(created.status, .confirmedSuccess)
        let createdDirectory = try await repository.loadAccountDirectoryForManagement()
        let group = try XCTUnwrap(createdDirectory.groups.first { $0.name == "new-group" })
        let edited = try await repository.changeDirectoryResult(.saveGroup(original: group, draft: .init(originalName: group.name, name: group.name, description: "Edited group"))) { _ in }
        XCTAssertEqual(edited.status, .confirmedSuccess)
        let updatedDirectory = try await repository.loadAccountDirectoryForManagement()
        let updated = try XCTUnwrap(updatedDirectory.groups.first { $0.name == "new-group" })
        let deleted = try await repository.changeDirectoryResult(.delete(updated)) { _ in }; XCTAssertEqual(deleted.status, .confirmedSuccess)
        let writes = await transport.writes
        XCTAssertTrue(writes.allSatisfy { $0["api"] == DsmAPIName.coreGroup })
        for field in ["email", "expired", "groups", "password", "password_confirm"] { XCTAssertTrue(writes.allSatisfy { $0[field] == nil }, field) }
    }

    func test原对象数字身份或资料变化不能保存或删除() async throws {
        for deletion in [false, true] {
            let transport = DirectoryFlowTransport(), repository = try repository(transport)
            let original = try await repository.loadAccountDirectoryForManagement().users[0]
            await transport.replaceID()
            let change = deletion ? NasDirectoryChange.delete(original) : .saveUser(original: original, draft: draft(original, description: "Changed"), groups: nil)
            let result = try await repository.changeDirectoryResult(change) { _ in XCTFail("冲突不得提交") }
            XCTAssertFalse(result.submitted); XCTAssertEqual(result.status, .confirmedFailure)
            let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
        }
    }

    func test成员变更绑定群组完整原快照() async throws {
        let transport = DirectoryFlowTransport(), repository = try repository(transport)
        let directory = try await repository.loadAccountDirectoryForManagement(), original = directory.users[0]
        var desired = draft(original, description: "Changed"); desired.groups = ["sample-team"]
        await transport.replaceGroupID()
        let result = try await repository.changeDirectoryResult(.saveUser(original: original, draft: desired, groups: directory.groups)) { _ in XCTFail("群组被替换不能提交") }
        XCTAssertFalse(result.submitted)
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }

    func test当前账号停用改组删除和保留群组删除均零写() async throws {
        let transport = DirectoryFlowTransport(), repository = try repository(transport, username: "sample-user")
        let directory = try await repository.loadAccountDirectoryForManagement(), original = directory.users[0]
        var disabled = draft(original, description: "Changed"); disabled.isExpired = true
        var membership = draft(original, description: "Changed"); membership.groups = ["sample-team"]
        for change in [NasDirectoryChange.delete(original), .saveUser(original: original, draft: disabled, groups: nil),
                       .saveUser(original: original, draft: membership, groups: directory.groups), .delete(directory.groups[1])] {
            let result = try await repository.changeDirectoryResult(change) { _ in XCTFail("受保护对象不得提交") }
            XCTAssertFalse(result.submitted)
        }
        let writes = await transport.writes; XCTAssertTrue(writes.isEmpty)
    }

    func test创建重名改名与未知所属组均不提交() async throws {
        let transport = DirectoryFlowTransport(), repository = try repository(transport)
        let directory = try await repository.loadAccountDirectoryForManagement(), original = directory.users[0]
        var renamed = draft(original, description: "Changed"); renamed.name = "other"
        var unknown = draft(original, description: "Changed"); unknown.groups = ["missing"]
        for change in [NasDirectoryChange.saveUser(original: nil, draft: .init(name: original.name, password: "synthetic", passwordConfirmation: "synthetic"), groups: nil),
                       .saveUser(original: original, draft: renamed, groups: nil), .saveUser(original: original, draft: unknown, groups: directory.groups)] {
            let result = try await repository.changeDirectoryResult(change) { _ in XCTFail("不合法确认不得提交") }; XCTAssertFalse(result.submitted)
        }
    }

    func test普通资料丢回执可以只读恢复但改密码和创建保持未知() async throws {
        for scenario in ["edit", "password", "create"] {
            let transport = DirectoryFlowTransport(), repository = try repository(transport)
            let original = try await repository.loadAccountDirectoryForManagement().users[0]
            await transport.setMode("lost-ack")
            var desired = draft(original, description: "Changed")
            if scenario == "password" { desired.password = "synthetic"; desired.passwordConfirmation = "synthetic" }
            let change: NasDirectoryChange = scenario == "create"
                ? .saveGroup(original: nil, draft: .init(name: "new-group", description: "New"))
                : .saveUser(original: original, draft: desired, groups: nil)
            let result = try await repository.changeDirectoryResult(change) { _ in }
            XCTAssertEqual(result.status, scenario == "edit" ? .confirmedSuccess : .submittedButUnverified)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }

    func test删除模糊结果只读恢复且畸形回读不冒报消失() async throws {
        for mode in ["lost-ack", "malformed-after-write"] {
            let transport = DirectoryFlowTransport(), repository = try repository(transport)
            let original = try await repository.loadAccountDirectoryForManagement().users[0]
            await transport.setMode(mode)
            let result = try await repository.changeDirectoryResult(.delete(original)) { _ in }
            XCTAssertEqual(result.status, mode == "lost-ack" ? .confirmedSuccess : .submittedButUnverified)
            let writes = await transport.writes; XCTAssertEqual(writes.count, 1)
        }
    }

    func test明确拒绝不被之后的目录变化覆盖() async throws {
        let transport = DirectoryFlowTransport(), repository = try repository(transport)
        let original = try await repository.loadAccountDirectoryForManagement().users[0]
        await transport.setMode("denied")
        let result = try await repository.changeDirectoryResult(.delete(original)) { _ in }
        XCTAssertEqual(result.status, .permissionDenied)
        let calls = await transport.calls; XCTAssertEqual(calls.count, 5); XCTAssertEqual(calls.last?["method"], "delete")
    }

    func test写前与回执落盘失败不继续副作用或回读() async throws {
        for accepted in [false, true] {
            let transport = DirectoryFlowTransport(), repository = try repository(transport)
            let original = try await repository.loadAccountDirectoryForManagement().users[0]
            do {
                _ = try await repository.changeDirectoryResult(.delete(original)) { stage in
                    if (stage == .accepted) == accepted { throw DirectoryJournalFailure.failed }
                }; XCTFail("必须传回记录失败")
            } catch { XCTAssertTrue(error is DirectoryJournalFailure) }
            let writes = await transport.writes; XCTAssertEqual(writes.count, accepted ? 1 : 0)
            let calls = await transport.calls; XCTAssertEqual(calls.count, accepted ? 5 : 4)
        }
    }

    func test不支持固定版本零请求() async throws {
        let transport = DirectoryFlowTransport(), repository = try repository(transport, minVersion: 2)
        do { _ = try await repository.loadAccountDirectoryForManagement(); XCTFail("不应使用更高版本猜测") }
        catch { XCTAssertEqual((error as? AppError)?.category, .apiUnavailable) }
        let calls = await transport.calls; XCTAssertTrue(calls.isEmpty)
    }

    private func draft(_ original: NasAccount, description: String) -> NasAccountDraft {
        .init(originalName: original.name, name: original.name, description: description, email: original.email ?? "", isExpired: original.isExpired)
    }
    private func repository(_ transport: DirectoryFlowTransport, username: String = "operator", minVersion: Int = 1) throws -> DsmNasAdministrationRepository {
        let names = [DsmAPIName.coreUser, DsmAPIName.coreGroup]
        let capabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: minVersion, maxVersion: 3, requestFormat: .form, selectedVersion: 3)) }))
        return try .init(profile: NasProfile(displayName: "Synthetic", host: "nas.example.invalid", port: 5001, usernameHint: username), capabilities: capabilities,
            session: AuthSession(sid: "synthetic", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
}
private enum DirectoryJournalFailure: Error { case failed }
private actor DirectoryCheckpointLog {
    private(set) var values: [String] = []
    func append(_ value: NasDirectoryCheckpoint) { values.append(value == .willSubmit ? "willSubmit" : "accepted") }
}
private actor DirectoryFlowTransport: DsmHTTPTransport {
    private(set) var calls: [[String: String]] = []
    var writes: [[String: String]] { calls.filter { $0["method"] != "list" } }
    private var mode = "normal"
    private var users: [[String: Any]] = [["name": "sample-user", "uid": 1100, "description": "Sample", "email": "member@example.invalid", "expired": "normal", "groups": ["users"], "can_edit": true, "can_delete": true]]
    private var groups: [[String: Any]] = [["name": "sample-team", "gid": 2100, "description": "Team", "can_edit": true, "can_delete": true],
        ["name": "users", "gid": 100, "description": "All", "can_edit": true, "can_delete": false]]
    func replaceID() { users[0]["uid"] = 1199 }
    func replaceGroupID() { groups[0]["gid"] = 2199 }
    func setMode(_ value: String) { mode = value }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let text = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://fixture.invalid/?" + text)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields)
        let user = fields["api"] == DsmAPIName.coreUser, method = fields["method"] ?? ""
        if method == "list" {
            if mode == "malformed-after-write" && !writes.isEmpty { return response([:]) }
            return response([user ? "users" : "groups": user ? users : groups])
        }
        if mode == "denied" { users = []; return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
        var items = user ? users : groups
        if method == "delete" {
            let names = try JSONDecoder().decode([String].self, from: Data(fields["name"]!.utf8))
            items.removeAll { names.contains($0["name"] as? String ?? "") }
        } else {
            let name = fields["name"]!
            var item = items.first { $0["name"] as? String == name } ?? ["name": name, user ? "uid" : "gid": 3000, "can_edit": true, "can_delete": true]
            item["description"] = fields["description"]
            if user { item["email"] = fields["email"]; item["expired"] = fields["expired"] == "true" ? "now" : "normal"
                if let groups = fields["groups"] { item["groups"] = try JSONDecoder().decode([String].self, from: Data(groups.utf8)) }
            }
            items.removeAll { $0["name"] as? String == name }; items.append(item)
        }
        if user { users = items } else { groups = items }
        if mode == "lost-ack" { throw URLError(.networkConnectionLost) }
        return response([:])
    }
    private func response(_ value: [String: Any]) -> DsmHTTPResponse {
        .init(data: try! JSONSerialization.data(withJSONObject: ["success": true, "data": value]), statusCode: 200)
    }
}
