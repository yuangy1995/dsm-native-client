import AppKit
import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

private enum FileViewMode: String, CaseIterable, Identifiable {
    case list
    case grid
    var id: Self { self }
}

private enum FileGrouping: String, CaseIterable, Identifiable {
    case none
    case type
    case date
    case size

    var id: Self { self }

    var title: String {
        switch self {
        case .none: L10n.string("ui.fcd40ee3f05a3cfa")
        case .type: L10n.string("ui.5ba65a74c4e792c5")
        case .date: L10n.string("ui.5f622df4ed56933c")
        case .size: L10n.string("ui.1d656a29f92194cc")
        }
    }
}

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    let profiles: [NasProfile]
    let selectedProfileID: UUID?
    let connectedWorkspaces: [WorkspaceModel]
    let connectionRoute: AppModel.ConnectionRoute?
    let onAddNAS: () -> Void
    let onSelectNAS: (UUID) -> Void
    let onMoveProfiles: (IndexSet, Int) -> Void
    let hasFileClipboard: Bool
    let onCopy: ([FileItem]) -> Void
    let onCut: ([FileItem]) -> Void
    let onPaste: () -> Void
    let onRenameNAS: (String) -> String?
    let onLogout: () async -> Void
    let onSessionExpired: (String) async -> Void

    @State private var deleteTargets: [FileItem] = []
    @State private var restoreTarget: FileItem?
    @State private var viewMode: FileViewMode = .grid
    @AppStorage("LanStash_FileGrouping") private var fileGrouping: FileGrouping = .none
    @State private var sortOrder = [KeyPathComparator<FileItem>]()
    @State private var showingInfoItem: FileItem? = nil
    @State private var previewWindowController: FloatingPreviewWindowController?
    @State private var shareTargets: [FileItem] = []
    @State private var isRestoringSectionAfterUnsavedEdit = false

    var body: some View {
        NavigationSplitView {
            SidebarView(
                model: model,
                profiles: profiles,
                selectedProfileID: selectedProfileID,
                connectionRoute: connectionRoute,
                onAddNAS: onAddNAS,
                onSelectNAS: { profile in onSelectNAS(profile.id) },
                onMoveProfiles: onMoveProfiles,
                onLogout: onLogout
            )
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 300)
        } detail: {
            contentColumn
                .fillsAvailableContentArea(alignment: .topLeading)
                .navigationSplitViewColumnWidth(min: 480, ideal: 680)
        }
        .navigationSplitViewStyle(.balanced)
        .task {
            await model.startEnabledModules()
        }
        .task(id: "\(model.profile.id.uuidString):\(model.isChatModuleEnabled)") {
            guard model.isChatModuleEnabled else {
                await model.chat.stopRealtime()
                return
            }
            while !Task.isCancelled, model.isChatModuleEnabled {
                await model.chat.syncWorkspaceChat(isChatVisible: model.section == .chat)
                do {
                    try await Task.sleep(
                        for: .seconds(model.chat.workspaceSyncIntervalSeconds)
                    )
                } catch {
                    break
                }
            }
            await model.chat.stopRealtime()
        }
        .onChange(of: model.section) { previousSection, section in
            if isRestoringSectionAfterUnsavedEdit {
                isRestoringSectionAfterUnsavedEdit = false
                return
            }
            if blockSectionChangeDueToUnsavedEdits(previousSection: previousSection, newSection: section) {
                return
            }
            switch section {
            case .files?, .recycle?:
                break
            default:
                previewWindowController?.closeFromModel()
                model.dismissPreview()
            }
            Task { await model.activate(section) }
        }
        .onChange(of: model.selection) { _, _ in
            // 照片模块的选中态由 PhotoLibraryModel 独立维护，WorkspaceModel.selection 仅在发起预览时被设置，
            // 不应被当作「用户切换选择」而关闭预览窗口。
            guard isFileSection else { return }
            if model.selectionChanged() {
                previewWindowController?.closeFromModel()
            }
        }
        .onChange(of: model.isPreviewPresented) { _, isPresented in
            if isPresented {
                presentFloatingPreview()
            } else {
                previewWindowController?.closeFromModel()
            }
        }
        .onDisappear {
            previewWindowController?.closeFromModel()
            model.dismissPreview()
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                // 固定为单个工具栏项目，避免页面切换时 AppKit 重复插入自动生成的项目标识。
                HStack(spacing: 6) {
                    Button {
                        navigateBack()
                    } label: {
                        Label(L10n.string("ui.572cf45ba43634b3"), systemImage: "chevron.backward")
                    }
                    .disabled(!canNavigateBack)
                    .help(isFileSection ? L10n.string("ui.265f9b089511054a") : L10n.string("ui.09059160dce356aa"))
                    .keyboardShortcut("[", modifiers: .command)

                    Button {
                        navigateUp()
                    } label: {
                        Label(L10n.string("ui.8e7847be62b68c2b"), systemImage: "arrow.up")
                    }
                    .disabled(!canNavigateUp)
                    .help(L10n.string("ui.3f374e18fac0a39b"))
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                // 页面对应的操作会变化，但 AppKit 始终只维护这一个工具栏项目。
                HStack(spacing: 8) {
                    if isFileSection {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label(L10n.string("ui.aee88743413144a2"), systemImage: "arrow.clockwise")
                    }
                    .disabled(model.currentPath.isEmpty || model.isRefreshing)
                    .keyboardShortcut("r", modifiers: .command)

                    Button {
                        presentUploadPanel()
                    } label: {
                        Label(L10n.string("ui.9e07e3c0532d4976"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(!isFileSection)
                    .help(L10n.string("ui.f7c49cca76cd2166"))

                    Menu {
                        if model.selectedItems.count > 1 {
                            Button(L10n.string("ui.b97cad08035a15e2")) {
                                presentBatchDownloadPanel(model.selectedItems)
                            }
                        } else if let item = model.selectedItem {
                            if item.isDirectory {
                                Button(L10n.string("ui.f956089b945b92cf")) {
                                    presentDownloadPanel(item, folderMode: .archive)
                                }
                                Button(L10n.string("ui.0f50ddf3fa8bb870")) {
                                    presentDownloadPanel(item, folderMode: .directory)
                                }
                            } else {
                                Button(L10n.string("ui.29610562f4b1c377")) {
                                    presentDownloadPanel(item, folderMode: .archive)
                                }
                            }
                        }
                    } label: {
                        Label(L10n.string("ui.4673a23061656125"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.selectedItem == nil)
                    .help(L10n.string("ui.3d8f89112076525f"))

                    Button {
                        shareTargets = model.selectedItems
                    } label: {
                        Label(L10n.string("ui.7e564575eb7d5eb2"), systemImage: "link")
                    }
                    .disabled(model.selectedItems.isEmpty)
                    .help(L10n.string("ui.bcb4ca87b0024cf4"))

                    Button {
                        deleteTargets = model.selectedItems
                    } label: {
                        Label(L10n.string("ui.2f9daa828907b93f"), systemImage: "trash")
                    }
                    .disabled(model.selectedItems.isEmpty)
                    .help(L10n.string("ui.33006fc9ca3c7e3e"))

                    Button {
                        onPaste()
                    } label: {
                        Label(L10n.string("ui.33517926747180e6"), systemImage: "doc.on.clipboard")
                    }
                    .disabled(!hasFileClipboard || !isFileSection)
                    .help(L10n.string("ui.2246a02a18714b5b"))
                    .keyboardShortcut("v", modifiers: .command)

                    Button {
                        model.section = .transfers
                    } label: {
                        Label(L10n.string("ui.a2f59f64d2623d19"), systemImage: "arrow.up.arrow.down.circle")
                    }
                    .badge(model.activeTransferCount)

                    Picker(L10n.string("ui.9f8f3cc264bae3ce"), selection: $viewMode) {
                        Label(L10n.string("ui.aedd6814ff8c516c"), systemImage: "list.bullet").tag(FileViewMode.list)
                        Label(L10n.string("ui.0d720eeea26466dd"), systemImage: "square.grid.3x3").tag(FileViewMode.grid)
                    }
                    .pickerStyle(.segmented)
                    .disabled(!isFileSection)

                    if viewMode == .grid {
                        groupingMenu
                    }

                } else if isPhotoSection {
                    Button {
                        presentPhotoUploadPanel()
                    } label: {
                        Label(L10n.string("ui.9e07e3c0532d4976"), systemImage: "square.and.arrow.up")
                    }
                    .disabled(model.photoLibrary.currentPath.isEmpty)
                    .help(L10n.string("ui.05bbc74c43b8bd85"))

                    Button {
                        presentBatchDownloadPanel(model.photoLibrary.selectedItems.map(\.fileItem))
                    } label: {
                        Label(L10n.string("ui.4673a23061656125"), systemImage: "square.and.arrow.down")
                    }
                    .disabled(model.photoLibrary.selectedItems.isEmpty)
                    .help(L10n.string("ui.9c859eb557775b37"))

                    Button {
                        shareTargets = model.photoLibrary.selectedItems.map(\.fileItem)
                    } label: {
                        Label(L10n.string("ui.7e564575eb7d5eb2"), systemImage: "link")
                    }
                    .disabled(model.photoLibrary.selectedItems.isEmpty)
                    .help(L10n.string("ui.bcb4ca87b0024cf4"))

                    Button {
                        showingInfoItem = model.photoLibrary.selectedItems.first?.fileItem
                    } label: {
                        Label(L10n.string("ui.e7028601e7da793d"), systemImage: "info.circle")
                    }
                    .disabled(model.photoLibrary.selectedItems.count != 1)
                    .help(L10n.string("ui.e8e8050316db3857"))

                    Button {
                        deleteTargets = model.photoLibrary.selectedItems.map(\.fileItem)
                    } label: {
                        Label(L10n.string("ui.2f9daa828907b93f"), systemImage: "trash")
                    }
                    .disabled(model.photoLibrary.selectedItems.isEmpty)
                    .help(L10n.string("ui.33006fc9ca3c7e3e"))

                    Button {
                        model.section = .transfers
                    } label: {
                        Label(L10n.string("ui.a2f59f64d2623d19"), systemImage: "arrow.up.arrow.down.circle")
                    }
                    .badge(model.activeTransferCount)

                    Menu {
                        Button {
                            Task { await model.photoLibrary.refreshAll() }
                        } label: {
                            Label(L10n.string("ui.049019b1718726b4"), systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Label(L10n.string("ui.ae163cfa2ee91303"), systemImage: "ellipsis.circle")
                    }
                    .disabled(
                        model.photoLibrary.isLoading
                            || model.photoLibrary.isLoadingTimeline
                            || model.photoLibrary.isRetryingTimelineFolders
                    )
                    .help(L10n.string("ui.ae163cfa2ee91303"))
                } else if model.section == .transfers {
                    Button(L10n.string("ui.349c4b7eb1f36c5a")) {
                        clearCompleted()
                    }
                    .disabled(!canClearCompleted)
                    
                    Button {
                        restoreFileBrowser()
                    } label: {
                        Label(L10n.string("ui.72225d17027d36c7"), systemImage: "folder")
                    }
                    } else if model.section == .settings {
                        Button {
                            restoreFileBrowser()
                        } label: {
                            Label(L10n.string("ui.72225d17027d36c7"), systemImage: "folder")
                        }
                    }
                }
            }
        }
        .sheet(isPresented: deleteAlertPresented) {
            ModernDeleteConfirmationDialog(
                targets: deleteTargets,
                profileName: model.profile.displayName,
                currentPath: model.currentPath,
                onConfirm: {
                    let targets = deleteTargets
                    deleteTargets = []
                    model.deleteItems(targets)
                },
                onCancel: {
                    deleteTargets = []
                }
            )
        }
        .overlay(alignment: .bottom) {
            if let toast = model.activeToast {
                InAppToastOverlayView(toast: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .zIndex(999)
            }
        }
        .alert(L10n.string("ui.9c82d7205cdc6a84"), isPresented: restoreAlertPresented) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {
                restoreTarget = nil
            }
            Button(L10n.string("ui.e0534b8a4e46a0cb")) {
                if let item = restoreTarget {
                    model.restoreToOriginalLocation(item)
                }
                restoreTarget = nil
            }
        } message: {
            Text(L10n.string("ui.2c33e68b793e860d"))
        }
        .sheet(item: $showingInfoItem) { item in
            FilePropertiesView(item: item, model: model)
        }
        .sheet(isPresented: Binding(
            get: { !shareTargets.isEmpty },
            set: { if !$0 { shareTargets = [] } }
        )) {
            ShareCreationView(model: model, targets: shareTargets) {
                shareTargets = []
            }
        }
        .alert(L10n.string("ui.9d8546855ba4a822"), isPresented: $model.requiresReauthentication) {
            Button(L10n.string("ui.b8784c8dd5636ff2")) {
                model.requiresReauthentication = false
                Task { await model.load() }
            }
            Button(L10n.string("ui.957244cdb9f232ab")) {
                let message = model.statusMessage ?? L10n.string("ui.bd0bb959fbb4f47c")
                Task { await onSessionExpired(message) }
            }
        } message: {
            Text(reauthenticationMessage)
        }
        .navigationTitle(navigationTitle)
    }

    private var reauthenticationMessage: String {
        L10n.string(
            "auth.reauthentication.recovery",
            model.statusMessage ?? L10n.string("auth.reauthentication.default")
        )
    }

    /// 如果当前有未保存的文本编辑，弹出警告并阻止切换侧边栏栏目。
    /// 返回 `true` 表示已阻止切换，调用方应直接 `return`。
    private func blockSectionChangeDueToUnsavedEdits(
        previousSection: WorkspaceSection?,
        newSection: WorkspaceSection?
    ) -> Bool {
        guard model.hasUnsavedTextEdits, newSection != previousSection else { return false }
        let alert = NSAlert()
        alert.messageText = L10n.string("ui.98a339d246ed8e40")
        alert.informativeText = L10n.string("ui.6744fcd7b7235a67")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("ui.fd4b9e3b6c685bae"))
        alert.runModal()
        isRestoringSectionAfterUnsavedEdit = true
        model.section = previousSection
        return true
    }

    @ViewBuilder
    private var groupingMenu: some View {
        Menu {
            Picker(L10n.string("ui.72148c2201764726"), selection: $fileGrouping) {
                ForEach(FileGrouping.allCases) { grouping in
                    Text(grouping.title).tag(grouping)
                }
            }
        } label: {
            Label(fileGrouping.title, systemImage: "rectangle.3.group")
        }
        .help(L10n.string("ui.493a93469c82d2d9"))
    }

    private var navigationTitle: String {
        switch model.section {
        case .favorites:
            return L10n.string("ui.60a53514eb9228a2")
        case .recent:
            return L10n.string("ui.de314b445e076e84")
        case .remoteLocations:
            return L10n.string("ui.6727073e65194528")
        case .sharedLinks:
            return L10n.string("ui.76cdc4a13d1eecc0")
        case .photos:
            return L10n.string("ui.7b50017ae47eca32")
        case .transfers:
            return L10n.string("ui.74c2308f64b688ae")
        case .chat:
            return L10n.string("ui.4da199fae933d4fa")
        case .nasSettings:
            return L10n.string("ui.b1729f4b03c4b97d")
        case .downloadStation:
            return L10n.string("ui.5248507df52ff455")
        case .containerManager:
            return L10n.string("ui.aaf778d85ce5c2ed")
        case .virtualMachineManager:
            return L10n.string("ui.80c43bd2481c9580")
        case .settings:
            return L10n.string("ui.df3d58c7d84b85f2")
        default:
            return (model.currentPath.isEmpty || model.currentPath == "/") ? model.profile.displayName : (model.currentPath.split(separator: "/").last.map(String.init) ?? model.currentPath)
        }
    }

    private var canClearCompleted: Bool {
        connectedWorkspaces.contains(where: { ws in
            ws.transfers.contains(where: { $0.state == .succeeded || $0.state == .cancelled })
        })
    }

    private func clearCompleted() {
        for ws in connectedWorkspaces {
            ws.clearCompletedTransfers()
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch model.section {
        case .favorites:
            LocationCollectionView(
                title: L10n.string("ui.60a53514eb9228a2"),
                locations: model.favorites,
                emptyMessage: L10n.string("ui.827428ead1987b8a"),
                onOpen: openLocation,
                onRemove: { location in model.toggleFavorite(path: location.path, name: location.name) }
            )
        case .recent:
            RecentLocationsView(
                locations: model.recentLocations,
                onOpen: { location in Task { await model.openRecentLocation(location) } },
                onRemove: model.removeRecentLocation,
                onClearAll: model.clearRecentLocations
            )
        case .remoteLocations:
            RemoteLocationsView(model: model, onOpen: { item in openLocation(item.path) })
        case .sharedLinks:
            ShareLinksView(model: model)
        case .photos:
            PhotoLibraryView(
                model: model.photoLibrary,
                onPreview: { item in
                    let previewItems = model.photoLibrary.displayedItems
                        .filter { !$0.isFolder }
                        .map(\.fileItem)
                    model.preparePhotoPreview(items: previewItems, selected: item.fileItem)
                    presentFloatingPreview()
                },
                onDownload: presentPhotoDownload,
                onDelete: { deleteTargets = $0.map(\.fileItem) },
                onRestore: { restoreTarget = $0.fileItem },
                onMove: { item, destinationPath in
                    let destination = FileItem(
                        profileID: model.profile.id,
                        name: (destinationPath as NSString).lastPathComponent,
                        path: destinationPath,
                        kind: .directory
                    )
                    model.moveByDragging([item.fileItem], to: destination)
                },
                onBrowseModeChange: { browseMode in
                    model.section = .photos(PhotoWorkspacePage(browseMode))
                }
            )
        case .transfers:
            TransferCenterView(model: model, connectedWorkspaces: connectedWorkspaces)
        case .chat:
            ChatWorkspaceView(model: model.chat)
        case .nasSettings:
            NasSettingsView(model: model.nasSettings)
        case .downloadStation:
            ServiceManagementView(module: .downloads, model: model.serviceManagement)
        case .containerManager(let pane):
            ServiceManagementView(
                module: .containers,
                model: model.serviceManagement,
                containerPane: pane,
                onSelectContainerPane: { model.section = .containerManager($0) }
            )
        case .virtualMachineManager(let pane):
            ServiceManagementView(
                module: .virtualMachines,
                model: model.serviceManagement,
                virtualMachinePane: pane,
                onSelectVirtualMachinePane: { model.section = .virtualMachineManager($0) }
            )
        case .settings:
            SettingsView(model: model, onRenameNAS: onRenameNAS)
        default:
            FileBrowserView(
                model: model,
                viewMode: $viewMode,
                fileGrouping: fileGrouping,
                showingInfoItem: $showingInfoItem,
                onDownload: presentDownloadPanel,
                onDownloadBatch: presentBatchDownloadPanel,
                onShare: { shareTargets = $0 },
                onDelete: { deleteTargets = $0 },
                onRestore: { restoreTarget = $0 },
                onCopy: onCopy,
                onCut: onCut,
                hasFileClipboard: hasFileClipboard,
                onPaste: onPaste
            )
        }
    }

    private func openLocation(_ path: String) {
        model.section = .files(path)
        Task { await model.navigate(to: path, recordingHistory: false) }
    }

    private var canNavigateBack: Bool {
        if isFileSection { return model.canGoBack }
        if isPhotoSection { return model.photoLibrary.canGoBack }
        return model.section != nil
    }

    private func navigateBack() {
        if isFileSection {
            Task { await model.goBack() }
        } else if isPhotoSection {
            Task { await model.photoLibrary.goBack() }
        } else {
            restoreFileBrowser()
        }
    }

    private var canNavigateUp: Bool {
        isPhotoSection ? model.photoLibrary.canGoUp : model.canGoUp
    }

    private func navigateUp() {
        if isPhotoSection {
            Task { await model.photoLibrary.goUp() }
        } else {
            Task { await model.goUp() }
        }
    }

    private func restoreFileBrowser() {
        model.section = model.currentFileSection
    }

    private var isFileSection: Bool {
        switch model.section {
        case .files, .recycle: true
        default: false
        }
    }

    private var isPhotoSection: Bool {
        model.section?.belongsToPhotosModule == true
    }

    private var shouldShowFloatingPreview: Bool {
        guard (isFileSection || isPhotoSection),
              model.isPreviewPresented,
              let item = model.selectedItem,
              !item.isDirectory else {
            return false
        }
        return PreviewKind.classify(item) != .unsupported
    }

    private func presentFloatingPreview() {
        let controller: FloatingPreviewWindowController
        if let existing = previewWindowController, existing.profileID == model.profile.id {
            controller = existing
        } else {
            previewWindowController?.closeFromModel()
            controller = FloatingPreviewWindowController(
                model: model,
                onDownload: presentDownloadPanel,
                onDelete: { deleteTargets = $0 },
                onRestore: { restoreTarget = $0 }
            )
            previewWindowController = controller
        }
        controller.show()
    }

    private var deleteAlertPresented: Binding<Bool> {
        Binding(
            get: { !deleteTargets.isEmpty },
            set: { if !$0 { deleteTargets = [] } }
        )
    }

    private var restoreAlertPresented: Binding<Bool> {
        Binding(
            get: { restoreTarget != nil },
            set: { if !$0 { restoreTarget = nil } }
        )
    }

    private func presentUploadPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("ui.bf3f404e39b7d03e")
        panel.prompt = L10n.string("ui.9e07e3c0532d4976")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            model.enqueueUploads(panel.urls, overwrite: false)
        }
    }

    private func presentPhotoUploadPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("ui.4ac6bc668684aba4")
        panel.message = L10n.string("ui.61f2a0f5010d37cf")
        panel.prompt = L10n.string("ui.9e07e3c0532d4976")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            model.enqueueUploads(
                panel.urls,
                to: model.photoLibrary.currentPath,
                overwrite: false
            )
        }
    }

    private func presentDownloadPanel(
        _ item: FileItem,
        folderMode: WorkspaceModel.FolderDownloadMode = .archive
    ) {
        let downloadsDirectoryAsArchive = item.isDirectory && folderMode == .archive
        let panel = NSSavePanel()
        panel.title = downloadsDirectoryAsArchive
            ? L10n.string("ui.240d3a887010077f", String(describing: item.name))
            : (
                item.isDirectory
                    ? L10n.string("folder.download.named", item.name)
                    : L10n.string("ui.6e0814e3ae47bc99", String(describing: item.name))
            )
        panel.message = downloadsDirectoryAsArchive
            ? L10n.string("ui.5a83ac39313ee6d7")
            : (item.isDirectory ? L10n.string("ui.079fb654ed51bcc6") : L10n.string("ui.09cf01aa643d7bb6"))
        panel.nameFieldStringValue = downloadsDirectoryAsArchive ? "\(item.name).zip" : item.name
        if downloadsDirectoryAsArchive {
            panel.allowedContentTypes = [.zip]
        }
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.enqueueDownload(item, to: url, folderMode: folderMode)
        }
    }

    private func presentBatchDownloadPanel(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = L10n.string("ui.e07cc22167e60dff")
        panel.message = L10n.string("ui.9d268900ee8b3e84")
        panel.nameFieldStringValue = L10n.string("ui.9cfc76e4f86bc453")
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            model.enqueueBatchDownload(items, to: url)
        }
    }

    private func presentPhotoDownload(_ items: [PhotoLibraryItem]) {
        let files = items.map(\.fileItem)
        guard let first = files.first else { return }
        if files.count == 1 {
            presentDownloadPanel(first)
        } else {
            presentBatchDownloadPanel(files)
        }
    }

}

@MainActor
private final class FloatingPreviewWindowController: NSObject, NSWindowDelegate {
    let profileID: UUID

    private let model: WorkspaceModel
    private let onDownload: (FileItem, WorkspaceModel.FolderDownloadMode) -> Void
    private let onDelete: ([FileItem]) -> Void
    private let onRestore: (FileItem) -> Void
    private let presentationState = PreviewWindowPresentationState()
    private var window: NSWindow?
    private var isClosingFromModel = false

    init(
        model: WorkspaceModel,
        onDownload: @escaping (FileItem, WorkspaceModel.FolderDownloadMode) -> Void,
        onDelete: @escaping ([FileItem]) -> Void,
        onRestore: @escaping (FileItem) -> Void
    ) {
        profileID = model.profile.id
        self.model = model
        self.onDownload = onDownload
        self.onDelete = onDelete
        self.onRestore = onRestore
    }

    func show() {
        let previewWindow = window ?? makeWindow()
        if !previewWindow.isVisible {
            placeAtScreenCenter(previewWindow)
        }
        previewWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeFromModel() {
        guard let window, window.isVisible else { return }
        isClosingFromModel = true
        window.close()
        isClosingFromModel = false
    }

    func windowWillClose(_ notification: Notification) {
        presentationState.isFullScreen = false
        window = nil
        if !isClosingFromModel, model.isPreviewPresented {
            model.dismissPreview()
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.isSavingText {
            NSSound.beep()
            return false
        }
        guard model.hasUnsavedTextEdits else { return true }
        let alert = NSAlert()
        alert.messageText = L10n.string("ui.01aeaa37eedefb79")
        alert.informativeText = L10n.string("ui.f76d9fbcbb4dd66f")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("ui.fd4b9e3b6c685bae"))
        alert.addButton(withTitle: L10n.string("ui.9b7824cefa1e8b16"))
        guard alert.runModal() == .alertSecondButtonReturn else { return false }
        model.cancelTextEditing()
        return true
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        presentationState.isFullScreen = true
        window?.level = .normal
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        presentationState.isFullScreen = false
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        presentationState.isFullScreen = false
        window?.level = .floating
    }

    private func makeWindow() -> NSWindow {
        let previewWindow = NSWindow(
            contentRect: .zero,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        previewWindow.title = L10n.string("ui.326950f6b7b32e5b")
        previewWindow.titleVisibility = .hidden
        previewWindow.titlebarAppearsTransparent = true
        previewWindow.isMovableByWindowBackground = false
        previewWindow.isReleasedWhenClosed = false
        previewWindow.level = .floating
        previewWindow.collectionBehavior = [.fullScreenPrimary]
        previewWindow.minSize = NSSize(width: 480, height: 420)
        previewWindow.delegate = self
        previewWindow.contentViewController = NSHostingController(
            rootView: FileDetailView(
                model: model,
                windowState: presentationState,
                onDownload: onDownload,
                onDelete: onDelete,
                onRestore: onRestore
            )
        )
        window = previewWindow
        return previewWindow
    }

    private func placeAtScreenCenter(_ window: NSWindow) {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1_280, height: 800)
        let contentSize = NSSize(
            width: min(1_080, max(640, visibleFrame.width * 0.68)),
            height: min(860, max(520, visibleFrame.height * 0.78))
        )
        let frame = NSRect(
            x: visibleFrame.midX - contentSize.width / 2,
            y: visibleFrame.midY - contentSize.height / 2,
            width: contentSize.width,
            height: contentSize.height
        )
        window.setFrame(frame, display: true)
    }
}

private struct TruncationAwareText: View {
    let title: String

    var body: some View {
        ViewThatFits(in: .horizontal) {
            Text(title)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            Text(title)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
        }
    }
}

private struct TruncationAwareLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label {
            TruncationAwareText(title: title)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}

private struct SidebarModuleLabel: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .symbolVariant(.fill)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 22, height: 20, alignment: .center)
                .accessibilityHidden(true)
            TruncationAwareText(title: title)
        }
        .foregroundStyle(
            isSelected
                ? Color(nsColor: .alternateSelectedControlTextColor)
                : tint
        )
        .accessibilityElement(children: .combine)
    }
}

private extension PhotoWorkspacePage {
    var title: String {
        switch self {
        case .timeline: L10n.string("ui.f1241a97b0821a99")
        case .albums: L10n.string("ui.38793c1c1c23437e")
        }
    }

    var icon: String {
        switch self {
        case .timeline: "clock"
        case .albums: "rectangle.stack"
        }
    }
}

private struct SidebarExpandableSectionHeader: View {
    @Environment(\.accessibilityReduceMotion) private var reducesMotion

    let title: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(
                reducesMotion ? nil : .spring(response: 0.3, dampingFraction: 0.8)
            ) {
                isExpanded.toggle()
            }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                    .padding(.trailing, 10)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            L10n.string(
                isExpanded
                    ? "sidebar.section.collapse-accessibility"
                    : "sidebar.section.expand-accessibility",
                title
            )
        )
    }
}

private struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    let profiles: [NasProfile]
    let selectedProfileID: UUID?
    let connectionRoute: AppModel.ConnectionRoute?
    let onAddNAS: () -> Void
    let onSelectNAS: (NasProfile) -> Void
    let onMoveProfiles: (IndexSet, Int) -> Void
    let onLogout: () async -> Void

    @AppStorage("sidebar_file_management_expanded") private var isFileManagementExpanded = false
    @AppStorage("sidebar_photo_management_expanded") private var isPhotoManagementExpanded = false
    @AppStorage("sidebar_container_management_expanded") private var isContainerManagementExpanded = false
    @AppStorage("sidebar_virtual_machine_management_expanded") private var isVirtualMachineManagementExpanded = false
    @State private var isNasListExpanded = true
    @State private var connectingProfileID: UUID? = nil
    @State private var confirmsLogout = false

    var body: some View {
        List(selection: $model.section) {
            Section(L10n.string("ui.4084e8707628b196"), isExpanded: $isNasListExpanded) {
                ForEach(profiles) { profile in
                    let isCurrent = profile.id == selectedProfileID
                    let isConnecting = connectingProfileID == profile.id
                    
                    HStack(spacing: 8) {
                        Image(
                            systemName: isCurrent
                                ? "externaldrive.fill.badge.checkmark"
                                : "externaldrive"
                        )
                        .foregroundStyle(isCurrent ? .blue : .secondary)
                        
                        VStack(alignment: .leading, spacing: 2) {
                            TruncationAwareText(title: profile.displayName)
                                .font(.headline)
                            TruncationAwareText(
                                title: isCurrent ? L10n.string("ui.e403ba5798ba13a4") : profile.host
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        } else if isCurrent {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                                .font(.system(size: 11, weight: .bold))
                                .accessibilityLabel(L10n.string("ui.01d5b647f634042d"))
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 4)
                    .onTapGesture {
                        guard !isCurrent && connectingProfileID == nil else { return }
                        connectingProfileID = profile.id
                        Task {
                            onSelectNAS(profile)
                            try? await Task.sleep(nanoseconds: 800_000_000)
                            connectingProfileID = nil
                        }
                    }
                }
                .onMove(perform: onMoveProfiles)

                HStack {
                    TruncationAwareLabel(
                        title: L10n.string("ui.8249cd04be30c505"),
                        systemImage: "plus"
                    )
                        .foregroundStyle(.blue)
                    Spacer()
                }
                .contentShape(Rectangle())
                .padding(.vertical, 4)
                .onTapGesture {
                    onAddNAS()
                }
            }

            if model.isFileModuleEnabled {
                let isFileChildSelected = [
                    WorkspaceSection.favorites,
                    .recent,
                    .remoteLocations,
                    .sharedLinks
                ].contains(model.section)
                let showFileDetails = isFileManagementExpanded || isFileChildSelected

                Section {
                    NavigationLink(value: model.currentFileSection) {
                        SidebarModuleLabel(
                            title: L10n.string("ui.8e8343f9178e476d"),
                            systemImage: "folder",
                            tint: .blue,
                            isSelected: model.section == model.currentFileSection
                        )
                    }

                    if showFileDetails {
                        NavigationLink(value: WorkspaceSection.favorites) {
                            TruncationAwareLabel(
                                title: L10n.string("ui.60a53514eb9228a2"),
                                systemImage: "star.fill"
                            )
                        }
                        NavigationLink(value: WorkspaceSection.recent) {
                            TruncationAwareLabel(
                                title: L10n.string("ui.de314b445e076e84"),
                                systemImage: "clock"
                            )
                        }
                        NavigationLink(value: WorkspaceSection.remoteLocations) {
                            TruncationAwareLabel(
                                title: L10n.string("ui.6727073e65194528"),
                                systemImage: "network"
                            )
                        }
                        NavigationLink(value: WorkspaceSection.sharedLinks) {
                            TruncationAwareLabel(
                                title: L10n.string("ui.76cdc4a13d1eecc0"),
                                systemImage: "link"
                            )
                        }
                    }
                } header: {
                    SidebarExpandableSectionHeader(
                        title: L10n.string("ui.b3bd5ac7cc4d668b"),
                        isExpanded: Binding(
                            get: { showFileDetails },
                            set: { isExpanded in
                                isFileManagementExpanded = isExpanded
                                if !isExpanded, isFileChildSelected {
                                    model.section = model.currentFileSection
                                }
                            }
                        )
                    )
                }
            }

            if model.isPhotosModuleEnabled {
                let selectedPhotoPage = if case .photos(let page) = model.section {
                    page
                } else {
                    Optional<PhotoWorkspacePage>.none
                }
                let showPhotoDetails = isPhotoManagementExpanded || selectedPhotoPage == .albums

                Section {
                    NavigationLink(value: WorkspaceSection.photos(.timeline)) {
                        SidebarModuleLabel(
                            title: PhotoWorkspacePage.timeline.title,
                            systemImage: "photo.on.rectangle.angled",
                            tint: .orange,
                            isSelected: selectedPhotoPage == .timeline
                        )
                    }

                    if showPhotoDetails {
                        NavigationLink(value: WorkspaceSection.photos(.albums)) {
                            TruncationAwareLabel(
                                title: PhotoWorkspacePage.albums.title,
                                systemImage: PhotoWorkspacePage.albums.icon
                            )
                        }
                    }
                } header: {
                    SidebarExpandableSectionHeader(
                        title: L10n.string("ui.67c683672f7ff48d"),
                        isExpanded: Binding(
                            get: { showPhotoDetails },
                            set: { isExpanded in
                                isPhotoManagementExpanded = isExpanded
                                if !isExpanded, selectedPhotoPage == .albums {
                                    model.section = .photos(.timeline)
                                }
                            }
                        )
                    )
                }
            }

            if model.isChatModuleEnabled {
                Section(L10n.string("ui.aadb2d9d805f9164")) {
                    NavigationLink(value: WorkspaceSection.chat) {
                        SidebarModuleLabel(
                            title: L10n.string("ui.4da199fae933d4fa"),
                            systemImage: "bubble.left.and.bubble.right",
                            tint: .indigo,
                            isSelected: model.section == .chat
                        )
                        .badge(model.chat.totalUnreadCount)
                    }
                }
            }

            if model.isDownloadStationModuleEnabled {
                Section(L10n.string("ui.4673a23061656125")) {
                    NavigationLink(value: WorkspaceSection.downloadStation) {
                        SidebarModuleLabel(
                            title: L10n.string("ui.5248507df52ff455"),
                            systemImage: "arrow.down.circle",
                            tint: .green,
                            isSelected: model.section == .downloadStation
                        )
                    }
                }
            }

            if model.isContainerManagerModuleEnabled {
                let selectedContainerPane = if case .containerManager(let pane) = model.section {
                    pane
                } else {
                    Optional<ContainerManagerPane>.none
                }
                let showContainerDetails = isContainerManagementExpanded
                    || selectedContainerPane.map { $0 != .overview } == true

                Section {
                    NavigationLink(value: WorkspaceSection.containerManager(.overview)) {
                        SidebarModuleLabel(
                            title: ContainerManagerPane.overview.title,
                            systemImage: "shippingbox",
                            tint: .blue,
                            isSelected: selectedContainerPane == .overview
                        )
                    }

                    if showContainerDetails {
                        ForEach(ContainerManagerPane.allCases.dropFirst()) { pane in
                            NavigationLink(value: WorkspaceSection.containerManager(pane)) {
                                TruncationAwareLabel(title: pane.title, systemImage: pane.icon)
                            }
                        }
                    }
                } header: {
                    SidebarExpandableSectionHeader(
                        title: L10n.string("ui.6d23f04b26967d64"),
                        isExpanded: Binding(
                            get: { showContainerDetails },
                            set: { isExpanded in
                                isContainerManagementExpanded = isExpanded
                                if !isExpanded,
                                   selectedContainerPane.map({ $0 != .overview }) == true {
                                    model.section = .containerManager(.overview)
                                }
                            }
                        )
                    )
                }
            }

            if model.isVirtualMachineManagerModuleEnabled {
                let selectedVirtualMachinePane = if case .virtualMachineManager(let pane) = model.section {
                    pane
                } else {
                    Optional<VirtualMachineManagerPane>.none
                }
                let showVirtualMachineDetails = isVirtualMachineManagementExpanded
                    || selectedVirtualMachinePane.map { $0 != .machines } == true

                Section {
                    NavigationLink(value: WorkspaceSection.virtualMachineManager(.machines)) {
                        SidebarModuleLabel(
                            title: VirtualMachineManagerPane.machines.title,
                            systemImage: "desktopcomputer",
                            tint: .indigo,
                            isSelected: selectedVirtualMachinePane == .machines
                        )
                    }

                    if showVirtualMachineDetails {
                        ForEach(VirtualMachineManagerPane.allCases.dropFirst()) { pane in
                            NavigationLink(value: WorkspaceSection.virtualMachineManager(pane)) {
                                TruncationAwareLabel(title: pane.title, systemImage: pane.icon)
                            }
                        }
                    }
                } header: {
                    SidebarExpandableSectionHeader(
                        title: L10n.string("ui.f3fb4b3a41570007"),
                        isExpanded: Binding(
                            get: { showVirtualMachineDetails },
                            set: { isExpanded in
                                isVirtualMachineManagementExpanded = isExpanded
                                if !isExpanded,
                                   selectedVirtualMachinePane.map({ $0 != .machines }) == true {
                                    model.section = .virtualMachineManager(.machines)
                                }
                            }
                        )
                    )
                }
            }

            if model.isNasSettingsModuleEnabled {
                Section(L10n.string("ui.5b50d7c4b5950dc5")) {
                    NavigationLink(value: WorkspaceSection.nasSettings) {
                        SidebarModuleLabel(
                            title: L10n.string("ui.b1729f4b03c4b97d"),
                            systemImage: "server.rack",
                            tint: .teal,
                            isSelected: model.section == .nasSettings
                        )
                    }
                }
            }

            Section(L10n.string("ui.df3d58c7d84b85f2")) {
                if model.isFileModuleEnabled {
                    NavigationLink(value: WorkspaceSection.transfers) {
                        TruncationAwareLabel(
                            title: L10n.string("ui.74c2308f64b688ae"),
                            systemImage: "arrow.up.arrow.down.circle"
                        )
                            .badge(model.activeTransferCount)
                    }
                }
                NavigationLink(value: WorkspaceSection.settings) {
                    TruncationAwareLabel(
                        title: L10n.string("ui.df3d58c7d84b85f2"),
                        systemImage: "gearshape"
                    )
                }
            }
        }
        .listStyle(.sidebar)
        .scrollIndicators(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                if model.isFileModuleEnabled {
                    StorageCapacityView(
                        summary: model.storageSpaceSummary,
                        isLoading: model.isLoadingStorageSpace
                    )
                }
                Divider()
                HStack(spacing: 10) {
                    Image(systemName: connectionRoute?.systemImage ?? "network")
                        .foregroundStyle(.green)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                    TruncationAwareText(
                        title: connectionRoute?.title ?? L10n.string("ui.5be0323e8adcaeae")
                    )
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 6)
                    Button(L10n.string("ui.498e1d59b4d787ee")) {
                        if model.activeTransferCount > 0 {
                            confirmsLogout = true
                        } else {
                            Task { await onLogout() }
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.red)
                    .help(L10n.string("ui.eee4ecee6e6275ea"))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(.bar)
        }
        .alert(L10n.string("ui.d6c03418feb80517"), isPresented: $confirmsLogout) {
            Button(L10n.string("ui.a6474132ac36cbb9"), role: .cancel) {}
            Button(L10n.string("ui.60c04f5366d555f1"), role: .destructive) {
                Task { await onLogout() }
            }
        } message: {
            Text(L10n.string("ui.32e3ea0fabc36062", String(describing: model.activeTransferCount)))
        }
    }
}

private struct StorageCapacityView: View {
    let summary: StorageSpaceSummary?
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary {
                HStack(spacing: 6) {
                    TruncationAwareLabel(
                        title: L10n.string("ui.26de3dd933ce00e3"),
                        systemImage: "internaldrive"
                    )
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    Text(Self.format(summary.totalBytes))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: summary.usedFraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel(L10n.string("ui.042828ceb40655f9"))
                    .accessibilityValue(
                        L10n.string("ui.d98de69897d983e7", String(describing: Self.format(summary.usedBytes)), String(describing: Self.format(summary.remainingBytes)))
                    )
                Text(L10n.string("ui.3dd4b9257f2385ec", String(describing: Self.format(summary.usedBytes)), String(describing: Self.format(summary.remainingBytes))))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if summary.volumeCount > 1 {
                    Text(L10n.string("ui.354a35ab2265ff7b", String(describing: summary.volumeCount)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } else if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.string("ui.8b80123824c3c6d1"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label(L10n.string("ui.1253e85101c3dc79"), systemImage: "internaldrive")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .help(L10n.string("ui.8c1a000858cfcd2d"))
    }

    private static func format(_ bytes: Int64) -> String {
        bytes.formatted(
            .byteCount(style: .file)
                .locale(L10n.locale)
        )
    }
}

private struct LocationCollectionView: View {
    let title: String
    let locations: [FavoriteLocation]
    let emptyMessage: String
    let onOpen: (String) -> Void
    var onRemove: ((FavoriteLocation) -> Void)? = nil

    var body: some View {
        Group {
            if locations.isEmpty {
                ContentUnavailableView(title, systemImage: "folder", description: Text(emptyMessage))
            } else {
                List(locations) { location in
                    HStack {
                        Button {
                            onOpen(location.path)
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(location.name)
                                    Text(location.path).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "folder.fill").foregroundStyle(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        if let onRemove {
                            Button(L10n.string("ui.6135d4159e892541")) { onRemove(location) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .contentShape(Rectangle())
                }
            }
        }
        .fillsAvailableContentArea()
        .navigationTitle(title)
    }
}

private struct RecentLocationsView: View {
    let locations: [FavoriteLocation]
    let onOpen: (FavoriteLocation) -> Void
    let onRemove: (FavoriteLocation) -> Void
    let onClearAll: () -> Void
    @State private var selection: FavoriteLocation.ID?
    @State private var confirmsClearAll = false

    var body: some View {
        Group {
            if locations.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.b25d5816536d9ef0"),
                    systemImage: "clock",
                    description: Text(L10n.string("ui.32761759ec740ab3"))
                )
            } else {
                List(selection: $selection) {
                    ForEach(locations) { location in
                        HStack {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(location.name)
                                    Text(location.path).font(.caption).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "folder.fill").foregroundStyle(.blue)
                            }
                            Spacer()
                            Button(L10n.string("ui.6135d4159e892541"), systemImage: "xmark.circle") { onRemove(location) }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.borderless)
                                .help(L10n.string("ui.8c22e5562e176879"))
                        }
                        .contentShape(Rectangle())
                        .tag(location.id)
                        .onTapGesture(count: 2) { onOpen(location) }
                        .contextMenu {
                            Button(L10n.string("ui.8c22e5562e176879"), role: .destructive) { onRemove(location) }
                        }
                    }
                }
                .toolbar {
                    Button(L10n.string("ui.55f1033fab699842"), systemImage: "trash") { confirmsClearAll = true }
                        .help(L10n.string("ui.61c7e3ab7996a8ff"))
                }
            }
        }
        .fillsAvailableContentArea()
        .navigationTitle(L10n.string("ui.de314b445e076e84"))
        .alert(L10n.string("ui.9f192aaa3a4d5330"), isPresented: $confirmsClearAll) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("ui.55f1033fab699842"), role: .destructive, action: onClearAll)
        } message: {
            Text(L10n.string("ui.faadde4b2f41b490"))
        }
    }
}

private struct RemoteLocationsView: View {
    @Bindable var model: WorkspaceModel
    let onOpen: (FileItem) -> Void
    @State private var showsCreate = false
    @State private var editingItem: FileItem?
    @State private var removingItem: FileItem?
    @State private var filter: RemoteLocationFilter = .all

    private enum RemoteLocationFilter: String, CaseIterable, Identifiable {
        case all
        case cifs
        case nfs
        case iso

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: L10n.string("remote-locations.filter.all")
            case .cifs: L10n.string("remote-locations.protocol.smb")
            case .nfs: L10n.string("remote-locations.protocol.nfs")
            case .iso: L10n.string("remote-locations.protocol.iso")
            }
        }

        func includes(_ protocolType: FileVirtualProtocol) -> Bool {
            self == .all || rawValue == protocolType.rawValue
        }
    }

    private var filteredLocations: [FileVirtualFolder] {
        model.remoteLocations.filter { filter.includes($0.protocolType) }
    }

    private var defaultMountPoint: String {
        let parent = model.shares.first(where: { $0.permissions?.canWrite == true })?.path
            ?? model.shares.first?.path
            ?? "/home"
        return parent + L10n.string("ui.d8d872031d5fe104")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker(L10n.string("remote-locations.filter.label"), selection: $filter) {
                ForEach(RemoteLocationFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            if !model.unavailableRemoteLocationProtocols.isEmpty {
                Label(
                    L10n.string(
                        "remote-locations.partial-unavailable",
                        model.unavailableRemoteLocationProtocols.map(protocolTitle).joined(
                            separator: L10n.string("remote-locations.protocol-list-separator")
                        )
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isStaticText)
            }

            if model.remoteLocationsAreTruncated {
                Label(
                    L10n.string("remote-locations.truncated"),
                    systemImage: "list.bullet.rectangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.bottom, 12)
                .accessibilityAddTraits(.isStaticText)
            }

            if let error = model.remoteLocationsError, !model.remoteLocations.isEmpty {
                Label(error, systemImage: "wifi.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                    .accessibilityAddTraits(.isStaticText)
            }

            Group {
                if (!model.remoteLocationsHasLoaded || model.isLoadingRemoteLocations)
                    && model.remoteLocations.isEmpty {
                    ProgressView(L10n.string("remote-locations.loading"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.remoteLocationsError, model.remoteLocations.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("remote-locations.error.title"), systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button(L10n.string("remote-locations.retry")) {
                            Task { await model.refreshRemoteLocations() }
                        }
                    }
                } else if filteredLocations.isEmpty, !model.remoteLocations.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.string("remote-locations.filtered-empty.title"), systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text(L10n.string("remote-locations.filtered-empty.description"))
                    } actions: {
                        Button(L10n.string("remote-locations.filter.show-all")) { filter = .all }
                    }
                } else if model.remoteLocations.isEmpty {
                    VStack(spacing: 16) {
                    ContentUnavailableView(
                        L10n.string("ui.9155045b349728e4"),
                        systemImage: "network",
                        description: Text(
                            model.allowsRemoteMountManagement
                                ? L10n.string("ui.5021ceb1d3b63a2b")
                                : L10n.string("ui.fe08319f29c48252")
                        )
                    )
                    if model.allowsRemoteMountManagement {
                        Button(L10n.string("ui.21539a2c4f05e43d")) { showsCreate = true }
                    }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filteredLocations) { folder in
                        let location = folder.item
                        Button { onOpen(location) } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(location.name)
                                    Text(remoteLocationDescription(folder))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: folder.protocolType == .iso ? "opticaldisc" : "network")
                                    .foregroundStyle(.blue)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(remoteLocationAccessibilityLabel(folder))
                        .contextMenu {
                            Button(L10n.string("ui.c771248e511fbf93")) { onOpen(location) }
                            if model.allowsRemoteMountManagement && folder.protocolType.supportsManagement {
                                Divider()
                                Button(L10n.string("ui.27765faa9412fc59")) { editingItem = location }
                                Button(L10n.string("ui.94a750d92afbec3e"), role: .destructive) { removingItem = location }
                            }
                        }
                    }
                }
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .navigationTitle(L10n.string("ui.6727073e65194528"))
        .toolbar {
            Button {
                Task { await model.refreshRemoteLocations() }
            } label: {
                Label(L10n.string("remote-locations.refresh"), systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoadingRemoteLocations)

            Button {
                showsCreate = true
            } label: {
                Label(L10n.string("ui.21539a2c4f05e43d"), systemImage: "plus")
            }
            .disabled(!model.allowsRemoteMountManagement || model.isManagingRemoteMount)
            .help(
                model.allowsRemoteMountManagement
                    ? L10n.string("ui.47be2e832d971204")
                    : L10n.string("ui.0b41577c05d286f3")
            )
        }
        .sheet(isPresented: $showsCreate) {
            RemoteMountEditorView(
                existingItem: nil,
                initialMountPoint: defaultMountPoint
            ) { configuration in
                let succeeded = await model.createRemoteMount(configuration)
                return succeeded ? nil : (model.statusMessage ?? L10n.string("ui.b6a766fd18efca46"))
            }
        }
        .sheet(item: $editingItem) { item in
            RemoteMountEditorView(
                existingItem: item,
                initialMountPoint: item.path
            ) { configuration in
                let succeeded = await model.updateRemoteMount(item, configuration: configuration)
                return succeeded ? nil : (model.statusMessage ?? L10n.string("ui.7d859f1cdcf0302b"))
            }
        }
        .alert(L10n.string("ui.d1df2211a0b4fb89"), isPresented: Binding(
            get: { removingItem != nil },
            set: { if !$0 { removingItem = nil } }
        )) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { removingItem = nil }
            Button(L10n.string("ui.96ded06c37b28ebc"), role: .destructive) {
                guard let item = removingItem else { return }
                removingItem = nil
                Task { _ = await model.removeRemoteMount(item) }
            }
        } message: {
            Text(L10n.string("ui.9400b6a479badb98"))
        }
    }

    private func protocolTitle(_ protocolType: FileVirtualProtocol) -> String {
        switch protocolType {
        case .cifs: L10n.string("remote-locations.protocol.smb")
        case .nfs: L10n.string("remote-locations.protocol.nfs")
        case .iso: L10n.string("remote-locations.protocol.iso")
        }
    }

    private func remoteLocationDescription(_ folder: FileVirtualFolder) -> String {
        let protocolName = protocolTitle(folder.protocolType)
        if folder.protocolType == .iso {
            return L10n.string("remote-locations.description.read-only", protocolName, folder.item.path)
        }
        return L10n.string("remote-locations.description", protocolName, folder.item.path)
    }

    private func remoteLocationAccessibilityLabel(_ folder: FileVirtualFolder) -> String {
        if folder.protocolType == .iso {
            return L10n.string(
                "remote-locations.accessibility.read-only",
                folder.item.name,
                protocolTitle(folder.protocolType),
                folder.item.path
            )
        }
        return L10n.string(
            "remote-locations.accessibility",
            folder.item.name,
            protocolTitle(folder.protocolType),
            folder.item.path
        )
    }
}

private struct RemoteMountEditorView: View {
    let existingItem: FileItem?
    let onSave: (RemoteMountConfiguration) async -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var protocolType: RemoteMountProtocol
    @State private var server = ""
    @State private var remotePath = ""
    @State private var mountPoint: String
    @State private var username = ""
    @State private var password = ""
    @State private var domain = ""
    @State private var readOnly = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    init(
        existingItem: FileItem?,
        initialMountPoint: String,
        onSave: @escaping (RemoteMountConfiguration) async -> String?
    ) {
        self.existingItem = existingItem
        self.onSave = onSave
        let rawType = existingItem?.mountPointType?.lowercased() ?? ""
        _protocolType = State(initialValue: rawType.contains("nfs") ? .nfs : .smb)
        _mountPoint = State(initialValue: initialMountPoint)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(
                existingItem == nil ? L10n.string("ui.21539a2c4f05e43d") : L10n.string("ui.3070367ee12e6c91"),
                systemImage: "network"
            )
            .font(.title2.weight(.semibold))

            if existingItem != nil {
                Text(L10n.string("ui.2752260d080806b1"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(L10n.string("ui.12440134971860f7"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Form {
                Picker(L10n.string("ui.485a26050ce57431"), selection: $protocolType) {
                    Text(L10n.string("ui.a8321322c1053180")).tag(RemoteMountProtocol.smb)
                    Text(L10n.string("protocol.nfs")).tag(RemoteMountProtocol.nfs)
                }
                TextField(L10n.string("ui.d3716cc5a2f5a810"), text: $server, prompt: Text(L10n.string("ui.d7cebe5eb5bbe1b4")))
                TextField(L10n.string("ui.9545e72a358cec9f"), text: $remotePath, prompt: Text(L10n.string("ui.cabd6e6b138047b3")))
                TextField(L10n.string("ui.23efe7b33221d11f"), text: $mountPoint, prompt: Text(L10n.string("ui.f2201180d039ff88")))

                if protocolType == .smb {
                    TextField(L10n.string("ui.1a3f0617d6de8e52"), text: $username)
                    SecureField(L10n.string("ui.a621ab606db2a11f"), text: $password)
                    TextField(L10n.string("ui.99ac911a386914a8"), text: $domain)
                }
                Toggle(L10n.string("ui.ac9d2114005fe37f"), isOn: $readOnly)
            }
            .formStyle(.grouped)

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityLabel(L10n.string("ui.c23788be4567dc28", String(describing: errorMessage)))
            }

            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSubmitting)
                Button(existingItem == nil ? L10n.string("ui.a5574109f0208e89") : L10n.string("ui.991bb7cfe5a81550")) {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSubmit || isSubmitting)
                .overlay(alignment: .leading) {
                    if isSubmitting {
                        ProgressView().controlSize(.small).offset(x: -24)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .interactiveDismissDisabled(isSubmitting)
    }

    private var canSubmit: Bool {
        !server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && mountPoint.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/")
    }

    private func submit() {
        guard canSubmit, !isSubmitting else { return }
        isSubmitting = true
        errorMessage = nil
        let configuration = RemoteMountConfiguration(
            protocolType: protocolType,
            server: server,
            remotePath: remotePath,
            mountPoint: mountPoint,
            username: username,
            password: password,
            domain: domain,
            readOnly: readOnly
        )
        Task {
            let failure = await onSave(configuration)
            isSubmitting = false
            if let failure {
                errorMessage = failure
            } else {
                password = ""
                dismiss()
            }
        }
    }
}

private struct ShareCreationView: View {
    @Bindable var model: WorkspaceModel
    let targets: [FileItem]
    let onClose: () -> Void
    @State private var password = ""
    @State private var expirationDays = 0
    @State private var isCreating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("ui.4c4f2eb53c85407b")).font(.title2.weight(.semibold))
            Text(
                targets.count == 1
                    ? L10n.string("item.share.named", targets[0].name)
                    : L10n.string("ui.e1b60edbc9502ad7", String(describing: targets.count))
            )
                .foregroundStyle(.secondary)
            Form {
                VStack(alignment: .leading, spacing: 4) {
                    SecureField(L10n.string("ui.145ffb632a72ddbd"), text: $password)
                        .onChange(of: password) { _, value in
                            if value.count > 16 { password = String(value.prefix(16)) }
                        }
                    Text(L10n.string("ui.0f39ff632ac67207")).font(.caption).foregroundStyle(.secondary)
                }
                Picker(L10n.string("ui.9c2a28e8f98fb5df"), selection: $expirationDays) {
                    Text(L10n.string("ui.824fe235445dd1be")).tag(0)
                    Text(L10n.string("ui.38eefacbb326e37f")).tag(7)
                    Text(L10n.string("ui.84ad2952a3089ce7")).tag(30)
                    Text(L10n.string("ui.cb82f419192b0423")).tag(90)
                }
            }
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel, action: onClose)
                Button {
                    createLink()
                } label: {
                    if isCreating { ProgressView().controlSize(.small) } else { Text(L10n.string("ui.a71bf6df75763893")) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func createLink() {
        isCreating = true
        Task {
            let expiresAt: String?
            if expirationDays == 0 {
                expiresAt = nil
            } else {
                let date = Calendar.current.date(byAdding: .day, value: expirationDays, to: Date()) ?? Date()
                expiresAt = date.formatted(.iso8601.year().month().day())
            }
            if let link = await model.createShareLink(
                paths: targets.map(\.path),
                password: password.isEmpty ? nil : password,
                expiresAt: expiresAt
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url, forType: .string)
                onClose()
            }
            isCreating = false
        }
    }
}

private struct ShareLinksView: View {
    @Bindable var model: WorkspaceModel
    @State private var linkToDelete: FileShareLink?

    var body: some View {
        Group {
            if model.isLoadingShareLinks {
                ProgressView(L10n.string("ui.fe59090f0d4bc698"))
            } else if model.shareLinks.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.a4a471232364a4e3"),
                    systemImage: "link",
                    description: Text(L10n.string("ui.9b90b76e744938f2"))
                )
            } else {
                List(model.shareLinks) { link in
                    HStack(spacing: 12) {
                        Image(systemName: "link.circle.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(link.name.isEmpty ? L10n.string("ui.15d422f6042e7855") : link.name)
                            HStack(spacing: 8) {
                                if link.hasPassword { Label(L10n.string("ui.8aa0da83b66e54f0"), systemImage: "lock.fill") }
                                if let expiration = link.expiresAt { Text(L10n.string("ui.f491436ed3a96c9c", String(describing: expiration))) }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L10n.string("ui.8e86f9b1d54f2c51")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link.url, forType: .string)
                            model.statusIsError = false
                            model.statusMessage = L10n.string("ui.de1804fdf8096e84")
                        }
                        Button(L10n.string("ui.21d728b6664ca9bc"), role: .destructive) { linkToDelete = link }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .fillsAvailableContentArea()
        .navigationTitle(L10n.string("ui.76cdc4a13d1eecc0"))
        .task { await model.loadShareLinks() }
        .alert(L10n.string("ui.0c1777d6b7a70cc7"), isPresented: Binding(
            get: { linkToDelete != nil },
            set: { if !$0 { linkToDelete = nil } }
        )) {
            Button(L10n.string("ui.670ec25af8419f48"), role: .cancel) { linkToDelete = nil }
            Button(L10n.string("ui.21d728b6664ca9bc"), role: .destructive) {
                guard let link = linkToDelete else { return }
                linkToDelete = nil
                Task { await model.deleteShareLinks(ids: [link.id]) }
            }
        } message: {
            Text(L10n.string("ui.0fefbd857362afbe"))
        }
    }
}

private struct FileBrowserView: View {
    @Bindable var model: WorkspaceModel
    @Binding var viewMode: FileViewMode
    let fileGrouping: FileGrouping
    @Binding var showingInfoItem: FileItem?
    let onDownload: (FileItem, WorkspaceModel.FolderDownloadMode) -> Void
    let onDownloadBatch: ([FileItem]) -> Void
    let onShare: ([FileItem]) -> Void
    let onDelete: ([FileItem]) -> Void
    let onRestore: (FileItem) -> Void
    let onCopy: ([FileItem]) -> Void
    let onCut: ([FileItem]) -> Void
    let hasFileClipboard: Bool
    let onPaste: () -> Void
    
    @State private var sortOrder = [KeyPathComparator<FileItem>]()
    @State private var showsCreateFolderPrompt = false
    @State private var showsCreateFilePrompt = false
    @State private var renameTarget: FileItem?
    @State private var renameName = ""
    @State private var compressionTargets: [FileItem] = []
    @State private var extractionTarget: FileItem?
    @State private var newItemName = ""
    @State private var hoveredItemID: FileItem.ID?
    @State private var dropTargetItemID: FileItem.ID?
    @State private var gridItemFrames: [FileItem.ID: CGRect] = [:]
    @State private var marqueeStart: CGPoint?
    @State private var marqueeCurrent: CGPoint?
    @State private var marqueeBaseSelection: Set<FileItem.ID> = []
    @State private var desktopDriveManager: DesktopCloudDriveManager?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct BreadcrumbItem: Identifiable {
        let id = UUID()
        let name: String
        let path: String
        let isLast: Bool
    }

    private struct FileGridGroup: Identifiable {
        let id: String
        let title: String?
        let items: [FileItem]
    }

    private var breadcrumbItems: [BreadcrumbItem] {
        var items: [BreadcrumbItem] = []
        let isRoot = model.currentPath.isEmpty || model.currentPath == "/"
        items.append(
            BreadcrumbItem(
                name: L10n.string("ui.b3bd5ac7cc4d668b"),
                path: "/",
                isLast: isRoot
            )
        )
        if !isRoot {
            let components = model.currentPath.split(separator: "/").map(String.init)
            var currentAccumulatedPath = ""
            for (index, component) in components.enumerated() {
                currentAccumulatedPath += "/" + component
                let isLast = index == components.count - 1
                let displayName = component == "#recycle" ? L10n.string("ui.ba35dc23b245e61e") : component
                items.append(
                    BreadcrumbItem(
                        name: displayName,
                        path: currentAccumulatedPath,
                        isLast: isLast
                    )
                )
            }
        }
        return items
    }

    private var showsCompressionSheet: Binding<Bool> {
        Binding(
            get: { !compressionTargets.isEmpty },
            set: { presented in if !presented { compressionTargets.removeAll() } }
        )
    }

    private var archivePasswordBinding: Binding<WorkspaceModel.ArchivePasswordRequest?> {
        Binding(
            get: { model.archivePasswordRequest },
            set: { request in
                if request == nil, model.archivePasswordRequest != nil {
                    model.cancelArchivePasswordRequest()
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: model.currentPath == "/" || model.currentPath.isEmpty ? "server.rack" : (model.currentPath.contains("#recycle") ? "trash" : "folder"))
                        .foregroundStyle(.secondary)
                    
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(breadcrumbItems) { item in
                                if item.path != "/" {
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                
                                if item.isLast {
                                    Text(item.name)
                                        .font(.headline)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.primary)
                                } else {
                                    Button {
                                        Task {
                                            await model.navigate(to: item.path)
                                        }
                                    } label: {
                                        Text(item.name)
                                            .font(.headline)
                                            .foregroundStyle(.blue)
                                    }
                                    .buttonStyle(.plain)
                                    .onHover { inside in
                                        if inside {
                                            NSCursor.pointingHand.push()
                                        } else {
                                            NSCursor.pop()
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Spacer()
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        model.hasMore
                            ? L10n.string(
                                "items.loaded_progress",
                                String(model.items.count),
                                String(model.totalItemCount)
                            )
                            : L10n.string("ui.fca58a18c69c0ffa", String(describing: model.filteredItems.count))
                    )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.hasMore {
                        Button {
                            Task { await model.loadMore() }
                        } label: {
                            if model.isLoadingMore {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text(L10n.string("ui.af90a08fec8ee28d"))
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isLoadingMore)
                    }
                }
                if let message = model.searchErrorMessage ?? model.statusMessage {
                    Label(
                        message,
                        systemImage: model.searchErrorMessage != nil || model.statusIsError
                            ? "exclamationmark.triangle.fill"
                            : "info.circle"
                    )
                        .font(.caption)
                        .foregroundStyle(model.searchErrorMessage != nil || model.statusIsError ? .red : .secondary)
                }
                if let manager = desktopDriveManager,
                   manager.statusSource == .userAction,
                   let message = manager.statusMessage {
                    Label(
                        message,
                        systemImage: manager.statusIsError
                            ? "exclamationmark.triangle.fill"
                            : "externaldrive.badge.checkmark"
                    )
                    .font(.caption)
                    .foregroundStyle(manager.statusIsError ? .red : .secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            if model.filteredItems.isEmpty {
                ContentUnavailableView(
                    model.searchText.isEmpty ? L10n.string("ui.77fa57e99556ca33") : L10n.string("ui.37b2f0bcebfc3490"),
                    systemImage: model.searchText.isEmpty ? "folder" : "magnifyingglass",
                    description: Text(model.searchText.isEmpty ? L10n.string("ui.efa74aff15bd0698") : L10n.string("ui.49e7a5872fdd5088"))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if viewMode == .list {
                    fileTable
                } else {
                    fileGrid
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .overlay {
            if model.isLoading || model.isRefreshing || model.isSearching {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .background(Color.primary.opacity(0.035))
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.regular)
                        Text(model.isSearching ? L10n.string("ui.c37059a3d9dfd5b1") : (model.isLoading ? L10n.string("ui.36517d179e0f88a8") : L10n.string("ui.d09045a8a3d7a70e")))
                            .font(.callout.weight(.medium))
                        Text(L10n.string("ui.95c3f74ad4864f1a"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.14), radius: 12, y: 5)
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityLabel(model.isSearching ? L10n.string("ui.6b7b618b0639aa8b") : L10n.string("ui.d5e639d4eab3fbaf"))
            } else if let undoMessage = model.recentDragMoveUndoMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Label(undoMessage, systemImage: "arrowshape.turn.up.backward.circle.fill")
                            .lineLimit(1)
                        Button(L10n.string("ui.926a50b98ece2667")) {
                            model.undoRecentDragMove()
                        }
                        .keyboardShortcut("z", modifiers: .command)
                        .disabled(model.isMovingItemsByDrag)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 8, y: 3)
                    .padding(.bottom, 18)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L10n.string("ui.69113f5c36207312", String(describing: undoMessage)))
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: L10n.string("ui.9c8bd1565def7849"))
        .searchScopes($model.searchScope) {
            ForEach(WorkspaceModel.SearchScope.allCases) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .onChange(of: model.searchText) { _, _ in model.updateSearch() }
        .onChange(of: model.searchScope) { _, _ in model.updateSearch() }
        .dropDestination(for: URL.self) { urls, _ in
            model.enqueueUploads(urls)
            return true
        }
        .background {
            FileKeyboardShortcutHandler(
                onAction: handleFileShortcut
            )
        }
        .contextMenu {
            blankAreaContextMenu
        }
        .alert(L10n.string("ui.84244abc71de03ac"), isPresented: $showsCreateFolderPrompt) {
            TextField(L10n.string("ui.bacf701908d8cf45"), text: $newItemName)
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { newItemName = "" }
            Button(L10n.string("ui.cde2cd071d25bbab")) {
                let name = newItemName
                newItemName = ""
                Task { await model.createFolder(named: name) }
            }
            .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(L10n.string("ui.43b157d93104f2df"))
        }
        .alert(L10n.string("ui.b3ab661d4917ccc6"), isPresented: $showsCreateFilePrompt) {
            TextField(L10n.string("ui.28427b364ef9ef33"), text: $newItemName)
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) { newItemName = "" }
            Button(L10n.string("ui.cde2cd071d25bbab")) {
                let name = newItemName
                newItemName = ""
                Task { await model.createEmptyFile(named: name) }
            }
            .disabled(newItemName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(L10n.string("ui.1479722cc4fda8bf"))
        }
        .alert(L10n.string("ui.0d0cbac2eee54113"), isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField(L10n.string("ui.92ddb51db6c45cf7"), text: $renameName)
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {
                renameTarget = nil
            }
            Button(L10n.string("ui.0d0cbac2eee54113")) {
                guard let target = renameTarget else { return }
                let newName = renameName
                renameTarget = nil
                Task { await model.rename(target, to: newName) }
            }
            .disabled(renameName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(L10n.string("ui.709941435c31f938"))
        }
        .sheet(isPresented: showsCompressionSheet) {
            ArchiveCreationView(targets: compressionTargets) { name, format, level, password in
                let targets = compressionTargets
                compressionTargets = []
                model.enqueueCompression(
                    targets,
                    archiveName: name,
                    format: format,
                    level: level,
                    password: password
                )
            } onCancel: {
                compressionTargets = []
            }
        }
        .sheet(item: $extractionTarget) { item in
            ArchiveExtractionView(item: item) { createSubfolder, keepDirectoryStructure, overwrite in
                extractionTarget = nil
                Task {
                    await model.prepareExtraction(
                        item,
                        createSubfolder: createSubfolder,
                        keepDirectoryStructure: keepDirectoryStructure,
                        overwrite: overwrite
                    )
                }
            } onCancel: {
                extractionTarget = nil
            }
        }
        .sheet(item: archivePasswordBinding) { request in
            ArchivePasswordView(
                archiveName: request.item.name,
                errorMessage: request.errorMessage,
                isChecking: model.isCheckingArchivePassword,
                onSubmit: { password in Task { await model.submitArchivePassword(password) } },
                onCancel: model.cancelArchivePasswordRequest
            )
        }
        .task(id: displayedItemIDs) {
            model.updateDisplayedItemOrder(displayedItems)
        }
        .task(id: model.profile.id) {
            guard DesktopCloudDriveAvailability.isAvailable else {
                desktopDriveManager = nil
                return
            }
            let manager = DesktopCloudDriveManager(
                profile: model.profile,
                repository: model.fileRepository,
                sessionBridge: model.desktopDriveSessionBridge
            )
            desktopDriveManager = manager
            await manager.load()
        }
        .navigationTitle(model.currentPath.isEmpty ? L10n.string("ui.39932f24fe11a6ba") : (model.currentPath as NSString).lastPathComponent)
    }

    private var sortedItems: [FileItem] {
        model.filteredItems.sorted(using: sortOrder)
    }

    private var displayedItems: [FileItem] {
        viewMode == .grid ? fileGridGroups.flatMap(\.items) : sortedItems
    }

    private var displayedItemIDs: [FileItem.ID] {
        displayedItems.map(\.id)
    }

    private func selectIfUnselected(_ item: FileItem) {
        if !model.selection.contains(item.id) {
            DispatchQueue.main.async {
                model.selection = [item.id]
            }
        }
    }

    private func beginRename(_ item: FileItem) {
        guard canRename(item) else { return }
        model.selection = [item.id]
        renameName = item.name
        renameTarget = item
    }

    private func renameSelectedItem() {
        guard let item = model.selectedItem else { return }
        beginRename(item)
    }

    private func toggleQuickPreview() {
        guard let item = model.selectedItem,
              !item.isDirectory,
              PreviewKind.classify(item) != .unsupported else { return }
        if model.isPreviewPresented {
            model.dismissPreview()
        } else {
            model.preparePreview()
        }
    }

    private func handleFileShortcut(_ action: MacFileShortcut) {
        switch action {
        case .preview:
            toggleQuickPreview()
        case .rename:
            renameSelectedItem()
        case .open:
            guard let item = model.selectedItem else { return }
            Task { await model.open(item) }
        case .up:
            Task { await model.goUp() }
        case .selectAll:
            model.selection = Set(model.filteredItems.map(\.id))
        case .copy:
            guard !model.selectedItems.isEmpty else { return }
            onCopy(model.selectedItems)
        case .cut:
            guard !model.selectedItems.isEmpty else { return }
            onCut(model.selectedItems)
        case .paste:
            guard hasFileClipboard && canCreateItems else { return }
            onPaste()
        case .info:
            showingInfoItem = model.selectedItem
        case .delete:
            guard !model.selectedItems.isEmpty else { return }
            onDelete(model.selectedItems)
        case .undo:
            guard model.recentDragMoveUndoMessage != nil else { return }
            model.undoRecentDragMove()
        }
    }

    private func canRename(_ item: FileItem) -> Bool {
        // 重命名取决于父目录权限，文件本身的 write 标记在部分 DSM 版本中会误报。
        // 保留共享根目录和回收站保护，其余情况交给 NAS 接口执行最终权限校验。
        canCreateItems && !item.isRecyclePath
    }

    private func isSupportedArchive(_ item: FileItem) -> Bool {
        guard !item.isDirectory else { return false }
        return ["zip", "gz", "tar", "tgz", "tbz", "bz2", "rar", "7z", "iso"]
            .contains(item.fileExtension?.lowercased() ?? "")
    }

    @ViewBuilder
    private func contextMenuForFile(_ item: FileItem) -> some View {
        let targets = contextTargets(for: item)
        if item.isDirectory {
            Button(L10n.string("ui.c771248e511fbf93")) {
                Task { await model.open(item) }
            }
        } else if PreviewKind.classify(item) != .unsupported {
            Button(L10n.string("ui.13d61fea9f174905")) {
                Task { await model.open(item) }
            }
        }
        Button(L10n.string("ui.ec4cd05f5147b1a9")) {
            beginRename(item)
        }
        .disabled(!canRename(item))
        .keyboardShortcut(.return, modifiers: [])
        Button(model.favorites.contains(where: { $0.path == item.path }) ? L10n.string("ui.dca60869e7d26839") : L10n.string("ui.0cfc396e4aa347ad")) {
            model.toggleFavorite(item)
        }
        if canCreateItems && !item.isRecyclePath {
            Divider()
            Button(targets.count > 1 ? L10n.string("ui.d7b17fd1aa5a82f8") : L10n.string("ui.ed3955526cf93b82")) {
                compressionTargets = targets
            }
            if targets.count == 1, isSupportedArchive(item) {
                Button(L10n.string("ui.a79e38aec37eb305")) {
                    extractionTarget = item
                }
            }
        }
        if targets.count > 1 {
            Button(L10n.string("ui.b97cad08035a15e2")) { onDownloadBatch(targets) }
        } else if item.isDirectory {
            Button(L10n.string("ui.f956089b945b92cf")) { onDownload(item, .archive) }
            Button(L10n.string("ui.0f50ddf3fa8bb870")) { onDownload(item, .directory) }
        } else {
            Button(L10n.string("ui.29610562f4b1c377")) { onDownload(item, .archive) }
        }
        if let manager = desktopDriveManager,
           let mapping = manager.mapping(containing: targets.map(\.path)) {
            Divider()
            if manager.isKeepingOffline(mapping) {
                Button(L10n.string("desktopDrive.cancel")) {
                    manager.cancelOffline(mapping)
                }
            } else if manager.itemsAreKeptOffline(targets) {
                Button(L10n.string("desktopDrive.releaseOffline")) {
                    Task { await manager.releaseOffline(targets) }
                }
            } else {
                Button(L10n.string("desktopDrive.keepOffline")) {
                    manager.keepOffline(targets)
                }
            }
        }
        Button(targets.count > 1 ? L10n.string("ui.0d0313e9ffdb27fc") : L10n.string("ui.a6e09bfc6210d1e0")) { onShare(targets) }
        Divider()
        Button(L10n.string("ui.63d90d977348ab1f")) {
            onCopy(contextTargets(for: item))
        }
        .keyboardShortcut("c", modifiers: .command)
        Button(L10n.string("ui.410a8e8a6bf253ac")) {
            onCut(contextTargets(for: item))
        }
        .keyboardShortcut("x", modifiers: .command)
        Button(L10n.string("ui.117e686f123e67e9")) {
            onCut(contextTargets(for: item))
        }
        if item.isRecyclePath, model.allowsVerifiedRestore {
            Divider()
            Button(L10n.string("ui.44614f5e3f1bf84d")) { onRestore(item) }
        }
        Divider()
        Button(L10n.string("ui.a748cc074f78de00")) {
            showingInfoItem = item
        }
        .keyboardShortcut("i", modifiers: .command)
        Divider()
        Button(item.isRecyclePath ? L10n.string("ui.0c6742d6c283bcf7") : L10n.string("ui.0552e329ccf875fb"), role: .destructive) {
            onDelete([item])
        }
        .keyboardShortcut(.delete, modifiers: .command)
    }

    private func contextTargets(for item: FileItem) -> [FileItem] {
        model.selection.contains(item.id) && !model.selectedItems.isEmpty
            ? model.selectedItems
            : [item]
    }

    @ViewBuilder
    private var blankAreaContextMenu: some View {
        Button(L10n.string("ui.aee88743413144a2")) {
            Task { await model.refresh() }
        }
        .disabled(model.isRefreshing)
        Divider()
        Button(L10n.string("ui.33517926747180e6")) { onPaste() }
        .disabled(!hasFileClipboard || !canCreateItems)
        Divider()
        Button(L10n.string("ui.fe33cf222f5b4d78")) {
            newItemName = L10n.string("ui.9e043005fd4d9367")
            showsCreateFolderPrompt = true
        }
        .disabled(!canCreateItems)
        Button(L10n.string("ui.911c82a8b69d5efa")) {
            newItemName = L10n.string("ui.7c477d119775959c")
            showsCreateFilePrompt = true
        }
        .disabled(!canCreateItems)
    }

    private var canCreateItems: Bool {
        !model.currentPath.isEmpty && model.currentPath != "/" && !model.currentPath.split(separator: "/").contains("#recycle")
    }

    private var fileGrid: some View {
        GeometryReader { availableSpace in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(fileGridGroups) { group in
                        VStack(alignment: .leading, spacing: 12) {
                            if let title = group.title {
                                HStack(spacing: 8) {
                                    Text(title)
                                        .font(.headline)
                                    Text(L10n.string("ui.fca58a18c69c0ffa", String(describing: group.items.count)))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .accessibilityElement(children: .combine)
                            }

                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 104), spacing: 16)], spacing: 16) {
                                ForEach(group.items) { item in
                                    FileGridCell(
                                        model: model,
                                        item: item,
                                        isSelected: model.selection.contains(item.id),
                                        isDropTarget: dropTargetItemID == item.id,
                                        onSelect: {
                                            if NSEvent.modifierFlags.contains(.command) {
                                                if model.selection.contains(item.id) {
                                                    model.selection.remove(item.id)
                                                } else {
                                                    model.selection.insert(item.id)
                                                }
                                            } else {
                                                model.selection = [item.id]
                                            }
                                        },
                                        onOpen: {
                                            Task { await model.open(item) }
                                        },
                                        contextMenuContent: AnyView(
                                            contextMenuForFile(item)
                                        )
                                    )
                                    .background {
                                        GeometryReader { proxy in
                                            Color.clear.preference(
                                                key: FileGridFramePreferenceKey.self,
                                                value: [item.id: proxy.frame(in: .named("FileGridSelectionSpace"))]
                                            )
                                        }
                                    }
                                    .draggable(item.id)
                                    .dropDestination(for: String.self) { ids, _ in
                                        handleInternalDrop(ids, onto: item)
                                    } isTargeted: { isTargeted in
                                        updateDropTarget(item, isTargeted: isTargeted)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: availableSpace.size.height, alignment: .top)
                .contentShape(Rectangle())
                .coordinateSpace(name: "FileGridSelectionSpace")
                .overlay(alignment: .topLeading) {
                    if let rectangle = marqueeRectangle {
                        Rectangle()
                            .fill(Color.accentColor.opacity(0.10))
                            .overlay {
                                Rectangle()
                                    .stroke(Color.accentColor.opacity(0.75), lineWidth: 1)
                            }
                            .frame(width: rectangle.width, height: rectangle.height)
                            .offset(x: rectangle.minX, y: rectangle.minY)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .simultaneousGesture(marqueeSelectionGesture)
                .simultaneousGesture(
                    SpatialTapGesture().onEnded { value in
                        if !gridItemFrames.values.contains(where: { $0.contains(value.location) }) {
                            model.selection.removeAll()
                        }
                    }
                )
                .onPreferenceChange(FileGridFramePreferenceKey.self) { gridItemFrames = $0 }
                .padding(16)
            }
            .background(Color(NSColor.controlBackgroundColor).opacity(0.2))
        }
    }

    private var marqueeRectangle: CGRect? {
        guard let start = marqueeStart, let current = marqueeCurrent else { return nil }
        return CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )
    }

    private var marqueeSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("FileGridSelectionSpace"))
            .onChanged { value in
                if marqueeStart == nil {
                    guard !gridItemFrames.values.contains(where: { $0.contains(value.startLocation) }) else { return }
                    marqueeStart = value.startLocation
                    marqueeBaseSelection = NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty
                        ? []
                        : model.selection
                }
                guard marqueeStart != nil else { return }
                marqueeCurrent = value.location
                guard let rectangle = marqueeRectangle else { return }
                let enclosed = Set(gridItemFrames.compactMap { id, frame in
                    frame.intersects(rectangle) ? id : nil
                })
                model.selection = marqueeBaseSelection.union(enclosed)
            }
            .onEnded { _ in
                marqueeStart = nil
                marqueeCurrent = nil
                marqueeBaseSelection.removeAll()
            }
    }

    private func updateDropTarget(_ item: FileItem, isTargeted: Bool) {
        guard item.isDirectory,
              !model.selectedItems.contains(where: { $0.id == item.id }) else {
            if dropTargetItemID == item.id { dropTargetItemID = nil }
            return
        }
        if isTargeted {
            dropTargetItemID = item.id
        } else if dropTargetItemID == item.id {
            dropTargetItemID = nil
        }
    }

    private var fileGridGroups: [FileGridGroup] {
        guard fileGrouping != .none else {
            return [FileGridGroup(id: "all", title: nil, items: sortedItems)]
        }

        var buckets: [String: [FileItem]] = [:]
        var titles: [String: String] = [:]
        for item in sortedItems {
            let group = gridGroup(for: item)
            buckets[group.id, default: []].append(item)
            titles[group.id] = group.title
        }

        return gridGroupOrder.compactMap { id in
            guard let items = buckets[id], !items.isEmpty else { return nil }
            return FileGridGroup(id: id, title: titles[id], items: items)
        }
    }

    private var gridGroupOrder: [String] {
        switch fileGrouping {
        case .none:
            ["all"]
        case .type:
            ["folder", "image", "video", "audio", "document", "other"]
        case .date:
            ["today", "yesterday", "week", "month", "earlier", "unknown-date"]
        case .size:
            ["folder", "tiny", "small", "medium", "large", "unknown-size"]
        }
    }

    private func gridGroup(for item: FileItem) -> (id: String, title: String) {
        switch fileGrouping {
        case .none:
            return ("all", L10n.string("ui.5c55a67935af8f45"))
        case .type:
            if item.isDirectory { return ("folder", L10n.string("ui.7c7802d8adaed72e")) }
            switch PreviewKind.classify(item) {
            case .image: return ("image", L10n.string("ui.d24c10d37db0feea"))
            case .video: return ("video", L10n.string("ui.c20f7618d330a854"))
            case .audio: return ("audio", L10n.string("ui.296c632ec857a0ba"))
            case .pdf, .text: return ("document", L10n.string("ui.2687ccdbb1d2288a"))
            case .unsupported: return ("other", L10n.string("ui.6ef019219ad4700a"))
            }
        case .date:
            guard let date = item.times?.modifiedAt else { return ("unknown-date", L10n.string("ui.664939a1fa2ef755")) }
            let calendar = Calendar.current
            if calendar.isDateInToday(date) { return ("today", L10n.string("ui.d5f5a7a010731feb")) }
            if calendar.isDateInYesterday(date) { return ("yesterday", L10n.string("ui.0c184871f658375a")) }
            if let week = calendar.dateInterval(of: .weekOfYear, for: Date()), week.contains(date) {
                return ("week", L10n.string("ui.b4c6c3eb0bce6b78"))
            }
            if let month = calendar.dateInterval(of: .month, for: Date()), month.contains(date) {
                return ("month", L10n.string("ui.0eeecd26f2ba61f9"))
            }
            return ("earlier", L10n.string("ui.c56a5bb657de8f96"))
        case .size:
            if item.isDirectory { return ("folder", L10n.string("ui.7c7802d8adaed72e")) }
            guard let size = item.sizeBytes else { return ("unknown-size", L10n.string("ui.f8f5f153c20d00b9")) }
            if size < 10 * 1_024 * 1_024 { return ("tiny", L10n.string("ui.70161cf3170dff10")) }
            if size < 100 * 1_024 * 1_024 { return ("small", "10 MB – 100 MB") }
            if size < 1_024 * 1_024 * 1_024 { return ("medium", "100 MB – 1 GB") }
            return ("large", L10n.string("ui.157794b18eccb99e"))
        }
    }

    private func handleInternalDrop(_ ids: [String], onto destination: FileItem) -> Bool {
        defer { dropTargetItemID = nil }
        guard canCreateItems,
              destination.isDirectory,
              let draggedID = ids.first,
              let draggedItem = model.filteredItems.first(where: { $0.id == draggedID }) else {
            return false
        }
        let targets = model.selection.contains(draggedID) && !model.selectedItems.isEmpty
            ? model.selectedItems
            : [draggedItem]
        model.moveByDragging(targets, to: destination)
        return true
    }

    private var fileTable: some View {
        Table(sortedItems, selection: $model.selection, sortOrder: $sortOrder) {
            TableColumn(L10n.string("ui.d44e9b3d3b31d37b"), value: \.name) { item in
                hoverableTableCell(item) {
                    HStack(spacing: 8) {
                        FileIcon(item: item)
                        Text(item.name)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                    .onDrag {
                        selectIfUnselected(item)
                        return NSItemProvider(object: item.id as NSString)
                    } preview: {
                        Label(item.name, systemImage: item.isDirectory ? "folder.fill" : "doc.fill")
                            .padding(8)
                    }
                }
            }
            .width(min: 220, ideal: 320)

            TableColumn(L10n.string("ui.50db7447b966f5ef"), value: \.sizeForSort) { item in
                hoverableTableCell(item) {
                    Text(item.isDirectory ? "—" : item.sizeBytes.map {
                        ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)
                    } ?? "—")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn(L10n.string("ui.ba40014ff496f64e"), value: \.fileTypeDisplay) { item in
                hoverableTableCell(item) {
                    Text(item.fileTypeDisplay)
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 100)

            TableColumn(L10n.string("ui.2cbced881b2df35a"), value: \.modifiedTimeForSort) { item in
                hoverableTableCell(item) {
                    Group {
                        if let date = item.times?.modifiedAt {
                            Text(date, format: .dateTime.year().month().day().hour().minute())
                                .foregroundStyle(.secondary)
                        } else {
                            Text("—").foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .width(min: 130, ideal: 160)

            TableColumn(L10n.string("ui.43a7f4b4c5c88a2a"), value: \.ownerForSort) { item in
                hoverableTableCell(item) {
                    Text(item.owner ?? "—")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 100)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .accessibilityLabel(L10n.string("ui.b37e64a8db35fd15", String(describing: model.currentPath)))
        .background {
            TableDoubleClickHandler(items: sortedItems) { itemID in
                guard let item = sortedItems.first(where: { $0.id == itemID }) else { return }
                Task { await model.open(item) }
            }
        }
        .overlay {
            BlankTableContextMenuArea(
                canPaste: hasFileClipboard && canCreateItems,
                canCreateItems: canCreateItems,
                isRefreshing: model.isRefreshing,
                onPaste: onPaste,
                onCreateFolder: {
                    newItemName = L10n.string("ui.9e043005fd4d9367")
                    showsCreateFolderPrompt = true
                },
                onCreateFile: {
                    newItemName = L10n.string("ui.7c477d119775959c")
                    showsCreateFilePrompt = true
                },
                onRefresh: {
                    Task { await model.refresh() }
                }
            )
            .id("BlankTableContext-\(hasFileClipboard)-\(canCreateItems)-\(model.isRefreshing)")
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { selectedIds in
            if let firstId = selectedIds.first,
               let item = sortedItems.first(where: { $0.id == firstId }) {
                contextMenuForFile(item)
            } else {
                blankAreaContextMenu
            }
        }
    }

    private func hoverableTableCell<Content: View>(
        _ item: FileItem,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                if dropTargetItemID == item.id {
                    Color.accentColor.opacity(0.20)
                } else if hoveredItemID == item.id, !model.selection.contains(item.id) {
                    Color.accentColor.opacity(0.10)
                }
            }
            .overlay {
                if dropTargetItemID == item.id {
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.accentColor.opacity(0.85), lineWidth: 2)
                        .padding(.vertical, 1)
                }
            }
            .dropDestination(for: String.self) { ids, _ in
                handleInternalDrop(ids, onto: item)
            } isTargeted: { isTargeted in
                updateDropTarget(item, isTargeted: isTargeted)
            }
            .onHover { isHovered in
                if isHovered {
                    hoveredItemID = item.id
                } else if hoveredItemID == item.id {
                    hoveredItemID = nil
                }
            }
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.15),
                value: hoveredItemID == item.id
            )
    }
}

private struct FileGridFramePreferenceKey: PreferenceKey {
    static let defaultValue: [FileItem.ID: CGRect] = [:]

    static func reduce(value: inout [FileItem.ID: CGRect], nextValue: () -> [FileItem.ID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private enum MacFileShortcut {
    case preview, rename, open, up, selectAll, copy, cut, paste, info, delete, undo
}

private struct FileKeyboardShortcutHandler: NSViewRepresentable {
    let onAction: (MacFileShortcut) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAction: onAction)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onAction = onAction
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onAction: (MacFileShortcut) -> Void
        private weak var hostView: NSView?
        private var monitor: Any?

        init(onAction: @escaping (MacFileShortcut) -> Void) {
            self.onAction = onAction
        }

        func attach(to view: NSView) {
            hostView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { @MainActor [weak self] event in
                guard let self,
                      !event.isARepeat,
                      event.window === self.hostView?.window,
                      !self.isEditingText(in: event.window) else {
                    return event
                }
                let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
                let action: MacFileShortcut?
                if modifiers.isEmpty {
                    switch event.keyCode {
                    case 49: action = .preview // 空格
                    case 36, 76: action = .rename // Return 与数字键盘 Enter
                    default: action = nil
                    }
                } else if modifiers == .command {
                    switch event.keyCode {
                    case 0: action = .selectAll // ⌘A
                    case 6: action = .undo // ⌘Z
                    case 7: action = .cut // ⌘X
                    case 8: action = .copy // ⌘C
                    case 9: action = .paste // ⌘V
                    case 34: action = .info // ⌘I
                    case 51: action = .delete // ⌘Delete
                    case 125: action = .open // ⌘↓
                    case 126: action = .up // ⌘↑
                    default: action = nil
                    }
                } else {
                    action = nil
                }
                guard let action else { return event }
                self.onAction(action)
                return nil
            }
        }

        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func isEditingText(in window: NSWindow?) -> Bool {
            window?.firstResponder is NSTextView
        }
    }
}

private struct TableDoubleClickHandler: NSViewRepresentable {
    let items: [FileItem]
    let onOpen: (FileItem.ID) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.items = items.map(\.id)
        context.coordinator.onOpen = onOpen
        context.coordinator.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject {
        var items: [FileItem.ID] = []
        var onOpen: (FileItem.ID) -> Void = { _ in }
        private weak var hostView: NSView?
        private var monitor: Any?

        func attach(to view: NSView) {
            hostView = view
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { @MainActor [weak self] event in
                    guard let self,
                          event.clickCount == 2,
                          event.window === self.hostView?.window,
                          let table = self.tableView(at: event.locationInWindow, in: event.window) else {
                        return event
                    }
                    let row = table.row(at: table.convert(event.locationInWindow, from: nil))
                    guard self.items.indices.contains(row) else { return event }
                    self.onOpen(self.items[row])
                    return event
            }
        }

        func detach() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func tableView(at point: NSPoint, in window: NSWindow?) -> NSTableView? {
            guard let contentView = window?.contentView else { return nil }
            return findTable(in: contentView, point: point)
        }

        private func findTable(in view: NSView, point: NSPoint) -> NSTableView? {
            if let table = view as? NSTableView {
                let localPoint = table.convert(point, from: nil)
                if table.visibleRect.contains(localPoint), table.row(at: localPoint) >= 0 {
                    return table
                }
            }
            for subview in view.subviews.reversed() {
                if let table = findTable(in: subview, point: point) {
                    return table
                }
            }
            return nil
        }
    }
}

private struct BlankTableContextMenuArea: NSViewRepresentable {
    let canPaste: Bool
    let canCreateItems: Bool
    let isRefreshing: Bool
    let onPaste: () -> Void
    let onCreateFolder: () -> Void
    let onCreateFile: () -> Void
    let onRefresh: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BlankTableContextNSView {
        let view = BlankTableContextNSView()
        view.coordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: BlankTableContextNSView, context: Context) {
        context.coordinator.canPaste = canPaste
        context.coordinator.canCreateItems = canCreateItems
        context.coordinator.isRefreshing = isRefreshing
        context.coordinator.onPaste = onPaste
        context.coordinator.onCreateFolder = onCreateFolder
        context.coordinator.onCreateFile = onCreateFile
        context.coordinator.onRefresh = onRefresh
    }

    final class Coordinator: NSObject {
        var canPaste = false
        var canCreateItems = false
        var isRefreshing = false
        var onPaste: () -> Void = {}
        var onCreateFolder: () -> Void = {}
        var onCreateFile: () -> Void = {}
        var onRefresh: () -> Void = {}

        func showMenu(for event: NSEvent, in view: NSView) {
            let menu = NSMenu()
            
            let refreshItem = NSMenuItem(title: L10n.string("ui.aee88743413144a2"), action: #selector(refresh), keyEquivalent: "")
            refreshItem.target = self
            refreshItem.isEnabled = !isRefreshing
            menu.addItem(refreshItem)
            
            menu.addItem(.separator())
            
            let pasteItem = NSMenuItem(title: L10n.string("ui.33517926747180e6"), action: #selector(paste), keyEquivalent: "")
            pasteItem.target = self
            pasteItem.isEnabled = canPaste
            menu.addItem(pasteItem)
            
            menu.addItem(.separator())

            let folderItem = NSMenuItem(title: L10n.string("ui.fe33cf222f5b4d78"), action: #selector(createFolder), keyEquivalent: "")
            folderItem.target = self
            folderItem.isEnabled = canCreateItems
            menu.addItem(folderItem)

            let fileItem = NSMenuItem(title: L10n.string("ui.911c82a8b69d5efa"), action: #selector(createFile), keyEquivalent: "")
            fileItem.target = self
            fileItem.isEnabled = canCreateItems
            menu.addItem(fileItem)
            
            NSMenu.popUpContextMenu(menu, with: event, for: view)
        }

        @objc private func refresh() { onRefresh() }
        @objc private func paste() { onPaste() }
        @objc private func createFolder() { onCreateFolder() }
        @objc private func createFile() { onCreateFile() }
    }
}

private final class BlankTableContextNSView: NSView {
    weak var coordinator: BlankTableContextMenuArea.Coordinator?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .rightMouseDown,
              let table = tableView(atWindowPoint: event.locationInWindow) else {
            return nil
        }
        let tablePoint = table.convert(event.locationInWindow, from: nil)
        return table.row(at: tablePoint) == -1 ? self : nil
    }

    override func rightMouseDown(with event: NSEvent) {
        coordinator?.showMenu(for: event, in: self)
    }

    private func tableView(atWindowPoint windowPoint: NSPoint) -> NSTableView? {
        guard let window else { return nil }
        return window.contentView.flatMap { findTable(in: $0, windowPoint: windowPoint) }
    }

    private func findTable(in view: NSView, windowPoint: NSPoint) -> NSTableView? {
        if let table = view as? NSTableView,
           table.visibleRect.contains(table.convert(windowPoint, from: nil)) {
            return table
        }
        for subview in view.subviews.reversed() {
            if let table = findTable(in: subview, windowPoint: windowPoint) {
                return table
            }
        }
        return nil
    }
}

private struct ArchiveCreationView: View {
    let targets: [FileItem]
    let onCreate: (String, ArchiveFormat, ArchiveCompressionLevel, String?) -> Void
    let onCancel: () -> Void

    @State private var archiveName: String
    @State private var format: ArchiveFormat = .zip
    @State private var level: ArchiveCompressionLevel = .moderate
    @State private var password = ""
    @State private var showsPassword = false

    init(
        targets: [FileItem],
        onCreate: @escaping (String, ArchiveFormat, ArchiveCompressionLevel, String?) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.targets = targets
        self.onCreate = onCreate
        self.onCancel = onCancel
        let baseName = targets.count == 1 ? targets[0].name : L10n.string("ui.42b6ace9affb8353")
        _archiveName = State(initialValue: "\(baseName).zip")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.string("ui.e185d04bcc5fef85"), systemImage: "archivebox.fill")
                .font(.title2.weight(.semibold))
            Text(
                targets.count == 1
                    ? L10n.string("item.compress.named", targets[0].name)
                    : L10n.string("ui.9e9fedbbc2308426", String(describing: targets.count))
            )
                .foregroundStyle(.secondary)
            Form {
                TextField(L10n.string("ui.13e694ce68bd0039"), text: $archiveName)
                Picker(L10n.string("ui.0e8b1c78c5f335ba"), selection: $format) {
                    Text(L10n.string("ui.4ba915abd4fd4008")).tag(ArchiveFormat.zip)
                    Text(L10n.string("ui.cbe200589b728e56")).tag(ArchiveFormat.sevenZip)
                }
                .onChange(of: format) { _, newFormat in
                    let desired = newFormat == .zip ? "zip" : "7z"
                    let current = (archiveName as NSString).pathExtension
                    if !current.isEmpty {
                        archiveName = (archiveName as NSString).deletingPathExtension + "." + desired
                    }
                }
                Picker(L10n.string("ui.c5b196e1399fb762"), selection: $level) {
                    Text(L10n.string("ui.8dd1fceed43b6a45")).tag(ArchiveCompressionLevel.moderate)
                    Text(L10n.string("ui.320096f1c73f2097")).tag(ArchiveCompressionLevel.store)
                    Text(L10n.string("ui.2578adcaa131dd22")).tag(ArchiveCompressionLevel.fastest)
                    Text(L10n.string("ui.d0fd2507d68680ab")).tag(ArchiveCompressionLevel.best)
                }
                HStack {
                    Group {
                        if showsPassword {
                            TextField(L10n.string("ui.44733c95379ca123"), text: $password)
                        } else {
                            SecureField(L10n.string("ui.44733c95379ca123"), text: $password)
                        }
                    }
                    Button(showsPassword ? L10n.string("ui.145219e726b87790") : L10n.string("ui.4e1449e7d5e50593")) { showsPassword.toggle() }
                        .buttonStyle(.borderless)
                }
            }
            Text(L10n.string("ui.0f00b880813ce106"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel, action: onCancel)
                Button(L10n.string("ui.b141929b4e20fad7")) {
                    onCreate(archiveName, format, level, password.isEmpty ? nil : password)
                }
                .buttonStyle(.borderedProminent)
                .disabled(archiveName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500)
    }
}

private struct ArchiveExtractionView: View {
    let item: FileItem
    let onExtract: (Bool, Bool, Bool) -> Void
    let onCancel: () -> Void

    @State private var createSubfolder = true
    @State private var keepDirectoryStructure = true
    @State private var overwrite = false
    @State private var confirmsOverwrite = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(L10n.string("ui.9f592131529b5467"), systemImage: "archivebox.fill")
                .font(.title2.weight(.semibold))
            Text(L10n.string("ui.c63d516cb699c824", String(describing: item.name)))
                .foregroundStyle(.secondary)
            Form {
                Toggle(L10n.string("ui.82e9111f1c4f130c"), isOn: $createSubfolder)
                Toggle(L10n.string("ui.afd0935d8e0eeb33"), isOn: $keepDirectoryStructure)
                Toggle(L10n.string("ui.c834c7a717bae791"), isOn: $overwrite)
                if overwrite {
                    Label(L10n.string("ui.5d0f3a5095aeafa0"), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Text(L10n.string("ui.f61b061246e4390f"))
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel, action: onCancel)
                Button(L10n.string("ui.d63e300f62a9a232")) {
                    if overwrite {
                        confirmsOverwrite = true
                    } else {
                        startExtraction()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 500)
        .alert(L10n.string("ui.cf24ad005620d2c7"), isPresented: $confirmsOverwrite) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("ui.3fcff1dca38adc47"), role: .destructive, action: startExtraction)
        } message: {
            Text(L10n.string("ui.a8bca50469cec17d"))
        }
    }

    private func startExtraction() {
        onExtract(createSubfolder, keepDirectoryStructure, overwrite)
    }
}

private struct ArchivePasswordView: View {
    let archiveName: String
    let errorMessage: String?
    let isChecking: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L10n.string("ui.421d797b31083050"), systemImage: "lock.fill")
                .font(.title2.weight(.semibold))
            Text(L10n.string("ui.e607b3e23af516cd", String(describing: archiveName)))
                .foregroundStyle(.secondary)
            SecureField(L10n.string("ui.9bde604e54c266b6"), text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                if isChecking { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel, action: onCancel)
                Button(L10n.string("ui.959216b78f9062f1"), action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || isChecking)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func submit() {
        guard !password.isEmpty, !isChecking else { return }
        onSubmit(password)
        password = ""
    }
}

struct FileIcon: View {
    let item: FileItem

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(width: 22)
            .accessibilityHidden(true)
    }

    private var symbol: String {
        if item.name == "#recycle" { return "trash.square.fill" }
        if item.isDirectory { return "folder.fill" }
        switch PreviewKind.classify(item) {
        case .image: return "photo.fill"
        case .pdf: return "doc.richtext.fill"
        case .text: return "doc.text.fill"
        case .video: return "video.fill"
        case .audio: return "waveform.circle.fill"
        case .unsupported:
            if ["zip", "rar", "7z", "tar", "gz"].contains(item.fileExtension ?? "") {
                return "archivebox.fill"
            }
            return "doc.fill"
        }
    }

    private var color: Color {
        if item.name == "#recycle" { return .orange }
        if item.isDirectory { return .blue }
        switch PreviewKind.classify(item) {
        case .image: return .purple
        case .pdf: return .red
        case .text: return .secondary
        case .video: return .blue
        case .audio: return .green
        case .unsupported: return .orange
        }
    }
}

private struct FilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .fontWeight(.medium)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.blue : Color.secondary.opacity(0.12))
                )
                .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}

private struct TransferCenterView: View {
    @Bindable var model: WorkspaceModel
    let connectedWorkspaces: [WorkspaceModel]

    @State private var selectedNasID: UUID?
    @State private var activeFilter: TaskFilterType? = nil
    @State private var source: TransferSource = .app

    private enum TransferSource: Hashable {
        case app
        case nas

        var title: String {
            switch self {
            case .app: return L10n.string("background-tasks.source-app")
            case .nas: return L10n.string("background-tasks.source-nas")
            }
        }
    }

    private enum TaskFilterType: Hashable {
        case upload
        case download
        case fileOperation
        case completed
        case failed

        var displayName: String {
            switch self {
            case .upload: return L10n.string("ui.9e07e3c0532d4976")
            case .download: return L10n.string("ui.4673a23061656125")
            case .fileOperation: return L10n.string("ui.a6a7e454cf11a050")
            case .completed: return L10n.string("ui.f28461bb49c85647")
            case .failed: return L10n.string("ui.7e9ef4d39655399e")
            }
        }
    }

    private var allConnectedTasks: [ActivityTask] {
        connectedWorkspaces.flatMap { $0.transfers }
    }

    private var baseTasks: [ActivityTask] {
        if let selectedNasID {
            if let ws = connectedWorkspaces.first(where: { $0.profile.id == selectedNasID }) {
                return ws.transfers
            }
            return []
        } else {
            return allConnectedTasks
        }
    }

    private func isTaskFinished(_ task: ActivityTask) -> Bool {
        task.state == .succeeded || task.state == .failed || task.state == .cancelled
    }

    private var availableFilters: [TaskFilterType] {
        var filters: [TaskFilterType] = []
        if baseTasks.contains(where: { $0.kind == .upload && !isTaskFinished($0) }) {
            filters.append(.upload)
        }
        if baseTasks.contains(where: { $0.kind == .download && !isTaskFinished($0) }) {
            filters.append(.download)
        }
        if baseTasks.contains(where: { ($0.kind == .copy || $0.kind == .move || $0.kind == .delete || $0.kind == .restore || $0.kind == .compress || $0.kind == .extract) && !isTaskFinished($0) }) {
            filters.append(.fileOperation)
        }
        if baseTasks.contains(where: { $0.state == .succeeded }) {
            filters.append(.completed)
        }
        if baseTasks.contains(where: { $0.state == .failed || $0.state == .cancelled }) {
            filters.append(.failed)
        }
        return filters
    }

    private var currentActiveFilter: TaskFilterType? {
        let available = availableFilters
        if let activeFilter, available.contains(activeFilter) {
            return activeFilter
        }
        return nil
    }

    private var filteredTasks: [ActivityTask] {
        let tasks = baseTasks
        guard let filter = currentActiveFilter else {
            return tasks
        }
        switch filter {
        case .upload:
            return tasks.filter { $0.kind == .upload && !isTaskFinished($0) }
        case .download:
            return tasks.filter { $0.kind == .download && !isTaskFinished($0) }
        case .fileOperation:
            return tasks.filter { ($0.kind == .copy || $0.kind == .move || $0.kind == .delete || $0.kind == .restore || $0.kind == .compress || $0.kind == .extract) && !isTaskFinished($0) }
        case .completed:
            return tasks.filter { $0.state == .succeeded }
        case .failed:
            return tasks.filter { $0.state == .failed || $0.state == .cancelled }
        }
    }

    private func countForFilter(_ filter: TaskFilterType) -> Int {
        switch filter {
        case .upload:
            return baseTasks.filter { $0.kind == .upload && !isTaskFinished($0) }.count
        case .download:
            return baseTasks.filter { $0.kind == .download && !isTaskFinished($0) }.count
        case .fileOperation:
            return baseTasks.filter { ($0.kind == .copy || $0.kind == .move || $0.kind == .delete || $0.kind == .restore || $0.kind == .compress || $0.kind == .extract) && !isTaskFinished($0) }.count
        case .completed:
            return baseTasks.filter { $0.state == .succeeded }.count
        case .failed:
            return baseTasks.filter { $0.state == .failed || $0.state == .cancelled }.count
        }
    }

    private var canClearCompleted: Bool {
        if let selectedNasID {
            if let ws = connectedWorkspaces.first(where: { $0.profile.id == selectedNasID }) {
                return ws.transfers.contains(where: { $0.state == .succeeded || $0.state == .cancelled })
            }
            return false
        } else {
            return connectedWorkspaces.contains(where: { ws in
                ws.transfers.contains(where: { $0.state == .succeeded || $0.state == .cancelled })
            })
        }
    }

    private func clearCompleted() {
        if let selectedNasID {
            if let ws = connectedWorkspaces.first(where: { $0.profile.id == selectedNasID }) {
                ws.clearCompletedTransfers()
            }
        } else {
            for ws in connectedWorkspaces {
                ws.clearCompletedTransfers()
            }
        }
    }

    private var selectedWorkspaces: [WorkspaceModel] {
        guard let selectedNasID else { return connectedWorkspaces }
        return connectedWorkspaces.filter { $0.profile.id == selectedNasID }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("ui.cebeae3f4b78f233", String(describing: model.profile.displayName)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 6)

            HStack(spacing: 12) {
                Picker(L10n.string("background-tasks.source-label"), selection: $source) {
                    Text(TransferSource.app.title).tag(TransferSource.app)
                    Text(TransferSource.nas.title).tag(TransferSource.nas)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 320)

                if connectedWorkspaces.count > 1 {
                    Divider()
                        .frame(height: 14)

                    Text(L10n.string("label.nas"))
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    FilterChip(title: L10n.string("ui.5c55a67935af8f45"), isSelected: selectedNasID == nil) {
                        selectedNasID = nil
                    }

                    ForEach(connectedWorkspaces, id: \.profile.id) { ws in
                        FilterChip(title: ws.profile.displayName, isSelected: selectedNasID == ws.profile.id) {
                            selectedNasID = ws.profile.id
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            if source == .app {
                let activeFilters = availableFilters
                if !activeFilters.isEmpty {
                    HStack(spacing: 6) {
                        Text(L10n.string("ui.f9082aad585f4fb9"))
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        FilterChip(title: L10n.string("ui.5c55a67935af8f45"), isSelected: currentActiveFilter == nil) {
                            activeFilter = nil
                        }

                        ForEach(activeFilters, id: \.self) { filter in
                            let count = countForFilter(filter)
                            FilterChip(title: "\(filter.displayName) (\(count))", isSelected: currentActiveFilter == filter) {
                                activeFilter = activeFilter == filter ? nil : filter
                            }
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }

            Divider()

            if source == .nas {
                NASBackgroundTaskCenter(workspaces: selectedWorkspaces)
            } else if baseTasks.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.d01c644a2d1f3570"),
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text(L10n.string("ui.f7503c0037f86224"))
                )
                .fillsAvailableContentArea()
            } else if filteredTasks.isEmpty {
                ContentUnavailableView(
                    L10n.string("ui.e8c286bbf6e5bd12"),
                    systemImage: "arrow.up.arrow.down.circle",
                    description: Text(L10n.string("ui.6fed029eeaa6ec22"))
                )
                .fillsAvailableContentArea()
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(filteredTasks) { task in
                            let taskWorkspace = connectedWorkspaces.first(where: { ws in
                                ws.transfers.contains(where: { $0.id == task.id })
                            }) ?? model

                            TransferRow(
                                task: task,
                                canRetry: taskWorkspace.canRetryTransfer(task.id),
                                onPause: { taskWorkspace.pauseTransfer(task.id) },
                                onResume: { taskWorkspace.resumeTransfer(task.id) },
                                onRetry: { taskWorkspace.retryTransfer(task.id) },
                                onCancel: { taskWorkspace.cancelTransfer(task.id) },
                                onDelete: { taskWorkspace.deleteTransfer(task.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .onAppear {
            if selectedNasID == nil {
                selectedNasID = model.profile.id
            }
        }
    }
}

private struct NASBackgroundTaskCenter: View {
    let workspaces: [WorkspaceModel]

    @State private var filter: Filter = .all

    private enum Filter: Hashable {
        case all
        case active
        case finished

        var title: String {
            switch self {
            case .all: return L10n.string("background-tasks.filter-all")
            case .active: return L10n.string("background-tasks.filter-active")
            case .finished: return L10n.string("background-tasks.filter-finished")
            }
        }
    }

    private var isLoading: Bool {
        workspaces.contains(where: \.isLoadingServerBackgroundTasks)
    }

    private var allTasks: [FileBackgroundTaskSummary] {
        workspaces.flatMap(\.serverBackgroundTasks)
    }

    private var hasErrorWithoutContent: Bool {
        allTasks.isEmpty && workspaces.contains { $0.serverBackgroundTaskError != nil }
    }

    private func tasks(for workspace: WorkspaceModel) -> [FileBackgroundTaskSummary] {
        switch filter {
        case .all:
            return workspace.serverBackgroundTasks
        case .active:
            return workspace.serverBackgroundTasks.filter { $0.state == .active }
        case .finished:
            return workspace.serverBackgroundTasks.filter { $0.state == .finished }
        }
    }

    private var filteredTaskCount: Int {
        workspaces.reduce(into: 0) { $0 += tasks(for: $1).count }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("background-tasks.title"))
                        .font(.headline)
                    Text(L10n.string("background-tasks.description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Label(L10n.string("background-tasks.read-only"), systemImage: "eye")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task { await refreshAll() }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label(L10n.string("background-tasks.refresh"), systemImage: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .accessibilityLabel(L10n.string("background-tasks.refresh"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            HStack(spacing: 6) {
                Text(L10n.string("background-tasks.filter-label"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach([Filter.all, .active, .finished], id: \.self) { option in
                    FilterChip(title: option.title, isSelected: filter == option) {
                        filter = option
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            if isLoading && allTasks.isEmpty {
                ProgressView(L10n.string("background-tasks.loading"))
                    .fillsAvailableContentArea()
            } else if hasErrorWithoutContent {
                ContentUnavailableView {
                    Label(L10n.string("background-tasks.error-title"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(workspaces.compactMap(\.serverBackgroundTaskError).first ?? L10n.string("background-tasks.error-description"))
                } actions: {
                    Button(L10n.string("background-tasks.retry")) {
                        Task { await refreshAll() }
                    }
                }
                .fillsAvailableContentArea()
            } else if allTasks.isEmpty {
                ContentUnavailableView(
                    L10n.string("background-tasks.empty-title"),
                    systemImage: "clock.badge.checkmark",
                    description: Text(L10n.string("background-tasks.empty-description"))
                )
                .fillsAvailableContentArea()
            } else if filteredTaskCount == 0 {
                ContentUnavailableView {
                    Label(L10n.string("background-tasks.filtered-empty-title"), systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(L10n.string("background-tasks.filtered-empty-description"))
                } actions: {
                    Button(L10n.string("background-tasks.show-all")) { filter = .all }
                }
                .fillsAvailableContentArea()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(workspaces, id: \.profile.id) { workspace in
                            let visibleTasks = tasks(for: workspace)
                            if !visibleTasks.isEmpty || workspace.serverBackgroundTaskError != nil {
                                Text(workspace.profile.displayName)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 4)

                                ForEach(visibleTasks) { task in
                                    NASBackgroundTaskRow(task: task)
                                }

                                if let error = workspace.serverBackgroundTaskError {
                                    Label(error, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }

                                if workspace.serverBackgroundTaskHasMore {
                                    Button {
                                        Task { await workspace.loadMoreServerBackgroundTasks() }
                                    } label: {
                                        if workspace.isLoadingServerBackgroundTasks {
                                            ProgressView()
                                                .controlSize(.small)
                                        } else {
                                            Text(L10n.string("background-tasks.load-more"))
                                        }
                                    }
                                    .disabled(workspace.isLoadingServerBackgroundTasks)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .task(id: workspaces.map(\.profile.id)) {
            for workspace in workspaces where !workspace.serverBackgroundTaskHasLoaded {
                await workspace.refreshServerBackgroundTasks()
            }
        }
    }

    private func refreshAll() async {
        for workspace in workspaces {
            await workspace.refreshServerBackgroundTasks()
        }
    }
}

private struct NASBackgroundTaskRow: View {
    let task: FileBackgroundTaskSummary

    private var kindTitle: String {
        switch task.kind {
        case .copyOrMove: return L10n.string("background-tasks.kind-copy-move")
        case .delete: return L10n.string("background-tasks.kind-delete")
        case .compress: return L10n.string("background-tasks.kind-compress")
        case .extract: return L10n.string("background-tasks.kind-extract")
        }
    }

    private var stateTitle: String {
        switch task.state {
        case .active: return L10n.string("background-tasks.state-active")
        case .finished: return L10n.string("background-tasks.state-finished")
        }
    }

    private var icon: String {
        switch task.kind {
        case .copyOrMove: return "doc.on.doc"
        case .delete: return "trash"
        case .compress: return "archivebox"
        case .extract: return "arrow.up.doc"
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.1), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(kindTitle)
                        .font(.subheadline.weight(.semibold))
                    Text(stateTitle)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                    Spacer()
                    if let createdAt = task.createdAt {
                        Text(createdAt, format: .dateTime.year().month().day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if task.state == .active {
                    if let progress = task.progress {
                        ProgressView(value: progress)
                            .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel(L10n.string("background-tasks.progress-unknown"))
                    }
                }

                if let detail = detailText {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L10n.string("background-tasks.row-accessibility", kindTitle, stateTitle))
    }

    private var detailText: String? {
        if let processed = task.processedBytes {
            let completed = ByteCountFormatter.string(fromByteCount: processed, countStyle: .file)
            if let total = task.totalBytes {
                let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
                return L10n.string("background-tasks.bytes-progress", completed, totalText)
            }
            return L10n.string("background-tasks.bytes-processed", completed)
        }
        if let processed = task.processedItemCount {
            if let total = task.totalItemCount {
                return L10n.string("background-tasks.items-progress", processed, total)
            }
            return L10n.string("background-tasks.items-processed", processed)
        }
        return nil
    }
}

private struct TransferRow: View {
    let task: ActivityTask
    let canRetry: Bool
    let onPause: () -> Void
    let onResume: () -> Void
    let onRetry: () -> Void
    let onCancel: () -> Void
    let onDelete: () -> Void
    
    @State private var isConfirmingDeletion = false
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部：图标 + 文件名/路径 + 状态 Badge
            HStack(alignment: .center, spacing: 12) {
                // 圆形高亮类型图标
                ZStack {
                    Circle()
                        .fill(iconThemeColor.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(iconThemeColor)
                }
                .accessibilityHidden(true)
                
                // 任务名称与详情路径
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(task.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        
                        Text(kindBadgeLabel)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.primary.opacity(0.06))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                    
                    if let failure = task.failureMessage {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    } else {
                        Text(task.remotePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                
                Spacer(minLength: 8)
                
                // 状态彩色胶囊 Tag
                Text(stateLabel)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(stateBadgeBackground)
                    .foregroundStyle(stateBadgeForeground)
                    .clipShape(Capsule())
            }

            // 进度条
            if let total = task.totalUnits, total > 0 {
                ProgressView(
                    value: Double(min(max(task.completedUnits, 0), total)),
                    total: Double(total)
                )
                .progressViewStyle(.linear)
                .tint(progressTint)
                .accessibilityLabel(L10n.string("ui.4dab9831931a4a38", String(describing: task.displayName)))
                .accessibilityValue(progressAccessibilityValue(total: total))
            } else if task.state == .running || task.state == .cancelling {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // 底部元信息与突出显眼的操作按钮区
            HStack(alignment: .center, spacing: 8) {
                if let transferDetails {
                    Text(transferDetails)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                
                Spacer()

                HStack(spacing: 8) {
                    if task.state == .running, task.kind == .download || task.kind == .upload {
                        TransferActionButton(icon: "pause.fill", label: L10n.string("ui.8d12fc0d4eb26021"), color: .blue, action: onPause)
                    } else if task.state == .paused {
                        TransferActionButton(icon: "play.fill", label: task.kind == .upload ? L10n.string("ui.11b7c7173da21db8") : L10n.string("ui.7c9691192f1b7340"), color: .green, action: onResume)
                    } else if canRetry && (task.state == .failed || task.state == .cancelled) {
                        TransferActionButton(icon: "arrow.clockwise", label: L10n.string("ui.b8784c8dd5636ff2"), color: .blue, action: onRetry)
                    }
                    
                    if task.state == .queued || task.state == .running || task.state == .paused {
                        TransferActionButton(icon: "xmark", label: L10n.string("ui.2cd0f3be8738a86c"), color: .orange, action: onCancel)
                    }
                    
                    // 醒目明确的删除任务按钮
                    TransferDeleteButton(
                        label: isFinishedState ? L10n.string("ui.f2cf9101bb2d8816") : L10n.string("ui.29dfebea0fdac1f6"),
                        action: {
                            if !isFinishedState {
                                isConfirmingDeletion = true
                            } else {
                                onDelete()
                            }
                        }
                    )
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isHovered ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = inside
            }
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if task.state == .running, task.kind == .download || task.kind == .upload {
                Button(L10n.string("ui.8d12fc0d4eb26021"), action: onPause)
            }
            if task.state == .paused {
                Button(task.kind == .upload ? L10n.string("ui.11b7c7173da21db8") : L10n.string("ui.7c9691192f1b7340"), action: onResume)
            }
            if canRetry && (task.state == .failed || task.state == .cancelled) {
                Button(L10n.string("ui.b8784c8dd5636ff2"), action: onRetry)
            }
            if task.state == .queued || task.state == .running || task.state == .paused {
                Button(L10n.string("ui.537d17f1c5313861"), action: onCancel)
            }
            Divider()
            Button(
                isFinishedState ? L10n.string("ui.debfd7b5a3f0fe49") : L10n.string("ui.b0a7a91c9b821434"),
                role: .destructive,
                action: {
                    if !isFinishedState {
                        isConfirmingDeletion = true
                    } else {
                        onDelete()
                    }
                }
            )
        }
        .confirmationDialog(
            L10n.string("ui.1eb43f6b5fe62345"),
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button(
                L10n.string("ui.b0a7a91c9b821434"),
                role: .destructive,
                action: onDelete
            )
            Button(L10n.string("ui.ca6db9df0f202957"), role: .cancel) {}
        } message: {
            Text(task.kind == .download
                ? L10n.string("ui.c01928816c334e4e")
                : L10n.string("ui.350ca379750211a9"))
        }
    }

    private var isFinishedState: Bool {
        task.state == .succeeded || task.state == .failed || task.state == .cancelled
    }

    private var icon: String {
        switch task.kind {
        case .upload: "arrow.up"
        case .download: "arrow.down"
        case .copy: "doc.on.doc"
        case .move: "folder.badge.gearshape"
        case .delete: "trash"
        case .restore: "arrow.uturn.backward"
        case .compress: "archivebox"
        case .extract: "doc.zipper"
        }
    }

    private var iconThemeColor: Color {
        switch task.kind {
        case .upload: .blue
        case .download: .green
        case .copy, .move: .purple
        case .delete: .red
        case .restore: .orange
        case .compress, .extract: .indigo
        }
    }

    private var kindBadgeLabel: String {
        switch task.kind {
        case .upload: L10n.string("ui.9e07e3c0532d4976")
        case .download: L10n.string("ui.4673a23061656125")
        case .copy: L10n.string("ui.63d90d977348ab1f")
        case .move: L10n.string("ui.fc6bb436b8caf08b")
        case .delete: L10n.string("ui.2f9daa828907b93f")
        case .restore: L10n.string("ui.e0534b8a4e46a0cb")
        case .compress: L10n.string("ui.a22879cda61a8da0")
        case .extract: L10n.string("ui.a147ebf3581ab1ee")
        }
    }

    private var stateBadgeBackground: Color {
        switch task.state {
        case .succeeded: .green.opacity(0.12)
        case .failed: .red.opacity(0.12)
        case .paused: .orange.opacity(0.12)
        case .cancelled: .secondary.opacity(0.12)
        default: .blue.opacity(0.12)
        }
    }

    private var stateBadgeForeground: Color {
        switch task.state {
        case .succeeded: .green
        case .failed: .red
        case .paused: .orange
        case .cancelled: .secondary
        default: .blue
        }
    }

    private var progressTint: Color {
        switch task.state {
        case .succeeded: .green
        case .failed: .red
        case .paused: .orange
        default: .blue
        }
    }

    private var stateLabel: String {
        switch task.state {
        case .queued: return L10n.string("ui.26c8cfcbf763073f")
        case .running:
            if let total = task.totalUnits, total > 0 {
                let percentage = Int((Double(task.completedUnits) / Double(total) * 100).rounded())
                return "\(min(max(percentage, 0), 100))%"
            }
            return L10n.string("ui.dc9591e56d502b43")
        case .paused: return task.kind == .upload ? L10n.string("ui.7d53a3f66521e362") : L10n.string("ui.eb0c326b60ae897a")
        case .cancelling: return L10n.string("ui.0b58e0113da68f91")
        case .succeeded: return L10n.string("ui.f28461bb49c85647")
        case .failed: return L10n.string("ui.28384d7afd2e4fa6")
        case .cancelled: return L10n.string("ui.a37778f17c5f3ee5")
        }
    }

    private var transferDetails: String? {
        guard task.kind == .upload
                || task.kind == .download
                || task.kind == .copy
                || task.kind == .move else {
            return nil
        }

        var parts: [String] = []
        if let fileSize = task.fileSizeBytes {
            parts.append(L10n.string("ui.db678ce1adf72227", String(describing: formatBytes(fileSize))))
        }
        if let total = task.totalUnits, total > 0 {
            let prefix: String
            if (task.kind == .copy || task.kind == .move), task.fileSizeBytes != nil {
                prefix = L10n.string("ui.156c8a1021a70e06")
            } else if task.kind == .copy || task.kind == .move {
                prefix = L10n.string("ui.755ca1516d681c2c")
            } else {
                prefix = ""
            }
            parts.append("\(prefix)\(formatBytes(task.completedUnits)) / \(formatBytes(total))")
        } else if task.completedUnits > 0 {
            parts.append(L10n.string("ui.a95725bb323a9eb8", String(describing: formatBytes(task.completedUnits))))
        }
        if let speed = task.bytesPerSecond, speed > 0,
           task.state == .running || task.state == .cancelling {
            parts.append("\(formatBytes(Int64(speed)))/s")
        }
        if let remaining = task.estimatedSecondsRemaining, remaining.isFinite, remaining > 0,
           task.state == .running {
            parts.append(L10n.string("ui.11364de0fdc8576a", String(describing: formatDuration(remaining))))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let rounded = max(Int(seconds.rounded(.up)), 1)
        if rounded < 60 {
            return L10n.string("ui.4579627524209c40", String(describing: rounded))
        }
        if rounded < 3_600 {
            return L10n.string("ui.cd3da627ff642a0c", String(describing: (rounded + 59) / 60))
        }
        let hours = rounded / 3_600
        let minutes = (rounded % 3_600 + 59) / 60
        return minutes > 0
            ? L10n.string("duration.hours_minutes", String(hours), String(minutes))
            : L10n.string("ui.b4f4b24037d30509", String(describing: hours))
    }

    private func progressAccessibilityValue(total: Int64) -> String {
        let percentage = Int((Double(task.completedUnits) / Double(total) * 100).rounded())
        return "\(min(max(percentage, 0), 100))%"
    }
}

private struct TransferActionButton: View {
    let icon: String
    let label: String
    let color: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovered ? color.opacity(0.18) : color.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(color.opacity(0.25), lineWidth: 1)
        )
        .foregroundStyle(color)
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = inside
            }
        }
    }
}

private struct TransferDeleteButton: View {
    let label: String
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 10, weight: .bold))
                Text(label)
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(Color.red)
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.red.opacity(0.18) : Color.red.opacity(0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.red.opacity(0.25), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.easeInOut(duration: 0.12)) {
                isHovered = inside
            }
        }
        .help(L10n.string("ui.7ea7469a91c940e6"))
    }
}


private struct SettingsSectionCard<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(iconColor)
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            
            VStack(alignment: .leading, spacing: 12) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }
}

private struct SettingsRow: View {
    let label: String
    let value: String
    var isMonospaced: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
                .layoutPriority(1)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
                .font(isMonospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
    }
}

struct CacheCleanupOptions: OptionSet {
    let rawValue: Int
    static let safeTrash = CacheCleanupOptions(rawValue: 1 << 0)
    static let photoCache = CacheCleanupOptions(rawValue: 1 << 1)
    static let all: CacheCleanupOptions = [.safeTrash, .photoCache]
}

private struct AppStorageSnapshot {
    let previewCache: Int64
    let photoCache: Int64
    let systemCache: Int64
    let protectedData: Int64

    var safeTrash: Int64 { previewCache + systemCache }
    var reclaimable: Int64 { safeTrash + photoCache }
    var total: Int64 { reclaimable + protectedData }
}

private enum AppStorageInspector {
    static func snapshot() -> AppStorageSnapshot {
        AppStorageSnapshot(
            previewCache: size(of: previewDirectory),
            photoCache: size(of: photoCacheDirectory) + size(of: photoThumbnailDirectory),
            systemCache: size(of: cacheDirectory),
            protectedData: size(of: secureDataDirectory)
        )
    }

    static func clearReclaimableData(options: CacheCleanupOptions = .safeTrash) throws {
        if options.contains(.safeTrash) {
            try removeContents(of: previewDirectory, expectedLastComponent: "LanStashPreview")
            if let bundleID = Bundle.main.bundleIdentifier {
                try removeContents(of: cacheDirectory, expectedLastComponent: bundleID)
            }
            URLCache.shared.removeAllCachedResponses()
        }
        if options.contains(.photoCache) {
            try removeContents(of: photoCacheDirectory, expectedLastComponent: "lanstash-photo-cache")
            try removeContents(of: photoThumbnailDirectory, expectedLastComponent: "lanstash-photo-thumbnails")
        }
    }

    private static var photoCacheDirectory: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("lanstash-photo-cache", isDirectory: true)
    }

    private static var photoThumbnailDirectory: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent("lanstash-photo-thumbnails", isDirectory: true)
    }

    private static var previewDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LanStashPreview", isDirectory: true)
    }

    private static var cacheDirectory: URL {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return root.appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.github.qwertyuiop1995.dsmnativeclient", isDirectory: true)
    }

    private static var secureDataDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("LanStashSecureStore", isDirectory: true)
    }

    private static func size(of root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if values?.isRegularFile == true { total += Int64(values?.fileSize ?? 0) }
        }
        return total
    }

    private static func removeContents(of directory: URL, expectedLastComponent: String) throws {
        guard directory.lastPathComponent == expectedLastComponent else { return }
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        for child in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try manager.removeItem(at: child)
        }
    }
}

private enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case features
    case storage
    case desktopDrive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:
            return L10n.string("ui.82479cb6ca73042d")
        case .features:
            return L10n.string("ui.25f5ce57a1909740")
        case .storage:
            return L10n.string("ui.0e41f8e3d59ec47b")
        case .desktopDrive:
            return L10n.string("desktopDrive.title")
        }
    }

    var icon: String {
        switch self {
        case .general:
            return "gearshape"
        case .features:
            return "square.grid.3x3.fill"
        case .storage:
            return "internaldrive.fill"
        case .desktopDrive:
            return "externaldrive.connected.to.line.below"
        }
    }
}

private struct SettingsView: View {
    @Bindable var model: WorkspaceModel
    let onRenameNAS: (String) -> String?
    @State private var desktopDriveManager: DesktopCloudDriveManager
    @State private var selectedCategory: SettingsCategory = .general
    @State private var showsRenamePrompt = false
    @State private var renamedNAS = ""
    @State private var renameError: String?
    @AppStorage("LanStash_DownloadChunkSize") private var chunkSizeSetting = 8
    @State private var storage = AppStorageInspector.snapshot()
    @State private var confirmsCacheCleanup = false
    @State private var showsSelectiveCleanupSheet = false
    @State private var storageMessage: String?
    @State private var mappingToRemove: DesktopDriveMapping?
    @State private var showsMappingCreator = false
    @State private var showsDiagnosticPreview = false
    @State private var diagnosticPreview = ""
    @State private var showsCommunityReport = false

    init(
        model: WorkspaceModel,
        onRenameNAS: @escaping (String) -> String?
    ) {
        self.model = model
        self.onRenameNAS = onRenameNAS
        _desktopDriveManager = State(
            initialValue: DesktopCloudDriveManager(
                profile: model.profile,
                repository: model.fileRepository,
                sessionBridge: model.desktopDriveSessionBridge
            )
        )
    }

    var body: some View {
        HStack(spacing: 0) {
            // 左侧分类子导航
            settingsSidebar

            Divider()

            // 右侧设置面板
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch selectedCategory {
                    case .general:
                        generalSettingsSection
                    case .features:
                        featuresSettingsSection
                    case .storage:
                        storageSettingsSection
                    case .desktopDrive:
                        desktopDriveSettingsSection
                    }
                }
                .padding(28)
                .frame(maxWidth: 680, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fillsAvailableContentArea(alignment: .topLeading)
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .task {
            storage = AppStorageInspector.snapshot()
            await desktopDriveManager.load()
        }
        .alert(
            L10n.string("desktopDrive.remove.confirm.title"),
            isPresented: Binding(
                get: { mappingToRemove != nil },
                set: { if !$0 { mappingToRemove = nil } }
            )
        ) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {
                mappingToRemove = nil
            }
            Button(L10n.string("desktopDrive.remove"), role: .destructive) {
                guard let mapping = mappingToRemove else { return }
                mappingToRemove = nil
                Task { await desktopDriveManager.remove(mapping) }
            }
        } message: {
            Text(L10n.string("desktopDrive.remove.confirm.message"))
        }
        .alert(L10n.string("ui.536d12618defa1a3"), isPresented: $confirmsCacheCleanup) {
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("ui.9d2998cca5172319"), role: .destructive) {
                model.dismissPreview()
                do {
                    try AppStorageInspector.clearReclaimableData(options: .safeTrash)
                    storage = AppStorageInspector.snapshot()
                    storageMessage = L10n.string("ui.6b4d085770642d6b")
                } catch {
                    storageMessage = L10n.string("ui.1ca55c6d7f531f67")
                }
            }
        } message: {
            Text(L10n.string("ui.d547ad40c1fb9469"))
        }
        .sheet(isPresented: $showsSelectiveCleanupSheet) {
            SelectiveCacheCleanupSheet(storage: storage) { options in
                model.dismissPreview()
                do {
                    try AppStorageInspector.clearReclaimableData(options: options)
                    storage = AppStorageInspector.snapshot()
                    storageMessage = L10n.string("ui.ea80daed400569fc")
                } catch {
                    storageMessage = L10n.string("ui.1ca55c6d7f531f67")
                }
            }
        }
        .sheet(isPresented: $showsMappingCreator) {
            DesktopDriveMappingCreatorSheet(
                manager: desktopDriveManager,
                profileName: model.profile.displayName,
                currentPath: model.currentPath
            )
        }
        .sheet(isPresented: $showsDiagnosticPreview) {
            DesktopDriveDiagnosticExportSheet(preview: diagnosticPreview)
        }
        .sheet(isPresented: $showsCommunityReport) {
            CommunityCompatibilitySubmissionSheet()
        }
        .alert(L10n.string("ui.baa1159c128223dd"), isPresented: $showsRenamePrompt) {
            TextField(L10n.string("ui.65d8f92232ae77b0"), text: $renamedNAS)
            Button(L10n.string("ui.2cd0f3be8738a86c"), role: .cancel) {}
            Button(L10n.string("ui.a3030bf8f16dc63c")) {
                renameError = onRenameNAS(renamedNAS)
            }
            .disabled(renamedNAS.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text(L10n.string("ui.c0fb0cc138b48413"))
        }
    }

    // MARK: - Sub-Sidebar

    @ViewBuilder
    private var settingsSidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string("ui.df3d58c7d84b85f2"))
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(SettingsCategory.allCases) { category in
                Button {
                    selectedCategory = category
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: category.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(selectedCategory == category ? Color.blue : Color.primary)
                            .frame(width: 20)
                        Text(category.title)
                            .font(.body)
                            .foregroundStyle(Color.primary.opacity(selectedCategory == category ? 1.0 : 0.7))
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selectedCategory == category ? Color.primary.opacity(0.08) : Color.clear)
                    )
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(width: 200)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.5))
    }

    // MARK: - Sub-Sections

    @ViewBuilder
    private var generalSettingsSection: some View {
        SettingsSectionCard(
            title: L10n.string("settings.language.title"),
            icon: "globe",
            iconColor: .blue
        ) {
            HStack {
                Text(L10n.string("settings.language.title"))
                Spacer()
                AppLanguagePicker()
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 180)
            }
            Text(L10n.string("settings.language.footer"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }

        SettingsSectionCard(
            title: L10n.string("ui.82479cb6ca73042d"),
            icon: "server.rack",
            iconColor: .blue
        ) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.string("ui.65d8f92232ae77b0"))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.profile.displayName)
                    .textSelection(.enabled)
                Button(L10n.string("ui.1eff9b7d894c0ff9")) {
                    renamedNAS = model.profile.displayName
                    renameError = nil
                    showsRenamePrompt = true
                }
            }
            if let renameError {
                Label(renameError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            Divider().opacity(0.3)
            SettingsRow(label: L10n.string("ui.317c133e7a877caf"), value: "https://\(model.profile.host):\(model.profile.port)")
            Divider().opacity(0.3)
            SettingsRow(label: L10n.string("ui.1a3f0617d6de8e52"), value: model.profile.usernameHint ?? L10n.string("ui.6a1be012c99c34e8"))
            Divider().opacity(0.3)
            SettingsRow(label: L10n.string("ui.b8f945ea49ff3774"), value: L10n.string("ui.39c35b1b42f8d938"))
        }

        SettingsSectionCard(
            title: L10n.string("communityReport.settings.title"),
            icon: "checklist.checked",
            iconColor: .green
        ) {
            Text(L10n.string("communityReport.settings.message"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.string("communityReport.settings.action")) {
                    showsCommunityReport = true
                }
            }
        }
    }

    @ViewBuilder
    private var featuresSettingsSection: some View {
        SettingsSectionCard(
            title: L10n.string("ui.25f5ce57a1909740"),
            icon: "square.grid.3x3.fill",
            iconColor: .blue
        ) {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $model.isFileModuleEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("ui.b3bd5ac7cc4d668b"))
                            .font(.body.weight(.medium))
                        Text(L10n.string("ui.b3ba4f016f790299"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.3)

                Toggle(isOn: $model.isPhotosModuleEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(L10n.string("ui.67c683672f7ff48d"))
                                .font(.body.weight(.medium))
                        }
                        Text(L10n.string("ui.a7b4352894d3f848"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.3)

                Toggle(isOn: $model.isChatModuleEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("ui.4da199fae933d4fa"))
                            .font(.body.weight(.medium))
                        Text(L10n.string("ui.77d90374f41aaf36"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.3)

                Toggle(isOn: $model.isNasSettingsModuleEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("ui.b1729f4b03c4b97d"))
                            .font(.body.weight(.medium))
                        Text(L10n.string("ui.ab0dbdbdfe0bfe42"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.3)

                Toggle(isOn: $model.isDownloadStationModuleEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("ui.5248507df52ff455"))
                            .font(.body.weight(.medium))
                        Text(L10n.string("ui.476f084918556c4f"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.3)

                Toggle(isOn: $model.isContainerManagerModuleEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("ui.aaf778d85ce5c2ed"))
                            .font(.body.weight(.medium))
                        Text(L10n.string("ui.fe5d8ebe107b885f"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                Divider().opacity(0.3)

                Toggle(isOn: $model.isVirtualMachineManagerModuleEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string("ui.80c43bd2481c9580"))
                            .font(.body.weight(.medium))
                        Text(L10n.string("ui.81d1084630dcb682"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    @ViewBuilder
    private var storageSettingsSection: some View {
        SettingsSectionCard(
            title: L10n.string("ui.04451130e17bac43"),
            icon: "arrow.up.and.down.and.sparkles",
            iconColor: .orange
        ) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L10n.string("ui.9159bd6506fdcf1e"))
                        .font(.body)
                    Spacer()
                    Picker("", selection: $chunkSizeSetting) {
                        Text(L10n.string("ui.19e6e917e4b79680")).tag(4)
                        Text(L10n.string("ui.d0621e01d3a44aed")).tag(8)
                        Text(L10n.string("ui.28e307d638dc8de8")).tag(16)
                        Text(L10n.string("ui.9aaec86f3a5dfb9a")).tag(32)
                        Text(L10n.string("ui.d621b33c69f45f77")).tag(64)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 155)
                }

                Text(L10n.string("ui.a684d5ddd3cc0bea"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        SettingsSectionCard(
            title: L10n.string("ui.0e41f8e3d59ec47b"),
            icon: "internaldrive.fill",
            iconColor: .teal
        ) {
            SettingsRow(label: L10n.string("ui.f47f13394910cbaa"), value: ByteCountFormatter.string(fromByteCount: storage.total, countStyle: .file))
            Divider().opacity(0.3)
            SettingsRow(label: L10n.string("ui.f19c6c4c2cf77247"), value: ByteCountFormatter.string(fromByteCount: storage.safeTrash, countStyle: .file))
            Divider().opacity(0.3)
            SettingsRow(label: L10n.string("ui.05ca0d4a5aed9488"), value: ByteCountFormatter.string(fromByteCount: storage.photoCache, countStyle: .file))
            Divider().opacity(0.3)
            SettingsRow(label: L10n.string("ui.5513fba74a6c8c0b"), value: ByteCountFormatter.string(fromByteCount: storage.protectedData, countStyle: .file))
            Text(L10n.string("ui.fa01182022325b0b"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack {
                if let storageMessage {
                    Text(storageMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.string("ui.99a713a1340efda3")) { storage = AppStorageInspector.snapshot() }
                Button(L10n.string("ui.4499f757f9894ee7")) { showsSelectiveCleanupSheet = true }
                    .disabled(storage.reclaimable == 0)
                Button(L10n.string("ui.1079be00e4efe07d")) { confirmsCacheCleanup = true }
                    .disabled(storage.safeTrash == 0)
            }
        }
    }

    @ViewBuilder
    private var desktopDriveSettingsSection: some View {
        SettingsSectionCard(
            title: L10n.string("desktopDrive.title"),
            icon: "externaldrive.connected.to.line.below",
            iconColor: .blue
        ) {
            Text(L10n.string("desktopDrive.description"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack {
                Button(L10n.string("desktopDrive.add")) {
                    showsMappingCreator = true
                }
                .disabled(
                    desktopDriveManager.isBusy
                        || !desktopDriveManager.isAvailable
                )
                Button(
                    L10n.string("desktopDrive.diagnostics.preview")
                ) {
                    do {
                        diagnosticPreview =
                            try desktopDriveManager.diagnosticPreview()
                        showsDiagnosticPreview = true
                    } catch {
                        desktopDriveManager.reportDiagnosticFailure()
                    }
                }
                Spacer()
                if desktopDriveManager.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(
                            L10n.string("desktopDrive.status.working")
                        )
                }
            }

            if !desktopDriveManager.isAvailable {
                Label(
                    L10n.string("desktopDrive.unavailable"),
                    systemImage: "info.circle"
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            } else if desktopDriveManager.mappings.isEmpty {
                Text(L10n.string("desktopDrive.empty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(desktopDriveManager.mappings) { mapping in
                    Divider().opacity(0.3)
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(mapping.displayName)
                                .font(.body.weight(.medium))
                            Text(mappingScopeText(mapping.scope))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                            Label(
                                mappingStatusText(mapping),
                                systemImage: mappingStatusIcon(mapping)
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text(mappingCacheText(mapping))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Text(
                                desktopDriveManager.cacheLocationText(mapping)
                            )
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            if let progress = desktopDriveManager
                                .offlineProgress[mapping.id] {
                                mappingOfflineProgress(
                                    mapping: mapping,
                                    progress: progress
                                )
                            }
                        }
                        Spacer()
                        Button(L10n.string("desktopDrive.open")) {
                            Task { await desktopDriveManager.reveal(mapping) }
                        }
                        .disabled(isRuntimeRecoveryRequired(mapping))
                        Menu(L10n.string("desktopDrive.more")) {
                            if isRuntimeRecoveryRequired(mapping) {
                                Button(
                                    L10n.string(
                                        "desktopDrive.recoverLocalState"
                                    )
                                ) {
                                    Task {
                                        await desktopDriveManager.resume(mapping)
                                    }
                                }
                            } else if isOfflineTaskRunning(mapping) {
                                Button(L10n.string("desktopDrive.cancel")) {
                                    desktopDriveManager.cancelOffline(mapping)
                                }
                            } else if desktopDriveManager.runtimes[mapping.id]?
                                .pinnedPaths.isEmpty == false {
                                Button(L10n.string("desktopDrive.releaseOffline")) {
                                    Task {
                                        await desktopDriveManager.releaseOffline(mapping)
                                    }
                                }
                            } else {
                                Button(L10n.string("desktopDrive.keepOffline")) {
                                    desktopDriveManager.keepMappingOffline(mapping)
                                }
                            }
                            if !isRuntimeRecoveryRequired(mapping) {
                                Divider()
                                if shouldReconnect(mapping) {
                                    Button(L10n.string("desktopDrive.reconnect")) {
                                        Task {
                                            await desktopDriveManager.resume(mapping)
                                        }
                                    }
                                } else if desktopDriveManager.runtimes[mapping.id]?
                                    .isManuallyPaused == true {
                                    Button(L10n.string("desktopDrive.resume")) {
                                        Task {
                                            await desktopDriveManager.resume(mapping)
                                        }
                                    }
                                } else {
                                    Button(L10n.string("desktopDrive.pause")) {
                                        Task {
                                            await desktopDriveManager.pause(mapping)
                                        }
                                    }
                                }
                                Button(L10n.string("desktopDrive.clearCache")) {
                                    Task {
                                        await desktopDriveManager.clearCache(mapping)
                                    }
                                }
                                Menu(L10n.string("desktopDrive.cache.limit")) {
                                    ForEach(
                                        [Int64(5), 10, 20, 50],
                                        id: \.self
                                    ) { gibibytes in
                                        let bytes = gibibytes
                                            * 1_024 * 1_024 * 1_024
                                        Button {
                                            Task {
                                                await desktopDriveManager
                                                    .setTemporaryCacheLimit(
                                                        bytes,
                                                        mapping: mapping
                                                    )
                                            }
                                        } label: {
                                            if mapping.cachePolicy
                                                .temporaryLimitBytes == bytes {
                                                Label(
                                                    L10n.string(
                                                        "desktopDrive.cache.limitGiB",
                                                        gibibytes
                                                    ),
                                                    systemImage: "checkmark"
                                                )
                                            } else {
                                                Text(
                                                    L10n.string(
                                                        "desktopDrive.cache.limitGiB",
                                                        gibibytes
                                                    )
                                                )
                                            }
                                        }
                                    }
                                }
                            }
                            Divider()
                            Button(
                                L10n.string("desktopDrive.remove"),
                                role: .destructive
                            ) {
                                mappingToRemove = mapping
                            }
                        }
                    }
                }
            }

            if let message = desktopDriveManager.statusMessage {
                Label(
                    message,
                    systemImage: desktopDriveManager.statusIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(
                    desktopDriveManager.statusIsError ? .red : .secondary
                )
            }
        }
    }

    private func mappingScopeText(_ scope: DesktopDriveScope) -> String {
        switch scope {
        case .allShares:
            L10n.string("desktopDrive.scope.all")
        case .folder(let path):
            path
        }
    }

    private func mappingCacheText(_ mapping: DesktopDriveMapping) -> String {
        let summary = desktopDriveManager.cacheSummaries[mapping.id] ?? .init()
        return L10n.string(
            "desktopDrive.cache.breakdown",
            ByteCountFormatter.string(
                fromByteCount: summary.temporaryBytes,
                countStyle: .file
            ),
            ByteCountFormatter.string(
                fromByteCount: summary.keptOfflineBytes,
                countStyle: .file
            )
        ) + " · " + L10n.string(
            "desktopDrive.cache.limitValue",
            ByteCountFormatter.string(
                fromByteCount: mapping.cachePolicy.temporaryLimitBytes,
                countStyle: .file
            )
        )
    }

    private func mappingStatusText(_ mapping: DesktopDriveMapping) -> String {
        let state = desktopDriveManager.runtimes[mapping.id]?.state ?? .preparing
        let key = switch state {
        case .preparing: "desktopDrive.state.preparing"
        case .available: "desktopDrive.state.available"
        case .checking: "desktopDrive.state.checking"
        case .paused: "desktopDrive.state.paused"
        case .offline: "desktopDrive.state.offline"
        case .authenticationRequired:
            "desktopDrive.state.authenticationRequired"
        case .cacheVolumeUnavailable:
            "desktopDrive.state.cacheVolumeUnavailable"
        case .insufficientLocalSpace:
            "desktopDrive.state.insufficientLocalSpace"
        case .degraded: "desktopDrive.state.degraded"
        case .recoveryRequired: "desktopDrive.state.recoveryRequired"
        case .removing: "desktopDrive.state.removing"
        case .failed: "desktopDrive.state.failed"
        }
        return L10n.string(key)
    }

    private func mappingStatusIcon(_ mapping: DesktopDriveMapping) -> String {
        switch desktopDriveManager.runtimes[mapping.id]?.state ?? .preparing {
        case .available:
            return "checkmark.circle"
        case .checking, .preparing:
            return "clock"
        case .paused:
            return "pause.circle"
        case .offline, .authenticationRequired, .cacheVolumeUnavailable,
             .insufficientLocalSpace, .degraded, .recoveryRequired:
            return "exclamationmark.triangle"
        case .removing:
            return "minus.circle"
        case .failed:
            return "xmark.circle"
        }
    }

    private func shouldReconnect(_ mapping: DesktopDriveMapping) -> Bool {
        guard let state = desktopDriveManager.runtimes[mapping.id]?.state else {
            return false
        }
        return [
            DesktopDriveMappingState.offline,
            .authenticationRequired,
            .failed,
        ].contains(state)
    }

    private func isRuntimeRecoveryRequired(
        _ mapping: DesktopDriveMapping
    ) -> Bool {
        desktopDriveManager.runtimes[mapping.id]?.state == .recoveryRequired
    }

    @ViewBuilder
    private func mappingOfflineProgress(
        mapping: DesktopDriveMapping,
        progress: DesktopDriveOfflineProgress
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch progress.phase {
            case .planning:
                ProgressView()
                    .controlSize(.small)
                Text(
                    L10n.string(
                        "desktopDrive.offline.planning",
                        progress.discoveredFiles,
                        ByteCountFormatter.string(
                            fromByteCount: progress.discoveredBytes,
                            countStyle: .file
                        )
                    )
                )
            case .checkingSpace:
                ProgressView()
                    .controlSize(.small)
                Text(L10n.string("desktopDrive.offline.checkingSpace"))
            case .requesting:
                ProgressView(
                    value: Double(progress.completedFiles),
                    total: Double(max(progress.totalFiles, 1))
                )
                Text(
                    L10n.string(
                        "desktopDrive.offline.requesting",
                        progress.completedFiles,
                        progress.totalFiles
                    )
                )
            case .downloading:
                ProgressView(
                    value: Double(progress.completedBytes),
                    total: Double(max(progress.totalBytes, 1))
                )
                Text(
                    L10n.string(
                        "desktopDrive.offline.downloading",
                        progress.completedFiles,
                        progress.totalFiles,
                        ByteCountFormatter.string(
                            fromByteCount: progress.completedBytes,
                            countStyle: .file
                        )
                    )
                )
            case .failed:
                if let required = progress.requiredBytes,
                   let available = progress.availableBytes,
                   let shortage = progress.shortageBytes {
                    Text(
                        L10n.string(
                            "desktopDrive.offline.insufficient",
                            ByteCountFormatter.string(
                                fromByteCount: required,
                                countStyle: .file
                            ),
                            progress.volumeName ?? L10n.string("desktopDrive.title"),
                            ByteCountFormatter.string(
                                fromByteCount: available,
                                countStyle: .file
                            ),
                            ByteCountFormatter.string(
                                fromByteCount: shortage,
                                countStyle: .file
                            )
                        )
                    )
                    .foregroundStyle(.red)
                }
            case .completed, .cancelled:
                EmptyView()
            }
        }
        .font(.caption2)
        .accessibilityElement(children: .combine)
    }

    private func isOfflineTaskRunning(_ mapping: DesktopDriveMapping) -> Bool {
        guard let phase = desktopDriveManager.offlineProgress[mapping.id]?.phase else {
            return false
        }
        return [
            .planning, .checkingSpace, .requesting, .downloading,
        ].contains(phase)
    }
}

extension FileItem {
    var modifiedTimeForSort: Date {
        times?.modifiedAt ?? Date.distantPast
    }
    
    var sizeForSort: Int64 {
        sizeBytes ?? -1
    }
    
    var fileTypeDisplay: String {
        if isDirectory { return L10n.string("ui.7c7802d8adaed72e") }
        return fileExtension?.uppercased() ?? L10n.string("ui.1bd7e9d2d5fd30e6")
    }
    
    var ownerForSort: String {
        owner ?? ""
    }
}

struct FileGridCell: View {
    @Bindable var model: WorkspaceModel
    let item: FileItem
    let isSelected: Bool
    let isDropTarget: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let contextMenuContent: AnyView
    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 6) {
            FileGridThumbnail(model: model, item: item)
                .frame(width: 64, height: 48)
            
            Text(item.name)
                .font(.subheadline)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 30, alignment: .top)
        }
        .padding(8)
        .frame(width: 104, height: 104)
        .contentShape(Rectangle())
        .background(
            RightClickDetector {
                onSelect()
            }
        )
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(
                    isDropTarget
                        ? Color.accentColor.opacity(0.22)
                        : isSelected
                        ? Color.accentColor.opacity(0.15)
                        : (isHovered ? Color.accentColor.opacity(0.10) : Color.clear)
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isDropTarget
                        ? Color.accentColor.opacity(0.90)
                        : isSelected
                        ? Color.accentColor.opacity(0.35)
                        : (isHovered ? Color.accentColor.opacity(0.18) : Color.clear),
                    lineWidth: isDropTarget ? 2 : 1
                )
        )
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isHovered)
        .onTapGesture {
            onSelect()
        }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                onOpen()
            }
        )
        .contextMenu {
            contextMenuContent
        }
    }
}

private struct FileGridThumbnail: View {
    @Bindable var model: WorkspaceModel
    let item: FileItem
    @State private var thumbnailData: Data?

    var body: some View {
        Group {
            if let thumbnailData, let decoded = decodedImage(from: thumbnailData) {
                ZStack {
                    Image(decorative: decoded.cgImage, scale: 1, orientation: decoded.orientation)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: 64, height: 48)
                        .clipped()

                    if PreviewKind.classify(item) == .video {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 20))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.48))
                            .shadow(radius: 2)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                }
            } else {
                FileLargeIcon(item: item)
                    .frame(width: 44, height: 44)
            }
        }
        .task(id: item.id) {
            thumbnailData = await model.thumbnailData(for: item)
        }
        .accessibilityHidden(true)
    }
}

struct FileLargeIcon: View {
    let item: FileItem
    
    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .accessibilityHidden(true)
    }
    
    private var symbol: String {
        if item.name == "#recycle" { return "trash.square.fill" }
        if item.isDirectory { return "folder.fill" }
        switch PreviewKind.classify(item) {
        case .image: return "photo.fill"
        case .pdf: return "doc.richtext.fill"
        case .text: return "doc.text.fill"
        case .video: return "video.fill"
        case .audio: return "waveform.circle.fill"
        case .unsupported:
            if ["zip", "rar", "7z", "tar", "gz"].contains(item.fileExtension ?? "") {
                return "archivebox.fill"
            }
            return "doc.fill"
        }
    }
    
    private var color: Color {
        if item.name == "#recycle" { return .orange }
        if item.isDirectory { return .blue }
        switch PreviewKind.classify(item) {
        case .image: return .teal
        case .pdf: return .red
        case .text: return .secondary
        case .video: return .purple
        case .audio: return .orange
        case .unsupported: return .secondary
        }
    }
}

struct FilePropertiesView: View {
    let item: FileItem
    let model: WorkspaceModel
    @Environment(\.dismiss) private var dismiss

    private var folderStatistics: FolderStatistics? {
        model.folderStatisticsResults[item.id]
    }

    private var isCalculatingFolderSize: Bool {
        model.calculatingFolderStatisticsIDs.contains(item.id)
    }

    private var isCancellingFolderSize: Bool {
        model.cancellingFolderStatisticsIDs.contains(item.id)
    }

    private var folderSizeError: String? {
        model.folderStatisticsErrors[item.id]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(L10n.string("ui.a748cc074f78de00"))
                    .font(.headline.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color(NSColor.windowBackgroundColor))
            
            Divider()

            ScrollView {
                VStack(spacing: 20) {
                    // 大图标与名称
                    VStack(spacing: 12) {
                        FileLargeIcon(item: item)
                            .frame(width: 64, height: 64)
                            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
                        
                        Text(item.name)
                            .font(.title3.weight(.bold))
                            .multilineTextAlignment(.center)
                            .textSelection(.enabled)
                    }
                    .padding(.top, 16)
                    
                    // 1. 基本信息卡片
                    SettingsSectionCard(
                        title: L10n.string("ui.e8df058725699a17"),
                        icon: "info.circle",
                        iconColor: .blue
                    ) {
                        SettingsRow(label: L10n.string("ui.a28cf187c617333f"), value: item.fileTypeDisplay)
                        Divider().opacity(0.3)
                        HStack(alignment: .firstTextBaseline) {
                            Text(L10n.string("ui.50db7447b966f5ef"))
                                .foregroundStyle(.secondary)
                            Spacer()
                            if isCalculatingFolderSize, folderStatistics == nil {
                                ProgressView()
                                    .controlSize(.small)
                                Text(
                                    L10n.string(
                                        isCancellingFolderSize
                                            ? "dirsize.cancelling"
                                            : "dirsize.calculating"
                                    )
                                )
                                    .foregroundStyle(.secondary)
                            } else {
                                Text(sizeDisplayValue)
                                    .monospacedDigit()
                                    .multilineTextAlignment(.trailing)
                                if isCalculatingFolderSize {
                                    ProgressView()
                                        .controlSize(.small)
                                        .accessibilityLabel(L10n.string("dirsize.calculating"))
                                }
                            }
                        }
                        if let folderStatistics {
                            Divider().opacity(0.3)
                            SettingsRow(
                                label: L10n.string("ui.7a688306423bec17"),
                                value: L10n.string("ui.1455e4d7dd9068d4", String(describing: folderStatistics.fileCount), String(describing: folderStatistics.folderCount))
                            )
                        }
                        if let folderSizeError {
                            Text(folderSizeError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                        if item.isDirectory {
                            Divider().opacity(0.3)
                            HStack(spacing: 10) {
                                if isCalculatingFolderSize {
                                    Button {
                                        model.cancelFolderStatistics(for: item.id)
                                    } label: {
                                        Text(
                                            L10n.string(
                                                isCancellingFolderSize
                                                    ? "dirsize.cancelling"
                                                    : "dirsize.cancel"
                                            )
                                        )
                                    }
                                    .disabled(isCancellingFolderSize)
                                } else {
                                    Button {
                                        model.startFolderStatistics(for: item)
                                    } label: {
                                        Text(
                                            L10n.string(
                                                folderStatistics == nil
                                                    ? "dirsize.calculate"
                                                    : "dirsize.recalculate"
                                            )
                                        )
                                    }
                                }
                                Spacer()
                            }
                            if isCalculatingFolderSize {
                                Text(L10n.string("dirsize.background-note"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Divider().opacity(0.3)
                        SettingsRow(label: L10n.string("ui.1fb4d574da92f1c1"), value: item.path, isMonospaced: true)
                    }

                    // 2. 时间卡片
                    SettingsSectionCard(
                        title: L10n.string("ui.a229d4f9ee0e4dfa"),
                        icon: "calendar",
                        iconColor: .purple
                    ) {
                        SettingsRow(label: L10n.string("ui.257bbcc44c839db4"), value: formatDateString(item.times?.modifiedAt))
                        if let createdAt = item.times?.createdAt {
                            Divider().opacity(0.3)
                            SettingsRow(label: L10n.string("ui.07ec86e0f1d44f91"), value: formatDateString(createdAt))
                        }
                        if let accessedAt = item.times?.accessedAt {
                            Divider().opacity(0.3)
                            SettingsRow(label: L10n.string("ui.92cfc7de2e886725"), value: formatDateString(accessedAt))
                        }
                    }

                    // 3. 所有权卡片
                    SettingsSectionCard(
                        title: L10n.string("ui.15157c55c392d1e4"),
                        icon: "person.badge.key",
                        iconColor: .green
                    ) {
                        SettingsRow(label: L10n.string("ui.43a7f4b4c5c88a2a"), value: item.owner ?? "—")
                        Divider().opacity(0.3)
                        SettingsRow(label: L10n.string("ui.963ead08d78d597c"), value: item.group ?? "—")
                        Divider().opacity(0.3)
                        SettingsRow(label: L10n.string("ui.281d3a306f2dc6cd"), value: item.permissions?.posixMode != nil ? String(format: "%o", item.permissions!.posixMode!) : "—")
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
        }
        .frame(width: 520, height: 540)
    }

    private var sizeDisplayValue: String {
        if item.isDirectory {
            guard let statistics = folderStatistics else { return "—" }
            return formatBytesDetailed(statistics.sizeBytes, isComplete: statistics.isComplete)
        }
        if let size = item.sizeBytes {
            return formatBytesDetailed(size, isComplete: true)
        }
        return "—"
    }

    private func formatBytesDetailed(_ bytes: Int64, isComplete: Bool) -> String {
        let prefix = isComplete ? "" : L10n.string("ui.7f99164ef0aac2fc")
        if bytes < 0 {
            return L10n.string("ui.698c80932fdc228e", String(describing: prefix))
        }
        if bytes < 1024 {
            return L10n.string("ui.08d75ecb4e667a28", String(describing: prefix), String(describing: bytes))
        }

        let doubleBytes = Double(bytes)
        let formattedSize: String

        if bytes < 1024 * 1024 {
            let kb = doubleBytes / 1024.0
            formattedSize = "\(trimTrailingZeros(kb)) KB"
        } else if bytes < 1024 * 1024 * 1024 {
            let mb = doubleBytes / (1024.0 * 1024.0)
            formattedSize = "\(trimTrailingZeros(mb)) MB"
        } else if bytes < 1024 * 1024 * 1024 * 1024 {
            let gb = doubleBytes / (1024.0 * 1024.0 * 1024.0)
            formattedSize = "\(trimTrailingZeros(gb)) GB"
        } else {
            let tb = doubleBytes / (1024.0 * 1024.0 * 1024.0 * 1024.0)
            formattedSize = "\(trimTrailingZeros(tb)) TB"
        }

        return "\(prefix)\(formattedSize)"
    }

    private func trimTrailingZeros(_ value: Double) -> String {
        var str = String(format: "%.2f", value)
        while str.hasSuffix("0") {
            str.removeLast()
        }
        if str.hasSuffix(".") {
            str.removeLast()
        }
        return str
    }

    private func formatDateString(_ date: Date?) -> String {
        guard let date = date else { return "—" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }
}

private struct DesktopDriveMappingCreatorSheet: View {
    private enum ScopeChoice: String, CaseIterable, Identifiable {
        case allShares
        case currentFolder

        var id: Self { self }
    }

    let manager: DesktopCloudDriveManager
    let profileName: String
    let currentPath: String
    @Environment(\.dismiss) private var dismiss
    @State private var scope: ScopeChoice = .allShares
    @State private var displayName = ""
    @State private var cacheLimitGiB: Int64 = 10
    @State private var cacheLocation: DesktopDriveCacheLocation = .systemDefault
    @State private var cacheVolumeName: String?
    @State private var selectionError: String?
    @State private var isCreating = false

    private var currentFolderAvailable: Bool {
        DesktopDrivePath.normalized(currentPath).map { $0 != "/" } == true
    }

    private var cacheHelpText: String {
        if #available(macOS 15.0, *) {
            return L10n.string("desktopDrive.creator.cacheHelp")
        }
        return L10n.string("desktopDrive.creator.cacheHelpMac14")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.string("desktopDrive.creator.title"))
                .font(.title2.weight(.semibold))
            Text(L10n.string("desktopDrive.creator.description"))
                .foregroundStyle(.secondary)

            Form {
                Picker(L10n.string("desktopDrive.creator.scope"), selection: $scope) {
                    Text(L10n.string("desktopDrive.scope.all"))
                        .tag(ScopeChoice.allShares)
                    Text(L10n.string("desktopDrive.creator.currentFolder"))
                        .tag(ScopeChoice.currentFolder)
                        .disabled(!currentFolderAvailable)
                }
                TextField(
                    L10n.string("desktopDrive.creator.name"),
                    text: $displayName
                )
                Picker(
                    L10n.string("desktopDrive.cache.limit"),
                    selection: $cacheLimitGiB
                ) {
                    ForEach([Int64(5), 10, 20, 50], id: \.self) {
                        Text(
                            L10n.string(
                                "desktopDrive.cache.limitGiB",
                                $0
                            )
                        ).tag($0)
                    }
                }
                LabeledContent(L10n.string("desktopDrive.creator.cacheDisk")) {
                    HStack {
                        Text(
                            cacheVolumeName
                                ?? L10n.string("desktopDrive.creator.systemDisk")
                        )
                        if #available(macOS 15.0, *) {
                            Button(L10n.string("desktopDrive.creator.chooseDisk")) {
                                chooseCacheVolume()
                            }
                        }
                        if cacheVolumeName != nil {
                            Button(L10n.string("desktopDrive.creator.useSystemDisk")) {
                                cacheLocation = .systemDefault
                                cacheVolumeName = nil
                                selectionError = nil
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Text(cacheHelpText)
            .font(.caption)
            .foregroundStyle(.secondary)

            if let selectionError {
                Label(selectionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if manager.statusIsError, let message = manager.statusMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) {
                    dismiss()
                }
                Button(L10n.string("desktopDrive.creator.create")) {
                    createMapping()
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    isCreating
                        || displayName.trimmingCharacters(
                            in: .whitespacesAndNewlines
                        ).isEmpty
                        || (scope == .currentFolder && !currentFolderAvailable)
                )
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear {
            if displayName.isEmpty {
                displayName = profileName
            }
        }
        .onChange(of: scope) { _, value in
            switch value {
            case .allShares:
                displayName = profileName
            case .currentFolder:
                let folder = (currentPath as NSString).lastPathComponent
                displayName = folder.isEmpty
                    ? profileName
                    : "\(profileName) — \(folder)"
            }
        }
    }

    @available(macOS 15.0, *)
    private func chooseCacheVolume() {
        let panel = NSOpenPanel()
        panel.title = L10n.string("desktopDrive.creator.chooseDisk")
        panel.message = L10n.string("desktopDrive.creator.chooseDiskHelp")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let selectedURL = panel.url else { return }
        do {
            let volumeURL = try selectedURL.resourceValues(
                forKeys: [.volumeURLForRemountingKey, .volumeNameKey]
            )
            cacheLocation = try manager.eligibleCacheLocation(
                selectedURL: selectedURL
            )
            cacheVolumeName = volumeURL.volumeName
                ?? selectedURL.lastPathComponent
            selectionError = nil
        } catch {
            selectionError = L10n.string(
                "desktopDrive.creator.diskIneligible"
            )
        }
    }

    private func createMapping() {
        isCreating = true
        let selectedScope: DesktopDriveScope
        switch scope {
        case .allShares:
            selectedScope = .allShares
        case .currentFolder:
            selectedScope = .folder(path: currentPath)
        }
        let previousCount = manager.mappings.count
        Task {
            await manager.addMapping(
                displayName: displayName,
                scope: selectedScope,
                cachePolicy: DesktopDriveCachePolicy(
                    location: cacheLocation,
                    temporaryLimitBytes:
                        cacheLimitGiB * 1_024 * 1_024 * 1_024
                )
            )
            isCreating = false
            if manager.mappings.count > previousCount {
                dismiss()
            }
        }
    }
}

private struct SelectiveCacheCleanupSheet: View {
    let storage: AppStorageSnapshot
    let onClean: (CacheCleanupOptions) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var cleanSafeTrash = true
    @State private var cleanPhotoCache = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Image(systemName: "trash.circle.fill")
                    .font(.title)
                    .foregroundStyle(.teal)
                Text(L10n.string("ui.3d10daba847a0695"))
                    .font(.title2.weight(.bold))
            }

            Text(L10n.string("ui.c524c199a5c08251"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $cleanSafeTrash) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(L10n.string("ui.d238ffac2960e8e1"))
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: storage.safeTrash, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        Text(L10n.string("ui.105156f052acc424"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()

                Toggle(isOn: $cleanPhotoCache) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(L10n.string("ui.996449099693965c"))
                                .font(.body.weight(.medium))
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: storage.photoCache, countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                        Text(L10n.string("ui.cb35276fd56e7db8"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(14)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Spacer()
                Button(L10n.string("ui.2cd0f3be8738a86c")) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button(L10n.string("ui.d395bbae498e085a")) {
                    var selected: CacheCleanupOptions = []
                    if cleanSafeTrash { selected.insert(.safeTrash) }
                    if cleanPhotoCache { selected.insert(.photoCache) }
                    onClean(selected)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!cleanSafeTrash && !cleanPhotoCache)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

struct RightClickDetector: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> NSView {
        RightClickNSView(action: action)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

class RightClickNSView: NSView {
    let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func rightMouseDown(with event: NSEvent) {
        action()
        super.rightMouseDown(with: event)
    }
}

// MARK: - 全新现代卡片式删除确认弹窗
struct ModernDeleteConfirmationDialog: View {
    let targets: [FileItem]
    let profileName: String
    let currentPath: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var isPermanent: Bool {
        targets.contains(where: \.isRecyclePath)
    }

    var body: some View {
        VStack(spacing: 18) {
            // 顶部警示图标 Badge
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 52, height: 52)
                Image(systemName: "trash.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.red)
            }
            .padding(.top, 4)

            // 标题与副标题
            VStack(spacing: 4) {
                Text(isPermanent ? L10n.string("ui.93838d5d880c6302") : (targets.count == 1 ? L10n.string("ui.a187b67796d30665") : L10n.string("ui.8ca04ccbe1e7fbf7", String(describing: targets.count))))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(isPermanent ? L10n.string("ui.1694e0aa50f1fed7") : L10n.string("ui.fd2f12c9d6cb9fe7"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // 中间待删除文件预览卡片
            VStack(alignment: .leading, spacing: 8) {
                if targets.count == 1, let item = targets.first {
                    HStack(spacing: 10) {
                        FileIcon(item: item)
                            .font(.system(size: 22))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                                .font(.callout.weight(.semibold))
                                .lineLimit(1)
                            Text(item.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "doc.on.doc.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.string("ui.3757aad933f4ef7b", String(describing: targets.count)))
                                .font(.callout.weight(.semibold))
                            Text(L10n.string("ui.1015814a58fcd174", String(describing: profileName)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))

            // 底部操作按钮
            HStack(spacing: 12) {
                Button(action: onCancel) {
                    Text(L10n.string("ui.2cd0f3be8738a86c"))
                        .font(.callout.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.escape, modifiers: [])

                Button(action: onConfirm) {
                    Text(isPermanent ? L10n.string("ui.4e01a4d26a03423b") : L10n.string("ui.a3ea3c17b401bd2f"))
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.red, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 350)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }
}

// MARK: - App 灵动悬浮 Toast 组件
struct InAppToastOverlayView: View {
    let toast: ToastMessage

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: toast.icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(toast.iconColor)
            Text(toast.text)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.quaternary.opacity(0.8), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 12, y: 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.text)
    }
}
