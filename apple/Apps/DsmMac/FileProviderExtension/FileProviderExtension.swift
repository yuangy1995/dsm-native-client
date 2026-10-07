import DsmFileProviderRuntime
import FileProvider
import Foundation

final class FileProviderExtension: ProviderExtension, NSFileProviderReplicatedExtension, @unchecked Sendable {
    required init(domain: NSFileProviderDomain) {
        let mappingIdentifier: String
        if #available(macOS 15.0, *), let value = domain.userInfo?["mappingID"] as? String {
            mappingIdentifier = value
        } else {
            mappingIdentifier = domain.identifier.rawValue
        }
        super.init(mappingIdentifier: mappingIdentifier, dependencies: .live())
    }
}
