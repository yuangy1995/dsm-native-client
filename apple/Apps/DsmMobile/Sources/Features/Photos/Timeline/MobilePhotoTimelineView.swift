import DsmCore
import DsmLocalization
import ImageIO
import SwiftUI
import UIKit

struct MobilePhotoTimelineView: View {
    @Bindable var model: MobilePhotoTimelineModel
    let compact: Bool
    let onOpenPhoto: (PhotoLibraryItem) -> Void
    let onSaveCopy: (PhotoLibraryItem) -> Void
    let onShare: (PhotoLibraryItem) -> Void
    let onMove: (PhotoLibraryItem) -> Void
    let onRestoreFromRecycle: (PhotoLibraryItem) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var state: MobilePhotoTimelineState { model.state }
    private var columns: [GridItem] {
        let minimum: CGFloat = dynamicTypeSize.isAccessibilitySize ? (compact ? 164 : 200) : (compact ? 124 : 168)
        return [GridItem(.adaptive(minimum: minimum, maximum: 260), spacing: 12)]
    }

    var body: some View {
        Group {
            switch state.phase {
            case .idle:
                idleView
            case .scanning where state.items.isEmpty:
                scanningView
            case .error:
                errorView
            case .empty:
                emptyView
            case .scanning, .content:
                contentView
            }
        }
        .searchable(text: queryBinding, prompt: L10n.string("mobile.photos.timeline.search.prompt"))
        .toolbar { timelineToolbar }
    }

    private var idleView: some View {
        ContentUnavailableView {
            Label(L10n.string("mobile.photos.timeline.idle.title"), systemImage: "calendar")
        } description: {
            Text(L10n.string("mobile.photos.timeline.idle.message"))
        } actions: {
            scanButton
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var scanningView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
                .accessibilityHidden(true)
            Text(L10n.string("mobile.photos.timeline.loading.title"))
                .font(.headline)
            Text(L10n.string("mobile.photos.timeline.loading.progress", state.scannedFolderCount))
                .foregroundStyle(.secondary)
            cancelButton
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var errorView: some View {
        ContentUnavailableView {
            Label(L10n.string("mobile.photos.timeline.error.title"), systemImage: "exclamationmark.triangle")
        } description: {
            Text(L10n.string("mobile.photos.timeline.error.message"))
        } actions: {
            scanButton
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            notices
            ContentUnavailableView {
                Label(L10n.string("mobile.photos.timeline.empty.title"), systemImage: "photo.on.rectangle")
            } description: {
                Text(L10n.string("mobile.photos.timeline.empty.message"))
            } actions: {
                refreshButton
            }
        }
        .fillsAvailableContentArea(alignment: .center)
    }

    private var contentView: some View {
        Group {
            if model.visibleItems.isEmpty {
                VStack(spacing: 12) {
                    notices
                ContentUnavailableView {
                    Label(L10n.string("mobile.photos.timeline.filtered-empty.title"), systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text(L10n.string("mobile.photos.timeline.filtered-empty.message"))
                } actions: {
                    Button(L10n.string("mobile.photos.timeline.action.clear-search")) {
                        model.setQuery("")
                        model.setFilter(.all)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(minWidth: 44, minHeight: 44)
                }
                .fillsAvailableContentArea(alignment: .center)
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        notices
                        ForEach(model.visibleMonths) { month in
                            VStack(alignment: .leading, spacing: 10) {
                                Text(monthTitle(month))
                                    .font(.title3.weight(.semibold))
                                    .accessibilityAddTraits(.isHeader)
                                LazyVGrid(columns: columns, spacing: 12) {
                                    ForEach(month.items) { item in
                                        TimelinePhotoCell(
                                            item: item,
                                            loadThumbnail: { await model.thumbnailData(for: item) },
                                            onOpen: { onOpenPhoto(item) },
                                            onSaveCopy: { onSaveCopy(item) },
                                            onShare: { onShare(item) },
                                            onMove: canMove(item) ? { onMove(item) } : nil,
                                            onRestoreFromRecycle: canRestoreFromRecycle(item)
                                                ? { onRestoreFromRecycle(item) }
                                                : nil
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .padding(compact ? 12 : 16)
                }
            }
        }
        .overlay(alignment: .top) {
            if state.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityLabel(L10n.string("mobile.photos.timeline.loading.title"))
            }
        }
    }

    @ViewBuilder
    private var notices: some View {
        if state.isTruncated {
            timelineNotice(
                title: L10n.string("mobile.photos.timeline.truncated.title"),
                message: L10n.string("mobile.photos.timeline.truncated.message"),
                systemImage: "exclamationmark.circle"
            )
        }
        if state.isPartial {
            timelineNotice(
                title: L10n.string("mobile.photos.timeline.partial.title"),
                message: L10n.string("mobile.photos.timeline.partial.message", state.skippedFolderPaths.count),
                systemImage: "folder.badge.questionmark"
            )
        }
        if state.refreshFailed {
            timelineNotice(
                title: L10n.string("mobile.photos.timeline.error.title"),
                message: L10n.string("mobile.photos.timeline.error.message"),
                systemImage: "wifi.exclamationmark"
            )
        }
    }

    private func timelineNotice(title: String, message: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.orange)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    @ToolbarContentBuilder
    private var timelineToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker(L10n.string("mobile.photos.timeline.filter.title"), selection: filterBinding) {
                    Text(L10n.string("mobile.photos.timeline.filter.all")).tag(PhotoMediaFilter.all)
                    Text(L10n.string("mobile.photos.timeline.filter.images")).tag(PhotoMediaFilter.images)
                    Text(L10n.string("mobile.photos.timeline.filter.videos")).tag(PhotoMediaFilter.videos)
                }
                if state.isScanning {
                    Button(L10n.string("mobile.photos.timeline.action.cancel"), role: .cancel) { model.cancel() }
                } else if state.hasCompletedScan {
                    Button(L10n.string("mobile.photos.timeline.action.refresh")) { Task { await model.refresh() } }
                }
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.string("mobile.photos.timeline.filter.title"))
        }
    }

    private var scanButton: some View {
        Button(L10n.string("mobile.photos.timeline.action.scan")) { Task { await model.refresh() } }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
    }

    private var refreshButton: some View {
        Button(L10n.string("mobile.photos.timeline.action.refresh")) { Task { await model.refresh() } }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
    }

    private var cancelButton: some View {
        Button(L10n.string("mobile.photos.timeline.action.cancel"), role: .cancel) { model.cancel() }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .frame(minWidth: 44, minHeight: 44)
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { state.query },
            set: { value in model.setQuery(value) }
        )
    }

    private var filterBinding: Binding<PhotoMediaFilter> {
        Binding(
            get: { state.filter },
            set: { value in model.setFilter(value) }
        )
    }

    private func monthTitle(_ month: MobilePhotoTimelineMonth) -> String {
        guard let date = month.monthStart else { return L10n.string("mobile.photos.timeline.unknown-month") }
        return date.formatted(.dateTime.year().month(.wide).locale(L10n.locale))
    }

    private func canRestoreFromRecycle(_ item: PhotoLibraryItem) -> Bool {
        item.fileItem.isRecyclePath &&
            MobileFileRecycleActionModel.restoreDestinationPath(for: item.path) != nil
    }

    private func canMove(_ item: PhotoLibraryItem) -> Bool {
        !item.fileItem.isRecyclePath && item.sizeBytes.map { $0 >= 0 } == true
    }
}

private struct TimelinePhotoCell: View {
    let item: PhotoLibraryItem
    let loadThumbnail: () async -> Data?
    let onOpen: () -> Void
    let onSaveCopy: () -> Void
    let onShare: () -> Void
    let onMove: (() -> Void)?
    let onRestoreFromRecycle: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: UIImage?
    @State private var didFinishThumbnailRequest = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 8) {
                    thumbnailView
                    Text(item.name).font(.body.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel(L10n.string("mobile.photos.open-photo", item.name))

            Divider()
            Menu {
                Button(L10n.string("mobile.photos.action.save-copy"), action: onSaveCopy)
                Button(L10n.string("mobile.photos.action.share"), action: onShare)
                if let onMove {
                    Button(L10n.string("mobile.files.copy-move.move.action"), action: onMove)
                }
                if let onRestoreFromRecycle {
                    Button(L10n.string("mobile.files.recycle.restore.action"), action: onRestoreFromRecycle)
                }
            } label: {
                Image(systemName: "ellipsis").frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.string("mobile.photos.item-actions", item.name))
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: "\(item.profileID.uuidString)|\(item.path)|\(item.modifiedAt?.timeIntervalSince1970 ?? 0)|\(item.sizeBytes ?? -1)") {
            guard item.kind == .image else {
                didFinishThumbnailRequest = true
                return
            }
            let data = await loadThumbnail()
            guard !Task.isCancelled else { return }
            let image = await Self.decodeThumbnail(data)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                thumbnail = image
                didFinishThumbnailRequest = true
            }
        }
    }

    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.secondary.opacity(0.1))
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill().transition(.opacity)
            } else if item.kind == .video {
                Image(systemName: "video.fill").font(.largeTitle).foregroundStyle(.secondary)
            } else if didFinishThumbnailRequest {
                Image(systemName: "photo").font(.title2).foregroundStyle(.secondary)
            } else {
                ProgressView().accessibilityHidden(true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private static func decodeThumbnail(_ data: Data?) async -> UIImage? {
        guard let data, !data.isEmpty, data.count <= 10 * 1_024 * 1_024 else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_024
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}
