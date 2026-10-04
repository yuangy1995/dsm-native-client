import Foundation

/// 未触碰日期时保留原始秒数；主动修改才按所选本地日末保存，兼容夏令时日长。
public struct PhotoSharingExpirationDraft {
    public enum Choice: Hashable { case unchanged, unlimited, date }
    public var choice: Choice
    public var date: Date
    public var edited = false

    public init(expiration: Int? = nil) {
        choice = expiration.map { $0 == 0 ? .unlimited : .date } ?? .unchanged
        date = expiration.flatMap { $0 > 0 ? Date(timeIntervalSince1970: Double($0)) : nil } ?? Date()
    }

    public func change(from original: Int?, calendar: Calendar = .current) -> Int? {
        guard edited else { return nil }
        let value: Int?
        switch choice {
        case .unchanged: value = nil
        case .unlimited: value = 0
        case .date: value = calendar.dateInterval(of: .day, for: date).flatMap { Int(exactly: $0.end.timeIntervalSince1970 - 1) }
        }
        return value == original ? nil : value
    }

    public var isValid: Bool {
        guard edited, choice == .date else { return true }
        return change(from: nil).map { Double($0) > Date().timeIntervalSince1970 } ?? false
    }
}


/// 不读取旧密码；nil保留，空字符串清除，主动设置时完整保留空格和Unicode。
public struct PhotoSharingPasswordDraft {
    public enum Choice: Hashable { case unchanged, newPassword, remove }
    public var choice: Choice = .unchanged
    public var password = ""
    public init() {}
    public var isValid: Bool { choice != .newPassword || !password.isEmpty }
    public func change(hasPassword: Bool?) -> String? {
        switch choice {
        case .unchanged: nil
        case .newPassword: password.isEmpty ? nil : password
        case .remove: hasPassword == false ? nil : ""
        }
    }
}
