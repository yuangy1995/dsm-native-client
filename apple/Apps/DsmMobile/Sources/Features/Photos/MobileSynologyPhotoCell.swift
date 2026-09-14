import DsmCore
import DsmLocalization
import ImageIO
import SwiftUI
import UIKit

struct MobileSynologyPhotoCell: View {
    let photo: SynologyPhoto
    let library: MobileSynologyPhotosModel
    let onOpen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var image: UIImage?
    @State private var finished = false

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    Rectangle().fill(Color(uiColor: .secondarySystemGroupedBackground))
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            if let image {
                                GeometryReader { geometry in
                                    Image(uiImage: image).resizable().scaledToFill()
                                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                                }
                            } else if finished {
                                Image(systemName: "photo").foregroundStyle(.secondary)
                            } else { ProgressView() }
                        }
                    if photo.mediaType == "video" || photo.mediaType == "live" {
                        Image(systemName: photo.mediaType == "live" ? "livephoto" : "play.fill")
                            .font(.caption).foregroundStyle(.white).padding(8)
                            .background(.black.opacity(0.5), in: Capsule()).padding(6)
                    }
                }.clipShape(RoundedRectangle(cornerRadius: 14))
                Text(photo.filename).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
            }.contentShape(Rectangle())
        }
        .buttonStyle(.plain).frame(minHeight: 44)
        .accessibilityLabel(L10n.string("mobile.photos.open-photo", photo.filename))
        .task(id: identity) {
            image = nil; finished = false
            do {
                let data = try await library.thumbnail(for: photo)
                let decoded = await MobileSynologyImageDecoder.decode(data, maximumPixels: 768)
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { image = decoded; finished = true }
            } catch {
                guard !Task.isCancelled else { return }
                finished = true
            }
        }
    }

    private var identity: String {
        "\(photo.id.profileID)|\(photo.id.space.rawValue)|\(photo.id.unitID)|\(photo.thumbnail?.revision ?? "")"
    }
}

enum MobileSynologyImageDecoder {
    static func decode(_ data: Data?, maximumPixels: Int) async -> UIImage? {
        guard let data, !data.isEmpty, data.count <= 8 * 1_024 * 1_024 else { return nil }
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard !Task.isCancelled,
                  let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: min(maximumPixels, 4_096)
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary), !Task.isCancelled else { return nil }
            return UIImage(cgImage: image)
        }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
