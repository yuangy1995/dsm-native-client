import Foundation

/// 仅保留一次授权所需的服务页面，不含 DSM 地址、会话或云盘凭据。
public struct FileVFSCloudAuthorizationRequest: Identifiable, Sendable {
    public let id: UUID
    public let profileID: UUID
    public let protocolID: String
    public let loginURL: URL
    public let callbackName: String
    public init(id: UUID = UUID(), profileID: UUID, protocolID: String, loginURL: URL, callbackName: String) {
        self.id = id; self.profileID = profileID; self.protocolID = protocolID; self.loginURL = loginURL
        self.callbackName = callbackName
    }
}

public struct FileVFSCloudIdentity: Equatable, Sendable {
    public let protocolID: String
    public let alias: String
    public let account: String
    public init(protocolID: String, alias: String, account: String) {
        self.protocolID = protocolID; self.alias = alias; self.account = account
    }
}

/// 只在授权和提交请求期间使用，不实现 Codable，也不放入待核查记录。
public struct FileVFSCloudAuthorization: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let requestID: UUID
    public let profileID: UUID
    public let protocolID: String
    public let account: String
    public let clientID: String?
    public let accessToken: String
    public let refreshToken: String?
    public let expiresIn: Int?
    public var description: String { "FileVFSCloudAuthorization([redacted])" }
    public var debugDescription: String { description }

    public init(requestID: UUID, profileID: UUID, protocolID: String, account: String, clientID: String?,
                accessToken: String, refreshToken: String?, expiresIn: Int?) {
        self.requestID = requestID; self.profileID = profileID; self.protocolID = protocolID; self.account = account
        self.clientID = clientID; self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresIn = expiresIn
    }

    /// 本机回调先核对一次性路径与主机；这里再核对回调名称及字段类型，忽略其他字段。
    public static func decode(_ data: Data, for request: FileVFSCloudAuthorizationRequest) throws -> Self {
        struct Payload: Decodable {
            let callback: String
            let account: String
            let client_id: String?
            let access_token: String
            let refresh_token: String?
            let expires_in: Int?
        }
        let value = try JSONDecoder().decode(Payload.self, from: data)
        guard value.callback == request.callbackName, !value.access_token.isEmpty, !value.account.isEmpty,
              value.expires_in.map({ $0 >= 0 }) ?? true else { throw CocoaError(.coderReadCorrupt) }
        return .init(requestID: request.id, profileID: request.profileID, protocolID: request.protocolID,
            account: value.account, clientID: value.client_id, accessToken: value.access_token,
            refreshToken: value.refresh_token, expiresIn: value.expires_in)
    }
}
