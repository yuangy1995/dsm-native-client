import DsmPhotosFeature
import DsmCore
import DsmLocalization
import Foundation
import Observation

/// 新照片工作区的会话与系统导出所有者。旧文件路径图库不能进入此边界。
@MainActor
@Observable
final class MobileSynologyPhotosSession {
    struct Export: Identifiable {
        let id: UUID
        let urls: [URL]
        let sharing: Bool
        var url: URL { urls[0] }
    }

    private(set) var identity = UUID()
    private(set) var model = SynologyPhotosModel()
    private(set) var uploads: MobilePhotoUploadImportModel?
    private(set) var albums: MobilePhotoAlbumModel?
    private(set) var editor: MobilePhotoEditModel?
    private(set) var folders: MobilePhotoFolderModel?
    private(set) var sharing: MobilePhotoSharingModel?
    private(set) var folderSharing: MobilePhotoFolderSharingModel?
    private(set) var tasks: MobilePhotoTasksModel?
    private(set) var preferences: MobilePhotoPreferencesModel?
    private(set) var administration: MobilePhotoAdministrationModel?
    private(set) var recognition: MobilePhotoRecognitionModel?
    private(set) var faces: MobilePhotoFaceModel?
    private(set) var previewRepair: MobilePhotoPreviewRepairModel?
    private(set) var temporarySharing: MobilePhotoTemporarySharingModel?
    private(set) var conditions: MobilePhotoConditionModel?
    private(set) var requests: MobilePhotoRequestModel?
    let thumbnails = MobilePhotoThumbnailStore(totalCostLimit: 32 * 1_024 * 1_024, concurrencyLimit: 4)
    private(set) var isExporting = false
    private(set) var exportProgress: Double?
    var export: Export?
    var exportError: String?
    @ObservationIgnored private var repository: (any SynologyPhotosServing)?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var exportDirectory: URL?
    @ObservationIgnored private var exportGeneration = UUID()
    @ObservationIgnored private var uploadRecoveryStore: PhotoUploadRecoveryStore?
    @ObservationIgnored private var hasCleanedUploadDrafts = false
    @ObservationIgnored private var albumRecoveryStore: PhotoAlbumRecoveryStore?
    @ObservationIgnored private var backgroundRecoveryStore: PhotoAlbumRecoveryStore?
    @ObservationIgnored private var deletionRecoveryStore: PhotoDeletionRecoveryStore?
    @ObservationIgnored private var similarRecoveryStore: PhotoSimilarRecoveryStore?
    private static var hasCleanedExportFiles = false

    func configure(_ repository: (any SynologyPhotosServing)?, uploadStorage: MobilePhotoUploadStorage? = nil,
                   reviewDelay: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        deactivate()
        if !Self.hasCleanedExportFiles {
            // 系统终止时无法执行 defer；重新打开照片后只清理本应用随机命名的旧副本。
            Self.hasCleanedExportFiles = (try? Self.removeAbandonedExports(in: FileManager.default.temporaryDirectory)) != nil
        }
        uploadRecoveryStore?.suspendWrites()
        albumRecoveryStore?.suspendWrites()
        backgroundRecoveryStore?.suspendWrites()
        deletionRecoveryStore?.suspendWrites()
        similarRecoveryStore?.suspendWrites()
        identity = UUID()
        self.repository = repository
        model = SynologyPhotosModel(repository: repository, deletionReviewDelay: reviewDelay)
        uploadRecoveryStore = uploadStorage?.recoveryStore()
        model.configureUploadRecovery(uploadRecoveryStore)
        albumRecoveryStore = uploadStorage.map { PhotoAlbumRecoveryStore(url: $0.recordURL.deletingPathExtension().appendingPathComponent("Albums/pending-v1.json")) }
        model.configureAlbumRecovery(albumRecoveryStore)
        backgroundRecoveryStore = uploadStorage.map { PhotoAlbumRecoveryStore(url: $0.recordURL.deletingPathExtension().appendingPathComponent("Albums/tasks-v1.json")) }
        model.configureBackgroundRecovery(backgroundRecoveryStore)
        deletionRecoveryStore = uploadStorage.map { PhotoDeletionRecoveryStore(url: $0.recordURL.deletingPathExtension().appendingPathComponent("Deletion/pending-v1.json")) }
        model.configureDeletionRecovery(deletionRecoveryStore)
        similarRecoveryStore = uploadStorage.map { PhotoSimilarRecoveryStore(url: $0.recordURL.deletingPathExtension().appendingPathComponent("Similar/batch-v1.json")) }
        model.configureSimilarRecovery(similarRecoveryStore)
        uploads = uploadStorage.map { MobilePhotoUploadImportModel(model: model, storage: $0) }
        albums = repository == nil ? nil : MobilePhotoAlbumModel(model: model)
        editor = repository == nil ? nil : MobilePhotoEditModel(model: model)
        folders = repository == nil ? nil : MobilePhotoFolderModel(model: model)
        sharing = repository == nil ? nil : MobilePhotoSharingModel(model: model)
        folderSharing = repository == nil ? nil : MobilePhotoFolderSharingModel(model: model)
        tasks = repository == nil ? nil : MobilePhotoTasksModel(model: model)
        preferences = repository == nil ? nil : MobilePhotoPreferencesModel(model: model)
        administration = repository == nil ? nil : MobilePhotoAdministrationModel(model: model)
        recognition = repository == nil ? nil : MobilePhotoRecognitionModel(model: model)
        faces = repository == nil ? nil : MobilePhotoFaceModel(model: model)
        previewRepair = repository == nil ? nil : MobilePhotoPreviewRepairModel(model: model)
        temporarySharing = sharing.map { MobilePhotoTemporarySharingModel(model: model, sharing: $0) }
        conditions = repository == nil ? nil : MobilePhotoConditionModel(model: model)
        requests = repository == nil ? nil : MobilePhotoRequestModel(model: model)
        hasCleanedUploadDrafts = false
    }

    func activate() async {
        model.setModuleEnabled(true)
        await model.loadIfNeeded()
        if model.isModuleEnabled, model.hasLoaded, model.managementFeatures.contains(.automaticPreview) || model.hasPendingAutomaticPreview { model.startAutomaticPreviews() }
        if !hasCleanedUploadDrafts, model.hasLoaded, !model.isLoading, model.errorMessage == nil,
           model.uploadPersistenceError == nil, let uploads, uploads.draftID == nil {
            try? uploads.storage.removeUnreferencedCopies(keeping: model.uploadQueue.map(\.file))
            hasCleanedUploadDrafts = true
        }
    }

    func deactivate() {
        uploads?.cancel()
        albums?.cancel()
        editor?.cancel()
        folders?.cancel()
        sharing?.cancel()
        folderSharing?.cancel()
        tasks?.cancel()
        preferences?.cancel()
        administration?.cancel()
        recognition?.cancel()
        faces?.cancel()
        previewRepair?.cancel()
        temporarySharing?.clear()
        requests?.cancel()
        conditions?.cancel()
        model.setModuleEnabled(false)
        cancelExport()
        Task { await thumbnails.removeAll() }
    }

    func thumbnail(_ photo: SynologyPhoto) async -> Data? {
        guard model.isModuleEnabled, let repository else { return nil }
        let current = identity
        let key = "\(current)|\(photo.id.profileID)|\(photo.id.space)|\(photo.id.unitID)|\(photo.thumbnail?.unitID ?? 0)|\(photo.thumbnail?.revision ?? "")|\(model.automaticPreviewRevision(for: photo))"
        let data = await thumbnails.data(for: key, namespace: current.uuidString, priority: .visible) {
            try await repository.thumbnail(for: photo)
        }
        guard current == identity, model.isModuleEnabled, !Task.isCancelled else { return nil }
        return data
    }

    func exportOriginal(_ photo: SynologyPhoto, sharing: Bool = false) {
        exportPhotos([photo], format: .original, sharing: sharing)
    }

    func canExport(_ photos: [SynologyPhoto], format: SynologyPhotoDownloadFormat = .original, includingSimilarMembers: Bool = false) -> Bool {
        guard model.isModuleEnabled, !isExporting, !photos.isEmpty, photos.allSatisfy(model.canDownload) else { return false }
        return format != .originalSizeJPEG || (!includingSimilarMembers && photos.count == 1 && photos.allSatisfy(model.canDownloadOriginalSizeJPEG))
    }

    func exportSelection(format: SynologyPhotoDownloadFormat, sharing: Bool = false) {
        if let target = model.selectedArchive {
            exportArchive(target, format: format, name: L10n.string("photos.download.defaultName"), sharing: sharing)
        } else {
            exportPhotos(model.selectedPhotos, format: format, sharing: sharing, includingSimilarMembers: model.selectedCategory == .similar)
        }
    }

    func exportPhotos(_ photos: [SynologyPhoto], format: SynologyPhotoDownloadFormat, sharing: Bool = false, includingSimilarMembers: Bool = false) {
        guard canExport(photos, format: format, includingSimilarMembers: includingSimilarMembers) else { return }
        beginExport(.photos(photos, includingSimilarMembers: includingSimilarMembers), format: format, sharing: sharing)
    }

    func exportArchive(_ target: SynologyPhotoArchiveTarget, format: SynologyPhotoDownloadFormat, name: String, sharing: Bool = false) {
        guard model.isModuleEnabled, !isExporting, format != .originalSizeJPEG, model.canDownloadArchive(target) else { return }
        beginExport(.archive(target, name: name), format: format, sharing: sharing)
    }

    private enum ExportSource {
        case photos([SynologyPhoto], includingSimilarMembers: Bool)
        case archive(SynologyPhotoArchiveTarget, name: String)
    }

    private func beginExport(_ source: ExportSource, format: SynologyPhotoDownloadFormat, sharing: Bool) {
        guard let repository else { return }
        finishExport()
        let request = UUID()
        let current = identity
        exportGeneration = request
        isExporting = true
        exportError = nil
        exportProgress = nil
        exportTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.exportGeneration == request { self.isExporting = false } }
            var directory: URL?
            var files: [URL] = []
            var requestedCount = 0
            var originalCount = 0
            do {
                try self.checkExport(request: request, identity: current)
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("synology-photos-\(request.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
                directory = folder
                var protectedFolder = folder
                var values = URLResourceValues(); values.isExcludedFromBackup = true
                try protectedFolder.setResourceValues(values)
                switch source {
                case .archive(let target, let name):
                    requestedCount = 1
                    let safeName = Self.isExportName(name) ? name : L10n.string("photos.download.defaultName")
                    let destination = folder.appendingPathComponent(safeName + ".zip")
                    try await repository.downloadArchive(target, format: format, to: destination,
                        progress: self.exportProgressHandler(request: request, identity: current, completed: 0, count: 1))
                    try self.checkExport(request: request, identity: current)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: destination.path)
                    files.append(destination)
                case .photos(let requested, let includingSimilarMembers):
                    var targets: [SynologyPhoto] = []
                    var seen: Set<SynologyPhotoID> = []
                    for representative in requested {
                        try self.checkExport(request: request, identity: current)
                        let members = includingSimilarMembers ? try await repository.similarPhotos(for: representative).photos : [representative]
                        try self.checkExport(request: request, identity: current)
                        for photo in members where seen.insert(photo.id).inserted { targets.append(photo) }
                    }
                    requestedCount = targets.count
                    guard !targets.isEmpty, targets.allSatisfy(self.model.canDownload) else { throw CocoaError(.fileReadNoPermission) }
                    // 先检查整批名称；任何服务端名称都不能选择本地目录。
                    guard targets.allSatisfy({ Self.isExportName($0.filename) }) else { throw CocoaError(.fileWriteInvalidFileName) }
                    for photo in targets {
                        try self.checkExport(request: request, identity: current)
                        let staging = folder.appendingPathComponent(UUID().uuidString + ".partial")
                        defer { try? FileManager.default.removeItem(at: staging) }
                        let actual = try await repository.download(photo, format: format, to: staging,
                            progress: self.exportProgressHandler(request: request, identity: current, completed: files.count, count: targets.count))
                        try self.checkExport(request: request, identity: current)
                        let name = actual == .original ? photo.filename : (photo.filename as NSString).deletingPathExtension + ".jpg"
                        let destination = Self.uniqueExportURL(name: name, directory: folder)
                        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUnlessOpen], ofItemAtPath: staging.path)
                        try FileManager.default.moveItem(at: staging, to: destination)
                        files.append(destination)
                        if format == .optimizedJPEG && actual == .original { originalCount += 1 }
                    }
                }
                if originalCount > 0 { self.exportError = L10n.string("mobile.photos.export.originals", originalCount) }
            } catch {
                if self.identity == current, self.exportGeneration == request, self.model.isModuleEnabled, !Task.isCancelled, !(error is CancellationError) {
                    self.exportError = files.isEmpty ? ((error as? AppError)?.safeUserMessage ?? L10n.string("mobile.photos.export.failed")) :
                        L10n.string("mobile.photos.export.partial", files.count, requestedCount)
                }
            }
            if !files.isEmpty, self.identity == current, self.exportGeneration == request, self.model.isModuleEnabled, !Task.isCancelled {
                self.exportDirectory = directory
                self.export = Export(id: request, urls: files, sharing: sharing)
                directory = nil
            }
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    private func checkExport(request: UUID, identity: UUID) throws {
        try Task.checkCancellation()
        guard self.identity == identity, exportGeneration == request, model.isModuleEnabled else { throw CancellationError() }
    }

    private func exportProgressHandler(request: UUID, identity: UUID, completed: Int, count: Int) -> FileTransferProgress {
        { [weak self] done, total in
            Task { @MainActor in
                guard let self, self.identity == identity, self.exportGeneration == request, self.isExporting else { return }
                self.exportProgress = total.flatMap { $0 > 0 ? (Double(completed) + min(1, max(0, Double(done) / Double($0)))) / Double(count) : nil }
            }
        }
    }

    private static func isExportName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }

    private static func uniqueExportURL(name: String, directory: URL) -> URL {
        var result = directory.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var suffix = 1
        while FileManager.default.fileExists(atPath: result.path) {
            result = directory.appendingPathComponent("\(base) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)"))
            suffix += 1
        }
        return result
    }

    func cancelExport() {
        exportGeneration = UUID()
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
        exportProgress = nil
        exportError = nil
        finishExport()
    }

    func finishExport(id: UUID? = nil) {
        if let id, id != exportGeneration { return }
        export = nil
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
    }

    static func removeAbandonedExports(in directory: URL) throws {
        let prefix = "synology-photos-"
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            guard child.lastPathComponent.hasPrefix(prefix), UUID(uuidString: String(child.lastPathComponent.dropFirst(prefix.count))) != nil else { continue }
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: child)
        }
    }
}
