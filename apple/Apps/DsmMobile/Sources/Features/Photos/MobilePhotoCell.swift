import DsmCore
import DsmLocalization
import ImageIO
import SwiftUI
import UIKit

struct MobilePhotoCell: View {
    let item: PhotoLibraryItem
    let library: MobilePhotoLibraryModel
    let onOpenFolder: (PhotoLibraryItem) -> Void
    let onOpenPhoto: (PhotoLibraryItem) -> Void
    let onSaveCopy: (PhotoLibraryItem) -> Void
    let onShare: (PhotoLibraryItem) -> Void
    let onMove: ((PhotoLibraryItem) -> Void)?
    let onMoveToRecycle: ((PhotoLibraryItem) -> Void)?
    let onRestoreFromRecycle: ((PhotoLibraryItem) -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var thumbnail: UIImage?
    @State private var didFinishThumbnailRequest = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: primaryAction) {
                VStack(alignment: .leading, spacing: 8) {
                    thumbnailView
                    Text(item.name)
                        .font(.body.weight(.medium))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(minHeight: 44)
            .accessibilityLabel(
                L10n.string(item.isFolder ? "mobile.photos.open-album" : "mobile.photos.open-photo", item.name)
            )

            if !item.isFolder {
                Divider()
                Menu {
                    Button(L10n.string("mobile.photos.action.save-copy")) { onSaveCopy(item) }
                    Button(L10n.string("mobile.photos.action.share")) { onShare(item) }
                    if let onMove {
                        Button(L10n.string("mobile.files.copy-move.move.action")) { onMove(item) }
                    }
                    if let onMoveToRecycle {
                        Button(L10n.string("mobile.files.recycle.move.action"), role: .destructive) {
                            onMoveToRecycle(item)
                        }
                    }
                    if let onRestoreFromRecycle {
                        Button(L10n.string("mobile.files.recycle.restore.action")) {
                            onRestoreFromRecycle(item)
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.string("mobile.photos.item-actions", item.name))
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .task(id: thumbnailIdentity) {
            guard item.kind == .image else { return }
            let data = await library.thumbnailData(for: item)
            guard !Task.isCancelled else { return }
            let decoded = await Self.decodeThumbnail(data)
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                thumbnail = decoded
                didFinishThumbnailRequest = true
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(item.isFolder ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.1))
            if item.isFolder {
                Image(systemName: "folder.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
            } else if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else if didFinishThumbnailRequest {
                VStack(spacing: 6) {
                    Image(systemName: "photo")
                        .font(.title2)
                    Text(L10n.string("mobile.photos.thumbnail.unavailable"))
                        .font(.caption)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(8)
            } else {
                ProgressView()
                    .accessibilityHidden(true)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var thumbnailIdentity: String {
        "\(item.profileID.uuidString)|\(item.path)|\(item.modifiedAt?.timeIntervalSince1970 ?? 0)"
    }

    private static func decodeThumbnail(_ data: Data?) async -> UIImage? {
        guard let data, !data.isEmpty, data.count <= 10 * 1024 * 1024 else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_024
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }

    private func primaryAction() {
        if item.isFolder {
            onOpenFolder(item)
        } else {
            onOpenPhoto(item)
        }
    }
}
