#if os(iOS)
import Darwin
import DsmCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// 非复制式提供器保存系统本地副本的原始版本；远端列表刷新不改变这个基线。
public final class ProviderLocalStorage: @unchecked Sendable {
    struct Item: Codable, Sendable {
        var identifier: String
        var parentIdentifier: String
        var filename: String
        var directory: Bool
        var size: Int64?
        var modifiedAt: Date?
        var contentVersion: Data
        var metadataVersion: Data
        var capabilities: UInt
        var remotePath: String
        var relativePath: String
        var baseContentVersion: Data?
        var baseMetadataVersion: Data?
        var baseHash: String?
        var pending = false
        var errorDomain: String?
        var errorCode: Int?
        var errorKind: LocalWriteFailure?

        var identifierValue: NSFileProviderItemIdentifier { .init(identifier) }
        var base: ProviderRequestedVersion? {
            guard let baseContentVersion, let baseMetadataVersion else { return nil }
            return .init(content: baseContentVersion, metadata: baseMetadataVersion)
        }
    }

    private struct Snapshot: Codable {
        var version = 1
        let mappingID: UUID
        var items: [String: Item] = [:]
    }

    public let mapping: DesktopDriveMapping
    public let documentStorageURL: URL
    let journal: DesktopDriveWritebackStore
    private let stateDirectory: URL
    private let purposeIdentifier: String

    public init(mapping: DesktopDriveMapping, documentStorageURL: URL, stateDirectory: URL,
                journal: DesktopDriveWritebackStore, purposeIdentifier: String) throws {
        self.mapping = mapping
        self.documentStorageURL = documentStorageURL.standardizedFileURL
        self.stateDirectory = stateDirectory
        self.journal = journal
        self.purposeIdentifier = purposeIdentifier
        try prepareDirectory(documentStorageURL)
        try prepareDirectory(stateDirectory)
        try mutate { snapshot in
            let identifier = NSFileProviderItemIdentifier.rootContainer.rawValue
            if snapshot.items[identifier] == nil {
                snapshot.items[identifier] = Item(identifier: identifier, parentIdentifier: identifier,
                    filename: mapping.displayName, directory: true, size: nil, modifiedAt: mapping.createdAt,
                    contentVersion: Data(mapping.id.uuidString.utf8), metadataVersion: Data("root".utf8),
                    capabilities: NSFileProviderItemCapabilities([.allowsReading, .allowsContentEnumerating]).rawValue,
                    remotePath: rootPath, relativePath: "")
            }
        }
    }

    var rootPath: String {
        if case .folder(let path) = mapping.scope { return path }
        return "/"
    }

    func item(_ identifier: NSFileProviderItemIdentifier) throws -> Item {
        try locked {
            guard let item = try load().items[identifier.rawValue] else { throw NSFileProviderError(.noSuchItem) }
            return item
        }
    }

    func allItems() throws -> [Item] { try locked { Array(try load().items.values) } }

    func localURL(_ item: Item) throws -> URL {
        guard item.relativePath.isEmpty || item.relativePath.split(separator: "/").allSatisfy({
            DesktopDriveWritebackStore.validFilename(String($0))
        }) else { throw DesktopDriveWritebackError.invalidItem }
        let url = documentStorageURL.appendingPathComponent(item.relativePath, isDirectory: item.directory).standardizedFileURL
        guard url == documentStorageURL || url.path.hasPrefix(documentStorageURL.path + "/") else {
            throw DesktopDriveWritebackError.invalidItem
        }
        var component = documentStorageURL
        for part in item.relativePath.split(separator: "/") {
            component.appendPathComponent(String(part))
            if FileManager.default.fileExists(atPath: component.path),
               try component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                throw DesktopDriveWritebackError.invalidItem
            }
        }
        return url
    }

    func identifier(for url: URL) throws -> NSFileProviderItemIdentifier {
        let normalized = url.standardizedFileURL
        guard let item = try allItems().first(where: { try localURL($0) == normalized }) else {
            throw NSFileProviderError(.noSuchItem)
        }
        return item.identifierValue
    }

    func isMaterialized(_ item: Item) throws -> Bool {
        if item.directory { return true }
        let url = try localURL(item)
        return item.baseHash != nil && FileManager.default.fileExists(atPath: url.path)
    }

    func provisionURL(_ identifier: NSFileProviderItemIdentifier) throws -> URL {
        let entry = try item(identifier)
        let url = try localURL(entry)
        try prepareDirectory(entry.directory ? url : url.deletingLastPathComponent())
        return url
    }

    func temporaryDirectory() throws -> URL {
        let url = stateDirectory.appendingPathComponent("Transfers", isDirectory: true)
        try prepareDirectory(url)
        return url
    }

    func freezeImport(_ source: URL) throws -> URL {
        try coordinate(source, writing: false) { stable in
            let values = try stable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  DesktopDriveWritebackStore.validFilename(source.lastPathComponent) else {
                throw DesktopDriveWritebackError.invalidItem
            }
            let folder = try temporaryDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try prepareDirectory(folder)
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: stable, to: destination)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete, .posixPermissions: 0o600],
                                                  ofItemAtPath: destination.path)
            return destination
        }
    }

    func cachedItem(_ identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        let item = try item(identifier)
        var capabilities = NSFileProviderItemCapabilities(rawValue: item.capabilities)
        let editingEnabled = try journal.isEnabled(mappingID: mapping.id)
        // 根项目不会作为自己的子项返回；按位置授权更新其能力，不能永久保留初始化时的只读值。
        if identifier == .rootContainer {
            capabilities = [.allowsReading, .allowsContentEnumerating]
            if case .folder = mapping.scope, editingEnabled { capabilities.insert(.allowsWriting) }
        }
        if !editingEnabled {
            capabilities.subtract([.allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting])
        } else if try !journal.isDeletionEnabled(mappingID: mapping.id) {
            capabilities.remove(.allowsDeleting)
        }
        return ProviderLocalItem(item, downloaded: try isMaterialized(item), capabilities: capabilities)
    }

    func store(_ providerItem: ProviderItem, remotePath: String) throws {
        guard remotePath == rootPath || DesktopDrivePath.isAncestorOrSame(rootPath, of: remotePath),
              DesktopDrivePath.normalized(remotePath) == remotePath else { throw DesktopDriveWritebackError.invalidItem }
        let id = providerItem.itemIdentifier.rawValue
        let relative = remotePath == rootPath ? "" :
            String(remotePath.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
        if let old = try? item(providerItem.itemIdentifier), !old.directory, old.baseHash != nil,
           old.baseContentVersion != providerItem.itemVersion.contentVersion {
            // 列表变化只能回收没有本机修改的副本；未保存的内容仍留在原位置。
            do { try evict(old.identifierValue) }
            catch DesktopDriveWritebackError.pendingChanges {}
        }
        try mutate { snapshot in
            let old = snapshot.items[id]
            snapshot.items[id] = Item(identifier: id, parentIdentifier: providerItem.parentItemIdentifier.rawValue,
                filename: providerItem.filename, directory: providerItem.contentType == .folder,
                size: providerItem.documentSize?.int64Value, modifiedAt: providerItem.contentModificationDate,
                contentVersion: providerItem.itemVersion.contentVersion,
                metadataVersion: providerItem.itemVersion.metadataVersion,
                capabilities: providerItem.capabilities.rawValue, remotePath: remotePath,
                relativePath: old?.relativePath ?? relative,
                baseContentVersion: old?.baseContentVersion, baseMetadataVersion: old?.baseMetadataVersion,
                baseHash: old?.baseHash, pending: old?.pending ?? false,
                errorDomain: old?.errorDomain, errorCode: old?.errorCode, errorKind: old?.errorKind)
        }
        let updated = try item(providerItem.itemIdentifier)
        let url = try localURL(updated)
        if !updated.directory, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.setAttributes(
                [.posixPermissions: providerItem.capabilities.contains(.allowsWriting) ? 0o600 : 0o400],
                ofItemAtPath: url.path)
        }
    }

    /// startProvidingItem 已由系统独占；复制结束并保存基线之后才向宿主交付。
    func materialize(_ source: URL, item: ProviderItem, remotePath: String) throws {
        try store(item, remotePath: remotePath)
        let record = try self.item(item.itemIdentifier)
        let destination = try localURL(record)
        if FileManager.default.fileExists(atPath: destination.path), !record.directory {
            guard let hash = record.baseHash,
                  try DesktopDriveWritebackStore.hash(of: destination) == hash,
                  !record.pending else { throw DesktopDriveWritebackError.pendingChanges }
            try FileManager.default.removeItem(at: destination)
        }
        try prepareDirectory(destination.deletingLastPathComponent())
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes([
            .protectionKey: FileProtectionType.complete,
            .posixPermissions: item.capabilities.contains(.allowsWriting) ? 0o600 : 0o400
        ], ofItemAtPath: destination.path)
        let hash = try DesktopDriveWritebackStore.hash(of: destination)
        try mutate { snapshot in
            guard var value = snapshot.items[record.identifier] else { throw NSFileProviderError(.noSuchItem) }
            value.baseContentVersion = item.itemVersion.contentVersion
            value.baseMetadataVersion = item.itemVersion.metadataVersion
            value.baseHash = hash
            value.pending = false
            value.errorDomain = nil
            value.errorCode = nil
            value.errorKind = nil
            snapshot.items[record.identifier] = value
        }
    }

    /// 在系统回调返回前冻结修改，进程退出后仍有可导出的受保护副本。
    func captureChanges(_ identifier: NSFileProviderItemIdentifier) throws -> DesktopDriveWritebackRecord? {
        let current = try item(identifier)
        guard !current.directory, let baseHash = current.baseHash, let base = current.base else { return nil }
        let url = try localURL(current)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try coordinate(url, writing: false) { stable in
            let values = try stable.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw DesktopDriveWritebackError.invalidItem }
            let hash = try DesktopDriveWritebackStore.hash(of: stable)
            guard hash != baseHash else { return nil }
            let lease = try journal.lock(mappingID: mapping.id)
            defer { withExtendedLifetime(lease) {} }
            let existing = try journal.pendingRecords(mappingID: mapping.id).first {
                $0.itemIdentifier == identifier.rawValue
            }
            if let existing {
                // 新一轮本机编辑不能覆盖尚未得到结果的上一份冻结副本。
                return existing.contentHash == hash ? existing : nil
            }
            let size = Int64(try stable.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
            let record = try journal.prepare(.init(mappingID: mapping.id, itemIdentifier: identifier.rawValue,
                sourcePath: current.remotePath, destinationPath: current.remotePath, isDirectory: false,
                contentHash: hash, contentSize: size,
                baseContentVersion: base.metadata.starts(with: Data("metadata:".utf8)) ? base.content : nil), contents: stable)
            try mutate { snapshot in
                snapshot.items[identifier.rawValue]?.pending = true
            }
            return record
        }
    }

    public func capturePendingFiles() throws {
        for item in try allItems() where !item.directory && item.baseHash != nil {
            _ = try captureChanges(item.identifierValue)
        }
    }

    func recordWrite(_ providerItem: ProviderItem, remotePath: String, submittedHash: String?) throws {
        let id = providerItem.itemIdentifier
        let old = try? item(id)
        if let old, old.remotePath != remotePath {
            try relocate(old, remotePath: remotePath)
        }
        // 已确认写入的版本是下一次本机编辑的基线，不使用列表刷新所得版本。
        try mutate { snapshot in
            guard var value = snapshot.items[id.rawValue] else { return }
            value.baseContentVersion = providerItem.itemVersion.contentVersion
            value.baseMetadataVersion = providerItem.itemVersion.metadataVersion
            if let submittedHash { value.baseHash = submittedHash }
            value.pending = false
            value.errorDomain = nil
            value.errorCode = nil
            value.errorKind = nil
            snapshot.items[id.rawValue] = value
        }
        try store(providerItem, remotePath: remotePath)
    }

    func recordError(_ error: Error, identifier: NSFileProviderItemIdentifier) throws {
        let kind = LocalWriteFailure(error)
        let error = error as NSError
        try mutate { snapshot in
            snapshot.items[identifier.rawValue]?.pending = true
            snapshot.items[identifier.rawValue]?.errorDomain = error.domain
            snapshot.items[identifier.rawValue]?.errorCode = error.code
            snapshot.items[identifier.rawValue]?.errorKind = kind
        }
    }

    public func requireNoUnsavedChanges(below identifier: NSFileProviderItemIdentifier = .rootContainer,
                                       allowingPendingDeletion: Bool = false) throws {
        try capturePendingFiles()
        let root = try item(identifier).remotePath
        guard try !journal.pendingRecords(mappingID: mapping.id).contains(where: {
            if allowingPendingDeletion, $0.isDeletion, $0.itemIdentifier == identifier.rawValue { return false }
            return [$0.sourcePath, $0.destinationPath].compactMap { $0 }.contains { DesktopDrivePath.isAncestorOrSame(root, of: $0) }
        }) else { throw DesktopDriveWritebackError.pendingChanges }
        for item in try allItems() where !item.directory && item.baseHash != nil &&
            DesktopDrivePath.isAncestorOrSame(root, of: item.remotePath) {
            let url = try localURL(item)
            if FileManager.default.fileExists(atPath: url.path),
               try DesktopDriveWritebackStore.hash(of: url) != item.baseHash {
                let kept = try journal.records(mappingID: mapping.id).contains {
                    $0.itemIdentifier == item.identifier && $0.phase == .keptLocally &&
                    $0.contentHash == (try? DesktopDriveWritebackStore.hash(of: url))
                }
                if !kept { throw DesktopDriveWritebackError.pendingChanges }
            }
        }
    }

    func evict(_ identifier: NSFileProviderItemIdentifier) throws {
        let current = try item(identifier)
        guard !current.directory else { return }
        let url = try localURL(current)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try coordinate(url, writing: true) { stable in
            let latest = try item(identifier)
            // 已确认的原删除可以清理旧错误标记；内容变化与其他未结束写仍不能被回收。
            let deletionVerified = try journal.records(mappingID: mapping.id).contains {
                $0.itemIdentifier == identifier.rawValue && $0.isDeletion && $0.phase == .verified
            }
            guard !latest.pending || deletionVerified, let baseline = latest.baseHash,
                  try !journal.pendingRecords(mappingID: mapping.id).contains(where: {
                      $0.itemIdentifier == identifier.rawValue ||
                      [$0.sourcePath, $0.destinationPath].compactMap { $0 }.contains {
                          DesktopDrivePath.isAncestorOrSame($0, of: latest.remotePath)
                      }
                  }),
                  try DesktopDriveWritebackStore.hash(of: stable) == baseline else {
                throw DesktopDriveWritebackError.pendingChanges
            }
            try FileManager.default.removeItem(at: stable)
            try mutate { snapshot in
                snapshot.items[identifier.rawValue]?.baseHash = nil
                snapshot.items[identifier.rawValue]?.baseContentVersion = nil
                snapshot.items[identifier.rawValue]?.baseMetadataVersion = nil
            }
        }
    }

    func remove(_ identifier: NSFileProviderItemIdentifier) throws {
        let current = try item(identifier)
        let affected = try allItems().filter { DesktopDrivePath.isAncestorOrSame(current.remotePath, of: $0.remotePath) }
        for item in affected where !item.directory {
            try evict(item.identifierValue)
        }
        // 不递归删除未编入本地记录的文件；位置移除仍由独立确认负责。
        for item in affected.sorted(by: { $0.relativePath.count > $1.relativePath.count }) where item.directory {
            let url = try localURL(item)
            if FileManager.default.fileExists(atPath: url.path),
               try FileManager.default.contentsOfDirectory(atPath: url.path).isEmpty {
                try FileManager.default.removeItem(at: url)
            }
        }
        try mutate { snapshot in
            for item in affected { snapshot.items[item.identifier] = nil }
        }
    }

    private func relocate(_ item: Item, remotePath: String) throws {
        let old = try localURL(item)
        let relative = String(remotePath.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1))
        var updated = item
        updated.remotePath = remotePath
        updated.relativePath = relative
        let destination = try localURL(updated)
        if FileManager.default.fileExists(atPath: old.path) {
            try prepareDirectory(destination.deletingLastPathComponent())
            let coordinator = NSFileCoordinator()
            coordinator.purposeIdentifier = purposeIdentifier
            var coordinationError: NSError?
            var moveError: Error?
            coordinator.coordinate(writingItemAt: old, options: .forMoving, writingItemAt: destination,
                                   options: .forReplacing, error: &coordinationError) { source, target in
                do {
                    guard !FileManager.default.fileExists(atPath: target.path) else { throw DesktopDriveWritebackError.conflict }
                    try FileManager.default.moveItem(at: source, to: target)
                    coordinator.item(at: source, didMoveTo: target)
                } catch { moveError = error }
            }
            if let error = coordinationError ?? moveError as NSError? { throw error }
        }
        try mutate { snapshot in
            for (id, var value) in snapshot.items where DesktopDrivePath.isAncestorOrSame(item.remotePath, of: value.remotePath) {
                let suffix = String(value.remotePath.dropFirst(item.remotePath.count))
                value.remotePath = remotePath + suffix
                value.relativePath = relative + suffix
                snapshot.items[id] = value
            }
        }
    }

    private func coordinate<Value>(_ url: URL, writing: Bool, body: (URL) throws -> Value) throws -> Value {
        let coordinator = NSFileCoordinator()
        coordinator.purposeIdentifier = purposeIdentifier
        var failure: NSError?
        var result: Result<Value, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: .forDeleting, error: &failure) { coordinated in result = Result { try body(coordinated) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &failure) { coordinated in result = Result { try body(coordinated) } }
        }
        if let failure { throw failure }
        guard let result else { throw CocoaError(.fileReadUnknown) }
        return try result.get()
    }

    private func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700, .protectionKey: FileProtectionType.complete])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try protectedURL.setResourceValues(values)
    }

    private var snapshotURL: URL { stateDirectory.appendingPathComponent("file-provider-items-v1.json") }
    private func load() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: snapshotURL.path) else { return Snapshot(mappingID: mapping.id) }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
        guard snapshot.version == 1, snapshot.mappingID == mapping.id,
              snapshot.items.allSatisfy({ $0.key == $0.value.identifier }) else {
            throw DesktopDriveWritebackError.invalidItem
        }
        return snapshot
    }
    private func mutate(_ operation: (inout Snapshot) throws -> Void) throws {
        try locked {
            var snapshot = try load()
            try operation(&snapshot)
            try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: [.atomic, .completeFileProtection])
        }
    }
    private func locked<Value>(_ body: () throws -> Value) throws -> Value {
        let descriptor = open(stateDirectory.appendingPathComponent("file-provider-items.lock").path,
                              O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(.EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

final class ProviderLocalItem: NSObject, NSFileProviderItem, @unchecked Sendable {
    let record: ProviderLocalStorage.Item
    private let hasDownloadedContent: Bool
    let capabilities: NSFileProviderItemCapabilities
    init(_ record: ProviderLocalStorage.Item, downloaded: Bool, capabilities: NSFileProviderItemCapabilities) {
        self.record = record; self.hasDownloadedContent = downloaded; self.capabilities = capabilities
    }
    var itemIdentifier: NSFileProviderItemIdentifier { record.identifierValue }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .init(record.parentIdentifier) }
    var filename: String { record.filename }
    var contentType: UTType { record.directory ? .folder : UTType(filenameExtension: (record.filename as NSString).pathExtension) ?? .data }
    var documentSize: NSNumber? { record.size.map(NSNumber.init(value:)) }
    var contentModificationDate: Date? { record.modifiedAt }
    var itemVersion: NSFileProviderItemVersion {
        .init(contentVersion: record.baseContentVersion ?? record.contentVersion,
              metadataVersion: record.metadataVersion + Data("|local:\(capabilities.rawValue)".utf8))
    }
    var versionIdentifier: Data? { itemVersion.contentVersion + itemVersion.metadataVersion }
    var isDownloaded: Bool { hasDownloadedContent }
    var isUploaded: Bool { !record.pending }
    var uploadingError: Error? {
        if let failure = record.errorKind {
            return ProviderErrorMapper.map(failure.error, itemIdentifier: itemIdentifier)
        }
        guard let domain = record.errorDomain, let code = record.errorCode else { return nil }
        return NSError(domain: domain, code: code)
    }
}

enum LocalWriteFailure: String, Codable {
    case disabled, busy, pendingChanges, conflict, outcomeUnknown, invalidItem, keptLocally
    init?(_ error: Error) {
        guard let error = error as? DesktopDriveWritebackError else { return nil }
        switch error {
        case .disabled: self = .disabled
        case .busy: self = .busy
        case .pendingChanges: self = .pendingChanges
        case .conflict: self = .conflict
        case .outcomeUnknown: self = .outcomeUnknown
        case .invalidItem: self = .invalidItem
        case .keptLocally: self = .keptLocally
        }
    }
    var error: DesktopDriveWritebackError {
        switch self {
        case .disabled: .disabled
        case .busy: .busy
        case .pendingChanges: .pendingChanges
        case .conflict: .conflict
        case .outcomeUnknown: .outcomeUnknown
        case .invalidItem: .invalidItem
        case .keptLocally: .keptLocally
        }
    }
}
#endif
