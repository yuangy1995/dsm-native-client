@testable import DsmMobile
import Foundation
import XCTest

/// 新 Photos 替换 File Station 路由后保留展示、安全与可访问性契约；实际状态另有合成服务回归。
final class MobilePhotosPresentationTests: XCTestCase {
    func test紧凑和常规布局按窗口宽度切换且月份导航可触控() throws {
        let view = try source("MobilePhotosView.swift")
        for token in ["@Environment(\\.horizontalSizeClass)", "regularLayout", "compactLayout", "monthSidebar", "photos.timeline.navigator"] {
            XCTAssertTrue(view.contains(token), token)
        }
        XCTAssertFalse(view.contains("UIDevice.current"))
    }
    func test五态保留真实错误权限恢复和全库筛选清除() throws {
        let view = try source("MobilePhotosView.swift")
        for token in ["library.isLoading && !hasContent", "library.errorMessage, !hasContent", "library.spaces.isEmpty",
                      "library.hasLoaded && !hasContent", "library.isFiltering", "ContentUnavailableView", "resetSearchAndFilters()", "await library.refresh()"] {
            XCTAssertTrue(view.contains(token), token)
        }
        XCTAssertFalse(view.contains("FileStation" + "PhotoRepository("))
    }
    func test实际网格惰性分页月份跳转和失败重试不扫描文件夹() throws {
        let view = try source("MobilePhotosView.swift")
        for token in ["LazyVGrid", "LazyVStack", "GridItem(.adaptive", "dynamicTypeSize.isAccessibilitySize",
                      ".task(id: library.paginationIdentity)", "loadNextPageAutomatically()", "loadPreviousPage()", "jumpToMonth(month)"] {
            XCTAssertTrue(view.contains(token), token)
        }
        for token in ["scanTimeline", "rootPath", "fileItem", "browseMode"] { XCTAssertFalse(view.contains(token), token) }
    }
    func test缩略图有界后台解码按完整身份取消并尊重降低动态效果() throws {
        let cell = try source("MobileSynologyPhotoCell.swift")
        let model = try source("MobileSynologyPhotosModel.swift")
        for token in ["library.thumbnail(for: photo)", ".task(id: identity)", "Task.detached", "CGImageSourceCreateThumbnailAtIndex",
                      "kCGImageSourceThumbnailMaxPixelSize", "8 * 1_024 * 1_024", "accessibilityReduceMotion", "withTaskCancellationHandler"] {
            XCTAssertTrue(cell.contains(token), token)
        }
        for token in ["photo.id.profileID", "photo.id.space.rawValue", "photo.id.unitID", "photo.thumbnail?.revision", "MobilePhotoThumbnailStore()"] {
            XCTAssertTrue(model.contains(token), token)
        }
        XCTAssertFalse(cell.contains("Data(contentsOf:"))
    }
    func test预览使用原生安全媒体源与系统分享而不是文件路径或外部播放器() throws {
        let view = try source("MobilePhotosView.swift")
        let preview = try source("MobileSynologyPhotoPreview.swift")
        XCTAssertTrue(view.contains(".fullScreenCover("))
        for token in ["MobileMediaPlayer", "MobileShareSheet", ".inspector(", "MobileSynologyZoomImage", "library.clearExport()",
                      ".keyboardShortcut(.leftArrow", ".keyboardShortcut(.rightArrow"] {
            XCTAssertTrue(preview.contains(token), token)
        }
        for token in ["fileItem", "UIApplication.shared.open", "WebView", "_sid"] { XCTAssertFalse(preview.contains(token), token) }
    }
    func test移动图库不向未验证远端写提供入口() throws {
        let combined = try source("MobilePhotosView.swift") + source("MobileSynologyPhotoPreview.swift") + source("MobileSynologyPhotosModel.swift")
        for token in ["func confirmDeletion", "func requestDeletion", "beginMoveToRecycle", "FileStationPhotoRepository", "repository.upload(", "MobileFileCopyMoveView"] {
            XCTAssertFalse(combined.contains(token), token)
        }
        XCTAssertTrue(combined.contains("photos.readOnly.message"))
        XCTAssertTrue(combined.contains("downloadOriginal"))
    }
    func test全部十二类筛选使用实际候选和本地化标签() throws {
        let view = try source("MobileSynologyPhotoFilters.swift")
        for key in ["photos.filters.type", "photos.category.person", "photos.category.location", "photos.category.tags", "photos.detail.rating",
                    "photos.filters.date", "photos.detail.camera", "photos.detail.lens", "photos.detail.focal", "photos.detail.shutter",
                    "photos.detail.aperture", "photos.detail.iso"] { XCTAssertTrue(view.contains(key), key) }
        XCTAssertTrue(view.contains("library.applyFilter(filter)"))
        XCTAssertTrue(view.contains("library.loadFilterOptions()"))
        XCTAssertTrue(view.contains("Calendar(identifier: .gregorian)"))
    }
    func test导出暂存文件有独立身份取消清理且迟到进度不得污染新任务() throws {
        let model = try source("MobileSynologyPhotosModel.swift")
        for token in ["exportGeneration += 1", "current == self.exportGeneration", "readyForSharing", "removeItem(at: directory)",
                      "lastPathComponent", "component == \"..\"", "saveTask?.cancel()", "exportURL = nil"] {
            XCTAssertTrue(model.contains(token), token)
        }
    }
    func test登录重连测试组合根和离开页面都接入新Photos模型() throws {
        let shell = try appSource("Sources/Session/MobileAppModel+Session.swift")
        let workspace = try appSource("Sources/AppShell/MobileAppModel+Workspace.swift")
        XCTAssertTrue(shell.contains("photos: SynologyPhotosRepository"))
        XCTAssertTrue(shell.contains("repository: repositories.photos"))
        XCTAssertTrue(shell.contains("deletionEnabled: false"))
        XCTAssertTrue(workspace.contains("await synologyPhotosModel.refresh()"))
        XCTAssertTrue(workspace.contains("synologyPhotosModel.setModuleEnabled(false)"))
    }
    func test玻璃支持新SDK和旧系统且高对比降低透明度优先() throws {
        let glass = try appSource("Sources/CommonUI/MobileGlassSurface.swift")
        for token in ["#if compiler(>=6.2)", "#available(iOS 26.0, *)", ".glassEffect(.regular", ".ultraThinMaterial",
                      "accessibilityReduceTransparency", "contrast == .increased"] { XCTAssertTrue(glass.contains(token), token) }
        XCTAssertFalse(glass.contains(".blur("))
    }
    func test触控目标动态文字与系统表单不依赖桌面手势() throws {
        let view = try source("MobilePhotosView.swift") + source("MobileSynologyPhotoPreview.swift") + source("MobileSynologyPhotoFilters.swift")
        for token in ["minHeight: 44", "frame(width: 44, height: 44)", ".accessibilityLabel", "Picker(", "Form {"] {
            XCTAssertTrue(view.contains(token), token)
        }
        for token in ["onHover", "rightClick", "doubleClick"] { XCTAssertFalse(view.contains(token), token) }
    }
    private func source(_ file: String) throws -> String { try appSource("Sources/Features/Photos/" + file) }
    private func appSource(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
