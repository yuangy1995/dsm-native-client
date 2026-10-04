import CryptoKit
import Foundation

/// 原件删除的持久身份与提交阶段；摘要占位照片只能用于只读恢复，不能直接再次删除。
public struct SynologyPhotoDeletionCheckpoint: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case prepared, submitted, confirmed, rejected, cancelled }
    public let version: Int
    public let operationID: UUID
    public let identity: String
    public let target: SynologyPhotosAlbumCheckpoint.PhotoEdit.Target
    public let takenAtDigest: String
    public var state: State

    public init(photo: SynologyPhoto, operationID: UUID, identity: String, state: State = .prepared) throws {
        version = 1; self.operationID = operationID; self.identity = identity; self.state = state
        target = try .init(photo, valueDigest: nil)
        takenAtDigest = Self.dateDigest(photo.takenAt)
        try validate()
    }
    public var isFinished: Bool { [.confirmed, .rejected, .cancelled].contains(state) }
    public func matches(_ photo: SynologyPhoto) throws -> Bool {
        try target.matchesIdentity(photo) && takenAtDigest == Self.dateDigest(photo.takenAt)
    }
    public func validate() throws {
        let expectedPrefix = target.profileID.uuidString + ":"
        guard version == 1, identity.hasPrefix(expectedPrefix),
              Int(identity.dropFirst(expectedPrefix.count)).map({ $0 > 0 }) == true,
              target.unitID > 0, target.folderID > 0, target.valueDigest == nil,
              [target.identityDigest, takenAtDigest].allSatisfy({ value in
                  value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
              }), target.albumID.map({ $0 > 0 && (target.ownerID.map { $0 >= 0 } ?? false) }) ?? (target.ownerID == nil && target.providerID == nil),
              target.providerID.map({ $0 > 0 }) ?? true else { throw CocoaError(.coderReadCorrupt) }
    }
    private static func dateDigest(_ value: Date) -> String {
        SHA256.hash(data: Data(String(value.timeIntervalSince1970).utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
