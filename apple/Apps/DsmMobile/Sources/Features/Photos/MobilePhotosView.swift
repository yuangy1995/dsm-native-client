import DsmCore
import DsmLocalization
import SwiftUI

struct MobilePhotosView: View {
    @Bindable var model: MobileAppModel
    var onOpenPhoto: ((PhotoLibraryItem) -> Void)?
    var onSaveCopy: ((PhotoLibraryItem) -> Void)?
    var onShare: ((PhotoLibraryItem) -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var browseMode = PhotoBrowseMode.albums
    @State private var timeline = MobilePhotoTimelineModel()
    @State private var viewer = MobilePhotoViewerModel()
    @State private var showsPreviewInspector = false
    @State private var showsPreviewFullScreen = false
    @State private var showsPreviewDetails = false
    @State private var restoresPreviewInspectorAfterFullScreen = false

    private var library: MobilePhotoLibraryModel { model.photoLibraryModel }
    private var state: MobilePhotoLibraryProfileState { library.state }
    private var preview: MobileFilePreviewModel { model.filePreviewModel }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                regularLayout
            } else {
                compactLayout
            }
        }
        .navigationTitle(L10n.string("mobile.photos.title"))
        .toolbar { photosToolbar }
        .refreshable {
            if state.spaces.isEmpty {
                await library.reload()
            } else if browseMode == .timeline {
                await timeline.refresh()
            } else {
                await library.reload()
            }
        }
        .inspector(isPresented: $showsPreviewInspector) {
            previewPresentation
                .inspectorColumnWidth(min: 320, ideal: 420, max: 560)
        }
        .fullScreenCover(isPresented: $showsPreviewFullScreen, onDismiss: previewPresentationDidDismiss) {
            previewPresentation
        }
        .sheet(item: documentPresentationBinding, onDismiss: {
            model.documentTransferController.presentationDidDismiss()
        }) { presentation in
            switch presentation.intent {
            case .exportCopy:
                MobileDocumentExporter(url: presentation.url) {
                    model.documentTransferController.requestDismiss(taskID: presentation.taskID)
                }
            case .share:
                MobileShareSheet(url: presentation.url) {
                    model.documentTransferController.requestDismiss(taskID: presentation.taskID)
                }
            case .upload:
                EmptyView()
            }
        }
        .alert(L10n.string("mobile.documents.error-title"), isPresented: documentFailureBinding) {
            Button(L10n.string("mobile.documents.dismiss")) {
                model.documentTransferController.clearFailure()
            }
        } message: {
            Text(documentFailureMessage)
        }
        .task(id: activationIdentity) { await activatePhotoContext() }
        .onChange(of: model.activeProfile?.id) { _, _ in
            resetPreviewPresentation()
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            adaptPreviewPresentation(to: sizeClass)
        }
        .onChange(of: browseMode) { _, mode in
            guard mode == .timeline else { return }
            Task { await timeline.show(space: library.state.selectedSpace) }
        }
        .onChange(of: showsPreviewInspector) { _, isPresented in
            if !isPresented,
               !showsPreviewFullScreen,
               !restoresPreviewInspectorAfterFullScreen {
                preview.close()
                viewer.close()
                showsPreviewDetails = false
            }
        }
        .onDisappear {
            library.cancelAllWork()
            timeline.cancelAllWork()
            viewer.close()
        }
    }

    private var compactLayout: some View {
        pageContent
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            spaceSidebar
                .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
            Divider()
            pageContent
        }
    }

    private var spaceSidebar: some View {
        List(state.spaces, selection: spaceSelection) { space in
            Label(space.title, systemImage: space.kind == .personal ? "person.crop.rectangle.stack" : "person.2.crop.square.stack")
                .tag(space.kind)
                .frame(minHeight: 44)
        }
        .listStyle(.sidebar)
        .navigationTitle(L10n.string("mobile.photos.space"))
        .accessibilityLabel(L10n.string("mobile.photos.space"))
    }

    @ViewBuilder
    private var pageContent: some View {
        VStack(spacing: 0) {
            Picker(L10n.string("mobile.photos.mode.title"), selection: $browseMode) {
                Text(L10n.string("mobile.photos.mode.albums")).tag(PhotoBrowseMode.albums)
                Text(L10n.string("mobile.photos.mode.timeline")).tag(PhotoBrowseMode.timeline)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, horizontalSizeClass == .regular ? 16 : 12)
            .padding(.vertical, 8)
            .frame(minHeight: 44)

            if browseMode == .timeline {
                MobilePhotoTimelineView(
                    model: timeline,
                    compact: horizontalSizeClass != .regular,
                    onOpenPhoto: openPhoto,
                    onSaveCopy: saveCopy,
                    onShare: share
                )
            } else {
                albumContent
            }
        }
    }

    @ViewBuilder
    private var albumContent: some View {
        if state.isDiscoveringSpaces && state.spaces.isEmpty {
            loadingView(L10n.string("mobile.photos.loading.spaces"))
        } else if state.pageState == .loading {
            loadingView(L10n.string("mobile.photos.loading.album"))
        } else if state.pageState == .error {
            errorView
        } else if state.spaces.isEmpty {
            noSpacesView
        } else if state.pageState == .filteredEmpty {
            filteredEmptyView
        } else if state.pageState == .empty {
            emptyAlbumView
        } else {
            MobilePhotoGrid(
                items: state.page.items,
                library: library,
                compact: horizontalSizeClass != .regular,
                isLoadingMore: state.isLoadingMore,
                loadMoreFailed: state.loadMoreFailed,
                hasMore: state.page.hasMore,
                onOpenFolder: openFolder,
                onOpenPhoto: openPhoto,
                onSaveCopy: saveCopy,
                onShare: share,
                onLoadMore: loadMore
            )
        }
    }

    private var previewPresentation: some View {
        NavigationStack {
            Group {
                if showsPreviewDetails,
                   (preview.state.details ?? preview.state.selectedItem) != nil {
                    MobilePhotoMetadataView(viewer: viewer, previewState: preview.state)
                } else {
                    MobileFilePreviewView(
                        state: preview.state,
                        mediaSource: preview.mediaSource,
                        onCancel: preview.cancel,
                        onRetry: retryPreview,
                        onClose: closePreview,
                        onShowDetails: { showsPreviewDetails = true },
                        onOpenFullScreen: openPreviewFullScreen,
                        canOpenFullScreen: horizontalSizeClass == .regular && !showsPreviewFullScreen,
                        onQuickLookDismiss: previewPresentationDidDismiss
                    )
                }
            }
            .navigationTitle(preview.state.details?.name ?? preview.state.selectedItem?.name ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsPreviewDetails {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            showsPreviewDetails = false
                        } label: {
                            Image(systemName: "chevron.backward")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(L10n.string("mobile.files.back"))
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(action: closePreview) {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel(L10n.string("mobile.files.preview.action.close"))
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    MobilePhotoViewerNavigationControls(
                        state: viewer.state,
                        onPrevious: openPreviousPhoto,
                        onNext: openNextPhoto,
                        onSaveCopy: saveCurrentPhotoCopy,
                        onShare: shareCurrentPhoto
                    )
                }
            }
        }
    }

    private func loadingView(_ title: String) -> some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
        }
        .fillsAvailableContentArea(alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }

    private var noSpacesView: some View {
        ContentUnavailableView {
            Label(L10n.string("mobile.photos.empty.spaces.title"), systemImage: "photo.stack")
        } description: {
            Text(L10n.string("mobile.photos.empty.spaces.message"))
        } actions: {
            retryButton
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var emptyAlbumView: some View {
        ContentUnavailableView {
            Label(L10n.string("mobile.photos.empty.album.title"), systemImage: "photo.on.rectangle")
        } description: {
            Text(L10n.string("mobile.photos.empty.album.message"))
        } actions: {
            retryButton
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var filteredEmptyView: some View {
        ContentUnavailableView {
            Label(L10n.string("mobile.photos.empty.filtered.title"), systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text(L10n.string("mobile.photos.empty.filtered.message"))
        } actions: {
            Button(L10n.string("mobile.photos.action.clear-filters")) {
                library.setFilter(.all)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var errorView: some View {
        ContentUnavailableView {
            Label(L10n.string("mobile.photos.error.title"), systemImage: "exclamationmark.triangle")
        } actions: {
            retryButton
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var retryButton: some View {
        Button(L10n.string("mobile.photos.action.retry")) {
            Task { await library.reload() }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .frame(minWidth: 44, minHeight: 44)
    }

    @ToolbarContentBuilder
    private var photosToolbar: some ToolbarContent {
        if browseMode == .albums, !state.pathHistory.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Task { await library.goBack() }
                } label: {
                    Image(systemName: "chevron.backward")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.string("mobile.files.back"))
            }
        }

        if browseMode == .albums {
            ToolbarItem(placement: .primaryAction) {
            Menu {
                if horizontalSizeClass != .regular, state.spaces.count > 1 {
                    Picker(L10n.string("mobile.photos.space"), selection: spaceSelection) {
                        ForEach(state.spaces) { space in
                            Text(space.title).tag(Optional(space.kind))
                        }
                    }
                }
                Picker(L10n.string("mobile.photos.filter.title"), selection: filterSelection) {
                    Text(L10n.string("mobile.photos.filter.all")).tag(MobilePhotoFilter.all)
                    Text(L10n.string("mobile.photos.filter.images")).tag(MobilePhotoFilter.images)
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.string("mobile.photos.filter.title"))
            }
        } else if horizontalSizeClass != .regular, state.spaces.count > 1 {
            ToolbarItem(placement: .secondaryAction) {
                Menu {
                    Picker(L10n.string("mobile.photos.space"), selection: spaceSelection) {
                        ForEach(state.spaces) { space in
                            Text(space.title).tag(Optional(space.kind))
                        }
                    }
                } label: {
                    Image(systemName: "person.2.crop.square.stack")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.string("mobile.photos.space"))
            }
        }
    }

    private var spaceSelection: Binding<PhotoSpaceKind?> {
        Binding(
            get: { state.selectedSpace?.kind },
            set: { kind in
                guard let kind else { return }
                Task {
                    await library.selectSpace(kind)
                    if browseMode == .timeline {
                        await timeline.show(space: library.state.selectedSpace)
                    }
                }
            }
        )
    }

    private var filterSelection: Binding<MobilePhotoFilter> {
        Binding(
            get: { state.filter },
            set: { library.setFilter($0) }
        )
    }

    private func openFolder(_ item: PhotoLibraryItem) {
        Task { await library.openFolder(item) }
    }

    private func loadMore() {
        Task { await library.loadMore() }
    }

    private func openPhoto(_ item: PhotoLibraryItem) {
        guard let item = canonicalPhotoItem(item) else { return }
        if let onOpenPhoto {
            onOpenPhoto(item)
            return
        }
        guard let repository = model.fileRepository else { return }
        guard viewer.open(item, visibleItems: visiblePhotoSnapshot) else { return }
        showsPreviewDetails = false
        restoresPreviewInspectorAfterFullScreen = false
        if horizontalSizeClass == .regular {
            showsPreviewFullScreen = false
            showsPreviewInspector = true
        } else {
            showsPreviewInspector = false
            showsPreviewFullScreen = true
        }
        Task { await preview.open(item.fileItem, service: repository) }
    }

    private func retryPreview() {
        guard let repository = model.fileRepository else { return }
        showsPreviewDetails = false
        Task { await preview.retry(service: repository) }
    }

    private func openPreviewFullScreen() {
        guard horizontalSizeClass == .regular,
              showsPreviewInspector,
              preview.state.phase != .inactive else { return }
        restoresPreviewInspectorAfterFullScreen = true
        showsPreviewInspector = false
        Task { @MainActor in
            await Task.yield()
            guard restoresPreviewInspectorAfterFullScreen,
                  horizontalSizeClass == .regular,
                  preview.state.phase != .inactive else {
                restoresPreviewInspectorAfterFullScreen = false
                return
            }
            showsPreviewFullScreen = true
        }
    }

    private func closePreview() {
        showsPreviewDetails = false
        restoresPreviewInspectorAfterFullScreen = false
        showsPreviewFullScreen = false
        showsPreviewInspector = false
        preview.close()
        viewer.close()
    }

    private func previewPresentationDidDismiss() {
        guard !showsPreviewFullScreen else { return }
        if restoresPreviewInspectorAfterFullScreen {
            restoresPreviewInspectorAfterFullScreen = false
            if horizontalSizeClass == .regular,
               preview.state.phase != .inactive {
                showsPreviewInspector = true
                return
            }
        }
        guard !showsPreviewInspector, !showsPreviewFullScreen else { return }
        showsPreviewDetails = false
        preview.close()
        viewer.close()
    }

    private func resetPreviewPresentation() {
        showsPreviewDetails = false
        restoresPreviewInspectorAfterFullScreen = false
        showsPreviewFullScreen = false
        showsPreviewInspector = false
        preview.close()
        viewer.activate(
            profileID: model.activeProfile?.id,
            fileRepository: model.fileRepository
        )
    }

    private func activatePhotoContext() async {
        model.documentTransferController.setActiveProfile(model.activeProfile?.id)
        if viewer.activate(
            profileID: model.activeProfile?.id,
            fileRepository: model.fileRepository
        ) {
            showsPreviewDetails = false
            restoresPreviewInspectorAfterFullScreen = false
            showsPreviewFullScreen = false
            showsPreviewInspector = false
            preview.close()
        }
        preview.activate(profileID: model.activeProfile?.id)
        timeline.activate(
            profileID: model.activeProfile?.id,
            repository: model.photoRepository,
            repositoryProfileID: model.fileRepository?.profileID
        )
        await library.activate(
            profileID: model.activeProfile?.id,
            repository: model.photoRepository
        )
        if browseMode == .timeline {
            await timeline.show(space: library.state.selectedSpace)
        }
    }

    private var activationIdentity: MobilePhotoActivationIdentity {
        MobilePhotoActivationIdentity(
            profileID: model.activeProfile?.id,
            fileRepository: model.fileRepository.map(ObjectIdentifier.init)
        )
    }

    private var visiblePhotoSnapshot: [PhotoLibraryItem] {
        let candidates = browseMode == .timeline ? timeline.visibleItems : state.page.items
        return candidates.filter { !$0.isFolder }
    }

    private func openPreviousPhoto() {
        guard let item = viewer.movePrevious() else { return }
        openSnapshotPhoto(item)
    }

    private func openNextPhoto() {
        guard let item = viewer.moveNext() else { return }
        openSnapshotPhoto(item)
    }

    private func openSnapshotPhoto(_ item: PhotoLibraryItem) {
        guard viewer.state.profileID == model.activeProfile?.id,
              let repository = model.fileRepository,
              repository.profileID == item.profileID else {
            viewer.close()
            return
        }
        showsPreviewDetails = false
        Task { await preview.open(item.fileItem, service: repository) }
    }

    private func saveCurrentPhotoCopy() {
        guard let item = viewer.state.selectedItem else { return }
        saveCopy(item)
    }

    private func shareCurrentPhoto() {
        guard let item = viewer.state.selectedItem else { return }
        share(item)
    }

    private func adaptPreviewPresentation(to sizeClass: UserInterfaceSizeClass?) {
        guard preview.state.phase != .inactive else { return }
        if sizeClass == .regular {
            showsPreviewInspector = !showsPreviewFullScreen
        } else {
            restoresPreviewInspectorAfterFullScreen = false
            showsPreviewFullScreen = true
            showsPreviewInspector = false
        }
    }

    private func saveCopy(_ item: PhotoLibraryItem) {
        guard let item = canonicalPhotoItem(item) else { return }
        if let onSaveCopy {
            onSaveCopy(item)
        } else {
            startDownload(item, intent: .exportCopy)
        }
    }

    private func share(_ item: PhotoLibraryItem) {
        guard let item = canonicalPhotoItem(item) else { return }
        if let onShare {
            onShare(item)
        } else {
            startDownload(item, intent: .share)
        }
    }

    private func startDownload(_ item: PhotoLibraryItem, intent: MobileDocumentIntent) {
        guard let activeProfileID = model.activeProfile?.id,
              item.profileID == activeProfileID,
              let repository = model.fileRepository,
              repository.profileID == activeProfileID else { return }
        let context = MobileDocumentDownloadContext(
            profileID: item.profileID,
            remotePath: item.path,
            fileName: item.name,
            intent: intent
        )
        let service = MobileFileTransferService(repository: repository)
        Task {
            _ = await model.documentTransferController.startDownload(context: context, service: service)
        }
    }

    private func canonicalPhotoItem(_ item: PhotoLibraryItem) -> PhotoLibraryItem? {
        guard let activeProfileID = model.activeProfile?.id,
              item.profileID == activeProfileID,
              library.activeProfileID == activeProfileID,
              timeline.activeProfileID == activeProfileID,
              let repository = model.fileRepository,
              repository.profileID == activeProfileID else { return nil }
        let candidates = browseMode == .timeline ? timeline.state.items : state.page.items
        return candidates.first {
            $0.id == item.id &&
            $0.profileID == item.profileID &&
            $0.path == item.path &&
            $0.kind == item.kind
        }
    }

    private var documentPresentationBinding: Binding<MobileDocumentPresentation?> {
        Binding(
            get: { model.documentTransferController.presentation },
            set: { value in
                guard value == nil,
                      let taskID = model.documentTransferController.presentation?.taskID else { return }
                model.documentTransferController.requestDismiss(taskID: taskID)
            }
        )
    }

    private var documentFailureBinding: Binding<Bool> {
        Binding(
            get: { model.documentTransferController.failure != nil },
            set: { if !$0 { model.documentTransferController.clearFailure() } }
        )
    }

    private var documentFailureMessage: String {
        switch model.documentTransferController.failure {
        case .localStorageFull: L10n.string("mobile.documents.error-local-space")
        case .remoteStorageFull: L10n.string("mobile.documents.error-nas-space")
        case .authenticationRequired: L10n.string("mobile.documents.error-authentication")
        case .otpRequired: L10n.string("mobile.documents.error-otp")
        case .permissionDenied: L10n.string("mobile.documents.error-permission")
        case .networkUnavailable: L10n.string("mobile.documents.error-network")
        case .unknown, .none: L10n.string("mobile.documents.error-unknown")
        }
    }
}

private struct MobilePhotoActivationIdentity: Hashable {
    let profileID: UUID?
    let fileRepository: ObjectIdentifier?
}
