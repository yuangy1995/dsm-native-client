#if os(iOS)
import DsmCore
import FileProvider
import Foundation
import UniformTypeIdentifiers

/// iOS 非复制式系统回调仍调用同一业务运行时，不复制 NAS 请求或安全策略。
public final class ProviderLocalBridge: @unchecked Sendable {
    public let storage: ProviderLocalStorage
    private let dependencies: ProviderRuntimeDependencies
    private let runtime: ProviderRuntime
    private let operations = ProviderOperationRegistry()
    private let operationLock = NSLock()
    private var activeWrites = Set<String>()

    public init(storage: ProviderLocalStorage, dependencies: ProviderRuntimeDependencies) {
        self.storage = storage
        var local = dependencies
        local.temporaryDirectory = { _ in try storage.temporaryDirectory() }
        local.evictItem = { identifier, _ in try storage.evict(identifier) }
        local.waitForChildren = { identifier, _ in
            try storage.requireNoUnsavedChanges(below: identifier, allowingPendingDeletion: true)
        }
        self.dependencies = local
        runtime = ProviderRuntime(mappingIdentifier: storage.mapping.id.uuidString, dependencies: local)
    }

    public func invalidate() {
        operations.cancelAll()
        Task { await runtime.invalidate() }
    }

    public func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        try storage.cachedItem(identifier)
    }

    public func url(for identifier: NSFileProviderItemIdentifier) throws -> URL {
        try storage.provisionURL(identifier)
    }

    public func identifier(for url: URL) throws -> NSFileProviderItemIdentifier { try storage.identifier(for: url) }

    public func enumerator(for identifier: NSFileProviderItemIdentifier) -> NSFileProviderEnumerator {
        if identifier == .trashContainer { return ProviderEmptyEnumerator() }
        return ProviderEnumerator(containerIdentifier: identifier, runtime: runtime,
            prepareItems: { [self] items in
                var prepared: [NSFileProviderItem] = []
                for item in items {
                    try await remember(item)
                    prepared.append(try storage.cachedItem(item.itemIdentifier))
                }
                return prepared
            },
            prepareDeletions: { [self] identifiers in
                var removed: [NSFileProviderItemIdentifier] = []
                for identifier in identifiers {
                    do {
                        _ = try storage.captureChanges(identifier)
                        try storage.remove(identifier)
                        removed.append(identifier)
                    } catch let error as NSFileProviderError where error.code == .noSuchItem {
                        removed.append(identifier)
                    } catch DesktopDriveWritebackError.pendingChanges {
                        try storage.recordError(NSFileProviderError(.cannotSynchronize), identifier: identifier)
                    }
                }
                return removed
            })
    }

    public func provide(at url: URL, completion: @escaping @Sendable (Error?) -> Void) {
        do {
            let identifier = try storage.identifier(for: url)
            let entry = try storage.item(identifier)
            if try storage.isMaterialized(entry) {
                _ = try storage.provisionURL(identifier)
                completion(nil)
                return
            }
            perform(identifier: identifier, recordsWriteError: false, completion: completion) { [self] in
                let result = try await runtime.fetchContents(for: identifier, requestedVersion: nil, progress: { _, _ in })
                defer { dependencies.removeItem(result.0) }
                try storage.materialize(result.0, item: result.1, remotePath: try await remotePath(identifier))
            }
        } catch { completion(ProviderErrorMapper.map(error, itemIdentifier: .rootContainer)) }
    }

    public func changed(at url: URL) {
        do {
            let identifier = try storage.identifier(for: url)
            guard let record = try storage.captureChanges(identifier), record.phase.isPending else { return }
            schedule(record)
        } catch {
            if let identifier = try? storage.identifier(for: url) {
                try? storage.recordError(error, identifier: identifier)
            }
        }
    }

    public func stopProviding(at url: URL) {
        guard let identifier = try? storage.identifier(for: url),
              let item = try? storage.item(identifier),
              NSFileProviderItemCapabilities(rawValue: item.capabilities).contains(.allowsEvicting) else { return }
        do {
            try storage.evict(identifier)
            try placeholder(at: url)
        } catch {
            // 本机修改或未结束写保留；回收不是丢弃编辑的授权。
        }
    }

    public func placeholder(at url: URL) throws {
        let identifier = try storage.identifier(for: url)
        _ = try storage.provisionURL(identifier)
        try NSFileProviderManager.writePlaceholder(at: NSFileProviderManager.placeholderURL(for: url),
                                                   withMetadata: storage.cachedItem(identifier))
    }

    public func create(name: String, parent: NSFileProviderItemIdentifier, source: URL?,
                       completion: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        let identifier = NSFileProviderItemIdentifier(UUID().uuidString)
        let callback = UncheckedSendableBox(completion)
        perform(identifier: identifier, completion: { error in if let error { callback.value(nil, error) } }) { [self] in
            let scoped = source?.startAccessingSecurityScopedResource() == true
            defer { if scoped { source?.stopAccessingSecurityScopedResource() } }
            let frozen = try source.map(storage.freezeImport)
            defer { if let frozen { try? FileManager.default.removeItem(at: frozen.deletingLastPathComponent()) } }
            let template = ProviderImportedItemTemplate(identifier: identifier, parentIdentifier: parent,
                filename: name, isDirectory: source == nil)
            let item = try await runtime.writeItem(template, baseVersion: nil, contents: frozen,
                creating: true, progress: { _, _ in })
            try await remember(item)
            if let frozen {
                try storage.materialize(frozen, item: item, remotePath: try await remotePath(item.itemIdentifier))
            } else { _ = try storage.provisionURL(item.itemIdentifier) }
            callback.value(try storage.cachedItem(item.itemIdentifier), nil)
            await signal()
        }
    }

    public func change(_ identifier: NSFileProviderItemIdentifier, parent: NSFileProviderItemIdentifier?,
                       name: String?, completion: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        let callback = UncheckedSendableBox(completion)
        perform(identifier: identifier, completion: { error in if let error { callback.value(nil, error) } }) { [self] in
            try storage.requireNoUnsavedChanges(below: identifier)
            let original = try storage.item(identifier)
            let template = ProviderImportedItemTemplate(identifier: identifier,
                parentIdentifier: parent ?? .init(original.parentIdentifier), filename: name ?? original.filename,
                isDirectory: original.directory)
            let base = original.base ?? ProviderRequestedVersion(content: original.contentVersion, metadata: original.metadataVersion)
            let item = try await runtime.writeItem(template, baseVersion: base, contents: nil,
                creating: false, progress: { _, _ in })
            try storage.recordWrite(item, remotePath: try await remotePath(item.itemIdentifier), submittedHash: nil)
            callback.value(try storage.cachedItem(item.itemIdentifier), nil)
            await signal()
        }
    }

    public func delete(_ identifier: NSFileProviderItemIdentifier, completion: @escaping @Sendable (Error?) -> Void) {
        perform(identifier: identifier, deletion: true, completion: completion) { [self] in
            try storage.requireNoUnsavedChanges(below: identifier, allowingPendingDeletion: true)
            let entry = try storage.item(identifier)
            let base = entry.base ?? ProviderRequestedVersion(content: entry.contentVersion, metadata: entry.metadataVersion)
            try await runtime.deleteItem(identifier: identifier, baseVersion: base,
                recursive: entry.directory, progress: { _, _ in })
            try storage.remove(identifier)
            await signal()
        }
    }

    /// 用户在原有恢复页明确继续后，沿同一收据恢复；未得到结果的请求由运行时只读核查。
    public func recover(_ record: DesktopDriveWritebackRecord) async throws {
        guard record.mappingID == storage.mapping.id else { throw DesktopDriveWritebackError.invalidItem }
        let current = try dependencies.writebackStore.records(mappingID: record.mappingID).first { $0.id == record.id }
        guard let current else { throw DesktopDriveWritebackError.invalidItem }
        try await process(current)
        await signal()
    }

    private func schedule(_ record: DesktopDriveWritebackRecord) {
        let identifier = record.itemIdentifier
        guard operationLock.withLock({ activeWrites.insert(identifier).inserted }) else { return }
        let lifetime = ProviderLocalWriteLifetime()
        ProcessInfo.processInfo.performExpiringActivity(withReason: "FileProviderWriteback") { [self] expired in
            if expired {
                if !lifetime.cancel() { operationLock.withLock { _ = activeWrites.remove(identifier) } }
                return
            }
            guard lifetime.begin() else { return }
            let finished = DispatchSemaphore(value: 0)
            let task = perform(identifier: .init(identifier), completion: { [self] error in
                operationLock.withLock { _ = activeWrites.remove(identifier) }
                finished.signal()
            }) { [self] in
                var pending: DesktopDriveWritebackRecord? = record
                while let current = pending {
                    try Task.checkCancellation()
                    try await process(current)
                    pending = try storage.captureChanges(.init(identifier))
                    if pending?.phase.isPending != true { pending = nil }
                }
                await signal()
            }
            lifetime.attach(task)
            finished.wait()
        }
    }

    private func process(_ record: DesktopDriveWritebackRecord) async throws {
        let identifier = NSFileProviderItemIdentifier(record.itemIdentifier)
        let base = record.baseContentVersion.map { ProviderRequestedVersion(content: $0, metadata: Data("metadata:".utf8)) }
        if record.isDeletion {
            try storage.requireNoUnsavedChanges(below: identifier, allowingPendingDeletion: true)
            try await runtime.deleteItem(identifier: identifier,
                baseVersion: base ?? .init(content: Data(), metadata: Data()),
                recursive: record.recursive == true, progress: { _, _ in })
            try storage.remove(identifier)
            return
        }
        let parentPath = (record.destinationPath as NSString).deletingLastPathComponent
        let parent: NSFileProviderItemIdentifier
        if parentPath == storage.rootPath { parent = .rootContainer }
        else {
            try await dependencies.configurationStore.registerItemPaths(mappingID: record.mappingID, remotePaths: [parentPath])
            let configuration = try await dependencies.configurationStore.configuration(mappingID: record.mappingID)
            guard let raw = configuration?.itemIdentifiersByPath[parentPath] ??
                DesktopDriveItemIdentity.identifier(mappingID: record.mappingID, remotePath: parentPath) else {
                throw DesktopDriveWritebackError.invalidItem
            }
            parent = .init(raw)
        }
        let template = ProviderImportedItemTemplate(identifier: identifier, parentIdentifier: parent,
            filename: (record.destinationPath as NSString).lastPathComponent, isDirectory: record.isDirectory)
        let source = try record.contentHash.map { _ in try dependencies.writebackStore.contentURL(for: record) }
        let item = try await runtime.writeItem(template, baseVersion: base, contents: source,
            creating: record.sourcePath == nil, progress: { _, _ in })
        try storage.recordWrite(item, remotePath: record.destinationPath, submittedHash: record.contentHash)
    }

    private func remember(_ item: ProviderItem) async throws {
        try storage.store(item, remotePath: try await remotePath(item.itemIdentifier))
    }

    private func remotePath(_ identifier: NSFileProviderItemIdentifier) async throws -> String {
        if identifier == .rootContainer { return storage.rootPath }
        guard let path = try await dependencies.configurationStore.remotePath(mappingID: storage.mapping.id,
            itemIdentifier: identifier.rawValue) else { throw NSFileProviderError(.noSuchItem) }
        return path
    }

    @discardableResult
    private func perform(identifier: NSFileProviderItemIdentifier, recordsWriteError: Bool = true, deletion: Bool = false, completion: @escaping @Sendable (Error?) -> Void,
                         operation: @escaping @Sendable () async throws -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task {
            defer { operations.remove(id) }
            do { try await operation(); completion(nil) }
            catch {
                if recordsWriteError { try? storage.recordError(error, identifier: identifier) }
                completion(deletion ? ProviderErrorMapper.mapDeletion(error, itemIdentifier: identifier) :
                    ProviderErrorMapper.map(error, itemIdentifier: identifier))
            }
        }
        operations.insert(task, id: id)
        return task
    }

    private func signal() async {
        let domain = NSFileProviderDomain(identifier: .init(storage.mapping.id.uuidString),
            displayName: storage.mapping.displayName, pathRelativeToDocumentStorage: storage.mapping.id.uuidString)
        guard let manager = NSFileProviderManager(for: domain) else { return }
        try? await manager.signalEnumerator(for: .workingSet)
        try? await manager.signalEnumerator(for: .rootContainer)
    }
}

private final class ProviderLocalWriteLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var expired = false
    private var started = false
    func begin() -> Bool {
        lock.withLock {
            guard !expired else { return false }
            started = true
            return true
        }
    }
    func attach(_ task: Task<Void, Never>) {
        lock.withLock { self.task = task; if expired { task.cancel() } }
    }
    func cancel() -> Bool {
        lock.withLock { expired = true; task?.cancel(); return started }
    }
}
#endif
