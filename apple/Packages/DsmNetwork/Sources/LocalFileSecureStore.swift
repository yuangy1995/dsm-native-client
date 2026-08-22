import CryptoKit
import DsmCore
import Foundation
import Security

/// 应用私有主密钥不可用或旧格式无法安全迁移时的错误。
public enum LocalFileSecureStoreError: Error, Equatable, Sendable {
    case secureDirectoryUnavailable
    case secureKeyUnavailable
    case invalidLegacyKey
    case legacyKeyConflict
}

/// 把 AES 主密钥限定在应用私有 Keychain 中，数据文件本身仍保持既有 AES-GCM 格式。
///
/// 该协议仅用于将系统 Keychain 调用与可重跑的故障注入测试隔离，不向业务层暴露。
protocol LocalFileSecureStoreKeyStoring: Sendable {
    /// 若已存在密钥则返回既有密钥；否则原子地保存并返回候选密钥。
    func loadOrCreate(_ candidate: Data) throws -> Data
}

private struct LocalFileSecureStoreKeychain: LocalFileSecureStoreKeyStoring {
    private let service =
        "io.github.qwertyuiop1995.dsmnativeclient.local-secure-store.master-key.v1"
    private let account = "master-key"

    func loadOrCreate(_ candidate: Data) throws -> Data {
        if let existing = try load() {
            return existing
        }

        var addQuery = baseQuery()
        addQuery[kSecValueData as String] = candidate
        addQuery[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return candidate
        }
        if addStatus == errSecDuplicateItem, let existing = try load() {
            return existing
        }
        throw KeychainStoreError(status: addStatus)
    }

    private func load() throws -> Data? {
        var query = baseQuery()
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

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public actor LocalFileSecureStore: SessionSecureStoring, PasswordSecureStoring {
    private let fileManager: FileManager
    private let secureDirectoryURL: URL
    private let encryptionKey: SymmetricKey?
    private let initializationError: LocalFileSecureStoreError?

    public init() {
        let fileManager = FileManager.default
        self.fileManager = fileManager
        guard let directoryURL = Self.defaultSecureDirectory(fileManager: fileManager)
        else {
            secureDirectoryURL = fileManager.temporaryDirectory
            encryptionKey = nil
            initializationError = .secureDirectoryUnavailable
            return
        }
        secureDirectoryURL = directoryURL
        do {
            encryptionKey = try Self.loadOrCreateEncryptionKey(
                directoryURL: directoryURL,
                fileManager: fileManager,
                keyStore: LocalFileSecureStoreKeychain()
            )
            initializationError = nil
        } catch let error as LocalFileSecureStoreError {
            encryptionKey = nil
            initializationError = error
        } catch {
            encryptionKey = nil
            initializationError = .secureKeyUnavailable
        }
    }

    init(
        directoryURL: URL,
        fileManager: FileManager = .default,
        keyStore: any LocalFileSecureStoreKeyStoring
    ) {
        self.fileManager = fileManager
        secureDirectoryURL = directoryURL
        do {
            encryptionKey = try Self.loadOrCreateEncryptionKey(
                directoryURL: directoryURL,
                fileManager: fileManager,
                keyStore: keyStore
            )
            initializationError = nil
        } catch let error as LocalFileSecureStoreError {
            encryptionKey = nil
            initializationError = error
        } catch {
            encryptionKey = nil
            initializationError = .secureKeyUnavailable
        }
    }

    private static func defaultSecureDirectory(
        fileManager: FileManager
    ) -> URL? {
        fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?.appendingPathComponent(
            "LanStashSecureStore",
            isDirectory: true
        )
    }

    private static func loadOrCreateEncryptionKey(
        directoryURL: URL,
        fileManager: FileManager,
        keyStore: any LocalFileSecureStoreKeyStoring
    ) throws -> SymmetricKey {
        try ensureSecureDirectory(at: directoryURL, fileManager: fileManager)
        let legacyKeyURL = directoryURL.appendingPathComponent("master.key")
        let legacyKeyData: Data?
        if fileManager.fileExists(atPath: legacyKeyURL.path) {
            legacyKeyData = try Data(contentsOf: legacyKeyURL)
            guard legacyKeyData?.count == 32 else {
                throw LocalFileSecureStoreError.invalidLegacyKey
            }
        } else {
            legacyKeyData = nil
        }

        let candidate = legacyKeyData ?? randomKeyData()
        let keyData: Data
        do {
            keyData = try keyStore.loadOrCreate(candidate)
        } catch {
            throw LocalFileSecureStoreError.secureKeyUnavailable
        }
        guard keyData.count == 32 else {
            throw LocalFileSecureStoreError.secureKeyUnavailable
        }

        if let legacyKeyData {
            guard legacyKeyData == keyData else {
                throw LocalFileSecureStoreError.legacyKeyConflict
            }
            do {
                try fileManager.removeItem(at: legacyKeyURL)
            } catch {
                // 不能确认该 Keychain 项是否由本轮创建，不能删除既有密钥；
                // 保留失败状态以便后续启动重试清理旧副本。
                throw LocalFileSecureStoreError.secureKeyUnavailable
            }
        }
        return SymmetricKey(data: keyData)
    }

    private static func randomKeyData() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    private func fileURL(for name: String, profileID: UUID) -> URL {
        secureDirectoryURL.appendingPathComponent(
            "\(profileID.uuidString).\(name).dat",
            isDirectory: false
        )
    }

    private func requireEncryptionKey() throws -> SymmetricKey {
        guard let encryptionKey else {
            throw initializationError ?? .secureKeyUnavailable
        }
        return encryptionKey
    }

    private static func ensureSecureDirectory(
        at directoryURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        // 已有目录不会因 createDirectory 再次调用而自动更新权限，必须主动收紧旧版本目录。
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: directoryURL.path
        )
    }

    private func encryptAndSave(_ plainData: Data, to url: URL) throws {
        let key = try requireEncryptionKey()
        try Self.ensureSecureDirectory(
            at: secureDirectoryURL,
            fileManager: fileManager
        )
        let sealedBox = try AES.GCM.seal(plainData, using: key)
        guard let encryptedData = sealedBox.combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        #if os(iOS)
        // iOS 支持系统文件保护，保持设备锁定后的额外保护。
        let writeOptions: Data.WritingOptions = [.atomic, .completeFileProtection]
        #else
        // macOS 沙盒不支持 completeFileProtection；AES-GCM 与 0600 权限仍是主保护边界。
        let writeOptions: Data.WritingOptions = [.atomic]
        #endif
        try encryptedData.write(to: url, options: writeOptions)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: url.path
        )
    }

    private func loadAndDecrypt(from url: URL) throws -> Data? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let key = try requireEncryptionKey()
        let encryptedData = try Data(contentsOf: url)
        let sealedBox = try AES.GCM.SealedBox(combined: encryptedData)
        return try AES.GCM.open(sealedBox, using: key)
    }

    private func removeIfPresent(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    // MARK: - SessionSecureStoring

    public func save(_ session: AuthSession, for profileID: UUID) async throws {
        try encryptAndSave(
            JSONEncoder().encode(session),
            to: fileURL(for: "session", profileID: profileID)
        )
    }

    public func load(for profileID: UUID) async throws -> AuthSession? {
        guard let decryptedData = try loadAndDecrypt(
            from: fileURL(for: "session", profileID: profileID)
        ) else {
            return nil
        }
        return try JSONDecoder().decode(AuthSession.self, from: decryptedData)
    }

    // MARK: - PasswordSecureStoring

    public func save(_ password: String, for profileID: UUID) async throws {
        try encryptAndSave(
            Data(password.utf8),
            to: fileURL(for: "password", profileID: profileID)
        )
    }

    public func load(for profileID: UUID) async throws -> String? {
        guard let decryptedData = try loadAndDecrypt(
            from: fileURL(for: "password", profileID: profileID)
        ) else {
            return nil
        }
        guard let password = String(data: decryptedData, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return password
    }

    // MARK: - Combined Removal for protocols

    public func remove(for profileID: UUID) async throws {
        try removeIfPresent(at: fileURL(for: "session", profileID: profileID))
        try removeIfPresent(at: fileURL(for: "password", profileID: profileID))
    }
}
