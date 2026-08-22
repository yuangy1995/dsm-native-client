import DsmCore
import Foundation

enum DsmNetworkError: Error, Sendable {
    case invalidRequest(requestID: UUID)
    case httpStatus(code: Int, requestID: UUID)
    case responseTooLarge(requestID: UUID)
    case invalidResponse(requestID: UUID)
    case api(code: Int, requestID: UUID)
    case transport(code: Int, requestID: UUID)
    case cancelled(requestID: UUID)

    var requestID: UUID {
        switch self {
        case .invalidRequest(let requestID),
             .responseTooLarge(let requestID),
             .invalidResponse(let requestID),
             .cancelled(let requestID):
            requestID
        case .httpStatus(_, let requestID),
             .api(_, let requestID),
             .transport(_, let requestID):
            requestID
        }
    }
}

private struct DsmEnvelope<Payload: Decodable & Sendable>: Decodable, Sendable {
    let success: Bool
    let data: Payload?
    let error: DsmErrorPayload?
}

private struct DsmErrorPayload: Decodable, Sendable {
    let code: Int
}

private struct DsmVoidEnvelope: Decodable, Sendable {
    let success: Bool
    let error: DsmErrorPayload?
}

public struct DsmAPIClient: Sendable {
    public let baseURL: URL
    private let transport: any DsmHTTPTransport
    private let maximumJSONResponseBytes: Int

    public init(
        baseURL: URL,
        transport: any DsmHTTPTransport,
        maximumJSONResponseBytes: Int = 8 * 1_024 * 1_024
    ) {
        self.baseURL = baseURL
        self.transport = transport
        self.maximumJSONResponseBytes = maximumJSONResponseBytes
    }

    func call<Payload: Decodable & Sendable>(
        path: String,
        api: String,
        version: Int,
        method: String,
        requestFormat: DsmRequestFormat,
        parameters: [String: DsmParameterValue],
        credential: DsmSessionCredential? = nil,
        as payloadType: Payload.Type
    ) async throws -> Payload {
        let requestID = UUID()
        let request: URLRequest

        do {
            request = try DsmRequestBuilder.build(
                baseURL: baseURL,
                path: path,
                api: api,
                version: version,
                method: method,
                requestFormat: requestFormat,
                parameters: parameters,
                credential: credential
            )
        } catch {
            throw DsmNetworkError.invalidRequest(requestID: requestID)
        }

        let response: DsmHTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw DsmNetworkError.cancelled(requestID: requestID)
        } catch let error as DsmCertificateTrustError {
            throw error
        } catch is DsmTransportError {
            throw DsmNetworkError.responseTooLarge(requestID: requestID)
        } catch let error as URLError {
            throw DsmNetworkError.transport(code: error.errorCode, requestID: requestID)
        } catch let error as DsmNetworkError {
            throw error
        } catch {
            throw DsmNetworkError.transport(
                code: URLError.unknown.rawValue,
                requestID: requestID
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw DsmNetworkError.httpStatus(
                code: response.statusCode,
                requestID: requestID
            )
        }
        guard response.data.count <= maximumJSONResponseBytes else {
            throw DsmNetworkError.responseTooLarge(requestID: requestID)
        }

        let envelope: DsmEnvelope<Payload>
        do {
            envelope = try JSONDecoder().decode(DsmEnvelope<Payload>.self, from: response.data)
        } catch {
            throw DsmNetworkError.invalidResponse(requestID: requestID)
        }

        if let error = envelope.error {
            throw DsmNetworkError.api(code: error.code, requestID: requestID)
        }
        guard envelope.success, let payload = envelope.data else {
            throw DsmNetworkError.invalidResponse(requestID: requestID)
        }
        return payload
    }

    func callVoid(
        path: String,
        api: String,
        version: Int,
        method: String,
        requestFormat: DsmRequestFormat,
        parameters: [String: DsmParameterValue],
        credential: DsmSessionCredential? = nil
    ) async throws {
        let requestID = UUID()
        let request: URLRequest

        do {
            request = try DsmRequestBuilder.build(
                baseURL: baseURL,
                path: path,
                api: api,
                version: version,
                method: method,
                requestFormat: requestFormat,
                parameters: parameters,
                credential: credential
            )
        } catch {
            throw DsmNetworkError.invalidRequest(requestID: requestID)
        }

        let response: DsmHTTPResponse
        do {
            response = try await transport.send(request)
        } catch is CancellationError {
            throw DsmNetworkError.cancelled(requestID: requestID)
        } catch let error as DsmCertificateTrustError {
            throw error
        } catch is DsmTransportError {
            throw DsmNetworkError.responseTooLarge(requestID: requestID)
        } catch let error as URLError {
            throw DsmNetworkError.transport(code: error.errorCode, requestID: requestID)
        } catch {
            throw DsmNetworkError.transport(
                code: URLError.unknown.rawValue,
                requestID: requestID
            )
        }

        guard (200..<300).contains(response.statusCode) else {
            throw DsmNetworkError.httpStatus(code: response.statusCode, requestID: requestID)
        }
        guard response.data.count <= maximumJSONResponseBytes else {
            throw DsmNetworkError.responseTooLarge(requestID: requestID)
        }

        let envelope: DsmVoidEnvelope
        do {
            envelope = try JSONDecoder().decode(DsmVoidEnvelope.self, from: response.data)
        } catch {
            throw DsmNetworkError.invalidResponse(requestID: requestID)
        }
        if let error = envelope.error {
            throw DsmNetworkError.api(code: error.code, requestID: requestID)
        }
        guard envelope.success else {
            throw DsmNetworkError.invalidResponse(requestID: requestID)
        }
    }
}
