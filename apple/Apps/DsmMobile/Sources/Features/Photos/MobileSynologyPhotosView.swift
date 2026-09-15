import DsmCore
import DsmLocalization
import SwiftUI
import UIKit

/// Photos 正式入口；旧 File Station 浏览器不参与本页面的加载或错误恢复。
struct MobileSynologyPhotosView: View {
    @Bindable var model: MobileSynologyPhotosModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsMonths = false

    var body: some View {
        HStack(spacing: 0) {
            if sizeClass == .regular {
                List(MobileSynologyPhotosSection.allCases, id: \.self) { section in
                    Button {
                        model.navigate { await model.selectSection(section) }
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .listRowBackground(model.section == section ? Color.accentColor.opacity(0.12) : Color.clear)
                    .accessibilityAddTraits(model.section == section ? .isSelected : [])
                }
                .listStyle(.sidebar)
                .frame(minWidth: 180, idealWidth: 210, maxWidth: 250)
                Divider()
            }
            VStack(spacing: 0) {
                if sizeClass != .regular { compactNavigation }
                if model.canGoBack { backButton }
                if model.section == .sharing, model.selectedAlbum == nil { sharingScopes }
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(model.selectedAlbum?.name ?? model.selectedCategoryItem?.name ?? model.selectedCategory?.title ?? model.section.title)
        .searchable(text: $model.searchText, prompt: L10n.string("photos.library.search"))
        .onSubmit(of: .search) { model.navigate { await model.submitSearch() } }
        .toolbar { toolbar }
        .task {
            model.setModuleEnabled(true)
            await model.loadIfNeeded()
        }
        .onDisappear { model.cancel() }
        .sheet(isPresented: $model.showsFilters) {
            MobileSynologyPhotoFilterView(model: model, draft: model.filter)
        }
        .sheet(isPresented: $showsMonths) { monthPicker }
        .sheet(item: $model.previewPhoto, onDismiss: model.closePreview) { _ in
            MobileSynologyPhotoPreview(model: model)
        }
        .sheet(isPresented: exportBinding, onDismiss: model.cancelExport) {
            if let url = model.exportURL {
                MobileShareSheet(url: url, completion: model.cancelExport)
            }
        }
        .confirmationDialog(L10n.string("photos.delete.title"), isPresented: deletionBinding, titleVisibility: .visible) {
            if let photo = model.deletionCandidate {
                Button(L10n.string("photos.delete.action"), role: .destructive) { model.confirmDeletion(photo) }
            }
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { model.deletionCandidate = nil }
        } message: {
            Text(L10n.string("photos.delete.confirm", model.deletionCandidate?.filename ?? ""))
        }
    }

    private var compactNavigation: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(MobileSynologyPhotosSection.allCases, id: \.self) { section in
                    Button {
                        model.navigate { await model.selectSection(section) }
                    } label: {
                        Label(section.title, systemImage: section.symbol)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .frame(minHeight: 44)
                            .background(model.section == section ? Color.accentColor.opacity(0.12) : Color.clear, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.section == section ? .isSelected : [])
                }
            }.padding(.horizontal)
        }.padding(.vertical, 4)
    }

    private var backButton: some View {
        Button {
            model.navigate { await model.goBack() }
        } label: {
            Label(L10n.string("photos.library.back"), systemImage: "chevron.backward")
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .padding(.horizontal)
        .keyboardShortcut("[", modifiers: .command)
    }

    private var sharingScopes: some View {
        Picker(L10n.string("photos.sharing"), selection: Binding(
            get: { model.shareScope },
            set: { scope in model.navigate { await model.selectShareScope(scope) } }
        )) {
            ForEach(SynologyPhotoShareScope.allCases, id: \.self) { scope in
                Text(scope.title).tag(scope)
            }
        }
        .pickerStyle(.menu)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .padding(.horizontal)
    }

    @ViewBuilder private var content: some View {
        if model.isLoading, model.items.isEmpty, model.collections.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage, model.items.isEmpty, model.collections.isEmpty, model.sharedEntries.isEmpty {
            ContentUnavailableView {
                Label(L10n.string("photos.error.title"), systemImage: "exclamationmark.triangle")
            } description: { Text(error) } actions: {
                Button(L10n.string("photos.retry")) { model.navigate { await model.refresh() } }
                    .buttonStyle(.borderedProminent).frame(minHeight: 44)
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        feedback
                        if model.hasPrevious {
                            Button {
                                let anchor = model.items.first?.id
                                Task {
                                    await model.loadPreviousPage()
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            } label: {
                                HStack {
                                    if model.isLoadingPrevious { ProgressView() }
                                    Text(L10n.string(model.previousPageErrorMessage == nil ? "photos.library.more" : "photos.retry"))
                                }.frame(maxWidth: .infinity, minHeight: 44)
                            }.disabled(model.isLoadingPrevious)
                            if let error = model.previousPageErrorMessage { Text(error).foregroundStyle(.secondary) }
                        }
                        if model.showsCategories {
                            LazyVGrid(columns: columns, spacing: 12) {
                                ForEach(SynologyPhotoCategory.allCases.filter { model.availableCategories.contains($0) }, id: \.self) { category in
                                    Button {
                                        model.navigate { await model.openCategory(category) }
                                    } label: {
                                        Label(category.title, systemImage: category.symbol)
                                            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                                            .padding(12)
                                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        ForEach(model.collections) { collection in
                            Button {
                                model.navigate { await model.open(collection) }
                            } label: {
                                HStack {
                                    Image(systemName: model.section == .folders ? "folder" : "photo.on.rectangle")
                                    Text(collection.name).frame(maxWidth: .infinity, alignment: .leading)
                                    if let count = collection.itemCount { Text(count, format: .number).foregroundStyle(.secondary) }
                                    Image(systemName: "chevron.forward").accessibilityHidden(true)
                                }.frame(minHeight: 44)
                            }.buttonStyle(.plain)
                        }
                        ForEach(model.sharedEntries) { entry in
                            HStack {
                                if entry.albumID != nil {
                                    Button(entry.title) { model.navigate { await model.openSharedAlbum(entry) } }
                                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                } else {
                                    Text(entry.title).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                if let url = entry.url {
                                    ShareLink(item: url) { Label(L10n.string("mobile.photos.action.share"), systemImage: "square.and.arrow.up") }
                                        .frame(minWidth: 44, minHeight: 44)
                                }
                            }
                        }
                        if model.showsTimeline {
                            ForEach(model.datedGroups) { group in
                                Text(group.date, format: .dateTime.year().month().day().locale(L10n.locale))
                                    .font(.headline).accessibilityAddTraits(.isHeader)
                                photoGrid(group.photos)
                            }
                        } else { photoGrid(model.items) }
                        if isEmpty {
                            ContentUnavailableView {
                                Label(L10n.string("photos.empty.title"), systemImage: "photo.on.rectangle")
                            } description: { Text(emptyMessage) } actions: {
                                Button(L10n.string("photos.library.refresh")) { model.navigate { await model.refresh() } }
                                    .frame(minHeight: 44)
                            }
                        }
                        if model.hasMore || model.hasMoreCollections {
                            Button {
                                Task { await loadMore() }
                            } label: {
                                HStack {
                                    if model.isLoadingMore { ProgressView() }
                                    Text(L10n.string(model.errorMessage == nil ? "photos.library.moreCollections" : "photos.retry"))
                                }.frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .disabled(model.isLoadingMore)
                            .task(id: model.paginationIdentity) { await model.loadNextPageAutomatically() }
                        }
                    }.padding()
                }
                .refreshable { await model.refresh() }
            }
        }
    }

    @ViewBuilder private var feedback: some View {
        if let error = model.errorMessage { Text(error).foregroundStyle(.secondary) }
        if let error = model.deletionError { Text(error).foregroundStyle(.secondary) }
        if let message = model.deletionMessage { Text(message).foregroundStyle(.secondary) }
        if let message = model.saveMessage { Text(message).foregroundStyle(.secondary) }
        if model.isSaving {
            HStack {
                ProgressView(value: model.saveProgress)
                Button(L10n.string("photos.delete.cancel"), action: model.cancelExport).frame(minHeight: 44)
            }
        }
        if model.pendingDeletionPhoto != nil {
            Button(L10n.string("photos.delete.review")) { Task { await model.reviewPendingDeletion() } }
                .frame(minHeight: 44).disabled(model.isDeleting)
        }
    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: sizeClass == .regular ? 150 : 110), spacing: 8)] }
    private var isEmpty: Bool { model.hasLoaded && model.items.isEmpty && model.collections.isEmpty && model.sharedEntries.isEmpty && !model.showsCategories }
    private var emptyMessage: String {
        L10n.string(model.isFiltering ? "photos.library.noResults" : model.section == .sharing ? "photos.sharing.empty" : model.section == .albums ? "photos.library.noAlbums" : "photos.library.empty")
    }

    private func photoGrid(_ photos: [SynologyPhoto]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(photos) { photo in
                MobileSynologyPhotoCell(photo: photo, model: model)
                    .id(photo.id)
                    .contextMenu {
                        Button(L10n.string("photos.media.open")) { model.showPreview(photo) }
                        Button(L10n.string("photos.media.save")) { model.prepareExport(photo) }.disabled(model.isSaving)
                        Button(L10n.string("photos.delete.action"), role: .destructive) { model.requestDeletion(photo) }
                            .disabled(!model.canDeleteOriginals || model.isDeleting || model.pendingDeletionPhoto != nil)
                    }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if !model.timelineMonths.isEmpty {
                Button { showsMonths = true } label: { Image(systemName: "calendar") }
                    .accessibilityLabel(L10n.string("photos.timeline.navigator"))
            }
            Button { model.showsFilters = true } label: { Image(systemName: model.filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") }
                .accessibilityLabel(L10n.string("photos.filters"))
            Button { model.navigate { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .accessibilityLabel(L10n.string("photos.library.refresh"))
                .keyboardShortcut("r", modifiers: .command)
        }
    }

    private var monthPicker: some View {
        NavigationStack {
            List(model.timelineMonths) { month in
                if let date = month.date {
                    Button {
                        showsMonths = false
                        model.navigate { await model.jumpToMonth(month) }
                    } label: {
                        Text(date, format: .dateTime.year().month(.wide).locale(L10n.locale))
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .accessibilityAddTraits(model.selectedTimelineMonthID == month.id ? .isSelected : [])
                }
            }
            .navigationTitle(L10n.string("photos.timeline.navigator"))
            .toolbar { Button(L10n.string("photos.media.close")) { showsMonths = false } }
        }
    }

    private var deletionBinding: Binding<Bool> {
        Binding(get: { model.deletionCandidate != nil }, set: { if !$0 { model.deletionCandidate = nil } })
    }
    private var exportBinding: Binding<Bool> {
        Binding(get: { model.exportURL != nil && model.previewPhoto == nil }, set: { if !$0 { model.cancelExport() } })
    }
    private func loadMore() async {
        if model.hasMoreCollections { await model.loadMoreCollections() } else { await model.loadMore() }
    }
}

extension MobileSynologyPhotosSection {
    var symbol: String {
        switch self {
        case .timeline: "clock"
        case .folders: "folder"
        case .albums: "rectangle.stack"
        case .sharing: "person.2"
        }
    }
}

extension SynologyPhotoCategory {
    var title: String { L10n.string("photos.category.\(rawValue)") }
    var symbol: String {
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
    var title: String { L10n.string("photos.sharing.\(rawValue)") }
}
