import AppKit
import DsmCore
import SwiftUI
import DsmLocalization

struct PhotoLibraryView: View {
    @Bindable var model: PhotoLibraryModel
    let onPreview: (PhotoLibraryItem) -> Void
    let onDownload: ([PhotoLibraryItem]) -> Void
    let onDelete: ([PhotoLibraryItem]) -> Void
    let onRestore: (PhotoLibraryItem) -> Void
    let onMove: (PhotoLibraryItem, String) -> Void
    let onBrowseModeChange: @MainActor @Sendable (PhotoBrowseMode) -> Void

    @State private var timelineScrollTarget: Date?
    @State private var moveTarget: PhotoLibraryItem?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    private let columns = [
        GridItem(.adaptive(minimum: 140, maximum: 180), spacing: 12, alignment: .top)
    ]

    private struct YearMonth: Identifiable, Hashable {
        let id: Date
        let title: String
    }

    private var timelineYearMonths: [YearMonth] {
        guard model.browseMode == .timeline, !model.timelineSections.isEmpty else { return [] }
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: model.timelineSections) { section in
            calendar.dateComponents([.year, .month], from: section.date)
        }
        let sorted = grouped.values.compactMap { sections -> YearMonth? in
            let sortedSections = sections.sorted { $0.date < $1.date }
            guard let first = sortedSections.first else { return nil }
            let title = first.date.formatted(
                Date.FormatStyle()
                    .year()
                    .month(.wide)
                    .locale(L10n.locale)
            )
            return YearMonth(id: first.date, title: title)
        }
        return sorted.sorted { $0.id < $1.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if shouldShowTimelineScanStatus {
                timelineScanStatus
                Divider()
            }
            content
        }
        .fillsAvailableContentArea(alignment: .topLeading)
        .task { await model.loadIfNeeded() }
        .macSheet(item: $moveTarget) { item in
            PhotoFolderDestinationPicker(
                repository: model.photoRepository,
                profileID: model.activeProfileID,
                sourcePath: item.path,
                onSelect: { destinationPath in
                    moveTarget = nil
                    onMove(item, destinationPath)
                },
                onCancel: {
                    moveTarget = nil
                }
            )
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if model.browseMode == .albums, !isAlbumsRoot {
                    Label(titleText, systemImage: titleIcon)
                        .font(.headline)
                        .lineLimit(1)
                }
                MacPageTabs(options: [PhotoBrowseMode.timeline, .albums], selection: browseModeSelection, title: {
                    $0 == .timeline ? L10n.string("ui.f1241a97b0821a99") : L10n.string("ui.38793c1c1c23437e")
                })
                .frame(maxWidth: 240)
                Spacer(minLength: 8)
                spacePicker
            }
            filterBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(MacGlassSurface(role: .toolbar))
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            mediaStatsBadge

            if model.browseMode == .timeline, !timelineYearMonths.isEmpty {
                Menu {
                    ForEach(timelineYearMonths) { yearMonth in
                        Button(yearMonth.title) {
                            timelineScrollTarget = yearMonth.id
                        }
                    }
                } label: {
                    Label(L10n.string("ui.70d0c1b33626ba4b"), systemImage: "calendar")
                }
                .help(L10n.string("ui.5473ed3722c21e8c"))
            }

            Spacer()

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(L10n.string("ui.02fd538b5510e8ba"), text: $model.searchText)
                    .textFieldStyle(.plain)
                    .frame(minWidth: 100, idealWidth: 180, maxWidth: 240)
                if !model.searchText.isEmpty {
                    Button(L10n.string("ui.ee32f25f70508f9c"), systemImage: "xmark.circle.fill") {
                        model.searchText = ""
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 36)
            .background(MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).searchField, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).separator))

            Menu {
                Picker(L10n.string("ui.296225a8ac50bbe9"), selection: $model.mediaFilter) {
                    Label(L10n.string("ui.5c55a67935af8f45"), systemImage: "photo.on.rectangle.angled").tag(PhotoMediaFilter.all)
                    Label(L10n.string("ui.7b50017ae47eca32"), systemImage: "photo").tag(PhotoMediaFilter.images)
                    Label(L10n.string("ui.c20f7618d330a854"), systemImage: "video").tag(PhotoMediaFilter.videos)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(mediaFilterTitle, systemImage: "line.3.horizontal.decrease.circle")
            }
            .help(L10n.string("ui.9577c61b76be01e6"))
        }
        .buttonStyle(MacToolbarButtonStyle())
    }

    @ViewBuilder
    private var spacePicker: some View {
        if model.spaces.count > 1 {
            Picker(L10n.string("ui.afbc722b9ad55bef"), selection: spaceSelection) {
                ForEach(model.spaces) { space in
                    Text(space.title).tag(Optional(space.id))
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)
            .accessibilityHint(L10n.string("ui.3e5a89a799968aab"))
        } else if let space = model.selectedSpace {
            Text(space.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var mediaStatsBadge: some View {
        let stats = model.mediaStats
        let isAlbumsRoot = model.browseMode == .albums && model.currentPath == model.selectedSpace?.rootPath
        return HStack(spacing: 5) {
            Label {
                Text("\(Self.formattedNumber(stats.total))")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: isAlbumsRoot ? "rectangle.stack.fill" : "photo.stack.fill")
                    .foregroundStyle(Color.accentColor)
            }

            if !isAlbumsRoot {
                Text("(")
                    .foregroundStyle(.secondary.opacity(0.6))

                Label("\(Self.formattedNumber(stats.images))", systemImage: "photo")
                    .foregroundStyle(.secondary)

                Text("·")
                    .foregroundStyle(.secondary.opacity(0.6))

                Label("\(Self.formattedNumber(stats.videos))", systemImage: "video")
                    .foregroundStyle(.secondary)

                Text(")")
                    .foregroundStyle(.secondary.opacity(0.6))
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.55), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isAlbumsRoot
                ? L10n.string("photo.albums.count", String(stats.total))
                : L10n.string("ui.7629e90c4abacf06", String(describing: stats.total), String(describing: stats.images), String(describing: stats.videos))
        )
    }

    private static func formattedNumber(_ number: Int) -> String {
        number.formatted(.number.locale(L10n.locale))
    }

    @ViewBuilder
    private var content: some View {
        if (model.isLoadingTimeline || (model.browseMode == .timeline && model.isSyncingTimeline)) && model.displayedItems.isEmpty {
            VStack(spacing: 0) {
                Spacer().frame(height: 36)
                timelineLoadingState
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if model.isLoading && model.displayedItems.isEmpty {
            loadingGrid
        } else if model.spaces.isEmpty {
            VStack(spacing: 0) {
                Spacer().frame(height: 36)
                ContentUnavailableView {
                    Label(L10n.string("ui.8c1040ae852de1b8"), systemImage: "photo.badge.exclamationmark")
                } description: {
                    Text(model.errorMessage ?? L10n.string("ui.c9e8421e4283b968"))
                } actions: {
                    Button(L10n.string("ui.c25fb86b1e96e063")) { Task { await model.reloadSpaces() } }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if let errorMessage = model.errorMessage, model.displayedItems.isEmpty {
            VStack(spacing: 0) {
                Spacer().frame(height: 36)
                ContentUnavailableView {
                    Label(L10n.string("ui.6d0edd7c46b17a50"), systemImage: "exclamationmark.triangle")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button(L10n.string("ui.049019b1718726b4")) { Task { await model.refreshAll() } }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else if model.displayedItems.isEmpty {
            VStack(spacing: 0) {
                Spacer().frame(height: 36)
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: model.searchText.isEmpty ? "photo" : "magnifyingglass")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    if !model.searchText.isEmpty || model.mediaFilter != .all {
                        Button(L10n.string("ui.657d9cbf45ec9e6a")) {
                            model.searchText = ""
                            model.mediaFilter = .all
                        }
                    } else {
                        Button(L10n.string("ui.049019b1718726b4")) { Task { await model.refreshAll() } }
                    }
                }
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    if let errorMessage = model.errorMessage {
                        errorBanner(errorMessage)
                    }

                    if model.timelineSkippedFolderCount > 0 || model.isRetryingTimelineFolders {
                        timelineNoticeBanner
                    }

                    if model.browseMode == .timeline {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            ForEach(model.timelineSections) { section in
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(section.title)
                                        .font(.headline)
                                        .accessibilityAddTraits(.isHeader)
                                    photoGrid(section.items)
                                }
                                .id(section.date)
                            }
                        }
                        .padding(16)
                    } else {
                        photoGrid(model.displayedItems)
                            .padding(16)
                    }

                    if model.isLoadingMore {
                        ProgressView(L10n.string("ui.b88bf6169458eaa4"))
                            .controlSize(.small)
                            .padding(.bottom, 20)
                    }
                }
                .onChange(of: timelineScrollTarget) { _, target in
                    guard let target else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                }
            }
        }
    }

    private var shouldShowTimelineScanStatus: Bool {
        model.browseMode == .timeline
            && (model.isLoadingTimeline || model.isSyncingTimeline)
            && !model.timelineItems.isEmpty
    }

    private var timelineScanStatus: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(
                    L10n.string("ui.6185e0d22d3da633", String(describing: model.timelineItems.count), String(describing: model.timelineScannedFolderCount))
                )

            Text(L10n.string("ui.23779fefc94e1de7"))
                .font(.callout.weight(.medium))
                .accessibilityHidden(true)

            Text(L10n.string("ui.a538265360dc44d0", String(describing: model.timelineItems.count), String(describing: model.timelineScannedFolderCount)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            Spacer(minLength: 8)

            Button(L10n.string("ui.e2aeadd63577f274")) {
                Task { await model.setBrowseMode(.albums) }
            }
            .buttonStyle(.borderless)
            .accessibilityHint(L10n.string("ui.7d6a5cb47b1fa8e5"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.35))
    }

    private var timelineLoadingState: some View {
        ContentUnavailableView {
            ProgressView()
                .controlSize(.large)
                .accessibilityLabel(L10n.string("ui.ebb0d72d354707bf"))
        } description: {
            VStack(spacing: 6) {
                Text(L10n.string("ui.3f3cf898ac905890"))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(L10n.string("ui.bdb069423b2a44ce", String(describing: model.timelineScannedFolderCount)))
            }
        } actions: {
            Button(L10n.string("ui.e2aeadd63577f274")) {
                Task { await model.setBrowseMode(.albums) }
            }
        }
    }

    private func photoGrid(_ items: [PhotoLibraryItem]) -> some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { item in
                PhotoLibraryCell(
                    model: model,
                    item: item,
                    isSelected: model.selection.contains(item.id),
                    onPreview: onPreview,
                    onDownload: onDownload,
                    onDelete: onDelete,
                    onRestore: onRestore,
                    onMove: { moveTarget = $0 }
                )
                .task {
                    if model.browseMode == .albums, item.id == model.displayedItems.last?.id {
                        await model.loadMore()
                    }
                }
            }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .accessibilityAddTraits(.isStaticText)
    }

    private var timelineNoticeBanner: some View {
        HStack(spacing: 12) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    if model.isRetryingTimelineFolders {
                        Text(L10n.string("ui.c3415704fad83ce7"))
                    } else {
                        Text(L10n.string("ui.e6e3e7422369a608", String(describing: model.timelineSkippedFolderCount)))
                    }
                    if let message = model.timelineRetryMessage {
                        Text(message)
                            .font(.caption)
                    }
                }
            } icon: {
                Image(systemName: "exclamationmark.triangle")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button(L10n.string("ui.52a6338d9a37348e")) {
                Task { await model.retrySkippedTimelineFolders() }
            }
            .buttonStyle(.bordered)
            .disabled(model.isRetryingTimelineFolders)
            .accessibilityHint(L10n.string("ui.917b504cc03432a8"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private var loadingGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 14) {
                ForEach(0..<18, id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 7) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                            .aspectRatio(1, contentMode: .fit)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.quaternary)
                            .frame(height: 12)
                    }
                    .redacted(reason: .placeholder)
                    .accessibilityHidden(true)
                }
            }
            .padding(16)
        }
        .accessibilityLabel(L10n.string("ui.bc7c663bcaa80f54"))
    }

    private var isAlbumsRoot: Bool {
        model.browseMode == .albums && model.currentPath == model.selectedSpace?.rootPath
    }

    private var titleText: String {
        switch model.browseMode {
        case .timeline: L10n.string("ui.f1241a97b0821a99")
        case .albums: isAlbumsRoot ? L10n.string("ui.38793c1c1c23437e") : model.locationTitle
        }
    }

    private var titleIcon: String {
        switch model.browseMode {
        case .timeline: "clock"
        case .albums: isAlbumsRoot ? "rectangle.stack" : "photo.on.rectangle"
        }
    }

    private var browseModeSelection: Binding<PhotoBrowseMode> {
        Binding(
            get: { model.browseMode },
            set: { mode in
                Task { @MainActor in onBrowseModeChange(mode) }
            }
        )
    }

    private var spaceSelection: Binding<PhotoSpaceKind?> {
        Binding(
            get: { model.selectedSpaceID },
            set: { id in
                guard let id else { return }
                Task { await model.selectSpace(id) }
            }
        )
    }

    private var mediaFilterTitle: String {
        switch model.mediaFilter {
        case .all: L10n.string("ui.5c55a67935af8f45")
        case .images: L10n.string("ui.7b50017ae47eca32")
        case .videos: L10n.string("ui.c20f7618d330a854")
        }
    }

    private var emptyTitle: String {
        if !model.searchText.isEmpty { return L10n.string("ui.c61a0643dcd67af9") }
        if model.mediaFilter != .all { return L10n.string("ui.85a5f6069fcb6530") }
        if isAlbumsRoot { return L10n.string("ui.0c349a4e26f357d7") }
        return L10n.string("ui.b4e2170ec781bf89")
    }

    private var emptyDescription: String {
        if !model.searchText.isEmpty || model.mediaFilter != .all {
            return L10n.string("ui.504665f05c0d4218")
        }
        if isAlbumsRoot { return L10n.string("ui.0c132f8c1951432b") }
        return L10n.string("ui.14b0d9cf43643b93")
    }
}

private struct PhotoLibraryCell: View {
    @Bindable var model: PhotoLibraryModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    let item: PhotoLibraryItem
    let isSelected: Bool
    let onPreview: (PhotoLibraryItem) -> Void
    let onDownload: ([PhotoLibraryItem]) -> Void
    let onDelete: ([PhotoLibraryItem]) -> Void
    let onRestore: (PhotoLibraryItem) -> Void
    let onMove: (PhotoLibraryItem) -> Void

    private var isRecyclePath: Bool {
        RecycleLocation(recyclePath: item.path) != nil
    }

    var body: some View {
        Button {
            if item.isFolder {
                Task { await model.open(item) }
            } else {
                let extending = NSEvent.modifierFlags.intersection([.command, .shift]).isEmpty == false
                model.select(item, extending: extending)
            }
        } label: {
            cellContents
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if !item.isFolder { onPreview(item) }
            }
        )
        .contextMenu {
            if item.isFolder {
                Button(model.browseMode == .albums ? L10n.string("ui.2a6babd672171738") : L10n.string("ui.fcf8b4bff0df782d")) { Task { await model.open(item) } }
            } else {
                Button(L10n.string("ui.fbae1674bbbe17d9")) { onPreview(item) }
            }

            Divider()

            Button {
                onDownload(contextTargets)
            } label: {
                Label(
                    contextTargets.count > 1
                        ? L10n.string("items.download.count", String(contextTargets.count))
                        : L10n.string("ui.4673a23061656125"),
                    systemImage: "square.and.arrow.down"
                )
            }

            if isRecyclePath {
                Button {
                    onRestore(item)
                } label: {
                    Label(L10n.string("ui.571cbba6210117a0"), systemImage: "arrow.uturn.backward.circle")
                }
            } else {
                Button {
                    onMove(item)
                } label: {
                    Label(L10n.string("ui.0bee1672c6d4a3a9"), systemImage: "folder.badge.arrow.right")
                }

                Button(role: .destructive) {
                    onDelete(contextTargets)
                } label: {
                    Label(
                        contextTargets.count > 1
                            ? L10n.string("items.delete.count", String(contextTargets.count))
                            : L10n.string("ui.0552e329ccf875fb"),
                        systemImage: "trash"
                    )
                }
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(item.isFolder ? (model.browseMode == .albums ? L10n.string("ui.624be41f0ec5751b") : L10n.string("ui.192e635718834fc0")) : L10n.string("ui.87e0cc516a580a29"))
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var cellContents: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    ZStack(alignment: .topTrailing) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(item.isFolder ? Color.accentColor.opacity(0.09) : Color.secondary.opacity(0.08))

                        if item.isFolder {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 44))
                                .foregroundStyle(.blue)
                        } else {
                            PhotoGridThumbnail(
                                model: model,
                                item: item
                            )
                        }

                        if item.isLivePhoto {
                            VStack {
                                Spacer()
                                HStack {
                                    HStack(spacing: 3) {
                                        Image(systemName: "livephoto")
                                            .font(.caption2.weight(.bold))
                                        Text(L10n.string("photo.live"))
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 3)
                                    .background(.ultraThinMaterial, in: Capsule())
                                    .foregroundStyle(.white)
                                    .shadow(color: .black.opacity(0.3), radius: 2)
                                    .padding(6)
                                    Spacer()
                                }
                            }
                        }

                        let isMultiSelecting = model.selection.count > 1
                        if isSelected && isMultiSelecting {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .padding(7)
                                .accessibilityHidden(true)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .background(
                        MacSelectionSurface(isSelected: isSelected, cornerRadius: 10)
                            .padding(-6)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(
                                isSelected ? MacAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).selectionBorder : Color(nsColor: .separatorColor).opacity(0.55),
                                lineWidth: isSelected ? (model.selection.count > 1 ? 3 : 1.5) : 0.5
                            )
                    }
                }

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var accessibilityLabel: String {
        if item.isFolder {
            return L10n.string(
                "photo.item.accessibility",
                model.browseMode == .albums ? L10n.string("photo.type.album") : L10n.string("photo.type.folder"),
                item.name
            )
        }
        return L10n.string(
            "photo.item.accessibility",
            item.kind == .video ? L10n.string("photo.type.video") : L10n.string("photo.type.photo"),
            item.name + (isSelected ? L10n.string("selection.selected_suffix") : "")
        )
    }

    private var contextTargets: [PhotoLibraryItem] {
        if model.selection.contains(item.id) {
            let selected = model.selectedItems
            if !selected.isEmpty { return selected }
        }
        return [item]
    }
}

private struct SkeletonPlaceholderView: View {
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 0)
                .fill(Color.primary.opacity(isBreathing ? 0.09 : 0.03))
                .animation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true), value: isBreathing)
            ProgressView()
                .controlSize(.small)
                .tint(.secondary)
        }
        .onAppear {
            isBreathing = true
        }
    }
}

private struct PhotoGridThumbnail: View {
    @Bindable var model: PhotoLibraryModel
    let item: PhotoLibraryItem
    @State private var displayedImage: DecodedImage?
    @State private var isLoading = true
    @State private var isFailed = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let decoded = displayedImage {
                    Image(decorative: decoded.cgImage, scale: 1, orientation: decoded.orientation)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .transition(.opacity.animation(.easeInOut(duration: 0.2)))
                } else if isLoading {
                    SkeletonPlaceholderView()
                        .frame(width: geo.size.width, height: geo.size.height)
                } else {
                    ZStack {
                        Color.secondary.opacity(0.08)
                        Image(systemName: item.kind == .video ? "video.fill" : "photo.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                if item.kind == .video {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.48))
                        .shadow(radius: 2)
                }
            }
        }
        .task(priority: .userInitiated) {
            isLoading = true
            isFailed = false
            model.thumbnailBecameVisible(item)

            if let cached = await model.cachedThumbnailData(for: item) {
                let decoded = await Task.detached(priority: .userInitiated) {
                    DecodedImage(from: cached)
                }.value
                model.thumbnailRequestDidFinish(for: item)
                guard !Task.isCancelled else { return }
                isLoading = false
                if let decoded {
                    displayedImage = decoded
                } else {
                    isFailed = true
                }
                return
            }

            let loadedData = await model.thumbnailData(for: item)
            model.thumbnailRequestDidFinish(for: item)
            guard !Task.isCancelled else { return }
            isLoading = false
            if let loadedData {
                let decoded = await Task.detached(priority: .userInitiated) {
                    DecodedImage(from: loadedData)
                }.value
                guard !Task.isCancelled else { return }
                if let decoded {
                    displayedImage = decoded
                } else {
                    isFailed = true
                }
            } else {
                isFailed = true
            }
        }
        .onDisappear {
            // 离屏时取消可见标记，并清空状态
            model.thumbnailBecameHidden(item)
            displayedImage = nil
            isLoading = true
            isFailed = false
        }
    }
}
