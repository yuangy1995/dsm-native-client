import CryptoKit
import DsmCore
import Foundation
import Security
import DsmLocalization

public struct DsmCertificateReview: Equatable, Sendable {
    public let host: String
    public let subjectSummary: String
    public let sha256Fingerprint: String
    public let canBePinned: Bool

    public init(
        host: String,
        subjectSummary: String,
        sha256Fingerprint: String,
        canBePinned: Bool
    ) {
        self.host = host
        self.subjectSummary = subjectSummary
        self.sha256Fingerprint = sha256Fingerprint
        self.canBePinned = canBePinned
    }

    public var formattedFingerprint: String {
        stride(from: 0, to: sha256Fingerprint.count, by: 2).map { offset in
            let start = sha256Fingerprint.index(sha256Fingerprint.startIndex, offsetBy: offset)
            let end = sha256Fingerprint.index(start, offsetBy: min(2, sha256Fingerprint.distance(from: start, to: sha256Fingerprint.endIndex)))
            return String(sha256Fingerprint[start..<end])
        }.joined(separator: ":")
    }
}

public enum DsmCertificateTrustError: Error, Sendable {
    case untrusted(DsmCertificateReview)
    case changed(DsmCertificateReview)
    case invalid(DsmCertificateReview)

    public var review: DsmCertificateReview {
        switch self {
        case .untrusted(let review), .changed(let review), .invalid(let review):
            review
        }
    }
}

extension DsmCertificateTrustError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .untrusted:
            L10n.string("shared.747b72d0d6fc61f9")
        case .changed:
            L10n.string("shared.fef968eaed0aa357")
        case .invalid:
            L10n.string("shared.3cc5b95fb6003934")
        }
    }
}

enum DsmCertificateTrustDecision: Equatable {
    case useSystemTrust
    case usePinnedCertificate
    case reviewUntrustedCertificate
    case reviewChangedCertificate
    case rejectInvalidCertificate
}

enum DsmCertificateTrustPolicy {
    static func decide(
        systemTrusted: Bool,
        pinnedFingerprint: String?,
        presentedFingerprint: String,
        canBePinned: Bool
    ) -> DsmCertificateTrustDecision {
        if let pinnedFingerprint, pinnedFingerprint != presentedFingerprint {
            return .reviewChangedCertificate
        }
        if systemTrusted {
            return .useSystemTrust
        }
        if pinnedFingerprint == presentedFingerprint, canBePinned {
            return .usePinnedCertificate
        }
        return canBePinned ? .reviewUntrustedCertificate : .rejectInvalidCertificate
    }
}

/// TLS 失败必须以 URLSession task 为边界保存，避免并发请求互相消费证书提示。
final class TaskScopedTLSFailureStore: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [Int: DsmCertificateTrustError] = [:]

    func store(_ failure: DsmCertificateTrustError, taskIdentifier: Int) {
        lock.lock()
        failures[taskIdentifier] = failure
        lock.unlock()
    }

    func consume(taskIdentifier: Int) -> DsmCertificateTrustError? {
        lock.lock()
        defer { lock.unlock() }
        return failures.removeValue(forKey: taskIdentifier)
    }

    func remove(taskIdentifier: Int) {
        lock.lock()
        failures.removeValue(forKey: taskIdentifier)
        lock.unlock()
    }
}

/// session 级挑战没有 URLSessionTask。以同一 session 内的 HTTPS origin 和单调
/// generation 关联当时已注册的任务，既不把失败留给之后才开始的请求，也不让一个
/// 已取消任务抢走另一个并发请求的结构化证书错误。
struct SessionTLSFailureScope: Hashable {
    let host: String
    let port: Int

    init?(
        host: String?,
        port: Int,
        scheme: String?,
        expectedHost: String?
    ) {
        // 挑战归属必须以实际 HTTPS origin 为准；只有任务 URL 不可用时才以
        // 配置主机名作为兜底，避免重定向场景把不同 host 错误归入同一失败范围。
        let resolvedHost = (host ?? expectedHost ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !resolvedHost.isEmpty else { return nil }
        self.host = resolvedHost
        if port > 0 {
            self.port = port
        } else if scheme?.lowercased() == "http" {
            self.port = 80
        } else {
            self.port = 443
        }
    }
}

/// 保证 session 级服务器信任挑战只被挑战发生时同一 host:port 上仍存活的任务消费。
final class SessionScopedTLSFailureStore: @unchecked Sendable {
    private struct TaskRegistration {
        let scope: SessionTLSFailureScope
        let generationAtRegistration: Int
    }

    private struct PendingFailure {
        let generation: Int
        let failure: DsmCertificateTrustError
        var eligibleTaskIdentifiers: Set<Int>
    }

    private let lock = NSLock()
    private var taskRegistrations: [Int: TaskRegistration] = [:]
    private var latestGenerations: [SessionTLSFailureScope: Int] = [:]
    private var pendingFailures: [SessionTLSFailureScope: [PendingFailure]] = [:]

    func register(taskIdentifier: Int, scope: SessionTLSFailureScope?) {
        lock.lock()
        defer { lock.unlock() }
        guard let scope else {
            taskRegistrations[taskIdentifier] = nil
            return
        }
        taskRegistrations[taskIdentifier] = TaskRegistration(
            scope: scope,
            generationAtRegistration: latestGenerations[scope] ?? 0
        )
    }

    func store(
        _ failure: DsmCertificateTrustError,
        scope: SessionTLSFailureScope
    ) {
        lock.lock()
        defer { lock.unlock() }
        let previousGeneration = latestGenerations[scope] ?? 0
        let next = previousGeneration.addingReportingOverflow(1)
        // generation 溢出时不复用旧数字；当前 session 中的旧 pending 也失去意义。
        let generation = next.overflow ? 1 : next.partialValue
        if next.overflow {
            pendingFailures[scope] = []
        }
        latestGenerations[scope] = generation
        let eligible = Set(taskRegistrations.compactMap { identifier, registration in
            registration.scope == scope
                && registration.generationAtRegistration < generation
                ? identifier
                : nil
        })
        guard !eligible.isEmpty else { return }
        pendingFailures[scope, default: []].append(
            PendingFailure(
                generation: generation,
                failure: failure,
                eligibleTaskIdentifiers: eligible
            )
        )
    }

    func consume(taskIdentifier: Int) -> DsmCertificateTrustError? {
        lock.lock()
        defer { lock.unlock() }
        guard let registration = taskRegistrations[taskIdentifier],
              var failures = pendingFailures[registration.scope],
              let index = failures.firstIndex(where: {
                  $0.generation > registration.generationAtRegistration
                      && $0.eligibleTaskIdentifiers.contains(taskIdentifier)
              }) else {
            return nil
        }
        let failure = failures[index].failure
        failures[index].eligibleTaskIdentifiers.remove(taskIdentifier)
        failures.removeAll { $0.eligibleTaskIdentifiers.isEmpty }
        if failures.isEmpty {
            pendingFailures[registration.scope] = nil
        } else {
            pendingFailures[registration.scope] = failures
        }
        return failure
    }

    func remove(taskIdentifier: Int) {
        lock.lock()
        defer { lock.unlock() }
        taskRegistrations[taskIdentifier] = nil
        for scope in Array(pendingFailures.keys) {
            guard var failures = pendingFailures[scope] else { continue }
            for index in failures.indices {
                failures[index].eligibleTaskIdentifiers.remove(taskIdentifier)
            }
            failures.removeAll { $0.eligibleTaskIdentifiers.isEmpty }
            pendingFailures[scope] = failures.isEmpty ? nil : failures
        }
    }
}

final class DsmTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedHost: String?
    private let pinnedFingerprint: String?
    private let requiresSystemTrust: Bool
    private let lock = NSLock()
    private let taskFailures = TaskScopedTLSFailureStore()
    private let sessionFailures = SessionScopedTLSFailureStore()

    private var progressHandlers = [Int: FileTransferProgress]()
    private var completionHandlers = [Int: (HTTPURLResponse?, Error?) -> Void]()
    private var downloadFinishHandlers = [Int: (URL) -> Void]()
    private var responseHandlers = [Int: (URLResponse) -> URLSession.ResponseDisposition]()
    private var dataHandlers = [Int: (Data) -> Bool]()
    private var lastProgressUpdateTimes = [Int: Date]()
    private var cancelledTaskIdentifiers = Set<Int>()

    init(
        expectedHost: String?,
        pinnedFingerprint: String?,
        requiresSystemTrust: Bool = false
    ) {
        self.expectedHost = expectedHost
        self.pinnedFingerprint = pinnedFingerprint?
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        self.requiresSystemTrust = requiresSystemTrust
    }

    func consumeFailure(for task: URLSessionTask) -> DsmCertificateTrustError? {
        let identifier = task.taskIdentifier
        return taskFailures.consume(taskIdentifier: identifier)
            ?? sessionFailures.consume(taskIdentifier: identifier)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(
            challenge,
            taskIdentifier: nil,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(
            challenge,
            taskIdentifier: task.taskIdentifier,
            completionHandler: completionHandler
        )
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(
            DsmRedirectPolicy.redirectedRequest(
                from: task.currentRequest?.url ?? task.originalRequest?.url,
                proposedRequest: request
            )
        )
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        taskIdentifier: Int?,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust,
              let certificate = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = certificate.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = expectedHost ?? challenge.protectionSpace.host
        let failureScope = SessionTLSFailureScope(
            host: challenge.protectionSpace.host,
            port: challenge.protectionSpace.port,
            scheme: challenge.protectionSpace.protocol,
            expectedHost: expectedHost
        )
        let data = SecCertificateCopyData(leaf) as Data
        let fingerprint = SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined()
        let subject = SecCertificateCopySubjectSummary(leaf) as String? ?? L10n.string("shared.3436b7107f7e8dc4")

        var systemError: CFError?
        let systemTrusted = SecTrustEvaluateWithError(trust, &systemError)

        if systemTrusted,
           pinnedFingerprint == nil || pinnedFingerprint == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        if requiresSystemTrust {
            let review = DsmCertificateReview(
                host: host,
                subjectSummary: subject,
                sha256Fingerprint: fingerprint,
                canBePinned: false
            )
            store(
                .invalid(review),
                taskIdentifier: taskIdentifier,
                sessionScope: failureScope
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // 用户核对指纹后的信任与具体 NAS 配置绑定，因此这里只校验证书本身和有效期，
        // 不再要求本地访问地址必须与证书名称一致。家庭 NAS 常使用 IP、短主机名或 .local 地址。
        let policyStatus = SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
        let anchorStatus = SecTrustSetAnchorCertificates(trust, [leaf] as CFArray)
        let anchorsOnlyStatus = SecTrustSetAnchorCertificatesOnly(trust, true)
        var pinnedError: CFError?
        let canBePinned = policyStatus == errSecSuccess
            && anchorStatus == errSecSuccess
            && anchorsOnlyStatus == errSecSuccess
            && SecTrustEvaluateWithError(trust, &pinnedError)

        let review = DsmCertificateReview(
            host: host,
            subjectSummary: subject,
            sha256Fingerprint: fingerprint,
            canBePinned: canBePinned
        )

        switch DsmCertificateTrustPolicy.decide(
            systemTrusted: systemTrusted,
            pinnedFingerprint: pinnedFingerprint,
            presentedFingerprint: fingerprint,
            canBePinned: canBePinned
        ) {
        case .useSystemTrust, .usePinnedCertificate:
            completionHandler(.useCredential, URLCredential(trust: trust))
        case .reviewUntrustedCertificate:
            store(
                .untrusted(review),
                taskIdentifier: taskIdentifier,
                sessionScope: failureScope
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .reviewChangedCertificate:
            store(
                .changed(review),
                taskIdentifier: taskIdentifier,
                sessionScope: failureScope
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .rejectInvalidCertificate:
            store(
                .invalid(review),
                taskIdentifier: taskIdentifier,
                sessionScope: failureScope
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func store(
        _ failure: DsmCertificateTrustError,
        taskIdentifier: Int?,
        sessionScope: SessionTLSFailureScope?
    ) {
        if let taskIdentifier {
            lock.lock()
            let isCancelled = cancelledTaskIdentifiers.contains(taskIdentifier)
            lock.unlock()
            guard !isCancelled else { return }
            taskFailures.store(failure, taskIdentifier: taskIdentifier)
            // `markTaskCancelled` 与挑战回调可能交错。再次确认后移除刚写入的
            // 条目，保证已取消任务不会在完成回调中优先得到 TLS 错误。
            lock.lock()
            let wasCancelled = cancelledTaskIdentifiers.contains(taskIdentifier)
            lock.unlock()
            if wasCancelled {
                taskFailures.remove(taskIdentifier: taskIdentifier)
            }
        } else if let sessionScope {
            sessionFailures.store(failure, scope: sessionScope)
        }
    }

    /// WebSocket 没有普通 data/download completion handler，也必须显式登记，
    /// 才能在 session 级信任挑战中获得同一连接的结构化错误。
    func registerTaskForTrustFailures(_ task: URLSessionTask) {
        let scope = Self.failureScope(
            for: task,
            expectedHost: expectedHost
        )
        sessionFailures.register(
            taskIdentifier: task.taskIdentifier,
            scope: scope
        )
        lock.lock()
        cancelledTaskIdentifiers.remove(task.taskIdentifier)
        lock.unlock()
    }

    func registerTask(
        _ task: URLSessionTask,
        progress: @escaping FileTransferProgress,
        completion: @escaping (HTTPURLResponse?, Error?) -> Void,
        onDownloadFinish: ((URL) -> Void)? = nil,
        onResponse: ((URLResponse) -> URLSession.ResponseDisposition)? = nil,
        onDataReceive: ((Data) -> Bool)? = nil
    ) {
        registerTaskForTrustFailures(task)
        lock.lock()
        let id = task.taskIdentifier
        progressHandlers[id] = progress
        completionHandlers[id] = completion
        if let onDownloadFinish = onDownloadFinish {
            downloadFinishHandlers[id] = onDownloadFinish
        }
        if let onResponse = onResponse {
            responseHandlers[id] = onResponse
        }
        if let onDataReceive = onDataReceive {
            dataHandlers[id] = onDataReceive
        }
        lock.unlock()
    }

    /// 取消请求不应再有资格消费 session 级失败；保留 completion handler 直到
    /// URLSession 回调结束，保证外层 continuation 仍会以取消结果收束。
    func markTaskCancelled(_ task: URLSessionTask) {
        let identifier = task.taskIdentifier
        lock.lock()
        cancelledTaskIdentifiers.insert(identifier)
        lock.unlock()
        taskFailures.remove(taskIdentifier: identifier)
        sessionFailures.remove(taskIdentifier: identifier)
    }

    func unregisterTask(_ task: URLSessionTask) {
        lock.lock()
        let id = task.taskIdentifier
        progressHandlers.removeValue(forKey: id)
        completionHandlers.removeValue(forKey: id)
        downloadFinishHandlers.removeValue(forKey: id)
        responseHandlers.removeValue(forKey: id)
        dataHandlers.removeValue(forKey: id)
        lastProgressUpdateTimes.removeValue(forKey: id)
        cancelledTaskIdentifiers.remove(id)
        lock.unlock()
        taskFailures.remove(taskIdentifier: id)
        sessionFailures.remove(taskIdentifier: id)
    }

    private static func failureScope(
        for task: URLSessionTask,
        expectedHost: String?
    ) -> SessionTLSFailureScope? {
        let url = task.currentRequest?.url ?? task.originalRequest?.url
        return SessionTLSFailureScope(
            host: url?.host,
            port: url?.port ?? 0,
            scheme: url?.scheme,
            expectedHost: expectedHost
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let id = downloadTask.taskIdentifier
        let now = Date()
        lock.lock()
        let lastTime = lastProgressUpdateTimes[id]
        let handler = progressHandlers[id]
        lock.unlock()

        let isComplete = totalBytesExpectedToWrite > 0 && totalBytesWritten >= totalBytesExpectedToWrite
        let timePassed = lastTime == nil || now.timeIntervalSince(lastTime!) >= 0.8

        if isComplete || timePassed {
            lock.lock()
            lastProgressUpdateTimes[id] = now
            lock.unlock()
            handler?(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let finishHandler = downloadFinishHandlers[downloadTask.taskIdentifier]
        lock.unlock()
        finishHandler?(location)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let id = task.taskIdentifier
        let now = Date()
        lock.lock()
        let lastTime = lastProgressUpdateTimes[id]
        let handler = progressHandlers[id]
        lock.unlock()

        let isComplete = totalBytesExpectedToSend > 0 && totalBytesSent >= totalBytesExpectedToSend
        let timePassed = lastTime == nil || now.timeIntervalSince(lastTime!) >= 0.8

        if isComplete || timePassed {
            lock.lock()
            lastProgressUpdateTimes[id] = now
            lock.unlock()
            handler?(totalBytesSent, totalBytesExpectedToSend > 0 ? totalBytesExpectedToSend : nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        let handler = responseHandlers[dataTask.taskIdentifier]
        lock.unlock()
        completionHandler(handler?(response) ?? .allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        let handler = dataHandlers[dataTask.taskIdentifier]
        lock.unlock()
        if handler?(data) == false {
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let completion = completionHandlers[task.taskIdentifier]
        lock.unlock()
        let httpResponse = task.response as? HTTPURLResponse
        completion?(httpResponse, error)
    }
}
