import DsmCore
import Foundation
import Security
import XCTest
@testable import DsmNetwork

final class SharedKeychainSessionStoreTests: XCTestCase {
    func testUpsert更新成功时不新增也不删除旧会话() throws {
        var updateCount = 0
        var addCount = 0

        try KeychainItemUpsert.save(
            update: {
                updateCount += 1
                return errSecSuccess
            },
            add: {
                addCount += 1
                return errSecSuccess
            }
        )

        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(addCount, 0)
    }

    func testUpsert新增失败时返回错误而不执行删除() {
        var updateCount = 0
        var addCount = 0

        XCTAssertThrowsError(
            try KeychainItemUpsert.save(
                update: {
                    updateCount += 1
                    return errSecItemNotFound
                },
                add: {
                    addCount += 1
                    return errSecAuthFailed
                }
            )
        ) { error in
            XCTAssertEqual(
                (error as? KeychainStoreError)?.status,
                errSecAuthFailed
            )
        }

        XCTAssertEqual(updateCount, 1)
        XCTAssertEqual(addCount, 1)
    }

    func testUpsert遇到并发新增时重试更新() throws {
        var updateResults: [OSStatus] = [errSecItemNotFound, errSecSuccess]
        var addCount = 0

        try KeychainItemUpsert.save(
            update: {
                updateResults.removeFirst()
            },
            add: {
                addCount += 1
                return errSecDuplicateItem
            }
        )

        XCTAssertTrue(updateResults.isEmpty)
        XCTAssertEqual(addCount, 1)
    }

    func test迁移临时失败后下次调用会重试() async throws {
        let profileID = UUID()
        let localStore = MigrationLocalStore(failingPasswordSaves: 1)
        let sharedStore = MigrationSessionStore()
        let legacyStore = MigrationLegacyPasswordStore(password: "legacy-password")
        let migrator = DesktopSecureStoreRollbackMigrator(
            localStore: localStore,
            sharedSessionStore: sharedStore,
            hasMappings: { _ in false },
            legacyPasswordStore: legacyStore
        )

        await migrator.migrateIfNeeded(profileID: profileID)
        let firstPassword: String? = try await localStore.load(for: profileID)
        let legacyPasswordAfterFailure = await legacyStore.password(
            for: profileID
        )
        XCTAssertNil(firstPassword)
        XCTAssertEqual(legacyPasswordAfterFailure, "legacy-password")

        await migrator.migrateIfNeeded(profileID: profileID)
        let migratedPassword: String? = try await localStore.load(for: profileID)
        let legacyPasswordAfterMigration = await legacyStore.password(
            for: profileID
        )
        let passwordSaveAttempts = await localStore.passwordSaveAttempts()
        XCTAssertEqual(migratedPassword, "legacy-password")
        XCTAssertNil(legacyPasswordAfterMigration)
        XCTAssertEqual(passwordSaveAttempts, 2)
    }
}

private enum SharedKeychainSessionStoreTestError: Error {
    case writeFailed
}

private actor MigrationLocalStore: LocalCredentialSecureStoring {
    private var sessions: [UUID: AuthSession] = [:]
    private var passwords: [UUID: String] = [:]
    private var remainingPasswordSaveFailures: Int
    private var passwordSaves = 0

    init(failingPasswordSaves: Int) {
        remainingPasswordSaveFailures = failingPasswordSaves
    }

    func save(_ session: AuthSession, for profileID: UUID) async throws {
        sessions[profileID] = session
    }

    func load(for profileID: UUID) async throws -> AuthSession? {
        sessions[profileID]
    }

    func save(_ password: String, for profileID: UUID) async throws {
        passwordSaves += 1
        if remainingPasswordSaveFailures > 0 {
            remainingPasswordSaveFailures -= 1
            throw SharedKeychainSessionStoreTestError.writeFailed
        }
        passwords[profileID] = password
    }

    func load(for profileID: UUID) async throws -> String? {
        passwords[profileID]
    }

    func remove(for profileID: UUID) async throws {
        sessions[profileID] = nil
        passwords[profileID] = nil
    }

    func passwordSaveAttempts() -> Int {
        passwordSaves
    }
}

private actor MigrationSessionStore: SessionSecureStoring {
    private var sessions: [UUID: AuthSession] = [:]

    func save(_ session: AuthSession, for profileID: UUID) async throws {
        sessions[profileID] = session
    }

    func load(for profileID: UUID) async throws -> AuthSession? {
        sessions[profileID]
    }

    func remove(for profileID: UUID) async throws {
        sessions[profileID] = nil
    }
}

private actor MigrationLegacyPasswordStore: LegacySharedPasswordStoring {
    private var passwords: [UUID: String] = [:]
    private var initialPassword: String?

    init(password: String?) {
        initialPassword = password
    }

    func load(for profileID: UUID) async throws -> String? {
        if let stored = passwords[profileID] {
            return stored
        }
        if let initialPassword {
            passwords[profileID] = initialPassword
            self.initialPassword = nil
            return initialPassword
        }
        return nil
    }

    func remove(for profileID: UUID) async throws {
        passwords[profileID] = nil
    }

    func password(for profileID: UUID) -> String? {
        passwords[profileID]
    }
}
