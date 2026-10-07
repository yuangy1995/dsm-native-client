import Darwin
import DsmCore
import DsmNetwork
import Foundation

enum MobileExtensionStorage {
    static let groupInfoKey = "LanStashMobileAppGroupIdentifier"
    static let sessionService = "io.github.qwertyuiop1995.dsmnativeclient.mobile.shared"

    static var preferences: UserDefaults? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: groupInfoKey) as? String,
              !group.isEmpty, !group.contains("$(") else { return nil }
        return UserDefaults(suiteName: group)
    }

    static func rootURL() throws -> URL {
        guard let group = Bundle.main.object(forInfoDictionaryKey: groupInfoKey) as? String,
              !group.isEmpty, !group.contains("$("),
              let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else {
            throw MobileExtensionAccountError.unavailable
        }
        return root.appendingPathComponent("MobileExtensions", isDirectory: true)
    }

    static func prepareDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    static func sessionStore() throws -> SharedKeychainSessionStore {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "LanStashSharedKeychainAccessGroup") as? String,
              !group.isEmpty, !group.contains("$(") else { throw MobileExtensionAccountError.unavailable }
        return SharedKeychainSessionStore(accessGroup: group, servicePrefix: sessionService)
    }
}

enum MobileExtensionAccountError: Error, Equatable { case unavailable, signedOut, invalidRecord }

struct MobileExtensionAccount: Codable, Equatable, Sendable, Identifiable {
    /// 这是共享会话的独立编号，不是主 App 的配置编号。
    let id: UUID
    let profile: NasProfile
    let connection: DesktopDriveProviderConnection
    var isActive: Bool

    var identity: MobileWorkspaceIdentity { MobileWorkspaceIdentity(profile) }
}

/// 所有读取重新取得文件锁并加载磁盘；不能以进程内缓存替代撤销判断。
struct MobileExtensionAccountStore: Sendable {
    private struct Snapshot: Codable {
        var version = 1
        var accounts: [MobileExtensionAccount] = []
        var retiredSessionIDs: Set<UUID> = []
    }

    let rootURL: URL
    var recordsURL: URL { rootURL.appendingPathComponent("accounts-v1.json") }

    func accounts() throws -> [MobileExtensionAccount] {
        try read { $0.accounts.filter(\.isActive).sorted { $0.profile.displayName.localizedStandardCompare($1.profile.displayName) == .orderedAscending } }
    }

    func requireCurrent(_ account: MobileExtensionAccount) throws {
        try read { snapshot in
            guard snapshot.accounts.contains(where: { $0.id == account.id && $0.isActive && $0 == account }) else {
                throw MobileExtensionAccountError.signedOut
            }
        }
    }

    func reserve(profile: NasProfile, connection: NasProfile, capabilities: CapabilitySet) throws -> MobileExtensionAccount {
        guard profile.id == connection.id, profile.usernameHint == connection.usernameHint else {
            throw MobileExtensionAccountError.invalidRecord
        }
        let names: Set<String> = [DsmAPIName.fileStationList, DsmAPIName.fileStationDownload,
            DsmAPIName.fileStationUpload, DsmAPIName.fileStationCheckPermission, DsmAPIName.fileStationCreateFolder,
            DsmAPIName.fileStationRename, DsmAPIName.fileStationCopyMove, DsmAPIName.fileStationDelete, DsmAPIName.fileStationMD5]
        let fileCapabilities = CapabilitySet(Dictionary(uniqueKeysWithValues: capabilities.all
            .filter { names.contains($0.name) }.map { ($0.name, $0) }))
        let account = MobileExtensionAccount(id: UUID(), profile: profile,
            connection: .init(profile: connection, capabilities: fileCapabilities), isActive: false)
        try update { snapshot in
            snapshot.retiredSessionIDs.formUnion(snapshot.accounts.filter { $0.profile.id == profile.id }.map(\.id))
            snapshot.accounts.removeAll { $0.profile.id == profile.id }
            snapshot.accounts.append(account)
        }
        return account
    }

    func activate(_ account: MobileExtensionAccount) throws -> MobileExtensionAccount {
        var active = account
        active.isActive = true
        try update { snapshot in
            guard let index = snapshot.accounts.firstIndex(where: { $0 == account }) else {
                throw MobileExtensionAccountError.signedOut
            }
            snapshot.accounts[index] = active
        }
        return active
    }

    func revoke(profileID: UUID, publicationID: UUID? = nil) throws {
        try update { snapshot in
            let removed = snapshot.accounts.filter {
                $0.profile.id == profileID && (publicationID == nil || $0.id == publicationID)
            }
            if let publicationID { snapshot.retiredSessionIDs.insert(publicationID) }
            snapshot.retiredSessionIDs.formUnion(removed.map(\.id))
            snapshot.accounts.removeAll { account in removed.contains { $0.id == account.id } }
        }
    }

    func retiredSessionIDs() throws -> Set<UUID> { try read { $0.retiredSessionIDs } }

    func reconcileProfiles(_ profiles: [NasProfile]) throws {
        try update { snapshot in
            let removed = snapshot.accounts.filter { account in
                !account.isActive || !profiles.contains { profile in
                    MobileWorkspaceIdentity(profile) == account.identity
                        && profile.pinnedCertificateSHA256 == account.profile.pinnedCertificateSHA256
                }
            }
            snapshot.retiredSessionIDs.formUnion(removed.map(\.id))
            snapshot.accounts.removeAll { account in removed.contains { $0.id == account.id } }
        }
    }

    func didRemoveSession(_ id: UUID) throws {
        try update { $0.retiredSessionIDs.remove(id) }
    }

    private func read<Value>(_ body: (Snapshot) throws -> Value) throws -> Value {
        try locked { try body(load()) }
    }

    private func update(_ body: (inout Snapshot) throws -> Void) throws {
        try locked {
            var snapshot = try load()
            try body(&snapshot)
            try JSONEncoder().encode(snapshot).write(to: recordsURL, options: [.atomic, .completeFileProtection])
        }
    }

    private func load() throws -> Snapshot {
        guard FileManager.default.fileExists(atPath: recordsURL.path) else { return Snapshot() }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: recordsURL))
        guard snapshot.version == 1,
              Set(snapshot.accounts.map(\.id)).count == snapshot.accounts.count,
              Set(snapshot.accounts.map { $0.profile.id }).count == snapshot.accounts.count,
              snapshot.accounts.allSatisfy({ account in
                  account.profile.id == account.connection.profile.id && !snapshot.retiredSessionIDs.contains(account.id)
                    && Set(account.connection.capabilities.map(\.name)).count == account.connection.capabilities.count
              }) else { throw MobileExtensionAccountError.invalidRecord }
        return snapshot
    }

    private func locked<Value>(_ body: () throws -> Value) throws -> Value {
        try MobileExtensionStorage.prepareDirectory(rootURL)
        let descriptor = open(rootURL.appendingPathComponent("accounts.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

/// 主 App 负责发布与撤销；扩展只能消费账号快照，不读取或复制密码。
@MainActor
final class MobileExtensionAccess {
    let accounts: MobileExtensionAccountStore
    let sessions: any SessionSecureStoring
    private var cleanupTask: Task<Void, Never>?

    init(accounts: MobileExtensionAccountStore, sessions: any SessionSecureStoring) {
        self.accounts = accounts
        self.sessions = sessions
    }

    static func live() throws -> MobileExtensionAccess {
        try .init(accounts: .init(rootURL: MobileExtensionStorage.rootURL()), sessions: MobileExtensionStorage.sessionStore())
    }

    @discardableResult
    func publish(profile: NasProfile, connection: NasProfile, capabilities: CapabilitySet, session: AuthSession) async throws -> MobileExtensionAccount {
        let reserved = try accounts.reserve(profile: profile, connection: connection, capabilities: capabilities)
        do {
            let shared = AuthSession(sid: session.sid, synoToken: session.synoToken, did: nil,
                isPortalPort: session.isPortalPort, transportVersion: session.transportVersion)
            try await sessions.save(shared, for: reserved.id)
            try Task.checkCancellation()
            // 已退休编号永不复用；迟到清理不会删除另一轮登录会话。
            await cleanRetiredSessions()
            try Task.checkCancellation()
            return try accounts.activate(reserved)
        } catch {
            try? accounts.revoke(profileID: profile.id, publicationID: reserved.id)
            // 即使另一个发布已接管同一配置，也只删除本次生成的会话编号。
            do {
                try await sessions.remove(for: reserved.id)
                try accounts.didRemoveSession(reserved.id)
            } catch {
                // 保留该独立编号的清理记录，即使旧清理早于迟到 save 完成。
            }
            throw error
        }
    }

    func revoke(profileID: UUID) throws {
        try accounts.revoke(profileID: profileID)
        Task { await cleanRetiredSessions() }
    }

    func cleanRetiredSessions() async {
        if let cleanupTask { await cleanupTask.value; return }
        let task = Task { await removeRetiredSessions() }
        cleanupTask = task
        await task.value
        cleanupTask = nil
    }

    private func removeRetiredSessions() async {
        guard let ids = try? accounts.retiredSessionIDs() else { return }
        for id in ids {
            do {
                try await sessions.remove(for: id)
                try accounts.didRemoveSession(id)
            } catch {
                // 保留清理记录供下次重试；已撤销元数据始终不能产生新请求。
                continue
            }
        }
    }
}
