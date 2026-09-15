import DsmCore
import DsmLocalization
import ImageIO
import SwiftUI
import UIKit

/// ImageIO 在后台按显示尺寸缩采样，图片与文字都不参与玻璃模糊。
enum MobilePhotosImageDecoder {
    static func decode(_ data: Data, maximumPixelSize: Int) async -> UIImage? {
        guard !data.isEmpty, data.count <= 8 * 1_024 * 1_024 else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, min(3_072, maximumPixelSize))
            ]
            guard let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: bitmap)
        }.value
    }
}

struct MobileSynologyPhotoCell: View {
    let photo: SynologyPhoto
    let repository: (any SynologyPhotosServing)?
    let cache: MobilePhotoThumbnailStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var finished = false

    private var identity: String {
        "\(photo.id.profileID.uuidString)|\(photo.id.space.rawValue)|\(photo.id.unitID)|\(photo.thumbnail?.unitID ?? 0)|\(photo.thumbnail?.revision ?? "")"
    }
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.secondary.opacity(0.1)
            if let image {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: photo.mediaType == "video" ? "video" : "photo").font(.title2)
                    if !finished { ProgressView().controlSize(.small) }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).foregroundStyle(.secondary)
            }
            if photo.mediaType == "video" || photo.mediaType == "live" {
                Image(systemName: photo.mediaType == "video" ? "play.fill" : "livephoto")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white)
                    .padding(6).background(.black.opacity(0.45), in: .capsule).padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityHidden(true)
        .task(id: identity) {
            image = nil; finished = false
            guard let repository else { finished = true; return }
            let key = identity
            let data = await cache.data(for: key, namespace: photo.id.profileID.uuidString, priority: .visible) {
                try await repository.thumbnail(for: photo)
            }
            guard !Task.isCancelled else { return }
            let decoded = if let data { await MobilePhotosImageDecoder.decode(data, maximumPixelSize: 640) } else { nil as UIImage? }
            guard !Task.isCancelled else { return }
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) {
                image = decoded; finished = true
            }
        }
    }
}
