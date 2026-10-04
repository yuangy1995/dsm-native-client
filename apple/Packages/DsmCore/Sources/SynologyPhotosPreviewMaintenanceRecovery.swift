import Foundation

extension SynologyPhotosAlbumCheckpoint {
    /// 前台转换和 NAS 维护共用现有单项恢复文件；只保留回读所需的身份与回执。
    public enum PreviewMaintenance: Codable, Sendable {
        case setting(original: Bool, enabled: Bool)
        case codec(SynologyPhotoCodecPrompt, generate: Bool, acknowledged: Bool, promptRejected: Bool)
        case library(SynologyPhotoLibraryMaintenanceStatus, SynologyPhotoLibraryMaintenanceStatus.Action, acknowledged: Bool)
        case automatic(AutomaticPreview)

        public init(mutation: SynologyPhotosMutation) throws {
            switch mutation {
            case .setAutomaticPreview(let original, let enabled): self = .setting(original: original, enabled: enabled)
            case .respondToCodecPrompt(let original, let generate): self = .codec(original, generate: generate, acknowledged: false, promptRejected: false)
            case .maintainLibrary(let original, let action): self = .library(original, action, acknowledged: false)
            case .generateAutomaticPreview(let task, let support): self = .automatic(.init(task: task, support: support))
            default: throw CocoaError(.coderInvalidValue)
            }
        }
        func reviewMutation(profileID: UUID, userID: Int) throws -> SynologyPhotosMutation {
            switch self {
            case .setting(let original, let enabled):
                guard original != enabled else { throw CocoaError(.coderReadCorrupt) }
                return .setAutomaticPreview(original: original, enabled: enabled)
            case .codec(let original, let generate, let acknowledged, _):
                guard original.profileID == profileID, original.userID == userID, original.shouldShow,
                      !generate || original.canGenerate, !acknowledged || generate else { throw CocoaError(.coderReadCorrupt) }
                return .respondToCodecPrompt(original, generate: generate)
            case .library(let original, let action, _):
                guard original.profileID == profileID, original.userID == userID, original.canStart(action) else { throw CocoaError(.coderReadCorrupt) }
                return .maintainLibrary(original, action)
            case .automatic(let value):
                try value.validate(profileID: profileID)
                return .generateAutomaticPreview(value.task, support: value.support)
            }
        }
        public func hasSameIntent(as mutation: SynologyPhotosMutation, profileID: UUID, userID: Int) -> Bool {
            if case .automatic(let value) = self, case .generateAutomaticPreview(let task, let support) = mutation {
                return value.task == AutomaticPreview(task: task, support: support).task && value.support == support
            }
            return (try? reviewMutation(profileID: profileID, userID: userID)) == mutation
        }
    }

    public struct AutomaticPreview: Codable, Sendable {
        public enum FailureKind: String, Codable, Sendable { case photo, video }
        let profileID: UUID
        let space: SynologyPhotoSpace
        let unitID: Int
        let filename: String
        let typeCode: Int
        let needsThumbnail, needsVideo: Bool
        let source: SynologyPhotoUploadPhoto?
        let priority: SynologyPhotoAutomaticPreviewPriority
        public let support: SynologyPhotoPreviewConversionSupport
        public var submitted = false
        public var acknowledged = false
        public var thumbnailDigests: [String: Data] = [:]
        public var videoSignature: Data?
        public var failureKind: FailureKind?
        public var failureAcknowledged = false

        init(task: SynologyPhotoAutomaticPreviewTask, support: SynologyPhotoPreviewConversionSupport) {
            profileID = task.profileID; space = task.space; unitID = task.unitID; filename = task.filename
            typeCode = task.typeCode; needsThumbnail = task.needsThumbnail; needsVideo = task.needsVideo
            source = task.sourcePhoto.map(SynologyPhotoUploadPhoto.init); priority = task.priority; self.support = support
        }
        public var task: SynologyPhotoAutomaticPreviewTask {
            .init(profileID: profileID, space: space, unitID: unitID, filename: filename, typeCode: typeCode,
                  needsThumbnail: needsThumbnail, needsVideo: needsVideo, sourcePhoto: source?.photo, priority: priority)
        }
        func validate(profileID: UUID) throws {
            guard self.profileID == profileID, unitID > 0, !filename.isEmpty, needsThumbnail || needsVideo,
                  !needsVideo || typeCode != 0, !acknowledged || submitted, !failureAcknowledged || failureKind != nil,
                  failureKind == nil || !submitted,
                  Set(thumbnailDigests.keys).isSubset(of: ["xl", "sm", "m"]), thumbnailDigests.values.allSatisfy({ $0.count == 32 }),
                  !submitted || !needsThumbnail || thumbnailDigests.count == 3,
                  !submitted || !needsVideo || videoSignature != nil,
                  videoSignature.map({ !$0.isEmpty }) ?? true else { throw CocoaError(.coderReadCorrupt) }
            if let source {
                guard source.profileID == profileID, source.space == space, source.unitID > 0, source.folderID > 0,
                      source.size >= 0, !source.filename.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            }
        }
    }
}
