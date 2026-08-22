import DsmCore
import Foundation
import DsmLocalization

public enum DsmParameterValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case stringArray([String])
    case integerArray([Int])
    case object([String: DsmJSONValue])
    case objectArray([[String: DsmJSONValue]])

    fileprivate func encoded(for requestFormat: DsmRequestFormat) throws -> String {
        switch (requestFormat, self) {
        case (.form, .string(let value)):
            return value
        case (.form, .integer(let value)):
            return String(value)
        case (.form, .boolean(let value)):
            return value ? "true" : "false"
        case (.form, .stringArray(let value)):
            return try Self.jsonString(value)
        case (.form, .integerArray(let value)):
            return try Self.jsonString(value)
        case (.form, .object(let value)):
            return try Self.jsonString(value)
        case (.form, .objectArray(let value)):
            return try Self.jsonString(value)
        case (.json, .string(let value)):
            return try Self.jsonString(value)
        case (.json, .integer(let value)):
            return try Self.jsonString(value)
        case (.json, .boolean(let value)):
            return try Self.jsonString(value)
        case (.json, .stringArray(let value)):
            return try Self.jsonString(value)
        case (.json, .integerArray(let value)):
            return try Self.jsonString(value)
        case (.json, .object(let value)):
            return try Self.jsonString(value)
        case (.json, .objectArray(let value)):
            return try Self.jsonString(value)
        }
    }

    private static func jsonString<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let result = String(data: data, encoding: .utf8) else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: [],
                    debugDescription: L10n.string("shared.b30fd06e3632c63a")
                )
            )
        }
        return result
    }
}

public indirect enum DsmJSONValue: Equatable, Sendable, Encodable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case array([DsmJSONValue])
    case object([String: DsmJSONValue])

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .integer(let value):
            try container.encode(value)
        case .boolean(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

public struct DsmSessionCredential: Equatable, Sendable {
    public let sid: String
    public let synoToken: String?

    public init(sid: String, synoToken: String?) {
        self.sid = sid
        self.synoToken = synoToken
    }

    var cookieHeaderValue: String? {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
        )
        guard !sid.isEmpty,
              sid.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }
        return "id=\(sid)"
    }
}

enum DsmRequestError: Error, Sendable {
    case insecureBaseURL
    case invalidAPIPath
    case parameterEncodingFailed
}

enum FormURLEncoder {
    private static let allowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"
    )

    static func encode(_ fields: [String: String]) throws -> Data {
        let body = try fields
            .sorted { $0.key < $1.key }
            .map { key, value in
                guard let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowedCharacters),
                      let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowedCharacters) else {
                    throw DsmRequestError.parameterEncodingFailed
                }
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")

        guard let data = body.data(using: .utf8) else {
            throw DsmRequestError.parameterEncodingFailed
        }
        return data
    }
}

enum DsmRequestBuilder {
    static func build(
        baseURL: URL,
        path: String,
        api: String,
        version: Int,
        method: String,
        requestFormat: DsmRequestFormat,
        parameters: [String: DsmParameterValue],
        credential: DsmSessionCredential? = nil,
        httpMethod: String = "POST"
    ) throws -> URLRequest {
        guard baseURL.scheme?.lowercased() == NasScheme.https.rawValue,
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil else {
            throw DsmRequestError.insecureBaseURL
        }

        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              pathSegments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw DsmRequestError.invalidAPIPath
        }

        var url = baseURL.appendingPathComponent("webapi", isDirectory: true)
        for segment in pathSegments {
            url.appendPathComponent(String(segment), isDirectory: false)
        }

        var fields = [
            "api": api,
            "version": String(version),
            "method": method
        ]

        for (key, value) in parameters {
            fields[key] = try value.encoded(for: requestFormat)
        }

        // GET 请求的认证仅通过 Header 发送，避免会话字段进入 URL、代理日志或重定向目标。
        if let credential, httpMethod.uppercased() != "GET" {
            fields["_sid"] = credential.sid
            if let synoToken = credential.synoToken, !synoToken.isEmpty {
                fields["SynoToken"] = synoToken
            }
        }

        var finalURL = url
        if httpMethod == "GET" {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            components?.queryItems = fields
                .sorted { $0.key < $1.key }
                .map { key, value in
                    URLQueryItem(name: key, value: value)
                }
            if let resolvedURL = components?.url {
                finalURL = resolvedURL
            }
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = httpMethod
        if httpMethod == "POST" {
            request.setValue(
                "application/x-www-form-urlencoded; charset=utf-8",
                forHTTPHeaderField: "Content-Type"
            )
            request.httpBody = try FormURLEncoder.encode(fields)
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let cookie = credential?.cookieHeaderValue {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let synoToken = credential?.synoToken, !synoToken.isEmpty {
            request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        return request
    }
}
