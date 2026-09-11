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
    private let writable: Bool
    private let movable: Bool
    private let deletable: Bool

    init(
        fileItem: FileItem,
        mapping: DesktopDriveMapping,
        keptOffline: Bool,
        identifiersByPath: [String: String] = [:],
        writable: Bool = false,
        deletable: Bool = false
    ) {
        identifier = identifiersByPath[fileItem.path].map { NSFileProviderItemIdentifier($0) } ?? Self.identifier(
            mappingID: mapping.id,
            remotePath: fileItem.path
        )
        let defaultParent = Self.parentIdentifier(
            remotePath: fileItem.path,
            mapping: mapping
        )
        parentIdentifier = defaultParent == .rootContainer ? defaultParent :
            identifiersByPath[(fileItem.path as NSString).deletingLastPathComponent].map { NSFileProviderItemIdentifier($0) } ?? defaultParent
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
        self.writable = writable && fileItem.permissions?.canWrite != false && !fileItem.isRecyclePath
            && (fileItem.kind == .file || fileItem.kind == .directory) && fileItem.mountPointType == nil
        // 共享文件夹可以接收文件，但其本身不能在 Finder 中改名或移动。
        movable = fileItem.path.split(separator: "/").count > 1
        self.deletable = deletable && movable && fileItem.permissions?.canDelete == true
            && !fileItem.isRecyclePath && fileItem.mountPointType == nil
            && (fileItem.kind == .file || fileItem.kind == .directory)
        super.init()
    }

    private init(
        root mapping: DesktopDriveMapping,
        keptOffline: Bool,
        writable: Bool
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
        if case .folder = mapping.scope { self.writable = writable }
        else { self.writable = false }
        movable = false
        deletable = false
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
        writable = false
        movable = false
        deletable = false
        super.init()
    }

    static func root(
        configuration: DesktopDriveProviderConfiguration,
        keptOffline: Bool,
        writable: Bool = false
    ) -> ProviderItem {
        ProviderItem(
            root: configuration.mapping,
            keptOffline: keptOffline,
            writable: writable
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
        var result: NSFileProviderItemCapabilities = [.allowsReading]
        if directory { result.insert(.allowsContentEnumerating) }
        if deletable { result.insert(.allowsDeleting) }
        if writable {
            result.insert(.allowsWriting)
            if movable { result.formUnion([.allowsRenaming, .allowsReparenting]) }
        }
        return result
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
            // 可比较标记放在元数据版本中，避免升级时把未变化的缓存内容全部判为过期。
            metadataVersion: Data((size != nil && modifiedAt != nil ? "metadata:" : "unversioned:").utf8) + value.metadata
        )
    }
}
