import DsmCore
import DsmLocalization
import DsmPhotosFeature
import SwiftUI

/// nil 表示当前选择；单张预览始终传入原照片，不能隐式导出整个相似组。
struct MobilePhotoExportActions: View {
    let session: MobileSynologyPhotosSession
    var photos: [SynologyPhoto]?

    private var targets: [SynologyPhoto] { photos ?? session.model.selectedPhotos }
    private var archive: SynologyPhotoArchiveTarget? { photos == nil ? session.model.selectedArchive : nil }
    private var similar: Bool { photos == nil && session.model.selectedCategory == .similar }
    private var canExport: Bool {
        if let archive { return !session.isExporting && session.model.canDownloadArchive(archive) }
        return session.canExport(targets, includingSimilarMembers: similar)
    }

    var body: some View {
        Menu {
            Button(L10n.string("photos.download.original")) { export(.original) }
                .accessibilityIdentifier("mobile.photos.export.original")
            Button(L10n.string("photos.download.jpeg")) { export(.optimizedJPEG) }
                .accessibilityIdentifier("mobile.photos.export.jpeg")
            if archive == nil, session.canExport(targets, format: .originalSizeJPEG, includingSimilarMembers: similar) {
                Button(L10n.string("photos.download.originalSizeJPEG")) { export(.originalSizeJPEG) }
                    .accessibilityIdentifier("mobile.photos.export.fullJPEG")
            }
        } label: { Label(L10n.string("mobile.photos.export.save"), systemImage: "square.and.arrow.down") }
            .disabled(!canExport).accessibilityIdentifier("mobile.photos.export.save")
        Button { export(.original, sharing: true) } label: {
            Label(L10n.string("mobile.documents.share"), systemImage: "square.and.arrow.up")
        }.disabled(!canExport).accessibilityIdentifier("mobile.photos.export.share")
    }

    private func export(_ format: SynologyPhotoDownloadFormat, sharing: Bool = false) {
        if let photos { session.exportPhotos(photos, format: format, sharing: sharing) }
        else { session.exportSelection(format: format, sharing: sharing) }
    }
}

struct MobilePhotoArchiveExportMenu: View {
    let session: MobileSynologyPhotosSession
    let target: SynologyPhotoArchiveTarget
    let name: String

    private var title: String {
        switch target {
        case .album: L10n.string("photos.download.album")
        case .folder: L10n.string("photos.download.folder")
        case .selection: L10n.string("photos.download.selection")
        }
    }

    var body: some View {
        Menu {
            Button(L10n.string("photos.download.original")) { session.exportArchive(target, format: .original, name: name) }
                .accessibilityIdentifier("mobile.photos.export.archiveOriginal")
            Button(L10n.string("photos.download.jpeg")) { session.exportArchive(target, format: .optimizedJPEG, name: name) }
                .accessibilityIdentifier("mobile.photos.export.archiveJPEG")
            Button(L10n.string("mobile.documents.share")) { session.exportArchive(target, format: .original, name: name, sharing: true) }
        } label: { Label(title, systemImage: "square.and.arrow.down") }
            .disabled(session.isExporting || !session.model.canDownloadArchive(target))
            .accessibilityIdentifier("mobile.photos.export.archive")
    }
}

struct MobilePhotoBrowsingControls: View {
    @Bindable var model: SynologyPhotosModel

    var body: some View {
        Button { model.startSlideshow() } label: { Label(L10n.string("photos.slideshow.start"), systemImage: "play.rectangle") }
            .disabled(!model.canStartSlideshow).accessibilityIdentifier("mobile.photos.slideshow.start")
        Menu {
            Button { changeSize(-1) } label: { Label(L10n.string("photos.thumbnail.smaller"), systemImage: "minus.magnifyingglass") }
                .disabled(model.thumbnailSize == .small).accessibilityIdentifier("mobile.photos.thumbnail.smaller")
            Button { changeSize(1) } label: { Label(L10n.string("photos.thumbnail.larger"), systemImage: "plus.magnifyingglass") }
                .disabled(model.thumbnailSize == .extraLarge).accessibilityIdentifier("mobile.photos.thumbnail.larger")
        } label: { Label(L10n.string("photos.thumbnail.size"), systemImage: "square.grid.3x3") }
            .accessibilityValue(L10n.string("photos.thumbnail.level", model.thumbnailSize.rawValue + 1))
            .accessibilityIdentifier("mobile.photos.thumbnail.size")
    }

    private func changeSize(_ delta: Int) {
        model.thumbnailSize = PhotoThumbnailSize(rawValue: min(4, max(0, model.thumbnailSize.rawValue + delta))) ?? .medium
    }
}
