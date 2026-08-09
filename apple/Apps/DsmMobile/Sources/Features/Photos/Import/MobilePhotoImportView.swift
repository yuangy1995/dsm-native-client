import DsmCore
import DsmLocalization
import PhotosUI
import SwiftUI

struct MobilePhotoImportButton: View {
    @Bindable var importModel: MobilePhotoImportModel
    let destination: MobilePhotoImportDestination
    let repository: any FileRepository
    let controller: MobileDocumentTransferController
    let coordinator: MobileTransferCoordinator
    let onConfirmedSuccess: @MainActor @Sendable () async -> Void

    @State private var selection: PhotosPickerItem?
    @State private var showsFeedback = false

    var body: some View {
        let isPreparing = importModel.isPreparing
        PhotosPicker(
            selection: $selection,
            matching: .any(of: [.images, .videos]),
            preferredItemEncoding: .current
        ) {
            if isPreparing {
                ProgressView()
                    .frame(width: 44, height: 44)
                    .accessibilityLabel(L10n.string("mobile.photos.import.preparing"))
            } else {
                Label(
                    L10n.string("mobile.photos.import.action"),
                    systemImage: "square.and.arrow.down"
                )
                .frame(minWidth: 44, minHeight: 44)
            }
        }
        .disabled(isPreparing)
        .accessibilityHint(
            L10n.string("mobile.photos.import.target", destination.folderPath)
        )
        .onChange(of: selection) { _, item in
            guard let item else { return }
            selection = nil
            importModel.begin(
                item: MobileSystemPhotosPickerItem(item),
                destination: destination,
                repositoryProfileID: repository.profileID,
                repositoryIdentity: ObjectIdentifier(repository as AnyObject),
                controller: controller,
                service: MobileFileTransferService(repository: repository),
                coordinator: coordinator,
                onConfirmedSuccess: onConfirmedSuccess
            )
        }
        .onChange(of: importModel.phase) { _, phase in
            switch phase {
            case .queued, .failed:
                showsFeedback = true
            case .idle, .preparing:
                break
            }
        }
        .alert(feedbackTitle, isPresented: $showsFeedback) {
            Button(L10n.string("mobile.photos.import.dismiss")) {
                importModel.dismissFeedback()
            }
        } message: {
            Text(feedbackMessage)
        }
    }

    private var feedbackTitle: String {
        switch importModel.phase {
        case .queued:
            L10n.string("mobile.photos.import.queued.title")
        case .failed:
            L10n.string("mobile.photos.import.failed.title")
        case .idle, .preparing:
            ""
        }
    }

    private var feedbackMessage: String {
        switch importModel.phase {
        case .queued:
            L10n.string("mobile.photos.import.queued.message")
        case .failed(.unavailable):
            L10n.string("mobile.photos.import.failed.destination")
        case .failed(.itemUnavailable):
            L10n.string("mobile.photos.import.failed.item")
        case .failed(.preparationFailed):
            L10n.string("mobile.photos.import.failed.generic")
        case .idle, .preparing:
            ""
        }
    }
}
