import DsmCore
import Foundation
import XCTest

final class SynologyPhotosAlbumRecoveryFormatTests: XCTestCase {
    func test当前格式往返保留账号操作编号和原目标() throws {
        let original = try SynologyPhotosAlbumCheckpoint(mutation: .renameAlbum(id: 21, name: "Synthetic"),
            operationID: UUID(), profileID: UUID(), userID: 7)
        let restored = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.version, 16)
        XCTAssertEqual(restored.profileID, original.profileID)
        XCTAssertEqual(restored.operationID, original.operationID)
        XCTAssertEqual(restored.userID, original.userID)
        XCTAssertEqual(try restored.reviewMutation(), .renameAlbum(id: 21, name: "Synthetic"))
    }

    func test旧开发格式和未知格式均拒绝而不猜测迁移() throws {
        let current = try SynologyPhotosAlbumCheckpoint(mutation: .renameAlbum(id: 21, name: "Synthetic"),
            operationID: UUID(), profileID: UUID(), userID: 7)
        let data = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        for version in Array(0..<16) + [17] {
            object["version"] = version
            let altered = try JSONSerialization.data(withJSONObject: object)
            let decoded = try JSONDecoder().decode(SynologyPhotosAlbumCheckpoint.self, from: altered)
            XCTAssertThrowsError(try decoded.reviewMutation(), "格式 \(version) 不受支持")
        }
    }
}
