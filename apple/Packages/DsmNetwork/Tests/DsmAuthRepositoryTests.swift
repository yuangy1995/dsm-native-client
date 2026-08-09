import DsmCore
import Foundation
import XCTest
@testable import DsmNetwork

private actor SuspendedAuthTransport: DsmHTTPTransport {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var requestStarted = false

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requestStarted = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
        return DsmHTTPResponse(
            data: Data(#"{"success":true,"data":{"sid":"cancelled-session"}}"#.utf8),
            statusCode: 200
        )
    }

    func releaseResponse() {
        continuation?.resume()
        continuation = nil
    }
}

private actor SuspendedAuthSessionStore: SessionSecureStoring {
    private let suspendsSave: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var saveStarted = false
    private(set) var savedSessions: [UUID: AuthSession] = [:]

    init(suspendsSave: Bool) {
        self.suspendsSave = suspendsSave
    }

    func save(_ session: AuthSession, for profileID: UUID) async throws {
        saveStarted = true
        if suspendsSave {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        savedSessions[profileID] = session
    }

    func load(for profileID: UUID) async throws -> AuthSession? {
        savedSessions[profileID]
    }

    func remove(for profileID: UUID) async throws {
        savedSessions.removeValue(forKey: profileID)
    }

    func releaseSave() {
        continuation?.resume()
        continuation = nil
    }
}

final class DsmAuthRepositoryTests: XCTestCase {
    func test登录响应返回前取消不会保存会话() async throws {
        let transport = SuspendedAuthTransport()
        let store = SuspendedAuthSessionStore(suspendsSave: false)
        let context = try makeContext(transport: transport, store: store)

        let task = Task {
            try await context.repository.login(
                profile: context.profile,
                capabilities: context.capabilities,
                account: "account-a",
                password: "password-a",
                otpCode: nil
            )
        }
        try await waitUntil { await transport.requestStarted }
        task.cancel()
        await transport.releaseResponse()

        await assertCancellation(task)
        let saveStarted = await store.saveStarted
        let savedSession = try await store.load(for: context.profile.id)
        XCTAssertFalse(saveStarted)
        XCTAssertNil(savedSession)
    }

    func test保存会话期间取消不会返回成功结果() async throws {
        let transport = MockHTTPTransport(responses: [successfulLoginResponse])
        let store = SuspendedAuthSessionStore(suspendsSave: true)
        let context = try makeContext(transport: transport, store: store)

        let task = Task {
            try await context.repository.login(
                profile: context.profile,
                capabilities: context.capabilities,
                account: "account-a",
                password: "password-a",
                otpCode: nil
            )
        }
        try await waitUntil { await store.saveStarted }
        task.cancel()
        await store.releaseSave()

        await assertCancellation(task)
    }

    private var successfulLoginResponse: DsmHTTPResponse {
        DsmHTTPResponse(
            data: Data(#"{"success":true,"data":{"sid":"test-session"}}"#.utf8),
            statusCode: 200
        )
    }

    private func makeContext(
        transport: any DsmHTTPTransport,
        store: SuspendedAuthSessionStore
    ) throws -> (
        repository: DsmAuthRepository,
        profile: NasProfile,
        capabilities: CapabilitySet
    ) {
        let profile = try NasProfile(
            displayName: "Test NAS",
            host: "nas.test",
            port: 5_001
        )
        let repository = DsmAuthRepository(
            sessionStore: store,
            transportFactory: { _ in transport }
        )
        let capability = ApiCapability(
            name: DsmAPIName.authentication,
            path: "entry.cgi",
            minVersion: 3,
            maxVersion: 7,
            requestFormat: .form,
            selectedVersion: 6
        )
        return (
            repository,
            profile,
            CapabilitySet([DsmAPIName.authentication: capability])
        )
    }

    private func assertCancellation(
        _ task: Task<AuthSession, Error>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await task.value
            XCTFail("预期任务取消", file: file, line: line)
        } catch is CancellationError {
            // 预期结果。
        } catch {
            XCTFail("预期 CancellationError，实际为 \(error)", file: file, line: line)
        }
    }

    private func waitUntil(
        _ condition: @escaping @Sendable () async -> Bool
    ) async throws {
        for _ in 0..<200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("等待异步状态超时")
    }
}
