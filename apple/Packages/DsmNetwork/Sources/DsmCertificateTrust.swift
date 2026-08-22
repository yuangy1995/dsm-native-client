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

final class DsmTLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, URLSessionDownloadDelegate, URLSessionDataDelegate, @unchecked Sendable {
    private let expectedHost: String?
    private let pinnedFingerprint: String?
    private let requiresSystemTrust: Bool
    private let lock = NSLock()
    private let failures = TaskScopedTLSFailureStore()

    private var progressHandlers = [Int: FileTransferProgress]()
    private var completionHandlers = [Int: (HTTPURLResponse?, Error?) -> Void]()
    private var downloadFinishHandlers = [Int: (URL) -> Void]()
    private var responseHandlers = [Int: (URLResponse) -> URLSession.ResponseDisposition]()
    private var dataHandlers = [Int: (Data) -> Bool]()
    private var lastProgressUpdateTimes = [Int: Date]()

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
        failures.consume(taskIdentifier: task.taskIdentifier)
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
            store(.invalid(review), taskIdentifier: taskIdentifier)
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
            store(.untrusted(review), taskIdentifier: taskIdentifier)
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .reviewChangedCertificate:
            store(.changed(review), taskIdentifier: taskIdentifier)
            completionHandler(.cancelAuthenticationChallenge, nil)
        case .rejectInvalidCertificate:
            store(.invalid(review), taskIdentifier: taskIdentifier)
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    private func store(
        _ failure: DsmCertificateTrustError,
        taskIdentifier: Int?
    ) {
        guard let taskIdentifier else { return }
        failures.store(failure, taskIdentifier: taskIdentifier)
    }

    func registerTask(
        _ task: URLSessionTask,
        progress: @escaping FileTransferProgress,
        completion: @escaping (HTTPURLResponse?, Error?) -> Void,
        onDownloadFinish: ((URL) -> Void)? = nil,
        onResponse: ((URLResponse) -> URLSession.ResponseDisposition)? = nil,
        onDataReceive: ((Data) -> Bool)? = nil
    ) {
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

    func unregisterTask(_ task: URLSessionTask) {
        lock.lock()
        let id = task.taskIdentifier
        progressHandlers.removeValue(forKey: id)
        completionHandlers.removeValue(forKey: id)
        downloadFinishHandlers.removeValue(forKey: id)
        responseHandlers.removeValue(forKey: id)
        dataHandlers.removeValue(forKey: id)
        lastProgressUpdateTimes.removeValue(forKey: id)
        failures.remove(taskIdentifier: id)
        lock.unlock()
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
