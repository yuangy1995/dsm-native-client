import Foundation
@testable import DsmNetwork

// 故意保留迟到响应，验证调用方不能依赖传输自动取消来隔离缓存。
actor DiskReadGateTransport: DsmHTTPTransport {
    private var responses: [DsmHTTPResponse]
    private let pausedCall: Int
    private var count = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(responses: [DsmHTTPResponse], pausedCall: Int) {
        self.responses = responses; self.pausedCall = pausedCall
    }
    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        guard !responses.isEmpty else { throw URLError(.badServerResponse) }
        count += 1
        let response = responses.removeFirst()
        if count == pausedCall { await withCheckedContinuation { continuation = $0 } }
        return response
    }
    func isSuspended() -> Bool { continuation != nil }
    func resume() { continuation?.resume(); continuation = nil }
}
