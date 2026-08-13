import Foundation
import XCTest
@testable import DsmMobile

final class MobileContainerPresentationTests: XCTestCase {
    func test页面覆盖五分区四状态与刷新() throws {
        let view = try source("Sources/Features/ReadOnlyServices/Containers/MobileContainersView.swift")
        let state = try source("Sources/Features/ReadOnlyServices/Containers/MobileContainerInventoryState.swift")
        for section in ["containers", "images", "networks", "projects", "events"] {
            XCTAssertTrue(state.contains("case \(section)"))
        }
        for value in [".unavailable", ".failed", ".empty", ".content"] {
            XCTAssertTrue(view.contains(value) || state.contains(value))
        }
        XCTAssertTrue(view.contains(".refreshable"))
        XCTAssertTrue(view.contains("await inventory.refresh()"))
        XCTAssertTrue(view.contains("state.hasRefreshError"))
        XCTAssertTrue(view.contains("state.requiresReconnect"))
        XCTAssertTrue(view.contains("mobile.containers.session-expired"))
    }

    func test页面采用原生自适应列表并具备源码无障碍门() throws {
        let view = try source("Sources/Features/ReadOnlyServices/Containers/MobileContainersView.swift")
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

    func test页面不展示事件正文用户或容器运行时隐私字段() throws {
        let view = try source("Sources/Features/ReadOnlyServices/Containers/MobileContainersView.swift")
        for forbidden in [
            "event.message", "event.user", "cpuUsage", "memoryBytes", "createdAt",
            "registry", "terminal", "compose", "deleteContainers", "controlContainers"
        ] { XCTAssertFalse(view.localizedCaseInsensitiveContains(forbidden), "不应出现：\(forbidden)") }
    }

    func test页面保留主分区筛选且资源键集合固定() throws {
        let view = try source("Sources/Features/ReadOnlyServices/Containers/MobileContainersView.swift")
        for expected in [
            "Picker(", "MobileContainerFilter.allCases", "inventory.state.visibleContainers",
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
        let expression = try! NSRegularExpression(pattern: #"mobile\.containers\.[a-z0-9.-]+"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return Set(expression.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        })
    }

    static let expectedResourceKeys: Set<String> = [
        "mobile.containers.accessibility.item", "mobile.containers.accessibility.section",
        "mobile.containers.action.retry", "mobile.containers.action.show-all",
        "mobile.containers.detail.select.message", "mobile.containers.detail.select.title",
        "mobile.containers.field.connected-containers", "mobile.containers.field.container-count",
        "mobile.containers.field.driver", "mobile.containers.field.image",
        "mobile.containers.field.level", "mobile.containers.field.size",
        "mobile.containers.field.status", "mobile.containers.field.time",
        "mobile.containers.field.usage", "mobile.containers.filter.all",
        "mobile.containers.filter.attention", "mobile.containers.filter.label",
        "mobile.containers.filter.running", "mobile.containers.filter.stopped",
        "mobile.containers.filtered-empty.message", "mobile.containers.filtered-empty.title",
        "mobile.containers.loading", "mobile.containers.read-only.notice",
        "mobile.containers.refresh.failed", "mobile.containers.section.containers",
        "mobile.containers.session-expired",
        "mobile.containers.section.empty.message", "mobile.containers.section.empty.title",
        "mobile.containers.section.events", "mobile.containers.section.failed.message",
        "mobile.containers.section.failed.title", "mobile.containers.section.images",
        "mobile.containers.section.networks", "mobile.containers.section.projects",
        "mobile.containers.section.state.content", "mobile.containers.section.state.empty",
        "mobile.containers.section.state.failed", "mobile.containers.section.state.unavailable",
        "mobile.containers.section.unavailable.message", "mobile.containers.section.unavailable.title",
        "mobile.containers.status.attention", "mobile.containers.status.running",
        "mobile.containers.status.stopped", "mobile.containers.status.unknown",
        "mobile.containers.value.in-use", "mobile.containers.value.not-in-use",
        "mobile.containers.value.time-unavailable"
    ]
}
