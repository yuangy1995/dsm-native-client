import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

struct MobilePhotoPreferencesForm: View {
    @Bindable var preferences: MobilePhotoPreferencesModel
    let draft: MobilePhotoPreferencesModel.Draft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if preferences.isLoading {
                    ProgressView(L10n.string("mobile.photos.preferences.loading"))
                        .accessibilityIdentifier("mobile.photos.preferences.loading")
                }
                else if let error = preferences.error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { preferences.load() } }
                } else if draft.page == .codec, preferences.codec?.shouldShow == false {
                    ContentUnavailableView {
                        Label(L10n.string("photos.codec.none"), systemImage: "checkmark.circle")
                    } actions: { Button(L10n.string("photos.library.refresh")) { preferences.load() } }
                } else if draft.page == .recognition, preferences.originalRecognition?.values.isEmpty == true {
                    ContentUnavailableView(L10n.string("photos.recognition.empty"), systemImage: "sparkles",
                        description: Text(L10n.string("photos.recognition.emptyHint")))
                } else {
                    Form {
                        switch draft.page {
                        case .duplicates: duplicateFields.disabled(!preferences.editable)
                        case .display: displayFields.disabled(!preferences.editable)
                        case .recognition: recognitionFields.disabled(!preferences.editable)
                        case .automatic: automaticFields
                        case .codec: codecFields
                        case .maintenance: maintenanceFields
                        }
                        if [.automatic, .codec, .maintenance].contains(draft.page), showsManagementStatus {
                            MobilePhotoManagementStatus(model: preferences.model)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(draft.page.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        if draft.page == .maintenance || draft.page == .codec {
                            Button { preferences.cancel(); dismiss() } label: { Image(systemName: "xmark") }
                                .accessibilityLabel(L10n.string("photos.media.close")).keyboardShortcut(.cancelAction)
                        } else { Button(L10n.string("photos.delete.cancel")) { preferences.cancel(); dismiss() } }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        if draft.page == .maintenance || draft.page == .codec {
                            Button { preferences.load() } label: { Image(systemName: "arrow.clockwise") }
                                .accessibilityLabel(L10n.string("photos.library.refresh")).disabled(preferences.isLoading)
                        } else { Button(L10n.string("mobile.photos.edit.save")) { if preferences.save() { dismiss() } }
                            .disabled(preferences.mutation == nil).accessibilityIdentifier("mobile.photos.preferences.save") }
                    }
                }
                .alert(preferences.confirmationTitle, isPresented: $preferences.showsConfirmation) {
                    Button(L10n.string("photos.delete.cancel"), role: .cancel) { preferences.cancelConfirmation() }
                    Button(preferences.confirmationAction, role: draft.page == .maintenance ? nil : .destructive) { if preferences.confirmSave() { dismiss() } }
                        .accessibilityIdentifier("mobile.photos.preferences.confirm")
                } message: { Text(preferences.confirmationMessage) }
        }
        .task(id: draft.id) {
            guard draft.page == .maintenance else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                if !preferences.showsConfirmation { preferences.load() }
            }
        }
    }

    private var showsManagementStatus: Bool {
        let model = preferences.model
        return model.albumRecoveryError != nil || (model.isManaging && !model.isGeneratingAutomaticPreview) ||
            (model.pendingMutationID != nil && (draft.page != .automatic || !model.hasPendingAutomaticPreview))
    }

    private var automaticFields: some View {
        Section {
            Toggle(L10n.string("photos.automatic.enabled"), isOn: $preferences.automatic)
                .disabled(!preferences.editable).accessibilityIdentifier("photos.automatic.enabled")
            Text(L10n.string("mobile.photos.automatic.foreground")).foregroundStyle(.secondary)
            if !preferences.model.automaticPreviewSupported {
                Text(L10n.string("mobile.photos.automatic.unsupported")).foregroundStyle(.secondary)
            }
            MobilePhotoAutomaticPreviewStatus(model: preferences.model)
        }
    }
    @ViewBuilder private var codecFields: some View {
        if let prompt = preferences.codec {
            Section {
                if !prompt.shouldShow { Text(L10n.string("photos.codec.none")) }
                else {
                    Text(L10n.string(prompt.generationAlreadySubmitted ? "photos.codec.submitted" : prompt.isAdministrator ? "photos.codec.allUsers" : "photos.codec.personal"))
                    if !prompt.canGenerate && !prompt.generationAlreadySubmitted { Text(L10n.string("photos.codec.unavailable")).foregroundStyle(.secondary) }
                    if prompt.canGenerate {
                        Button(L10n.string("photos.codec.generate")) { if preferences.respondToCodec(generate: true) { dismiss() } }
                            .accessibilityIdentifier("mobile.photos.codec.generate")
                    }
                    Button(L10n.string(prompt.generationAlreadySubmitted ? "photos.codec.dismiss" : "photos.codec.later")) {
                        if preferences.respondToCodec(generate: false) { dismiss() }
                    }.accessibilityIdentifier("mobile.photos.codec.dismiss")
                }
            }.disabled(!preferences.editable)
        }
    }
    @ViewBuilder private var maintenanceFields: some View {
        if let status = preferences.maintenance {
            ForEach(SynologyPhotoLibraryMaintenanceStatus.Action.allCases, id: \.self) { action in
                Section(L10n.string(action == .reindex ? "photos.maintenance.reindex" : "photos.maintenance.previews")) {
                    Text(L10n.string(action == .reindex ? "photos.maintenance.reindexDescription" : "photos.maintenance.previewsDescription"))
                    if action == .previews && !status.supportsPreviewGeneration {
                        Text(L10n.string("photos.maintenance.previewUnavailable")).foregroundStyle(.secondary)
                    } else if status.pendingCount(for: action) > 0 {
                        Label(L10n.string("photos.maintenance.running"), systemImage: "arrow.triangle.2.circlepath")
                    }
                    Button(L10n.string("photos.maintenance.start")) { preferences.confirmMaintenance(action) }
                        .disabled(!preferences.editable || !status.canStart(action))
                        .accessibilityIdentifier("mobile.photos.maintenance.\(action.rawValue)")
                }
            }
        }
    }

    private var duplicateFields: some View {
        Group {
            Picker(L10n.string("photos.duplicates.upload"), selection: $preferences.duplicates.upload) {
                Text(L10n.string("photos.duplicates.rename")).tag(SynologyPhotoDuplicateSettings.Upload.rename)
                Text(L10n.string("photos.duplicates.ignore")).tag(SynologyPhotoDuplicateSettings.Upload.ignore)
            }.accessibilityIdentifier("mobile.photos.preferences.upload")
            Picker(L10n.string("photos.duplicates.transfer"), selection: $preferences.duplicates.transfer) {
                Text(L10n.string("photos.duplicates.skip")).tag(SynologyPhotoDuplicateSettings.Transfer.skip)
                Text(L10n.string("photos.duplicates.overwrite")).tag(SynologyPhotoDuplicateSettings.Transfer.overwrite)
            }.accessibilityIdentifier("mobile.photos.preferences.transfer")
        }
    }
    private var displayFields: some View {
        Group {
            Picker(L10n.string("photos.display.grouping"), selection: $preferences.display.grouping) {
                Text(L10n.string("photos.display.day")).tag(SynologyPhotoDisplaySettings.Grouping.day)
                Text(L10n.string("photos.display.month")).tag(SynologyPhotoDisplaySettings.Grouping.month)
            }.accessibilityIdentifier("mobile.photos.preferences.grouping")
            Picker(L10n.string("photos.display.date"), selection: $preferences.display.dateFormat) {
                ForEach(SynologyPhotoDisplaySettings.DateFormat.allCases, id: \.self) { format in
                    Text(format.rawValue.replacingOccurrences(of: "yyyy", with: "2019").replacingOccurrences(of: "mm", with: "12").replacingOccurrences(of: "dd", with: "31")).tag(format)
                }
            }.accessibilityIdentifier("mobile.photos.preferences.date")
            Picker(L10n.string("photos.display.time"), selection: $preferences.display.clock) {
                Text(L10n.string("photos.display.clock12")).tag(SynologyPhotoDisplaySettings.Clock.twelve)
                Text(L10n.string("photos.display.clock24")).tag(SynologyPhotoDisplaySettings.Clock.twentyFour)
            }.accessibilityIdentifier("mobile.photos.preferences.clock")
            Picker(L10n.string("photos.display.sort"), selection: $preferences.display.defaultSort.field) {
                ForEach(SynologyPhotoSort.Field.allCases, id: \.self) { field in Text(sortTitle(field)).tag(field) }
            }
            Picker(L10n.string("photos.folderSort.title"), selection: $preferences.display.defaultSort.direction) {
                Text(L10n.string("workspace.sort.ascending")).tag(SynologyPhotoSort.Direction.ascending)
                Text(L10n.string("workspace.sort.descending")).tag(SynologyPhotoSort.Direction.descending)
            }
            Toggle(L10n.string("mobile.photos.preferences.info"), isOn: $preferences.display.showsPreviewInfo)
                .accessibilityIdentifier("mobile.photos.preferences.info")
        }
    }
    @ViewBuilder private var recognitionFields: some View {
        if let original = preferences.originalRecognition {
            if !original.personalSpaceEnabled { Text(L10n.string("photos.recognition.homeRequired")).foregroundStyle(.secondary) }
            ForEach(SynologyPhotoRecognitionSettings.Kind.allCases, id: \.self) { kind in
                if original.values[kind] != nil {
                    Toggle(recognitionTitle(kind), isOn: Binding(get: { preferences.recognition.contains(kind) }, set: {
                        if $0 { preferences.recognition.insert(kind) } else { preferences.recognition.remove(kind) }
                    })).disabled(!original.editable.contains(kind)).accessibilityIdentifier("mobile.photos.preferences.\(kind.rawValue)")
                    if original.personalSpaceEnabled && !original.globallyEnabled.contains(kind) {
                        Text(L10n.string("photos.recognition.adminRequired")).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
    private func recognitionTitle(_ kind: SynologyPhotoRecognitionSettings.Kind) -> String {
        switch kind {
        case .person: L10n.string("photos.recognition.enable_person")
        case .concept: L10n.string("photos.recognition.enable_concept")
        case .similar: L10n.string("photos.recognition.enable_similar")
        }
    }
    private func sortTitle(_ field: SynologyPhotoSort.Field) -> String {
        switch field {
        case .filename: L10n.string("photos.folderSort.filename")
        case .filesize: L10n.string("photos.folderSort.filesize")
        case .itemType: L10n.string("photos.folderSort.item_type")
        case .takenTime: L10n.string("photos.folderSort.takentime")
        }
    }
}

struct MobilePhotoPreferencesPresentation: ViewModifier {
    @Bindable var session: MobileSynologyPhotosSession
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { session.preferences?.draft }, set: { if $0 == nil { session.preferences?.cancel() } }), onDismiss: { session.preferences?.cancel() }) { draft in
            if let preferences = session.preferences { MobilePhotoPreferencesForm(preferences: preferences, draft: draft) }
        }
    }
}

struct MobilePhotoAutomaticPreviewStatus: View {
    @Bindable var model: SynologyPhotosModel
    var body: some View {
        if model.showsAutomaticPreviewStatus || model.automaticPreviewCompleted > 0 {
            VStack(alignment: .leading, spacing: 8) {
                if let filename = model.automaticPreviewFilename { Text(L10n.string("photos.automatic.processing", filename)) }
                else if model.hasPendingAutomaticPreview { Text(L10n.string("mobile.photos.automatic.pending")) }
                else if let error = model.automaticPreviewError { Text(error) }
                else if model.automaticPreviewPaused { Text(L10n.string("photos.automatic.paused")) }
                else if model.automaticPreviewCompleted > 0 { Text(L10n.string("photos.automatic.completed", model.automaticPreviewCompleted)) }
                HStack {
                    if model.isGeneratingAutomaticPreview {
                        Button(L10n.string("photos.automatic.pause")) { model.pauseAutomaticPreviews() }
                            .accessibilityIdentifier("mobile.photos.automatic.pause")
                    } else if model.hasPendingAutomaticPreview {
                        Button(L10n.string("mobile.photos.album.refresh")) { model.reviewPendingMutation() }.disabled(model.isManaging)
                    } else if model.automaticPreviewPaused || model.automaticPreviewError != nil {
                        Button(L10n.string("photos.automatic.resume")) { model.resumeAutomaticPreviews() }
                            .accessibilityIdentifier("mobile.photos.automatic.resume")
                    }
                }.buttonStyle(.bordered).controlSize(.large)
            }.font(.callout)
        }
    }
}
