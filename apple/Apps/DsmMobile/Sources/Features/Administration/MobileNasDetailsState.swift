import Foundation

enum MobileNasAdministrationDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case system
    case performance
    case storage
    case update
    case packages
    case scheduledTasks
    case logs
    case connections

    var id: String { rawValue }

    static let health: [Self] = [.system, .performance, .storage, .update]
    static let details: [Self] = [.packages, .scheduledTasks, .logs, .connections]

    var isDetails: Bool { Self.details.contains(self) }
}

enum MobileNasDetailsPhase: String, CaseIterable, Equatable, Sendable {
    case idle
    case loading
    case empty
    case error
    case unavailable
    case content
}

struct MobileNasDetailsSection<Value: Equatable & Sendable>: Equatable, Sendable {
    var phase: MobileNasDetailsPhase = .idle
    var value: Value?
    var isRefreshing = false
    var hasRefreshError = false
    var hasLoadedOnce = false

    mutating func beginLoading() {
        hasRefreshError = false
        if hasLoadedOnce {
            isRefreshing = true
        } else {
            phase = .loading
        }
    }

    mutating func finish(_ value: Value, isEmpty: Bool) {
        self.value = value
        phase = isEmpty ? .empty : .content
        isRefreshing = false
        hasRefreshError = false
        hasLoadedOnce = true
    }

    mutating func fail(isUnavailable: Bool) {
        isRefreshing = false
        if hasLoadedOnce {
            hasRefreshError = true
        } else {
            value = nil
            phase = isUnavailable ? .unavailable : .error
            hasLoadedOnce = isUnavailable
        }
    }

    mutating func cancelLoading() {
        isRefreshing = false
        if !hasLoadedOnce, phase == .loading {
            phase = .idle
        }
    }
}

struct MobileNasBoundedPage<Item: Equatable & Sendable>: Equatable, Sendable {
    let items: [Item]
    let total: Int
    let isTruncated: Bool

    var isEmpty: Bool { items.isEmpty }
}

enum MobileNasPackageStatus: String, Equatable, Sendable {
    case running
    case stopped
    case needsAttention
    case unknown

    init(_ value: String?) {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "running", "started", "enabled", "online": self = .running
        case "stopped", "disabled", "offline": self = .stopped
        case "error", "broken", "repair", "failed", "attention": self = .needsAttention
        default: self = .unknown
        }
    }
}

struct MobileNasPackageDetail: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let version: String?
    let status: MobileNasPackageStatus
}

struct MobileNasScheduledTaskDetail: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let isEnabled: Bool
    let nextTriggerDescription: String?
}

enum MobileNasLogLevel: String, Equatable, Sendable {
    case information
    case warning
    case error
    case unknown

    init(_ value: String?) {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "info", "information", "notice": self = .information
        case "warn", "warning": self = .warning
        case "error", "err", "critical", "alert": self = .error
        default: self = .unknown
        }
    }
}

struct MobileNasLogDetail: Identifiable, Equatable, Sendable {
    let id: Int
    let date: Date?
    let source: String?
    let level: MobileNasLogLevel
}

struct MobileNasConnectionDetail: Identifiable, Equatable, Sendable {
    let id: Int
    let protocolName: String?
    let type: String?
    let connectedAt: Date?
    let isCurrentConnection: Bool
}

struct MobileNasDetailsState: Equatable, Sendable {
    var packages = MobileNasDetailsSection<MobileNasBoundedPage<MobileNasPackageDetail>>()
    var scheduledTasks = MobileNasDetailsSection<MobileNasBoundedPage<MobileNasScheduledTaskDetail>>()
    var logs = MobileNasDetailsSection<MobileNasBoundedPage<MobileNasLogDetail>>()
    var connections = MobileNasDetailsSection<MobileNasBoundedPage<MobileNasConnectionDetail>>()

    var isRefreshing: Bool {
        [packages.isRefreshing, scheduledTasks.isRefreshing, logs.isRefreshing, connections.isRefreshing]
            .contains(true)
            || packages.phase == .loading
            || scheduledTasks.phase == .loading
            || logs.phase == .loading
            || connections.phase == .loading
    }
}
