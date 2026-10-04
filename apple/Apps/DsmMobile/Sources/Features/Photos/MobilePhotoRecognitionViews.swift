import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI
import UIKit

struct MobilePhotoRecognitionActions: View {
    let recognition: MobilePhotoRecognitionModel
    var photos: [SynologyPhoto]?
    var body: some View {
        ForEach([MobilePhotoRecognitionModel.Action.removeFaces, .reassignFaces, .personCover, .conceptCover, .removeConceptItems], id: \.self) { action in
            if recognition.allows(action, photos: photos) {
                Button(action.title) { recognition.begin(action, photos: photos) }
                    .accessibilityIdentifier("mobile.photos.recognition.\(action.rawValue)")
            }
        }
    }
}

struct MobilePhotoRecognitionPresentation: ViewModifier {
    let session: MobileSynologyPhotosSession
    let active: Bool
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? session.recognition?.draft : nil }, set: { if $0 == nil, active { session.recognition?.cancel() } }),
                      onDismiss: { session.recognition?.cancel() }) { draft in
            if let recognition = session.recognition { MobilePhotoRecognitionForm(recognition: recognition, draft: draft) }
        }
    }
}

struct MobilePhotoRecognitionForm: View {
    @Bindable var recognition: MobilePhotoRecognitionModel
    let draft: MobilePhotoRecognitionModel.Draft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if recognition.isLoading {
                    ProgressView(L10n.string("mobile.photos.edit.loading")).accessibilityIdentifier("mobile.photos.recognition.loading")
                } else if let error = recognition.error {
                    ContentUnavailableView {
                        Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                    } description: { Text(error) } actions: { Button(L10n.string("photos.retry")) { recognition.load() } }
                } else { fields.disabled(!recognition.editable) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationTitle(draft.action.title).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("photos.delete.cancel")) { recognition.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L10n.string("mobile.photos.edit.save")) { if recognition.save() { dismiss() } }
                            .disabled(recognition.mutation == nil).keyboardShortcut(.defaultAction).accessibilityIdentifier("mobile.photos.recognition.save")
                    }
                }
                .alert(draft.action.title, isPresented: $recognition.showsConfirmation) {
                    Button(L10n.string("photos.delete.cancel"), role: .cancel) { recognition.cancelConfirmation() }
                    Button(draft.action.title) { if recognition.confirmSave() { dismiss() } }
                        .accessibilityIdentifier("mobile.photos.recognition.confirm")
                } message: { Text(recognition.confirmationMessage) }
        }
    }
    private var nameField: some View {
        TextField(L10n.string("photos.people.name"), text: $recognition.text)
            .textInputAutocapitalization(.words).accessibilityIdentifier("mobile.photos.recognition.name")
    }
    @ViewBuilder private var fields: some View {
        switch draft.action {
        case .peopleVisibility, .conceptVisibility: visibility
        case .merge:
            VStack(spacing: 0) {
                nameField.textFieldStyle(.roundedBorder).padding()
                Text(L10n.string("photos.people.mergeHint")).font(.callout).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom)
                List(recognition.filteredPeople) { person in
                    selection(person.id) {
                        personRow(person)
                    }
                }.overlay {
                    if recognition.filteredPeople.isEmpty {
                        ContentUnavailableView(L10n.string(recognition.people.isEmpty ? "photos.people.noOthers" : "photos.people.visibilityEmpty"), systemImage: "person.2",
                            description: Text(L10n.string(recognition.people.isEmpty ? "photos.people.noOthersHint" : "photos.people.searchEmptyHint")))
                    }
                }.searchable(text: $recognition.search, prompt: L10n.string("photos.people.search"))
            }
        case .removeFaces, .reassignFaces:
            VStack(spacing: 0) {
                if draft.action == .reassignFaces {
                    VStack(alignment: .leading) {
                        Picker(L10n.string("photos.people.destination"), selection: $recognition.targetPersonID) {
                            Text(L10n.string("photos.people.newPerson")).tag(0)
                            ForEach(recognition.people) { Text(personName($0)).tag($0.id) }
                        }.accessibilityIdentifier("mobile.photos.recognition.destination")
                        if recognition.targetPersonID == 0 { nameField.textFieldStyle(.roundedBorder) }
                    }.padding()
                }
                List(recognition.faces) { face in
                    selection(face.id) {
                        HStack {
                            MobilePhotoRecognitionThumbnail(model: recognition.model, source: .face(face)).frame(width: 68, height: 68)
                            Text(face.photo.filename).lineLimit(3)
                        }
                    }
                }.overlay {
                    if recognition.faces.isEmpty {
                        ContentUnavailableView(L10n.string("photos.people.noFaces"), systemImage: "person.crop.rectangle", description: Text(L10n.string("photos.people.noFacesHint")))
                    }
                }
                Text(L10n.string("photos.people.faceCount", recognition.selected.count)).font(.footnote).foregroundStyle(.secondary).padding()
            }
        case .rename:
            Form { nameField; Text(L10n.string("photos.people.clearNameHint")).foregroundStyle(.secondary) }
        case .personCover, .conceptCover:
            Form {
                if let photo = draft.photos.first { Text(photo.filename) }
                Text(L10n.string(draft.action == .personCover ? "photos.people.coverHint" : "photos.concepts.coverHint")).foregroundStyle(.secondary)
            }
        case .removeConceptItems:
            List {
                Text(L10n.string("photos.concepts.removeHint")).foregroundStyle(.secondary)
                if recognition.belowConceptThreshold { Text(L10n.string("photos.concepts.belowThreshold")).foregroundStyle(.secondary) }
                ForEach(draft.photos) { Text($0.filename) }
            }
        }
    }
    private var visibility: some View {
        let concept = draft.action == .conceptVisibility
        return VStack(spacing: 0) {
            Picker(L10n.string("photos.people.visibilityAction"), selection: $recognition.visible) {
                Text(L10n.string(concept ? "photos.concepts.show" : "photos.people.show")).tag(true)
                Text(L10n.string(concept ? "photos.concepts.hide" : "photos.people.hide")).tag(false)
            }.pickerStyle(.segmented).padding().accessibilityIdentifier("mobile.photos.recognition.visibility")
            List(recognition.filteredVisibility) { entry in
                selection(entry.id) {
                    HStack {
                        MobilePhotoRecognitionThumbnail(model: recognition.model, source: .collection(entry.collection, concept ? .concept : .person)).frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(personName(entry.collection))
                            Text(L10n.string(entry.visible ? "photos.people.visible" : "photos.people.hidden")).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }.overlay {
                if recognition.filteredVisibility.isEmpty {
                    ContentUnavailableView(L10n.string(concept ? "photos.concepts.visibilityEmpty" : "photos.people.visibilityEmpty"), systemImage: concept ? "sparkles" : "person.2",
                        description: Text(L10n.string(concept ? "photos.concepts.visibilityEmptyHint" : (recognition.visibilityEntries.isEmpty ? "photos.people.visibilityEmptyHint" : "photos.people.searchEmptyHint"))))
                }
            }.searchable(text: $recognition.search, prompt: L10n.string(concept ? "photos.concepts.search" : "photos.people.search"))
            Text(L10n.string(concept ? "photos.concepts.visibilityCount" : "photos.people.visibilityCount", recognition.selected.count)).font(.footnote).foregroundStyle(.secondary).padding()
            if !concept && recognition.selected.count > 100 {
                Text(L10n.string("photos.people.visibilityHint")).font(.footnote).foregroundStyle(.secondary).padding(.horizontal).padding(.bottom)
            }
        }
    }
    private func selection<Label: View>(_ id: Int, @ViewBuilder label: () -> Label) -> some View {
        Toggle(isOn: Binding(get: { recognition.selected.contains(id) }, set: { selected in
            if selected { recognition.selected.insert(id) } else { recognition.selected.remove(id) }
        }), label: label).accessibilityIdentifier("mobile.photos.recognition.selection.\(id)")
    }
    private func personRow(_ person: SynologyPhotoCollection) -> some View {
        HStack {
            MobilePhotoRecognitionThumbnail(model: recognition.model, source: .collection(person, .person)).frame(width: 44, height: 44)
            VStack(alignment: .leading) {
                Text(personName(person))
                if let count = person.itemCount { Text(L10n.string("photos.people.photoCount", Int64(count))).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func personName(_ person: SynologyPhotoCollection) -> String { person.name.isEmpty ? L10n.string("photos.people.unnamed") : person.name }
}

private struct MobilePhotoRecognitionThumbnail: View {
    enum Source: Equatable { case collection(SynologyPhotoCollection, SynologyPhotoCategory), face(SynologyPhotoFace) }
    let model: SynologyPhotosModel
    let source: Source
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "person.crop.rectangle").foregroundStyle(.secondary) }
        }.clipShape(RoundedRectangle(cornerRadius: 6)).accessibilityHidden(true)
            .task(id: source) {
                image = nil
                let data: Data?
                switch source {
                case .collection(let collection, let category): data = try? await model.categoryThumbnail(for: collection, category: category)
                case .face(let face): data = try? await model.faceThumbnail(face)
                }
                let decoded = await MobileSynologyPhotoImage.decode(data, maximumPixels: 256)
                guard !Task.isCancelled, model.isModuleEnabled else { return }
                image = decoded
            }
    }
}
