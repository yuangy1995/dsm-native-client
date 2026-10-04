import CoreGraphics
import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoFaceModel {
    struct Draft: Identifiable { let id = UUID(); let photo: SynologyPhoto; let data: Data }
    private(set) var draft: Draft?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var saveError: String?
    private(set) var image: CGImage?
    private(set) var faces: [PhotoFaceDraft] = []
    private(set) var people: [SynologyPhotoCollection] = []
    var selectedID: String?
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: SynologyPhotosModel) { self.model = model }
    var canBegin: Bool {
        guard let photo = model.previewPhoto else { return false }
        return model.canStartManagementMutation && model.managementFeatures.contains(.manualFaces) && model.canEditPhoto(photo) &&
            photo.mediaType != "video" && model.previewData?.isEmpty == false && !model.isPreparingPreview
    }
    func begin() {
        guard canBegin, let photo = model.previewPhoto, let data = model.previewData else { return }
        cancel(); draft = .init(photo: photo, data: data); load()
    }
    private func isCurrent(_ value: Draft) -> Bool {
        draft?.id == value.id && model.isModuleEnabled && model.previewPhoto?.id == value.photo.id &&
            model.previewPhoto?.filename == value.photo.filename && model.previewPhoto?.folderID == value.photo.folderID &&
            model.previewPhoto?.sizeBytes == value.photo.sizeBytes && model.previewPhoto?.indexedAt == value.photo.indexedAt &&
            model.previewPhoto?.albumContext == value.photo.albumContext
    }
    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        isLoading = true; error = nil; saveError = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.task = nil } }
            do {
                // 与预览一样按显示方向解码，归一化坐标不受屏幕和原图方向影响。
                guard let image = await MobileSynologyPhotoImage.decode(draft.data, maximumPixels: 4_096)?.cgImage else { throw PhotoFaceEditing.Failure.invalidImage }
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                let regions = try await self.model.photoFaces(for: draft.photo)
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                var people = try await self.model.peopleVisibility(in: draft.photo.id.space).map(\.person)
                for face in regions where face.personID > 0 && !people.contains(where: { $0.id == face.personID }) {
                    people.append(.init(id: face.personID, name: face.name, space: draft.photo.id.space))
                }
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.image = image; self.people = people
                self.faces = regions.map { .init(id: "face-\($0.id)", original: $0, bounds: $0.bounds, personID: $0.personID, name: $0.name) }
                self.selectedID = self.faces.first?.id
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.error = L10n.string("photos.faces.failed") }
            }
        }
    }
    var editable: Bool {
        guard let draft else { return false }
        return isCurrent(draft) && !isLoading && error == nil && image != nil && model.canStartManagementMutation && model.canEditPhoto(draft.photo) && model.managementFeatures.contains(.manualFaces)
    }
    var selected: PhotoFaceDraft? { faces.first { $0.id == selectedID } }
    var pendingChangeCount: Int {
        faces.reduce(0) { result, face in
            guard let original = face.original else { return result + (face.removed ? 0 : 1) }
            if face.removed { return result + 1 }
            if face.bounds != original.bounds { return result + 2 }
            return result + (face.personID != original.personID || face.name != original.name ? 1 : 0)
        }
    }
    var canSave: Bool {
        editable && (1...100).contains(pendingChangeCount) && faces.filter { !$0.removed }.allSatisfy { face in
            if let original = face.original, face.bounds == original.bounds, face.personID == original.personID, face.name == original.name { return true }
            return face.bounds.isValid && (people.contains { $0.id == face.personID } || !face.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
    func addCentered() {
        guard let image else { return }
        let side = Double(min(image.width, image.height)) * 0.25
        let width = side / Double(image.width), height = side / Double(image.height)
        add(.init(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height))
    }
    func add(_ bounds: SynologyPhotoFaceBounds) {
        guard editable, bounds.isValid else { return }
        let id = UUID().uuidString
        faces.append(.init(id: id, original: nil, bounds: bounds, personID: 0, name: "")); selectedID = id; saveError = nil
    }
    func setBounds(_ bounds: SynologyPhotoFaceBounds, for id: String) {
        guard editable, bounds.isValid, let index = faces.firstIndex(where: { $0.id == id && !$0.removed }) else { return }
        faces[index].bounds = bounds; selectedID = id; saveError = nil
    }
    func setPerson(_ id: Int) {
        guard editable, let index = faces.firstIndex(where: { $0.id == selectedID && !$0.removed }), id == 0 || people.contains(where: { $0.id == id }) else { return }
        faces[index].personID = id; faces[index].name = people.first { $0.id == id }?.name ?? ""; saveError = nil
    }
    func setName(_ name: String) {
        guard editable, let index = faces.firstIndex(where: { $0.id == selectedID && !$0.removed && $0.personID == 0 }) else { return }
        faces[index].name = name; saveError = nil
    }
    func removeSelected() {
        guard editable, let index = faces.firstIndex(where: { $0.id == selectedID }) else { return }
        if faces[index].original == nil { faces.remove(at: index); selectedID = faces.first?.id }
        else { faces[index].removed = true }
        saveError = nil
    }
    func undoRemove() {
        guard editable, let index = faces.firstIndex(where: { $0.id == selectedID }) else { return }
        faces[index].removed = false; saveError = nil
    }
    @discardableResult func save() -> Bool {
        guard canSave, let draft, let image else { return false }
        do {
            let changes = try PhotoFaceEditing.changes(photo: draft.photo, image: image, drafts: faces, people: people)
            guard !changes.isEmpty else { return false }
            model.submitMutation(.editPhotoFaces(photo: draft.photo, changes: changes))
            guard model.isManaging else { return false }
            cancel(); return true
        } catch { saveError = L10n.string("photos.faces.failed"); return false }
    }
    func cancel() {
        task?.cancel(); task = nil; draft = nil; image = nil; faces = []; people = []; selectedID = nil
        isLoading = false; error = nil; saveError = nil
    }
}
