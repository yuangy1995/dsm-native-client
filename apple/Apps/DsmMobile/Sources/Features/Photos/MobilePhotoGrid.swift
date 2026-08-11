import DsmCore
import DsmLocalization
import SwiftUI

struct MobilePhotoGrid: View {
    let items: [PhotoLibraryItem]
    let library: MobilePhotoLibraryModel
    let compact: Bool
    let isLoadingMore: Bool
    let loadMoreFailed: Bool
    let hasMore: Bool
    let onOpenFolder: (PhotoLibraryItem) -> Void
    let onOpenPhoto: (PhotoLibraryItem) -> Void
    let onSaveCopy: (PhotoLibraryItem) -> Void
    let onShare: (PhotoLibraryItem) -> Void
    let onMove: (PhotoLibraryItem) -> Void
    let onRestoreFromRecycle: (PhotoLibraryItem) -> Void
    let onLoadMore: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var columns: [GridItem] {
        let minimum: CGFloat
        if dynamicTypeSize.isAccessibilitySize {
            minimum = compact ? 164 : 200
        } else {
            minimum = compact ? 124 : 168
        }
        return [GridItem(.adaptive(minimum: minimum, maximum: 260), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items) { item in
                    MobilePhotoCell(
                        item: item,
                        library: library,
                        onOpenFolder: onOpenFolder,
                        onOpenPhoto: onOpenPhoto,
                        onSaveCopy: onSaveCopy,
                        onShare: onShare,
                        onMove: canMove(item) ? onMove : nil,
                        onRestoreFromRecycle: canRestoreFromRecycle(item) ? onRestoreFromRecycle : nil
                    )
                }
            }
            .padding(compact ? 12 : 16)

            paginationFooter
                .padding(.horizontal, compact ? 12 : 16)
                .padding(.bottom, 16)
        }
        .task(id: prefetchIdentity) {
            library.prefetchThumbnails(items)
        }
    }

    @ViewBuilder
    private var paginationFooter: some View {
        if loadMoreFailed {
            VStack(spacing: 8) {
                Label(L10n.string("mobile.photos.error.title"), systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button(L10n.string("mobile.photos.action.retry"), action: onLoadMore)
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        } else if isLoadingMore {
            ProgressView(L10n.string("mobile.photos.loading-more"))
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 8)
        } else if hasMore {
            Button(L10n.string("mobile.photos.action.load-more"), action: onLoadMore)
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity, minHeight: 44)
                .padding(.vertical, 8)
        }
    }

    private var prefetchIdentity: String {
        items.prefix(MobilePhotoLibraryModel.prefetchLimit).map(\.id).joined(separator: "|")
    }

    private func canRestoreFromRecycle(_ item: PhotoLibraryItem) -> Bool {
        !item.isFolder &&
            item.fileItem.isRecyclePath &&
            MobileFileRecycleActionModel.restoreDestinationPath(for: item.path) != nil
    }

    private func canMove(_ item: PhotoLibraryItem) -> Bool {
        !item.isFolder &&
            !item.fileItem.isRecyclePath &&
            item.sizeBytes.map { $0 >= 0 } == true
    }
}
