import DsmCore
import DsmFileProviderRuntime
import DsmNetwork
import FileProvider
import Foundation

enum MobileFilesDependencies {
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
