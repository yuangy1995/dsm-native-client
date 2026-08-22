import DsmCore
import Foundation
import Security

/// Keychain 的更新与新增之间可能发生并发竞争，因此只允许“更新优先、找不到再新增”。
/// 不得以删除旧项作为更新前置条件，否则新增失败会丢失仍有效的共享会话。
enum KeychainItemUpsert {
    static func save(
        update: () -> OSStatus,
        add: () -> OSStatus
    ) throws {
        let updateStatus = update()
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError(status: updateStatus)
        }

        let addStatus = add()
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let retryStatus = update()
            guard retryStatus == errSecSuccess else {
                throw KeychainStoreError(status: retryStatus)
            }
            return
        }
        throw KeychainStoreError(status: addStatus)
    }
}

/// 仅供主 App 与 File Provider 扩展共享最小必要会话，不保存登录密码。
public actor SharedKeychainSessionStore: SessionSecureStoring {
    private let accessGroup: String?
    private let servicePrefix: String

    public init(
        accessGroup: String? = Bundle.main.object(
            forInfoDictionaryKey: "LanStashSharedKeychainAccessGroup"
        ) as? String,
        servicePrefix: String = "io.github.qwertyuiop1995.dsmnativeclient.shared"
    ) {
        self.accessGroup = accessGroup
        self.servicePrefix = servicePrefix
    }

    public func save(_ session: AuthSession, for profileID: UUID) async throws {
        try save(
            try JSONEncoder().encode(session),
            service: sessionService,
            profileID: profileID
        )
    }

    public func load(for profileID: UUID) async throws -> AuthSession? {
        guard let data = try load(
            service: sessionService,
            profileID: profileID
        ) else {
            return nil
        }
        return try JSONDecoder().decode(AuthSession.self, from: data)
    }

    public func remove(for profileID: UUID) async throws {
        try remove(service: sessionService, profileID: profileID)
    }

    private var sessionService: String {
        "\(servicePrefix).session"
    }

    private func save(
        _ data: Data,
        service: String,
        profileID: UUID
    ) throws {
        let query = baseQuery(service: service, profileID: profileID)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        try KeychainItemUpsert.save(
            update: {
                SecItemUpdate(
                    query as CFDictionary,
                    attributes as CFDictionary
                )
            },
            add: {
                var addQuery = query
                for (key, value) in attributes {
                    addQuery[key] = value
                }
                return SecItemAdd(addQuery as CFDictionary, nil)
            }
        )
    }

    private func load(service: String, profileID: UUID) throws -> Data? {
        var query = baseQuery(service: service, profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainStoreError(status: status)
        }
        return data
    }

    private func remove(service: String, profileID: UUID) throws {
        let status = SecItemDelete(
            baseQuery(service: service, profileID: profileID) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }

    private func baseQuery(
        service: String,
        profileID: UUID
    ) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}

public struct KeychainStoreError: Error, Equatable, Sendable {
    public let status: OSStatus

    public init(status: OSStatus) {
        self.status = status
    }
}

protocol LocalCredentialSecureStoring:
    SessionSecureStoring,
    PasswordSecureStoring {}

extension LocalFileSecureStore: LocalCredentialSecureStoring {}

protocol LegacySharedPasswordStoring: Sendable {
    func load(for profileID: UUID) async throws -> String?
    func remove(for profileID: UUID) async throws
}

/// 把短期版本迁入共享钥匙串的资料迁回应用内加密存储。
///
/// 迁移完成后共享钥匙串不再保留密码；只有仍存在 Finder 映射时才保留会话。
public actor DesktopSecureStoreRollbackMigrator {
    private let localStore: any LocalCredentialSecureStoring
    private let sharedSessionStore: any SessionSecureStoring
    private let hasMappings: @Sendable (UUID) async throws -> Bool
    private let legacyPasswordStore: any LegacySharedPasswordStoring
    private var migratedProfileIDs: Set<UUID> = []

    public init(
        localStore: LocalFileSecureStore,
        sharedSessionStore: SharedKeychainSessionStore,
        configurationStore: DesktopDriveConfigurationStore = .init()
    ) {
        self.localStore = localStore
        self.sharedSessionStore = sharedSessionStore
        hasMappings = { profileID in
            try await configurationStore.mappings(profileID: profileID)
                .isEmpty == false
        }
        self.legacyPasswordStore = LegacySharedKeychainPasswordStore()
    }

    init(
        localStore: any LocalCredentialSecureStoring,
        sharedSessionStore: any SessionSecureStoring,
        hasMappings: @escaping @Sendable (UUID) async throws -> Bool,
        legacyPasswordStore: any LegacySharedPasswordStoring
    ) {
        self.localStore = localStore
        self.sharedSessionStore = sharedSessionStore
        self.hasMappings = hasMappings
        self.legacyPasswordStore = legacyPasswordStore
    }

    public func migrateIfNeeded(profileID: UUID) async {
        guard !migratedProfileIDs.contains(profileID) else {
            return
        }
        do {
            let localSession: AuthSession? = try await localStore.load(
                for: profileID
            )
            let localPassword: String? = try await localStore.load(
                for: profileID
            )
            let sharedSession = try await sharedSessionStore.load(
                for: profileID
            )
            let sharedPassword = try await legacyPasswordStore.load(
                for: profileID
            )
            if localSession == nil, let sharedSession {
                try await localStore.save(sharedSession, for: profileID)
            }
            if localPassword == nil, let sharedPassword {
                try await localStore.save(sharedPassword, for: profileID)
            }
            if sharedPassword != nil {
                try await legacyPasswordStore.remove(for: profileID)
            }
            let keepsSharedSession = try await hasMappings(profileID)
            if !keepsSharedSession {
                try await sharedSessionStore.remove(for: profileID)
            }
            // 只有所有目标写入和源数据清理都成功，才阻止后续重复迁移。
            migratedProfileIDs.insert(profileID)
        } catch {
            // 迁移失败时保留可重试资格；任何尚未完成的源数据都不能被当作已迁移。
        }
    }
}

private struct LegacySharedKeychainPasswordStore: LegacySharedPasswordStoring {
    private let accessGroup: String? = Bundle.main.object(
        forInfoDictionaryKey: "LanStashSharedKeychainAccessGroup"
    ) as? String
    private let service =
        "io.github.qwertyuiop1995.dsmnativeclient.shared.password"

    func load(for profileID: UUID) async throws -> String? {
        var query = baseQuery(profileID: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainStoreError(status: status)
        }
        return String(data: data, encoding: .utf8)
    }

    func remove(for profileID: UUID) async throws {
        let status = SecItemDelete(
            baseQuery(profileID: profileID) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }

    private func baseQuery(profileID: UUID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
