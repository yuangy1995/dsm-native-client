import DsmPhotosFeature
import DsmCore
import DsmLocalization
import SwiftUI
import UIKit

struct MobileSynologyPhotoPreview: View {
    @Bindable var session: MobileSynologyPhotosSession
    @Bindable var model: SynologyPhotosModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var showsInfo = false
    @State private var image: UIImage?
    @State private var isDecoding = false
    @State private var showsSimilar = false

    var body: some View {
        NavigationStack {
            Group {
                if sizeClass == .regular && showsInfo {
                    HStack(spacing: 0) {
                        media.frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        details.frame(minWidth: 240, idealWidth: 300, maxWidth: 360)
                    }
                } else {
                    VStack(spacing: 0) {
                        media.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showsInfo { details.frame(maxHeight: 300) }
                    }
                }
            }
            .navigationTitle(model.previewPhoto?.filename ?? L10n.string("photos.media.open"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("photos.media.close")) { model.closePreview() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button { model.adjacentPreview(-1) } label: {
                        Label(L10n.string("photos.media.previous"), systemImage: "chevron.left")
                    }.frame(minWidth: 44, minHeight: 44).keyboardShortcut(.leftArrow, modifiers: [])
                    Button { model.adjacentPreview(1) } label: {
                        Label(L10n.string("photos.media.next"), systemImage: "chevron.right")
                    }.frame(minWidth: 44, minHeight: 44).keyboardShortcut(.rightArrow, modifiers: [])
                    Spacer()
                    Button { showsInfo.toggle() } label: {
                        Label(L10n.string("photos.media.info"), systemImage: "info.circle")
                    }.frame(minWidth: 44, minHeight: 44)
                    if let photo = model.previewPhoto {
                        if photo.similarGroup != nil || model.previewSimilarDetail != nil {
                            Button { showsSimilar = true } label: { Label(L10n.string("mobile.photos.similar.open"), systemImage: "square.stack.3d.up") }
                                .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("mobile.photos.similar.open")
                        }
                        if let editor = session.editor {
                            Menu {
                                MobilePhotoEditActions(editor: editor, photos: [photo])
                                if let recognition = session.recognition { MobilePhotoRecognitionActions(recognition: recognition, photos: [photo]) }
                                if let faces = session.faces, model.managementFeatures.contains(.manualFaces), photo.mediaType != "video" {
                                    Button(L10n.string("photos.faces.edit")) { faces.begin() }
                                        .disabled(!faces.canBegin).accessibilityIdentifier("mobile.photos.faces.begin")
                                }
                                Button(L10n.string("photos.media.rotate")) { model.rotatePreview() }
                                    .disabled(!model.canRotatePreview).accessibilityIdentifier("mobile.photos.rotate")
                                if let repair = session.previewRepair {
                                    Button(L10n.string("photos.preview.rebuild")) { repair.regenerate([photo], fromPreview: true) }
                                        .disabled(!repair.canRegenerate([photo], fromPreview: true)).accessibilityIdentifier("mobile.photos.repair.preview")
                                }
                            } label: {
                                Label(L10n.string("mobile.photos.edit.title"), systemImage: "pencil")
                            }.frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("mobile.photos.edit.preview")
                        }
                        Menu {
                            if let folders = session.folders { MobilePhotoFolderActions(folders: folders, photos: [photo], targets: []) }
                            Button(L10n.string("photos.media.save")) { session.exportOriginal(photo) }
                            Button(L10n.string("mobile.documents.share")) { session.exportOriginal(photo, sharing: true) }
                            Button(L10n.string("photos.delete.action"), role: .destructive) { model.requestDeletion(photo) }
                                .disabled(!model.canDeletePhotos([photo])).accessibilityIdentifier("mobile.photos.preview.delete")
                        } label: {
                            Label(L10n.string("photos.media.save"), systemImage: "square.and.arrow.up")
                        }.frame(minWidth: 44, minHeight: 44).disabled(session.isExporting)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) { MobilePhotoManagementStatus(model: model); MobilePhotoSimilarStatus(model: model) }
            }
        }
        .onAppear { showsInfo = model.displayPreferences?.showsPreviewInfo == true }
        .task(id: model.previewData) {
            image = nil
            isDecoding = model.previewData != nil
            let decoded = await MobileSynologyPhotoImage.decode(model.previewData, maximumPixels: 2_048)
            guard !Task.isCancelled else { return }
            image = decoded
            isDecoding = false
        }
        .modifier(MobileSynologyPhotoDeletionPresentation(model: model, active: !showsSimilar))
        .sheet(isPresented: $showsSimilar) { MobilePhotoSimilarPanel(session: session, model: model) }
        .modifier(MobilePhotoEditPresentation(session: session, active: true))
        .modifier(MobilePhotoRecognitionPresentation(session: session, active: true))
        .modifier(MobilePhotoFacePresentation(session: session))
        .modifier(MobilePhotoFolderPresentation(session: session, active: true))
        .modifier(MobileSynologyPhotoExportPresentation(session: session, active: true))
    }

    @ViewBuilder private var media: some View {
        ZStack(alignment: .topLeading) {
            if let source = model.previewSource, model.previewPhoto?.mediaType == "video" || model.isPlayingMotion {
                // 复用证书钉扎和同源范围读取，不把带凭据 URL 直接交给系统播放器。
                MobileMediaPlayer(source: source, title: model.previewPhoto?.filename ?? "")
                    .id(source.request.url)
            } else if let image {
                MobileSynologyPhotoZoomView(image: image, title: model.previewPhoto?.filename ?? "")
                    .id(model.previewPhoto?.id)
            } else if model.isPreparingPreview || isDecoding {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label(L10n.string("photos.media.open"), systemImage: "photo")
                } description: { Text(model.previewError ?? L10n.string("photos.media.failed")) } actions: {
                    if let photo = model.previewPhoto {
                        Button(L10n.string("photos.retry")) { model.showPreview(photo) }
                        Button(L10n.string("photos.media.save")) { session.exportOriginal(photo) }
                    }
                }
            }
            if model.previewPhoto?.mediaType == "live" {
                Button {
                    if model.isPlayingMotion { model.finishMotion() } else { model.playMotion() }
                } label: {
                    Label(L10n.string("photos.media.playMotion"), systemImage: model.isPlayingMotion ? "pause.circle" : "livephoto")
                }.buttonStyle(.bordered).frame(minHeight: 44).padding(12)
            }
            if let error = model.previewError, image != nil {
                VStack { Spacer(); Text(error).padding().background(.regularMaterial) }
            }
        }
        .background(Color(uiColor: .systemBackground))
    }

    private var details: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let photo = model.previewPhoto {
                    Text(photo.filename).font(.headline).textSelection(.enabled)
                    row("photos.detail.taken", model.formattedPhotoDate(photo.takenAt, includesTime: true))
                    row("photos.detail.added", model.formattedPhotoDate(photo.indexedAt, includesTime: true))
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
                    row("photos.detail.location", formattedLocation(photo.addressComponents))
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
                    row("photos.category.tags", formattedLocation(photo.tags?.map(\.name) ?? []))
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }.background(.regularMaterial)
    }

    private func formattedLocation(_ components: [String]) -> String? {
        let formatter = ListFormatter()
        formatter.locale = L10n.locale
        return formatter.string(from: components)
    }

    @ViewBuilder private func row(_ key: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string(key)).font(.caption).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }.accessibilityElement(children: .combine)
        }
    }
}

/// 导出文件只在用户选择系统保存／分享后交给系统；关闭时清理本次私有临时目录。
struct MobileSynologyPhotoExportPresentation: ViewModifier {
    @Bindable var session: MobileSynologyPhotosSession
    let active: Bool

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom) {
                if active && session.isExporting {
                    HStack {
                        ProgressView(value: session.exportProgress)
                        Button(L10n.string("photos.delete.cancel")) { session.cancelExport() }.frame(minHeight: 44)
                    }.padding().background(.bar)
                }
            }
            .sheet(item: Binding(get: { active ? session.export : nil }, set: { session.export = $0 }), onDismiss: session.finishExport) { item in
                if item.sharing {
                    MobileShareSheet(url: item.url, completion: session.finishExport)
                } else {
                    MobileDocumentExporter(url: item.url, completion: session.finishExport)
                }
            }
            .alert(L10n.string("photos.media.save"), isPresented: Binding(
                get: { active && session.exportError != nil },
                set: { if !$0 { session.exportError = nil } }
            )) {
                Button(L10n.string("photos.media.close"), role: .cancel) { session.exportError = nil }
            } message: { Text(session.exportError ?? "") }
    }
}

struct MobileSynologyPhotoDeletionPresentation: ViewModifier {
    @Bindable var model: SynologyPhotosModel
    let active: Bool

    func body(content: Content) -> some View {
        content
            .alert(L10n.string("mobile.photos.deletion.title"), isPresented: Binding(
                get: { active && !model.deletionCandidates.isEmpty },
                set: { if !$0 { model.deletionCandidates = [] } }
            ), presenting: model.deletionCandidates) { photos in
                Button(L10n.string("photos.delete.cancel"), role: .cancel) { model.deletionCandidates = [] }
                Button(L10n.string("photos.delete.action"), role: .destructive) {
                    model.confirmDeletion(photos)
                    if model.isDeleting { model.clearSelection(); model.closePreview() }
                }.accessibilityIdentifier("mobile.photos.deletion.confirm")
            } message: { photos in
                if let kept = model.deletionKeptCount {
                    Text(L10n.string("photos.similar.cleanupConfirm", kept, photos.count))
                } else if photos.count == 1 {
                    Text(L10n.string("photos.delete.confirm", photos[0].filename))
                } else { Text(L10n.string("mobile.photos.deletion.confirmMany", photos.count)) }
            }
            .alert(L10n.string("photos.delete.title"), isPresented: Binding(
                get: { active && model.deletionError != nil },
                set: { if !$0 { model.deletionError = nil } }
            )) {
                Button(L10n.string("photos.media.close"), role: .cancel) { model.deletionError = nil }
            } message: { Text(model.deletionError ?? "") }
    }
}

struct MobilePhotoDeletionStatus: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if model.isDeleting || model.isCheckingDeletion || model.deletionRecoveryError != nil || model.deletionMessage != nil {
            if typeSize.isAccessibilitySize {
                ScrollView { controls }.frame(height: 280).clipped()
                    .accessibilityIdentifier("mobile.photos.deletion.controls")
            } else { controls }
        }
    }
    private var controls: some View {
        VStack(spacing: 8) {
            if model.isDeleting || model.isCheckingDeletion { ProgressView().accessibilityIdentifier("mobile.photos.deletion.loading") }
            if let error = model.deletionRecoveryError {
                Text(error).font(.callout).fixedSize(horizontal: false, vertical: true)
                Button { Task { await model.retryDeletionRecovery() } } label: { Text(L10n.string("photos.retry")) }
                    .disabled(model.isDeleting || model.isCheckingDeletion).accessibilityIdentifier("mobile.photos.deletion.retry")
            } else {
                if let message = model.deletionMessage {
                    Text(message).font(.callout).fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("mobile.photos.deletion.status")
                }
                if model.pendingDeletionPhoto != nil {
                    Button { Task { await model.reviewPendingDeletion() } } label: { Text(L10n.string("photos.library.refresh")) }
                        .disabled(model.isDeleting).accessibilityIdentifier("mobile.photos.deletion.refresh")
                }
                if model.remainingDeletionCount > 0 {
                    Button { model.requestRemainingDeletion() } label: {
                        Text(L10n.string("mobile.photos.deletion.continue", model.remainingDeletionCount)).fixedSize(horizontal: false, vertical: true)
                    }.disabled(!model.canContinueDeletion).accessibilityIdentifier("mobile.photos.deletion.continue")
                    Button { model.cancelRemainingDeletion() } label: {
                        Text(L10n.string("mobile.photos.deletion.cancelRemaining")).fixedSize(horizontal: false, vertical: true)
                    }.disabled(model.isDeleting || model.isCheckingDeletion).accessibilityIdentifier("mobile.photos.deletion.cancelRemaining")
                }
            }
        }.multilineTextAlignment(.center).frame(maxWidth: .infinity).buttonStyle(.bordered).controlSize(.large).padding(8)
    }
}

private struct MobileSynologyPhotoZoomView: UIViewRepresentable {
    let image: UIImage
    let title: String
    func makeUIView(context: Context) -> PhotoScrollView { PhotoScrollView() }
    func updateUIView(_ view: PhotoScrollView, context: Context) { view.show(image, title: title) }

    final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
        private let photoView = UIImageView()
        private var lastBounds = CGSize.zero
        private var needsFit = true
        override init(frame: CGRect) {
            super.init(frame: frame)
            delegate = self
            addSubview(photoView)
            showsHorizontalScrollIndicator = false
            showsVerticalScrollIndicator = false
            bouncesZoom = true
            let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom))
            doubleTap.numberOfTapsRequired = 2
            addGestureRecognizer(doubleTap)
            isAccessibilityElement = true
            accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: L10n.string("preview.zoom.in"), target: self, selector: #selector(zoomIn)),
                UIAccessibilityCustomAction(name: L10n.string("preview.zoom.out"), target: self, selector: #selector(zoomOut))
            ]
        }
        required init?(coder: NSCoder) { nil }
        func show(_ image: UIImage, title: String) {
            accessibilityLabel = title
            guard photoView.image !== image else { return }
            zoomScale = 1
            photoView.image = image
            photoView.frame = CGRect(origin: .zero, size: image.size)
            contentSize = image.size
            needsFit = true
            setNeedsLayout()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let size = photoView.image?.size, size.width > 0, size.height > 0,
                  bounds.width > 0, bounds.height > 0 else { return }
            if needsFit || lastBounds != bounds.size {
                let relativeZoom = needsFit ? 1 : zoomScale / max(minimumZoomScale, 0.001)
                minimumZoomScale = min(bounds.width / size.width, bounds.height / size.height)
                maximumZoomScale = max(4 * minimumZoomScale, 1)
                zoomScale = min(maximumZoomScale, max(minimumZoomScale, minimumZoomScale * relativeZoom))
                needsFit = false
                lastBounds = bounds.size
            }
            contentInset = UIEdgeInsets(top: max(0, (bounds.height - contentSize.height) / 2),
                left: max(0, (bounds.width - contentSize.width) / 2), bottom: 0, right: 0)
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { photoView }
        func scrollViewDidZoom(_ scrollView: UIScrollView) { setNeedsLayout() }
        @objc private func toggleZoom() { setZoomScale(zoomScale > minimumZoomScale * 1.05 ? minimumZoomScale : min(maximumZoomScale, minimumZoomScale * 2), animated: !UIAccessibility.isReduceMotionEnabled) }
        @objc private func zoomIn() -> Bool { setZoomScale(min(maximumZoomScale, zoomScale * 1.5), animated: false); return true }
        @objc private func zoomOut() -> Bool { setZoomScale(max(minimumZoomScale, zoomScale / 1.5), animated: false); return true }
    }
}
