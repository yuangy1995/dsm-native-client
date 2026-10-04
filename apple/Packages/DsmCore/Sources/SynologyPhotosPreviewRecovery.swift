import Foundation

extension SynologyPhotosAlbumCheckpoint {
    /// 每个原件单独记录写入边界；恢复只能读取，不重新生成或上传媒体。
    public struct PreviewRegeneration: Codable, Sendable {
        public struct Target: Codable, Sendable {
            public let original: SynologyPhotoUploadPhoto
            public var baselineUnitID: Int?
            public var baselineRevision: String?
            public var marking = false
            public var marked = false
            public var submitted = false
            public var restoring = false
            public var generated = false
            public var recovered = false
            public var failed = false

            public init(_ photo: SynologyPhoto) { original = .init(photo) }
            public var id: SynologyPhotoID { original.photo.id }
            public var baseline: SynologyPhotoThumbnail? {
                guard let baselineUnitID, let baselineRevision else { return nil }
                return .init(unitID: baselineUnitID, revision: baselineRevision)
            }
        }
        public var targets: [Target]
        public let resuming: Bool
        public init(mutation: SynologyPhotosMutation) throws {
            guard case .regeneratePreviews(let photos, let resuming) = mutation else { throw CocoaError(.coderInvalidValue) }
            targets = photos.map(Target.init); self.resuming = resuming
        }
        func reviewMutation() throws -> SynologyPhotosMutation {
            guard !targets.isEmpty, targets.count <= 100, Set(targets.map(\.id)).count == targets.count,
                  targets.allSatisfy({ value in
                      value.original.size >= 0 && !value.original.filename.isEmpty &&
                      (value.baselineUnitID == nil) == (value.baselineRevision == nil) &&
                      (value.baselineUnitID.map { $0 > 0 } ?? true) &&
                      (!value.marked || value.marking || resuming) && (!value.submitted || value.marked) &&
                      (!value.restoring || value.submitted) && (!value.generated || value.submitted) &&
                      (!value.recovered || value.generated) && !(value.generated && value.failed)
                  }) else { throw CocoaError(.coderReadCorrupt) }
            return .regeneratePreviews(targets.map { $0.original.photo }, resuming: resuming)
        }
        public func hasSameIntent(as mutation: SynologyPhotosMutation) -> Bool {
            guard case .regeneratePreviews(let photos, let resuming) = mutation, self.resuming == resuming else { return false }
            return targets.map { $0.original.photo } == photos.map { SynologyPhotoUploadPhoto($0).photo }
        }
    }
}
