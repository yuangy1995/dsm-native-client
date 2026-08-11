import Foundation
import XCTest

final class MobilePhotoTimelinePresentationTests: XCTestCase {
    func test时间线使用原生分段搜索惰性月份和自适应网格() throws {
        let root = Self.repositoryRoot()
        let photos = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/MobilePhotosView.swift")
        let timeline = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/Timeline/MobilePhotoTimelineView.swift")

        XCTAssertTrue(photos.contains(".pickerStyle(.segmented)"))
        XCTAssertTrue(photos.contains("PhotoBrowseMode.timeline"))
        XCTAssertTrue(timeline.contains(".searchable("))
        XCTAssertTrue(timeline.contains("LazyVStack"))
        XCTAssertTrue(timeline.contains("LazyVGrid"))
        XCTAssertTrue(timeline.contains("GridItem(.adaptive"))
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

    func test时间线照片仅向合格单项开放共享移动入口() throws {
        let root = Self.repositoryRoot()
        let photos = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/MobilePhotosView.swift")
        let timeline = try String(contentsOfFile: root + "/apple/Apps/DsmMobile/Sources/Features/Photos/Timeline/MobilePhotoTimelineView.swift")

        XCTAssertTrue(timeline.contains("onMove: canMove(item)"))
        XCTAssertTrue(timeline.contains("!item.fileItem.isRecyclePath"))
        XCTAssertTrue(timeline.contains("item.sizeBytes.map { $0 >= 0 } == true"))
        XCTAssertTrue(timeline.contains("mobile.files.copy-move.move.action"))
        XCTAssertTrue(photos.contains("if browseMode == .timeline"))
        XCTAssertTrue(photos.contains("await timeline.refresh()"))
        XCTAssertFalse(timeline.contains("copyMoveResult("))
    }

    private static func repositoryRoot(filePath: String = #filePath) -> String {
        let marker = "/apple/Apps/DsmMobile/Tests/"
        guard let range = filePath.range(of: marker) else { return "" }
        return String(filePath[..<range.lowerBound])
    }
}
