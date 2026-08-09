import Foundation
import XCTest
@testable import DsmMobile

final class MobileVirtualMachinePresentationTests: XCTestCase {
    func test页面只呈现公开清单且旧桌面管理套件生产不可达() throws {
        let source = try viewSource()
        for forbidden in [
            "MobileAppModel", "virtualMachineSnapshot", ".hosts", ".storages", ".networks",
            ".images", "protection", "event.message", "event.user", "logSearch", "logLevel",
            "create", "delete", "startVirtualMachine", "stopVirtualMachine", "console"
        ] {
            XCTAssertFalse(source.localizedCaseInsensitiveContains(forbidden), "页面不应引用：\(forbidden)")
        }
        XCTAssertTrue(source.contains("MobileVirtualMachineInventoryModel"))
    }

    func test页面覆盖五态刷新保留与明确恢复动作() throws {
        let view = try viewSource()
        let model = try modelSource()
        let workspace = try source("Sources/AppShell/MobileWorkspaceView.swift")
        for state in [".loading", ".empty", ".filteredEmpty", ".error", ".content"] {
            XCTAssertTrue(view.contains(state) || model.contains(state), "缺少状态：\(state)")
        }
        XCTAssertTrue(view.contains("state.hasRefreshError"))
        XCTAssertTrue(view.contains("inventory.setFilter(.all)"))
        XCTAssertTrue(view.contains("await inventory.refresh()"))
        XCTAssertTrue(model.contains("preservesContent"))
        XCTAssertTrue(workspace.contains("virtualMachineInventoryModel.state.isRefreshing"))
        XCTAssertTrue(workspace.contains("ProgressView()"))
        XCTAssertTrue(workspace.contains(".disabled("))
    }

    func test页面遵循iPhone与iPad原生交互和无障碍边界() throws {
        let source = try viewSource()
        XCTAssertTrue(source.contains("horizontalSizeClass == .regular"))
        XCTAssertTrue(source.contains("NavigationLink"))
        XCTAssertTrue(source.contains("inventory.select(item.id)"))
        XCTAssertTrue(source.contains(".listStyle(.insetGrouped)"))
        XCTAssertTrue(source.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(source.contains(".refreshable"))
        XCTAssertTrue(source.contains("minHeight: 44"))
        XCTAssertTrue(source.contains(".accessibilityElement"))
        XCTAssertTrue(source.contains(".accessibilityAddTraits"))
        XCTAssertTrue(source.contains("fillsAvailableContentArea"))
        XCTAssertFalse(source.contains("ScrollView(.horizontal"))
        XCTAssertFalse(source.contains("withAnimation"))
        XCTAssertFalse(source.contains("font(.system(size:"))
    }

    func test页面不展示服务返回的敏感或桌面专属字段() throws {
        let source = try viewSource()
        for forbidden in [
            "item.description", "item.hostID", "item.storageID", "item.ipAddress",
            "item.keyboardLayout", "item.cpuWeight"
        ] {
            XCTAssertFalse(source.contains(forbidden), "页面不应展示：\(forbidden)")
        }
        for allowed in ["cpuCount", "memoryBytes", "storageBytes", "autoStart"] {
            XCTAssertTrue(source.contains(allowed))
        }
    }

    func test页面只引用已声明的虚拟机资源键() throws {
        let source = try viewSource()
        let expression = try NSRegularExpression(pattern: #"mobile\.virtual-machines\.[a-z0-9.-]+"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let actual = Set(expression.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        })
        XCTAssertEqual(actual, Self.expectedResourceKeys)
    }

    private func viewSource() throws -> String {
        try source("Sources/Features/ReadOnlyServices/VirtualMachines/MobileVirtualMachinesView.swift")
    }

    private func modelSource() throws -> String {
        try source("Sources/Features/ReadOnlyServices/VirtualMachines/MobileVirtualMachineInventoryModel.swift")
    }

    private func source(_ path: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    static let expectedResourceKeys: Set<String> = [
        "mobile.virtual-machines.accessibility.row",
        "mobile.virtual-machines.action.retry",
        "mobile.virtual-machines.action.show-all",
        "mobile.virtual-machines.detail.select.message",
        "mobile.virtual-machines.detail.select.title",
        "mobile.virtual-machines.empty.message",
        "mobile.virtual-machines.empty.title",
        "mobile.virtual-machines.error.message",
        "mobile.virtual-machines.error.title",
        "mobile.virtual-machines.field.auto-start",
        "mobile.virtual-machines.field.cpu",
        "mobile.virtual-machines.field.memory",
        "mobile.virtual-machines.field.status",
        "mobile.virtual-machines.field.storage",
        "mobile.virtual-machines.filter.all",
        "mobile.virtual-machines.filter.attention",
        "mobile.virtual-machines.filter.label",
        "mobile.virtual-machines.filter.running",
        "mobile.virtual-machines.filter.stopped",
        "mobile.virtual-machines.filtered-empty.message",
        "mobile.virtual-machines.filtered-empty.title",
        "mobile.virtual-machines.loading",
        "mobile.virtual-machines.read-only.notice",
        "mobile.virtual-machines.refresh.failed",
        "mobile.virtual-machines.status.attention",
        "mobile.virtual-machines.status.running",
        "mobile.virtual-machines.status.stopped",
        "mobile.virtual-machines.status.unknown",
        "mobile.virtual-machines.value.disabled",
        "mobile.virtual-machines.value.enabled"
    ]
}
