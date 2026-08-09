@testable import DsmMobile
import Foundation
import XCTest

final class MobileDownloadsSafetyTests: XCTestCase {
    func test下载页面和模型没有可达写入口() throws {
        let view = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadsView.swift"
        )
        let model = try sourceFile(
            "Sources/Features/Services/Downloads/MobileAppModel+Downloads.swift"
        )

        for forbidden in [
            "MobileDownloadSheet", "TextField(", "confirmationDialog(",
            "createDownloadTask", "controlDownloadTasks", "deleteDownloadTasks",
            "func createDownload", "func controlDownload", "action: .pause",
            "action: .resume", "isCreating"
        ] {
            XCTAssertFalse(view.contains(forbidden), "View: \(forbidden)")
            XCTAssertFalse(model.contains(forbidden), "Model: \(forbidden)")
        }
    }

    func test下载页面保留四态只读列表和详情选择() throws {
        let view = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadsView.swift"
        )
        let model = try sourceFile(
            "Sources/Features/Services/Downloads/MobileAppModel+Downloads.swift"
        )

        XCTAssertTrue(view.contains("MobilePageStateView("))
        XCTAssertTrue(view.contains("state: model.downloadPageState"))
        XCTAssertTrue(view.contains("List {"))
        XCTAssertTrue(view.contains(".sheet(item: $selectedTask)"))
        XCTAssertTrue(view.contains("MobileDownloadTaskDetailView"))
        XCTAssertTrue(model.contains("return .loading"))
        XCTAssertTrue(model.contains("return message == nil ? .loading : .error"))
        XCTAssertTrue(model.contains("return downloadSnapshot.tasks.isEmpty ? .empty : .content"))
    }

    func test只读说明触控和VoiceOver语义保持稳定() throws {
        let view = try sourceFile(
            "Sources/Features/Services/Downloads/MobileDownloadsView.swift"
        )

        XCTAssertTrue(view.contains("mobile.downloads.read-only.notice"))
        XCTAssertTrue(view.contains("MobileMetrics.minimumTouchTarget"))
        XCTAssertTrue(view.contains(".accessibilityHint("))
        XCTAssertTrue(view.contains(".accessibilityLabel("))
        XCTAssertTrue(view.contains(".accessibilityValue("))
        XCTAssertTrue(view.contains(".accessibilityHidden(true)"))
        XCTAssertFalse(view.contains(".font(.system(size:"))
        XCTAssertFalse(view.contains("withAnimation"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(
            contentsOf: appRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
