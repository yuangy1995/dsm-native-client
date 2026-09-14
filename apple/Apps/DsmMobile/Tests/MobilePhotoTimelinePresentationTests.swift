import Foundation
import XCTest

final class MobilePhotoTimelinePresentationTests: XCTestCase {
    func test时间线使用原生分段搜索惰性月份和自适应网格() throws {
        let root = Self.repositoryRoot()
        let photos = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/MobilePhotosView.swift")
        for token in ["MobileSynologyPhotosSection.allCases", "TextField(", "submitSearch()", "LazyVStack", "LazyVGrid", "GridItem(.adaptive", "jumpToMonth(month)"] {
            XCTAssertTrue(photos.contains(token), token)
        }
    }

    func test时间线有取消截断部分结果和降低动态效果护栏() throws {
        let root = Self.repositoryRoot()
        let timeline = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/Timeline/MobilePhotoTimelineView.swift")
        let model = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/Timeline/MobilePhotoTimelineModel.swift")

        for token in ["timeline.action.cancel", "timeline.truncated.title", "timeline.partial.title", "accessibilityReduceMotion"] {
            XCTAssertTrue(timeline.contains(token), "Missing presentation guard: \(token)")
        }
        XCTAssertTrue(model.contains("limits: .mobileDefault"))
        XCTAssertTrue(model.contains("generation == requestGeneration"))
        XCTAssertFalse(model.contains("UserDefaults"))
    }

    func test新版Photos时间线使用项目身份预览而不把文件移动当照片整理() throws {
        let root = Self.repositoryRoot()
        let photos = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/MobilePhotosView.swift")
        XCTAssertTrue(photos.contains("library.datedGroups"))
        XCTAssertTrue(photos.contains("library.showPreview(photo)"))
        XCTAssertFalse(photos.contains("beginMove"))
        XCTAssertFalse(photos.contains("copyMoveResult("))
    }

    func test新版Photos时间线保持只读并拒绝FileStation降级() throws {
        let root = Self.repositoryRoot()
        let photos = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/MobilePhotosView.swift")
        let model = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/MobileSynologyPhotosModel.swift")
        XCTAssertFalse(photos.contains("recycleAction"))
        XCTAssertFalse(model.contains("func confirmDeletion"))
        XCTAssertFalse(model.contains("FileStation" + "PhotoRepository("))
        XCTAssertTrue(photos.contains("loadNextPageAutomatically()"))
    }

    private static func repositoryRoot(filePath: String = #filePath) -> String {
        let marker = "/apple/Apps/DsmMobile/Tests/"
        guard let range = filePath.range(of: marker) else { return "" }
        return String(filePath[..<range.lowerBound])
    }
}
