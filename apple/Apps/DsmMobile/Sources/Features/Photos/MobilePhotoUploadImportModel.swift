import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoUploadImportModel {
    struct Destination: Equatable {
        let space: SynologyPhotoSpace
        let album: SynologyPhotoCollection?
        let folder: SynologyPhotoCollection?
    }
    private(set) var draftID: UUID?
    private(set) var destination: Destination?
    private(set) var files: [PhotoUploadFile] = []
    private(set) var isPreparing = false
    private(set) var skippedCount = 0
    private(set) var includesDirectory = false
    var preservesDirectories = true
    var duplicate = SynologyPhotoDuplicateSettings.Upload.rename
    var error: String?
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored let storage: MobilePhotoUploadStorage
    @ObservationIgnored private var preparationTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    #if DEBUG
    var fixtureSources: [URL] = []
    #endif

    init(model: SynologyPhotosModel, storage: MobilePhotoUploadStorage) {
        self.model = model; self.storage = storage
    }

    private var currentDestination: Destination {
        .init(space: model.selectedSpace, album: model.selectedAlbum,
              folder: model.section == .folders ? model.folderHistory.last : nil)
    }
    var canBegin: Bool {
        model.isModuleEnabled && model.hasLoaded && model.canUploadPhotos &&
        (model.managementFeatures.contains(.upload) || model.uploadsDirectlyToAlbum(model.selectedAlbum, space: model.selectedSpace)) &&
        !model.isLoading && !model.isManaging &&
        !model.isDeleting && !model.isCheckingDeletion && model.pendingMutationID == nil && model.uploadPersistenceError == nil
    }
    var canSubmit: Bool {
        canBegin && draftID != nil && destination == currentDestination && !isPreparing && !files.isEmpty &&
        (!includesDirectory || !preservesDirectories || model.managementFeatures.contains(.folders))
    }

    func begin() {
        guard canBegin else { return }
        cancel()
        draftID = UUID(); destination = currentDestination
        duplicate = .rename; preservesDirectories = true
        #if DEBUG
        if !fixtureSources.isEmpty, let id = draftID { prepareFiles(fixtureSources, draftID: id) }
        #endif
    }

    func prepareFiles(_ urls: [URL], draftID: UUID) {
        prepare(draftID: draftID) { [storage] in
            try await Self.copy(urls, storage: storage)
        }
    }

    func preparePhotos(_ items: [any MobilePhotosPickerItemServing], draftID: UUID) {
        prepare(draftID: draftID) { [storage] in
            var artifacts: [MobilePhotosPickerArtifact] = []
            defer { artifacts.forEach { $0.release() } }
            for item in items {
                try Task.checkCancellation()
                artifacts.append(try await item.loadArtifact())
            }
            let urls = artifacts.map(\.url)
            return try await Self.copy(urls, storage: storage)
        }
    }

    private nonisolated static func copy(_ urls: [URL], storage: MobilePhotoUploadStorage) async throws -> PhotoUploadPreparation {
        let task = Task.detached(priority: .userInitiated) { try storage.prepare(urls) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func prepare(draftID: UUID, operation: @escaping @Sendable () async throws -> PhotoUploadPreparation) {
        guard self.draftID == draftID, canBegin, destination == currentDestination, !isPreparing else { return }
        let request = UUID(); generation = request
        isPreparing = true; error = nil
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.isPreparing = false; self.preparationTask = nil } }
            do {
                let prepared = try await operation()
                guard !Task.isCancelled, self.generation == request, self.draftID == draftID,
                      self.model.isModuleEnabled, self.destination == self.currentDestination else {
                    self.storage.remove(prepared.files); return
                }
                self.storage.remove(self.files)
                self.files = prepared.files; self.skippedCount = prepared.skippedCount
                self.includesDirectory = prepared.includesDirectory
                if self.files.isEmpty { self.error = L10n.string("photos.upload.noMedia") }
            } catch {
                if !Task.isCancelled, self.generation == request {
                    self.error = L10n.string("mobile.photos.upload.prepareFailed")
                }
            }
        }
    }

    @discardableResult
    func submit() -> Bool {
        guard canSubmit, let destination else { return false }
        let ids = Set(files.map(\.id))
        model.enqueueUploads(files, album: destination.album, folder: destination.folder,
            preserveDirectories: includesDirectory && preservesDirectories,
            space: destination.space, duplicate: duplicate)
        guard ids.isSubset(of: Set(model.uploadQueue.map(\.id))) else { return false }
        // 落盘失败仍由队列持有副本和恢复入口，关闭表单不能删除这些文件。
        files = []; cancel()
        return true
    }

    func cancel() {
        generation = UUID(); preparationTask?.cancel(); preparationTask = nil
        storage.remove(files); files = []; draftID = nil; destination = nil
        skippedCount = 0; includesDirectory = false; isPreparing = false; error = nil
    }

    func clear(_ id: UUID) {
        guard let entry = model.uploadQueue.first(where: { $0.id == id }), model.canClearUpload(id) else { return }
        model.clearUpload(id)
        if model.uploadPersistenceError == nil, !model.uploadQueue.contains(where: { $0.id == id }) { storage.remove([entry.file]) }
    }

    func reselect(_ id: UUID, url: URL) {
        guard model.isModuleEnabled, !isPreparing, !model.isManaging, model.pendingMutationID == nil,
              let old = model.uploadQueue.first(where: { $0.id == id }), old.uploadedPhoto == nil,
              [.failed, .cancelled].contains(old.state) else { return }
        let request = UUID(); generation = request; isPreparing = true; error = nil
        preparationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == request { self.isPreparing = false; self.preparationTask = nil } }
            do {
                let prepared = try await Self.copy([url], storage: self.storage)
                guard self.generation == request, !Task.isCancelled, self.model.isModuleEnabled,
                      prepared.files.count == 1, let file = prepared.files.first else {
                    self.storage.remove(prepared.files); return
                }
                self.model.reselectUploadSource(id, url: file.url)
                if self.model.uploadQueue.first(where: { $0.id == id })?.file.url == file.url {
                    if self.model.uploadPersistenceError == nil { self.storage.remove([old.file]) }
                } else { self.storage.remove(prepared.files) }
            } catch {
                if self.generation == request, !Task.isCancelled { self.error = L10n.string("mobile.photos.upload.prepareFailed") }
            }
        }
    }
}
