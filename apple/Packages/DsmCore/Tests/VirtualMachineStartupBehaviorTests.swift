import XCTest
@testable import DsmCore

final class VirtualMachineStartupBehaviorTests: XCTestCase {
    func test启动三态保持原始值且旧布尔写入代表明确开关() {
        XCTAssertEqual(VirtualMachineStartupBehavior.allCases.map(\.rawValue), [0, 1, 2])
        XCTAssertEqual(VirtualMachineUpdate(autoStart: true).startupBehavior, .powerOn)
        XCTAssertEqual(VirtualMachineUpdate(autoStart: false).startupBehavior, .off)
        XCTAssertNil(VirtualMachineUpdate(description: "only description").startupBehavior)
        XCTAssertEqual(VirtualMachineUpdate(startupBehavior: .restorePreviousState).startupBehavior, .restorePreviousState)
        let creation = VirtualMachineCreation(name: "Synthetic", operatingSystem: .linux, storageID: "storage",
            networkID: "network", cpuCount: 2, memoryMiB: 2048, diskGiB: 20, autoStart: true)
        XCTAssertEqual(creation.startupBehavior, .powerOn)
    }

    func test未知读取不伪装成关闭且旧布尔属性仅作兼容() {
        XCTAssertNil(VirtualMachine(id: "vm", name: "VM", status: "unknown").startupBehavior)
        let restored = VirtualMachine(id: "vm", name: "VM", status: "shutdown", startupBehavior: .restorePreviousState)
        XCTAssertEqual(restored.startupBehavior, .restorePreviousState)
        XCTAssertTrue(restored.autoStart)
        let inventory = VirtualMachineInventoryItem(id: "vm", name: "VM", status: "shutdown", startupBehavior: .powerOn)
        XCTAssertEqual(inventory.startupBehavior, .powerOn)
        XCTAssertTrue(inventory.autoStart)
    }
}
