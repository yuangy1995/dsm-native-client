import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoAlbumModel {
    enum Action: String, CaseIterable {
        case create, add, remove, rename, delete, cover
        var title: String {
            switch self {
            case .create: L10n.string("photos.manage.createAlbum")
            case .add: L10n.string("photos.manage.addAlbum")
            case .remove: L10n.string("photos.manage.removeAlbum")
            case .rename: L10n.string("photos.manage.renameAlbum")
            case .delete: L10n.string("photos.manage.deleteAlbum")
            case .cover: L10n.string("photos.manage.cover")
            }
        }
    }
    struct Draft: Identifiable {
        let id = UUID()
        let action: Action
        let photos: [SynologyPhoto]
        let album: SynologyPhotoCollection?
        let space: SynologyPhotoSpace
    }
    private(set) var draft: Draft?
    private(set) var albums: [SynologyPhotoCollection] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var name = ""
    var albumID: Int?
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var loadingTask: Task<Void, Never>?

    init(model: SynologyPhotosModel) { self.model = model }

    func allows(_ action: Action, photos: [SynologyPhoto]? = nil) -> Bool {
        let photos = photos ?? model.selectedPhotos
        guard model.canStartManagementMutation, model.managementFeatures.contains(.albums), photos.count <= 100 else { return false }
        switch action {
        case .create: return photos.isEmpty || model.canAddToAlbum(photos)
        case .add: return !photos.isEmpty && model.canAddToAlbum(photos)
        case .remove: return model.selectedAlbum?.acceptsManualMembers == true && model.canRemoveAlbumPhotos(photos)
        case .rename, .delete:
            return model.selectedAlbum != nil && model.selectedAlbumAccess?.albumID == model.selectedAlbum?.id && model.selectedAlbumAccess?.isOwner == true
        case .cover:
            return photos.count == 1 && model.selectedAlbum != nil && model.selectedAlbumAccess?.albumID == model.selectedAlbum?.id &&
                model.selectedAlbumAccess?.isOwner == true && photos.first?.albumContext?.albumID == model.selectedAlbum?.id
        }
    }

    func begin(_ action: Action, photos: [SynologyPhoto]? = nil) {
        let photos = photos ?? model.selectedPhotos
        guard allows(action, photos: photos) else { return }
        cancel()
        let value = Draft(action: action, photos: photos, album: model.selectedAlbum, space: model.selectedSpace)
        draft = value
        name = action == .rename ? value.album?.name ?? "" : ""
        load()
    }

    private func isCurrent(_ value: Draft) -> Bool {
        draft?.id == value.id && model.isModuleEnabled && model.selectedSpace == value.space && model.selectedAlbum == value.album &&
            value.photos.allSatisfy { model.items.contains($0) }
    }

    var mutation: SynologyPhotosMutation? {
        guard let draft, isCurrent(draft), allows(draft.action, photos: draft.photos), !isLoading, error == nil else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        switch draft.action {
        case .create: return trimmed.isEmpty ? nil : .createAlbum(name: name, photos: draft.photos)
        case .add:
            return albums.first(where: { $0.id == albumID && $0.acceptsManualMembers }).map { .addToAlbum(id: $0.id, photos: draft.photos) }
        case .remove: return draft.album.map { .removeFromAlbum(id: $0.id, photos: draft.photos) }
        case .rename: return draft.album.flatMap { trimmed.isEmpty || name == $0.name ? nil : .renameAlbum(id: $0.id, name: name) }
        case .delete: return draft.album.map { .deleteAlbum(id: $0.id) }
        case .cover: return draft.album.flatMap { album in draft.photos.first.map { .setAlbumCover(id: album.id, photo: $0) } }
        }
    }

    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        error = nil
        guard draft.action == .add else { return }
        isLoading = true
        loadingTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.loadingTask = nil } }
            do {
                let values = try await self.model.managementAlbums().filter(\.acceptsManualMembers)
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.albums = values
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) {
                    self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("photos.manage.failed")
                }
            }
        }
    }

    @discardableResult
    func submit() -> Bool {
        guard let mutation else { error = L10n.string("mobile.photos.album.stale"); return false }
        model.submitMutation(mutation)
        guard model.isManaging else { error = L10n.string("mobile.photos.album.stale"); return false }
        cancel()
        return true
    }

    func cancel() {
        loadingTask?.cancel(); loadingTask = nil
        draft = nil; albums = []; name = ""; albumID = nil; error = nil; isLoading = false
    }
}
