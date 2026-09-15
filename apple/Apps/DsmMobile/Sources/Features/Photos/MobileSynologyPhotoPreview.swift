import DsmCore
import DsmLocalization
import SwiftUI
import UIKit

/// iPhone 全屏触控、iPad 可展开详情栏；写操作不从文件路径推导。
struct MobileSynologyPhotoPreview: View {
    @Bindable var library: SynologyPhotosModel
    let repository: (any SynologyPhotosServing)?
    @Bindable var exporter: MobilePhotosExportModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @State private var showsInfo = false
    @State private var zoomReset = 0

    var body: some View {
        NavigationStack {
            ZStack {
                MobileGlassBackground()
                media
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { controls }
            .navigationTitle(library.previewPhoto?.filename ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.media.close")) {
                        exporter.cancel()
                        library.closePreview()
                    }.keyboardShortcut(.cancelAction).frame(minHeight: 44)
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showsInfo.toggle() } label: {
                        Label(L10n.string("photos.media.info"), systemImage: "info.circle")
                    }.frame(minWidth: 44, minHeight: 44)
                    if let photo = library.previewPhoto, let repository {
                        Button { exporter.export(photo, using: repository) } label: {
                            Label(L10n.string("photos.media.save"), systemImage: "square.and.arrow.up")
                        }.frame(minWidth: 44, minHeight: 44)
                            .disabled(exporter.isPreparing || exporter.presentation != nil)
                    }
                }
            }
            .inspector(isPresented: $showsInfo) {
                if let photo = library.previewPhoto {
                    MobileSynologyPhotoDetails(photo: photo)
                        .inspectorColumnWidth(min: 280, ideal: 320, max: 440)
                }
            }
        }
        .sheet(item: Binding(
            get: { exporter.presentation },
            set: { if $0 == nil { exporter.finishPresentation() } }
        ), onDismiss: exporter.finishPresentation) { file in
            MobileShareSheet(url: file.url, completion: exporter.finishPresentation)
        }
        .alert(L10n.string("photos.error.title"), isPresented: Binding(
            get: { exporter.errorMessage != nil },
            set: { if !$0 { exporter.errorMessage = nil } }
        )) {
            Button(L10n.string("photos.media.close")) { exporter.errorMessage = nil }
        } message: { Text(exporter.errorMessage ?? "") }
        .onChange(of: library.isModuleEnabled) { _, enabled in
            if !enabled { exporter.cancel(); library.closePreview() }
        }
    }

    @ViewBuilder private var media: some View {
        if let source = library.previewSource {
            MobileMediaPlayer(source: source, title: library.previewPhoto?.filename ?? "",
                              autoplays: library.isPlayingMotion,
                              onFinished: { if library.isPlayingMotion { library.finishMotion() } })
                .id(library.previewPhoto?.id)
        } else if let data = library.previewData, let photo = library.previewPhoto {
            MobileSynologyPreviewImage(data: data, title: photo.filename, reset: zoomReset,
                onPrevious: { library.adjacentPreview(-1) }, onNext: { library.adjacentPreview(1) })
                .id(photo.id)
        } else if library.isPreparingPreview {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel(L10n.string("mobile.files.preview.media.loading"))
        } else {
            ContentUnavailableView {
                Label(L10n.string("photos.media.open"), systemImage: "photo")
            } description: { Text(library.previewError ?? L10n.string("photos.media.failed")) }
            actions: {
                Button(L10n.string("photos.retry")) {
                    if let photo = library.previewPhoto { library.showPreview(photo) }
                }.frame(minHeight: 44)
            }
        }
    }

    private var controls: some View {
        MobileGlassGroup {
            VStack(spacing: 8) {
                if exporter.isPreparing {
                    HStack {
                        ProgressView(value: exporter.progress)
                        Text(L10n.string("native.photos.exporting")).font(.caption)
                        Button(L10n.string("photos.delete.cancel")) { exporter.cancel() }.frame(minHeight: 44)
                    }
                }
                HStack(spacing: 16) {
                    Button { library.adjacentPreview(-1) } label: {
                        Label(L10n.string("photos.media.previous"), systemImage: "chevron.left")
                    }.disabled(!hasAdjacent(-1)).keyboardShortcut(.leftArrow, modifiers: [])
                    Spacer(minLength: 0)
                    if library.previewPhoto?.mediaType == "live" {
                        Button {
                            if library.isPlayingMotion { library.finishMotion() } else { library.playMotion() }
                        } label: {
                            Label(L10n.string("photos.media.playMotion"), systemImage: library.isPlayingMotion ? "stop.circle" : "livephoto")
                        }.disabled(library.isPreparingPreview)
                    }
                    if library.previewData != nil && !library.isPlayingMotion {
                        Button { zoomReset += 1 } label: {
                            Label(L10n.string("native.photos.zoom.reset"), systemImage: "arrow.up.left.and.arrow.down.right")
                        }
                    }
                    Spacer(minLength: 0)
                    Button { library.adjacentPreview(1) } label: {
                        Label(L10n.string("photos.media.next"), systemImage: "chevron.right")
                    }.disabled(!hasAdjacent(1)).keyboardShortcut(.rightArrow, modifiers: [])
                }
                .labelStyle(.iconOnly).buttonStyle(MobilePhotoControlStyle())
            }
            .padding(.horizontal, 16).padding(.vertical, 8).mobileGlassChrome(cornerRadius: 24)
            .padding(.horizontal, 16).padding(.bottom, 8)
        }
    }
    private func hasAdjacent(_ offset: Int) -> Bool {
        guard let id = library.previewPhoto?.id, let index = library.items.firstIndex(where: { $0.id == id }) else { return false }
        return library.items.indices.contains(index + offset)
    }
}

private struct MobilePhotoControlStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.6 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct MobileSynologyPreviewImage: View {
    let data: Data
    let title: String
    let reset: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image {
                MobilePhotoZoomView(image: image, title: title, reset: reset, onPrevious: onPrevious, onNext: onNext)
            } else if failed {
                ContentUnavailableView(L10n.string("photos.media.open"), systemImage: "photo",
                                       description: Text(L10n.string("photos.media.failed")))
            } else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: data) {
            failed = false
            let decoded = await MobilePhotosImageDecoder.decode(data, maximumPixelSize: 3_072)
            guard !Task.isCancelled else { return }
            image = decoded; failed = decoded == nil
        }
    }
}

/// 系统 UIScrollView 提供捏合、平移与双击缩放，未放大时横划切换照片。
struct MobilePhotoZoomView: UIViewRepresentable {
    let image: UIImage
    let title: String
    let reset: Int
    let onPrevious: () -> Void
    let onNext: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeCoordinator() -> Coordinator { Coordinator(onPrevious: onPrevious, onNext: onNext) }
    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.delegate = context.coordinator
        view.backgroundColor = .clear
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.bouncesZoom = true
        view.imageView.contentMode = .scaleAspectFit
        view.imageView.isAccessibilityElement = true
        view.addSubview(view.imageView)
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let recognizer = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.swipe(_:)))
            recognizer.direction = direction
            recognizer.delegate = context.coordinator
            view.addGestureRecognizer(recognizer)
        }
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.zoom(_:)))
        tap.numberOfTapsRequired = 2
        view.addGestureRecognizer(tap)
        context.coordinator.view = view
        return view
    }
    func updateUIView(_ view: PhotoScrollView, context: Context) {
        context.coordinator.onPrevious = onPrevious
        context.coordinator.onNext = onNext
        context.coordinator.reduceMotion = reduceMotion
        view.imageView.accessibilityLabel = title
        if view.imageView.image !== image {
            view.imageView.image = image
            view.needsFit = true
            view.setNeedsLayout()
        }
        if context.coordinator.reset != reset {
            context.coordinator.reset = reset
            view.setZoomScale(view.minimumZoomScale, animated: !reduceMotion)
        }
    }
    final class PhotoScrollView: UIScrollView {
        let imageView = UIImageView()
        var needsFit = true
        private var previousSize = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0, bounds.height > 0, let image = imageView.image else { return }
            if needsFit || previousSize != bounds.size {
                needsFit = false
                previousSize = bounds.size
                zoomScale = 1
                imageView.frame = CGRect(origin: .zero, size: image.size)
                contentSize = image.size
                let fit = min(bounds.width / max(1, image.size.width), bounds.height / max(1, image.size.height))
                minimumZoomScale = fit
                maximumZoomScale = fit * 6
                zoomScale = fit
            }
            centerImage()
        }
        func centerImage() {
            imageView.center = CGPoint(x: max(contentSize.width, bounds.width) / 2,
                                       y: max(contentSize.height, bounds.height) / 2)
        }
    }
    @MainActor final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        weak var view: PhotoScrollView?
        var onPrevious: () -> Void
        var onNext: () -> Void
        var reduceMotion = false
        var reset = 0
        init(onPrevious: @escaping () -> Void, onNext: @escaping () -> Void) {
            self.onPrevious = onPrevious; self.onNext = onNext
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { view?.imageView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { view?.centerImage() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            gestureRecognizer is UISwipeGestureRecognizer && !(otherGestureRecognizer is UIPinchGestureRecognizer)
        }
        @objc func swipe(_ recognizer: UISwipeGestureRecognizer) {
            guard let view, view.zoomScale <= view.minimumZoomScale * 1.01 else { return }
            if recognizer.direction == .left { onNext() } else { onPrevious() }
        }
        @objc func zoom(_ recognizer: UITapGestureRecognizer) {
            guard let view else { return }
            let target = view.zoomScale > view.minimumZoomScale * 1.01 ? view.minimumZoomScale : view.minimumZoomScale * 2.5
            view.setZoomScale(target, animated: !reduceMotion)
        }
    }
}

struct MobileSynologyPhotoDetails: View {
    let photo: SynologyPhoto
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(photo.filename).font(.headline).textSelection(.enabled)
                row("photos.detail.taken", photo.takenAt.formatted(.dateTime.locale(L10n.locale)))
                row("photos.detail.added", photo.indexedAt.formatted(.dateTime.locale(L10n.locale)))
                row("photos.detail.size", photo.sizeBytes.formatted(.byteCount(style: .file).locale(L10n.locale)))
                row("photos.detail.format", (photo.filename as NSString).pathExtension.uppercased())
                if let width = photo.width, let height = photo.height {
                    row("photos.detail.resolution", L10n.string("photos.media.dimensions", width, height))
                }
                row("photos.detail.camera", photo.camera)
                row("photos.detail.lens", photo.lens)
                row("photos.detail.aperture", photo.aperture)
                row("photos.detail.shutter", photo.exposureTime)
                row("photos.detail.focal", photo.focalLength)
                row("photos.detail.iso", photo.iso)
                if !photo.addressComponents.isEmpty {
                    let formatter = ListFormatter()
                    let _ = { formatter.locale = L10n.locale }()
                    row("photos.detail.location", formatter.string(from: photo.addressComponents))
                }
                if let latitude = photo.latitude, let longitude = photo.longitude {
                    row("photos.detail.coordinates", L10n.string("photos.coordinates",
                        latitude.formatted(.number.precision(.fractionLength(5)).locale(L10n.locale)),
                        longitude.formatted(.number.precision(.fractionLength(5)).locale(L10n.locale))))
                }
                if let duration = photo.duration {
                    row("photos.detail.duration", L10n.string("photos.seconds", duration.formatted(.number.precision(.fractionLength(1)).locale(L10n.locale))))
                }
                if let rating = photo.rating { row("photos.detail.rating", L10n.string("photos.stars", rating)) }
                row("photos.detail.description", photo.description)
                Text(L10n.string("native.photos.readonly")).font(.footnote).foregroundStyle(.secondary)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.mobileGlassWorkspace().navigationTitle(L10n.string("photos.media.info"))
    }
    @ViewBuilder private func row(_ key: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(key)).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.body).textSelection(.enabled)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
