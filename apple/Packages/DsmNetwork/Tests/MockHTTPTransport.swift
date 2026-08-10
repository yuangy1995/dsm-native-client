import DsmCore
import Foundation
@testable import DsmNetwork

actor MockHTTPTransport: DsmBinaryHTTPTransport {
    enum Step: Sendable {
        case response(DsmHTTPResponse)
        case urlError(URLError.Code)
        case waitUntilCancelled
    }

    private var steps: [Step]
    private var requests: [URLRequest] = []
    private var requestCancellationStates: [Bool] = []
    private var uploadBodies: [Data] = []

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
        case .waitUntilCancelled:
            try await Task.sleep(nanoseconds: UInt64.max)
            throw URLError(.cancelled)
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
