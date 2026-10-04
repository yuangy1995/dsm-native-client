import DsmCore
import DsmLocalization
import DsmPhotosFeature
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct MobilePhotoUploadForm: View {
    @Bindable var uploads: MobilePhotoUploadImportModel
    let draftID: UUID
    let submitted: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [PhotosPickerItem] = []
    @State private var showsFiles = false
    @State private var picksFolder = false

    var body: some View {
        NavigationStack {
            Form {
                if let destination = uploads.destination {
                    Section {
                        Text(L10n.string("photos.upload.destination", destination.album?.name ?? destination.folder?.name ?? L10n.string("photos.library.timeline")))
                        if uploads.model.spaces.count > 1 {
                            Text(L10n.string(destination.space == .personal ? "mobile.photos.source.mine" : "mobile.photos.source.shared"))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    PhotosPicker(selection: $selection, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current) {
                        Label(L10n.string("mobile.photos.upload.choosePhotos"), systemImage: "photo.on.rectangle")
                    }.accessibilityIdentifier("mobile.photos.upload.choosePhotos")
                    Button { picksFolder = false; showsFiles = true } label: {
                        Label(L10n.string("mobile.photos.upload.chooseFiles"), systemImage: "doc")
                    }.accessibilityIdentifier("mobile.photos.upload.chooseFiles")
                    if uploads.model.managementFeatures.contains(.folders),
                       !uploads.model.uploadsDirectlyToAlbum(uploads.destination?.album, space: uploads.destination?.space ?? .personal) {
                        Button { picksFolder = true; showsFiles = true } label: {
                            Label(L10n.string("mobile.photos.upload.chooseFolder"), systemImage: "folder")
                        }
                    }
                }.disabled(uploads.isPreparing)
                if uploads.isPreparing {
                    ProgressView(L10n.string("mobile.photos.import.preparing"))
                }
                if let error = uploads.error { Text(error).foregroundStyle(.red) }
                if !uploads.files.isEmpty {
                    Section(L10n.string("photos.upload.fileCount", uploads.files.count)) {
                        ForEach(uploads.files) { file in
                            LabeledContent {
                                Text(file.size.formatted(.byteCount(style: .file).locale(L10n.locale)))
                            } label: { Text(file.url.lastPathComponent).lineLimit(2) }
                        }
                    }
                    Section {
                        if uploads.includesDirectory {
                            Toggle(L10n.string("photos.upload.preserveDirectories"), isOn: $uploads.preservesDirectories)
                        }
                        if uploads.isLoadingDefaults { ProgressView(L10n.string("mobile.photos.preferences.loading")) }
                        if let error = uploads.defaultsError {
                            Text(error).foregroundStyle(.secondary)
                            Button(L10n.string("photos.retry")) { uploads.loadDefaults() }
                        }
                        Picker(L10n.string("photos.duplicates.upload"), selection: $uploads.duplicate) {
                            ForEach(SynologyPhotoDuplicateSettings.Upload.allCases, id: \.self) { value in
                                Text(L10n.string(value == .ignore ? "photos.duplicates.ignore" : "photos.duplicates.rename")).tag(value)
                            }
                        }.disabled(uploads.isLoadingDefaults || uploads.defaultsError != nil)
                    }
                }
                if uploads.skippedCount > 0 { Text(L10n.string("photos.upload.skippedCount", uploads.skippedCount)) }
            }
            .navigationTitle(L10n.string("photos.manage.upload"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.delete.cancel")) { uploads.cancel(); dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("photos.manage.upload")) {
                        if uploads.submit() { dismiss(); submitted() }
                    }.disabled(!uploads.canSubmit).accessibilityIdentifier("mobile.photos.upload.submit")
                }
            }
        }
        .onChange(of: selection) { _, value in
            guard !value.isEmpty else { return }
            uploads.preparePhotos(value.map(MobileSystemPhotosPickerItem.init), draftID: draftID)
            selection = []
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: picksFolder ? [.folder] : [.image, .movie],
            allowsMultipleSelection: true, onCompletion: selectedFiles)
    }

    private func selectedFiles(_ result: Result<[URL], Error>) {
        guard uploads.draftID == draftID else { return }
        switch result {
        case .success(let urls): uploads.prepareFiles(urls, draftID: draftID)
        case .failure: uploads.error = L10n.string("mobile.photos.import.failed.item")
        }
    }
}

struct MobilePhotoUploadQueueView: View {
    @Bindable var model: SynologyPhotosModel
    @Bindable var uploads: MobilePhotoUploadImportModel
    @Environment(\.dismiss) private var dismiss
    @State private var reselectionID: UUID?
    @State private var showsReselection = false

    var body: some View {
        NavigationStack {
            List {
                if uploads.isPreparing { ProgressView(L10n.string("mobile.photos.import.preparing")) }
                if let error = uploads.error { Text(error).foregroundStyle(.red) }
                if let error = model.uploadPersistenceError {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button(L10n.string("photos.retry")) { Task { await model.retryUploadPersistence() } }
                            .disabled(model.isManaging)
                    }
                }
                if model.uploadQueue.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("photos.upload.empty"), systemImage: "square.and.arrow.up")
                    } description: { Text(L10n.string("photos.upload.emptyHint")) }
                }
                ForEach(model.uploadQueue) { entry in
                    Section {
                        Text(entry.file.url.lastPathComponent).font(.headline)
                        Text(stateTitle(entry.state)).accessibilityIdentifier("mobile.photos.upload.state.\(entry.state.rawValue)")
                        Text(L10n.string("photos.upload.destination", entry.album?.name ?? entry.folder?.name ?? L10n.string("photos.library.timeline")))
                            .foregroundStyle(.secondary)
                        if entry.state == .uploading { ProgressView(value: entry.progress) }
                        if entry.state == .addingToAlbum || entry.state == .preparingFolders { ProgressView() }
                        if let error = entry.error { Text(error).foregroundStyle(.red) }
                        if [.failed, .cancelled].contains(entry.state) {
                            if entry.uploadedPhoto == nil && entry.file.requiresSourceSelection {
                                Text(L10n.string("photos.upload.recovery.sourceNeeded")).foregroundStyle(.secondary)
                                Button(L10n.string("photos.upload.recovery.reselect")) { reselectionID = entry.id; showsReselection = true }
                                    .disabled(uploads.isPreparing || model.isManaging || model.pendingMutationID != nil)
                            } else {
                                Button(L10n.string(entry.uploadedPhoto == nil ? "photos.retry" : "photos.upload.retryAlbum")) { model.retryUpload(entry.id) }
                                    .disabled(model.isManaging || model.pendingMutationID != nil || model.uploadPersistenceError != nil)
                                    .accessibilityIdentifier("mobile.photos.upload.retry")
                            }
                        }
                        if entry.state == .pendingReview {
                            Text(L10n.string("mobile.photos.upload.pendingHint")).foregroundStyle(.secondary)
                            Button(L10n.string("mobile.photos.upload.refresh")) { model.reviewPendingMutation() }
                                .disabled(model.isManaging).accessibilityIdentifier("mobile.photos.upload.refresh")
                        }
                        if model.canOpenUpload(entry.id, destination: .folder) {
                            Button(L10n.string("photos.upload.openFolder")) { open(entry.id, destination: .folder) }
                                .disabled(model.isOpeningUploadDestination || model.isBrowsingBlocked || model.isLoading)
                        }
                        if model.canOpenUpload(entry.id, destination: .album) {
                            Button(L10n.string("photos.upload.openAlbum")) { open(entry.id, destination: .album) }
                                .disabled(model.isOpeningUploadDestination || model.isBrowsingBlocked || model.isLoading)
                        }
                        if model.canCancelUpload(entry.id) {
                            Button(L10n.string("photos.upload.cancelQueued")) { model.cancelUpload(entry.id) }
                        }
                        if model.canClearUpload(entry.id) {
                            Button(L10n.string("photos.upload.clearEntry")) { uploads.clear(entry.id) }
                                .accessibilityIdentifier("mobile.photos.upload.clear")
                        }
                    }
                }
                if let error = model.uploadNavigationError { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(L10n.string("photos.upload.queue"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.media.close")) { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    if model.canResumeUploads {
                        Button(L10n.string("photos.upload.recovery.resume")) { model.resumeUploads() }
                            .accessibilityIdentifier("mobile.photos.upload.resume")
                    } else if model.isUploading {
                        Button(L10n.string("photos.upload.stopAfterCurrent")) { model.stopUploadQueue() }
                            .disabled(model.stopsAfterCurrentUpload)
                    }
                }
            }
        }
        .fileImporter(isPresented: $showsReselection,
            allowedContentTypes: [.image, .movie]) { result in
                guard let id = reselectionID else { return }
                reselectionID = nil
                if case .success(let url) = result { uploads.reselect(id, url: url) }
            }
    }

    private func open(_ id: UUID, destination: SynologyPhotosModel.UploadDestination) {
        Task { if await model.openUpload(id, destination: destination) { dismiss() } }
    }

    private func stateTitle(_ state: PhotoUploadEntry.State) -> String {
        switch state {
        case .queued: L10n.string("photos.upload.state.queued")
        case .preparingFolders: L10n.string("photos.upload.state.preparingFolders")
        case .uploading: L10n.string("photos.upload.state.uploading")
        case .addingToAlbum: L10n.string("photos.upload.state.addingToAlbum")
        case .completed: L10n.string("photos.upload.state.completed")
        case .skipped: L10n.string("photos.upload.state.skipped")
        case .failed: L10n.string("photos.upload.state.failed")
        case .pendingReview: L10n.string("mobile.photos.upload.pending")
        case .cancelled: L10n.string("photos.upload.state.cancelled")
        }
    }
}
