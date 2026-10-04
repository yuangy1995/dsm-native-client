import DsmPhotosFeature
import DsmCore
import DsmLocalization
import ImageIO
import SwiftUI
import UIKit

/// iPhone 与 iPad 的正式照片入口；不接受 File Station 路径或扫描库。
struct MobileSynologyPhotosView: View {
    let session: MobileSynologyPhotosSession

    var body: some View {
        MobileSynologyPhotosContent(session: session, model: session.model)
            .id(session.identity)
    }
}

private struct MobileSynologyPhotosContent: View {
    @Bindable var session: MobileSynologyPhotosSession
    @Bindable var model: SynologyPhotosModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var showsMonths = false
    @State private var showsUploadQueue = false
    @State private var opensQueueAfterUpload = false

    private var section: Binding<SynologyPhotosSection> {
        Binding(get: { model.section }, set: { value in Task { await model.selectSection(value) } })
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        Color.clear.frame(height: 1).id("photos-top")
                        if model.isLoading {
                            ProgressView().frame(maxWidth: .infinity).padding()
                        } else {
                            if model.hasPrevious {
                                Button(L10n.string("photos.media.previous")) {
                                    Task { await loadPrevious(using: proxy) }
                                }.frame(minHeight: 44)
                                if model.isLoadingPrevious { ProgressView() }
                                if let error = model.previousPageErrorMessage {
                                    Text(error).foregroundStyle(.secondary)
                                    Button(L10n.string("photos.retry")) { Task { await loadPrevious(using: proxy) } }
                                        .frame(minHeight: 44)
                                }
                            }
                            collectionContent
                            if model.showsTimeline {
                                ForEach(model.datedGroups, id: \.date) { group in
                                    Section {
                                        photoGrid(group.photos)
                                    } header: {
                                        Text(group.date.formatted(.dateTime.year().month().day().locale(L10n.locale)))
                                            .font(.headline).accessibilityAddTraits(.isHeader)
                                    }
                                }
                            } else {
                                photoGrid(model.items)
                            }
                            if let error = model.errorMessage {
                                ContentUnavailableView {
                                    Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                                } description: { Text(error) } actions: {
                                    Button(L10n.string("photos.retry")) { Task { await model.refresh() } }
                                }
                            } else if model.hasLoaded && model.spaces.isEmpty && model.section != .albums
                                        && (model.section != .sharing || model.shareScope == .requests) {
                                ContentUnavailableView {
                                    Label(L10n.string("photos.error.title"), systemImage: "lock")
                                } description: { Text(L10n.string("photos.service.permission")) } actions: {
                                    Button(L10n.string("photos.retry")) { Task { await model.refresh() } }
                                }
                            } else if model.hasLoaded && model.items.isEmpty && model.collections.isEmpty
                                        && model.visibleSharedEntries.isEmpty && !model.showsCategories {
                                emptyContent
                            }
                            if (model.hasMore || model.hasMoreCollections) && model.errorMessage == nil {
                                ProgressView().frame(maxWidth: .infinity).padding()
                                    .id(model.paginationIdentity)
                                    .task { await model.loadNextPageAutomatically() }
                                Button(L10n.string("photos.library.more")) {
                                    Task { await model.loadNextPageAutomatically() }
                                }.frame(minHeight: 44).disabled(model.isLoadingMore)
                            }
                        }
                    }.padding()
                }
                .refreshable { await model.refresh() }
                .onChange(of: model.selectedTimelineMonthID) { _, _ in
                    proxy.scrollTo("photos-top", anchor: .top)
                }
            }
            if model.isSelecting {
                selectionToolbar
                if model.selectedItemCount > 100 { Text(L10n.string("mobile.photos.folder.limit")).font(.caption).padding(.horizontal) }
            }
            MobilePhotoManagementStatus(model: model)
            if model.preparedTemporaryAlbum != nil, let sharing = session.sharing {
                Button(L10n.string("mobile.photos.temporary.resume")) { sharing.beginPrepared() }
                    .disabled(!model.canStartManagementMutation).accessibilityIdentifier("mobile.photos.temporary.resume")
            }
            if model.isDeleting || model.isCheckingDeletion { ProgressView().padding(8) }
            if let message = model.deletionMessage {
                VStack {
                    Text(message).font(.callout)
                    if model.pendingDeletionPhoto != nil {
                        Button(L10n.string("photos.delete.review")) { Task { await model.reviewPendingDeletion() } }
                            .frame(minHeight: 44).disabled(model.isDeleting)
                    }
                }.padding(8)
            }
        }
        .navigationTitle(model.selectedCategoryItem?.name ?? model.selectedAlbum?.name ??
            (model.folderHistory.count > 1 ? model.folderHistory.last?.name : nil) ?? L10n.string("mobile.photos.title"))
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if model.canGoBack {
                    Button { Task { await model.goBack() } } label: {
                        Label(L10n.string("photos.library.back"), systemImage: "chevron.left")
                    }.frame(minWidth: 44, minHeight: 44)
                    if model.section == .folders, model.folderHistory.count > 1 {
                        Menu {
                            ForEach(model.folderHistory) { folder in
                                Button(folder.path == "/" ? L10n.string("photos.folders.root") : folder.name) { Task { await model.navigateToFolder(folder) } }
                                    .disabled(folder.id == model.folderHistory.last?.id)
                            }
                        } label: { Label(L10n.string("photos.folders.root"), systemImage: "folder") }
                            .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("mobile.photos.folder.navigation")
                    }
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !model.items.isEmpty || (model.section == .folders && !model.collections.isEmpty) {
                    Button {
                        if model.isSelecting { model.clearSelection() } else { model.isSelecting = true }
                    } label: {
                        Label(L10n.string(model.isSelecting ? "photos.selection.cancel" : "photos.selection.start"), systemImage: "checkmark.circle")
                    }.disabled(model.isBrowsingBlocked || model.isDeleting).accessibilityIdentifier("mobile.photos.selection.begin")
                }
                Menu {
                    if let folders = session.folders, model.section == .folders {
                        ForEach([MobilePhotoFolderModel.Action.create, .rename, .sort, .cover], id: \.self) { action in
                            Button(action.title) { folders.begin(action, photos: [], folders: []) }
                                .disabled(!folders.allows(action, photos: [], folders: []))
                                .accessibilityIdentifier("mobile.photos.folder.\(action.rawValue)")
                        }
                        Divider()
                    }
                    if let uploads = session.uploads {
                        Button { uploads.begin() } label: {
                            Label(L10n.string("photos.manage.upload"), systemImage: "square.and.arrow.up")
                        }.disabled(!uploads.canBegin).accessibilityIdentifier("mobile.photos.upload.begin")
                        Button { showsUploadQueue = true } label: {
                            Label(L10n.string("photos.upload.queue"), systemImage: "list.bullet")
                        }.accessibilityIdentifier("mobile.photos.upload.queue")
                    }
                    if let albums = session.albums {
                        Divider()
                        Button(MobilePhotoAlbumModel.Action.create.title) { albums.begin(.create, photos: []) }
                            .disabled(!albums.allows(.create, photos: [])).accessibilityIdentifier("mobile.photos.album.create")
                        if model.selectedAlbum != nil {
                            if let sharing = session.sharing {
                                Button(L10n.string("photos.manage.sharing")) { sharing.begin() }
                                    .disabled(!sharing.canOpen()).accessibilityIdentifier("mobile.photos.sharing.begin")
                            }
                            ForEach([MobilePhotoAlbumModel.Action.rename, .delete], id: \.self) { action in
                                Button(action.title, role: action == .delete ? .destructive : nil) { albums.begin(action, photos: []) }
                                    .disabled(!albums.allows(action, photos: [])).accessibilityIdentifier("mobile.photos.album.\(action.rawValue)")
                            }
                        }
                    }
                    if let conditions = session.conditions {
                        if model.selectedAlbum?.isFrozen == true {
                            Button(L10n.string("photos.frozen.restore")) { conditions.begin(restoring: true) }
                                .disabled(!conditions.canRestore()).accessibilityIdentifier("mobile.photos.frozen.restore")
                        }
                        Button(L10n.string("photos.condition.create")) { conditions.begin() }
                            .disabled(!conditions.canOpen()).accessibilityIdentifier("mobile.photos.condition.create")
                        if model.selectedAlbum?.isConditional == true, model.selectedAlbum?.isFrozen == false {
                            Button(L10n.string("photos.condition.edit")) { conditions.begin(editing: true) }
                                .disabled(!conditions.canOpen(editing: true)).accessibilityIdentifier("mobile.photos.condition.edit")
                        }
                    }
                    if let requests = session.requests {
                        Button(L10n.string("photos.request.create")) { requests.begin() }
                            .disabled(!requests.canOpen()).accessibilityIdentifier("mobile.photos.request.create")
                    }
                    if let editor = session.editor {
                        Button(MobilePhotoEditModel.Action.tagsCreate.title) { editor.begin(.tagsCreate, photos: []) }
                            .disabled(!editor.allows(.tagsCreate, photos: [])).accessibilityIdentifier("mobile.photos.edit.createEmptyTag")
                    }
                    if sizeClass != .regular { timelineActions }
                } label: { Label(L10n.string("photos.manage.actions"), systemImage: "ellipsis.circle") }
                    .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("mobile.photos.actions")
                if sizeClass == .regular { timelineActions }
                Button { Task { await model.refresh() } } label: {
                    Label(L10n.string("photos.library.refresh"), systemImage: "arrow.clockwise")
                }.frame(minWidth: 44, minHeight: 44).disabled(model.isLoading || model.isDeleting)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .sheet(isPresented: $model.showsFilters) {
            MobileSynologyPhotoFilters(model: model, draft: model.filter)
        }
        .sheet(isPresented: Binding(get: { session.uploads?.draftID != nil }, set: { if !$0 { session.uploads?.cancel() } }), onDismiss: {
            session.uploads?.cancel()
            if opensQueueAfterUpload { opensQueueAfterUpload = false; showsUploadQueue = true }
        }) {
            if let uploads = session.uploads, let id = uploads.draftID {
                MobilePhotoUploadForm(uploads: uploads, draftID: id) { opensQueueAfterUpload = true }
            }
        }
        .sheet(isPresented: $showsUploadQueue) {
            if let uploads = session.uploads { MobilePhotoUploadQueueView(model: model, uploads: uploads) }
        }
        .sheet(item: Binding(get: { session.albums?.draft }, set: { if $0 == nil { session.albums?.cancel() } }), onDismiss: { session.albums?.cancel() }) { draft in
            if let albums = session.albums { MobilePhotoAlbumForm(albums: albums, draft: draft) }
        }
        .sheet(item: sharingDraft, onDismiss: { session.sharing?.cancel() }) { draft in
            if let sharing = session.sharing { MobilePhotoSharingForm(sharing: sharing, draft: draft) }
        }
        .sheet(item: conditionDraft, onDismiss: { session.conditions?.cancel() }) { draft in
            if let conditions = session.conditions { MobilePhotoConditionForm(editor: conditions, draft: draft) }
        }
        .sheet(item: requestDraft, onDismiss: { session.requests?.cancel() }) { draft in
            if let requests = session.requests { MobilePhotoRequestForm(request: requests, draft: draft) }
        }
        .sheet(item: Binding(get: { session.temporarySharing?.draft }, set: { if $0 == nil { session.temporarySharing?.clear() } }), onDismiss: { session.temporarySharing?.clear() }) { draft in
            if let temporary = session.temporarySharing { MobilePhotoTemporarySharingForm(temporary: temporary, draft: draft) }
        }
        .sheet(isPresented: $showsMonths) {
            NavigationStack {
                List(model.timelineMonths) { month in
                    Button(month.date?.formatted(.dateTime.year().month(.wide).locale(L10n.locale)) ?? "") {
                        showsMonths = false
                        Task { await model.jumpToMonth(month) }
                    }.frame(minHeight: 44)
                }
                .navigationTitle(L10n.string("photos.timeline.navigator"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("photos.media.close")) { showsMonths = false }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { model.previewPhoto != nil }, set: { if !$0 { model.closePreview() } })) {
            MobileSynologyPhotoPreview(session: session, model: model)
        }
        .modifier(MobileSynologyPhotoDeletionPresentation(model: model, active: model.previewPhoto == nil))
        .modifier(MobilePhotoEditPresentation(session: session, active: model.previewPhoto == nil))
        .modifier(MobilePhotoFolderPresentation(session: session, active: model.previewPhoto == nil))
        .modifier(MobileSynologyPhotoExportPresentation(session: session, active: model.previewPhoto == nil))
        .task { await session.activate() }
        .onDisappear { session.deactivate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.deactivate() }
            else if phase == .active { Task { await session.activate() } }
        }
    }

    private var conditionDraft: Binding<MobilePhotoConditionModel.Draft?> {
        Binding(get: { session.conditions?.draft }, set: { if $0 == nil { session.conditions?.cancel() } })
    }

    private var emptyContent: some View {
        ContentUnavailableView {
            Label(L10n.string("photos.empty.title"), systemImage: "photo.on.rectangle")
        } description: {
            Text(L10n.string(model.isRequestList && !model.requestSearchText.isEmpty ? "photos.request.noResults" : model.isFiltering ? "photos.library.noResults" :
                model.selectedAlbum != nil ? "mobile.photos.album.emptyContent" : model.section == .sharing ? "photos.sharing.empty" :
                model.section == .albums ? "photos.library.noAlbums" : "photos.library.empty"))
        } actions: {
            Button(L10n.string("photos.library.refresh")) { Task { await model.refresh() } }
            if model.isRequestList && !model.requestSearchText.isEmpty {
                Button(L10n.string("photos.request.clearSearch")) { model.requestSearchText = "" }
            }
            if model.isFiltering {
                Button(L10n.string("photos.filters.clear")) {
                    model.searchText = ""
                    Task { await model.applyFilter(SynologyPhotoFilter()) }
                }
            }
        }
    }

    private var requestDraft: Binding<MobilePhotoRequestModel.Draft?> {
        Binding(get: { session.requests?.draft }, set: { if $0 == nil { session.requests?.cancel() } })
    }

    private var sharingDraft: Binding<MobilePhotoSharingModel.Draft?> {
        Binding(get: {
            if session.temporarySharing?.draft != nil { return nil }
            return session.sharing?.draft
        }, set: { if $0 == nil { session.sharing?.cancel() } })
    }

    private var header: some View {
        VStack(spacing: 8) {
            if model.spaces.count > 1 && model.selectedAlbum == nil && model.section != .sharing {
                Picker(L10n.string("mobile.photos.source.title"), selection: Binding(get: { model.selectedSpace }, set: { value in
                    Task { await model.selectSpace(value) }
                })) {
                    ForEach(model.spaces, id: \.self) { space in
                        Text(L10n.string(space == .personal ? "mobile.photos.source.mine" : "mobile.photos.source.shared")).tag(space)
                    }
                }.pickerStyle(.menu).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if sizeClass == .regular {
                Picker(L10n.string("photos.library.browse"), selection: section) {
                    ForEach(SynologyPhotosSection.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).accessibilityIdentifier("mobile.photos.section")
            } else {
                Picker(L10n.string("photos.library.browse"), selection: section) {
                    ForEach(SynologyPhotosSection.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("mobile.photos.section")
            }
            if model.section == .sharing && model.selectedAlbum == nil {
                Picker(L10n.string("photos.sharing"), selection: Binding(get: { model.shareScope }, set: { value in
                    Task { await model.selectShareScope(value) }
                })) {
                    ForEach(SynologyPhotoShareScope.allCases, id: \.self) { Text($0.mobileTitle).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityIdentifier("mobile.photos.sharing.scope")
                if model.isRequestList {
                    TextField(L10n.string("photos.request.search"), text: $model.requestSearchText)
                        .textFieldStyle(.roundedBorder).accessibilityIdentifier("mobile.photos.request.search")
                }
            } else {
                HStack {
                    Image(systemName: "magnifyingglass").accessibilityHidden(true)
                    TextField(L10n.string("photos.library.search"), text: $model.searchText)
                        .submitLabel(.search).onSubmit(search)
                        .disabled(model.filter.isActive)
                    Button(action: search) { Label(L10n.string("photos.library.search"), systemImage: "arrow.right") }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44).disabled(model.filter.isActive)
                }
                if model.filter.isActive {
                    Text(L10n.string("photos.filters.searchHint")).font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.horizontal).padding(.vertical, 8).background(.bar)
    }

    @ViewBuilder private var collectionContent: some View {
        if model.showsCategories {
            ForEach(SynologyPhotoCategory.allCases.filter { model.availableCategories.contains($0) }, id: \.self) { category in
                Button { Task { await model.openCategory(category) } } label: {
                    Label(category.mobileTitle, systemImage: category.mobileSymbol)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.bordered)
            }
        }
        ForEach(model.collections) { collection in
            HStack {
                Button {
                    if model.section == .folders, model.isSelecting { model.toggleFolderSelection(collection) }
                    else { Task { await model.open(collection) } }
                } label: {
                    HStack {
                        Label(collection.name, systemImage: model.section == .folders ? "folder" : "photo.on.rectangle")
                        Spacer()
                        if model.section == .folders, model.isSelecting {
                            Image(systemName: model.selectedFolderIDs.contains(collection.id) ? "checkmark.circle.fill" : "circle")
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.buttonStyle(.bordered).accessibilityIdentifier("mobile.photos.collection.\(collection.id)")
                    .accessibilityAddTraits(model.section == .folders && model.selectedFolderIDs.contains(collection.id) ? .isSelected : [])
                    .onDrag { dragProvider(folder: collection) }
                if model.section == .folders, let folders = session.folders, !model.isSelecting {
                    Menu {
                        ForEach([MobilePhotoFolderModel.Action.create, .rename, .sort, .cover], id: \.self) { action in
                            Button(action.title) { folders.begin(action, folder: collection, photos: [], folders: []) }
                                .disabled(!folders.allows(action, folder: collection, photos: [], folders: []))
                        }
                        MobilePhotoFolderActions(folders: folders, photos: [], targets: [collection])
                        Button(L10n.string("photos.delete.action"), role: .destructive) { folders.begin(.delete, photos: [], folders: [collection]) }
                            .disabled(!folders.allows(.delete, photos: [], folders: [collection]))
                    } label: { Label(L10n.string("photos.manage.actions"), systemImage: "ellipsis.circle") }
                        .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("mobile.photos.collection.actions.\(collection.id)")
                }
            }.dropDestination(for: String.self) { values, _ in drop(values, into: collection) }
        }
        ForEach(model.visibleSharedEntries) { entry in
            HStack {
                if entry.albumID != nil {
                    Button(entry.title) { Task { await model.openSharedAlbum(entry) } }.frame(minHeight: 44)
                } else { Text(entry.title) }
                Spacer()
                if model.shareScope == .requests, let requests = session.requests {
                    Menu {
                        Button(L10n.string("photos.request.edit")) { requests.begin(entry: entry) }
                            .accessibilityIdentifier("mobile.photos.request.edit")
                        Button(L10n.string("photos.request.delete"), role: .destructive) { requests.begin(entry: entry, deleting: true) }
                            .accessibilityIdentifier("mobile.photos.request.delete")
                    } label: { Label(L10n.string("photos.manage.actions"), systemImage: "ellipsis.circle") }
                        .disabled(!requests.canOpen(entry: entry)).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("mobile.photos.request.actions")
                }
                if let sharing = session.sharing, model.sharingManagementTarget(for: entry) != nil {
                    Button { sharing.begin(entry: entry) } label: {
                        Label(L10n.string("photos.manage.sharing"), systemImage: "person.2.badge.gearshape")
                    }.disabled(!sharing.canOpen(entry: entry)).frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("mobile.photos.sharing.entry")
                }
                if let url = entry.url {
                    Link(destination: url) { Label(L10n.string("photos.media.open"), systemImage: "arrow.up.right.square") }
                        .frame(minWidth: 44, minHeight: 44)
                    Button { UIPasteboard.general.url = url } label: {
                        Label(L10n.string("photos.copyLink"), systemImage: "link")
                    }.frame(minWidth: 44, minHeight: 44)
                }
            }
        }
    }

    @ViewBuilder private var timelineActions: some View {
        if model.section == .timeline {
            Button { model.showsFilters = true } label: {
                Label(L10n.string("photos.filters"), systemImage: model.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
            }.frame(minWidth: 44, minHeight: 44)
        }
        if model.showsTimeline && !model.timelineMonths.isEmpty {
            Button { showsMonths = true } label: {
                Label(L10n.string("photos.timeline.navigator"), systemImage: "calendar")
            }.frame(minWidth: 44, minHeight: 44)
        }
    }

    private var selectionToolbar: some View {
        HStack {
            Text(L10n.string("photos.selection.count", model.selectedItemCount)).font(.callout)
            Spacer()
            Button { model.selectLoadedItems() } label: {
                Label(L10n.string("photos.folder.selectLoaded"), systemImage: "checkmark.circle.fill")
            }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                .disabled(model.isBrowsingBlocked).accessibilityIdentifier("mobile.photos.selection.loaded")
            if let albums = session.albums {
                Menu {
                    if let folders = session.folders {
                        MobilePhotoFolderActions(folders: folders)
                        Button(L10n.string("photos.delete.action"), role: .destructive) {
                            if model.selectedFolders.isEmpty { model.requestDeletion(model.selectedPhotos) }
                            else { folders.begin(.delete) }
                        }.disabled(!model.canDeleteSelection || model.selectedItemCount > 100)
                            .accessibilityIdentifier("mobile.photos.selection.delete")
                        Divider()
                    }
                    if model.selectedFolders.isEmpty {
                        if let editor = session.editor {
                            MobilePhotoEditActions(editor: editor)
                            Divider()
                        }
                        if let temporary = session.temporarySharing {
                            Button(L10n.string("photos.selectionShare.title")) { temporary.begin() }
                                .disabled(!temporary.canBegin).accessibilityIdentifier("mobile.photos.temporary.begin")
                        }
                        ForEach([MobilePhotoAlbumModel.Action.create, .add, .remove, .cover], id: \.self) { action in
                            Button(action.title) { albums.begin(action) }
                                .disabled(!albums.allows(action)).accessibilityIdentifier("mobile.photos.selection.\(action.rawValue)")
                        }
                    }
                } label: { Label(L10n.string("photos.manage.actions"), systemImage: "ellipsis.circle") }
                    .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("mobile.photos.selection.actions")
            }
        }.padding(.horizontal).background(.bar)
    }

    private func photoGrid(_ photos: [SynologyPhoto]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 8)], spacing: 8) {
            ForEach(photos) { photo in
                MobileSynologyPhotoCell(photo: photo, session: session, isSelecting: model.isSelecting, isSelected: model.selectedPhotoIDs.contains(photo.id)) {
                    if model.isSelecting { model.toggleSelection(photo) } else { model.showPreview(photo) }
                }
                    .id(photo.id)
                    .onDrag { dragProvider(photo: photo) }
                    .contextMenu {
                        Button(L10n.string("photos.media.open")) { model.showPreview(photo) }
                        Button(L10n.string("photos.media.save")) { session.exportOriginal(photo) }
                        Button(L10n.string("photos.delete.action"), role: .destructive) { model.requestDeletion(photo) }
                            .disabled(model.isDeleting || model.isCheckingDeletion || model.pendingDeletionPhoto != nil)
                    }
            }
        }
    }

    private func dragProvider(photo: SynologyPhoto? = nil, folder: SynologyPhotoCollection? = nil) -> NSItemProvider {
        guard let token = model.beginPhotoDrag(photo: photo, folder: folder) else { return NSItemProvider() }
        return NSItemProvider(object: token.uuidString as NSString)
    }

    private func drop(_ values: [String], into folder: SynologyPhotoCollection) -> Bool {
        guard values.count == 1, let token = UUID(uuidString: values[0]), let editor = session.folders,
              let path = model.photoDropPath(to: folder), let source = model.takePhotoDrop(token: token, to: folder) else { return false }
        editor.begin(.move, photos: source.photos, folders: source.folders, destinationPath: path)
        return editor.draft != nil
    }

    private func search() {
        let keyword = model.searchText
        Task {
            // 搜索始终针对图库，不把当前文件夹／人物集合当作搜索全集。
            if model.section != .timeline { await model.selectSection(.timeline) }
            model.searchText = keyword
            await model.refresh()
        }
    }

    private func loadPrevious(using proxy: ScrollViewProxy) async {
        let anchor = model.items.first?.id
        await model.loadPreviousPage()
        if let anchor { proxy.scrollTo(anchor, anchor: .top) }
    }
}

private struct MobileSynologyPhotoCell: View {
    let photo: SynologyPhoto
    let session: MobileSynologyPhotosSession
    let isSelecting: Bool
    let isSelected: Bool
    let open: () -> Void
    @State private var image: UIImage?

    var body: some View {
        Button(action: open) {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(.quaternary).aspectRatio(1, contentMode: .fit)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                } else { Image(systemName: "photo").frame(maxWidth: .infinity, maxHeight: .infinity) }
                if photo.mediaType == "video" || photo.mediaType == "live" {
                    Image(systemName: photo.mediaType == "live" ? "livephoto" : "play.fill")
                        .padding(8).background(.regularMaterial, in: Capsule()).padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit).clipped()
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .symbolRenderingMode(.palette).foregroundStyle(isSelected ? Color.accentColor : Color.primary, .background)
                        .font(.title2).padding(8).accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo.filename)
        .accessibilityHint(isSelecting ? L10n.string("photos.selection.toggle", photo.filename) : L10n.string("photos.media.open"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: photo.thumbnail) {
            image = nil
            let data = await session.thumbnail(photo)
            let decoded = await MobileSynologyPhotoImage.decode(data, maximumPixels: 512)
            guard !Task.isCancelled else { return }
            image = decoded
        }
        .onDisappear { image = nil }
    }
}

enum MobileSynologyPhotoImage {
    static func decode(_ data: Data?, maximumPixels: Int) async -> UIImage? {
        guard let data, !data.isEmpty, data.count <= 8 * 1_024 * 1_024 else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixels
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}

extension SynologyPhotoCategory {
    var mobileTitle: String {
        switch self {
        case .recentlyAdded: L10n.string("photos.category.recentlyAdded")
        case .person: L10n.string("photos.category.person")
        case .concept: L10n.string("photos.category.concept")
        case .location: L10n.string("photos.category.location")
        case .tags: L10n.string("photos.category.tags")
        case .videos: L10n.string("photos.category.videos")
        case .similar: L10n.string("photos.category.similar")
        }
    }
    var mobileSymbol: String {
        switch self {
        case .recentlyAdded: "clock"
        case .person: "person.crop.rectangle"
        case .concept: "sparkles"
        case .location: "mappin.and.ellipse"
        case .tags: "tag"
        case .videos: "video"
        case .similar: "square.stack.3d.up"
        }
    }
}

extension SynologyPhotoShareScope {
    var mobileTitle: String {
        switch self {
        case .withMe: L10n.string("photos.sharing.withMe")
        case .withOthers: L10n.string("photos.sharing.withOthers")
        case .requests: L10n.string("photos.sharing.requests")
        }
    }
}
