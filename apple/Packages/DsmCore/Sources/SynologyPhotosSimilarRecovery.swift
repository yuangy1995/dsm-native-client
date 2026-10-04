import Foundation

extension SynologyPhotosAlbumCheckpoint {
    /// 相似操作只保留原分组与照片身份摘要；不保存文件名或媒体。
    public struct Similar: Codable, Equatable, Sendable {
        public let group: SynologyPhotoSimilarGroup
        public let edit: SynologyPhotoSimilarEdit
        public let targets: [PhotoEdit.Target]
        public var submitted = false
        public var confirmed = false
        public var resultingGroup: SynologyPhotoSimilarGroup?

        public init(mutation: SynologyPhotosMutation) throws {
            guard case .editSimilarGroup(let detail, let edit) = mutation else { throw CocoaError(.coderInvalidValue) }
            group = detail.group; self.edit = edit
            targets = try detail.photos.map { try .init($0, valueDigest: nil) }
            _ = try reviewMutation(profileID: group.profileID)
        }

        public func reviewMutation(profileID: UUID) throws -> SynologyPhotosMutation {
            func valid(_ value: SynologyPhotoSimilarGroup) -> Bool {
                value.profileID == profileID && value.space == group.space && value.id == group.id && value.id > 0 &&
                    value.photoIDs.count >= 2 && value.photoIDs.allSatisfy { $0 > 0 } &&
                    Set(value.photoIDs).count == value.photoIDs.count && value.photoIDs.contains(value.topPickID)
            }
            guard valid(group), !confirmed || submitted, resultingGroup.map(valid) ?? true,
                  confirmed || resultingGroup == nil, targets.count == group.photoIDs.count,
                  Set(targets.map(\.unitID)) == Set(group.photoIDs),
                  targets.allSatisfy({ target in
                      target.profileID == profileID && target.space == group.space && target.folderID > 0 &&
                          target.albumID == nil && target.ownerID == nil && target.providerID == nil && target.valueDigest == nil &&
                          target.identityDigest.count == 64 && target.identityDigest.allSatisfy { "0123456789abcdef".contains($0) }
                  }) else { throw CocoaError(.coderReadCorrupt) }
            switch edit {
            case .topPick(let id): guard group.photoIDs.contains(id), id != group.topPickID else { throw CocoaError(.coderReadCorrupt) }
            case .remove(let ids): guard !ids.isEmpty, Set(ids).count == ids.count, Set(ids).isSubset(of: Set(group.photoIDs)) else { throw CocoaError(.coderReadCorrupt) }
            case .ungroup, .undo: break
            }
            if confirmed {
                switch edit {
                case .topPick(let id):
                    guard resultingGroup.map({ Set($0.photoIDs) == Set(group.photoIDs) }) == true, resultingGroup?.topPickID == id else { throw CocoaError(.coderReadCorrupt) }
                case .ungroup: guard resultingGroup == nil else { throw CocoaError(.coderReadCorrupt) }
                case .remove(let ids):
                    let remaining = Set(group.photoIDs).subtracting(ids)
                    guard remaining.count < 2 ? resultingGroup == nil : resultingGroup.map({ Set($0.photoIDs) == remaining }) == true else { throw CocoaError(.coderReadCorrupt) }
                case .undo:
                    guard resultingGroup.map({ Set($0.photoIDs) == Set(group.photoIDs) && $0.topPickID == group.topPickID }) == true else { throw CocoaError(.coderReadCorrupt) }
                }
            }
            let photos = targets.map { target in var photo = target.queryPhoto; photo.similarGroup = group; return photo }
            return .editSimilarGroup(.init(group: group, photos: photos), edit)
        }

        public func hasSameIntent(as mutation: SynologyPhotosMutation) -> Bool {
            guard let other = try? Similar(mutation: mutation) else { return false }
            return group == other.group && edit == other.edit && targets == other.targets
        }
        public var canUndo: Bool {
            guard confirmed else { return false }
            switch edit { case .remove, .ungroup: return true; default: return false }
        }
    }
}
