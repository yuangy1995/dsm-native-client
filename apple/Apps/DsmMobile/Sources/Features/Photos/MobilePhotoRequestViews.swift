import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

struct MobilePhotoRequestForm: View {
    @Bindable var request: MobilePhotoRequestModel
    let draft: MobilePhotoRequestModel.Draft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if request.isLoading { ProgressView(L10n.string("mobile.photos.request.loading")) }
                else if let error = request.error {
                    Text(error).foregroundStyle(.red)
                    Button(L10n.string("photos.retry")) { request.load() }
                } else if draft.deleting {
                    Text(request.original?.settings.subject ?? draft.entry?.title ?? "").font(.headline)
                    Text(L10n.string("mobile.photos.request.deleteHint"))
                } else {
                    Section {
                        TextField(L10n.string("photos.request.subject"), text: $request.settings.subject)
                            .accessibilityIdentifier("mobile.photos.request.subject")
                        TextField(L10n.string("photos.request.description"), text: $request.settings.description, axis: .vertical)
                            .lineLimit(2...4).accessibilityIdentifier("mobile.photos.request.description")
                        if request.settings.subject.utf16.count > 50 || request.settings.description.utf16.count > 100 {
                            Text(L10n.string("photos.request.lengthLimit")).foregroundStyle(.red)
                        }
                        if let url = request.original?.url { MobilePhotoSharingLink(url: url) }
                    }
                    destination
                    album
                    limits
                    Section { Text(L10n.string("photos.request.createHint")).font(.callout).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(draft.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.delete.cancel")) { request.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string(draft.deleting ? "photos.request.delete" : draft.entry == nil ? "photos.request.create" : "mobile.photos.album.save"), role: draft.deleting ? .destructive : nil) {
                        if draft.deleting { request.showsDeleteConfirmation = true }
                        else if request.submit() { dismiss() }
                    }.disabled(request.mutation == nil).accessibilityIdentifier("mobile.photos.request.save")
                }
            }
            .alert(L10n.string("photos.request.delete"), isPresented: $request.showsDeleteConfirmation) {
                Button(L10n.string("photos.delete.cancel"), role: .cancel) { }
                Button(L10n.string("photos.request.delete"), role: .destructive) { if request.submit(confirmedDeletion: true) { dismiss() } }
                    .accessibilityIdentifier("mobile.photos.request.confirmDelete")
            } message: { Text(L10n.string("mobile.photos.request.deleteHint")) }
        }
    }

    private var destination: some View {
        Section {
            if request.model.spaces.count > 1 {
                Picker(L10n.string("photos.library.space"), selection: Binding(get: { request.settings.space }, set: { request.changeSpace($0) })) {
                    ForEach(request.model.spaces, id: \.self) { space in
                        Text(L10n.string(space == .personal ? "shared.51fcaa8035fc61e2" : "shared.17d2e16862f16829")).tag(space)
                    }
                }.accessibilityIdentifier("mobile.photos.request.space")
            }
            if request.model.canUseDefaultRequestFolder(in: request.settings.space) {
                Toggle(L10n.string("photos.request.defaultFolder"), isOn: $request.usesDefaultFolder)
            }
            if request.usesDefaultFolder || !request.settings.folderPath.isEmpty {
                Text(request.usesDefaultFolder ? SynologyPhotoRequestSettings.defaultFolderPath(subject: request.settings.subject) : request.settings.folderPath)
                    .font(.callout).textSelection(.enabled)
            } else { Text(L10n.string("photos.request.selectFolderHint")).foregroundStyle(.secondary) }
            if request.original?.isFolderValid == false, !request.usesDefaultFolder,
               request.settings.space == request.original?.settings.space, request.settings.folderID == request.original?.settings.folderID {
                Text(L10n.string("photos.request.invalidFolder")).foregroundStyle(.red)
            }
            NavigationLink(L10n.string("photos.request.chooseFolder")) { MobilePhotoRequestFolderPicker(request: request) }
                .accessibilityIdentifier("mobile.photos.request.folder")
        }
    }

    private var album: some View {
        Section {
            Picker(L10n.string("photos.request.album"), selection: $request.selectedAlbumID) {
                Text(L10n.string("photos.request.noAlbum")).tag("")
                ForEach(request.albums) { album in Text(album.name).tag(album.id) }
                if !request.selectedAlbumID.isEmpty, !request.albums.contains(where: { $0.id == request.selectedAlbumID }) {
                    Text(request.original?.albumName ?? L10n.string("mobile.photos.request.currentAlbum")).tag(request.selectedAlbumID)
                }
            }.accessibilityIdentifier("mobile.photos.request.album")
            if request.loadingAlbums { ProgressView(L10n.string("mobile.photos.album.loading")) }
            if let error = request.albumError {
                Text(error).foregroundStyle(.red)
                Button(L10n.string("photos.retry")) { request.loadAlbums() }
            }
            if request.canCreateAlbum {
                DisclosureGroup(L10n.string("photos.manage.createAlbum")) {
                    TextField(L10n.string("photos.manage.albumName"), text: $request.newAlbumName)
                        .accessibilityIdentifier("mobile.photos.request.newAlbumName")
                    Button(L10n.string("photos.manage.createAlbum")) { request.createAlbum() }
                        .disabled(request.newAlbumName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !request.model.canStartManagementMutation)
                        .accessibilityIdentifier("mobile.photos.request.createAlbum")
                    if let message = request.model.managementMessage { Text(message).font(.callout) }
                    if request.model.isManaging { ProgressView() }
                    else if request.model.pendingMutationID != nil {
                        Button(L10n.string("photos.selection.retryReview")) { request.model.reviewPendingMutation() }
                    }
                }
            }
            if request.albums.contains(where: { $0.id == request.selectedAlbumID && !$0.shared }) {
                Text(L10n.string("photos.request.privateAlbumHint")).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var limits: some View {
        Section {
            Toggle(L10n.string("photos.request.limitSize"), isOn: Binding(get: { request.limitsSize }, set: { request.limitsSize = $0; request.sizeEdited = true }))
            if request.limitsSize {
                TextField(L10n.string("photos.request.sizeMiB"), value: Binding(get: { request.sizeMiB }, set: { request.sizeMiB = $0; request.sizeEdited = true }), format: .number.locale(L10n.locale))
                    .keyboardType(.numberPad).accessibilityIdentifier("mobile.photos.request.size")
                if !(1...3000).contains(request.sizeMiB) { Text(L10n.string("photos.request.sizeRange")).foregroundStyle(.red) }
            }
            Picker(L10n.string("photos.sharing.expiration"), selection: Binding(get: { request.expiration.choice }, set: { request.expiration.choice = $0; request.expiration.edited = true })) {
                Text(L10n.string("photos.sharing.expirationUnlimited")).tag(PhotoSharingExpirationDraft.Choice.unlimited)
                Text(L10n.string("photos.sharing.expirationDate")).tag(PhotoSharingExpirationDraft.Choice.date)
            }
            if request.expiration.choice == .date {
                DatePicker(L10n.string("photos.sharing.expirationDate"), selection: Binding(get: { request.expiration.date }, set: { request.expiration.date = $0; request.expiration.edited = true }), displayedComponents: .date)
                if !request.expiration.isValid { Text(L10n.string("photos.sharing.expirationPast")).foregroundStyle(.red) }
            }
        }
    }
}

private struct MobilePhotoRequestFolderPicker: View {
    @Bindable var request: MobilePhotoRequestModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            if request.loadingFolders { ProgressView(L10n.string("mobile.photos.request.loadingFolders")) }
            else if let error = request.folderError {
                Text(error).foregroundStyle(.red)
                Button(L10n.string("photos.retry")) { request.loadFolders(path: request.folderPath) }
            } else {
                if request.folders.isEmpty { Text(L10n.string("mobile.photos.request.noSubfolders")).foregroundStyle(.secondary) }
                ForEach(request.folders) { folder in
                    Button { request.loadFolders(path: request.folderPath + [folder]) } label: {
                        Label(folder.name, systemImage: "folder").frame(minHeight: 44)
                    }
                }
            }
        }
        .navigationTitle(L10n.string("photos.request.chooseFolder"))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            HStack {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(request.folderPath.enumerated()), id: \.element.id) { index, folder in
                            if index > 0 { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true) }
                            Button(folder.name) { request.loadFolders(path: Array(request.folderPath.prefix(index + 1))) }
                                .frame(minHeight: 44).disabled(request.loadingFolders)
                        }
                    }
                }.scrollIndicators(.hidden)
                Button(L10n.string("photos.request.useFolder")) { if request.chooseFolder() { dismiss() } }
                    .frame(minHeight: 44).fixedSize(horizontal: false, vertical: true)
                    .disabled(request.loadingFolders || request.folderError != nil || request.folderPath.last?.path == nil)
                    .accessibilityIdentifier("mobile.photos.request.useFolder")
            }.buttonStyle(.bordered).padding(.horizontal).padding(.vertical, 8).background(.regularMaterial)
        }
        .task { request.loadFolders() }
    }
}
