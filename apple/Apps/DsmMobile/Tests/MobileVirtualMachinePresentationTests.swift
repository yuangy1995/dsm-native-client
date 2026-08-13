import Foundation
import XCTest
@testable import DsmMobile

final class MobileVirtualMachinePresentationTests: XCTestCase {
    func test页面覆盖七分区四状态与刷新() throws {
        let view = try source("Sources/Features/ReadOnlyServices/VirtualMachines/MobileVirtualMachinesView.swift")
        let state = try source("Sources/Features/ReadOnlyServices/VirtualMachines/MobileVirtualMachineInventoryState.swift")
        for section in ["machines", "hosts", "storages", "networks", "images", "protection", "events"] {
            XCTAssertTrue(state.contains("case \(section)"))
        }
        for value in [".unavailable", ".failed", ".empty", ".content"] {
            XCTAssertTrue(view.contains(value) || state.contains(value))
        }
        XCTAssertTrue(view.contains(".refreshable"))
        XCTAssertTrue(view.contains("await inventory.refresh()"))
        XCTAssertTrue(view.contains("state.hasRefreshError"))
        XCTAssertTrue(view.contains("state.requiresReconnect"))
        XCTAssertTrue(view.contains("mobile.virtual-machines.session-expired"))
    }

    func test页面采用原生自适应列表并具备源码无障碍门() throws {
        let view = try source("Sources/Features/ReadOnlyServices/VirtualMachines/MobileVirtualMachinesView.swift")
        for expected in [
            "horizontalSizeClass == .regular", "NavigationLink", "List {", "List(selection:",
            ".listStyle(.insetGrouped)", ".listStyle(.sidebar)", "minHeight: 44",
            ".accessibilityElement", ".accessibilityLabel", ".accessibilityAddTraits",
            "fillsAvailableContentArea"
        ] { XCTAssertTrue(view.contains(expected), "缺少：\(expected)") }
        XCTAssertFalse(view.contains("font(.system(size:"))
        XCTAssertFalse(view.contains("ScrollView(.horizontal"))
        XCTAssertFalse(view.contains("withAnimation"))
    }

    func test页面不展示绑定事件正文与桌面写能力() throws {
        let view = try source("Sources/Features/ReadOnlyServices/VirtualMachines/MobileVirtualMachinesView.swift")
        for forbidden in [
            "event.message", "event.user", "hostID", "hostName", "ipAddress", "keyboardLayout",
            "cpuWeight", "item.description", "createVirtualMachine", "deleteVirtualMachine",
            "powerOn", "console"
        ] { XCTAssertFalse(view.localizedCaseInsensitiveContains(forbidden), "不应出现：\(forbidden)") }
    }

    func test页面保留主分区筛选且资源键集合固定() throws {
        let view = try source("Sources/Features/ReadOnlyServices/VirtualMachines/MobileVirtualMachinesView.swift")
        for expected in [
            "Picker(", "MobileVirtualMachineFilter.allCases", "inventory.state.visibleMachines",
            "inventory.setFilter(.all)", ".filteredEmpty"
        ] { XCTAssertTrue(view.contains(expected), "缺少：\(expected)") }
        XCTAssertEqual(resourceKeys(in: view), Self.expectedResourceKeys)
    }

    private func source(_ path: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    private func resourceKeys(in source: String) -> Set<String> {
        let expression = try! NSRegularExpression(pattern: #"mobile\.virtual-machines\.[a-z0-9.-]+"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(expression.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        })
    }

    static let expectedResourceKeys: Set<String> = [
        "mobile.virtual-machines.accessibility.item", "mobile.virtual-machines.accessibility.section",
        "mobile.virtual-machines.action.retry", "mobile.virtual-machines.action.show-all",
        "mobile.virtual-machines.detail.select.message", "mobile.virtual-machines.detail.select.title",
        "mobile.virtual-machines.field.allocated", "mobile.virtual-machines.field.auto-start",
        "mobile.virtual-machines.field.capacity", "mobile.virtual-machines.field.cpu",
        "mobile.virtual-machines.field.kind", "mobile.virtual-machines.field.level",
        "mobile.virtual-machines.field.memory", "mobile.virtual-machines.field.status",
        "mobile.virtual-machines.field.storage", "mobile.virtual-machines.field.time",
        "mobile.virtual-machines.filter.all", "mobile.virtual-machines.filter.attention",
        "mobile.virtual-machines.filter.label", "mobile.virtual-machines.filter.running",
        "mobile.virtual-machines.filter.stopped", "mobile.virtual-machines.filtered-empty.message",
        "mobile.virtual-machines.filtered-empty.title", "mobile.virtual-machines.loading",
        "mobile.virtual-machines.protection.plan", "mobile.virtual-machines.protection.retention",
        "mobile.virtual-machines.protection.schedule", "mobile.virtual-machines.read-only.notice",
        "mobile.virtual-machines.refresh.failed", "mobile.virtual-machines.section.empty.message",
        "mobile.virtual-machines.session-expired",
        "mobile.virtual-machines.section.empty.title", "mobile.virtual-machines.section.events",
        "mobile.virtual-machines.section.failed.message", "mobile.virtual-machines.section.failed.title",
        "mobile.virtual-machines.section.hosts", "mobile.virtual-machines.section.images",
        "mobile.virtual-machines.section.machines", "mobile.virtual-machines.section.networks",
        "mobile.virtual-machines.section.protection", "mobile.virtual-machines.section.state.content",
        "mobile.virtual-machines.section.state.empty", "mobile.virtual-machines.section.state.failed",
        "mobile.virtual-machines.section.state.unavailable", "mobile.virtual-machines.section.storages",
        "mobile.virtual-machines.section.unavailable.message",
        "mobile.virtual-machines.section.unavailable.title",
        "mobile.virtual-machines.status.attention", "mobile.virtual-machines.status.running",
        "mobile.virtual-machines.status.stopped", "mobile.virtual-machines.status.unknown",
        "mobile.virtual-machines.value.disabled", "mobile.virtual-machines.value.enabled",
        "mobile.virtual-machines.value.time-unavailable"
    ]
}
