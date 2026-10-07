@testable import DsmMobile
import Foundation
import XCTest

final class MobilePhotosPresentationTests: XCTestCase {
    func test照片正式页面按可用宽度选择布局而不依赖设备名称() throws {
        let source = try sourceFile("MobileSynologyPhotosView.swift")
        XCTAssertTrue(source.contains("@Environment(\\.horizontalSizeClass)"))
        XCTAssertTrue(source.contains("if sizeClass == .regular"))
        XCTAssertTrue(source.contains(".pickerStyle(.segmented)"))
        XCTAssertFalse(source.contains("UIDevice.current"))
    }

    func test正式照片覆盖加载错误空图库筛选为空与内容() throws {
        let source = try sourceFile("MobileSynologyPhotosView.swift")
        for token in ["model.isLoading", "model.errorMessage", "model.items.isEmpty", "model.isFiltering",
                      "photoGrid(model.items)", "photos.library.noResults", "photos.filters.clear", "await model.refresh()"] {
            XCTAssertTrue(source.contains(token), token)
        }
    }

    func test网格保持有界图片和前后分页失败恢复() throws {
        let source = try sourceFile("MobileSynologyPhotosView.swift")
        for token in ["LazyVGrid", "GridItem(.adaptive", "model.previousPageErrorMessage", "loadPreviousPage", "loadNextPageAutomatically",
                      "maximumPixels: 512", "data.count <= 8 * 1_024 * 1_024", "CGImageSourceCreateThumbnailAtIndex"] {
            XCTAssertTrue(source.contains(token), token)
        }
    }

    func test异步图片解码取消后不回填且离开清除可见项() throws {
        let source = try sourceFile("MobileSynologyPhotosView.swift")
        for token in ["await session.thumbnail(photo)", "guard !Task.isCancelled", "Task.detached(priority: .userInitiated)",
                      "ThumbnailIdentity(thumbnail:", "image = nil", "visible: false"] {
            XCTAssertTrue(source.contains(token), token)
        }
    }

    func test系统全屏预览与后台传输保留会话而主动离开停用() throws {
        let source = try sourceFile("MobileSynologyPhotosView.swift")
        // M8 已开始的传输需跨后台保留；主动离开仍停用，行为由上传/导出生命周期测试覆盖。
        XCTAssertTrue(source.contains("if model.previewPhoto == nil, scenePhase == .active { session.deactivate() }"))
        XCTAssertTrue(source.contains("if phase == .background { session.enterBackground() }"))
        XCTAssertFalse(source.contains("if phase == .background { session.deactivate() }"))
        XCTAssertTrue(source.contains("await session.activate()"))
        XCTAssertTrue(source.contains("model.closePreview()"))
    }

    func test移动与删除沿Photos身份和权限而不转换为FileStation路径() throws {
        let source = try sourceFile("MobileSynologyPhotosView.swift") + sourceFile("MobileSynologyPhotoPreview.swift")
        for token in ["MobilePhotoFolderActions", "model.requestDeletion", "model.canDeletePhotos", "role: .destructive"] {
            XCTAssertTrue(source.contains(token), token)
        }
        for forbidden in ["FileStationPhotoRepository", "PhotoLibraryItem", "moveToRecycleResult(", "copyMoveResult("] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
    }

    func test触控和VoiceOver保留原生按钮语义与照片名称() throws {
        let source = try sourceFile("MobileSynologyPhotosView.swift")
        for token in ["Button {", "minWidth: 44, minHeight: 44", ".accessibilityLabel(photo.filename)",
                      ".accessibilityHint(", ".accessibilityAddTraits(isSelected", ".accessibilityHidden(true)"] {
            XCTAssertTrue(source.contains(token), token)
        }
        XCTAssertFalse(source.contains("onHover"))
        XCTAssertFalse(source.contains("doubleClick"))
    }

    func test只有实际多来源时才呈现来源切换() throws {
        let source = try sourceFile("MobileSynologyPhotosView.swift")
        XCTAssertTrue(source.contains("model.spaces.count > 1"))
        XCTAssertTrue(source.contains("mobile.photos.source.mine"))
        XCTAssertTrue(source.contains("mobile.photos.source.shared"))
        XCTAssertFalse(source.contains("mobile.photos.space"))
    }

    func test已移除旧路径图库且Shell只装配正式会话() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let shell = try String(contentsOf: root.appendingPathComponent("Sources/AppShell/MobileAppModel.swift"), encoding: .utf8)
        XCTAssertTrue(shell.contains("MobileSynologyPhotosSession(backgroundExecution: transferBackgroundExecution)"))
        XCTAssertFalse(shell.contains("MobilePhotoLibraryModel"))
        XCTAssertFalse(shell.contains("FileStationPhotoRepository"))
        for file in ["MobilePhotosView.swift", "MobilePhotoLibraryModel.swift", "MobilePhotoGrid.swift", "MobilePhotoCell.swift",
                     "Timeline/MobilePhotoTimelineModel.swift", "Viewer/MobilePhotoViewerModel.swift"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sources/Features/Photos/" + file).path), file)
        }
    }

    private func sourceFile(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Features/Photos/" + file), encoding: .utf8)
    }
}
