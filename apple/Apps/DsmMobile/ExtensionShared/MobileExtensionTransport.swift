import DsmCore
import DsmLocalization
import DsmNetwork
import Foundation

/// 沿用原传输的 TLS/同源保护，另在扩展执行期间持续检查主 App 的撤销记录。
struct MobileExtensionTransport: DsmBinaryHTTPTransport {
    let account: MobileExtensionAccount
    let accounts: MobileExtensionAccountStore
    let sessions: any SessionSecureStoring
    let transport: any DsmBinaryHTTPTransport
    var validateContext: @Sendable () async throws -> Void = {}

    static func repository(account: MobileExtensionAccount, accounts: MobileExtensionAccountStore,
                           sessions: any SessionSecureStoring, transport suppliedTransport: (any DsmBinaryHTTPTransport)? = nil,
                           validateContext: @escaping @Sendable () async throws -> Void = {}) async throws -> DsmFileRepository {
        try await validateContext()
        try accounts.requireCurrent(account)
        guard let session = try await sessions.load(for: account.id) else { throw authenticationError }
        try accounts.requireCurrent(account)
        let profile = account.connection.profile
        let transport = Self(account: account, accounts: accounts, sessions: sessions,
            transport: suppliedTransport ?? URLSessionTransport(expectedHost: profile.host,
                pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
                requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(profile.host)),
            validateContext: validateContext)
        return try DsmFileRepository(profile: profile, capabilities: account.connection.capabilitySet,
            session: session, transport: transport)
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        try await guarded { try await transport.send(request) }
    }

    func download(_ request: URLRequest, to destinationURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try await guarded { try await transport.download(request, to: destinationURL, progress: progress) }
    }

    func upload(_ request: URLRequest, from bodyFileURL: URL, progress: @escaping FileTransferProgress) async throws -> DsmHTTPResponse {
        try await guarded { try await transport.upload(request, from: bodyFileURL, progress: progress) }
    }

    private func requireCurrent() async throws {
        try Task.checkCancellation()
        try await validateContext()
        do {
            try accounts.requireCurrent(account)
            guard try await sessions.load(for: account.id) != nil else { throw MobileExtensionAccountError.signedOut }
            try accounts.requireCurrent(account)
        } catch { throw Self.authenticationError }
    }

    private func guarded(_ operation: @escaping @Sendable () async throws -> DsmHTTPResponse) async throws -> DsmHTTPResponse {
        try await requireCurrent()
        return try await withThrowingTaskGroup(of: DsmHTTPResponse.self) { group in
            group.addTask {
                try await requireCurrent()
                let response = try await operation()
                try await requireCurrent()
                return response
            }
            group.addTask {
                while true {
                    try await Task.sleep(for: .milliseconds(250))
                    try await requireCurrent()
                }
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }

    private static var authenticationError: AppError {
        AppError(category: .authenticationRequired, isRetryable: false,
            safeUserMessage: L10n.string("mobile.extensions.sign-in-again"))
    }
}
