import DsmCore
import DsmLocalization
import Foundation

enum MobileDownloadFilter: String, CaseIterable, Identifiable {
    case all, active, downloading, seeding, finished, paused, waiting, error
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: L10n.string("download.workspace.filter.all")
        case .active: L10n.string("download.workspace.filter.active")
        case .downloading: L10n.string("download.workspace.filter.downloading")
        case .seeding: L10n.string("download.workspace.filter.seeding")
        case .finished: L10n.string("download.workspace.filter.finished")
        case .paused: L10n.string("download.workspace.filter.paused")
        case .waiting: L10n.string("download.workspace.filter.waiting")
        case .error: L10n.string("download.workspace.filter.error")
        }
    }

    func includes(_ task: DownloadStationTask) -> Bool {
        let status = task.status.lowercased()
        switch self {
        case .all: return true
        case .active: return ["downloading", "uploading", "seeding", "waiting", "checking", "hash_checking", "filehosting_waiting", "extracting"].contains(status)
        case .seeding: return ["seeding", "uploading"].contains(status)
        case .waiting: return ["waiting", "filehosting_waiting"].contains(status)
        default: return status == rawValue
        }
    }
}

enum MobileDownloadSort: String, CaseIterable, Identifiable {
    case name, progress, status
    var id: String { rawValue }
    var title: String {
        switch self {
        case .name: L10n.string("download.workspace.name")
        case .progress: L10n.string("download.workspace.progress")
        case .status: L10n.string("download.workspace.status")
        }
    }

    func precedes(_ left: DownloadStationTask, _ right: DownloadStationTask) -> Bool {
        if self == .progress, left.progress != right.progress { return (left.progress ?? -1) > (right.progress ?? -1) }
        if self == .status, left.status != right.status { return left.status < right.status }
        let comparison = left.title.compare(right.title, options: [.caseInsensitive, .numeric], locale: L10n.locale)
        return comparison == .orderedSame ? left.id < right.id : comparison == .orderedAscending
    }
}

enum MobileDownloadPresentation {
    static var unknown: String { L10n.string("mobile.downloads.value.unknown") }

    static func status(_ raw: String) -> String {
        switch raw.lowercased() {
        case "waiting", "filehosting_waiting": return MobileDownloadFilter.waiting.title
        case "downloading": return MobileDownloadFilter.downloading.title
        case "uploading", "seeding": return MobileDownloadFilter.seeding.title
        case "paused": return MobileDownloadFilter.paused.title
        case "finished": return MobileDownloadFilter.finished.title
        case "error": return MobileDownloadFilter.error.title
        case "checking", "hash_checking": return L10n.string("download.workspace.checking")
        case "extracting": return L10n.string("download.workspace.extracting")
        default: return L10n.string("download.workspace.unknown")
        }
    }

    static func bytes(_ bytes: Int64?) -> String {
        guard let bytes, bytes >= 0 else { return unknown }
        return bytes.formatted(.byteCount(style: .file).locale(L10n.locale))
    }

    static func speed(_ value: Int64?) -> String {
        guard let value, value >= 0 else { return unknown }
        return L10n.string("ui.3b14d1af77ab3e3e", bytes(value))
    }

    static func remaining(_ task: DownloadStationTask) -> String {
        guard let seconds = task.remainingSeconds else { return unknown }
        let formatter = DateComponentsFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.calendar?.locale = L10n.locale
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = seconds >= 86_400 ? [.day, .hour] : seconds >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.maximumUnitCount = 2
        return formatter.string(from: seconds) ?? unknown
    }
}
