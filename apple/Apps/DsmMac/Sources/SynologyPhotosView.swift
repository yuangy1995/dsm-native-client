import DsmPhotosFeature
import AppKit
import AVKit
import DsmCore
import DsmLocalization
import SwiftUI
import UniformTypeIdentifiers

struct SynologyPhotosView: View {
    @Bindable var model: SynologyPhotosModel
    @State private var pendingSimilarGroups: [SynologyPhotoSimilarDetail] = []
    @State private var managementSheet: PhotoManagementSheet?
    @State private var selectionSharingSheet: PhotoManagementSheet?
    @State private var folderCoverTarget: PhotoFolderCoverTarget?
    @State private var folderPermissionTarget: SynologyPhotoCollection?
    @State private var showsBackgroundTasks = false
    @State private var showsUploadQueue = false
    @State private var showsGlobalSettings = false
    @State private var showsLibraryMaintenance = false
    @State private var showsCodecPrompt = false
    @State private var codecPromptSeed: SynologyPhotoCodecPrompt?
    @State private var showsSharedSpaceSettings = false
    @State private var showsSharedMembers = false
    @State private var showsRecognitionSettings = false
    @State private var showsAutomaticPreviewSettings = false
    @State private var showsDisplaySettings = false
    @State private var showsDuplicateSettings = false
    @State private var showsPreviewRecovery = false
    @State private var thumbnailAnchor: SynologyPhotoID?
    var onSectionChange: ((SynologyPhotosSection) -> Void)? = nil
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var palette: MacAppearancePalette {
        MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if model.canGoBack {
                    Button { Task { await model.goBack() } } label: { Label(L10n.string("photos.library.back"), systemImage: "chevron.left") }.labelStyle(.iconOnly)
                        .modifier(PhotoFolderDropTarget(model: model, target: model.section == .folders ? model.folderHistory.dropLast().last : nil, onDrop: showPhotoDrop))
                }
                ForEach(SynologyPhotosSection.allCases, id: \.self) { section in
                    Button(section.title) {
                        if let onSectionChange { onSectionChange(section) }
                        else { Task { await model.selectSection(section) } }
                    }.buttonStyle(MacToolbarButtonStyle(selected: model.section == section))
                }
                photoSourceMenu
                Spacer(minLength: 12)
                Button { model.startSlideshow() } label: { Image(systemName: "play.rectangle") }
                    .help(L10n.string("photos.slideshow.start")).accessibilityLabel(L10n.string("photos.slideshow.start"))
                    .disabled(!model.canStartSlideshow)
                if let archive = model.currentArchive {
                    PhotoArchiveDownloadMenu(target: archive.target, name: archive.name, model: model)
                        .labelStyle(.iconOnly)
                }
                if model.section == .folders || (model.section == .albums && model.selectedAlbum != nil && model.selectedAlbum?.acceptsManualMembers == true) {
                    Button {
                        managementSheet = PhotoManagementSheet(kind: .createRequest, photos: [], album: model.selectedAlbum,
                            folder: model.section == .folders ? model.folderHistory.last : nil, space: model.selectedSpace)
                    } label: { Image(systemName: "square.and.arrow.down.on.square") }
                        .help(PhotoManagementKind.createRequest.title).accessibilityLabel(PhotoManagementKind.createRequest.title)
                        .disabled(!model.managementFeatures.contains(.photoRequests) || model.isManaging || model.isLoading || model.pendingMutationID != nil)
                }
                Menu {
                    if model.managementFeatures.contains(.codecPrompt) {
                        Button(L10n.string("photos.codec.title")) { codecPromptSeed = nil; showsCodecPrompt = true }
                    }
                    if model.managementFeatures.contains(.libraryMaintenance) {
                        Button(L10n.string("photos.maintenance.title")) { showsLibraryMaintenance = true }
                    }
                    if model.managementFeatures.contains(.globalSettings) {
                        Button(L10n.string("photos.global.title")) { showsGlobalSettings = true }
                    }
                    if model.managementFeatures.contains(.sharedMembers) {
                        Button(L10n.string("photos.members.title")) { showsSharedMembers = true }
                    }
                    if model.managementFeatures.contains(.sharedSpaceSettings) {
                        Button(L10n.string("photos.sharedSettings.title")) { showsSharedSpaceSettings = true }
                    }
                    Button(L10n.string("photos.automatic.title")) { showsAutomaticPreviewSettings = true }
                        .disabled(!model.managementFeatures.contains(.automaticPreviewSettings))
                    Button(L10n.string("photos.recognition.title")) { showsRecognitionSettings = true }
                        .disabled(!model.managementFeatures.contains(.recognitionSettings))
                    Button(L10n.string("photos.display.title")) { showsDisplaySettings = true }
                        .disabled(!model.managementFeatures.contains(.displaySettings))
                    Button(L10n.string("photos.duplicates.title")) { showsDuplicateSettings = true }
                        .disabled(!model.managementFeatures.contains(.duplicateSettings))
                } label: { Image(systemName: "gearshape") }
                    .help(L10n.string("photos.settings.title")).accessibilityLabel(L10n.string("photos.settings.title"))
                    .disabled(model.isBrowsingBlocked || model.isLoading || (model.pendingMutationID != nil && !model.hasPendingAutomaticPreview))
                Button { showsPreviewRecovery = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .help(L10n.string("photos.preview.recovery.title"))
                    .accessibilityLabel(L10n.string("photos.preview.recovery.title"))
                    .disabled(!model.managementFeatures.contains(.previewRegeneration) || model.isManaging || model.isLoading || model.pendingMutationID != nil)
                if let folder = model.currentCreationFolder {
                    Button {
                        managementSheet = .init(kind: .createFolder, photos: [], folder: folder, space: folder.space)
                    } label: { Image(systemName: "folder.badge.plus") }
                        .help(PhotoManagementKind.createFolder.title).accessibilityLabel(PhotoManagementKind.createFolder.title)
                        .disabled(model.isLoading || model.isManaging || model.isDeleting || model.isCheckingDeletion || model.pendingMutationID != nil)
                }
                if model.managementFeatures.contains(.backgroundTasks) {
                    Button { showsBackgroundTasks = true } label: { Image(systemName: "list.bullet.rectangle") }
                        .help(L10n.string("photos.tasks.title")).accessibilityLabel(L10n.string("photos.tasks.title"))
                        .accessibilityIdentifier("photos.backgroundTasks")
                }
                Button { chooseUpload() } label: { Image(systemName: "square.and.arrow.up") }
                    .help(L10n.string("photos.manage.upload"))
                    .accessibilityLabel(L10n.string("photos.manage.upload"))
                    .disabled(!model.canUploadPhotos || model.isManaging || model.isLoading || model.pendingMutationID != nil)
                if model.selectedCategory == .concept && model.selectedCategoryItem == nil {
                    Button { managementSheet = PhotoManagementSheet(kind: .conceptVisibility, photos: [], space: model.selectedSpace) } label: { Image(systemName: "eye") }
                        .help(PhotoManagementKind.conceptVisibility.title).accessibilityLabel(PhotoManagementKind.conceptVisibility.title)
                        .disabled(!model.managementFeatures.contains(.conceptVisibility) || model.isManaging || model.isLoading || model.pendingMutationID != nil)
                }
                if model.selectedCategory == .person && model.selectedCategoryItem == nil {
                    Button { managementSheet = PhotoManagementSheet(kind: .peopleVisibility, photos: [], space: model.selectedSpace) } label: { Image(systemName: "eye") }
                        .help(PhotoManagementKind.peopleVisibility.title).accessibilityLabel(PhotoManagementKind.peopleVisibility.title)
                        .disabled(!model.managementFeatures.contains(.peopleVisibility) || model.isManaging || model.isLoading || model.pendingMutationID != nil)
                }
                if model.selectedCategory == .tags && model.selectedCategoryItem == nil {
                    Button { managementSheet = PhotoManagementSheet(kind: .tagsCreate, photos: [], space: model.selectedSpace) } label: { Image(systemName: "tag.badge.plus") }
                        .help(L10n.string("photos.manage.tagsCreate"))
                        .accessibilityLabel(L10n.string("photos.manage.tagsCreate"))
                        .disabled(!model.managementFeatures.contains(.tagCreation) || model.pendingMutationID != nil)
                }
                if model.section == .albums && model.selectedAlbum == nil && model.selectedCategory == nil {
                    Menu {
                        Button(PhotoManagementKind.createAlbum.title) { managementSheet = PhotoManagementSheet(kind: .createAlbum, photos: []) }
                            .disabled(!model.managementFeatures.contains(.albums))
                        Button(PhotoManagementKind.createConditionAlbum.title) { managementSheet = PhotoManagementSheet(kind: .createConditionAlbum, photos: [], space: model.selectedSpace) }
                            .disabled(!model.managementFeatures.contains(.conditionAlbums))
                    } label: { Image(systemName: "plus") }
                        .help(L10n.string("photos.manage.createAlbum"))
                        .accessibilityLabel(L10n.string("photos.manage.createAlbum"))
                        .disabled(model.managementFeatures.isDisjoint(with: [.albums, .conditionAlbums]) || model.pendingMutationID != nil)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.string(model.isRequestList ? "photos.request.search" : "photos.library.search"), text: Binding(
                        get: { model.isRequestList ? model.requestSearchText : model.searchText },
                        set: { if model.isRequestList { model.requestSearchText = $0 } else { model.searchText = $0 } }))
                        .textFieldStyle(.plain)
                        .onSubmit { if !model.isRequestList { Task { await model.refresh() } } }
                }
                .padding(.horizontal, 10).frame(minWidth: 140, idealWidth: 230, maxWidth: 280).frame(height: 36)
                .background(palette.searchField, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0.25), lineWidth: 1))
                .disabled(model.filter.isActive || (model.section == .sharing && !model.isRequestList))
                .help(L10n.string(model.isRequestList ? "photos.request.search" : "photos.filters.searchHint"))
                if model.section == .timeline {
                    Button { model.showsFilters.toggle() } label: {
                        Label(L10n.string("photos.filters"), systemImage: "line.3.horizontal.decrease.circle")
                    }
                    .buttonStyle(MacToolbarButtonStyle(selected: model.filter.isActive))
                    .labelStyle(.iconOnly)
                    .popover(isPresented: $model.showsFilters) { PhotoFilterPanel(model: model, draft: model.filter) }
                }
                Button { Task { await model.refresh() } } label: {
                    Label(L10n.string("photos.library.refresh"), systemImage: "arrow.clockwise")
                }.disabled(model.isLoading).accessibilityIdentifier("photos.refresh")
            }
            .buttonStyle(MacToolbarButtonStyle())
            .padding(16)
            .background(MacGlassSurface(role: .toolbar))
            .disabled(model.isDeleting || model.isCheckingDeletion || model.isBrowsingBlocked)
            if model.albumListScope == .albums, model.albumListSort != nil || model.albumListDisplay != nil {
                PhotoAlbumListControls(model: model).padding(.horizontal, 16).padding(.vertical, 8)
            }
            if let title = model.selectedCategoryItem?.name ?? model.selectedCategory?.title ?? model.selectedAlbum?.name {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let current = model.currentSortAlbum {
                        PhotoFolderSortMenu(accessibilityID: "photos.albumSort", sort: current.sort, changeSort: model.changeCurrentAlbumSort)
                            .disabled(model.isLoading || model.isManaging || model.pendingMutationID != nil || model.isDeleting || model.isCheckingDeletion)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            if let album = model.selectedAlbum, album.isFrozen {
                HStack {
                    Label(L10n.string("photos.frozen.hint"), systemImage: "pause.circle")
                    Spacer()
                    if model.selectedAlbumAccess?.isOwner == true {
                        Button(L10n.string("photos.frozen.restore")) {
                            managementSheet = .init(kind: .restoreFrozenAlbum, photos: [], album: album)
                        }.disabled(!model.managementFeatures.contains(.frozenAlbums) || model.isManaging || model.pendingMutationID != nil)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            if model.section == .sharing, model.selectedAlbum == nil {
                HStack {
                    ForEach(SynologyPhotoShareScope.allCases, id: \.self) { scope in
                        Button(scope.title) { Task { await model.selectShareScope(scope) } }
                            .buttonStyle(MacToolbarButtonStyle(selected: model.shareScope == scope))
                    }
                    Spacer()
                    if model.albumListScope != nil, model.albumListSort != nil {
                        PhotoAlbumListControls(model: model).fixedSize(horizontal: true, vertical: false)
                    }
                    if model.shareScope == .requests {
                        Button(PhotoManagementKind.createRequest.title) {
                            managementSheet = PhotoManagementSheet(kind: .createRequest, photos: [], space: model.selectedSpace)
                        }.buttonStyle(MacToolbarButtonStyle())
                            .disabled(!model.managementFeatures.contains(.photoRequests) || model.isBrowsingBlocked)
                    }
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }

            if !model.items.isEmpty || (model.section == .folders && (!model.collections.isEmpty || !model.folderHistory.isEmpty)) {
                HStack(spacing: 8) {
                    if model.section == .folders, !model.isSelecting { folderBreadcrumbs }
                    if !model.isSelecting { Spacer(minLength: 8) }
                    Button {
                        if model.isSelecting { model.clearSelection() } else { model.isSelecting = true }
                    } label: {
                        Label(L10n.string(model.isSelecting ? "photos.selection.cancel" : "photos.selection.start"), systemImage: "checkmark.circle")
                    }
                    if model.isSelecting {
                        Text(L10n.string("photos.selection.count", model.selectedItemCount)).foregroundStyle(.secondary)
                        Button(L10n.string(model.section == .folders ? "photos.folder.selectLoaded" : "photos.selection.loaded")) { model.selectLoadedItems() }
                            .keyboardShortcut("a", modifiers: .command)
                        Spacer()
                        if let target = model.selectedArchive {
                            PhotoArchiveDownloadMenu(target: target, name: L10n.string("photos.download.defaultName"), model: model)
                        } else {
                            Menu {
                                Button(L10n.string("photos.download.original")) { chooseSaveFolder() }
                                Button(L10n.string("photos.download.jpeg")) { chooseSaveFolder(format: .optimizedJPEG) }
                                if model.selectedCategory != .similar, model.selectedPhotos.count == 1,
                                   let photo = model.selectedPhotos.first, model.canDownloadOriginalSizeJPEG(photo) {
                                    Button(L10n.string("photos.download.originalSizeJPEG")) { chooseSaveFolder(format: .originalSizeJPEG) }
                                }
                            } label: { Label(L10n.string("photos.manage.download"), systemImage: "square.and.arrow.down") }
                                .disabled(!model.selectedFolders.isEmpty || model.selectedPhotoIDs.isEmpty || model.isSaving || !model.selectedPhotos.allSatisfy(model.canDownload))
                        }
                        Button {
                            selectionSharingSheet = .init(kind: .createAlbum, photos: model.selectedPhotos)
                        } label: { Label(L10n.string("photos.selectionShare.title"), systemImage: "square.and.arrow.up") }
                            .disabled(!model.canManageSelection || !canManage(.createAlbum))
                        Menu {
                            if model.selectedCategory == .similar {
                                Button(L10n.string("photos.similar.ungroupSelected")) {
                                    Task { if let groups = await model.prepareSelectedSimilarGroups() { pendingSimilarGroups = groups } }
                                }.disabled(model.selectedPhotos.isEmpty || !model.managementFeatures.contains(.similarGroups) || model.isPreparingSimilarBatch)
                                Divider()
                            }
                            if model.selectedCategory == .concept, let concept = model.selectedCategoryItem {
                                ForEach([PhotoManagementKind.conceptCover, .removeConceptItems], id: \.self) { kind in
                                    Button(kind.title) { managementSheet = .init(kind: kind, photos: model.selectedPhotos, concept: concept, space: concept.space) }
                                        .disabled(!model.canManageConceptPhotos(model.selectedPhotos, cover: kind == .conceptCover))
                                }
                                Divider()
                            }
                            if model.selectedCategory == .person, let person = model.selectedCategoryItem {
                                ForEach([PhotoManagementKind.removeFaces, .reassignFaces, .personCover], id: \.self) { kind in
                                    Button(kind.title) { managementSheet = PhotoManagementSheet(kind: kind, photos: model.selectedPhotos, person: person, space: person.space) }
                                        .disabled(!model.canManageSelection || !model.managementFeatures.contains(kind.feature) || (kind == .personCover && model.selectedPhotos.count != 1))
                                }
                                Divider()
                            }
                            if let folder = model.currentCoverFolder, model.selectedFolders.isEmpty, model.selectedPhotos.count == 1, let photo = model.selectedPhotos.first {
                                Button(L10n.string("photos.folderCover.set")) { folderCoverTarget = .init(folder: folder, photo: photo) }
                                    .disabled(model.isManaging || model.pendingMutationID != nil)
                            }
                            ForEach(PhotoManagementKind.selectionCases, id: \.self) { kind in
                                Button(kind.title) { managementSheet = PhotoManagementSheet(kind: kind, photos: model.selectedPhotos, album: model.selectedAlbum, folders: model.selectedFolders, space: model.selectedPhotos.first?.id.space ?? model.selectedSpace) }
                                    .disabled((([PhotoManagementKind.move, .copy].contains(kind) && !model.selectedFolders.isEmpty) ? (model.isManaging || model.isDeleting || model.isCheckingDeletion || model.pendingMutationID != nil) : !model.canManageSelection) || !canManage(kind) || ([.removeAlbum, .cover].contains(kind) && model.selectedAlbum == nil) || (kind == .cover && model.selectedPhotos.count != 1) || (kind == .removeAlbum && model.selectedAlbum?.acceptsManualMembers == false))
                            }
                        } label: { Label(L10n.string("photos.manage.actions"), systemImage: "ellipsis.circle") }
                        Button(role: .destructive) {
                            if model.selectedFolders.isEmpty { model.requestDeletion(model.selectedPhotos) }
                            else { managementSheet = .init(kind: .deleteFolders, photos: model.selectedPhotos, folders: model.selectedFolders) }
                        } label: {
                            Label(L10n.string("photos.delete.action"), systemImage: "trash")
                        }.disabled(!model.canDeleteSelection)
                    } else { folderActions }
                }
                .buttonStyle(MacToolbarButtonStyle())
                .padding(.horizontal, 16).padding(.bottom, 10)
                .disabled(model.isDeleting || model.isCheckingDeletion || model.isBrowsingBlocked)
            }

            if model.selectedCategory == .similar, let status = model.similarStatus, status.isVisible {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status.isRunning ? L10n.string("photos.similar.processing", status.waitingCount) : L10n.string("photos.similar.scheduled"))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 16).padding(.bottom, 8)
            }
            HStack(spacing: 0) {
                galleryContent.fillsAvailableContentArea(alignment: .topLeading)
                if model.showsTimeline, !model.timelineMonths.isEmpty {
                    Divider()
                    PhotoTimelineRail(months: model.timelineMonths, selectedID: model.selectedTimelineMonthID) { month in
                        Task { await model.jumpToMonth(month) }
                    }.frame(width: 92).padding(.vertical, 12)
                        .disabled(model.isDeleting || model.isCheckingDeletion || model.isBrowsingBlocked)
                }
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard !urls.isEmpty, urls.allSatisfy(\.isFileURL), managementSheet == nil,
                      !model.isManaging, !model.isLoading, !model.isDeleting, !model.isCheckingDeletion,
                      model.pendingMutationID == nil, model.canUploadPhotos else { return false }
                presentUpload(urls)
                return true
            }
            if model.section != .sharing || model.selectedAlbum != nil {
                HStack {
                    Spacer()
                    PhotoThumbnailSizeControls(model: model)
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            if !model.uploadQueue.isEmpty || model.uploadPersistenceError != nil {
                HStack {
                    Text(L10n.string("photos.upload.summary", model.uploadQueue.filter { [.completed, .skipped].contains($0.state) }.count, model.uploadQueue.count))
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.string("photos.upload.queue")) { showsUploadQueue = true }
                }.padding(.horizontal, 16).padding(.vertical, 8)
            }
            if model.isManaging && !model.isGeneratingAutomaticPreview { ProgressView().controlSize(.small).padding(8) }
            if let message = model.managementMessage {
                HStack {
                    Text(message).font(.callout)
                    if model.managementFeatures.contains(.backgroundTasks), model.isManaging || model.pendingMutationID != nil {
                        Button(L10n.string("photos.tasks.title")) { showsBackgroundTasks = true }
                    }
                    if model.needsSharedListRefresh {
                        Button(L10n.string("photos.library.refresh")) { Task { await model.retrySharedListRefresh() } }
                            .disabled(model.isManaging || model.isLoadingMore)
                    }
                    if model.hasSimilarBatchToContinue {
                        Button(L10n.string("photos.similar.continueGroups")) { model.continueSimilarBatch() }
                        Button(L10n.string("photos.similar.cancelRemaining")) { model.cancelRemainingSimilarGroups() }
                    }
                    if model.similarUndoMutation != nil {
                        Button(L10n.string("photos.similar.undo")) { model.undoSimilarChanges() }
                            .disabled(model.isManaging || model.pendingMutationID != nil || model.hasSimilarBatchToContinue)
                    }
                    if model.pendingMutationID != nil && model.automaticMutationReviewID == nil && !model.isManaging {
                        Button(L10n.string("photos.selection.retryReview")) { model.reviewPendingMutation() }
                    }
                    if model.temporarySharingCleanupNeedsRetry {
                        Button(L10n.string("photos.retry")) { model.retryTemporarySharingCleanup() }
                            .disabled(model.isManaging || model.pendingMutationID != nil)
                        Button(L10n.string("photos.temporary.keepExisting")) { model.keepTemporarySharingAlbums() }
                            .disabled(model.isManaging || model.pendingMutationID != nil)
                    }
                    if model.retryableManagementMutation != nil {
                        Button(L10n.string("photos.manage.continueRemaining")) { model.continuePartialManagement() }
                            .disabled(model.isManaging || model.pendingMutationID != nil)
                    }
                    if let url = model.managementLink {
                        Button(L10n.string("photos.copyLink")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string) }
                    }
                }.padding(8)
            }
            if model.isSaving {
                HStack {
                    ProgressView(value: model.saveProgress)
                    Button(L10n.string("photos.download.cancel")) { model.cancelSave() }
                }.padding(.horizontal)
            }
            if let message = model.saveMessage { Text(message).font(.callout).foregroundStyle(.secondary).padding(8) }
            if let error = model.similarRefreshError {
                HStack {
                    Text(error).font(.callout)
                    Button(L10n.string("photos.retry")) { Task { await model.refreshAffectedSimilarGroups() } }
                }.padding(8)
            }
            if model.showsAutomaticPreviewStatus {
                HStack(spacing: 10) {
                    if model.isGeneratingAutomaticPreview { ProgressView().controlSize(.small) }
                    Text(model.hasPendingAutomaticPreview && !model.isGeneratingAutomaticPreview
                         ? L10n.string("photos.automatic.reviewing")
                         : model.automaticPreviewFilename.map { L10n.string("photos.automatic.processing", $0) }
                            ?? model.automaticPreviewError ?? L10n.string("photos.automatic.paused"))
                        .font(.callout).lineLimit(2)
                    Spacer()
                    Button(L10n.string(model.automaticPreviewPaused || model.automaticPreviewError != nil ? "photos.automatic.resume" : "photos.automatic.pause")) {
                        if model.automaticPreviewPaused || model.automaticPreviewError != nil { model.resumeAutomaticPreviews() }
                        else { model.pauseAutomaticPreviews() }
                    }
                }.padding(8)
            }
            if model.isDeleting || model.isCheckingDeletion { ProgressView().controlSize(.small).padding(8) }
            if let message = model.deletionMessage {
                HStack {
                    Text(message).font(.callout)
                }.padding(8)
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .background(MacGlassSurface(role: .content))
        .task {
            await model.loadIfNeeded()
            model.continueTemporarySharingCleanup()
            if model.managementFeatures.contains(.codecPrompt), model.pendingMutationID == nil,
               let prompt = try? await model.codecPrompt(), prompt.shouldShow, !Task.isCancelled {
                codecPromptSeed = prompt; showsCodecPrompt = true
            }
            model.startAutomaticPreviews()
        }
        .task(id: model.hasAutomaticDeletionReview) {
            guard model.hasAutomaticDeletionReview else { return }
            await model.continueAutomaticDeletionReview()
        }
        .task(id: model.automaticMutationReviewID) {
            guard let id = model.automaticMutationReviewID else { return }
            while !Task.isCancelled, model.automaticMutationReviewID == id {
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard !Task.isCancelled, model.automaticMutationReviewID == id else { return }
                model.reviewPendingMutation()
            }
        }
        .task(id: model.similarStatusIdentity) {
            guard model.selectedCategory == .similar else { return }
            while !Task.isCancelled {
                await model.refreshSimilarStatus()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
        .onChange(of: model.isManaging) { _, managing in
            if !managing { model.continueTemporarySharingCleanup() }
        }
        .onDisappear { model.leaveGallery() }
        .alert(L10n.string("photos.similar.ungroupSelected"), isPresented: Binding(
            get: { !pendingSimilarGroups.isEmpty }, set: { if !$0 { pendingSimilarGroups = [] } }), presenting: pendingSimilarGroups) { groups in
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { pendingSimilarGroups = [] }
            Button(L10n.string("photos.similar.confirm")) { model.ungroupSimilarSelection(groups); pendingSimilarGroups = [] }
        } message: { groups in Text(L10n.string("photos.similar.ungroupSelectedConfirm", groups.count)) }
        .alert(L10n.string("photos.delete.title"), isPresented: Binding(
            get: { !model.deletionCandidates.isEmpty },
            set: { if !$0 { model.deletionCandidates = [] } }
        ), presenting: model.deletionCandidates) { targets in
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { model.deletionCandidates = [] }
            Button(L10n.string("photos.delete.action"), role: .destructive) { model.confirmDeletion(targets) }
        } message: { targets in
            if let kept = model.deletionKeptCount {
                Text(L10n.string("photos.similar.cleanupConfirm", kept, targets.count))
            } else {
                Text(targets.count == 1
                    ? L10n.string("photos.delete.confirm", targets.first?.filename ?? "")
                    : L10n.string("photos.selection.confirm", targets.count))
            }
        }
        .alert(L10n.string("photos.delete.title"), isPresented: Binding(get: { model.deletionError != nil }, set: { if !$0 { model.deletionError = nil } })) {
            Button(L10n.string("photos.media.close"), role: .cancel) { model.deletionError = nil }
        } message: { Text(model.deletionError ?? "") }
        .alert(L10n.string("photos.delete.success"), isPresented: Binding(
            get: { model.deletionSuccessMessage != nil },
            set: { if !$0 { model.deletionSuccessMessage = nil } }
        )) {
            Button(L10n.string("photos.media.close"), role: .cancel) { model.deletionSuccessMessage = nil }
        } message: { Text(model.deletionSuccessMessage ?? "") }
        .sheet(isPresented: $showsPreviewRecovery) { PhotoPreviewRecoveryPanel(model: model, initialSpace: model.selectedSpace) }
        .sheet(isPresented: $showsAutomaticPreviewSettings) { PhotoAutomaticPreviewSettingsPanel(model: model) }
        .sheet(isPresented: $showsGlobalSettings) { PhotoGlobalSettingsPanel(model: model) }
        .sheet(isPresented: $showsCodecPrompt) { PhotoCodecPromptPanel(model: model, initial: codecPromptSeed) }
        .sheet(isPresented: $showsLibraryMaintenance) { PhotoLibraryMaintenancePanel(model: model, space: model.selectedSpace) }
        .sheet(isPresented: $showsSharedMembers) { PhotoSharedMembersPanel(model: model) }
        .sheet(isPresented: $showsSharedSpaceSettings) { PhotoSharedSpaceSettingsPanel(model: model) }
        .sheet(isPresented: $showsRecognitionSettings) { PhotoRecognitionSettingsPanel(model: model) }
        .sheet(isPresented: $showsDisplaySettings) { PhotoDisplaySettingsPanel(model: model) }
        .sheet(isPresented: $showsDuplicateSettings) { PhotoDuplicateSettingsPanel(model: model) }
        .sheet(isPresented: $showsBackgroundTasks) { PhotoBackgroundTasksPanel(model: model) }
        .sheet(isPresented: $showsUploadQueue) { PhotoUploadQueuePanel(model: model) }
        .sheet(item: $folderPermissionTarget) { folder in PhotoFolderSharingPanel(model: model, folder: folder) }
        .sheet(item: $folderCoverTarget) { target in PhotoFolderCoverPanel(model: model, target: target) }
        .sheet(item: $selectionSharingSheet) { sheet in PhotoSelectionSharingPanel(model: model, photos: sheet.photos) }
        .sheet(item: $managementSheet) { sheet in
            PhotoManagementPanel(model: model, sheet: sheet)
        }
        .sheet(isPresented: Binding(get: { model.previewPhoto != nil && !model.isSlideshowPresented }, set: { if !$0 && !model.isSlideshowPresented { model.closePreview() } })) {
            SynologyPhotoPreview(model: model)
        }
        .background(PhotoSlideshowPresentation(model: model, isPresented: model.isSlideshowPresented).frame(width: 0, height: 0))
    }
    @ViewBuilder private var photoSourceMenu: some View {
        if model.section != .sharing, model.spaces.count > 1 {
            Menu {
                ForEach(model.spaces, id: \.self) { space in
                    Button { Task { await model.selectSpace(space) } } label: {
                        Label(L10n.string(space == .personal ? "shared.51fcaa8035fc61e2" : "shared.17d2e16862f16829"),
                              systemImage: model.selectedSpace == space ? "checkmark" : "photo.on.rectangle")
                    }
                }
            } label: {
                if model.selectedSpace == .shared { Label(L10n.string("shared.17d2e16862f16829"), systemImage: "person.2") }
                else { Image(systemName: "photo.on.rectangle") }
            }.menuStyle(.borderlessButton).fixedSize().frame(minWidth: 36, minHeight: 36)
                .help(L10n.string("photos.source.switch"))
                .accessibilityLabel(L10n.string("photos.source.switch"))
                .accessibilityIdentifier("photos.space")
                .disabled(model.isLoading || model.isManaging || model.pendingMutationID != nil)
        } else if model.section != .sharing, model.selectedSpace == .shared {
            Label(L10n.string("shared.17d2e16862f16829"), systemImage: "person.2").font(.callout)
        }
    }

    private var folderBreadcrumbs: some View {
        HStack(spacing: 2) {
            if model.folderHistory.count > 2 {
                Menu {
                    ForEach(model.folderHistory.dropLast(2)) { folder in
                        Button(folder.name == "/" ? L10n.string("photos.folders.root") : folder.name) {
                            Task { await model.navigateToFolder(folder) }
                        }
                    }
                } label: { Label(L10n.string("navigation.parentFolders"), systemImage: "ellipsis") }
                    .labelStyle(.iconOnly).menuStyle(.borderlessButton).fixedSize().frame(minWidth: 32, minHeight: 32)
            }
            ForEach(model.folderHistory.suffix(2)) { folder in
                if folder.id != model.folderHistory.suffix(2).first?.id || model.folderHistory.count > 2 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                Button { Task { await model.navigateToFolder(folder) } } label: {
                    if folder.name == "/" { Label(L10n.string("photos.folders.root"), systemImage: "folder").labelStyle(.iconOnly) }
                    else { Text(folder.name).lineLimit(1).truncationMode(.middle) }
                }.buttonStyle(MacPathButtonStyle(current: folder.id == model.folderHistory.last?.id))
                    .help(folder.name == "/" ? L10n.string("photos.folders.root") : folder.name)
                    .accessibilityIdentifier(folder.id == model.folderHistory.last?.id ? "photos.path.current" : "photos.path.parent")
                    .modifier(PhotoFolderDropTarget(model: model, target: folder, onDrop: showPhotoDrop))
            }
        }.accessibilityIdentifier("photos.path")
    }

    @ViewBuilder private var folderActions: some View {
        if let current = model.currentSortFolder {
            PhotoFolderSortMenu(sort: current.sort, changeSort: model.changeCurrentFolderSort)
                .disabled(model.isLoading || model.isManaging || model.pendingMutationID != nil)
        }
        if model.currentCoverFolder != nil || model.currentSortFolder.map({ model.canInspectFolderSharing($0.folder) }) == true {
            Menu {
                if let folder = model.currentCoverFolder {
                    Button(L10n.string("photos.folderCover.change")) { folderCoverTarget = .init(folder: folder) }
                }
                if let current = model.currentSortFolder, model.canInspectFolderSharing(current.folder) {
                    Button(L10n.string("photos.folderSharing.title")) { folderPermissionTarget = current.folder }
                }
            } label: { Label(L10n.string("photos.manage.actions"), systemImage: "ellipsis") }
                .labelStyle(.iconOnly).macThemedMenu()
                .disabled(model.isManaging || model.isLoading || model.pendingMutationID != nil)
        }
    }

    private func canManage(_ kind: PhotoManagementKind) -> Bool {
        if kind == .removeAlbum { return model.canRemoveAlbumSelection }
        if kind == .regeneratePreviews { return model.canRegeneratePreviews(model.selectedPhotos) }
        if kind == .addAlbum || kind == .createAlbum {
            return model.managementFeatures.contains(.albums) && model.canAddToAlbum(model.selectedPhotos)
        }
        if kind == .move || kind == .copy {
            return model.managementFeatures.contains(.fileTransfer) && model.canTransfer(model.selectedPhotos, copying: kind == .copy, folders: model.selectedFolders)
        }
        if kind == .cover { return model.selectedAlbumAccess?.isOwner == true && model.managementFeatures.contains(.albums) }
        let supportsMixed = [PhotoManagementKind.rating, .date, .shiftDates, .regeneratePreviews].contains(kind)
        return model.managementFeatures.contains(kind.feature) && model.canEditSelection(model.selectedPhotos, supportsMixedSpaces: supportsMixed)
    }

    private func chooseSaveFolder(format: SynologyPhotoDownloadFormat = .original) {
        let photos = model.selectedPhotos, similar = model.selectedCategory == .similar
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L10n.string("photos.manage.download")
        panel.begin { result in
            if result == .OK, let url = panel.url { model.savePhotos(photos, to: url, format: format, includingSimilarMembers: similar) }
        }
    }

    private func chooseUpload() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        panel.prompt = L10n.string("photos.manage.upload")
        let album = model.selectedAlbum
        let folder = model.section == .folders ? model.folderHistory.last : nil
        let space = model.selectedSpace
        panel.begin { result in
            guard result == .OK, !panel.urls.isEmpty else { return }
            managementSheet = PhotoManagementSheet(kind: .upload, photos: [], album: album, files: panel.urls, folder: folder, space: space)
        }
    }

    private func presentUpload(_ urls: [URL]) {
        managementSheet = PhotoManagementSheet(kind: .upload, photos: [], album: model.selectedAlbum,
            files: urls, folder: model.section == .folders ? model.folderHistory.last : nil, space: model.selectedSpace)
    }

    @ViewBuilder private var galleryContent: some View {
            if model.isLoading {
                ProgressView().fillsAvailableContentArea()
            } else if model.items.isEmpty && model.collections.isEmpty && !model.showsCategories && model.visibleSharedEntries.isEmpty && !model.hasPrevious && !model.hasMore && !model.hasMoreCollections {
                ContentUnavailableView {
                    Label(L10n.string(model.errorMessage == nil ? "photos.empty.title" : "photos.error.title"), systemImage: "photo.on.rectangle")
                } description: {
                    Text(model.errorMessage ?? L10n.string(model.sharedCategoriesRequireManagement ? "photos.categories.sharedFolders" : model.isRequestList && !model.requestSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "photos.request.noResults" : model.section == .sharing ? "photos.sharing.empty" : (model.isFiltering ? "photos.library.noResults" : model.selectedCategory == .similar ? "photos.similar.empty" : "photos.library.empty")))
                } actions: {
                    if model.sharedCategoriesRequireManagement {
                        Button(SynologyPhotosSection.folders.title) {
                            if let onSectionChange { onSectionChange(.folders) }
                            else { Task { await model.selectSection(.folders) } }
                        }
                    }
                    if model.isRequestList && !model.requestSearchText.isEmpty {
                        Button(L10n.string("photos.request.clearSearch")) { model.requestSearchText = "" }
                    }
                    Button(L10n.string("photos.library.refresh")) { Task { await model.refresh() } }
                }
                .fillsAvailableContentArea()
            } else {
                ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.hasPrevious {
                            if let message = model.previousPageErrorMessage {
                                Text(message).foregroundStyle(.secondary)
                                Button(L10n.string("photos.retry")) {
                                    Task { await loadPreviousPage(using: proxy) }
                                }.buttonStyle(MacToolbarButtonStyle())
                            } else {
                                HStack {
                                    Spacer()
                                    if model.isLoadingPrevious { ProgressView().controlSize(.small) }
                                    else {
                                        Button(L10n.string("photos.timeline.newer")) {
                                            Task { await loadPreviousPage(using: proxy) }
                                        }.buttonStyle(MacToolbarButtonStyle())
                                    }
                                    Spacer()
                                }
                            }
                        }

                        if model.showsCategories {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(SynologyPhotoCategory.allCases.filter { model.availableCategories.contains($0) }, id: \.self) { category in
                                    Button { Task { await model.openCategory(category) } } label: {
                                        VStack(spacing: 0) {
                                            PhotoCategoryPreview(model: model, category: category, space: model.selectedSpace)
                                                .frame(height: 125 * thumbnailScale)
                                            Text(category.title).font(.headline).padding(.vertical, 12)
                                        }
                                        .frame(maxWidth: .infinity)
                                        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain).accessibilityLabel(category.title)

                                }
                            }
                        }
                        ForEach(model.visibleSharedEntries) { entry in
                            HStack {
                                if model.shareScope == .requests { Text(entry.title).font(.headline) }
                                else { Button(entry.title) { Task { await model.openSharedAlbum(entry) } }.disabled(entry.albumID == nil) }
                                Spacer()
                                if let album = model.sharingManagementTarget(for: entry) {
                                    Button(PhotoManagementKind.sharing.title) {
                                        managementSheet = .init(kind: .sharing, photos: [], album: album)
                                    }.disabled(model.isManaging || model.pendingMutationID != nil)
                                        .accessibilityIdentifier("photos.sharedEntry.manage")
                                }
                                if model.shareScope == .requests {
                                    Button(PhotoManagementKind.editRequest.title) {
                                        managementSheet = PhotoManagementSheet(kind: .editRequest, photos: [], requestID: entry.id)
                                    }
                                    Button(PhotoManagementKind.deleteRequest.title, role: .destructive) {
                                        managementSheet = PhotoManagementSheet(kind: .deleteRequest, photos: [], requestID: entry.id)
                                    }
                                }
                                if let url = entry.url {
                                    Button(L10n.string("photos.copyLink")) {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                    }
                                }
                            }.buttonStyle(MacToolbarButtonStyle()).padding().background(palette.card, in: RoundedRectangle(cornerRadius: 10))
                        }
                        if !model.collections.isEmpty {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(model.collections) { collection in
                                    Button {
                                        if model.section == .folders && model.isSelecting { model.toggleFolderSelection(collection) }
                                        else { Task { await model.open(collection) } }
                                    } label: {
                                        VStack(spacing: 10) {
                                            if model.section == .folders {
                                                PhotoFolderCover(model: model, folder: collection).frame(height: 105 * thumbnailScale).clipped()
                                            } else if model.section == .albums, collection.thumbnail != nil {
                                                PhotoAlbumCover(model: model, album: collection, category: model.selectedCategory)
                                                    .frame(height: 105 * thumbnailScale).clipped()
                                            } else {
                                                Image(systemName: model.section == .folders ? "folder.fill" : "rectangle.stack.fill").font(.system(size: 36)).foregroundStyle(.tint)
                                            }
                                            Text(collection.name.isEmpty && model.selectedCategory == .person ? L10n.string("photos.people.unnamed") : collection.name).lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity).frame(height: 105 * thumbnailScale + 45)
                                        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                    .overlay(alignment: .topLeading) {
                                        if model.section == .folders, model.isSelecting {
                                            Image(systemName: model.selectedFolderIDs.contains(collection.id) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(model.selectedFolderIDs.contains(collection.id) ? Color.accentColor : .secondary)
                                                .font(.title2).padding(8).allowsHitTesting(false)
                                        }
                                    }
                                    .accessibilityValue(model.section == .folders && model.isSelecting ? L10n.string(model.selectedFolderIDs.contains(collection.id) ? "photos.selection.selected" : "photos.selection.unselected") : "")
                                    .onDrag { PhotoDragItemProvider.make(token: model.beginPhotoDrag(folder: collection)) }
                                    .modifier(PhotoFolderDropTarget(model: model, target: model.section == .folders ? collection : nil, onDrop: showPhotoDrop))
                                    .contextMenu {
                                        if model.section == .folders {
                                            if model.canInspectFolderSharing(collection) {
                                                Button(L10n.string("photos.folderSharing.title")) { folderPermissionTarget = collection }
                                                    .disabled(model.isManaging)
                                            }
                                            Button(PhotoManagementKind.renameFolder.title) {
                                                managementSheet = .init(kind: .renameFolder, photos: [], folder: collection, space: collection.space)
                                            }.disabled(!model.managementFeatures.contains(.folders) || model.isManaging || model.pendingMutationID != nil)
                                            Button(L10n.string("photos.folderCover.change")) { folderCoverTarget = .init(folder: collection) }
                                                .disabled(!model.managementFeatures.contains(.folderCover) || model.isManaging || model.pendingMutationID != nil)
                                            ForEach([PhotoManagementKind.move, .copy], id: \.self) { kind in
                                                Button(kind.title) {
                                                    let selected = model.selectedFolderIDs.contains(collection.id)
                                                    managementSheet = .init(kind: kind, photos: selected ? model.selectedPhotos : [], folders: selected ? model.selectedFolders : [collection], space: collection.space)
                                                }.disabled(!model.managementFeatures.contains(.fileTransfer) || model.isManaging || model.isDeleting || model.isCheckingDeletion || model.pendingMutationID != nil)
                                            }
                                            if model.selectedFolderIDs.contains(collection.id), let target = model.selectedArchive {
                                                PhotoArchiveDownloadMenu(target: target, name: L10n.string("photos.download.defaultName"), model: model)
                                            } else {
                                                PhotoArchiveDownloadMenu(target: .folder(id: collection.id, space: collection.space), name: collection.name, model: model)
                                            }
                                            Button(L10n.string("photos.delete.action"), role: .destructive) {
                                                let selected = model.selectedFolderIDs.contains(collection.id)
                                                managementSheet = .init(kind: .deleteFolders, photos: selected ? model.selectedPhotos : [], folders: selected ? model.selectedFolders : [collection])
                                            }.disabled(!model.managementFeatures.contains(.folderDeletion) || model.isManaging || model.isDeleting || model.isCheckingDeletion || model.pendingMutationID != nil)
                                        } else if model.selectedCategory == nil && (model.section == .albums || model.section == .sharing) {
                                            PhotoArchiveDownloadMenu(target: .album(id: collection.id), name: collection.name, model: model)
                                        }
                                        if model.selectedCategory == .concept {
                                            Button(PhotoManagementKind.conceptVisibility.title) {
                                                managementSheet = .init(kind: .conceptVisibility, photos: [], concept: collection, space: collection.space)
                                            }.disabled(!model.managementFeatures.contains(.conceptVisibility) || model.isManaging || model.pendingMutationID != nil)
                                        }
                                        if model.selectedCategory == .person {
                                            ForEach([PhotoManagementKind.renamePerson, .mergePeople, .peopleVisibility], id: \.self) { kind in
                                                Button(kind.title) { managementSheet = PhotoManagementSheet(kind: kind, photos: [], person: collection, space: collection.space) }
                                                    .disabled(!model.managementFeatures.contains(kind.feature) || model.isManaging || model.pendingMutationID != nil)
                                            }
                                        }
                                        if model.section == .albums && model.selectedCategory == nil {
                                            ForEach((collection.isFrozen ? [PhotoManagementKind.restoreFrozenAlbum, .deleteAlbum] : PhotoManagementKind.albumCases + (collection.isConditional ? [.editConditionAlbum] : [])), id: \.self) { kind in
                                                Button(kind.title) { managementSheet = PhotoManagementSheet(kind: kind, photos: [], album: collection) }
                                                    .disabled(!model.managementFeatures.contains(kind.feature) || model.isManaging || model.pendingMutationID != nil)
                                            }
                                        }
                                        if model.section == .folders || (model.section == .albums && model.selectedCategory == nil && collection.acceptsManualMembers) {
                                            Button(PhotoManagementKind.createRequest.title) {
                                                managementSheet = PhotoManagementSheet(kind: .createRequest, photos: [],
                                                    album: model.section == .albums ? collection : nil,
                                                    folder: model.section == .folders ? collection : nil, space: model.selectedSpace)
                                            }.disabled(!model.managementFeatures.contains(.photoRequests) || model.isManaging || model.pendingMutationID != nil)
                                        }
                                    }
                                }
                            }
                        }
                        if model.showsTimeline {
                            ForEach(model.datedGroups, id: \.date) { group in
                                HStack {
                                    Text(model.formattedPhotoDate(group.date, group: true))
                                        .font(.headline).accessibilityAddTraits(.isHeader)
                                    Button { model.selectGroup(group.photos) } label: {
                                        Image(systemName: Set(group.photos.map(\.id)).isSubset(of: model.selectedPhotoIDs)
                                            ? "checkmark.circle.fill" : "circle")
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(L10n.string(model.displayPreferences?.grouping == .month ? "photos.selection.month" : "photos.selection.day"))
                                    .disabled(model.isDeleting || model.isManaging)
                                    Spacer()
                                }
                                photoGrid(group.photos)
                            }
                        } else { photoGrid(model.items) }
                        if let message = model.errorMessage {
                            Text(message).foregroundStyle(.secondary)
                            Button(L10n.string("photos.retry")) {
                                Task {
                                    if model.needsAlbumRefresh { await model.retryAlbumRefresh() }
                                    else if model.hasMoreCollections { await model.loadMoreCollections() }
                                    else { await model.loadMore() }
                                }
                            }.buttonStyle(MacToolbarButtonStyle())
                        } else if model.hasMore || model.hasMoreCollections {
                            ProgressView().frame(maxWidth: .infinity).padding()
                                .id("\(model.paginationIdentity):\(model.isDeleting):\(model.isManaging)")
                                .task { await model.loadNextPageAutomatically() }
                        }
                    }.padding(16)
                }
                .macThemedScrollContent()
                .coordinateSpace(name: "photos.thumbnailViewport")
                .onPreferenceChange(PhotoThumbnailFrames.self) { frames in
                    thumbnailAnchor = frames.filter { $0.value.maxY > 0 && $0.value.minY < 80 }
                        .min { a, b in a.value.minY == b.value.minY ? a.value.minX < b.value.minX : a.value.minY < b.value.minY }?.key
                }
                .onChange(of: model.thumbnailSize) { _, _ in
                    if let anchor = thumbnailAnchor {
                        Task { @MainActor in
                            await Task.yield()
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                    }
                }
                .background(PhotoTimelineScrollIntent {
                    guard model.hasPrevious, !model.isLoadingPrevious, model.previousPageErrorMessage == nil else { return }
                    Task { await loadPreviousPage(using: proxy) }
                })
                }
            }

    }

    private var thumbnailScale: Double { model.thumbnailSize.minimumWidth / 150 }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.thumbnailSize.minimumWidth, maximum: model.thumbnailSize.maximumWidth), spacing: 8)]
    }

    private func loadPreviousPage(using proxy: ScrollViewProxy) async {
        let anchor = model.items.first?.id
        let month = model.selectedTimelineMonthID
        let previousMonth = model.previousMonthID
        await model.loadPreviousPage()
        if month == model.selectedTimelineMonthID, model.previousMonthID != previousMonth, let anchor {
            // 等待补入内容进入布局，再回到原来第一张照片，避免整月内容推走视口。
            await Task.yield()
            proxy.scrollTo(anchor, anchor: .top)
        }
    }

    private func photoGrid(_ photos: [SynologyPhoto]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(photos) { photo in
                ZStack(alignment: .topLeading) {
                    Button {
                        let modifiers = NSEvent.modifierFlags
                        if model.isSelecting || modifiers.contains(.command) || modifiers.contains(.shift) {
                            model.toggleSelection(photo, extending: modifiers.contains(.shift))
                        } else { model.showPreview(photo) }
                    } label: { SynologyPhotoCell(photo: photo, model: model) }
                    .buttonStyle(.plain)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(model.selectedPhotoIDs.contains(photo.id) ? Color.accentColor : .clear, lineWidth: 3))
                    Button { model.toggleSelection(photo, extending: NSEvent.modifierFlags.contains(.shift)) } label: {
                        Image(systemName: model.selectedPhotoIDs.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title3).symbolRenderingMode(.palette)
                            .foregroundStyle(model.selectedPhotoIDs.contains(photo.id) ? Color.accentColor : .white, .white)
                            .padding(5).background(.black.opacity(0.35), in: Circle())
                    }
                    .buttonStyle(.plain).padding(6)
                    .accessibilityLabel(L10n.string("photos.selection.toggle", photo.filename))
                    .accessibilityValue(L10n.string(model.selectedPhotoIDs.contains(photo.id)
                        ? "photos.selection.selected" : "photos.selection.unselected"))
                    .disabled(model.isDeleting || model.isBrowsingBlocked)
                }
                .id(photo.id)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: PhotoThumbnailFrames.self,
                        value: [photo.id: geometry.frame(in: .named("photos.thumbnailViewport"))])
                })
                .onDrag { PhotoDragItemProvider.make(token: model.beginPhotoDrag(photo: photo)) }
                .contextMenu {
                    Button(L10n.string("photos.media.open")) { model.showPreview(photo) }
                    if model.selectedPhotoIDs.contains(photo.id), let target = model.selectedArchive {
                        PhotoArchiveDownloadMenu(target: target, name: L10n.string("photos.download.defaultName"), model: model)
                    } else {
                        PhotoDownloadMenu(photo: photo, model: model)
                    }
                    Button(L10n.string("photos.selectionShare.title")) {
                        selectionSharingSheet = .init(kind: .createAlbum, photos: model.selectedPhotoIDs.contains(photo.id) ? model.selectedPhotos : [photo])
                    }.disabled(model.isManaging || model.pendingMutationID != nil || !model.managementFeatures.contains(.albums) ||
                               !model.canAddToAlbum(model.selectedPhotoIDs.contains(photo.id) ? model.selectedPhotos : [photo]) ||
                               (model.selectedPhotoIDs.contains(photo.id) && !model.selectedFolders.isEmpty))
                    if let folder = model.currentCoverFolder {
                        Button(L10n.string("photos.folderCover.set")) {
                            folderCoverTarget = .init(folder: folder, photo: photo)
                        }.disabled(model.isManaging || model.pendingMutationID != nil)
                    }
                    Button(L10n.string("photos.delete.action"), role: .destructive) {
                        if model.selectedPhotoIDs.contains(photo.id), !model.selectedFolders.isEmpty {
                            managementSheet = .init(kind: .deleteFolders, photos: model.selectedPhotos, folders: model.selectedFolders)
                        } else { model.requestDeletion(model.selectedPhotoIDs.contains(photo.id) ? model.selectedPhotos : [photo]) }
                    }.disabled(!model.canModifyOriginal(photo) || model.isDeleting || model.isCheckingDeletion || model.pendingDeletionPhoto != nil)
                }
            }
        }
    }

    private func showPhotoDrop(_ selection: PhotoDragSelection, _ path: [SynologyPhotoCollection]) {
        managementSheet = .init(kind: .move, photos: selection.photos, folders: selection.folders,
            space: path.last?.space ?? model.selectedSpace, transferPath: path)
    }
}

/// 只暴露一次性随机标识，不向拖放剪贴板导出文件名、路径或认证数据。
enum PhotoDragItemProvider {
    static let typeIdentifier = "io.github.qwertyuiop1995.dsmnativeclient.photos-selection"
    static func make(token: UUID?) -> NSItemProvider {
        let provider = NSItemProvider()
        if let token {
            let data = Data(token.uuidString.utf8)
            provider.registerDataRepresentation(forTypeIdentifier: typeIdentifier, visibility: .ownProcess) { completion in
                completion(data, nil); return nil
            }
        }
        return provider
    }
}

@MainActor
struct PhotoFolderDropTarget: ViewModifier {
    let model: SynologyPhotosModel
    let target: SynologyPhotoCollection?
    let onDrop: @MainActor (PhotoDragSelection, [SynologyPhotoCollection]) -> Void
    @State private var isTargeted = false

    @ViewBuilder func body(content: Content) -> some View {
        if let target {
            content
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isTargeted && model.canDropPhotos(to: target) ? Color.accentColor : .clear, lineWidth: 3).allowsHitTesting(false))
                .onDrop(of: [PhotoDragItemProvider.typeIdentifier], delegate: PhotoFolderDropDelegate(model: model, target: target, isTargeted: $isTargeted, onDrop: onDrop))
        } else { content }
    }
}

@MainActor
private struct PhotoFolderDropDelegate: DropDelegate {
    let model: SynologyPhotosModel
    let target: SynologyPhotoCollection
    @Binding var isTargeted: Bool
    let onDrop: @MainActor (PhotoDragSelection, [SynologyPhotoCollection]) -> Void

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [PhotoDragItemProvider.typeIdentifier]) && model.canDropPhotos(to: target) }
    func dropEntered(info: DropInfo) { isTargeted = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isTargeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { .init(operation: validateDrop(info: info) ? .move : .forbidden) }
    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        let providers = info.itemProviders(for: [PhotoDragItemProvider.typeIdentifier])
        guard validateDrop(info: info), providers.count == 1, let provider = providers.first else { return false }
        provider.loadDataRepresentation(forTypeIdentifier: PhotoDragItemProvider.typeIdentifier) { data, _ in
            guard let data, let string = String(data: data, encoding: .utf8), let token = UUID(uuidString: string) else { return }
            Task { @MainActor in
                guard let path = model.photoDropPath(to: target), let selection = model.takePhotoDrop(token: token, to: target) else { return }
                onDrop(selection, path)
            }
        }
        return true
    }
}

/// 普通布局、缩略图加载和程序滚动不触发向前分页。
private struct PhotoThumbnailFrames: PreferenceKey {
    static let defaultValue: [SynologyPhotoID: CGRect] = [:]
    static func reduce(value: inout [SynologyPhotoID: CGRect], nextValue: () -> [SynologyPhotoID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

struct PhotoThumbnailSizeControls: View {
    @Bindable var model: SynologyPhotosModel
    @FocusState private var sliderFocused: Bool
    private func changeSize(_ value: Int) {
        model.thumbnailSize = PhotoThumbnailSize(rawValue: min(4, max(0, value))) ?? .medium
    }

    var body: some View {
        HStack(spacing: 8) {
            Button { changeSize(model.thumbnailSize.rawValue - 1) } label: { Image(systemName: "minus.magnifyingglass") }
                .disabled(model.thumbnailSize == .small)
                .help(L10n.string("photos.thumbnail.smaller"))
                .accessibilityLabel(L10n.string("photos.thumbnail.smaller"))
                .accessibilityIdentifier("photos.thumbnail.smaller")
            Slider(value: Binding(get: { Double(model.thumbnailSize.rawValue) }, set: { changeSize(Int($0)) }), in: 0...4, step: 1) {
                Text(L10n.string("photos.thumbnail.size"))
            }.labelsHidden().frame(width: 130)
                .focusable().focused($sliderFocused)
                .simultaneousGesture(TapGesture().onEnded { sliderFocused = true })
                .onMoveCommand { direction in
                    switch direction {
                    case .left, .down: changeSize(model.thumbnailSize.rawValue - 1)
                    case .right, .up: changeSize(model.thumbnailSize.rawValue + 1)
                    default: break
                    }
                }
                .accessibilityLabel(L10n.string("photos.thumbnail.size"))
                .accessibilityValue(L10n.string("photos.thumbnail.level", model.thumbnailSize.rawValue + 1))
                .accessibilityIdentifier("photos.thumbnail.size")
                .help(L10n.string("photos.thumbnail.size"))
            Button { changeSize(model.thumbnailSize.rawValue + 1) } label: { Image(systemName: "plus.magnifyingglass") }
                .disabled(model.thumbnailSize == .extraLarge)
                .help(L10n.string("photos.thumbnail.larger"))
                .accessibilityLabel(L10n.string("photos.thumbnail.larger"))
                .accessibilityIdentifier("photos.thumbnail.larger")
        }.buttonStyle(.borderless)
    }
}

private struct PhotoTimelineScrollIntent: NSViewRepresentable {
    let onReachTop: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onReachTop) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.attach(view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.onReachTop = onReachTop }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.detach() }

    @MainActor final class Coordinator {
        var onReachTop: () -> Void
        private weak var view: NSView?
        private var monitor: Any?
        init(_ action: @escaping () -> Void) { onReachTop = action }
        func attach(_ view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { @MainActor [weak self] event in
                guard let self, let view = self.view, let window = view.window,
                      event.window === window, event.scrollingDeltaY > 0, event.momentumPhase.isEmpty,
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil)),
                      let content = window.contentView,
                      let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)),
                      let scroll = hit.enclosingScrollView,
                      scroll.documentVisibleRect.minY <= 1 else { return event }
                DispatchQueue.main.async { [weak self] in self?.onReachTop() }
                return event
            }
        }
        func detach() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}

@MainActor
private func savePhoto(_ photo: SynologyPhoto, model: SynologyPhotosModel) {
    guard model.canDownload(photo) else { return }
    let panel = NSSavePanel()
    panel.title = L10n.string("photos.media.save")
    panel.nameFieldStringValue = (photo.filename as NSString).lastPathComponent
    if panel.runModal() == .OK, let url = panel.url { model.save(photo, to: url) }
}

struct PhotoArchiveDownloadMenu: View {
    let target: SynologyPhotoArchiveTarget
    let name: String
    let model: SynologyPhotosModel

    private var title: String {
        switch target {
        case .album: L10n.string("photos.download.album")
        case .folder: L10n.string("photos.download.folder")
        case .selection: L10n.string("photos.download.selection")
        }
    }

    var body: some View {
        Menu {
            Button(L10n.string("photos.download.original")) { chooseArchive(.original) }
            Button(L10n.string("photos.download.jpeg")) { chooseArchive(.optimizedJPEG) }
        } label: { Label(title, systemImage: "square.and.arrow.down") }
        .help(title).accessibilityLabel(title)
        .disabled(model.isSaving || !model.canDownloadArchive(target))
    }

    private func chooseArchive(_ format: SynologyPhotoDownloadFormat) {
        let panel = NSSavePanel()
        panel.title = title; panel.allowedContentTypes = [.zip]
        let filename = (name as NSString).lastPathComponent
        panel.nameFieldStringValue = (filename.isEmpty || ["/", ".", ".."].contains(filename) ? L10n.string("photos.download.defaultName") : filename) + ".zip"
        if format == .optimizedJPEG { panel.message = L10n.string("photos.download.archiveJPEGHint") }
        panel.begin { result in
            if result == .OK, let url = panel.url { model.saveArchive(target, format: format, to: url) }
        }
    }
}

struct PhotoDownloadMenu: View {
    let photo: SynologyPhoto
    let model: SynologyPhotosModel

    var body: some View {
        Menu {
            Button(L10n.string("photos.download.original")) { savePhoto(photo, model: model) }
            if !["video", "video360", "video_360"].contains(photo.mediaType), !["gif", "webp"].contains((photo.filename as NSString).pathExtension.lowercased()) {
                Button(L10n.string("photos.download.jpeg")) { chooseJPEG(.optimizedJPEG) }
            }
            if model.canDownloadOriginalSizeJPEG(photo) {
                Button(L10n.string("photos.download.originalSizeJPEG")) { chooseJPEG(.originalSizeJPEG) }
            }
        } label: { Label(L10n.string("photos.media.save"), systemImage: "square.and.arrow.down") }
        .disabled(model.isSaving || !model.canDownload(photo))
    }

    private func chooseJPEG(_ format: SynologyPhotoDownloadFormat) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = L10n.string("photos.manage.download")
        panel.begin { result in
            if result == .OK, let url = panel.url { model.savePhotos([photo], to: url, format: format) }
        }
    }
}

struct SynologyPhotoPreview: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var pendingSimilarMutation: SynologyPhotosMutation?
    @State private var managementSheet: PhotoManagementSheet?
    @State private var selectionSharingSheet: PhotoManagementSheet?
    @State private var showsInfo = false
    @State private var folderCoverTarget: PhotoFolderCoverTarget?
    @State private var faceEditorTarget: PhotoFaceEditorTarget?
    @Environment(\.displayScale) private var displayScale
    init(model: SynologyPhotosModel, showsInfo: Bool = false) {
        self.model = model
        _showsInfo = State(initialValue: showsInfo)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(L10n.string("photos.media.close")) { model.closePreview() }.keyboardShortcut(.cancelAction)
                Spacer()
                Text(model.previewPhoto?.filename ?? "").font(.headline).lineLimit(1)
                Spacer()
                Button { model.startSlideshow() } label: { Label(L10n.string("photos.slideshow.start"), systemImage: "play.rectangle") }
                Button { model.adjacentPreview(-1) } label: { Label(L10n.string("photos.media.previous"), systemImage: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.adjacentPreview(1) } label: { Label(L10n.string("photos.media.next"), systemImage: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button { showsInfo.toggle() } label: { Label(L10n.string("photos.media.info"), systemImage: "info.circle") }
                if let photo = model.previewPhoto {
                    if photo.supportsRotation {
                        Button { model.rotatePreview() } label: {
                            Label(L10n.string("photos.media.rotate"), systemImage: "rotate.left")
                        }.disabled(!model.canRotatePreview)
                            .help(L10n.string("photos.media.rotate"))
                    }
                    if photo.mediaType != "video", let data = model.previewData {
                        Button { model.finishMotion(); faceEditorTarget = .init(photo: photo, data: data) } label: {
                            Label(L10n.string("photos.faces.edit"), systemImage: "person.crop.rectangle")
                        }.disabled(!model.canEditPhoto(photo) || !model.managementFeatures.contains(.manualFaces) || model.isManaging || model.pendingMutationID != nil)
                    }
                    Menu {
                        if model.selectedCategory == .concept, model.selectedCategoryItem != nil {
                            ForEach([PhotoManagementKind.conceptCover, .removeConceptItems], id: \.self) { kind in
                                managementButton(kind, photo: photo)
                            }
                            Divider()
                        }
                        if model.selectedCategory == .person, model.selectedCategoryItem != nil {
                            ForEach([PhotoManagementKind.removeFaces, .reassignFaces, .personCover], id: \.self) { kind in
                                managementButton(kind, photo: photo)
                            }
                            Divider()
                        }
                        ForEach(PhotoManagementKind.selectionCases.filter { $0 != .regeneratePreviews }, id: \.self) { kind in
                            managementButton(kind, photo: photo)
                        }
                    } label: { Label(L10n.string("photos.manage.actions"), systemImage: "ellipsis.circle") }
                        .accessibilityIdentifier("photos.preview.actions")
                    if let folder = model.currentCoverFolder {
                        Button { folderCoverTarget = .init(folder: folder, photo: photo) } label: { Label(L10n.string("photos.folderCover.set"), systemImage: "folder.badge.gearshape") }
                            .disabled(model.isManaging || model.pendingMutationID != nil)
                    }
                    Button {
                        model.finishMotion()
                        selectionSharingSheet = .init(kind: .createAlbum, photos: [photo])
                    } label: { Label(L10n.string("photos.selectionShare.title"), systemImage: "square.and.arrow.up") }
                        .disabled(model.isManaging || model.pendingMutationID != nil || !model.managementFeatures.contains(.albums) || !model.canAddToAlbum([photo]))
                    Button {
                        model.finishMotion()
                        managementSheet = .init(kind: .regeneratePreviews, photos: [photo])
                    } label: { Label(L10n.string("photos.preview.rebuild"), systemImage: "arrow.triangle.2.circlepath") }
                        .disabled(!model.canRegeneratePreviews([photo], fromPreview: true) || model.isManaging || model.pendingMutationID != nil)
                        .accessibilityIdentifier("photos.preview.rebuild")
                    PhotoDownloadMenu(photo: photo, model: model)
                        .disabled(model.isSaving || !model.canDownload(photo))
                    Button {
                        model.closePreview()
                        model.requestDeletion(photo)
                    } label: { Label(L10n.string("photos.delete.action"), systemImage: "trash") }
                        .disabled(!model.canModifyOriginal(photo) || model.isDeleting || model.isCheckingDeletion || model.pendingDeletionPhoto != nil)
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(MacToolbarButtonStyle())
            .padding()
            .background(MacGlassSurface(role: .toolbar))
            HStack(spacing: 0) {
                ZStack {
                    if let data = model.previewData, let image = NSImage(data: data),
                       let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        FittedImagePreview(cgImage: cgImage, orientation: .up, showsControls: false, isZoomEnabled: !model.isPlayingMotion)
                            .id(model.previewPhoto?.id)
                            .id(model.isPlayingMotion)
                        if model.isPlayingMotion, let source = model.previewSource {
                            GeometryReader { proxy in
                                let width = CGFloat(cgImage.width) / displayScale
                                let height = CGFloat(cgImage.height) / displayScale
                                let scale = min(1, max(1, proxy.size.width - 32) / width, max(1, proxy.size.height - 32) / height)
                                PhotoMotionPlayer(source: source, onFinished: model.finishMotion)
                                    .frame(width: width * scale, height: height * scale)
                                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
                            }.allowsHitTesting(false)
                        }
                        if model.previewPhoto?.canPlayMotion == true {
                            VStack {
                                HStack {
                                    Button {
                                        if model.isPlayingMotion { model.finishMotion() } else { model.playMotion() }
                                    } label: {
                                        Label(L10n.string("photos.live"), systemImage: model.isPlayingMotion ? "livephoto.play" : "livephoto")
                                    }
                                    .buttonStyle(MacToolbarButtonStyle(selected: model.isPlayingMotion))
                                    .help(L10n.string("photos.media.playMotion"))
                                    Spacer()
                                }
                                Spacer()
                            }.padding(24)
                        }
                    } else if model.isPreparingPreview { ProgressView() }
                    else if let source = model.previewSource {
                        VideoPlayerView(source: source, onDownload: model.previewPhoto.map(model.canDownload) == true ? { if let photo = model.previewPhoto { savePhoto(photo, model: model) } } : nil)
                    } else {
                        ContentUnavailableView {
                            Label(L10n.string("photos.media.open"), systemImage: "photo")
                        } description: { Text(model.previewError ?? L10n.string("photos.media.failed")) }
                        actions: { Button(L10n.string("photos.retry")) { if let photo = model.previewPhoto { model.showPreview(photo) } } }
                    }
                }.fillsAvailableContentArea()
                .overlay(alignment: .bottomLeading) {
                    if !showsInfo { PhotoPreviewInformation(model: model) }
                }
                if showsInfo, let photo = model.previewPhoto {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(photo.filename).font(.headline).textSelection(.enabled)
                            detailRow("photos.detail.taken", model.formattedPhotoDate(photo.takenAt, includesTime: true))
                            detailRow("photos.detail.added", model.formattedPhotoDate(photo.indexedAt, includesTime: true))
                            detailRow("photos.detail.size", photo.sizeBytes.formatted(.byteCount(style: .file).locale(L10n.locale)))
                            detailRow("photos.detail.format", (photo.filename as NSString).pathExtension.uppercased())
                            if let width = photo.width, let height = photo.height { detailRow("photos.detail.resolution", L10n.string("photos.media.dimensions", width, height)) }
                            detailRow("photos.detail.camera", photo.camera)
                            detailRow("photos.detail.lens", photo.lens)
                            detailRow("photos.detail.aperture", photo.aperture)
                            detailRow("photos.detail.shutter", photo.exposureTime)
                            detailRow("photos.detail.focal", photo.focalLength)
                            detailRow("photos.detail.iso", photo.iso)
                            if !photo.addressComponents.isEmpty {
                                detailRow("photos.detail.location", locationText(photo.addressComponents))
                            }
                            if let latitude = photo.latitude, let longitude = photo.longitude {
                                detailRow("photos.detail.coordinates", L10n.string("photos.coordinates",
                                    latitude.formatted(.number.precision(.fractionLength(5)).locale(L10n.locale)),
                                    longitude.formatted(.number.precision(.fractionLength(5)).locale(L10n.locale))))
                            }
                            if let duration = photo.duration { detailRow("photos.detail.duration", L10n.string("photos.seconds", duration.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale)))) }
                            if let rating = photo.rating { detailRow("photos.detail.rating", L10n.string("photos.stars", rating)) }
                            detailRow("photos.detail.description", photo.description)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.frame(width: 280).background(MacGlassSurface(role: .content))
                }
            }
            if model.isLoadingSimilarPreview {
                ProgressView(L10n.string("photos.similar.loading")).padding(12)
            } else if let error = model.similarPreviewError {
                HStack {
                    Text(error).foregroundStyle(.secondary)
                    Button(L10n.string("photos.retry")) { Task { await model.retrySimilarPreview() } }
                }.padding(12)
            } else if let detail = model.previewSimilarDetail {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L10n.string("photos.similar.count", detail.photos.count)).font(.headline)
                        Spacer()
                        Menu {
                            if let photo = model.previewPhoto {
                                Button(L10n.string("photos.similar.setTopPick")) { pendingSimilarMutation = .editSimilarGroup(detail, .topPick(photo.id.unitID)) }
                                    .disabled(photo.id.unitID == detail.group.topPickID)
                            }
                            Button(L10n.string("photos.similar.remove")) {
                                pendingSimilarMutation = .editSimilarGroup(detail, .remove(detail.photos.filter { model.similarSelectedIDs.contains($0.id) }.map { $0.id.unitID }))
                            }.disabled(model.similarSelectedIDs.isEmpty)
                            Button(L10n.string("photos.similar.ungroup")) { pendingSimilarMutation = .editSimilarGroup(detail, .ungroup) }
                            Divider()
                            Button(L10n.string("photos.similar.keepSelected"), role: .destructive) {
                                model.requestSimilarCleanup(detail, keeping: model.similarSelectedIDs)
                            }.disabled(model.similarSelectedIDs.isEmpty || model.similarSelectedIDs.count == detail.photos.count || !detail.photos.allSatisfy(model.canModifyOriginal))
                        } label: { Label(L10n.string("photos.similar.manage"), systemImage: "ellipsis.circle") }
                        .disabled(!model.managementFeatures.contains(.similarGroups) || model.isManaging || model.pendingMutationID != nil || model.isDeleting || model.isCheckingDeletion)
                    }
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 10) {
                            ForEach(detail.photos) { photo in
                                Button { model.showSimilarPreview(photo) } label: {
                                    VStack(spacing: 4) {
                                        SynologyPhotoCell(photo: photo, model: model, showsSimilarBadge: false).frame(width: 76, height: 76)
                                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(photo.id == model.previewPhoto?.id ? Color.accentColor : .clear, lineWidth: 3))
                                        Text(L10n.string("photos.similar.topPick")).font(.caption)
                                            .opacity(photo.id.unitID == detail.group.topPickID ? 1 : 0)
                                            .accessibilityHidden(photo.id.unitID != detail.group.topPickID)
                                    }
                                }.buttonStyle(.plain)
                                    .accessibilityLabel(photo.filename)
                                    .accessibilityValue(photo.id.unitID == detail.group.topPickID ? L10n.string("photos.similar.topPick") : "")
                                    .overlay(alignment: .topTrailing) {
                                        Button {
                                            if !model.similarSelectedIDs.insert(photo.id).inserted { model.similarSelectedIDs.remove(photo.id) }
                                        } label: {
                                            Image(systemName: model.similarSelectedIDs.contains(photo.id) ? "checkmark.circle.fill" : "circle")
                                                .symbolRenderingMode(.palette).foregroundStyle(.white, Color.accentColor)
                                                .padding(4).background(.black.opacity(0.4), in: Circle())
                                        }.buttonStyle(.plain)
                                            .accessibilityLabel(L10n.string("photos.selection.toggle", photo.filename))
                                            .accessibilityValue(L10n.string(model.similarSelectedIDs.contains(photo.id) ? "photos.selection.selected" : "photos.selection.unselected"))
                                    }
                            }
                        }.padding(3)
                    }.frame(height: 112)
                }.padding(12).background(MacGlassSurface(role: .toolbar))
            }
            if model.isSaving {
                HStack {
                    ProgressView(value: model.saveProgress)
                    Button(L10n.string("photos.download.cancel")) { model.cancelSave() }
                }.padding(.horizontal)
                    .accessibilityIdentifier("photos.preview.saveProgress")
            }
            if let message = model.saveMessage {
                Text(message).font(.callout).padding(8).accessibilityIdentifier("photos.preview.saveMessage")
            }
            if model.similarUndoMutation != nil {
                Button(L10n.string("photos.similar.undo")) { model.undoSimilarChanges() }
                    .disabled(model.isManaging || model.pendingMutationID != nil || model.hasSimilarBatchToContinue).padding(8)
            }
            // 后台预览生成和上传有各自的进度入口，不占用当前照片的预览状态栏。
            if model.isManaging, !model.isGeneratingAutomaticPreview, !model.isUploading {
                ProgressView().padding(8).accessibilityIdentifier("photos.preview.managementProgress")
            }
            if let message = model.managementMessage { Text(message).font(.callout).padding(8) }
            if model.pendingMutationID != nil, !model.hasPendingAutomaticPreview, !model.isManaging {
                Button(L10n.string("photos.retry")) { model.reviewPendingMutation() }.padding(.bottom, 8)
            }
        }
        .alert(L10n.string("photos.similar.manage"), isPresented: Binding(
            get: { pendingSimilarMutation != nil }, set: { if !$0 { pendingSimilarMutation = nil } }), presenting: pendingSimilarMutation) { mutation in
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { pendingSimilarMutation = nil }
            Button(L10n.string("photos.similar.confirm")) { model.submitMutation(mutation); pendingSimilarMutation = nil }
        } message: { mutation in
            Text(similarConfirmation(mutation))
        }
        .sheet(item: $folderCoverTarget) { target in PhotoFolderCoverPanel(model: model, target: target) }
        .sheet(item: $selectionSharingSheet) { sheet in PhotoSelectionSharingPanel(model: model, photos: sheet.photos) }
        .sheet(item: $managementSheet) { sheet in PhotoManagementPanel(model: model, sheet: sheet) }
        .sheet(item: $faceEditorTarget) { target in PhotoFaceEditor(model: model, target: target) }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 600, idealHeight: 720)
        .background(MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).content)
    }

    private func managementButton(_ kind: PhotoManagementKind, photo: SynologyPhoto) -> some View {
        Button(kind.title) {
            model.finishMotion()
            managementSheet = managementTarget(kind, photo: photo)
        }.disabled(!canManage(kind, photo: photo))
    }

    // 表单固定打开时的照片及分类，不依赖图库中保留的多选。
    func managementTarget(_ kind: PhotoManagementKind, photo: SynologyPhoto) -> PhotoManagementSheet {
        .init(kind: kind, photos: [photo], album: model.selectedAlbum,
              concept: model.selectedCategory == .concept ? model.selectedCategoryItem : nil,
              person: model.selectedCategory == .person ? model.selectedCategoryItem : nil, space: photo.id.space)
    }

    func canManage(_ kind: PhotoManagementKind, photo: SynologyPhoto) -> Bool {
        guard !model.isManaging, !model.isDeleting, !model.isCheckingDeletion,
              model.pendingMutationID == nil, model.managementFeatures.contains(kind.feature) else { return false }
        switch kind {
        case .removeAlbum:
            return model.selectedAlbum?.acceptsManualMembers == true && model.canRemoveAlbumPhotos([photo])
        case .cover:
            return model.selectedAlbum != nil && model.selectedAlbumAccess?.isOwner == true
        case .addAlbum, .createAlbum: return model.canAddToAlbum([photo])
        case .move, .copy: return model.canTransfer([photo], copying: kind == .copy)
        case .conceptCover, .removeConceptItems:
            return model.canManageConceptPhotos([photo], cover: kind == .conceptCover)
        case .removeFaces, .reassignFaces, .personCover:
            return model.selectedCategory == .person && model.selectedCategoryItem?.space == photo.id.space
        default: return model.canEditSelection([photo], supportsMixedSpaces: false)
        }
    }

    private func similarConfirmation(_ mutation: SynologyPhotosMutation) -> String {
        guard case .editSimilarGroup(_, let edit) = mutation else { return "" }
        switch edit {
        case .topPick: return L10n.string("photos.similar.topPickConfirm")
        case .ungroup: return L10n.string("photos.similar.ungroupConfirm")
        case .remove(let ids): return L10n.string("photos.similar.removeConfirm", ids.count)
        case .undo: return L10n.string("photos.similar.undo")
        }
    }

    @ViewBuilder private func detailRow(_ key: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(key)).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func locationText(_ components: [String]) -> String {
        let formatter = ListFormatter()
        formatter.locale = L10n.locale
        return formatter.string(from: components) ?? components.joined(separator: " · ")
    }
}

/// 原生独立全屏窗口，关闭/退出全屏后回到原预览，不更改主窗口全屏状态。
private struct PhotoSlideshowPresentation: NSViewRepresentable {
    let model: SynologyPhotosModel
    let isPresented: Bool
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.synchronize(isPresented: isPresented) }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.model.stopSlideshow(); coordinator.close() }

    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: SynologyPhotosModel
        var window: NSWindow?
        init(model: SynologyPhotosModel) { self.model = model }
        func synchronize(isPresented: Bool) {
            if isPresented {
                guard window == nil else { return }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
                    styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.title = L10n.string("photos.slideshow.start")
                window.collectionBehavior.insert(.fullScreenPrimary)
                window.contentView = NSHostingView(rootView: PhotoSlideshowView(model: model).environment(MacAppearanceStore()))
                window.delegate = self; self.window = window
                window.center(); window.makeKeyAndOrderFront(nil); window.toggleFullScreen(nil)
            } else { close() }
        }
        func close() {
            guard let window else { return }
            window.delegate = nil; self.window = nil
            window.close(); window.contentView = nil
        }
        func windowWillClose(_ notification: Notification) { window = nil; model.stopSlideshow() }
        func windowDidExitFullScreen(_ notification: Notification) { model.stopSlideshow(); close() }
    }
}

struct PhotoSlideshowView: View {
    @Bindable var model: SynologyPhotosModel
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if model.isPreparingPreview { ProgressView().tint(.white) }
                else if let data = model.previewData, let image = NSImage(data: data),
                        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    FittedImagePreview(cgImage: cgImage, orientation: .up, showsControls: false, isZoomEnabled: false)
                        .id(model.slideshowMediaID)
                } else if let source = model.previewSource {
                    PhotoMotionPlayer(source: source, onFinished: model.slideshowVideoEnded,
                        isPlaying: model.isSlideshowPlaying, showsControls: true, onFailure: model.slideshowPlaybackFailed)
                        .id(model.slideshowMediaID)
                } else {
                    ContentUnavailableView(L10n.string("photos.media.open"), systemImage: "photo",
                        description: Text(model.previewError ?? L10n.string("photos.media.failed")))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottomLeading) { PhotoPreviewInformation(model: model) }
            if let error = model.slideshowError { Text(error).foregroundStyle(.white).padding(8) }
            HStack(spacing: 18) {
                Text(model.previewPhoto?.filename ?? "").lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                if model.isLoadingSlideshow { ProgressView().controlSize(.small).tint(.white) }
                Button { model.advanceSlideshow(-1) } label: { Label(L10n.string("photos.media.previous"), systemImage: "backward.end.fill") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.toggleSlideshowPlayback() } label: {
                    Label(L10n.string(model.isSlideshowPlaying ? "photos.slideshow.pause" : "photos.slideshow.play"),
                        systemImage: model.isSlideshowPlaying ? "pause.fill" : "play.fill")
                }.keyboardShortcut(.space, modifiers: [])
                Button { model.advanceSlideshow(1) } label: { Label(L10n.string("photos.media.next"), systemImage: "forward.end.fill") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button { model.stopSlideshow() } label: { Label(L10n.string("photos.slideshow.stop"), systemImage: "stop.fill") }
                    .keyboardShortcut(.cancelAction)
            }.labelStyle(.iconOnly).buttonStyle(.bordered).padding(16)
        }.background(.black).foregroundStyle(.white).environment(\.colorScheme, .dark).preferredColorScheme(.dark)
    }
}

/// Live Photo 和幻灯片复用同一流媒体加载器，暂停不重建请求，离开时释放播放器。
private struct PhotoMotionPlayer: NSViewRepresentable {
    let source: MediaStreamSource
    let onFinished: () -> Void
    var isPlaying = true
    var showsControls = false
    var onFailure: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished, onFailure: onFailure ?? onFinished) }
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = showsControls ? .inline : .none
        view.videoGravity = showsControls ? .resizeAspect : .resizeAspectFill
        context.coordinator.start(source, view: view)
        context.coordinator.setPlaying(isPlaying)
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { context.coordinator.setPlaying(isPlaying) }
    static func dismantleNSView(_ view: AVPlayerView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        private var loader: DsmAVAssetResourceLoaderDelegate?
        private var player: AVPlayer?
        private var endObserver: NSObjectProtocol?
        private var failureObserver: NSObjectProtocol?
        private var statusObserver: NSKeyValueObservation?
        private var active = false
        private let onFinished: () -> Void
        private let onFailure: () -> Void
        init(onFinished: @escaping () -> Void, onFailure: @escaping () -> Void) { self.onFinished = onFinished; self.onFailure = onFailure }
        func start(_ source: MediaStreamSource, view: AVPlayerView) {
            active = true
            let loader = DsmAVAssetResourceLoaderDelegate(source: source, onFailure: { [weak self] _ in
                Task { @MainActor in if self?.active == true { self?.onFailure() } }
            }, onLoadingMetrics: { _, _ in })
            self.loader = loader
            let asset = AVURLAsset(url: URL(string: "lanstash-media://motion/\(UUID().uuidString).mov")!)
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "lanstash.photos.motion"))
            let item = AVPlayerItem(asset: asset)
            statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                guard item.status == .failed else { return }
                Task { @MainActor in if self?.active == true { self?.onFailure() } }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.active == true { self?.onFinished() } }
            }
            failureObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.active == true { self?.onFailure() } }
            }
            let player = AVPlayer(playerItem: item)
            self.player = player
            view.player = player
        }
        func setPlaying(_ playing: Bool) { if playing { player?.play() } else { player?.pause() } }
        func stop() {
            active = false
            player?.pause()
            player = nil
            loader?.cancelAll()
            loader = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
            if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
            failureObserver = nil
            statusObserver = nil
        }
    }
}

private struct PhotoThumbnailLoadIdentity: Equatable { let photo: SynologyPhoto; let revision: Int }

/// 使用原生裁切区域判断可见比例，避免LazyVGrid预加载被当成正在浏览。
struct PhotoPreviewVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> VisibilityView { VisibilityView() }
    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
        view.scheduleReport()
    }
    static func dismantleNSView(_ view: VisibilityView, coordinator: ()) { view.detach() }

    @MainActor final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var lastVisible = false
        private var reportScheduled = false
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); observeClipping() }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); observeClipping() }
        override func setFrameOrigin(_ origin: NSPoint) { super.setFrameOrigin(origin); scheduleReport() }
        override func setFrameSize(_ size: NSSize) { super.setFrameSize(size); scheduleReport() }
        override var isHidden: Bool { didSet { scheduleReport() } }

        private func observeClipping() {
            NotificationCenter.default.removeObserver(self)
            var ancestor = superview
            while let view = ancestor {
                for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                    NotificationCenter.default.addObserver(self, selector: #selector(clippingChanged), name: name, object: view)
                }
                ancestor = view.superview
            }
            scheduleReport()
        }
        @objc private func clippingChanged(_ notification: Notification) { scheduleReport() }
        func scheduleReport() {
            guard !reportScheduled else { return }
            reportScheduled = true
            // 避开SwiftUI布局事务；合并同一轮滚动/尺寸变化，只报告阈值跨越。
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reportScheduled = false
                let area = self.bounds.width * self.bounds.height
                let clipped = self.visibleRect.intersection(self.bounds)
                let visible = self.window != nil && !self.isHiddenOrHasHiddenAncestor && area > 0 &&
                    !clipped.isNull && clipped.width * clipped.height / area >= 0.8
                guard visible != self.lastVisible else { return }
                self.lastVisible = visible
                self.onChange?(visible)
            }
        }
        func detach() {
            NotificationCenter.default.removeObserver(self)
            if lastVisible { onChange?(false) }
            lastVisible = false
            onChange = nil
        }
    }
}

struct SynologyPhotoCell: View {
    let photo: SynologyPhoto
    let model: SynologyPhotosModel
    var showsSimilarBadge = true
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var image: NSImage?
    @State private var visibilitySource = UUID()

    var body: some View {
        ZStack {
            MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).card
            if let image {
                GeometryReader { proxy in
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            } else {
                Image(systemName: photo.mediaType == "video" ? "video" : "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottomTrailing) {
            if showsSimilarBadge, let group = photo.similarGroup {
                Label(L10n.string("photos.similar.count", group.photoIDs.count), systemImage: "square.stack.3d.up")
                    .font(.caption.bold()).padding(6).background(.regularMaterial, in: Capsule()).padding(6)
            }
        }
        .accessibilityLabel(photo.filename)
        .background(PhotoPreviewVisibilityReader { visible in
            model.setPreviewVisible(photo, visible: visible, source: visibilitySource)
        })
        .onDisappear { model.setPreviewVisible(photo, visible: false, source: visibilitySource) }
        .task(id: PhotoThumbnailLoadIdentity(photo: photo, revision: model.automaticPreviewRevision(for: photo))) {
            image = nil
            do {
                let data = try await model.thumbnail(for: photo)
                guard !Task.isCancelled else { return }
                image = NSImage(data: data)
            } catch {
                // 图片读取失败保持占位，不影响其他照片；刷新后可重试。
            }
        }
    }
}
private extension SynologyPhotoCategory {
    var title: String {
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
    var symbol: String {
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

private extension SynologyPhotoShareScope {
    var title: String {
        switch self {
        case .withMe: L10n.string("photos.sharing.withMe")
        case .withOthers: L10n.string("photos.sharing.withOthers")
        case .requests: L10n.string("photos.sharing.requests")
        }
    }
}

struct PhotoFilterPanel: View {
    let model: SynologyPhotosModel
    @State var draft: SynologyPhotoFilter
    @State private var usesDate = false
    @State private var start = Date()
    @State private var end = Date()
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private var palette: MacAppearancePalette {
        MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased)
    }

    private var locations: [SynologyPhotoFilterChoice] {
        func flatten(_ entries: [SynologyPhotoLocation], prefix: String = "") -> [SynologyPhotoFilterChoice] {
            entries.flatMap { entry in
                let name = prefix.isEmpty ? entry.name : prefix + " / " + entry.name
                return [SynologyPhotoFilterChoice(id: entry.id, name: name)] + flatten(entry.children, prefix: name)
            }
        }
        return flatten(model.options.locations)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L10n.string("photos.filters")).font(.headline)
                if model.isLoadingFilterOptions { ProgressView().controlSize(.small) }
                Spacer()
                Button(L10n.string("photos.filters.clear")) { draft = SynologyPhotoFilter(); usesDate = false }
            }.padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = model.filterOptionsErrorMessage {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Button(L10n.string("photos.retry")) { Task { await model.loadFilterOptions() } }
                    }
                    sectionTitle("photos.filters.content")
                    choiceRow("photos.filters.type", options: [
                        .init(id: 0, name: L10n.string("photos.filters.images")),
                        .init(id: 1, name: L10n.string("photos.filters.videos"))
                    ], selection: $draft.mediaType)
                    choiceRow("photos.category.person", options: model.options.people.map { .init(id: $0.id, name: $0.name) }, selection: $draft.personID)
                    choiceRow("photos.category.location", options: locations, selection: $draft.locationID)
                    choiceRow("photos.category.tags", options: model.options.tags, selection: $draft.tagID)
                    choiceRow("photos.detail.rating", options: (0...5).map { .init(id: $0, name: $0 == 0 ? L10n.string("photos.filters.unrated") : L10n.string("photos.stars", $0)) }, selection: $draft.rating)
                    Divider()
                    sectionTitle("photos.filters.timeSection")
                    row("photos.filters.date") {
                        Toggle(L10n.string("photos.filters.date"), isOn: $usesDate)
                            .labelsHidden().toggleStyle(.switch).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if usesDate {
                        row("photos.filters.from") { DatePicker(L10n.string("photos.filters.from"), selection: $start, displayedComponents: .date).labelsHidden() }
                        row("photos.filters.to") { DatePicker(L10n.string("photos.filters.to"), selection: $end, displayedComponents: .date).labelsHidden() }
                    }
                    Divider()
                    sectionTitle("photos.filters.capture")
                    choiceRow("photos.detail.camera", options: model.options.cameras, selection: $draft.cameraID)
                    choiceRow("photos.detail.lens", options: model.options.lenses, selection: $draft.lensID)
                    row("photos.detail.focal") {
                        selectionMenu("photos.detail.focal", selection: $draft.focalRange, values: model.options.focalRanges, label: focalLabel)
                    }
                    row("photos.detail.shutter") {
                        selectionMenu("photos.detail.shutter", selection: $draft.exposureRange, values: model.options.exposureRanges, label: exposureLabel)
                    }
                    choiceRow("photos.detail.aperture", options: model.options.apertures, selection: $draft.apertureID)
                    choiceRow("photos.detail.iso", options: model.options.isoValues, selection: $draft.isoID)
                }.padding(16)
            }.frame(height: 420)
            Divider()
            HStack {
                Spacer()
                Button(L10n.string("photos.media.close")) { model.showsFilters = false }
                Button(L10n.string("photos.filters.apply"), action: apply)
                    .buttonStyle(MacToolbarButtonStyle(prominent: true))
                    .disabled(usesDate && Calendar.current.startOfDay(for: start) > Calendar.current.startOfDay(for: end))
            }.padding(16)
        }
        .buttonStyle(MacToolbarButtonStyle())
        .frame(width: 420)
        .background(palette.content)
        .task {
            if let from = draft.startTime, let to = draft.endTime {
                usesDate = true; start = Date(timeIntervalSince1970: Double(from)); end = Date(timeIntervalSince1970: Double(to))
            }
            await model.loadFilterOptions()
        }
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(L10n.string(key)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    private func row<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(L10n.string(key)).font(.callout).frame(width: 100, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }.frame(maxWidth: .infinity, minHeight: 34)
    }

    private func choiceRow(_ key: String, options: [SynologyPhotoFilterChoice], selection: Binding<Int?>) -> some View {
        row(key) {
            selectionMenu(key, selection: selection, values: options.map(\.id)) { id in
                options.first(where: { $0.id == id })?.name ?? L10n.string("photos.filters.noOptions")
            }
        }
    }

    private func selectionMenu<Value: Hashable>(_ key: String, selection: Binding<Value?>, values: [Value], label: @escaping (Value) -> String) -> some View {
        let titles = [L10n.string(values.isEmpty ? "photos.filters.noOptions" : "photos.filters.all")] + values.map(label)
        return PhotoFilterPopup(titles: titles, selectedIndex: Binding(
            get: { selection.wrappedValue.flatMap { values.firstIndex(of: $0) }.map { $0 + 1 } ?? 0 },
            set: { index in selection.wrappedValue = index > 0 && values.indices.contains(index - 1) ? values[index - 1] : nil }
        ), enabled: !values.isEmpty && !model.isLoadingFilterOptions, label: L10n.string(key))
        .frame(maxWidth: .infinity).frame(height: 34)
        .padding(.horizontal, 8)
        .background(palette.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(palette.separator, lineWidth: 1))
    }

    private func focalLabel(_ range: SynologyPhotoFocalRange) -> String {
        let start = range.start.formatted(.number.locale(L10n.locale))
        let end = range.end.formatted(.number.locale(L10n.locale))
        if range.start == 0 { return L10n.string("photos.filters.focalBelow", end) }
        if range.end == 0 { return L10n.string("photos.filters.focalAbove", start) }
        return L10n.string("photos.filters.focalRange", start, end)
    }

    private func fraction(_ value: SynologyPhotoFraction) -> String {
        let num = value.num.formatted(.number.locale(L10n.locale))
        return value.den == 1 ? num : num + "/" + value.den.formatted(.number.locale(L10n.locale))
    }

    private func exposureLabel(_ range: SynologyPhotoExposureRange) -> String {
        if range.start.num == 0 { return L10n.string("photos.filters.exposureBelow", fraction(range.end)) }
        if range.end.num == 0 { return L10n.string("photos.filters.exposureAbove", fraction(range.start)) }
        return L10n.string("photos.filters.exposureRange", fraction(range.start), fraction(range.end))
    }

    private func apply() {
        var filter = draft
        let calendar = Calendar(identifier: .gregorian)
        filter.startTime = usesDate ? Int(calendar.startOfDay(for: start).timeIntervalSince1970) : nil
        filter.endTime = usesDate ? calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)).map { Int($0.timeIntervalSince1970) - 1 } : nil
        model.showsFilters = false
        Task { await model.applyFilter(filter) }
    }
}
private struct PhotoFilterPopup: NSViewRepresentable {
    let titles: [String]
    @Binding var selectedIndex: Int
    let enabled: Bool
    let label: String
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selectedIndex) }
    func makeNSView(context: Context) -> FullWidthPopup {
        let view = FullWidthPopup(frame: .zero, pullsDown: false)
        view.isBordered = false
        view.alignment = .left
        view.font = .systemFont(ofSize: NSFont.systemFontSize)
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.target = context.coordinator
        view.action = #selector(Coordinator.select(_:))
        return view
    }
    func updateNSView(_ view: FullWidthPopup, context: Context) {
        context.coordinator.selection = $selectedIndex
        if context.coordinator.titles != titles {
            view.removeAllItems()
            view.addItems(withTitles: titles)
            context.coordinator.titles = titles
        }
        view.selectItem(at: selectedIndex)
        view.isEnabled = enabled
        view.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        view.setAccessibilityLabel(label)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FullWidthPopup, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: 34)
    }
    @MainActor final class FullWidthPopup: NSPopUpButton {
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 34) }
    }
    @MainActor final class Coordinator: NSObject {
        var selection: Binding<Int>
        var titles: [String] = []
        init(selection: Binding<Int>) { self.selection = selection }
        @objc func select(_ sender: NSPopUpButton) { selection.wrappedValue = sender.indexOfSelectedItem }
    }
}
struct PhotoTimelineRail: View {
    let months: [SynologyPhotoMonth]
    let selectedID: Int?
    let onSelect: (SynologyPhotoMonth) -> Void
    @State private var hoveredIndex: Int?
    @State private var draggedIndex: Int?
    @FocusState private var isFocused: Bool

    private var selectedIndex: Int { months.firstIndex { $0.id == selectedID } ?? 0 }
    private var highlightedIndex: Int? { draggedIndex ?? hoveredIndex ?? (isFocused ? selectedIndex : nil) }

    var body: some View {
        GeometryReader { geometry in
            let height = max(1, geometry.size.height - 20)
            let step = height / CGFloat(max(1, months.count - 1))
            ZStack(alignment: .topLeading) {
                ForEach(Array(months.enumerated()), id: \.element.id) { index, month in
                    Circle().fill(month.id == selectedID ? Color.accentColor : Color.secondary.opacity(0.35))
                        .frame(width: 3, height: 3)
                        .position(x: geometry.size.width - 10, y: 10 + CGFloat(index) * step)
                }
                ForEach(yearIndices(step: step), id: \.self) { index in
                    Text(months[index].year.formatted(.number.grouping(.never).locale(L10n.locale)))
                        .font(.caption).foregroundStyle(.secondary)
                        .opacity(highlightedIndex.map { abs(CGFloat(index - $0) * step) < 20 } == true ? 0 : 1)
                        .position(x: 42, y: 10 + CGFloat(index) * step)
                }
                if let index = highlightedIndex, months.indices.contains(index), let date = months[index].date {
                    Text(date.formatted(.dateTime.year().month(.twoDigits).locale(L10n.locale)))
                        .font(.caption.monospacedDigit()).padding(.horizontal, 6).padding(.vertical, 4)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .position(x: 42, y: min(max(14, 10 + CGFloat(index) * step), geometry.size.height - 14))
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoveredIndex = index(at: location.y, height: height)
                case .ended: hoveredIndex = nil
                }
            }
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                draggedIndex = index(at: value.location.y, height: height)
            }.onEnded { value in
                let target = index(at: value.location.y, height: height)
                draggedIndex = nil
                if months.indices.contains(target) { onSelect(months[target]) }
            })
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onKeyPress(.upArrow) { select(offset: -1); return .handled }
        .onKeyPress(.downArrow) { select(offset: 1); return .handled }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.string("photos.timeline.navigator"))
        .accessibilityValue(months.indices.contains(selectedIndex) ? months[selectedIndex].date?.formatted(.dateTime.year().month().locale(L10n.locale)) ?? "" : "")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: select(offset: -1)
            case .decrement: select(offset: 1)
            @unknown default: break
            }
        }
    }

    private func index(at y: CGFloat, height: CGFloat) -> Int {
        min(max(0, Int(((y - 10) / height * CGFloat(max(0, months.count - 1))).rounded())), max(0, months.count - 1))
    }
    private func yearIndices(step: CGFloat) -> [Int] {
        var indices: [Int] = []
        var previousYear: Int?
        for (index, month) in months.enumerated() where month.year != previousYear {
            previousYear = month.year
            if let last = indices.last, CGFloat(index - last) * step < 20 { continue }
            indices.append(index)
        }
        return indices
    }
    private func select(offset: Int) {
        guard !months.isEmpty else { return }
        onSelect(months[min(max(0, selectedIndex + offset), months.count - 1)])
    }
}

struct PhotoCategoryPreview: View {
    let model: SynologyPhotosModel
    let category: SynologyPhotoCategory
    let space: SynologyPhotoSpace
    @State private var images: [NSImage] = []
    @State private var isLoading = true

    var body: some View {
        GeometryReader { proxy in
            if images.isEmpty {
                ZStack {
                    if isLoading { ProgressView().controlSize(.small) }
                    else { Image(systemName: category.symbol).font(.system(size: 32)).foregroundStyle(.tint) }
                }.frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                let columns = images.count == 1 ? 1 : 2
                let rows = images.count > 2 ? 2 : 1
                let width = (proxy.size.width - CGFloat(columns - 1) * 2) / CGFloat(columns)
                let height = (proxy.size.height - CGFloat(rows - 1) * 2) / CGFloat(rows)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(width), spacing: 2), count: columns), spacing: 2) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(nsImage: images[index]).resizable().scaledToFill()
                            .frame(width: width, height: height).clipped()
                    }
                }
            }
        }
        .clipped().accessibilityHidden(true)
        .task(id: space) {
            images = []; isLoading = true
            defer { if !Task.isCancelled { isLoading = false } }
            do {
                let data = try await model.categoryPreviewImages(category, in: space)
                guard !Task.isCancelled else { return }
                images = data.compactMap(NSImage.init(data:))
            } catch { }
        }
    }
}

struct PhotoAlbumCover: View {
    let model: SynologyPhotosModel
    let album: SynologyPhotoCollection
    var category: SynologyPhotoCategory? = nil
    @State private var image: NSImage?
    var body: some View {
        GeometryReader { proxy in
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: category == .person ? "person.crop.square" : "rectangle.stack.fill").font(.system(size: 36)).foregroundStyle(.tint)
                }
            }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
        }
        .accessibilityHidden(true)
        .task(id: album) {
            image = nil
            do {
                let data: Data
                if let category { data = try await model.categoryThumbnail(for: album, category: category) }
                else { data = try await model.thumbnail(for: album) }
                guard !Task.isCancelled else { return }
                image = NSImage(data: data)
            } catch {
                // 单张封面加载失败保留占位，不影响打开相册。
            }
        }
    }
}

struct PhotoFolderCover: View {
    let model: SynologyPhotosModel
    let folder: SynologyPhotoCollection
    @State private var images: [NSImage] = []
    var body: some View {
        GeometryReader { proxy in
            if images.isEmpty {
                Image(systemName: "folder.fill").font(.system(size: 36)).foregroundStyle(.tint)
                    .frame(width: proxy.size.width, height: proxy.size.height)
            } else {
                let columns = images.count == 1 ? 1 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                    ForEach(images.indices, id: \.self) { index in
                        Image(nsImage: images[index]).resizable().scaledToFill()
                            .frame(width: (proxy.size.width - CGFloat(columns - 1) * 2) / CGFloat(columns),
                                   height: images.count <= 2 ? proxy.size.height : (proxy.size.height - 2) / 2).clipped()
                    }
                }
            }
        }.clipped().accessibilityHidden(true)
        .task(id: "\(folder.space.rawValue):\(folder.id):\(model.folderCoverRevision)") {
            images = []
            do {
                let data = try await model.folderCoverImages(folder)
                guard !Task.isCancelled else { return }
                images = data.compactMap(NSImage.init(data:))
            } catch { }
        }
    }
}


/// 网页底部信息等价入口；视频不叠加照片日期、地点和描述。
private struct PhotoPreviewInformation: View {
    @Bindable var model: SynologyPhotosModel
    var body: some View {
        if model.displayPreferences?.showsPreviewInfo == true, let photo = model.previewPhoto, !["video", "video360"].contains(photo.mediaType) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.formattedPhotoDate(photo.takenAt)).font(.callout)
                if !photo.addressComponents.isEmpty { Text(photo.addressComponents.prefix(3).joined(separator: ", ")).font(.caption) }
                if let description = photo.description, !description.isEmpty { Text(description).font(.callout).lineLimit(2) }
            }
            .foregroundStyle(.white).padding(12)
            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
            .padding(16).allowsHitTesting(false)
        }
    }
}
