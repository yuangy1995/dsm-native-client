import Foundation

public enum NasServiceKind: String, CaseIterable, Codable, Sendable { case fileServices, terminal, proxy, remoteAccess, zram, powerSchedule }

/// 与实际写请求一一对应；同组字段不能拆成多个请求。
public enum NasServiceStep: String, CaseIterable, Codable, Sendable {
    case smb, nfs, ftp, sftp, webDiscovery, fileDiscovery, terminal, proxy, relay, routerConfiguration, zram, rebootRequired, powerSchedule
    public var kind: NasServiceKind {
        switch self { case .terminal: .terminal; case .proxy: .proxy; case .relay, .routerConfiguration: .remoteAccess
        case .zram, .rebootRequired: .zram; case .powerSchedule: .powerSchedule; default: .fileServices }
    }
}

public enum NasServiceCheckpoint: Equatable, Sendable {
    case willSubmit(NasServiceStep), accepted(NasServiceStep), verified(NasServiceStep), partial(NasServiceStep), rejected(NasServiceStep)
}

public enum NasServiceSettings: Equatable, Sendable {
    case fileServices(NasFileServiceSettings), terminal(NasTerminalSettings), proxy(NasProxySettings), remoteAccess(NasRemoteAccessSettings)
    case zram(NasZRAMSnapshot, needsReboot: Bool?), powerSchedule(NasPowerScheduleSnapshot)
    public var kind: NasServiceKind {
        switch self { case .fileServices: .fileServices; case .terminal: .terminal; case .proxy: .proxy; case .remoteAccess: .remoteAccess
        case .zram: .zram; case .powerSchedule: .powerSchedule }
    }
    public var isEmpty: Bool {
        switch self {
        case .zram: return false
        case .powerSchedule(let value): return value.entries.isEmpty && !value.isTruncated
        default: return steps.allSatisfy { fields(for: $0).allSatisfy { $0 == nil } }
        }
    }
    public var supportsEditing: Bool {
        switch self {
        case .zram(let value, let needsReboot): return value.isEnabled != nil && needsReboot != nil
        case .powerSchedule(let value): return value.canEdit
        default: return !isEmpty
        }
    }
    public var steps: [NasServiceStep] { NasServiceStep.allCases.filter { $0.kind == kind } }

    /// 顺序与分组固定，用于原值比较及恢复摘要；不包含翻译或 API 参数。
    public func fields(for step: NasServiceStep, verifying: Bool = false) -> [String?] {
        switch (self, step) {
        case (.fileServices(let value), .smb): return [value.isSMBEnabled.map(String.init)]
        case (.fileServices(let value), .nfs): return [value.isNFSEnabled.map(String.init)]
        case (.fileServices(let value), .ftp): return [value.isFTPEnabled.map(String.init), value.isFTPSEnabled.map(String.init), value.ftpPort.map(String.init)]
        case (.fileServices(let value), .sftp): return [value.isSFTPEnabled.map(String.init), value.sftpPort.map(String.init)]
        case (.fileServices(let value), .webDiscovery): return [value.isSSDPEnabled.map(String.init), value.isBonjourEnabled.map(String.init)]
        case (.fileServices(let value), .fileDiscovery): return [value.isSMBTimeMachineEnabled.map(String.init)]
        case (.terminal(let value), .terminal): return [String(value.isSSHEnabled), String(value.isTelnetEnabled), value.sshPort.map(String.init)]
        case (.remoteAccess(let value), .relay): return [value.isRelayEnabled.map(String.init)]
        case (.remoteAccess(let value), .routerConfiguration): return [value.isRouterConfigurationEnabled.map(String.init)]
        case (.zram(let value, _), .zram): return [value.isEnabled.map(String.init)]
        case (.zram(let value, let needsReboot), .rebootRequired): return [value.isEnabled.map(String.init), needsReboot.map(String.init)]
        case (.powerSchedule(let value), .powerSchedule):
            // 空的完整清单也有确定摘要；不完整读取不能用于恢复或覆盖。
            return [value.canEdit ? value.entries.map(\.scheduleComparisonKey).sorted().joined(separator: "|") : nil, value.timeZoneIdentifier]
        case (.proxy(let value), .proxy):
            if verifying && !value.isEnabled { return [String(false)] }
            return [String(value.isEnabled), value.normalizedHost, value.port.map(String.init)]
        default: return []
        }
    }

    public func replacing(_ step: NasServiceStep, with desired: NasServiceSettings) -> NasServiceSettings {
        switch (self, desired) {
        case (.fileServices(var value), .fileServices(let next)):
            switch step {
            case .smb: value.isSMBEnabled = next.isSMBEnabled
            case .nfs: value.isNFSEnabled = next.isNFSEnabled
            case .ftp: value.isFTPEnabled = next.isFTPEnabled; value.isFTPSEnabled = next.isFTPSEnabled; value.ftpPort = next.ftpPort
            case .sftp: value.isSFTPEnabled = next.isSFTPEnabled; value.sftpPort = next.sftpPort
            case .webDiscovery: value.isSSDPEnabled = next.isSSDPEnabled; value.isBonjourEnabled = next.isBonjourEnabled
            case .fileDiscovery: value.isSMBTimeMachineEnabled = next.isSMBTimeMachineEnabled
            default: break
            }
            return .fileServices(value)
        case (.remoteAccess(var value), .remoteAccess(let next)):
            if step == .relay { value.isRelayEnabled = next.isRelayEnabled }
            if step == .routerConfiguration { value.isRouterConfigurationEnabled = next.isRouterConfigurationEnabled }
            return .remoteAccess(value)
        case (.terminal, .terminal) where step == .terminal: return desired
        case (.zram(let value, let needsReboot), .zram(let next, let reboot)):
            return .zram(step == .zram ? next : value, needsReboot: step == .rebootRequired ? reboot : needsReboot)
        case (.powerSchedule, .powerSchedule) where step == .powerSchedule: return desired
        case (.proxy(let previous), .proxy(let next)) where step == .proxy:
            return .proxy(.init(isEnabled: next.isEnabled, host: next.isEnabled ? next.normalizedHost : previous.host, port: next.isEnabled ? next.port : previous.port))
        default: return self
        }
    }

    public var isValid: Bool {
        func port(_ value: Int?) -> Bool { value.map { (1...65_535).contains($0) } ?? true }
        switch self {
        case .fileServices(let value):
            return port(value.ftpPort) && port(value.sftpPort)
                && !(value.isSMBTimeMachineEnabled == true && value.isSMBEnabled == false)
                && !((value.isFTPEnabled == true || value.isFTPSEnabled == true) && value.isSFTPEnabled == true
                    && value.ftpPort != nil && value.ftpPort == value.sftpPort)
        case .terminal(let value): return port(value.sshPort)
        case .proxy(let value): return value.isValidForSaving
        case .remoteAccess: return true
        case .zram: return supportsEditing
        case .powerSchedule(let value): return value.canEdit && NasPowerScheduleSnapshot.replacementIsValid(value.entries)
        }
    }

    /// 电源计划忽略临时行 ID 和数组顺序；重启要求由 NAS 维护，不作为用户编辑的原值。
    public func hasSameConfiguration(as other: NasServiceSettings) -> Bool {
        switch (self, other) {
        case (.powerSchedule(let value), .powerSchedule(let next)):
            return value.timeZoneIdentifier == next.timeZoneIdentifier && value.hasSameSchedule(as: next.entries) && next.canEdit
        case (.zram(let value, _), .zram(let next, _)):
            return supportsEditing && other.supportsEditing && value.isEnabled == next.isEnabled
        default: return self == other
        }
    }
}

public struct NasServiceChange: Equatable, Sendable {
    public let original: NasServiceSettings
    public let desired: NasServiceSettings
    public init(original: NasServiceSettings, desired: NasServiceSettings) { self.original = original; self.desired = desired }
    public var kind: NasServiceKind { original.kind }
    public var changedSteps: [NasServiceStep] {
        guard kind == desired.kind else { return [] }
        if case .zram(let before, _) = original, case .zram(let after, _) = desired, before.isEnabled != after.isEnabled {
            // 与官方保存一致，即使之前已有重启要求，也为这次压缩更改执行两个边界。
            return [.zram, .rebootRequired]
        }
        return original.steps.filter { step in
            if case .proxy(let value) = desired, !value.isEnabled {
                return original.fields(for: step).first != desired.fields(for: step).first
            }
            return original.fields(for: step) != desired.fields(for: step)
        }
    }
    /// 顺序必须使每个中间状态满足已有依赖；不能暗中增加开关操作。
    public var orderedSteps: [NasServiceStep]? {
        guard kind == desired.kind, original.supportsEditing, desired.isValid, !changedSteps.isEmpty else { return nil }
        if case .zram(_, let reboot) = desired, reboot != true { return nil }
        if case .remoteAccess(let before) = original, case .remoteAccess(let after) = desired {
            guard before.canDisableRelay == after.canDisableRelay,
                  !(changedSteps.contains(.relay) && after.isRelayEnabled == false && !before.canDisableRelay) else { return nil }
        }
        if kind != .proxy {
            guard original.steps.allSatisfy({ step in
                zip(original.fields(for: step), desired.fields(for: step)).allSatisfy { ($0 == nil) == ($1 == nil) }
            }) else { return nil }
        }
        var pending = changedSteps, state = original, result: [NasServiceStep] = []
        while !pending.isEmpty {
            guard let index = pending.firstIndex(where: { state.replacing($0, with: desired).isValid }) else { return nil }
            let step = pending.remove(at: index); state = state.replacing(step, with: desired); result.append(step)
        }
        return result
    }
    public func matches(_ settings: NasServiceSettings) -> Bool { original.hasSameConfiguration(as: settings) && orderedSteps != nil }
    public func savedFieldsMatch(_ settings: NasServiceSettings, step: NasServiceStep) -> Bool {
        settings.kind == kind && settings.fields(for: step, verifying: true) == desired.fields(for: step, verifying: true)
    }
    public func hasPartialResult(_ settings: NasServiceSettings, step: NasServiceStep) -> Bool {
        guard settings.kind == kind else { return false }
        if kind == .zram { return false }
        // 停用代理只提交一个开关，保留地址变化不能算成本次部分生效。
        if case .proxy(let value) = desired, !value.isEnabled { return false }
        let before = original.fields(for: step), after = desired.fields(for: step), actual = settings.fields(for: step)
        return zip(zip(before, after), actual).contains { pair, value in pair.0 != pair.1 && pair.1 == value }
    }
}
