import DsmCore
import Foundation
import Observation

enum MobileDocumentIntent: String, Equatable, Sendable {
    case upload
    case exportCopy
    case share
}

enum MobileDocumentTransferPolicy {
    static let supportsBackgroundTransfer = false
    static let supportsMultipleSelection = false
    static let supportsResume = false
}

struct MobileDocumentPickerContext: Equatable, Sendable {
    let profileID: UUID
    let folderPath: String
    let intent: MobileDocumentIntent
}

struct MobileDocumentDownloadContext: Equatable, Sendable {
    let profileID: UUID
    let remotePath: String
    let fileName: String
    let intent: MobileDocumentIntent
}

enum MobileDocumentTransferFailure: Equatable, Sendable {
    case localStorageFull
    case remoteStorageFull
    case authenticationRequired
    case otpRequired
    case permissionDenied
    case networkUnavailable
    case unknown

    init(category: AppErrorCategory) {
        switch category {
        case .localStorageFull: self = .localStorageFull
        case .remoteStorageFull: self = .remoteStorageFull
        case .authenticationRequired: self = .authenticationRequired
        case .otpRequired: self = .otpRequired
        case .permissionDenied: self = .permissionDenied
        case .networkUnavailable, .timeout: self = .networkUnavailable
        default: self = .unknown
        }
    }
}

struct MobileDocumentPresentation: Identifiable, Equatable {
    let taskID: UUID
    let profileID: UUID
    let url: URL
    let intent: MobileDocumentIntent

    var id: UUID { taskID }
}

protocol MobileDocumentImportCopying: Sendable {
    func copySecurityScopedFile(
        from sourceURL: URL,
        to destinationURL: URL,
        in directoryURL: URL
    ) async throws
}

struct MobileSecurityScopedDocumentCopier: MobileDocumentImportCopying {
    func copySecurityScopedFile(
        from sourceURL: URL,
        to destinationURL: URL,
        in directoryURL: URL
    ) async throws {
        let hasScope = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if hasScope { sourceURL.stopAccessingSecurityScopedResource() }
        }
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: (any Error)?
            coordinator.coordinate(
                readingItemAt: sourceURL,
                options: .withoutChanges,
                error: &coordinationError
            ) { coordinatedURL in
                do {
                    try fileManager.copyItem(at: coordinatedURL, to: destinationURL)
                } catch {
                    copyError = error
                }
            }
            if let copyError { throw copyError }
            if let coordinationError { throw coordinationError }
        }.value
    }
}

/// 桥接系统文档入口与前台传输状态机；每个任务只拥有自己的受控临时目录。
@MainActor
@Observable
final class MobileDocumentTransferController {
    private struct ArtifactRecord {
        let taskID: UUID
        let profileID: UUID
        let directoryURL: URL
        let fileURL: URL
        let intent: MobileDocumentIntent
    }

    private let transferCoordinator: MobileTransferCoordinator
    private let fileManager: FileManager
    private let importCopier: any MobileDocumentImportCopying
    private let rootURL: URL
    private var artifactsByTaskID: [UUID: ArtifactRecord] = [:]
    private var monitorsByTaskID: [UUID: Task<Void, Never>] = [:]
    private var activeProfileID: UUID?
    private var presentationQueue: [UUID] = []

    private(set) var presentation: MobileDocumentPresentation?
    private(set) var failure: MobileDocumentTransferFailure?
    private(set) var isAwaitingSystemDismissal = false

    init(
        transferCoordinator: MobileTransferCoordinator,
        fileManager: FileManager = .default,
        importCopier: any MobileDocumentImportCopying = MobileSecurityScopedDocumentCopier(),
        rootURL: URL? = nil,
        clearsStaleRootOnInitialization: Bool = false
    ) {
        self.transferCoordinator = transferCoordinator
        self.fileManager = fileManager
        self.importCopier = importCopier
        self.rootURL = rootURL ?? fileManager.temporaryDirectory
            .appendingPathComponent("LanStashDocuments", isDirectory: true)
        if clearsStaleRootOnInitialization {
            // 仅测试或调用方能证明没有 active task 时启用；App 首版不冒险清理共享根目录。
            try? fileManager.removeItem(at: self.rootURL)
        }
    }

    func handlePickedFile(
        _ sourceURL: URL,
        context: MobileDocumentPickerContext,
        service: any MobileTransferServing
    ) async -> UUID? {
        guard context.intent == .upload else { return nil }
        failure = nil
        let taskID = UUID()
        let directory = taskDirectory(taskID)
        let destination = directory.appendingPathComponent(
            Self.safeLeafName(sourceURL.lastPathComponent),
            isDirectory: false
        )
        do {
            try await importCopier.copySecurityScopedFile(
                from: sourceURL,
                to: destination,
                in: directory
            )
            try Task.checkCancellation()
        } catch {
            cleanup(directory)
            if error is CancellationError { return nil }
            failure = Self.failure(for: error)
            return nil
        }

        let target = Self.join(folder: context.folderPath, leaf: destination.lastPathComponent)
        let request = MobileUploadRequest(
            profileID: context.profileID,
            localURL: destination,
            folderPath: context.folderPath,
            overwrite: false,
            stableTarget: target
        )
        let enqueuedID = await transferCoordinator.enqueueUpload(request, retryPolicy: .none)
        artifactsByTaskID[enqueuedID] = ArtifactRecord(
            taskID: enqueuedID,
            profileID: context.profileID,
            directoryURL: directory,
            fileURL: destination,
            intent: .upload
        )
        await transferCoordinator.start(enqueuedID, using: service)
        monitor(enqueuedID)
        return enqueuedID
    }

    func startDownload(
        context: MobileDocumentDownloadContext,
        service: any MobileTransferServing
    ) async -> UUID? {
        guard context.intent == .exportCopy || context.intent == .share else { return nil }
        failure = nil
        let taskID = UUID()
        let directory = taskDirectory(taskID)
        let destination = directory.appendingPathComponent(
            Self.safeLeafName(context.fileName),
            isDirectory: false
        )
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            failure = Self.failure(for: error)
            return nil
        }
        let request = MobileDownloadRequest(
            profileID: context.profileID,
            remotePath: context.remotePath,
            temporaryURL: destination,
            stableTarget: context.remotePath
        )
        let enqueuedID = await transferCoordinator.enqueueDownload(request)
        artifactsByTaskID[enqueuedID] = ArtifactRecord(
            taskID: enqueuedID,
            profileID: context.profileID,
            directoryURL: directory,
            fileURL: destination,
            intent: context.intent
        )
        await transferCoordinator.start(enqueuedID, using: service)
        monitor(enqueuedID)
        return enqueuedID
    }

    /// 请求系统面板关闭时只释放当前 artifact；下一项必须等待 SwiftUI 的 onDismiss。
    func requestDismiss(taskID: UUID) {
        guard presentation?.taskID == taskID else { return }
        presentation = nil
        removeArtifact(taskID)
        isAwaitingSystemDismissal = true
    }

    func presentationDidDismiss() {
        guard isAwaitingSystemDismissal else { return }
        isAwaitingSystemDismissal = false
        advancePresentationQueue()
    }

    func clearFailure() {
        failure = nil
    }

    func reportPickerFailure(_ error: Error) {
        failure = Self.failure(for: error)
    }

    func setActiveProfile(_ profileID: UUID?) {
        activeProfileID = profileID
        if let current = presentation, current.profileID != profileID {
            presentation = nil
            removeArtifact(current.taskID)
            isAwaitingSystemDismissal = true
        }
        let staleQueued = presentationQueue.filter {
            artifactsByTaskID[$0]?.profileID != profileID
        }
        presentationQueue.removeAll { staleQueued.contains($0) }
        staleQueued.forEach(removeArtifact)
        if !isAwaitingSystemDismissal {
            advancePresentationQueue()
        }
    }

    /// 连接工作区已经结束，系统面板不会再提供 onDismiss；立即释放本会话拥有的任务与临时文件。
    func resetForDisconnectedWorkspace() {
        activeProfileID = nil
        presentation = nil
        isAwaitingSystemDismissal = false
        failure = nil
        presentationQueue.removeAll()

        let taskIDs = Set(monitorsByTaskID.keys).union(artifactsByTaskID.keys)
        monitorsByTaskID.values.forEach { $0.cancel() }
        monitorsByTaskID.removeAll()
        Array(artifactsByTaskID.keys).forEach(removeArtifact)

        Task {
            for taskID in taskIDs {
                await transferCoordinator.cancel(taskID)
            }
        }
    }

    func ownsArtifact(taskID: UUID) -> Bool {
        artifactsByTaskID[taskID] != nil
    }

    private func monitor(_ taskID: UUID) {
        monitorsByTaskID[taskID]?.cancel()
        monitorsByTaskID[taskID] = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                guard let task = await transferCoordinator.task(id: taskID) else {
                    removeArtifact(taskID)
                    return
                }
                guard task.status.isTerminal else {
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
                await finish(task)
                return
            }
        }
    }

    private func finish(_ task: MobileActivityTask) async {
        monitorsByTaskID[task.id] = nil
        guard let artifact = artifactsByTaskID[task.id] else { return }
        if artifact.intent == .upload {
            cleanup(artifact.directoryURL)
            artifactsByTaskID[task.id] = nil
            await transferCoordinator.disableRetry(task.id)
            if let category = task.failureCategory,
               task.status != .resultNeedsReview {
                failure = MobileDocumentTransferFailure(category: category)
            }
            return
        }
        guard task.status == .succeeded,
              fileManager.fileExists(atPath: artifact.fileURL.path) else {
            if task.status == .failed, let category = task.failureCategory {
                failure = MobileDocumentTransferFailure(category: category)
            }
            removeArtifact(task.id)
            return
        }
        guard activeProfileID == artifact.profileID else {
            // 传输期间切换 NAS 时不跨 Profile 弹出系统面板，也不保留不可见临时文件。
            removeArtifact(task.id)
            return
        }
        presentationQueue.append(task.id)
        advancePresentationQueue()
    }

    private func removeArtifact(_ taskID: UUID) {
        presentationQueue.removeAll { $0 == taskID }
        guard let artifact = artifactsByTaskID.removeValue(forKey: taskID) else { return }
        cleanup(artifact.directoryURL)
    }

    private func advancePresentationQueue() {
        guard presentation == nil, !isAwaitingSystemDismissal else { return }
        while let taskID = presentationQueue.first {
            presentationQueue.removeFirst()
            guard let artifact = artifactsByTaskID[taskID] else { continue }
            guard artifact.profileID == activeProfileID else {
                removeArtifact(taskID)
                continue
            }
            presentation = MobileDocumentPresentation(
                taskID: taskID,
                profileID: artifact.profileID,
                url: artifact.fileURL,
                intent: artifact.intent
            )
            return
        }
    }

    private func cleanup(_ directory: URL) {
        try? fileManager.removeItem(at: directory)
    }

    private func taskDirectory(_ taskID: UUID) -> URL {
        rootURL.appendingPathComponent(taskID.uuidString, isDirectory: true)
    }

    static func safeLeafName(_ proposed: String) -> String {
        let leaf = (proposed as NSString).lastPathComponent
        let filtered = leaf.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != ":"
        }
        let value = String(String.UnicodeScalarView(filtered))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "." || value == ".." ? "file" : value
    }

    private static func join(folder: String, leaf: String) -> String {
        let base = folder.isEmpty ? "/" : folder
        return (base as NSString).appendingPathComponent(leaf)
    }

    private static func failure(for error: Error) -> MobileDocumentTransferFailure {
        if let error = error as? AppError {
            return MobileDocumentTransferFailure(category: error.category)
        }
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain,
           cocoa.code == CocoaError.fileWriteOutOfSpace.rawValue {
            return .localStorageFull
        }
        if error is URLError { return .networkUnavailable }
        return .unknown
    }
}
