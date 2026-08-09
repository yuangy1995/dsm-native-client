import DsmCore
import Foundation

enum MobilePhotoMetadataPhase: Equatable, Sendable {
    case inactive
    case loading
    case content
    case unavailable
    case failed
}

struct MobilePhotoMetadata: Equatable, Sendable {
    var name: String
    var kind: PhotoLibraryItemKind
    var sizeBytes: Int64?
    var createdAt: Date?
    var modifiedAt: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var capturedAt: Date?
    var cameraMake: String?
    var cameraModel: String?
}

struct MobilePhotoViewerState: Equatable, Sendable {
    var profileID: UUID?
    var snapshot: [PhotoLibraryItem] = []
    var selectedIndex: Int?
    var metadataPhase: MobilePhotoMetadataPhase = .inactive
    var metadata: MobilePhotoMetadata?

    var selectedItem: PhotoLibraryItem? {
        guard let selectedIndex, snapshot.indices.contains(selectedIndex) else { return nil }
        return snapshot[selectedIndex]
    }

    var canMovePrevious: Bool {
        guard let selectedIndex else { return false }
        return selectedIndex > snapshot.startIndex
    }

    var canMoveNext: Bool {
        guard let selectedIndex, !snapshot.isEmpty else { return false }
        return selectedIndex < snapshot.index(before: snapshot.endIndex)
    }
}
