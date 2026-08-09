import DsmCore
import Foundation
import ImageIO
import Observation

@MainActor
@Observable
final class MobilePhotoViewerModel {
    private(set) var state = MobilePhotoViewerState()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fileRepositoryIdentity: ObjectIdentifier?

    @discardableResult
    func activate(
        profileID: UUID?,
        fileRepository: AnyObject? = nil
    ) -> Bool {
        let nextFileIdentity = fileRepository.map(ObjectIdentifier.init)
        guard state.profileID != profileID ||
                fileRepositoryIdentity != nextFileIdentity else { return false }
        generation &+= 1
        state = MobilePhotoViewerState(profileID: profileID)
        fileRepositoryIdentity = nextFileIdentity
        return true
    }

    @discardableResult
    func open(
        _ item: PhotoLibraryItem,
        visibleItems: [PhotoLibraryItem]
    ) -> Bool {
        guard let profileID = state.profileID,
              item.profileID == profileID,
              item.kind != .folder else { return false }

        var identities = Set<String>()
        let snapshot = visibleItems.filter { candidate in
            guard candidate.profileID == profileID,
                  candidate.kind != .folder else { return false }
            return identities.insert(Self.identity(candidate)).inserted
        }
        guard let selectedIndex = snapshot.firstIndex(where: {
            Self.identity($0) == Self.identity(item)
        }) else { return false }

        generation &+= 1
        state.snapshot = snapshot
        state.selectedIndex = selectedIndex
        state.metadataPhase = .loading
        state.metadata = Self.fileMetadata(item.fileItem, kind: item.kind)
        return true
    }

    func movePrevious() -> PhotoLibraryItem? {
        guard state.canMovePrevious, let selectedIndex = state.selectedIndex else { return nil }
        return select(index: snapshotIndex(before: selectedIndex))
    }

    func moveNext() -> PhotoLibraryItem? {
        guard state.canMoveNext, let selectedIndex = state.selectedIndex else { return nil }
        return select(index: snapshotIndex(after: selectedIndex))
    }

    func close() {
        let profileID = state.profileID
        generation &+= 1
        state = MobilePhotoViewerState(profileID: profileID)
    }

    func loadMetadata(from preview: MobileFilePreviewState) async {
        guard let selected = state.selectedItem,
              preview.profileID == selected.profileID,
              preview.selectedItem.map(Self.identity) == Self.identity(selected.fileItem) else { return }

        let requestGeneration = generation
        let resolved = preview.details ?? preview.selectedItem ?? selected.fileItem
        var metadata = Self.fileMetadata(resolved, kind: selected.kind)
        state.metadata = metadata
        state.metadataPhase = preview.phase == .loadingDetails || preview.phase == .loadingPreview
            ? .loading
            : .content

        guard selected.kind == .image,
              preview.phase == .ready,
              preview.content == .quickLook,
              let artifactURL = preview.artifactURL else { return }

        let artifact = await Task.detached(priority: .utility) {
            Self.readImageMetadata(at: artifactURL)
        }.value
        guard requestGeneration == generation,
              state.selectedItem.map(Self.identity) == Self.identity(selected),
              preview.artifactURL == artifactURL else { return }
        metadata.pixelWidth = artifact.pixelWidth
        metadata.pixelHeight = artifact.pixelHeight
        metadata.capturedAt = artifact.capturedAt
        metadata.cameraMake = artifact.cameraMake
        metadata.cameraModel = artifact.cameraModel
        state.metadata = metadata
        state.metadataPhase = .content
    }

    private func select(index: Int) -> PhotoLibraryItem? {
        guard state.snapshot.indices.contains(index) else { return nil }
        generation &+= 1
        state.selectedIndex = index
        let item = state.snapshot[index]
        state.metadata = Self.fileMetadata(item.fileItem, kind: item.kind)
        state.metadataPhase = .loading
        return item
    }

    private func snapshotIndex(before index: Int) -> Int { state.snapshot.index(before: index) }
    private func snapshotIndex(after index: Int) -> Int { state.snapshot.index(after: index) }

    private static func identity(_ item: PhotoLibraryItem) -> String {
        "\(item.profileID.uuidString)|\(item.path)|\(item.modifiedAt?.timeIntervalSince1970 ?? -1)|\(item.sizeBytes ?? -1)|\(item.kind.rawValue)"
    }

    private static func identity(_ item: FileItem) -> String {
        let kind: PhotoLibraryItemKind = PreviewKind.classify(item) == .video ? .video : .image
        return "\(item.profileID.uuidString)|\(item.path)|\(item.times?.modifiedAt?.timeIntervalSince1970 ?? -1)|\(item.sizeBytes ?? -1)|\(kind.rawValue)"
    }

    private static func fileMetadata(
        _ item: FileItem,
        kind: PhotoLibraryItemKind
    ) -> MobilePhotoMetadata {
        MobilePhotoMetadata(
            name: item.name,
            kind: kind,
            sizeBytes: item.sizeBytes,
            createdAt: item.times?.createdAt,
            modifiedAt: item.times?.modifiedAt
        )
    }

    nonisolated private static func readImageMetadata(at url: URL) -> ImageArtifactMetadata {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return ImageArtifactMetadata()
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return ImageArtifactMetadata(
            pixelWidth: Self.positiveInt(properties[kCGImagePropertyPixelWidth]),
            pixelHeight: Self.positiveInt(properties[kCGImagePropertyPixelHeight]),
            capturedAt: Self.captureDate(exif?[kCGImagePropertyExifDateTimeOriginal]),
            cameraMake: Self.safeText(tiff?[kCGImagePropertyTIFFMake]),
            cameraModel: Self.safeText(tiff?[kCGImagePropertyTIFFModel])
        )
    }

    nonisolated private static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, number.intValue > 0 else { return nil }
        return number.intValue
    }

    nonisolated private static func safeText(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 160 else { return nil }
        return trimmed
    }

    nonisolated private static func captureDate(_ value: Any?) -> Date? {
        guard let text = safeText(value) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text)
    }
}

private struct ImageArtifactMetadata: Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var capturedAt: Date?
    var cameraMake: String?
    var cameraModel: String?
}
