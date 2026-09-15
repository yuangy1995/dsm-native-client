import DsmCore
import DsmLocalization
import ImageIO
import SwiftUI
import UIKit

struct MobileSynologyPhotoCell: View {
    let photo: SynologyPhoto
    let model: MobileSynologyPhotosModel
    @State private var image: UIImage?
    @State private var finished = false

    var body: some View {
        Button { model.showPreview(photo) } label: {
            ZStack(alignment: .bottomLeading) {
                Rectangle().fill(Color.secondary.opacity(0.1))
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else if finished {
                    Image(systemName: photo.mediaType == "video" ? "video" : "photo").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                if photo.mediaType == "live" || photo.mediaType == "video" {
                    Label(L10n.string(photo.mediaType == "live" ? "photos.live" : "photos.category.videos"), systemImage: photo.mediaType == "live" ? "livephoto" : "play.fill")
                        .font(.caption).padding(6).background(.regularMaterial, in: Capsule()).padding(6)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(photo.filename)
        .accessibilityHint(L10n.string("photos.media.open"))
        .task(id: photo.thumbnail) {
            image = nil
            finished = false
            let data = await model.thumbnailData(for: photo)
            let decoded = await MobileSynologyPhotoImage.decode(data, maximumPixels: 640)
            guard !Task.isCancelled else { return }
            image = decoded
            finished = true
        }
    }
}

/// 在后台缩采样，限制解码后的像素开销；大图不直接按原始像素解码到主线程。
enum MobileSynologyPhotoImage {
    static func decode(_ data: Data?, maximumPixels: Int) async -> UIImage? {
        guard let data, !data.isEmpty, data.count <= 8 * 1_024 * 1_024 else { return nil }
        return await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixels
                  ] as CFDictionary) else { return nil }
            return UIImage(cgImage: image)
        }.value
    }
}

struct MobileSynologyPhotoPreview: View {
    @Bindable var model: MobileSynologyPhotosModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var image: UIImage?
    @State private var showsInfo = false
    @State private var decodedPreview = false
    @State private var zoom: CGFloat = 1
    @State private var initialZoom: CGFloat = 1

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if sizeClass == .regular, showsInfo {
                    HStack(spacing: 0) {
                        media
                        Divider()
                        details.frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
                    }
                } else {
                    media
                    if showsInfo { details.frame(maxHeight: 280) }
                }
                if let message = model.saveMessage { Text(message).font(.callout).padding(8) }
                if model.isSaving {
                    HStack {
                        ProgressView(value: model.saveProgress)
                        Button(L10n.string("photos.delete.cancel"), action: model.cancelExport).frame(minHeight: 44)
                    }.padding(.horizontal)
                }
                controls
            }
            .navigationTitle(model.previewPhoto?.filename ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.media.close")) { model.closePreview(); dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showsInfo.toggle() } label: { Image(systemName: "info.circle") }
                        .accessibilityLabel(L10n.string("photos.media.info"))
                    Button {
                        if let photo = model.previewPhoto { model.prepareExport(photo) }
                    } label: { Image(systemName: "square.and.arrow.up") }
                    .disabled(model.isSaving)
                    .accessibilityLabel(L10n.string("photos.media.save"))
                }
            }
            .sheet(isPresented: Binding(get: { model.exportURL != nil }, set: { if !$0 { model.cancelExport() } }), onDismiss: model.cancelExport) {
                if let url = model.exportURL { MobileShareSheet(url: url, completion: model.cancelExport) }
            }
            .onChange(of: model.previewPhoto?.id) { _, _ in zoom = 1; initialZoom = 1; image = nil; decodedPreview = false }
            .task(id: model.previewData) {
                decodedPreview = false
                let decoded = await MobileSynologyPhotoImage.decode(model.previewData, maximumPixels: 2_560)
                guard !Task.isCancelled else { return }
                image = decoded
                decodedPreview = model.previewData != nil
            }
        }
    }

    @ViewBuilder private var media: some View {
        ZStack {
            Color(uiColor: .secondarySystemBackground)
            if model.isPreparingPreview { ProgressView() }
            else if let error = model.previewError {
                ContentUnavailableView {
                    Label(L10n.string("photos.error.title"), systemImage: "photo.badge.exclamationmark")
                } description: { Text(error) } actions: {
                    Button(L10n.string("photos.retry")) {
                        if let photo = model.previewPhoto { model.showPreview(photo) }
                    }.frame(minHeight: 44)
                }
            } else if let source = model.previewSource {
                MobileMediaPlayer(source: source, title: model.previewPhoto?.filename ?? "")
                    .id(source.request.url)
            } else if let image {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: geometry.size.width * zoom, height: geometry.size.height * zoom)
                    }
                    .gesture(MagnifyGesture().onChanged { value in zoom = min(5, max(1, initialZoom * value.magnification)) }
                        .onEnded { _ in initialZoom = zoom })
                    .onTapGesture(count: 2) { zoom = zoom > 1 ? 1 : 2; initialZoom = zoom }
                }
            } else if decodedPreview {
                ContentUnavailableView(L10n.string("photos.media.failed"), systemImage: "photo.badge.exclamationmark")
            } else if model.previewData != nil { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(model.previewPhoto?.filename ?? "")
    }

    private var controls: some View {
        HStack {
            Button { model.adjacentPreview(-1) } label: { Label(L10n.string("photos.media.previous"), systemImage: "chevron.left") }
                .disabled(!canMove(-1)).keyboardShortcut(.leftArrow, modifiers: [])
            Spacer()
            if model.previewPhoto?.mediaType == "live" {
                Button {
                    if model.isPlayingMotion { model.finishMotion() } else { model.playMotion() }
                } label: {
                    Label(L10n.string(model.isPlayingMotion ? "photos.media.close" : "photos.media.playMotion"), systemImage: "livephoto")
                }
            }
            Spacer()
            Button { model.adjacentPreview(1) } label: { Label(L10n.string("photos.media.next"), systemImage: "chevron.right") }
                .disabled(!canMove(1)).keyboardShortcut(.rightArrow, modifiers: [])
        }.frame(minHeight: 44).padding(.horizontal)
    }

    @ViewBuilder private var details: some View {
        if let photo = model.previewPhoto {
            Form {
                LabeledContent(L10n.string("photos.detail.taken"), value: photo.takenAt.formatted(.dateTime.locale(L10n.locale)))
                LabeledContent(L10n.string("photos.detail.added"), value: photo.indexedAt.formatted(.dateTime.locale(L10n.locale)))
                LabeledContent(L10n.string("photos.detail.size"), value: photo.sizeBytes.formatted(.byteCount(style: .file)))
                LabeledContent(L10n.string("photos.detail.format"), value: (photo.filename as NSString).pathExtension.uppercased())
                if let width = photo.width, let height = photo.height {
                    LabeledContent(L10n.string("photos.detail.resolution"), value: L10n.string("photos.media.dimensions", width, height))
                }
                value("photos.detail.camera", photo.camera)
                value("photos.detail.lens", photo.lens)
                value("photos.detail.aperture", photo.aperture)
                value("photos.detail.shutter", photo.exposureTime)
                value("photos.detail.focal", photo.focalLength)
                value("photos.detail.iso", photo.iso)
                if let duration = photo.duration {
                    value("photos.detail.duration", L10n.string("photos.seconds", duration.formatted(.number.locale(L10n.locale))))
                }
                if let rating = photo.rating { value("photos.detail.rating", L10n.string("photos.stars", rating)) }
                value("photos.detail.description", photo.description)
                if !photo.addressComponents.isEmpty { value("photos.detail.location", photo.addressComponents.joined(separator: " · ")) }
                if let latitude = photo.latitude, let longitude = photo.longitude {
                    value("photos.detail.coordinates", L10n.string("photos.coordinates", latitude.formatted(.number.locale(L10n.locale)), longitude.formatted(.number.locale(L10n.locale))))
                }
            }
        }
    }

    @ViewBuilder private func value(_ key: String, _ text: String?) -> some View {
        if let text, !text.isEmpty { LabeledContent(L10n.string(key), value: text) }
    }
    private func canMove(_ direction: Int) -> Bool {
        guard let id = model.previewPhoto?.id, let index = model.items.firstIndex(where: { $0.id == id }) else { return false }
        return model.items.indices.contains(index + direction)
    }
}
