import DsmCore
import DsmLocalization
import SwiftUI
import UIKit

struct MobileSynologyPhotoPreview: View {
    @Bindable var library: MobileSynologyPhotosModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var image: UIImage?
    @State private var didDecode = false
    @State private var showsInformation = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let photo = library.previewPhoto {
                    if let source = library.previewSource {
                        MobileMediaPlayer(source: source, title: photo.filename)
                    } else if let image {
                        MobileSynologyZoomImage(image: image, title: photo.filename)
                    }
                    if library.isPreparingPreview || (library.previewData != nil && !didDecode && library.previewError == nil) {
                        ProgressView().tint(.white)
                    }
                    if let error = library.previewError ?? (didDecode && library.previewData != nil && image == nil ? L10n.string("photos.media.failed") : nil) {
                        ContentUnavailableView {
                            Label(L10n.string("photos.error.title"), systemImage: "photo")
                        } description: { Text(error) } actions: {
                            Button(L10n.string("photos.retry")) { library.showPreview(photo) }.frame(minHeight: 44)
                            Button(L10n.string("photos.media.save")) { library.exportOriginal(photo) }.frame(minHeight: 44)
                        }.foregroundStyle(.white)
                    }
                }
            }
            .navigationTitle(library.previewPhoto?.filename ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar, .bottomBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(L10n.string("photos.media.close"), systemImage: "xmark") {
                        library.closePreview(); library.clearExport()
                    }.keyboardShortcut(.cancelAction)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    control("photos.media.previous", symbol: "chevron.backward") { library.adjacentPreview(-1) }
                        .disabled(!canMove(-1)).keyboardShortcut(.leftArrow, modifiers: [])
                    control("photos.media.next", symbol: "chevron.forward") { library.adjacentPreview(1) }
                        .disabled(!canMove(1)).keyboardShortcut(.rightArrow, modifiers: [])
                    Spacer()
                    if let photo = library.previewPhoto, photo.mediaType == "live" {
                        control("photos.media.playMotion", symbol: library.isPlayingMotion ? "stop.fill" : "livephoto") {
                            if library.isPlayingMotion { library.finishMotion() } else { library.playMotion() }
                        }
                    }
                    control("photos.media.save", symbol: "square.and.arrow.up") {
                        if let photo = library.previewPhoto { library.exportOriginal(photo) }
                    }.disabled(library.isSaving || library.previewPhoto == nil)
                    control("photos.media.info", symbol: "info.circle") { showsInformation.toggle() }
                        .disabled(library.previewPhoto == nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if library.isSaving {
                    HStack {
                        ProgressView(value: library.saveProgress).frame(maxWidth: 240)
                        Button(L10n.string("ui.2cd0f3be8738a86c")) { library.clearExport() }.frame(minHeight: 44)
                    }.padding(12).mobileGlass().padding(12)
                } else if let message = library.saveMessage {
                    Text(message).font(.callout).padding(12).mobileGlass().padding(12)
                }
            }
            .inspector(isPresented: $showsInformation) {
                if let photo = library.previewPhoto {
                    MobileSynologyPhotoInformation(photo: photo)
                        .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
                }
            }
        }
        .task(id: library.previewRevision) {
            image = nil
            didDecode = false
            let identity = library.previewPhoto?.id
            let decoded = await MobileSynologyImageDecoder.decode(library.previewData,
                maximumPixels: horizontalSizeClass == .regular ? 2_560 : 2_048)
            guard !Task.isCancelled, library.previewPhoto?.id == identity else { return }
            image = decoded
            didDecode = true
        }
        .sheet(isPresented: Binding(
            get: { library.exportURL != nil },
            set: { if !$0 { library.clearExport() } }
        ), onDismiss: { library.clearExport() }) {
            if let url = library.exportURL {
                MobileShareSheet(url: url) { library.clearExport() }
            }
        }
    }

    private func canMove(_ direction: Int) -> Bool {
        guard let id = library.previewPhoto?.id, let index = library.items.firstIndex(where: { $0.id == id }) else { return false }
        return library.items.indices.contains(index + direction)
    }
    private func control(_ key: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 44, height: 44) }
            .accessibilityLabel(L10n.string(key))
    }
}

private struct MobileSynologyPhotoInformation: View {
    let photo: SynologyPhoto
    var body: some View {
        Form {
            Section(L10n.string("photos.media.info")) {
                Text(photo.filename).textSelection(.enabled)
                value("photos.detail.taken", photo.takenAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
                value("photos.detail.added", photo.indexedAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
                value("photos.detail.size", photo.sizeBytes.formatted(.byteCount(style: .file).locale(L10n.locale)))
                value("photos.detail.format", photo.mediaType)
                if let width = photo.width, let height = photo.height {
                    value("photos.detail.resolution", L10n.string("photos.media.dimensions", width, height))
                }
                if let duration = photo.duration { value("photos.detail.duration", L10n.string("photos.seconds", duration.formatted(.number.precision(.fractionLength(0...1)).locale(L10n.locale)))) }
                if let rating = photo.rating { value("photos.detail.rating", L10n.string("photos.stars", rating)) }
            }
            Section(L10n.string("photos.filters.capture")) {
                optional("photos.detail.camera", photo.camera)
                optional("photos.detail.lens", photo.lens)
                optional("photos.detail.aperture", photo.aperture)
                optional("photos.detail.shutter", photo.exposureTime)
                optional("photos.detail.focal", photo.focalLength)
                optional("photos.detail.iso", photo.iso)
            }
            if !photo.addressComponents.isEmpty || photo.latitude != nil {
                Section(L10n.string("photos.detail.location")) {
                    if !photo.addressComponents.isEmpty { Text(photo.addressComponents.joined(separator: " · ")).textSelection(.enabled) }
                    if let latitude = photo.latitude, let longitude = photo.longitude {
                        value("photos.detail.coordinates", L10n.string("photos.coordinates",
                            latitude.formatted(.number.precision(.fractionLength(0...6)).locale(L10n.locale)),
                            longitude.formatted(.number.precision(.fractionLength(0...6)).locale(L10n.locale))))
                    }
                }
            }
            if let description = photo.description, !description.isEmpty {
                Section(L10n.string("photos.detail.description")) { Text(description).textSelection(.enabled) }
            }
            Section { Text(L10n.string("photos.readOnly.message")).font(.footnote).foregroundStyle(.secondary) }
        }
    }
    private func value(_ key: String, _ text: String) -> some View {
        LabeledContent(L10n.string(key)) { Text(text).textSelection(.enabled) }
    }
    @ViewBuilder private func optional(_ key: String, _ text: String?) -> some View {
        if let text, !text.isEmpty { value(key, text) }
    }
}

/// UIKit 原生缩放保持惯性、捏合、VoiceOver 和旋转后的边界，不模糊图像本身。
private struct MobileSynologyZoomImage: UIViewRepresentable {
    let image: UIImage
    let title: String

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> PhotoScrollView {
        let view = PhotoScrollView()
        view.delegate = context.coordinator
        view.minimumZoomScale = 1
        view.maximumZoomScale = 5
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.imageView.contentMode = .scaleAspectFit
        view.imageView.isAccessibilityElement = true
        view.imageView.accessibilityTraits = .image
        view.addSubview(view.imageView)
        return view
    }
    func updateUIView(_ view: PhotoScrollView, context: Context) {
        if view.imageView.image !== image {
            view.setZoomScale(1, animated: false)
            view.imageView.image = image
        }
        view.imageView.accessibilityLabel = title
    }
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? PhotoScrollView)?.imageView }
    }
    final class PhotoScrollView: UIScrollView {
        let imageView = UIImageView()
        private var previousSize: CGSize = .zero
        override func layoutSubviews() {
            super.layoutSubviews()
            if bounds.size != previousSize {
                previousSize = bounds.size
                setZoomScale(1, animated: false)
                imageView.frame = CGRect(origin: .zero, size: bounds.size)
                contentSize = bounds.size
            }
        }
    }
}
