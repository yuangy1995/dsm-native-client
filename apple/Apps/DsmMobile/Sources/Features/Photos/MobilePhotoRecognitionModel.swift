import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

/// 分类目标与选片在打开时固定；人物、人脸和原照片身份各自校验。
@MainActor
@Observable
final class MobilePhotoRecognitionModel {
    enum Action: String, CaseIterable {
        case rename, merge, peopleVisibility, removeFaces, reassignFaces, personCover, conceptCover, removeConceptItems, conceptVisibility
        var title: String {
            let key: String = switch self {
            case .rename: "photos.people.rename"
            case .merge: "photos.people.merge"
            case .peopleVisibility: "photos.people.visibility"
            case .removeFaces: "photos.people.removeFaces"
            case .reassignFaces: "photos.people.reassignFaces"
            case .personCover: "photos.people.cover"
            case .conceptCover: "photos.concepts.cover"
            case .removeConceptItems: "photos.concepts.remove"
            case .conceptVisibility: "photos.concepts.visibility"
            }
            return L10n.string(key)
        }
        var feature: SynologyPhotosManagementFeature {
            switch self {
            case .rename: .peopleNames
            case .merge: .peopleMerge
            case .peopleVisibility: .peopleVisibility
            case .removeFaces, .reassignFaces: .peopleFaces
            case .personCover: .peopleCover
            case .conceptCover: .conceptCover
            case .removeConceptItems: .conceptItems
            case .conceptVisibility: .conceptVisibility
            }
        }
        var usesPhotos: Bool { [.removeFaces, .reassignFaces, .personCover, .conceptCover, .removeConceptItems].contains(self) }
        var isVisibility: Bool { self == .peopleVisibility || self == .conceptVisibility }
    }
    struct Draft: Identifiable {
        let id = UUID()
        let action: Action
        let collection: SynologyPhotoCollection?
        let photos: [SynologyPhoto]
        let space: SynologyPhotoSpace
        let category: SynologyPhotoCategory?
        let categoryID: Int?
    }
    struct VisibilityEntry: Identifiable {
        let collection: SynologyPhotoCollection
        let visible: Bool
        var id: Int { collection.id }
    }
    private(set) var draft: Draft?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var people: [SynologyPhotoCollection] = []
    private(set) var faces: [SynologyPhotoFace] = []
    private(set) var peopleVisibility: [SynologyPhotoPersonVisibility] = []
    private(set) var conceptVisibility: [SynologyPhotoConceptVisibility] = []
    private(set) var originalConcept: SynologyPhotoConceptVisibility?
    var text = ""
    var search = ""
    var selected: Set<Int> = []
    var visible = true
    var targetPersonID = 0
    var showsConfirmation = false
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var confirmation: SynologyPhotosMutation?

    init(model: SynologyPhotosModel) { self.model = model }
    func allows(_ action: Action, collection: SynologyPhotoCollection? = nil, photos: [SynologyPhoto]? = nil) -> Bool {
        guard model.canStartManagementMutation, model.managementFeatures.contains(action.feature), model.spaces.contains(model.selectedSpace) else { return false }
        if action.isVisibility { return true }
        guard let target = collection ?? model.selectedCategoryItem, target.space == model.selectedSpace else { return false }
        if action == .conceptCover || action == .removeConceptItems {
            let values = photos ?? model.selectedPhotos
            return values.count <= 100 && model.selectedCategoryItem?.id == target.id && model.canManageConceptPhotos(values, cover: action == .conceptCover)
        }
        guard model.selectedCategory == .person else { return false }
        if !action.usesPhotos { return model.selectedCategoryItem?.id == target.id || model.collections.contains(target) }
        let values = photos ?? model.selectedPhotos
        return model.selectedCategoryItem?.id == target.id && !values.isEmpty && values.count <= 100 &&
            values.allSatisfy { $0.id.space == target.space && model.canModifyOriginal($0) } && (action != .personCover || values.count == 1)
    }
    func begin(_ action: Action, collection: SynologyPhotoCollection? = nil, photos: [SynologyPhoto]? = nil) {
        guard allows(action, collection: collection, photos: photos) else { return }
        cancel()
        draft = .init(action: action, collection: collection ?? model.selectedCategoryItem,
                      photos: action.usesPhotos ? photos ?? model.selectedPhotos : [], space: model.selectedSpace,
                      category: model.selectedCategory, categoryID: model.selectedCategoryItem?.id)
        load()
    }
    private func isCurrent(_ value: Draft) -> Bool {
        draft?.id == value.id && model.isModuleEnabled && model.selectedSpace == value.space &&
            model.selectedCategory == value.category && model.selectedCategoryItem?.id == value.categoryID &&
            value.photos.allSatisfy { original in
                model.items.contains { Self.samePhoto($0, original) } || model.previewPhoto.map { Self.samePhoto($0, original) } == true
            }
    }
    private static func samePhoto(_ current: SynologyPhoto, _ original: SynologyPhoto) -> Bool {
        current.id == original.id && current.filename == original.filename && current.sizeBytes == original.sizeBytes &&
            current.folderID == original.folderID && current.indexedAt == original.indexedAt && current.albumContext == original.albumContext
    }
    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        isLoading = true; error = nil; people = []; faces = []; peopleVisibility = []; conceptVisibility = []; originalConcept = nil
        selected = []; text = draft.collection?.name ?? ""; targetPersonID = 0; cancelConfirmation()
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.task = nil } }
            do {
                switch draft.action {
                case .rename, .personCover: break
                case .merge:
                    let values = try await self.model.managementPeople(in: draft.space)
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.people = values.filter { $0.id != draft.collection?.id }
                case .removeFaces, .reassignFaces:
                    guard let person = draft.collection else { throw CocoaError(.fileReadUnknown) }
                    let values = try await self.model.personFaces(personID: person.id, photos: draft.photos)
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    let choices = draft.action == .reassignFaces ? try await self.model.managementPeople(in: draft.space) : []
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.faces = values; self.selected = Set(values.map(\.id)); self.people = choices.filter { $0.id != person.id }; self.text = ""
                case .peopleVisibility:
                    let values = try await self.model.peopleVisibility(in: draft.space)
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.peopleVisibility = values
                    if let target = values.first(where: { $0.id == draft.collection?.id }) { self.selected = [target.id]; self.visible = !target.isVisible }
                case .conceptVisibility:
                    let values = try await self.model.conceptVisibility(in: draft.space)
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.conceptVisibility = values
                    if let target = values.first(where: { $0.id == draft.collection?.id }) { self.selected = [target.id]; self.visible = !target.isVisible }
                case .conceptCover, .removeConceptItems:
                    guard let concept = draft.collection else { throw CocoaError(.fileReadUnknown) }
                    let value = try await self.model.conceptState(concept)
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    guard value.concept.id == concept.id, value.concept.space == concept.space, value.concept.name == concept.name else { throw CocoaError(.fileReadUnknown) }
                    self.originalConcept = value
                }
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("mobile.photos.recognition.loadFailed") }
            }
        }
    }
    var visibilityEntries: [VisibilityEntry] {
        draft?.action == .conceptVisibility ? conceptVisibility.map { .init(collection: $0.concept, visible: $0.isVisible) } : peopleVisibility.map { .init(collection: $0.person, visible: $0.isVisible) }
    }
    var filteredVisibility: [VisibilityEntry] { visibilityEntries.filter { matchesSearch($0.collection.name) } }
    var filteredPeople: [SynologyPhotoCollection] { people.filter { matchesSearch($0.name) } }
    private func matchesSearch(_ name: String) -> Bool { search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.localizedStandardContains(search.trimmingCharacters(in: .whitespacesAndNewlines)) }
    var editable: Bool { draft.map { isCurrent($0) && allows($0.action, collection: $0.collection, photos: $0.photos) } == true && !isLoading && error == nil }
    var mutation: SynologyPhotosMutation? {
        guard editable, let draft else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch draft.action {
        case .rename:
            guard let person = draft.collection, person.name != name else { return nil }
            return .renamePerson(person, name: name)
        case .merge:
            guard let person = draft.collection else { return nil }
            let sources = people.filter { selected.contains($0.id) }
            guard !sources.isEmpty else { return nil }
            return .mergePeople(target: person, sources: sources, name: name)
        case .peopleVisibility:
            let values = peopleVisibility.filter { selected.contains($0.id) && $0.isVisible != visible }
            guard !values.isEmpty, values.count <= 100 else { return nil }
            return .setPeopleVisibility(values, visible: visible)
        case .conceptVisibility:
            let values = conceptVisibility.filter { selected.contains($0.id) && $0.isVisible != visible }
            guard !values.isEmpty else { return nil }
            return .setConceptVisibility(values, visible: visible)
        case .removeFaces, .reassignFaces:
            guard let person = draft.collection else { return nil }
            let values = faces.filter { selected.contains($0.id) }
            guard !values.isEmpty else { return nil }
            if draft.action == .removeFaces { return .removePersonFaces(person: person, faces: values) }
            let target = people.first { $0.id == targetPersonID }
            guard targetPersonID == 0 ? !name.isEmpty : target != nil else { return nil }
            return .reassignPersonFaces(person: person, faces: values, target: target, name: target?.name ?? name)
        case .personCover:
            guard let person = draft.collection, let photo = draft.photos.first else { return nil }
            return .setPersonCover(person: person, photo: photo)
        case .conceptCover:
            guard let originalConcept, let photo = draft.photos.first else { return nil }
            return .setConceptCover(concept: originalConcept, photo: photo)
        case .removeConceptItems:
            guard let originalConcept, let count = originalConcept.concept.itemCount, originalConcept.displayThreshold != nil, count >= draft.photos.count else { return nil }
            return .removeConceptItems(concept: originalConcept, photos: draft.photos)
        }
    }
    var belowConceptThreshold: Bool {
        guard let draft, let originalConcept, let count = originalConcept.concept.itemCount, let threshold = originalConcept.displayThreshold else { return false }
        return count - draft.photos.count < threshold
    }
    @discardableResult func save() -> Bool {
        guard let mutation, let draft else { return false }
        if [.merge, .removeFaces, .removeConceptItems].contains(draft.action) { confirmation = mutation; showsConfirmation = true; return false }
        return submit(mutation)
    }
    @discardableResult func confirmSave() -> Bool {
        guard let confirmation, confirmation == mutation else { cancelConfirmation(); return false }
        return submit(confirmation)
    }
    private func submit(_ mutation: SynologyPhotosMutation) -> Bool {
        model.submitMutation(mutation)
        guard model.isManaging else { return false }
        cancel(); return true
    }
    var confirmationMessage: String {
        switch draft?.action {
        case .merge: L10n.string("photos.people.mergeHint")
        case .removeFaces: L10n.string("mobile.photos.recognition.removeFacesConfirm")
        case .removeConceptItems: L10n.string("photos.concepts.removeHint") + (belowConceptThreshold ? "\n\n" + L10n.string("photos.concepts.belowThreshold") : "")
        default: ""
        }
    }
    func cancelConfirmation() { confirmation = nil; showsConfirmation = false }
    func cancel() {
        task?.cancel(); task = nil; draft = nil; isLoading = false; error = nil
        people = []; faces = []; peopleVisibility = []; conceptVisibility = []; originalConcept = nil
        text = ""; search = ""; selected = []; visible = true; targetPersonID = 0; cancelConfirmation()
    }
}
