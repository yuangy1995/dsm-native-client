import Foundation
import XCTest
@testable import DsmMobile

@MainActor
final class MobileFileShareLinkPresentationTests: XCTestCase {
    func test创建页使用原生表单五态取消与可访问触控目标() throws {
        let source = try Self.source("MobileFileShareLinkView.swift")

        for required in [
            "Form {", "SecureField(", "Picker(", "presentationDetents",
            "interactiveDismissDisabled", "requestCancellation()", "minHeight: 44",
            ".disabled(!model.canSubmit)",
            "accessibilityAddTraits([.isStaticText, .updatesFrequently])",
            "List {", "model.confirmDeleteManagedLink()", "Button(role: .destructive)",
        ] {
            XCTAssertTrue(source.contains(required), "缺少 \(required)")
        }
        for phase in [
            ".form", ".creating", ".confirmedSuccess", ".reviewRequired", ".confirmedFailure",
            ".managementLoading", ".managementEmpty", ".managementContent", ".managementError",
            ".managementUnsupported", ".deletionConfirm", ".deleting", ".deletionConfirmed",
            ".deletionReviewRequired", ".deletionFailure",
        ] {
            XCTAssertTrue(source.contains(phase), "缺少五态 \(phase)")
        }
    }

    func test用户文案只引用语义资源且危险动作需要确认和回读() throws {
        let view = try Self.source("MobileFileShareLinkView.swift")
        let model = try Self.source("MobileFileShareLinkModel.swift")

        XCTAssertFalse(view.contains("Text(\""))
        XCTAssertTrue(view.contains("mobile.files.share-link.action.copy"))
        XCTAssertTrue(view.contains("mobile.files.share-link.action.share"))
        XCTAssertTrue(view.contains("mobile.files.share-link.delete.confirm.title"))
        XCTAssertTrue(model.contains("state.phase == .confirmedSuccess"))
        XCTAssertTrue(model.contains("confirmedLink"))
        XCTAssertTrue(model.contains("deleteShareLinks(ids: [link.id])"))
        XCTAssertTrue(model.contains("loadManagedLinkSnapshot(targetPath: targetPath, repository: repository)"))
        XCTAssertFalse(model.contains("clear_invalid"))
        XCTAssertFalse(model.contains("download("))
    }

    func test到期日期严格解析后本地化且无原始字符串直出() throws {
        let source = try Self.source("MobileFileShareLinkView.swift")
        XCTAssertTrue(source.contains("FileShareLinkCalendarDate(iso8601:"))
        XCTAssertTrue(source.contains("date.formatted(.dateTime.year().month().day())"))
        XCTAssertFalse(source.contains("expires\", expiresAt"))
    }

    func test负时区按本地公历日构造到期日期而不从UTC午夜换算() throws {
        let timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 3_600))
        let date = try XCTUnwrap(MobileFileShareLinkView.expirationDate(
            "2027-01-01",
            timeZone: timeZone
        ))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)

        XCTAssertEqual(components.year, 2027)
        XCTAssertEqual(components.month, 1)
        XCTAssertEqual(components.day, 1)
    }

    private static func source(_ name: String) throws -> String {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        return try String(
            contentsOf: tests.deletingLastPathComponent()
                .appendingPathComponent("Sources/Features/Files/Sharing")
                .appendingPathComponent(name),
            encoding: .utf8
        )
    }
}
