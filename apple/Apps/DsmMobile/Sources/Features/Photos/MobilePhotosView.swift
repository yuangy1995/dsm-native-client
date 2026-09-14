import DsmCore
import DsmLocalization
import SwiftUI

/// 正式照片入口只消费 Synology Photos 身份；文件管理中的媒体预览保持独立。
struct MobilePhotosView: View {
    let model: MobileAppModel
    var body: some View {
        MobileSynologyPhotosContent(library: model.synologyPhotosModel)
            .id(ObjectIdentifier(model.synologyPhotosModel))
    }
}

private struct MobileSynologyPhotosContent: View {
    @Bindable var library: MobileSynologyPhotosModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if horizontalSizeClass == .regular { regularLayout }
            else { compactLayout }
        }
        .background { MobileWorkspaceBackground() }
        .safeAreaInset(edge: .top, spacing: 0) { controls.padding(.horizontal, 12).padding(.bottom, 8) }
        .task {
            library.setModuleEnabled(true)
            await library.loadIfNeeded()
        }
        .onDisappear { library.cancel() }
        .sheet(isPresented: $library.showsFilters) {
            MobileSynologyPhotoFilters(library: library, draft: library.filter)
        }
        .fullScreenCover(isPresented: Binding(
            get: { library.previewPhoto != nil },
            set: { if !$0 { library.closePreview(); library.clearExport() } }
        ), onDismiss: { library.closePreview(); library.clearExport() }) {
            MobileSynologyPhotoPreview(library: library)
        }
    }

    private var regularLayout: some View {
        HStack(alignment: .top, spacing: 12) {
            page
            if library.showsTimeline, !library.timelineMonths.isEmpty,
               !dynamicTypeSize.isAccessibilitySize {
                monthSidebar.frame(width: 112).padding(.trailing, 12)
            }
        }
    }

    private var compactLayout: some View { page }

    private var controls: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(MobileSynologyPhotosSection.allCases, id: \.self) { section in
                        Button {
                            Task { await library.selectSection(section) }
                        } label: {
                            Text(section.title).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14).frame(minHeight: 44)
                                .background(library.section == section ? Color.accentColor.opacity(0.16) : .clear, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(library.section == section ? Color.accentColor : .primary)
                        .accessibilityAddTraits(library.section == section ? .isSelected : [])
                    }
                }
            }
            if library.section == .sharing, library.selectedAlbum == nil {
                Picker(L10n.string("photos.sharing"), selection: Binding(
                    get: { library.shareScope },
                    set: { scope in Task { await library.selectShareScope(scope) } }
                )) {
                    ForEach(SynologyPhotoShareScope.allCases, id: \.self) { scope in
                        Text(scope.mobileTitle).tag(scope)
                    }
                }.pickerStyle(.menu).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            HStack(spacing: 4) {
                if library.canGoBack {
                    control("photos.library.back", symbol: "chevron.backward") { Task { await library.goBack() } }
                }
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField(L10n.string("photos.library.search"), text: $library.searchText)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search).onSubmit { Task { await library.submitSearch() } }
                    .frame(minHeight: 44)
                    .disabled(library.section == .sharing)
                if !library.searchText.isEmpty {
                    control("photos.filters.clear", symbol: "xmark.circle.fill") {
                        library.searchText = ""; Task { await library.submitSearch() }
                    }
                }
                control("photos.filters", symbol: library.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") {
                    library.showsFilters = true
                }.disabled(library.section == .sharing)
                if !library.timelineMonths.isEmpty {
                    Menu {
                        ForEach(library.timelineMonths) { month in
                            Button(monthLabel(month)) { Task { await library.jumpToMonth(month) } }
                        }
                    } label: {
                        Image(systemName: "calendar").frame(width: 44, height: 44)
                    }.accessibilityLabel(L10n.string("photos.timeline.navigator"))
                }
            }
            if library.spaces.count > 1 {
                Picker(L10n.string("photos.library.space"), selection: Binding(
                    get: { library.selectedSpace },
                    set: { space in Task { await library.refresh(space: space) } }
                )) {
                    ForEach(library.spaces, id: \.self) { space in
                        Text(L10n.string(space == .personal ? "photos.space.personal" : "photos.space.shared")).tag(space)
                    }
                }.pickerStyle(.segmented)
            }
        }
        .padding(8).mobileGlass()
    }

    private var monthSidebar: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(library.timelineMonths) { month in
                    Button(monthLabel(month)) { Task { await library.jumpToMonth(month) } }
                        .font(.caption.monospacedDigit())
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(library.selectedTimelineMonthID == month.id ? Color.accentColor.opacity(0.16) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityAddTraits(library.selectedTimelineMonthID == month.id ? .isSelected : [])
                }
            }.padding(6)
        }.mobileGlass().accessibilityLabel(L10n.string("photos.timeline.navigator"))
    }

    @ViewBuilder
    private var page: some View {
        if library.isLoading && !hasContent {
            ProgressView(L10n.string("mobile.photos.loading.album"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = library.errorMessage, !hasContent {
            emptyState(title: "photos.error.title", message: error, isError: true)
        } else if library.hasLoaded && library.spaces.isEmpty {
            emptyState(title: "photos.error.title", message: L10n.string("photos.service.permission"), isError: true)
        } else if library.hasLoaded && !hasContent && !library.hasPrevious {
            emptyState(title: "photos.empty.title", message: emptyMessage, isError: false)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let error = library.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.secondary)
                        Button(L10n.string("photos.retry")) {
                            Task {
                                if library.hasMoreCollections { await library.loadMoreCollections() }
                                else if library.hasMore { await library.loadMore() }
                                else { await library.refresh() }
                            }
                        }.frame(minHeight: 44)
                    }
                    if library.hasPrevious {
                        Button(L10n.string("photos.library.newer")) { Task { await library.loadPreviousPage() } }
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .disabled(library.isLoadingPrevious)
                        if library.isLoadingPrevious { ProgressView() }
                        if let error = library.previousPageErrorMessage {
                            Text(error).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if library.showsCategories {
                        LazyVGrid(columns: collectionColumns, spacing: 12) {
                            ForEach(SynologyPhotoCategory.allCases.filter { library.availableCategories.contains($0) }, id: \.self) { category in
                                collectionButton(category.mobileTitle, symbol: category.mobileSymbol) {
                                    Task { await library.openCategory(category) }
                                }
                            }
                        }
                    }
                    if !library.collections.isEmpty {
                        LazyVGrid(columns: collectionColumns, spacing: 12) {
                            ForEach(library.collections) { collection in
                                collectionButton(collection.name, symbol: library.section == .folders ? "folder" : "rectangle.stack") {
                                    Task { await library.open(collection) }
                                }
                            }
                        }
                    }
                    ForEach(library.sharedEntries) { entry in
                        HStack {
                            if entry.albumID != nil {
                                Button { Task { await library.openSharedAlbum(entry) } } label: {
                                    Label(entry.title, systemImage: "person.2.crop.square.stack")
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                            } else {
                                Label(entry.title, systemImage: "link").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                            if let url = entry.url {
                                ShareLink(item: url) {
                                    Image(systemName: "square.and.arrow.up").frame(width: 44, height: 44)
                                }.accessibilityLabel(L10n.string("mobile.photos.action.share"))
                            }
                        }.padding(12).background(.background, in: RoundedRectangle(cornerRadius: 16))
                    }
                    ForEach(library.datedGroups, id: \.date) { group in
                        Text(group.date.formatted(.dateTime.year().month().day().locale(L10n.locale)))
                            .font(.headline).accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: photoColumns, spacing: 8) {
                            ForEach(group.photos) { photo in
                                MobileSynologyPhotoCell(photo: photo, library: library) { library.showPreview(photo) }
                            }
                        }
                    }
                    if library.hasMore || library.hasMoreCollections {
                        ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                            .accessibilityLabel(L10n.string("mobile.photos.loading-more"))
                            .task(id: library.paginationIdentity) { await library.loadNextPageAutomatically() }
                    }
                }.padding(16)
            }.refreshable { await library.refresh() }
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
    private var collectionColumns: [GridItem] { [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 260 : 150), spacing: 12)] }
    private var photoColumns: [GridItem] { [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 180 : 108), spacing: 8)] }

    private func emptyState(title: String, message: String, isError: Bool) -> some View {
        ContentUnavailableView {
            Label(L10n.string(title), systemImage: isError ? "exclamationmark.triangle" : "photo.on.rectangle")
        } description: { Text(message) } actions: {
            if library.isFiltering {
                Button(L10n.string("photos.filters.clear")) { Task { await library.resetSearchAndFilters() } }.frame(minHeight: 44)
            }
            Button(L10n.string(isError ? "photos.retry" : "photos.library.refresh")) { Task { await library.refresh() } }.frame(minHeight: 44)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func collectionButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol).font(.body)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading).padding(12)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain)
    }
    private func control(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
            .accessibilityLabel(L10n.string(key))
    }
    private func monthLabel(_ month: MobileSynologyPhotoMonth) -> String {
        month.date?.formatted(.dateTime.year().month(.abbreviated).locale(L10n.locale)) ?? ""
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
