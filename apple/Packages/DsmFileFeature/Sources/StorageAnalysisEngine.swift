import DsmCore
import DsmLocalization
import Foundation

public struct StorageAnalysisShare: Identifiable, Equatable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let usedBytes: Int64
    public let fileCount: Int
    public let unmeasuredFileCount: Int
}

public struct StorageAnalysisCategory: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case photos, videos, audio, documents, archives, noExtension, other
    }
    public var id: String { kind.rawValue }
    public let kind: Kind
    public var name: String {
        switch kind {
        case .photos: L10n.string("ui.d24c10d37db0feea")
        case .videos: L10n.string("ui.c20f7618d330a854")
        case .audio: L10n.string("ui.296c632ec857a0ba")
        case .documents: L10n.string("ui.2687ccdbb1d2288a")
        case .archives: L10n.string("ui.e3a3e47360e24f0b")
        case .noExtension: L10n.string("ui.905ace3177aa8af8")
        case .other: L10n.string("ui.d2909f1647e7c891")
        }
    }
    public let usedBytes: Int64
    public let fileCount: Int
    public let unmeasuredFileCount: Int
}

public struct StorageAnalysisOwner: Identifiable, Equatable, Sendable {
    public var id: String { ownerName.map { "owner:" + $0 } ?? "unknown" }
    public let ownerName: String?
    public var name: String { ownerName ?? L10n.string("ui.c8b0ccfade8f4591") }
    public let usedBytes: Int64
    public let fileCount: Int
    public let unmeasuredFileCount: Int
}

public struct StorageDuplicateGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let sizeBytes: Int64
    public let files: [FileItem]

    public var reclaimableBytes: Int64 {
        Int64(max(files.count - 1, 0)) * sizeBytes
    }
}

public struct StorageAnalysisSnapshot: Equatable, Sendable {
    public let generatedAt: Date
    public let shares: [StorageAnalysisShare]
    public let categories: [StorageAnalysisCategory]
    public let owners: [StorageAnalysisOwner]
    public let largeFiles: [FileItem]
    public let recentlyModifiedFiles: [FileItem]
    public let leastRecentlyAccessedFiles: [FileItem]
    public let duplicateGroups: [StorageDuplicateGroup]
    public let scannedFileCount: Int
    public let scannedBytes: Int64
    public let unmeasuredFileCount: Int
    public let failedDuplicateChecks: Int
    public let duplicateCheckWasLimited: Bool
    public let duplicateCheckUnavailable: Bool
}

public struct StorageAnalysisProgress: Equatable, Sendable {
    public let title: String
    public let completed: Int
    public let total: Int

    public init(title: String, completed: Int, total: Int) {
        self.title = title; self.completed = completed; self.total = total
    }

    public var fraction: Double? {
        guard total > 0 else { return nil }
        return min(max(Double(completed) / Double(total), 0), 1)
    }
}

public actor StorageAnalysisEngine {
    private struct Usage {
        var bytes: Int64 = 0
        var count = 0
        var unmeasured = 0

        mutating func add(_ bytes: Int64?) {
            count += 1
            guard let bytes, bytes >= 0 else { unmeasured += 1; return }
            self.bytes += bytes
        }
    }

    private let repository: any FileRepository
    private let maximumDuplicateCandidates = 400

    public init(repository: any FileRepository) {
        self.repository = repository
    }

    public func analyze(
        progress: @escaping @MainActor @Sendable (StorageAnalysisProgress) -> Void
    ) async throws -> StorageAnalysisSnapshot {
        var shares: [FileItem] = []
        var offset = 0
        repeat {
            try Task.checkCancellation()
            let page = try await repository.listShares(offset: offset, limit: 200)
            guard !page.hasMore || !page.items.isEmpty else {
                throw AppError(category: .invalidResponse, isRetryable: true,
                               safeUserMessage: L10n.string("ui.ebf27fffde487252"))
            }
            shares.append(
                contentsOf: page.items.filter {
                    guard !$0.isRecyclePath else { return false }
                    guard let mountType = $0.mountPointType?.lowercased(), !mountType.isEmpty else {
                        return true
                    }
                    return mountType == "normal"
                }
            )
            offset += page.items.count
            if !page.hasMore || page.items.isEmpty { break }
        } while true

        var allFiles: [FileItem] = []
        var shareRows: [StorageAnalysisShare] = []
        for (index, share) in shares.enumerated() {
            try Task.checkCancellation()
            await progress(
                StorageAnalysisProgress(
                    title: L10n.string("ui.8cbbfd3cde8b7d20", String(describing: share.name)),
                    completed: index,
                    total: shares.count
                )
            )
            let files = try await repository.search(folderPath: share.path, query: "*")
                .filter { $0.kind == .file && !$0.isRecyclePath }
            let usedBytes = files.reduce(Int64(0)) { $0 + max($1.sizeBytes ?? 0, 0) }
            shareRows.append(
                StorageAnalysisShare(
                    name: share.name,
                    path: share.path,
                    usedBytes: usedBytes,
                    fileCount: files.count,
                    unmeasuredFileCount: files.filter { $0.sizeBytes == nil || $0.sizeBytes! < 0 }.count
                )
            )
            allFiles.append(contentsOf: files)
        }

        await progress(
            StorageAnalysisProgress(
                title: L10n.string("ui.428cdf164eefc170"),
                completed: 0,
                total: 1
            )
        )
        let duplicateResult = try await duplicateGroups(in: allFiles, progress: progress)
        try Task.checkCancellation()

        var categories: [StorageAnalysisCategory.Kind: Usage] = [:]
        var owners: [String?: Usage] = [:]
        for file in allFiles {
            let size = file.sizeBytes
            categories[Self.category(for: file), default: Usage()].add(size)
            owners[file.owner?.isEmpty == false ? file.owner : nil, default: Usage()].add(size)
        }

        let categoryRows = categories.map {
            StorageAnalysisCategory(kind: $0.key, usedBytes: $0.value.bytes, fileCount: $0.value.count, unmeasuredFileCount: $0.value.unmeasured)
        }
        .sorted { $0.usedBytes > $1.usedBytes }
        let ownerRows = owners.map {
            StorageAnalysisOwner(ownerName: $0.key, usedBytes: $0.value.bytes, fileCount: $0.value.count, unmeasuredFileCount: $0.value.unmeasured)
        }
        .sorted { $0.usedBytes > $1.usedBytes }
        let largeFiles = Array(
            allFiles.sorted { ($0.sizeBytes ?? 0) > ($1.sizeBytes ?? 0) }.prefix(200)
        )
        let recentFiles = Array(
            allFiles
                .filter { $0.times?.modifiedAt != nil }
                .sorted { $0.times!.modifiedAt! > $1.times!.modifiedAt! }
                .prefix(200)
        )
        let oldAccessFiles = Array(
            allFiles
                .filter { $0.times?.accessedAt != nil }
                .sorted { $0.times!.accessedAt! < $1.times!.accessedAt! }
                .prefix(200)
        )

        await progress(
            StorageAnalysisProgress(
                title: L10n.string("ui.0ff9cc7e060ea234"),
                completed: 1,
                total: 1
            )
        )
        return StorageAnalysisSnapshot(
            generatedAt: Date(),
            shares: shareRows.sorted { $0.usedBytes > $1.usedBytes },
            categories: categoryRows,
            owners: ownerRows,
            largeFiles: largeFiles,
            recentlyModifiedFiles: recentFiles,
            leastRecentlyAccessedFiles: oldAccessFiles,
            duplicateGroups: duplicateResult.groups,
            scannedFileCount: allFiles.count,
            scannedBytes: allFiles.reduce(Int64(0)) { $0 + max($1.sizeBytes ?? 0, 0) },
            unmeasuredFileCount: allFiles.filter { $0.sizeBytes == nil || $0.sizeBytes! < 0 }.count,
            failedDuplicateChecks: duplicateResult.failedChecks,
            duplicateCheckWasLimited: duplicateResult.wasLimited,
            duplicateCheckUnavailable: duplicateResult.wasUnavailable
        )
    }

    private func duplicateGroups(
        in files: [FileItem],
        progress: @escaping @MainActor @Sendable (StorageAnalysisProgress) -> Void
    ) async throws -> (groups: [StorageDuplicateGroup], wasLimited: Bool, wasUnavailable: Bool, failedChecks: Int) {
        let sameSizeGroups = Dictionary(
            grouping: files.filter { ($0.sizeBytes ?? 0) > 0 },
            by: { $0.sizeBytes! }
        )
        .values
        .filter { $0.count > 1 }
        .sorted { ($0.first?.sizeBytes ?? 0) > ($1.first?.sizeBytes ?? 0) }
        let allCandidates = sameSizeGroups.flatMap { $0 }
        let candidates = Array(allCandidates.prefix(maximumDuplicateCandidates))
        var checksums: [String: [FileItem]] = [:]
        var unavailable = false
        var failedChecks = 0

        for (index, file) in candidates.enumerated() {
            try Task.checkCancellation()
            await progress(
                StorageAnalysisProgress(
                    title: L10n.string("ui.428cdf164eefc170"),
                    completed: index,
                    total: candidates.count
                )
            )
            do {
                let checksum = try await repository.fileMD5(remotePath: file.path)
                checksums["\(file.sizeBytes ?? 0):\(checksum)", default: []].append(file)
            } catch let error as AppError where error.category == .apiUnavailable {
                unavailable = true
                break
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedChecks += 1
                continue
            }
        }

        let groups = checksums.compactMap { key, files -> StorageDuplicateGroup? in
            guard files.count > 1 else { return nil }
            return StorageDuplicateGroup(
                id: key,
                sizeBytes: files.first?.sizeBytes ?? 0,
                files: files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            )
        }
        .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
        return (groups, allCandidates.count > candidates.count, unavailable, failedChecks)
    }

    private static func category(for file: FileItem) -> StorageAnalysisCategory.Kind {
        let ext = file.fileExtension?.lowercased() ?? ""
        if ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "raw"].contains(ext) {
            return .photos
        }
        if ["mp4", "m4v", "mov", "avi", "mkv", "webm", "mpeg", "mpg", "ts", "m2ts"].contains(ext) {
            return .videos
        }
        if ["mp3", "m4a", "aac", "flac", "wav", "ogg", "ape", "alac"].contains(ext) {
            return .audio
        }
        if ["pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "pages", "numbers", "key"].contains(ext) {
            return .documents
        }
        if ["zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso"].contains(ext) {
            return .archives
        }
        return ext.isEmpty ? .noExtension : .other
    }
}
