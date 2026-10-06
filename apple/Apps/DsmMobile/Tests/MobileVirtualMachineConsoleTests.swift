import DsmCore
import DsmNetwork
import Foundation
import XCTest
@testable import DsmMobile

@MainActor final class MobileVirtualMachineConsoleTests: XCTestCase {
    private var roots: [URL] = []
    override func tearDown() async throws {
        for root in roots { try? FileManager.default.removeItem(at: root) }; roots = []
    }
    private func make(mode: String = "vmm-console", supports: Bool = true, allowed: Bool = true) throws -> (MobileVirtualMachineControlModel, MobileVirtualMachineUITransport, MobileConsolePermission) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vmm-console-" + UUID().uuidString)
        roots.append(root)
        let api = MobileVirtualMachineUITransport(mode: mode), permission = MobileConsolePermission(allowed: allowed)
        let names = [DsmAPIName.virtualizationAPIGuest] + (supports ? [DsmAPIName.virtualizationGuest] : [])
        let profile = try NasProfile(displayName: "Synthetic", host: "example.invalid", port: 5001)
        let repository = try DsmServiceManagementRepository(profile: profile,
            capabilities: CapabilitySet(Dictionary(uniqueKeysWithValues: names.map { ($0, ApiCapability(name: $0, path: "entry.cgi", minVersion: 1, maxVersion: 2, requestFormat: .form, selectedVersion: 2)) })),
            session: .init(sid: "SYNTHETIC", synoToken: nil, did: nil, isPortalPort: false), transport: api,
            consoleTransportFactory: { policy, _ in MobileConsoleUITransport(policy: policy) })
        let model = MobileVirtualMachineControlModel(root: root)
        model.configure(profile: profile, repository: repository, authorize: { await permission.check() })
        return (model, api, permission)
    }
    func test运行能力与权限决定入口且不依赖待真机常量() async throws {
        let (model, _, _) = try make(); await model.refresh()
        XCTAssertTrue(model.canOpenConsole(id: "synthetic-vm"))
        for (mode, supports, allowed) in [("vmm-console-stopped", true, true), ("vmm-console", false, true), ("vmm-console", true, false)] {
            let (blocked, _, _) = try make(mode: mode, supports: supports, allowed: allowed); await blocked.refresh()
            XCTAssertFalse(blocked.canOpenConsole(id: "synthetic-vm"))
        }
    }
    func test打开后账号停用立即关闭会话() async throws {
        let (model, _, _) = try make(); await model.refresh()
        let target = try XCTUnwrap(model.targets.first)
        let session = try await model.openConsole(target, activation: model.activation)
        XCTAssertEqual(model.consoleSession?.id, session.id)
        model.deactivate()
        XCTAssertNil(model.consoleSession)
        let transport = try XCTUnwrap(session.transport as? MobileConsoleUITransport)
        for _ in 0..<20 { if await transport.closed { break }; await Task.yield() }
        let closed = await transport.closed; XCTAssertTrue(closed)
    }
    func test权限在打开前撤回不创建控制台() async throws {
        let (model, transport, permission) = try make(); await model.refresh(); await permission.set(false)
        let before = await transport.calls.count
        do { _ = try await model.openConsole(XCTUnwrap(model.targets.first), activation: model.activation); XCTFail("不能使用缓存权限打开") }
        catch let error as AppError { XCTAssertEqual(error.category, .permissionDenied) }
        let after = await transport.calls.count
        XCTAssertEqual(before, after); XCTAssertNil(model.consoleSession)
    }
    func test旧页面与更名目标不能打开() async throws {
        let (model, transport, _) = try make(); await model.refresh()
        let target = try XCTUnwrap(model.targets.first), token = model.activation
        await transport.renameFirst()
        do { _ = try await model.openConsole(target, activation: token); XCTFail("更名目标不能按旧确认打开") } catch {}
        model.deactivate()
        do { _ = try await model.openConsole(target, activation: token); XCTFail("旧账号页面不能继续") } catch {}
        XCTAssertNil(model.consoleSession)
    }
    func test重连新窗口关闭前一会话且不发送输入() async throws {
        let (model, _, _) = try make(); await model.refresh()
        let target = try XCTUnwrap(model.targets.first)
        let first = try await model.openConsole(target, activation: model.activation)
        let second = try await model.openConsole(target, activation: model.activation)
        XCTAssertNotEqual(first.id, second.id)
        let old = try XCTUnwrap(first.transport as? MobileConsoleUITransport)
        for _ in 0..<20 { if await old.closed { break }; await Task.yield() }
        let closed = await old.closed, inputs = await old.inputs
        XCTAssertTrue(closed); XCTAssertTrue(inputs.isEmpty); model.closeConsole()
    }
}

private actor MobileConsolePermission {
    var allowed: Bool
    init(allowed: Bool) { self.allowed = allowed }
    func set(_ value: Bool) { allowed = value }
    func check() -> Bool { allowed }
}
