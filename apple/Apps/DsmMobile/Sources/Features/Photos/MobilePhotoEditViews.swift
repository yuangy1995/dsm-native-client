import DsmCore
import DsmLocalization
import SwiftUI

struct MobilePhotoEditActions: View {
    let editor: MobilePhotoEditModel
    var photos: [SynologyPhoto]?

    var body: some View {
        ForEach(MobilePhotoEditModel.Action.allCases, id: \.self) { action in
            Button(action.title) { editor.begin(action, photos: photos) }
                .disabled(!editor.allows(action, photos: photos)).accessibilityIdentifier("mobile.photos.edit.\(action.rawValue)")
        }
    }
}

struct MobilePhotoEditPresentation: ViewModifier {
    let session: MobileSynologyPhotosSession
    let active: Bool

    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? session.editor?.draft : nil },
                                   set: { if $0 == nil, active { session.editor?.cancel() } }), onDismiss: { session.editor?.cancel() }) { draft in
            if let editor = session.editor { MobilePhotoEditForm(editor: editor, draft: draft) }
        }
    }
}

struct MobilePhotoEditForm: View {
    @Bindable var editor: MobilePhotoEditModel
    let draft: MobilePhotoEditModel.Draft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if editor.isLoading {
                    ProgressView(L10n.string("mobile.photos.edit.loading"))
                        .accessibilityIdentifier("mobile.photos.edit.loading")
                } else if let error = editor.error {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.photos.edit.detailsUnavailable"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { editor.load() }
                    }
                } else if [.tagsAdd, .tagsRemove].contains(draft.action), editor.choices.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.photos.edit.noTagsTitle"), systemImage: "tag")
                    } description: { Text(L10n.string("mobile.photos.edit.noTags")) } actions: {
                        Button(L10n.string("photos.retry")) { editor.load() }
                    }
                } else {
                    Form {
                        if !draft.photos.isEmpty { Text(L10n.string("photos.selection.count", draft.photos.count)) }
                        fields
                    }.scrollDismissesKeyboard(.interactively)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(draft.action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.delete.cancel")) { editor.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("mobile.photos.edit.save")) { if editor.submit() { dismiss() } }
                        .disabled(editor.mutation == nil).accessibilityIdentifier("mobile.photos.edit.submit")
                }
            }
        }
    }

    @ViewBuilder private var fields: some View {
        switch draft.action {
        case .rating:
            Picker(L10n.string("photos.detail.rating"), selection: $editor.rating) {
                Text(L10n.string("photos.manage.unrated")).tag(0)
                ForEach(1...5, id: \.self) { value in Text(L10n.string("photos.stars", value)).tag(value) }
            }.pickerStyle(.inline).accessibilityIdentifier("mobile.photos.edit.ratingValue")
        case .description:
            TextEditor(text: $editor.text).frame(minHeight: 150).accessibilityLabel(draft.action.title)
                .accessibilityIdentifier("mobile.photos.edit.text")
            if draft.photos.count > 1 { Text(L10n.string("mobile.photos.edit.descriptionHint")).foregroundStyle(.secondary) }
        case .date:
            DatePicker(L10n.string("photos.detail.taken"), selection: $editor.date, in: Date(timeIntervalSince1970: 0)...)
                .environment(\.locale, L10n.locale).accessibilityIdentifier("mobile.photos.edit.dateValue")
            if draft.photos.count > 1 { Text(L10n.string("photos.manage.dateHint")).foregroundStyle(.secondary) }
        case .shiftDates:
            Picker(L10n.string("photos.manage.shiftDirection"), selection: $editor.shiftForward) {
                Text(L10n.string("photos.manage.shiftLater")).tag(true)
                Text(L10n.string("photos.manage.shiftEarlier")).tag(false)
            }.accessibilityIdentifier("mobile.photos.edit.direction")
            LabeledContent(L10n.string("photos.manage.shiftAmount")) {
                TextField(L10n.string("photos.manage.shiftAmount"), value: $editor.shiftAmount, format: .number.locale(L10n.locale))
                    .multilineTextAlignment(.trailing).keyboardType(.numberPad).accessibilityIdentifier("mobile.photos.edit.amount")
            }
            Picker(L10n.string("photos.manage.shiftUnit"), selection: $editor.shiftUnit) {
                ForEach(MobilePhotoEditModel.ShiftUnit.allCases, id: \.self) { unit in Text(unit.title).tag(unit) }
            }
            Text(L10n.string("photos.manage.shiftHint")).foregroundStyle(.secondary)
            if let photo = editor.photos.first, let seconds = editor.shiftSeconds {
                let style = Date.FormatStyle(date: .numeric, time: .standard).locale(L10n.locale)
                Text(L10n.string("photos.manage.shiftPreview", photo.takenAt.formatted(style),
                                photo.takenAt.addingTimeInterval(Double(seconds)).formatted(style))).foregroundStyle(.secondary)
            }
        case .tagsCreate:
            TextField(L10n.string("photos.manage.tagName"), text: $editor.text)
                .accessibilityIdentifier("mobile.photos.edit.text")
        case .tagsAdd, .tagsRemove:
            ForEach(editor.choices) { tag in
                Toggle(tag.name, isOn: Binding(get: { editor.tags.contains(tag.id) }, set: { selected in
                    if selected { editor.tags.insert(tag.id) } else { editor.tags.remove(tag.id) }
                })).accessibilityIdentifier("mobile.photos.edit.tag.\(tag.id)")
            }
        }
    }
}
