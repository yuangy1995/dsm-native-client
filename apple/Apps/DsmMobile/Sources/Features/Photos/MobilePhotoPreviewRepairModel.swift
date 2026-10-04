import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

/// 未完成列表只读取；用户明确继续后才复用共享预览转换流程。
@MainActor
@Observable
final class MobilePhotoPreviewRepairModel {
    var isPresented = false
    private(set) var space: SynologyPhotoSpace = .personal
    private(set) var photos: [SynologyPhoto] = []
    private(set) var selected: Set<SynologyPhotoID> = []
    var search = ""
    private(set) var isLoading = false
    private(set) var error: String?
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: SynologyPhotosModel) { self.model = model }
    var canOpen: Bool { model.isModuleEnabled && !model.spaces.isEmpty && model.managementFeatures.contains(.previewRegeneration) }
    var visiblePhotos: [SynologyPhoto] { search.isEmpty ? photos : photos.filter { $0.filename.localizedStandardContains(search) } }
    var canResume: Bool {
        canOpen && isPresented && !isLoading && error == nil && !selected.isEmpty && selected.count <= 100 &&
        model.canStartManagementMutation && selected.isSubset(of: Set(photos.map(\.id)))
    }
    func canRegenerate(_ photos: [SynologyPhoto], fromPreview: Bool = false) -> Bool {
        model.canStartManagementMutation && photos.count <= 100 && model.canRegeneratePreviews(photos, fromPreview: fromPreview) &&
        Set(photos.map(\.id)).count == photos.count
    }
    @discardableResult func regenerate(_ photos: [SynologyPhoto], fromPreview: Bool = false) -> Bool {
        guard canRegenerate(photos, fromPreview: fromPreview) else { return false }
        if fromPreview { guard photos.count == 1, model.previewPhoto == photos.first else { return false } }
        else { guard photos.allSatisfy({ model.items.contains($0) }) else { return false } }
        model.submitMutation(.regeneratePreviews(photos))
        return model.isManaging
    }
    func begin() {
        guard canOpen else { return }
        cancel(); space = model.spaces.contains(model.selectedSpace) ? model.selectedSpace : model.spaces[0]
        isPresented = true; load()
    }
    func selectSpace(_ value: SynologyPhotoSpace) {
        guard isPresented, canOpen, model.spaces.contains(value), space != value else { return }
        task?.cancel(); generation = UUID(); space = value; search = ""; load()
    }
    func load() {
        guard isPresented, canOpen else { return }
        task?.cancel(); generation = UUID(); let current = generation, requestedSpace = space
        photos = []; selected = []; error = nil; isLoading = true
        task = Task { [weak self] in
            guard let self else { return }
            defer { if current == self.generation { self.isLoading = false; self.task = nil } }
            do {
                let values = try await self.model.pendingPreviewRegenerations(in: requestedSpace)
                guard current == self.generation, !Task.isCancelled, self.isPresented, self.canOpen else { return }
                self.photos = values
                self.selected = Set(values.prefix(100).map(\.id))
            } catch {
                if current == self.generation, !Task.isCancelled, self.isPresented, self.canOpen {
                    self.error = L10n.string("photos.preview.recovery.failed")
                }
            }
        }
    }
    func toggle(_ photo: SynologyPhoto) {
        guard isPresented, !isLoading, error == nil, photos.contains(photo) else { return }
        if selected.contains(photo.id) { selected.remove(photo.id) }
        else if selected.count < 100 { selected.insert(photo.id) }
    }
    func selectVisible() { guard isPresented, !isLoading, error == nil else { return }; selected = Set(visiblePhotos.prefix(100).map(\.id)) }
    func clearSelection() { selected = [] }
    @discardableResult func resume() -> Bool {
        guard canResume else { return false }
        model.submitMutation(.regeneratePreviews(photos.filter { selected.contains($0.id) }, resuming: true))
        guard model.isManaging else { return false }
        cancel(); return true
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; isPresented = false
        photos = []; selected = []; search = ""; isLoading = false; error = nil
    }
}
