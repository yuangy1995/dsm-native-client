import DsmCore
import DsmNetwork
import XCTest
@testable import DsmMobile

final class MobileSecureStoreDefaultsTests: XCTestCase {
    func testSimulatorUsesSandboxEncryptedStoreWithoutSigningEntitlements() {
#if targetEnvironment(simulator)
        XCTAssertTrue(MobileSecureStoreDefaults.sessionStore() is LocalFileSecureStore)
        XCTAssertTrue(MobileSecureStoreDefaults.passwordStore() is LocalFileSecureStore)
#endif
    }

    func testSimulatorDefaultStoresRoundTripSessionAndPassword() async throws {
#if targetEnvironment(simulator)
        let profileID = UUID()
        let sessionStore = MobileSecureStoreDefaults.sessionStore()
        let passwordStore = MobileSecureStoreDefaults.passwordStore()
        let session = AuthSession(
            sid: "synthetic-session",
            synoToken: nil,
            did: nil,
            isPortalPort: false
        )
        try await sessionStore.save(session, for: profileID)
        try await passwordStore.save("synthetic-password", for: profileID)
        let restoredSession = try await sessionStore.load(for: profileID)
        let restoredPassword = try await passwordStore.load(for: profileID)

        XCTAssertEqual(restoredSession, session)
        XCTAssertEqual(restoredPassword, "synthetic-password")
        try await sessionStore.remove(for: profileID)
        try await passwordStore.remove(for: profileID)
#endif
    }
}
