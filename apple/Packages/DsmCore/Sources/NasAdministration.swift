import Foundation
import DsmLocalization

public struct NasSystemOverview: Equatable, Sendable {
    public let serverName: String
    public let model: String?
    public let version: String?
    public let uptimeSeconds: Int64?
    public let cpuModel: String?
    public let cpuCoreCount: Int?
    public let cpuClockMHz: Int?
    public let memoryBytes: Int64?
    public let temperatureCelsius: Double?
    public let hasTemperatureWarning: Bool

    public init(
        serverName: String,
        model: String? = nil,
        version: String? = nil,
        uptimeSeconds: Int64? = nil,
        cpuModel: String? = nil,
        cpuCoreCount: Int? = nil,
        cpuClockMHz: Int? = nil,
        memoryBytes: Int64? = nil,
        temperatureCelsius: Double? = nil,
        hasTemperatureWarning: Bool = false
    ) {
        self.serverName = serverName
        self.model = model
        self.version = version
        self.uptimeSeconds = uptimeSeconds
        self.cpuModel = cpuModel
        self.cpuCoreCount = cpuCoreCount
        self.cpuClockMHz = cpuClockMHz
        self.memoryBytes = memoryBytes
        self.temperatureCelsius = temperatureCelsius
        self.hasTemperatureWarning = hasTemperatureWarning
    }
}

public struct NasPerformanceSnapshot: Identifiable, Equatable, Sendable {
    public let id: Date
    public let recordedAt: Date
    public let cpuUsage: Double
    public let cpuUserUsage: Double
    public let cpuSystemUsage: Double
    public let cpuOtherUsage: Double
    public let memoryUsage: Double
    public let swapUsage: Double
    public let networkReceivedBytesPerSecond: Int64
    public let networkSentBytesPerSecond: Int64
    public let diskReadBytesPerSecond: Int64
    public let diskWriteBytesPerSecond: Int64
    public let volumeReadBytesPerSecond: Int64
    public let volumeWriteBytesPerSecond: Int64
    public let diskUtilization: Double
    public let nfsReadOperationsPerSecond: Int64
    public let nfsWriteOperationsPerSecond: Int64

    public init(
        recordedAt: Date,
        cpuUsage: Double,
        cpuUserUsage: Double,
        cpuSystemUsage: Double,
        cpuOtherUsage: Double,
        memoryUsage: Double,
        swapUsage: Double,
        networkReceivedBytesPerSecond: Int64,
        networkSentBytesPerSecond: Int64,
        diskReadBytesPerSecond: Int64,
        diskWriteBytesPerSecond: Int64,
        volumeReadBytesPerSecond: Int64,
        volumeWriteBytesPerSecond: Int64,
        diskUtilization: Double,
        nfsReadOperationsPerSecond: Int64,
        nfsWriteOperationsPerSecond: Int64
    ) {
        id = recordedAt
        self.recordedAt = recordedAt
        self.cpuUsage = cpuUsage
        self.cpuUserUsage = cpuUserUsage
        self.cpuSystemUsage = cpuSystemUsage
        self.cpuOtherUsage = cpuOtherUsage
        self.memoryUsage = memoryUsage
        self.swapUsage = swapUsage
        self.networkReceivedBytesPerSecond = networkReceivedBytesPerSecond
        self.networkSentBytesPerSecond = networkSentBytesPerSecond
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.volumeReadBytesPerSecond = volumeReadBytesPerSecond
        self.volumeWriteBytesPerSecond = volumeWriteBytesPerSecond
        self.diskUtilization = diskUtilization
        self.nfsReadOperationsPerSecond = nfsReadOperationsPerSecond
        self.nfsWriteOperationsPerSecond = nfsWriteOperationsPerSecond
    }
}

public struct NasStorageSnapshot: Equatable, Sendable {
    public let overallStatus: String?
    public let disks: [NasDisk]
    public let pools: [NasStoragePool]
    public let volumes: [NasVolume]

    public init(
        overallStatus: String?,
        disks: [NasDisk],
        pools: [NasStoragePool],
        volumes: [NasVolume]
    ) {
        self.overallStatus = overallStatus
        self.disks = disks
        self.pools = pools
        self.volumes = volumes
    }
}

public struct NasDisk: Identifiable, Equatable, Sendable {
    public let id: String
    /// DSM 内部接口使用的硬盘设备标识；与界面列表使用的稳定 `id` 不一定相同。
    public let deviceID: String
    public let name: String
    public let vendor: String?
    public let model: String?
    public let type: String?
    public let totalBytes: Int64?
    public let status: String?
    public let smartStatus: String?
    public let temperatureCelsius: Double?
    public let isSSD: Bool
    public let usedBy: String?
    public let supportsSmartTest: Bool
    public let serialNumber: String?
    public let firmwareVersion: String?
    public let location: String?
    public let is4KNative: Bool?
    public let estimatedLifePercent: Int?
    public let badSectorCount: Int?

    public init(
        id: String,
        deviceID: String? = nil,
        name: String,
        vendor: String? = nil,
        model: String?,
        type: String?,
        totalBytes: Int64?,
        status: String?,
        smartStatus: String?,
        temperatureCelsius: Double?,
        isSSD: Bool,
        usedBy: String?,
        supportsSmartTest: Bool,
        serialNumber: String? = nil,
        firmwareVersion: String? = nil,
        location: String? = nil,
        is4KNative: Bool? = nil,
        estimatedLifePercent: Int? = nil,
        badSectorCount: Int? = nil
    ) {
        self.id = id
        self.deviceID = deviceID ?? id
        self.name = name
        self.vendor = vendor
        self.model = model
        self.type = type
        self.totalBytes = totalBytes
        self.status = status
        self.smartStatus = smartStatus
        self.temperatureCelsius = temperatureCelsius
        self.isSSD = isSSD
        self.usedBy = usedBy
        self.supportsSmartTest = supportsSmartTest
        self.serialNumber = serialNumber
        self.firmwareVersion = firmwareVersion
        self.location = location
        self.is4KNative = is4KNative
        self.estimatedLifePercent = estimatedLifePercent
        self.badSectorCount = badSectorCount
    }
}

public struct NasStoragePool: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let raidType: String?
    public let status: String?
    public let totalBytes: Int64?
    public let usedBytes: Int64?
    public let isWritable: Bool
    public let isScrubbing: Bool
    public let nextScrubbingDate: Date?
    public let diskIDs: [String]
    public let spareDiskIDs: [String]
    public let supportsMultipleVolumes: Bool?

    /// 保留原布尔供既有调用使用；以下值仅表示 NAS 实际返回的状态，缺失保持 nil。
    public let reportedWritable: Bool?
    public let reportedScrubbing: Bool?

    public init(
        id: String,
        name: String,
        raidType: String?,
        status: String?,
        totalBytes: Int64?,
        usedBytes: Int64?,
        isWritable: Bool,
        isScrubbing: Bool,
        nextScrubbingDate: Date?,
        diskIDs: [String] = [],
        spareDiskIDs: [String] = [],
        supportsMultipleVolumes: Bool? = nil,
        reportedWritable: Bool? = nil,
        reportedScrubbing: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.raidType = raidType
        self.status = status
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.isWritable = isWritable
        self.isScrubbing = isScrubbing
        self.nextScrubbingDate = nextScrubbingDate
        self.diskIDs = diskIDs
        self.spareDiskIDs = spareDiskIDs
        self.supportsMultipleVolumes = supportsMultipleVolumes
        self.reportedWritable = reportedWritable
        self.reportedScrubbing = reportedScrubbing
    }
}

public struct NasVolume: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let fileSystem: String?
    public let status: String?
    public let totalBytes: Int64?
    public let usedBytes: Int64?
    public let isEncrypted: Bool
    public let isWritable: Bool
    public let poolID: String?
    public let path: String?

    /// 保留原布尔供既有调用使用；以下值仅表示 NAS 实际返回的状态，缺失保持 nil。
    public let reportedEncrypted: Bool?
    public let reportedWritable: Bool?

    public init(
        id: String,
        name: String,
        fileSystem: String?,
        status: String?,
        totalBytes: Int64?,
        usedBytes: Int64?,
        isEncrypted: Bool,
        isWritable: Bool,
        poolID: String? = nil,
        path: String? = nil,
        reportedEncrypted: Bool? = nil,
        reportedWritable: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.fileSystem = fileSystem
        self.status = status
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.isEncrypted = isEncrypted
        self.isWritable = isWritable
        self.poolID = poolID
        self.path = path
        self.reportedEncrypted = reportedEncrypted
        self.reportedWritable = reportedWritable
    }
}

public enum NasDiskTestType: String, CaseIterable, Equatable, Sendable {
    case quick
    case extended
}

public struct NasDiskTestStatus: Equatable, Sendable {
    public let diskID: String
    public let isRunning: Bool
    public let isBusyWithOtherTest: Bool
    public let runningType: NasDiskTestType?
    public let progressDescription: String?
    public let lastQuickTest: String?
    public let lastExtendedTest: String?
    public let lastResult: String?
    public let isHistoryAvailable: Bool

    public init(
        diskID: String,
        isRunning: Bool,
        isBusyWithOtherTest: Bool = false,
        runningType: NasDiskTestType? = nil,
        progressDescription: String? = nil,
        lastQuickTest: String? = nil,
        lastExtendedTest: String? = nil,
        lastResult: String? = nil,
        isHistoryAvailable: Bool = true
    ) {
        self.diskID = diskID
        self.isRunning = isRunning
        self.isBusyWithOtherTest = isBusyWithOtherTest
        self.runningType = runningType
        self.progressDescription = progressDescription
        self.lastQuickTest = lastQuickTest
        self.lastExtendedTest = lastExtendedTest
        self.lastResult = lastResult
        self.isHistoryAvailable = isHistoryAvailable
    }
}

public struct NasScheduledTaskResult: Identifiable, Equatable, Sendable {
    public let id: String
    public let taskName: String
    public let startedAt: Date?
    public let stoppedAt: Date?
    public let exitType: String?
    public let exitCode: Int?
    public let triggerEvent: String?

    public init(
        id: String,
        taskName: String,
        startedAt: Date?,
        stoppedAt: Date?,
        exitType: String?,
        exitCode: Int?,
        triggerEvent: String?
    ) {
        self.id = id
        self.taskName = taskName
        self.startedAt = startedAt
        self.stoppedAt = stoppedAt
        self.exitType = exitType
        self.exitCode = exitCode
        self.triggerEvent = triggerEvent
    }
}

public struct NasScheduledTaskResultOutput: Equatable, Sendable {
    public let command: String?
    public let output: String?

    public init(command: String?, output: String?) {
        self.command = command
        self.output = output
    }
}

public enum NasPackageAction: String, Sendable {
    case start
    case stop
    case uninstall
    case upgrade
}

public enum NasPowerAction: String, Sendable {
    case shutdown
    case reboot
}

public struct NasSystemUpdateInfo: Equatable, Sendable {
    public let isUpdateAvailable: Bool
    public let currentVersion: String?
    public let latestVersion: String?
    public let releaseNotes: String?

    public init(
        isUpdateAvailable: Bool,
        currentVersion: String? = nil,
        latestVersion: String? = nil,
        releaseNotes: String? = nil
    ) {
        self.isUpdateAvailable = isUpdateAvailable
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.releaseNotes = releaseNotes
    }
}

public struct NasPackage: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let version: String?
    public let status: String?
    public let statusDescription: String?
    public let packageDescription: String?
    public let installType: String?
    public let installedAt: Date?
    public let iconData: Data?
    public let canStart: Bool
    public let canStop: Bool
    public let canUninstall: Bool
    public let isUpgradeAvailable: Bool
    public let canUpgrade: Bool
    /// 只来自本次套件列表；nil 表示字段缺失或不可信，不能猜作空集合。
    public let dsmApps: [String]?

    public init(
        id: String,
        name: String,
        version: String?,
        status: String?,
        statusDescription: String?,
        packageDescription: String?,
        installType: String?,
        installedAt: Date?,
        iconData: Data? = nil,
        canStart: Bool = true,
        canStop: Bool = true,
        canUninstall: Bool = false,
        isUpgradeAvailable: Bool = false,
        canUpgrade: Bool = false,
        dsmApps: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.status = status
        self.statusDescription = statusDescription
        self.packageDescription = packageDescription
        self.installType = installType
        self.installedAt = installedAt
        self.iconData = iconData
        self.canStart = canStart
        self.canStop = canStop
        self.canUninstall = canUninstall
        self.isUpgradeAvailable = isUpgradeAvailable
        self.canUpgrade = canUpgrade
        self.dsmApps = dsmApps
    }
}

public struct NasScheduledTask: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let owner: String?
    public let realOwner: String?
    public let type: String?
    public let action: String?
    public let isEnabled: Bool
    public let isEnabledKnown: Bool
    public let nextTriggerDescription: String?
    public let canRun: Bool
    public let canEdit: Bool

    public init(
        id: String,
        name: String,
        owner: String?,
        realOwner: String? = nil,
        type: String?,
        action: String?,
        isEnabled: Bool,
        nextTriggerDescription: String?,
        canRun: Bool,
        canEdit: Bool,
        isEnabledKnown: Bool = true
    ) {
        self.id = id
        self.name = name
        self.owner = owner
        self.realOwner = realOwner
        self.type = type
        self.action = action
        self.isEnabled = isEnabled
        self.isEnabledKnown = isEnabledKnown
        self.nextTriggerDescription = nextTriggerDescription
        self.canRun = canRun
        self.canEdit = canEdit
    }
}

public struct NasTaskSchedule: Equatable, Sendable {
    public var dateType: Int
    public var weekDays: String
    public var date: String?
    public var repeatDate: Int
    public var monthlyWeek: [Int]
    public var hour: Int
    public var minute: Int
    public var repeatHour: Int
    public var repeatMinute: Int
    public var lastWorkHour: Int

    public init(
        dateType: Int = 0,
        weekDays: String = "0,1,2,3,4,5,6",
        date: String? = nil,
        repeatDate: Int = 1001,
        monthlyWeek: [Int] = [],
        hour: Int = 0,
        minute: Int = 0,
        repeatHour: Int = 0,
        repeatMinute: Int = 0,
        lastWorkHour: Int = 0
    ) {
        self.dateType = dateType
        self.weekDays = weekDays
        self.date = date
        self.repeatDate = repeatDate
        self.monthlyWeek = monthlyWeek
        self.hour = hour
        self.minute = minute
        self.repeatHour = repeatHour
        self.repeatMinute = repeatMinute
        self.lastWorkHour = lastWorkHour
    }
}

public struct NasScheduledTaskDraft: Equatable, Sendable {
    public var id: Int?
    public var name: String
    public var owner: String
    public var realOwner: String?
    public var isEnabled: Bool
    public var script: String
    public var notifyOnError: Bool
    public var notificationEmails: String
    public var schedule: NasTaskSchedule

    public init(
        id: Int? = nil,
        name: String = "",
        owner: String,
        realOwner: String? = nil,
        isEnabled: Bool = true,
        script: String = "",
        notifyOnError: Bool = false,
        notificationEmails: String = "",
        schedule: NasTaskSchedule = NasTaskSchedule()
    ) {
        self.id = id
        self.name = name
        self.owner = owner
        self.realOwner = realOwner
        self.isEnabled = isEnabled
        self.script = script
        self.notifyOnError = notifyOnError
        self.notificationEmails = notificationEmails
        self.schedule = schedule
    }
}

public struct NasAccountDirectory: Equatable, Sendable {
    public let users: [NasAccount]
    public let groups: [NasAccount]

    public init(users: [NasAccount], groups: [NasAccount]) {
        self.users = users
        self.groups = groups
    }
}

public enum NasShareAccessLevel: String, Equatable, Sendable {
    case readWrite
    case readOnly
    case unknown
}

public struct NasShareAccessEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let accessLevel: NasShareAccessLevel
    public let canDelete: Bool

    public init(
        id: String,
        name: String,
        accessLevel: NasShareAccessLevel,
        canDelete: Bool
    ) {
        self.id = id
        self.name = name
        self.accessLevel = accessLevel
        self.canDelete = canDelete
    }
}

public struct NasShareAccessDirectory: Equatable, Sendable {
    public let shares: [NasShareAccessEntry]

    public init(shares: [NasShareAccessEntry]) {
        self.shares = shares
    }
}

public protocol NasShareAccessRepository: Sendable {
    func loadShareAccess() async throws -> NasShareAccessDirectory
}

public struct NasAccount: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        case user
        case group
    }

    public let id: String
    public let name: String
    public let kind: Kind
    public let numericID: Int64?
    public let description: String?
    public let email: String?
    public let groups: [String]?
    public let isExpired: Bool
    public let canEdit: Bool
    public let canDelete: Bool

    public init(
        id: String,
        name: String,
        kind: Kind,
        numericID: Int64?,
        description: String?,
        email: String? = nil,
        groups: [String]? = nil,
        isExpired: Bool = false,
        canEdit: Bool = false,
        canDelete: Bool = false
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.numericID = numericID
        self.description = description
        self.email = email
        self.groups = groups
        self.isExpired = isExpired
        self.canEdit = canEdit
        self.canDelete = canDelete
    }
}

public struct NasAccountDraft: Equatable, Sendable {
    public let originalName: String?
    public var name: String
    public var description: String
    public var email: String
    public var isExpired: Bool
    public var groups: [String]?
    public var password: String
    public var passwordConfirmation: String

    public init(
        originalName: String? = nil,
        name: String = "",
        description: String = "",
        email: String = "",
        isExpired: Bool = false,
        groups: [String]? = nil,
        password: String = "",
        passwordConfirmation: String = ""
    ) {
        self.originalName = originalName
        self.name = name
        self.description = description
        self.email = email
        self.isExpired = isExpired
        self.groups = groups
        self.password = password
        self.passwordConfirmation = passwordConfirmation
    }
}

public struct NasGroupDraft: Equatable, Sendable {
    public let originalName: String?
    public var name: String
    public var description: String

    public init(
        originalName: String? = nil,
        name: String = "",
        description: String = ""
    ) {
        self.originalName = originalName
        self.name = name
        self.description = description
    }
}

public struct NasLogPage: Equatable, Sendable {
    public let entries: [NasLogEntry]
    public let total: Int
    public let isTotalKnown: Bool
    public let infoCount: Int?
    public let warningCount: Int?
    public let errorCount: Int?

    public init(
        entries: [NasLogEntry],
        total: Int,
        infoCount: Int?,
        warningCount: Int?,
        errorCount: Int?,
        isTotalKnown: Bool = true
    ) {
        self.entries = entries
        self.total = total
        self.isTotalKnown = isTotalKnown
        self.infoCount = infoCount
        self.warningCount = warningCount
        self.errorCount = errorCount
    }
}

public struct NasLogEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date?
    public let source: String?
    public let level: String?
    public let account: String?
    public let message: String

    public init(
        id: String,
        date: Date?,
        source: String?,
        level: String?,
        account: String?,
        message: String
    ) {
        self.id = id
        self.date = date
        self.source = source
        self.level = level
        self.account = account
        self.message = message
    }
}

/// 系统进程只读目录。命令行、路径、账号与网络地址不得进入领域模型。
public struct NasProcessDirectory: Equatable, Sendable {
    public let processes: [NasSystemProcess]
    public let groups: [NasProcessGroup]
    public let total: Int
    public let isTruncated: Bool
    public let groupsAreUnavailable: Bool

    public init(
        processes: [NasSystemProcess],
        groups: [NasProcessGroup],
        total: Int,
        isTruncated: Bool,
        groupsAreUnavailable: Bool
    ) {
        self.processes = processes
        self.groups = groups
        self.total = total
        self.isTruncated = isTruncated
        self.groupsAreUnavailable = groupsAreUnavailable
    }
}

public struct NasSystemProcess: Identifiable, Equatable, Sendable {
    public let id: String
    public let processID: String
    public let name: String
    public let status: String?
    public let groupID: String?

    public init(
        id: String,
        processID: String,
        name: String,
        status: String?,
        groupID: String?
    ) {
        self.id = id
        self.processID = processID
        self.name = name
        self.status = status
        self.groupID = groupID
    }
}

public struct NasProcessGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let status: String?
    public let processCount: Int?

    public init(
        id: String,
        name: String,
        status: String?,
        processCount: Int?
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.processCount = processCount
    }
}

/// 电源计划快照。只有完整的开关机清单允许整体保存。
public struct NasPowerScheduleSnapshot: Equatable, Sendable {
    public let entries: [NasPowerScheduleEntry]
    public let timeZoneIdentifier: String?
    public let total: Int
    public let isTruncated: Bool
    public let supportsEditing: Bool

    public init(
        entries: [NasPowerScheduleEntry],
        timeZoneIdentifier: String?,
        total: Int,
        isTruncated: Bool,
        supportsEditing: Bool = false
    ) {
        self.entries = entries
        self.timeZoneIdentifier = timeZoneIdentifier
        self.total = total
        self.isTruncated = isTruncated
        self.supportsEditing = supportsEditing
    }
}

public struct NasPowerScheduleEntry: Identifiable, Equatable, Sendable {
    public let id: String
    public let action: NasPowerScheduleAction
    public let isEnabled: Bool?
    public let hour: Int
    public let minute: Int
    public let recurrence: NasPowerScheduleRecurrence

    public init(
        id: String,
        action: NasPowerScheduleAction,
        isEnabled: Bool?,
        hour: Int,
        minute: Int,
        recurrence: NasPowerScheduleRecurrence
    ) {
        self.id = id
        self.action = action
        self.isEnabled = isEnabled
        self.hour = hour
        self.minute = minute
        self.recurrence = recurrence
    }
}

public enum NasPowerScheduleAction: Equatable, Sendable {
    case startup
    case shutdown
    case restart
    case unknown
}

public enum NasPowerScheduleRecurrence: Equatable, Sendable {
    case daily
    case weekly([NasWeekday])
    case once(NasPowerScheduleDate)
    case unknown
}

public enum NasWeekday: Int, CaseIterable, Equatable, Sendable {
    case monday = 1
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday
}

public struct NasPowerScheduleDate: Equatable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }
}

/// 外接存储只读目录。设备路径、挂载路径、共享名和序列号不得进入领域模型。
public struct NasExternalStorageDirectory: Equatable, Sendable {
    public let devices: [NasExternalStorageDevice]
    public let total: Int
    public let isTruncated: Bool
    public let unavailableConnections: [NasExternalStorageConnection]

    public init(
        devices: [NasExternalStorageDevice],
        total: Int,
        isTruncated: Bool,
        unavailableConnections: [NasExternalStorageConnection]
    ) {
        self.devices = devices
        self.total = total
        self.isTruncated = isTruncated
        self.unavailableConnections = unavailableConnections
    }
}

public struct NasExternalStorageDevice: Identifiable, Equatable, Sendable {
    public let id: String
    public let displayName: String?
    public let connection: NasExternalStorageConnection
    public let status: NasExternalStorageStatus
    public let capacityBytes: Int64?
    public let usedBytes: Int64?

    public init(
        id: String,
        displayName: String?,
        connection: NasExternalStorageConnection,
        status: NasExternalStorageStatus,
        capacityBytes: Int64?,
        usedBytes: Int64?
    ) {
        self.id = id
        self.displayName = displayName
        self.connection = connection
        self.status = status
        self.capacityBytes = capacityBytes
        self.usedBytes = usedBytes
    }
}

public enum NasExternalStorageConnection: String, CaseIterable, Equatable, Sendable {
    case usb
    case eSATA
}

public enum NasExternalStorageStatus: Equatable, Sendable {
    case ready
    case busy
    case unavailable
    case unknown
}

/// ZRAM 只读摘要。原始内核参数和设备节点不得进入领域模型。
public struct NasZRAMSnapshot: Equatable, Sendable {
    public let isEnabled: Bool?
    public let configuredBytes: Int64?
    public let algorithm: NasZRAMAlgorithm

    public init(
        isEnabled: Bool?,
        configuredBytes: Int64?,
        algorithm: NasZRAMAlgorithm
    ) {
        self.isEnabled = isEnabled
        self.configuredBytes = configuredBytes
        self.algorithm = algorithm
    }
}

public enum NasZRAMAlgorithm: Equatable, Sendable {
    case lz4
    case lzo
    case zstd
    case unknown
}

public struct NasConnectionPage: Equatable, Sendable {
    public let connections: [NasConnection]
    public let total: Int

    public init(connections: [NasConnection], total: Int) {
        self.connections = connections
        self.total = total
    }
}

public struct NasConnection: Identifiable, Equatable, Sendable {
    public let id: String
    public let processID: String?
    public let deviceID: String?
    public let account: String
    public let source: String?
    public let location: String?
    public let protocolName: String?
    public let type: String?
    public let connectedAt: Date?
    public let description: String?
    public let isCurrentConnection: Bool
    public let canDisconnect: Bool

    public init(
        id: String,
        processID: String? = nil,
        deviceID: String? = nil,
        account: String,
        source: String?,
        location: String?,
        protocolName: String?,
        type: String?,
        connectedAt: Date?,
        description: String?,
        isCurrentConnection: Bool,
        canDisconnect: Bool = false
    ) {
        self.id = id
        self.processID = processID
        self.deviceID = deviceID
        self.account = account
        self.source = source
        self.location = location
        self.protocolName = protocolName
        self.type = type
        self.connectedAt = connectedAt
        self.description = description
        self.isCurrentConnection = isCurrentConnection
        self.canDisconnect = canDisconnect
    }
}

/// NAS 文件共享服务设置。`nil` 表示当前 NAS 未提供对应能力，不能展示为可修改。
public struct NasFileServiceSettings: Hashable, Sendable {
    public var isSMBEnabled: Bool?
    public var isNFSEnabled: Bool?
    public var isFTPEnabled: Bool?
    public var isFTPSEnabled: Bool?
    public var ftpPort: Int?
    public var isSFTPEnabled: Bool?
    public var sftpPort: Int?
    public var isSSDPEnabled: Bool?
    public var isBonjourEnabled: Bool?
    public var isSMBTimeMachineEnabled: Bool?

    public init(
        isSMBEnabled: Bool?,
        isNFSEnabled: Bool?,
        isFTPEnabled: Bool?,
        isFTPSEnabled: Bool?,
        ftpPort: Int?,
        isSFTPEnabled: Bool?,
        sftpPort: Int?,
        isSSDPEnabled: Bool? = nil,
        isBonjourEnabled: Bool? = nil,
        isSMBTimeMachineEnabled: Bool? = nil
    ) {
        self.isSMBEnabled = isSMBEnabled
        self.isNFSEnabled = isNFSEnabled
        self.isFTPEnabled = isFTPEnabled
        self.isFTPSEnabled = isFTPSEnabled
        self.ftpPort = ftpPort
        self.isSFTPEnabled = isSFTPEnabled
        self.sftpPort = sftpPort
        self.isSSDPEnabled = isSSDPEnabled
        self.isBonjourEnabled = isBonjourEnabled
        self.isSMBTimeMachineEnabled = isSMBTimeMachineEnabled
    }
}

/// NAS 远程终端设置。端口只有在当前设备返回有效值时才允许修改。
public struct NasTerminalSettings: Hashable, Sendable {
    public var isSSHEnabled: Bool
    public var isTelnetEnabled: Bool
    public var sshPort: Int?

    public init(isSSHEnabled: Bool, isTelnetEnabled: Bool, sshPort: Int?) {
        self.isSSHEnabled = isSSHEnabled
        self.isTelnetEnabled = isTelnetEnabled
        self.sshPort = sshPort
    }
}

/// NAS 访问互联网时使用的代理设置。密码不会从 NAS 读取或保存在客户端。
public struct NasProxySettings: Hashable, Sendable {
    public var isEnabled: Bool
    public var host: String
    public var port: Int?

    public init(isEnabled: Bool, host: String, port: Int?) {
        self.isEnabled = isEnabled
        self.host = host
        self.port = port
    }

    public var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValidForSaving: Bool {
        guard isEnabled else { return true }
        return Self.isValidHost(normalizedHost)
            && port.map { (1...65_535).contains($0) } == true
    }

    /// 代理地址只接受主机名或 IP，不接受协议、路径、用户信息或空白。
    public static func isValidHost(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet(charactersIn: "/?#@")
            .union(.whitespacesAndNewlines)
        return !normalized.isEmpty
            && normalized.rangeOfCharacter(from: forbidden) == nil
            && !normalized.contains("://")
    }
}

public struct NasEthernetInterface: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let status: String?
    public var usesDHCP: Bool
    public var address: String
    public var subnetMask: String
    public var gateway: String
    public var dnsServers: String
    public var isDefaultGateway: Bool
    public var mtu: Int
    public var isVLANEnabled: Bool
    public var vlanID: Int?

    public init(
        id: String,
        displayName: String,
        status: String?,
        usesDHCP: Bool,
        address: String,
        subnetMask: String,
        gateway: String,
        dnsServers: String,
        isDefaultGateway: Bool,
        mtu: Int,
        isVLANEnabled: Bool,
        vlanID: Int?
    ) {
        self.id = id
        self.displayName = displayName
        self.status = status
        self.usesDHCP = usesDHCP
        self.address = address
        self.subnetMask = subnetMask
        self.gateway = gateway
        self.dnsServers = dnsServers
        self.isDefaultGateway = isDefaultGateway
        self.mtu = mtu
        self.isVLANEnabled = isVLANEnabled
        self.vlanID = vlanID
    }
}

/// 当前设备实际提供的基础硬件设置。
public struct NasUPSSettings: Hashable, Sendable {
    public var isEnabled: Bool
    public var mode: String
    public var safeModeDelaySeconds: Int?
    public var waitsUntilLowBattery: Bool?
    public var shutsDownUPSAfterSafeMode: Bool?
    public var networkServerAddress: String?
    public var snmpServerAddress: String?

    public init(
        isEnabled: Bool,
        mode: String,
        safeModeDelaySeconds: Int?,
        waitsUntilLowBattery: Bool?,
        shutsDownUPSAfterSafeMode: Bool?,
        networkServerAddress: String?,
        snmpServerAddress: String?
    ) {
        self.isEnabled = isEnabled
        self.mode = mode
        self.safeModeDelaySeconds = safeModeDelaySeconds
        self.waitsUntilLowBattery = waitsUntilLowBattery
        self.shutsDownUPSAfterSafeMode = shutsDownUPSAfterSafeMode
        self.networkServerAddress = networkServerAddress
        self.snmpServerAddress = snmpServerAddress
    }
}

public struct NasHardwareSettings: Hashable, Sendable {
    public var restartsAfterPowerFailure: Bool?
    public var ledBrightness: Int?
    public let ledBrightnessRange: ClosedRange<Int>?
    public var fanMode: String?
    /// 设备明确支持的模式；nil 表示旧响应未提供模式范围。
    public let supportedFanModes: [String]?
    public var isFanFailureAlertEnabled: Bool?
    public var isVolumeFailureAlertEnabled: Bool?
    public var isPowerOnSoundEnabled: Bool?
    public var isPowerOffSoundEnabled: Bool?
    public var isResetSoundEnabled: Bool?
    public var isExternalDriveDeepSleepEnabled: Bool?
    public var isWakeUpLogEnabled: Bool?
    public var isSATASleepEnabled: Bool?
    public var ignoresNetworkDiscoveryDuringSleep: Bool?
    public var isAutomaticPowerOffEnabled: Bool?
    public var ups: NasUPSSettings?

    public init(
        restartsAfterPowerFailure: Bool?,
        ledBrightness: Int?,
        ledBrightnessRange: ClosedRange<Int>?,
        fanMode: String? = nil,
        isFanFailureAlertEnabled: Bool? = nil,
        isVolumeFailureAlertEnabled: Bool? = nil,
        isPowerOnSoundEnabled: Bool? = nil,
        isPowerOffSoundEnabled: Bool? = nil,
        isResetSoundEnabled: Bool? = nil,
        isExternalDriveDeepSleepEnabled: Bool? = nil,
        isWakeUpLogEnabled: Bool? = nil,
        isSATASleepEnabled: Bool? = nil,
        ignoresNetworkDiscoveryDuringSleep: Bool? = nil,
        isAutomaticPowerOffEnabled: Bool? = nil,
        ups: NasUPSSettings? = nil,
        supportedFanModes: [String]? = nil
    ) {
        self.restartsAfterPowerFailure = restartsAfterPowerFailure
        self.ledBrightness = ledBrightness
        self.ledBrightnessRange = ledBrightnessRange
        self.fanMode = fanMode
        self.supportedFanModes = supportedFanModes
        self.isFanFailureAlertEnabled = isFanFailureAlertEnabled
        self.isVolumeFailureAlertEnabled = isVolumeFailureAlertEnabled
        self.isPowerOnSoundEnabled = isPowerOnSoundEnabled
        self.isPowerOffSoundEnabled = isPowerOffSoundEnabled
        self.isResetSoundEnabled = isResetSoundEnabled
        self.isExternalDriveDeepSleepEnabled = isExternalDriveDeepSleepEnabled
        self.isWakeUpLogEnabled = isWakeUpLogEnabled
        self.isSATASleepEnabled = isSATASleepEnabled
        self.ignoresNetworkDiscoveryDuringSleep = ignoresNetworkDiscoveryDuringSleep
        self.isAutomaticPowerOffEnabled = isAutomaticPowerOffEnabled
        self.ups = ups
    }
}

/// QuickConnect 远程访问设置。`nil` 表示当前设备未提供对应能力。
public struct NasRemoteAccessSettings: Hashable, Sendable {
    public var isRelayEnabled: Bool?
    public var isRouterConfigurationEnabled: Bool?
    public let canDisableRelay: Bool
    /// 单项读取失败与接口/字段未提供分开；旧调用默认不使用这些管理提示。
    public let relayReadFailed: Bool
    public let routerConfigurationReadFailed: Bool

    public init(
        isRelayEnabled: Bool?,
        isRouterConfigurationEnabled: Bool?,
        canDisableRelay: Bool,
        relayReadFailed: Bool = false,
        routerConfigurationReadFailed: Bool = false
    ) {
        self.isRelayEnabled = isRelayEnabled
        self.isRouterConfigurationEnabled = isRouterConfigurationEnabled
        self.canDisableRelay = canDisableRelay
        self.relayReadFailed = relayReadFailed
        self.routerConfigurationReadFailed = routerConfigurationReadFailed
    }
}

/// 登录失败自动封锁设置。
public struct NasDoSProtectionSetting: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public var isEnabled: Bool

    public init(id: String, displayName: String, isEnabled: Bool) {
        self.id = id
        self.displayName = displayName
        self.isEnabled = isEnabled
    }
}

public struct NasSecuritySettings: Hashable, Sendable {
    public var isAutoBlockEnabled: Bool
    public var failedAttempts: Int
    public var withinMinutes: Int
    /// `nil` 表示封锁不会自动过期。
    public var expirationDays: Int?
    public var dosProtection: [NasDoSProtectionSetting]
    public var isFirewallEnabled: Bool?
    public var firewallProfileName: String?
    /// 历史属性名保留兼容；实际对应 DSM 的防火墙通知 enable_port_check。
    public var isPortScanProtectionEnabled: Bool?

    public init(
        isAutoBlockEnabled: Bool,
        failedAttempts: Int,
        withinMinutes: Int,
        expirationDays: Int?,
        dosProtection: [NasDoSProtectionSetting] = [],
        isFirewallEnabled: Bool? = nil,
        firewallProfileName: String? = nil,
        isPortScanProtectionEnabled: Bool? = nil
    ) {
        self.isAutoBlockEnabled = isAutoBlockEnabled
        self.failedAttempts = failedAttempts
        self.withinMinutes = withinMinutes
        self.expirationDays = expirationDays
        self.dosProtection = dosProtection
        self.isFirewallEnabled = isFirewallEnabled
        self.firewallProfileName = firewallProfileName
        self.isPortScanProtectionEnabled = isPortScanProtectionEnabled
    }
}

/// NAS 区域与网络校时设置。时区选项只使用设备实际返回的值。
public struct NasTimeZoneOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct NasRegionSettings: Hashable, Sendable {
    public var dateFormat: String
    public var timeFormat: String
    public var timeZone: String
    public var isNetworkTimeEnabled: Bool
    public var timeServers: [String]
    public var manualDate: Date?
    public let timeZones: [NasTimeZoneOption]

    public init(
        dateFormat: String,
        timeFormat: String,
        timeZone: String,
        isNetworkTimeEnabled: Bool,
        timeServers: [String],
        manualDate: Date?,
        timeZones: [NasTimeZoneOption]
    ) {
        self.dateFormat = dateFormat
        self.timeFormat = timeFormat
        self.timeZone = timeZone
        self.isNetworkTimeEnabled = isNetworkTimeEnabled
        self.timeServers = timeServers
        self.manualDate = manualDate
        self.timeZones = timeZones
    }

    public var normalizedDateFormat: String {
        dateFormat.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedTimeFormat: String {
        timeFormat.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedTimeServers: [String] {
        timeServers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public var isValidForSaving: Bool {
        guard !normalizedDateFormat.isEmpty,
              !normalizedTimeFormat.isEmpty,
              timeZones.contains(where: { $0.id == timeZone }) else {
            return false
        }
        if isNetworkTimeEnabled {
            let servers = normalizedTimeServers
            return !servers.isEmpty
                && servers.count <= 3
                && servers.allSatisfy(Self.isValidTimeServer)
        }
        return manualDate != nil
    }

    /// 时间服务器只接受主机名或 IP，不接受协议、路径、用户信息或空白。
    public static func isValidTimeServer(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= 253, !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(
                      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-:"
                  ).contains($0)
              }) else {
            return false
        }
        return !normalized.hasPrefix(".")
            && !normalized.hasSuffix(".")
            && !normalized.contains("..")
    }
}

public struct NasDDNSProvider: Identifiable, Hashable, Sendable {
    public let id: String
    public let displayName: String

    public init(id: String, displayName: String) {
        self.id = id
        self.displayName = displayName
    }
}

public struct NasDDNSRecord: Identifiable, Hashable, Sendable {
    public let id: String
    public let providerID: String
    public let providerName: String
    public let hostname: String
    public let address: String?
    public let status: String?
    public let lastUpdated: String?
    public let isEnabled: Bool
    public let username: String?
    public let networkType: String?
    public let ipv4: String?
    public let ipv6: String?
    public let interfaceV4: String?
    public let interfaceV6: String?
    public let heartbeat: Bool

    public init(
        id: String,
        providerID: String,
        providerName: String,
        hostname: String,
        address: String?,
        status: String?,
        lastUpdated: String?,
        isEnabled: Bool,
        username: String?,
        networkType: String?,
        ipv4: String?,
        ipv6: String?,
        interfaceV4: String?,
        interfaceV6: String?,
        heartbeat: Bool
    ) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.hostname = hostname
        self.address = address
        self.status = status
        self.lastUpdated = lastUpdated
        self.isEnabled = isEnabled
        self.username = username
        self.networkType = networkType
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.interfaceV4 = interfaceV4
        self.interfaceV6 = interfaceV6
        self.heartbeat = heartbeat
    }
}

public struct NasDDNSDirectory: Hashable, Sendable {
    public let providers: [NasDDNSProvider]
    public let records: [NasDDNSRecord]

    public init(providers: [NasDDNSProvider], records: [NasDDNSRecord]) {
        self.providers = providers
        self.records = records
    }
}

/// DDNS 密码只用于本次提交，客户端不会从 NAS 读取或持久化。
public struct NasDDNSDraft: Hashable, Sendable {
    public var originalProviderID: String?
    public var providerID: String
    public var hostname: String
    public var username: String
    public var password: String
    public var isEnabled: Bool
    public var networkType: String
    public var ipv4: String
    public var ipv6: String
    public var interfaceV4: String
    public var interfaceV6: String
    public var heartbeat: Bool

    public init(
        originalProviderID: String? = nil,
        providerID: String,
        hostname: String,
        username: String,
        password: String = "",
        isEnabled: Bool = true,
        networkType: String = "auto",
        ipv4: String = "0.0.0.0",
        ipv6: String = "0:0:0:0:0:0:0:0",
        interfaceV4: String = "",
        interfaceV6: String = "",
        heartbeat: Bool = false
    ) {
        self.originalProviderID = originalProviderID
        self.providerID = providerID
        self.hostname = hostname
        self.username = username
        self.password = password
        self.isEnabled = isEnabled
        self.networkType = networkType
        self.ipv4 = ipv4
        self.ipv6 = ipv6
        self.interfaceV4 = interfaceV4
        self.interfaceV6 = interfaceV6
        self.heartbeat = heartbeat
    }

    public var normalizedProviderID: String {
        providerID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var normalizedHostname: String {
        hostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public var normalizedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValidForSubmission: Bool {
        !normalizedProviderID.isEmpty
            && Self.isValidHostname(normalizedHostname)
            && !normalizedUsername.isEmpty
            && (originalProviderID != nil
                || normalizedProviderID == "Synology"
                || !password.isEmpty)
    }

    /// DDNS 主机名不接受协议、路径、用户信息、端口或空白。
    public static func isValidHostname(_ value: String) -> Bool {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count <= 253, !normalized.isEmpty,
              normalized.unicodeScalars.allSatisfy({
                  CharacterSet(
                      charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-"
                  ).contains($0)
              }) else {
            return false
        }
        return !normalized.hasPrefix(".")
            && !normalized.hasSuffix(".")
            && !normalized.contains("..")
    }
}

/// NAS 设置主要使用 DSM 内部接口。写操作必须先完成能力、权限与目标状态检查。
public protocol NasSettingsRepository: Sendable {
    func loadSystemOverview() async throws -> NasSystemOverview
    func loadPerformanceSnapshot() async throws -> NasPerformanceSnapshot
    func loadStorage() async throws -> NasStorageSnapshot
    func loadDiskTestStatus(diskID: String) async throws -> NasDiskTestStatus
    func loadDiskTestStatus(disk: NasDisk) async throws -> NasDiskTestStatus
    func startDiskTest(diskID: String, type: NasDiskTestType) async throws -> NasDiskTestStatus
    func stopDiskTest(diskID: String) async throws -> NasDiskTestStatus
    func startDiskTestResult(
        diskID: String,
        type: NasDiskTestType
    ) async throws -> MutationResult
    func stopDiskTestResult(diskID: String) async throws -> MutationResult
    func changeDiskTestResult(
        _ change: NasDiskTestChange,
        beforeSubmission: @escaping @Sendable () async throws -> Void
    ) async throws -> MutationResult
    func loadPackages() async throws -> [NasPackage]
    func loadPackageCatalog() async throws -> NasPackageCatalog
    func loadPackageCatalogForManagement() async throws -> NasPackageCatalog
    func loadPackagesForManagement() async throws -> [NasPackage]
    func preparePackageInstallationForManagement(catalogIDs: [String]) async throws -> NasPackageInstallPlan
    func loadPackageCenterSettings() async throws -> NasPackageCenterSettings
    func savePackageCenterSettings(_ settings: NasPackageCenterSettings, replacing baseline: NasPackageCenterSettings) async throws -> NasPackageCenterSettings
    func loadPackageSources() async throws -> [NasPackageSource]
    func savePackageSource(_ source: NasPackageSource, replacing baseline: NasPackageSource?) async throws -> [NasPackageSource]
    func deletePackageSource(_ source: NasPackageSource) async throws -> [NasPackageSource]
    func preparePackageInstallation(catalogIDs: [String]) async throws -> NasPackageInstallPlan
    func startPackageInstallation(planID: UUID, volumes: [String: String], startAfterInstall: Bool) async throws -> NasPackageInstallProgress
    func startPackageInstallation(planID: UUID, volumes: [String: String], startAfterInstall: Bool, checkpoint: @escaping NasPackageInstallationObserver) async throws -> NasPackageInstallProgress
    func advancePackageInstallation(id: UUID) async throws -> NasPackageInstallProgress
    func configurePackageInstallation(id: UUID, volumeID: String, startAfterInstall: Bool, licenseAccepted: Bool, values: [String: NasPackageOptionValue]) async throws -> NasPackageInstallProgress
    func cancelPackageInstallation(id: UUID) async throws -> NasPackageInstallProgress
    func uploadPackageForInstallation(fileURL: URL) async throws -> NasPackageInstallProgress
    func uploadPackageForInstallation(fileURL: URL, checkpoint: @escaping NasPackageInstallationObserver) async throws -> NasPackageInstallProgress
    func loadScheduledTasks() async throws -> [NasScheduledTask]
    func loadScheduledTaskDraft(id: Int?, realOwner: String?) async throws -> NasScheduledTaskDraft
    func loadScheduledTaskResults(taskName: String) async throws -> [NasScheduledTaskResult]
    func loadScheduledTaskResultOutput(
        taskName: String,
        resultID: String
    ) async throws -> NasScheduledTaskResultOutput
    func saveScheduledTask(_ draft: NasScheduledTaskDraft) async throws
    func setScheduledTaskEnabled(id: Int, realOwner: String?, enabled: Bool) async throws
    func runScheduledTask(id: Int, realOwner: String?) async throws
    func deleteScheduledTask(id: Int, realOwner: String?) async throws
    func loadAccountsAndGroups() async throws -> NasAccountDirectory
    func loadAccountDirectoryForManagement() async throws -> NasAccountDirectory
    func changeDirectoryResult(_ change: NasDirectoryChange, checkpoint: @escaping @Sendable (NasDirectoryCheckpoint) async throws -> Void) async throws -> MutationResult
    func saveAccount(_ draft: NasAccountDraft) async throws
    func deleteAccount(name: String) async throws
    func deleteAccountResult(name: String) async throws -> MutationResult
    func saveGroup(_ draft: NasGroupDraft) async throws
    func deleteGroup(name: String) async throws
    func deleteGroupResult(name: String) async throws -> MutationResult
    func loadLogs(offset: Int, limit: Int) async throws -> NasLogPage
    func loadSystemProcesses(start: Int, limit: Int) async throws -> NasProcessDirectory
    func loadConnections(offset: Int, limit: Int) async throws -> NasConnectionPage
    func disconnectConnection(_ connection: NasConnection) async throws
    func loadConnectionsForManagement() async throws -> NasConnectionPage
    func performSystemActionResult(_ action: NasSystemAction, checkpoint: @escaping @Sendable (NasSystemActionCheckpoint) async throws -> Void) async throws -> MutationResult
    func verifyPowerConnection() async throws
    func loadPackagePreferencesForManagement() async throws -> NasPackagePreferencesSnapshot
    func loadPackageSourcesForManagement() async throws -> [NasPackageSource]
    func changePackagePreferencesResult(_ change: NasPackagePreferenceChange, checkpoint: @escaping @Sendable (NasPackagePreferenceCheckpoint) async throws -> Void) async throws -> MutationResult
    func loadServiceForManagement(_ kind: NasServiceKind) async throws -> NasServiceSettings
    func changeServiceResult(_ change: NasServiceChange, checkpoint: @escaping @Sendable (NasServiceCheckpoint) async throws -> Void) async throws -> MutationResult
    func loadFileServiceSettings() async throws -> NasFileServiceSettings
    func saveFileServiceSettings(_ settings: NasFileServiceSettings) async throws
    func saveFileServiceSettingsResult(
        _ settings: NasFileServiceSettings
    ) async throws -> MutationResult
    func loadTerminalSettings() async throws -> NasTerminalSettings
    func saveTerminalSettings(_ settings: NasTerminalSettings) async throws
    func saveTerminalSettingsResult(
        _ settings: NasTerminalSettings
    ) async throws -> MutationResult
    func loadProxySettings() async throws -> NasProxySettings
    func saveProxySettings(_ settings: NasProxySettings) async throws
    func saveProxySettingsResult(
        _ settings: NasProxySettings
    ) async throws -> MutationResult
    func loadEthernetInterfaces() async throws -> [NasEthernetInterface]
    func saveEthernetInterface(_ interface: NasEthernetInterface) async throws
    func saveEthernetInterfaceResult(
        _ interface: NasEthernetInterface
    ) async throws -> MutationResult
    func loadHardwareSettings() async throws -> NasHardwareSettings
    func loadPowerSchedule() async throws -> NasPowerScheduleSnapshot
    func savePowerScheduleResult(_ entries: [NasPowerScheduleEntry], replacing baseline: NasPowerScheduleSnapshot) async throws -> MutationResult
    func loadExternalStorage() async throws -> NasExternalStorageDirectory
    func loadZRAM() async throws -> NasZRAMSnapshot
    func saveZRAMResult(enabled: Bool, replacing baseline: NasZRAMSnapshot) async throws -> MutationResult
    func saveHardwareSettings(_ settings: NasHardwareSettings) async throws
    func saveHardwareSettingsResult(
        _ settings: NasHardwareSettings
    ) async throws -> MutationResult
    func loadRemoteAccessSettings() async throws -> NasRemoteAccessSettings
    func saveRemoteAccessSettings(_ settings: NasRemoteAccessSettings) async throws
    func saveRemoteAccessSettingsResult(
        _ settings: NasRemoteAccessSettings
    ) async throws -> MutationResult
    func loadSecuritySettings() async throws -> NasSecuritySettings
    func saveSecuritySettings(_ settings: NasSecuritySettings) async throws
    func saveSecuritySettingsResult(
        _ settings: NasSecuritySettings
    ) async throws -> MutationResult
    func loadRegionSettings() async throws -> NasRegionSettings
    func loadRegionForManagement() async throws -> NasRegionSettings
    func changeRegionResult(_ change: NasRegionChange,
                            checkpoint: @escaping @Sendable (NasRegionCheckpoint) async throws -> Void) async throws -> MutationResult
    func saveRegionSettings(_ settings: NasRegionSettings) async throws
    func saveRegionSettingsResult(
        _ settings: NasRegionSettings
    ) async throws -> MutationResult
    func loadDDNS() async throws -> NasDDNSDirectory
    func loadDDNSForManagement() async throws -> NasDDNSDirectory
    func changeDDNSResult(_ change: NasDDNSChange,
                          checkpoint: @escaping @Sendable (NasDDNSCheckpoint) async throws -> Void) async throws -> MutationResult
    func testDDNSResult(_ draft: NasDDNSDraft) async throws -> MutationResult
    func saveDDNS(_ draft: NasDDNSDraft) async throws
    func saveDDNSResult(_ draft: NasDDNSDraft) async throws -> MutationResult
    func deleteDDNS(providerID: String) async throws
    func deleteDDNSResult(providerID: String) async throws -> MutationResult
    func refreshDDNS() async throws
    func refreshDDNSResult() async throws -> MutationResult
    func controlPackage(id: String, action: NasPackageAction) async throws
    func controlPackageResult(
        id: String,
        action: NasPackageAction
    ) async throws -> MutationResult
    func uninstallPackageResult(id: String) async throws -> MutationResult
    func performPowerAction(_ action: NasPowerAction) async throws
    func performPowerActionResult(
        _ action: NasPowerAction
    ) async throws -> MutationResult
    func checkSystemUpdate() async throws -> NasSystemUpdateInfo
}

public extension NasSettingsRepository {
    func loadServiceForManagement(_ kind: NasServiceKind) async throws -> NasServiceSettings { throw unsupportedManagementOperation() }
    func changeServiceResult(_ change: NasServiceChange, checkpoint: @escaping @Sendable (NasServiceCheckpoint) async throws -> Void) async throws -> MutationResult { throw unsupportedManagementOperation() }
    func savePowerScheduleResult(_ entries: [NasPowerScheduleEntry], replacing baseline: NasPowerScheduleSnapshot) async throws -> MutationResult {
        throw unsupportedManagementOperation()
    }

    func saveZRAMResult(enabled: Bool, replacing baseline: NasZRAMSnapshot) async throws -> MutationResult {
        throw unsupportedManagementOperation()
    }

    func loadSystemProcesses(start: Int, limit: Int) async throws -> NasProcessDirectory {
        throw unsupportedManagementOperation()
    }

    func loadDiskTestStatus(diskID: String) async throws -> NasDiskTestStatus {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.dfb40c98654f42a7")
        )
    }
    func loadDiskTestStatus(disk: NasDisk) async throws -> NasDiskTestStatus {
        throw AppError(category: .apiUnavailable, isRetryable: false,
                       safeUserMessage: L10n.string("storage.disk-test.start.unsupported"))
    }
    func startDiskTest(
        diskID: String,
        type: NasDiskTestType
    ) async throws -> NasDiskTestStatus {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.8f8772f1d7a97b10")
        )
    }
    func stopDiskTest(diskID: String) async throws -> NasDiskTestStatus {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.0863df49f654262b")
        )
    }
    func startDiskTestResult(
        diskID: String,
        type: NasDiskTestType
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "diskTestStart",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "storage.disk-test.start.unsupported",
            diagnosticTag: "storage.disk-test.start.unsupported"
        )
    }
    func stopDiskTestResult(diskID: String) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "diskTestStop",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "storage.disk-test.stop.unsupported",
            diagnosticTag: "storage.disk-test.stop.unsupported"
        )
    }
    func changeDiskTestResult(
        _ change: NasDiskTestChange,
        beforeSubmission: @escaping @Sendable () async throws -> Void
    ) async throws -> MutationResult {
        throw AppError(category: .apiUnavailable, isRetryable: false,
                       safeUserMessage: L10n.string("storage.disk-test.start.unsupported"))
    }
    func controlPackage(id: String, action: NasPackageAction) async throws {
        throw unsupportedManagementOperation()
    }
    func controlPackageResult(
        id: String,
        action: NasPackageAction
    ) async throws -> MutationResult {
        if action == .uninstall {
            return try await uninstallPackageResult(id: id)
        }
        let operation: String
        let prefix: String
        switch action {
        case .start:
            operation = "packageStart"
            prefix = "package.start"
        case .stop:
            operation = "packageStop"
            prefix = "package.stop"
        case .uninstall:
            operation = "packageUninstall"
            prefix = "package.uninstall"
        case .upgrade:
            operation = "packageUpgrade"
            prefix = "package.upgrade"
        }
        return try MutationResult(
            status: .unsupported,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "\(prefix).unsupported",
            diagnosticTag: "\(prefix).unsupported"
        )
    }
    func uninstallPackageResult(id: String) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "packageUninstall",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "package.uninstall.unsupported",
            diagnosticTag: "package.uninstall.unsupported"
        )
    }
    func loadScheduledTaskDraft(id: Int?, realOwner: String?) async throws -> NasScheduledTaskDraft {
        throw AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.f305c4e6f6daf1fa")
        )
    }
    func loadScheduledTaskResults(taskName: String) async throws -> [NasScheduledTaskResult] {
        throw unsupportedManagementOperation()
    }
    func loadScheduledTaskResultOutput(
        taskName: String,
        resultID: String
    ) async throws -> NasScheduledTaskResultOutput {
        throw unsupportedManagementOperation()
    }
    func loadAccountDirectoryForManagement() async throws -> NasAccountDirectory { throw unsupportedManagementOperation() }
    func changeDirectoryResult(_ change: NasDirectoryChange, checkpoint: @escaping @Sendable (NasDirectoryCheckpoint) async throws -> Void) async throws -> MutationResult { throw unsupportedManagementOperation() }
    func saveAccount(_ draft: NasAccountDraft) async throws {
        throw unsupportedManagementOperation()
    }
    func deleteAccount(name: String) async throws {
        throw unsupportedManagementOperation()
    }
    func deleteAccountResult(name: String) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "accountDelete",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "account.delete.unsupported",
            diagnosticTag: "account.delete.unsupported"
        )
    }
    func saveGroup(_ draft: NasGroupDraft) async throws {
        throw unsupportedManagementOperation()
    }
    func deleteGroup(name: String) async throws {
        throw unsupportedManagementOperation()
    }
    func deleteGroupResult(name: String) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "groupDelete",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "group.delete.unsupported",
            diagnosticTag: "group.delete.unsupported"
        )
    }
    func saveScheduledTask(_ draft: NasScheduledTaskDraft) async throws {
        throw unsupportedManagementOperation()
    }
    func setScheduledTaskEnabled(id: Int, realOwner: String?, enabled: Bool) async throws {
        throw unsupportedManagementOperation()
    }
    func runScheduledTask(id: Int, realOwner: String?) async throws {
        throw unsupportedManagementOperation()
    }
    func deleteScheduledTask(id: Int, realOwner: String?) async throws {
        throw unsupportedManagementOperation()
    }
    func disconnectConnection(_ connection: NasConnection) async throws {
        throw unsupportedManagementOperation()
    }
    func loadConnectionsForManagement() async throws -> NasConnectionPage { throw unsupportedManagementOperation() }
    func verifyPowerConnection() async throws { throw unsupportedManagementOperation() }
    func loadPackagePreferencesForManagement() async throws -> NasPackagePreferencesSnapshot { throw unsupportedManagementOperation() }
    func loadPackageSourcesForManagement() async throws -> [NasPackageSource] { throw unsupportedManagementOperation() }
    func changePackagePreferencesResult(_ change: NasPackagePreferenceChange, checkpoint: @escaping @Sendable (NasPackagePreferenceCheckpoint) async throws -> Void) async throws -> MutationResult {
        try .init(status: .unsupported, operation: change.kind.rawValue, submitted: false, requiresRefresh: false,
                  counts: .init(succeeded: 0, failed: 1, unknown: 0), errorCategory: .unsupported, diagnosticTag: "package-preference.unsupported")
    }
    func performSystemActionResult(_ action: NasSystemAction, checkpoint: @escaping @Sendable (NasSystemActionCheckpoint) async throws -> Void) async throws -> MutationResult {
        try .init(status: .unsupported, operation: action.kind.rawValue, submitted: false, requiresRefresh: false,
                  counts: .init(succeeded: 0, failed: 1, unknown: 0), errorCategory: .unsupported, diagnosticTag: "system-action.unsupported")
    }
    func loadFileServiceSettings() async throws -> NasFileServiceSettings {
        throw unsupportedManagementOperation()
    }
    func saveFileServiceSettings(_ settings: NasFileServiceSettings) async throws {
        throw unsupportedManagementOperation()
    }
    func saveFileServiceSettingsResult(
        _ settings: NasFileServiceSettings
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "fileServiceSettingsUpdate",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "file-services.settings.unsupported",
            diagnosticTag: "file-services.settings.unsupported"
        )
    }
    func loadTerminalSettings() async throws -> NasTerminalSettings {
        throw unsupportedManagementOperation()
    }
    func saveTerminalSettings(_ settings: NasTerminalSettings) async throws {
        throw unsupportedManagementOperation()
    }
    func saveTerminalSettingsResult(
        _ settings: NasTerminalSettings
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "terminalSettingsUpdate",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "terminal.settings.unsupported",
            diagnosticTag: "terminal.settings.unsupported"
        )
    }
    func loadProxySettings() async throws -> NasProxySettings {
        throw unsupportedManagementOperation()
    }
    func saveProxySettings(_ settings: NasProxySettings) async throws {
        throw unsupportedManagementOperation()
    }
    func saveProxySettingsResult(
        _ settings: NasProxySettings
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "proxySettingsUpdate",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "proxy.settings.unsupported",
            diagnosticTag: "proxy.settings.unsupported"
        )
    }
    func loadEthernetInterfaces() async throws -> [NasEthernetInterface] {
        throw unsupportedManagementOperation()
    }
    func saveEthernetInterface(_ interface: NasEthernetInterface) async throws {
        throw unsupportedManagementOperation()
    }
    func saveEthernetInterfaceResult(
        _ interface: NasEthernetInterface
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "ethernetUpdate",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "network.ethernet.unsupported",
            diagnosticTag: "network.ethernet.unsupported"
        )
    }
    func loadHardwareSettings() async throws -> NasHardwareSettings {
        throw unsupportedManagementOperation()
    }
    func loadPowerSchedule() async throws -> NasPowerScheduleSnapshot {
        throw unsupportedManagementOperation()
    }
    func loadExternalStorage() async throws -> NasExternalStorageDirectory {
        throw unsupportedManagementOperation()
    }
    func loadZRAM() async throws -> NasZRAMSnapshot {
        throw unsupportedManagementOperation()
    }
    func saveHardwareSettings(_ settings: NasHardwareSettings) async throws {
        throw unsupportedManagementOperation()
    }
    func saveHardwareSettingsResult(
        _ settings: NasHardwareSettings
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "hardwareSettingsUpdate",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "hardware.settings.unsupported",
            diagnosticTag: "hardware.settings.unsupported"
        )
    }
    func loadRemoteAccessSettings() async throws -> NasRemoteAccessSettings {
        throw unsupportedManagementOperation()
    }
    func saveRemoteAccessSettings(_ settings: NasRemoteAccessSettings) async throws {
        throw unsupportedManagementOperation()
    }
    func saveRemoteAccessSettingsResult(
        _ settings: NasRemoteAccessSettings
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "remoteAccessSettingsUpdate",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "remote-access.settings.unsupported",
            diagnosticTag: "remote-access.settings.unsupported"
        )
    }
    func loadSecuritySettings() async throws -> NasSecuritySettings {
        throw unsupportedManagementOperation()
    }
    func saveSecuritySettings(_ settings: NasSecuritySettings) async throws {
        throw unsupportedManagementOperation()
    }
    func saveSecuritySettingsResult(
        _ settings: NasSecuritySettings
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "securitySettingsUpdate",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "security.settings.unsupported",
            diagnosticTag: "security.settings.unsupported"
        )
    }
    func loadRegionSettings() async throws -> NasRegionSettings {
        throw unsupportedManagementOperation()
    }
    func loadRegionForManagement() async throws -> NasRegionSettings { throw unsupportedManagementOperation() }
    func changeRegionResult(_ change: NasRegionChange,
                            checkpoint: @escaping @Sendable (NasRegionCheckpoint) async throws -> Void) async throws -> MutationResult {
        throw unsupportedManagementOperation()
    }
    func saveRegionSettings(_ settings: NasRegionSettings) async throws {
        throw unsupportedManagementOperation()
    }
    func saveRegionSettingsResult(
        _ settings: NasRegionSettings
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: "regionSettingsUpdate",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "region.settings.unsupported",
            diagnosticTag: "region.settings.unsupported"
        )
    }
    func loadDDNS() async throws -> NasDDNSDirectory {
        throw unsupportedManagementOperation()
    }
    func loadDDNSForManagement() async throws -> NasDDNSDirectory { throw unsupportedManagementOperation() }
    func changeDDNSResult(_ change: NasDDNSChange,
                          checkpoint: @escaping @Sendable (NasDDNSCheckpoint) async throws -> Void) async throws -> MutationResult {
        throw unsupportedManagementOperation()
    }
    func testDDNSResult(_ draft: NasDDNSDraft) async throws -> MutationResult {
        try unsupportedDDNSResult(operation: "ddnsProviderTest")
    }
    func saveDDNS(_ draft: NasDDNSDraft) async throws {
        throw unsupportedManagementOperation()
    }
    func saveDDNSResult(_ draft: NasDDNSDraft) async throws -> MutationResult {
        try unsupportedDDNSResult(operation: "ddnsRecordSave")
    }
    func deleteDDNS(providerID: String) async throws {
        throw unsupportedManagementOperation()
    }
    func deleteDDNSResult(providerID: String) async throws -> MutationResult {
        try unsupportedDDNSResult(operation: "ddnsRecordDelete")
    }
    func refreshDDNS() async throws {
        throw unsupportedManagementOperation()
    }
    func refreshDDNSResult() async throws -> MutationResult {
        try unsupportedDDNSResult(operation: "ddnsAddressRefresh")
    }
    func performPowerAction(_ action: NasPowerAction) async throws {
        throw unsupportedManagementOperation()
    }
    func performPowerActionResult(
        _ action: NasPowerAction
    ) async throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: action == .shutdown ? "nasShutdown" : "nasReboot",
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "power.action.unsupported",
            diagnosticTag: "power.action.unsupported"
        )
    }
    func checkSystemUpdate() async throws -> NasSystemUpdateInfo {
        throw unsupportedManagementOperation()
    }

    private func unsupportedManagementOperation() -> AppError {
        AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.89527fd77aba1533")
        )
    }

    private func unsupportedDDNSResult(operation: String) throws -> MutationResult {
        try MutationResult(
            status: .unsupported,
            operation: operation,
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .unsupported,
            localizationKey: "ddns.operation.unsupported",
            diagnosticTag: "ddns.operation.unsupported"
        )
    }
}
