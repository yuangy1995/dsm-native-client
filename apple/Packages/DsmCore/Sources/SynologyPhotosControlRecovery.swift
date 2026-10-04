import CryptoKit
import Foundation

extension SynologyPhotosAlbumCheckpoint {
    /// 目录权限只保留原快照摘要、成员身份及密码操作类别；不保存链接、密码或成员名称。
    public struct FolderSharing: Codable, Equatable, Sendable {
        let target: FolderOperation.Folder
        public let access: String
        public let members: [Sharing.Member]?
        public let password: Sharing.Password
        public let previousHasPassword: Bool?
        public let appliesToSubfolders: Bool
        let parentIsShared: Bool
        let previousApply: Bool
        let revisionDigest: String
        public var acknowledged = false
        public var folder: SynologyPhotoCollection { target.collection }

        public init(mutation: SynologyPhotosMutation) throws {
            guard case .setFolderSharing(let original, let access, let members, let password, let apply) = mutation else { throw CocoaError(.coderInvalidValue) }
            target = .init(original.folder); self.access = access.rawValue
            self.members = (members ?? original.members)?.map(Sharing.Member.init)
            self.password = password.map { $0.isEmpty ? .remove : .set } ?? .unchanged
            previousHasPassword = original.hasPassword; appliesToSubfolders = apply
            parentIsShared = original.parentIsShared; previousApply = original.appliesToSubfolders
            revisionDigest = SHA256.hash(data: Data(original.revision.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        public func hasSameIntent(as mutation: SynologyPhotosMutation) -> Bool {
            guard let other = try? Self(mutation: mutation) else { return false }
            return folder == other.folder && access == other.access && members == other.members && password == other.password &&
                previousHasPassword == other.previousHasPassword && appliesToSubfolders == other.appliesToSubfolders &&
                parentIsShared == other.parentIsShared && previousApply == other.previousApply && revisionDigest == other.revisionDigest
        }
        func reviewMutation() throws -> SynologyPhotosMutation {
            guard folder.id > 0, folder.space == .shared, let path = folder.path, path.hasPrefix("/"), !path.hasSuffix("/"),
                  (1...2).contains(path.split(separator: "/").count), (path as NSString).lastPathComponent == folder.name,
                  let access = SynologyPhotoFolderSharingState.Access(rawValue: access),
                  revisionDigest.count == 64, revisionDigest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw CocoaError(.coderReadCorrupt) }
            if let members {
                guard members.allSatisfy(\.isValid), Set(members.map { $0.grant.id }).count == members.count else { throw CocoaError(.coderReadCorrupt) }
            }
            let original = SynologyPhotoFolderSharingState(folder: folder, access: access, url: URL(string: "about:blank")!,
                hasPassword: previousHasPassword, members: members?.map(\.grant), parentIsShared: parentIsShared,
                appliesToSubfolders: previousApply, revision: revisionDigest)
            guard !original.inheritsManagementOnly, original.depth == 1 || appliesToSubfolders == previousApply else { throw CocoaError(.coderReadCorrupt) }
            return .setFolderSharing(original: original, access: access, members: members?.map(\.grant), password: nil, appliesToSubfolders: appliesToSubfolders)
        }
    }

    /// 冻结任务身份与逐项提交范围。恢复只读取原任务，不能再次取消或清除。
    public struct BackgroundControl: Codable, Sendable {
        public struct TaskSnapshot: Codable, Sendable {
            let id: Int
            let operation, status: String
            let total: Int
            let createdAt: Double
            let targetFolderID, targetOwnerID: Int?
            init(_ task: SynologyPhotoBackgroundTask) {
                id = task.id; operation = task.operation; status = task.status.rawValue
                total = task.total; createdAt = task.createdAt; targetFolderID = task.targetFolderID; targetOwnerID = task.targetOwnerID
            }
            func task(profileID: UUID, userID: Int) throws -> SynologyPhotoBackgroundTask {
                guard id > 0, total >= 0, createdAt.isFinite, createdAt >= 0,
                      let status = SynologyPhotoBackgroundTask.Status(rawValue: status) else { throw CocoaError(.coderReadCorrupt) }
                return .init(profileID: profileID, userID: userID, id: id, operation: operation, status: status,
                    total: total, completion: status == .done ? total : 0, errors: 0, skipped: 0, overwritten: 0,
                    createdAt: createdAt, targetFolderID: targetFolderID, targetOwnerID: targetOwnerID)
            }
        }
        public let clearing: Bool
        public let tasks: [TaskSnapshot]
        public var attempted: Set<Int> = []
        public var rejected: Set<Int> = []
        public init(mutation: SynologyPhotosMutation) throws {
            switch mutation {
            case .cancelBackgroundTask(let task): clearing = false; tasks = [.init(task)]
            case .clearBackgroundTasks(let tasks): clearing = true; self.tasks = tasks.map(TaskSnapshot.init)
            default: throw CocoaError(.coderInvalidValue)
            }
        }
        public func hasSameIntent(as mutation: SynologyPhotosMutation, profileID: UUID, userID: Int) -> Bool {
            guard let other = try? Self(mutation: mutation), other.clearing == clearing,
                  let current = try? tasks.map({ try $0.task(profileID: profileID, userID: userID) }),
                  let expected = try? other.tasks.map({ try $0.task(profileID: profileID, userID: userID) }) else { return false }
            return current == expected
        }
        func reviewMutation(profileID: UUID, userID: Int) throws -> SynologyPhotosMutation {
            let values = try tasks.map { try $0.task(profileID: profileID, userID: userID) }, ids = Set(values.map(\.id))
            guard !values.isEmpty, ids.count == values.count, attempted.isSubset(of: ids), rejected.isSubset(of: attempted),
                  clearing ? values.allSatisfy(\.canClear) : values.count == 1 && values[0].canCancel && attempted.isEmpty && rejected.isEmpty else { throw CocoaError(.coderReadCorrupt) }
            return clearing ? .clearBackgroundTasks(values) : .cancelBackgroundTask(values[0])
        }
    }
}
