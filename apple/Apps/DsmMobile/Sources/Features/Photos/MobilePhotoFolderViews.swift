import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI
import UIKit

struct MobilePhotoFolderActions: View {
    let folders: MobilePhotoFolderModel
    var photos: [SynologyPhoto]?
    var targets: [SynologyPhotoCollection]?

    var body: some View {
        ForEach([MobilePhotoFolderModel.Action.move, .copy], id: \.self) { action in
            Button(action.title) { folders.begin(action, photos: photos, folders: targets) }
                .disabled(!folders.allows(action, photos: photos, folders: targets))
                .accessibilityIdentifier("mobile.photos.folder.\(action.rawValue)")
        }
    }
}

struct MobilePhotoFolderPresentation: ViewModifier {
    let session: MobileSynologyPhotosSession
    let active: Bool
    func body(content: Content) -> some View {
        content.sheet(item: Binding(get: { active ? session.folders?.draft : nil },
            set: { if $0 == nil, active { session.folders?.cancel() } }), onDismiss: { session.folders?.cancel() }) { draft in
            if let folders = session.folders { MobilePhotoFolderForm(folders: folders, draft: draft) }
        }
    }
}

struct MobilePhotoFolderForm: View {
    @Bindable var folders: MobilePhotoFolderModel
    let draft: MobilePhotoFolderModel.Draft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if folders.isLoading {
                    ProgressView(L10n.string("mobile.photos.folder.loading"))
                        .accessibilityIdentifier("mobile.photos.folder.loading")
                } else if let error = folders.error {
                    ContentUnavailableView {
                        Label(L10n.string("mobile.photos.folder.unavailable"), systemImage: "folder.badge.questionmark")
                    } description: { Text(error) } actions: {
                        Button(L10n.string("photos.retry")) { folders.retry() }
                        if folders.path.count > 1 { Button(L10n.string("photos.library.back")) { folders.goBack() } }
                    }
                } else if draft.action.isTransfer || draft.action == .cover {
                    browser
                } else {
                    Form {
                        if let target = draft.target {
                            Label(target.path == "/" ? L10n.string("photos.folders.root") : target.name, systemImage: "folder")
                        }
                        if draft.action == .create || draft.action == .rename {
                            TextField(L10n.string("photos.folder.name"), text: $folders.name)
                                .textInputAutocapitalization(.sentences).autocorrectionDisabled()
                                .accessibilityIdentifier("mobile.photos.folder.name")
                            if !folders.name.isEmpty, !SynologyPhotosMutation.isValidFolderName(folders.name.trimmingCharacters(in: .whitespacesAndNewlines)) {
                                Text(L10n.string("photos.folder.invalidName")).foregroundStyle(.secondary)
                            }
                        } else if draft.action == .sort {
                            Picker(L10n.string("photos.folderSort.title"), selection: $folders.sort.field) {
                                ForEach(SynologyPhotoSort.Field.allCases, id: \.self) { field in Text(field.mobileTitle).tag(field) }
                            }.accessibilityIdentifier("mobile.photos.folder.sortField")
                            Picker(L10n.string("workspace.sort.direction"), selection: $folders.sort.direction) {
                                Text(L10n.string("workspace.sort.ascending")).tag(SynologyPhotoSort.Direction.ascending)
                                Text(L10n.string("workspace.sort.descending")).tag(SynologyPhotoSort.Direction.descending)
                            }
                        } else if draft.action == .delete {
                            Text(deletionMessage)
                            ForEach(draft.folders) { folder in Label(folder.name, systemImage: "folder") }
                            ForEach(draft.photos) { photo in Label(photo.filename, systemImage: "photo") }
                        }
                    }.scrollDismissesKeyboard(.interactively)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(draft.action.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.delete.cancel")) { folders.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle, role: draft.action == .delete ? .destructive : nil) {
                        if folders.submit() { dismiss() }
                    }.disabled(folders.mutation == nil).accessibilityIdentifier("mobile.photos.folder.submit")
                }
            }
            .alert(L10n.string(draft.action == .delete ? "photos.folder.deleteTitle" : "photos.duplicates.overwriteTitle"), isPresented: $folders.showsConfirmation) {
                Button(L10n.string("photos.delete.cancel"), role: .cancel) { }
                Button(L10n.string(draft.action == .delete ? "photos.delete.action" : "photos.duplicates.overwriteConfirm"), role: .destructive) {
                    if folders.submit(confirmed: true) { dismiss() }
                }.accessibilityIdentifier("mobile.photos.folder.confirm")
            } message: { Text(draft.action == .delete ? deletionMessage : L10n.string("photos.duplicates.overwriteWarning")) }
        }
    }

    private var submitTitle: String {
        switch draft.action {
        case .move: L10n.string("mobile.photos.folder.moveHere")
        case .copy: L10n.string("mobile.photos.folder.copyHere")
        case .create: L10n.string("mobile.photos.folder.create")
        case .delete: L10n.string("photos.delete.action")
        default: L10n.string("mobile.photos.edit.save")
        }
    }
    private var deletionMessage: String { L10n.string("photos.folder.deleteConfirm", draft.folders.count, draft.photos.count) }

    private var browser: some View {
        VStack(spacing: 0) {
            HStack {
                Button { folders.goBack() } label: {
                    Label(L10n.string("photos.library.back"), systemImage: "chevron.left")
                }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(folders.path.count <= 1)
                    .accessibilityIdentifier("mobile.photos.folder.back")
                Menu {
                    ForEach(Array(folders.path.enumerated()), id: \.offset) { index, folder in
                        Button(folder.path == "/" ? L10n.string("photos.folders.root") : folder.name) { folders.goBack(to: index) }
                            .disabled(index == folders.path.count - 1)
                    }
                } label: {
                    Text(folders.path.last.map { $0.path == "/" ? L10n.string("photos.folders.root") : $0.name } ?? "")
                        .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("mobile.photos.folder.path")
            }.padding(.horizontal).background(.bar)
            List {
                if folders.destinationSpaces.count > 1 {
                    Picker(L10n.string("mobile.photos.source.title"), selection: Binding(get: { folders.destinationSpace }, set: { folders.changeSpace($0) })) {
                        ForEach(folders.destinationSpaces, id: \.self) { space in
                            Text(L10n.string(space == .personal ? "mobile.photos.source.mine" : "mobile.photos.source.shared")).tag(space)
                        }
                    }.accessibilityIdentifier("mobile.photos.folder.space")
                }
                if draft.action.isTransfer {
                    Text(L10n.string("photos.selection.count", draft.photos.count + draft.folders.count))
                    Picker(L10n.string("photos.duplicates.title"), selection: $folders.duplicate) {
                        Text(L10n.string("photos.duplicates.skip")).tag(SynologyPhotoDuplicateSettings.Transfer.skip)
                        Text(L10n.string("photos.duplicates.overwrite")).tag(SynologyPhotoDuplicateSettings.Transfer.overwrite)
                    }.accessibilityIdentifier("mobile.photos.folder.duplicate")
                    if folders.duplicate == .overwrite { Text(L10n.string("photos.duplicates.overwriteWarning")).foregroundStyle(.secondary) }
                }
                ForEach(folders.children) { folder in
                    Button { folders.open(folder) } label: {
                        Label(folder.name, systemImage: "folder").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("mobile.photos.folder.child.\(folder.id)")
                }
                if draft.action == .cover {
                    ForEach(folders.coverPhotos) { photo in
                        Button { folders.coverPhoto = photo } label: {
                            HStack {
                                MobilePhotoFolderCoverImage(photo: photo, model: folders.model)
                                Text(photo.filename).lineLimit(2)
                                Spacer()
                                if folders.coverPhoto?.id == photo.id { Image(systemName: "checkmark") }
                            }.frame(minHeight: 44)
                        }.accessibilityAddTraits(folders.coverPhoto?.id == photo.id ? .isSelected : [])
                            .accessibilityIdentifier("mobile.photos.folder.cover.\(photo.id.unitID)")
                    }
                    if let error = folders.moreError { Text(error).foregroundStyle(.secondary) }
                    if folders.hasMore {
                        Button(L10n.string("photos.folderCover.more")) { Task { await folders.loadMore() } }.disabled(folders.isLoadingMore)
                    }
                    if folders.isLoadingMore { ProgressView() }
                }
                if folders.children.isEmpty, folders.coverPhotos.isEmpty {
                    Text(L10n.string(draft.action == .cover ? "photos.folderCover.emptyHint" : "mobile.photos.folder.noChildren"))
                        .foregroundStyle(.secondary).accessibilityIdentifier("mobile.photos.folder.empty")
                }
            }.listStyle(.insetGrouped)
        }
    }
}

private extension SynologyPhotoSort.Field {
    var mobileTitle: String {
        switch self {
        case .filename: L10n.string("photos.folderSort.filename")
        case .filesize: L10n.string("photos.folderSort.filesize")
        case .itemType: L10n.string("photos.folderSort.item_type")
        case .takenTime: L10n.string("photos.folderSort.takentime")
        }
    }
}

private struct MobilePhotoFolderCoverImage: View {
    let photo: SynologyPhoto
    let model: SynologyPhotosModel
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.frame(width: 52, height: 52).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
            .accessibilityHidden(true)
            .task(id: photo.id) {
                let data = try? await model.thumbnail(for: photo)
                guard !Task.isCancelled else { return }
                image = data.flatMap { UIImage(data: $0) }
            }
    }
}
