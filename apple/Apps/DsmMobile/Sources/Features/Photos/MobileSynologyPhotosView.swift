import DsmCore
import DsmLocalization
import ImageIO
import SwiftUI
import UIKit

/// 正式照片入口只接受 Photos 身份。文件管理中的预览、传输和后台任务不在此伪装成图库写操作。
struct MobileSynologyPhotosView: View {
    @Bindable var model: MobileSynologyPhotosModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsMonths = false
    @FocusState private var searchFocused: Bool

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: dynamicTypeSize.isAccessibilitySize ? 160 : (sizeClass == .regular ? 150 : 108)), spacing: 8)]
    }

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16, pinnedViews: [.sectionHeaders]) {
                    Color.clear.frame(height: 1).id("photos-top")
                    pageContent
                    pagination
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 20)
            }
            .safeAreaInset(edge: .top, spacing: 0) { navigationChrome }
            .refreshable { await model.refresh() }
            .onChange(of: model.selectedTimelineMonthID) { _, _ in
                scroll.scrollTo("photos-top", anchor: .top)
            }
        }
        .mobileAppearanceRoot()
        .task { await model.loadIfNeeded() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { model.suspend() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.thumbnailStore.removeAll() }
        }
        .sheet(isPresented: $model.showsFilters) {
            MobileSynologyPhotoFilters(model: model, draft: model.filter)
        }
        .sheet(isPresented: $showsMonths) { monthPicker }
        .fullScreenCover(isPresented: Binding(
            get: { model.previewPhoto != nil },
            set: { if !$0 { model.closePreview() } }
        )) {
            MobileSynologyPhotoPreview(model: model)
        }
        .sheet(item: Binding(
            get: { model.previewPhoto == nil ? model.exportPresentation : nil },
            set: { if $0 == nil, model.previewPhoto == nil { model.completeExport() } }
        )) { presentation in
            MobilePhotosExportSheet(presentation: presentation, completion: model.completeExport)
        }
    }

    private var navigationChrome: some View {
        MobileGlassGroup {
            VStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(MobileSynologyPhotosSection.allCases, id: \.self) { section in
                            Button {
                                searchFocused = false
                                Task { await model.selectSection(section) }
                            } label: {
                                Text(section.title)
                                    .font(.callout.weight(model.section == section ? .semibold : .regular))
                                    .padding(.horizontal, 14)
                                    .frame(minHeight: 44)
                                    .background(model.section == section ? Color.accentColor.opacity(0.13) : .clear, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(model.section == section ? .isSelected : [])
                        }
                    }.padding(4)
                }.mobileGlass(radius: 28)
                HStack(spacing: 8) {
                    if model.canGoBack {
                        Button { Task { await model.goBack() } } label: {
                            Label(L10n.string("photos.library.back"), systemImage: "chevron.left")
                                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                        }
                        .keyboardShortcut(.leftArrow, modifiers: .command)
                    }
                    if model.section == .timeline {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                            TextField(L10n.string("photos.library.search"), text: $model.searchText)
                                .focused($searchFocused)
                                .submitLabel(.search)
                                .autocorrectionDisabled()
                                .onSubmit { searchFocused = false; Task { await model.refresh() } }
                                .disabled(model.filter.isActive)
                            if !model.searchText.isEmpty {
                                Button {
                                    model.searchText = ""
                                    Task { await model.refresh() }
                                } label: {
                                    Image(systemName: "xmark.circle.fill").frame(minWidth: 44, minHeight: 44)
                                }.accessibilityLabel(L10n.string("photos.filters.clear"))
                            }
                        }
                        .padding(.leading, 12).frame(minHeight: 44).mobileGlass(radius: 12)
                    } else {
                        Text(model.folderHistory.last?.name ?? model.selectedAlbum?.name
                             ?? model.selectedCategoryItem?.name ?? model.section.title)
                            .font(.callout.weight(.medium)).lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.section == .timeline {
                        Button { model.showsFilters = true; searchFocused = false } label: {
                            Image(systemName: model.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                                .frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel(L10n.string("photos.filters"))
                    }
                    if !model.timelineMonths.isEmpty {
                        Button { showsMonths = true; searchFocused = false } label: {
                            Image(systemName: "calendar").frame(minWidth: 44, minHeight: 44)
                        }.accessibilityLabel(L10n.string("photos.timeline.navigator"))
                    }
                    Button { searchFocused = false; Task { await model.refresh() } } label: {
                        Image(systemName: "arrow.clockwise").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel(L10n.string("photos.library.refresh"))
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isLoading)
                }
                if model.filter.isActive {
                    HStack {
                        Text(L10n.string("photos.filters.searchHint")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(L10n.string("photos.filters.clear")) {
                            Task { await model.applyFilter(SynologyPhotoFilter()) }
                        }.frame(minHeight: 44)
                    }
                }
                if model.section == .sharing, model.selectedAlbum == nil {
                    Picker(L10n.string("photos.sharing"), selection: Binding(
                        get: { model.shareScope },
                        set: { value in Task { await model.selectShareScope(value) } }
                    )) {
                        ForEach(SynologyPhotoShareScope.allCases, id: \.self) { scope in
                            Text(shareTitle(scope)).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }

    @ViewBuilder private var pageContent: some View {
        if model.isLoading && !model.hasLoaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                .accessibilityLabel(L10n.string("parity.photos.loading"))
        } else {
            if let error = model.errorMessage {
                ContentUnavailableView {
                    Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button(L10n.string("photos.retry")) { Task { await model.retryCurrentPage() } }
                        .frame(minHeight: 44)
                }
            }
            if model.hasPrevious {
                Button {
                    Task { await model.openNewerMonth() }
                } label: {
                    Label(L10n.string("parity.photos.newerMonth"), systemImage: "arrow.up")
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.mobileGlass()
            }
            if model.showsCategories { categories }
            if !model.collections.isEmpty { collections }
            if !model.sharedEntries.isEmpty { sharing }
            if model.showsTimeline {
                ForEach(model.datedGroups, id: \.date) { group in
                    Section {
                        photoGrid(group.photos)
                    } header: {
                        Text(group.date.formatted(.dateTime.year().month(.wide).day().locale(L10n.locale)))
                            .font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .mobileGlass(radius: 12).accessibilityAddTraits(.isHeader)
                    }
                }
            } else if !model.items.isEmpty { photoGrid(model.items) }
            if model.hasLoaded, model.items.isEmpty, model.collections.isEmpty, model.sharedEntries.isEmpty,
               !model.showsCategories, model.errorMessage == nil {
                ContentUnavailableView {
                    Label(L10n.string("photos.empty.title"), systemImage: "photo.on.rectangle.angled")
                } description: {
                    Text(L10n.string(model.spaces.isEmpty ? "photos.service.permission" :
                        model.section == .sharing ? "photos.sharing.empty" :
                        model.isFiltering ? "photos.library.noResults" : "photos.library.empty"))
                }
            }
            if model.isSaving {
                ProgressView(value: model.saveProgress)
                    .accessibilityLabel(L10n.string("photos.media.save"))
            }
            if let message = model.saveMessage {
                Text(message).foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    private func photoGrid(_ photos: [SynologyPhoto]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(photos) { photo in
                MobileSynologyPhotoCell(photo: photo, model: model)
            }
        }
    }

    private var categories: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
            ForEach(SynologyPhotoCategory.allCases.filter { model.availableCategories.contains($0) }, id: \.self) { category in
                Button { Task { await model.openCategory(category) } } label: {
                    VStack(alignment: .leading, spacing: 14) {
                        Image(systemName: categorySymbol(category)).font(.title2).foregroundStyle(.tint)
                        Text(categoryTitle(category)).font(.callout.weight(.medium))
                    }
                    .frame(maxWidth: .infinity, minHeight: 94, alignment: .leading).padding(16)
                    .mobileGlass(.card)
                }.buttonStyle(.plain)
            }
        }
    }

    private var collections: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], spacing: 8) {
            ForEach(model.collections) { collection in
                Button { Task { await model.open(collection) } } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: model.section == .folders ? "folder.fill" : "rectangle.stack.fill")
                            .font(.largeTitle).foregroundStyle(.tint)
                        Text(collection.name).font(.callout.weight(.medium)).lineLimit(2)
                        if let count = collection.itemCount {
                            Text(count.formatted(.number.locale(L10n.locale))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading).padding(16).mobileGlass(.card)
                }.buttonStyle(.plain)
            }
        }
    }

    private var sharing: some View {
        ForEach(model.sharedEntries) { entry in
            HStack {
                if entry.albumID != nil {
                    Button { Task { await model.openSharedAlbum(entry) } } label: {
                        Label(entry.title, systemImage: "person.2.crop.square.stack")
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.buttonStyle(.plain)
                } else {
                    Label(entry.title, systemImage: "link")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                if let url = entry.url {
                    ShareLink(item: url) {
                        Image(systemName: "square.and.arrow.up").frame(minWidth: 44, minHeight: 44)
                    }.accessibilityLabel(L10n.string("parity.photos.shareLink"))
                }
            }.padding(12).mobileGlass(.card)
        }
    }

    @ViewBuilder private var pagination: some View {
        if model.isLoadingMore {
            ProgressView().frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityLabel(L10n.string("photos.library.more"))
        } else if model.hasMore || model.hasMoreCollections {
            Button(L10n.string(model.hasMoreCollections ? "photos.library.moreCollections" : "photos.library.more")) {
                Task { await model.retryCurrentPage() }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .task(id: model.paginationIdentity) { await model.loadNextPageAutomatically() }
        }
    }

    private var monthPicker: some View {
        NavigationStack {
            List(model.timelineMonths) { month in
                Button {
                    showsMonths = false
                    Task { await model.jumpToMonth(month) }
                } label: {
                    HStack {
                        Text(month.date?.formatted(.dateTime.year().month(.wide).locale(L10n.locale)) ?? "")
                        Spacer()
                        if model.selectedTimelineMonthID == month.id { Image(systemName: "checkmark") }
                    }.frame(minHeight: 44)
                }
            }
            .navigationTitle(L10n.string("photos.timeline.navigator"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("photos.media.close")) { showsMonths = false }
                }
            }
            .mobileAppearanceRoot()
        }.presentationDetents([.medium, .large])
    }

    private func shareTitle(_ scope: SynologyPhotoShareScope) -> String {
        switch scope {
        case .withMe: L10n.string("photos.sharing.withMe")
        case .withOthers: L10n.string("photos.sharing.withOthers")
        case .requests: L10n.string("photos.sharing.requests")
        }
    }

    private func categoryTitle(_ category: SynologyPhotoCategory) -> String {
        switch category {
        case .recentlyAdded: L10n.string("photos.category.recentlyAdded")
        case .person: L10n.string("photos.category.person")
        case .concept: L10n.string("photos.category.concept")
        case .location: L10n.string("photos.category.location")
        case .tags: L10n.string("photos.category.tags")
        case .videos: L10n.string("photos.category.videos")
        }
    }

    private func categorySymbol(_ category: SynologyPhotoCategory) -> String {
        switch category {
        case .recentlyAdded: "clock"
        case .person: "person.2"
        case .concept: "sparkles"
        case .location: "mappin.and.ellipse"
        case .tags: "tag"
        case .videos: "play.rectangle"
        }
    }
}

private struct MobileSynologyPhotoCell: View {
    let photo: SynologyPhoto
    let model: MobileSynologyPhotosModel
    @State private var image: UIImage?
    @State private var failed = false
    private var identity: String {
        "\(photo.id.profileID)|\(photo.id.space.rawValue)|\(photo.id.unitID)|\(photo.thumbnail?.revision ?? "")"
    }

    var body: some View {
        Button { model.showPreview(photo) } label: {
            ZStack(alignment: .bottomLeading) {
                Color.secondary.opacity(0.10)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if failed {
                    Image(systemName: "photo.badge.exclamationmark").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if photo.mediaType == "video" || photo.mediaType == "live" {
                    Label(L10n.string(photo.mediaType == "live" ? "photos.live" : "photos.category.videos"),
                        systemImage: photo.mediaType == "live" ? "livephoto" : "play.fill")
                        .font(.caption2.weight(.semibold)).padding(5)
                        .background(.regularMaterial, in: Capsule()).padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.string("mobile.photos.open-photo", photo.filename))
        .contextMenu {
            Button(L10n.string("photos.media.open")) { model.showPreview(photo) }
            Button(L10n.string("photos.media.save")) { model.prepareExport(photo, intent: .exportCopy) }
            Button(L10n.string("mobile.photos.action.share")) { model.prepareExport(photo, intent: .share) }
        }
        .task(id: identity) {
            image = nil; failed = false
            do {
                let data = try await model.thumbnail(photo)
                let decoded = await MobileSynologyImageDecoder.image(data, maximumPixelSize: 480)
                guard !Task.isCancelled else { return }
                image = decoded; failed = decoded == nil
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
        .onDisappear { image = nil }
    }
}

enum MobileSynologyImageDecoder {
    static func image(_ data: Data, maximumPixelSize: Int) async -> UIImage? {
        guard !data.isEmpty, data.count <= 32 * 1_024 * 1_024 else { return nil }
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  !Task.isCancelled else { return nil }
            return UIImage(cgImage: image)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

struct MobilePhotosExportSheet: View {
    let presentation: MobileDocumentPresentation
    let completion: () -> Void
    var body: some View {
        if presentation.intent == .share {
            MobileShareSheet(url: presentation.url, completion: completion)
        } else {
            MobileDocumentExporter(url: presentation.url, completion: completion)
        }
    }
}
