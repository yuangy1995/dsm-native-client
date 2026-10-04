import DsmPhotosFeature
import DsmLocalization
import SwiftUI
import UIKit

/// 共享模型负责独立分页与视频结束推进；移动层仅提供触控和系统播放器。
struct MobilePhotoSlideshowView: View {
    @Bindable var model: SynologyPhotosModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var decoding = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let source = model.previewSource {
                    MobileMediaPlayer(source: source, title: model.previewPhoto?.filename ?? "",
                        isPlaying: model.isSlideshowPlaying, onFinished: model.slideshowVideoEnded, onFailure: model.slideshowPlaybackFailed)
                        .id(model.slideshowMediaID)
                } else if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                        .accessibilityLabel(model.previewPhoto?.filename ?? "")
                        .accessibilityIdentifier("mobile.photos.slideshow.image")
                } else if model.isPreparingPreview || decoding {
                    ProgressView().tint(.white)
                } else {
                    ContentUnavailableView {
                        Label(L10n.string("photos.media.open"), systemImage: "photo")
                    } description: { Text(model.previewError ?? L10n.string("photos.media.failed")) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if let error = model.slideshowError { Text(error).padding(8).accessibilityIdentifier("mobile.photos.slideshow.error") }
            VStack(spacing: 4) {
                Text(model.previewPhoto?.filename ?? "").font(.callout).lineLimit(2).truncationMode(.middle)
                    .accessibilityIdentifier("mobile.photos.slideshow.filename")
                HStack {
                    Button { model.advanceSlideshow(-1) } label: { Label(L10n.string("photos.media.previous"), systemImage: "backward.end.fill") }
                        .keyboardShortcut(.leftArrow, modifiers: []).accessibilityIdentifier("mobile.photos.slideshow.previous")
                    Spacer()
                    Button { model.toggleSlideshowPlayback() } label: {
                        Label(L10n.string(model.isSlideshowPlaying ? "photos.slideshow.pause" : "photos.slideshow.play"),
                              systemImage: model.isSlideshowPlaying ? "pause.fill" : "play.fill")
                    }.keyboardShortcut(.space, modifiers: []).accessibilityIdentifier("mobile.photos.slideshow.playback")
                    Spacer()
                    Button { model.advanceSlideshow(1) } label: { Label(L10n.string("photos.media.next"), systemImage: "forward.end.fill") }
                        .keyboardShortcut(.rightArrow, modifiers: []).accessibilityIdentifier("mobile.photos.slideshow.next")
                    Spacer()
                    Button { model.stopSlideshow() } label: { Label(L10n.string("photos.slideshow.stop"), systemImage: "stop.fill") }
                        .keyboardShortcut(.cancelAction).accessibilityIdentifier("mobile.photos.slideshow.stop")
                }.labelStyle(.iconOnly).buttonStyle(SlideshowButtonStyle())
                if model.isLoadingSlideshow { ProgressView().tint(.white) }
            }.padding()
        }
        .background(.black).foregroundStyle(.white).environment(\.colorScheme, .dark)
        .task(id: model.previewData) {
            image = nil; decoding = model.previewData != nil
            let decoded = await MobileSynologyPhotoImage.decode(model.previewData, maximumPixels: 2_048)
            guard !Task.isCancelled else { return }
            image = decoded; decoding = false
            if model.previewData != nil, decoded == nil { model.slideshowPlaybackFailed() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active, model.isSlideshowPlaying { model.toggleSlideshowPlayback() }
        }
    }
}

private struct SlideshowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: 44, minHeight: 44)
            .background(configuration.isPressed ? Color.white.opacity(0.25) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
