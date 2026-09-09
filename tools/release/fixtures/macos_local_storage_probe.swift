import CryptoKit
import DsmCore
import Foundation
import Security
@testable import DsmNetwork

/// 仅使用脚本提供的临时目录、随机测试服务和合成凭据，不访问真实账号或主密钥。
@main
struct LocalStorageProbe {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4, let id = UUID(uuidString: arguments[2]),
              AppStorageNamespace.isLocalTest else { exit(2) }
        let directory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let service = "io.github.qwertyuiop1995.dsmnativeclient.storage-probe.\(id.uuidString)"
        if arguments[3] == "cleanup" {
            let status = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: "master-key"
            ] as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { exit(3) }
            return
        }
        let store = LocalFileSecureStore(directoryURL: directory,
            keyStore: LocalFileSecureStoreKeychain(service: service))
        let session = AuthSession(sid: "synthetic-session", synoToken: nil, did: nil, isPortalPort: false)
        if arguments[3] == "write" {
            try await store.save(session, for: id)
            try await store.save("synthetic-password", for: id)
            let contents = try Data(contentsOf: directory.appendingPathComponent("\(id.uuidString).password.dat"))
            guard contents.range(of: Data("synthetic-password".utf8)) == nil else { exit(4) }
        } else if arguments[3] == "read" {
            let restoredSession: AuthSession? = try await store.load(for: id)
            let restoredPassword: String? = try await store.load(for: id)
            guard restoredSession == session, restoredPassword == "synthetic-password" else { exit(5) }
            try await store.remove(for: id)
        } else { exit(2) }
        print("isolated secure storage \(arguments[3]) passed")
    }
}
