import DsmCore
import DsmLocalization
import XCTest
@testable import DsmMacExecutable

@MainActor
final class PhotoMediaPresentationTests: XCTestCase {
    func test媒体标识按套件类型区分照片视频实况与动态照片() {
        let language = AppLanguageStore.shared.selection
        defer { AppLanguageStore.shared.selection = language }
        for locale in [AppLanguageSelection.simplifiedChinese, .english] {
            AppLanguageStore.shared.selection = locale
            for (type, key, symbol) in [
                ("photo", "photos.mediaType.photo", "photo.fill"),
                ("photo360", "photos.mediaType.photo", "photo.fill"),
                ("video", "photos.mediaType.video", "video.fill"),
                ("video360", "photos.mediaType.video", "video.fill"),
                ("video_360", "photos.mediaType.video", "video.fill"),
                ("live", "photos.mediaType.live", "livephoto"),
                ("motion_photo", "photos.mediaType.motion", "livephoto"),
                ("burst", "photos.mediaType.burst", "square.stack.3d.up.fill"),
                ("future-format", "photos.mediaType.other", "doc")
            ] {
                // 扩展名固定，避免靠文件名把实况照片或未知格式误判为静态图片。
                let photo = SynologyPhoto(id: .init(profileID: UUID(), space: .personal, unitID: 1),
                    filename: "Synthetic.jpg", sizeBytes: 1, takenAt: .distantPast, indexedAt: .distantPast,
                    folderID: 1, mediaType: type)
                let media = PhotoMediaPresentation(photo: photo)
                XCTAssertEqual(media.symbol, symbol)
                XCTAssertEqual(media.title, L10n.string(key))
                XCTAssertNotEqual(media.title, key)
            }
        }
    }
}
