import DsmCore
import Foundation

enum DsmTransportError: Error, Equatable, Sendable {
    case responseTooLarge
}

/// 集中处理可能被记录到诊断中的会话字段，避免各调用点各自遗漏。
enum DsmSensitiveRequestRedactor {
    private static let sensitiveQueryNames: Set<String> = [
        "_sid", "sid", "synotoken", "syno_token", "token", "cookie", "did",
    ]
    private static let sensitiveHeaderNames: Set<String> = [
        "authorization", "cookie", "x-syno-token", "set-cookie",
    ]

    static func redactedURL(_ url: URL) -> URL {
        guard var components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ) else {
            return url
        }
        components.queryItems = components.queryItems?.filter {
            !sensitiveQueryNames.contains($0.name.lowercased())
        }
        return components.url ?? url
    }

    private static func redactedURLString(_ value: String) -> String {
        guard var components = URLComponents(string: value) else {
            return value
        }
        components.queryItems = components.queryItems?.filter {
            !sensitiveQueryNames.contains($0.name.lowercased())
        }
        return components.string ?? value
    }

    static func redactedHeaders(
        _ headers: [String: String]
    ) -> [String: String] {
        headers.reduce(into: [:]) { result, entry in
            let name = entry.key.lowercased()
            if sensitiveHeaderNames.contains(name) {
                result[entry.key] = "<redacted>"
            } else if name == "location" {
                // 重定向目标也可能携带旧式查询认证，诊断对象不能保留它。
                result[entry.key] = redactedURLString(entry.value)
            } else {
                result[entry.key] = entry.value
            }
        }
    }
}

/// 重定向只允许在同一 HTTPS origin 内进行；跨源时直接取消，避免认证 Header 被转发。
enum DsmRedirectPolicy {
    static func redirectedRequest(
        from sourceURL: URL?,
        proposedRequest: URLRequest
    ) -> URLRequest? {
        guard let sourceURL,
              let destinationURL = proposedRequest.url,
              isSameHTTPSOrigin(sourceURL, destinationURL) else {
            return nil
        }
        var request = proposedRequest
        request.url = DsmSensitiveRequestRedactor.redactedURL(destinationURL)
        return request
    }

    private static func isSameHTTPSOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == "https"
            && rhs.scheme?.lowercased() == "https"
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : nil)
    }
}

final class BoundedResponseDataBox: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumBytes: Int
    private var data = Data()
    private var exceededLimit = false

    init(maximumBytes: Int) {
        self.maximumBytes = max(maximumBytes, 1)
    }

    func accept(_ response: URLResponse) -> URLSession.ResponseDisposition {
        guard response.expectedContentLength > Int64(maximumBytes) else {
            return .allow
        }
        lock.lock()
        exceededLimit = true
        lock.unlock()
        return .cancel
    }

    func append(_ chunk: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else { return false }
        let nextCount = data.count.addingReportingOverflow(chunk.count)
        guard !nextCount.overflow, nextCount.partialValue <= maximumBytes else {
            exceededLimit = true
            return false
        }
        data.append(chunk)
        return true
    }

    func value() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !exceededLimit else {
            throw DsmTransportError.responseTooLarge
        }
        return data
    }
}

private final class DownloadLocationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<URL, Error>?

    func store(_ url: URL) {
        lock.lock()
        result = .success(url)
        lock.unlock()
    }

    func fail(_ error: Error) {
        lock.lock()
        result = .failure(error)
        lock.unlock()
    }

    func consume() -> Result<URL, Error>? {
        lock.lock()
        defer { lock.unlock() }
        defer { result = nil }
        return result
    }
}

public struct DsmHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol DsmHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse
}

public protocol DsmBinaryHTTPTransport: DsmHTTPTransport {
    func download(
        _ request: URLRequest,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws -> DsmHTTPResponse

    func upload(
        _ request: URLRequest,
        from bodyFileURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws -> DsmHTTPResponse
}

public final class URLSessionTransport: DsmBinaryHTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let tlsDelegate: DsmTLSDelegate
    private let maximumResponseBytes: Int

    public init(
        configuration: URLSessionConfiguration = .ephemeral,
        expectedHost: String? = nil,
        pinnedCertificateSHA256: String? = nil,
        requiresSystemCertificateTrust: Bool = false,
        maximumResponseBytes: Int = 8 * 1_024 * 1_024
    ) {
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.maximumResponseBytes = max(maximumResponseBytes, 1)
        tlsDelegate = DsmTLSDelegate(
            expectedHost: expectedHost,
            pinnedFingerprint: pinnedCertificateSHA256,
            requiresSystemTrust: requiresSystemCertificateTrust
        )
        session = URLSession(
            configuration: configuration,
            delegate: tlsDelegate,
            delegateQueue: nil
        )
    }

    public func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        let task = session.dataTask(with: request)
        return try await executeDataTask(
            task,
            progress: { _, _ in }
        )
    }

    public func download(
        _ request: URLRequest,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws -> DsmHTTPResponse {
        let task = session.downloadTask(with: request)
        let downloadedFile = DownloadLocationBox()
        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(destinationURL.lastPathComponent).\(UUID().uuidString).lanstash.download"
            )

        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    tlsDelegate.registerTask(
                        task,
                        progress: progress,
                        completion: { httpResponse, error in
                            let trustError = self.tlsDelegate.consumeFailure(for: task)
                            self.tlsDelegate.unregisterTask(task)
                            if let trustError {
                                continuation.resume(throwing: trustError)
                                return
                            }
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            guard let httpResponse else {
                                continuation.resume(throwing: URLError(.badServerResponse))
                                return
                            }
                            guard let result = downloadedFile.consume() else {
                                continuation.resume(throwing: URLError(.badServerResponse))
                                return
                            }
                            switch result {
                            case .failure(let error):
                                continuation.resume(throwing: error)
                            case .success(let sourceURL):
                                do {
                                    try AtomicFilePromotion.promote(
                                        from: sourceURL,
                                        to: destinationURL
                                    )
                                    let size = try destinationURL.resourceValues(
                                        forKeys: [.fileSizeKey]
                                    ).fileSize
                                    let expected = httpResponse.expectedContentLength > 0
                                        ? httpResponse.expectedContentLength
                                        : size.map(Int64.init)
                                    progress(Int64(size ?? 0), expected)
                                    continuation.resume(returning: DsmHTTPResponse(
                                        data: Data(),
                                        statusCode: httpResponse.statusCode,
                                        headers: Self.headers(from: httpResponse)
                                    ))
                                } catch {
                                    continuation.resume(throwing: error)
                                }
                            }
                        },
                        onDownloadFinish: { location in
                            do {
                                try FileManager.default.createDirectory(
                                    at: destinationURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true
                                )
                                try FileManager.default.moveItem(
                                    at: location,
                                    to: stagingURL
                                )
                                downloadedFile.store(stagingURL)
                            } catch {
                                try? FileManager.default.removeItem(at: stagingURL)
                                downloadedFile.fail(error)
                            }
                        }
                    )
                    task.resume()
                }
            } onCancel: {
                self.tlsDelegate.markTaskCancelled(task)
                task.cancel()
            }
        } catch {
            if case .success(let url)? = downloadedFile.consume() {
                try? FileManager.default.removeItem(at: url)
            }
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
    }

    public func upload(
        _ request: URLRequest,
        from bodyFileURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws -> DsmHTTPResponse {
        let task = session.uploadTask(with: request, fromFile: bodyFileURL)
        let size = try? bodyFileURL.resourceValues(
            forKeys: [.fileSizeKey]
        ).fileSize
        progress(0, size.map(Int64.init))
        let response = try await executeDataTask(task, progress: progress)
        progress(Int64(size ?? 0), size.map(Int64.init))
        return response
    }

    private func executeDataTask(
        _ task: URLSessionDataTask,
        progress: @escaping FileTransferProgress
    ) async throws -> DsmHTTPResponse {
        let responseData = BoundedResponseDataBox(
            maximumBytes: maximumResponseBytes
        )
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                tlsDelegate.registerTask(
                    task,
                    progress: progress,
                    completion: { httpResponse, error in
                        let trustError = self.tlsDelegate.consumeFailure(for: task)
                        self.tlsDelegate.unregisterTask(task)
                        if let trustError {
                            continuation.resume(throwing: trustError)
                            return
                        }
                        do {
                            let data = try responseData.value()
                            if let error {
                                continuation.resume(throwing: error)
                                return
                            }
                            guard let httpResponse else {
                                continuation.resume(
                                    throwing: URLError(.badServerResponse)
                                )
                                return
                            }
                            continuation.resume(returning: DsmHTTPResponse(
                                data: data,
                                statusCode: httpResponse.statusCode,
                                headers: Self.headers(from: httpResponse)
                            ))
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    },
                    onResponse: { responseData.accept($0) },
                    onDataReceive: { responseData.append($0) }
                )
                task.resume()
            }
        } onCancel: {
            tlsDelegate.markTaskCancelled(task)
            task.cancel()
        }
    }

    private static func headers(from response: HTTPURLResponse) -> [String: String] {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { headers, field in
            let (key, value) = field
            guard let key = key as? String else {
                return
            }
            // HTTP 字段名不区分大小写，统一后若重复则以 URLSession 的最后值为准。
            headers[key.lowercased()] = String(describing: value)
        }
        return DsmSensitiveRequestRedactor.redactedHeaders(headers)
    }
}
