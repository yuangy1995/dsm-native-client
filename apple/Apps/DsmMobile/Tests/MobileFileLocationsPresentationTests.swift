@testable import DsmMobile
import Foundation
import XCTest

final class MobileFileLocationsPresentationTests: XCTestCase {
    func test文件页面使用原生位置Sheet且不嵌套SplitView() throws {
        let browser = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        let locations = try sourceFile("Sources/Features/Files/Locations/MobileFileLocationsView.swift")
        XCTAssertTrue(browser.contains(".sheet(isPresented: $showsLocations)"))
        XCTAssertTrue(browser.contains("MobileFileLocationsView("))
        XCTAssertTrue(locations.contains("NavigationStack"))
        XCTAssertTrue(locations.contains("List {"))
        XCTAssertFalse(locations.contains("NavigationSplitView"))
    }

    func test位置入口与行满足四十四点并提供VoiceOver文案() throws {
        let browser = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        let locations = try sourceFile("Sources/Features/Files/Locations/MobileFileLocationsView.swift")
        XCTAssertTrue(browser.contains("mobile.files.locations.open"))
        XCTAssertTrue(browser.contains(".frame(width: 44, height: 44)"))
        XCTAssertTrue(locations.contains(".frame(minHeight: 44)"))
        XCTAssertTrue(locations.contains("mobile.files.locations.item-format"))
        XCTAssertTrue(locations.contains(".accessibilityValue(path)"))
        XCTAssertTrue(locations.contains("mobile.files.locations.open-hint"))
        XCTAssertTrue(locations.contains("mobile.files.locations.remote.read-only-hint"))
    }

    func test切换位置前关闭预览与分享动作且复用原浏览器() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(source.contains("prepareForLocationChange()"))
        XCTAssertTrue(source.contains("preview.close()"))
        XCTAssertTrue(source.contains("fileShareLinkModel.dismiss()"))
        XCTAssertTrue(source.contains("browser.openLocation("))
    }

    func test位置打开失败保留Sheet并显示通俗本地化反馈() throws {
        let source = try sourceFile("Sources/Features/Files/Locations/MobileFileLocationsView.swift")
        XCTAssertTrue(source.contains("if opened {"))
        XCTAssertTrue(source.contains("showsOpenError = true"))
        XCTAssertTrue(source.contains("mobile.files.locations.open-error.title"))
        XCTAssertTrue(source.contains("mobile.files.locations.open-error.message"))
    }

    func test远程与回收站隐藏写入口并在Handler再次校验只读来源() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        XCTAssertTrue(source.contains("if !state.location.source.isReadOnlyLocation"))
        XCTAssertTrue(source.contains("beginShareLink(for: item)"))
        XCTAssertTrue(source.contains("guard !state.location.source.isReadOnlyLocation"))
        XCTAssertTrue(source.contains("model.fileRepository == nil || state.location.source.isReadOnlyLocation"))
        XCTAssertTrue(source.contains("mobile.documents.save-copy"))
        XCTAssertTrue(source.contains("mobile.documents.share"))
    }

    func test关闭位置Sheet取消独立事务导航并避免迟到状态更新() throws {
        let browser = try sourceFile("Sources/Features/Files/MobileFileBrowser.swift")
        let locations = try sourceFile("Sources/Features/Files/Locations/MobileFileLocationsView.swift")
        let browserModel = try sourceFile("Sources/Features/Files/MobileFileBrowserModel.swift")
        XCTAssertTrue(browser.contains("cancelOpenLocation: browser.cancelLocationRequest"))
        XCTAssertTrue(locations.contains("openTask?.cancel()"))
        XCTAssertTrue(locations.contains("cancelOpenLocation()"))
        XCTAssertTrue(locations.contains("guard !Task.isCancelled else { return }"))
        XCTAssertTrue(browserModel.contains("func cancelLocationRequest()"))
        XCTAssertTrue(browserModel.contains("locationRequestTask?.cancel()"))
    }

    func test位置界面表达五态以及PartialTruncated和刷新错误() throws {
        let source = try sourceFile("Sources/Features/Files/Locations/MobileFileLocationsView.swift")
        for state in ["case .loading", "case .empty", "case .filteredEmpty", "case .error", "case .content"] {
            XCTAssertTrue(source.contains(state), state)
        }
        for key in [
            "mobile.files.locations.favorites.truncated",
            "mobile.files.locations.favorites.refresh-error",
            "mobile.files.locations.remote.partial",
            "mobile.files.locations.remote.truncated",
            "mobile.files.locations.remote.refresh-error",
            "mobile.files.locations.recycle.partial",
            "mobile.files.locations.recycle.truncated",
            "mobile.files.locations.recycle.refresh-error"
        ] {
            XCTAssertTrue(source.contains(key), key)
        }
    }

    func test不包含回收站恢复收藏写或远程挂载管理入口() throws {
        let locations = try sourceFile("Sources/Features/Files/Locations/MobileFileLocationsView.swift")
        for forbidden in [
            "restoreRecycle",
            "addFavorite",
            "removeFavorite",
            "createRemoteMount",
            "updateRemoteMount",
            "removeRemoteMount",
            "#recycle"
        ] {
            XCTAssertFalse(locations.contains(forbidden), forbidden)
        }
    }

    func test组合根在Profile和会话生命周期关闭位置Repository绑定并清理缓存() throws {
        let appModel = try sourceFile("Sources/AppShell/MobileAppModel.swift")
        let workspace = try sourceFile("Sources/AppShell/MobileAppModel+Workspace.swift")
        let session = try sourceFile("Sources/Session/MobileAppModel+Session.swift")

        XCTAssertTrue(appModel.contains("deactivateFileLocations()"))
        XCTAssertTrue(workspace.contains("deactivateFileLocations()"))
        XCTAssertTrue(session.contains("deactivateFileLocations()"))
        XCTAssertGreaterThanOrEqual(
            session.components(separatedBy: "purgeFileLocations(profileID:").count - 1,
            2
        )
        XCTAssertTrue(session.contains("purgeFileLocations(profileID: profile.id)"))
        XCTAssertTrue(session.contains("purgeFileLocations(profileID: profileID)"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
