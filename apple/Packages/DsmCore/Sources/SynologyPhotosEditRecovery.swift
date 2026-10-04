import CryptoKit
import Foundation

extension SynologyPhotosAlbumCheckpoint {
    /// 复用照片操作恢复文件；正文只保留摘要，恢复命令只能用于查询。
    public struct PhotoEdit: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case rating, description, date, shift, addTags, removeTags, createTag }
        public struct Target: Codable, Equatable, Sendable {
            public let profileID: UUID
            public let space: SynologyPhotoSpace
            public let unitID: Int
            public let folderID: Int
            public let albumID: Int?
            public let ownerID: Int?
            public let providerID: Int?
            public let identityDigest: String
            public let valueDigest: String?

            public var id: SynologyPhotoID { .init(profileID: profileID, space: space, unitID: unitID) }
            public var queryPhoto: SynologyPhoto {
                .init(id: id, filename: identityDigest, sizeBytes: 0, takenAt: Date(timeIntervalSince1970: 0),
                      indexedAt: Date(timeIntervalSince1970: 0), folderID: folderID, mediaType: "photo",
                      albumContext: albumID.map { .init(albumID: $0, ownerUserID: ownerID ?? 0, providerUserID: providerID) })
            }

            init(_ photo: SynologyPhoto, valueDigest: String?) throws {
                profileID = photo.id.profileID; space = photo.id.space; unitID = photo.id.unitID; folderID = photo.folderID
                albumID = photo.albumContext?.albumID; ownerID = photo.albumContext?.ownerUserID; providerID = photo.albumContext?.providerUserID
                identityDigest = try Self.digest(photo); self.valueDigest = valueDigest
            }
            public func matchesIdentity(_ photo: SynologyPhoto) throws -> Bool {
                try photo.id == id && identityDigest == Self.digest(photo)
            }
            private static func digest(_ photo: SynologyPhoto) throws -> String {
                struct Identity: Encodable {
                    let filename: String, size: Int64, folder: Int, indexed: Date, type: String
                    let album, owner, provider: Int?
                }
                return try PhotoEdit.digest(Identity(filename: photo.filename, size: photo.sizeBytes, folder: photo.folderID,
                    indexed: photo.indexedAt, type: photo.mediaType, album: photo.albumContext?.albumID,
                    owner: photo.albumContext?.ownerUserID, provider: photo.albumContext?.providerUserID))
            }
        }

        public let kind: Kind
        public let space: SynologyPhotoSpace
        public let targets: [Target]
        public let tagIDs: [Int]
        public let tagNameDigest: String?
        public var createdTagID: Int?
        public var attempted: Set<Int> = []
        public var rejected: Set<Int> = []
        public var reportedFailures: Set<Int> = []
        public var tagAdditionAttempted = false
        public var tagAdditionRejected = false

        public init(mutation: SynologyPhotosMutation) throws {
            space = mutation.space
            let expected: (SynologyPhoto) throws -> String?
            switch mutation {
            case .edit(_, .rating(let value)):
                guard (0...5).contains(value) else { throw CocoaError(.coderInvalidValue) }
                kind = .rating; tagIDs = []; tagNameDigest = nil; expected = { _ in try Self.digest(value) }
            case .edit(_, .description(let value)):
                kind = .description; tagIDs = []; tagNameDigest = nil; expected = { _ in try Self.digest(value) }
            case .edit(_, .takenAt(let value)):
                let time = try Self.timestamp(value)
                kind = .date; tagIDs = []; tagNameDigest = nil; expected = { _ in try Self.digest(time) }
            case .shiftDates(_, let seconds):
                guard seconds != 0 else { throw CocoaError(.coderInvalidValue) }
                kind = .shift; tagIDs = []; tagNameDigest = nil
                expected = {
                    let (time, overflow) = try Self.timestamp($0.takenAt).addingReportingOverflow(seconds)
                    guard !overflow, time >= 0, time <= Int.max / 2 else { throw CocoaError(.coderInvalidValue) }
                    return try Self.digest(time)
                }
            case .addTags(_, let ids): kind = .addTags; tagIDs = ids.sorted(); tagNameDigest = nil; expected = { _ in nil }
            case .removeTags(_, let ids): kind = .removeTags; tagIDs = ids.sorted(); tagNameDigest = nil; expected = { _ in nil }
            case .createTag(let name, _, _):
                guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CocoaError(.coderInvalidValue) }
                kind = .createTag; tagIDs = []; tagNameDigest = try Self.digest(name); expected = { _ in nil }
            default: throw CocoaError(.coderInvalidValue)
            }
            targets = try mutation.photos.map { try Target($0, valueDigest: expected($0)) }
        }

        public func matchesValue(_ photo: SynologyPhoto, target: Target) throws -> Bool {
            switch kind {
            case .rating: return try photo.rating.map { try Self.digest($0) == target.valueDigest } ?? false
            case .description: return try photo.description.map { try Self.digest($0) == target.valueDigest } ?? false
            case .date, .shift: return try Self.digest(Self.timestamp(photo.takenAt)) == target.valueDigest
            case .addTags: return photo.tags.map { Set(tagIDs).isSubset(of: Set($0.map(\.id))) } ?? false
            case .removeTags: return photo.tags.map { Set(tagIDs).isDisjoint(with: Set($0.map(\.id))) } ?? false
            case .createTag:
                guard let tag = photo.tags?.first(where: { $0.id == createdTagID }) else { return false }
                return try matchesTag(tag)
            }
        }

        public func matchesTag(_ tag: SynologyPhotoFilterChoice) throws -> Bool {
            try tag.id == createdTagID && tagNameDigest == Self.digest(tag.name)
        }

        public func hasSameIntent(as mutation: SynologyPhotosMutation) -> Bool {
            guard var other = try? Self(mutation: mutation) else { return false }
            other.createdTagID = createdTagID; other.attempted = attempted; other.rejected = rejected
            other.reportedFailures = reportedFailures; other.tagAdditionAttempted = tagAdditionAttempted
            other.tagAdditionRejected = tagAdditionRejected
            return other == self
        }

        func reviewMutation(profileID: UUID) throws -> SynologyPhotosMutation {
            let values = Set(targets.indices)
            let scalar = [.rating, .description, .date, .shift].contains(kind)
            guard targets.count <= 100, !targets.isEmpty || kind == .createTag,
                  Set(targets.map(\.id)).count == targets.count, attempted.isSubset(of: values),
                  rejected.isSubset(of: attempted), reportedFailures.isSubset(of: attempted),
                  targets.allSatisfy({ target in
                      target.profileID == profileID && target.unitID > 0 && target.folderID > 0 && Self.validDigest(target.identityDigest) &&
                      (scalar ? target.valueDigest.map(Self.validDigest) == true : target.valueDigest == nil) &&
                      (target.albumID.map { $0 > 0 && target.ownerID.map { $0 >= 0 } == true } ?? (target.ownerID == nil && target.providerID == nil)) &&
                      (target.providerID.map { $0 > 0 } ?? true)
                  }),
                  ([.rating, .date, .shift].contains(kind) || targets.allSatisfy({ $0.space == space })),
                  targets.first.map({ $0.space == space }) ?? true,
                  [.addTags, .removeTags].contains(kind) ? (!tagIDs.isEmpty && tagIDs.allSatisfy { $0 > 0 } && Set(tagIDs).count == tagIDs.count) : tagIDs.isEmpty,
                  kind == .createTag ? (tagNameDigest.map(Self.validDigest) == true && (createdTagID.map { $0 > 0 } ?? true)) : (tagNameDigest == nil && createdTagID == nil),
                  !tagAdditionAttempted || (kind == .createTag && createdTagID != nil),
                  !tagAdditionRejected || tagAdditionAttempted else { throw CocoaError(.coderReadCorrupt) }
            let photos = targets.map(\.queryPhoto)
            switch kind {
            case .rating: return .edit(photos, .rating(0))
            case .description: return .edit(photos, .description(""))
            case .date: return .edit(photos, .takenAt(Date(timeIntervalSince1970: 0)))
            case .shift: return .shiftDates(photos, seconds: 1)
            case .addTags: return .addTags(photos, ids: tagIDs)
            case .removeTags: return .removeTags(photos, ids: tagIDs)
            case .createTag: return .createTag(name: tagNameDigest ?? "", photos: photos, space: space)
            }
        }

        private static func timestamp(_ date: Date) throws -> Int {
            let value = date.timeIntervalSince1970
            guard value.isFinite, value >= 0, value <= Double(Int.max / 2) else { throw CocoaError(.coderInvalidValue) }
            return Int(value)
        }
        private static func validDigest(_ value: String) -> Bool {
            value.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        private static func digest<T: Encodable>(_ value: T) throws -> String {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
        }
    }
}
