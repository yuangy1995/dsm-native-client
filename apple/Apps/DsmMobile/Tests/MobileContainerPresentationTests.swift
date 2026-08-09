import Foundation
import XCTest
@testable import DsmMobile

final class MobileContainerPresentationTests: XCTestCase {
    func test页面只呈现实例白名单且旧宽管理链生产不可达() throws {
        let view = try viewSource()
        let app = try source("Sources/AppShell/MobileAppModel.swift")
        let workspace = try source("Sources/AppShell/MobileAppModel+Workspace.swift")
        for forbidden in [
            "containerSnapshot", "loadContainerManager", ".images", ".networks", ".projects",
            "event.message", "event.user", "registry", "terminal", "compose", "resourceList",
            "deleteContainers", "controlContainers", "createContainer", "restartContainer",
            "get_process", "containerLog"
        ] {
            XCTAssertFalse(view.localizedCaseInsensitiveContains(forbidden), "页面不应引用：\(forbidden)")
            XCTAssertFalse(app.localizedCaseInsensitiveContains(forbidden), "AppModel 不应引用：\(forbidden)")
            XCTAssertFalse(workspace.localizedCaseInsensitiveContains(forbidden), "Workspace 不应引用：\(forbidden)")
        }
        XCTAssertTrue(app.contains("MobileContainerInventoryModel"))
        XCTAssertTrue(workspace.contains("MobileReadOnlyContainerRepository"))
        XCTAssertTrue(workspace.contains("containerInventoryModel.activate"))
    }

    func test页面覆盖五态刷新保留和明确恢复动作() throws {
        let view = try viewSource()
        let model = try modelSource()
        let workspaceView = try source("Sources/AppShell/MobileWorkspaceView.swift")
        for state in [".loading", ".empty", ".filteredEmpty", ".error", ".content"] {
            XCTAssertTrue(view.contains(state) || model.contains(state), "缺少状态：\(state)")
        }
        XCTAssertTrue(view.contains("state.hasRefreshError"))
        XCTAssertTrue(view.contains("inventory.setFilter(.all)"))
        XCTAssertTrue(view.contains("await inventory.refresh()"))
        XCTAssertTrue(model.contains("preservesContent"))
        XCTAssertTrue(workspaceView.contains("containerInventoryModel.refresh()"))
        XCTAssertTrue(workspaceView.contains("containerInventoryModel.state.isRefreshing"))
        XCTAssertTrue(workspaceView.contains("ProgressView()"))
        XCTAssertTrue(workspaceView.contains("module != .containers"))
    }

    func test页面遵循iPhone与iPad原生交互和无障碍边界() throws {
        let view = try viewSource()
        XCTAssertTrue(view.contains("horizontalSizeClass == .regular"))
        XCTAssertTrue(view.contains("NavigationLink"))
        XCTAssertTrue(view.contains("inventory.select(item.id)"))
        XCTAssertTrue(view.contains(".listStyle(.insetGrouped)"))
        XCTAssertTrue(view.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(view.contains(".refreshable"))
        XCTAssertTrue(view.contains("minHeight: 44"))
        XCTAssertTrue(view.contains(".accessibilityElement"))
        XCTAssertTrue(view.contains(".accessibilityAddTraits"))
        XCTAssertTrue(view.contains("fillsAvailableContentArea"))
        XCTAssertEqual(view.components(separatedBy: "Picker(").count - 1, 1)
        XCTAssertFalse(view.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(view.contains("ScrollView(.horizontal"))
        XCTAssertFalse(view.contains("withAnimation"))
        XCTAssertFalse(view.contains("font(.system(size:"))
    }

    func test页面只显示名称状态与可选映像() throws {
        let view = try viewSource()
        for allowed in ["item.name", "item.status", "item.image"] {
            XCTAssertTrue(view.contains(allowed))
        }
        for forbidden in [
            "item.project", "item.cpu", "item.memory", "item.port", "item.network",
            "item.environment", "item.mount", "item.process", "item.log"
        ] {
            XCTAssertFalse(view.localizedCaseInsensitiveContains(forbidden), "页面不应展示：\(forbidden)")
        }
    }

    func testAppShell和Session覆盖容器绑定的完整生命周期() throws {
        let app = try source("Sources/AppShell/MobileAppModel.swift")
        let workspace = try source("Sources/AppShell/MobileAppModel+Workspace.swift")
        let session = try source("Sources/Session/MobileAppModel+Session.swift")
        let workspaceView = try source("Sources/AppShell/MobileWorkspaceView.swift")
        XCTAssertTrue(app.contains("containerInventoryModel.deactivate()"))
        XCTAssertTrue(workspace.contains("containerInventoryModel.deactivate()"))
        XCTAssertTrue(session.contains("containerInventoryModel.deactivate()"))
        XCTAssertTrue(session.contains("containerInventoryModel.purge(profileID: profile.id)"))
        XCTAssertTrue(session.contains("containerInventoryModel.purge(profileID: profileID)"))
        XCTAssertTrue(workspaceView.contains("MobileContainersView(inventory:"))
    }

    func test页面只引用冻结的26个容器资源键() throws {
        let view = try viewSource()
        let expression = try NSRegularExpression(pattern: #"mobile\.containers\.[a-z0-9.-]+"#)
        let range = NSRange(view.startIndex..<view.endIndex, in: view)
        let actual = Set(expression.matches(in: view, range: range).compactMap {
            Range($0.range, in: view).map { String(view[$0]) }
        })
        XCTAssertEqual(actual, Self.expectedResourceKeys)
        XCTAssertEqual(actual.count, 26)
    }

    private func viewSource() throws -> String {
        try source("Sources/Features/ReadOnlyServices/Containers/MobileContainersView.swift")
    }

    private func modelSource() throws -> String {
        try source("Sources/Features/ReadOnlyServices/Containers/MobileContainerInventoryModel.swift")
    }

    private func source(_ path: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(path), encoding: .utf8)
    }

    static let expectedResourceKeys: Set<String> = [
        "mobile.containers.accessibility.row",
        "mobile.containers.action.retry",
        "mobile.containers.action.show-all",
        "mobile.containers.detail.select.message",
        "mobile.containers.detail.select.title",
        "mobile.containers.empty.message",
        "mobile.containers.empty.title",
        "mobile.containers.error.message",
        "mobile.containers.error.title",
        "mobile.containers.field.image",
        "mobile.containers.field.status",
        "mobile.containers.filter.all",
        "mobile.containers.filter.attention",
        "mobile.containers.filter.label",
        "mobile.containers.filter.running",
        "mobile.containers.filter.stopped",
        "mobile.containers.filtered-empty.message",
        "mobile.containers.filtered-empty.title",
        "mobile.containers.loading",
        "mobile.containers.read-only.notice",
        "mobile.containers.refresh.failed",
        "mobile.containers.status.attention",
        "mobile.containers.status.running",
        "mobile.containers.status.stopped",
        "mobile.containers.status.unknown",
        "mobile.containers.value.image-unavailable",
    ]
}
