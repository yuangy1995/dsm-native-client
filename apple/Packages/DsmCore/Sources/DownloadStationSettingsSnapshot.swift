import Foundation

/// 公开设置的已知字段。未返回或类型不符的字段保持缺失，不推导默认值。
public enum DownloadSettingsField: String, CaseIterable, Codable, Sendable {
    case destination, emule, autoExtract, btDownload, btUpload, httpDownload, ftpDownload
    case nzbDownload, emuleDownload, emuleUpload, schedule, emuleSchedule

    public enum Group: String, CaseIterable, Codable, Sendable { case general, schedule }
    public var group: Group { self == .schedule || self == .emuleSchedule ? .schedule : .general }
    public var parameter: String {
        switch self {
        case .destination: "default_destination"
        case .emule, .emuleSchedule: "emule_enabled"
        case .autoExtract: "unzip_service_enabled"
        case .btDownload: "bt_max_download"
        case .btUpload: "bt_max_upload"
        case .httpDownload: "http_max_download"
        case .ftpDownload: "ftp_max_download"
        case .nzbDownload: "nzb_max_download"
        case .emuleDownload: "emule_max_download"
        case .emuleUpload: "emule_max_upload"
        case .schedule: "enabled"
        }
    }
    public func accepts(_ value: DownloadSettingsValue) -> Bool {
        switch (self, value) {
        case (.destination, .text(let path)):
            return !path.hasPrefix("/") && !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
                && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." })
        case (.emule, .flag), (.autoExtract, .flag), (.schedule, .flag), (.emuleSchedule, .flag): return true
        case (.btDownload, .number(let number)), (.btUpload, .number(let number)), (.httpDownload, .number(let number)),
             (.ftpDownload, .number(let number)), (.nzbDownload, .number(let number)), (.emuleDownload, .number(let number)),
             (.emuleUpload, .number(let number)): return (0...1_000_000).contains(number)
        default: return false
        }
    }
}

public enum DownloadSettingsValue: Codable, Equatable, Sendable {
    case text(String), flag(Bool), number(Int)
    public var text: String? { if case .text(let value) = self { value } else { nil } }
    public var flag: Bool? { if case .flag(let value) = self { value } else { nil } }
    public var number: Int? { if case .number(let value) = self { value } else { nil } }
}

public struct DownloadSettingsSnapshot: Equatable, Sendable {
    public let isManager: Bool?
    public let values: [DownloadSettingsField: DownloadSettingsValue]
    public init(isManager: Bool?, values: [DownloadSettingsField: DownloadSettingsValue]) {
        self.isManager = isManager; self.values = values
    }
}

/// 每次只保存一个设置分区。HTTP/FTP 成对记录，以保留其共用值和写前比较。
public struct DownloadSettingsChange: Codable, Equatable, Sendable {
    public let group: DownloadSettingsField.Group
    public let original: [DownloadSettingsField: DownloadSettingsValue]
    public let desired: [DownloadSettingsField: DownloadSettingsValue]
    public init(group: DownloadSettingsField.Group, original: [DownloadSettingsField: DownloadSettingsValue],
                desired: [DownloadSettingsField: DownloadSettingsValue]) {
        self.group = group; self.original = original; self.desired = desired
    }
    public var isValid: Bool {
        guard !desired.isEmpty, original != desired, Set(original.keys) == Set(desired.keys),
              original.allSatisfy({ $0.key.group == group && $0.key.accepts($0.value) }),
              desired.allSatisfy({ $0.key.accepts($0.value) }) else { return false }
        if desired[.httpDownload] != nil || desired[.ftpDownload] != nil {
            guard desired[.httpDownload] != nil, desired[.httpDownload] == desired[.ftpDownload],
                  original[.httpDownload] == original[.ftpDownload] else { return false }
        }
        return true
    }
    public func matches(_ snapshot: DownloadSettingsSnapshot, desired: Bool) -> Bool {
        (desired ? self.desired : original).allSatisfy { snapshot.values[$0.key] == $0.value }
    }
}

public enum DownloadSettingsWriteOutcome: Equatable, Sendable {
    case complete, pending, denied, rejected, cancelledBeforeSubmission
}
