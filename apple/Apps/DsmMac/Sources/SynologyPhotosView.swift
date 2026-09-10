import AppKit
import AVKit
import DsmCore
import DsmLocalization
import SwiftUI

struct SynologyPhotosView: View {
    @Bindable var model: SynologyPhotosModel
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
                }
                ForEach(SynologyPhotosSection.allCases, id: \.self) { section in
                    Button(section.title) {
                        if let onSectionChange { onSectionChange(section) }
                        else { Task { await model.selectSection(section) } }
                    }.buttonStyle(MacToolbarButtonStyle(selected: model.section == section))
                }
                Spacer(minLength: 12)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L10n.string("photos.library.search"), text: $model.searchText)
                        .textFieldStyle(.plain)
                        .onSubmit { Task { await model.refresh() } }
                }
                .padding(.horizontal, 10).frame(minWidth: 140, idealWidth: 230, maxWidth: 280).frame(height: 36)
                .background(palette.searchField, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(contrast == .increased ? 0.55 : 0.25), lineWidth: 1))
                .disabled(model.filter.isActive || model.section == .sharing)
                .help(L10n.string("photos.filters.searchHint"))
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
            if let title = model.selectedCategoryItem?.name ?? model.selectedCategory?.title ?? model.selectedAlbum?.name ?? (model.folderHistory.count > 1 ? model.folderHistory.last?.name : nil) {
                Text(title).font(.headline).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 8)
            }
            if model.section == .sharing, model.selectedAlbum == nil {
                HStack {
                    ForEach(SynologyPhotoShareScope.allCases, id: \.self) { scope in
                        Button(scope.title) { Task { await model.selectShareScope(scope) } }
                            .buttonStyle(MacToolbarButtonStyle(selected: model.shareScope == scope))
                    }
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
                }
            }
            if model.isSaving { ProgressView(value: model.saveProgress).padding(.horizontal) }
            if let message = model.saveMessage { Text(message).font(.callout).foregroundStyle(.secondary).padding(8) }
            if model.isDeleting || model.isCheckingDeletion { ProgressView().controlSize(.small).padding(8) }
            if let message = model.deletionMessage {
                HStack {
                    Text(message).font(.callout)
                    if model.pendingDeletionPhoto != nil {
                        Button(L10n.string("photos.delete.review")) { Task { await model.reviewPendingDeletion() } }.disabled(model.isDeleting)
                    }
                }.padding(8)
            }
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .background(MacGlassSurface(role: .content))
        .task { await model.loadIfNeeded() }
        .onDisappear { model.cancel() }
        .alert(L10n.string("photos.delete.title"), isPresented: Binding(get: { model.deletionCandidate != nil }, set: { if !$0 { model.deletionCandidate = nil } })) {
            Button(L10n.string("photos.delete.cancel"), role: .cancel) { model.deletionCandidate = nil }
            if let photo = model.deletionCandidate {
                Button(L10n.string("photos.delete.action"), role: .destructive) { model.confirmDeletion(photo) }
            }
        } message: {
            Text(L10n.string("photos.delete.confirm", model.deletionCandidate?.filename ?? ""))
        }
        .alert(L10n.string("photos.delete.title"), isPresented: Binding(get: { model.deletionError != nil }, set: { if !$0 { model.deletionError = nil } })) {
            Button(L10n.string("photos.media.close"), role: .cancel) { model.deletionError = nil }
        } message: { Text(model.deletionError ?? "") }
        .sheet(isPresented: Binding(get: { model.previewPhoto != nil }, set: { if !$0 { model.closePreview() } })) {
            SynologyPhotoPreview(model: model)
        }
    }
    @ViewBuilder private var galleryContent: some View {
            if model.isLoading {
                ProgressView().fillsAvailableContentArea()
            } else if model.items.isEmpty && model.collections.isEmpty && !model.showsCategories && model.sharedEntries.isEmpty {
                ContentUnavailableView {
                    Label(L10n.string(model.errorMessage == nil ? "photos.empty.title" : "photos.error.title"), systemImage: "photo.on.rectangle")
                } description: {
                    Text(model.errorMessage ?? L10n.string(model.section == .sharing ? "photos.sharing.empty" : (model.isFiltering ? "photos.library.noResults" : "photos.library.empty")))
                } actions: {
                    Button(L10n.string("photos.library.refresh")) { Task { await model.refresh() } }
                }
                .fillsAvailableContentArea()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if model.showsCategories {
                            LazyVGrid(columns: columns, spacing: 8) {
                                ForEach(SynologyPhotoCategory.allCases.filter { model.availableCategories.contains($0) }, id: \.self) { category in
                                    Button { Task { await model.openCategory(category) } } label: {
                                        VStack(spacing: 12) {
                                            Image(systemName: category.symbol).font(.system(size: 32)).foregroundStyle(.tint)
                                            Text(category.title).font(.headline)
                                        }
                                        .frame(maxWidth: .infinity).frame(height: 145)
                                        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        ForEach(model.sharedEntries) { entry in
                            HStack {
                                Button(entry.title) { Task { await model.openSharedAlbum(entry) } }.disabled(entry.albumID == nil)
                                Spacer()
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
                                    Button { Task { await model.open(collection) } } label: {
                                        VStack(spacing: 10) {
                                            Image(systemName: model.section == .folders ? "folder.fill" : "rectangle.stack.fill").font(.system(size: 36)).foregroundStyle(.tint)
                                            Text(collection.name).lineLimit(2)
                                        }
                                        .frame(maxWidth: .infinity).frame(height: 150)
                                        .background(palette.card, in: RoundedRectangle(cornerRadius: 10))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                        if model.showsTimeline {
                            ForEach(model.datedGroups, id: \.date) { group in
                                Text(group.date.formatted(.dateTime.year().month().day().locale(L10n.locale)))
                                    .font(.headline).accessibilityAddTraits(.isHeader)
                                photoGrid(group.photos)
                            }
                        } else { photoGrid(model.items) }
                        if let message = model.errorMessage {
                            Text(message).foregroundStyle(.secondary)
                            Button(L10n.string("photos.retry")) {
                                Task {
                                    if model.hasMoreCollections { await model.loadMoreCollections() }
                                    else { await model.loadMore() }
                                }
                            }.buttonStyle(MacToolbarButtonStyle())
                        } else if model.hasMore || model.hasMoreCollections {
                            ProgressView().frame(maxWidth: .infinity).padding()
                                .id(model.paginationIdentity)
                                .task { await model.loadNextPageAutomatically() }
                        }
                    }.padding(16)
                }
            }

    }

    private var columns: [GridItem] { [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 8)] }

    private func photoGrid(_ photos: [SynologyPhoto]) -> some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(photos) { photo in
                Button { model.showPreview(photo) } label: { SynologyPhotoCell(photo: photo, model: model) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(L10n.string("photos.media.open")) { model.showPreview(photo) }
                        Button(L10n.string("photos.media.save")) { savePhoto(photo, model: model) }.disabled(model.isSaving)
                        Button(L10n.string("photos.delete.action"), role: .destructive) { model.requestDeletion(photo) }
                            .disabled(model.isDeleting || model.isCheckingDeletion || model.pendingDeletionPhoto != nil)
                    }
            }
        }
    }

}

@MainActor
private func savePhoto(_ photo: SynologyPhoto, model: SynologyPhotosModel) {
    let panel = NSSavePanel()
    panel.title = L10n.string("photos.media.save")
    panel.nameFieldStringValue = (photo.filename as NSString).lastPathComponent
    if panel.runModal() == .OK, let url = panel.url { model.save(photo, to: url) }
}

struct SynologyPhotoPreview: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var showsInfo = false
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
                Button { model.adjacentPreview(-1) } label: { Label(L10n.string("photos.media.previous"), systemImage: "chevron.left") }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button { model.adjacentPreview(1) } label: { Label(L10n.string("photos.media.next"), systemImage: "chevron.right") }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button { showsInfo.toggle() } label: { Label(L10n.string("photos.media.info"), systemImage: "info.circle") }
                if let photo = model.previewPhoto {
                    Button { savePhoto(photo, model: model) } label: { Label(L10n.string("photos.media.save"), systemImage: "square.and.arrow.down") }
                        .disabled(model.isSaving)
                    Button {
                        model.closePreview()
                        model.requestDeletion(photo)
                    } label: { Label(L10n.string("photos.delete.action"), systemImage: "trash") }
                        .disabled(model.isDeleting || model.isCheckingDeletion || model.pendingDeletionPhoto != nil)
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
                        if model.previewPhoto?.mediaType == "live" {
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
                        VideoPlayerView(source: source, onDownload: { if let photo = model.previewPhoto { savePhoto(photo, model: model) } })
                    } else {
                        ContentUnavailableView {
                            Label(L10n.string("photos.media.open"), systemImage: "photo")
                        } description: { Text(model.previewError ?? L10n.string("photos.media.failed")) }
                        actions: { Button(L10n.string("photos.retry")) { if let photo = model.previewPhoto { model.showPreview(photo) } } }
                    }
                }.fillsAvailableContentArea()
                if showsInfo, let photo = model.previewPhoto {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(photo.filename).font(.headline).textSelection(.enabled)
                            detailRow("photos.detail.taken", photo.takenAt.formatted(.dateTime.locale(L10n.locale)))
                            detailRow("photos.detail.added", photo.indexedAt.formatted(.dateTime.locale(L10n.locale)))
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
            if model.isSaving { ProgressView(value: model.saveProgress).padding(.horizontal) }
            if let message = model.saveMessage { Text(message).font(.callout).padding(8) }
        }
        .frame(minWidth: 820, idealWidth: 1000, minHeight: 600, idealHeight: 720)
        .background(MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).content)
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

/// Live Photo 的视频在原图区域播放一次，结束或失败恢复静态图。
private struct PhotoMotionPlayer: NSViewRepresentable {
    let source: MediaStreamSource
    let onFinished: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinished: onFinished) }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer()
        layer.videoGravity = .resizeAspectFill
        layer.masksToBounds = true
        view.layer = layer
        context.coordinator.start(source, layer: layer)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.stop() }

    @MainActor final class Coordinator {
        private var loader: DsmAVAssetResourceLoaderDelegate?
        private var player: AVPlayer?
        private var endObserver: NSObjectProtocol?
        private var active = false
        private let onFinished: () -> Void
        init(onFinished: @escaping () -> Void) { self.onFinished = onFinished }
        func start(_ source: MediaStreamSource, layer: AVPlayerLayer) {
            active = true
            let loader = DsmAVAssetResourceLoaderDelegate(source: source, onFailure: { [weak self] _ in
                Task { @MainActor in if self?.active == true { self?.onFinished() } }
            }, onLoadingMetrics: { _, _ in })
            self.loader = loader
            let asset = AVURLAsset(url: URL(string: "lanstash-media://motion/\(UUID().uuidString).mov")!)
            asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "lanstash.photos.motion"))
            let item = AVPlayerItem(asset: asset)
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                Task { @MainActor in if self?.active == true { self?.onFinished() } }
            }
            let player = AVPlayer(playerItem: item)
            self.player = player
            layer.player = player
            player.play()
        }
        func stop() {
            active = false
            player?.pause()
            player = nil
            loader?.cancelAll()
            loader = nil
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
            endObserver = nil
        }
    }
}

private struct SynologyPhotoCell: View {
    let photo: SynologyPhoto
    let model: SynologyPhotosModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var image: NSImage?

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
        .accessibilityLabel(photo.filename)
        .task(id: photo.thumbnail) {
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
