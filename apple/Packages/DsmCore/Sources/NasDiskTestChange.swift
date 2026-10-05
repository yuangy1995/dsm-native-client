import Foundation

/// 硬盘检测动作使用稳定枚举，界面文案不参与请求或恢复判断。
public enum NasDiskTestAction: String, Codable, CaseIterable, Sendable {
    case quick, extended, stop

    public var testType: NasDiskTestType? {
        switch self {
        case .quick: .quick
        case .extended: .extended
        case .stop: nil
        }
    }
}

/// 用户确认时的硬盘身份与检测状态；进度、温度和展示名不作为身份。
public struct NasDiskTestChange: Equatable, Sendable {
    public let disk: NasDisk
    public let baseline: NasDiskTestStatus
    public let action: NasDiskTestAction

    public init(disk: NasDisk, baseline: NasDiskTestStatus, action: NasDiskTestAction) {
        self.disk = disk; self.baseline = baseline; self.action = action
    }

    public func matchesDisk(_ current: NasDisk) -> Bool {
        disk.hasSameTestIdentity(as: current)
    }

    public func matchesStatus(_ current: NasDiskTestStatus) -> Bool {
        baseline.diskID == disk.id && current.diskID == disk.id
            && baseline.isRunning == current.isRunning
            && baseline.isBusyWithOtherTest == current.isBusyWithOtherTest
            && baseline.runningType == current.runningType
    }

    public var isValid: Bool {
        guard !disk.id.isEmpty, !disk.deviceID.isEmpty, disk.supportsSmartTest,
              baseline.diskID == disk.id, !baseline.isBusyWithOtherTest else { return false }
        if action == .stop { return baseline.isRunning && baseline.runningType != nil }
        return !baseline.isRunning && baseline.runningType == nil
    }

    public func confirms(_ current: NasDiskTestStatus) -> Bool {
        guard current.diskID == disk.id else { return false }
        if action == .stop { return !current.isRunning }
        return current.isRunning && current.runningType == action.testType
    }
}

public extension NasDisk {
    func hasSameTestIdentity(as current: NasDisk) -> Bool {
        id == current.id && deviceID == current.deviceID && supportsSmartTest == current.supportsSmartTest
    }
}
