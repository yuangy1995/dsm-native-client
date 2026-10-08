import DsmCore
import DsmFileProviderRuntime
import DsmNetwork
import FileProvider
import Foundation

enum MobileFilesDependencies {
    static func localBridge(for location: MobileFilesLocation) throws -> ProviderLocalBridge {
        // 与扩展使用相同的默认域存储根，再附加本位置的相对目录。
        let manager = NSFileProviderManager.default
        let documentStorage = manager.documentStorageURL.appendingPathComponent(location.domain.pathRelativeToDocumentStorage, isDirectory: true)
        #if DEBUG
        if let fixture = MobileFilesDebugEnvironment.active(),
           let recorded = try? fixture.locations.location(id: location.id), recorded == location {
            return try localBridge(locationID: location.id, documentStorageURL: documentStorage,
                purposeIdentifier: manager.providerIdentifier, locations: fixture.locations, accounts: fixture.accounts,
                sessions: MobileExtensionStorage.sessionStore(),
                transport: MobileFilesSyntheticTransport(root: fixture.rootURL().appendingPathComponent("Server"), mode: fixture.mode))
        }
        #endif
        return try localBridge(locationID: location.id, documentStorageURL: documentStorage,
            purposeIdentifier: manager.providerIdentifier, locations: .live(),
            accounts: .init(rootURL: MobileExtensionStorage.rootURL()), sessions: MobileExtensionStorage.sessionStore())
    }

    static func localBridge(locationID: UUID, documentStorageURL: URL, purposeIdentifier: String,
                            locations: MobileFilesLocationStore, accounts: MobileExtensionAccountStore,
                            sessions: any SessionSecureStoring,
                            transport: (any DsmBinaryHTTPTransport)? = nil) throws -> ProviderLocalBridge {
        let location = try locations.location(id: locationID)
        let storage = try ProviderLocalStorage(mapping: location.mapping, documentStorageURL: documentStorageURL,
            stateDirectory: locations.directory(id: locationID).appendingPathComponent("LocalFiles", isDirectory: true),
            journal: locations.writebackStore(id: locationID), purposeIdentifier: purposeIdentifier)
        return try ProviderLocalBridge(storage: storage, dependencies: make(locationID: locationID,
            locations: locations, accounts: accounts, sessions: sessions, transport: transport))
    }

    static func make(locationID: UUID, locations: MobileFilesLocationStore,
                     accounts: MobileExtensionAccountStore, sessions: any SessionSecureStoring,
                     transport: (any DsmBinaryHTTPTransport)? = nil) throws -> ProviderRuntimeDependencies {
        let location = try locations.location(id: locationID)
        let configuration = try locations.configurationStore(id: locationID)
        return .system(configurationStore: configuration, writebackStore: try locations.writebackStore(id: locationID)) { current in
            guard current.mapping == location.mapping else { throw NSFileProviderError(.providerNotFound) }
            let account = try locations.requireCurrent(location, accounts: accounts)
            return try await MobileExtensionTransport.repository(account: account, accounts: accounts, sessions: sessions, transport: transport) {
                _ = try locations.requireCurrent(location, accounts: accounts)
                // 新建 store 避免暂停、移除或损坏记录被进程内读取缓存掩盖。
                let live = try locations.configurationStore(id: locationID)
                guard try await live.configuration(mappingID: locationID)?.mapping == location.mapping else {
                    throw NSFileProviderError(.providerNotFound)
                }
                try await live.validateWritebackState(mappingID: locationID)
            }
        }
    }
}
