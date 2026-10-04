@testable import DsmMobile
import Foundation
import XCTest

final class MobilePhotoTimelinePresentationTests: XCTestCase {
    func test时间线按套件日期索引分组且仍有手动分页入口() throws {
        let source = try photos()
        for token in ["model.datedGroups", "model.formattedPhotoDate", "photos.library.more", "model.hasPrevious", "model.hasMore"] {
            XCTAssertTrue(source.contains(token), token)
        }
        XCTAssertFalse(source.contains("scanTimeline"))
    }

    func test月份定位可滚动且清除筛选提供恢复入口() throws {
        let source = try photos()
        for token in ["ScrollViewReader", "model.selectedTimelineMonthID", "proxy.scrollTo", "photos.filters.clear", "model.applyFilter"] {
            XCTAssertTrue(source.contains(token), token)
        }
    }

    func test按日期选择复用正式原件删除完整选择() throws {
        let source = try photos()
        XCTAssertTrue(source.contains("model.selectGroup(group.photos)"))
        XCTAssertTrue(source.contains("model.requestDeletion(model.selectedPhotos)"))
        XCTAssertTrue(source.contains("model.canDeleteSelection"))
        XCTAssertTrue(source.contains("role: .destructive"))
    }

    func test时间线与目录都使用同一照片网格和导出入口() throws {
        let source = try photos()
        XCTAssertTrue(source.contains("photoGrid(group.photos)"))
        XCTAssertTrue(source.contains("photoGrid(model.items)"))
        XCTAssertTrue(source.contains("MobilePhotoExportActions"))
        XCTAssertFalse(source.contains("PhotoBrowseMode"))
        XCTAssertFalse(source.contains("FileStationPhotoRepository"))
    }

    private func photos() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/Features/Photos/MobileSynologyPhotosView.swift"), encoding: .utf8)
    }
}
