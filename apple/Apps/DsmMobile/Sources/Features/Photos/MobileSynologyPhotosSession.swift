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
        let url: URL
        let sharing: Bool
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

    func configure(_ repository: (any SynologyPhotosServing)?, uploadStorage: MobilePhotoUploadStorage? = nil,
                   reviewDelay: @escaping @Sendable (Double) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        deactivate()
        uploadRecoveryStore?.suspendWrites()
        albumRecoveryStore?.suspendWrites()
        backgroundRecoveryStore?.suspendWrites()
        deletionRecoveryStore?.suspendWrites()
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
        guard model.isModuleEnabled, !isExporting, let repository else { return }
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
            do {
                // 服务端文件名只能是单个名称，绝不用于选择任意本地路径。
                guard !photo.filename.isEmpty, photo.filename != ".", photo.filename != "..",
                      !photo.filename.contains("/"), !photo.filename.contains("\\"),
                      !photo.filename.contains("\0") else { throw CocoaError(.fileWriteInvalidFileName) }
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("synology-photos-\(request.uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false,
                    attributes: [.protectionKey: FileProtectionType.completeUnlessOpen])
                directory = folder
                let destination = folder.appendingPathComponent(photo.filename)
                try await repository.downloadOriginal(photo, to: destination) { [weak self] done, total in
                    Task { @MainActor in
                        guard let self, self.identity == current, self.exportGeneration == request else { return }
                        self.exportProgress = total.flatMap { $0 > 0 ? min(1, Double(done) / Double($0)) : nil }
                    }
                }
                try Task.checkCancellation()
                guard self.identity == current, self.exportGeneration == request, self.model.isModuleEnabled else {
                    throw CancellationError()
                }
                self.exportDirectory = folder
                self.export = Export(id: request, url: destination, sharing: sharing)
                directory = nil
            } catch {
                if self.identity == current, self.exportGeneration == request, !(error is CancellationError) {
                    self.exportError = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.media.saveFailed")
                }
            }
            if let directory { try? FileManager.default.removeItem(at: directory) }
        }
    }

    func cancelExport() {
        exportGeneration = UUID()
        exportTask?.cancel()
        exportTask = nil
        isExporting = false
        exportProgress = nil
        finishExport()
    }

    func finishExport() {
        export = nil
        if let exportDirectory { try? FileManager.default.removeItem(at: exportDirectory) }
        exportDirectory = nil
    }
}
