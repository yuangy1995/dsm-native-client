import DsmCore
import DsmLocalization
import SwiftUI
import UIKit

struct MobileSynologyPhotoPreview: View {
    @Bindable var model: MobileSynologyPhotosModel
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var image: UIImage?
    @State private var scale: CGFloat = 1
    @State private var savedScale: CGFloat = 1
    @State private var translation: CGSize = .zero
    @State private var savedTranslation: CGSize = .zero
    @State private var showsDetails = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    MobileAppearancePalette(scheme: scheme, increasedContrast: contrast == .increased).preview
                    media(in: geometry.size)
                    if model.isPreparingPreview {
                        ProgressView().padding(20).mobileGlass()
                            .accessibilityLabel(L10n.string("parity.photos.loading"))
                    }
                }
                .clipped()
            }
            .navigationTitle(model.previewPhoto?.filename ?? L10n.string("photos.media.open"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { previewToolbar }
            .safeAreaInset(edge: .bottom) {
                if model.isSaving {
                    ProgressView(value: model.saveProgress).padding(12)
                        .accessibilityLabel(L10n.string("photos.media.save"))
                } else if let message = model.saveMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary).padding(12).mobileGlass()
                }
            }
            .task(id: model.previewIdentity) {
                image = nil
                guard let data = model.previewData else { return }
                let decoded = await MobileSynologyImageDecoder.image(data, maximumPixelSize: 3_200)
                guard !Task.isCancelled else { return }
                image = decoded
            }
            .onChange(of: model.previewPhoto?.id) { _, _ in resetZoom() }
            .onDisappear { image = nil }
            .sheet(isPresented: $showsDetails) {
                if let photo = model.previewPhoto { MobileSynologyPhotoDetails(photo: photo) }
            }
            .sheet(item: Binding(
                get: { model.exportPresentation },
                set: { if $0 == nil { model.completeExport() } }
            )) { presentation in
                MobilePhotosExportSheet(presentation: presentation, completion: model.completeExport)
            }
        }
    }

    @ViewBuilder private func media(in size: CGSize) -> some View {
        if let source = model.previewSource {
            MobileMediaPlayer(source: source, title: model.previewPhoto?.filename ?? "")
        } else if let image {
            Image(uiImage: image)
                .resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(scale)
                .offset(translation)
                .contentShape(Rectangle())
                .gesture(MagnifyGesture().onChanged { value in
                    scale = min(6, max(1, savedScale * value.magnification))
                    translation = clamp(translation, in: size)
                }.onEnded { _ in
                    savedScale = scale
                    if scale == 1 { translation = .zero }
                    savedTranslation = translation
                })
                .simultaneousGesture(DragGesture().onChanged { value in
                    guard scale > 1 else { return }
                    translation = clamp(CGSize(width: savedTranslation.width + value.translation.width,
                        height: savedTranslation.height + value.translation.height), in: size)
                }.onEnded { value in
                    if scale == 1, abs(value.translation.width) > 80, abs(value.translation.height) < 80 {
                        model.adjacentPreview(value.translation.width < 0 ? 1 : -1)
                    }
                    savedTranslation = translation
                })
                .onTapGesture(count: 2) {
                    if scale > 1 { resetZoom() } else { scale = 2.5; savedScale = scale }
                }
                .accessibilityLabel(model.previewPhoto?.filename ?? "")
                .accessibilityAction(named: L10n.string("photos.media.previous")) { model.adjacentPreview(-1) }
                .accessibilityAction(named: L10n.string("photos.media.next")) { model.adjacentPreview(1) }
                .accessibilityAction(named: L10n.string("photos.media.zoom")) {
                    if scale > 1 { resetZoom() } else { scale = 2.5; savedScale = scale }
                }
        } else if let error = model.previewError {
            ContentUnavailableView {
                Label(L10n.string("photos.error.title"), systemImage: "photo.badge.exclamationmark")
            } description: { Text(error) } actions: {
                Button(L10n.string("photos.retry")) {
                    if let photo = model.previewPhoto { model.showPreview(photo) }
                }.frame(minHeight: 44)
            }
        } else if !model.isPreparingPreview, model.previewData != nil {
            ContentUnavailableView(L10n.string("photos.media.failed"), systemImage: "photo.badge.exclamationmark")
        }
    }

    @ToolbarContentBuilder private var previewToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(L10n.string("photos.media.close")) { model.closePreview() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Button { showsDetails = true } label: {
                    Label(L10n.string("photos.media.info"), systemImage: "info.circle")
                }
                Button {
                    if let photo = model.previewPhoto { model.prepareExport(photo, intent: .exportCopy) }
                } label: { Label(L10n.string("photos.media.save"), systemImage: "square.and.arrow.down") }
                    .disabled(model.isSaving)
                    .keyboardShortcut("s", modifiers: .command)
                Button {
                    if let photo = model.previewPhoto { model.prepareExport(photo, intent: .share) }
                } label: { Label(L10n.string("mobile.photos.action.share"), systemImage: "square.and.arrow.up") }
                    .disabled(model.isSaving)
            } label: {
                Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel(L10n.string("mobile.photos.item-actions", model.previewPhoto?.filename ?? ""))
        }
        ToolbarItemGroup(placement: .bottomBar) {
            Button { model.adjacentPreview(-1) } label: {
                Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(L10n.string("photos.media.previous"))
            .keyboardShortcut(.leftArrow, modifiers: [])
            .disabled(!model.canPreviewAdjacent(-1))
            Spacer()
            if model.previewPhoto?.mediaType == "live" {
                Button {
                    if model.isPlayingMotion { model.finishMotion() } else { model.playMotion() }
                } label: {
                    Image(systemName: model.isPlayingMotion ? "pause.circle" : "livephoto")
                        .frame(minWidth: 44, minHeight: 44)
                }.accessibilityLabel(L10n.string(model.isPlayingMotion ? "parity.photos.stopMotion" : "photos.media.playMotion"))
            }
            Button { showsDetails = true } label: {
                Image(systemName: "info.circle").frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel(L10n.string("photos.media.info"))
            Spacer()
            Button { model.adjacentPreview(1) } label: {
                Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(L10n.string("photos.media.next"))
            .keyboardShortcut(.rightArrow, modifiers: [])
            .disabled(!model.canPreviewAdjacent(1))
        }
    }

    private func clamp(_ proposed: CGSize, in size: CGSize) -> CGSize {
        let x = size.width * (scale - 1) / 2
        let y = size.height * (scale - 1) / 2
        return CGSize(width: min(x, max(-x, proposed.width)), height: min(y, max(-y, proposed.height)))
    }

    private func resetZoom() {
        scale = 1; savedScale = 1; translation = .zero; savedTranslation = .zero
    }
}

private struct MobileSynologyPhotoDetails: View {
    let photo: SynologyPhoto
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(photo.filename).font(.headline).textSelection(.enabled) }
                Section {
                    value("photos.detail.taken", photo.takenAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
                    value("photos.detail.added", photo.indexedAt.formatted(.dateTime.year().month().day().hour().minute().locale(L10n.locale)))
                    value("photos.detail.size", photo.sizeBytes.formatted(.byteCount(style: .file)))
                    value("photos.detail.format", photo.mediaType)
                    if let width = photo.width, let height = photo.height {
                        value("photos.detail.resolution", L10n.string("photos.media.dimensions", width, height))
                    }
                }
                Section(L10n.string("photos.filters.capture")) {
                    if let camera = photo.camera { value("photos.detail.camera", camera) }
                    if let lens = photo.lens { value("photos.detail.lens", lens) }
                    if let aperture = photo.aperture { value("photos.detail.aperture", aperture) }
                    if let exposure = photo.exposureTime { value("photos.detail.shutter", exposure) }
                    if let focal = photo.focalLength { value("photos.detail.focal", focal) }
                    if let iso = photo.iso { value("photos.detail.iso", iso) }
                    if let rating = photo.rating { value("photos.detail.rating", L10n.string("photos.stars", rating)) }
                    if let duration = photo.duration {
                        value("photos.detail.duration", L10n.string("photos.seconds", duration.formatted(.number.locale(L10n.locale))))
                    }
                }
                if let description = photo.description, !description.isEmpty {
                    Section(L10n.string("photos.detail.description")) { Text(description).textSelection(.enabled) }
                }
                if !photo.addressComponents.isEmpty {
                    Section(L10n.string("photos.detail.location")) { Text(photo.addressComponents.joined(separator: ", ")).textSelection(.enabled) }
                }
                if let latitude = photo.latitude, let longitude = photo.longitude {
                    value("photos.detail.coordinates", L10n.string("photos.coordinates",
                        latitude.formatted(.number.locale(L10n.locale)), longitude.formatted(.number.locale(L10n.locale))))
                }
            }
            .navigationTitle(L10n.string("photos.media.info"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.string("photos.media.close")) { dismiss() }
                }
            }
            .mobileAppearanceRoot()
        }.presentationDetents([.medium, .large])
    }

    private func value(_ key: String, _ text: String) -> some View {
        LabeledContent(L10n.string(key)) { Text(text).textSelection(.enabled) }
    }
}
