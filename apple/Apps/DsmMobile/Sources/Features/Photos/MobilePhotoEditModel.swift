import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoEditModel {
    enum Action: String, CaseIterable {
        case rating, description, date, shiftDates, tagsAdd, tagsRemove, tagsCreate
        var title: String {
            switch self {
            case .rating: L10n.string("photos.manage.rating")
            case .description: L10n.string("photos.manage.description")
            case .date: L10n.string("photos.manage.date")
            case .shiftDates: L10n.string("photos.manage.shiftDates")
            case .tagsAdd: L10n.string("photos.manage.tagsAdd")
            case .tagsRemove: L10n.string("photos.manage.tagsRemove")
            case .tagsCreate: L10n.string("photos.manage.tagsCreate")
            }
        }
        var feature: SynologyPhotosManagementFeature {
            switch self {
            case .tagsAdd, .tagsRemove: .tags
            case .tagsCreate: .tagCreation
            default: .metadata
            }
        }
        var supportsMixedSpaces: Bool { [.rating, .date, .shiftDates].contains(self) }
    }
    enum ShiftUnit: String, CaseIterable {
        case days, hours, minutes, seconds
        var seconds: Int { switch self { case .days: 86_400; case .hours: 3_600; case .minutes: 60; case .seconds: 1 } }
        var title: String {
            switch self {
            case .days: L10n.string("photos.manage.shiftDays")
            case .hours: L10n.string("photos.manage.shiftHours")
            case .minutes: L10n.string("photos.manage.shiftMinutes")
            case .seconds: L10n.string("photos.manage.shiftSeconds")
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
    private(set) var photos: [SynologyPhoto] = []
    private(set) var choices: [SynologyPhotoFilterChoice] = []
    private(set) var isLoading = false
    private(set) var error: String?
    var text = ""
    var rating = 0
    var date = Date()
    var tags: Set<Int> = []
    var shiftForward = true
    var shiftAmount = 1
    var shiftUnit = ShiftUnit.hours
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var task: Task<Void, Never>?

    init(model: SynologyPhotosModel) { self.model = model }

    func allows(_ action: Action, photos: [SynologyPhoto]? = nil) -> Bool {
        let values = photos ?? model.selectedPhotos
        guard model.canStartManagementMutation, values.count <= 100, model.managementFeatures.contains(action.feature) else { return false }
        if action == .tagsCreate, values.isEmpty { return model.spaces.contains(model.selectedSpace) }
        return model.canEditSelection(values, supportsMixedSpaces: action.supportsMixedSpaces)
    }

    func begin(_ action: Action, photos: [SynologyPhoto]? = nil) {
        let values = photos ?? model.selectedPhotos
        guard allows(action, photos: values) else { return }
        cancel()
        draft = Draft(action: action, photos: values, album: model.selectedAlbum, space: model.selectedSpace)
        self.photos = values
        load()
    }

    private func isCurrent(_ value: Draft) -> Bool {
        draft?.id == value.id && model.isModuleEnabled && model.selectedSpace == value.space && model.selectedAlbum == value.album &&
            value.photos.allSatisfy { original in
                model.items.contains { $0.id == original.id && Self.sameIdentity($0, original) } ||
                    model.previewPhoto.map { $0.id == original.id && Self.sameIdentity($0, original) } == true
            }
    }

    private static func sameIdentity(_ lhs: SynologyPhoto, _ rhs: SynologyPhoto) -> Bool {
        lhs.id == rhs.id && lhs.filename == rhs.filename && lhs.sizeBytes == rhs.sizeBytes && lhs.folderID == rhs.folderID &&
            lhs.indexedAt == rhs.indexedAt && lhs.takenAt == rhs.takenAt && lhs.albumContext == rhs.albumContext
    }

    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        isLoading = true; error = nil; choices = []; tags = []
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.task = nil } }
            do {
                var values = draft.photos
                if values.count == 1, let original = values.first {
                    let current = try await self.model.managementPhotoDetails(original)
                    guard Self.sameIdentity(current, original) else { throw CocoaError(.fileReadUnknown) }
                    values = [current]
                }
                let choices: [SynologyPhotoFilterChoice]
                if [.tagsAdd, .tagsRemove].contains(draft.action) {
                    choices = try await self.model.managementFilterOptions(in: values.first?.id.space ?? draft.space).tags
                } else { choices = [] }
                guard !Task.isCancelled, self.isCurrent(draft) else { return }
                self.photos = values; self.choices = choices
                self.rating = values.first?.rating ?? 0
                self.date = values.first?.takenAt ?? Date()
                self.text = draft.action == .description && values.count == 1 ? values.first?.description ?? "" : ""
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) {
                    self.error = (error as? AppError)?.safeUserMessage ?? L10n.string("mobile.photos.edit.loadFailed")
                }
            }
        }
    }

    var shiftSeconds: Int? {
        let (seconds, overflow) = shiftAmount.multipliedReportingOverflow(by: shiftUnit.seconds)
        guard shiftAmount > 0, !overflow else { return nil }
        let delta = shiftForward ? seconds : -seconds
        for photo in photos {
            let time = photo.takenAt.timeIntervalSince1970
            guard time.isFinite, time >= 0, time <= Double(Int.max / 2) else { return nil }
            let (target, overflow) = Int(time).addingReportingOverflow(delta)
            guard !overflow, target >= 0, target <= Int.max / 2 else { return nil }
        }
        return delta
    }

    var mutation: SynologyPhotosMutation? {
        guard let draft, isCurrent(draft), !isLoading, error == nil, allows(draft.action, photos: photos) else { return nil }
        switch draft.action {
        case .rating: return (0...5).contains(rating) ? .edit(photos, .rating(rating)) : nil
        case .description: return .edit(photos, .description(text))
        case .date:
            let time = date.timeIntervalSince1970
            return time.isFinite && time >= 0 && time <= Double(Int.max / 2) ? .edit(photos, .takenAt(date)) : nil
        case .shiftDates: return shiftSeconds.map { .shiftDates(photos, seconds: $0) }
        case .tagsCreate:
            let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : .createTag(name: name, photos: photos, space: photos.first?.id.space ?? draft.space)
        case .tagsAdd, .tagsRemove:
            guard !tags.isEmpty, tags.isSubset(of: Set(choices.map(\.id))) else { return nil }
            return draft.action == .tagsAdd ? .addTags(photos, ids: tags.sorted()) : .removeTags(photos, ids: tags.sorted())
        }
    }

    @discardableResult
    func submit() -> Bool {
        guard let mutation else { error = L10n.string("mobile.photos.album.stale"); return false }
        model.submitMutation(mutation)
        guard model.isManaging else { error = L10n.string("mobile.photos.album.stale"); return false }
        cancel(); return true
    }

    func cancel() {
        task?.cancel(); task = nil; draft = nil; photos = []; choices = []; tags = []
        isLoading = false; error = nil; text = ""; rating = 0; date = Date()
        shiftForward = true; shiftAmount = 1; shiftUnit = .hours
    }
}
