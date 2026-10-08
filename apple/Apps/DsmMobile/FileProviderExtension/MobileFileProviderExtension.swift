import DsmCore
import DsmFileProviderRuntime
import DsmLocalization
import FileProvider
import Foundation
import UniformTypeIdentifiers

final class MobileFileProviderExtension: NSFileProviderExtension, @unchecked Sendable {
    private let bridgeLock = NSLock()
    private var configuredBridge: Result<ProviderLocalBridge, Error>?

    override init() {
        let preference = MobileExtensionStorage.preferences?.string(forKey: "lanstash.app-language.v1")
        UserDefaults.standard.set(preference, forKey: "lanstash.app-language.v1")
        super.init()
    }

    deinit { try? configuredBridge?.get().invalidate() }

    private func bridge() throws -> ProviderLocalBridge {
        try bridgeLock.withLock {
            if let configuredBridge { return try configuredBridge.get() }
            let result = Result {
                guard let domain, let id = UUID(uuidString: domain.identifier.rawValue) else {
                    throw NSFileProviderError(.notAuthenticated)
                }
                let manager = NSFileProviderManager.default
                let directory = manager.documentStorageURL.appendingPathComponent(domain.pathRelativeToDocumentStorage, isDirectory: true)
                #if DEBUG
                if let fixture = MobileFilesDebugEnvironment.active(),
                   let location = try? fixture.locations.location(id: id),
                   location.profile.id == fixture.id, location.profile.host == "files-ui.invalid" {
                    return try MobileFilesDependencies.localBridge(locationID: id, documentStorageURL: directory,
                        purposeIdentifier: manager.providerIdentifier, locations: fixture.locations,
                        accounts: fixture.accounts, sessions: MobileExtensionStorage.sessionStore(),
                        transport: MobileFilesSyntheticTransport(root: fixture.rootURL().appendingPathComponent("Server"), mode: fixture.mode))
                }
                #endif
                return try MobileFilesDependencies.localBridge(locationID: id, documentStorageURL: directory,
                    purposeIdentifier: manager.providerIdentifier, locations: .live(),
                    accounts: .init(rootURL: MobileExtensionStorage.rootURL()), sessions: MobileExtensionStorage.sessionStore())
            }
            configuredBridge = result
            return try result.get()
        }
    }

    override func item(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderItem {
        // 非复制式提供器在尚无位置时仍有默认入口，不能把整个提供器报告为不存在。
        if domain.flatMap({ UUID(uuidString: $0.identifier.rawValue) }) == nil, identifier == .rootContainer {
            return MobileFilesUnconfiguredRoot()
        }
        return try bridge().item(for: identifier)
    }
    override func enumerator(for identifier: NSFileProviderItemIdentifier) throws -> NSFileProviderEnumerator {
        try bridge().enumerator(for: identifier)
    }
    override func urlForItem(withPersistentIdentifier identifier: NSFileProviderItemIdentifier) -> URL? {
        try? bridge().url(for: identifier)
    }
    override func persistentIdentifierForItem(at url: URL) -> NSFileProviderItemIdentifier? {
        try? bridge().identifier(for: url)
    }
    override func providePlaceholder(at url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        do { try bridge().placeholder(at: url); completionHandler(nil) }
        catch { completionHandler(error) }
    }
    override func startProvidingItem(at url: URL, completionHandler: @escaping @Sendable (Error?) -> Void) {
        do { try bridge().provide(at: url, completion: completionHandler) }
        catch { completionHandler(error) }
    }
    override func stopProvidingItem(at url: URL) { try? bridge().stopProviding(at: url) }
    override func itemChanged(at url: URL) { try? bridge().changed(at: url) }

    override func importDocument(at url: URL, toParentItemIdentifier parent: NSFileProviderItemIdentifier,
                                 completionHandler: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        do { try bridge().create(name: url.lastPathComponent, parent: parent, source: url, completion: completionHandler) }
        catch { completionHandler(nil, error) }
    }
    override func createDirectory(withName name: String, inParentItemIdentifier parent: NSFileProviderItemIdentifier,
                                  completionHandler: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        do { try bridge().create(name: name, parent: parent, source: nil, completion: completionHandler) }
        catch { completionHandler(nil, error) }
    }
    override func renameItem(withIdentifier identifier: NSFileProviderItemIdentifier, toName name: String,
                             completionHandler: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        do { try bridge().change(identifier, parent: nil, name: name, completion: completionHandler) }
        catch { completionHandler(nil, error) }
    }
    override func reparentItem(withIdentifier identifier: NSFileProviderItemIdentifier,
                               toParentItemWithIdentifier parent: NSFileProviderItemIdentifier, newName: String?,
                               completionHandler: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        do { try bridge().change(identifier, parent: parent, name: newName, completion: completionHandler) }
        catch { completionHandler(nil, error) }
    }
    override func deleteItem(withIdentifier identifier: NSFileProviderItemIdentifier,
                             completionHandler: @escaping @Sendable (Error?) -> Void) {
        do { try bridge().delete(identifier, completion: completionHandler) }
        catch { completionHandler(error) }
    }
    override func trashItem(withIdentifier identifier: NSFileProviderItemIdentifier,
                            completionHandler: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        completionHandler(nil, CocoaError(.fileWriteNoPermission))
    }
    override func untrashItem(withIdentifier identifier: NSFileProviderItemIdentifier,
                              toParentItemIdentifier parent: NSFileProviderItemIdentifier?,
                              completionHandler: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        completionHandler(nil, CocoaError(.fileWriteNoPermission))
    }
    override func setLastUsedDate(_ date: Date?, forItemIdentifier identifier: NSFileProviderItemIdentifier,
                                  completionHandler: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        do { completionHandler(try bridge().item(for: identifier), nil) }
        catch { completionHandler(nil, error) }
    }
    override func setTagData(_ data: Data?, forItemIdentifier identifier: NSFileProviderItemIdentifier,
                             completionHandler: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        completionHandler(nil, CocoaError(.featureUnsupported))
    }
    override func setFavoriteRank(_ rank: NSNumber?, forItemIdentifier identifier: NSFileProviderItemIdentifier,
                                   completionHandler: @escaping @Sendable (NSFileProviderItem?, Error?) -> Void) {
        completionHandler(nil, CocoaError(.featureUnsupported))
    }
}

private final class MobileFilesUnconfiguredRoot: NSObject, NSFileProviderItem {
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { L10n.string("app.name") }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities { [] }
    var isUploaded: Bool { true }
    var itemVersion: NSFileProviderItemVersion {
        .init(contentVersion: Data("unconfigured".utf8), metadataVersion: Data("unconfigured".utf8))
    }
}
