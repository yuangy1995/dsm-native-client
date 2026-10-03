import CryptoKit
import DsmCore
import Foundation

/// 配置名称和证书更新不改变账号；端点或账号改变必须隔离缓存、草稿和任务。
struct MobileWorkspaceIdentity: Hashable, Sendable {
    let profileID: UUID
    let scheme: NasScheme
    let host: String
    let port: Int
    let account: String

    init(_ profile: NasProfile) {
        profileID = profile.id; scheme = profile.scheme; host = profile.host.lowercased()
        port = profile.port; account = profile.usernameHint ?? ""
    }

    var storageIdentifier: String {
        let value = [profileID.uuidString, scheme.rawValue, host, String(port), account].joined(separator: "\n")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
