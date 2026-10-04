import Foundation

extension SynologyPhotosAlbumCheckpoint {
    /// 管理设置按实际提交步骤恢复；成员只保存稳定身份和权限，不保存显示名称。
    public struct Administration: Codable, Sendable {
        public enum GlobalStep: String, Codable, Hashable, Sendable { case cache, admin, personal, shared }
        public enum Intent: Codable, Equatable, Sendable {
            case sharedEnabled(SynologyPhotoSharedSpaceSettings, Bool)
            case sharedSettings(SynologyPhotoSharedSpaceSettings, Set<SynologyPhotoSharedSpaceSettings.Kind>)
            case global(SynologyPhotoGlobalSettings, Set<SynologyPhotoGlobalSettings.Kind>, Set<String>?)
            case cache(SynologyPhotoConversionCache)
            case members(original: [Member], target: [Member], edits: [FolderEdit])
        }
        public struct Member: Codable, Equatable, Sendable {
            let id: SynologyPhotoShareRecipient.ID
            let role: String
            let autoBackup, isProtected: Bool
            init(_ member: SynologyPhotoSharedMember) {
                id = member.id; role = member.role; autoBackup = member.autoBackup; isProtected = member.isProtected
            }
            var member: SynologyPhotoSharedMember {
                .init(recipient: .init(id: id, name: isProtected ? "administrators" : ""), role: role, autoBackup: autoBackup)
            }
            var isValid: Bool {
                Administration.isValid(id) && !role.isEmpty && (!isProtected || id.type == "group")
            }
        }
        public struct Folder: Codable, Equatable, Sendable {
            let target: FolderOperation.Folder
            let sort: SynologyPhotoSort?
            let rootID, depth: Int
            let privacy, revision: String
            let directRole: String?
            init(_ value: SynologyPhotoMemberFolder) throws {
                target = .init(value.folder); sort = value.folder.sort
                rootID = value.rootID; depth = value.depth; privacy = value.privacy
                revision = value.revision; directRole = value.directRole
                // 此端点只返回目录身份与排序，不能截掉未知的身份字段后仍宣称快照相同。
                guard collection == value.folder else { throw CocoaError(.coderInvalidValue) }
            }
            var collection: SynologyPhotoCollection {
                let value = target.collection
                return .init(id: value.id, name: value.name, parentID: value.parentID, path: value.path, space: value.space, sort: sort)
            }
            func folder(profileID: UUID, memberID: SynologyPhotoShareRecipient.ID) throws -> SynologyPhotoMemberFolder {
                let value = collection
                guard rootID > 0, value.id > 0, value.id != rootID, value.space == .shared,
                      (0...1).contains(depth), let parent = value.parentID, parent > 0, parent != value.id,
                      (depth == 0) == (parent == rootID), !privacy.isEmpty, !revision.isEmpty,
                      let path = value.path, path.hasPrefix("/"), !path.hasSuffix("/"),
                      path.split(separator: "/").count == depth + 1,
                      (path as NSString).lastPathComponent == value.name else { throw CocoaError(.coderReadCorrupt) }
                return .init(profileID: profileID, memberID: memberID, rootID: rootID, folder: value,
                    depth: depth, privacy: privacy, directRole: directRole, revision: revision)
            }
        }
        public struct FolderEdit: Codable, Equatable, Sendable {
            let memberID: SynologyPhotoShareRecipient.ID
            let original: [Folder]
            let batch: SynologyPhotoMemberFolderEdit.Batch?
            let changes: [SynologyPhotoMemberFolderEdit.Change]
            init(_ edit: SynologyPhotoMemberFolderEdit, profileID: UUID) throws {
                guard edit.original.allSatisfy({ $0.profileID == profileID && $0.memberID == edit.memberID }) else { throw CocoaError(.coderInvalidValue) }
                memberID = edit.memberID; original = try edit.original.map(Folder.init)
                batch = edit.batch; changes = edit.changes
            }
            func edit(profileID: UUID) throws -> SynologyPhotoMemberFolderEdit {
                let folders = try original.map { try $0.folder(profileID: profileID, memberID: memberID) }
                guard Administration.isValid(memberID), Set(folders.map(\.rootID)).count == 1,
                      folders.filter({ $0.depth == 1 }).allSatisfy({ child in
                          folders.contains { $0.depth == 0 && $0.id == child.folder.parentID }
                      }) else { throw CocoaError(.coderReadCorrupt) }
                let value = SynologyPhotoMemberFolderEdit(memberID: memberID, original: folders, batch: batch, changes: changes)
                guard value.canSave else { throw CocoaError(.coderReadCorrupt) }
                return value
            }
        }

        public let profileID: UUID
        public let administratorID: Int
        public let intent: Intent
        public var memberAttempted: Set<Int> = []
        public var memberAcknowledged: Set<Int> = []
        public var memberRejected: Set<Int> = []
        public var globalAttempted: Set<GlobalStep> = []
        public var globalAcknowledged: Set<GlobalStep> = []
        public var globalRejected: Set<GlobalStep> = []

        public init(mutation: SynologyPhotosMutation) throws {
            switch mutation {
            case .setSharedSpaceEnabled(let original, let enabled):
                profileID = original.profileID; administratorID = original.administratorID; intent = .sharedEnabled(original, enabled)
            case .setSharedSpaceSettings(let original, let enabled):
                profileID = original.profileID; administratorID = original.administratorID; intent = .sharedSettings(original, enabled)
            case .setGlobalSettings(let original, let enabled, let excluded):
                profileID = original.profileID; administratorID = original.administratorID; intent = .global(original, enabled, excluded)
            case .clearConversionCache(let original):
                profileID = original.profileID; administratorID = original.administratorID; intent = .cache(original)
            case .setSharedMembers(let original, let target, let edits):
                guard original.isEnabled else { throw CocoaError(.coderInvalidValue) }
                profileID = original.profileID; administratorID = original.administratorID
                intent = .members(original: original.members.map(Member.init), target: target.map(Member.init),
                    edits: try edits.map { try FolderEdit($0, profileID: original.profileID) })
            default: throw CocoaError(.coderInvalidValue)
            }
        }

        public func hasSameIntent(as mutation: SynologyPhotosMutation) -> Bool {
            guard let other = try? Self(mutation: mutation) else { return false }
            return profileID == other.profileID && administratorID == other.administratorID && intent == other.intent
        }

        func reviewMutation(profileID: UUID, userID: Int) throws -> SynologyPhotosMutation {
            guard self.profileID == profileID, administratorID == userID,
                  memberAcknowledged.isSubset(of: memberAttempted), memberRejected.isSubset(of: memberAttempted),
                  memberAcknowledged.isDisjoint(with: memberRejected),
                  globalAcknowledged.isSubset(of: globalAttempted), globalRejected.isSubset(of: globalAttempted),
                  globalAcknowledged.isDisjoint(with: globalRejected) else { throw CocoaError(.coderReadCorrupt) }
            let mutation: SynologyPhotosMutation
            var memberSteps = 0
            var globalSteps: Set<GlobalStep> = []
            switch intent {
            case .sharedEnabled(let original, let enabled):
                guard original.profileID == profileID, original.administratorID == userID, original.canSetEnabled(enabled) else { throw CocoaError(.coderReadCorrupt) }
                mutation = .setSharedSpaceEnabled(original: original, enabled: enabled)
            case .sharedSettings(let original, let enabled):
                guard original.profileID == profileID, original.administratorID == userID, original.canSave(enabled) else { throw CocoaError(.coderReadCorrupt) }
                mutation = .setSharedSpaceSettings(original: original, enabled: enabled)
            case .global(let original, let enabled, let excluded):
                guard original.profileID == profileID, original.administratorID == userID,
                      original.canSave(enabled: enabled, excludedExtensions: excluded) else { throw CocoaError(.coderReadCorrupt) }
                let target = original.applying(enabled: enabled, excludedExtensions: excluded)
                if original.values[.originalJPEG] == true, target.values[.originalJPEG] == false { globalSteps.insert(.cache) }
                if original.values != target.values || original.excludedExtensions != target.excludedExtensions { globalSteps.insert(.admin) }
                if original.personalRecognition != target.personalRecognition { globalSteps.insert(.personal) }
                if original.sharedRecognition != target.sharedRecognition { globalSteps.insert(.shared) }
                mutation = .setGlobalSettings(original: original, enabled: enabled, excludedExtensions: excluded)
            case .cache(let original):
                guard original.profileID == profileID, original.administratorID == userID, original.canClear else { throw CocoaError(.coderReadCorrupt) }
                globalSteps = [.cache]; mutation = .clearConversionCache(original)
            case .members(let before, let after, let edits):
                guard before.allSatisfy(\.isValid), after.allSatisfy(\.isValid),
                      Set(edits.map(\.memberID)).count == edits.count else { throw CocoaError(.coderReadCorrupt) }
                let original = SynologyPhotoSharedMembers(profileID: profileID, administratorID: userID, isEnabled: true, members: before.map(\.member))
                let target = after.map(\.member), changes = try edits.map { try $0.edit(profileID: profileID) }
                guard original.canSave(target, candidates: target.map(\.recipient), allowsUnchanged: !changes.isEmpty),
                      changes.allSatisfy({ edit in target.contains { $0.id == edit.memberID && $0.role == "entry" && !$0.isProtected } }) else { throw CocoaError(.coderReadCorrupt) }
                let old = Dictionary(uniqueKeysWithValues: original.members.map { ($0.id, $0) })
                let new = Dictionary(uniqueKeysWithValues: target.map { ($0.id, $0) })
                memberSteps = (old == new ? 0 : 1) + changes.reduce(0) { $0 + ($1.batch == nil ? 0 : 1) + ($1.changes.isEmpty ? 0 : 1) }
                mutation = .setSharedMembers(original: original, members: target, folderEdits: changes)
            }
            guard memberAttempted.isSubset(of: Set(0..<memberSteps)), globalAttempted.isSubset(of: globalSteps) else { throw CocoaError(.coderReadCorrupt) }
            // 后续写只有收到前一步回执才会发生；缺失前序记录不能组成有效恢复链。
            if let last = memberAttempted.max(), !Set(0..<last).isSubset(of: memberAcknowledged) { throw CocoaError(.coderReadCorrupt) }
            let ordered = [GlobalStep.cache, .admin, .personal, .shared].filter(globalSteps.contains)
            if let last = ordered.lastIndex(where: globalAttempted.contains), !Set(ordered.prefix(last)).isSubset(of: globalAcknowledged) { throw CocoaError(.coderReadCorrupt) }
            return mutation
        }

        private static func isValid(_ id: SynologyPhotoShareRecipient.ID) -> Bool {
            guard ["user", "group"].contains(id.type) else { return false }
            switch id.value { case .integer(let number): return number > 0; case .string(let text): return !text.isEmpty; default: return false }
        }
    }
}
