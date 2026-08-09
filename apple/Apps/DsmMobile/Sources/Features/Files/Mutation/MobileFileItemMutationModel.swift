import DsmCore
import DsmNetwork
import Foundation
import Observation

protocol MobileFileItemMutating: AnyObject, Sendable {
    var profileID: UUID { get }
    func createFolderResult(parentPath: String, name: String) async throws -> FileItemMutationOutcome
    func renameResult(path: String, newName: String) async throws -> FileItemMutationOutcome
}

extension DsmFileRepository: MobileFileItemMutating {}

@MainActor
@Observable
final class MobileFileItemMutationModel {
    private(set) var activeProfileID: UUID?
    private(set) var presentation: MobileFileItemMutationPresentation?
    @ObservationIgnored private var repositoryIdentity: ObjectIdentifier?
    @ObservationIgnored private var requestTask: Task<FileItemMutationOutcome, Error>?
    @ObservationIgnored private var generation = 0

    var isPresented: Bool { presentation != nil }

    func activate(profileID: UUID?, repository: (any MobileFileItemMutating)?) {
        deactivate()
        guard let profileID,
              let repository,
              repository.profileID == profileID else { return }
        activeProfileID = profileID
        repositoryIdentity = ObjectIdentifier(repository)
    }

    func beginCreateFolder(
        parentPath: String,
        source: MobileFileLocationSource,
        readOnlyRoots: [String] = [],
        repository: any MobileFileItemMutating
    ) {
        guard isActive(repository),
              Self.canMutate(
                  parentPath: parentPath,
                  source: source,
                  readOnlyRoots: readOnlyRoots
              ) else { return }
        generation &+= 1
        presentation = MobileFileItemMutationPresentation(
            kind: .createFolder,
            profileID: repository.profileID,
            parentPath: parentPath,
            sourceItem: nil,
            name: ""
        )
    }

    func beginRename(
        item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        readOnlyRoots: [String] = [],
        repository: any MobileFileItemMutating
    ) {
        guard isActive(repository),
              Self.canRename(
                  item: item,
                  parentPath: parentPath,
                  source: source,
                  readOnlyRoots: readOnlyRoots,
                  profileID: repository.profileID
              ) else { return }
        generation &+= 1
        presentation = MobileFileItemMutationPresentation(
            kind: .rename,
            profileID: repository.profileID,
            parentPath: parentPath,
            sourceItem: item,
            name: item.name
        )
    }

    func setName(_ name: String) {
        guard var presentation, presentation.phase == .editing else { return }
        if presentation.name != name {
            presentation.feedback = nil
            presentation.requiresNameChange = false
        }
        presentation.name = name
        self.presentation = presentation
    }

    func submit(
        repository: any MobileFileItemMutating
    ) async -> MobileFileItemMutationSuccess? {
        guard var snapshot = presentation,
              snapshot.phase == .editing,
              isActive(repository),
              snapshot.profileID == repository.profileID else { return nil }
        guard Self.isValidName(snapshot.name),
              let destinationPath = snapshot.destinationPath else {
            snapshot.feedback = .invalidName
            presentation = snapshot
            return nil
        }
        guard !snapshot.requiresNameChange else { return nil }

        snapshot.phase = .submitting
        snapshot.feedback = nil
        presentation = snapshot
        let requestGeneration = generation
        let identity = ObjectIdentifier(repository)
        let task = Task {
            switch snapshot.kind {
            case .createFolder:
                return try await repository.createFolderResult(
                    parentPath: snapshot.parentPath,
                    name: snapshot.name
                )
            case .rename:
                guard let sourceItem = snapshot.sourceItem else {
                    throw MobileFileItemMutationInternalError.missingSource
                }
                return try await repository.renameResult(
                    path: sourceItem.path,
                    newName: snapshot.name
                )
            }
        }
        requestTask = task

        do {
            let outcome = try await task.value
            guard isCurrent(
                profileID: snapshot.profileID,
                repositoryIdentity: identity,
                generation: requestGeneration
            ) else { return nil }
            requestTask = nil
            return handle(
                outcome,
                snapshot: snapshot,
                destinationPath: destinationPath
            )
        } catch {
            guard isCurrent(
                profileID: snapshot.profileID,
                repositoryIdentity: identity,
                generation: requestGeneration
            ) else { return nil }
            requestTask = nil
            enterReview(
                snapshot: snapshot,
                feedback: Self.feedback(for: error)
            )
            return nil
        }
    }

    /// 提交中只请求取消；由 typed result 区分写前取消与提交后未知状态。
    func requestCancellation() {
        guard presentation?.phase == .submitting else { return }
        requestTask?.cancel()
    }

    func dismiss() {
        guard presentation?.phase != .submitting else { return }
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
        presentation = nil
    }

    func deactivate() {
        generation &+= 1
        requestTask?.cancel()
        requestTask = nil
        presentation = nil
        activeProfileID = nil
        repositoryIdentity = nil
    }

    static func canMutate(
        parentPath: String,
        source: MobileFileLocationSource,
        readOnlyRoots: [String] = []
    ) -> Bool {
        !source.isReadOnlyLocation &&
            isCanonicalAbsolutePath(parentPath) &&
            !containsRecycleSegment(parentPath) &&
            !readOnlyRoots.contains(where: { isSameOrDescendant(parentPath, of: $0) })
    }

    static func canRename(
        item: FileItem,
        parentPath: String,
        source: MobileFileLocationSource,
        readOnlyRoots: [String] = [],
        profileID: UUID
    ) -> Bool {
        item.profileID == profileID &&
            canMutate(
                parentPath: parentPath,
                source: source,
                readOnlyRoots: readOnlyRoots
            ) &&
            isCanonicalAbsolutePath(item.path) &&
            Self.parentPath(of: item.path) == parentPath &&
            !item.isRecyclePath &&
            !isRemote(item)
    }

    nonisolated static func isValidName(_ name: String) -> Bool {
        !name.isEmpty &&
            name == name.trimmingCharacters(in: .whitespacesAndNewlines) &&
            name != "." &&
            name != ".." &&
            name.utf8.count <= 255 &&
            !name.contains("/") &&
            !name.contains("\\") &&
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func handle(
        _ outcome: FileItemMutationOutcome,
        snapshot: MobileFileItemMutationPresentation,
        destinationPath: String
    ) -> MobileFileItemMutationSuccess? {
        switch outcome.result.status {
        case .confirmedSuccess:
            guard let item = outcome.item,
                  item.profileID == snapshot.profileID,
                  item.path == destinationPath,
                  item.name == snapshot.name,
                  snapshot.kind != .createFolder || item.isDirectory,
                  snapshot.sourceItem.map({ $0.kind == item.kind }) ?? true else {
                enterReview(snapshot: snapshot, feedback: .unknown)
                return nil
            }
            presentation = nil
            return MobileFileItemMutationSuccess(
                profileID: snapshot.profileID,
                parentPath: snapshot.parentPath,
                item: item
            )
        case .cancelledBeforeSubmission:
            var editable = snapshot
            editable.phase = .editing
            editable.feedback = nil
            presentation = editable
        case .permissionDenied:
            enterEditingFailure(snapshot: snapshot, feedback: .permission, requiresNameChange: false)
        case .unsupported:
            enterEditingFailure(snapshot: snapshot, feedback: .unavailable, requiresNameChange: false)
        case .confirmedFailure:
            let feedback: MobileFileItemMutationFeedback = outcome.result.errorCategory == .permission
                ? .permission : .conflict
            if feedback == .permission {
                enterEditingFailure(snapshot: snapshot, feedback: feedback, requiresNameChange: false)
            } else {
                enterReview(snapshot: snapshot, feedback: feedback)
            }
        case .submittedButUnverified,
             .cancellationRequestedAfterSubmission,
             .partialSuccess:
            enterReview(snapshot: snapshot, feedback: .unknown)
        }
        return nil
    }

    private func enterEditingFailure(
        snapshot: MobileFileItemMutationPresentation,
        feedback: MobileFileItemMutationFeedback,
        requiresNameChange: Bool
    ) {
        var editable = snapshot
        editable.phase = .editing
        editable.feedback = feedback
        editable.requiresNameChange = requiresNameChange
        presentation = editable
    }

    private func enterReview(
        snapshot: MobileFileItemMutationPresentation,
        feedback: MobileFileItemMutationFeedback
    ) {
        var review = snapshot
        review.phase = .review
        review.feedback = feedback
        review.name = ""
        review.requiresNameChange = true
        presentation = review
    }

    private func isActive(_ repository: any MobileFileItemMutating) -> Bool {
        activeProfileID == repository.profileID &&
            repositoryIdentity == ObjectIdentifier(repository)
    }

    private func isCurrent(
        profileID: UUID,
        repositoryIdentity identity: ObjectIdentifier,
        generation requestGeneration: Int
    ) -> Bool {
        activeProfileID == profileID &&
            repositoryIdentity == identity &&
            generation == requestGeneration
    }

    private static func feedback(for error: Error) -> MobileFileItemMutationFeedback {
        guard let appError = error as? AppError else { return .unknown }
        switch appError.category {
        case .authenticationRequired, .otpRequired:
            return MobileFileItemMutationFeedback.authentication
        case .permissionDenied:
            return MobileFileItemMutationFeedback.permission
        case .apiUnavailable, .versionUnsupported:
            return MobileFileItemMutationFeedback.unavailable
        default:
            return MobileFileItemMutationFeedback.unknown
        }
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"),
              path != "/",
              !path.hasSuffix("/"),
              !path.contains("//"),
              !path.contains("\\") else { return false }
        return path.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
    }

    private static func parentPath(of path: String) -> String? {
        let components = path.split(separator: "/")
        guard components.count >= 2 else { return nil }
        return "/" + components.dropLast().joined(separator: "/")
    }

    private static func containsRecycleSegment(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.lowercased() == "#recycle" }
    }

    private static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        isCanonicalAbsolutePath(root) && (path == root || path.hasPrefix(root + "/"))
    }

    private static func isRemote(_ item: FileItem) -> Bool {
        guard let type = item.mountPointType?.lowercased() else { return false }
        return ["cifs", "nfs", "iso", "remote"].contains(type)
    }
}

private enum MobileFileItemMutationInternalError: Error {
    case missingSource
}
