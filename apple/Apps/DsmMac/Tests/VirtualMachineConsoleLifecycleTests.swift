import DsmCore
import Foundation
import XCTest
@testable import DsmMacExecutable

@MainActor final class VirtualMachineConsoleLifecycleTests: XCTestCase {
    private func session(_ transport: MacConsoleLifecycleTransport) throws -> VirtualMachineConsoleSession {
        .init(policy: try .init(baseURL: XCTUnwrap(URL(string: "https://example.invalid")), machineID: "vm-1", name: "Synthetic", keyboardLayout: "en-us"), transport: transport)
    }
    func test关闭模块立即关闭独立窗口并停止传输() async throws {
        let transport = MacConsoleLifecycleTransport(), stub = ServiceManagementRepositoryStub()
        await stub.setConsoleSession(try session(transport))
        let model = ServiceManagementModel(repository: stub)
        let opened = await model.openVirtualMachineConsole(id: "vm-1")
        let value = try XCTUnwrap(opened)
        var closedWindow = false
        model.registerConsoleWindow(value) { closedWindow = true }
        model.setEnabledModules([])
        XCTAssertTrue(closedWindow)
        for _ in 0..<20 { if await transport.closed { break }; await Task.yield() }
        let closed = await transport.closed
        XCTAssertTrue(closed)
        let next = await model.openVirtualMachineConsole(id: "vm-1")
        XCTAssertNil(next)
    }
    func test退出账号后迟到控制台不会重新出现() async throws {
        let transport = MacConsoleLifecycleTransport(), stub = ServiceManagementRepositoryStub()
        await stub.setConsoleSession(try session(transport), held: true)
        let model = ServiceManagementModel(repository: stub)
        let task = Task { await model.openVirtualMachineConsole(id: "vm-1") }
        await stub.waitForConsole()
        model.closeVirtualMachineConsoles()
        await stub.releaseConsolePreparation()
        let value = await task.value, closed = await transport.closed
        XCTAssertNil(value); XCTAssertTrue(closed)
    }
}

private actor MacConsoleLifecycleTransport: VirtualMachineConsoleTransport {
    var closed = false
    func resource(_ url: URL) async throws -> VirtualMachineConsoleResource { throw VirtualMachineConsoleError.unavailable }
    func connect() async throws {}
    func receive() async throws -> Data { throw VirtualMachineConsoleError.unavailable }
    func send(_ data: Data) async throws {}
    func close() async { closed = true }
}
