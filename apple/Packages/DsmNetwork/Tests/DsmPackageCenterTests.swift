import DsmCore
import DsmLocalization
import Foundation
import XCTest
@testable import DsmNetwork

final class DsmPackageCenterTests: XCTestCase {
    func test目录分离已安装状态更新候选和测试频道() async throws {
        let upgraded = manifest(version: "2.0")
        let installed = installedList(version: "1.0", upgrade: upgraded)
        let transport = MockHTTPTransport(responses: [response(installed), response(catalog(manifest: upgraded)), response(emptyCatalog)])
        let repository = try makeRepository(transport)
        let result = try await repository.loadPackageCatalog()
        XCTAssertEqual(result.entries.count, 1)
        XCTAssertEqual(result.entries.first?.installedVersion, "1.0")
        XCTAssertEqual(result.entries.first?.version, "2.0")
        XCTAssertEqual(result.entries.first?.isUpdateAvailable, true)
        XCTAssertEqual(result.categories.first?.id, "backup")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(value("method", requests[1]), "list")
        XCTAssertEqual(value("version", requests[1]), "2")
        XCTAssertEqual(value("blloadothers", requests[2]), "true")
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "nas.example.invalid" })
    }

    func test目录版本不同但没有更新操作不能擅自升级() async throws {
        let transport = MockHTTPTransport(responses: [response(installedList(version: "1.0")), response(catalog()), response(emptyCatalog)])
        let repository = try makeRepository(transport)
        let result = try await repository.loadPackageCatalog()
        XCTAssertFalse(try XCTUnwrap(result.entries.first).isUpdateAvailable)
    }

    func test安装计划只读并保存服务端依赖顺序() async throws {
        let transport = MockHTTPTransport(responses: planResponses())
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        XCTAssertEqual(plan.items.map { $0.package.packageID }, ["Demo"])
        XCTAssertEqual(plan.items.first?.defaultVolumeID, "/volume1")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.count, 7)
        XCTAssertTrue(requests.allSatisfy { ["list", "check", "get_queue", "feasibility_check"].contains(value("method", $0) ?? "") })
        let queue = try XCTUnwrap(jsonValue("pkgs", requests[4]) as? [[String: Any]])
        XCTAssertEqual(queue.first?["pkg"] as? String, "Demo")
        XCTAssertEqual(queue.first?["operation"] as? String, "install")
        XCTAssertEqual(queue.first?["beta"] as? Bool, false)
    }

    func test无数据正文的成功预检可以准备更新且不提交安装() async throws {
        let installed = installedList(version: "1.0", upgrade: manifest())
        let transport = MockHTTPTransport(responses: [response(installed), response(catalog()), response(emptyCatalog),
            response(try fixture("feasibility/synthetic-success-without-data")), response(queue()), response(environment), response(installed)])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        XCTAssertEqual(plan.items.first?.package.installedVersion, "1.0")
        XCTAssertEqual(plan.items.first?.package.version, "2.0")
        let requests = await transport.recordedRequests()
        XCTAssertEqual(value("method", requests[3]), "feasibility_check")
        XCTAssertFalse(requests.contains { ["install", "upgrade"].contains(value("method", $0) ?? "") })
    }

    func test系统套件缺省存储空间仍可确认更新并核对最终版本() async throws {
        for type in ["system", "system_hidden"] {
            let candidate = manifest().replacingOccurrences(of: "\"install_type\":\"user\"", with: "\"install_type\":\"\(type)\"")
            let installed = installedList(version: "1.0", upgrade: candidate)
            let environment = try fixture("installation-check/synthetic-system-no-volume")
            let preparation = [installed, catalog(manifest: candidate), emptyCatalog, ok, queue(), environment, installed].map { response($0) }
            let transport = MockHTTPTransport(responses: preparation + preparation + [response(installed), response(ok), response(environment),
                response(#"{"progress":0,"taskid":"synthetic-task"}"#, wrapped: false),
                response(#"{"finished":true,"success":true,"progress":1}"#, wrapped: false), response(installedList(version: "2.0"))])
            let repository = try makeRepository(transport)
            let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
            XCTAssertEqual(plan.items.first?.volumes, [])
            XCTAssertEqual(plan.items.first?.defaultVolumeID, "")
            let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: false)
            let finished = try await repository.advancePackageInstallation(id: start.id)
            XCTAssertEqual(finished.phase, .completed)
            let requests = await transport.recordedRequests()
            let writes = requests.filter { value("method", $0) == "upgrade" }
            XCTAssertEqual(writes.count, 1)
            XCTAssertEqual(value("volume_path", try XCTUnwrap(writes.first)), "")
        }
    }

    func test只有已知系统类型允许缺省或空存储列表且占用仍拒绝() async throws {
        for (type, occupied, rawList, allowed) in [("system", false, "null", true), ("user", false, "null", false),
                                                  ("user", false, "[]", false), ("system", true, "null", false)] {
            let raw = manifest().replacingOccurrences(of: "\"install_type\":\"user\"", with: "\"install_type\":\"\(type)\"")
            let environment = "{\"success\":true,\"data\":{\"is_occupied\":\(occupied),\"volume_list\":\(rawList)}}"
            let transport = MockHTTPTransport(responses: [response(environment)])
            let repository = try makeRepository(transport)
            let candidate = try await repository.packageCandidate(JSONDecoder().decode(DsmDynamicJSON.self, from: Data(raw.utf8)), installed: [])
            do {
                let item = try await repository.packageInstallationEnvironment(candidate)
                XCTAssertTrue(allowed)
                XCTAssertTrue(item.volumes.isEmpty)
            } catch { XCTAssertFalse(allowed) }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(value("method", requests[0]), "check")
        }
    }

    func test快速安装核对最终版本且不关闭签名检查() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses() + submitResponses() + [
            response(#"{"finished":true,"success":true,"progress":1}"#, wrapped: false), response(installedList(version: "2.0"))
        ])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        let started = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: false)
        XCTAssertEqual(started.phase, .installing)
        let finished = try await repository.advancePackageInstallation(id: started.id)
        XCTAssertEqual(finished.phase, .completed); XCTAssertEqual(finished.completedCount, 1)
        let requests = await transport.recordedRequests()
        let write = try XCTUnwrap(requests.first { value("method", $0) == "install" })
        XCTAssertEqual(value("name", write), "Demo")
        XCTAssertEqual(value("blqinst", write), "true")
        XCTAssertEqual(value("installrunpackage", write), "false")
        XCTAssertEqual(value("volume_path", write), "/volume1")
        XCTAssertNil(value("check_codesign", write))
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.count, 1)
    }

    func test安装完成标记不能替代目标版本确认() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses() + submitResponses() + [
            response(#"{"finished":true,"success":true,"progress":1}"#, wrapped: false), response(installedList(version: "1.0"))
        ])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true)
        let status = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(status.phase, .unverified)
        let count = await transport.recordedRequests().count
        do { _ = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true); XCTFail("不能重复安装") } catch {}
        let after = await transport.recordedRequests().count; XCTAssertEqual(after, count)
    }

    func test未知提交结果只查询安装版本不重放() async throws {
        let preflight = planResponses() + planResponses() + Array(submitResponses().dropLast())
        let transport = MockHTTPTransport(steps: preflight.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost),
            .response(response(installedList(version: "2.0")))])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true)
        XCTAssertEqual(start.phase, .unverified)
        let checked = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(checked.phase, .completed)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.count, 1)
    }

    func test计划后的目录变更导致零安装请求() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses(manifest: manifest(version: "3.0")))
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        do { _ = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true); XCTFail("计划已过期") } catch {}
        let requests = await transport.recordedRequests(); XCTAssertFalse(requests.contains { value("method", $0) == "install" })
    }

    func test缺失依赖和服务端权限拒绝不触发写入() async throws {
        for denied in [false, true] {
            var responses = [response(emptyInstalled), response(catalog()), response(emptyCatalog)]
            responses += denied ? [response(#"{"success":false,"error":{"code":105}}"#)] : [response(ok), response(queue(missing: true))]
            let transport = MockHTTPTransport(responses: responses)
            let repository = try makeRepository(transport)
            do { _ = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"]); XCTFail("预检应失败") } catch {}
            let requests = await transport.recordedRequests(); XCTAssertFalse(requests.contains { value("method", $0) == "install" })
        }
    }

    func test未接受测试版协议不能安装且不代为接受() async throws {
        let beta = manifest(beta: true)
        let transport = MockHTTPTransport(responses: [response(emptyInstalled), response(catalog(manifest: beta)), response(emptyCatalog),
            response(#"{"prerelease":{"success":true,"agreed":false}}"#, wrapped: false)])
        let repository = try makeRepository(transport)
        do { _ = try await repository.preparePackageInstallation(catalogIDs: ["Demo:beta"]); XCTFail("必须接受协议") } catch {}
        let requests = await transport.recordedRequests()
        XCTAssertEqual(value("api", requests.last!), DsmAPIName.corePackageInfo)
        XCTAssertFalse(requests.contains { ["set", "install", "upgrade"].contains(value("method", $0) ?? "") })
    }

    func test安装进行时阻止同仓库启停与卸载() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses() + submitResponses())
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        _ = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true)
        let before = await transport.recordedRequests().count
        do { _ = try await repository.controlPackageResult(id: "Demo", action: .stop); XCTFail("安装期间不能停止") } catch {}
        do { _ = try await repository.uninstallPackageResult(id: "Demo"); XCTFail("安装期间不能卸载") } catch {}
        let after = await transport.recordedRequests().count; XCTAssertEqual(before, after)
    }

    func test下载取消等待任务结束且只提交一次取消() async throws {
        let nonquick = manifest(quick: false)
        let transport = MockHTTPTransport(responses: planResponses(manifest: nonquick) + planResponses(manifest: nonquick) + submitResponses() + [
            response(ok), response(#"{"finished":true,"success":false,"progress":0.1}"#, wrapped: false)
        ])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true)
        XCTAssertEqual(start.phase, .downloading)
        let cancelling = try await repository.cancelPackageInstallation(id: start.id)
        XCTAssertEqual(cancelling.phase, .downloading)
        let requestCount = await transport.recordedRequests().count
        _ = try await repository.cancelPackageInstallation(id: start.id)
        let afterRepeat = await transport.recordedRequests().count
        XCTAssertEqual(requestCount, afterRepeat)
        let cancelled = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(cancelled.phase, .cancelled)
        let requests = await transport.recordedRequests()
        let cancel = try XCTUnwrap(requests.first { value("method", $0) == "cancel" })
        XCTAssertEqual(value("taskid", cancel), "synthetic-task")
        XCTAssertNil(value("task_id", cancel))
    }

    func test非快速下载后展示许可和选项再安装() async throws {
        let nonquick = manifest(quick: false)
        let transport = MockHTTPTransport(responses: planResponses(manifest: nonquick) + planResponses(manifest: nonquick) + submitResponses() + [
            response(#"{"finished":true,"success":true,"progress":1}"#, wrapped: false), response(uploaded(license: "Synthetic license")),
            response(ok), response(settings()), response(#"{"default_vol":"/volume1"}"#, wrapped: false),
            response(emptyInstalled), response(ok), response(environment), response(ok), response(installedList(version: "2.0"))
        ])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true)
        let options = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(options.phase, .needsOptions); XCTAssertEqual(options.configuration?.license, "Synthetic license")
        let before = await transport.recordedRequests().count
        do { _ = try await repository.configurePackageInstallation(id: start.id, volumeID: "/volume1", startAfterInstall: true, licenseAccepted: false, values: [:]); XCTFail("必须接受许可") } catch {}
        let after = await transport.recordedRequests().count; XCTAssertEqual(before, after)
        let installing = try await repository.configurePackageInstallation(id: start.id, volumeID: "/volume1", startAfterInstall: true, licenseAccepted: true, values: [:])
        XCTAssertEqual(installing.phase, .installing)
        let done = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(done.phase, .completed)
        let requests = await transport.recordedRequests()
        let writes = requests.filter { value("method", $0) == "install" }
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(value("blqinst", writes[0]), "false")
        XCTAssertEqual(value("check_codesign", writes[1]), "true")
        XCTAssertEqual(value("task_id", writes[1]), "owned-upload")
        XCTAssertEqual(value("force", writes[1]), "true")
        XCTAssertNil(value("name", writes[1]))
    }

    func test手动上传使用受控临时文件且取消仅清理本次上传() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticPackage-\(UUID().uuidString).spk")
        try Data("synthetic package bytes".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = MockHTTPTransport(responses: [response(uploaded()), response(emptyInstalled), response(ok), response(settings()),
            response(#"{"default_vol":"/volume1"}"#, wrapped: false), response(ok)])
        let repository = try makeRepository(transport)
        let result = try await repository.uploadPackageForInstallation(fileURL: file)
        XCTAssertEqual(result.phase, .needsOptions)
        let bodies = await transport.recordedUploadBodies()
        let body = String(decoding: try XCTUnwrap(bodies.first), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"package.spk\""))
        XCTAssertFalse(body.contains(file.path)); XCTAssertFalse(body.contains(file.lastPathComponent))
        let cancelled = try await repository.cancelPackageInstallation(id: result.id)
        XCTAssertEqual(cancelled.phase, .cancelled)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(value("method", requests.last!), "clean")
        XCTAssertEqual(value("task_id", requests.last!), "owned-upload")
        XCTAssertFalse(requests.contains { ["install", "upgrade", "uninstall"].contains(value("method", $0) ?? "") })
    }

    func test签名失败只清理本次上传不安装() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticPackage-\(UUID().uuidString).spk")
        try Data("synthetic".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let invalid = uploaded().replacingOccurrences(of: "\"additional\":", with: "\"codesign_error\":4501,\"additional\":")
        let transport = MockHTTPTransport(responses: [response(invalid), response(emptyInstalled), response(ok)])
        let repository = try makeRepository(transport)
        do { _ = try await repository.uploadPackageForInstallation(fileURL: file); XCTFail("签名不合法") } catch {}
        let requests = await transport.recordedRequests()
        XCTAssertEqual(value("method", requests.last!), "clean")
        XCTAssertFalse(requests.contains { value("method", $0) == "install" })
    }

    func test自定义表单解析保留值类型并拒绝脚本校验() async throws {
        let repository = try makeRepository(MockHTTPTransport(responses: []))
        let pages = try JSONDecoder().decode(DsmDynamicJSON.self, from: Data(#"[{"items":[{"type":"textfield","subitems":[{"key":"name","desc":"Synthetic label","defaultValue":"hello","validator":{"allowBlank":false,"minLength":2}}]},{"type":"multiselect","subitems":[{"key":"flag","desc":"Synthetic flag","defaultValue":true}]}]}]"#.utf8))
        let fields = try await repository.packageInstallFields(pages)
        XCTAssertEqual(fields.map(\.id), ["name", "flag"])
        XCTAssertEqual(fields[0].defaultValue, .text("hello")); XCTAssertTrue(fields[0].required)
        XCTAssertEqual(fields[1].defaultValue, .flag(true))
        let scripted = try JSONDecoder().decode(DsmDynamicJSON.self, from: Data(#"[{"items":[{"type":"textfield","subitems":[{"key":"field","validator":{"fn":"return true;"}}]}]}]"#.utf8))
        do { _ = try await repository.packageInstallFields(scripted); XCTFail("不能绕过脚本校验") } catch {}
    }

    func test自动更新保存先检查基线并回读所有策略() async throws {
        let old = settings(auto: false), new = settings(auto: true)
        let transport = MockHTTPTransport(responses: [response(old), response(emptyInstalled), response(old), response(emptyInstalled),
            response(ok), response(new), response(emptyInstalled)])
        let repository = try makeRepository(transport)
        let baseline = try await repository.loadPackageCenterSettings()
        var draft = baseline; draft.updatePolicy = .important
        let result = try await repository.savePackageCenterSettings(draft, replacing: baseline)
        XCTAssertEqual(result.updatePolicy, .important)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(value("autoupdateimportant", requests[4]), "true")
        XCTAssertEqual(value("autoupdateall", requests[4]), "false")
        XCTAssertNil(value("default_vol", requests[4]))
    }

    func test设置频道按布尔读取而按字符串保存并接受无正文成功() async throws {
        let old = settings(), new = settings().replacingOccurrences(of: "\"update_channel\":false", with: "\"update_channel\":true")
        let transport = MockHTTPTransport(responses: [response(old), response(emptyInstalled), response(old), response(emptyInstalled),
            response(ok), response(new), response(emptyInstalled)])
        let repository = try makeRepository(transport)
        let baseline = try await repository.loadPackageCenterSettings()
        XCTAssertFalse(baseline.betaEnabled)
        var draft = baseline; draft.betaEnabled = true
        let result = try await repository.savePackageCenterSettings(draft, replacing: baseline)
        XCTAssertTrue(result.betaEnabled)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(value("update_channel", requests[4]), "beta")
        XCTAssertEqual(requests.filter { value("method", $0) == "set" }.count, 1)
    }

    func test单卷设置可缺省安装位置但不接受畸形频道() async throws {
        let noDefault = try fixture("settings/synthetic-boolean-channel")
        let repository = try makeRepository(MockHTTPTransport(responses: [response(noDefault), response(emptyInstalled)]))
        let result = try await repository.loadPackageCenterSettings()
        XCTAssertEqual(result.volumes.count, 1)
        XCTAssertEqual(result.defaultVolumeID, "")
        for invalid in ["null", "\"stable\"", "1"] {
            let malformed = noDefault.replacingOccurrences(of: "\"update_channel\": false", with: "\"update_channel\": \(invalid)")
            let transport = MockHTTPTransport(responses: [response(malformed)])
            let badRepository = try makeRepository(transport)
            do { _ = try await badRepository.loadPackageCenterSettings(); XCTFail("畸形设置不能作为可写基线") }
            catch let error as AppError { XCTAssertEqual(error.category, .invalidResponse) }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.count, 1)
            XCTAssertEqual(value("method", requests[0]), "get")
        }
    }

    func test来源添加编辑删除使用精确目标并验证清单() async throws {
        let empty = #"{"success":true,"data":{"items":[]}}"#
        let a = sourceList("Synthetic A", "https://packages.example.invalid/a")
        let b = sourceList("Synthetic B", "https://packages.example.invalid/b")
        let transport = MockHTTPTransport(responses: [response(empty), response(ok), response(a), response(a), response(ok), response(b), response(b), response(ok), response(empty)])
        let repository = try makeRepository(transport)
        let first = NasPackageSource(name: "Synthetic A", url: "https://packages.example.invalid/a")
        let second = NasPackageSource(name: "Synthetic B", url: "https://packages.example.invalid/b")
        let added = try await repository.savePackageSource(first, replacing: nil); XCTAssertEqual(added, [first])
        let edited = try await repository.savePackageSource(second, replacing: first); XCTAssertEqual(edited, [second])
        let removed = try await repository.deletePackageSource(second); XCTAssertTrue(removed.isEmpty)
        let requests = await transport.recordedRequests()
        let field = try XCTUnwrap(jsonValue("list", requests[4]) as? [String: String])
        XCTAssertEqual(field["orifeed"], first.url); XCTAssertEqual(field["feed"], second.url)
        XCTAssertEqual(jsonValue("list", requests[7]) as? [String], [second.url])
    }

    func test来源保存断线后必须刷新且拒绝凭据地址() async throws {
        let empty = #"{"success":true,"data":{"items":[]}}"#
        let transport = MockHTTPTransport(steps: [.response(response(empty)), .urlError(.networkConnectionLost), .response(response(empty))])
        let repository = try makeRepository(transport)
        let source = NasPackageSource(name: "Synthetic", url: "https://packages.example.invalid/feed")
        do { _ = try await repository.savePackageSource(source, replacing: nil); XCTFail("断线未知") } catch {}
        let before = await transport.recordedRequests().count
        do { _ = try await repository.savePackageSource(source, replacing: nil); XCTFail("不能重复提交") } catch {}
        let after = await transport.recordedRequests().count; XCTAssertEqual(before, after)
        _ = try await repository.loadPackageSources()
        do { _ = try await repository.savePackageSource(NasPackageSource(name: "Synthetic", url: "https://user:password@example.invalid/"), replacing: nil); XCTFail("来源中不能携带凭据") } catch {}
        let final = await transport.recordedRequests().count; XCTAssertEqual(final, 3)
    }

    func test第三方目录失败保留官方套件但明确标记不可用() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(emptyInstalled)), .response(response(catalog())), .urlError(.cannotConnectToHost)])
        let repository = try makeRepository(transport)
        let catalog = try await repository.loadPackageCatalog()
        XCTAssertEqual(catalog.entries.count, 1); XCTAssertFalse(catalog.communityAvailable)
    }

    func test同一安装请求并发进入不会提交两次() async throws {
        let steps = (planResponses() + planResponses() + Array(submitResponses().dropLast())).map(MockHTTPTransport.Step.response)
            + [.waitUntilCancelled]
        let transport = MockHTTPTransport(steps: steps)
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        let operation = Task { try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) }
        for _ in 0..<200 {
            if await transport.recordedRequests().count >= 18 { break }
            try await Task.sleep(for: .milliseconds(2))
        }
        let before = await transport.recordedRequests().count
        XCTAssertEqual(before, 18)
        do { _ = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true); XCTFail("不能并发提交") } catch {}
        let after = await transport.recordedRequests().count; XCTAssertEqual(before, after)
        operation.cancel()
        let result = try await operation.value
        XCTAssertEqual(result.phase, .unverified)
    }

    func test依赖队列逐个核对完成再提交下一个套件() async throws {
        let dependency = manifest().replacingOccurrences(of: "Demo", with: "Dependency")
        let catalogJSON = "{\"success\":true,\"data\":{\"packages\":[" + manifest() + "," + dependency + "],\"beta_packages\":[],\"categories\":[]}}"
        let queueJSON = queue().replacingOccurrences(of: "[{\"pkg\":\"Demo\",\"beta\":false}]", with: "[{\"pkg\":\"Dependency\",\"beta\":false},{\"pkg\":\"Demo\",\"beta\":false}]")
        let prepare = [emptyInstalled, catalogJSON, emptyCatalog, ok, queueJSON, environment, environment, emptyInstalled].map { response($0) }
        let dependencyInstalled = installedList(version: "2.0").replacingOccurrences(of: "Demo", with: "Dependency")
        let finished = response(#"{"finished":true,"success":true,"progress":1}"#, wrapped: false)
        let transport = MockHTTPTransport(responses: prepare + prepare + submitResponses() + [finished, response(dependencyInstalled),
            response(dependencyInstalled), response(ok), response(environment), response(#"{"progress":0,"taskid":"synthetic-task-2"}"#, wrapped: false),
            finished, response(installedList(version: "2.0"))])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        XCTAssertEqual(plan.items.map { $0.package.packageID }, ["Dependency", "Demo"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true)
        let second = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(second.phase, .installing); XCTAssertEqual(second.completedCount, 1)
        let complete = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(complete.phase, .completed); XCTAssertEqual(complete.completedCount, 2)
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.compactMap { value("name", $0) }, ["Dependency", "Demo"])
    }

    func test安装JSON请求保留布尔与对象数组而不双重编码() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses() + submitResponses())
        let repository = try makeRepository(transport, format: .json)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        _ = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true)
        let requests = await transport.recordedRequests()
        let write = try XCTUnwrap(requests.first { value("method", $0) == "install" })
        XCTAssertEqual(jsonValue("name", write) as? String, "Demo")
        XCTAssertEqual(jsonValue("blqinst", write) as? Bool, true)
        XCTAssertEqual(jsonValue("installrunpackage", write) as? Bool, true)
        XCTAssertNotNil(jsonValue("pkgs", requests[4]) as? [[String: Any]])
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/request-fixtures/packages/quick-install/synthetic-settings/request.json"))) as? [String: Any]
        let parameters = try XCTUnwrap(fixture?["parameters"] as? [[String: String]])
        for parameter in parameters {
            let expected = parameter["encodedValue"]?.replacingOccurrences(of: "<synthetic-package>", with: "Demo")
                .replacingOccurrences(of: "<synthetic-volume>", with: "/volume1")
            let actual = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value(try XCTUnwrap(parameter["name"]), write)).utf8), options: [.fragmentsAllowed]) as? NSObject
            let expectedValue = try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(expected).utf8), options: [.fragmentsAllowed]) as? NSObject
            XCTAssertEqual(actual, expectedValue)
        }
    }

    func test提交响应缺少进度不是确定失败且仍可查询已有任务() async throws {
        let responses = planResponses() + planResponses() + Array(submitResponses().dropLast())
            + [response(#"{"taskid":"synthetic-task"}"#, wrapped: false), response(#"{"finished":true,"success":true,"progress":1}"#, wrapped: false), response(installedList(version: "2.0"))]
        let transport = MockHTTPTransport(responses: responses)
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true)
        XCTAssertEqual(start.phase, .unverified)
        let result = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(result.phase, .completed)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.filter { value("method", $0) == "install" }.count, 1)
    }

    func test安装任务记录不可读时以精确版本恢复结果() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses() + submitResponses() + [
            response(#"{"success":false,"error":{"code":408}}"#), response(installedList(version: "2.0"))])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallation(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true)
        let result = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(result.phase, .completed)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.filter { value("method", $0) == "install" }.count, 1)
    }

    func test同版本手动安装断线不能用原有版本误报成功() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticPackage-\(UUID().uuidString).spk")
        try Data("synthetic".utf8).write(to: file); defer { try? FileManager.default.removeItem(at: file) }
        let beforeWrite = [uploaded(), installedList(version: "2.0"), ok, settings(), #"{"success":true,"data":{"default_vol":"/volume1"}}"#,
            installedList(version: "2.0"), ok, environment].map { response($0) }
        let transport = MockHTTPTransport(steps: beforeWrite.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(installedList(version: "2.0")))])
        let repository = try makeRepository(transport)
        let ready = try await repository.uploadPackageForInstallation(fileURL: file)
        let pending = try await repository.configurePackageInstallation(id: ready.id, volumeID: "/volume1", startAfterInstall: true, licenseAccepted: false, values: [:])
        XCTAssertEqual(pending.phase, .unverified)
        let result = try await repository.advancePackageInstallation(id: ready.id)
        XCTAssertEqual(result.phase, .unverified)
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.filter { value("method", $0) == "upgrade" }.count, 1)
    }

    func test非法数值不截断或溢出为安装参数() async throws {
        let repository = try makeRepository(MockHTTPTransport(responses: []))
        for raw in [DsmDynamicJSON.number(1.5), .number(Double.greatestFiniteMagnitude), .boolean(true)] {
            let value = await repository.packageInteger(raw)
            XCTAssertNil(value)
        }
        let parameter = await repository.packageParameter(.number(1.5))
        XCTAssertNil(parameter)
    }

    private func makeRepository(_ transport: any DsmHTTPTransport, format: DsmRequestFormat = .form) throws -> DsmNasAdministrationRepository {
        let names = [DsmAPIName.corePackage, DsmAPIName.corePackageServer, DsmAPIName.corePackageInstallation,
                     DsmAPIName.corePackageDownload, DsmAPIName.corePackageSetting, DsmAPIName.corePackageSettingVolume,
                     DsmAPIName.corePackageFeed, DsmAPIName.corePackageInfo]
        let capabilities = Dictionary(uniqueKeysWithValues: names.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: format, selectedVersion: 2)) })
        return try DsmNasAdministrationRepository(profile: NasProfile(displayName: "Synthetic NAS", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet(capabilities), session: AuthSession(sid: "REDACTED_SESSION", synoToken: "REDACTED_SESSION", did: nil, isPortalPort: false), transport: transport)
    }
    private var ok: String { #"{"success":true}"# }
    private var emptyInstalled: String { #"{"success":true,"data":{"packages":[]}}"# }
    private var emptyCatalog: String { #"{"success":true,"data":{"packages":[],"beta_packages":[],"categories":[]}}"# }
    private var environment: String { #"{"success":true,"data":{"is_occupied":false,"volume_count":1,"volume_list":[{"mount_point":"/volume1","display":"Synthetic Volume"}],"volume_path":"/volume1"}}"# }
    private func manifest(version: String = "2.0", quick: Bool = true, beta: Bool = false) -> String {
        """
        {"id":"Demo","dname":"Synthetic Package","version":"\(version)","source":"syno","beta":\(beta),"qinst":\(quick),"qupgrade":\(quick),"install_type":"user","size":1024,"type":0,"price":null,"link":"https://packages.example.invalid/demo.spk","md5":"00000000000000000000000000000000","desc":"Synthetic description","category":["backup"]}
        """
    }
    private func catalog(manifest: String? = nil) -> String { "{\"success\":true,\"data\":{\"packages\":[\(manifest ?? self.manifest())],\"beta_packages\":[],\"categories\":[{\"id\":\"backup\",\"dname\":\"Synthetic Category\"}]}}" }
    private func queue(missing: Bool = false) -> String { "{\"success\":true,\"data\":{\"queue\":[{\"pkg\":\"Demo\",\"beta\":false}],\"non_exist_pkgs\":\(missing ? "[\"Missing\"]" : "[]"),\"conflicted_pkgs\":[],\"broken_pkgs\":[],\"replaced_pkgs\":[],\"paused_pkgs\":[]}}" }
    private func installedList(version: String, upgrade: String = "null") -> String {
        "{\"success\":true,\"data\":{\"packages\":[{\"id\":\"Demo\",\"name\":\"Synthetic Package\",\"version\":\"\(version)\",\"additional\":{\"status\":\"running\",\"startable\":true,\"install_type\":\"user\",\"ctl_uninstall\":true,\"available_operation\":{\"upgrade\":\(upgrade)}}}]}}"
    }
    private func planResponses(manifest: String? = nil) -> [DsmHTTPResponse] {
        [emptyInstalled, catalog(manifest: manifest), emptyCatalog, ok, queue(), environment, emptyInstalled].map { response($0) }
    }
    private func submitResponses() -> [DsmHTTPResponse] {
        [emptyInstalled, ok, environment, #"{"success":true,"data":{"progress":0,"taskid":"synthetic-task"}}"#].map { response($0) }
    }
    private func uploaded(license: String = "") -> String {
        "{\"success\":true,\"data\":{\"id\":\"Demo\",\"name\":\"Synthetic Package\",\"version\":\"2.0\",\"additional\":{\"task_id\":\"owned-upload\",\"startable\":true,\"install_type\":\"user\",\"licence\":\"\(license)\"}}}"
    }
    private func settings(auto: Bool = false) -> String {
        "{\"success\":true,\"data\":{\"update_channel\":false,\"enable_email\":false,\"enable_dsm\":true,\"enable_autoupdate\":\(auto),\"autoupdateall\":false,\"autoupdateimportant\":\(auto),\"default_vol\":\"/volume1\",\"volume_list\":[{\"mount_point\":\"/volume1\",\"display\":\"Synthetic Volume\"}]}}"
    }
    private func sourceList(_ name: String, _ url: String) -> String { "{\"success\":true,\"data\":{\"items\":[{\"name\":\"\(name)\",\"feed\":\"\(url)\"}]}}" }
    private func fixture(_ path: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent("contracts/fixtures-redacted/packages/\(path)/response.json"), encoding: .utf8)
    }
    private func response(_ json: String, wrapped: Bool = true) -> DsmHTTPResponse {
        DsmHTTPResponse(data: Data((wrapped ? json : "{\"success\":true,\"data\":\(json)}").utf8), statusCode: 200)
    }
    private func value(_ key: String, _ request: URLRequest) -> String? {
        URLComponents(string: "https://example.invalid/?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems?.first { $0.name == key }?.value
    }
    private func jsonValue(_ key: String, _ request: URLRequest) -> Any? {
        value(key, request).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8), options: [.fragmentsAllowed]) }
    }
}
