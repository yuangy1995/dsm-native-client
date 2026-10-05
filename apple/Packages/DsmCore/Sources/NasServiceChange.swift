import Foundation

public enum NasServiceKind: String, CaseIterable, Codable, Sendable { case fileServices, terminal, proxy }

/// 与实际写请求一一对应；同组字段不能拆成多个请求。
public enum NasServiceStep: String, CaseIterable, Codable, Sendable {
    case smb, nfs, ftp, sftp, webDiscovery, fileDiscovery, terminal, proxy
    public var kind: NasServiceKind {
        switch self { case .terminal: .terminal; case .proxy: .proxy; default: .fileServices }
    }
}

public enum NasServiceCheckpoint: Equatable, Sendable {
    case willSubmit(NasServiceStep), accepted(NasServiceStep), verified(NasServiceStep), partial(NasServiceStep), rejected(NasServiceStep)
}

public enum NasServiceSettings: Equatable, Sendable {
    case fileServices(NasFileServiceSettings), terminal(NasTerminalSettings), proxy(NasProxySettings)
    public var kind: NasServiceKind {
        switch self { case .fileServices: .fileServices; case .terminal: .terminal; case .proxy: .proxy }
    }
    public var isEmpty: Bool { steps.allSatisfy { fields(for: $0).allSatisfy { $0 == nil } } }
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
        case (.terminal, .terminal) where step == .terminal: return desired
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
        return original.steps.filter { step in
            if case .proxy(let value) = desired, !value.isEnabled {
                return original.fields(for: step).first != desired.fields(for: step).first
            }
            return original.fields(for: step) != desired.fields(for: step)
        }
    }
    /// 顺序必须使每个中间状态满足已有依赖；不能暗中增加开关操作。
    public var orderedSteps: [NasServiceStep]? {
        guard kind == desired.kind, desired.isValid, !changedSteps.isEmpty else { return nil }
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
    public func matches(_ settings: NasServiceSettings) -> Bool { original == settings && orderedSteps != nil }
    public func savedFieldsMatch(_ settings: NasServiceSettings, step: NasServiceStep) -> Bool {
        settings.kind == kind && settings.fields(for: step, verifying: true) == desired.fields(for: step, verifying: true)
    }
    public func hasPartialResult(_ settings: NasServiceSettings, step: NasServiceStep) -> Bool {
        guard settings.kind == kind else { return false }
        // 停用代理只提交一个开关，保留地址变化不能算成本次部分生效。
        if case .proxy(let value) = desired, !value.isEnabled { return false }
        let before = original.fields(for: step), after = desired.fields(for: step), actual = settings.fields(for: step)
        return zip(zip(before, after), actual).contains { pair, value in pair.0 != pair.1 && pair.1 == value }
    }
}
