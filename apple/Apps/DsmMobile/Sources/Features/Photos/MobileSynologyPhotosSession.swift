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
    let thumbnails = MobilePhotoThumbnailStore(totalCostLimit: 32 * 1_024 * 1_024, concurrencyLimit: 4)
    private(set) var isExporting = false
    private(set) var exportProgress: Double?
    var export: Export?
    var exportError: String?
    @ObservationIgnored private var repository: (any SynologyPhotosServing)?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var exportDirectory: URL?
    @ObservationIgnored private var exportGeneration = UUID()

    func configure(_ repository: (any SynologyPhotosServing)?) {
        deactivate()
        identity = UUID()
        self.repository = repository
        model = SynologyPhotosModel(repository: repository)
    }

    func activate() async {
        model.setModuleEnabled(true)
        await model.loadIfNeeded()
    }

    func deactivate() {
        model.setModuleEnabled(false)
        cancelExport()
        Task { await thumbnails.removeAll() }
    }

    func thumbnail(_ photo: SynologyPhoto) async -> Data? {
        guard model.isModuleEnabled, let repository else { return nil }
        let current = identity
        let key = "\(current)|\(photo.id.profileID)|\(photo.id.space)|\(photo.id.unitID)|\(photo.thumbnail?.unitID ?? 0)|\(photo.thumbnail?.revision ?? "")"
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
