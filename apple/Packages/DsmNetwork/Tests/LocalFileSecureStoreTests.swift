import CryptoKit
import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

final class LocalFileSecureStoreTests: XCTestCase {
    func test迁移旧主密钥后旧会话仍可读取且容器副本被删除() async throws {
        let directory = try makeDirectory()
        let profileID = UUID()
        let keyData = Data(repeating: 0x42, count: 32)
        let session = AuthSession(
            sid: "test-session",
            synoToken: "test-token",
            did: nil,
            isPortalPort: false
        )
        let keyURL = directory.appendingPathComponent("master.key")
        try keyData.write(to: keyURL)
        try writeLegacySession(
            session,
            profileID: profileID,
            keyData: keyData,
            directory: directory
        )
        let keyStore = InMemoryLocalSecureStoreKeyStore()
        let store = LocalFileSecureStore(
            directoryURL: directory,
            keyStore: keyStore
        )

        let loaded: AuthSession? = try await store.load(for: profileID)

        XCTAssertEqual(loaded, session)
        XCTAssertEqual(keyStore.storedKey(), keyData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func testKeychain不可用时安全失败且不生成固定回退密钥() async throws {
        let directory = try makeDirectory()
        let keyStore = InMemoryLocalSecureStoreKeyStore(shouldFail: true)
        let store = LocalFileSecureStore(
            directoryURL: directory,
            keyStore: keyStore
        )

        do {
            try await store.save(
                AuthSession(
                    sid: "test-session",
                    synoToken: nil,
                    did: nil,
                    isPortalPort: false
                ),
                for: UUID()
            )
            XCTFail("Keychain 不可用时不应继续保存凭据。")
        } catch let error as LocalFileSecureStoreError {
            XCTAssertEqual(error, .secureKeyUnavailable)
        }

        XCTAssertNil(keyStore.storedKey())
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("master.key").path
            )
        )
    }

    func test旧主密钥与Keychain密钥不一致时保留旧数据并失败() async throws {
        let directory = try makeDirectory()
        let profileID = UUID()
        let legacyKey = Data(repeating: 0x11, count: 32)
        let existingKey = Data(repeating: 0x22, count: 32)
        let keyURL = directory.appendingPathComponent("master.key")
        try legacyKey.write(to: keyURL)
        try Data([0x00]).write(
            to: directory.appendingPathComponent(
                "\(profileID.uuidString).session.dat"
            )
        )
        let keyStore = InMemoryLocalSecureStoreKeyStore(storedKey: existingKey)
        let store = LocalFileSecureStore(
            directoryURL: directory,
            keyStore: keyStore
        )

        do {
            let _: AuthSession? = try await store.load(for: profileID)
            XCTFail("不一致的主密钥不应被静默接受。")
        } catch let error as LocalFileSecureStoreError {
            XCTAssertEqual(error, .legacyKeyConflict)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func test密文损坏时抛出错误而不是当作没有凭据() async throws {
        let directory = try makeDirectory()
        let profileID = UUID()
        let store = LocalFileSecureStore(
            directoryURL: directory,
            keyStore: InMemoryLocalSecureStoreKeyStore()
        )
        try await store.save(
            AuthSession(
                sid: "test-session",
                synoToken: nil,
                did: nil,
                isPortalPort: false
            ),
            for: profileID
        )
        let encryptedFile = try XCTUnwrap(
            try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "dat" })
        )
        try Data([0x00, 0x01]).write(to: encryptedFile, options: .atomic)

        do {
            let _: AuthSession? = try await store.load(for: profileID)
            XCTFail("损坏密文不应被当作没有会话。")
        } catch {}
    }

    func test初始化和保存时收紧既有安全目录和数据文件权限() async throws {
        let directory = try makeDirectory()
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o755))],
            ofItemAtPath: directory.path
        )
        let profileID = UUID()
        let store = LocalFileSecureStore(
            directoryURL: directory,
            keyStore: InMemoryLocalSecureStoreKeyStore()
        )

        XCTAssertEqual(try permissions(of: directory), 0o700)

        try await store.save(
            AuthSession(
                sid: "test-session",
                synoToken: nil,
                did: nil,
                isPortalPort: false
            ),
            for: profileID
        )

        let directoryPermissions = try permissions(of: directory)
        let dataPermissions = try permissions(
            of: directory.appendingPathComponent(
                "\(profileID.uuidString).session.dat"
            )
        )
        XCTAssertEqual(directoryPermissions, 0o700)
        XCTAssertEqual(dataPermissions, 0o600)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func writeLegacySession(
        _ session: AuthSession,
        profileID: UUID,
        keyData: Data,
        directory: URL
    ) throws {
        let sealed = try AES.GCM.seal(
            JSONEncoder().encode(session),
            using: SymmetricKey(data: keyData)
        )
        try XCTUnwrap(sealed.combined).write(
            to: directory.appendingPathComponent(
                "\(profileID.uuidString).session.dat"
            )
        )
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let rawValue = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        return rawValue.intValue & 0o777
    }
}

private enum LocalFileSecureStoreTestError: Error {
    case unavailable
}

private final class InMemoryLocalSecureStoreKeyStore:
    LocalFileSecureStoreKeyStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var value: Data?
    private let shouldFail: Bool

    init(storedKey: Data? = nil, shouldFail: Bool = false) {
        value = storedKey
        self.shouldFail = shouldFail
    }

    func loadOrCreate(_ candidate: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if shouldFail {
            throw LocalFileSecureStoreTestError.unavailable
        }
        if let value {
            return value
        }
        value = candidate
        return candidate
    }

    func storedKey() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
