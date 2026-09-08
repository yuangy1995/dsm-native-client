import DsmCore
import XCTest
@testable import DsmNetwork

final class DsmErrorMapperTests: XCTestCase {
    func test文件禁止操作和只读文件系统映射为权限问题() {
        for code in [407, 411] {
            let error = DsmErrorMapper.map(.api(code: code, requestID: UUID()), context: .fileStation)
            XCTAssertEqual(error.category, .permissionDenied)
            XCTAssertFalse(error.isRetryable)
        }
        XCTAssertEqual(DsmErrorMapper.map(.api(code: 407, requestID: UUID()), context: .general).category, .unknown)
    }

    func test文件请求的HTTP403映射为权限不足() {
        let error = DsmErrorMapper.map(
            .httpStatus(code: 403, requestID: UUID()),
            context: .general
        )

        XCTAssertEqual(error.category, .permissionDenied)
        XCTAssertEqual(error.httpStatus, 403)
        XCTAssertTrue(error.safeUserMessage.contains("File Station"))
    }

    func test登录请求的HTTP403仍映射为登录失败() {
        let error = DsmErrorMapper.map(
            .httpStatus(code: 403, requestID: UUID()),
            context: .authentication(otpWasSubmitted: false)
        )

        XCTAssertEqual(error.category, .authenticationRequired)
        XCTAssertEqual(error.httpStatus, 403)
    }
}
