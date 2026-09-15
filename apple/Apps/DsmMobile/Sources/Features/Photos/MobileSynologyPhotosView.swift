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
                            } else if model.hasLoaded && model.spaces.isEmpty {
                                ContentUnavailableView {
                                    Label(L10n.string("photos.error.title"), systemImage: "lock")
                                } description: { Text(L10n.string("photos.service.permission")) } actions: {
                                    Button(L10n.string("photos.retry")) { Task { await model.refresh() } }
                                }
                            } else if model.hasLoaded && model.items.isEmpty && model.collections.isEmpty
                                        && model.sharedEntries.isEmpty && !model.showsCategories {
                                ContentUnavailableView {
                                    Label(L10n.string("photos.empty.title"), systemImage: "photo.on.rectangle")
                                } description: {
                                    Text(L10n.string(model.isFiltering ? "photos.library.noResults" :
                                        model.section == .sharing ? "photos.sharing.empty" :
                                        model.section == .albums ? "photos.library.noAlbums" : "photos.library.empty"))
                                } actions: {
                                    Button(L10n.string("photos.library.refresh")) { Task { await model.refresh() } }
                                    if model.isFiltering {
                                        Button(L10n.string("photos.filters.clear")) {
                                            model.searchText = ""
                                            Task { await model.applyFilter(SynologyPhotoFilter()) }
                                        }
                                    }
                                }
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
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
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
                Button { Task { await model.refresh() } } label: {
                    Label(L10n.string("photos.library.refresh"), systemImage: "arrow.clockwise")
                }.frame(minWidth: 44, minHeight: 44).disabled(model.isLoading || model.isDeleting)
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .sheet(isPresented: $model.showsFilters) {
            MobileSynologyPhotoFilters(model: model, draft: model.filter)
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
        .modifier(MobileSynologyPhotoExportPresentation(session: session, active: model.previewPhoto == nil))
        .task { await session.activate() }
        .onDisappear { session.deactivate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.deactivate() }
            else if phase == .active { Task { await session.activate() } }
        }
    }

    private var header: some View {
        VStack(spacing: 8) {
            if sizeClass == .regular {
                Picker(L10n.string("photos.library.browse"), selection: section) {
                    ForEach(SynologyPhotosSection.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            } else {
                Picker(L10n.string("photos.library.browse"), selection: section) {
                    ForEach(SynologyPhotosSection.allCases, id: \.self) { Text($0.title).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            if model.section == .sharing && model.selectedAlbum == nil {
                Picker(L10n.string("photos.sharing"), selection: Binding(get: { model.shareScope }, set: { value in
                    Task { await model.selectShareScope(value) }
                })) {
                    ForEach(SynologyPhotoShareScope.allCases, id: \.self) { Text($0.mobileTitle).tag($0) }
                }.pickerStyle(.menu).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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
            Button { Task { await model.open(collection) } } label: {
                Label(collection.name, systemImage: model.section == .folders ? "folder" : "photo.on.rectangle")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.bordered)
        }
        ForEach(model.sharedEntries) { entry in
            HStack {
                if entry.albumID != nil {
                    Button(entry.title) { Task { await model.openSharedAlbum(entry) } }.frame(minHeight: 44)
                } else { Text(entry.title) }
                Spacer()
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

    private func photoGrid(_ photos: [SynologyPhoto]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 220), spacing: 8)], spacing: 8) {
            ForEach(photos) { photo in
                MobileSynologyPhotoCell(photo: photo, session: session) { model.showPreview(photo) }
                    .id(photo.id)
                    .contextMenu {
                        Button(L10n.string("photos.media.open")) { model.showPreview(photo) }
                        Button(L10n.string("photos.media.save")) { session.exportOriginal(photo) }
                        Button(L10n.string("photos.delete.action"), role: .destructive) { model.requestDeletion(photo) }
                            .disabled(model.isDeleting || model.isCheckingDeletion || model.pendingDeletionPhoto != nil)
                    }
            }
        }
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo.filename)
        .accessibilityHint(L10n.string("photos.media.open"))
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
