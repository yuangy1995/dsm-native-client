import DsmCore
import Foundation
import DsmLocalization

public actor DsmAuthRepository: AuthRepository {
    private let sessionStore: any SessionSecureStoring
    private let transportFactory: @Sendable (NasProfile) -> any DsmHTTPTransport

    public init(
        sessionStore: any SessionSecureStoring = LocalFileSecureStore(),
        transportFactory: @escaping @Sendable (NasProfile) -> any DsmHTTPTransport = { profile in
            URLSessionTransport(
                expectedHost: profile.host,
                pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
                requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(
                    profile.host
                )
            )
        }
    ) {
        self.sessionStore = sessionStore
        self.transportFactory = transportFactory
    }

    public func discover(profile: NasProfile) async throws -> CapabilitySet {
        let client = try makeClient(for: profile)
        return try await DsmCapabilityDiscovery(client: client).discover()
    }

    public func login(
        profile: NasProfile,
        capabilities: CapabilitySet,
        account: String,
        password: String,
        otpCode: String?
    ) async throws -> AuthSession {
        guard let capability = capabilities[DsmAPIName.authentication] else {
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.c9fdaa50f318a255")
            )
        }

        let client = try makeClient(for: profile)
        let session = try await DsmAuthenticationService(client: client).login(
            capability: capability,
            account: account,
            password: password,
            otpCode: otpCode
        )
        try Task.checkCancellation()

        do {
            try await sessionStore.save(session, for: profile.id)
        } catch {
            throw AppError(
                category: .unknown,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.138cb3321aeec22f")
            )
        }
        try Task.checkCancellation()
        return session
    }

    public func restoreSession(for profileID: UUID) async throws -> AuthSession? {
        do {
            guard let session = try await sessionStore.load(for: profileID) else {
                return nil
            }
            guard session.transportVersion >= AuthSession.currentTransportVersion else {
                try await sessionStore.remove(for: profileID)
                return nil
            }
            return session
        } catch {
            throw AppError(
                category: .authenticationRequired,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.18e15bfc47d389cd")
            )
        }
    }

    public func clearSession(for profileID: UUID) async throws {
        do {
            try await sessionStore.remove(for: profileID)
        } catch {
            throw AppError(
                category: .unknown,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.4b88e52d11ac0435")
            )
        }
    }

    public func logout(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession
    ) async throws {
        var remoteError: Error?
        if let capability = capabilities[DsmAPIName.authentication] {
            do {
                let client = try makeClient(for: profile)
                try await DsmAuthenticationService(client: client).logout(
                    capability: capability,
                    session: session
                )
            } catch {
                remoteError = error
            }
        }

        try await clearSession(for: profile.id)
        if let remoteError {
            throw remoteError
        }
    }

    private func makeClient(for profile: NasProfile) throws -> DsmAPIClient {
        do {
            return DsmAPIClient(
                baseURL: try DsmEndpoint.baseURL(for: profile),
                transport: transportFactory(profile)
            )
        } catch {
            throw AppError(
                category: .invalidResponse,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.fef12d46ae67039c")
            )
        }
    }
}
