import Foundation

public struct FileStationAdvancedAccess: Equatable, Sendable {
    public let isAdministrator: Bool
    public let writesEnabled: Bool
    public init(isAdministrator: Bool, writesEnabled: Bool) {
        self.isAdministrator = isAdministrator
        self.writesEnabled = writesEnabled
    }
}

public struct FileStationPrincipal: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case user, group }
    public let name: String
    public let kind: Kind
    public var id: String { kind.rawValue + ":" + name }
    public init(name: String, kind: Kind) { self.name = name; self.kind = kind }
}

public struct FileStationPrincipalPage: Sendable {
    public let items: [FileStationPrincipal]
    public let total: Int
    public let nextOffset: Int
    public init(items: [FileStationPrincipal], total: Int, nextOffset: Int) {
        self.items = items; self.total = total; self.nextOffset = nextOffset
    }
}

/// 可选附加字段保留旧分享存储的解码兼容性；缺字段不等于没有保护。
public struct FileShareAdvancedDetails: Codable, Hashable, Sendable {
    public enum Protection: String, Codable, CaseIterable, Sendable { case none, password, users = "user" }
    public let protection: Protection
    public let users: [String]
    public let groups: [String]
    public let maximumAccesses: Int
    public let isFileRequest: Bool
    public let allowsUpload: Bool
    public let requestName: String
    public let requestMessage: String
    public init(protection: Protection, users: [String], groups: [String], maximumAccesses: Int,
                isFileRequest: Bool, allowsUpload: Bool, requestName: String, requestMessage: String) {
        self.protection = protection; self.users = users; self.groups = groups
        self.maximumAccesses = maximumAccesses; self.isFileRequest = isFileRequest
        self.allowsUpload = allowsUpload; self.requestName = requestName; self.requestMessage = requestMessage
    }
}

/// 高级分享只修改明确列出的字段，日期与密码由既有编辑意图独立管理。
public struct FileShareAdvancedChange: Sendable {
    public enum Audience: Sendable { case keep, anyone, principals([FileStationPrincipal]) }
    public let audience: Audience
    public let maximumAccesses: Int?
    public let requestName: String?
    public let requestMessage: String?
    public init(audience: Audience = .keep, maximumAccesses: Int? = nil,
                requestName: String? = nil, requestMessage: String? = nil) {
        self.audience = audience; self.maximumAccesses = maximumAccesses
        self.requestName = requestName; self.requestMessage = requestMessage
    }
}

public struct FileRequestConfiguration: Sendable {
    public let name: String
    public let message: String
    public init(name: String, message: String) { self.name = name; self.message = message }
}
