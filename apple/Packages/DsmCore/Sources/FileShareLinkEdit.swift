import Foundation

public enum FileShareLinkStatus: String, Codable, Hashable, Sendable {
    case valid, invalid, inactive, expired, broken, unknown
}

/// 密码意图显式区分保留、设置和移除，不序列化或回显密码。
public enum FileShareLinkPasswordChange: Sendable { case keep, set(String), remove }

public struct FileShareLinkEditRequest: Sendable {
    public let baseline: FileShareLink
    public let password: FileShareLinkPasswordChange
    public let availableOn: FileShareLinkCalendarDate?
    public let expiresOn: FileShareLinkCalendarDate?
    public let advanced: FileShareAdvancedChange?
    public let keepsAvailableDate: Bool
    public let keepsExpirationDate: Bool
    public init(baseline: FileShareLink, password: FileShareLinkPasswordChange = .keep,
                availableOn: FileShareLinkCalendarDate?, expiresOn: FileShareLinkCalendarDate?,
                advanced: FileShareAdvancedChange? = nil,
                keepsAvailableDate: Bool = false, keepsExpirationDate: Bool = false) throws {
        guard !baseline.id.isEmpty else { throw FileShareLinkContractError.invalidTarget }
        if case .set(let value) = password, value.isEmpty || value.count > 16 { throw FileShareLinkContractError.invalidPassword }
        if let availableOn, let expiresOn, availableOn > expiresOn { throw FileShareLinkContractError.invalidDateRange }
        if let advanced {
            if case .keep = password {} else {
                if case .keep = advanced.audience {} else { throw FileShareLinkContractError.invalidTarget }
            }
        }
        self.baseline = baseline; self.password = password; self.availableOn = availableOn; self.expiresOn = expiresOn
        self.advanced = advanced
        self.keepsAvailableDate = keepsAvailableDate; self.keepsExpirationDate = keepsExpirationDate
    }
}

public struct FileShareLinkEditOutcome: Sendable {
    public let result: MutationResult
    public let confirmedLink: FileShareLink?
    public init(result: MutationResult, confirmedLink: FileShareLink?) { self.result = result; self.confirmedLink = confirmedLink }
}
