@testable import DsmMobile
import XCTest

final class MobileContentStateTests: XCTestCase {
    func test页面状态身份保持稳定且完整() {
        XCTAssertEqual(
            MobilePageState.allCases.map(\.rawValue),
            ["loading", "empty", "filteredEmpty", "error", "content"]
        )
    }

    func test只有正常状态显示业务内容() {
        for state in MobilePageState.allCases {
            XCTAssertEqual(state.showsContent, state == .content)
        }
    }

    func test只有错误状态提供恢复动作() {
        for state in MobilePageState.allCases {
            XCTAssertEqual(state.showsRecoveryAction, state == .error)
        }
    }

    func test普通空态居中而筛选空与内容顶部对齐() {
        XCTAssertEqual(MobilePageState.loading.layout, .centered)
        XCTAssertEqual(MobilePageState.empty.layout, .centered)
        XCTAssertEqual(MobilePageState.error.layout, .centered)
        XCTAssertEqual(MobilePageState.filteredEmpty.layout, .topLeading)
        XCTAssertEqual(MobilePageState.content.layout, .topLeading)
    }
}
