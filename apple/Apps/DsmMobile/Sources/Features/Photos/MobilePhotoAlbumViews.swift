import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

struct MobilePhotoAlbumForm: View {
    @Bindable var albums: MobilePhotoAlbumModel
    let draft: MobilePhotoAlbumModel.Draft
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                if let album = draft.album { Text(album.name).font(.headline) }
                if !draft.photos.isEmpty { Text(L10n.string("photos.selection.count", draft.photos.count)) }
                if albums.isLoading {
                    ProgressView(L10n.string("mobile.photos.album.loading")).accessibilityIdentifier("mobile.photos.album.loading")
                }
                else if let error = albums.error {
                    Text(error).foregroundStyle(.red)
                    Button(L10n.string("photos.retry")) { albums.load() }
                } else {
                    switch draft.action {
                    case .create, .rename:
                        TextField(L10n.string("photos.manage.albumName"), text: $albums.name)
                            .accessibilityIdentifier("mobile.photos.album.name")
                    case .add:
                        if albums.albums.isEmpty {
                            ContentUnavailableView {
                                Label(L10n.string("mobile.photos.album.choose"), systemImage: "photo.on.rectangle")
                            } description: { Text(L10n.string("mobile.photos.album.empty")) } actions: {
                                Button(L10n.string("photos.retry")) { albums.load() }
                            }
                        } else {
                            ForEach(albums.albums) { album in
                                Button { albums.albumID = album.id } label: {
                                    HStack {
                                        Text(album.name).foregroundStyle(.primary)
                                        Spacer()
                                        if albums.albumID == album.id { Image(systemName: "checkmark") }
                                    }.frame(minHeight: 44)
                                }.accessibilityAddTraits(albums.albumID == album.id ? .isSelected : [])
                            }
                        }
                    case .remove: Text(L10n.string("mobile.photos.album.removeHint"))
                    case .delete: Text(L10n.string("photos.manage.deleteAlbumHint"))
                    case .cover: Text(L10n.string("photos.manage.coverHint"))
                    }
                }
            }
            .navigationTitle(draft.action.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.delete.cancel")) { albums.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.action == .rename ? L10n.string("mobile.photos.album.save") : draft.action.title,
                           role: [.delete, .remove].contains(draft.action) ? .destructive : nil) {
                        if albums.submit() { dismiss() }
                    }.disabled(albums.mutation == nil).accessibilityIdentifier("mobile.photos.album.submit")
                }
            }
        }
    }
}

struct MobilePhotoManagementStatus: View {
    @Bindable var model: SynologyPhotosModel

    private var isAlbumContinuation: Bool {
        switch model.retryableManagementMutation {
        case .addToAlbum, .removeFromAlbum: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.albumRecoveryError {
                Text(error).foregroundStyle(.red)
                Button(L10n.string("mobile.photos.album.refresh")) { Task { await model.retryAlbumRecovery() } }
                    .disabled(model.isManaging).accessibilityIdentifier("mobile.photos.album.refresh")
            } else if model.isManaging && !model.isUploading {
                ProgressView(L10n.string("photos.manage.working"))
            } else if model.pendingMutationID != nil && !model.uploadQueue.contains(where: { $0.state == .pendingReview }) {
                Text(L10n.string("photos.album.recovery.pending"))
                Button(L10n.string("mobile.photos.album.refresh")) { model.reviewPendingMutation() }
                    .disabled(model.isManaging).accessibilityIdentifier("mobile.photos.album.refresh")
            } else if let message = model.managementMessage, model.pendingMutationID == nil {
                Text(isAlbumContinuation ? L10n.string("mobile.photos.album.partial") : message).accessibilityIdentifier("mobile.photos.album.result")
            }
            if model.retryableManagementMutation != nil && !model.isManaging && model.pendingMutationID == nil {
                Button(L10n.string("photos.retry")) { model.continuePartialManagement() }
                    .disabled(!model.canStartManagementMutation).accessibilityIdentifier("mobile.photos.album.continue")
            }
            if let url = model.managementLink, model.pendingMutationID == nil, !model.isManaging { MobilePhotoSharingLink(url: url) }
        }.font(.callout).frame(maxWidth: .infinity).padding(.horizontal)
    }
}
