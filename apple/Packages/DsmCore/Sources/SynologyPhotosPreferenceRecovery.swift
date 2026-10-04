import Foundation

extension SynologyPhotosAlbumCheckpoint {
    /// 偏好只含稳定枚举和开关；旋转仅保留原件身份、方向和尺寸，恢复不重放写入。
    public enum Preference: Codable, Sendable {
        case duplicates(original: SynologyPhotoDuplicateSettings, updated: SynologyPhotoDuplicateSettings)
        case display(original: SynologyPhotoDisplaySettings, updated: SynologyPhotoDisplaySettings)
        case recognition(original: SynologyPhotoRecognitionSettings, enabled: Set<SynologyPhotoRecognitionSettings.Kind>)
        case rotation(Rotation)

        public init(mutation: SynologyPhotosMutation) throws {
            switch mutation {
            case .setDuplicateSettings(let original, let updated): self = .duplicates(original: original, updated: updated)
            case .setDisplaySettings(let original, let updated): self = .display(original: original, updated: updated)
            case .setRecognitionSettings(let original, let enabled): self = .recognition(original: original, enabled: enabled)
            case .rotatePhoto(let photo): self = .rotation(Rotation(photo))
            default: throw CocoaError(.coderInvalidValue)
            }
        }

        func reviewMutation() throws -> SynologyPhotosMutation {
            switch self {
            case .duplicates(let original, let updated):
                guard original != updated else { throw CocoaError(.coderReadCorrupt) }
                return .setDuplicateSettings(original: original, updated: updated)
            case .display(let original, let updated):
                guard original != updated else { throw CocoaError(.coderReadCorrupt) }
                return .setDisplaySettings(original: original, updated: updated)
            case .recognition(let original, let enabled):
                guard original.canSave(enabled) else { throw CocoaError(.coderReadCorrupt) }
                return .setRecognitionSettings(original: original, enabled: enabled)
            case .rotation(let value):
                let photo = value.photo
                guard photo.supportsRotation, photo.sizeBytes >= 0,
                      photo.width.map({ $0 > 0 }) ?? true, photo.height.map({ $0 > 0 }) ?? true else { throw CocoaError(.coderReadCorrupt) }
                return .rotatePhoto(photo)
            }
        }

        public func hasSameIntent(as mutation: SynologyPhotosMutation) -> Bool {
            if case .rotation(let value) = self, case .rotatePhoto(let photo) = mutation {
                return value.photo == Rotation(photo).photo
            }
            return (try? reviewMutation()) == mutation
        }
    }

    public struct Rotation: Codable, Sendable {
        let original: SynologyPhotoUploadPhoto
        let orientation: Int?
        let width, height: Int?
        init(_ photo: SynologyPhoto) {
            original = .init(photo); orientation = photo.orientation; width = photo.width; height = photo.height
        }
        public var photo: SynologyPhoto {
            let source = original.photo
            return .init(id: source.id, filename: source.filename, sizeBytes: source.sizeBytes,
                takenAt: source.takenAt, indexedAt: source.indexedAt, folderID: source.folderID, mediaType: source.mediaType,
                width: width, height: height, orientation: orientation, albumContext: source.albumContext)
        }
    }
}
