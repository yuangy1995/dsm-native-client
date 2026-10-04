import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoTemporarySharingModel {
    struct Draft: Identifiable {
        let id = UUID()
        let photos: [SynologyPhoto]
        let album: SynologyPhotoCollection?
        let space: SynologyPhotoSpace
        let section: SynologyPhotosSection
    }
    private(set) var draft: Draft?
    private(set) var isCreating = false
    private(set) var error: String?
    var name = ""
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored let sharing: MobilePhotoSharingModel
    init(model: SynologyPhotosModel, sharing: MobilePhotoSharingModel) { self.model = model; self.sharing = sharing }
    var canBegin: Bool {
        model.canStartTemporarySharing && model.managementFeatures.contains(.albums) && model.managementFeatures.contains(.sharing) &&
            model.spaces.contains(.personal) && !model.selectedPhotos.isEmpty && model.selectedPhotos.count <= 100 && model.canAddToAlbum(model.selectedPhotos)
    }
    func begin() {
        guard canBegin else { return }
        clear()
        draft = .init(photos: model.selectedPhotos, album: model.selectedAlbum, space: model.selectedSpace, section: model.section)
    }
    var canCreate: Bool {
        guard let draft else { return false }
        return !isCreating && model.canStartTemporarySharing && model.selectedAlbum == draft.album && model.selectedSpace == draft.space &&
            model.section == draft.section && draft.photos.allSatisfy { model.items.contains($0) } && model.canAddToAlbum(draft.photos) &&
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    func create() {
        guard canCreate, let draft else { return }
        error = nil
        model.submitMutation(.createTemporaryAlbum(name: name.trimmingCharacters(in: .whitespacesAndNewlines), photos: draft.photos))
        isCreating = model.isManaging
        if !isCreating { error = model.managementMessage ?? L10n.string("photos.selectionShare.unavailable") }
    }
    func creationChanged() {
        guard draft != nil, isCreating, !model.isManaging, model.pendingMutationID == nil, sharing.draft == nil else { return }
        if model.preparedTemporaryAlbum != nil { sharing.beginPrepared(); return }
        isCreating = false; error = model.managementMessage ?? L10n.string("photos.selectionShare.unavailable")
    }
    @discardableResult func cancel() -> Bool {
        if let album = model.preparedTemporaryAlbum {
            guard model.stopTemporarySharing(album, keepCopy: false) else { error = model.managementMessage; return false }
        } else if isCreating { model.cancelTemporaryAlbumCreation() }
        clear(); return true
    }
    func clear() { draft = nil; isCreating = false; error = nil; name = "" }
}
