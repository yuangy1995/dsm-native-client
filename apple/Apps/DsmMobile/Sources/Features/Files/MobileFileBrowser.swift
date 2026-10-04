import DsmCore
import DsmLocalization
import Foundation
import SwiftUI
import UniformTypeIdentifiers

private struct MobileFileBrowserActivationIdentity: Hashable {
    let profileID: UUID?
    let repositoryIdentity: ObjectIdentifier?
}

private struct MobileFileCompressionSelection: Identifiable {
    let id = UUID()
    let items: [FileItem]
    let destination: String
}

struct MobileFileBrowser: View {
    @Bindable var model: MobileAppModel
    @State private var isImportingFile = false
    @State private var pendingUploadContext: MobileDocumentPickerContext?
    @State private var pendingUploadService: MobileFileTransferService?
    @State private var showsPreviewInspector = false
    @State private var showsPreviewFullScreen = false
    @State private var showsPreviewDetails = false
    @State private var compressionSelection: MobileFileCompressionSelection?
    @State private var extractionItem: FileItem?
    @State private var permissionItem: FileItem?
    @State private var showsLocations = false
    @State private var favoritePreview: FileItem?
    @State private var showsFileSettings = false
    @State private var showsRemoteLocations = false
    @State private var remoteAfterLocations = false
    @State private var remoteContext = ""
    @State private var remotePath: String?
    @State private var remoteDownload: FileItem?
    @State private var isoSource: FileItem?
    @State private var crossNASSelection: MobileCrossNASSelection?
    @State private var showsAdvancedSearch = false
    @State private var restoresPreviewInspectorAfterFullScreen = false
    @State private var isSelectingCopyMoveItems = false
    @State private var selectedCopyMovePaths: Set<String> = []
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private var browser: MobileFileBrowserModel { model.fileBrowserModel }
    private var locations: MobileFileLocationsModel { browser.locations }
    private var mutation: MobileFileItemMutationModel { browser.mutations }
    private var copyMove: MobileFileCopyMoveModel { browser.copyMove }
    private var recycleAction: MobileFileRecycleActionModel { browser.recycleAction }
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
        .safeAreaInset(edge: .top) {
            if model.favorites.feedback != nil || state.advancedSearch != nil || state.page.indexCoverage == .incomplete || state.errorMessage != nil && state.pageState == .content {
                VStack(alignment: .leading, spacing: 8) {
                    if let feedback = model.favorites.feedback {
                        HStack {
                            Text(feedback).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                            Button { model.favorites.clearFeedback() } label: {
                                Image(systemName: "xmark").frame(width: 44, height: 44)
                            }.accessibilityLabel(L10n.string("files.common.close"))
                        }
                    }
                    if state.advancedSearch != nil {
                        Button { showsAdvancedSearch = true } label: {
                            Label(L10n.string("mobile.files.search.active"), systemImage: "line.3.horizontal.decrease.circle.fill")
                                .frame(minHeight: 44)
                        }
                    }
                    if state.page.indexCoverage == .incomplete {
                        Text(L10n.string("files.search.indexIncomplete")).font(.callout).foregroundStyle(.secondary)
                    }
                    if let message = state.errorMessage, state.pageState == .content {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal).background(.bar)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelectingCopyMoveItems {
                batchCopyMoveBar
            }
        }
        .fileImporter(
            isPresented: $isImportingFile,
            allowedContentTypes: [.item, .folder],
            allowsMultipleSelection: true,
            onCompletion: handleFileImport
        )
        .sheet(isPresented: Binding(get: { model.fileUploadQueue.isPresented },
                                    set: { if !$0 { model.fileUploadQueue.dismissSelection() } })) {
            MobileFileUploadSelectionView(queue: model.fileUploadQueue)
        }
        .sheet(isPresented: shareLinkPresentationBinding) {
            MobileFileShareLinkView(model: model.fileShareLinkModel)
        }
        .sheet(item: $crossNASSelection) { selection in
            MobileCrossNASSelectionView(model: model, selection: selection)
        }
        .sheet(isPresented: $showsAdvancedSearch) {
            if let repository = model.fileRepository {
                let identity = activationIdentity
                MobileFileAdvancedSearchView(repository: repository, request: advancedSearchDraft) { request in
                    guard identity == activationIdentity else { return }
                    Task { await browser.applyAdvancedSearch(request, repository: repository) }
                }
            }
        }
        .sheet(item: $compressionSelection) { selection in
            if let repository = model.fileRepository {
                MobileFileCompressionView(items: selection.items, repository: repository,
                    queue: model.fileArchiveQueue, destination: selection.destination)
            }
        }
        .sheet(item: $extractionItem) { item in
            if let repository = model.fileRepository {
                MobileFileExtractionView(item: item, destination: state.currentPath,
                    repository: repository, queue: model.fileArchiveQueue)
            }
        }
        .sheet(item: $permissionItem) { item in
            MobileFilePermissionView(model: model.filePermissionModel, item: item)
        }
        .sheet(isPresented: $showsFileSettings) {
            if let repository = model.fileRepository { MobileFileSettingsView(model: model.fileSettings, repository: repository) }
        }
        .sheet(isPresented: $showsRemoteLocations, onDismiss: finishRemoteSelection) {
            if let repository = model.fileRepository {
                MobileRemoteLocationsView(model: model.remoteLocations, repository: repository,
                    openMount: { remotePath = $0 }, download: { remoteDownload = $0; showsRemoteLocations = false })
            }
        }
        .sheet(item: $isoSource) { source in
            if let repository = model.fileRepository {
                MobileISOMountView(model: model.remoteLocations, repository: repository, source: source, existing: nil)
            }
        }
        .sheet(isPresented: $showsLocations, onDismiss: {
            if remoteAfterLocations { remoteAfterLocations = false; showRemoteLocations() }
            if let item = favoritePreview { favoritePreview = nil; openPreview(item) }
            model.favorites.clearFeedback()
        }) {
            MobileFileLocationsView(
                locations: locations,
                refresh: refreshLocations,
                openLocation: openLocation,
                cancelOpenLocation: browser.cancelLocationRequest,
                onManageRemote: { remoteAfterLocations = true },
                favorites: model.favorites
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
        .sheet(isPresented: recycleActionPresentationBinding) {
            if let repository = model.fileRepository {
                MobileFileRecycleActionView(
                    recycleAction: recycleAction,
                    repository: repository,
                    didConfirm: recycleActionDidConfirm
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
            copyMove.activate(profileID: profileID, repository: repository,
                context: model.activeProfile.map { MobileWorkspaceIdentity($0).storageIdentifier })
            recycleAction.activate(profileID: profileID, repository: repository, context: model.activeProfile.map { MobileWorkspaceIdentity($0).storageIdentifier })
            locations.activate(profileID: profileID, repository: repository)
            guard let profileID, let repository else { return }
            model.fileShareLinkModel.activate(profileID: profileID, repository: repository,
                context: model.activeProfile.map { MobileWorkspaceIdentity($0).storageIdentifier })
            await locations.loadIfNeeded(repository: repository)
            if browser.state.visibleKey == nil && !browser.state.hasLoadedStorage {
                async let files: Void = browser.refresh(repository: repository)
                async let storage: Void = browser.refreshStorage(repository: repository)
                _ = await (files, storage)
            } else if browser.state.visibleKey == nil {
                await browser.refresh(repository: repository)
            } else if !browser.state.hasLoadedStorage && browser.state.currentPath.isEmpty {
                await browser.refreshStorage(repository: repository)
            }
        }
        .onChange(of: activationIdentity) { _, _ in
            showsFileSettings = false
            showsAdvancedSearch = false
            compressionSelection = nil; extractionItem = nil
            permissionItem = nil; favoritePreview = nil
            isoSource = nil; remotePath = nil; remoteDownload = nil; remoteAfterLocations = false; showsRemoteLocations = false
            resetPreviewPresentation()
            endCopyMoveSelection()
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
            endCopyMoveSelection()
            browser.cancelRequest()
            browser.cancelStorageRequest()
            locations.cancelRequest()
            mutation.deactivate()
            copyMove.deactivate()
            recycleAction.deactivate()
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
                if showsStorageSummary {
                    storageSummaryView
                        .padding(.horizontal)
                        .padding(.top, 12)
                }
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
                if showsStorageSummary {
                    storageSummaryView
                        .listRowSeparator(.hidden)
                }
                ForEach(state.page.items) { item in
                    listItem(item)
                }
                paginationFooter
            }
            .listStyle(.plain)
        }
    }

    private var showsStorageSummary: Bool {
        state.currentPath.isEmpty && state.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && state.advancedSearch == nil
    }

    private var storageSummaryView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(L10n.string("mobile.files.storage.title"), systemImage: "internaldrive")
                .font(.headline)
            if let summary = state.storageSummary {
                ProgressView(value: summary.usedFraction)
                    .accessibilityHidden(true)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 16) {
                        storageValue("mobile.files.storage.used", bytes: summary.usedBytes)
                        storageValue("mobile.files.storage.remaining", bytes: summary.remainingBytes)
                        storageValue("mobile.files.storage.total", bytes: summary.totalBytes)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        storageValue("mobile.files.storage.used", bytes: summary.usedBytes)
                        storageValue("mobile.files.storage.remaining", bytes: summary.remainingBytes)
                        storageValue("mobile.files.storage.total", bytes: summary.totalBytes)
                    }
                }
                Text(L10n.string("mobile.files.storage.volumes", Int64(summary.volumeCount)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if state.storageRefreshFailed {
                    Label(
                        L10n.string("mobile.files.storage.refresh-failed"),
                        systemImage: "exclamationmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else if state.isStorageLoading || !state.hasLoadedStorage {
                ProgressView(L10n.string("mobile.files.storage.loading"))
                    .frame(minHeight: 44)
            } else {
                Label(
                    L10n.string("mobile.files.storage.unavailable"),
                    systemImage: "exclamationmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(minHeight: 44)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(storageAccessibilityLabel)
    }

    private func storageValue(_ key: String, bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string(key))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(formattedBytes(bytes))
                .font(.body.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var storageAccessibilityLabel: String {
        guard let summary = state.storageSummary else {
            return L10n.string(
                state.isStorageLoading || !state.hasLoadedStorage
                    ? "mobile.files.storage.loading"
                    : "mobile.files.storage.unavailable"
            )
        }
        let summaryLabel = L10n.string(
            "mobile.files.storage.accessibility",
            formattedBytes(summary.usedBytes),
            formattedBytes(summary.remainingBytes),
            formattedBytes(summary.totalBytes),
            Int64(summary.volumeCount)
        )
        guard state.storageRefreshFailed else { return summaryLabel }
        return "\(summaryLabel) \(L10n.string("mobile.files.storage.refresh-failed"))"
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        bytes.formatted(.byteCount(style: .file).locale(L10n.locale))
    }

    private func listItem(_ item: FileItem) -> some View {
        HStack(spacing: 8) {
            Button { fileItemPrimaryAction(item) } label: {
                HStack(spacing: 14) {
                    if isSelectingCopyMoveItems {
                        selectionSymbol(item)
                    }
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
            .disabled(isSelectingCopyMoveItems && !canSelectCopyMoveItem(item))
            .accessibilityAddTraits(
                isSelectingCopyMoveItems && selectedCopyMovePaths.contains(item.path)
                    ? .isSelected
                    : []
            )
            .accessibilityValue(copyMoveSelectionAccessibilityValue(item))
            .accessibilityHint(fileItemAccessibilityHint(item))

            if !isSelectingCopyMoveItems {
                itemMenu(item)
            }
        }
    }

    private func gridItem(_ item: FileItem) -> some View {
        VStack(spacing: 0) {
            Button { fileItemPrimaryAction(item) } label: {
                VStack(spacing: 10) {
                    if isSelectingCopyMoveItems {
                        selectionSymbol(item)
                    }
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
            .disabled(isSelectingCopyMoveItems && !canSelectCopyMoveItem(item))
            .accessibilityAddTraits(
                isSelectingCopyMoveItems && selectedCopyMovePaths.contains(item.path)
                    ? .isSelected
                    : []
            )
            .accessibilityValue(copyMoveSelectionAccessibilityValue(item))
            .accessibilityHint(fileItemAccessibilityHint(item))

            if !isSelectingCopyMoveItems {
                Divider()
                itemMenu(item)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
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
            if !state.location.source.isReadOnlyLocation && (item.kind == .file || item.isDirectory) {
                let selected = locations.state.favorites.locations.contains { $0.path == item.path }
                Button {
                    Task { await model.favorites.setFavorite(path: item.path, name: item.name, removing: selected) }
                } label: {
                    Label(L10n.string(selected ? "ui.dca60869e7d26839" : "ui.0cfc396e4aa347ad"),
                          systemImage: selected ? "star.slash" : "star")
                }.disabled(!model.favorites.available || model.favorites.isBlocked(item.path))
            }
            if item.kind == .file || item.isDirectory {
                Button { permissionItem = item } label: {
                    Label(L10n.string("files.permissions.title"), systemImage: "person.badge.key")
                }.disabled(model.fileRepository == nil)
            }
            if item.kind == .file && item.fileExtension?.lowercased() == "iso" {
                Button { model.remoteLocations.clearFeedback(); isoSource = item } label: {
                    Label(L10n.string("files.iso.mount"), systemImage: "opticaldisc")
                }.disabled(model.fileRepository == nil)
            }
            if canCreateFolder && !state.location.source.isReadOnlyLocation {
                Button { compressionSelection = .init(items: [item], destination: state.currentPath) } label: {
                    Label(L10n.string("mobile.archive.compress"), systemImage: "archivebox")
                }
                if !item.isDirectory && ["zip", "7z", "rar", "tar", "gz", "bz2", "xz", "tgz", "iso"].contains((item.name as NSString).pathExtension.lowercased()) {
                    Button { extractionItem = item } label: {
                        Label(L10n.string("mobile.archive.extract"), systemImage: "archivebox.fill")
                    }
                }
            }
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
            if canDelete(item) {
                Button(role: .destructive) {
                    beginDelete(item)
                } label: {
                    Label(
                        L10n.string("mobile.files.recycle.delete.action"),
                        systemImage: "trash"
                    )
                }
            }
            if canRestoreFromRecycle(item) {
                Button {
                    beginRestoreFromRecycle(item)
                } label: {
                    Label(
                        L10n.string("mobile.files.recycle.restore.action"),
                        systemImage: "arrow.uturn.backward"
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
                Button {
                    beginShareLinkManagement(for: item)
                } label: {
                    Label(
                        L10n.string("mobile.files.share-link.management.action"),
                        systemImage: "link"
                    )
                }
            }
            if canCrossNAS(item) {
                Button(L10n.string("mobile.cross.title")) { beginCrossNAS([item]) }
                    .accessibilityIdentifier("files.item.cross-nas")
            }
            if item.isDirectory {
                Button(L10n.string("ui.c771248e511fbf93")) { openDirectory(item) }
                if canDownloadSelection(item) {
                    Button(L10n.string("mobile.documents.archive.save")) { startArchiveDownload([item], intent: .exportCopy) }
                        .accessibilityIdentifier("files.item.download-archive")
                    Button(L10n.string("mobile.documents.archive.share")) { startArchiveDownload([item], intent: .share) }
                        .accessibilityIdentifier("files.item.share-archive")
                }
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
        ToolbarItemGroup(placement: .primaryAction) {
            sortAndFilterMenu.disabled(isSelectingCopyMoveItems)
            if horizontalSizeClass == .regular {
                createFolderButton
                uploadButton
            }
            Menu {
                Button(action: toggleCopyMoveSelection) {
                    Label(L10n.string(isSelectingCopyMoveItems ? "mobile.files.batch-selection.done" : "mobile.files.batch-selection.start"),
                          systemImage: isSelectingCopyMoveItems ? "xmark" : "checkmark.circle")
                }
                .disabled(!isSelectingCopyMoveItems && selectableCopyMoveItems.isEmpty)
                if !state.currentPath.isEmpty {
                    Button(action: goUp) {
                        Label(L10n.string("ui.2bab713fde4ebc53"), systemImage: "arrow.up")
                    }
                }
                if horizontalSizeClass != .regular {
                    createFolderButton
                    uploadButton
                }
                Button {
                    model.fileShareLinkModel.beginManagement()
                } label: { Label(L10n.string("mobile.sharing.all"), systemImage: "link") }
                .disabled(model.fileRepository == nil).accessibilityIdentifier("files.sharing.all")
                Button(action: showRemoteLocations) {
                    Label(L10n.string("mobile.files.locations.remote"), systemImage: "network")
                }.disabled(model.fileRepository == nil).accessibilityIdentifier("files.remote.manage")
                Button { showsFileSettings = true } label: {
                    Label(L10n.string("files.settings.title"), systemImage: "gearshape")
                }.disabled(model.fileRepository == nil).accessibilityIdentifier("files.settings.open")
                Button(action: toggleLayout) {
                    Label(L10n.string(state.layout == .list ? "mobile.files.show-grid" : "mobile.files.show-list"),
                          systemImage: state.layout == .list ? "square.grid.2x2" : "list.bullet")
                }
                Button(action: refresh) {
                    Label(L10n.string("ui.aee88743413144a2"), systemImage: "arrow.clockwise")
                }.disabled(state.isRefreshing || isSelectingCopyMoveItems)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.string("workspace.actions.more"))
            .accessibilityIdentifier("files.toolbar.more")
        }
    }

    private var createFolderButton: some View {
        Button(action: beginCreateFolder) {
            Label(L10n.string("mobile.files.mutation.create.action"), systemImage: "folder.badge.plus")
        }
        .disabled(!canCreateFolder || isSelectingCopyMoveItems)
    }

    private var uploadButton: some View {
        Button(action: beginUpload) {
            Label(L10n.string("mobile.documents.upload"), systemImage: "square.and.arrow.up")
        }
        .disabled(!canCreateFolder || state.location.source.isReadOnlyLocation || isSelectingCopyMoveItems)
    }

    private var batchCopyMoveBar: some View {
        ViewThatFits(in: .horizontal) {
            batchCopyMoveBarContent(horizontal: true)
            batchCopyMoveBarContent(horizontal: false)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func batchCopyMoveBarContent(horizontal: Bool) -> some View {
        let content = Group {
            Text(
                L10n.string(
                    "mobile.files.batch-selection.count",
                    Int64(selectedCopyMoveItems.count),
                    Int64(MobileFileCopyMoveModel.maximumBatchCount)
                )
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button { startSelectedDownload(intent: .exportCopy) } label: {
                    Label(L10n.string("mobile.documents.save-copy"), systemImage: "square.and.arrow.down")
                }.disabled(selectedCopyMoveItems.isEmpty || !selectedCopyMoveItems.allSatisfy(canDownloadSelection))
                    .accessibilityIdentifier("files.batch.download")
                Button { startSelectedDownload(intent: .share) } label: {
                    Label(L10n.string("mobile.documents.share"), systemImage: "square.and.arrow.up")
                }.disabled(selectedCopyMoveItems.isEmpty || !selectedCopyMoveItems.allSatisfy(canDownloadSelection))
                    .accessibilityIdentifier("files.batch.share")
                Button(L10n.string("mobile.cross.title")) { beginCrossNAS(selectedCopyMoveItems) }
                    .disabled(selectedCopyMoveItems.isEmpty || !selectedCopyMoveItems.allSatisfy(canCrossNAS))
                    .accessibilityIdentifier("files.batch.cross-nas")
                Button(role: .destructive) { beginBatchRecycle(.delete) } label: {
                    Label(L10n.string("mobile.files.recycle.delete.action"), systemImage: "trash")
                }.disabled(selectedCopyMoveItems.isEmpty || !selectedCopyMoveItems.allSatisfy(canDelete))
                    .accessibilityIdentifier("files.batch.delete")
                if state.location.source == .recycle {
                    Button { beginBatchRecycle(.restoreFromRecycle) } label: {
                        Label(L10n.string("mobile.files.recycle.restore.action"), systemImage: "arrow.uturn.backward")
                    }.disabled(selectedCopyMoveItems.isEmpty || !selectedCopyMoveItems.allSatisfy(canRestoreFromRecycle))
                        .accessibilityIdentifier("files.batch.restore")
                }
                Button {
                    model.fileShareLinkModel.begin(for: selectedCopyMoveItems); endCopyMoveSelection()
                } label: { Label(L10n.string("mobile.files.share-link.action.create"), systemImage: "link.badge.plus") }
                    .disabled(selectedCopyMoveItems.isEmpty || state.location.source.isReadOnlyLocation)
                Button {
                    compressionSelection = .init(items: selectedCopyMoveItems, destination: state.currentPath); endCopyMoveSelection()
                } label: { Label(L10n.string("mobile.archive.compress"), systemImage: "archivebox") }
                    .disabled(selectedCopyMoveItems.isEmpty || !canCreateFolder || state.location.source.isReadOnlyLocation)
            } label: { Image(systemName: "ellipsis").frame(minWidth: 24, minHeight: 24) }
                .accessibilityLabel(L10n.string("workspace.actions.more"))
                .accessibilityIdentifier("files.batch.more")
            Button {
                beginBatchCopyMove(.copy)
            } label: {
                Label(
                    L10n.string("mobile.files.copy-move.copy.action"),
                    systemImage: "doc.on.doc"
                )
            }
            .disabled(selectedCopyMoveItems.isEmpty || !selectedCopyMoveItems.allSatisfy(canBatchCopyMove))
            .accessibilityIdentifier("files.batch.copy")
            Button {
                beginBatchCopyMove(.move)
            } label: {
                Label(
                    L10n.string("mobile.files.copy-move.move.action"),
                    systemImage: "folder"
                )
            }
            .disabled(selectedCopyMoveItems.isEmpty || !selectedCopyMoveItems.allSatisfy(canBatchCopyMove))
            .accessibilityIdentifier("files.batch.move")
        }
        if horizontal {
            HStack(spacing: 12) { content }
        } else {
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }

    private func selectionSymbol(_ item: FileItem) -> some View {
        Image(
            systemName: selectedCopyMovePaths.contains(item.path)
                ? "checkmark.circle.fill"
                : "circle"
        )
        .foregroundStyle(canSelectCopyMoveItem(item) ? Color.accentColor : Color.secondary)
        .frame(width: 32, height: 44)
        .accessibilityHidden(true)
    }

    private var advancedSearchDraft: FileSearchRequest {
        var request = state.advancedSearch ?? FileSearchRequest(folders: state.currentPath.isEmpty ? [] : [state.currentPath])
        request.name = state.query
        return request
    }

    private var sortAndFilterMenu: some View {
        Menu {
            Button(L10n.string("files.search.advanced")) { showsAdvancedSearch = true }
                .accessibilityIdentifier("files.search.advanced")
            Divider()
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
            errorMessage: state.errorMessage ?? L10n.string("ui.5448ceb91a80e260"),
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
        async let files: Void = browser.refresh(repository: repository)
        async let storage: Void = browser.refreshStorage(repository: repository)
        _ = await (files, storage)
    }

    private func refreshLocations() async {
        guard let repository = model.fileRepository else { return }
        await model.favorites.refreshPending()
        await locations.refresh(repository: repository)
    }

    private func openLocation(
        _ path: String,
        _ source: MobileFileLocationSource
    ) async -> Bool {
        guard let repository = model.fileRepository else { return false }
        prepareForLocationChange()
        if source == .favorite {
            let identity = activationIdentity
            guard let item = try? await repository.getInfo(paths: [path]).first(where: { $0.path == path }),
                  identity == activationIdentity, !Task.isCancelled else { return false }
            if !item.isDirectory { favoritePreview = item; return true }
        }
        let opened = await browser.openLocation(path: path, source: source, repository: repository)
        if opened, path.isEmpty, !browser.state.hasLoadedStorage {
            await browser.refreshStorage(repository: repository)
        }
        return opened
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
        guard canCreateFolder, !state.location.source.isReadOnlyLocation,
              let profileID = model.activeProfile?.id,
              let repository = model.fileRepository else { return }
        pendingUploadContext = MobileDocumentPickerContext(contextID: model.documentTransferController.contextID,
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

    private func canCrossNAS(_ item: FileItem) -> Bool {
        guard let profile = model.activeProfile, !state.location.source.isReadOnlyLocation else { return false }
        return MobileCrossNASPlan.canSelect(item, profileID: profile.id)
    }

    private func beginCrossNAS(_ items: [FileItem]) {
        guard let profile = model.activeProfile, !items.isEmpty, items.allSatisfy(canCrossNAS),
              items.allSatisfy({ state.page.items.contains($0) }) else { return }
        crossNASSelection = .init(sourceContext: MobileWorkspaceIdentity(profile).storageIdentifier, items: items)
        endCopyMoveSelection()
    }

    private var selectableCopyMoveItems: [FileItem] {
        // 文件和目录共用选择，具体操作继续检查自己的权限和目标限制。
        state.page.items.filter { canCopyMove($0) || canDelete($0) || canRestoreFromRecycle($0) || canDownloadSelection($0) }
    }

    private var selectedCopyMoveItems: [FileItem] {
        selectableCopyMoveItems.filter { selectedCopyMovePaths.contains($0.path) }
    }

    private func fileItemPrimaryAction(_ item: FileItem) {
        guard isSelectingCopyMoveItems else {
            primaryAction(for: item)
            return
        }
        guard canSelectCopyMoveItem(item) else { return }
        if selectedCopyMovePaths.contains(item.path) {
            selectedCopyMovePaths.remove(item.path)
        } else if selectedCopyMovePaths.count < MobileFileCopyMoveModel.maximumBatchCount {
            selectedCopyMovePaths.insert(item.path)
        }
    }

    private func canSelectCopyMoveItem(_ item: FileItem) -> Bool {
        (canCopyMove(item) || canDelete(item) || canRestoreFromRecycle(item) || canDownloadSelection(item)) && (
            selectedCopyMovePaths.contains(item.path) ||
                selectedCopyMovePaths.count < MobileFileCopyMoveModel.maximumBatchCount
        )
    }

    private func copyMoveSelectionAccessibilityValue(_ item: FileItem) -> String {
        guard isSelectingCopyMoveItems else { return "" }
        if selectedCopyMovePaths.contains(item.path) {
            return L10n.string("mobile.files.batch-selection.selected")
        }
        if !canCopyMove(item) && !canDelete(item) && !canRestoreFromRecycle(item) && !canDownloadSelection(item) {
            return L10n.string("mobile.files.batch-selection.unavailable")
        }
        if selectedCopyMovePaths.count >= MobileFileCopyMoveModel.maximumBatchCount {
            return L10n.string("mobile.files.batch-selection.limit-reached")
        }
        return L10n.string("mobile.files.batch-selection.not-selected")
    }

    private func canBatchCopyMove(_ item: FileItem) -> Bool {
        guard let profileID = model.activeProfile?.id else { return false }
        return MobileFileCopyMoveModel.canBeginBatchItem(
            item: item,
            parentPath: state.currentPath,
            source: state.location.source,
            visibleItems: state.page.items,
            readOnlyRoots: readOnlyMutationRoots,
            profileID: profileID
        )
    }

    private func fileItemAccessibilityHint(_ item: FileItem) -> String {
        if isSelectingCopyMoveItems {
            guard canSelectCopyMoveItem(item) else { return "" }
            return selectedCopyMovePaths.contains(item.path)
                ? L10n.string("mobile.files.batch-selection.remove-hint")
                : L10n.string("mobile.files.batch-selection.add-hint")
        }
        return item.isDirectory
            ? L10n.string("mobile.files.open-folder-hint")
            : L10n.string("mobile.files.open-preview-hint")
    }

    private func toggleCopyMoveSelection() {
        if isSelectingCopyMoveItems {
            endCopyMoveSelection()
        } else {
            selectedCopyMovePaths = []
            isSelectingCopyMoveItems = true
        }
    }

    private func endCopyMoveSelection() {
        isSelectingCopyMoveItems = false
        selectedCopyMovePaths = []
    }

    private func beginBatchCopyMove(_ operation: FileCopyMoveOperation) {
        let items = selectedCopyMoveItems
        guard !items.isEmpty, items.allSatisfy(canBatchCopyMove), let repository = model.fileRepository else { return }
        prepareForMutation()
        copyMove.begin(
            operation: operation,
            items: items,
            parentPath: state.currentPath,
            source: state.location.source,
            visibleItems: state.page.items,
            readOnlyRoots: readOnlyMutationRoots,
            repository: repository
        )
        if copyMove.isPresented {
            endCopyMoveSelection()
        }
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

    private func canDelete(_ item: FileItem) -> Bool {
        guard let profileID = model.activeProfile?.id else { return false }
        return MobileFileRecycleActionModel.canDelete(
            item: item,
            parentPath: state.currentPath,
            source: state.location.source,
            visibleItems: state.page.items,
            readOnlyRoots: locations.state.remote.folders.map(\.item.path),
            profileID: profileID
        )
    }

    private func canRestoreFromRecycle(_ item: FileItem) -> Bool {
        guard let profileID = model.activeProfile?.id else { return false }
        return MobileFileRecycleActionModel.canRestoreFromRecycle(
            item: item,
            parentPath: state.currentPath,
            source: state.location.source,
            visibleItems: state.page.items,
            profileID: profileID
        )
    }

    private func beginDelete(_ item: FileItem) {
        guard canDelete(item), let repository = model.fileRepository else { return }
        prepareForMutation()
        recycleAction.begin(operation: .delete, items: [item], parentPath: state.currentPath,
            source: state.location.source, visibleItems: state.page.items,
            readOnlyRoots: locations.state.remote.folders.map(\.item.path), repository: repository)
    }

    private func beginBatchRecycle(_ operation: MobileFileRecycleActionOperation) {
        let items = selectedCopyMoveItems
        guard !items.isEmpty, let repository = model.fileRepository else { return }
        prepareForMutation()
        recycleAction.begin(operation: operation, items: items, parentPath: state.currentPath,
            source: state.location.source, visibleItems: state.page.items,
            readOnlyRoots: locations.state.remote.folders.map(\.item.path), repository: repository)
        if recycleAction.isPresented { endCopyMoveSelection() }
    }

    private func beginRestoreFromRecycle(_ item: FileItem) {
        guard canRestoreFromRecycle(item), let repository = model.fileRepository else { return }
        prepareForMutation()
        recycleAction.beginRestoreFromRecycle(
            item: item,
            parentPath: state.currentPath,
            source: state.location.source,
            visibleItems: state.page.items,
            repository: repository
        )
    }

    private func recycleActionDidConfirm(_ success: MobileFileRecycleActionSuccess) async {
        guard let repository = model.fileRepository else { return }
        await browser.refreshAfterConfirmedRecycleAction(success, repository: repository)
    }

    private func beginShareLink(for item: FileItem) {
        guard !state.location.source.isReadOnlyLocation else { return }
        model.fileShareLinkModel.begin(for: item)
    }

    private func beginShareLinkManagement(for item: FileItem) {
        guard !state.location.source.isReadOnlyLocation else { return }
        model.fileShareLinkModel.beginManagement(for: item)
    }

    private func handleFileImport(_ result: Result<[URL], Error>) {
        guard let context = pendingUploadContext, pendingUploadService != nil else { return }
        pendingUploadContext = nil
        pendingUploadService = nil
        switch result {
        case .success(let urls):
            guard context.contextID == model.documentTransferController.contextID,
                  context.profileID == model.activeProfile?.id else { return }
            Task { await model.fileUploadQueue.prepare(urls, destination: context.folderPath) }
        case .failure(let error):
            let nsError = error as NSError
            if nsError.domain != NSCocoaErrorDomain || nsError.code != NSUserCancelledError {
                model.documentTransferController.reportPickerFailure(error)
            }
        }
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

    private var recycleActionPresentationBinding: Binding<Bool> {
        Binding(
            get: { recycleAction.isPresented },
            set: { if !$0 { recycleAction.dismiss() } }
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
        item.sizeBytes.map(formattedBytes) ?? L10n.string("mobile.documents.size-unavailable")
    }

    private func showRemoteLocations() {
        remoteContext = model.remoteLocations.context; model.remoteLocations.clearFeedback(); showsRemoteLocations = true
    }

    private func finishRemoteSelection() {
        defer { remotePath = nil; remoteDownload = nil }
        guard remoteContext == model.remoteLocations.context else { return }
        if let path = remotePath { Task { _ = await openLocation(path, .remote) } }
        if let item = remoteDownload { startDownload(item, intent: .exportCopy) }
    }

    private func canDownloadSelection(_ item: FileItem) -> Bool {
        guard model.fileRepository != nil, let profileID = model.activeProfile?.id else { return false }
        return MobileArchiveDownloadSelection.canSelect(item, profileID: profileID)
    }

    private func startSelectedDownload(intent: MobileDocumentIntent) {
        let items = selectedCopyMoveItems
        guard !items.isEmpty, items.allSatisfy(canDownloadSelection) else { return }
        if items.count == 1, let item = items.first, !item.isDirectory {
            startDownload(item, intent: intent)
        } else {
            startArchiveDownload(items, intent: intent)
        }
        endCopyMoveSelection()
    }

    private func startArchiveDownload(_ items: [FileItem], intent: MobileDocumentIntent) {
        guard let repository = model.fileRepository, let profileID = model.activeProfile?.id,
              let sources = MobileArchiveDownloadSelection.sources(items, profileID: profileID),
              let first = items.first else { return }
        let name = items.count == 1 ? first.name + ".zip"
            : L10n.string("mobile.documents.archive.filename", Int64(items.count))
        let context = MobileDocumentDownloadContext(contextID: model.documentTransferController.contextID,
            profileID: profileID, remotePath: first.path, fileName: name, intent: intent, archiveSources: sources)
        let service = MobileFileTransferService(repository: repository)
        Task { _ = await model.documentTransferController.startDownload(context: context, service: service) }
    }

    private func startDownload(_ item: FileItem, intent: MobileDocumentIntent) {
        guard let repository = model.fileRepository else { return }
        let context = MobileDocumentDownloadContext(contextID: model.documentTransferController.contextID,
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
