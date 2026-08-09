import DsmCore
import Foundation

enum MobileNasHealthPhase: String, CaseIterable, Equatable, Sendable {
    case idle
    case loading
    case empty
    case error
    case content
}

struct MobileNasHealthSection<Value: Equatable & Sendable>: Equatable, Sendable {
    var phase: MobileNasHealthPhase = .idle
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

    mutating func finish(_ value: Value, isEmpty: Bool = false) {
        self.value = value
        phase = isEmpty ? .empty : .content
        isRefreshing = false
        hasRefreshError = false
        hasLoadedOnce = true
    }

    mutating func fail() {
        isRefreshing = false
        if hasLoadedOnce {
            hasRefreshError = true
        } else {
            value = nil
            phase = .error
        }
    }

    mutating func cancelLoading() {
        isRefreshing = false
        if !hasLoadedOnce, phase == .loading {
            phase = .idle
        }
    }
}

enum MobileNasHealthLevel: String, CaseIterable, Equatable, Sendable {
    case healthy
    case warning
    case critical
    case unknown

    init(status: String?) {
        switch status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "normal", "healthy", "good", "ready", "optimal": self = .healthy
        case "warning", "attention", "degraded": self = .warning
        case "critical", "crashed", "failing", "failed", "error", "abnormal": self = .critical
        default: self = .unknown
        }
    }
}

struct MobileNasSystemHealth: Equatable, Sendable {
    let serverName: String
    let model: String?
    let version: String?
    let uptimeSeconds: Int64?
    let cpuModel: String?
    let cpuCoreCount: Int?
    let cpuClockMHz: Int?
    let memoryBytes: Int64?
    let temperatureCelsius: Double?
    let temperatureLevel: MobileNasHealthLevel

    init(_ overview: NasSystemOverview) {
        serverName = overview.serverName
        model = overview.model
        version = overview.version
        uptimeSeconds = overview.uptimeSeconds
        cpuModel = overview.cpuModel
        cpuCoreCount = overview.cpuCoreCount
        cpuClockMHz = overview.cpuClockMHz
        memoryBytes = overview.memoryBytes
        temperatureCelsius = overview.temperatureCelsius
        if overview.temperatureCelsius == nil {
            temperatureLevel = .unknown
        } else {
            temperatureLevel = overview.hasTemperatureWarning ? .warning : .healthy
        }
    }
}

struct MobileNasPerformanceHealth: Equatable, Sendable {
    let recordedAt: Date
    let cpuUsage: Double
    let memoryUsage: Double
    let swapUsage: Double
    let networkReceivedBytesPerSecond: Int64
    let networkSentBytesPerSecond: Int64
    let diskReadBytesPerSecond: Int64
    let diskWriteBytesPerSecond: Int64
    let volumeReadBytesPerSecond: Int64
    let volumeWriteBytesPerSecond: Int64
    let diskUtilization: Double

    init(_ snapshot: NasPerformanceSnapshot) {
        recordedAt = snapshot.recordedAt
        cpuUsage = snapshot.cpuUsage
        memoryUsage = snapshot.memoryUsage
        swapUsage = snapshot.swapUsage
        networkReceivedBytesPerSecond = snapshot.networkReceivedBytesPerSecond
        networkSentBytesPerSecond = snapshot.networkSentBytesPerSecond
        diskReadBytesPerSecond = snapshot.diskReadBytesPerSecond
        diskWriteBytesPerSecond = snapshot.diskWriteBytesPerSecond
        volumeReadBytesPerSecond = snapshot.volumeReadBytesPerSecond
        volumeWriteBytesPerSecond = snapshot.volumeWriteBytesPerSecond
        diskUtilization = snapshot.diskUtilization
    }
}

struct MobileNasStoragePoolHealth: Equatable, Sendable {
    let name: String
    let raidType: String?
    let health: MobileNasHealthLevel
    let totalBytes: Int64?
    let usedBytes: Int64?
    let isScrubbing: Bool

    init(_ pool: NasStoragePool) {
        name = pool.name
        raidType = pool.raidType
        health = MobileNasHealthLevel(status: pool.status)
        totalBytes = pool.totalBytes
        usedBytes = pool.usedBytes
        isScrubbing = pool.isScrubbing
    }
}

struct MobileNasVolumeHealth: Equatable, Sendable {
    let name: String
    let fileSystem: String?
    let health: MobileNasHealthLevel
    let totalBytes: Int64?
    let usedBytes: Int64?
    let isEncrypted: Bool

    init(_ volume: NasVolume) {
        name = volume.name
        fileSystem = volume.fileSystem
        health = MobileNasHealthLevel(status: volume.status)
        totalBytes = volume.totalBytes
        usedBytes = volume.usedBytes
        isEncrypted = volume.isEncrypted
    }
}

struct MobileNasDiskHealth: Equatable, Sendable {
    let name: String
    let vendor: String?
    let model: String?
    let type: String?
    let totalBytes: Int64?
    let health: MobileNasHealthLevel
    let smartHealth: MobileNasHealthLevel
    let temperatureCelsius: Double?
    let isSSD: Bool
    let estimatedLifePercent: Int?
    let badSectorCount: Int?

    init(_ disk: NasDisk) {
        name = disk.name
        vendor = disk.vendor
        model = disk.model
        type = disk.type
        totalBytes = disk.totalBytes
        health = MobileNasHealthLevel(status: disk.status)
        smartHealth = MobileNasHealthLevel(status: disk.smartStatus)
        temperatureCelsius = disk.temperatureCelsius
        isSSD = disk.isSSD
        estimatedLifePercent = disk.estimatedLifePercent
        badSectorCount = disk.badSectorCount
    }
}

struct MobileNasStorageHealth: Equatable, Sendable {
    let overallHealth: MobileNasHealthLevel
    let pools: [MobileNasStoragePoolHealth]
    let volumes: [MobileNasVolumeHealth]
    let disks: [MobileNasDiskHealth]

    var isEmpty: Bool { pools.isEmpty && volumes.isEmpty && disks.isEmpty }

    init(_ snapshot: NasStorageSnapshot) {
        overallHealth = MobileNasHealthLevel(status: snapshot.overallStatus)
        pools = snapshot.pools.map(MobileNasStoragePoolHealth.init)
        volumes = snapshot.volumes.map(MobileNasVolumeHealth.init)
        disks = snapshot.disks.map(MobileNasDiskHealth.init)
    }
}

enum MobileNasUpdateStatus: String, CaseIterable, Equatable, Sendable {
    case updateAvailable
    case upToDate
}

struct MobileNasUpdateHealth: Equatable, Sendable {
    let status: MobileNasUpdateStatus
    let currentVersion: String?
    let latestVersion: String?
    let releaseNotes: String?

    init(_ info: NasSystemUpdateInfo) {
        status = info.isUpdateAvailable ? .updateAvailable : .upToDate
        currentVersion = info.currentVersion
        latestVersion = info.latestVersion
        releaseNotes = info.releaseNotes
    }
}

struct MobileNasHealthState: Equatable, Sendable {
    var system = MobileNasHealthSection<MobileNasSystemHealth>()
    var performance = MobileNasHealthSection<MobileNasPerformanceHealth>()
    var storage = MobileNasHealthSection<MobileNasStorageHealth>()
    var update = MobileNasHealthSection<MobileNasUpdateHealth>()

    var isRefreshing: Bool {
        system.isRefreshing || performance.isRefreshing || storage.isRefreshing || update.isRefreshing
            || system.phase == .loading || performance.phase == .loading
            || storage.phase == .loading || update.phase == .loading
    }
}
