import DsmCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class ProviderItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    private let identifier: NSFileProviderItemIdentifier
    private let parentIdentifier: NSFileProviderItemIdentifier
    private let itemName: String
    private let type: UTType
    private let directory: Bool
    private let size: Int64?
    private let modifiedAt: Date?
    private let version: NSFileProviderItemVersion
    private let keptOffline: Bool

    init(
        fileItem: FileItem,
        mapping: DesktopDriveMapping,
        keptOffline: Bool
    ) {
        identifier = Self.identifier(
            mappingID: mapping.id,
            remotePath: fileItem.path
        )
        parentIdentifier = Self.parentIdentifier(
            remotePath: fileItem.path,
            mapping: mapping
        )
        itemName = fileItem.name
        directory = fileItem.isDirectory
        type = fileItem.isDirectory
            ? .folder
            : (UTType(filenameExtension: fileItem.fileExtension ?? "") ?? .data)
        size = fileItem.sizeBytes
        modifiedAt = fileItem.times?.modifiedAt
        version = Self.version(
            path: fileItem.path,
            size: fileItem.sizeBytes,
            modifiedAt: fileItem.times?.modifiedAt
        )
        self.keptOffline = keptOffline
        super.init()
    }

    private init(
        root mapping: DesktopDriveMapping,
        keptOffline: Bool
    ) {
        identifier = .rootContainer
        parentIdentifier = .rootContainer
        itemName = mapping.displayName
        directory = true
        type = .folder
        size = nil
        modifiedAt = mapping.createdAt
        version = Self.version(
            path: "/",
            size: nil,
            modifiedAt: mapping.createdAt
        )
        self.keptOffline = keptOffline
        super.init()
    }

    private init(systemContainer identifier: NSFileProviderItemIdentifier) {
        self.identifier = identifier
        parentIdentifier = .rootContainer
        itemName = identifier.rawValue
        directory = true
        type = .folder
        size = nil
        modifiedAt = nil
        version = Self.version(
            path: identifier.rawValue,
            size: nil,
            modifiedAt: nil
        )
        keptOffline = false
        super.init()
    }

    static func root(
        configuration: DesktopDriveProviderConfiguration,
        keptOffline: Bool
    ) -> ProviderItem {
        ProviderItem(
            root: configuration.mapping,
            keptOffline: keptOffline
        )
    }

    static func trashContainer() -> ProviderItem {
        ProviderItem(systemContainer: .trashContainer)
    }

    var itemIdentifier: NSFileProviderItemIdentifier { identifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { parentIdentifier }
    var filename: String { itemName }
    var contentType: UTType { type }
    var itemVersion: NSFileProviderItemVersion { version }
    var documentSize: NSNumber? { size.map(NSNumber.init(value:)) }
    var contentModificationDate: Date? { modifiedAt }
    var capabilities: NSFileProviderItemCapabilities {
        if directory {
            return [.allowsReading, .allowsContentEnumerating]
        }
        return [.allowsReading]
    }
    var contentPolicy: NSFileProviderContentPolicy {
        keptOffline ? .downloadEagerlyAndKeepDownloaded : .downloadLazily
    }
    var isUploaded: Bool { true }

    private static func identifier(
        mappingID: UUID,
        remotePath: String
    ) -> NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(
            DesktopDriveItemIdentity.identifier(
                mappingID: mappingID,
                remotePath: remotePath
            ) ?? "invalid"
        )
    }

    private static func parentIdentifier(
        remotePath: String,
        mapping: DesktopDriveMapping
    ) -> NSFileProviderItemIdentifier {
        let parentPath = URL(fileURLWithPath: remotePath)
            .deletingLastPathComponent()
            .path
        switch mapping.scope {
        case .allShares:
            return parentPath == "/" || parentPath.isEmpty
                ? .rootContainer
                : identifier(mappingID: mapping.id, remotePath: parentPath)
        case .folder(let rootPath):
            return parentPath == DesktopDrivePath.normalized(rootPath)
                ? .rootContainer
                : identifier(mappingID: mapping.id, remotePath: parentPath)
        }
    }

    private static func version(
        path: String,
        size: Int64?,
        modifiedAt: Date?
    ) -> NSFileProviderItemVersion {
        let value = DesktopDriveItemVersionStrategy.make(
            path: path,
            sizeBytes: size,
            modifiedAt: modifiedAt
        )
        return NSFileProviderItemVersion(
            contentVersion: value.content,
            metadataVersion: value.metadata
        )
    }
}
