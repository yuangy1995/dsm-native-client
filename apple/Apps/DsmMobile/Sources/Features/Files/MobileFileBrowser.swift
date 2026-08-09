import DsmCore
import DsmLocalization
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct MobileFileBrowserActivationIdentity: Hashable {
    let profileID: UUID?
    let repositoryIdentity: ObjectIdentifier?
}

struct MobileFileBrowser: View {
    @Bindable var model: MobileAppModel
    @State private var isImportingFile = false
    @State private var pendingUploadContext: MobileDocumentPickerContext?
    @State private var pendingUploadService: MobileFileTransferService?
    @State private var showsPreviewInspector = false
    @State private var showsPreviewFullScreen = false
    @State private var showsPreviewDetails = false
    @State private var showsLocations = false
    @State private var restoresPreviewInspectorAfterFullScreen = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var browser: MobileFileBrowserModel { model.fileBrowserModel }
    private var locations: MobileFileLocationsModel { browser.locations }
    private var mutation: MobileFileItemMutationModel { browser.mutations }
    private var copyMove: MobileFileCopyMoveModel { browser.copyMove }
    private var state: MobileFileBrowserProfileState { browser.state }
    private var preview: MobileFilePreviewModel { model.filePreviewModel }
    private var activationIdentity: MobileFileBrowserActivationIdentity {
        MobileFileBrowserActivationIdentity(
            profileID: model.activeProfile?.id,
            repositoryIdentity: model.fileRepository.map { ObjectIdentifier($0) }
        )
    }

    var body: some View {
        Group {
            if state.pageState == .filteredEmpty,
               state.filteredEmptyReason == .typeFilter {
                typeFilterEmptyView
            } else {
                MobilePageStateView(
                    state: state.pageState,
                    labels: pageStateLabels,
                    emptySystemImage: "folder",
                    filteredEmptySystemImage: "magnifyingglass",
                    retryAction: refresh
                ) {
                    fileCollection
                }
            }
        }
        .searchable(text: searchBinding, prompt: L10n.string("ui.9c8bd1565def7849"))
        .onSubmit(of: .search, submitSearch)
        .refreshable { await refreshNow() }
        .toolbar { browserToolbar }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false,
            onCompletion: handleFileImport
        )
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
        .sheet(isPresented: shareLinkPresentationBinding) {
            MobileFileShareLinkView(model: model.fileShareLinkModel)
        }
        .sheet(isPresented: $showsLocations) {
            MobileFileLocationsView(
                locations: locations,
                refresh: refreshLocations,
                openLocation: openLocation,
                cancelOpenLocation: browser.cancelLocationRequest
            )
        }
        .sheet(isPresented: mutationPresentationBinding) {
            if let repository = model.fileRepository {
                MobileFileItemMutationView(
                    mutation: mutation,
                    repository: repository,
                    didConfirm: mutationDidConfirm
                )
            }
        }
        .sheet(isPresented: copyMovePresentationBinding) {
            if let repository = model.fileRepository {
                MobileFileCopyMoveView(
                    copyMove: copyMove,
                    repository: repository,
                    didConfirm: copyMoveDidConfirm
                )
            }
        }
        .alert(L10n.string("mobile.documents.error-title"), isPresented: documentFailureBinding) {
            Button(L10n.string("mobile.documents.dismiss")) {
                model.documentTransferController.clearFailure()
            }
        } message: {
            Text(documentFailureMessage)
        }
        .inspector(isPresented: $showsPreviewInspector) {
            previewPresentation
                .inspectorColumnWidth(min: 320, ideal: 420, max: 560)
        }
        .fullScreenCover(isPresented: $showsPreviewFullScreen, onDismiss: previewPresentationDidDismiss) {
            previewPresentation
        }
        .task(id: activationIdentity) {
            model.documentTransferController.setActiveProfile(model.activeProfile?.id)
            preview.activate(profileID: model.activeProfile?.id)
            let profileID = model.activeProfile?.id
            let repository = model.fileRepository
            await browser.activate(profileID: profileID, repository: repository)
            mutation.activate(profileID: profileID, repository: repository)
            copyMove.activate(profileID: profileID, repository: repository)
            locations.activate(profileID: profileID, repository: repository)
            guard let profileID, let repository else { return }
            model.fileShareLinkModel.activate(profileID: profileID, repository: repository)
            await locations.loadIfNeeded(repository: repository)
            if browser.state.visibleKey == nil {
                await browser.refresh(repository: repository)
            }
        }
        .onChange(of: model.activeProfile?.id) { _, _ in
            resetPreviewPresentation()
        }
        .onChange(of: horizontalSizeClass) { _, sizeClass in
            adaptPreviewPresentation(to: sizeClass)
        }
        .onChange(of: showsPreviewInspector) { _, isPresented in
            if !isPresented,
               !showsPreviewFullScreen,
               !restoresPreviewInspectorAfterFullScreen {
                preview.close()
                showsPreviewDetails = false
            }
        }
        .onDisappear {
            browser.cancelRequest()
            locations.cancelRequest()
            mutation.deactivate()
            copyMove.deactivate()
            model.fileShareLinkModel.deactivate()
        }
    }

    private var previewPresentation: some View {
        NavigationStack {
            Group {
                if showsPreviewDetails,
                   let item = preview.state.details ?? preview.state.selectedItem {
                    MobileFileDetailsView(item: item)
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
            }
        }
    }

    @ViewBuilder
    private var fileCollection: some View {
        if state.layout == .grid {
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: horizontalSizeClass == .regular ? 150 : 120), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(state.page.items) { item in
                        gridItem(item)
                    }
                }
                .padding()
                paginationFooter
            }
        } else {
            List {
                ForEach(state.page.items) { item in
                    listItem(item)
                }
                paginationFooter
            }
            .listStyle(.plain)
        }
    }

    private func listItem(_ item: FileItem) -> some View {
        HStack(spacing: 8) {
            Button { primaryAction(for: item) } label: {
                HStack(spacing: 14) {
                    fileSymbol(item)
                    fileDescription(item)
                    Spacer(minLength: 8)
                    if item.isDirectory {
                        Image(systemName: "chevron.forward")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
                .contentShape(Rectangle())
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.isDirectory ? L10n.string("mobile.files.open-folder-hint") : L10n.string("mobile.files.open-preview-hint"))

            itemMenu(item)
        }
    }

    private func gridItem(_ item: FileItem) -> some View {
        VStack(spacing: 0) {
            Button { primaryAction(for: item) } label: {
                VStack(spacing: 10) {
                    fileSymbol(item)
                        .font(.largeTitle)
                    Text(item.name)
                        .font(.body)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(item.isDirectory ? L10n.string("ui.7c7802d8adaed72e") : formattedSize(item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 112)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.isDirectory ? L10n.string("mobile.files.open-folder-hint") : L10n.string("mobile.files.open-preview-hint"))

            Divider()
            itemMenu(item)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func fileSymbol(_ item: FileItem) -> some View {
        Image(systemName: item.isDirectory ? "folder.fill" : fileIcon(item))
            .font(.title3)
            .foregroundStyle(item.isDirectory ? .blue : .secondary)
            .frame(width: 32)
            .accessibilityHidden(true)
    }

    private func fileDescription(_ item: FileItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(item.name)
                .lineLimit(2)
            Text(item.isDirectory ? L10n.string("ui.7c7802d8adaed72e") : formattedSize(item))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.leading)
    }

    private func itemMenu(_ item: FileItem) -> some View {
        Menu {
            if canCopyMove(item) {
                Button {
                    beginCopyMove(.copy, item: item)
                } label: {
                    Label(
                        L10n.string("mobile.files.copy-move.copy.action"),
                        systemImage: "doc.on.doc"
                    )
                }
                Button {
                    beginCopyMove(.move, item: item)
                } label: {
                    Label(
                        L10n.string("mobile.files.copy-move.move.action"),
                        systemImage: "folder"
                    )
                }
            }
            if canRename(item) {
                Button {
                    beginRename(item)
                } label: {
                    Label(
                        L10n.string("mobile.files.mutation.rename.action"),
                        systemImage: "pencil"
                    )
                }
            }
            if !state.location.source.isReadOnlyLocation {
                Button {
                    beginShareLink(for: item)
                } label: {
                    Label(
                        L10n.string("mobile.files.share-link.action.create"),
                        systemImage: "link.badge.plus"
                    )
                }
            }
            if item.isDirectory {
                Button(L10n.string("ui.c771248e511fbf93")) { openDirectory(item) }
            } else {
                Button(L10n.string("mobile.documents.save-copy")) {
                    startDownload(item, intent: .exportCopy)
                }
                Button(L10n.string("mobile.documents.share")) {
                    startDownload(item, intent: .share)
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.string("mobile.files.item-actions", item.name))
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if state.loadMoreFailed {
            VStack(spacing: 8) {
                Label(L10n.string("mobile.files.load-more-error"), systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.string("mobile.files.retry-load-more"), action: loadMore)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        } else if state.isLoadingMore {
            ProgressView(L10n.string("mobile.files.loading-more"))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 8)
        } else if state.page.hasMore {
            Button(L10n.string("mobile.files.load-more"), action: loadMore)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 8)
        }
    }

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                showsLocations = true
            } label: {
                Image(systemName: "sidebar.left")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(model.fileRepository == nil)
            .accessibilityLabel(L10n.string("mobile.files.locations.open"))
        }
        if !state.pathHistory.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: goBack) { Image(systemName: "chevron.backward") }
                    .accessibilityLabel(L10n.string("mobile.files.back"))
            }
        }
        if !state.currentPath.isEmpty {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: goUp) { Image(systemName: "arrow.up") }
                    .accessibilityLabel(L10n.string("ui.2bab713fde4ebc53"))
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button(action: beginCreateFolder) {
                Image(systemName: "folder.badge.plus")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .disabled(!canCreateFolder)
            .accessibilityLabel(L10n.string("mobile.files.mutation.create.action"))
            sortAndFilterMenu
            Button(action: toggleLayout) {
                Image(systemName: state.layout == .list ? "square.grid.2x2" : "list.bullet")
            }
            .accessibilityLabel(L10n.string(state.layout == .list ? "mobile.files.show-grid" : "mobile.files.show-list"))
            Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                .disabled(state.isRefreshing)
                .accessibilityLabel(L10n.string("ui.aee88743413144a2"))
            Button(action: beginUpload) {
                Label(L10n.string("mobile.documents.upload"), systemImage: "square.and.arrow.up")
            }
            .disabled(model.fileRepository == nil || state.location.source.isReadOnlyLocation)
        }
    }

    private var sortAndFilterMenu: some View {
        Menu {
            Picker(L10n.string("mobile.files.sort-by"), selection: sortFieldBinding) {
                Text(L10n.string("mobile.files.sort.name"))
                    .tag(FileListSortField.name)
                if !state.currentPath.isEmpty {
                    Text(L10n.string("mobile.files.sort.size"))
                        .tag(FileListSortField.size)
                    Text(L10n.string("mobile.files.sort.modified"))
                        .tag(FileListSortField.modifiedTime)
                }
            }
            Picker(L10n.string("mobile.files.sort-direction"), selection: sortDirectionBinding) {
                Text(L10n.string("mobile.files.sort.ascending"))
                    .tag(FileListSortDirection.ascending)
                Text(L10n.string("mobile.files.sort.descending"))
                    .tag(FileListSortDirection.descending)
            }
            if !state.currentPath.isEmpty {
                Picker(L10n.string("mobile.files.filter"), selection: typeFilterBinding) {
                    Text(L10n.string("mobile.files.filter.all"))
                        .tag(FileListTypeFilter.all)
                    Text(L10n.string("mobile.files.filter.files"))
                        .tag(FileListTypeFilter.files)
                    Text(L10n.string("mobile.files.filter.folders"))
                        .tag(FileListTypeFilter.folders)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down.circle")
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(L10n.string("mobile.files.sort-filter"))
    }

    private var typeFilterEmptyView: some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.files.filter-empty.title"),
                systemImage: "line.3.horizontal.decrease.circle"
            )
        } description: {
            Text(L10n.string("mobile.files.filter-empty.message"))
        } actions: {
            Button(L10n.string("mobile.files.filter.show-all"), action: showAllTypes)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .frame(minWidth: 44, minHeight: 44)
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var pageStateLabels: MobilePageStateLabels {
        MobilePageStateLabels(
            loading: L10n.string("mobile.files.loading"),
            emptyTitle: L10n.string("ui.45d5c590513a6fdc"),
            emptyMessage: L10n.string("ui.6aabdc2485f34c84"),
            filteredEmptyTitle: L10n.string("mobile.files.no-results"),
            filteredEmptyMessage: L10n.string("ui.49e7a5872fdd5088"),
            errorTitle: L10n.string("mobile.files.load-error"),
            errorMessage: L10n.string("ui.5448ceb91a80e260"),
            retryTitle: L10n.string("ui.b8784c8dd5636ff2")
        )
    }

    private var searchBinding: Binding<String> {
        Binding(
            get: { state.query },
            set: { value in
                let previousQuery = browser.state.query
                let clearsPresentedSearch = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !previousQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                browser.setQuery(value)
                if clearsPresentedSearch { submitSearch() }
            }
        )
    }

    private var sortFieldBinding: Binding<FileListSortField> {
        Binding(
            get: { state.options.sortField },
            set: { updateOptions(sortField: $0) }
        )
    }

    private var sortDirectionBinding: Binding<FileListSortDirection> {
        Binding(
            get: { state.options.sortDirection },
            set: { updateOptions(sortDirection: $0) }
        )
    }

    private var typeFilterBinding: Binding<FileListTypeFilter> {
        Binding(
            get: { state.options.typeFilter },
            set: { updateOptions(typeFilter: $0) }
        )
    }

    private func primaryAction(for item: FileItem) {
        if item.isDirectory {
            openDirectory(item)
        } else {
            openPreview(item)
        }
    }

    private func openPreview(_ item: FileItem) {
        guard let repository = model.fileRepository else { return }
        showsPreviewDetails = false
        restoresPreviewInspectorAfterFullScreen = false
        if horizontalSizeClass == .regular {
            showsPreviewFullScreen = false
            showsPreviewInspector = true
        } else {
            showsPreviewInspector = false
            showsPreviewFullScreen = true
        }
        Task { await preview.open(item, service: repository) }
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
    }

    private func resetPreviewPresentation() {
        showsPreviewDetails = false
        restoresPreviewInspectorAfterFullScreen = false
        showsPreviewFullScreen = false
        showsPreviewInspector = false
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

    private func openDirectory(_ item: FileItem) {
        guard let repository = model.fileRepository else { return }
        Task { await browser.openDirectory(item, repository: repository) }
    }

    private func goBack() {
        guard let repository = model.fileRepository else { return }
        Task { await browser.goBack(repository: repository) }
    }

    private func goUp() {
        guard let repository = model.fileRepository else { return }
        Task { await browser.goUp(repository: repository) }
    }

    private func submitSearch() {
        guard let repository = model.fileRepository else { return }
        Task { await browser.submitSearch(repository: repository) }
    }

    private func refresh() {
        Task { await refreshNow() }
    }

    private func refreshNow() async {
        guard let repository = model.fileRepository else { return }
        await browser.refresh(repository: repository)
    }

    private func refreshLocations() async {
        guard let repository = model.fileRepository else { return }
        await locations.refresh(repository: repository)
    }

    private func openLocation(
        _ path: String,
        _ source: MobileFileLocationSource
    ) async -> Bool {
        guard let repository = model.fileRepository else { return false }
        prepareForLocationChange()
        return await browser.openLocation(path: path, source: source, repository: repository)
    }

    private func prepareForLocationChange() {
        resetPreviewPresentation()
        preview.close()
        model.fileShareLinkModel.dismiss()
    }

    private func loadMore() {
        guard let repository = model.fileRepository else { return }
        Task { await browser.loadMore(repository: repository) }
    }

    private func toggleLayout() {
        browser.setLayout(state.layout == .list ? .grid : .list)
    }

    private func showAllTypes() {
        updateOptions(typeFilter: .all)
    }

    private func updateOptions(
        sortField: FileListSortField? = nil,
        sortDirection: FileListSortDirection? = nil,
        typeFilter: FileListTypeFilter? = nil
    ) {
        guard let repository = model.fileRepository else { return }
        let options = FileListOptions(
            sortField: sortField ?? state.options.sortField,
            sortDirection: sortDirection ?? state.options.sortDirection,
            typeFilter: typeFilter ?? state.options.typeFilter
        )
        Task { await browser.setOptions(options, repository: repository) }
    }

    private func beginUpload() {
        guard !state.location.source.isReadOnlyLocation,
              let profileID = model.activeProfile?.id,
              let repository = model.fileRepository else { return }
        pendingUploadContext = MobileDocumentPickerContext(
            profileID: profileID,
            folderPath: state.currentPath.isEmpty ? "/" : state.currentPath,
            intent: .upload
        )
        pendingUploadService = MobileFileTransferService(repository: repository)
        isImportingFile = true
    }

    private var canCreateFolder: Bool {
        guard model.fileRepository != nil else { return false }
        return MobileFileItemMutationModel.canMutate(
            parentPath: state.currentPath,
            source: state.location.source,
            readOnlyRoots: readOnlyMutationRoots
        )
    }

    private func canRename(_ item: FileItem) -> Bool {
        guard let profileID = model.activeProfile?.id else { return false }
        return MobileFileItemMutationModel.canRename(
            item: item,
            parentPath: state.currentPath,
            source: state.location.source,
            readOnlyRoots: readOnlyMutationRoots,
            profileID: profileID
        )
    }

    private func beginCreateFolder() {
        guard canCreateFolder, let repository = model.fileRepository else { return }
        prepareForMutation()
        mutation.beginCreateFolder(
            parentPath: state.currentPath,
            source: state.location.source,
            readOnlyRoots: readOnlyMutationRoots,
            repository: repository
        )
    }

    private func beginRename(_ item: FileItem) {
        guard canRename(item), let repository = model.fileRepository else { return }
        prepareForMutation()
        mutation.beginRename(
            item: item,
            parentPath: state.currentPath,
            source: state.location.source,
            readOnlyRoots: readOnlyMutationRoots,
            repository: repository
        )
    }

    private func canCopyMove(_ item: FileItem) -> Bool {
        guard let profileID = model.activeProfile?.id else { return false }
        return MobileFileCopyMoveModel.canBegin(
            item: item,
            parentPath: state.currentPath,
            source: state.location.source,
            visibleItems: state.page.items,
            readOnlyRoots: readOnlyMutationRoots,
            profileID: profileID
        )
    }

    private func beginCopyMove(_ operation: FileCopyMoveOperation, item: FileItem) {
        guard canCopyMove(item), let repository = model.fileRepository else { return }
        prepareForMutation()
        copyMove.begin(
            operation: operation,
            item: item,
            parentPath: state.currentPath,
            source: state.location.source,
            visibleItems: state.page.items,
            readOnlyRoots: readOnlyMutationRoots,
            repository: repository
        )
    }

    private func prepareForMutation() {
        resetPreviewPresentation()
        preview.close()
        model.fileShareLinkModel.dismiss()
    }

    private var readOnlyMutationRoots: [String] {
        locations.state.remote.folders.map(\.item.path) +
            locations.state.recycle.locations.map(\.recyclePath)
    }

    private func mutationDidConfirm(_ success: MobileFileItemMutationSuccess) async {
        guard let repository = model.fileRepository else { return }
        await browser.refreshAfterConfirmedMutation(success, repository: repository)
    }

    private func copyMoveDidConfirm(_ success: MobileFileCopyMoveSuccess) async {
        guard let repository = model.fileRepository else { return }
        await browser.refreshAfterConfirmedCopyMove(success, repository: repository)
    }

    private func beginShareLink(for item: FileItem) {
        guard !state.location.source.isReadOnlyLocation else { return }
        model.fileShareLinkModel.begin(for: item)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard let context = pendingUploadContext,
              let service = pendingUploadService else { return }
        pendingUploadContext = nil
        pendingUploadService = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task {
                _ = await model.documentTransferController.handlePickedFile(url, context: context, service: service)
            }
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                model.documentTransferController.reportPickerFailure(error)
            }
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

    private var shareLinkPresentationBinding: Binding<Bool> {
        Binding(
            get: { model.fileShareLinkModel.state.isPresented },
            set: { if !$0 { model.fileShareLinkModel.dismiss() } }
        )
    }

    private var mutationPresentationBinding: Binding<Bool> {
        Binding(
            get: { mutation.isPresented },
            set: { if !$0 { mutation.dismiss() } }
        )
    }

    private var copyMovePresentationBinding: Binding<Bool> {
        Binding(
            get: { copyMove.isPresented },
            set: { if !$0 { copyMove.dismiss() } }
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

    private func formattedSize(_ item: FileItem) -> String {
        ByteCountFormatter.string(fromByteCount: item.sizeBytes ?? 0, countStyle: .file)
    }

    private func startDownload(_ item: FileItem, intent: MobileDocumentIntent) {
        guard let repository = model.fileRepository else { return }
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
}
