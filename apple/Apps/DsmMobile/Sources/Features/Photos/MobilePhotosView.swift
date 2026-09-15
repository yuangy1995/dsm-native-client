import DsmCore
import DsmLocalization
import SwiftUI

/// 照片主入口只接 Synology Photos。Files 中的路径媒体预览仍由 Files 自己负责。
struct MobilePhotosView: View {
    @Bindable var model: MobileAppModel
    var body: some View {
        MobileSynologyPhotosLibrary(
            library: model.synologyPhotosModel,
            repository: model.synologyPhotosRepository,
            cache: model.synologyPhotosCache,
            exporter: model.synologyPhotosExporter
        )
        .id(model.synologyPhotosProfileID)
    }
}

struct MobileSynologyPhotosLibrary: View {
    @Bindable var library: SynologyPhotosModel
    let repository: (any SynologyPhotosServing)?
    let cache: MobilePhotoThumbnailStore
    @Bindable var exporter: MobilePhotosExportModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsMonths = false
    @State private var galleryScale = 1.0

    var body: some View {
        ZStack {
            MobileGlassBackground()
            content
        }
        .safeAreaInset(edge: .top, spacing: 0) { chrome }
        .navigationTitle(L10n.string("mobile.photos.title"))
        .toolbarBackground(.hidden, for: .navigationBar)
        .task(id: ObjectIdentifier(library)) { await library.loadIfNeeded() }
        .refreshable { await refresh() }
        .sheet(isPresented: $library.showsFilters) {
            MobileSynologyPhotoFilters(library: library, draft: library.filter)
        }
        .sheet(isPresented: $showsMonths) { monthPicker }
        .fullScreenCover(isPresented: Binding(
            get: { library.previewPhoto != nil },
            set: { if !$0 { library.closePreview() } }
        )) {
            MobileSynologyPhotoPreview(library: library, repository: repository, exporter: exporter)
        }
        .sheet(item: Binding(
            get: { library.previewPhoto == nil ? exporter.presentation : nil },
            set: { if $0 == nil && library.previewPhoto == nil { exporter.finishPresentation() } }
        ), onDismiss: exporter.finishPresentation) { presentation in
            MobileShareSheet(url: presentation.url, completion: exporter.finishPresentation)
        }
        .alert(L10n.string("photos.error.title"), isPresented: Binding(
            get: { exporter.errorMessage != nil && library.previewPhoto == nil },
            set: { if !$0 { exporter.errorMessage = nil } }
        )) {
            Button(L10n.string("photos.media.close")) { exporter.errorMessage = nil }
        } message: { Text(exporter.errorMessage ?? "") }
        .overlay(alignment: .bottom) {
            if exporter.isPreparing && library.previewPhoto == nil {
                exportProgress.padding(16)
            }
        }
    }

    private var chrome: some View {
        MobileGlassGroup {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    if library.canGoBack {
                        Button { Task { await library.goBack() } } label: {
                            Label(L10n.string("photos.library.back"), systemImage: "chevron.left")
                        }
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    Picker(L10n.string("photos.library.space"), selection: Binding(
                        get: { library.selectedSpace },
                        set: { space in Task { await library.refresh(space: space) } }
                    )) {
                        ForEach(library.spaces, id: \.self) { space in
                            Text(L10n.string(space == .personal ? "native.photos.personal" : "native.photos.shared"))
                                .tag(space)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(library.spaces.count < 2)
                    Spacer(minLength: 4)
                    if !library.timelineMonths.isEmpty {
                        Button { showsMonths = true } label: {
                            Label(L10n.string("photos.timeline.navigator"), systemImage: "calendar")
                        }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    }
                    Menu {
                        Button { galleryScale = max(0.75, galleryScale - 0.25) } label: {
                            Label(L10n.string("native.photos.grid.smaller"), systemImage: "square.grid.3x3")
                        }.disabled(galleryScale <= 0.75)
                        Button { galleryScale = min(2, galleryScale + 0.25) } label: {
                            Label(L10n.string("native.photos.grid.larger"), systemImage: "square.grid.2x2")
                        }.disabled(galleryScale >= 2)
                        Button { Task { await refresh() } } label: {
                            Label(L10n.string("photos.library.refresh"), systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Label(L10n.string("photos.library.browse"), systemImage: "ellipsis.circle")
                    }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                    Button { library.showsFilters = true } label: {
                        Label(L10n.string("photos.filters"), systemImage: library.filter.isActive
                              ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                if dynamicTypeSize.isAccessibilitySize {
                    sectionPicker.pickerStyle(.menu)
                } else {
                    sectionPicker.pickerStyle(.segmented)
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(L10n.string("photos.library.search"), text: $library.searchText)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await library.refresh() } }
                        .disabled(library.filter.isActive)
                    if !library.searchText.isEmpty {
                        Button {
                            library.searchText = ""
                            Task { await library.refresh() }
                        } label: { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel(L10n.string("photos.filters.clear"))
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .padding(.horizontal, 12).frame(minHeight: 44)
                .mobileGlassCard(cornerRadius: 12)
                if library.filter.isActive {
                    HStack {
                        Text(L10n.string("photos.filters.searchHint")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.string("photos.filters.clear")) {
                            Task { await library.applyFilter(SynologyPhotoFilter()) }
                        }.frame(minHeight: 44)
                    }
                }
                if library.section == .sharing && library.selectedAlbum == nil {
                    Picker(L10n.string("photos.sharing"), selection: Binding(
                        get: { library.shareScope },
                        set: { scope in Task { await library.selectShareScope(scope) } }
                    )) {
                        ForEach(SynologyPhotoShareScope.allCases, id: \.self) { scope in
                            Text(scope.mobileTitle).tag(scope)
                        }
                    }.pickerStyle(.menu)
                }
                if let title = library.selectedCategoryItem?.name ?? library.selectedAlbum?.name
                    ?? (library.folderHistory.count > 1 ? library.folderHistory.last?.name : nil) {
                    Text(title).font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                        .lineLimit(2).accessibilityAddTraits(.isHeader)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .mobileGlassChrome(cornerRadius: 20)
            .padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private var sectionPicker: some View {
        Picker(L10n.string("photos.library.browse"), selection: Binding(
            get: { library.section },
            set: { section in Task { await library.selectSection(section) } }
        )) {
            ForEach(SynologyPhotosSection.allCases, id: \.self) { section in
                Text(section.title).tag(section)
            }
        }
    }

    @ViewBuilder private var content: some View {
        if library.isLoading && library.items.isEmpty && library.collections.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.string("mobile.photos.loading.album"))
        } else if let message = library.errorMessage, !hasContent {
            ContentUnavailableView {
                Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.icloud")
            } description: { Text(message) }
            actions: { Button(L10n.string("photos.retry")) { Task { await refresh() } }.frame(minHeight: 44) }
        } else if !hasContent {
            ContentUnavailableView {
                Label(L10n.string("photos.empty.title"), systemImage: "photo.on.rectangle.angled")
            } description: { Text(emptyMessage) }
            actions: {
                if library.isFiltering {
                    Button(L10n.string("photos.filters.clear")) {
                        library.searchText = ""
                        Task { await library.applyFilter(SynologyPhotoFilter()) }
                    }.frame(minHeight: 44)
                } else {
                    Button(L10n.string("photos.library.refresh")) { Task { await refresh() } }.frame(minHeight: 44)
                }
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if library.hasPrevious {
                            Button {
                                let anchor = library.items.first?.id
                                Task {
                                    await library.loadPreviousPage()
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            } label: {
                                if library.isLoadingPrevious { ProgressView() }
                                else { Label(L10n.string("native.photos.newer"), systemImage: "arrow.up") }
                            }.frame(maxWidth: .infinity, minHeight: 44)
                                .disabled(library.isLoadingPrevious)
                            if let message = library.previousPageErrorMessage {
                                Text(message).foregroundStyle(.secondary)
                            }
                        }
                        if library.showsCategories { categories }
                        if !library.collections.isEmpty { collections }
                        ForEach(library.sharedEntries) { entry in
                            HStack(spacing: 12) {
                                Button { Task { await library.openSharedAlbum(entry) } } label: {
                                    Label(entry.title, systemImage: entry.albumID == nil ? "person.crop.rectangle" : "rectangle.stack")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }.disabled(entry.albumID == nil)
                                if let url = entry.url {
                                    ShareLink(item: url) {
                                        Label(L10n.string("native.photos.share"), systemImage: "square.and.arrow.up")
                                    }.labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                                }
                            }.padding(12).mobileGlassCard()
                        }
                        if library.showsTimeline {
                            ForEach(library.datedGroups, id: \.date) { group in
                                Text(group.date.formatted(.dateTime.year().month().day().locale(L10n.locale)))
                                    .font(.headline).accessibilityAddTraits(.isHeader)
                                photoGrid(group.photos)
                            }
                        } else { photoGrid(library.items) }
                        pagination
                    }.padding(16)
                }
                .accessibilityIdentifier("native.photos.gallery")
            }
        }
    }

    private var hasContent: Bool {
        !library.items.isEmpty || !library.collections.isEmpty || !library.sharedEntries.isEmpty || library.showsCategories
    }
    private var emptyMessage: String {
        if library.isFiltering { return L10n.string("photos.library.noResults") }
        if library.section == .sharing { return L10n.string("photos.sharing.empty") }
        if library.section == .albums { return L10n.string("photos.library.noAlbums") }
        return L10n.string("photos.library.empty")
    }
    private var columns: [GridItem] {
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? 170 : (sizeClass == .regular ? 150 : 104)
        return [GridItem(.adaptive(minimum: minimum * CGFloat(galleryScale)), spacing: 6)]
    }
    private var categories: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
            ForEach(SynologyPhotoCategory.allCases.filter { library.availableCategories.contains($0) }, id: \.self) { category in
                Button { Task { await library.openCategory(category) } } label: {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: category.mobileSymbol).font(.largeTitle).foregroundStyle(.tint)
                        Text(category.mobileTitle).font(.headline).multilineTextAlignment(.leading)
                    }.frame(maxWidth: .infinity, minHeight: 108, alignment: .leading).padding(16)
                        .mobileGlassCard()
                }.buttonStyle(.plain)
            }
        }
    }
    private var collections: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 12)], spacing: 12) {
            ForEach(library.collections) { collection in
                Button { Task { await library.open(collection) } } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: library.section == .folders ? "folder.fill" : "rectangle.stack.fill")
                            .font(.largeTitle).foregroundStyle(.tint)
                        Text(collection.name).font(.headline).multilineTextAlignment(.leading).lineLimit(3)
                        if let count = collection.itemCount {
                            Text(L10n.string("native.photos.collection.count", count)).font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 112, alignment: .leading).padding(16).mobileGlassCard()
                }.buttonStyle(.plain).accessibilityLabel(collection.name)
            }
        }
    }
    private func photoGrid(_ photos: [SynologyPhoto]) -> some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(photos) { photo in
                Button { library.showPreview(photo) } label: {
                    MobileSynologyPhotoCell(photo: photo, repository: repository, cache: cache)
                }.buttonStyle(.plain).id(photo.id)
                    .accessibilityLabel(L10n.string("mobile.photos.open-photo", photo.filename))
            }
        }
    }
    @ViewBuilder private var pagination: some View {
        if let message = library.errorMessage {
            VStack(spacing: 8) {
                Text(message).foregroundStyle(.secondary)
                Button(L10n.string("photos.retry")) {
                    Task {
                        if library.hasMoreCollections { await library.loadMoreCollections() }
                        else if library.hasMore { await library.loadMore() }
                        else { await refresh() }
                    }
                }.frame(minHeight: 44)
            }.frame(maxWidth: .infinity)
        } else if library.hasMore || library.hasMoreCollections {
            ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                .id(library.paginationIdentity)
                .task { await library.loadNextPageAutomatically() }
        }
    }
    private var monthPicker: some View {
        NavigationStack {
            List(library.timelineMonths) { month in
                if let date = month.date {
                    Button {
                        showsMonths = false
                        Task { await library.jumpToMonth(month) }
                    } label: {
                        HStack {
                            Text(date.formatted(.dateTime.year().month().locale(L10n.locale)))
                            Spacer()
                            if month.id == library.selectedTimelineMonthID { Image(systemName: "checkmark") }
                        }.frame(minHeight: 44)
                    }
                }
            }.mobileGlassWorkspace()
                .navigationTitle(L10n.string("photos.timeline.navigator"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L10n.string("photos.media.close")) { showsMonths = false }.frame(minHeight: 44)
                    }
                }
        }.presentationDetents([.medium, .large])
    }
    private var exportProgress: some View {
        HStack {
            ProgressView(value: exporter.progress)
            Text(L10n.string("native.photos.exporting")).font(.callout)
            Button(L10n.string("photos.delete.cancel")) { exporter.cancel() }.frame(minHeight: 44)
        }.padding(12).mobileGlassChrome()
    }
    private func refresh() async {
        await cache.removeAll()
        await library.refresh()
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
