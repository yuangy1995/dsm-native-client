import DsmLocalization
import SwiftUI

struct MobilePhotoTemporarySharingForm: View {
    @Bindable var temporary: MobilePhotoTemporarySharingModel
    let draft: MobilePhotoTemporarySharingModel.Draft
    @Environment(\.dismiss) private var dismiss
    @State private var configuring = false
    var body: some View {
        Group {
            if let sharingDraft = temporary.sharing.draft {
                MobilePhotoSharingForm(sharing: temporary.sharing, draft: sharingDraft)
                    .onAppear { configuring = true }
            } else {
                NavigationStack {
                    Form {
                        Text(L10n.string("photos.selection.count", draft.photos.count))
                        TextField(L10n.string("photos.manage.albumName"), text: $temporary.name)
                            .accessibilityIdentifier("mobile.photos.temporary.name").disabled(temporary.isCreating)
                        Text(L10n.string("photos.selectionShare.hint")).foregroundStyle(.secondary)
                        if temporary.isCreating { ProgressView(L10n.string("mobile.photos.temporary.preparing")) }
                        if let error = temporary.error { Text(error).foregroundStyle(.red) }
                        if temporary.model.pendingMutationID != nil {
                            Text(temporary.model.managementMessage ?? L10n.string("photos.manage.pending"))
                            Button(L10n.string("photos.library.refresh")) { temporary.model.reviewPendingMutation() }.disabled(temporary.model.isManaging)
                        }
                    }
                    .navigationTitle(L10n.string("photos.selectionShare.title"))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button(L10n.string("photos.delete.cancel")) { if temporary.cancel() { dismiss() } }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(L10n.string("photos.selectionShare.configure")) { temporary.create() }
                                .disabled(!temporary.canCreate).accessibilityIdentifier("mobile.photos.temporary.create")
                        }
                    }
                }
            }
        }
        .interactiveDismissDisabled()
        .onChange(of: temporary.model.isManaging) { _, _ in temporary.creationChanged() }
        .onChange(of: temporary.sharing.draft?.id) { _, value in
            if configuring, value == nil { temporary.clear(); dismiss() }
        }
    }
}
