import Foundation

/// DSM 返回的更新状态；未知状态只允许继续读取，不推断可以安装。
public struct NasSystemUpdateStatus: Equatable, Sendable {
    public enum Phase: Sendable { case idle, downloading, ready, installing, completed, unknown }
    public let phase: Phase
    public let percent: Double?
    public let canInstall: Bool
    public let installedVersion: String?

    public init(phase: Phase, percent: Double? = nil, canInstall: Bool = false, installedVersion: String? = nil) {
        self.phase = phase
        self.percent = percent
        self.canInstall = canInstall
        self.installedVersion = installedVersion
    }
}

/// 安装确认绑定已检查的补丁，不能用旧确认安装后来出现的其他版本。
public struct NasSystemUpdatePlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let version: String
    public let build: Int
    public let update: Int
    public let requiresNASRestart: Bool

    public init(id: UUID = UUID(), version: String, build: Int, update: Int, requiresNASRestart: Bool = true) {
        self.id = id
        self.version = version
        self.build = build
        self.update = update
        self.requiresNASRestart = requiresNASRestart
    }

    public func matchesInstalledVersion(_ current: String?) -> Bool {
        guard let current else { return false }
        func normalized(_ text: String) -> String { text.lowercased().replacingOccurrences(of: "dsm", with: "").filter { !$0.isWhitespace } }
        return matchesTargetPatch && normalized(current) == normalized(version)
    }

    public var matchesTargetPatch: Bool {
        let normalized = version.lowercased().replacingOccurrences(of: "dsm", with: "").filter { !$0.isWhitespace }
        return normalized.range(of: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?-\(build)update\(update)$", options: .regularExpression) != nil
    }

    /// 调用者须先确认 NAS 已退出更新状态；运行时间用于确认确实发生了重启。
    public func confirmsCompletion(version: String?, uptimeSeconds: Int64?, submittedAt: Date, now: Date = Date()) -> Bool {
        guard matchesInstalledVersion(version) else { return false }
        guard requiresNASRestart else { return true }
        guard let uptimeSeconds, uptimeSeconds >= 0 else { return false }
        return now.timeIntervalSince(submittedAt) - Double(uptimeSeconds) >= 2
    }
}

public enum NasSystemUpdateSubmission: Sendable { case accepted, uncertain }
