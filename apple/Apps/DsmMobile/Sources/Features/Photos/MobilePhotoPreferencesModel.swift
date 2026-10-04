import DsmCore
import DsmLocalization
import DsmPhotosFeature
import Foundation
import Observation

@MainActor
@Observable
final class MobilePhotoPreferencesModel {
    enum Page: String, CaseIterable {
        case duplicates, display, recognition, automatic, codec, maintenance
        var title: String {
            switch self {
            case .duplicates: L10n.string("photos.duplicates.title")
            case .display: L10n.string("photos.display.title")
            case .recognition: L10n.string("mobile.photos.preferences.recognition")
            case .automatic: L10n.string("photos.automatic.title")
            case .codec: L10n.string("photos.codec.title")
            case .maintenance: L10n.string("photos.maintenance.title")
            }
        }
        var feature: SynologyPhotosManagementFeature {
            switch self { case .duplicates: .duplicateSettings; case .display: .displaySettings; case .recognition: .recognitionSettings; case .automatic: .automaticPreviewSettings; case .codec: .codecPrompt; case .maintenance: .libraryMaintenance }
        }
    }
    struct Draft: Identifiable { let id = UUID(); let page: Page; let space: SynologyPhotoSpace }
    private(set) var draft: Draft?
    private(set) var isLoading = false
    private(set) var error: String?
    private(set) var originalDuplicates: SynologyPhotoDuplicateSettings?
    private(set) var originalDisplay: SynologyPhotoDisplaySettings?
    private(set) var originalRecognition: SynologyPhotoRecognitionSettings?
    private(set) var originalAutomatic: Bool?
    private(set) var codec: SynologyPhotoCodecPrompt?
    private(set) var maintenance: SynologyPhotoLibraryMaintenanceStatus?
    var automatic = false
    var duplicates = SynologyPhotoDuplicateSettings(upload: .rename, transfer: .skip)
    var display = SynologyPhotoDisplaySettings()
    var recognition: Set<SynologyPhotoRecognitionSettings.Kind> = []
    var showsConfirmation = false
    @ObservationIgnored let model: SynologyPhotosModel
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var confirmation: SynologyPhotosMutation?

    init(model: SynologyPhotosModel) { self.model = model }
    func canOpen(_ page: Page) -> Bool { model.isModuleEnabled && model.managementFeatures.contains(page.feature) }
    func begin(_ page: Page) {
        guard canOpen(page) else { return }
        cancel(); draft = .init(page: page, space: model.selectedSpace)
        model.setAutomaticPreviewSettingsVisible([.automatic, .codec, .maintenance].contains(page)); load()
    }
    private func isCurrent(_ draft: Draft) -> Bool { self.draft?.id == draft.id && canOpen(draft.page) && (draft.page != .maintenance || model.selectedSpace == draft.space) }
    func load() {
        guard let draft, isCurrent(draft), !isLoading else { return }
        isLoading = true; error = nil; originalDuplicates = nil; originalDisplay = nil; originalRecognition = nil
        originalAutomatic = nil; codec = nil; maintenance = nil
        cancelConfirmation()
        task = Task { [weak self] in
            guard let self else { return }
            defer { if self.draft?.id == draft.id { self.isLoading = false; self.task = nil } }
            do {
                switch draft.page {
                case .duplicates:
                    let value = try await self.model.duplicateSettings()
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.originalDuplicates = value; self.duplicates = value
                case .display:
                    let value = try await self.model.displaySettings()
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.originalDisplay = value; self.display = value
                case .automatic:
                    let value = try await self.model.automaticPreviewSetting()
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.originalAutomatic = value; self.automatic = value
                case .codec:
                    let value = try await self.model.codecPrompt()
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.codec = value
                case .maintenance:
                    let value = try await self.model.libraryMaintenanceStatus(in: draft.space)
                    guard !Task.isCancelled, self.isCurrent(draft), value.space == draft.space else { return }
                    self.maintenance = value
                case .recognition:
                    let value = try await self.model.recognitionSettings()
                    guard !Task.isCancelled, self.isCurrent(draft) else { return }
                    self.originalRecognition = value; self.recognition = value.enabled
                }
            } catch {
                if !Task.isCancelled, self.isCurrent(draft) { self.error = L10n.string("mobile.photos.preferences.loadFailed") }
            }
        }
    }
    var editable: Bool {
        guard let draft else { return false }
        return isCurrent(draft) && !isLoading && error == nil && model.canStartManagementMutation
    }
    var mutation: SynologyPhotosMutation? {
        guard editable, let draft else { return nil }
        switch draft.page {
        case .automatic:
            guard let originalAutomatic, originalAutomatic != automatic else { return nil }
            return .setAutomaticPreview(original: originalAutomatic, enabled: automatic)
        case .codec, .maintenance: return nil
        case .duplicates:
            guard let originalDuplicates, originalDuplicates != duplicates else { return nil }
            return .setDuplicateSettings(original: originalDuplicates, updated: duplicates)
        case .display:
            guard let originalDisplay, originalDisplay != display else { return nil }
            return .setDisplaySettings(original: originalDisplay, updated: display)
        case .recognition:
            guard let originalRecognition, originalRecognition.canSave(recognition) else { return nil }
            return .setRecognitionSettings(original: originalRecognition, enabled: recognition)
        }
    }
    var needsConfirmation: Bool {
        if case .setDuplicateSettings(let original, let updated) = mutation { return original.transfer != .overwrite && updated.transfer == .overwrite }
        return false
    }
    @discardableResult func save() -> Bool {
        guard let mutation else { return false }
        if needsConfirmation { confirmation = mutation; showsConfirmation = true; return false }
        return submit(mutation)
    }
    @discardableResult func confirmSave() -> Bool {
        guard let confirmation, editable else { return false }
        let current: Bool
        if case .maintainLibrary(let original, let action) = confirmation { current = maintenance == original && original.canStart(action) }
        else { current = mutation == confirmation }
        guard current else { cancelConfirmation(); error = L10n.string("mobile.photos.album.stale"); return false }
        return submit(confirmation)
    }
    func confirmMaintenance(_ action: SynologyPhotoLibraryMaintenanceStatus.Action) {
        guard editable, let maintenance, maintenance.canStart(action) else { return }
        confirmation = .maintainLibrary(maintenance, action); showsConfirmation = true
    }
    @discardableResult func respondToCodec(generate: Bool) -> Bool {
        guard editable, let codec, codec.shouldShow, !generate || codec.canGenerate else { return false }
        return submit(.respondToCodecPrompt(codec, generate: generate))
    }
    var confirmationTitle: String { L10n.string(draft?.page == .maintenance ? "photos.maintenance.confirmTitle" : "photos.duplicates.overwriteTitle") }
    var confirmationAction: String { L10n.string(draft?.page == .maintenance ? "photos.maintenance.start" : "mobile.photos.edit.save") }
    var confirmationMessage: String {
        if case .maintainLibrary(let original, let action) = confirmation {
            return L10n.string(action == .reindex ? "photos.maintenance.confirmReindex" : "photos.maintenance.confirmPreviews",
                L10n.string(original.space == .personal ? "mobile.photos.source.mine" : "mobile.photos.source.shared"))
        }
        return L10n.string("photos.duplicates.defaultOverwriteWarning")
    }
    private func submit(_ mutation: SynologyPhotosMutation) -> Bool {
        model.submitMutation(mutation)
        guard model.isManaging else { return false }
        cancel(); return true
    }
    func cancelConfirmation() { confirmation = nil; showsConfirmation = false }
    func cancel() {
        task?.cancel(); task = nil; draft = nil; isLoading = false; error = nil
        originalDuplicates = nil; originalDisplay = nil; originalRecognition = nil
        originalAutomatic = nil; automatic = false; codec = nil; maintenance = nil
        model.setAutomaticPreviewSettingsVisible(false)
        duplicates = .init(upload: .rename, transfer: .skip); display = .init(); recognition = []
        cancelConfirmation()
    }
}
