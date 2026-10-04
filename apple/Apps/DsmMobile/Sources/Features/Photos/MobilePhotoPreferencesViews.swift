import DsmCore
import DsmLocalization
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
                } else if draft.page == .recognition, preferences.originalRecognition?.values.isEmpty == true {
                    ContentUnavailableView(L10n.string("photos.recognition.empty"), systemImage: "sparkles",
                        description: Text(L10n.string("photos.recognition.emptyHint")))
                } else {
                    Form {
                        switch draft.page {
                        case .duplicates: duplicateFields
                        case .display: displayFields
                        case .recognition: recognitionFields
                        }
                    }.disabled(!preferences.editable)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(draft.page.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(L10n.string("photos.delete.cancel")) { preferences.cancel(); dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("mobile.photos.edit.save")) { if preferences.save() { dismiss() } }
                            .disabled(preferences.mutation == nil).accessibilityIdentifier("mobile.photos.preferences.save")
                    }
                }
                .alert(L10n.string("photos.duplicates.overwriteTitle"), isPresented: $preferences.showsConfirmation) {
                    Button(L10n.string("photos.delete.cancel"), role: .cancel) { preferences.cancelConfirmation() }
                    Button(L10n.string("mobile.photos.edit.save"), role: .destructive) { if preferences.confirmSave() { dismiss() } }
                        .accessibilityIdentifier("mobile.photos.preferences.confirm")
                } message: { Text(L10n.string("photos.duplicates.defaultOverwriteWarning")) }
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
