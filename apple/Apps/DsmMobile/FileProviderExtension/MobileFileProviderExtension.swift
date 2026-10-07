import DsmFileProviderRuntime
import DsmLocalization
import FileProvider
import Foundation

final class MobileFileProviderExtension: ProviderExtension, NSFileProviderReplicatedExtension, @unchecked Sendable {
    required init(domain: NSFileProviderDomain) {
        let preference = MobileExtensionStorage.preferences?.string(forKey: "lanstash.app-language.v1")
        UserDefaults.standard.set(preference, forKey: "lanstash.app-language.v1")
        super.init(mappingIdentifier: domain.identifier.rawValue) {
            guard let id = UUID(uuidString: domain.identifier.rawValue) else { throw NSFileProviderError(.providerNotFound) }
            #if DEBUG
            if let fixture = MobileFilesDebugEnvironment.active(),
               let location = try? fixture.locations.location(id: id),
               location.profile.id == fixture.id, location.profile.host == "files-ui.invalid" {
                return try MobileFilesDependencies.make(locationID: id, locations: fixture.locations,
                    accounts: fixture.accounts, sessions: MobileExtensionStorage.sessionStore(),
                    transport: MobileFilesSyntheticTransport(root: fixture.rootURL().appendingPathComponent("Server"), mode: fixture.mode))
            }
            #endif
            return try MobileFilesDependencies.make(locationID: id, locations: .live(),
                accounts: .init(rootURL: MobileExtensionStorage.rootURL()), sessions: MobileExtensionStorage.sessionStore())
        }
    }
}
