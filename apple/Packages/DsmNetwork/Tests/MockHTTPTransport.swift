import DsmCore
import Foundation
@testable import DsmNetwork

actor MockHTTPTransport: DsmBinaryHTTPTransport {
    enum Step: Sendable {
        case response(DsmHTTPResponse)
        case urlError(URLError.Code)
        case responseTooLarge
        case waitUntilCancelled
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []
    private var requestCancellationStates: [Bool] = []
    private var uploadBodies: [Data] = []
    private var cancellationWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingCancelledWaiterIDs: Set<UUID> = []

    init(responses: [DsmHTTPResponse]) {
        steps = responses.map(Step.response)
    }

    init(steps: [Step]) {
        self.steps = steps
    }

    func send(_ request: URLRequest) async throws -> DsmHTTPResponse {
        requests.append(request)
        requestCancellationStates.append(Task.isCancelled)
        guard !steps.isEmpty else {
            throw URLError(.badServerResponse)
        }
        switch steps.removeFirst() {
        case .response(let response):
            return response
        case .urlError(let code):
            throw URLError(code)
        case .responseTooLarge:
            throw DsmTransportError.responseTooLarge
        case .waitUntilCancelled:
            try await waitUntilCancelled()
            throw CancellationError()
        }
    }

    func recordedRequests() -> [URLRequest] {
        requests
    }

    func recordedRequestCancellationStates() -> [Bool] {
        requestCancellationStates
    }

    func recordedUploadBodies() -> [Data] {
        uploadBodies
    }

    // 不能以 UInt64.max 休眠模拟无限等待：旧 Swift 运行时可能提前结束，破坏取消测试的同步屏障。
    private func waitUntilCancelled() async throws {
        let waiterID = UUID()
        try await withTaskCancellationHandler(
            operation: {
                try await self.suspendUntilCancelled(waiterID)
            },
            onCancel: {
                Task {
                    await self.cancelWaiter(waiterID)
                }
            }
        )
    }

    private func suspendUntilCancelled(_ waiterID: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if pendingCancelledWaiterIDs.remove(waiterID) != nil {
                continuation.resume(throwing: CancellationError())
            } else {
                cancellationWaiters[waiterID] = continuation
            }
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        if let continuation = cancellationWaiters.removeValue(forKey: waiterID) {
            continuation.resume(throwing: CancellationError())
        } else {
            pendingCancelledWaiterIDs.insert(waiterID)
        }
    }

    func download(
        _ request: URLRequest,
        to destinationURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws -> DsmHTTPResponse {
        let response = try await send(request)
        progress(0, Int64(response.data.count))
        try response.data.write(to: destinationURL)
        progress(Int64(response.data.count), Int64(response.data.count))
        return response
    }

    func upload(
        _ request: URLRequest,
        from bodyFileURL: URL,
        progress: @escaping FileTransferProgress
    ) async throws -> DsmHTTPResponse {
        let size = Int64((try? bodyFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if let body = try? Data(contentsOf: bodyFileURL) {
            uploadBodies.append(body)
        }
        progress(0, size)
        let response = try await send(request)
        progress(size, size)
        return response
    }
}
