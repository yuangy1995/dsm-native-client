import Foundation
import XCTest
@testable import DsmMobile

final class MobileNasHealthPresentationTests: XCTestCase {
    func test展示格式使用区域化系统格式且空白值不进入界面() {
        XCTAssertNil(MobileNasHealthFormatting.nonempty(nil))
        XCTAssertNil(MobileNasHealthFormatting.nonempty("  \n"))
        XCTAssertEqual(MobileNasHealthFormatting.nonempty("  DSM  "), "DSM")
        XCTAssertNotNil(MobileNasHealthFormatting.bytes(1_024))
        XCTAssertNotNil(MobileNasHealthFormatting.temperature(32))
        XCTAssertNotNil(MobileNasHealthFormatting.duration(90_000))
        XCTAssertFalse(MobileNasHealthFormatting.percent(42).isEmpty)
        XCTAssertFalse(MobileNasHealthFormatting.rate(1_024).isEmpty)
    }

    func test页面不再引用旧管理数据或敏感字段() throws {
        let source = try viewSource()
        for forbidden in [
            "accountsAndGroups", "model.logs", "model.connections", "model.packages",
            "NasAccount", "connection.source", "serialNumber", "deviceID",
            "firmwareVersion", ".path", "poolID", "diskIDs", "realOwner",
            "saveScheduledTask", "controlPackage", "performPowerAction", "startDiskTest"
        ] {
            XCTAssertFalse(source.contains(forbidden), "健康页不应引用：\(forbidden)")
        }
    }

    func test页面覆盖四分区独立五态和分区内恢复动作() throws {
        let source = try viewSource()
        for state in [".idle", ".loading", ".empty", ".error", ".content"] {
            XCTAssertTrue(source.contains(state), "缺少状态分支：\(state)")
        }
        XCTAssertTrue(source.contains("section.hasRefreshError"))
        XCTAssertTrue(source.contains("MobileNasHealthRecoveryView"))
        XCTAssertTrue(source.contains("await model.nasHealthModel.refresh()"))
    }

    func test页面遵循iPhone和iPad原生自适应与无障碍边界() throws {
        let source = try viewSource()
        XCTAssertTrue(source.contains("horizontalSizeClass == .regular"))
        XCTAssertTrue(source.contains(".listStyle(.insetGrouped)"))
        XCTAssertTrue(source.contains(".listStyle(.sidebar)"))
        XCTAssertTrue(source.contains(".refreshable"))
        XCTAssertTrue(source.contains("minHeight: 44"))
        XCTAssertTrue(source.contains(".accessibilityElement"))
        XCTAssertTrue(source.contains(".accessibilityAddTraits"))
        XCTAssertFalse(source.contains(".animation("))
        XCTAssertFalse(source.contains("withAnimation"))
        XCTAssertFalse(source.contains("font(.system(size:"))
    }

    func test页面只引用已声明的NasHealth资源键() throws {
        let source = try viewSource()
        let expression = try NSRegularExpression(pattern: #"mobile\.nas-health\.[a-z0-9.-]+"#)
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        let actual = Set(expression.matches(in: source, range: range).compactMap {
            Range($0.range, in: source).map { String(source[$0]) }
        })

        XCTAssertEqual(actual, Self.expectedResourceKeys)
    }

    func test工作区刷新按钮会直接刷新健康模型而不是重复激活缓存() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: appRoot.appendingPathComponent("Sources/AppShell/MobileWorkspaceView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("if module == .nasSettings"))
        XCTAssertTrue(source.contains("await model.nasHealthModel.refresh()"))
    }

    private func viewSource() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        let viewURL = appRoot
            .appendingPathComponent("Sources/Features/Administration/MobileNasSettingsView.swift")
        return try String(contentsOf: viewURL, encoding: .utf8)
    }

    private static let expectedResourceKeys: Set<String> = [
        "mobile.nas-health.accessibility.transfer-rate",
        "mobile.nas-health.action.retry",
        "mobile.nas-health.error.performance.message",
        "mobile.nas-health.error.performance.title",
        "mobile.nas-health.error.storage.message",
        "mobile.nas-health.error.storage.title",
        "mobile.nas-health.error.system.message",
        "mobile.nas-health.error.system.title",
        "mobile.nas-health.error.update.message",
        "mobile.nas-health.error.update.title",
        "mobile.nas-health.loading.performance",
        "mobile.nas-health.loading.storage",
        "mobile.nas-health.loading.system",
        "mobile.nas-health.loading.update",
        "mobile.nas-health.performance.cpu",
        "mobile.nas-health.performance.disk-utilization",
        "mobile.nas-health.performance.disk.read",
        "mobile.nas-health.performance.disk.write",
        "mobile.nas-health.performance.memory",
        "mobile.nas-health.performance.network.receive",
        "mobile.nas-health.performance.network.send",
        "mobile.nas-health.performance.swap",
        "mobile.nas-health.performance.volume.read",
        "mobile.nas-health.performance.volume.write",
        "mobile.nas-health.read-only.notice",
        "mobile.nas-health.refresh.failed",
        "mobile.nas-health.status.critical",
        "mobile.nas-health.status.healthy",
        "mobile.nas-health.status.unknown",
        "mobile.nas-health.status.warning",
        "mobile.nas-health.storage.bad-sectors",
        "mobile.nas-health.storage.capacity",
        "mobile.nas-health.storage.drive-type",
        "mobile.nas-health.storage.drives",
        "mobile.nas-health.storage.empty.message",
        "mobile.nas-health.storage.empty.title",
        "mobile.nas-health.storage.encrypted",
        "mobile.nas-health.storage.file-system",
        "mobile.nas-health.storage.overall",
        "mobile.nas-health.storage.pools",
        "mobile.nas-health.storage.raid-type",
        "mobile.nas-health.storage.scrubbing",
        "mobile.nas-health.storage.smart-health",
        "mobile.nas-health.storage.ssd-life",
        "mobile.nas-health.storage.used",
        "mobile.nas-health.storage.volumes",
        "mobile.nas-health.system.memory",
        "mobile.nas-health.system.model",
        "mobile.nas-health.system.name",
        "mobile.nas-health.system.processor",
        "mobile.nas-health.system.temperature",
        "mobile.nas-health.system.uptime",
        "mobile.nas-health.system.version",
        "mobile.nas-health.update.available",
        "mobile.nas-health.update.browser-notice",
        "mobile.nas-health.update.current-version",
        "mobile.nas-health.update.latest-version",
        "mobile.nas-health.update.release-notes",
        "mobile.nas-health.update.up-to-date",
        "mobile.nas-health.updated-at"
    ]
}
