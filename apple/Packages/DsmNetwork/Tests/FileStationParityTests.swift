import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class FileStationParityTests: XCTestCase, @unchecked Sendable {
    func test真实空日期形态可读取且保留时分秒编辑不发送日期() async throws {
        let empty = ParityTransport([try sharePage(password: false, available: "", expires: "")])
        let links = try await repository(empty).listShareLinks()
        XCTAssertNil(links.first?.availableAt); XCTAssertNil(links.first?.expiresAt)
        let start = "2026-10-01 12:34:56", end = "2026-10-30 18:45:00"
        let transport = ParityTransport([try sharePage(password: true, available: start, expires: end), try response([:]),
            try sharePage(password: true, available: start, expires: end)])
        let baseline = FileShareLink(id: "synthetic-link", name: "item", path: "/synthetic/item", url: "https://example.invalid/shared",
            hasPassword: true, expiresAt: end, availableAt: start, availabilityDateKnown: true, status: .valid)
        let result = try await repository(transport).editShareLink(.init(baseline: baseline, password: .set("new-synthetic"),
            availableOn: nil, expiresOn: nil, keepsAvailableDate: true, keepsExpirationDate: true))
        XCTAssertEqual(result.result.status, .confirmedSuccess)
        let calls = await transport.requests
        XCTAssertNil(parameters(calls[1])["date_available"]); XCTAssertNil(parameters(calls[1])["date_expired"])
        XCTAssertEqual(result.confirmedLink?.availableAt, start)
    }

    func test目录来源按已启用服务读取域的真实标识且失败不吞掉其他来源() async throws {
        let transport = ParityTransport(try [response(["enable_client": true]), response(["enable_domain": true]),
            response(["test_join_success": true]), response(["domain_list": ["EXAMPLE", ["Example unit", "OU=Example,DC=invalid", "Description"]]])])
        let result = try await repository(transport).loadFileStationMountDirectories()
        XCTAssertEqual(result.items.map(\.source), [.local, .ldap, .domain("EXAMPLE"), .domain("OU=Example,DC=invalid")])
        XCTAssertEqual(result.items.last?.name, "Example unit"); XCTAssertFalse(result.hasUnavailableSources)
        let calls = await transport.requests
        XCTAssertEqual(calls.map { parameters($0)["method"] }, ["get", "get", "test_dc", "get_domain_list"])
        XCTAssertEqual(parameters(calls[3])["version"], "2")
        let partial = ParityTransport([.failure, try response(["enable_domain": false])])
        let report = try await repository(partial).loadFileStationMountDirectories()
        XCTAssertTrue(report.hasUnavailableSources); XCTAssertEqual(report.items.map(\.source), [.local])
        let malformed = ParityTransport(try [response(["enable_client": false]), response(["enable_domain": true]),
            response(["test_join_success": true]), response(["domain_list": [["display-only"]]])])
        let badReport = try await repository(malformed).loadFileStationMountDirectories()
        XCTAssertTrue(badReport.hasUnavailableSources); XCTAssertEqual(badReport.items.count, 1)
    }

    func test远程账号名单读取官方数字字符串编号() async throws {
        for kind in FileStationPrincipal.Kind.allCases {
            let key = kind == .user ? "uid" : "gid"
            let transport = ParityTransport([try response(["offset": 0, "total": 2, "usergrp_settings": [
                ["name": "synthetic-locked", key: "1001", "enabled": true, "is_modifiable": false],
                ["name": "synthetic-editable", key: "1002", "enabled": false, "is_modifiable": true]
            ]])])
            let page = try await repository(transport).listFileStationMountAccounts(kind: kind, query: "", offset: 0, limit: 100)
            XCTAssertEqual(page.items.map(\.id.value), [1001, 1002])
            XCTAssertTrue(page.items.allSatisfy { $0.id.kind == kind && $0.source == .local })
            XCTAssertEqual(page.items.map(\.enabled), [true, false])
            XCTAssertEqual(page.items.map(\.canModify), [false, true])
            XCTAssertEqual(page.nextOffset, 2)
            XCTAssertEqual(page.total, 2)
        }
    }

    func test远程账号名单拒绝无效或重复编号且布尔权限不作宽松转换() async throws {
        let invalidIDs: [Any] = ["", "not-an-id", "-1", -1, true, 1001.5, "9223372036854775808", NSNull()]
        for kind in FileStationPrincipal.Kind.allCases {
            let key = kind == .user ? "uid" : "gid"
            for id in invalidIDs {
                let transport = ParityTransport([try response(["total": 1, "usergrp_settings": [
                    ["name": "synthetic-user", key: id, "enabled": false, "is_modifiable": true]
                ]])])
                do {
                    _ = try await repository(transport).listFileStationMountAccounts(kind: kind, query: "", offset: 0, limit: 100)
                    XCTFail("无效编号必须拒绝，不能伪造账号身份")
                } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
            }
            let duplicate = ParityTransport([try response(["total": 2, "usergrp_settings": [
                ["name": "synthetic-a", key: 1001, "enabled": false, "is_modifiable": true],
                ["name": "synthetic-b", key: "1001", "enabled": false, "is_modifiable": true]
            ]])])
            do {
                _ = try await repository(duplicate).listFileStationMountAccounts(kind: kind, query: "", offset: 0, limit: 100)
                XCTFail("两种编码的相同编号仍属于同一身份，不能作为两个账号返回")
            } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
        for field in ["enabled", "is_modifiable"] {
            var row: [String: Any] = ["name": "synthetic-user", "uid": "1001", "enabled": false, "is_modifiable": true]
            row[field] = "true"
            let transport = ParityTransport([try response(["total": 1, "usergrp_settings": [row]])])
            do {
                _ = try await repository(transport).listFileStationMountAccounts(kind: .user, query: "", offset: 0, limit: 100)
                XCTFail("修复编号格式不能放宽权限布尔值")
            } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
    }

    func test远程账号数字字符串读取后保存与回读保持同一身份() async throws {
        let before = try response(["total": 1, "usergrp_settings": [
            ["name": "synthetic-user", "uid": "1001", "enabled": false, "is_modifiable": true]
        ]])
        let after = try response(["total": 1, "usergrp_settings": [
            ["name": "synthetic-user", "uid": 1001, "enabled": true, "is_modifiable": true]
        ]])
        let transport = ParityTransport([before] + (try accessResponses()) + [before, before, try response([:]), after])
        let repo = try repository(transport)
        let page = try await repo.listFileStationMountAccounts(kind: .user, query: "", offset: 0, limit: 100)
        let result = try await repo.changeFileStationSettings(.mountAccount(baseline: XCTUnwrap(page.items.first), enabled: true), confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        let writes = calls.filter { parameters($0)["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
        try assertRequestFixture(XCTUnwrap(writes.first), folder: "set-mount-account")
    }

    func test域和LDAP挂载账号按来源读取且单账号保存回读保留来源() async throws {
        for source in [FileStationMountAccountSource.ldap, .domain("OU=Example,DC=invalid")] {
            let row: (Bool) throws -> ParityTransport.Response = { enabled in
                try self.response(["total": 1, "usergrp_settings": [["name": "synthetic-group", "gid": 50001, "enabled": enabled, "is_modifiable": true]]])
            }
            let transport = ParityTransport(try [row(false)] + accessResponses() + [row(false), row(false), response([:]), row(true)])
            let repo = try repository(transport)
            let old = try await repo.listFileStationMountAccounts(source: source, kind: .group, query: "", offset: 0, limit: 100)
            let baseline = try XCTUnwrap(old.items.first)
            XCTAssertEqual(baseline.source, source)
            let result = try await repo.changeFileStationSettings(.mountAccount(baseline: baseline, enabled: true), confirmed: true)
            XCTAssertEqual(result.status, .confirmedSuccess)
            let calls = await transport.requests
            let reads = calls.filter { parameters($0)["content"] == "group_settings" }
            XCTAssertEqual(reads.count, 4)
            for read in reads {
                XCTAssertEqual(parameters(read)["type"], source.type)
                if case .domain(let id) = source { XCTAssertEqual(parameters(read)["domain"], id) }
                else { XCTAssertNil(parameters(read)["domain"]) }
            }
            let write = try XCTUnwrap(calls.first { parameters($0)["method"] == "set" })
            let settings = try JSONSerialization.jsonObject(with: Data(XCTUnwrap(parameters(write)["settings"]).utf8)) as? [String: [[String: Any]]]
            XCTAssertEqual(settings?["group_settings"]?.count, 1)
            XCTAssertEqual(settings?["group_settings"]?.first?["gid"] as? Int, 50001)
            XCTAssertEqual(settings?["group_settings"]?.first?["enabled"] as? Bool, true)
            XCTAssertNil(settings?["user_settings"])
        }
    }

    func test高级功能按真实权限开放而不要求实测开关() async throws {
        let allowed = ParityTransport(try accessResponses())
        let access = try await repository(allowed).loadFileStationAdvancedAccess()
        XCTAssertTrue(access.writesEnabled); XCTAssertTrue(access.isAdministrator)
        let accessCalls = await allowed.requests
        XCTAssertEqual(accessCalls.count, 1)
        XCTAssertEqual(parameters(accessCalls[0])["method"], "get_user_service")
        let denied = ParityTransport(try accessResponses(allowed: false))
        let request = try FileShareLinkEditRequest(baseline: advancedShare(), availableOn: nil, expiresOn: nil,
            advanced: .init(maximumAccesses: 8), keepsAvailableDate: true, keepsExpirationDate: true)
        do { _ = try await repository(denied).editShareLink(request); XCTFail("实际权限拒绝仍须阻止写入") }
        catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
        let calls = await denied.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertFalse(calls.contains { parameters($0)["method"] == "edit" })
    }

    func test具名分享发送完整成员与新增差量并回读() async throws {
        let transport = ParityTransport(try accessResponses() + [advancedSharePage(),
            response(["owners": [["name": "new-user", "type": "user"]], "total": 1]),
            advancedSharePage(), response([:]), advancedSharePage(users: ["new-user"], limit: 7)])
        let result = try await repository(transport).editShareLink(.init(baseline: advancedShare(),
            availableOn: nil, expiresOn: nil,
            advanced: .init(audience: .principals([.init(name: "new-user", kind: .user)]), maximumAccesses: 7),
            keepsAvailableDate: true, keepsExpirationDate: true))
        XCTAssertEqual(result.result.status, .confirmedSuccess)
        let calls = await transport.requests
        let write = try XCTUnwrap(calls.first { parameters($0)["method"] == "edit" })
        let fields = parameters(write)
        XCTAssertEqual(fields["protect_type"], "user")
        XCTAssertEqual(fields["protect_users"], "[\"new-user\"]")
        XCTAssertEqual(fields["new_protect_users"], "[\"new-user\"]")
        XCTAssertEqual(fields["protect_groups"], "[]")
        XCTAssertEqual(fields["expire_times"], "7")
        XCTAssertNil(fields["password"]); XCTAssertNil(fields["date_expired"])
    }

    func test高级分享未知结果不能再次修改() async throws {
        let transport = ParityTransport(try accessResponses() + [advancedSharePage(), advancedSharePage(), .failure, advancedSharePage()])
        let repo = try repository(transport)
        let request = try FileShareLinkEditRequest(baseline: advancedShare(), availableOn: nil, expiresOn: nil,
            advanced: .init(maximumAccesses: 8), keepsAvailableDate: true, keepsExpirationDate: true)
        let result = try await repo.editShareLink(request)
        XCTAssertEqual(result.result.status, .submittedButUnverified)
        do { _ = try await repo.editShareLink(request); XCTFail("未知写不得重放") }
        catch { XCTAssertEqual((error as? AppError)?.category, .conflict) }
        let calls = await transport.requests
        XCTAssertEqual(calls.filter { parameters($0)["method"] == "edit" }.count, 1)
    }

    func test文件收集只创建可写目录且核对请求类型和说明() async throws {
        let transport = ParityTransport(try accessResponses() + [
            response(["files": [["name": "item", "path": "/synthetic/item", "isdir": true, "additional": ["size": 0, "perm": ["adv_right": ["read": true, "write": true]]]]]]),
            response(["links": [], "total": 0, "offset": 0]),
            response(["links": [["id": "synthetic-link", "path": "/synthetic/item", "url": "https://example.invalid/shared", "error": 0]]]),
            advancedSharePage(fileRequest: true)])
        let repo = try repository(transport)
        let target = FileItem(profileID: repo.profileID, name: "item", path: "/synthetic/item", kind: .directory, sizeBytes: 0,
            permissions: .init(canRead: true, canWrite: true, canDelete: false, posixMode: nil))
        let result = try await repo.createShareLinkResult(.init(target: target, fileRequest: .init(name: "Collection", message: "Message")))
        XCTAssertEqual(result.result.status, .confirmedSuccess)
        XCTAssertEqual(result.confirmedLink?.advanced?.isFileRequest, true)
        let calls = await transport.requests
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "create" }))
        XCTAssertEqual(fields["file_request"], "true"); XCTAssertEqual(fields["request_name"], "Collection")
        XCTAssertEqual(fields["request_info"], "Message")
    }

    func test正文搜索保留名称不匹配项目并返回索引缺失状态() async throws {
        let transport = ParityTransport([try response(["taskid": "content", "has_not_index_share": true]),
            try response(["finished": true, "total": 1, "files": [["name": "report.txt", "path": "/synthetic/report.txt", "isdir": false]]]),
            try response([:])])
        let report = try await repository(transport).searchWithReport(.init(folders: ["/synthetic"], name: "正文关键词", searchesContents: true))
        XCTAssertEqual(report.items.first?.name, "report.txt")
        XCTAssertEqual(report.indexCoverage, .incomplete)
        let calls = await transport.requests
        XCTAssertEqual(parameters(calls[0])["search_content"], "true")
        XCTAssertEqual(parameters(calls[0])["search_type"], "advance")
        XCTAssertEqual(parameters(calls[0])["pattern"], "正文关键词")
    }

    func test正文搜索缺少索引状态时终止且不降级冒充成功() async throws {
        let transport = ParityTransport([try response(["taskid": "content"]), try response([:]), try response([:])])
        do {
            _ = try await repository(transport).searchWithReport(.init(folders: ["/synthetic"], name: "term", searchesContents: true))
            XCTFail("正文语义未经确认时必须拒绝")
        } catch { XCTAssertEqual((error as? AppError)?.category, .versionUnsupported) }
        let calls = await transport.requests
        XCTAssertEqual(calls.map { parameters($0)["method"] }, ["start", "stop", "clean"])
    }

    func test高级搜索发送全部条件完整分页并清理() async throws {
        let first = (0..<2_000).map { ["name": "\($0).txt", "path": "/synthetic/\($0).txt", "isdir": false] as [String: Any] }
        let transport = ParityTransport([
            try response(["taskid": "synthetic-search"]),
            try response(["finished": true, "total": 2_001, "files": first]),
            try response(["finished": true, "total": 2_001, "files": [["name": "last.txt", "path": "/synthetic/last.txt", "isdir": false]]]),
            try response([:])
        ])
        let repo = try repository(transport)
        let range = FileSearchTimeRange(from: Date(timeIntervalSince1970: 100), to: Date(timeIntervalSince1970: 200))
        let request = FileSearchRequest(folders: ["/synthetic/a", "/synthetic/b"], recursive: false, name: "*.txt",
            fileExtension: "txt,md", kind: .file, minimumBytes: 1_048_576, maximumBytes: 2_097_152,
            modified: range, created: range, accessed: range, owner: "synthetic-owner", group: "synthetic-group")
        let files = try await repo.search(request)
        XCTAssertEqual(files.count, 2_001)
        let requests = await transport.requests
        let fields = parameters(requests[0])
        let folderData = try XCTUnwrap(fields["folder_path"]?.data(using: .utf8))
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: folderData), ["/synthetic/a", "/synthetic/b"])
        XCTAssertEqual(fields["recursive"], "false"); XCTAssertEqual(fields["filetype"], "file")
        XCTAssertEqual(fields["extension"], "txt,md"); XCTAssertEqual(fields["size_from"], "1048576")
        XCTAssertEqual(fields["size_to"], "2097152"); XCTAssertEqual(fields["owner"], "synthetic-owner")
        XCTAssertEqual(fields["group"], "synthetic-group")
        for key in ["mtime", "crtime", "atime"] {
            XCTAssertEqual(fields[key + "_from"], "100"); XCTAssertEqual(fields[key + "_to"], "200")
        }
        XCTAssertEqual(parameters(requests[2])["offset"], "2000")
        XCTAssertEqual(parameters(requests[3])["method"], "clean")
    }

    func test高级搜索分页中断不能报告完整结果() async throws {
        let transport = ParityTransport([try response(["taskid": "search"]),
            try response(["finished": true, "total": 2, "files": [["name": "one", "path": "/synthetic/one", "isdir": false]]]),
            try response(["finished": true, "total": 2, "files": []]), try response([:]), try response([:])])
        do { _ = try await repository(transport).search(.init(folders: ["/synthetic"])); XCTFail("不能把不完整分页当作成功") }
        catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
        let calls = await transport.requests
        XCTAssertEqual(calls.suffix(2).map { parameters($0)["method"] }, ["stop", "clean"])
    }

    func test分享编辑区分保留设置移除密码并回读日期() async throws {
        let changes: [FileShareLinkPasswordChange] = [.keep, .set("synthetic-secret"), .remove]
        for (index, change) in changes.enumerated() {
            let transport = ParityTransport([try sharePage(password: true), try response([:]),
                try sharePage(password: index != 2, available: "2026-10-02", expires: "2026-10-08")])
            let repo = try repository(transport)
            let result = try await repo.editShareLink(.init(baseline: baselineShare(), password: change,
                availableOn: .init(iso8601: "2026-10-02"), expiresOn: .init(iso8601: "2026-10-08")))
            XCTAssertEqual(result.result.status, .confirmedSuccess)
            let calls = await transport.requests
            let fields = parameters(calls[1])
            XCTAssertEqual(fields["method"], "edit")
            XCTAssertEqual(fields["password"], index == 0 ? nil : index == 1 ? "synthetic-secret" : "")
            XCTAssertEqual(fields["date_available"], "2026-10-02")
            XCTAssertEqual(result.confirmedLink?.availableAt, "2026-10-02")
        }
    }

    func test设置密码超时不能用布尔状态冒充密码已核对() async throws {
        let transport = ParityTransport([try sharePage(password: true), .failure, try sharePage(password: true)])
        let result = try await repository(transport).editShareLink(.init(baseline: baselineShare(),
            password: .set("synthetic-secret"), availableOn: nil, expiresOn: nil))
        XCTAssertEqual(result.result.status, .submittedButUnverified)
        XCTAssertNil(result.confirmedLink)
        let calls = await transport.requests
        XCTAssertEqual(calls.filter { parameters($0)["method"] == "edit" }.count, 1)
    }

    func test分享确认后目标变化禁止修改() async throws {
        let transport = ParityTransport([try sharePage(password: false)])
        let result = try await repository(transport).editShareLink(.init(baseline: baselineShare(),
            password: .remove, availableOn: nil, expiresOn: nil))
        XCTAssertEqual(result.result.status, .confirmedFailure)
        let calls = await transport.requests; XCTAssertEqual(calls.count, 1)
    }

    func test压缩包超过二百项可分页兼容官方两种编号拼写() async throws {
        let rows = (0..<200).map { ["itemid": $0, "name": "\($0)", "path": "\($0)", "is_dir": false] as [String: Any] }
        let transport = ParityTransport([try response(["items": rows, "total": 201]),
            try response(["items": [["item_id": 200, "name": "last", "path": "last", "is_dir": false]], "total": 201])])
        let items = try await repository(transport).listArchiveItems(filePath: "/synthetic/archive.zip", codepage: "chs", password: nil)
        XCTAssertEqual(items.count, 201); XCTAssertEqual(items.last?.id, 200)
        let calls = await transport.requests; XCTAssertEqual(parameters(calls[1])["offset"], "200")
    }

    func test空选择不变成全包解压且越界路径被拒绝() async throws {
        let transport = ParityTransport([])
        do {
            try await repository(transport).extract(.init(filePath: "/synthetic/archive.zip", destination: "/synthetic/out", selection: .items([]))) { _, _ in }
            XCTFail("空选择必须拒绝")
        } catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
        let calls = await transport.requests; XCTAssertTrue(calls.isEmpty)
        for path in ["/absolute", "../escape", "a/../../escape", "C:\\escape"] {
            let unsafe = ParityTransport([try response(["items": [["itemid": 1, "name": "escape", "path": path, "is_dir": false]], "total": 1])])
            do {
                _ = try await repository(unsafe).listArchivePage(filePath: "/synthetic/archive.zip", parentID: -1, offset: 0, limit: 200, codepage: nil, password: nil)
                XCTFail("不安全路径必须拒绝")
            } catch { XCTAssertEqual((error as? AppError)?.category, .invalidResponse) }
        }
    }

    func test选择性解压仅发送选中编号() async throws {
        let transport = ParityTransport([try response(["taskid": "extract"]), try response(["finished": true, "progress": 1])])
        let selection = [ArchiveItem(id: 3, name: "a", path: "a", isDirectory: false), ArchiveItem(id: 8, name: "b", path: "b", isDirectory: false)]
        try await repository(transport).extract(.init(filePath: "/synthetic/archive.zip", destination: "/synthetic/out", selection: .items(selection))) { _, _ in }
        let calls = await transport.requests
        XCTAssertEqual(parameters(calls[0])["item_id"], "3,8")
        XCTAssertEqual(parameters(calls[0])["dest_folder_path"], "/synthetic/out")
    }

    func test清理任务明确指定编号且回读空列表() async throws {
        let transport = ParityTransport([try taskPage(finished: true), try response([:]), try response(["offset": 0, "total": 0, "tasks": []])])
        let result = try await repository(transport).controlBackgroundTask(task(finished: true), clearFinished: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        XCTAssertEqual(parameters(calls[1])["taskid"], "[\"synthetic-task\"]")
        XCTAssertEqual(parameters(calls[1])["method"], "clear_finished")
    }

    func test清理后列表损坏不能冒充任务消失() async throws {
        let transport = ParityTransport([try taskPage(finished: true), try response([:]), try response([:])])
        let result = try await repository(transport).controlBackgroundTask(task(finished: true), clearFinished: true)
        XCTAssertEqual(result.status, .submittedButUnverified)
    }

    func test停止任务确认前已完成时零写() async throws {
        let transport = ParityTransport([try taskPage(finished: true)])
        let result = try await repository(transport).controlBackgroundTask(task(finished: false), clearFinished: false)
        XCTAssertEqual(result.status, .confirmedFailure)
        let calls = await transport.requests; XCTAssertEqual(calls.count, 1)
    }

    func testISO只挂载明确的空目录且核对来源和自动挂载() async throws {
        let transport = ParityTransport(try accessResponses() + [isoInventory(), isoItems(),
            response(["offset": 0, "total": 0, "files": []]), response([:]), isoInventory(mounted: true), isoItems(mounted: true, destinationOnly: true)])
        let repo = try repository(transport)
        let result = try await repo.changeISOMount(isoChange(profileID: repo.profileID))
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "mount_iso" }), folder: "mount-iso", substitutions: ["<synthetic-source>": "/synthetic/disc.iso", "<synthetic-target>": "/synthetic/mount"])
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "mount_iso" }))
        XCTAssertEqual(fields["source"], "/synthetic/disc.iso"); XCTAssertEqual(fields["mount_point"], "/synthetic/mount")
        XCTAssertEqual(fields["auto_mount"], "true"); XCTAssertEqual(fields["user_set"], "true")
        XCTAssertFalse(calls.contains { parameters($0)["method"] == "create" || parameters($0)["api"] == DsmAPIName.fileStationDelete })
    }

    func testISO非空目标和已变化连接均禁止写入() async throws {
        let transport = ParityTransport(try accessResponses() + [isoInventory(), isoItems(),
            response(["offset": 0, "total": 1, "files": [["name": "occupied", "path": "/synthetic/mount/occupied", "isdir": false]]])])
        let repo = try repository(transport)
        do { _ = try await repo.changeISOMount(isoChange(profileID: repo.profileID)); XCTFail("不能遮蔽现有内容") } catch { }
        let calls = await transport.requests
        XCTAssertFalse(calls.contains { parameters($0)["method"] == "mount_iso" })
        let changed = ParityTransport(try accessResponses() + [isoInventory(mounted: true, source: "/synthetic/other.iso")])
        let changedRepo = try repository(changed)
        do { _ = try await changedRepo.changeISOMount(.unmount(.init(profileID: changedRepo.profileID,
            source: "/synthetic/disc.iso", mountPoint: "/synthetic/mount", automaticMount: true))); XCTFail("不能断开不同连接") } catch { }
        let changedCalls = await changed.requests
        XCTAssertFalse(changedCalls.contains { parameters($0)["method"] == "unmount" })
    }

    func testISO未知结果只核对不重放且不影响其他路径() async throws {
        let transport = ParityTransport(try accessResponses() + [isoInventory(), isoItems(),
            response(["offset": 0, "total": 0, "files": []]), .failure, isoInventory(), isoItems(destinationOnly: true)]
            + accessResponses() + [isoInventory(mounted: true), isoItems(mounted: true, destinationOnly: true)])
        let repo = try repository(transport)
        let change = isoChange(profileID: repo.profileID)
        let result = try await repo.changeISOMount(change)
        XCTAssertEqual(result.status, .submittedButUnverified)
        do { _ = try await repo.changeISOMount(change); XCTFail("未知结果不得重放") } catch { }
        let reviewed = try await repo.reviewISOMount(change)
        XCTAssertEqual(reviewed.status, .confirmedSuccess)
        let calls = await transport.requests; XCTAssertEqual(calls.filter { parameters($0)["method"] == "mount_iso" }.count, 1)
    }

    func test权限读取必须主动请求真实路径() async throws {
        let transport = ParityTransport(try permissionPages())
        let repo = try repository(transport)
        let snapshot = try await repo.loadFilePermissions(permissionItem(profileID: repo.profileID))
        XCTAssertEqual(snapshot.resolvedPath, "/volume-synthetic/synthetic/folder")
        XCTAssertTrue(snapshot.canChangePermissions)
        XCTAssertEqual(snapshot.owner?.canChange, true)
        let calls = await transport.requests
        let request = try XCTUnwrap(calls.first)
        let additional = try JSONDecoder().decode([String].self, from: Data(XCTUnwrap(parameters(request)["additional"]).utf8))
        XCTAssertTrue(additional.contains("real_path"), "NAS 只返回主动请求的附加字段，权限读取必须请求真实路径")
        XCTAssertTrue(additional.contains("perm"))
        XCTAssertTrue(additional.contains("owner"))
    }

    func test权限缺少实际路径时不猜测路径也不继续读取ACL() async throws {
        let transport = ParityTransport(try permissionPages(omitsRealPath: true))
        let repo = try repository(transport)
        do {
            _ = try await repo.loadFilePermissions(permissionItem(profileID: repo.profileID))
            XCTFail("缺少 NAS 返回的实际路径时不能读取或修改权限")
        } catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(parameters(calls[0])["api"], DsmAPIName.fileStationList)
        XCTAssertEqual(parameters(calls[0])["method"], "getinfo")
    }

    func test共享根挂载和回收站可读取ACL但不开放修改() async throws {
        for (path, mount) in [("/synthetic", "normal"), ("/synthetic", "shared_folder"),
                              ("/synthetic/mount", "cifs"), ("/synthetic/#recycle/folder", "normal")] {
            let transport = ParityTransport(try permissionPages(path: path, mountPointType: mount) + accessResponses())
            let repo = try repository(transport)
            let item = FileItem(profileID: repo.profileID, name: "Synthetic folder", path: path, kind: .directory)
            let snapshot = try await repo.loadFilePermissions(item)
            XCTAssertEqual(snapshot.target.path, path)
            XCTAssertEqual(snapshot.owner?.name, "synthetic-user")
            XCTAssertEqual(snapshot.rules.count, 2)
            XCTAssertFalse(snapshot.canChangePermissions)
            XCTAssertEqual(snapshot.owner?.canChange, false)
            var rules = snapshot.rules.filter { $0.level == 0 }; rules[0].rights.insert(.writeData)
            do {
                _ = try await repo.changeFilePermissions(.init(baseline: snapshot, explicitRules: rules,
                    confirmedScope: false, confirmedOwner: false, confirmedAccessRemoval: true))
                XCTFail("受保护位置只能读取，不得提交权限修改")
            } catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
            let calls = await transport.requests
            XCTAssertFalse(calls.contains { parameters($0)["method"] == "set" })
        }
    }

    func test共享根POSIX权限与所有者可以读取但不开放修改() async throws {
        let transport = ParityTransport(try posixPages(path: "/synthetic", mountPointType: "shared_folder"))
        let repo = try repository(transport)
        let snapshot = try await repo.loadFilePermissions(.init(profileID: repo.profileID, name: "Synthetic share", path: "/synthetic", kind: .directory))
        XCTAssertFalse(snapshot.isACL)
        XCTAssertEqual(snapshot.posixMode, "755")
        XCTAssertEqual(snapshot.target.owner, "synthetic-user")
        XCTAssertEqual(snapshot.target.group, "synthetic-group")
        XCTAssertFalse(snapshot.canChangePermissions)
    }

    func testACL仅写显式规则保留继承并等待后台任务完成() async throws {
        let transport = ParityTransport(try permissionPages() + accessResponses() + permissionPages()
            + [response(["is_denied": false])] + permissionPages()
            + [response(["task_id": "synthetic-permission-task"]), response(["finished": false])]
            + permissionPages(changed: true) + [response(["finished": true])] + permissionPages(changed: true))
        let repo = try repository(transport)
        let snapshot = try await repo.loadFilePermissions(permissionItem(profileID: repo.profileID))
        var rules = snapshot.rules.filter { $0.level == 0 }; rules[0].rights.insert(.writeData)
        let change = FilePermissionChange(baseline: snapshot, explicitRules: rules, recursive: true,
            confirmedScope: true, confirmedOwner: false, confirmedAccessRemoval: true)
        let initial = try await repo.changeFilePermissions(change)
        XCTAssertEqual(initial.status, .submittedButUnverified)
        let final = try await repo.reviewFilePermissions(change); XCTAssertEqual(final.status, .confirmedSuccess)
        let calls = await transport.requests
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "set" }), folder: "set-acl", substitutions: ["<synthetic-real-path>": "/volume-synthetic/synthetic/folder"])
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "set" }))
        let written = try JSONSerialization.jsonObject(with: XCTUnwrap(fields["rules"]?.data(using: .utf8))) as! [[String: Any]]
        XCTAssertEqual(written.count, 1); XCTAssertEqual(written[0]["owner_name"] as? String, "synthetic-user")
        XCTAssertEqual(fields["acl_recur"], "true"); XCTAssertEqual(fields["inherited"], "true")
        XCTAssertEqual(fields["file_path"], "/volume-synthetic/synthetic/folder")
    }

    func testACL自锁检查失败或权限基线变化都不写入() async throws {
        for denied in [true, false] {
            let responses = try permissionPages() + accessResponses() + permissionPages(changed: !denied)
                + (denied ? [response(["is_denied": true])] : [])
            let transport = ParityTransport(responses)
            let repo = try repository(transport)
            let snapshot = try await repo.loadFilePermissions(permissionItem(profileID: repo.profileID))
            var rules = snapshot.rules.filter { $0.level == 0 }; rules[0].rights.insert(.writeData)
            do { _ = try await repo.changeFilePermissions(.init(baseline: snapshot, explicitRules: rules,
                confirmedScope: false, confirmedOwner: false, confirmedAccessRemoval: true)); XCTFail("应拒绝修改") } catch { }
            let calls = await transport.requests
            XCTAssertFalse(calls.contains { parameters($0)["method"] == "set" })
        }
    }

    func testACL部分失败不能用根项目已修改冒充成功() async throws {
        let transport = ParityTransport(try permissionPages() + accessResponses() + permissionPages()
            + [response(["is_denied": false])] + permissionPages()
            + [response(["task_id": "synthetic-task"]), response(["finished": true, "result": "fail", "errItems": [[:]]])])
        let repo = try repository(transport)
        let snapshot = try await repo.loadFilePermissions(permissionItem(profileID: repo.profileID))
        var rules = snapshot.rules.filter { $0.level == 0 }; rules[0].rights.insert(.writeData)
        let change = FilePermissionChange(baseline: snapshot, explicitRules: rules, recursive: true,
            confirmedScope: true, confirmedOwner: false, confirmedAccessRemoval: true)
        let result = try await repo.changeFilePermissions(change)
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.localizationKey, "files.permissions.partial-failure")
        let pending = await repo.pendingFileStationChanges(); XCTAssertEqual(pending.first?.kind, .permissions)
        let reviewed = try await repo.reviewPendingFileStationChange(id: XCTUnwrap(pending.first).id)
        XCTAssertEqual(reviewed.localizationKey, "files.permissions.partial-failure")
        do { _ = try await repo.changeFilePermissions(change); XCTFail("不重放部分应用的权限写") } catch { }
        let calls = await transport.requests; XCTAssertEqual(calls.filter { parameters($0)["method"] == "set" }.count, 1)
    }

    func test设置只提交变化字段且保存前后核对() async throws {
        let transport = ParityTransport(try [settingsPage()] + accessResponses() + [settingsPage(), settingsPage(), response([:]), settingsPage(log: true)])
        let repo = try repository(transport)
        let old = try await repo.loadFileStationSettings(); var updated = old; updated.recordsTransfers = true
        let result = try await repo.changeFileStationSettings(.general(baseline: old, updated: updated), confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "set" }), folder: "set-package-settings")
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "set" }))
        XCTAssertEqual(fields["transfer_log_enable"], "true")
        XCTAssertNil(fields["sharing_allow"]); XCTAssertNil(fields["schedule_plan"]); XCTAssertNil(fields["link_limit"])
    }

    func test设置未知结果不会重复保存且可以只读核查() async throws {
        let transport = ParityTransport(try [settingsPage()] + accessResponses() + [settingsPage(), settingsPage(), .failure, settingsPage(), settingsPage(log: true)])
        let repo = try repository(transport)
        let old = try await repo.loadFileStationSettings(); var updated = old; updated.recordsTransfers = true
        let change = FileStationSettingsChange.general(baseline: old, updated: updated)
        let result = try await repo.changeFileStationSettings(change, confirmed: true)
        XCTAssertEqual(result.status, .submittedButUnverified)
        do { _ = try await repo.changeFileStationSettings(change, confirmed: true); XCTFail("不能重放未知设置") } catch { }
        let pending = await repo.pendingFileStationChanges(); XCTAssertEqual(pending.count, 1); XCTAssertEqual(pending.first?.kind, .general)
        let reviewed = try await repo.reviewPendingFileStationChange(id: XCTUnwrap(pending.first).id); XCTAssertEqual(reviewed.status, .confirmedSuccess)
        let remaining = await repo.pendingFileStationChanges(); XCTAssertTrue(remaining.isEmpty)
        let calls = await transport.requests; XCTAssertEqual(calls.filter { parameters($0)["method"] == "set" }.count, 1)
    }

    func test普通账号不可保存管理员设置且字段缺失不默认为关闭() async throws {
        let transport = ParityTransport(try [settingsPage()] + accessResponses(administrator: false))
        let repo = try repository(transport)
        let old = try await repo.loadFileStationSettings(); var updated = old; updated.recordsTransfers = true
        do { _ = try await repo.changeFileStationSettings(.general(baseline: old, updated: updated), confirmed: true); XCTFail("普通账号不可写设置") }
        catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
        let calls = await transport.requests; XCTAssertFalse(calls.contains { parameters($0)["method"] == "set" })
        let malformed = ParityTransport([try response(["transfer_log_enable": false])])
        do { _ = try await repository(malformed).loadFileStationSettings(); XCTFail("缺失字段不能作为关闭") } catch { }
    }

    func test设置提交期间核查入口不能提前清除待核查记录() async throws {
        let acknowledgement = try JSONSerialization.data(withJSONObject: ["success": true, "data": [:]])
        let transport = ParityTransport(try [settingsPage()] + accessResponses() +
            [settingsPage(), settingsPage(), .held(acknowledgement), settingsPage(log: true)])
        let repo = try repository(transport)
        let baseline = try await repo.loadFileStationSettings()
        var updated = baseline; updated.recordsTransfers = true
        let change = FileStationSettingsChange.general(baseline: baseline, updated: updated)
        let save = Task { try await repo.changeFileStationSettings(change, confirmed: true) }
        await transport.waitUntilHeld()
        let before = await transport.requests.count
        do { _ = try await repo.reviewFileStationSettings(change); XCTFail("提交尚未结束，不得并发核查并清除记录") }
        catch { XCTAssertEqual((error as? AppError)?.category, .conflict) }
        let after = await transport.requests.count; XCTAssertEqual(after, before)
        await transport.releaseHeld()
        let result = try await save.value; XCTAssertEqual(result.status, .confirmedSuccess)
        let pending = await repo.pendingFileStationChanges(); XCTAssertTrue(pending.isEmpty)
    }

    func test分享授权发送明确账号差量不重写其他权限() async throws {
        let transport = ParityTransport(try [settingsPage()] + accessResponses() + [settingsPage(),
            response(["users": [["uid": 1001, "name": "synthetic-user", "is_admin": false]], "total": 1]),
            settingsPage(), response([:]), settingsPage(sharingMember: true)])
        let repo = try repository(transport)
        let old = try await repo.loadFileStationSettings(); var updated = old
        updated.sharing = .selected; updated.sharingAccounts = [.init(kind: .user, value: 1001)]
        let result = try await repo.changeFileStationSettings(.general(baseline: old, updated: updated), confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "set" }))
        XCTAssertEqual(fields["enabled_sharing_privilege"], "1001"); XCTAssertEqual(fields["sharing_allow"], "per_user")
        XCTAssertNil(fields["disabled_sharing_privilege"]); XCTAssertNil(fields["enabled_file_request_privilege"])
    }

    func test限速读取未单独配置的用户和群组() async throws {
        for ownerType in [FileStationBandwidthEntry.OwnerType.localUser, .localGroup] {
            var root = URL(fileURLWithPath: #filePath)
            for _ in 0..<5 { root.deleteLastPathComponent() }
            let suffix = ownerType == .localUser ? "user" : "group"
            let fixture = root.appendingPathComponent("contracts/fixtures-redacted/file-station/settings/synthetic-bandwidth-unconfigured-" + suffix + "/response.json")
            let transport = ParityTransport([.success(try Data(contentsOf: fixture))])
            let repo = try repository(transport)
            let page = try await repo.listFileStationBandwidth(ownerType: ownerType, offset: 0, limit: 100)
            let row = try XCTUnwrap(page.items.first)
            XCTAssertEqual(row.policy.rawValue, "notexist", "未单独配置不能被当成不限速")
            XCTAssertEqual(row.ownerType, ownerType)
            XCTAssertEqual(page.total, 1); XCTAssertEqual(page.nextOffset, 1)
            let calls = await transport.requests
            XCTAssertEqual(calls.count, 1)
            XCTAssertEqual(parameters(calls[0])["method"], "list")
            XCTAssertEqual(parameters(calls[0])["owner_type"], ownerType.rawValue)
        }
    }

    func test未配置限速可明确设定并回读但不提交未配置标记() async throws {
        let schedule = String(repeating: "1", count: 168)
        let transport = ParityTransport(try [bandwidthPage(policy: "notexist")] + accessResponses()
            + [bandwidthPage(policy: "notexist"), bandwidthPage(policy: "notexist"), response([:]), bandwidthPage(limit: 42, schedule: schedule)])
        let repo = try repository(transport)
        let page = try await repo.listFileStationBandwidth(ownerType: .localUser, offset: 0, limit: 100)
        let old = try XCTUnwrap(page.items.first)
        var updated = old; updated.policy = .scheduled; updated.uploadLimit = 42; updated.schedule = schedule
        let result = try await repo.changeFileStationSettings(.bandwidth(baseline: old, updated: updated), confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        let writes = calls.filter { parameters($0)["method"] == "set" }
        XCTAssertEqual(writes.count, 1)
        try assertRequestFixture(XCTUnwrap(writes.first), folder: "set-bandwidth", substitutions: ["2" + String(repeating: "1", count: 167): schedule])

        let rejected = ParityTransport(try [bandwidthPage()] + accessResponses() + [bandwidthPage()])
        let rejectedRepo = try repository(rejected)
        let current = try await rejectedRepo.listFileStationBandwidth(ownerType: .localUser, offset: 0, limit: 100)
        let baseline = try XCTUnwrap(current.items.first)
        var reset = baseline; reset.policy = .notConfigured
        do { _ = try await rejectedRepo.changeFileStationSettings(.bandwidth(baseline: baseline, updated: reset), confirmed: true); XCTFail("不能猜测恢复群组配置的写入方式") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let rejectedCalls = await rejected.requests
        XCTAssertFalse(rejectedCalls.contains { parameters($0)["method"] == "set" })
    }

    func test限速未知策略及服务级未配置状态仍拒绝() async throws {
        for policy in ["unknown-policy", "", "NotExist"] {
            let transport = ParityTransport(try [bandwidthPage(policy: policy)])
            let repo = try repository(transport)
            do { _ = try await repo.listFileStationBandwidth(ownerType: .localUser, offset: 0, limit: 100); XCTFail("不能将未知策略默认成不限速") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        }
        let transport = ParityTransport(try [settingsPage()] + accessResponses() + [settingsPage()])
        let repo = try repository(transport)
        let baseline = try await repo.loadFileStationSettings()
        var updated = baseline; updated.bandwidth = .notConfigured
        do { _ = try await repo.changeFileStationSettings(.general(baseline: baseline, updated: updated), confirmed: true); XCTFail("账号状态不能写入服务总开关") }
        catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
        let calls = await transport.requests
        XCTAssertFalse(calls.contains { parameters($0)["method"] == "set" })
    }

    func test限速指定账号与每周时间编码并拒绝低于十的非零值() async throws {
        XCTAssertEqual(FileStationWeeklySchedule.index(day: 0, hour: 0), 0)
        XCTAssertEqual(FileStationWeeklySchedule.index(day: 1, hour: 0), 24)
        XCTAssertEqual(FileStationWeeklySchedule.index(day: 6, hour: 23), 167)
        XCTAssertNil(FileStationWeeklySchedule.index(day: 7, hour: 0))
        let schedule = "2" + String(repeating: "1", count: 167)
        XCTAssertTrue(FileStationWeeklySchedule.isValid(schedule, perAccount: true))
        XCTAssertFalse(FileStationWeeklySchedule.isValid(schedule, perAccount: false))
        let transport = ParityTransport(try [bandwidthPage()] + accessResponses() + [bandwidthPage(), bandwidthPage(), response([:]), bandwidthPage(limit: 42, schedule: schedule)])
        let repo = try repository(transport)
        let loadedPage = try await repo.listFileStationBandwidth(ownerType: .localUser, offset: 0, limit: 100)
        let old = try XCTUnwrap(loadedPage.items.first)
        var updated = old; updated.uploadLimit = 42; updated.policy = .scheduled; updated.schedule = schedule
        let result = try await repo.changeFileStationSettings(.bandwidth(baseline: old, updated: updated), confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "set" }), folder: "set-bandwidth")
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "set" }))
        let rows = try JSONSerialization.jsonObject(with: XCTUnwrap(fields["bandwidths"]?.data(using: .utf8))) as! [[String: Any]]
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows[0]["name"] as? String, "synthetic-user")
        XCTAssertEqual(rows[0]["schedule_plan"] as? String, schedule); XCTAssertEqual(rows[0]["protocol"] as? String, "FileStation")
        let invalid = ParityTransport(try [bandwidthPage()] + accessResponses() + [bandwidthPage()])
        let invalidRepo = try repository(invalid)
        let invalidPage = try await invalidRepo.listFileStationBandwidth(ownerType: .localUser, offset: 0, limit: 100)
        let baseline = try XCTUnwrap(invalidPage.items.first)
        var invalidValue = baseline; invalidValue.uploadLimit = 9
        do { _ = try await invalidRepo.changeFileStationSettings(.bandwidth(baseline: baseline, updated: invalidValue), confirmed: true); XCTFail("不能写入过低限速") } catch { }
        let invalidCalls = await invalid.requests; XCTAssertFalse(invalidCalls.contains { parameters($0)["method"] == "set" })
    }

    func testVFS协议尚无已存连接仍可创建并分别核对配置() async throws {
        let transport = ParityTransport(try accessResponses() + [vfsProfiles(empty: true), vfsProtocols(), vfsProfiles(empty: true),
            response([:]), response([:]), vfsProfiles(), vfsProfiles(), vfsDetail()])
        let repo = try repository(transport)
        let result = try await repo.changeFileVFS(.create(vfsConfiguration()), password: "synthetic-remote", confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "create" && parameters($0)["api"] == DsmAPIName.fileStationVFSConnection }), folder: "create-vfs-connection", substitutions: ["<synthetic-remote-folder>": ""])
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "create" && parameters($0)["api"] == DsmAPIName.fileStationVFSProfile }), folder: "create-vfs-profile", substitutions: ["<synthetic-remote-folder>": ""])
        let writes = calls.filter { parameters($0)["method"] == "create" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(parameters(writes[0])["api"], DsmAPIName.fileStationVFSConnection)
        XCTAssertEqual(parameters(writes[1])["api"], DsmAPIName.fileStationVFSProfile)
        XCTAssertEqual(parameters(writes[0])["force"], "false"); XCTAssertNil(parameters(writes[1])["force"])
        XCTAssertFalse(calls.contains { parameters($0)["method"] == "delete" })
    }

    func testVFS第二步失败保留连接且不自动重连或删除() async throws {
        let transport = ParityTransport(try accessResponses() + [vfsProfiles(empty: true), vfsProtocols(), vfsProfiles(empty: true),
            response([:]), .failure, vfsProfiles(empty: true)])
        let repo = try repository(transport)
        let change = FileVFSChange.create(vfsConfiguration())
        let result = try await repo.changeFileVFS(change, password: "synthetic-remote", confirmed: true)
        XCTAssertEqual(result.status, .submittedButUnverified); XCTAssertEqual(result.localizationKey, "files.vfs.partial")
        do { _ = try await repo.changeFileVFS(change, password: "synthetic-remote", confirmed: true); XCTFail("不能重放已部分完成的创建") } catch { }
        let calls = await transport.requests
        XCTAssertEqual(calls.filter { parameters($0)["method"] == "create" }.count, 2)
        XCTAssertFalse(calls.contains { parameters($0)["method"] == "delete" || parameters($0)["force"] == "true" })
    }

    func testVFS确认后别名或身份变化不能断开其他连接() async throws {
        let transport = ParityTransport(try [vfsProfiles()] + accessResponses() + [vfsProfiles(alias: "Changed")])
        let repo = try repository(transport)
        let loadedProfiles = try await repo.listFileVFSProfiles()
        let profile = try XCTUnwrap(loadedProfiles.first)
        do { _ = try await repo.changeFileVFS(.disconnect(profile), password: nil, confirmed: true); XCTFail("目标变化不得断开") } catch { }
        let calls = await transport.requests; XCTAssertFalse(calls.contains { parameters($0)["method"] == "delete" })
    }

    func testVFS编辑保留密码时不发送占位密码() async throws {
        let transport = ParityTransport(try [vfsProfiles(), vfsProfiles(), vfsDetail()] + accessResponses()
            + [vfsProfiles(), vfsProfiles(), vfsDetail(), vfsProtocols(), vfsProfiles(), response([:]), response([:]),
               vfsProfiles(alias: "Renamed"), vfsProfiles(alias: "Renamed"), vfsDetail(alias: "Renamed")])
        let repo = try repository(transport)
        let loadedProfiles = try await repo.listFileVFSProfiles()
        let profile = try XCTUnwrap(loadedProfiles.first)
        let baseline = try await repo.loadFileVFSDetail(profile)
        var configuration = baseline.configuration; configuration.alias = "Renamed"
        let result = try await repo.changeFileVFS(.update(baseline: baseline, configuration: configuration), password: nil, confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        let writes = calls.filter { parameters($0)["method"] == "set" }; XCTAssertEqual(writes.count, 2)
        for write in writes { XCTAssertNil(parameters(write)["password"]); XCTAssertEqual(parameters(write)["id"], "synthetic-vfs-id") }
    }

    func test自定义分享页面开关保持字符串读取并发送布尔修改() async throws {
        let transport = ParityTransport(try [settingsPage()] + accessResponses() + [settingsPage(), settingsPage(), response([:]), settingsPage(customPage: true)])
        let repo = try repository(transport)
        let baseline = try await repo.loadFileStationSettings(); XCTAssertEqual(baseline.usesCustomSharingPage, false)
        var updated = baseline; updated.usesCustomSharingPage = true
        let result = try await repo.changeFileStationSettings(.general(baseline: baseline, updated: updated), confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "set" }), folder: "set-sharing-theme-enabled")
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "set" }))
        XCTAssertEqual(fields["enable_sharing_custom_setting"], "true"); XCTAssertNil(fields["enable_list_usergrp"])
    }

    func test远程访问只修改本机所选账号并保持其他账号权限() async throws {
        let transport = ParityTransport(try [mountAccountPage()] + accessResponses()
            + [mountAccountPage(), mountAccountPage(), response([:]), mountAccountPage(enabled: true)])
        let repo = try repository(transport)
        let page = try await repo.listFileStationMountAccounts(kind: .user, query: "", offset: 0, limit: 100)
        let baseline = try XCTUnwrap(page.items.first)
        let result = try await repo.changeFileStationSettings(.mountAccount(baseline: baseline, enabled: true), confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "set" }), folder: "set-mount-account")
        try assertRequestFixture(XCTUnwrap(calls.first), folder: "list-mount-accounts", substitutions: ["<synthetic-filter>": ""])
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "set" }))
        let settings = try JSONSerialization.jsonObject(with: XCTUnwrap(fields["settings"]?.data(using: .utf8))) as! [String: Any]
        let users = try XCTUnwrap(settings["user_settings"] as? [[String: Any]])
        XCTAssertEqual(users.count, 1); XCTAssertEqual(users[0]["uid"] as? Int, 1001); XCTAssertEqual(users[0]["enabled"] as? Bool, true)
        XCTAssertNil(settings["user_enabled_type"]); XCTAssertNil(settings["group_settings"])
        XCTAssertEqual(parameters(calls[0])["type"], "local"); XCTAssertEqual(parameters(calls[0])["usergroup"], "user")
    }

    func test远程访问不可修改的账号与确认后变化均拒绝写入() async throws {
        for mutable in [true, false] {
            let transport = ParityTransport(try [mountAccountPage(mutable: mutable)] + accessResponses()
                + [mountAccountPage(enabled: mutable, mutable: mutable)])
            let repo = try repository(transport)
            let page = try await repo.listFileStationMountAccounts(kind: .user, query: "", offset: 0, limit: 100)
            do {
                _ = try await repo.changeFileStationSettings(.mountAccount(baseline: XCTUnwrap(page.items.first), enabled: true), confirmed: true)
                XCTFail("不能修改锁定或已变化账号")
            } catch { }
            let calls = await transport.requests; XCTAssertFalse(calls.contains { parameters($0)["method"] == "set" })
        }
    }

    func test分享主题提交完整布局保留现有图片且回读确认() async throws {
        let transport = ParityTransport(try [themePage()] + accessResponses() + [themePage(), themePage(), response([:]), themePage(footer: "Synthetic footer")])
        let repo = try repository(transport)
        let baseline = try await repo.loadFileStationSharingTheme(); var updated = baseline; updated.footer = "Synthetic footer"
        let result = try await repo.changeFileStationSettings(.theme(baseline: baseline, updated: updated), confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "set" }), folder: "set-sharing-theme")
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "set" }))
        XCTAssertEqual(fields["footer_msg"], "Synthetic footer"); XCTAssertEqual(fields["logo_position"], "leftup")
        XCTAssertEqual(fields["enable_background_customize"], "true"); XCTAssertNil(fields["background_path"]); XCTAssertNil(fields["logo_path"])
    }

    func test主题新图片只发送指定来源并在回执与序列回读后成功() async throws {
        let choice = FileStationThemeImage(kind: .logo, source: .history, path: "/synthetic-theme/logo.png", name: "Logo", historyIndex: 0)
        let images = try response(["list": [["index": 0, "path": choice.path, "filename": choice.name]]])
        for acknowledged in [true, false] {
            let transport = ParityTransport(try [themePage()] + accessResponses() + [themePage(), images, themePage(),
                acknowledged ? response([:]) : .failure, themePage(logoSequence: 2)])
            let repo = try repository(transport)
            let baseline = try await repo.loadFileStationSharingTheme(); var updated = baseline; updated.logoImage = choice
            let result = try await repo.changeFileStationSettings(.theme(baseline: baseline, updated: updated), confirmed: true)
            XCTAssertEqual(result.status, acknowledged ? .confirmedSuccess : .submittedButUnverified)
            let calls = await transport.requests
            let write = try XCTUnwrap(calls.first { parameters($0)["method"] == "set" })
            XCTAssertEqual(parameters(write)["logo_type"], "history"); XCTAssertEqual(parameters(write)["logo_path"], "logo.png")
            XCTAssertNil(parameters(write)["background_path"])
            if !acknowledged {
                do { _ = try await repo.changeFileStationSettings(.theme(baseline: baseline, updated: updated), confirmed: true); XCTFail("未知换图不得自动重放") } catch {}
                let pending = await repo.pendingFileStationChanges(); XCTAssertEqual(pending.count, 1)
            }
        }
    }

    func test主题图片预览重新解析历史编号且凭据不进入URL() async throws {
        let choice = FileStationThemeImage(kind: .background, source: .history, path: "/synthetic-theme/image.png", name: "Background", historyIndex: 0)
        let row = try response(["list": [["index": 3, "path": choice.path, "filename": choice.name]]])
        let pixels = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lU8AAAAASUVORK5CYII="))
        let transport = ParityTransport([row, row, .success(pixels)])
        let data = try await repository(transport).loadFileStationThemeImage(choice)
        XCTAssertEqual(data, pixels)
        let calls = await transport.requests
        XCTAssertEqual(parameters(calls[2])["index"], "3"); XCTAssertEqual(parameters(calls[2])["type"], "fbsharing_login_background")
        XCTAssertFalse(calls[2].url!.absoluteString.contains("synthetic-session")); XCTAssertNotNil(calls[2].value(forHTTPHeaderField: "Cookie"))
    }

    func test主题本机上传使用正式字段并核对历史但不自动应用() async throws {
        let pixels = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lU8AAAAASUVORK5CYII="))
        let transport = ParityTransport(try accessResponses() + [response(["path": "/synthetic-theme/new.png"]),
            response(["list": [["index": 0, "path": "/synthetic-theme/new.png", "filename": "image.png"]]])])
        let result = try await repository(transport).uploadFileStationThemeImage(data: pixels, filename: "image.png", kind: .logo, confirmed: true)
        XCTAssertEqual(result.source, .history); XCTAssertEqual(result.path, "/synthetic-theme/new.png")
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 3)
        XCTAssertTrue(calls[1].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true)
        let body = String(decoding: calls[1].httpBody!, as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"upload_image\"; filename=\"image.png\""))
        XCTAssertTrue(body.contains("fbsharing_login_logo")); XCTAssertFalse(body.contains("FileSharingLogin"))
        let denied = ParityTransport([])
        do { _ = try await repository(denied).uploadFileStationThemeImage(data: pixels, filename: "image.png", kind: .logo, confirmed: false); XCTFail("上传仍须明确确认") } catch {}
        let deniedCalls = await denied.requests; XCTAssertTrue(deniedCalls.isEmpty)
    }

    func test主题上传超时后同一图片只允许检查历史不重传() async throws {
        let pixels = try XCTUnwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/lU8AAAAASUVORK5CYII="))
        let transport = ParityTransport(try accessResponses() + [.failure])
        let repo = try repository(transport)
        for _ in 0..<2 {
            do { _ = try await repo.uploadFileStationThemeImage(data: pixels, filename: "image.png", kind: .logo, confirmed: true); XCTFail("未知上传不能确认成功或自动重复") } catch {}
        }
        let calls = await transport.requests
        XCTAssertEqual(calls.count, 2)
        XCTAssertEqual(calls.filter { $0.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data") == true }.count, 1)
    }

    func test云盘授权使用实际版本且不发送会话或设备标识() async throws {
        let transport = ParityTransport(try cloudPreparation())
        let repo = try repository(transport)
        let request = try await repo.prepareFileVFSCloudAuthorization(protocolID: "google")
        let url = try XCTUnwrap(URLComponents(url: request.loginURL, resolvingAgainstBaseURL: false))
        let fields = Dictionary(uniqueKeysWithValues: (url.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(url.host, "synooauth.synology.com"); XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(fields["major"], "7"); XCTAssertEqual(fields["minor"], "2")
        XCTAssertEqual(Set(fields.keys), ["major", "minor", "type"])
        XCTAssertFalse(request.loginURL.absoluteString.contains("synthetic-session"))
        XCTAssertEqual(request.profileID, repo.profileID)
    }

    func test云盘授权回调只接受准确名称且不解码密码() throws {
        let request = cloudRequest(profileID: UUID())
        let valid = try cloudAuthorization(request)
        XCTAssertEqual(valid.account, "synthetic-cloud-account")
        XCTAssertFalse(String(reflecting: valid).contains("synthetic-access"))
        let payload = try JSONSerialization.data(withJSONObject: ["callback": "wrong-callback", "account": "synthetic-cloud-account",
            "access_token": "synthetic-access", "password": "must-not-decode"])
        XCTAssertThrowsError(try FileVFSCloudAuthorization.decode(payload, for: request))
        let noAccount = try JSONSerialization.data(withJSONObject: ["callback": request.callbackName, "access_token": "synthetic-access"])
        XCTAssertThrowsError(try FileVFSCloudAuthorization.decode(noAccount, for: request))
    }

    func test云盘创建核对账号并分别提交连接与保存配置() async throws {
        let transport = ParityTransport(try cloudPreparation() + accessResponses() + [cloudProfiles(empty: true), cloudProtocols(),
            cloudProfiles(empty: true), response([:]), response([:]), cloudProfiles()])
        let repo = try repository(transport)
        let request = try await repo.prepareFileVFSCloudAuthorization(protocolID: "google")
        let authorization = try cloudAuthorization(request)
        let change = FileVFSChange.createCloud(.init(protocolID: "google", alias: "Cloud", account: authorization.account))
        let result = try await repo.authorizeFileVFS(change, authorization: authorization, confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        let writes = calls.filter { parameters($0)["method"] == "create" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(parameters(writes[0])["api"], DsmAPIName.fileStationVFSConnection)
        XCTAssertEqual(parameters(writes[1])["api"], DsmAPIName.fileStationVFSProfile)
        try assertRequestFixture(writes[0], folder: "create-vfs-cloud-connection")
        try assertRequestFixture(writes[1], folder: "create-vfs-cloud-profile")
        XCTAssertEqual(parameters(writes[0])["access_token"], "synthetic-access")
        XCTAssertEqual(parameters(writes[0])["force"], "false")
        XCTAssertEqual(parameters(writes[1])["account"], "synthetic-cloud-account")
        XCTAssertFalse(writes.contains { $0.url?.absoluteString.contains("synthetic-access") == true })
        let pending = await repo.pendingFileStationChanges(); XCTAssertTrue(pending.isEmpty)
        do { _ = try await repo.authorizeFileVFS(change, authorization: authorization, confirmed: true); XCTFail("已使用授权不能重放") } catch {}
        let after = await transport.requests.count; XCTAssertEqual(after, calls.count)
    }

    func test云盘重新授权只更新原账号原连接() async throws {
        let transport = ParityTransport(try cloudPreparation() + [cloudProfiles()] + accessResponses() + [cloudProfiles(), cloudProtocols(),
            cloudProfiles(), response([:]), response([:]), cloudProfiles()])
        let repo = try repository(transport)
        let request = try await repo.prepareFileVFSCloudAuthorization(protocolID: "google")
        let profile = try await repo.listFileVFSProfiles()[0]
        let result = try await repo.authorizeFileVFS(.reauthorize(profile), authorization: cloudAuthorization(request), confirmed: true)
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        let writes = calls.filter { parameters($0)["method"] == "set" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertTrue(writes.allSatisfy { parameters($0)["id"] == profile.id })
        XCTAssertTrue(writes.allSatisfy { parameters($0)["account"] == profile.account })
        try assertRequestFixture(writes[0], folder: "reauthorize-vfs-connection")
        try assertRequestFixture(writes[1], folder: "reauthorize-vfs-profile")

        let mismatch = ParityTransport(try cloudPreparation() + [cloudProfiles()] + accessResponses() + [cloudProfiles()])
        let second = try repository(mismatch)
        let nextRequest = try await second.prepareFileVFSCloudAuthorization(protocolID: "google")
        let baseline = try await second.listFileVFSProfiles()[0]
        do { _ = try await second.authorizeFileVFS(.reauthorize(baseline), authorization: cloudAuthorization(nextRequest, account: "another-account"), confirmed: true); XCTFail("不能换成其他账号") } catch {}
        let mismatchCalls = await mismatch.requests
        XCTAssertFalse(mismatchCalls.contains { parameters($0)["method"] == "set" })
    }

    func test云盘保存配置结果未知不重放且待核查不包含令牌() async throws {
        let transport = ParityTransport(try cloudPreparation() + accessResponses() + [cloudProfiles(empty: true), cloudProtocols(),
            cloudProfiles(empty: true), response([:]), .failure, cloudProfiles(), cloudProfiles()])
        let repo = try repository(transport)
        let request = try await repo.prepareFileVFSCloudAuthorization(protocolID: "google")
        let authorization = try cloudAuthorization(request)
        let change = FileVFSChange.createCloud(.init(protocolID: "google", alias: "Cloud", account: authorization.account))
        let result = try await repo.authorizeFileVFS(change, authorization: authorization, confirmed: true)
        XCTAssertEqual(result.status, .submittedButUnverified)
        let pending = await repo.pendingFileStationChanges()
        XCTAssertEqual(pending.count, 1)
        XCTAssertFalse(String(reflecting: pending).contains("synthetic-access"))
        let review = try await repo.reviewFileVFS(change)
        XCTAssertEqual(review.status, .submittedButUnverified)
        let calls = await transport.requests
        XCTAssertEqual(calls.filter { parameters($0)["method"] == "create" }.count, 2)
    }

    private func cloudRequest(profileID: UUID) -> FileVFSCloudAuthorizationRequest {
        .init(profileID: profileID, protocolID: "google", loginURL: URL(string: "https://auth.invalid/authorize")!,
            callbackName: "_webfmOAuthCallback")
    }
    private func cloudAuthorization(_ request: FileVFSCloudAuthorizationRequest, account: String = "synthetic-cloud-account") throws -> FileVFSCloudAuthorization {
        let data = try JSONSerialization.data(withJSONObject: ["callback": request.callbackName, "account": account, "client_id": "synthetic-client",
            "access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "expires_in": 3600, "password": "must-not-decode"])
        return try .decode(data, for: request)
    }
    private func cloudProtocols() throws -> ParityTransport.Response {
        try response(["protocols": [["protocol": "google", "name": "Google Drive", "has_server": false]]])
    }
    private func cloudPreparation() throws -> [ParityTransport.Response] {
        try accessResponses() + [cloudProtocols(), response(["firmware_ver": "DSM 7.2.1-69057 Update 12"]) ]
    }
    private func cloudProfiles(empty: Bool = false) throws -> ParityTransport.Response {
        try response(["profiles": empty ? [] : [["id": "synthetic-cloud-id", "protocol": "google", "protocol_name": "Google Drive",
            "uri": "google://synthetic-cloud-id", "alias": "Cloud", "account": "synthetic-cloud-account", "connect_status": 1]]])
    }

    func test远程文件列表保留URI并拒绝越过原连接边界() async throws {
        let transport = ParityTransport(try [vfsProfiles(), vfsProfiles(), response(["offset": 0, "total": 2,
            "files": [["name": "folder", "path": "sftp://synthetic-vfs-id/folder", "isdir": true]]]),
            vfsProfiles(), response(["offset": 1, "total": 2, "files": [["name": "file.txt", "path": "sftp://synthetic-vfs-id/file.txt", "isdir": false]]])])
        let repo = try repository(transport)
        let baseline = try await repo.listFileVFSProfiles()[0]
        let first = try await repo.listFileVFSFolder(baseline, path: baseline.uri, offset: 0, limit: 1)
        XCTAssertTrue(first.hasMore); XCTAssertEqual(first.items.first?.path, "sftp://synthetic-vfs-id/folder")
        let second = try await repo.listFileVFSFolder(baseline, path: baseline.uri, offset: 1, limit: 1)
        XCTAssertFalse(second.hasMore)
        let count = await transport.requests.count
        do { _ = try await repo.listFileVFSFolder(baseline, path: "sftp://other/folder", offset: 0, limit: 1); XCTFail("不能进入其他连接") } catch {}
        do { _ = try await repo.listFileVFSFolder(baseline, path: baseline.uri + "/../other", offset: 0, limit: 1); XCTFail("不能使用越界路径") } catch {}
        let calls = await transport.requests; XCTAssertEqual(calls.count, count)
        XCTAssertEqual(parameters(calls[2])["folder_path"], baseline.uri)
        XCTAssertEqual(parameters(calls[2])["api"], DsmAPIName.fileStationList)
    }

    func testPOSIX三位权限按十进制字段读取并提交准确实际路径() async throws {
        let transport = ParityTransport(try posixPages() + accessResponses() + posixPages() + posixPages()
            + [response([:])] + posixPages(mode: 750))
        let repo = try repository(transport)
        let baseline = try await repo.loadFilePermissions(permissionItem(profileID: repo.profileID))
        XCTAssertEqual(baseline.posixMode, "755")
        let result = try await repo.changeFilePermissions(.init(baseline: baseline, posixMode: "750", confirmedScope: false,
            confirmedOwner: false, confirmedAccessRemoval: true))
        XCTAssertEqual(result.status, .confirmedSuccess)
        let calls = await transport.requests
        try assertRequestFixture(XCTUnwrap(calls.first { parameters($0)["method"] == "set" }), folder: "set-posix", substitutions: ["<synthetic-real-path>": "/volume-synthetic/synthetic/folder", "<synthetic-path>": "/synthetic/folder"])
        let fields = parameters(try XCTUnwrap(calls.first { parameters($0)["method"] == "set" }))
        XCTAssertEqual(fields["mode"], "750")
        let paths = try JSONSerialization.jsonObject(with: XCTUnwrap(fields["files"]?.data(using: .utf8))) as? [String]
        XCTAssertEqual(paths, ["/volume-synthetic/synthetic/folder"])
        XCTAssertEqual(fields["posix_mode_recur"], "false"); XCTAssertNil(fields["owner"])
    }

    private func posixPages(mode: Int = 755, path: String = "/synthetic/folder", mountPointType: String = "normal") throws -> [ParityTransport.Response] {
        try [response(["files": [["name": "folder", "path": path, "isdir": true, "additional": [
            "real_path": "/volume-synthetic" + path, "mount_point_type": mountPointType, "size": 0,
            "owner": ["user": "synthetic-user", "group": "synthetic-group"],
            "perm": ["is_acl_mode": false, "posix": mode, "adv_right": ["read": true, "write": true]]]]]])] + accessResponses()
    }
    private func mountAccountPage(enabled: Bool = false, mutable: Bool = true) throws -> ParityTransport.Response {
        try response(["total": 1, "usergrp_settings": [["uid": 1001, "name": "synthetic-user", "enabled": enabled, "is_modifiable": mutable]]])
    }
    private func themePage(footer: String = "", logoSequence: Int = 1, backgroundSequence: Int = 1) throws -> ParityTransport.Response {
        try response(["enable_logo_customize": true, "enable_background_customize": true, "logo_position": "leftup",
            "background_position": "fill", "background_color": "#FFFFFF", "footer_msg": footer, "enable_footer_html": false,
            "logo_seq": logoSequence, "background_seq": backgroundSequence])
    }

    private func settingsPage(log: Bool = false, sharingMember: Bool = false, customPage: Bool = false) throws -> ParityTransport.Response {
        try response(["transfer_log_enable": log, "use_unix_default_perm": false, "enable_list_usergrp": true,
            "sharing_allow": sharingMember ? "per_user" : "admin", "file_request_allow": "admin", "rf_allow": "admin", "vd_allow": "admin",
            "sharing_privilege": ["items": sharingMember ? [["uid": 1001, "enabled": true]] : []],
            "sharing_group_privilege": ["items": []], "file_request_privilege": ["items": []], "file_request_group_privilege": ["items": []],
            "sharing_default_limit": "1000", "bandwidth_enable": "bandwidth_disable", "schedule_plan": "", "enable_sharing_custom_setting": customPage ? "true" : "false"])
    }
    private func bandwidthPage(limit: Int = 0, schedule: String = "", policy: String? = nil,
                               ownerType: FileStationBandwidthEntry.OwnerType = .localUser) throws -> ParityTransport.Response {
        try response(["total": 1, "bandwidths": [["name": "synthetic-user", "protocol": "FileStation", "owner_type": ownerType.rawValue,
            "policy": policy ?? (schedule.isEmpty ? "disabled" : "scheduled"), "schedule_plan": schedule, "upload_limit_1": limit,
            "upload_limit_2": 0, "download_limit_1": 0, "download_limit_2": 0]]])
    }
    private func vfsConfiguration(alias: String = "Remote") -> FileVFSConfiguration {
        .init(protocolID: "sftp", hostname: "remote.invalid", port: 22, alias: alias, account: "synthetic-user")
    }
    private func vfsProtocols() throws -> ParityTransport.Response {
        try response(["protocols": [["protocol": "sftp", "name": "SFTP", "default_port": 22, "has_server": false]]])
    }
    private func vfsProfiles(empty: Bool = false, alias: String = "Remote") throws -> ParityTransport.Response {
        try response(["profiles": empty ? [] : [["id": "synthetic-vfs-id", "protocol": "sftp", "protocol_name": "SFTP",
            "uri": "sftp://synthetic-vfs-id", "hostname": "remote.invalid", "port": 22, "alias": alias,
            "account": "synthetic-user", "codepage": "UTF-8", "connect_status": 1]]])
    }
    private func vfsDetail(alias: String = "Remote") throws -> ParityTransport.Response {
        try response(["hostname": "remote.invalid", "port": 22, "alias": alias, "account": "synthetic-user", "codepage": "UTF-8",
            "uri_path": "", "max_connection": 0, "password": "must-never-be-decoded-or-returned"])
    }

    private func isoChange(profileID: UUID) -> FileISOMountChange {
        .mount(.init(source: .init(profileID: profileID, name: "disc.iso", path: "/synthetic/disc.iso", kind: .file, sizeBytes: 4),
            destination: .init(profileID: profileID, name: "mount", path: "/synthetic/mount", kind: .directory), automaticMount: true))
    }
    private func isoInventory(mounted: Bool = false, source: String = "/synthetic/disc.iso") throws -> ParityTransport.Response {
        try response(["mountConfig": ["enable_remote_mount": true, "enable_iso_mount": true], "remoteList": [],
            "isoList": mounted ? [["type": "iso", "source": source, "mount_point": "/synthetic/mount", "auto_mount": true]] : []])
    }
    private func isoItems(mounted: Bool = false, destinationOnly: Bool = false) throws -> ParityTransport.Response {
        var items: [[String: Any]] = [["name": "mount", "path": "/synthetic/mount", "isdir": true,
            "additional": ["mount_point_type": mounted ? "iso" : "normal", "perm": ["adv_right": ["read": true, "write": true]]]]]
        if !destinationOnly { items.append(["name": "disc.iso", "path": "/synthetic/disc.iso", "isdir": false,
            "additional": ["size": 4, "perm": ["adv_right": ["read": true, "write": false]]]]) }
        return try response(["files": items])
    }
    private func permissionItem(profileID: UUID) -> FileItem { .init(profileID: profileID, name: "folder", path: "/synthetic/folder", kind: .directory) }
    private func permissionPages(changed: Bool = false, path: String = "/synthetic/folder", mountPointType: String = "normal", omitsRealPath: Bool = false) throws -> [ParityTransport.Response] {
        let rights = Dictionary(uniqueKeysWithValues: FileACLRight.allCases.map { ($0.rawValue, $0 == .readData || (changed && $0 == .writeData)) })
        let inheritance = Dictionary(uniqueKeysWithValues: FileACLInheritance.allCases.map { ($0.rawValue, $0 == .thisFolder) })
        var additional: [String: Any] = ["mount_point_type": mountPointType, "size": 0,
            "owner": ["user": "synthetic-user", "group": "synthetic-group"],
            "perm": ["is_acl_mode": true, "posix": 755, "adv_right": ["read": true, "write": true]]]
        if !omitsRealPath { additional["real_path"] = "/volume-synthetic" + path }
        return try [response(["files": [["name": "folder", "path": path, "isdir": true, "additional": additional]]]),
            response(["is_acl": true, "change_permission": true, "is_inherited": true, "acl": [
                ["owner_type": "user", "owner_name": "synthetic-user", "owner_id": 1000, "permission_type": "allow", "permission": rights, "inherit": inheritance, "level": 0],
                ["owner_type": "group", "owner_name": "synthetic-group", "permission_type": "allow", "permission": Dictionary(uniqueKeysWithValues: FileACLRight.allCases.map { ($0.rawValue, $0 == .readData) }), "inherit": inheritance, "level": 1]]]),
            response(["name": "synthetic-user", "type": "user", "value": "user:synthetic-user", "hasPrivilege": true])]
    }

    private func assertRequestFixture(_ request: URLRequest, folder: String, substitutions: [String: String] = [:]) throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("contracts/request-fixtures/file-station/" + folder + "/synthetic-request/request.json")
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let api = try XCTUnwrap(fixture["api"] as? [String: Any]), rows = try XCTUnwrap(fixture["parameters"] as? [[String: Any]])
        let actual = parameters(request)
        XCTAssertEqual(request.httpMethod, "POST"); XCTAssertEqual(request.url?.lastPathComponent, api["resolvedPath"] as? String)
        XCTAssertEqual(actual["api"], api["name"] as? String); XCTAssertEqual(actual["method"], api["method"] as? String)
        XCTAssertEqual(actual["version"], String(try XCTUnwrap(api["resolvedVersion"] as? Int)))
        XCTAssertEqual(Set(actual.keys).subtracting(["api", "method", "version", "_sid", "SynoToken"]), Set(rows.compactMap { $0["name"] as? String }))
        for row in rows {
            let name = try XCTUnwrap(row["name"] as? String), value = try XCTUnwrap(actual[name])
            if row["redacted"] as? Bool == true { continue }
            var expected = try XCTUnwrap(row["encodedValue"] as? String)
            for (key, replacement) in substitutions { expected = expected.replacingOccurrences(of: key, with: replacement) }
            if ["object", "objectArray", "stringArray", "integerArray"].contains(row["valueType"] as? String ?? "") {
                let left = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? NSObject
                let right = try JSONSerialization.jsonObject(with: Data(expected.utf8)) as? NSObject
                XCTAssertEqual(left, right, "字段 \(name) 与请求契约不一致")
            } else { XCTAssertEqual(value, expected, "字段 \(name) 与请求契约不一致") }
        }
    }

    private func repository(_ transport: ParityTransport) throws -> DsmFileRepository {
        let versions = [DsmAPIName.fileStationList: 2, DsmAPIName.fileStationSearch: 2,
            DsmAPIName.fileStationSharing: 3, DsmAPIName.fileStationExtract: 2,
            DsmAPIName.fileStationBackgroundTask: 3, DsmAPIName.fileStationCopyMove: 3,
            DsmAPIName.fileStationSettings: 1, DsmAPIName.fileStationVFSUser: 1, DsmAPIName.coreBandwidthControl: 1,
            DsmAPIName.coreDirectoryLDAP: 1, DsmAPIName.coreDirectoryDomain: 2, DsmAPIName.coreThemeImage: 1, DsmAPIName.coreFileSharingTheme: 1, DsmAPIName.fileStationVFSProtocol: 1, DsmAPIName.fileStationVFSProfile: 1, DsmAPIName.fileStationVFSConnection: 1,
            DsmAPIName.fileStationMount: 1, DsmAPIName.fileStationMountList: 1, DsmAPIName.coreACL: 1,
            DsmAPIName.fileStationACLOwner: 1, DsmAPIName.fileStationProperty: 1,
            DsmAPIName.fileStationUserGroup: 1, DsmAPIName.desktopInitData: 1, DsmAPIName.coreSystem: 3, DsmAPIName.corePackage: 2]
        return try DsmFileRepository(profile: NasProfile(displayName: "Synthetic", host: "nas.invalid", port: 5001),
            capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: versions.map { name, version in
                (name, ApiCapability(name: name, path: "entry.cgi", minVersion: 1, maxVersion: version, requestFormat: .form, selectedVersion: version))
            })), session: AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    private func accessResponses(administrator: Bool = true, allowed: Bool = true) throws -> [ParityTransport.Response] {
        try [response(["AppPrivilege": ["SYNO.SDS.App.FileStation3.Instance": allowed], "Session": ["is_admin": administrator]])]
    }
    private func advancedShare() -> FileShareLink {
        .init(id: "synthetic-link", name: "item", path: "/synthetic/item", url: "https://example.invalid/shared", availabilityDateKnown: true, status: .valid,
              advanced: .init(protection: .users, users: ["old-user"], groups: [], maximumAccesses: 0, isFileRequest: false,
                allowsUpload: false, requestName: "", requestMessage: ""))
    }
    private func advancedSharePage(users: [String] = ["old-user"], limit: Int = 0, fileRequest: Bool = false) throws -> ParityTransport.Response {
        try response(["offset": 0, "total": 1, "links": [["id": "synthetic-link", "name": "item", "path": "/synthetic/item", "url": "https://example.invalid/shared",
            "has_password": false, "date_available": "", "date_expired": "", "status": "valid", "protect_type": fileRequest ? "none" : "user",
            "protect_users": fileRequest ? [] : users, "protect_groups": [], "expire_times": limit, "enable_upload": fileRequest,
            "project_name": fileRequest ? "SYNO.SDS.App.SharingUpload.Application" : "SYNO.SDS.App.FileStation3.Instance",
            "request_name": fileRequest ? "Collection" : "", "request_info": fileRequest ? "Message" : ""]]])
    }
    private func baselineShare() -> FileShareLink {
        FileShareLink(id: "synthetic-link", name: "item", path: "/synthetic/item", url: "https://example.invalid/shared",
            hasPassword: true, availabilityDateKnown: true, status: .valid)
    }
    private func sharePage(password: Bool, available: String = "0", expires: String = "0") throws -> ParityTransport.Response {
        try response(["offset": 0, "total": 1, "links": [["id": "synthetic-link", "name": "item", "path": "/synthetic/item",
            "url": "https://example.invalid/shared", "has_password": password, "date_available": available, "date_expired": expires, "status": "valid"]]])
    }
    private func task(finished: Bool) -> FileBackgroundTaskSummary {
        .init(id: "synthetic-task", kind: .copyOrMove, state: finished ? .finished : .active, progress: nil,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000), processedItemCount: nil, totalItemCount: nil,
            processedBytes: nil, totalBytes: nil, apiVersion: 3, method: "start")
    }
    private func taskPage(finished: Bool) throws -> ParityTransport.Response {
        try response(["offset": 0, "total": 1, "tasks": [["taskid": "synthetic-task", "api": DsmAPIName.fileStationCopyMove,
            "version": 3, "method": "start", "crtime": 1_700_000_000, "finished": finished]]])
    }
    private func response(_ data: [String: Any]) throws -> ParityTransport.Response {
        .success(try JSONSerialization.data(withJSONObject: ["success": true, "data": data]))
    }
    private func parameters(_ request: URLRequest) -> [String: String] {
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        let items = request.httpMethod == "GET"
            ? URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            : URLComponents(string: "?" + body)?.queryItems
        return Dictionary(uniqueKeysWithValues: (items ?? []).map { ($0.name, $0.value ?? "") })
    }
}

private actor ParityTransport: DsmBinaryHTTPTransport {
    enum Response: Sendable { case success(Data), held(Data), failure }
    var responses: [Response]
    private(set) var requests: [URLRequest] = []
    private var heldReached = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    init(_ responses: [Response]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        switch responses.removeFirst() {
        case .success(let data): return DsmHTTPResponse(data: data, statusCode: 200)
        case .held(let data):
            await withCheckedContinuation { continuation in
                release = continuation; heldReached = true; observer?.resume(); observer = nil
            }
            return DsmHTTPResponse(data: data, statusCode: 200)
        case .failure: throw URLError(.timedOut)
        }
    }
    func waitUntilHeld() async {
        if !heldReached { await withCheckedContinuation { observer = $0 } }
    }
    func releaseHeld() { release?.resume(); release = nil }
    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse { throw URLError(.unsupportedURL) }
}
