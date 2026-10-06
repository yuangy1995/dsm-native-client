import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class VirtualMachineConsoleWorkflowTests: XCTestCase, @unchecked Sendable {
    private func repository(_ transport: ConsolePreparationTransport, general: Bool = true) throws -> DsmServiceManagementRepository {
        let names = [DsmAPIName.virtualizationGuest] + (general ? ["SYNO.Virtualization.Setting.General"] : [])
        return try DsmServiceManagementRepository(profile: .init(displayName: "Synthetic", host: "nas.example.invalid", port: 5001),
            capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: names.map {
                ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .json, selectedVersion: 2))
            })), session: .init(sid: "REDACTED_SESSION", synoToken: nil, did: nil, isPortalPort: false), transport: transport)
    }
    func test默认键盘读取真实套件设置且地址没有凭据() async throws {
        let transport = ConsolePreparationTransport()
        let session = try await repository(transport).openVirtualMachineConsole(id: "vm-1")
        let fields = URLComponents(url: session.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(fields.first { $0.name == "kb_layout" }?.value, "de")
        XCTAssertEqual(fields.first { $0.name == "reconnect" }?.value, "false")
        XCTAssertFalse(session.url.absoluteString.contains("REDACTED"))
        let calls = await transport.calls
        XCTAssertTrue(calls.contains { $0["api"] == "SYNO.Virtualization.Setting.General" && $0["version"] == "1" && $0["method"] == "get" })
        XCTAssertTrue(calls.contains { $0["api"] == DsmAPIName.virtualizationGuest && $0["version"] == "2" && $0["method"] == "get" })
        await session.transport.close()
    }
    func test布局明确时不读取默认设置() async throws {
        let transport = ConsolePreparationTransport(mode: .explicitKeyboard)
        let session = try await repository(transport, general: false).openVirtualMachineConsole(id: "vm-1")
        XCTAssertTrue(session.url.absoluteString.contains("kb_layout=fr"))
        let calls = await transport.calls
        XCTAssertFalse(calls.contains { $0["api"] == "SYNO.Virtualization.Setting.General" })
        await session.transport.close()
    }
    func test默认布局缺少能力不能静默换英语() async throws {
        do { _ = try await repository(ConsolePreparationTransport(), general: false).openVirtualMachineConsole(id: "vm-1"); XCTFail("不能替换未读取的默认布局") }
        catch is AppError {}
    }
    func test离线错误身份重名改名与缺失字段不能打开() async throws {
        for mode in [ConsolePreparationTransport.Mode.offline, .wrongIdentity, .renamed, .missingKeyboard, .invalidDefault, .duplicateList] {
            let transport = ConsolePreparationTransport(mode: mode)
            do { _ = try await repository(transport).openVirtualMachineConsole(id: "vm-1"); XCTFail("不能连接不可信目标：\(mode)") }
            catch is AppError {}
        }
    }
    func test详情权限拒绝不继续读取网页() async throws {
        let transport = ConsolePreparationTransport(mode: .denied)
        do { _ = try await repository(transport).openVirtualMachineConsole(id: "vm-1"); XCTFail("权限拒绝不能降级") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let calls = await transport.calls
        XCTAssertFalse(calls.contains { $0["api"] == "SYNO.Virtualization.Setting.General" })
    }
}

private actor ConsolePreparationTransport: DsmHTTPTransport {
    enum Mode { case normal, explicitKeyboard, offline, wrongIdentity, renamed, missingKeyboard, invalidDefault, duplicateList, denied }
    let mode: Mode
    var calls: [[String: String]] = []
    init(mode: Mode = .normal) { self.mode = mode }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let fields = Dictionary(uniqueKeysWithValues: (URLComponents(string: "https://example.invalid/?" + String(decoding: request.httpBody ?? Data(), as: UTF8.self))?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        calls.append(fields)
        let data: [String: Any]
        if fields["api"] == "SYNO.Virtualization.Setting.General" {
            data = ["kb_layout": mode == .invalidDefault ? "Default" : "de"]
        } else if fields["method"] == "list" {
            let item = ["guest_id": "vm-1", "name": "Synthetic", "status": "running", "kb_layout": "Default"]
            data = ["guests": mode == .duplicateList ? [item, item] : [item]]
        } else {
            if mode == .denied { return .init(data: Data(#"{"success":false,"error":{"code":105}}"#.utf8), statusCode: 200) }
            var item: [String: Any] = ["guest_id": mode == .wrongIdentity ? "other" : "vm-1", "name": mode == .renamed ? "Changed" : "Synthetic",
                                       "is_online": mode != .offline, "kb_layout": mode == .explicitKeyboard ? "fr" : "Default"]
            if mode == .missingKeyboard { item.removeValue(forKey: "kb_layout") }
            data = item
        }
        return .init(data: try JSONSerialization.data(withJSONObject: ["success": true, "data": data]), statusCode: 200)
    }
}
