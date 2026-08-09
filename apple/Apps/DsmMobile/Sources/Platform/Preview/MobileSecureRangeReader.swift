import CryptoKit
import DsmCore
import Foundation
import Security

struct MobileSecureRangePayload: Sendable {
    let data: Data
    let contentType: String?
    let totalLength: Int64
    let strongETag: String?
}

protocol MobileSecureRangeReading: Sendable {
    func read(
        source: MediaStreamSource,
        offset: Int64,
        maximumLength: Int,
        ifMatch: String?,
        requiresStrongETag: Bool
    ) async throws -> MobileSecureRangePayload
}

struct MobileSecureRangeReader: MobileSecureRangeReading, @unchecked Sendable {
    static let maximumRangeLength = 4 * 1_024 * 1_024

    private let protocolClasses: [AnyClass]?

    init(protocolClasses: [AnyClass]? = nil) {
        self.protocolClasses = protocolClasses
    }

    func read(
        source: MediaStreamSource,
        offset: Int64,
        maximumLength: Int,
        ifMatch: String? = nil,
        requiresStrongETag: Bool = false
    ) async throws -> MobileSecureRangePayload {
        try await MobileSecureRangeTransaction(
            source: source,
            offset: offset,
            maximumLength: maximumLength,
            ifMatch: ifMatch,
            requiresStrongETag: requiresStrongETag,
            protocolClasses: protocolClasses
        ).run()
    }
}

private final class MobileSecureRangeTransaction: NSObject,
    URLSessionDataDelegate,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    private let source: MediaStreamSource
    private let offset: Int64
    private let maximumLength: Int
    private let ifMatch: String?
    private let requiresStrongETag: Bool
    private let protocolClasses: [AnyClass]?
    private let lock = NSLock()
    private var continuation: CheckedContinuation<MobileSecureRangePayload, Error>?
    private var task: URLSessionDataTask?
    private var session: URLSession?
    private var received = Data()
    private var expectedResponseLength: Int?
    private var contentType: String?
    private var totalLength: Int64?
    private var strongETag: String?
    private var completed = false

    init(
        source: MediaStreamSource,
        offset: Int64,
        maximumLength: Int,
        ifMatch: String?,
        requiresStrongETag: Bool,
        protocolClasses: [AnyClass]?
    ) {
        self.source = source
        self.offset = offset
        self.maximumLength = maximumLength
        self.ifMatch = ifMatch
        self.requiresStrongETag = requiresStrongETag
        self.protocolClasses = protocolClasses
    }

    func run() async throws -> MobileSecureRangePayload {
        guard source.request.url?.host?.lowercased() == source.expectedHost.lowercased(),
              let total = source.expectedContentLength,
              total > 0,
              offset >= 0,
              offset < total,
              maximumLength > 0,
              maximumLength <= MobileSecureRangeReader.maximumRangeLength,
              !offset.addingReportingOverflow(Int64(maximumLength) - 1).overflow else {
            throw URLError(.badURL)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let shouldStart = lock.withLock { () -> Bool in
                    guard !completed else { return false }
                    self.continuation = continuation
                    let configuration = URLSessionConfiguration.ephemeral
                    if let protocolClasses { configuration.protocolClasses = protocolClasses }
                    configuration.urlCache = nil
                    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                    configuration.httpShouldSetCookies = false
                    configuration.httpCookieAcceptPolicy = .never
                    configuration.timeoutIntervalForRequest = 30
                    configuration.timeoutIntervalForResource = 60
                    let session = URLSession(
                        configuration: configuration,
                        delegate: self,
                        delegateQueue: nil
                    )
                    self.session = session
                    var request = rangedRequest(url: source.request.url)
                    request.cachePolicy = .reloadIgnoringLocalCacheData
                    let task = session.dataTask(with: request)
                    self.task = task
                    task.resume()
                    return true
                }
                if !shouldStart { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            finish(throwing: CancellationError())
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(throwing: URLError(.badServerResponse))
            return
        }
        let declaredLength = response.value(forHTTPHeaderField: "Content-Length")
            .flatMap(Int64.init)
        guard response.value(forHTTPHeaderField: "Content-Length") == nil || declaredLength != nil,
              response.statusCode == 206,
              let range = Self.parseContentRange(
                response.value(forHTTPHeaderField: "Content-Range")
              ),
              range.start == offset,
              range.end >= range.start,
              range.end - range.start + 1 <= Int64(maximumLength),
              declaredLength == nil || declaredLength == range.end - range.start + 1,
              response.expectedContentLength < 0
                || response.expectedContentLength == range.end - range.start + 1,
              let expectedTotal = source.expectedContentLength,
              expectedTotal >= 0,
              range.total == expectedTotal else {
            completionHandler(.cancel)
            finish(throwing: URLError(.badServerResponse))
            return
        }
        let type = response.value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased()
        guard type?.contains("application/json") != true,
              type?.contains("text/html") != true else {
            completionHandler(.cancel)
            finish(throwing: URLError(.cannotDecodeContentData))
            return
        }
        let responseETag = Self.strongETag(
            response.value(forHTTPHeaderField: "ETag")
        )
        guard (!requiresStrongETag || responseETag != nil),
              ifMatch == nil || responseETag == ifMatch else {
            completionHandler(.cancel)
            finish(throwing: URLError(.resourceUnavailable))
            return
        }
        lock.withLock {
            expectedResponseLength = Int(range.end - range.start + 1)
            contentType = type
            totalLength = range.total
            strongETag = responseETag
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let acceptsData = lock.withLock { () -> Bool in
            guard !completed,
                  let expectedResponseLength,
                  received.count + data.count <= expectedResponseLength,
                  received.count + data.count <= maximumLength else { return false }
            received.append(data)
            return true
        }
        if !acceptsData {
            finish(throwing: URLError(.dataLengthExceedsMaximum))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            if (error as? URLError)?.code == .cancelled, completed { return }
            finish(throwing: error)
            return
        }
        let result = lock.withLock { () -> MobileSecureRangePayload? in
            guard let expectedResponseLength,
                  received.count == expectedResponseLength,
                  let totalLength else { return nil }
            return MobileSecureRangePayload(
                data: received,
                contentType: contentType,
                totalLength: totalLength,
                strongETag: strongETag
            )
        }
        if let result {
            finish(returning: result)
        } else {
            finish(throwing: URLError(.badServerResponse))
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard request.url?.host?.lowercased() == source.expectedHost.lowercased(),
              request.url?.scheme?.lowercased() == source.request.url?.scheme?.lowercased() else {
            completionHandler(nil)
            finish(throwing: URLError(.redirectToNonExistentLocation))
            return
        }
        completionHandler(rangedRequest(url: request.url))
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        handleChallenge(challenge, completionHandler: completionHandler)
    }

    private func handleChallenge(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host.lowercased() == source.expectedHost.lowercased(),
              let serverTrust = challenge.protectionSpace.serverTrust,
              let certificate = (SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate])?.first else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var systemError: CFError?
        let systemTrusted = SecTrustEvaluateWithError(serverTrust, &systemError)
        let fingerprint = SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }.joined()
        let pin = source.pinnedCertificateSHA256?
            .replacingOccurrences(of: ":", with: "").uppercased()
        if systemTrusted, pin == nil || pin == fingerprint {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
            return
        }
        if pin == fingerprint,
           SecTrustSetPolicies(serverTrust, SecPolicyCreateBasicX509()) == errSecSuccess,
           SecTrustSetAnchorCertificates(serverTrust, [certificate] as CFArray) == errSecSuccess,
           SecTrustSetAnchorCertificatesOnly(serverTrust, true) == errSecSuccess {
            var pinnedError: CFError?
            if SecTrustEvaluateWithError(serverTrust, &pinnedError) {
                completionHandler(.useCredential, URLCredential(trust: serverTrust))
                return
            }
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    private func rangedRequest(url: URL?) -> URLRequest {
        var request = source.request
        request.url = url
        request.setValue(
            "bytes=\(offset)-\(offset + Int64(maximumLength) - 1)",
            forHTTPHeaderField: "Range"
        )
        if let ifMatch {
            request.setValue(ifMatch, forHTTPHeaderField: "If-Match")
        }
        return request
    }

    private func finish(returning payload: MobileSecureRangePayload) {
        let continuation = takeContinuation()
        continuation?.resume(returning: payload)
    }

    private func finish(throwing error: Error) {
        let continuation = takeContinuation()
        continuation?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<MobileSecureRangePayload, Error>? {
        let values = lock.withLock { () -> (
            CheckedContinuation<MobileSecureRangePayload, Error>?,
            URLSessionDataTask?,
            URLSession?
        ) in
            guard !completed else { return (nil, nil, nil) }
            completed = true
            let continuation = self.continuation
            self.continuation = nil
            let task = self.task
            self.task = nil
            let session = self.session
            self.session = nil
            return (continuation, task, session)
        }
        values.1?.cancel()
        values.2?.invalidateAndCancel()
        return values.0
    }

    struct ContentRange: Equatable {
        let start: Int64
        let end: Int64
        let total: Int64
    }

    static func parseContentRange(_ value: String?) -> ContentRange? {
        guard let value,
              value.lowercased().hasPrefix("bytes ") else { return nil }
        let parts = value.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let total = Int64(parts[1]),
              total >= 0 else { return nil }
        let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int64(bounds[0]),
              let end = Int64(bounds[1]),
              start >= 0,
              end >= start,
              end < total else { return nil }
        return ContentRange(start: start, end: end, total: total)
    }

    static func strongETag(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.lowercased().hasPrefix("w/"),
              trimmed.count >= 2,
              trimmed.first == "\"",
              trimmed.last == "\"" else { return nil }
        return trimmed
    }
}
