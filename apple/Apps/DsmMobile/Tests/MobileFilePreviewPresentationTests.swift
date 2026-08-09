@testable import DsmMobile
import Foundation
import XCTest

final class MobileFilePreviewPresentationTests: XCTestCase {
    func test预览组件覆盖完整状态并提供明确恢复动作() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFilePreviewView.swift")
        for phase in [
            "case .inactive:",
            "case .loadingDetails:",
            "case .loadingPreview:",
            "case .detailsOnly:",
            "case .ready:",
            "case .failed:",
            "case .cancelled:"
        ] {
            XCTAssertTrue(source.contains(phase), phase)
        }
        for callback in [
            "onCancel",
            "onRetry",
            "onClose",
            "onShowDetails",
            "onOpenFullScreen",
            "onQuickLookDismiss"
        ] {
            XCTAssertTrue(source.contains(callback), callback)
        }
    }

    func testReady状态使用本地QuickLook且保留原始文件名() throws {
        let preview = try sourceFile("Sources/Features/Files/MobileFilePreviewView.swift")
        let quickLook = try sourceFile("Sources/Platform/Preview/MobileQuickLookPreview.swift")

        XCTAssertTrue(preview.contains("MobileQuickLookPreview("))
        XCTAssertTrue(preview.contains("localURL: url"))
        XCTAssertTrue(preview.contains("title: item.name"))
        XCTAssertTrue(quickLook.contains("QLPreviewController"))
        XCTAssertTrue(quickLook.contains("previewItemURL = localURL"))
        XCTAssertTrue(quickLook.contains("previewItemTitle = title"))
        XCTAssertFalse(quickLook.contains("removeItem"))
        XCTAssertFalse(quickLook.contains("Data(contentsOf:"))
        XCTAssertFalse(quickLook.contains("AVPlayer"))
    }

    func test文本与媒体使用移动端原生只读呈现且不落整文件() throws {
        let preview = try sourceFile("Sources/Features/Files/MobileFilePreviewView.swift")
        let media = try sourceFile("Sources/Platform/Preview/MobileMediaPlayer.swift")
        let reader = try sourceFile("Sources/Platform/Preview/MobileSecureRangeReader.swift")

        XCTAssertTrue(preview.contains("case .text(let text):"))
        XCTAssertTrue(preview.contains(".textSelection(.enabled)"))
        XCTAssertTrue(preview.contains("MobileMediaPlayer(source: mediaSource"))
        XCTAssertTrue(media.contains("VideoPlayer(player: player)"))
        XCTAssertTrue(media.contains("static let maximumRangeLength = 4 * 1_024 * 1_024"))
        XCTAssertTrue(reader.contains("response.statusCode == 206"))
        XCTAssertTrue(reader.contains("range.total == expectedTotal"))
        XCTAssertTrue(reader.contains("request.setValue(ifMatch, forHTTPHeaderField: \"If-Match\")"))
        XCTAssertTrue(reader.contains("let responseETag = Self.strongETag"))
        XCTAssertFalse(try sourceFile("Sources/Features/Files/MobileFilePreviewModel.swift").contains("service.download("))
        XCTAssertFalse(media.contains("Data(contentsOf:"))
        XCTAssertFalse(media.contains("temporaryDirectory"))
    }

    func test详情使用原生分组并按App语言格式化日期和大小() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFileDetailsView.swift")
        XCTAssertTrue(source.contains("List {"))
        XCTAssertTrue(source.contains("Section(L10n.string(\"mobile.files.details.section.general\")"))
        XCTAssertTrue(source.contains("Section(L10n.string(\"mobile.files.details.section.dates\")"))
        XCTAssertTrue(source.contains("Section(L10n.string(\"mobile.files.details.section.ownership\")"))
        XCTAssertTrue(source.contains("Section(L10n.string(\"mobile.files.details.section.permissions\")"))
        XCTAssertTrue(source.contains(".locale(L10n.locale)"))
        XCTAssertTrue(source.contains("ByteCountFormatStyle(style: .file)"))
        XCTAssertTrue(source.contains("DateFormatter()"))
        XCTAssertFalse(source.contains("posixMode"))
        XCTAssertFalse(source.contains("rawType"))
    }

    func test触控动态文字辅助功能和降低动态效果有明确实现() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFilePreviewView.swift")
        XCTAssertTrue(source.contains("minHeight: 44"))
        XCTAssertTrue(source.contains(".accessibilityLabel(title)"))
        XCTAssertTrue(source.contains("@Environment(\\.dynamicTypeSize)"))
        XCTAssertTrue(source.contains("dynamicTypeSize.isAccessibilitySize"))
        XCTAssertTrue(source.contains("@Environment(\\.accessibilityReduceMotion)"))
        XCTAssertTrue(source.contains("reduceMotion ? nil"))
    }

    func test加载态标题只朗读一次且进度文字保留语义() throws {
        let source = try sourceFile("Sources/Features/Files/MobileFilePreviewView.swift")
        XCTAssertTrue(
            source.contains(
                "ProgressView()\n                .controlSize(.large)\n                .accessibilityHidden(true)"
            )
        )
        XCTAssertTrue(source.contains("if showsProgress, let progressText"))
        XCTAssertTrue(source.contains("Text(progressText)"))
    }

    func testQuickLook只在URL或标题变化时重新加载() {
        let firstURL = URL(fileURLWithPath: "/synthetic/first.pdf")
        let secondURL = URL(fileURLWithPath: "/synthetic/second.pdf")

        XCTAssertFalse(
            MobileQuickLookPreview.Coordinator.requiresReload(
                currentURL: firstURL,
                currentTitle: "First",
                nextURL: firstURL,
                nextTitle: "First"
            )
        )
        XCTAssertTrue(
            MobileQuickLookPreview.Coordinator.requiresReload(
                currentURL: firstURL,
                currentTitle: "First",
                nextURL: secondURL,
                nextTitle: "First"
            )
        )
        XCTAssertTrue(
            MobileQuickLookPreview.Coordinator.requiresReload(
                currentURL: firstURL,
                currentTitle: "First",
                nextURL: firstURL,
                nextTitle: "Renamed"
            )
        )
    }

    func test组件不自行决定iPhone或iPad的容器与Artifact生命周期() throws {
        let preview = try sourceFile("Sources/Features/Files/MobileFilePreviewView.swift")
        let quickLook = try sourceFile("Sources/Platform/Preview/MobileQuickLookPreview.swift")
        for forbidden in ["fullScreenCover", "inspector(", "removeItem", "MobileDocumentTransferController"] {
            XCTAssertFalse(preview.contains(forbidden), forbidden)
            XCTAssertFalse(quickLook.contains(forbidden), forbidden)
        }
    }

    func test全部新增可见文案均通过约定资源键() throws {
        let preview = try sourceFile("Sources/Features/Files/MobileFilePreviewView.swift")
        let details = try sourceFile("Sources/Features/Files/MobileFileDetailsView.swift")
        let media = try sourceFile("Sources/Platform/Preview/MobileMediaPlayer.swift")
        let combined = preview + details + media
        let keys = [
            "mobile.files.preview.inactive.title",
            "mobile.files.preview.inactive.message",
            "mobile.files.preview.loading-details",
            "mobile.files.preview.loading-preview",
            "mobile.files.preview.failed.title",
            "mobile.files.preview.cancelled.title",
            "mobile.files.preview.cancelled.message",
            "mobile.files.preview.unsupported.message",
            "mobile.files.preview.action.cancel",
            "mobile.files.preview.action.retry",
            "mobile.files.preview.action.close",
            "mobile.files.preview.action.details",
            "mobile.files.preview.action.full-screen",
            "mobile.files.preview.progress.bytes",
            "mobile.files.preview.progress.bytes-total",
            "mobile.files.preview.failure.authentication",
            "mobile.files.preview.failure.otp",
            "mobile.files.preview.failure.permission",
            "mobile.files.preview.failure.network",
            "mobile.files.preview.failure.local-space",
            "mobile.files.preview.failure.not-found",
            "mobile.files.preview.failure.unavailable",
            "mobile.files.preview.failure.unknown",
            "mobile.files.preview.text.empty.title",
            "mobile.files.preview.text.empty.message",
            "mobile.files.preview.text.too-large.title",
            "mobile.files.preview.text.too-large.message",
            "mobile.files.preview.text.size-unknown.message",
            "mobile.files.preview.text.encoding.title",
            "mobile.files.preview.text.encoding.message",
            "mobile.files.preview.media.loading",
            "mobile.files.preview.media.failed.title",
            "mobile.files.preview.media.failed.message",
            "mobile.files.preview.media.accessibility.player",
            "mobile.files.details.section.general",
            "mobile.files.details.section.dates",
            "mobile.files.details.section.ownership",
            "mobile.files.details.section.permissions",
            "mobile.files.details.name",
            "mobile.files.details.type",
            "mobile.files.details.size",
            "mobile.files.details.location",
            "mobile.files.details.mime",
            "mobile.files.details.extension",
            "mobile.files.details.modified",
            "mobile.files.details.created",
            "mobile.files.details.accessed",
            "mobile.files.details.owner",
            "mobile.files.details.group",
            "mobile.files.details.view",
            "mobile.files.details.edit",
            "mobile.files.details.delete",
            "mobile.files.details.value.file",
            "mobile.files.details.value.folder",
            "mobile.files.details.value.link",
            "mobile.files.details.value.item",
            "mobile.files.details.value.allowed",
            "mobile.files.details.value.not-allowed",
            "mobile.files.details.recycle-location"
        ]
        for key in keys {
            XCTAssertTrue(combined.contains("\"\(key)\""), key)
        }
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile.deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
