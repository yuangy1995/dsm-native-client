import Foundation
import XCTest

final class MobileFileShareLinkIntegrationTests: XCTestCase {
    func testFiles文件和文件夹共用单项菜单入口且复用系统分享() throws {
        let source = try Self.mobileSource("Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(source.contains("model.fileShareLinkModel.begin(for: item)"))
        XCTAssertTrue(source.contains("MobileFileShareLinkView"))
        XCTAssertTrue(source.contains("model.fileShareLinkModel.activate"))
        XCTAssertTrue(source.contains("model.fileShareLinkModel.deactivate"))
        XCTAssertFalse(source.contains("deleteShareLinks"))
    }

    func testProfile切换离开Files与退出均释放分享链接状态() throws {
        let appModel = try Self.mobileSource("AppShell/MobileAppModel.swift")
        let workspace = try Self.mobileSource("AppShell/MobileAppModel+Workspace.swift")
        let session = try Self.mobileSource("Session/MobileAppModel+Session.swift")

        XCTAssertTrue(appModel.contains("fileShareLinkModel.deactivate()"))
        XCTAssertTrue(workspace.contains("selectedModule == .files, module != .files"))
        XCTAssertTrue(workspace.contains("fileShareLinkModel.deactivate()"))
        XCTAssertTrue(session.contains("clearWorkspace()"))
        XCTAssertTrue(session.contains("fileShareLinkModel.deactivate()"))
    }

    func test剪贴板仅本设备并设置短期过期() throws {
        let source = try Self.mobileSource("Platform/Sharing/MobileClipboard.swift")
        XCTAssertTrue(source.contains(".localOnly: true"))
        XCTAssertTrue(source.contains(".expirationDate:"))
        XCTAssertTrue(source.contains("UTType.url.identifier"))
    }

    private static func mobileSource(_ path: String) throws -> String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: tests.deletingLastPathComponent()
                .appendingPathComponent("Sources")
                .appendingPathComponent(path),
            encoding: .utf8
        )
    }
}
