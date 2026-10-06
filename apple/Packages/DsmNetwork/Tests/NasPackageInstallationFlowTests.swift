import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class NasPackageInstallationFlowTests: XCTestCase {
    func test快速安装按唯一提交接受及实际完成顺序保存检查点() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses() + submitResponses() + [
            response(#"{"finished":true,"success":true,"progress":1}"#, wrapped: false), response(installedList(version: "2.0"))])
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        let started = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: false) { await events.append($0) }
        let done = try await repository.advancePackageInstallation(id: started.id)
        XCTAssertEqual(done.phase, .completed)
        let values = await events.values
        XCTAssertEqual(values.map(\.stage), [.willSubmit, .accepted, .verified])
        XCTAssertEqual(Set(values.map(\.step)), [.install])
        XCTAssertTrue(values.allSatisfy { $0.id == started.id && $0.package?.packageID == "Demo" && !$0.isSynchronousInstallation })
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.count, 1)
        XCTAssertTrue(requests.filter { value("api", $0) == DsmAPIName.corePackage && value("method", $0) == "list" }.allSatisfy { value("version", $0) == "2" })
    }

    func test写前记录失败或当前权限撤销时零安装() async throws {
        for denied in [false, true] {
            let transport = MockHTTPTransport(responses: planResponses() + planResponses() + Array(submitResponses().dropLast()))
            let repository = try makeRepository(transport)
            let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
            do {
                _ = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { event in
                    XCTAssertEqual(event.stage, .willSubmit)
                    if denied { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                XCTFail("不应提交")
            } catch {
                if denied { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
                else { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
            }
            let requests = await transport.recordedRequests()
            XCTAssertFalse(requests.contains { value("method", $0) == "install" })
        }
    }

    func test接受回执保存失败不跟读或重放() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses() + submitResponses())
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        do {
            _ = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { event in
                await events.append(event)
                if event.stage == .accepted { throw CocoaError(.fileWriteOutOfSpace) }
            }
            XCTFail("保存失败必须传出")
        } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
        let requests = await transport.recordedRequests(), values = await events.values
        XCTAssertEqual(values.map(\.stage), [.willSubmit, .accepted])
        XCTAssertEqual(value("method", requests.last!), "install")
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.count, 1)
        do { _ = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { _ in }; XCTFail("不可重放") } catch {}
        let count = await transport.recordedRequests().count; XCTAssertEqual(count, requests.count)
    }

    func test前一依赖完成记录保存失败时不提交下一项() async throws {
        let (prepare, installed) = dependencyResponses()
        let transport = MockHTTPTransport(responses: prepare + prepare + submitResponses() + [
            response(#"{"finished":true,"success":true}"#, wrapped: false), response(installed)])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { event in
            if event.stage == .verified { throw CocoaError(.fileWriteOutOfSpace) }
        }
        do { _ = try await repository.advancePackageInstallation(id: start.id); XCTFail("记录失败") }
        catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.compactMap { value("name", $0) }, ["Dependency"])
        XCTAssertEqual(value("method", requests.last!), "list")
    }

    func test第二依赖写前重新检查权限并保留第一项完成() async throws {
        let (prepare, installed) = dependencyResponses()
        let transport = MockHTTPTransport(responses: prepare + prepare + submitResponses() + [
            response(#"{"finished":true,"success":true}"#, wrapped: false), response(installed), response(installed), response(ok), response(environment)])
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { event in
            await events.append(event)
            if event.stage == .willSubmit && event.completedCount == 1 { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
        }
        do { _ = try await repository.advancePackageInstallation(id: start.id); XCTFail("权限已撤销") }
        catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
        let values = await events.values, requests = await transport.recordedRequests()
        XCTAssertEqual(values.filter { $0.stage == .verified }.map { $0.package?.packageID }, ["Dependency"])
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.compactMap { value("name", $0) }, ["Dependency"])
    }

    func test提交明确拒绝记录失败且不会靠原版本变成成功() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses() + Array(submitResponses().dropLast()) + [response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        let result = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { await events.append($0) }
        XCTAssertEqual(result.phase, .failed)
        let next = try await repository.advancePackageInstallation(id: result.id)
        XCTAssertEqual(next.phase, .failed)
        let values = await events.values, requests = await transport.recordedRequests()
        XCTAssertEqual(values.map(\.stage), [.willSubmit, .rejected])
        XCTAssertEqual(value("method", requests.last!), "install")
    }

    func test安装证书错误原样传出并立即停止链路() async throws {
        let responses = planResponses() + planResponses() + Array(submitResponses().dropLast())
        let transport = MockHTTPTransport(steps: responses.map(MockHTTPTransport.Step.response) + [.urlError(.serverCertificateUntrusted)])
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        do { _ = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { await events.append($0) }; XCTFail("证书异常必须抛出") }
        catch { XCTAssertTrue(DsmNasAdministrationRepository.packagePreferenceTrustFailure(error)) }
        let values = await events.values, requests = await transport.recordedRequests()
        XCTAssertEqual(values.map(\.stage), [.willSubmit])
        XCTAssertEqual(value("method", requests.last!), "install")
    }

    func test读取任务权限拒绝不继续读目录或提交后续依赖() async throws {
        let transport = MockHTTPTransport(responses: planResponses() + planResponses() + submitResponses() + [response(#"{"success":false,"error":{"code":105}}"#)])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { _ in }
        do { _ = try await repository.advancePackageInstallation(id: start.id); XCTFail("权限不足") }
        catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
        let requests = await transport.recordedRequests()
        XCTAssertEqual(value("method", requests.last!), "status")
    }

    func test未知安装通过实际新版本恢复但不重放() async throws {
        let responses = planResponses() + planResponses() + Array(submitResponses().dropLast())
        let transport = MockHTTPTransport(steps: responses.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(installedList(version: "2.0")))])
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { await events.append($0) }
        XCTAssertEqual(start.phase, .unverified)
        let done = try await repository.advancePackageInstallation(id: start.id)
        XCTAssertEqual(done.phase, .completed)
        let values = await events.values, requests = await transport.recordedRequests()
        XCTAssertEqual(values.map(\.stage), [.willSubmit, .verified])
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.count, 1)
    }

    func test管理目录拒绝部分结果并不降级请求版本() async throws {
        let partial = emptyInstalled.replacingOccurrences(of: "\"packages\":[]", with: "\"total\":2,\"packages\":[]")
        let transport = MockHTTPTransport(responses: [response(partial)])
        let repository = try makeRepository(transport)
        do { _ = try await repository.loadPackagesForManagement(); XCTFail("部分目录不能恢复结果") } catch {}
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 1); XCTAssertEqual(value("version", requests[0]), "2")
    }

    func test第三方目录证书异常不能被吞为普通来源不可用() async throws {
        let transport = MockHTTPTransport(steps: [.response(response(emptyInstalled)), .response(response(catalog())), .urlError(.serverCertificateUntrusted)])
        let repository = try makeRepository(transport)
        do { _ = try await repository.loadPackageCatalogForManagement(); XCTFail("停止证书异常链路") }
        catch { XCTAssertTrue(DsmNasAdministrationRepository.packagePreferenceTrustFailure(error)) }
    }

    func test上传前失败不发送文件且接受后保存失败不自动清理() async throws {
        let file = try syntheticFile(); defer { try? FileManager.default.removeItem(at: file) }
        for stage in [NasPackageInstallationCheckpoint.Stage.willSubmit, .accepted] {
            let transport = MockHTTPTransport(responses: [response(uploaded())])
            let repository = try makeRepository(transport)
            do {
                _ = try await repository.uploadPackageForInstallation(fileURL: file) { event in
                    if event.stage == stage { throw CocoaError(.fileWriteOutOfSpace) }
                }
                XCTFail("必须停止")
            } catch { XCTAssertEqual((error as? CocoaError)?.code, .fileWriteOutOfSpace) }
            let bodies = await transport.recordedUploadBodies(), requests = await transport.recordedRequests()
            XCTAssertEqual(bodies.count, stage == .willSubmit ? 0 : 1)
            XCTAssertEqual(requests.count, stage == .willSubmit ? 0 : 1)
        }
    }

    func test手动安装前再次检查权限且不提交默认字段() async throws {
        let file = try syntheticFile(); defer { try? FileManager.default.removeItem(at: file) }
        let transport = MockHTTPTransport(responses: uploadResponses() + [response(emptyInstalled), response(ok), response(environment)])
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let ready = try await repository.uploadPackageForInstallation(fileURL: file) { event in
            await events.append(event)
            if event.step == .install && event.stage == .willSubmit { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
        }
        do { _ = try await repository.configurePackageInstallation(id: ready.id, volumeID: "/volume1", startAfterInstall: false, licenseAccepted: true, values: [:]); XCTFail("权限撤回") }
        catch { XCTAssertEqual((error as? AppError)?.category, .permissionDenied) }
        let values = await events.values, requests = await transport.recordedRequests()
        XCTAssertEqual(values.map(\.stage), [.willSubmit, .accepted, .prepared, .willSubmit])
        XCTAssertEqual(Set(values.map(\.id)), [ready.id])
        XCTAssertTrue(values.last?.isSynchronousInstallation == true)
        XCTAssertFalse(requests.contains { ["install", "upgrade", "clean", "delete"].contains(value("method", $0) ?? "") })
    }

    func test清理前权限失败零清理且未知清理不重放() async throws {
        let file = try syntheticFile(); defer { try? FileManager.default.removeItem(at: file) }
        for denied in [true, false] {
            let transport = MockHTTPTransport(steps: uploadResponses().map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost)])
            let repository = try makeRepository(transport)
            let ready = try await repository.uploadPackageForInstallation(fileURL: file) { event in
                if denied && event.step == .cleanup && event.stage == .willSubmit { throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: "") }
            }
            do { _ = try await repository.cancelPackageInstallation(id: ready.id); XCTFail("必须显示原错误") } catch {}
            if !denied {
                let again = try await repository.cancelPackageInstallation(id: ready.id)
                XCTAssertFalse(again.canCancel)
                let refreshed = try await repository.advancePackageInstallation(id: ready.id)
                XCTAssertEqual(refreshed.phase, .unverified)
            }
            let requests = await transport.recordedRequests()
            XCTAssertEqual(requests.filter { value("method", $0) == "clean" }.count, denied ? 0 : 1)
            XCTAssertFalse(requests.contains { value("method", $0) == "install" })
        }
    }

    func test同版本重装丢失回执不能以旧版本恢复() async throws {
        let file = try syntheticFile(); defer { try? FileManager.default.removeItem(at: file) }
        let preparation = [uploaded(), installedList(version: "2.0"), ok, settings(), #"{"success":true,"data":{"default_vol":"/volume1"}}"#,
            installedList(version: "2.0"), ok, environment].map { response($0) }
        let transport = MockHTTPTransport(steps: preparation.map(MockHTTPTransport.Step.response) + [.urlError(.networkConnectionLost), .response(response(installedList(version: "2.0")))])
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let ready = try await repository.uploadPackageForInstallation(fileURL: file) { await events.append($0) }
        let pending = try await repository.configurePackageInstallation(id: ready.id, volumeID: "/volume1", startAfterInstall: false, licenseAccepted: false, values: [:])
        XCTAssertEqual(pending.phase, .unverified)
        let refreshed = try await repository.advancePackageInstallation(id: ready.id)
        XCTAssertEqual(refreshed.phase, .unverified)
        let values = await events.values, requests = await transport.recordedRequests()
        XCTAssertFalse(values.contains { $0.stage == .verified })
        XCTAssertEqual(requests.filter { value("method", $0) == "upgrade" }.count, 1)
    }

    func test取消下载先保存仅一次请求并等待任务实际结束() async throws {
        let candidate = manifest(quick: false)
        let transport = MockHTTPTransport(responses: planResponses(manifest: candidate) + planResponses(manifest: candidate) + submitResponses() + [
            response(ok), response(#"{"finished":false,"progress":0.5}"#, wrapped: false), response(#"{"finished":true,"success":false}"#, wrapped: false)])
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: false) { await events.append($0) }
        let cancel = try await repository.cancelPackageInstallation(id: start.id)
        XCTAssertEqual(cancel.phase, .downloading); XCTAssertFalse(cancel.canCancel)
        _ = try await repository.cancelPackageInstallation(id: start.id)
        let pending = try await repository.advancePackageInstallation(id: start.id); XCTAssertEqual(pending.phase, .downloading)
        let done = try await repository.advancePackageInstallation(id: start.id); XCTAssertEqual(done.phase, .cancelled)
        let values = await events.values, requests = await transport.recordedRequests()
        XCTAssertEqual(values.filter { $0.step == .cancelDownload }.map(\.stage), [.willSubmit, .accepted, .verified])
        XCTAssertEqual(requests.filter { value("method", $0) == "cancel" }.count, 1)
        XCTAssertEqual(value("taskid", try XCTUnwrap(requests.first { value("method", $0) == "cancel" })), "synthetic-task")
    }

    func test状态超时后的目录证书错误也立即停止() async throws {
        let transport = MockHTTPTransport(steps: (planResponses() + planResponses() + submitResponses()).map(MockHTTPTransport.Step.response)
            + [.urlError(.timedOut), .urlError(.serverCertificateUntrusted)])
        let repository = try makeRepository(transport)
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: true) { _ in }
        do { _ = try await repository.advancePackageInstallation(id: start.id); XCTFail("不能吞掉第二次读取的证书错误") }
        catch { XCTAssertTrue(DsmNasAdministrationRepository.packagePreferenceTrustFailure(error)) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(value("method", requests.last!), "list")
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.count, 1)
    }

    func test取消时下载恰好完成只清理本次暂存再结束() async throws {
        let candidate = manifest(quick: false)
        let transport = MockHTTPTransport(responses: planResponses(manifest: candidate) + planResponses(manifest: candidate) + submitResponses() + [
            response(ok), response(#"{"finished":true,"success":true}"#, wrapped: false), response(uploaded()), response(ok)])
        let repository = try makeRepository(transport), events = PackageInstallationEvents()
        let plan = try await repository.preparePackageInstallationForManagement(catalogIDs: ["Demo:stable"])
        let start = try await repository.startPackageInstallation(planID: plan.id, volumes: [:], startAfterInstall: false) { await events.append($0) }
        _ = try await repository.cancelPackageInstallation(id: start.id)
        let done = try await repository.advancePackageInstallation(id: start.id); XCTAssertEqual(done.phase, .cancelled)
        let values = await events.values, requests = await transport.recordedRequests()
        XCTAssertEqual(values.suffix(3).map(\.step), [.cleanup, .cleanup, .cancelDownload])
        XCTAssertEqual(values.suffix(3).map(\.stage), [.willSubmit, .accepted, .verified])
        XCTAssertEqual(value("task_id", requests.last!), "owned-upload")
        XCTAssertEqual(requests.filter { value("method", $0) == "install" }.count, 1)
        XCTAssertNil(done.configuration)
    }

    func test安装选项提交前位置消失或被占用均零正式安装() async throws {
        let file = try syntheticFile(); defer { try? FileManager.default.removeItem(at: file) }
        for changed in [environment.replacingOccurrences(of: "/volume1", with: "/volume2"), environment.replacingOccurrences(of: "\"is_occupied\":false", with: "\"is_occupied\":true")] {
            let transport = MockHTTPTransport(responses: uploadResponses() + [response(emptyInstalled), response(ok), response(changed)])
            let repository = try makeRepository(transport), events = PackageInstallationEvents()
            let ready = try await repository.uploadPackageForInstallation(fileURL: file) { await events.append($0) }
            do { _ = try await repository.configurePackageInstallation(id: ready.id, volumeID: "/volume1", startAfterInstall: false, licenseAccepted: true, values: [:]); XCTFail("安装位置已经变化") } catch {}
            let values = await events.values, requests = await transport.recordedRequests()
            XCTAssertFalse(values.contains { $0.step == .install })
            XCTAssertFalse(requests.contains { ["install", "upgrade"].contains(value("method", $0) ?? "") })
        }
    }

    func test上传证书错误映射为信任失败且没有后续清理() async throws {
        let file = try syntheticFile(); defer { try? FileManager.default.removeItem(at: file) }
        let transport = MockHTTPTransport(steps: [.urlError(.serverCertificateUntrusted)]), repository = try makeRepository(transport)
        do { _ = try await repository.uploadPackageForInstallation(fileURL: file) { _ in }; XCTFail("上传必须停止") }
        catch { XCTAssertEqual((error as? AppError)?.category, .tlsUntrusted) }
        let requests = await transport.recordedRequests(); XCTAssertEqual(requests.count, 1)
    }

    private func syntheticFile() throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticInstall-\(UUID()).spk")
        try Data("synthetic bytes".utf8).write(to: file); return file
    }
    private func uploadResponses() -> [DsmHTTPResponse] {
        [uploaded(), emptyInstalled, ok, settings(), #"{"success":true,"data":{"default_vol":"/volume1"}}"#].map { response($0) }
    }
    private func dependencyResponses() -> ([DsmHTTPResponse], String) {
        let dependency = manifest().replacingOccurrences(of: "Demo", with: "Dependency")
        let catalogJSON = "{\"success\":true,\"data\":{\"packages\":[" + manifest() + "," + dependency + "],\"beta_packages\":[],\"categories\":[]}}"
        let queueJSON = queue().replacingOccurrences(of: "[{\"pkg\":\"Demo\",\"beta\":false}]", with: "[{\"pkg\":\"Dependency\",\"beta\":false},{\"pkg\":\"Demo\",\"beta\":false}]")
        let prepare = [emptyInstalled, catalogJSON, emptyCatalog, ok, queueJSON, environment, environment, emptyInstalled].map { response($0) }
        return (prepare, installedList(version: "2.0").replacingOccurrences(of: "Demo", with: "Dependency"))
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

private actor PackageInstallationEvents {
    var values: [NasPackageInstallationCheckpoint] = []
    func append(_ value: NasPackageInstallationCheckpoint) { values.append(value) }
}
