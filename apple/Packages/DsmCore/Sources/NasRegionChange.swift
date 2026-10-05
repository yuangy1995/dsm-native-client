import Foundation

/// 配置保存和立即校时分别落盘；检查点不携带服务器地址或其他配置正文。
public enum NasRegionCheckpoint: Equatable, Sendable {
    case willSave, saved, configurationVerified, willSynchronize, synchronized
}

public enum NasRegionChange: Equatable, Sendable {
    case save(original: NasRegionSettings, desired: NasRegionSettings, editsManualTime: Bool)
    case synchronize(expected: NasRegionSettings)

    public var original: NasRegionSettings {
        switch self { case .save(let value, _, _), .synchronize(let value): value }
    }
    public var desired: NasRegionSettings {
        switch self { case .save(_, let value, _), .synchronize(let value): value }
    }
    public var editsManualTime: Bool {
        if case .save(_, let value, let edited) = self { return edited && !value.isNetworkTimeEnabled }
        return false
    }
    public var isSynchronizationOnly: Bool { if case .synchronize = self { return true }; return false }
    public var requiresSynchronization: Bool {
        isSynchronizationOnly || desired.isNetworkTimeEnabled
            && (!original.isNetworkTimeEnabled || original.normalizedTimeServers != desired.normalizedTimeServers)
    }
    public var hasChanges: Bool {
        isSynchronizationOnly || !original.hasSameRegionConfiguration(as: desired)
            || editsManualTime && original.manualDate != desired.manualDate
    }
    public var isValid: Bool {
        let value = desired
        guard hasChanges, !value.normalizedDateFormat.isEmpty, !value.normalizedTimeFormat.isEmpty,
              value.timeZones.contains(where: { $0.id == value.timeZone }), value.normalizedTimeServers.count <= 3 else { return false }
        if value.isNetworkTimeEnabled {
            return !value.normalizedTimeServers.isEmpty && value.normalizedTimeServers.allSatisfy(NasRegionSettings.isValidTimeServer)
        }
        return !isSynchronizationOnly && (!editsManualTime || value.manualDate != nil)
    }
    public func matches(_ current: NasRegionSettings) -> Bool {
        isValid && original.hasSameRegionConfiguration(as: current)
            && current.timeZones.contains { $0.id == desired.timeZone }
    }

    /// 既有 Date 承载 NAS 的墙上时间；转为固定基准后才能跨设备时区保存和比较。
    public static func wallTime(_ date: Date, timeZone: TimeZone = .current) -> Date {
        var source = Calendar(identifier: .gregorian); source.timeZone = timeZone
        var target = Calendar(identifier: .gregorian); target.timeZone = TimeZone(secondsFromGMT: 0)!
        return target.date(from: source.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date))!
    }
}

public extension NasRegionSettings {
    func hasSameRegionConfiguration(as other: NasRegionSettings) -> Bool {
        normalizedDateFormat == other.normalizedDateFormat && normalizedTimeFormat == other.normalizedTimeFormat
            && timeZone == other.timeZone && isNetworkTimeEnabled == other.isNetworkTimeEnabled
            && normalizedTimeServers == other.normalizedTimeServers
    }
}
