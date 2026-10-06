import DsmCore
import CryptoKit
import Foundation
import DsmLocalization

private actor NetworkDeletionTracking {
    var state = (submitted: false, rejected: false)
    func recordVmm(_ stage: VirtualMachineControlStage) {
        if stage == .willSubmit { state.submitted = true }
        if stage == .rejected { state.rejected = true }
    }
    func record(_ stage: ContainerNetworkMutationStage) {
        if case .willSubmit = stage { state.submitted = true }
        if case .rejected = stage { state.rejected = true }
    }
}

private enum ServiceJSON: Decodable, Sendable {
    case object([String: ServiceJSON])
    case array([ServiceJSON])
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: ServiceJSON].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([ServiceJSON].self))
        }
    }

    subscript(key: String) -> ServiceJSON? {
        guard case .object(let value) = self else { return nil }
        return value[key]
    }

    var object: [String: ServiceJSON]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var array: [ServiceJSON]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value): value.rounded() == value ? String(Int64(value)) : String(value)
        case .boolean(let value): value ? "true" : "false"
        default: nil
        }
    }

    var numberValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        case .boolean(let value): value ? 1 : 0
        default: nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .boolean(let value): value
        case .number(let value): value != 0
        case .string(let value): ["1", "true", "yes", "running", "in_use"].contains(value.lowercased())
        default: nil
        }
    }

    func firstString(_ keys: [String]) -> String? {
        for key in keys {
            if let value = self[key]?.stringValue, !value.isEmpty { return value }
        }
        return nil
    }

    func firstInteger(_ keys: [String]) -> Int64? {
        for key in keys {
            if let value = self[key]?.numberValue { return Int64(value) }
        }
        return nil
    }

    func firstDouble(_ keys: [String]) -> Double? {
        for key in keys {
            if let value = self[key]?.numberValue { return value }
        }
        return nil
    }

    func firstBoolean(_ keys: [String]) -> Bool? {
        for key in keys {
            if let value = self[key]?.boolValue { return value }
        }
        return nil
    }

    func objects(for keys: [String], depth: Int = 0) -> [[String: ServiceJSON]] {
        guard depth < 4 else { return [] }
        if case .array(let values) = self {
            return values.compactMap(\.object)
        }
        guard case .object(let object) = self else { return [] }

        for key in keys {
            guard let child = object[key] else { continue }
            if let values = child.array?.compactMap(\.object) {
                return values
            }
            let nested = child.objects(for: keys, depth: depth + 1)
            if !nested.isEmpty {
                return nested
            }
        }
        for wrapper in ["data", "result", "items"] where !keys.contains(wrapper) {
            guard let child = object[wrapper] else { continue }
            let nested = child.objects(for: keys, depth: depth + 1)
            if !nested.isEmpty {
                return nested
            }
        }
        return []
    }
}

private enum SupplementaryServiceResult: Sendable {
    case available(ServiceJSON)
    case unavailable
    case failed

    var value: ServiceJSON? {
        guard case .available(let value) = self else { return nil }
        return value
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

private struct DownloadTaskControlKey: Hashable, Sendable {
    let taskID: String
    let action: String
}

private struct DownloadTaskControlReview: Sendable {
    let key: DownloadTaskControlKey
}

private struct DownloadTaskCreateKey: Hashable, Sendable {
    let digest: String
}

private struct DownloadTaskCreateReview: Sendable {
    let key: DownloadTaskCreateKey
    let previousTaskIDs: Set<String>
    let expectedTaskID: String?
    let destination: String?
}

private enum DownloadTaskCreateSource: Sendable {
    case uri(String)
    case file(URL, unzipPassword: String?)
}

private struct PreparedDownloadTaskCreateRequest: Sendable {
    let identity: DownloadTaskCreationIdentity
    var key: DownloadTaskCreateKey { .init(digest: identity.requestDigest) }
    let source: DownloadTaskCreateSource
    let destination: String?
}

private enum DownloadTaskCreateValidation: Sendable {
    case success(PreparedDownloadTaskCreateRequest)
    case failure(DownloadTaskCreateOutcome)
}

/// Download Station、VMM 与 Container Manager 的套件适配器。
/// Container Manager 以及无公开接口时的套件分支均属于 DSM 内部接口。
public actor DsmServiceManagementRepository: ServiceManagementRepository,
    VirtualMachineInventoryReading, ContainerInventoryReading {
    private static let downloadControlPageSize = 500
    private static let downloadBTSearchResultLimit = 200
    private let capabilities: CapabilitySet
    private let credential: DsmSessionCredential
    private let baseURL: URL
    private let client: DsmAPIClient
    private let transport: any DsmHTTPTransport
    private var activeDownloadSettings = false
    private var pendingDownloadSettings: [DownloadSettingsField.Group: DownloadSettingsChange] = [:]
    private var activeDownloadRSSUpdates: Set<Int> = []
    private var pendingDownloadRSSUpdates: [Int: DownloadRSSSite] = [:]
    private var activeDownloadRemovals: Set<String> = []
    private var pendingDownloadRemovals: [String: DownloadTaskRemoval] = [:]
    private var activeDownloadEdits: Set<String> = []
    private var pendingDownloadEdits: [String: DownloadTaskDestinationChange] = [:]
    private var activeDownloadControlKeys: Set<DownloadTaskControlKey> = []
    private var pendingDownloadControlReviews: [DownloadTaskControlKey: DownloadTaskControlReview] = [:]
    private var activeDownloadCreateKeys: Set<DownloadTaskCreateKey> = []
    private var pendingDownloadCreateReviews: [DownloadTaskCreateKey: DownloadTaskCreateReview] = [:]
    private var activeContainerMutationIDs: Set<String> = []
    private var pendingContainerDeletions: [String: String] = [:]
    private var pendingContainerControls: [String: ContainerControlReview] = [:]
    private var imageDeletionActive = false
    private var pendingImageDeletions: [Set<String>: ContainerImageDeletionRecovery] = [:]
    private var completedImageDeletions: [UUID: (ContainerImageDeletionRecovery, ContainerImageDeletionProgress)] = [:]
    private var imagePullBusy = false
    private var imagePullOperations: [UUID: ImagePullOperation] = [:]
    private var unverifiedVmmDeletions: [String: [String: VmmDeletion]] = [:]
    private var activeVmmPowerIDs: Set<String> = []
    private var unverifiedVmmPower: [String: VmmPowerTarget] = [:]
    private var activeVmmSettingsIDs: Set<String> = []
    private var unverifiedVmmSettings: [String: VmmSettingsSubmission] = [:]
    private var activeVmmCreationNames: Set<String> = []
    private var activeVmmCreationResources: [String: [String: String]] = [:]
    private var activeVmmNetworkMutationIDs: Set<String> = []
    private var activeVmmNetworkNames: Set<String> = []
    private var activeVmmNetworkGuests: [String: Set<String>] = [:]
    private var pendingVmmNetworks: [String: VmmNetworkSubmission] = [:]
    private var pendingVmmCreations: [String: (configuration: VirtualMachineCreation?, tracking: VirtualMachineCreationTracking)] = [:]
    private var activeDeletionIDsByOperation: [String: Set<String>] = [:]
    private let containerNetworkCreationEnabled: Bool
    private var networkMutationActive = false
    private var pendingNetworkCreations: [String: (configuration: ContainerNetworkCreation, accepted: Bool)] = [:]
    private var pendingNetworkDeletions: [String: (network: ContainerNetwork, accepted: Bool)] = [:]

    public init(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession,
        transport: (any DsmHTTPTransport)? = nil,
        containerNetworkCreationEnabled: Bool = false
    ) throws {
        let resolvedTransport = transport ?? URLSessionTransport(
            expectedHost: profile.host,
            pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
            requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(profile.host)
        )
        let baseURL = try DsmEndpoint.baseURL(for: profile)
        self.capabilities = capabilities
        // 由客户端组合根显式启用；实际提交仍检查接口能力、配置与同名操作状态。
        self.containerNetworkCreationEnabled = containerNetworkCreationEnabled
        credential = DsmSessionCredential(sid: session.sid, synoToken: session.synoToken)
        self.baseURL = baseURL
        self.transport = resolvedTransport
        client = DsmAPIClient(
            baseURL: baseURL,
            transport: resolvedTransport
        )
    }

    public func loadDownloadStation() async throws -> DownloadStationSnapshot {
        let usesOfficial = capabilities[DsmAPIName.downloadStationTask]?.selectedVersion != nil
        let taskAPI = usesOfficial
            ? DsmAPIName.downloadStationTask
            : DsmAPIName.downloadStation2Task
        let taskValue = try await call(
            taskAPI,
            method: "list",
            parameters: usesOfficial
                ? [
                    "offset": .integer(0),
                    "limit": .integer(1_000),
                    "additional": .stringArray(["detail", "transfer"])
                ]
                : ["offset": .integer(0), "limit": .integer(1_000)]
        )

        let taskObjects = taskValue.objects(for: ["tasks", "task", "items", "list"])
        let tasks = taskObjects.compactMap(Self.downloadTask)
        return try await downloadStationSnapshot(tasks: tasks, usesOfficial: usesOfficial, isComplete: false)
    }

    /// 移动任务目录与写操作使用同一完整分页读取；内部备用仍是明确受限的摘要。
    public func loadDownloadStationInventory() async throws -> DownloadStationSnapshot {
        guard capabilities[DsmAPIName.downloadStationTask]?.selectedVersion != nil else {
            return try await loadDownloadStation()
        }
        let tasks = try await loadAllOfficialDownloadTasks()
        return try await downloadStationSnapshot(tasks: tasks, usesOfficial: true, isComplete: true)
    }

    public func loadDownloadTaskDetails(id: String) async throws -> DownloadStationTaskDetails {
        guard Self.isStableDownloadBTSearchIdentifier(id, allowComma: false) else {
            throw invalidServiceResponse()
        }
        let value = try await callOfficialDownloadTask(method: "getinfo", parameters: [
            "id": .string(id),
            "additional": .string("detail,transfer,file,tracker,peer")
        ])
        let objects = try Self.strictRootObjects(value, keys: ["tasks"])
        guard objects.count == 1, let object = objects.first,
              let task = Self.officialDownloadTask(object), task.id == id else {
            throw invalidServiceResponse()
        }
        return try Self.downloadTaskDetails(object, task: task)
    }

    private func downloadStationSnapshot(
        tasks: [DownloadStationTask], usesOfficial: Bool, isComplete: Bool
    ) async throws -> DownloadStationSnapshot {
        let statisticAPI = usesOfficial
            ? DsmAPIName.downloadStationStatistic
            : DsmAPIName.downloadStation2Statistic
        let statisticMethod = usesOfficial ? "getinfo" : "get"
        let statistic = try? await call(statisticAPI, method: statisticMethod)
        let location = usesOfficial
            ? nil
            : try? await call(DsmAPIName.downloadStation2Location, method: "get")
        try Task.checkCancellation()
        let statistics = DownloadStationStatistics(
            downloadBytesPerSecond: Self.downloadNumber(statistic, keys: ["download_rate", "download_speed", "speed_download"]),
            uploadBytesPerSecond: Self.downloadNumber(statistic, keys: ["upload_rate", "upload_speed", "speed_upload"]),
            emuleDownloadBytesPerSecond: Self.downloadNumber(statistic, keys: ["emule_download_rate", "emule_download_speed", "emule_speed_download"]),
            emuleUploadBytesPerSecond: Self.downloadNumber(statistic, keys: ["emule_upload_rate", "emule_upload_speed", "emule_speed_upload"])
        )

        return DownloadStationSnapshot(
            source: usesOfficial ? .official : .internalAPI,
            tasks: tasks,
            hasActivitySummary: statistic != nil,
            hasBTSearch: usesOfficial &&
                capabilities[DsmAPIName.downloadStationBTSearch]?.selectedVersion != nil,
            downloadBytesPerSecond: statistics.downloadBytesPerSecond ?? 0,
            uploadBytesPerSecond: statistics.uploadBytesPerSecond ?? 0,
            emuleDownloadBytesPerSecond: statistics.emuleDownloadBytesPerSecond ?? 0,
            emuleUploadBytesPerSecond: statistics.emuleUploadBytesPerSecond ?? 0,
            defaultDestination: location?.firstString(["destination", "path", "default_destination"]),
            isComplete: isComplete,
            statistics: statistics
        )
    }

    public var supportsDownloadRSS: Bool {
        [DsmAPIName.downloadStationRSSSite, DsmAPIName.downloadStationRSSFeed].allSatisfy {
            guard let capability = capabilities[$0] else { return false }
            return capability.name == $0 && capability.selectedVersion != nil && capability.minVersion <= 1 && capability.maxVersion >= 1
        }
    }

    public func loadDownloadRSSSites() async throws -> [DownloadRSSSite] {
        let objects = try await loadDownloadRSSObjects(api: DsmAPIName.downloadStationRSSSite, keys: ["sites", "site"])
        var ids: Set<Int> = []
        let sites = try objects.map { object -> DownloadRSSSite in
            guard let rawID = Self.rssInteger(object["id"]), let id = Int(exactly: rawID), ids.insert(id).inserted,
                  case .string(let title) = object["title"], case .string(let url) = object["url"],
                  case .string(let username) = object["username"], case .boolean(let updating) = object["is_updating"],
                  let lastUpdate = Self.rssInteger(object["last_update"]) else { throw invalidServiceResponse() }
            let digest = Self.rssDigest([String(id), url, username])
            return .init(id: id, identityDigest: digest, title: title, isUpdating: updating, lastUpdate: lastUpdate)
        }
        // 仅同一订阅的更新日期前进且更新结束，才能解除原请求的不确定状态。
        for site in sites {
            if let pending = pendingDownloadRSSUpdates[site.id], pending.identityDigest == site.identityDigest,
               site.lastUpdate > pending.lastUpdate, !site.isUpdating { pendingDownloadRSSUpdates.removeValue(forKey: site.id) }
        }
        return sites
    }

    public func loadDownloadRSSFeeds(siteID: Int) async throws -> [DownloadRSSFeed] {
        guard siteID >= 0 else { throw invalidServiceResponse() }
        let objects = try await loadDownloadRSSObjects(api: DsmAPIName.downloadStationRSSFeed, keys: ["feeds"],
            parameters: ["id": .string(String(siteID))])
        var seen: Set<String> = []
        return try objects.compactMap { object in
            guard case .string(let title) = object["title"], case .string(let uri) = object["download_uri"],
                  case .string(let link) = object["external_link"], case .string(let rawSize) = object["size"],
                  !rawSize.isEmpty, rawSize.utf8.allSatisfy({ (48...57).contains($0) }),
                  let size = Int64(rawSize), let time = Self.rssInteger(object["time"]) else { throw invalidServiceResponse() }
            let id = Self.rssDigest([title, uri, link, rawSize, String(time)])
            // 完全相同的条目可以合并，分页偏移仍按原始条目数推进。
            guard seen.insert(id).inserted else { return nil }
            return .init(id: id, title: title, sizeBytes: size, time: time, downloadURI: uri)
        }
    }

    public func refreshDownloadRSSSite(_ original: DownloadRSSSite,
        willSubmit: @escaping @Sendable () async throws -> Void
    ) async throws -> DownloadRSSRefreshReceipt {
        guard original.id >= 0, activeDownloadRSSUpdates.insert(original.id).inserted else {
            throw validationError(L10n.string("download.rss.changed"))
        }
        defer { activeDownloadRSSUpdates.remove(original.id) }
        let sites = try await loadDownloadRSSSites()
        guard let current = sites.first(where: { $0.id == original.id }),
              current.identityDigest == original.identityDigest, current.lastUpdate == original.lastUpdate,
              !current.isUpdating, pendingDownloadRSSUpdates[original.id] == nil else {
            throw validationError(L10n.string("download.rss.changed"))
        }
        try Task.checkCancellation()
        try await willSubmit()
        if Task.isCancelled { return .cancelledBeforeSubmission }
        pendingDownloadRSSUpdates[original.id] = current
        do {
            try await callVoid(DsmAPIName.downloadStationRSSSite, method: "refresh",
                parameters: ["id": .string(String(original.id))], fixedVersion: 1)
            return .accepted
        } catch let error as AppError where error.dsmCode.map({ [101, 102, 103, 104, 105, 106, 107].contains($0) }) == true {
            pendingDownloadRSSUpdates.removeValue(forKey: original.id)
            return error.category == .permissionDenied ? .denied : .rejected
        } catch { return .unknown }
    }

    private func loadDownloadRSSObjects(api: String, keys: [String], parameters: [String: DsmParameterValue] = [:]) async throws -> [ServiceJSON] {
        var offset = 0, expectedTotal: Int?
        var result: [ServiceJSON] = []
        while true {
            try Task.checkCancellation()
            let value = try await call(api, method: "list", parameters: parameters.merging([
                "offset": .integer(offset), "limit": .integer(Self.downloadControlPageSize)
            ]) { _, next in next }, fixedVersion: 1)
            guard let rawTotal = Self.rssInteger(value["total"]), let total = Int(exactly: rawTotal),
                  Self.rssInteger(value["offset"]) == Int64(offset), expectedTotal == nil || expectedTotal == total else {
                throw invalidServiceResponse()
            }
            let containers = keys.compactMap { value[$0] }
            // 官方表使用 sites，示例使用 site；同时出现时不猜测哪个权威。
            guard containers.count == 1, case .array(let page) = containers[0],
                  page.count <= Self.downloadControlPageSize, page.allSatisfy({ $0.object != nil }),
                  offset <= total, page.count <= total - offset else { throw invalidServiceResponse() }
            expectedTotal = total; result.append(contentsOf: page); offset += page.count
            if offset == total { return result }
            guard !page.isEmpty else { throw invalidServiceResponse() }
        }
    }

    private static func rssInteger(_ value: ServiceJSON?) -> Int64? {
        guard case .number(let value) = value, let integer = Int64(exactly: value), integer >= 0 else { return nil }
        return integer
    }

    private static func rssDigest(_ parts: [String]) -> String {
        let encoded = parts.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func loadDownloadBTSearchCatalog() async throws -> DownloadBTSearchCatalog {
        let modulesValue = try await call(
            DsmAPIName.downloadStationBTSearch,
            method: "getModule"
        )
        let categoriesValue = try await call(
            DsmAPIName.downloadStationBTSearch,
            method: "getCategory"
        )
        return try Self.downloadBTSearchCatalog(
            modulesValue: modulesValue,
            categoriesValue: categoriesValue
        )
    }

    public func searchDownloadBT(
        _ request: DownloadBTSearchRequest
    ) async throws -> [DownloadBTSearchResult] {
        let prepared = try Self.preparedDownloadBTSearchRequest(request)
        let started = try await call(
            DsmAPIName.downloadStationBTSearch,
            method: "start",
            parameters: [
                "keyword": .string(prepared.keyword),
                "module": .string(prepared.module)
            ]
        )
        guard let taskID = Self.strictNonEmptyString(started["taskid"]) else {
            throw Self.invalidDownloadBTSearchResponse()
        }

        do {
            for _ in 0..<60 {
                let data = try await call(
                    DsmAPIName.downloadStationBTSearch,
                    method: "list",
                    parameters: [
                        "taskid": .string(taskID),
                        "offset": .integer(0),
                        "limit": .integer(Self.downloadBTSearchResultLimit),
                        "sort_by": .string(prepared.sort),
                        "sort_direction": .string(prepared.direction),
                        "filter_category": .string(prepared.category),
                        "filter_title": .string(prepared.titleFilter)
                    ]
                )
                guard let finished = Self.strictBoolean(data["finished"]) else {
                    throw Self.invalidDownloadBTSearchResponse()
                }
                if finished {
                    let results = try Self.downloadBTSearchResults(from: data)
                    await cleanDownloadBTSearch(taskID: taskID)
                    return results
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            }
            throw Self.invalidDownloadBTSearchResponse()
        } catch {
            await cleanDownloadBTSearch(taskID: taskID)
            throw error
        }
    }

    private func cleanDownloadBTSearch(taskID: String) async {
        guard let capability = capabilities[DsmAPIName.downloadStationBTSearch],
              let version = capability.selectedVersion else { return }
        let cleanupClient = client
        let cleanupCredential = credential
        let cleanupTask = Task.detached {
            try? await cleanupClient.callVoid(
                path: capability.path,
                api: capability.name,
                version: version,
                method: "clean",
                requestFormat: capability.requestFormat,
                parameters: ["taskid": .string(taskID)],
                credential: cleanupCredential
            )
        }
        await cleanupTask.value
    }

    public func createDownloadTask(uri: String, destination: String?) async throws {
        let normalized = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: normalized),
              ["http", "https", "ftp", "magnet"].contains(url.scheme?.lowercased() ?? "") else {
            throw validationError(L10n.string("shared.ee9bd6266a536859"))
        }
        let api = preferredDownloadTaskAPI()
        var parameters: [String: DsmParameterValue] = ["uri": .string(normalized)]
        if let destination = Self.nonEmpty(destination) {
            parameters["destination"] = .string(destination)
        }
        if api == DsmAPIName.downloadStationTask {
            _ = try await callOfficialDownloadTask(method: "create", parameters: parameters,
                version: 3)
        } else {
            try await callVoid(api, method: "create", parameters: parameters)
        }
    }

    public func createDownloadTaskResult(
        _ request: DownloadTaskCreateRequest
    ) async throws -> DownloadTaskCreateOutcome {
        let validation = try Self.validatedDownloadCreateRequest(request)
        switch validation {
        case .failure(let outcome):
            return outcome
        case .success(let prepared):
            return try await performDownloadTaskCreate(prepared)
        }
    }

    public func createDownloadTaskFileResult(
        _ request: DownloadTaskFileCreateRequest
    ) async throws -> DownloadTaskCreateOutcome {
        let validation = try Self.validatedDownloadFileCreateRequest(request)
        switch validation {
        case .failure(let outcome):
            return outcome
        case .success(let prepared):
            return try await performDownloadTaskCreate(prepared)
        }
    }

    /// 在发送前持久保存摘要；收到官方成功回执后持久保存接受状态。旧任务回读接口仍保留。
    public func createDownloadTaskResult(_ request: DownloadTaskCreateRequest,
        willSubmit: @escaping @Sendable (DownloadTaskCreationIdentity) async throws -> Void,
        didAccept: @escaping @Sendable () async throws -> Void
    ) async throws -> DownloadTaskCreateOutcome {
        switch try Self.validatedDownloadCreateRequest(request) {
        case .failure(let outcome): return outcome
        case .success(let prepared): return try await performDownloadTaskCreate(prepared, willSubmit: willSubmit, didAccept: didAccept)
        }
    }

    public func createDownloadTaskFileResult(_ request: DownloadTaskFileCreateRequest,
        willSubmit: @escaping @Sendable (DownloadTaskCreationIdentity) async throws -> Void,
        didAccept: @escaping @Sendable () async throws -> Void
    ) async throws -> DownloadTaskCreateOutcome {
        switch try Self.validatedDownloadFileCreateRequest(request) {
        case .failure(let outcome): return outcome
        case .success(let prepared): return try await performDownloadTaskCreate(prepared, willSubmit: willSubmit, didAccept: didAccept)
        }
    }

    public func createDownloadTask(
        fileURL: URL,
        destination: String?,
        unzipPassword: String?
    ) async throws {
        guard capabilities[DsmAPIName.downloadStationTask]?.selectedVersion != nil else {
            throw AppError(
                category: .apiUnavailable,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.8308afa6a7f31906")
            )
        }
        let normalizedURL = fileURL.standardizedFileURL
        let allowedExtensions = ["torrent", "nzb", "txt"]
        guard normalizedURL.isFileURL,
              allowedExtensions.contains(normalizedURL.pathExtension.lowercased()) else {
            throw validationError(L10n.string("shared.14f852b3c59ec0c8"))
        }

        let accessed = normalizedURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                normalizedURL.stopAccessingSecurityScopedResource()
            }
        }
        let values = try normalizedURL.resourceValues(
            forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]
        )
        guard values.isRegularFile == true, values.isReadable != false else {
            throw validationError(L10n.string("shared.51bdbefbc0c88421"))
        }
        guard (values.fileSize ?? 0) <= 100 * 1_024 * 1_024 else {
            throw validationError(L10n.string("shared.799f04c59bdac5e7"))
        }

        _ = try await callOfficialDownloadTaskFileCreate(
            fileURL: normalizedURL,
            destination: destination,
            unzipPassword: unzipPassword
        )
    }

    public func loadDownloadStationSettings() async throws -> DownloadStationSettings {
        let config = try await call(DsmAPIName.downloadStationInfo, method: "getconfig")
        let schedule = try? await call(DsmAPIName.downloadStationSchedule, method: "getconfig")
        return Self.downloadSettings(config: config, schedule: schedule)
    }

    /// 保留字段存在性和套件当前管理权限，供增量设置与恢复使用。
    public func loadDownloadSettingsSnapshot() async throws -> DownloadSettingsSnapshot {
        let version = try downloadSettingsInfoVersion()
        let info = try? await call(DsmAPIName.downloadStationInfo, method: "getinfo", fixedVersion: version)
        try Task.checkCancellation()
        let config = try await call(DsmAPIName.downloadStationInfo, method: "getconfig", fixedVersion: version)
        let schedule = try? await call(DsmAPIName.downloadStationSchedule, method: "getconfig", fixedVersion: 1)
        try Task.checkCancellation()
        var values: [DownloadSettingsField: DownloadSettingsValue] = [:]
        for field in DownloadSettingsField.allCases {
            if field == .destination && version < 2 { continue }
            let source = field.group == .general ? config : schedule
            let value: DownloadSettingsValue?
            switch source?[field.parameter] {
            case .boolean(let flag): value = .flag(flag)
            case .number(let number): value = Int(exactly: number).map(DownloadSettingsValue.number)
            case .string(let text): value = field == .destination ? .text(text) : Int(text).map(DownloadSettingsValue.number)
            default: value = nil
            }
            if let value, field.accepts(value) { values[field] = value }
        }
        let manager: Bool?
        if case .boolean(let value) = info?["is_manager"] { manager = value } else { manager = nil }
        return DownloadSettingsSnapshot(isManager: manager, values: values)
    }

    /// 只写已知差量；持久化回调失败及原值改变均发生在发送之前。
    public func changeDownloadSettings(
        _ change: DownloadSettingsChange,
        willSubmit: @escaping @Sendable () async throws -> Void
    ) async throws -> DownloadSettingsWriteOutcome {
        guard change.isValid, !activeDownloadSettings, pendingDownloadSettings[change.group] == nil else {
            throw validationError(L10n.string("download.settings.changed"))
        }
        activeDownloadSettings = true
        defer { activeDownloadSettings = false }
        let baseline = try await loadDownloadSettingsSnapshot()
        guard let isManager = baseline.isManager else {
            throw AppError(category: .invalidResponse, isRetryable: true, safeUserMessage: L10n.string("download.settings.permission-unknown"))
        }
        guard isManager else {
            throw AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: L10n.string("download.settings.permission"))
        }
        guard change.matches(baseline, desired: false) else {
            throw validationError(L10n.string("download.settings.changed"))
        }
        let version = change.group == .general ? try downloadSettingsInfoVersion() : 1
        try Task.checkCancellation()
        try await willSubmit()
        if Task.isCancelled { return .cancelledBeforeSubmission }
        let parameters = Dictionary(uniqueKeysWithValues: change.desired.map { field, value in
            let parameter: DsmParameterValue
            switch value {
            case .text(let text): parameter = .string(text)
            case .flag(let flag): parameter = .boolean(flag)
            case .number(let number): parameter = .integer(number)
            }
            return (field.parameter, parameter)
        })
        pendingDownloadSettings[change.group] = change
        do {
            try await callVoid(change.group == .general ? DsmAPIName.downloadStationInfo : DsmAPIName.downloadStationSchedule,
                method: change.group == .general ? "setserverconfig" : "setconfig", parameters: parameters, fixedVersion: version)
        } catch let error as AppError where error.dsmCode != nil && [101, 102, 103, 104, 105, 106, 107].contains(error.dsmCode!) {
            // 官方明确拒绝与网络中断分开；未知错误不据此解锁重发。
            pendingDownloadSettings.removeValue(forKey: change.group)
            return error.category == .permissionDenied ? .denied : .rejected
        } catch {
            return .pending
        }
        return (try? await reviewDownloadSettings(change)) == true ? .complete : .pending
    }

    /// 未知写只查询；即使当前值仍为原值，也不能证明先前请求未生效。
    public func reviewDownloadSettings(_ change: DownloadSettingsChange) async throws -> Bool {
        guard change.isValid else { throw validationError(L10n.string("download.settings.changed")) }
        let current = try await loadDownloadSettingsSnapshot()
        let complete = change.matches(current, desired: true)
        if complete, pendingDownloadSettings[change.group] == change { pendingDownloadSettings.removeValue(forKey: change.group) }
        return complete
    }

    private func downloadSettingsInfoVersion() throws -> Int {
        guard let capability = capabilities[DsmAPIName.downloadStationInfo],
              capability.name == DsmAPIName.downloadStationInfo, capability.selectedVersion != nil else { throw unavailableError() }
        for version in [2, 1] where capability.minVersion <= version && capability.maxVersion >= version { return version }
        throw unavailableError()
    }

    public func saveDownloadStationSettings(_ settings: DownloadStationSettings) async throws {
        let limits = [
            settings.btDownloadLimit,
            settings.btUploadLimit,
            settings.httpDownloadLimit,
            settings.ftpDownloadLimit,
            settings.nzbDownloadLimit,
            settings.emuleDownloadLimit,
            settings.emuleUploadLimit
        ]
        guard limits.allSatisfy({ $0 >= 0 && $0 <= 1_000_000 }) else {
            throw validationError(L10n.string("shared.2a1456d8267f62b5"))
        }

        try await callVoid(
            DsmAPIName.downloadStationInfo,
            method: "setserverconfig",
            parameters: [
                "default_destination": .string(
                    settings.defaultDestination.trimmingCharacters(
                        in: CharacterSet(charactersIn: "/")
                    )
                ),
                "emule_enabled": .boolean(settings.isEMuleEnabled),
                "unzip_service_enabled": .boolean(settings.isAutoExtractEnabled),
                "bt_max_download": .integer(settings.btDownloadLimit),
                "bt_max_upload": .integer(settings.btUploadLimit),
                "http_max_download": .integer(settings.httpDownloadLimit),
                "ftp_max_download": .integer(settings.ftpDownloadLimit),
                "nzb_max_download": .integer(settings.nzbDownloadLimit),
                "emule_max_download": .integer(settings.emuleDownloadLimit),
                "emule_max_upload": .integer(settings.emuleUploadLimit)
            ]
        )
        if capabilities[DsmAPIName.downloadStationSchedule]?.selectedVersion != nil {
            try await callVoid(
                DsmAPIName.downloadStationSchedule,
                method: "setconfig",
                parameters: [
                    "enabled": .boolean(settings.isScheduleEnabled),
                    "emule_enabled": .boolean(settings.isEMuleScheduleEnabled)
                ]
            )
        }

        let confirmed = try await loadDownloadStationSettings()
        guard confirmed == settings else {
            throw verificationError(L10n.string("shared.59b0fabe649e326a"))
        }
    }

    public func controlDownloadTasks(
        ids: [String],
        action: DownloadStationTaskAction
    ) async throws {
        let ids = try validatedIDs(ids)
        guard let method = Self.downloadControlMethod(for: action) else { throw unavailableError() }
        try ensureNoDownloadEdit(ids)
        try await callVoid(
            preferredDownloadTaskAPI(),
            method: method,
            parameters: ["id": .string(ids.joined(separator: ","))]
        )
    }

    public nonisolated var supportsDownloadDestinationEditing: Bool {
        guard let capability = capabilities[DsmAPIName.downloadStationTask] else { return false }
        return capability.name == DsmAPIName.downloadStationTask && capability.selectedVersion != nil
            && capability.minVersion <= 1 && capability.maxVersion >= 2 && capability.requestFormat == .form
    }

    /// 官方 Task.edit v2；逐任务返回值与随后的实际位置都必须核对。
    public func changeDownloadTaskDestination(_ change: DownloadTaskDestinationChange,
        willSubmit: @escaping @Sendable () async throws -> Void
    ) async throws -> DownloadTaskDestinationOutcome {
        guard supportsDownloadDestinationEditing else { throw unavailableError() }
        guard change.isValid, !activeDownloadEdits.contains(change.taskID), pendingDownloadEdits[change.taskID] == nil,
              !activeDownloadRemovals.contains(change.taskID), pendingDownloadRemovals[change.taskID] == nil,
              !activeDownloadControlKeys.contains(where: { $0.taskID == change.taskID }),
              !pendingDownloadControlReviews.keys.contains(where: { $0.taskID == change.taskID }),
              activeDeletionIDsByOperation["downloadTaskDelete"]?.contains(change.taskID) != true else {
            throw validationError(L10n.string("download.edit.changed"))
        }
        activeDownloadEdits.insert(change.taskID)
        defer { activeDownloadEdits.remove(change.taskID) }
        guard let task = try await loadOfficialDownloadControlTask(id: change.taskID),
              change.matchesIdentity(task), task.destination == change.original else { return .changed }
        try Task.checkCancellation()
        try await willSubmit()
        if Task.isCancelled { return .cancelledBeforeSubmission }
        pendingDownloadEdits[change.taskID] = change
        do {
            let value = try await callOfficialDownloadTask(method: "edit",
                parameters: ["id": .string(change.taskID), "destination": .string(change.desired)], version: 2)
            // 不接受缺少条目、重复编号、其他任务编号或隐式成功。
            guard let items = value.array, items.count == 1, case .string(let id) = items[0]["id"], id == change.taskID,
                  case .number(let raw) = items[0]["error"], let code = Int(exactly: raw) else { return .pending }
            if code != 0 {
                guard Self.downloadEditRejection(code) != nil else { return .pending }
                pendingDownloadEdits[change.taskID] = nil
                return Self.downloadEditRejection(code)!
            }
        } catch let error as AppError {
            if let code = error.dsmCode, let rejection = Self.downloadEditRejection(code) {
                pendingDownloadEdits[change.taskID] = nil
                return rejection
            }
            return .pending
        } catch { return .pending }
        return (try? await reviewDownloadTaskDestination(change)) ?? .pending
    }

    /// 重启恢复只读；原值未变化仍不能证明旧请求没有执行。
    public func reviewDownloadTaskDestination(_ change: DownloadTaskDestinationChange) async throws -> DownloadTaskDestinationOutcome {
        guard change.isValid else { throw validationError(L10n.string("download.edit.changed")) }
        guard let task = try await loadOfficialDownloadControlTask(id: change.taskID), change.matchesIdentity(task) else {
            if pendingDownloadEdits[change.taskID] == change { pendingDownloadEdits[change.taskID] = nil }
            return .changed
        }
        guard task.destination == change.desired else { return .pending }
        if pendingDownloadEdits[change.taskID] == change { pendingDownloadEdits[change.taskID] = nil }
        return .complete(task)
    }

    private static func downloadEditRejection(_ code: Int) -> DownloadTaskDestinationOutcome? {
        switch code {
        case 105, 402: .denied
        case 404: .changed
        case 101...104, 106, 107, 400, 401, 403, 405...408: .rejected
        default: nil
        }
    }

    public func controlDownloadTaskResult(
        _ request: DownloadTaskControlRequest
    ) async throws -> DownloadTaskControlOutcome {
        try await controlDownloadTaskResult(request, willSubmit: { _ in })
    }

    /// 移动恢复队列在最新状态检查之后、发送之前保存记录；失败必须阻止发送。
    public func controlDownloadTaskResult(
        _ request: DownloadTaskControlRequest,
        willSubmit: @escaping @Sendable (DownloadStationTask) async throws -> Void
    ) async throws -> DownloadTaskControlOutcome {
        guard !activeDownloadEdits.contains(request.task.id), pendingDownloadEdits[request.task.id] == nil,
              !activeDownloadRemovals.contains(request.task.id), pendingDownloadRemovals[request.task.id] == nil else {
            throw validationError(L10n.string("download.edit.pending-help"))
        }
        guard let taskID = Self.nonEmpty(request.task.id), taskID == request.task.id,
              !taskID.contains(","), !taskID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return try downloadControlOutcome(
                status: .confirmedFailure,
                action: request.action,
                taskID: request.task.id,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .validation,
                tag: "download-task.control.invalid"
            )
        }
        guard Self.downloadControlMethod(for: request.action) != nil else {
            return try downloadControlOutcome(
                status: .unsupported,
                action: request.action,
                taskID: taskID,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                tag: "download-task.control.unsupported"
            )
        }
        guard officialDownloadTaskV1Capability() != nil else {
            return try downloadControlOutcome(
                status: .unsupported,
                action: request.action,
                taskID: taskID,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                tag: "download-task.control.unsupported"
            )
        }
        if Task.isCancelled {
            return try downloadControlOutcome(
                status: .cancelledBeforeSubmission,
                action: request.action,
                taskID: taskID,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 0),
                errorCategory: nil,
                tag: "download-task.control.cancelled-before"
            )
        }

        let key = DownloadTaskControlKey(taskID: taskID, action: request.action.rawValue)
        if pendingDownloadControlReviews[key] != nil {
            return try await finishDownloadControlReview(
                key: key,
                action: request.action,
                statusIfUnconfirmed: .submittedButUnverified
            )
        }
        guard !activeDownloadControlKeys.contains(key) else {
            return try downloadControlOutcome(
                status: .confirmedFailure,
                action: request.action,
                taskID: taskID,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .conflict,
                tag: "download-task.control.duplicate"
            )
        }
        activeDownloadControlKeys.insert(key)
        defer {
            activeDownloadControlKeys.remove(key)
        }

        let baseline: DownloadStationTask
        do {
            guard let loaded = try await loadOfficialDownloadControlTask(id: taskID) else {
                return try downloadControlConflictOutcome(action: request.action, taskID: taskID)
            }
            baseline = loaded
        } catch let error as AppError where error.category == .cancelled {
            return try downloadControlOutcome(
                status: .cancelledBeforeSubmission,
                action: request.action,
                taskID: taskID,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 0),
                errorCategory: nil,
                tag: "download-task.control.cancelled-before"
            )
        }
        guard Self.normalizedDownloadTaskStatus(baseline.status)
            == Self.normalizedDownloadTaskStatus(request.task.status),
            Self.canSubmitDownloadControl(action: request.action, status: baseline.status) else {
            return try downloadControlConflictOutcome(action: request.action, taskID: taskID)
        }
        if Task.isCancelled {
            return try downloadControlOutcome(
                status: .cancelledBeforeSubmission,
                action: request.action,
                taskID: taskID,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 0),
                errorCategory: nil,
                tag: "download-task.control.cancelled-before"
            )
        }

        guard let method = Self.downloadControlMethod(for: request.action) else {
            return try downloadControlOutcome(
                status: .unsupported,
                action: request.action,
                taskID: taskID,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                tag: "download-task.control.unsupported"
            )
        }

        try await willSubmit(baseline)
        if Task.isCancelled {
            return try downloadControlOutcome(status: .cancelledBeforeSubmission, action: request.action,
                taskID: taskID, task: nil, submitted: false, requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 0), errorCategory: nil,
                tag: "download-task.control.cancelled-before")
        }
        do {
            try await callOfficialDownloadTaskV1Void(
                method: method,
                parameters: ["id": .string(taskID)]
            )
            pendingDownloadControlReviews[key] = DownloadTaskControlReview(key: key)
            return try await finishDownloadControlReview(
                key: key,
                action: request.action,
                statusIfUnconfirmed: .submittedButUnverified
            )
        } catch let error as AppError {
            switch error.category {
            case .cancelled:
                pendingDownloadControlReviews[key] = DownloadTaskControlReview(key: key)
                return try await finishDownloadControlReview(
                    key: key,
                    action: request.action,
                    statusIfUnconfirmed: .cancellationRequestedAfterSubmission
                )
            case .permissionDenied:
                return try downloadControlOutcome(
                    status: .permissionDenied,
                    action: request.action,
                    taskID: taskID,
                    task: nil,
                    submitted: true,
                    requiresRefresh: true,
                    counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                    errorCategory: .permission,
                    tag: "download-task.control.permission"
                )
            default:
                pendingDownloadControlReviews[key] = DownloadTaskControlReview(key: key)
                return try await finishDownloadControlReview(
                    key: key,
                    action: request.action,
                    statusIfUnconfirmed: .submittedButUnverified
                )
            }
        } catch {
            pendingDownloadControlReviews[key] = DownloadTaskControlReview(key: key)
            return try await finishDownloadControlReview(
                key: key,
                action: request.action,
                statusIfUnconfirmed: .submittedButUnverified
            )
        }
    }

    /// 应用重启后的控制恢复只读取当前任务，绝不再次调用暂停或继续。
    public func loadDownloadTaskControlState(id: String) async throws -> DownloadStationTask? {
        let ids = try validatedIDs([id])
        guard ids.count == 1, id == ids[0], !id.contains(","),
              !id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              officialDownloadTaskV1Capability() != nil else {
            throw AppError(category: .apiUnavailable, isRetryable: false,
                           safeUserMessage: L10n.string("mobile.downloads.control.unsupported.message"))
        }
        return try await loadOfficialDownloadControlTask(id: ids[0])
    }

    /// 调用方已将终态持久保存后，结束旧的进程内回读保护；不发送 NAS 请求。
    public func acknowledgeDownloadTaskControlResult(id: String, action: DownloadStationTaskAction) {
        pendingDownloadControlReviews[DownloadTaskControlKey(taskID: id, action: action.rawValue)] = nil
    }

    public nonisolated var supportsDownloadTaskRemoval: Bool { officialDownloadTaskV1Capability() != nil }

    /// 冻结目标后逐项提交。写前保存失败、目标改变或无公开能力时不得发送。
    public func removeDownloadTask(_ removal: DownloadTaskRemoval,
        willSubmit: @escaping @Sendable () async throws -> Void
    ) async throws -> DownloadTaskRemovalOutcome {
        guard supportsDownloadTaskRemoval else { throw unavailableError() }
        guard removal.isValid, !activeDownloadRemovals.contains(removal.taskID), pendingDownloadRemovals[removal.taskID] == nil,
              !activeDownloadEdits.contains(removal.taskID), pendingDownloadEdits[removal.taskID] == nil,
              !activeDownloadControlKeys.contains(where: { $0.taskID == removal.taskID }),
              !pendingDownloadControlReviews.keys.contains(where: { $0.taskID == removal.taskID }),
              activeDeletionIDsByOperation["downloadTaskDelete"]?.contains(removal.taskID) != true else {
            throw validationError(L10n.string("download.removal.changed"))
        }
        activeDownloadRemovals.insert(removal.taskID)
        defer { activeDownloadRemovals.remove(removal.taskID) }
        guard let task = try await loadOfficialDownloadControlTask(id: removal.taskID), removal.matches(task) else { return .changed }
        try Task.checkCancellation()
        try await willSubmit()
        if Task.isCancelled { return .cancelledBeforeSubmission }
        pendingDownloadRemovals[removal.taskID] = removal
        do {
            let value = try await callOfficialDownloadTask(method: "delete", parameters: [
                "id": .string(removal.taskID), "force_complete": .boolean(removal.forceComplete)
            ], version: 1)
            guard let items = value.array, items.count == 1, case .string(let id) = items[0]["id"], id == removal.taskID,
                  case .number(let raw) = items[0]["error"], let code = Int(exactly: raw) else { return .pending }
            if code != 0 {
                guard let rejection = Self.downloadRemovalRejection(code) else { return .pending }
                pendingDownloadRemovals[removal.taskID] = nil; return rejection
            }
        } catch let error as AppError {
            if let code = error.dsmCode, let rejection = Self.downloadRemovalRejection(code) {
                pendingDownloadRemovals[removal.taskID] = nil; return rejection
            }
            return .pending
        } catch { return .pending }
        return (try? await reviewDownloadTaskRemoval(removal)) ?? .pending
    }

    /// 完整读取失败不能冒充消失；重启恢复不重复删除，也不推断下载文件状态。
    public func reviewDownloadTaskRemoval(_ removal: DownloadTaskRemoval) async throws -> DownloadTaskRemovalOutcome {
        guard removal.isValid, supportsDownloadTaskRemoval else { throw unavailableError() }
        let task = try await loadOfficialDownloadControlTask(id: removal.taskID)
        let outcome: DownloadTaskRemovalOutcome = task.map { removal.matches($0) ? .pending : .changed } ?? .removed
        if outcome != .pending, pendingDownloadRemovals[removal.taskID] == removal { pendingDownloadRemovals[removal.taskID] = nil }
        return outcome
    }

    private static func downloadRemovalRejection(_ code: Int) -> DownloadTaskRemovalOutcome? {
        switch code {
        case 105, 402: .denied
        case 404: .changed
        case 101...104, 106, 107, 400, 401, 403, 405...408: .rejected
        default: nil
        }
    }

    public func deleteDownloadTasks(ids: [String], removeData: Bool) async throws {
        try ensureNoDownloadEdit(ids)
        let ids = try validatedIDs(ids)
        try await callVoid(
            preferredDownloadTaskAPI(),
            method: "delete",
            parameters: [
                "id": .string(ids.joined(separator: ",")),
                "force_complete": .boolean(removeData)
            ]
        )
        let remaining = try await loadDownloadDeletionIDs()
        guard ids.allSatisfy({ !remaining.contains($0) }) else {
            throw verificationError(L10n.string("shared.7ca744fb7c598d20"))
        }
    }

    /// 通过任务列表确认移除/结束任务。removeData 是兼容旧调用的历史参数名，实际映射
    /// force_complete：true 将未完成文件移入目标目录，并非删除数据；列表消失不能证明文件移动完成。
    public func deleteDownloadTasksResult(
        ids: [String],
        removeData: Bool
    ) async throws -> MutationResult {
        try ensureNoDownloadEdit(ids)
        let api = preferredDownloadTaskAPI()
        return try await performServiceDeletion(
            ids: ids,
            context: ServiceDeletionContext(
                operation: "downloadTaskDelete",
                localizationPrefix: "download-task.delete"
            ),
            isSupported: capabilities[api]?.selectedVersion != nil,
            loadCurrentIDs: {
                try await self.loadDownloadDeletionIDs()
            },
            submit: { targets in
                try await self.callVoid(
                    api,
                    method: "delete",
                    parameters: [
                        "id": .string(targets.joined(separator: ",")),
                        "force_complete": .boolean(removeData)
                    ]
                )
            }
        )
    }

    private func loadDownloadDeletionIDs() async throws -> Set<String> {
        if capabilities[DsmAPIName.downloadStationTask]?.selectedVersion != nil {
            return Set(try await loadAllOfficialDownloadTasks().map(\.id))
        }
        return Set(try await loadDownloadStation().tasks.map(\.id))
    }

    public func loadContainerManager() async throws -> ContainerManagerSnapshot {
        async let containersValue = containerInventoryPayload()
        async let imagesValue = containerImageListResult()
        async let networksValue = supplementaryCall(DsmAPIName.dockerNetwork, methods: ["list"])
        async let projectsValue = supplementaryCall(DsmAPIName.dockerProject, methods: ["list"])
        async let eventsValue = containerActivityLogs()
        let (containerJSON, imageResult, networkResult, projectResult, eventResult) =
            try await (containersValue, imagesValue, networksValue, projectsValue, eventsValue)

        let supplementaryResults: [(ContainerManagerSection, SupplementaryServiceResult)] = [
            (.images, imageResult),
            (.networks, networkResult),
            (.projects, projectResult),
            (.logs, eventResult)
        ]
        let unavailableSections = Set(supplementaryResults.compactMap { section, result in
            result.isUnavailable ? section : nil
        })
        var failedSections = Set(supplementaryResults.compactMap { section, result in
            result.isFailed ? section : nil
        })
        let containers = try Self.strictMappedItems(
            containerJSON,
            keys: ["containers", "container"],
            parser: Self.container
        )
        var images: [ContainerImage] = []
        if case .available(let value) = imageResult {
            do {
                let parsed = try Self.containerImages(value)
                let usedIDs = try Self.containerImageUsage(parsed, containers: containerJSON)
                images = parsed.map { image in
                    ContainerImage(id: image.id, repository: image.repository, tag: image.tag,
                        sizeBytes: image.sizeBytes, createdAt: image.createdAt, isInUse: usedIDs.contains(image.id), sourceImageID: image.sourceImageID)
                }
            } catch { failedSections.insert(.images) }
        }
        let networks: [ContainerNetwork] = Self.strictSupplementaryItems(
            networkResult,
            keys: ["networks", "network"],
            parser: Self.containerNetwork,
            failedSection: .networks,
            failedSections: &failedSections
        )
        let projects = Self.containerProjects(projectResult, failedSections: &failedSections)
        let events = Self.strictSupplementaryEvents(
            eventResult,
            keys: ["logs", "events"],
            failedSection: .logs,
            failedSections: &failedSections
        )

        return ContainerManagerSnapshot(
            containers: containers,
            images: images,
            networks: networks,
            projects: projects,
            events: events,
            unavailableSections: unavailableSections,
            failedSections: failedSections,
            canCreateNetworks: containerNetworkCreationEnabled && supportsContainerNetworkManagement
        )
    }

    /// 官方日志页使用 load 动作；按返回总数读取后续页，避免活动记录被静默截断。
    private func containerActivityLogs() async throws -> SupplementaryServiceResult {
        var records: [ServiceJSON] = []
        let pageSize = 1000
        while true {
            let offset = records.count
            let result = try await supplementaryCall(
                DsmAPIName.dockerLog,
                methods: ["list"],
                parameters: [
                    "action": .string("load"), "offset": .integer(offset), "limit": .integer(pageSize),
                    "sort_by": .string("time"), "sort_dir": .string("DESC"),
                    "loglevel": .string(""), "filter_content": .string(""),
                    "datefrom": .integer(0), "dateto": .integer(0)
                ]
            )
            guard case .available(let value) = result else { return result }
            let page: [[String: ServiceJSON]]
            do { page = try Self.strictRootObjects(value, keys: ["logs", "events"]) }
            catch { return .failed }
            if let returnedOffset = value.firstInteger(["offset"]), returnedOffset != offset { return .failed }
            records.append(contentsOf: page.map(ServiceJSON.object))
            guard let total = value.firstInteger(["total"]), records.count < total else {
                return .available(.object(["logs": .array(records)]))
            }
            guard !page.isEmpty else { return .failed }
        }
    }

    /// 移动端首个 Container Manager 闭环固定使用已记录的内部 Container.list v1。
    /// 只读取实例清单，不读取映像、网络、项目、事件、资源、进程或日志。
    public func loadContainerInventory() async throws -> ContainerInventorySnapshot {
        let value = try await containerInventoryPayload()
        return ContainerInventorySnapshot(
            source: .internalAPI,
            containers: try Self.internalContainerV1Inventory(from: value)
        )
    }

    private func containerInventoryPayload() async throws -> ServiceJSON {
        guard let capability = capabilities[DsmAPIName.dockerContainer],
              capability.name == DsmAPIName.dockerContainer, capability.minVersion == 1,
              capability.maxVersion >= 1,
              capability.selectedVersion != nil else {
            throw unavailableError()
        }
        let value: ServiceJSON
        do {
            value = try await client.call(
                path: capability.path,
                api: capability.name,
                version: 1,
                method: "list",
                requestFormat: capability.requestFormat,
                parameters: [
                    "offset": .integer(0),
                    "limit": .integer(-1),
                    "type": .string("all")
                ],
                credential: credential,
                as: ServiceJSON.self
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
        return value
    }

    public func controlContainers(ids: [String], action: ContainerAction) async throws {
        try await controlContainers(ids: ids, action: action, expected: nil, observer: nil)
    }

    public func loadContainerControlStates() async throws -> [ContainerControlState] {
        let values = try await containerControlTargets(requiredIDs: nil)
        for target in values {
            if let review = pendingContainerControls[target.item.id],
               Self.containerControlVerified(target, review: review) {
                pendingContainerControls[target.item.id] = nil
            }
        }
        let remaining = Set(values.map { $0.item.id })
        for id in Set(pendingContainerDeletions.keys).subtracting(remaining) { pendingContainerDeletions[id] = nil }
        return values.map(\.controlState)
    }

    public func controlContainer(_ target: ContainerControlState, action: ContainerAction,
                                 observer: @escaping ContainerControlObserver) async throws {
        guard target.supports(action) else { throw containerMutationChangedError() }
        try await controlContainers(ids: [target.id], action: action, expected: target, observer: observer)
    }

    private func controlContainers(ids: [String], action: ContainerAction, expected: ContainerControlState?,
                                   observer: ContainerControlObserver?) async throws {
        let ids = try validatedIDs(ids)
        let targets = Set(ids)
        guard activeContainerMutationIDs.isDisjoint(with: targets), targets.isDisjoint(with: Set(pendingContainerDeletions.keys)) else {
            throw containerMutationChangedError()
        }
        activeContainerMutationIDs.formUnion(targets)
        defer { activeContainerMutationIDs.subtract(targets) }
        for id in ids {
            try Task.checkCancellation()
            let current = try await containerControlTargets(requiredIDs: [id])
            guard let target = current.first(where: { $0.item.id == id }),
                  current.filter({ $0.item.name == target.item.name }).count == 1 else { throw containerMutationChangedError() }
            if let expected, target.controlState != expected { throw containerMutationChangedError() }
            guard !pendingContainerControls.contains(where: { $0.key != id && $0.value.name == target.item.name }),
                  !pendingContainerDeletions.values.contains(target.item.name) else { throw containerMutationChangedError() }
            if let pending = pendingContainerControls[id] {
                // 移动恢复只通过独立读取解除旧操作，不能借新确认重放原提交。
                guard expected == nil else { throw containerControlUnverifiedError() }
                guard pending.action == action else { throw containerMutationChangedError() }
                guard Self.containerControlVerified(target, review: pending) else { throw containerControlUnverifiedError() }
                pendingContainerControls[id] = nil
                continue
            }
            if target.managedByPackage == true { throw containerManagedError() }
            guard target.managedByPackage == false, target.paused == false, let restarting = target.restarting, let running = target.running else { throw containerMutationChangedError() }
            if action == .start && restarting { throw containerMutationChangedError() }
            if (action == .start && running) || (action == .stop && !running && !restarting) { continue }
            if action == .restart && (!(running || restarting) || target.startedAt == nil) { throw containerMutationChangedError() }
            let review = ContainerControlReview(action: action, name: target.item.name, startedAt: target.startedAt)
            try await observer?(.willSubmit)
            pendingContainerControls[id] = review
            do {
                try await callContainerMutation(method: action.rawValue, name: target.item.name)
            } catch let error as AppError {
                if error.dsmCode != nil {
                    pendingContainerControls[id] = nil
                    try await observer?(.rejected)
                }
                throw error
            }
            try await observer?(.accepted)
            let refreshed = try await containerControlTargets(requiredIDs: [id])
            guard let after = refreshed.first(where: { $0.item.id == id }), Self.containerControlVerified(after, review: review) else {
                throw containerControlUnverifiedError()
            }
            pendingContainerControls[id] = nil
            try await observer?(.verified)
        }
    }

    public func deleteContainers(ids: [String]) async throws {
        let result = try await deleteContainersResult(ids: ids)
        guard result.status == .confirmedSuccess else {
            throw AppError(category: result.status == .permissionDenied ? .permissionDenied : .partialFailure,
                isRetryable: false, safeUserMessage: result.localizationKey.map { L10n.string($0) }
                    ?? L10n.string("shared.830e41a22a4f104d"))
        }
    }

    /// 容器删除使用内部接口；提交后通过容器列表逐项确认，未知结果不得自动重放。
    public func deleteContainersResult(ids: [String]) async throws -> MutationResult {
        try await deleteContainersResult(ids: ids, expected: nil, observer: nil)
    }

    /// 移动端沿同一删除流水线绑定确认快照，并在每个不可重放边界保存原记录。
    public func deleteContainer(_ target: ContainerControlState,
                                observer: @escaping ContainerControlObserver) async throws {
        guard target.canDelete else { throw containerMutationChangedError() }
        let result = try await deleteContainersResult(ids: [target.id], expected: target, observer: observer)
        guard result.status == .confirmedSuccess else {
            throw containerControlUnverifiedError()
        }
    }

    private func deleteContainersResult(ids: [String], expected: ContainerControlState?,
                                        observer: ContainerControlObserver?) async throws -> MutationResult {
        let context = ServiceDeletionContext(
            operation: "containerDelete",
            localizationPrefix: "container.delete"
        )
        if Task.isCancelled {
            if expected != nil { throw CancellationError() }
            return try deletionCancellationBeforeSubmission(context: context)
        }

        let targets: [String]
        do {
            targets = try validatedIDs(ids)
        } catch let error as AppError {
            if expected != nil || Self.imageManagementTrustError(error) { throw error }
            return try deletionPreflightResult(
                error,
                targetCount: max(ids.count, 1),
                context: context
            )
        } catch {
            if expected != nil || Self.imageManagementTrustError(error) { throw error }
            return try deletionUnexpectedPreflightResult(
                targetCount: max(ids.count, 1),
                context: context
            )
        }
        guard capabilities[DsmAPIName.dockerContainer]?.selectedVersion != nil else {
            if expected != nil { throw unavailableError() }
            return try deletionUnsupportedResult(
                targetCount: targets.count,
                context: context
            )
        }

        let targetSet = Set(targets)
        guard activeContainerMutationIDs.isDisjoint(with: targetSet), targetSet.isDisjoint(with: Set(pendingContainerControls.keys)) else {
            if expected != nil { throw containerMutationChangedError() }
            return try deletionDuplicateResult(
                targetCount: targets.count,
                context: context
            )
        }
        activeContainerMutationIDs.formUnion(targetSet)
        defer { activeContainerMutationIDs.subtract(targetSet) }

        let pendingIDs = Set(pendingContainerDeletions.keys)
        if !pendingIDs.isDisjoint(with: targetSet) {
            guard expected == nil else { throw containerControlUnverifiedError() }
            guard targetSet.isSubset(of: pendingIDs) else {
                return try deletionDuplicateResult(targetCount: targets.count, context: context)
            }
            do {
                let remaining = Set(try await loadContainerInventory().containers.map(\.id))
                for id in targetSet.subtracting(remaining) { pendingContainerDeletions[id] = nil }
                return try deletionReadbackResult(targets: targetSet, remaining: remaining, context: context)
            } catch let error as AppError {
                if Self.imageManagementTrustError(error) { throw error }
                return try deletionReadbackFailureResult(error, targetCount: targets.count, context: context)
            } catch {
                if Self.imageManagementTrustError(error) { throw error }
                return try deletionUnexpectedReadbackResult(targetCount: targets.count, context: context)
            }
        }

        let names: [String: String]
        do {
            let definitions = try await containerControlTargets(requiredIDs: targetSet)
            let inventory = definitions.map(\.item)
            let currentIDs = Set(inventory.map(\.id))
            guard targetSet.isSubset(of: currentIDs) else {
                if expected != nil { throw containerMutationChangedError() }
                return try deletionMissingTargetResult(
                    targetCount: targets.count,
                    context: context
                )
            }
            guard Set(inventory.map(\.name)).count == inventory.count else { throw containerMutationChangedError() }
            for target in definitions where targetSet.contains(target.item.id) {
                if let expected, target.controlState != expected { throw containerMutationChangedError() }
                if target.managedByPackage == true { throw containerManagedError() }
                guard target.managedByPackage == false, target.running == false, target.restarting == false, target.paused == false else { throw containerMutationChangedError() }
                guard !pendingContainerDeletions.values.contains(target.item.name),
                      !pendingContainerControls.values.contains(where: { $0.name == target.item.name }) else { throw containerMutationChangedError() }
            }
            names = Dictionary(uniqueKeysWithValues: inventory.map { ($0.id, $0.name) })
        } catch let error as AppError {
            if expected != nil || Self.imageManagementTrustError(error) { throw error }
            return try deletionPreflightResult(
                error,
                targetCount: targets.count,
                context: context
            )
        } catch {
            if expected != nil || Self.imageManagementTrustError(error) { throw error }
            return try deletionUnexpectedPreflightResult(
                targetCount: targets.count,
                context: context
            )
        }

        if Task.isCancelled {
            if expected != nil { throw CancellationError() }
            return try deletionCancellationBeforeSubmission(context: context)
        }

        var submittedCount = 0
        // 旧批量调用也须保留已发送前项与明确未提交后项的区别。
        func stopped(_ result: MutationResult, unknown: Int) throws -> MutationResult {
            guard submittedCount > 0 else { return result }
            return try MutationResult(status: result.status == .cancelledBeforeSubmission ? .cancellationRequestedAfterSubmission : result.status,
                operation: context.operation, submitted: true, requiresRefresh: result.requiresRefresh || unknown > 0,
                counts: .init(succeeded: 0, failed: targets.count - unknown, unknown: unknown),
                errorCategory: result.errorCategory, localizationKey: result.localizationKey, diagnosticTag: result.diagnosticTag)
        }
        for id in targets {
            if Task.isCancelled {
                if expected != nil { throw CancellationError() }
                if submittedCount == 0 { return try deletionCancellationBeforeSubmission(context: context) }
                return try deletionCancellationAfterSubmission(targetCount: submittedCount, context: context)
            }
            // 批量前项等待期间名称可能被复用；后续项在提交边界之前单独预检。
            do {
                if id != targets.first {
                    let refreshed = try await containerControlTargets(requiredIDs: [id])
                    guard let current = refreshed.first(where: { $0.item.id == id }), current.item.name == names[id],
                          current.controlState.canDelete else { throw containerMutationChangedError() }
                }
            } catch let error as AppError {
                if expected != nil || Self.imageManagementTrustError(error) { throw error }
                let result = try deletionPreflightResult(error, targetCount: targets.count, context: context)
                return try stopped(result, unknown: submittedCount)
            } catch {
                if expected != nil || Self.imageManagementTrustError(error) { throw error }
                let result = try deletionUnexpectedPreflightResult(targetCount: targets.count, context: context)
                return try stopped(result, unknown: submittedCount)
            }
            // 本地保存/权限失败不进入网络提交的 catch，不能被包装为已发送。
            try await observer?(.willSubmit)
            pendingContainerDeletions[id] = names[id]!
            submittedCount += 1
            do {
                try await callContainerMutation(method: "delete", name: names[id]!)
            } catch let error as AppError {
                let rejected = error.dsmCode != nil
                if rejected {
                    pendingContainerDeletions[id] = nil
                    try await observer?(.rejected)
                }
                if expected != nil || Self.imageManagementTrustError(error) { throw error }
                let result = try deletionSubmissionResult(error, targetCount: targets.count, context: context)
                return try stopped(result, unknown: submittedCount - (rejected ? 1 : 0))
            } catch {
                if expected != nil || Self.imageManagementTrustError(error) { throw error }
                let result = try deletionUnexpectedSubmissionResult(targetCount: targets.count, context: context)
                return try stopped(result, unknown: submittedCount)
            }
            try await observer?(.accepted)
        }

        if Task.isCancelled {
            if expected != nil { throw CancellationError() }
            return try deletionCancellationAfterSubmission(
                targetCount: targets.count,
                context: context
            )
        }
        let remaining: Set<String>
        do {
            remaining = Set(try await loadContainerInventory().containers.map(\.id))
        } catch let error as AppError {
            if expected != nil || Self.imageManagementTrustError(error) { throw error }
            return try deletionReadbackFailureResult(error, targetCount: targets.count, context: context)
        } catch {
            if expected != nil || Self.imageManagementTrustError(error) { throw error }
            return try deletionUnexpectedReadbackResult(targetCount: targets.count, context: context)
        }
        for id in targetSet.subtracting(remaining) { pendingContainerDeletions[id] = nil }
        let result = try deletionReadbackResult(targets: targetSet, remaining: remaining, context: context)
        if result.status == .confirmedSuccess { try await observer?(.verified) }
        return result
    }

    /// 官方内部 v1 使用名称寻址；名称只能来自当前 ID 对应的实例清单。
    private func callContainerMutation(method: String, name: String) async throws {
        guard let capability = capabilities[DsmAPIName.dockerContainer],
              capability.name == DsmAPIName.dockerContainer, capability.minVersion == 1, capability.maxVersion >= 1,
              capability.selectedVersion != nil else { throw unavailableError() }
        var parameters: [String: DsmParameterValue] = ["name": .string(name)]
        if method == "delete" {
            parameters["force"] = .boolean(false)
            parameters["preserve_profile"] = .boolean(false)
        }
        do {
            try await client.callVoid(path: capability.path, api: capability.name, version: 1,
                method: method, requestFormat: capability.requestFormat, parameters: parameters, credential: credential)
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
    }

    private struct ContainerControlTarget {
        let item: ContainerInventoryItem
        let running: Bool?
        let paused: Bool?
        let restarting: Bool?
        let startedAt: Date?
        var managedByPackage: Bool?
        let projectName: String?

        var controlState: ContainerControlState {
            .init(id: item.id, name: item.name, running: running, paused: paused,
                  restarting: restarting, startedAt: startedAt, managedByPackage: managedByPackage)
        }
    }

    private struct ContainerControlReview {
        let action: ContainerAction
        let name: String
        let startedAt: Date?
    }

    private func containerControlTargets(requiredIDs: Set<String>?) async throws -> [ContainerControlTarget] {
        let value = try await containerInventoryPayload()
        let items = try Self.internalContainerV1Inventory(from: value)
        let objects = try Self.strictRootObjects(value, keys: ["containers"])
        guard Set(items.map(\.name)).count == items.count else { throw containerMutationChangedError() }
        var targets = zip(items, objects).map { pair in
            let (item, object) = pair
            var runtime: [String: ServiceJSON] = [:]
            if case .object(let fields)? = object["State"] { runtime = fields }
            func flag(_ key: String) -> Bool? {
                if case .boolean(let value)? = runtime[key] { return value }
                return nil
            }
            var startedAt: Date?
            if let text = Self.officialNonEmptyString(runtime["StartedAt"]), !text.hasPrefix("0001-") {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                startedAt = formatter.date(from: text)
                if startedAt == nil { formatter.formatOptions = [.withInternetDateTime]; startedAt = formatter.date(from: text) }
            }
            var managed: Bool?
            if case .boolean(let value)? = object["is_package"] { managed = value }
            var projectName: String?
            if case .object(let labels)? = object["Labels"] {
                if let label = labels["com.docker.compose.project"] {
                    projectName = Self.officialNonEmptyString(label)
                    if projectName == nil, managed != true { managed = nil }
                }
            } else if let labels = object["Labels"] {
                if case .null = labels { } else if managed != true { managed = nil }
            }
            return ContainerControlTarget(item: item, running: flag("Running"), paused: flag("Paused"),
                restarting: flag("Restarting"), startedAt: startedAt, managedByPackage: managed, projectName: projectName)
        }
        if targets.contains(where: { (requiredIDs?.contains($0.item.id) ?? true) && $0.managedByPackage == false && $0.projectName != nil }) {
            guard let capability = capabilities[DsmAPIName.dockerProject], capability.name == DsmAPIName.dockerProject, capability.minVersion == 1,
                  capability.maxVersion >= 1, capability.selectedVersion != nil else { throw unavailableError() }
            let projects: ServiceJSON
            do {
                projects = try await client.call(path: capability.path, api: capability.name, version: 1, method: "list",
                    requestFormat: capability.requestFormat, parameters: [:], credential: credential, as: ServiceJSON.self)
            } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
            guard case .object(let entries) = projects else { throw containerMutationChangedError() }
            var ownership: [String: Bool] = [:]
            for entry in entries.values {
                guard case .object(let value) = entry, let name = Self.officialNonEmptyString(value["name"]), ownership[name] == nil else { throw containerMutationChangedError() }
                let managed: Bool
                if let marker = value["is_package"] {
                    guard case .boolean(let flag) = marker else { throw containerMutationChangedError() }
                    managed = flag
                } else { managed = false }
                ownership[name] = managed
            }
            for index in targets.indices where (requiredIDs?.contains(targets[index].item.id) ?? true) && targets[index].managedByPackage == false {
                if let name = targets[index].projectName { targets[index].managedByPackage = ownership[name] ?? false }
            }
        }
        return targets
    }

    private static func containerControlVerified(_ target: ContainerControlTarget, review: ContainerControlReview) -> Bool {
        target.item.name == review.name && target.controlState.verifies(review.action, previousStartedAt: review.startedAt)
    }

    private func containerMutationChangedError() -> AppError {
        AppError(category: .conflict, isRetryable: false, safeUserMessage: L10n.string("container.control.changed"))
    }

    private func containerControlUnverifiedError() -> AppError {
        AppError(category: .partialFailure, isRetryable: false, safeUserMessage: L10n.string("container.control.unverified"))
    }

    private func containerManagedError() -> AppError {
        AppError(category: .permissionDenied, isRetryable: false, safeUserMessage: L10n.string("container.control.managed"))
    }

    public func searchContainerImages(query: String) async throws -> [ContainerRegistryImage] {
        let query = try validatedName(query, message: L10n.string("shared.7031852e2ed8042f"))
        guard let capability = capabilities[DsmAPIName.dockerRegistry], capability.name == DsmAPIName.dockerRegistry,
              capability.minVersion == 1, capability.maxVersion >= 1, capability.selectedVersion != nil else { throw unavailableError() }
        let value: ServiceJSON
        do {
            // Registry 的最高版本不代表每个方法都支持；官方搜索固定使用 v1，v2 返回 103。
            value = try await client.call(path: capability.path, api: capability.name, version: 1, method: "search",
                requestFormat: capability.requestFormat, parameters: [
                "offset": .integer(0),
                "limit": .integer(50),
                "page_size": .integer(50),
                "q": .string(query)
            ], credential: credential, as: ServiceJSON.self)
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
        guard let rows = value["data"]?.array else { throw Self.invalidServiceResponseStatic() }
        return try rows.map { row in
            guard let object = row.object, let image = Self.registryImage(object),
                  ContainerImagePullRequest.isValidTarget(repository: image.name, tag: "latest") else {
                throw Self.invalidServiceResponseStatic()
            }
            return image
        }
    }

    public func loadContainerImageTags(repository: String) async throws -> [String] {
        let repository = try validatedName(repository, message: L10n.string("shared.73537393048d9596"))
        guard let capability = capabilities[DsmAPIName.dockerRegistry], capability.name == DsmAPIName.dockerRegistry,
              capability.minVersion == 1, capability.maxVersion >= 1, capability.selectedVersion != nil else { throw unavailableError() }
        let value: ServiceJSON
        do {
            value = try await client.call(path: capability.path, api: capability.name, version: 1, method: "tags",
                requestFormat: capability.requestFormat, parameters: ["repo": .string(repository)], credential: credential, as: ServiceJSON.self)
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
        // 已记录的标签既可为字符串数组，也可为 tag/name 对象；畸形项不是空列表。
        let containers: [ServiceJSON]
        if case .array = value {
            containers = [value]
        } else if let root = value.object {
            containers = ["data", "tags", "items"].compactMap { root[$0] }
        } else {
            throw Self.invalidServiceResponseStatic()
        }
        guard !containers.isEmpty else { throw Self.invalidServiceResponseStatic() }
        var result: [String]?
        for container in containers {
            guard let nodes = container.array else { throw Self.invalidServiceResponseStatic() }
            var tags: [String] = []
            for node in nodes {
                let raw: String
                if case .string(let text) = node {
                    raw = text
                } else if let object = node.object {
                    let fields = ["tag", "name"].compactMap { object[$0] }
                    let strings = fields.compactMap { field -> String? in
                        if case .string(let text) = field { return text }
                        return nil
                    }
                    guard !strings.isEmpty, strings.count == fields.count, Set(strings).count == 1 else {
                        throw Self.invalidServiceResponseStatic()
                    }
                    raw = strings[0]
                } else {
                    throw Self.invalidServiceResponseStatic()
                }
                let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !tag.isEmpty, raw.rangeOfCharacter(from: .controlCharacters) == nil else {
                    throw Self.invalidServiceResponseStatic()
                }
                if !tags.contains(tag) { tags.append(tag) }
            }
            if let previous = result, previous != tags { throw Self.invalidServiceResponseStatic() }
            result = tags
        }
        return result ?? []
    }

    public func pullContainerImage(repository: String, tag: String) async throws {
        let repository = try validatedName(repository, message: L10n.string("shared.0c6ce91d30f67594"))
        let tag = try validatedName(tag, message: L10n.string("shared.6a2c72fe709bf1e8"))
        let result = try await startContainerImagePull(.init(repository: repository, tag: tag, isConfirmed: true))
        guard result.stage == .downloading || result.stage == .ready else {
            throw AppError(category: result.outcome.errorCategory == .permission ? .permissionDenied : .partialFailure,
                isRetryable: false, safeUserMessage: L10n.string("container-image.pull.review-needed"))
        }
    }

    private struct ImagePullOperation: Sendable {
        var request: ContainerImagePullRequest?
        var recovery: ContainerImagePullRecovery
        var progress: ContainerImagePullProgress
    }

    public func canStartContainerImagePull() async -> Bool {
        [DsmAPIName.dockerImage, DsmAPIName.dockerRegistry].allSatisfy { name in
            guard let capability = capabilities[name] else { return false }
            return capability.name == name && capability.minVersion == 1 && capability.maxVersion >= 1 && capability.selectedVersion != nil
        }
    }

    public func startContainerImagePull(_ request: ContainerImagePullRequest) async throws -> ContainerImagePullProgress {
        try await startImagePull(request, observer: nil)
    }

    public func startContainerImagePull(_ request: ContainerImagePullRequest, observer: @escaping ContainerImagePullObserver) async throws -> ContainerImagePullProgress {
        try await startImagePull(request, observer: observer)
    }

    private func startImagePull(_ request: ContainerImagePullRequest, observer: ContainerImagePullObserver?) async throws -> ContainerImagePullProgress {
        if Task.isCancelled { return try imagePullProgress(request, stage: .rejected, status: .cancelledBeforeSubmission, submitted: false) }
        guard request.isValid, request.isConfirmed else { return try imagePullProgress(request, stage: .rejected, submitted: false, error: .validation) }
        guard !imagePullBusy, !imageDeletionActive else { return try imagePullProgress(request, stage: .rejected, submitted: false, error: .conflict) }
        imagePullBusy = true
        defer { imagePullBusy = false }
        if let previous = imagePullOperations[request.id] {
            guard previous.request == request else { return try imagePullProgress(request, stage: .rejected, submitted: false, error: .conflict) }
            if previous.progress.stage.isTerminal { return previous.progress }
            return try await reviewImagePullOperation(id: request.id, preservesTrustError: observer != nil)
        }
        guard await canStartContainerImagePull() else { return try imagePullProgress(request, stage: .rejected, status: .unsupported, submitted: false, error: .unsupported) }
        guard !imagePullOperations.values.contains(where: { !$0.progress.stage.isTerminal && $0.recovery.matches(repository: request.repository, tag: request.tag) }) else {
            return try imagePullProgress(request, stage: .rejected, submitted: false, error: .conflict)
        }
        let baselineIDs: Set<String>
        do {
            let tags = try await loadContainerImageTags(repository: request.repository)
            guard tags.contains(request.tag) else { return try imagePullProgress(request, stage: .rejected, submitted: false, error: .conflict) }
            let images = try await loadContainerImageDefinitions()
            guard images.allSatisfy({ $0.sourceImageID != nil }) else { throw Self.invalidServiceResponseStatic() }
            baselineIDs = Set(images.filter { Self.imageAddress($0) == request.referenceKey }.compactMap(\.sourceImageID))
            guard !pendingImageDeletions.values.flatMap(\.targets).contains(where: { target in
                target.reference == ContainerImagePullRecovery.target(repository: request.repository, tag: request.tag)
                    || (target.isUntagged && baselineIDs.contains(where: { ContainerImagePullRecovery.digest($0) == target.imageID }))
            }) else { return try imagePullProgress(request, stage: .rejected, submitted: false, error: .conflict) }
            try Task.checkCancellation()
        } catch is CancellationError { return try imagePullProgress(request, stage: .rejected, status: .cancelledBeforeSubmission, submitted: false) }
        catch let error as AppError {
            if observer != nil, Self.imageManagementTrustError(error) { throw error }
            if error.category == .cancelled || Task.isCancelled { return try imagePullProgress(request, stage: .rejected, status: .cancelledBeforeSubmission, submitted: false) }
            return try imagePullProgress(request, stage: .rejected, submitted: false, error: serviceMutationErrorCategory(for: error.category))
        }
        catch {
            if observer != nil, Self.imageManagementTrustError(error) { throw error }
            return try imagePullProgress(request, stage: .rejected, submitted: false, error: .network)
        }

        let initial = try imagePullProgress(request, stage: .awaitingReceipt)
        var recovery = ContainerImagePullRecovery(id: request.id,
            target: ContainerImagePullRecovery.target(repository: request.repository, tag: request.tag),
            baselineImageIDs: Set(baselineIDs.map(ContainerImagePullRecovery.digest)))
        try await observer?(.willSubmit(recovery))
        imagePullOperations[request.id] = ImagePullOperation(request: request, recovery: recovery, progress: initial)
        var accepted = false
        do {
            let response = try await containerImageRequest(method: "pull_start", parameters: ["repository": .string(request.repository), "tag": .string(request.tag)])
            recovery.taskID = Self.imagePullTaskID(response["task_id"])
            imagePullOperations[request.id]?.recovery = recovery
            accepted = true
        } catch let error as AppError where error.dsmCode != nil {
            let result = try imagePullProgress(request, stage: .rejected, status: error.category == .permissionDenied ? .permissionDenied : .confirmedFailure,
                error: serviceMutationErrorCategory(for: error.category))
            imagePullOperations[request.id]?.progress = result
            try await observer?(.rejected)
            return result
        } catch {
            if observer != nil, Self.imageManagementTrustError(error) { throw error }
            // 可能已经启动：保留原请求，无回执不得按名称重绑或重发。
        }
        // 回执必须先保存；存储失败不能被当作网络未知后继续读取。
        if accepted { try await observer?(.accepted(recovery)) }
        return try await reviewImagePullOperation(id: request.id, preservesTrustError: observer != nil)
    }

    public func restoreContainerImagePull(_ recovery: ContainerImagePullRecovery) async throws -> ContainerImagePullProgress {
        guard recovery.isValid else { throw Self.invalidServiceResponseStatic() }
        guard !imagePullBusy, !imageDeletionActive else { throw containerMutationChangedError() }
        imagePullBusy = true
        defer { imagePullBusy = false }
        if let previous = imagePullOperations[recovery.id] {
            guard previous.recovery == recovery else { throw containerMutationChangedError() }
            if previous.progress.stage.isTerminal { return previous.progress }
        } else {
            guard !imagePullOperations.values.contains(where: { !$0.progress.stage.isTerminal && $0.recovery.target == recovery.target }) else {
                throw containerMutationChangedError()
            }
            imagePullOperations[recovery.id] = ImagePullOperation(request: nil, recovery: recovery,
                progress: try imagePullProgress(nil, id: recovery.id, stage: recovery.taskID == nil ? .awaitingReceipt : .needsReview))
        }
        // 只有原任务编号可以恢复；无回执时只恢复保护记录，不从清单猜测任务。
        return try await reviewImagePullOperation(id: recovery.id, preservesTrustError: true)
    }

    public func loadContainerImagePulls() async throws -> [ContainerImagePullProgress] {
        imagePullOperations.values.map(\.progress).filter { !$0.stage.isTerminal }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func reviewContainerImagePull(id: UUID) async throws -> ContainerImagePullProgress? {
        guard !imagePullBusy, let operation = imagePullOperations[id] else { return nil }
        if operation.progress.stage.isTerminal { return operation.progress }
        imagePullBusy = true
        defer { imagePullBusy = false }
        return try await reviewImagePullOperation(id: id)
    }

    private func reviewImagePullOperation(id: UUID, preservesTrustError: Bool = false) async throws -> ContainerImagePullProgress {
        guard let operation = imagePullOperations[id] else { throw Self.invalidServiceResponseStatic() }
        var request = operation.request
        var result: ContainerImagePullProgress
        if Task.isCancelled {
            result = try imagePullProgress(request, id: id, stage: operation.recovery.taskID == nil ? .awaitingReceipt : .needsReview, status: .cancellationRequestedAfterSubmission)
        } else if let taskID = operation.recovery.taskID {
            var hasReadTaskStatus = false
            do {
                let parameter: DsmParameterValue
                switch taskID { case .text(let value): parameter = .string(value); case .integer(let value): parameter = .integer(value) }
                let value = try await containerImageRequest(method: "pull_status", parameters: ["task_id": parameter])
                hasReadTaskStatus = true
                guard let row = value.object, let repository = try Self.imageString(row, "repository"), let tag = try Self.imageString(row, "tag"),
                      ContainerImagePullRequest.isValidTarget(repository: repository, tag: tag),
                      operation.recovery.matches(repository: repository, tag: tag),
                      case .boolean(let finished) = row["finished"] else { throw Self.invalidServiceResponseStatic() }
                if request == nil {
                    request = .init(id: id, repository: repository, tag: tag, isConfirmed: true)
                    imagePullOperations[id]?.request = request
                }
                var percentage: Double?
                if case .number(let current) = row["current"], case .number(let total) = row["total"],
                   current.isFinite, total.isFinite, total > 0, current >= 0, current <= total { percentage = current / total * 100 }
                if finished {
                    let images = try await loadContainerImageDefinitions()
                    guard images.allSatisfy({ $0.sourceImageID != nil }), images.contains(where: {
                        ContainerImagePullRecovery.digest(Self.imageAddress($0)) == operation.recovery.target
                    }) else {
                        throw Self.invalidServiceResponseStatic()
                    }
                    result = try imagePullProgress(request, id: id, stage: .ready, percentage: 100)
                } else { result = try imagePullProgress(request, id: id, stage: .downloading, percentage: percentage) }
            } catch let error as AppError where !hasReadTaskStatus && error.dsmCode == 1202 {
                // 24.0.2-1535 的受控下载实测：任务先运行，再以 Docker 错误结束；
                // 后续读取只剩任务不存在，不能丢弃首次明确失败并永久显示正在恢复。
                result = try imagePullProgress(request, id: id, stage: .rejected, error: .server)
            } catch {
                if preservesTrustError, Self.imageManagementTrustError(error) { throw error }
                result = try imagePullProgress(request, id: id, stage: .needsReview, status: Task.isCancelled ? .cancellationRequestedAfterSubmission : nil,
                    error: (error as? AppError).map { serviceMutationErrorCategory(for: $0.category) } ?? .network)
            }
        } else { result = try imagePullProgress(request, id: id, stage: .awaitingReceipt) }
        imagePullOperations[id]?.progress = result
        return result
    }

    private static func imageManagementTrustError(_ error: Error) -> Bool {
        if error is DsmCertificateTrustError { return true }
        if let error = error as? AppError { return error.category == .tlsUntrusted || error.category == .tlsCertificateChanged }
        if let error = error as? URLError {
            return [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                    .serverCertificateNotYetValid, .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired].contains(error.code)
        }
        return false
    }

    private static func imagePullTaskID(_ value: ServiceJSON?) -> ContainerImagePullRecovery.TaskID? {
        switch value {
        case .string(let text) where stableImageText(text): return .text(text)
        // ServiceJSON 的数字为 Double，超出安全整数范围的任务编号不能无损回传。
        case .number(let number) where number.isFinite && number >= 0 && number.rounded() == number && number <= 9_007_199_254_740_991:
            return .integer(Int(number))
        default: return nil
        }
    }

    private func imagePullProgress(_ request: ContainerImagePullRequest?, id: UUID? = nil, stage: ContainerImagePullStage, percentage: Double? = nil,
        status: MutationResultStatus? = nil, submitted: Bool = true, error: MutationErrorCategory? = nil) throws -> ContainerImagePullProgress {
        let status = status ?? (stage == .ready ? .confirmedSuccess : stage == .rejected ? .confirmedFailure : .submittedButUnverified)
        guard let id = request?.id ?? id else { throw Self.invalidServiceResponseStatic() }
        return try ContainerImagePullProgress(id: id, repository: request?.repository ?? "", tag: request?.tag ?? "", stage: stage, percentage: percentage,
            outcome: MutationResult(status: status, operation: "containerImagePull", submitted: submitted, requiresRefresh: stage != .rejected,
                counts: MutationResultCounts(succeeded: stage == .ready ? 1 : 0,
                    failed: stage == .rejected && status != .cancelledBeforeSubmission ? 1 : 0,
                    unknown: stage.isTerminal ? 0 : 1), errorCategory: error))
    }

    public func deleteContainerImages(ids: [String]) async throws {
        let result = try await deleteContainerImagesResult(ids: ids)
        guard result.status == .confirmedSuccess else {
            throw AppError(category: result.status == .permissionDenied ? .permissionDenied : .partialFailure,
                isRetryable: false, safeUserMessage: L10n.string(result.localizationKey ?? "container-image.delete.unverified"))
        }
    }

    private var imageDeletionContext: ServiceDeletionContext {
        ServiceDeletionContext(operation: "containerImageDelete", localizationPrefix: "container-image.delete")
    }

    public func loadContainerImageDeletionTargets() async throws -> [ContainerImage] {
        let images = try await loadContainerImageDefinitions()
        guard images.allSatisfy({ ContainerImageDeletionTarget($0) != nil }) else { throw Self.invalidServiceResponseStatic() }
        let used = try Self.containerImageUsage(images, containers: try await containerInventoryPayload())
        return images.map { ContainerImage(id: $0.id, repository: $0.repository, tag: $0.tag,
            sizeBytes: $0.sizeBytes, createdAt: $0.createdAt, isInUse: used.contains($0.id), sourceImageID: $0.sourceImageID) }
    }

    /// 内部 v1 按仓库/标签或裸身份删除；旧调用与持久恢复共用同一提交和回读。
    public func deleteContainerImagesResult(ids: [String]) async throws -> MutationResult {
        try await deleteImageTargets(ids: ids, expected: nil, observer: nil).outcome
    }

    public func deleteContainerImages(_ request: ContainerImageDeletionRequest, observer: @escaping ContainerImageDeletionObserver) async throws -> ContainerImageDeletionProgress {
        guard request.isValid, request.isConfirmed else { throw containerMutationChangedError() }
        return try await deleteImageTargets(ids: request.targets.map(\.id), expected: request, observer: observer)
    }

    private func deleteImageTargets(ids: [String], expected: ContainerImageDeletionRequest?, observer: ContainerImageDeletionObserver?) async throws -> ContainerImageDeletionProgress {
        let context = imageDeletionContext, operationID = expected?.id ?? UUID()
        func progress(_ result: MutationResult) -> ContainerImageDeletionProgress { .init(id: operationID, outcome: result) }
        if Task.isCancelled { return try progress(deletionCancellationBeforeSubmission(context: context)) }
        let targetIDs: Set<String>
        do { targetIDs = Set(try validatedIDs(ids)) }
        catch { return try progress(deletionUnexpectedPreflightResult(targetCount: max(ids.count, 1), context: context)) }
        let targetKey = Set(targetIDs.map(ContainerImagePullRecovery.digest))
        if let expected, let completed = completedImageDeletions[operationID] {
            guard completed.0 == expected.recovery else { throw containerMutationChangedError() }
            return completed.1
        }
        guard !imageDeletionActive, !imagePullBusy else { return try progress(deletionDuplicateResult(targetCount: targetIDs.count, context: context)) }
        imageDeletionActive = true
        defer { imageDeletionActive = false }
        if let pending = pendingImageDeletions[targetKey] {
            guard expected == nil || expected?.recovery == pending else { throw containerMutationChangedError() }
            return try await reviewImageDeletionTargets(pending, managed: observer != nil)
        }
        guard !pendingImageDeletions.values.contains(where: { $0.id == operationID }) else { throw containerMutationChangedError() }
        guard let capability = capabilities[DsmAPIName.dockerImage], capability.name == DsmAPIName.dockerImage,
              capability.minVersion == 1, capability.maxVersion >= 1, capability.selectedVersion != nil else {
            return try progress(deletionUnsupportedResult(targetCount: targetIDs.count, context: context))
        }
        let selected: [ContainerImage]
        do {
            let images = try await loadContainerImageDefinitions()
            guard images.allSatisfy({ ContainerImageDeletionTarget($0) != nil }) else { throw Self.invalidServiceResponseStatic() }
            selected = images.filter { targetIDs.contains($0.id) }
            guard selected.count == targetIDs.count else { return try progress(deletionMissingTargetResult(targetCount: targetIDs.count, context: context)) }
            if let expected {
                guard expected.targets.allSatisfy({ original in selected.contains(where: {
                    ContainerImageDeletionTarget($0) == ContainerImageDeletionTarget(original)
                }) }) else { throw containerMutationChangedError() }
            }
            let targets = selected.compactMap(ContainerImageDeletionTarget.init)
            guard !imagePullOperations.values.contains(where: { pull in
                !pull.progress.stage.isTerminal && targets.contains(where: { $0.overlaps(pull.recovery) })
            }) else { return try progress(deletionDuplicateResult(targetCount: targetIDs.count, context: context)) }
            let pendingTargets = pendingImageDeletions.values.flatMap(\.targets)
            guard !targets.contains(where: { target in pendingTargets.contains(where: target.overlaps) }) else {
                return try progress(deletionDuplicateResult(targetCount: targetIDs.count, context: context))
            }
            // 裸身份会删除整个 ID，不允许带走未确认的有效标签。
            guard !selected.contains(where: { target in target.tag == "<none>" && images.contains(where: {
                $0.sourceImageID == target.sourceImageID && $0.tag != "<none>"
            }) }) else { throw containerMutationChangedError() }
            let usedIDs = try Self.containerImageUsage(images, containers: try await containerInventoryPayload())
            guard targetIDs.isDisjoint(with: usedIDs) else { throw validationError(L10n.string("container-image.delete.in-use")) }
            try Task.checkCancellation()
        } catch let error as AppError {
            if observer != nil, Self.imageManagementTrustError(error) { throw error }
            return try progress(deletionPreflightResult(error, targetCount: targetIDs.count, context: context))
        } catch is CancellationError { return try progress(deletionCancellationBeforeSubmission(context: context)) }
        catch {
            if observer != nil, Self.imageManagementTrustError(error) { throw error }
            return try progress(deletionUnexpectedPreflightResult(targetCount: targetIDs.count, context: context))
        }

        var objects: [[String: DsmJSONValue]] = []
        let tagged = Dictionary(grouping: selected.filter { $0.tag != "<none>" }, by: \.repository)
        for repository in tagged.keys.sorted() {
            objects.append(["repository": .string(repository), "tags": .array(tagged[repository]!.map { .string($0.tag) })])
        }
        for identity in Set(selected.filter { $0.tag == "<none>" }.compactMap(\.sourceImageID)).sorted() {
            objects.append(["identity": .string(identity)])
        }
        let recovery = expected?.recovery ?? ContainerImageDeletionRecovery(id: operationID, targets: selected.compactMap(ContainerImageDeletionTarget.init))
        try await observer?(.willSubmit(recovery))
        pendingImageDeletions[targetKey] = recovery
        var accepted = false
        do {
            try await client.callVoid(path: capability.path, api: capability.name, version: 1, method: "delete",
                requestFormat: capability.requestFormat, parameters: ["images": .objectArray(objects)], credential: credential)
            accepted = true
        } catch let error as DsmNetworkError {
            let mapped = DsmErrorMapper.map(error)
            if observer != nil, Self.imageManagementTrustError(mapped) { throw mapped }
            if mapped.dsmCode != nil {
                // 明确拒绝不能因第三方删除改判成功，存储检查点失败也不能被吞成未知。
                pendingImageDeletions[targetKey] = nil
                let result = try progress(serviceDeletionResult(status: mapped.category == .permissionDenied ? .permissionDenied : .confirmedFailure,
                    context: context, submitted: true, requiresRefresh: false, succeeded: 0, failed: targetIDs.count, unknown: 0,
                    errorCategory: serviceMutationErrorCategory(for: mapped.category),
                    localizationSuffix: mapped.category == .permissionDenied ? "permission-denied" : "failed", diagnosticSuffix: "rejected"))
                if observer != nil { completedImageDeletions[operationID] = (recovery, result) }
                try await observer?(.rejected)
                return result
            }
        } catch {
            if observer != nil, Self.imageManagementTrustError(error) { throw error }
            // 回执丢失或取消后只读取原标签，不重放。
        }
        if accepted { try await observer?(.accepted) }
        return try await reviewImageDeletionTargets(recovery, managed: observer != nil)
    }

    public func reviewContainerImageDeletion(ids: [String]) async throws -> MutationResult {
        let context = imageDeletionContext
        let targetIDs: Set<String>
        do { targetIDs = Set(try validatedIDs(ids)) }
        catch { return try deletionUnexpectedPreflightResult(targetCount: max(ids.count, 1), context: context) }
        guard !imageDeletionActive else { return try deletionDuplicateResult(targetCount: targetIDs.count, context: context) }
        let targetKey = Set(targetIDs.map(ContainerImagePullRecovery.digest))
        guard let recovery = pendingImageDeletions[targetKey] else {
            return try deletionMissingTargetResult(targetCount: targetIDs.count, context: context)
        }
        imageDeletionActive = true
        defer { imageDeletionActive = false }
        return try await reviewImageDeletionTargets(recovery, managed: false).outcome
    }

    public func restoreContainerImageDeletion(_ recovery: ContainerImageDeletionRecovery) async throws -> ContainerImageDeletionProgress {
        guard recovery.isValid else { throw Self.invalidServiceResponseStatic() }
        if let completed = completedImageDeletions[recovery.id] {
            guard completed.0 == recovery else { throw containerMutationChangedError() }
            return completed.1
        }
        guard !imageDeletionActive, !imagePullBusy else { throw containerMutationChangedError() }
        imageDeletionActive = true
        defer { imageDeletionActive = false }
        if let pending = pendingImageDeletions[recovery.targetIDs] {
            guard pending == recovery else { throw containerMutationChangedError() }
        } else {
            guard !pendingImageDeletions.values.contains(where: { pending in
                pending.id == recovery.id || pending.targets.contains(where: { original in recovery.targets.contains(where: original.overlaps) })
            }) else { throw containerMutationChangedError() }
            pendingImageDeletions[recovery.targetIDs] = recovery
        }
        return try await reviewImageDeletionTargets(recovery, managed: true)
    }

    private func reviewImageDeletionTargets(_ recovery: ContainerImageDeletionRecovery, managed: Bool) async throws -> ContainerImageDeletionProgress {
        let context = imageDeletionContext, ids = recovery.targetIDs
        func progress(_ result: MutationResult, removed: Set<String> = []) -> ContainerImageDeletionProgress {
            .init(id: recovery.id, removedTargetIDs: removed, outcome: result)
        }
        if Task.isCancelled { return try progress(deletionCancellationAfterSubmission(targetCount: ids.count, context: context)) }
        do {
            let current = try await loadContainerImageDefinitions()
            guard current.allSatisfy({ ContainerImageDeletionTarget($0) != nil }) else { throw Self.invalidServiceResponseStatic() }
            let remaining = Set(recovery.targets.filter { target in current.contains(where: target.remains) }.map(\.id))
            let result = try progress(deletionReadbackResult(targets: ids, remaining: remaining, context: context), removed: ids.subtracting(remaining))
            if result.outcome.status == .confirmedSuccess {
                pendingImageDeletions[ids] = nil
                if managed { completedImageDeletions[recovery.id] = (recovery, result) }
            }
            return result
        } catch let error as AppError {
            if managed, Self.imageManagementTrustError(error) { throw error }
            return try progress(deletionReadbackFailureResult(error, targetCount: ids.count, context: context))
        } catch {
            if managed, Self.imageManagementTrustError(error) { throw error }
            return try progress(deletionUnexpectedReadbackResult(targetCount: ids.count, context: context))
        }
    }

    private func loadContainerImageDefinitions() async throws -> [ContainerImage] {
        let payload = try await containerImageListPayload()
        return try Self.containerImages(payload)
    }

    private func containerImageListResult() async throws -> SupplementaryServiceResult {
        guard let capability = capabilities[DsmAPIName.dockerImage], capability.name == DsmAPIName.dockerImage,
              capability.minVersion == 1, capability.maxVersion >= 1, capability.selectedVersion != nil else { return .unavailable }
        do { return .available(try await containerImageListPayload()) }
        catch let error as AppError {
            switch error.category {
            case .authenticationRequired, .otpRequired, .tlsUntrusted, .tlsCertificateChanged, .cancelled: throw error
            default: return .failed
            }
        }
    }

    private func containerImageListPayload() async throws -> ServiceJSON {
        try await containerImageRequest(method: "list", parameters: ["offset": .integer(0), "limit": .integer(-1), "show_dsm": .boolean(false)])
    }

    private func containerImageRequest(method: String, parameters: [String: DsmParameterValue]) async throws -> ServiceJSON {
        guard let capability = capabilities[DsmAPIName.dockerImage], capability.name == DsmAPIName.dockerImage,
              capability.minVersion == 1, capability.maxVersion >= 1, capability.selectedVersion != nil else { throw unavailableError() }
        do {
            let value = try await client.call(path: capability.path, api: capability.name, version: 1, method: method,
                requestFormat: capability.requestFormat, parameters: parameters,
                credential: credential, as: ServiceJSON.self)
            return value
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
    }

    public func createContainerNetwork(_ configuration: ContainerNetworkCreation) async throws {
        try await createContainerNetwork(configuration, observer: nil)
    }

    public var supportsContainerNetworkManagement: Bool {
        guard let capability = capabilities[DsmAPIName.dockerNetwork] else { return false }
        return capability.name == DsmAPIName.dockerNetwork && capability.minVersion == 1
            && capability.maxVersion >= 1 && capability.selectedVersion != nil
    }
    public var canCreateContainerNetworks: Bool { containerNetworkCreationEnabled && supportsContainerNetworkManagement }

    public func createContainerNetwork(_ configuration: ContainerNetworkCreation,
                                       observer: ContainerNetworkMutationObserver?) async throws {
        guard canCreateContainerNetworks else {
            throw validationError(L10n.string("container.network.creation.unavailable"))
        }
        if let issue = configuration.validationIssue { throw validationError(L10n.string(issue.rawValue)) }
        let name = configuration.name
        guard !networkMutationActive, !pendingNetworkDeletions.values.contains(where: { $0.network.name == name }) else {
            throw validationError(L10n.string("container.network.creation.inProgress"))
        }
        networkMutationActive = true
        defer { networkMutationActive = false }
        if let pending = pendingNetworkCreations[name] {
            guard pending.configuration == configuration else { throw verificationError(L10n.string("container.network.creation.review")) }
            let outcome = try await reviewContainerNetworkCreation(.init(configuration), accepted: pending.accepted)
            guard outcome == .created else { throw verificationError(L10n.string("container.network.creation.review")) }
            pendingNetworkCreations.removeValue(forKey: name)
            return
        }
        // 先核对读取权限与名称占用；创建权限仍由 NAS 在写入时裁决。
        let networks = try await loadContainerNetworks()
        guard !networks.contains(where: { $0.name == name }) else {
            throw validationError(L10n.string("container.network.creation.nameTaken"))
        }
        try Task.checkCancellation()
        var parameters: [String: DsmParameterValue] = [
            "name": .string(name), "enable_ipv6": .boolean(configuration.isIPv6Enabled),
            "disable_masquerade": .boolean(configuration.disableMasquerade)
        ]
        if configuration.usesManualIPv4 {
            parameters["subnet"] = .string(configuration.subnet)
            parameters["iprange"] = .string(configuration.ipRange)
            parameters["gateway"] = .string(configuration.gateway)
        }
        if configuration.isIPv6Enabled {
            parameters["ipv6_subnet"] = .string(configuration.ipv6Subnet)
            parameters["ipv6_iprange"] = .string(configuration.ipv6Range)
            parameters["ipv6_gateway"] = .string(configuration.ipv6Gateway)
        }
        try await observer?(.willSubmit)
        pendingNetworkCreations[name] = (configuration, false)
        do {
            try await networkCreateRequest(parameters)
        } catch let error as AppError {
            if error.dsmCode != nil {
                pendingNetworkCreations[name] = nil
                try await observer?(.rejected)
            }
            throw error
        }
        pendingNetworkCreations[name]?.accepted = true
        try await observer?(.accepted)
        guard try await reviewContainerNetworkCreation(.init(configuration), accepted: true) == .created else {
            throw verificationError(L10n.string("container.network.creation.review"))
        }
        try await observer?(.verified)
    }

    /// 无创建回执时只表达同名对象已存在，不认领为本次创建成功。
    public func reviewContainerNetworkCreation(_ identity: ContainerNetworkCreationIdentity,
                                               accepted: Bool) async throws -> ContainerNetworkCreationOutcome {
        guard identity.isValid else { throw Self.invalidServiceResponseStatic() }
        let values = try await loadContainerNetworks()
        guard let network = values.first(where: identity.matchesName) else { return .pending }
        let result: ContainerNetworkCreationOutcome = accepted && identity.matches(network) ? .created : accepted ? .pending : .existing
        if result != .pending { pendingNetworkCreations[network.name] = nil }
        return result
    }

    public func loadContainerNetworks() async throws -> [ContainerNetwork] {
        try await containerNetworkDefinitions().map(\.network)
    }

    private func containerNetworkDefinitions() async throws -> [(network: ContainerNetwork, raw: [String: ServiceJSON])] {
        let value = try await networkRequest(method: "list")
        let objects = try Self.strictRootObjects(value, keys: ["network", "networks"])
        try Self.requireCompleteServiceList(value, count: objects.count)
        let values = try objects.map { raw in
            guard let network = Self.containerNetwork(raw),
                  Self.officialNonEmptyString(raw["id"] ?? raw["network_id"] ?? raw["Id"]) == network.id,
                  Self.officialNonEmptyString(raw["name"] ?? raw["Name"]) == network.name,
                  Self.officialNonEmptyString(raw["driver"] ?? raw["Driver"] ?? raw["type"]) == network.driver else {
                throw Self.invalidServiceResponseStatic()
            }
            return (network: network, raw: raw)
        }
        guard Set(values.map { $0.network.id }).count == values.count,
              Set(values.map { $0.network.name }).count == values.count else { throw Self.invalidServiceResponseStatic() }
        return values
    }

    private func networkRequest(method: String, parameters: [String: DsmParameterValue] = [:]) async throws -> ServiceJSON {
        guard supportsContainerNetworkManagement, let capability = capabilities[DsmAPIName.dockerNetwork] else { throw unavailableError() }
        do { return try await client.call(path: capability.path, api: capability.name, version: 1, method: method,
            requestFormat: capability.requestFormat, parameters: parameters, credential: credential, as: ServiceJSON.self) }
        catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
    }
    private func networkCreateRequest(_ parameters: [String: DsmParameterValue]) async throws {
        guard supportsContainerNetworkManagement, let capability = capabilities[DsmAPIName.dockerNetwork] else { throw unavailableError() }
        do { try await client.callVoid(path: capability.path, api: capability.name, version: 1, method: "create",
            requestFormat: capability.requestFormat, parameters: parameters, credential: credential) }
        catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
    }

    public func deleteContainerNetworks(ids: [String]) async throws {
        let result = try await deleteContainerNetworksResult(ids: ids)
        guard result.status == .confirmedSuccess else {
            throw verificationError(L10n.string("shared.3f7da50cab7bd49a"))
        }
    }

    /// 容器网络删除使用内部接口；提交后重新读取网络列表确认。
    public func deleteContainerNetworksResult(ids: [String]) async throws -> MutationResult {
        let context = ServiceDeletionContext(operation: "containerNetworkDelete", localizationPrefix: "container-network.delete")
        if Task.isCancelled { return try deletionCancellationBeforeSubmission(context: context) }
        let targets: [ContainerNetwork]
        do {
            let ids = try validatedIDs(ids), values = try await loadContainerNetworks()
            targets = ids.compactMap { id in values.first { $0.id == id } ?? pendingNetworkDeletions[id]?.network }
            guard targets.count == ids.count else { throw containerMutationChangedError() }
        } catch {
            if Self.imageManagementTrustError(error) { throw error }
            if let error = error as? AppError { return try deletionPreflightResult(error, targetCount: max(1, ids.count), context: context) }
            return try deletionUnexpectedPreflightResult(targetCount: max(1, ids.count), context: context)
        }
        var succeeded = 0
        for target in targets {
            let tracking = NetworkDeletionTracking()
            do {
                if let pending = pendingNetworkDeletions[target.id] {
                    await tracking.record(.willSubmit)
                    let absent = try await reviewContainerNetworkDeletion(.init(pending.network))
                    // 丢回执后的原 ID 消失只证明当前缺失，旧入口同样不能认领本次成功。
                    guard absent && pending.accepted else { throw containerControlUnverifiedError() }
                } else {
                    try await deleteContainerNetwork(target) { stage in await tracking.record(stage) }
                }
                succeeded += 1
            } catch {
                if Self.imageManagementTrustError(error) { throw error }
                let (submitted, rejected) = await tracking.state
                let unknown = (submitted && !rejected) || pendingNetworkDeletions[target.id] != nil ? 1 : 0
                let mapped = error as? AppError
                return try serviceDeletionResult(status: succeeded > 0 ? .partialSuccess : mapped?.category == .permissionDenied ? .permissionDenied : unknown > 0 ? .submittedButUnverified : .confirmedFailure,
                    context: context, submitted: succeeded > 0 || submitted || unknown > 0, requiresRefresh: unknown > 0,
                    succeeded: succeeded, failed: targets.count - succeeded - unknown, unknown: unknown,
                    errorCategory: mapped.map { serviceMutationErrorCategory(for: $0.category) } ?? .unknown,
                    localizationSuffix: unknown > 0 ? "unverified" : "failed", diagnosticSuffix: "network-stopped")
            }
        }
        return try deletionReadbackResult(targets: Set(targets.map(\.id)), remaining: [], context: context)
    }

    /// 官方 remove 接收所选网络对象数组，而不是单个 id；只复制已观察的字段。
    public func deleteContainerNetwork(_ original: ContainerNetwork, observer: @escaping ContainerNetworkMutationObserver) async throws {
        guard !networkMutationActive, pendingNetworkDeletions[original.id] == nil,
              pendingNetworkCreations[original.name] == nil else { throw containerMutationChangedError() }
        networkMutationActive = true
        defer { networkMutationActive = false }
        let definitions = try await containerNetworkDefinitions()
        guard let definition = definitions.first(where: { $0.network.id == original.id }), definition.network == original else {
            throw containerMutationChangedError()
        }
        let network = definition.network, id = network.id
        guard !["bridge", "host", "none"].contains(network.name) else {
            throw validationError(L10n.string("container.network.delete.protected"))
        }
        guard network.connectedContainerCount == 0 else {
            throw validationError(L10n.string("container.network.delete.inUse"))
        }
        let source = ServiceJSON.object(definition.raw)
        var target: [String: DsmJSONValue] = [
            "id": .string(id), "_key": .string(id), "name": .string(network.name),
            "driver": .string(network.driver), "containers": .array([]),
            "enable_ipv6": .boolean(network.isIPv6Enabled ?? false),
            "disable_masquerade": .boolean(source.firstBoolean(["disable_masquerade"]) ?? false)
        ]
        for key in ["subnet", "gateway", "iprange", "ipv6_subnet", "ipv6_gateway", "ipv6_iprange"] {
            target[key] = .string(source.firstString([key]) ?? "")
        }
        try Task.checkCancellation()
        try await observer(.willSubmit)
        pendingNetworkDeletions[id] = (original, false)
        let result: ServiceJSON
        do { result = try await networkRequest(method: "remove", parameters: ["networks": .objectArray([target])]) }
        catch let error as AppError {
            if error.dsmCode != nil { pendingNetworkDeletions[id] = nil; try await observer(.rejected) }
            throw error
        }
        guard let failed = result["failed"]?.array else { throw Self.invalidServiceResponseStatic() }
        guard failed.isEmpty else {
            // 单项删除的失败数组非空即为明确失败，不猜测其中目标字段。
            pendingNetworkDeletions[id] = nil
            try await observer(.rejected)
            throw verificationError(L10n.string("shared.3f7da50cab7bd49a"))
        }
        pendingNetworkDeletions[id]?.accepted = true
        try await observer(.accepted)
        guard try await reviewContainerNetworkDeletion(.init(original)) else { throw containerControlUnverifiedError() }
        try await observer(.verified)
    }

    public func reviewContainerNetworkDeletion(_ identity: ContainerNetworkDeletionIdentity) async throws -> Bool {
        guard identity.isValid else { throw Self.invalidServiceResponseStatic() }
        let values = try await loadContainerNetworks()
        guard !values.contains(where: identity.remains) else { return false }
        for id in pendingNetworkDeletions.keys where ContainerImagePullRecovery.digest(id) == identity.id { pendingNetworkDeletions[id] = nil }
        return true
    }

    public func loadVirtualMachineManager() async throws -> VirtualMachineManagerSnapshot {
        let (official, guestJSON) = try await loadVirtualMachineList()
        // 创建向导需要内部资源接口返回的主机归属和容量字段；缺失时再退回公开只读接口。
        let hostAPI = capabilities[DsmAPIName.virtualizationHost]?.selectedVersion != nil
            ? DsmAPIName.virtualizationHost
            : DsmAPIName.virtualizationAPIHost
        let storageAPI = capabilities[DsmAPIName.virtualizationRepo]?.selectedVersion != nil
            ? DsmAPIName.virtualizationRepo
            : DsmAPIName.virtualizationAPIStorage
        let networkAPI = capabilities[DsmAPIName.virtualizationNetwork]?.selectedVersion != nil
            ? DsmAPIName.virtualizationNetwork
            : DsmAPIName.virtualizationAPINetwork
        let imageAPI = capabilities[DsmAPIName.virtualizationGuestImage]?.selectedVersion != nil
            ? DsmAPIName.virtualizationGuestImage
            : DsmAPIName.virtualizationAPIGuestImage

        async let hostsResult = supplementaryCall(hostAPI, methods: ["list"])
        async let storagesResult = supplementaryCall(storageAPI, methods: ["list"])
        async let networksResult = supplementaryCall(networkAPI, methods: ["list"])
        async let imagesResult = supplementaryCall(imageAPI, methods: ["list"])
        async let plansResult = supplementaryCall(
            DsmAPIName.virtualizationProtectionPlan,
            methods: ["list", "get"]
        )
        async let eventsResult = supplementaryCall(
            DsmAPIName.virtualizationLog,
            methods: ["list"],
            parameters: [
                "offset": .integer(0),
                "limit": .integer(1_000),
                "loglevel": .string(""),
                "filter_content": .string(""),
                "datefrom": .integer(0),
                "dateto": .integer(0),
                "sort_by": .string("time"),
                "sort_dir": .string("DESC")
            ]
        )
        let (hostResult, storageResult, networkResult, imageResult, planResult, eventResult) =
            try await (
                hostsResult, storagesResult, networksResult, imagesResult, plansResult, eventsResult
            )
        var unavailableSections: Set<VirtualMachineManagerSection> = []
        if hostResult.isUnavailable { unavailableSections.insert(.hosts) }
        if storageResult.isUnavailable { unavailableSections.insert(.storages) }
        if networkResult.isUnavailable { unavailableSections.insert(.networks) }
        if imageResult.isUnavailable { unavailableSections.insert(.images) }
        if planResult.isUnavailable { unavailableSections.insert(.protection) }
        if eventResult.isUnavailable { unavailableSections.insert(.logs) }
        var failedSections: Set<VirtualMachineManagerSection> = []
        if hostResult.isFailed { failedSections.insert(.hosts) }
        if storageResult.isFailed { failedSections.insert(.storages) }
        if networkResult.isFailed { failedSections.insert(.networks) }
        if imageResult.isFailed { failedSections.insert(.images) }
        if planResult.isFailed { failedSections.insert(.protection) }
        if eventResult.isFailed { failedSections.insert(.logs) }
        let machines = try Self.strictMappedItems(
            guestJSON,
            keys: ["guests", "guest", "vms"],
            parser: { Self.machine($0, internalMemoryKiB: !official) }
        )
        let hosts: [VirtualizationResource] = Self.strictSupplementaryResources(
            hostResult,
            keys: ["hosts", "host"],
            failedSection: .hosts,
            failedSections: &failedSections
        )
        let storages: [VirtualizationResource] = Self.strictSupplementaryResources(
            storageResult,
            keys: ["repos", "storages"],
            failedSection: .storages,
            failedSections: &failedSections
        )
        let networks: [VirtualizationResource] = Self.strictSupplementaryResources(
            networkResult,
            keys: ["networks", "network"],
            failedSection: .networks,
            failedSections: &failedSections
        )
        let images: [VirtualizationResource] = Self.strictSupplementaryResources(
            imageResult,
            keys: ["images", "image"],
            failedSection: .images,
            failedSections: &failedSections
        )
        let protection = Self.strictSupplementaryProtection(
            planResult,
            failedSections: &failedSections
        )
        let events = Self.strictSupplementaryEvents(
            eventResult,
            keys: ["logs", "log", "events", "records", "entries", "items"],
            failedSection: .logs,
            failedSections: &failedSections
        )

        // Mac 使用此普通刷新入口；只有原操作已接受时追加严格恢复读取，不能借展示摘要解锁。
        if pendingVmmNetworks.contains(where: { $0.value.accepted && !activeVmmNetworkMutationIDs.contains($0.key) }) {
            do { _ = try await loadVirtualMachineNetworks() }
            catch {
                try throwCreationReadBoundary(error)
                failedSections.insert(.networks)
            }
        }
        if unverifiedVmmDeletions[vmmImageAPI, default: [:]].contains(where: {
            $0.value.accepted && activeDeletionIDsByOperation["virtualMachineImageDelete"]?.contains($0.key) != true
        }) {
            do { _ = try await loadVirtualMachineImages() }
            catch { try throwCreationReadBoundary(error); failedSections.insert(.images) }
        }

        return VirtualMachineManagerSnapshot(
            source: official ? .official : .internalAPI,
            machines: machines,
            hosts: hosts,
            storages: storages,
            networks: networks,
            images: images,
            protectionPlans: protection.plans,
            protectionSchedulePolicies: protection.schedules,
            protectionRetentionPolicies: protection.retentions,
            events: events,
            unavailableSections: unavailableSections,
            failedSections: failedSections
        )
    }

    /// 移动端首个 VMM 闭环固定使用公开 Guest v1，只读取虚拟机清单。
    /// 不降级到内部接口，也不读取主机、存储、网络、映像、保护或日志。
    public func loadVirtualMachineInventory() async throws -> VirtualMachineInventorySnapshot {
        guard let capability = capabilities[DsmAPIName.virtualizationAPIGuest],
              capability.minVersion <= 1,
              capability.maxVersion >= 1,
              capability.selectedVersion != nil else {
            throw unavailableError()
        }
        let value: ServiceJSON
        do {
            value = try await client.call(
                path: capability.path,
                api: capability.name,
                version: 1,
                method: "list",
                requestFormat: capability.requestFormat,
                parameters: [:],
                credential: credential,
                as: ServiceJSON.self
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
        return VirtualMachineInventorySnapshot(
            source: .official,
            machines: try Self.publicGuestV1Inventory(from: value)
        )
    }

    public var supportsVirtualMachineCreation: Bool {
        supportsVirtualMachineSettings && vmmCapability(DsmAPIName.virtualizationRepo, version: 2) != nil
            && vmmCapability(DsmAPIName.virtualizationCluster, version: 1) != nil
    }

    public func loadVirtualMachineCreationResources() async throws -> VirtualMachineCreationResources {
        guard supportsVirtualMachineCreation else { throw unavailableError() }
        let repos = try await call(DsmAPIName.virtualizationRepo, method: "list", fixedVersion: 2)
        guard try !creationBool(repos, "is_freeze") else {
            throw validationError(L10n.string("virtual-machine.creation.resources-changed"))
        }
        let storages = try creationRows(repos, "repos").map { row in
            VirtualMachineCreationStorage(id: try creationText(row, "repo_id"), name: try creationText(row, "name"),
                hostID: try creationText(row, "host_id"), hostName: try creationText(row, "host_name"),
                allocatedBytes: try creationInteger(row, "allocated_size"), capacityBytes: try creationText(row, "size"),
                status: try creationText(row, "status"), statusType: try creationText(row, "status_type"))
        }
        guard Set(storages.map(\.id)).count == storages.count,
              storages.allSatisfy({ UInt64($0.capacityBytes) != nil }) else { throw invalidServiceResponse() }
        var networks: [VirtualizationResource] = [], images: [VirtualMachineCreationImage] = []
        var networksAvailable = false, imagesAvailable = false
        if vmmCapability(DsmAPIName.virtualizationNetwork, version: 2) != nil {
            do {
                let value = try await call(DsmAPIName.virtualizationNetwork, method: "list", fixedVersion: 2)
                if try !creationBool(value, "is_freeze") {
                    networks = try creationRows(value, "networks").map {
                        VirtualizationResource(id: try creationText($0, "network_id"), name: try creationText($0, "name"))
                    }
                    guard Set(networks.map(\.id)).count == networks.count else { throw invalidServiceResponse() }
                    networksAvailable = true
                }
            } catch { try throwCreationReadBoundary(error) }
        }
        if vmmCapability(DsmAPIName.virtualizationGuestImage, version: 2) != nil {
            do {
                let value = try await call(DsmAPIName.virtualizationGuestImage, method: "list", fixedVersion: 2)
                if try !creationBool(value, "is_freeze") {
                    for row in try creationRows(value, "images") {
                        let image = VirtualMachineCreationImage(id: try creationText(row, "id"), name: try creationText(row, "name"),
                            storageID: try creationText(row, "repo_id"), hostID: try creationText(row, "host_id"))
                        let type = try creationText(row, "type"), status = try creationText(row, "status"), statusType = try creationText(row, "status_type")
                        if type == "iso", status == "online", statusType == "healthy" { images.append(image) }
                    }
                    guard Set(images.map { [$0.id, $0.storageID, $0.hostID] }).count == images.count else { throw invalidServiceResponse() }
                    imagesAvailable = true
                }
            } catch { try throwCreationReadBoundary(error) }
        }
        try Task.checkCancellation()
        return .init(storages: storages, networks: networksAvailable ? networks : [], images: imagesAvailable ? images : [],
                     imagesAvailable: imagesAvailable, networksAvailable: networksAvailable)
    }

    /// 保留 Mac 旧调用入口；再次操作同一未完成配置只能读取原任务，不能重发。
    public func createVirtualMachine(_ configuration: VirtualMachineCreation) async throws {
        let result = try await createVirtualMachine(configuration, expectedResources: nil, observer: nil)
        switch result {
        case .succeeded: return
        case .pending: throw verificationError(L10n.string("virtual-machine.creation.pending"))
        case .failed: throw validationError(L10n.string("virtual-machine.creation.failed"))
        }
    }

    public func createVirtualMachine(_ configuration: VirtualMachineCreation,
                                    expectedResources: VirtualMachineCreationResources?,
                                    observer: VirtualMachineCreationObserver?) async throws -> VirtualMachineCreationReview {
        guard supportsVirtualMachineCreation else { throw unavailableError() }
        let name = Self.creationNameDigest(configuration.name)
        guard activeVmmCreationNames.insert(name).inserted else {
            throw verificationError(L10n.string("virtual-machine.creation.pending"))
        }
        defer { activeVmmCreationNames.remove(name); activeVmmCreationResources[name] = nil }
        if let pending = pendingVmmCreations[name] {
            guard pending.configuration == configuration else {
                throw verificationError(L10n.string("virtual-machine.creation.pending"))
            }
            return try await reviewVmmCreation(pending.tracking, observer: observer)
        }
        var referencedResources = ["storage": Self.creationIdentityDigest(configuration.storageID)]
        if !configuration.networkID.isEmpty {
            guard !activeVmmNetworkMutationIDs.contains(configuration.networkID), pendingVmmNetworks[configuration.networkID] == nil,
                  activeDeletionIDsByOperation["virtualMachineNetworkDelete"]?.contains(configuration.networkID) != true else {
                throw verificationError(L10n.string("virtual-machine.creation.resources-changed"))
            }
            referencedResources["network"] = Self.creationIdentityDigest(configuration.networkID)
        }
        if let image = configuration.bootImageID {
            guard activeDeletionIDsByOperation["virtualMachineImageDelete"]?.contains(image) != true,
                  unverifiedVmmDeletions[DsmAPIName.virtualizationAPIGuestImage]?[image] == nil,
                  unverifiedVmmDeletions[DsmAPIName.virtualizationGuestImage]?[image] == nil else {
                throw verificationError(L10n.string("virtual-machine.creation.resources-changed"))
            }
            referencedResources["image"] = Self.creationIdentityDigest(image)
        }
        activeVmmCreationResources[name] = referencedResources
        let resources = try await loadVirtualMachineCreationResources(), requestID = UUID()
        let parameters = try vmmCreationParameters(configuration, resources: resources, requestID: requestID)
        if let expectedResources {
            let storage = resources.storages.first { $0.id == configuration.storageID }
            let expected = expectedResources.storages.first { $0.id == configuration.storageID }
            guard let storage, let expected, storage.id == expected.id, storage.name == expected.name,
                  storage.hostID == expected.hostID, storage.hostName == expected.hostName,
                  configuration.networkID.isEmpty || resources.networks.first(where: { $0.id == configuration.networkID })
                    == expectedResources.networks.first(where: { $0.id == configuration.networkID }),
                  configuration.bootImageID == nil || resources.images.filter({ $0.id == configuration.bootImageID && $0.storageID == storage.id && $0.hostID == storage.hostID })
                    == expectedResources.images.filter({ $0.id == configuration.bootImageID && $0.storageID == storage.id && $0.hostID == storage.hostID }) else {
                throw validationError(L10n.string("virtual-machine.creation.resources-changed"))
            }
        }
        guard let guest = vmmCapability(DsmAPIName.virtualizationGuest, version: 2) else { throw unavailableError() }
        let initial = try await vmmDeletionSnapshot(capability: guest, arrayKey: "guests", idKey: "guest_id")
        guard activeVmmSettingsIDs.isEmpty,
              !initial.guests.values.contains(where: { $0.name.caseInsensitiveCompare(configuration.name) == .orderedSame }),
              !unverifiedVmmSettings.values.contains(where: { Self.creationNameDigest($0.configuration.name ?? $0.name) == name }) else {
            throw validationError(L10n.string("shared.433935ad21c1d3da"))
        }
        let json = Self.creationJSON(parameters)
        var tracking = VirtualMachineCreationTracking(requestID: requestID, nameDigest: name,
            parameterDigests: try json.mapValues(Self.creationDigest), configurationDigest: try creationExpectedDigest(json),
            existingIdentityDigests: Set(initial.ids.map(Self.creationIdentityDigest)), resourceIdentityDigests: referencedResources)
        try Task.checkCancellation()
        try await observer?(.willSubmit(tracking))
        pendingVmmCreations[name] = (configuration, tracking)
        do {
            let receipt = try await client.call(path: guest.path, api: guest.name, version: 1, method: "create",
                requestFormat: guest.requestFormat, parameters: parameters, credential: credential, as: ServiceJSON.self)
            let taskID = try creationText(receipt, "task_id")
            tracking.taskIdentityDigest = Self.creationIdentityDigest(taskID)
        } catch let error as DsmNetworkError {
            let mapped = DsmErrorMapper.map(error)
            if Self.imageManagementTrustError(mapped) { throw mapped }
            let rejected: Bool = switch error { case .api(let code, _) where code > 0: true; case .invalidRequest: true; default: false }
            if rejected {
                pendingVmmCreations[name] = nil; try await observer?(.rejected); throw mapped
            }
            if case .cancelled = error { throw CancellationError() }
            if [.authenticationRequired, .otpRequired, .permissionDenied].contains(mapped.category) { throw mapped }
        } catch { try throwCreationReadBoundary(error) }
        pendingVmmCreations[name] = (configuration, tracking)
        if tracking.taskIdentityDigest != nil { try await observer?(.accepted(tracking)) }
        return try await reviewVmmCreation(tracking, observer: observer)
    }

    public func reviewVirtualMachineCreation(_ tracking: VirtualMachineCreationTracking,
                                             observer: VirtualMachineCreationObserver? = nil) async throws -> VirtualMachineCreationReview {
        guard tracking.isValid else { throw invalidServiceResponse() }
        guard activeVmmCreationNames.insert(tracking.nameDigest).inserted else { return .pending }
        defer { activeVmmCreationNames.remove(tracking.nameDigest) }
        return try await reviewVmmCreation(tracking, observer: observer)
    }

    private func reviewVmmCreation(_ original: VirtualMachineCreationTracking,
                                   observer: VirtualMachineCreationObserver?) async throws -> VirtualMachineCreationReview {
        guard original.isValid, supportsVirtualMachineCreation else { throw unavailableError() }
        var tracking = original
        let configuration = pendingVmmCreations[tracking.nameDigest]?.configuration
        pendingVmmCreations[tracking.nameDigest] = (configuration, tracking)
        try Task.checkCancellation()
        if tracking.guestIdentityDigest == nil {
            let progress = try await call(DsmAPIName.virtualizationCluster, method: "get_total_progress",
                parameters: ["prefix": .string("virtualization_guest")], fixedVersion: 1)
            guard let hosts = progress.object else { throw invalidServiceResponse() }
            var matches: [(String, ServiceJSON)] = []
            for (host, group) in hosts where host != "local_host" && host != "has_fail" {
                guard let tasks = group.object else { throw invalidServiceResponse() }
                for (id, task) in tasks {
                    let expectedID = tracking.taskIdentityDigest == Self.creationIdentityDigest(id)
                    let expectedContext = task["info"]?["param"]?["synovmm_ui_id"]?.stringValue == tracking.requestID.uuidString.lowercased()
                    if expectedID || expectedContext { matches.append((id, task)) }
                }
            }
            guard matches.count == 1 else { return .pending }
            let (taskID, task) = matches[0]
            guard Self.isVmmDeletionID(taskID), tracking.taskIdentityDigest == nil || tracking.taskIdentityDigest == Self.creationIdentityDigest(taskID),
                  let info = task["info"], try creationText(info, "api") == DsmAPIName.virtualizationGuest,
                  try creationText(info, "method") == "create", try creationInteger(info, "version") == 1,
                  try creationText(info, "prefix") == "virtualization_guest_create", let sent = info["param"]?.object else { return .pending }
            for (key, digest) in tracking.parameterDigests {
                guard let value = sent[key], try Self.creationDigest(Self.creationJSON(value)) == digest else { return .pending }
            }
            if tracking.taskIdentityDigest == nil {
                tracking.taskIdentityDigest = Self.creationIdentityDigest(taskID)
                pendingVmmCreations[tracking.nameDigest] = (configuration, tracking)
                try await observer?(.accepted(tracking))
            }
            guard try creationBool(task, "finish") else { return .pending }
            guard try creationBool(task, "success") else {
                pendingVmmCreations[tracking.nameDigest] = nil; try await observer?(.rejected); return .failed
            }
            guard let data = task["data"] else { throw invalidServiceResponse() }
            let id = try creationText(data, "guest_id"), digest = Self.creationIdentityDigest(id)
            guard !tracking.existingIdentityDigests.contains(digest) else { return .pending }
            tracking.guestIdentityDigest = digest
            pendingVmmCreations[tracking.nameDigest] = (configuration, tracking)
            try await observer?(.taskSucceeded(tracking))
        }
        guard let guest = vmmCapability(DsmAPIName.virtualizationGuest, version: 2) else { throw unavailableError() }
        let inventory = try await vmmDeletionSnapshot(capability: guest, arrayKey: "guests", idKey: "guest_id")
        let ids = inventory.ids.filter { Self.creationIdentityDigest($0) == tracking.guestIdentityDigest }
        guard ids.count == 1, let id = ids.first else { return .pending }
        let before = try await call(guest.name, method: "get", parameters: ["guest_id": .string(id)], fixedVersion: 2)
        let baseline = try vmmSettingsState(before)
        guard baseline.id == id else { return .pending }
        let settings = try await call(guest.name, method: "get_setting", parameters: ["guest_id": .string(id)], fixedVersion: 1)
        let digest = try creationObservedDigest(settings, baseline: before)
        let after = try await call(guest.name, method: "get", parameters: ["guest_id": .string(id)], fixedVersion: 2)
        try Task.checkCancellation()
        guard try vmmSettingsState(after) == baseline, digest == tracking.configurationDigest else { return .pending }
        try await observer?(.succeeded(guestID: id))
        pendingVmmCreations[tracking.nameDigest] = nil
        return .succeeded(guestID: id)
    }

    private func throwCreationReadBoundary(_ error: Error) throws {
        if error is CancellationError || error is DsmCertificateTrustError { throw error }
        if let value = error as? AppError, Self.imageManagementTrustError(value)
            || [.authenticationRequired, .otpRequired, .cancelled].contains(value.category) { throw error }
    }
    private func creationRows(_ value: ServiceJSON, _ key: String) throws -> [ServiceJSON] {
        guard case .array(let rows)? = value[key], rows.allSatisfy({ $0.object != nil }) else { throw invalidServiceResponse() }
        try Self.requireCompleteServiceList(value, count: rows.count)
        return rows
    }
    private func creationText(_ value: ServiceJSON, _ key: String) throws -> String {
        guard case .string(let text)? = value[key], !text.isEmpty,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalidServiceResponse() }
        if ["repo_id", "network_id", "host_id", "guest_id", "task_id", "id"].contains(key), !Self.isVmmDeletionID(text) {
            throw invalidServiceResponse()
        }
        return text
    }
    private func creationInteger(_ value: ServiceJSON, _ key: String) throws -> Int {
        guard case .number(let number)? = value[key], number.isFinite, number >= 0, number < Double(Int.max),
              number.rounded() == number else { throw invalidServiceResponse() }
        return Int(number)
    }
    private func creationBool(_ value: ServiceJSON, _ key: String) throws -> Bool {
        guard case .boolean(let flag)? = value[key] else { throw invalidServiceResponse() }; return flag
    }
    private static func creationIdentityDigest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func creationNameDigest(_ value: String) -> String {
        creationIdentityDigest(value.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")))
    }
    private func creationProtects(id: String, name: String) -> Bool {
        let name = Self.creationNameDigest(name), id = Self.creationIdentityDigest(id)
        return activeVmmCreationNames.contains(name) || pendingVmmCreations[name] != nil
            || pendingVmmCreations.values.contains { $0.tracking.guestIdentityDigest == id }
    }
    private func creationReferences(_ kind: String, id: String) -> Bool {
        let digest = Self.creationIdentityDigest(id)
        return activeVmmCreationResources.values.contains { $0[kind] == digest }
            || pendingVmmCreations.values.contains { $0.tracking.resourceIdentityDigests[kind] == digest }
    }
    private static func creationDigest(_ value: DsmJSONValue) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return SHA256.hash(data: try encoder.encode(value)).map { String(format: "%02x", $0) }.joined()
    }
    private static func creationJSON(_ value: ServiceJSON) -> DsmJSONValue {
        switch value {
        case .object(let values): .object(values.mapValues(creationJSON))
        case .array(let values): .array(values.map(creationJSON))
        case .string(let text): .string(text)
        case .number(let number): .decimal(number)
        case .boolean(let flag): .boolean(flag)
        case .null: .null
        }
    }
    private static func creationJSON(_ values: [String: DsmParameterValue]) -> [String: DsmJSONValue] {
        values.mapValues { value in
            switch value {
            case .string(let value): .string(value)
            case .integer(let value): .integer(value)
            case .boolean(let value): .boolean(value)
            case .stringArray(let value): .array(value.map(DsmJSONValue.string))
            case .integerArray(let value): .array(value.map(DsmJSONValue.integer))
            case .object(let value): .object(value)
            case .objectArray(let value): .array(value.map(DsmJSONValue.object))
            }
        }
    }
    private static let creationResultKeys: Set<String> = ["name", "desc", "vcpu_num", "vram_size", "cpu_weight", "autorun",
        "repo_id", "is_general_vm", "use_ovmf", "boot_from", "iso_images", "video_card", "cpu_passthru", "hyperv_enlighten",
        "cpu_pin_num", "kb_layout", "usb_version", "usbs"]
    private func creationExpectedDigest(_ sent: [String: DsmJSONValue]) throws -> String {
        var value = sent.filter { Self.creationResultKeys.contains($0.key) }
        guard case .array(let disks)? = sent["vdisks"], case .array(let nics)? = sent["vnics"] else { throw invalidServiceResponse() }
        value["vdisks"] = .array(try disks.map { disk in
            guard case .object(let disk) = disk, case .integer(let size)? = disk["vdisk_size"], let mode = disk["vdisk_mode"] else { throw invalidServiceResponse() }
            return .object(["size": .string(String(Int64(size) * 1_024 * 1_024 * 1_024)), "vdisk_mode": mode, "unmap": .boolean(false)])
        })
        value["vnics"] = .array(try nics.map { nic in
            guard case .object(let nic) = nic else { throw invalidServiceResponse() }
            return .object(nic.filter { ["network_id", "mac", "vnic_type", "prefer_sriov"].contains($0.key) })
        })
        value["status"] = .string(sent["poweron_after_create"] == .boolean(true) ? "running" : "shutdown")
        return try Self.creationDigest(.object(value))
    }
    private func creationObservedDigest(_ settings: ServiceJSON, baseline: ServiceJSON) throws -> String {
        var value: [String: DsmJSONValue] = [:]
        for key in Self.creationResultKeys {
            guard let raw = settings[key] else { throw invalidServiceResponse() }
            if ["name", "desc", "vcpu_num", "vram_size", "cpu_weight", "autorun"].contains(key) {
                guard let basic = baseline[key], try Self.creationDigest(Self.creationJSON(basic)) == Self.creationDigest(Self.creationJSON(raw)) else {
                    throw invalidServiceResponse()
                }
            }
            if key == "vram_size" {
                let memory = try creationInteger(settings, key)
                guard memory.isMultiple(of: 1_024) else { throw invalidServiceResponse() }
                value[key] = .integer(memory / 1_024)
            } else { value[key] = Self.creationJSON(raw) }
        }
        value["status"] = .string(try creationText(baseline, "status"))
        value["vdisks"] = .array(try creationRows(settings, "vdisks").map { row in
            guard let object = row.object else { throw invalidServiceResponse() }
            return .object(object.filter { ["size", "vdisk_mode", "unmap"].contains($0.key) }.mapValues(Self.creationJSON))
        })
        value["vnics"] = .array(try creationRows(settings, "vnics").map { row in
            guard let object = row.object else { throw invalidServiceResponse() }
            return .object(object.filter { ["network_id", "mac", "vnic_type", "prefer_sriov"].contains($0.key) }.mapValues(Self.creationJSON))
        })
        return try Self.creationDigest(.object(value))
    }

    private func vmmCreationParameters(_ configuration: VirtualMachineCreation, resources: VirtualMachineCreationResources,
                                       requestID: UUID) throws -> [String: DsmParameterValue] {
        let name = try validatedName(configuration.name, message: L10n.string("shared.5350a51d42c2c339"))
        guard (1...64).contains(configuration.cpuCount) else {
            throw validationError(L10n.string("shared.f41be5e7aec143e3"))
        }
        guard (128...1_048_576).contains(configuration.memoryMiB) else {
            throw validationError(L10n.string("shared.4d40041e1ad34be1"))
        }
        guard (10...1_048_576).contains(configuration.diskGiB) else {
            throw validationError(L10n.string("shared.2b4d322a593abfbb"))
        }
        let storageID = try validatedName(
            configuration.storageID,
            message: L10n.string("shared.90d0c55da0db0537")
        )
        let networkID = configuration.networkID
        guard name == configuration.name, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (configuration.description ?? "").count <= 1_024,
              let storage = resources.storages.first(where: { $0.id == storageID }), storage.isAvailable else {
            throw validationError(L10n.string("virtual-machine.creation.resources-changed"))
        }
        if !networkID.isEmpty {
            guard resources.networksAvailable, resources.networks.contains(where: { $0.id == networkID }) else {
                throw validationError(L10n.string("shared.6f6895462cc6e8ed"))
            }
        }
        if let imageID = configuration.bootImageID {
            guard !imageID.isEmpty, resources.imagesAvailable,
                  resources.images.contains(where: { $0.id == imageID && $0.storageID == storageID && $0.hostID == storage.hostID }) else {
                throw validationError(L10n.string("shared.015a36c415279fb5"))
            }
        }
        let hostID = storage.hostID, hostName = storage.hostName
        let isLinux = configuration.operatingSystem == .linux
        let isWindows = configuration.operatingSystem == .windows
        let usesUEFI = configuration.firmware == .uefi
        let bootImages = [Self.nonEmpty(configuration.bootImageID) ?? "unmounted", "unmounted"]
        let disk: [String: DsmJSONValue] = [
            "type": .string("add"),
            "vdisk_mode": .integer(isLinux ? 1 : 2),
            "name": .string("disk-1"),
            "unmap": .boolean(false),
            "iops_enable": .boolean(false),
            "dev_limit": .integer(0),
            "dev_reservation": .integer(0),
            "dev_weight": .integer(3),
            "vdisk_size": .integer(configuration.diskGiB),
            "idx": .integer(0)
        ]
        let network: [String: DsmJSONValue] = [
            "prefer_sriov": .boolean(false),
            "vnic_type": .integer(isLinux ? 1 : 2),
            "type": .string("add"),
            "mac": .string(Self.randomVirtualMACAddress()),
            "network_id": .string(networkID)
        ]
        let parameters: [String: DsmParameterValue] = [
            "guest_privilege": .objectArray([]),
            "iso_images": .stringArray(bootImages),
            "autorun": .integer(configuration.startupBehavior.rawValue),
            "boot_from": .string("disk"),
            "bios": .string(usesUEFI ? "uefi" : "legacy"),
            "kb_layout": .string("Default"),
            "usb_version": .integer(0),
            "usbs": .stringArray(["unmounted", "unmounted", "unmounted", "unmounted"]),
            "is_windows_vm": .boolean(isWindows),
            "use_ovmf": .boolean(usesUEFI),
            "vnics": .objectArray([network]),
            "is_general_vm": .boolean(true),
            "increaseAllocatedSize": .integer(configuration.diskGiB),
            "vdisks": .objectArray([disk]),
            "auto_switch": .integer(isWindows ? 1 : 0),
            "vdisk_struct": .objectArray([]),
            "name": .string(name),
            "vcpu_num": .integer(configuration.cpuCount),
            "vram_size": .integer(configuration.memoryMiB),
            "video_card": .string(isLinux ? "vmvga" : "vga"),
            "cpu_weight": .integer(256),
            "desc": .string(configuration.description ?? ""),
            "cpu_passthru": .boolean(true),
            "hyperv_enlighten": .boolean(true),
            "cpu_pin_num": .integer(0),
            "repo_id": .string(storage.id),
            "repo_name": .string(storage.name),
            "host_id": .string(hostID),
            "repo_host_name": .string(hostName),
            "poweron_after_create": .boolean(configuration.powerOnAfterCreation),
            "synovmm_ui_id": .string(requestID.uuidString.lowercased()),
            "allocated_size": .integer(storage.allocatedBytes),
            "size": .string(storage.capacityBytes)
        ]
        return parameters
    }

    private struct VmmSettingsSubmission {
        let name: String
        let configuration: VirtualMachineUpdate
        let parameters: [String: DsmParameterValue]
        var accepted = false
    }

    /// 设置只使用已记录的内部读取，不能由公开摘要或展示默认值补全。
    public var supportsVirtualMachineSettings: Bool {
        vmmCapability(DsmAPIName.virtualizationGuest, version: 1) != nil
            && vmmCapability(DsmAPIName.virtualizationGuest, version: 2) != nil
    }

    public func loadVirtualMachineSettings(id: String) async throws -> VirtualMachineSettingsState {
        guard Self.isVmmDeletionID(id), let capability = vmmCapability(DsmAPIName.virtualizationGuest, version: 2),
              vmmCapability(DsmAPIName.virtualizationGuest, version: 1) != nil else { throw unavailableError() }
        let value: ServiceJSON
        do {
            value = try await client.call(path: capability.path, api: capability.name, version: 2, method: "get",
                requestFormat: capability.requestFormat, parameters: ["guest_id": .string(id)],
                credential: credential, as: ServiceJSON.self)
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
        try Task.checkCancellation()
        let target = try vmmSettingsState(value)
        guard target.id == id else { throw invalidServiceResponse() }
        if !activeVmmSettingsIDs.contains(id), let pending = unverifiedVmmSettings[id], pending.accepted,
           try Self.virtualMachineUpdateMatches(.object(["guests": .array([value])]), id: id,
                                                name: pending.name, parameters: pending.parameters) {
            unverifiedVmmSettings[id] = nil
        }
        return target
    }

    private func vmmSettingsList(_ capability: ApiCapability) async throws -> ServiceJSON {
        do {
            return try await client.call(path: capability.path, api: capability.name, version: 2, method: "list",
                requestFormat: capability.requestFormat, parameters: [:], credential: credential, as: ServiceJSON.self)
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
    }

    private func vmmSettingsState(_ value: ServiceJSON) throws -> VirtualMachineSettingsState {
        guard case .string(let id)? = value["guest_id"], Self.isVmmDeletionID(id),
              case .string(let name)? = value["name"], !name.isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              case .string(let status)? = value["status"], !status.isEmpty else { throw invalidServiceResponse() }
        func integer(_ key: String, range: ClosedRange<Int>) throws -> Int? {
            guard let raw = value[key] else { return nil }
            guard case .number(let number) = raw, number.isFinite, number.rounded() == number,
                  number >= Double(range.lowerBound), number <= Double(range.upperBound) else { throw invalidServiceResponse() }
            return Int(number)
        }
        let description: String?
        if let raw = value["desc"] {
            guard case .string(let text) = raw else { throw invalidServiceResponse() }
            description = text
        } else { description = nil }
        let memoryKiB = try integer("vram_size", range: 1...1_073_741_824)
        guard memoryKiB == nil || memoryKiB! % 1_024 == 0 else { throw invalidServiceResponse() }
        return VirtualMachineSettingsState(id: id, name: name, status: status, description: description,
            cpuCount: try integer("vcpu_num", range: 1...64), memoryMiB: memoryKiB.map { $0 / 1_024 },
            cpuWeight: try integer("cpu_weight", range: 1...Int(Int32.max)),
            startupBehavior: try integer("autorun", range: 0...2).flatMap(VirtualMachineStartupBehavior.init(rawValue:)))
    }

    /// 兼容 Mac 调用；同一实例未知结果只读恢复，不重新发送保存。
    public func updateVirtualMachine(
        id: String,
        configuration: VirtualMachineUpdate
    ) async throws {
        try await updateVirtualMachine(id: id, configuration: configuration, expected: nil, observer: nil)
    }

    public func updateVirtualMachine(_ target: VirtualMachineSettingsState, configuration: VirtualMachineUpdate,
                                     observer: @escaping VirtualMachineControlObserver) async throws {
        try await updateVirtualMachine(id: target.id, configuration: configuration, expected: target, observer: observer)
    }

    private func updateVirtualMachine(id: String, configuration: VirtualMachineUpdate,
                                      expected: VirtualMachineSettingsState?, observer: VirtualMachineControlObserver?) async throws {
        try Task.checkCancellation()
        guard Self.isVmmDeletionID(id) else { throw validationError(L10n.string("shared.706d4bbb975fcdc6")) }
        guard !activeVmmSettingsIDs.contains(id), !activeVmmPowerIDs.contains(id), unverifiedVmmPower[id] == nil, !networkProtectsGuest(id),
              !(activeDeletionIDsByOperation["virtualMachineDelete"] ?? []).contains(id),
              [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuest].allSatisfy({
                  unverifiedVmmDeletions[$0]?[id] == nil
              }) else {
            throw validationError(L10n.string("virtual-machine.power.review-required"))
        }
        guard let capability = vmmCapability(DsmAPIName.virtualizationGuest, version: 1),
              vmmCapability(DsmAPIName.virtualizationGuest, version: 2) != nil else {
            throw unavailableError()
        }
        activeVmmSettingsIDs.insert(id)
        defer { activeVmmSettingsIDs.remove(id) }
        if let pending = unverifiedVmmSettings[id] {
            guard expected == nil, pending.configuration == configuration else {
                throw verificationError(L10n.string("virtual-machine.settings.unverified"))
            }
            let values = try await vmmSettingsList(capability)
            guard pending.accepted,
                  try Self.virtualMachineUpdateMatches(values, id: id, name: pending.name, parameters: pending.parameters) else {
                throw verificationError(L10n.string("virtual-machine.settings.unverified"))
            }
            unverifiedVmmSettings[id] = nil
            return
        }
        let raw = try await vmmSettingsList(capability)
        let objects = try Self.strictRootObjects(raw, keys: ["guests", "guest", "vms"])
        let machines = try objects.map { try vmmSettingsState(.object($0)) }
        try Self.requireCompleteServiceList(raw, count: machines.count)
        guard Set(machines.map(\.id)).count == machines.count else { throw invalidServiceResponse() }
        guard let current = machines.first(where: { $0.id == id }) else {
            throw validationError(L10n.string("shared.706d4bbb975fcdc6"))
        }
        guard current.canEdit, expected == nil || expected == current else {
            throw validationError(L10n.string("virtual-machine.settings.changed"))
        }
        var parameters: [String: DsmParameterValue] = [
            "guest_id": .string(id),
            "synovmm_ui_id": .string(UUID().uuidString.lowercased())
        ]
        if let name = configuration.name {
            let name = try validatedName(name, message: L10n.string("shared.5350a51d42c2c339"))
            guard !machines.contains(where: {
                $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) else {
                throw validationError(L10n.string("shared.433935ad21c1d3da"))
            }
            parameters["name"] = .string(name)
        }
        if let description = configuration.description {
            guard description.count <= 1_024 else {
                throw validationError(L10n.string("shared.f9112198a60b7d70"))
            }
            parameters["desc"] = .string(description)
        }
        if let cpuWeight = configuration.cpuWeight {
            guard [8, 64, 256, 512, 1024].contains(cpuWeight) else {
                throw validationError(L10n.string("shared.4f060f32743040c5"))
            }
            parameters["cpu_weight"] = .integer(cpuWeight)
        }
        if let startupBehavior = configuration.startupBehavior {
            parameters["autorun"] = .integer(startupBehavior.rawValue)
        }

        if configuration.cpuCount != nil || configuration.memoryMiB != nil {
            guard current.canEditHardware else {
                throw validationError(L10n.string("shared.b67ec1a7e6173fed"))
            }
            if let cpuCount = configuration.cpuCount {
                guard (1...64).contains(cpuCount) else {
                    throw validationError(L10n.string("shared.f41be5e7aec143e3"))
                }
                parameters["vcpu_num"] = .integer(cpuCount)
            }
            if let memoryMiB = configuration.memoryMiB {
                guard (128...1_048_576).contains(memoryMiB) else {
                    throw validationError(L10n.string("shared.4d40041e1ad34be1"))
                }
                parameters["vram_size"] = .integer(memoryMiB)
            }
        }
        guard parameters.count > 2 else {
            throw validationError(L10n.string("shared.c01558c4918833c0"))
        }
        guard !creationProtects(id: id, name: current.name),
              !creationProtects(id: id, name: configuration.name ?? current.name) else {
            throw verificationError(L10n.string("virtual-machine.creation.pending"))
        }
        try Task.checkCancellation()
        try await observer?(.willSubmit)
        unverifiedVmmSettings[id] = VmmSettingsSubmission(name: current.name, configuration: configuration, parameters: parameters)
        // 当前官方编辑器固定 Guest.set v1；不能跟随只读 get/list 的 v2。
        do {
            try await client.callVoid(path: capability.path, api: DsmAPIName.virtualizationGuest, version: 1,
                method: "set", requestFormat: capability.requestFormat, parameters: parameters, credential: credential)
        } catch let error as DsmNetworkError {
            let mapped = DsmErrorMapper.map(error)
            if Self.imageManagementTrustError(mapped) { throw mapped }
            let rejected: Bool = switch error {
            case .api(let code, _) where code > 0: true
            case .invalidRequest: true
            default: false
            }
            if rejected {
                unverifiedVmmSettings[id] = nil
                try await observer?(.rejected)
                throw mapped
            }
            if case .cancelled = error { throw CancellationError() }
            throw verificationError(L10n.string("virtual-machine.settings.unverified"))
        } catch let error as DsmCertificateTrustError { throw error }
        catch let error as AppError {
            if Self.imageManagementTrustError(error) { throw error }
            throw verificationError(L10n.string("virtual-machine.settings.unverified"))
        } catch { throw verificationError(L10n.string("virtual-machine.settings.unverified")) }
        unverifiedVmmSettings[id]?.accepted = true
        try await observer?(.accepted)
        try Task.checkCancellation()
        // 内部写只按同一内部清单的原始字段核查，不能用公开清单或展示默认值证明保存。
        let updated = try await vmmSettingsList(capability)
        guard try Self.virtualMachineUpdateMatches(updated, id: id, name: current.name, parameters: parameters) else {
            throw AppError(category: .conflict, isRetryable: false, safeUserMessage: L10n.string("virtual-machine.settings.unverified"))
        }
        unverifiedVmmSettings[id] = nil
        try await observer?(.verified)
    }

    private static func virtualMachineUpdateMatches(
        _ value: ServiceJSON,
        id: String,
        name: String,
        parameters: [String: DsmParameterValue]
    ) throws -> Bool {
        let machines = try strictRootObjects(value, keys: ["guests", "guest", "vms"])
        try requireCompleteServiceList(value, count: machines.count)
        let targets = machines.filter { machine in
            if case .string(let actual)? = machine["guest_id"] { return actual == id }
            return false
        }
        guard targets.count == 1, let target = targets.first else { return false }
        let expectedName: String
        if case .string(let updatedName)? = parameters["name"] { expectedName = updatedName } else { expectedName = name }
        guard case .string(let actualName)? = target["name"], actualName == expectedName else { return false }
        // 保留空说明和精确数字；不将缺失、布尔、小数或展示层默认值转换为已保存。
        for key in ["name", "desc", "vcpu_num", "vram_size", "cpu_weight", "autorun"] {
            guard let expected = parameters[key] else { continue }
            switch expected {
            case .string(let text):
                guard case .string(let actual)? = target[key], actual == text else { return false }
            case .integer(let number):
                // 内部清单读取 KiB，但 create/set 的内存参数为 MiB；不能直接比较原始数值。
                let expectedRead = key == "vram_size" ? Double(number) * 1_024 : Double(number)
                guard case .number(let actual)? = target[key], actual == expectedRead else { return false }
            default:
                return false
            }
        }
        return true
    }

    public func openVirtualMachineConsole(id: String) async throws -> VirtualMachineConsoleSession {
        let id = try validatedIDs([id])[0]
        let snapshot = try await loadVirtualMachineManager()
        guard let machine = snapshot.machines.first(where: { $0.id == id }) else {
            throw validationError(L10n.string("shared.706d4bbb975fcdc6"))
        }
        guard Self.isVirtualMachineRunning(machine.status) else {
            throw validationError(L10n.string("shared.7047a09e87d95943"))
        }
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("webman", isDirectory: true)
                .appendingPathComponent("3rdparty", isDirectory: true)
                .appendingPathComponent("Virtualization", isDirectory: true)
                .appendingPathComponent("noVNC", isDirectory: true)
                .appendingPathComponent("vnc.html"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "autoconnect", value: "true"),
            URLQueryItem(name: "reconnect", value: "true"),
            URLQueryItem(name: "path", value: "synovirtualization/ws/\(id)"),
            URLQueryItem(name: "title", value: machine.name),
            URLQueryItem(name: "app_id", value: UUID().uuidString.lowercased()),
            URLQueryItem(
                name: "kb_layout",
                value: machine.keyboardLayout == "Default"
                    ? "en-us"
                    : machine.keyboardLayout ?? "en-us"
            ),
            URLQueryItem(name: "app_alias", value: "")
        ]
        guard let url = components?.url else {
            throw verificationError(L10n.string("shared.59faeb679e4861af"))
        }
        return VirtualMachineConsoleSession(
            url: url,
            sessionCookieValue: credential.sid
        )
    }

    public func controlVirtualMachines(ids: [String], action: VirtualMachinePowerAction) async throws {
        try await controlVirtualMachines(ids: ids, action: action, expected: nil, observer: nil)
    }

    public func controlVirtualMachine(_ target: VirtualMachineControlState, action: VirtualMachinePowerAction,
                                      observer: @escaping VirtualMachineControlObserver) async throws {
        guard target.supports(action) else { throw validationError(L10n.string("virtual-machine.power.target-changed")) }
        try await controlVirtualMachines(ids: [target.id], action: action, expected: target, observer: observer)
    }

    /// 严格读取原始清单；只读恢复不发送电源，也不把没有回执的外部变化归于原操作。
    public func loadVirtualMachineControlStates() async throws -> [VirtualMachineControlState] {
        let capability = try vmmGuestCapability()
        let value: ServiceJSON
        do {
            value = try await client.call(path: capability.path, api: capability.name,
                version: capability.name == DsmAPIName.virtualizationAPIGuest ? 1 : 2,
                method: "list", requestFormat: capability.requestFormat, parameters: [:],
                credential: credential, as: ServiceJSON.self)
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
        try Task.checkCancellation()
        guard case .array(let values)? = value["guests"] else { throw invalidServiceResponse() }
        try Self.requireCompleteServiceList(value, count: values.count)
        var identifiers = Set<String>()
        let targets = try values.map { value in
            let target = try vmmControlState(value, capability: capability)
            guard identifiers.insert(target.id).inserted else { throw invalidServiceResponse() }
            return target
        }
        for target in targets {
            if !activeVmmPowerIDs.contains(target.id), let pending = unverifiedVmmPower[target.id], pending.accepted,
               target.name == pending.name, target.verifies(pending.action) {
                unverifiedVmmPower[target.id] = nil
            }
        }
        let remaining = Set(targets.map(\.id))
        for api in [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuest] {
            for (id, pending) in unverifiedVmmDeletions[api, default: [:]]
                where pending.accepted && !remaining.contains(id) && !(activeDeletionIDsByOperation["virtualMachineDelete"] ?? []).contains(id) {
                unverifiedVmmDeletions[api]?[id] = nil
            }
        }
        return targets
    }

    public func deleteVirtualMachines(ids: [String]) async throws {
        let result = try await deleteVirtualMachinesResult(ids: ids)
        guard result.status == .confirmedSuccess else {
            throw AppError(category: result.errorCategory == .authentication ? .authenticationRequired : result.status == .permissionDenied ? .permissionDenied : .partialFailure,
                isRetryable: false, safeUserMessage: result.localizationKey.map { L10n.string($0) }
                    ?? L10n.string("shared.bf17ba5ccdef0c83"))
        }
    }

    /// 公开/内部删除均逐项固定 v1；移动确认与旧入口复用同一状态核查及回执流水线。
    public func deleteVirtualMachinesResult(ids: [String]) async throws -> MutationResult {
        try await deleteVirtualMachinesResult(ids: ids, expected: nil, observer: nil)
    }

    public func deleteVirtualMachine(_ target: VirtualMachineControlState,
                                     observer: @escaping VirtualMachineControlObserver) async throws {
        guard target.canDelete else { throw validationError(L10n.string("virtual-machine.power.target-changed")) }
        let result = try await deleteVirtualMachinesResult(ids: [target.id], expected: target, observer: observer)
        guard result.status == .confirmedSuccess else {
            let category: AppErrorCategory = switch result.errorCategory {
            case .authentication: .authenticationRequired
            case .permission: .permissionDenied
            case .unsupported: .apiUnavailable
            case .validation, .conflict: .conflict
            default: .partialFailure
            }
            throw AppError(category: category, isRetryable: false,
                           safeUserMessage: L10n.string(result.localizationKey ?? "virtual-machine.delete.unverified"))
        }
    }

    private func deleteVirtualMachinesResult(ids: [String], expected: VirtualMachineControlState?,
                                             observer: VirtualMachineControlObserver?) async throws -> MutationResult {
        let api = capabilities[DsmAPIName.virtualizationAPIGuest]?.selectedVersion != nil
            ? DsmAPIName.virtualizationAPIGuest : DsmAPIName.virtualizationGuest
        return try await deleteVmmResources(ids: ids, api: api, arrayKey: "guests", idKey: "guest_id",
            context: ServiceDeletionContext(operation: "virtualMachineDelete", localizationPrefix: "virtual-machine.delete"),
            expected: expected, observer: observer)
    }

    public var supportsVirtualMachineNetworks: Bool {
        vmmCapability(DsmAPIName.virtualizationNetwork, version: 1) != nil
            && vmmCapability(DsmAPIName.virtualizationNetwork, version: 2) != nil
    }

    private struct VmmNetworkSubmission {
        let target: VirtualMachineNetworkState
        let newName: String?
        var accepted = false
    }
    private struct VmmNetworkList {
        let frozen: Bool
        let networks: [VirtualMachineNetworkState]
        let guestCounts: [String: Int]
    }

    /// 只读详情中的 get 不含网络 ID，必须结合完整 list 的唯一身份、名称及关联数量。
    public func loadVirtualMachineNetworks() async throws -> VirtualMachineNetworkInventory {
        let list = try await vmmNetworkList()
        var networks: [VirtualMachineNetworkState] = []
        for network in list.networks {
            networks.append(try await vmmNetworkDetail(network, guestCount: list.guestCounts[network.id]!))
        }
        if !list.frozen {
            for (id, pending) in pendingVmmNetworks where pending.accepted && !activeVmmNetworkMutationIDs.contains(id) {
                let current = networks.first { $0.id == id }
                let matches = pending.newName.map { name in current?.name == name && current?.hasSameTopology(as: pending.target) == true }
                    ?? (current == nil)
                if matches { pendingVmmNetworks[id] = nil }
            }
        }
        return .init(isFrozen: list.frozen, networks: networks)
    }

    private func vmmNetworkList() async throws -> VmmNetworkList {
        guard vmmCapability(DsmAPIName.virtualizationNetwork, version: 2) != nil else { throw unavailableError() }
        let value = try await call(DsmAPIName.virtualizationNetwork, method: "list", fixedVersion: 2)
        let frozen = try creationBool(value, "is_freeze")
        var ids = Set<String>(), names = Set<String>(), counts: [String: Int] = [:]
        let networks = try creationRows(value, "networks").map { row in
            let id = try creationText(row, "network_id"), name = try creationText(row, "name")
            let type = try creationText(row, "type"), vlan = try creationInteger(row, "vlan_id")
            guard case .string(let host)? = row["host_id"], ["external", "private"].contains(type),
                  type != "private" || Self.isVmmDeletionID(host), vlan <= 4094,
                  VirtualMachineNetworkState.isValidName(name), ids.insert(id).inserted,
                  names.insert(Self.creationNameDigest(name)).inserted else { throw invalidServiceResponse() }
            let interfaces = try creationRows(row, "interfaces").map { item in
                let host = try creationText(item, "host_id"), interface = try creationText(item, "interface_id")
                guard Self.isVmmDeletionID(interface) else { throw invalidServiceResponse() }
                return VirtualMachineNetworkState.Interface(hostID: host, id: interface)
            }
            guard type != "external" || !interfaces.isEmpty, Set(interfaces).count == interfaces.count,
                  try creationInteger(row, "num_interfaces") == interfaces.count else { throw invalidServiceResponse() }
            _ = try creationInteger(row, "num_hosts"); _ = try creationInteger(row, "num_vinterfaces")
            counts[id] = try creationInteger(row, "num_guests")
            return VirtualMachineNetworkState(id: id, name: name, type: type, hostID: host, vlanID: vlan, interfaces: interfaces, guests: [])
        }
        try Task.checkCancellation()
        return VmmNetworkList(frozen: frozen, networks: networks, guestCounts: counts)
    }

    private func vmmNetworkDetail(_ network: VirtualMachineNetworkState, guestCount: Int) async throws -> VirtualMachineNetworkState {
        let value = try await call(DsmAPIName.virtualizationNetwork, method: "get",
            parameters: ["network_id": .string(network.id)], fixedVersion: 2)
        guard try creationText(value, "name") == network.name else { throw invalidServiceResponse() }
        // 详情接口只有主机/接口显示名与实时指标，不用这些字段猜测拓扑 ID。
        _ = try creationRows(value, "interfaces")
        let guests = try creationRows(value, "guests").map { item in
            guard case .string(let mac)? = item["mac_addr"], case .string(let interfaces)? = item["vinterface_names"] else {
                throw invalidServiceResponse()
            }
            return VirtualMachineNetworkState.Guest(id: try creationText(item, "guest_id"), name: try creationText(item, "name"),
                isRunning: try creationBool(item, "running"), prefersSriov: try creationBool(item, "prefer_sriov"),
                usesVirtualFunction: try creationBool(item, "use_vf"), macAddress: mac, interfaceNames: interfaces)
        }
        guard guests.count == guestCount, Set(guests.map(\.id)).count == guests.count else { throw invalidServiceResponse() }
        try Task.checkCancellation()
        return .init(id: network.id, name: network.name, type: network.type, hostID: network.hostID,
                     vlanID: network.vlanID, interfaces: network.interfaces, guests: guests)
    }

    public func updateVirtualMachineNetwork(id: String, configuration: VirtualMachineNetworkUpdate) async throws {
        try await mutateVmmNetwork(id: id, expected: nil, newName: configuration.name, observer: nil)
    }
    public func updateVirtualMachineNetwork(_ target: VirtualMachineNetworkState, configuration: VirtualMachineNetworkUpdate,
                                            observer: @escaping VirtualMachineControlObserver) async throws {
        try await mutateVmmNetwork(id: target.id, expected: target, newName: configuration.name, observer: observer)
    }
    public func deleteVirtualMachineNetwork(_ target: VirtualMachineNetworkState,
                                            observer: @escaping VirtualMachineControlObserver) async throws {
        try await mutateVmmNetwork(id: target.id, expected: target, newName: nil, observer: observer)
    }

    private func networkProtectsGuest(_ id: String) -> Bool {
        activeVmmNetworkGuests.values.contains { $0.contains(id) }
            || pendingVmmNetworks.values.contains { $0.target.guests.contains { $0.id == id } }
    }
    private func networkGuestsAreAvailable(_ target: VirtualMachineNetworkState) -> Bool {
        !target.guests.contains { guest in
            networkProtectsGuest(guest.id) || activeVmmPowerIDs.contains(guest.id) || unverifiedVmmPower[guest.id] != nil
                || activeVmmSettingsIDs.contains(guest.id) || unverifiedVmmSettings[guest.id] != nil
                || activeDeletionIDsByOperation["virtualMachineDelete"]?.contains(guest.id) == true
                || [DsmAPIName.virtualizationGuest, DsmAPIName.virtualizationAPIGuest].contains {
                    unverifiedVmmDeletions[$0]?[guest.id] != nil
                } || creationProtects(id: guest.id, name: guest.name)
        }
    }

    /// 旧 Mac 入口与移动确认共用；回执丢失不会由同名/消失清单认领或重发。
    private func mutateVmmNetwork(id: String, expected: VirtualMachineNetworkState?, newName: String?,
                                  observer: VirtualMachineControlObserver?) async throws {
        try Task.checkCancellation()
        guard supportsVirtualMachineNetworks, let capability = vmmCapability(DsmAPIName.virtualizationNetwork, version: 1) else {
            throw unavailableError()
        }
        guard Self.isVmmDeletionID(id), newName.map(VirtualMachineNetworkState.isValidName) ?? true else {
            throw validationError(L10n.string("virtual-machine-network.invalid-name"))
        }
        guard !creationReferences("network", id: id), activeVmmNetworkMutationIDs.insert(id).inserted else {
            throw verificationError(L10n.string("virtual-machine-network.pending"))
        }
        defer { activeVmmNetworkMutationIDs.remove(id); activeVmmNetworkGuests[id] = nil }
        if let pending = pendingVmmNetworks[id] {
            guard expected == nil, pending.newName == newName, try await vmmNetworkResultMatches(pending) else {
                throw verificationError(L10n.string("virtual-machine-network.pending"))
            }
            pendingVmmNetworks[id] = nil
            return
        }
        let reservedName = newName.map(Self.creationNameDigest)
        if let reservedName {
            guard !pendingVmmNetworks.values.contains(where: { $0.newName.map(Self.creationNameDigest) == reservedName }),
                  activeVmmNetworkNames.insert(reservedName).inserted else {
                throw verificationError(L10n.string("virtual-machine-network.pending"))
            }
        }
        defer { if let reservedName { activeVmmNetworkNames.remove(reservedName) } }
        let list = try await vmmNetworkList()
        guard !list.frozen, let row = list.networks.first(where: { $0.id == id }),
              newName == nil || !list.networks.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(newName!) == .orderedSame }) else {
            throw validationError(L10n.string("virtual-machine-network.changed"))
        }
        let target = try await vmmNetworkDetail(row, guestCount: list.guestCounts[id]!)
        guard expected == nil || expected == target, networkGuestsAreAvailable(target), !creationReferences("network", id: id) else {
            throw validationError(L10n.string("virtual-machine-network.changed"))
        }
        activeVmmNetworkGuests[id] = Set(target.guests.map(\.id))
        // 纯改名不发送 VLAN 或整份接口列表，保留原网络类型/主机及官方空增量字段。
        var parameters: [String: DsmParameterValue] = ["network_id": .string(id)]
        if let newName {
            // 保留 Mac 旧表单的未修改保存行为，已严格核对原对象后直接结束且零写。
            if newName == target.name && expected == nil { return }
            guard newName != target.name else { throw validationError(L10n.string("virtual-machine-network.invalid-name")) }
            parameters["name"] = .string(newName)
            if target.type == "external" {
                parameters["interfaces_add"] = .objectArray([]); parameters["interfaces_remove"] = .objectArray([])
            } else { parameters["host_id"] = .string(target.hostID) }
        }
        try Task.checkCancellation()
        try await observer?(.willSubmit)
        pendingVmmNetworks[id] = VmmNetworkSubmission(target: target, newName: newName)
        do {
            try await client.callVoid(path: capability.path, api: capability.name, version: 1,
                method: newName == nil ? "delete" : "set", requestFormat: capability.requestFormat,
                parameters: parameters, credential: credential)
        } catch let error as DsmNetworkError {
            let mapped = DsmErrorMapper.map(error)
            if Self.imageManagementTrustError(mapped) { throw mapped }
            let rejected: Bool = switch error { case .api(let code, _) where code > 0: true; case .invalidRequest: true; default: false }
            if rejected {
                pendingVmmNetworks[id] = nil
                try await observer?(.rejected)
                throw mapped
            }
            if case .cancelled = error { throw CancellationError() }
            if [.authenticationRequired, .otpRequired, .permissionDenied].contains(mapped.category) { throw mapped }
            throw verificationError(L10n.string("virtual-machine-network.pending"))
        } catch {
            if Self.imageManagementTrustError(error)
                || (error as? AppError).map({ [.authenticationRequired, .otpRequired].contains($0.category) }) == true { throw error }
            if error is CancellationError { throw error }
            throw verificationError(L10n.string("virtual-machine-network.pending"))
        }
        pendingVmmNetworks[id]?.accepted = true
        try await observer?(.accepted)
        try Task.checkCancellation()
        guard let pending = pendingVmmNetworks[id], try await vmmNetworkResultMatches(pending) else {
            throw verificationError(L10n.string("virtual-machine-network.pending"))
        }
        pendingVmmNetworks[id] = nil
        try await observer?(.verified)
    }

    private func vmmNetworkResultMatches(_ pending: VmmNetworkSubmission) async throws -> Bool {
        guard pending.accepted else { return false }
        let list = try await vmmNetworkList()
        guard !list.frozen else { return false }
        let row = list.networks.first { $0.id == pending.target.id }
        guard let name = pending.newName else { return row == nil }
        guard let row, row.name == name else { return false }
        let current = try await vmmNetworkDetail(row, guestCount: list.guestCounts[row.id]!)
        return current.hasSameTopology(as: pending.target)
    }

    public func deleteVirtualMachineNetworks(ids: [String]) async throws {
        guard supportsVirtualMachineNetworks else { throw unavailableError() }
        let result = try await deleteVirtualMachineNetworksResult(ids: ids)
        guard result.status == .confirmedSuccess else {
            throw AppError(category: result.errorCategory == .authentication ? .authenticationRequired
                : result.status == .permissionDenied ? .permissionDenied : .partialFailure, isRetryable: false,
                safeUserMessage: L10n.string(result.localizationKey ?? "virtual-machine-network.delete.unverified"))
        }
    }

    /// 多项删除先核对全选集合，再逐项提交与只读回查；未知后停止余项。
    public func deleteVirtualMachineNetworksResult(ids: [String]) async throws -> MutationResult {
        let context = ServiceDeletionContext(operation: "virtualMachineNetworkDelete", localizationPrefix: "virtual-machine-network.delete")
        if Task.isCancelled { return try deletionCancellationBeforeSubmission(context: context) }
        guard !ids.isEmpty, ids.allSatisfy(Self.isVmmDeletionID) else {
            return try deletionUnexpectedPreflightResult(targetCount: max(1, ids.count), context: context)
        }
        let ids = Array(Set(ids)).sorted()
        guard supportsVirtualMachineNetworks else { return try deletionUnsupportedResult(targetCount: ids.count, context: context) }
        guard ids.allSatisfy({ !creationReferences("network", id: $0) }) else {
            throw verificationError(L10n.string("virtual-machine.creation.pending"))
        }
        guard activeVmmNetworkMutationIDs.isDisjoint(with: ids) else {
            return try deletionDuplicateResult(targetCount: ids.count, context: context)
        }
        var succeeded = 0, submitted = false
        func summary(unknown: Int, category: MutationErrorCategory? = nil) throws -> MutationResult {
            let status: MutationResultStatus = Task.isCancelled && submitted ? .cancellationRequestedAfterSubmission
                : succeeded == ids.count ? .confirmedSuccess : succeeded > 0 ? .partialSuccess
                : unknown > 0 ? .submittedButUnverified : category == .permission ? .permissionDenied : .confirmedFailure
            return try serviceDeletionResult(status: status, context: context, submitted: submitted,
                requiresRefresh: submitted && status != .confirmedSuccess,
                succeeded: succeeded, failed: ids.count - succeeded - unknown, unknown: unknown, errorCategory: category,
                localizationSuffix: category == .authentication ? "authentication" : status == .confirmedSuccess ? "completed"
                    : succeeded > 0 ? "partial" : unknown > 0 ? "unverified" : category == .permission ? "permission-denied" : "failed",
                diagnosticSuffix: "internal-v1-batch")
        }
        do {
            let prior = ids.filter { pendingVmmNetworks[$0] != nil }
            if !prior.isEmpty {
                submitted = true
                for id in prior {
                    guard let pending = pendingVmmNetworks[id], pending.newName == nil else {
                        return try summary(unknown: prior.count - succeeded, category: .conflict)
                    }
                    if try await vmmNetworkResultMatches(pending) { pendingVmmNetworks[id] = nil; succeeded += 1 }
                }
                return try summary(unknown: prior.count - succeeded)
            }
            let list = try await vmmNetworkList()
            guard !list.frozen, ids.allSatisfy({ id in list.networks.contains { $0.id == id } }) else {
                return try summary(unknown: 0, category: .conflict)
            }
            var targets: [VirtualMachineNetworkState] = []
            for id in ids {
                let target = try await vmmNetworkDetail(list.networks.first { $0.id == id }!, guestCount: list.guestCounts[id]!)
                guard networkGuestsAreAvailable(target) else { return try summary(unknown: 0, category: .conflict) }
                targets.append(target)
            }
            for target in targets {
                let tracking = NetworkDeletionTracking()
                do {
                    try await mutateVmmNetwork(id: target.id, expected: target, newName: nil, observer: { await tracking.recordVmm($0) })
                    submitted = true; succeeded += 1
                } catch {
                    let state = await tracking.state
                    submitted = submitted || state.submitted
                    if Self.imageManagementTrustError(error)
                || (error as? AppError).map({ [.authenticationRequired, .otpRequired].contains($0.category) }) == true { throw error }
                    let category = (error as? AppError).map { serviceMutationErrorCategory(for: $0.category) }
                    return try summary(unknown: state.submitted && !state.rejected ? 1 : 0, category: category)
                }
            }
            return try summary(unknown: 0)
        } catch {
            if Self.imageManagementTrustError(error)
                || (error as? AppError).map({ [.authenticationRequired, .otpRequired].contains($0.category) }) == true { throw error }
            if Task.isCancelled && !submitted { return try deletionCancellationBeforeSubmission(context: context) }
            let category = (error as? AppError).map { serviceMutationErrorCategory(for: $0.category) }
            return try summary(unknown: submitted ? ids.filter { pendingVmmNetworks[$0] != nil }.count : 0, category: category)
        }
    }

    /// 映像删除使用同步空响应；公开接口固定 v1，不根据无关字段猜测异步任务。
    public func deleteVirtualMachineImages(ids: [String]) async throws {
        let result = try await deleteVirtualMachineImagesResult(ids: ids)
        guard result.status == .confirmedSuccess else {
            throw AppError(category: result.errorCategory == .authentication ? .authenticationRequired : result.status == .permissionDenied ? .permissionDenied : .partialFailure,
                isRetryable: false, safeUserMessage: result.localizationKey.map { L10n.string($0) }
                    ?? L10n.string("shared.298bd4a069695e72"))
        }
    }

    private struct VmmDeletion {
        var accepted = false
    }

    private struct VmmPowerTarget {
        let name: String
        let action: VirtualMachinePowerAction
        let guestAPI: String
        var accepted = false
    }

    private struct VmmPowerRoute {
        let action: ApiCapability
        let guest: ApiCapability
        var isInternal: Bool { guest.name == DsmAPIName.virtualizationGuest }
        var readVersion: Int { isInternal ? 2 : 1 }
    }

    private func vmmCapability(_ api: String, version: Int) -> ApiCapability? {
        guard let capability = capabilities[api], capability.name == api, capability.selectedVersion != nil,
              capability.minVersion <= version, capability.maxVersion >= version else { return nil }
        return capability
    }

    private func vmmGuestCapability() throws -> ApiCapability {
        let usesPublic = capabilities[DsmAPIName.virtualizationAPIGuest]?.selectedVersion != nil
        guard let value = vmmCapability(usesPublic ? DsmAPIName.virtualizationAPIGuest : DsmAPIName.virtualizationGuest,
                                        version: usesPublic ? 1 : 2) else { throw unavailableError() }
        return value
    }

    private func vmmPowerRoute(_ action: VirtualMachinePowerAction) throws -> VmmPowerRoute {
        // 公开 v1 无 reboot；仅该动作明确使用已经记录的内部接口，不把拒绝改为另一种写法。
        let usesPublic = action != .restart && capabilities[DsmAPIName.virtualizationAPIGuestAction]?.selectedVersion != nil
        let actionAPI = usesPublic ? DsmAPIName.virtualizationAPIGuestAction : DsmAPIName.virtualizationGuestAction
        let guestAPI = usesPublic ? DsmAPIName.virtualizationAPIGuest : DsmAPIName.virtualizationGuest
        guard let write = vmmCapability(actionAPI, version: 1),
              let read = vmmCapability(guestAPI, version: usesPublic ? 1 : 2) else {
            if action == .restart {
                throw AppError(category: .apiUnavailable, isRetryable: false,
                               safeUserMessage: L10n.string("virtual-machine.power.restart-unavailable"))
            }
            throw unavailableError()
        }
        return VmmPowerRoute(action: write, guest: read)
    }

    /// 两条已记录接口共享身份、回执和恢复边界；不会因未知结果切换接口或重放。
    private func controlVirtualMachines(ids: [String], action: VirtualMachinePowerAction,
                                        expected: VirtualMachineControlState?, observer: VirtualMachineControlObserver?) async throws {
        try Task.checkCancellation()
        guard !ids.isEmpty, ids.allSatisfy(Self.isVmmDeletionID) else {
            throw validationError(L10n.string("shared.e594e487c681e714"))
        }
        let route = try vmmPowerRoute(action)
        let targets = Array(Set(ids)).sorted(), targetSet = Set(targets)
        guard !targets.contains(where: networkProtectsGuest), activeVmmPowerIDs.isDisjoint(with: targetSet),
              activeVmmSettingsIDs.isDisjoint(with: targetSet),
              Set(unverifiedVmmSettings.keys).isDisjoint(with: targetSet),
              (activeDeletionIDsByOperation["virtualMachineDelete"] ?? []).isDisjoint(with: targetSet),
              [DsmAPIName.virtualizationAPIGuest, DsmAPIName.virtualizationGuest].allSatisfy({
                  Set(unverifiedVmmDeletions[$0, default: [:]].keys).isDisjoint(with: targetSet)
              }) else {
            throw validationError(L10n.string("virtual-machine.power.review-required"))
        }
        activeVmmPowerIDs.formUnion(targetSet)
        defer { activeVmmPowerIDs.subtract(targetSet) }

        let prior = targets.filter { unverifiedVmmPower[$0] != nil }
        if !prior.isEmpty {
            // 新确认不能消费旧提交；旧入口只恢复原动作，不借混合选择继续未执行目标。
            guard expected == nil else { throw verificationError(L10n.string("virtual-machine.power.unverified")) }
            for id in prior {
                guard let pending = unverifiedVmmPower[id], pending.action == action,
                      pending.guestAPI == route.guest.name else {
                    throw validationError(L10n.string("virtual-machine.power.review-required"))
                }
            }
            for id in prior {
                let pending = unverifiedVmmPower[id]!
                let current = try await readVmmPowerTarget(id: id, route: route)
                guard pending.accepted, current.name == pending.name, current.verifies(action) else {
                    throw verificationError(L10n.string("virtual-machine.power.unverified"))
                }
                unverifiedVmmPower[id] = nil
            }
            guard prior.count == targets.count else { throw verificationError(L10n.string("virtual-machine.power.review-only")) }
            return
        }

        var baselines: [String: VirtualMachineControlState] = [:]
        for id in targets {
            let current = try await readVmmPowerTarget(id: id, route: route)
            guard current.supports(action), expected == nil || current == expected,
                  !creationProtects(id: id, name: current.name) else {
                throw validationError(L10n.string("virtual-machine.power.target-changed"))
            }
            baselines[id] = current
        }
        for id in targets {
            let current = try await readVmmPowerTarget(id: id, route: route)
            guard current == baselines[id], current.supports(action), !creationProtects(id: id, name: current.name) else {
                throw validationError(L10n.string("virtual-machine.power.target-changed"))
            }
            try Task.checkCancellation()
            try await observer?(.willSubmit)
            unverifiedVmmPower[id] = VmmPowerTarget(name: current.name, action: action, guestAPI: route.guest.name)
            let command: String = switch action {
            case .powerOn: "poweron"
            case .shutdown: "shutdown"
            case .powerOff: "poweroff"
            case .restart: "reboot"
            }
            var parameters: [String: DsmParameterValue] = ["guest_id": .string(id)]
            if route.isInternal { parameters["action"] = .string(command) }
            do {
                try await client.callVoid(path: route.action.path, api: route.action.name, version: 1,
                    method: route.isInternal ? "pwr_ctl" : command, requestFormat: route.action.requestFormat,
                    parameters: parameters, credential: credential)
            } catch let error as DsmNetworkError {
                let mapped = DsmErrorMapper.map(error)
                if Self.imageManagementTrustError(mapped) { throw mapped }
                let rejected: Bool = switch error {
                case .api(let code, _) where code > 0: true
                case .invalidRequest: true
                default: false
                }
                if rejected {
                    unverifiedVmmPower[id] = nil
                    try await observer?(.rejected)
                    throw DsmErrorMapper.map(error)
                }
                if case .cancelled = error { throw CancellationError() }
                throw verificationError(L10n.string("virtual-machine.power.unverified"))
            } catch let error as DsmCertificateTrustError { throw error }
            catch let error as AppError {
                if Self.imageManagementTrustError(error) { throw error }
                throw verificationError(L10n.string("virtual-machine.power.unverified"))
            }
            catch { throw verificationError(L10n.string("virtual-machine.power.unverified")) }
            unverifiedVmmPower[id]?.accepted = true
            try await observer?(.accepted)
            try Task.checkCancellation()
            let updated = try await readVmmPowerTarget(id: id, route: route)
            guard updated.name == current.name, updated.verifies(action) else {
                throw verificationError(L10n.string("virtual-machine.power.unverified"))
            }
            unverifiedVmmPower[id] = nil
            try await observer?(.verified)
        }
    }

    private func readVmmPowerTarget(id: String, route: VmmPowerRoute) async throws -> VirtualMachineControlState {
        let value: ServiceJSON
        do {
            value = try await client.call(path: route.guest.path, api: route.guest.name, version: route.readVersion,
                method: "get", requestFormat: route.guest.requestFormat, parameters: ["guest_id": .string(id)],
                credential: credential, as: ServiceJSON.self)
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
        try Task.checkCancellation()
        let target = try vmmControlState(value, capability: route.guest)
        guard target.id == id else { throw invalidServiceResponse() }
        return target
    }

    private func vmmControlState(_ value: ServiceJSON, capability: ApiCapability) throws -> VirtualMachineControlState {
        let usesPublic = capability.name == DsmAPIName.virtualizationAPIGuest
        guard case .string(let id)? = value["guest_id"], Self.isVmmDeletionID(id),
              case .string(let name)? = value[usesPublic ? "guest_name" : "name"], !name.isEmpty,
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              case .string(let status)? = value["status"], !status.isEmpty else { throw invalidServiceResponse() }
        let actions: [VirtualMachinePowerAction] = [.powerOn, .shutdown, .powerOff, .restart]
        return VirtualMachineControlState(id: id, name: name, status: status,
            availableActions: Set(actions.filter { (try? vmmPowerRoute($0)) != nil }),
            allowsDeletion: vmmCapability(capability.name, version: 1) != nil)
    }

    public func deleteVirtualMachineImagesResult(ids: [String]) async throws -> MutationResult {
        guard ids.allSatisfy({ !creationReferences("image", id: $0) }) else {
            throw verificationError(L10n.string("virtual-machine.creation.pending"))
        }
        let context = ServiceDeletionContext(operation: "virtualMachineImageDelete", localizationPrefix: "virtual-machine-image.delete")
        let api = vmmImageAPI
        return try await deleteVmmResources(ids: ids, api: api, arrayKey: "images",
            idKey: api == DsmAPIName.virtualizationAPIGuestImage ? "image_id" : "id", context: context)
    }

    private var vmmImageAPI: String {
        vmmCapability(DsmAPIName.virtualizationAPIGuestImage, version: 1) != nil
            ? DsmAPIName.virtualizationAPIGuestImage : DsmAPIName.virtualizationGuestImage
    }

    public func loadVirtualMachineImages() async throws -> VirtualMachineImageInventory {
        let api = vmmImageAPI, isInternal = api == DsmAPIName.virtualizationGuestImage
        guard let capability = vmmCapability(api, version: isInternal ? 2 : 1) else { throw unavailableError() }
        let snapshot = try await vmmDeletionSnapshot(capability: capability, arrayKey: "images", idKey: isInternal ? "id" : "image_id")
        if !snapshot.frozen {
            for (id, pending) in unverifiedVmmDeletions[api, default: [:]] where pending.accepted
                && activeDeletionIDsByOperation["virtualMachineImageDelete"]?.contains(id) != true && !snapshot.ids.contains(id) {
                unverifiedVmmDeletions[api]?[id] = nil
            }
        }
        return .init(source: isInternal ? .internalAPI : .official, isFrozen: snapshot.frozen,
                     images: snapshot.images.values.sorted { $0.id < $1.id })
    }

    public func deleteVirtualMachineImage(_ target: VirtualMachineImageState,
                                          observer: @escaping VirtualMachineControlObserver) async throws {
        guard !creationReferences("image", id: target.id) else {
            throw verificationError(L10n.string("virtual-machine.creation.pending"))
        }
        let api = vmmImageAPI
        guard target.source == (api == DsmAPIName.virtualizationGuestImage ? .internalAPI : .official) else { throw unavailableError() }
        let result = try await deleteVmmResources(ids: [target.id], api: api, arrayKey: "images",
            idKey: target.source == .official ? "image_id" : "id",
            context: .init(operation: "virtualMachineImageDelete", localizationPrefix: "virtual-machine-image.delete"),
            expectedImage: target, observer: observer)
        guard result.status == .confirmedSuccess else {
            throw AppError(category: result.errorCategory == .authentication ? .authenticationRequired
                : result.status == .permissionDenied ? .permissionDenied : result.submitted ? .partialFailure : .conflict,
                isRetryable: false, safeUserMessage: L10n.string(result.localizationKey ?? "virtual-machine-image.delete.unverified"))
        }
    }

    /// VM 与映像两种来源的删除逐项闭环；未知和未执行项分别计数，不自动重发。
    private func deleteVmmResources(ids: [String], api: String, arrayKey: String, idKey: String,
                                     context: ServiceDeletionContext, expected: VirtualMachineControlState? = nil,
                                     expectedImage: VirtualMachineImageState? = nil,
                                     observer: VirtualMachineControlObserver? = nil) async throws -> MutationResult {
        if Task.isCancelled { return try deletionCancellationBeforeSubmission(context: context) }
        guard !ids.isEmpty, ids.allSatisfy(Self.isVmmDeletionID) else {
            return try deletionUnexpectedPreflightResult(targetCount: max(1, ids.count), context: context)
        }
        let targets = Array(Set(ids)).sorted(), targetSet = Set(ids)
        let isGuest = api == DsmAPIName.virtualizationAPIGuest || api == DsmAPIName.virtualizationGuest
        let writeVersion = api == DsmAPIName.virtualizationGuestImage ? 2 : 1
        guard let capability = vmmCapability(api, version: writeVersion),
              api != DsmAPIName.virtualizationGuest || vmmCapability(api, version: 2) != nil else {
            return try deletionUnsupportedResult(targetCount: targets.count, context: context)
        }
        let active = activeDeletionIDsByOperation[context.operation] ?? []
        if isGuest && (targets.contains(where: networkProtectsGuest) || !activeVmmPowerIDs.isDisjoint(with: targetSet) || !activeVmmSettingsIDs.isDisjoint(with: targetSet)
            || targets.contains(where: { unverifiedVmmPower[$0] != nil || unverifiedVmmSettings[$0] != nil })) {
            return try deletionDuplicateResult(targetCount: targets.count, context: context)
        }
        guard active.isDisjoint(with: targetSet) else { return try deletionDuplicateResult(targetCount: targets.count, context: context) }
        activeDeletionIDsByOperation[context.operation] = active.union(targetSet)
        defer { activeDeletionIDsByOperation[context.operation]?.subtract(targetSet) }
        var succeeded = 0, submitted = false
        func summary(unknown: Int, category: MutationErrorCategory? = nil) throws -> MutationResult {
            let failed = targets.count - succeeded - unknown
            let status: MutationResultStatus = Task.isCancelled && submitted ? .cancellationRequestedAfterSubmission
                : succeeded == targets.count ? .confirmedSuccess : succeeded > 0 ? .partialSuccess
                : unknown > 0 ? .submittedButUnverified
                : category == .permission ? .permissionDenied : category == .unsupported ? .unsupported : .confirmedFailure
            return try serviceDeletionResult(status: status, context: context, submitted: submitted,
                requiresRefresh: submitted && status != .confirmedSuccess,
                succeeded: succeeded, failed: failed, unknown: unknown, errorCategory: category,
                localizationSuffix: category == .authentication ? "authentication" : status == .confirmedSuccess ? "completed"
                    : succeeded > 0 ? "partial" : unknown > 0 ? "unverified" : status == .permissionDenied ? "permission-denied"
                    : status == .unsupported ? "unsupported" : "failed",
                diagnosticSuffix: api == DsmAPIName.virtualizationGuestImage ? "internal-v2-image-batch"
                    : api == DsmAPIName.virtualizationGuest ? "internal-v1-batch" : "public-v1-batch")
        }
        let prior = Set(unverifiedVmmDeletions[api, default: [:]].keys).intersection(targetSet)
        submitted = !prior.isEmpty
        if (expected != nil || expectedImage != nil) && !prior.isEmpty {
            throw verificationError(L10n.string(isGuest ? "virtual-machine.delete.unverified" : "virtual-machine-image.delete.unverified"))
        }
        let initial: VmmDeletionSnapshot
        do { initial = try await vmmDeletionSnapshot(capability: capability, arrayKey: arrayKey, idKey: idKey) }
        catch let error as AppError {
            if Self.imageManagementTrustError(error) || [.authenticationRequired, .otpRequired].contains(error.category) { throw error }
            if !prior.isEmpty { return try summary(unknown: prior.count, category: serviceMutationErrorCategory(for: error.category)) }
            return try deletionPreflightResult(error, targetCount: targets.count, context: context)
        } catch {
            if Self.imageManagementTrustError(error) { throw error }
            if !prior.isEmpty { return try summary(unknown: prior.count, category: Task.isCancelled ? nil : .unknown) }
            if Task.isCancelled { return try deletionCancellationBeforeSubmission(context: context) }
            return try deletionUnexpectedPreflightResult(targetCount: targets.count, context: context)
        }
        if !prior.isEmpty {
            let resolved = prior.filter { !initial.frozen && !initial.ids.contains($0) && unverifiedVmmDeletions[api]?[$0]?.accepted == true }
            for id in resolved { unverifiedVmmDeletions[api]?[id] = nil }
            succeeded = resolved.count
            return try summary(unknown: prior.count - resolved.count)
        }
        guard targetSet.isSubset(of: initial.ids) else { return try deletionMissingTargetResult(targetCount: targets.count, context: context) }
        guard !initial.frozen, isGuest || targets.allSatisfy({ initial.images[$0]?.canDelete == true && !creationReferences("image", id: $0) }) else {
            return try summary(unknown: 0, category: .conflict)
        }
        if isGuest && !targets.allSatisfy({ id in
            guard let target = initial.guests[id] else { return false }
            return target.canDelete && !creationProtects(id: id, name: target.name)
        }) {
            return try summary(unknown: 0, category: .conflict)
        }
        if let expected, initial.guests[expected.id] != expected { return try summary(unknown: 0, category: .conflict) }
        if let expectedImage, initial.images[expectedImage.id] != expectedImage { return try summary(unknown: 0, category: .conflict) }
        var observed = initial
        for id in targets {
            if Task.isCancelled {
                if submitted { return try summary(unknown: 0) }
                return try deletionCancellationBeforeSubmission(context: context)
            }
            guard observed.ids.contains(id), !isGuest || (observed.guests[id] == initial.guests[id] && observed.guests[id]?.canDelete == true) else {
                return try summary(unknown: 0, category: .conflict)
            }
            guard !observed.frozen, isGuest || (observed.images[id] == initial.images[id] && observed.images[id]?.canDelete == true
                && !creationReferences("image", id: id)) else { return try summary(unknown: 0, category: .conflict) }
            try await observer?(.willSubmit)
            unverifiedVmmDeletions[api, default: [:]][id] = VmmDeletion()
            submitted = true
            var submissionError: AppError?, explicitlyRejected = false
            do {
                var parameters: [String: DsmParameterValue] = [idKey: .string(id)]
                if api == DsmAPIName.virtualizationGuestImage { parameters["synovmm_ui_id"] = .string(UUID().uuidString.lowercased()) }
                try await client.callVoid(path: capability.path, api: api, version: writeVersion, method: "delete",
                    requestFormat: capability.requestFormat, parameters: parameters, credential: credential)
                unverifiedVmmDeletions[api]?[id]?.accepted = true
            } catch let error as DsmNetworkError {
                let mapped = DsmErrorMapper.map(error)
                submissionError = mapped
                if case .api(let code, _) = error, code > 0 { explicitlyRejected = true }
                if case .invalidRequest = error { explicitlyRejected = true }
                if !explicitlyRejected && (Self.imageManagementTrustError(mapped)
                    || [.authenticationRequired, .otpRequired].contains(mapped.category)) { throw mapped }
            } catch let error as AppError {
                if Self.imageManagementTrustError(error) || [.authenticationRequired, .otpRequired].contains(error.category) { throw error }
                submissionError = error
            } catch {
                if Self.imageManagementTrustError(error) { throw error }
                return try summary(unknown: 1, category: Task.isCancelled ? nil : .unknown)
            }
            if let error = submissionError, explicitlyRejected {
                unverifiedVmmDeletions[api]?[id] = nil
                try await observer?(.rejected)
                if observer != nil || [.authenticationRequired, .otpRequired].contains(error.category) { throw error }
                return try summary(unknown: 0, category: serviceMutationErrorCategory(for: error.category))
            }
            if unverifiedVmmDeletions[api]?[id]?.accepted == true { try await observer?(.accepted) }
            if Task.isCancelled { return try summary(unknown: 1) }
            do {
                observed = try await vmmDeletionSnapshot(capability: capability, arrayKey: arrayKey, idKey: idKey)
            } catch let error as AppError {
                if Self.imageManagementTrustError(error) || [.authenticationRequired, .otpRequired].contains(error.category) { throw error }
                return try summary(unknown: 1, category: serviceMutationErrorCategory(for: submissionError?.category ?? error.category))
            } catch {
                if Self.imageManagementTrustError(error) { throw error }
                return try summary(unknown: 1, category: Task.isCancelled ? nil : .unknown)
            }
            guard !observed.frozen, !observed.ids.contains(id), unverifiedVmmDeletions[api]?[id]?.accepted == true else {
                return try summary(unknown: 1, category: submissionError.map { serviceMutationErrorCategory(for: $0.category) })
            }
            unverifiedVmmDeletions[api]?[id] = nil
            try await observer?(.verified)
            succeeded += 1
        }
        return try summary(unknown: 0)
    }

    private static func isVmmDeletionID(_ id: String) -> Bool {
        !id.isEmpty && id == id.trimmingCharacters(in: .whitespacesAndNewlines) && !id.contains(",") && !id.contains("\\") &&
            !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private struct VmmDeletionSnapshot {
        let ids: Set<String>
        let guests: [String: VirtualMachineControlState]
        var images: [String: VirtualMachineImageState] = [:]
        var frozen = false
    }

    private func vmmDeletionSnapshot(capability: ApiCapability, arrayKey: String, idKey: String) async throws -> VmmDeletionSnapshot {
        let value: ServiceJSON
        do {
            value = try await client.call(path: capability.path, api: capability.name,
                version: [DsmAPIName.virtualizationGuest, DsmAPIName.virtualizationGuestImage].contains(capability.name) ? 2 : 1, method: "list",
                requestFormat: capability.requestFormat, parameters: [:], credential: credential, as: ServiceJSON.self)
        } catch let error as DsmNetworkError { throw DsmErrorMapper.map(error) }
        try Task.checkCancellation()
        guard case .array(let items)? = value[arrayKey] else { throw invalidServiceResponse() }
        try Self.requireCompleteServiceList(value, count: items.count)
        if arrayKey == "images" { return try await vmmImageDeletionSnapshot(value, capability: capability) }
        var ids = Set<String>(), guests: [String: VirtualMachineControlState] = [:]
        for item in items {
            guard case .string(let id)? = item[idKey], Self.isVmmDeletionID(id), ids.insert(id).inserted else { throw invalidServiceResponse() }
            if idKey == "guest_id" { guests[id] = try vmmControlState(item, capability: capability) }
        }
        return VmmDeletionSnapshot(ids: ids, guests: guests)
    }

    private func vmmImageDeletionSnapshot(_ value: ServiceJSON, capability: ApiCapability) async throws -> VmmDeletionSnapshot {
        let internalAPI = capability.name == DsmAPIName.virtualizationGuestImage
        let frozen = internalAPI ? try creationBool(value, "is_freeze") : false
        let rows = try creationRows(value, "images")
        var images: [String: VirtualMachineImageState] = [:]
        func optionalText(_ row: ServiceJSON, _ key: String) throws -> String? {
            guard row[key] != nil else { return nil }
            return try creationText(row, key)
        }
        for row in rows {
            let id = try creationText(row, internalAPI ? "id" : "image_id")
            guard Self.isVmmDeletionID(id) else { throw invalidServiceResponse() }
            if internalAPI {
                let name = try creationText(row, "name"), type = try creationText(row, "type")
                let copy = VirtualMachineImageState.Copy(storageID: try creationText(row, "repo_id"), hostID: try creationText(row, "host_id"),
                    status: try creationText(row, "status"), statusType: try creationText(row, "status_type"))
                let prior = images[id]
                guard prior == nil || (prior?.name == name && prior?.type == type
                    && prior?.copies.contains(where: { $0.storageID == copy.storageID && $0.hostID == copy.hostID }) == false) else {
                    throw invalidServiceResponse()
                }
                images[id] = .init(id: id, name: name, type: type, source: .internalAPI, copies: (prior?.copies ?? []) + [copy])
            } else {
                guard images[id] == nil else { throw invalidServiceResponse() }
                images[id] = .init(id: id, name: try optionalText(row, "image_name"), type: try optionalText(row, "type"), source: .official)
            }
        }
        // 内部 ISO 的挂载关系来自已记录 get_setting.iso_images；停止的 VM 同样占用。
        // 公开映像接口没有该字段，不从名称猜占用；NAS 明确拒绝仍作为删除失败。
        if internalAPI, !frozen, images.values.contains(where: { $0.type == "iso" }) {
            guard vmmCapability(DsmAPIName.virtualizationGuest, version: 2) != nil,
                  vmmCapability(DsmAPIName.virtualizationGuest, version: 1) != nil else { throw unavailableError() }
            let guests = try await call(DsmAPIName.virtualizationGuest, method: "list", fixedVersion: 2)
            let guestIDs = try creationRows(guests, "guests").map { try creationText($0, "guest_id") }
            guard Set(guestIDs).count == guestIDs.count else { throw invalidServiceResponse() }
            var used = Set<String>()
            for guestID in guestIDs {
                try Task.checkCancellation()
                let setting = try await call(DsmAPIName.virtualizationGuest, method: "get_setting",
                    parameters: ["guest_id": .string(guestID)], fixedVersion: 1)
                guard case .array(let slots)? = setting["iso_images"] else { throw invalidServiceResponse() }
                for slot in slots {
                    guard case .string(let id) = slot, Self.isVmmDeletionID(id) else { throw invalidServiceResponse() }
                    if id != "unmounted" { used.insert(id) }
                }
            }
            for (id, image) in images where image.type == "iso" {
                images[id] = .init(id: id, name: image.name, type: image.type, source: image.source,
                    copies: image.copies, isInUse: used.contains(id))
            }
        }
        try Task.checkCancellation()
        return .init(ids: Set(images.keys), guests: [:], images: images, frozen: frozen)
    }

    private struct ServiceDeletionContext {
        let operation: String
        let localizationPrefix: String
    }

    private func performServiceDeletion(
        ids: [String],
        context: ServiceDeletionContext,
        isSupported: Bool,
        loadCurrentIDs: () async throws -> Set<String>,
        submit: ([String]) async throws -> Void
    ) async throws -> MutationResult {
        if Task.isCancelled {
            return try deletionCancellationBeforeSubmission(context: context)
        }

        let targets: [String]
        do {
            targets = try validatedIDs(ids)
        } catch let error as AppError {
            return try deletionPreflightResult(
                error,
                targetCount: max(ids.count, 1),
                context: context
            )
        } catch {
            return try deletionUnexpectedPreflightResult(
                targetCount: max(ids.count, 1),
                context: context
            )
        }
        guard isSupported else {
            return try deletionUnsupportedResult(
                targetCount: targets.count,
                context: context
            )
        }

        let targetSet = Set(targets)
        let activeTargets = activeDeletionIDsByOperation[context.operation] ?? []
        guard activeTargets.isDisjoint(with: targetSet) else {
            return try deletionDuplicateResult(
                targetCount: targets.count,
                context: context
            )
        }
        activeDeletionIDsByOperation[context.operation] = activeTargets.union(targetSet)
        defer {
            let remaining = (activeDeletionIDsByOperation[context.operation] ?? [])
                .subtracting(targetSet)
            if remaining.isEmpty {
                activeDeletionIDsByOperation.removeValue(forKey: context.operation)
            } else {
                activeDeletionIDsByOperation[context.operation] = remaining
            }
        }

        do {
            let currentIDs = try await loadCurrentIDs()
            guard targetSet.isSubset(of: currentIDs) else {
                return try deletionMissingTargetResult(
                    targetCount: targets.count,
                    context: context
                )
            }
        } catch let error as AppError {
            return try deletionPreflightResult(
                error,
                targetCount: targets.count,
                context: context
            )
        } catch {
            return try deletionUnexpectedPreflightResult(
                targetCount: targets.count,
                context: context
            )
        }

        if Task.isCancelled {
            return try deletionCancellationBeforeSubmission(context: context)
        }
        do {
            try await submit(targets)
        } catch let error as AppError {
            if let reconciled = try await reconciledDeletionAfterSubmissionFailure(
                targets: targetSet,
                context: context,
                loadCurrentIDs: loadCurrentIDs
            ) {
                return reconciled
            }
            return try deletionSubmissionResult(
                error,
                targetCount: targets.count,
                context: context
            )
        } catch {
            if let reconciled = try await reconciledDeletionAfterSubmissionFailure(
                targets: targetSet,
                context: context,
                loadCurrentIDs: loadCurrentIDs
            ) {
                return reconciled
            }
            return try deletionUnexpectedSubmissionResult(
                targetCount: targets.count,
                context: context
            )
        }

        if Task.isCancelled {
            return try deletionCancellationAfterSubmission(
                targetCount: targets.count,
                context: context
            )
        }
        do {
            return try deletionReadbackResult(
                targets: targetSet,
                remaining: try await loadCurrentIDs(),
                context: context
            )
        } catch let error as AppError {
            return try deletionReadbackFailureResult(
                error,
                targetCount: targets.count,
                context: context
            )
        } catch {
            return try deletionUnexpectedReadbackResult(
                targetCount: targets.count,
                context: context
            )
        }
    }

    private func reconciledDeletionAfterSubmissionFailure(
        targets: Set<String>,
        context: ServiceDeletionContext,
        loadCurrentIDs: () async throws -> Set<String>
    ) async throws -> MutationResult? {
        guard let remaining = try? await loadCurrentIDs() else {
            return nil
        }
        let result = try deletionReadbackResult(
            targets: targets,
            remaining: remaining,
            context: context
        )
        switch result.status {
        case .confirmedSuccess, .partialSuccess:
            return result
        default:
            return nil
        }
    }

    private func deletionCancellationBeforeSubmission(
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        try serviceDeletionResult(
            status: .cancelledBeforeSubmission,
            context: context,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: 0,
            unknown: 0,
            localizationSuffix: "cancelled",
            diagnosticSuffix: "cancelled-before-submission"
        )
    }

    private func deletionCancellationAfterSubmission(
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        try serviceDeletionResult(
            status: .cancellationRequestedAfterSubmission,
            context: context,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: targetCount,
            localizationSuffix: "unverified",
            diagnosticSuffix: "cancelled-after-submission"
        )
    }

    private func deletionUnsupportedResult(
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        try serviceDeletionResult(
            status: .unsupported,
            context: context,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: targetCount,
            unknown: 0,
            errorCategory: .unsupported,
            localizationSuffix: "unsupported",
            diagnosticSuffix: "unsupported"
        )
    }

    private func deletionDuplicateResult(
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        try serviceDeletionResult(
            status: .confirmedFailure,
            context: context,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: targetCount,
            unknown: 0,
            errorCategory: .conflict,
            localizationSuffix: "failed",
            diagnosticSuffix: "duplicate-submission"
        )
    }

    private func deletionMissingTargetResult(
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        try serviceDeletionResult(
            status: .confirmedFailure,
            context: context,
            submitted: false,
            requiresRefresh: true,
            succeeded: 0,
            failed: targetCount,
            unknown: 0,
            errorCategory: .validation,
            localizationSuffix: "failed",
            diagnosticSuffix: "target-not-found"
        )
    }

    private func deletionPreflightResult(
        _ error: AppError,
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try deletionCancellationBeforeSubmission(context: context)
        case .permissionDenied, .authenticationRequired:
            return try serviceDeletionResult(
                status: .permissionDenied,
                context: context,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: targetCount,
                unknown: 0,
                errorCategory: .permission,
                localizationSuffix: "permission-denied",
                diagnosticSuffix: "preflight-permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try deletionUnsupportedResult(
                targetCount: targetCount,
                context: context
            )
        default:
            return try serviceDeletionResult(
                status: .confirmedFailure,
                context: context,
                submitted: false,
                requiresRefresh: false,
                succeeded: 0,
                failed: targetCount,
                unknown: 0,
                errorCategory: serviceMutationErrorCategory(for: error.category),
                localizationSuffix: "failed",
                diagnosticSuffix: "preflight-failed"
            )
        }
    }

    private func deletionUnexpectedPreflightResult(
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        try serviceDeletionResult(
            status: .confirmedFailure,
            context: context,
            submitted: false,
            requiresRefresh: false,
            succeeded: 0,
            failed: targetCount,
            unknown: 0,
            errorCategory: .unknown,
            localizationSuffix: "failed",
            diagnosticSuffix: "preflight-unknown"
        )
    }

    private func deletionSubmissionResult(
        _ error: AppError,
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        switch error.category {
        case .cancelled:
            return try deletionCancellationAfterSubmission(
                targetCount: targetCount,
                context: context
            )
        case .permissionDenied, .authenticationRequired:
            return try serviceDeletionResult(
                status: .permissionDenied,
                context: context,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: targetCount,
                unknown: 0,
                errorCategory: .permission,
                localizationSuffix: "permission-denied",
                diagnosticSuffix: "permission-denied"
            )
        case .apiUnavailable, .versionUnsupported:
            return try serviceDeletionResult(
                status: .unsupported,
                context: context,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: targetCount,
                unknown: 0,
                errorCategory: .unsupported,
                localizationSuffix: "unsupported",
                diagnosticSuffix: "unsupported-response"
            )
        case .networkUnavailable, .timeout, .serverBusy, .invalidResponse, .unknown:
            return try serviceDeletionResult(
                status: .submittedButUnverified,
                context: context,
                submitted: true,
                requiresRefresh: true,
                succeeded: 0,
                failed: 0,
                unknown: targetCount,
                errorCategory: serviceMutationErrorCategory(for: error.category),
                localizationSuffix: "unverified",
                diagnosticSuffix: "submitted-unverified"
            )
        default:
            return try serviceDeletionResult(
                status: .confirmedFailure,
                context: context,
                submitted: true,
                requiresRefresh: false,
                succeeded: 0,
                failed: targetCount,
                unknown: 0,
                errorCategory: serviceMutationErrorCategory(for: error.category),
                localizationSuffix: "failed",
                diagnosticSuffix: "rejected"
            )
        }
    }

    private func deletionUnexpectedSubmissionResult(
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        try serviceDeletionResult(
            status: .submittedButUnverified,
            context: context,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: targetCount,
            errorCategory: .unknown,
            localizationSuffix: "unverified",
            diagnosticSuffix: "submission-unknown"
        )
    }

    private func deletionReadbackResult(
        targets: Set<String>,
        remaining: Set<String>,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        let remainingTargets = targets.intersection(remaining)
        let succeeded = targets.count - remainingTargets.count
        if remainingTargets.isEmpty {
            return try serviceDeletionResult(
                status: .confirmedSuccess,
                context: context,
                submitted: true,
                requiresRefresh: false,
                succeeded: succeeded,
                failed: 0,
                unknown: 0,
                localizationSuffix: "completed",
                diagnosticSuffix: "confirmed"
            )
        }
        if succeeded > 0 {
            return try serviceDeletionResult(
                status: .partialSuccess,
                context: context,
                submitted: true,
                requiresRefresh: true,
                succeeded: succeeded,
                failed: 0,
                unknown: remainingTargets.count,
                localizationSuffix: "partial",
                diagnosticSuffix: "partially-confirmed"
            )
        }
        return try serviceDeletionResult(
            status: .submittedButUnverified,
            context: context,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: targets.count,
            localizationSuffix: "unverified",
            diagnosticSuffix: "still-listed"
        )
    }

    private func deletionReadbackFailureResult(
        _ error: AppError,
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        if error.category == .cancelled {
            return try deletionCancellationAfterSubmission(
                targetCount: targetCount,
                context: context
            )
        }
        return try serviceDeletionResult(
            status: .submittedButUnverified,
            context: context,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: targetCount,
            errorCategory: serviceMutationErrorCategory(for: error.category),
            localizationSuffix: "unverified",
            diagnosticSuffix: "readback-unverified"
        )
    }

    private func deletionUnexpectedReadbackResult(
        targetCount: Int,
        context: ServiceDeletionContext
    ) throws -> MutationResult {
        try serviceDeletionResult(
            status: .submittedButUnverified,
            context: context,
            submitted: true,
            requiresRefresh: true,
            succeeded: 0,
            failed: 0,
            unknown: targetCount,
            errorCategory: .unknown,
            localizationSuffix: "unverified",
            diagnosticSuffix: "readback-unknown"
        )
    }

    private func serviceDeletionResult(
        status: MutationResultStatus,
        context: ServiceDeletionContext,
        submitted: Bool,
        requiresRefresh: Bool,
        succeeded: Int,
        failed: Int,
        unknown: Int,
        errorCategory: MutationErrorCategory? = nil,
        localizationSuffix: String,
        diagnosticSuffix: String
    ) throws -> MutationResult {
        try MutationResult(
            status: status,
            operation: context.operation,
            submitted: submitted,
            requiresRefresh: requiresRefresh,
            counts: MutationResultCounts(
                succeeded: succeeded,
                failed: failed,
                unknown: unknown
            ),
            errorCategory: errorCategory,
            localizationKey: "\(context.localizationPrefix).\(localizationSuffix)",
            diagnosticTag: "\(context.localizationPrefix).\(diagnosticSuffix)"
        )
    }

    private func serviceMutationErrorCategory(
        for category: AppErrorCategory
    ) -> MutationErrorCategory {
        switch category {
        case .networkUnavailable, .timeout:
            .network
        case .authenticationRequired, .otpRequired:
            .authentication
        case .permissionDenied:
            .permission
        case .conflict, .notFound, .serverBusy:
            .conflict
        case .apiUnavailable, .versionUnsupported:
            .unsupported
        case .invalidResponse:
            .server
        default:
            .unknown
        }
    }


    private func ensureNoDownloadEdit(_ ids: [String]) throws {
        guard ids.allSatisfy({ !activeDownloadEdits.contains($0) && pendingDownloadEdits[$0] == nil
            && !activeDownloadRemovals.contains($0) && pendingDownloadRemovals[$0] == nil }) else {
            throw validationError(L10n.string("download.edit.pending-help"))
        }
    }

    private func preferredDownloadTaskAPI() -> String {
        capabilities[DsmAPIName.downloadStationTask]?.selectedVersion != nil
            ? DsmAPIName.downloadStationTask
            : DsmAPIName.downloadStation2Task
    }

    private nonisolated func officialDownloadTaskV1Capability() -> ApiCapability? {
        guard let capability = capabilities[DsmAPIName.downloadStationTask],
              capability.selectedVersion != nil,
              capability.minVersion <= 1,
              capability.maxVersion >= 1,
              capability.requestFormat == .form else {
            return nil
        }
        return capability
    }

    private func callOfficialDownloadTask(
        method: String,
        parameters: [String: DsmParameterValue],
        version: Int = 1
    ) async throws -> ServiceJSON {
        guard let capability = capabilities[DsmAPIName.downloadStationTask],
              capability.selectedVersion != nil, capability.minVersion <= version,
              capability.maxVersion >= version, capability.requestFormat == .form else {
            throw unavailableError()
        }
        do {
            return try await client.call(
                path: capability.path,
                api: capability.name,
                version: version,
                method: method,
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential,
                as: ServiceJSON.self,
                emptySuccessPayload: method == "create" ? .object([:]) : nil
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private func callOfficialDownloadTaskFileCreate(
        fileURL: URL,
        destination: String?,
        unzipPassword: String?
    ) async throws -> ServiceJSON {
        let requiredVersion = destination?.isEmpty != false ? 1 : 2
        guard let capability = capabilities[DsmAPIName.downloadStationTask],
              capability.selectedVersion != nil,
              capability.minVersion <= requiredVersion, capability.maxVersion >= requiredVersion,
              capability.requestFormat == .form,
              let binaryTransport = transport as? any DsmBinaryHTTPTransport else {
            throw unavailableError()
        }

        let accessed = fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let boundary = "LanStashDownload-\(UUID().uuidString)"
        var multipartFields: [String: String] = [:]
        if let destination, !destination.isEmpty {
            multipartFields["destination"] = destination
        }
        if let unzipPassword, !unzipPassword.isEmpty {
            multipartFields["unzip_password"] = unzipPassword
        }
        let bodyURL = try createDownloadMultipartBody(
            localURL: fileURL,
            boundary: boundary,
            fields: multipartFields
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var endpoint = apiURL(path: capability.path)
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw validationError(L10n.string("shared.6a5dbf096a38ba4f"))
        }
        components.queryItems = [
            URLQueryItem(name: "api", value: capability.name),
            URLQueryItem(name: "version", value: String(requiredVersion)),
            URLQueryItem(name: "method", value: "create")
        ]
        guard let resolvedEndpoint = components.url else {
            throw validationError(L10n.string("shared.6a5dbf096a38ba4f"))
        }
        endpoint = resolvedEndpoint

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        if let cookie = credential.cookieHeaderValue {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
        if let synoToken = credential.synoToken, !synoToken.isEmpty {
            request.setValue(synoToken, forHTTPHeaderField: "X-SYNO-TOKEN")
        }
        let bodySize = try bodyURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        request.setValue(String(bodySize), forHTTPHeaderField: "Content-Length")

        let response: DsmHTTPResponse
        do {
            response = try await binaryTransport.upload(request, from: bodyURL) { _, _ in }
        } catch is DsmTransportError {
            throw DsmErrorMapper.map(.responseTooLarge(requestID: UUID()))
        }
        guard (200..<300).contains(response.statusCode) else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.847fe982ab6f5ef7")
            )
        }
        let envelope: ServiceJSON
        do {
            envelope = try JSONDecoder().decode(ServiceJSON.self, from: response.data)
        } catch {
            throw AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.847fe982ab6f5ef7")
            )
        }
        if let code = envelope["error"]?.firstInteger(["code"]) {
            throw DsmErrorMapper.map(.api(code: Int(code), requestID: UUID()))
        }
        guard case .boolean(true)? = envelope["success"] else {
            throw AppError(
                category: .invalidResponse,
                isRetryable: true,
                safeUserMessage: L10n.string("shared.847fe982ab6f5ef7")
            )
        }
        return envelope["data"] ?? .object([:])
    }

    private func callOfficialDownloadTaskV1Void(
        method: String,
        parameters: [String: DsmParameterValue]
    ) async throws {
        guard let capability = officialDownloadTaskV1Capability() else {
            throw unavailableError()
        }
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: 1,
                method: method,
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private static func validatedDownloadCreateRequest(
        _ request: DownloadTaskCreateRequest
    ) throws -> DownloadTaskCreateValidation {
        let normalizedURI = request.uri.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedDestination = request.destination.flatMap { $0.isEmpty ? nil : $0 }
        guard let url = URL(string: normalizedURI),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "magnet"].contains(scheme),
              !normalizedURI.isEmpty,
              !normalizedURI.contains(where: \.isNewline),
              !normalizedURI.contains("\0"),
              (scheme == "magnet" || url.host?.isEmpty == false),
              normalizedDestination?.contains(where: \.isNewline) != true,
              normalizedDestination?.contains("\0") != true else {
            return .failure(try downloadCreateOutcome(
                status: .confirmedFailure,
                taskID: nil,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .validation,
                tag: "download-task.create.invalid"
            ))
        }
        return .success(PreparedDownloadTaskCreateRequest(
            identity: DownloadTaskCreationIdentity(
                sourceDigest: Self.downloadCreateDigest(kind: "uri", values: [normalizedURI]),
                requestDigest: Self.downloadCreateDigest(kind: "uri", values: [normalizedURI, normalizedDestination ?? ""])
            ),
            source: .uri(normalizedURI),
            destination: normalizedDestination
        ))
    }

    private static func validatedDownloadFileCreateRequest(
        _ request: DownloadTaskFileCreateRequest
    ) throws -> DownloadTaskCreateValidation {
        let normalizedURL = request.fileURL.standardizedFileURL
        // 目录名和解压密码中的空格属于原值，只有空字符串表示不提供。
        let normalizedDestination = request.destination.flatMap { $0.isEmpty ? nil : $0 }
        let normalizedPassword = request.unzipPassword.flatMap { $0.isEmpty ? nil : $0 }
        let allowedExtensions = ["torrent", "nzb", "txt"]
        guard normalizedURL.isFileURL,
              allowedExtensions.contains(normalizedURL.pathExtension.lowercased()),
              normalizedDestination?.contains(where: \.isNewline) != true,
              normalizedDestination?.contains("\0") != true,
              normalizedPassword?.contains(where: \.isNewline) != true,
              normalizedPassword?.contains("\0") != true else {
            return .failure(try downloadCreateOutcome(
                status: .confirmedFailure,
                taskID: nil,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .validation,
                tag: "download-task.create.invalid-file"
            ))
        }

        let accessed = normalizedURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                normalizedURL.stopAccessingSecurityScopedResource()
            }
        }
        do {
            let values = try normalizedURL.resourceValues(
                forKeys: [.isRegularFileKey, .isReadableKey, .fileSizeKey]
            )
            guard values.isRegularFile == true,
                  values.isReadable != false,
                  (values.fileSize ?? 0) <= 100 * 1_024 * 1_024 else {
                return .failure(try downloadCreateOutcome(
                    status: .confirmedFailure,
                    taskID: nil,
                    task: nil,
                    submitted: false,
                    requiresRefresh: false,
                    counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                    errorCategory: .validation,
                    tag: "download-task.create.invalid-file"
                ))
            }
            let file = try FileHandle(forReadingFrom: normalizedURL)
            defer { try? file.close() }
            var content = SHA256()
            while let bytes = try file.read(upToCount: 1_048_576), !bytes.isEmpty { content.update(data: bytes) }
            let contentDigest = content.finalize().map { String(format: "%02x", $0) }.joined()
            return .success(PreparedDownloadTaskCreateRequest(
                identity: DownloadTaskCreationIdentity(
                    sourceDigest: Self.downloadCreateDigest(kind: "file", values: [contentDigest]),
                    requestDigest: Self.downloadCreateDigest(kind: "file", values: [contentDigest, normalizedDestination ?? "", normalizedPassword ?? ""])
                ),
                source: .file(normalizedURL, unzipPassword: normalizedPassword),
                destination: normalizedDestination
            ))
        } catch {
            return .failure(try downloadCreateOutcome(
                status: .confirmedFailure,
                taskID: nil,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .validation,
                tag: "download-task.create.invalid-file"
            ))
        }
    }

    private func performDownloadTaskCreate(
        _ request: PreparedDownloadTaskCreateRequest,
        willSubmit: (@Sendable (DownloadTaskCreationIdentity) async throws -> Void)? = nil,
        didAccept: (@Sendable () async throws -> Void)? = nil
    ) async throws -> DownloadTaskCreateOutcome {
        let requiredVersion: Int
        switch request.source {
        case .uri: requiredVersion = 3
        case .file: requiredVersion = request.destination == nil ? 1 : 2
        }
        let hasTransport: Bool
        switch request.source { case .uri: hasTransport = true; case .file: hasTransport = transport is any DsmBinaryHTTPTransport }
        guard let capability = officialDownloadTaskV1Capability(), capability.maxVersion >= requiredVersion, hasTransport else {
            return try Self.downloadCreateOutcome(
                status: .unsupported,
                taskID: nil,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .unsupported,
                tag: "download-task.create.unsupported"
            )
        }
        if Task.isCancelled {
            return try Self.downloadCreateOutcome(
                status: .cancelledBeforeSubmission,
                taskID: nil,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 0),
                errorCategory: nil,
                tag: "download-task.create.cancelled-before"
            )
        }
        if let review = pendingDownloadCreateReviews[request.key] {
            return try await finishDownloadCreateReview(
                review,
                statusIfUnconfirmed: .submittedButUnverified
            )
        }
        guard !activeDownloadCreateKeys.contains(request.key) else {
            return try Self.downloadCreateOutcome(
                status: .confirmedFailure,
                taskID: nil,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .conflict,
                tag: "download-task.create.duplicate"
            )
        }
        activeDownloadCreateKeys.insert(request.key)
        defer {
            activeDownloadCreateKeys.remove(request.key)
        }

        let previousIDs: Set<String>
        do {
            previousIDs = Set(try await loadAllOfficialDownloadTasks().map(\.id))
        } catch let error as AppError where error.category == .cancelled {
            return try Self.downloadCreateOutcome(
                status: .cancelledBeforeSubmission,
                taskID: nil,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 0),
                errorCategory: nil,
                tag: "download-task.create.cancelled-before"
            )
        } catch {
            return try Self.downloadCreateOutcome(
                status: .confirmedFailure,
                taskID: nil,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: Self.downloadCreateErrorCategory(error),
                tag: "download-task.create.preflight"
            )
        }
        if Task.isCancelled {
            return try Self.downloadCreateOutcome(
                status: .cancelledBeforeSubmission,
                taskID: nil,
                task: nil,
                submitted: false,
                requiresRefresh: false,
                counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 0),
                errorCategory: nil,
                tag: "download-task.create.cancelled-before"
            )
        }

        try await willSubmit?(request.identity)
        if Task.isCancelled {
            return try Self.downloadCreateOutcome(status: .cancelledBeforeSubmission, taskID: nil, task: nil,
                submitted: false, requiresRefresh: false, counts: .init(succeeded: 0, failed: 0, unknown: 0),
                errorCategory: nil, tag: "download-task.create.cancelled-before")
        }
        let response: ServiceJSON
        do {
            response = try await submitDownloadTaskCreate(request)
        } catch let error as AppError where error.category == .permissionDenied || error.dsmCode == 402 {
            return try Self.downloadCreateOutcome(
                status: .permissionDenied,
                taskID: nil,
                task: nil,
                submitted: true,
                requiresRefresh: true,
                counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: .permission,
                tag: "download-task.create.permission"
            )
        } catch let error as AppError where error.dsmCode.map({ [101, 102, 103, 104, 106, 107, 400, 401, 403, 404, 405, 406, 407, 408].contains($0) }) == true {
            return try Self.downloadCreateOutcome(status: .confirmedFailure, taskID: nil, task: nil,
                submitted: true, requiresRefresh: false, counts: .init(succeeded: 0, failed: 1, unknown: 0),
                errorCategory: Self.downloadCreateErrorCategory(error), tag: "download-task.create.rejected")
        } catch let error as AppError where error.category == .cancelled {
            let review = DownloadTaskCreateReview(
                key: request.key,
                previousTaskIDs: previousIDs,
                expectedTaskID: nil,
                destination: request.destination
            )
            pendingDownloadCreateReviews[request.key] = review
            return try await finishDownloadCreateReview(
                review,
                statusIfUnconfirmed: .cancellationRequestedAfterSubmission
            )
        } catch {
            let review = DownloadTaskCreateReview(
                key: request.key,
                previousTaskIDs: previousIDs,
                expectedTaskID: nil,
                destination: request.destination
            )
            pendingDownloadCreateReviews[request.key] = review
            return try await finishDownloadCreateReview(
                review,
                statusIfUnconfirmed: .submittedButUnverified
            )
        }

        let expectedID = Self.downloadCreateTaskID(from: response)
        if let didAccept {
            // 先保留在内存中，回执落盘失败时不能让同一请求重发。
            pendingDownloadCreateReviews[request.key] = .init(key: request.key,
                previousTaskIDs: previousIDs, expectedTaskID: nil, destination: request.destination)
            try await didAccept()
            pendingDownloadCreateReviews[request.key] = nil
            return try Self.downloadCreateOutcome(status: .confirmedSuccess, taskID: expectedID, task: nil,
                submitted: true, requiresRefresh: true, counts: .init(succeeded: 1, failed: 0, unknown: 0),
                errorCategory: nil, tag: "download-task.create.accepted", requestAccepted: true)
        }
        let review = DownloadTaskCreateReview(
            key: request.key,
            previousTaskIDs: previousIDs,
            expectedTaskID: expectedID,
            destination: request.destination
        )
        pendingDownloadCreateReviews[request.key] = review
        return try await finishDownloadCreateReview(
            review,
            statusIfUnconfirmed: .submittedButUnverified
        )
    }

    private func submitDownloadTaskCreate(
        _ request: PreparedDownloadTaskCreateRequest
    ) async throws -> ServiceJSON {
        switch request.source {
        case .uri(let uri):
            var parameters: [String: DsmParameterValue] = ["uri": .string(uri)]
            if let destination = request.destination {
                parameters["destination"] = .string(destination)
            }
            return try await callOfficialDownloadTask(
                method: "create",
                parameters: parameters,
                version: 3
            )
        case .file(let fileURL, let unzipPassword):
            return try await callOfficialDownloadTaskFileCreate(
                fileURL: fileURL,
                destination: request.destination,
                unzipPassword: unzipPassword
            )
        }
    }

    private func finishDownloadCreateReview(
        _ review: DownloadTaskCreateReview,
        statusIfUnconfirmed: MutationResultStatus
    ) async throws -> DownloadTaskCreateOutcome {
        guard let expectedTaskID = review.expectedTaskID else {
            pendingDownloadCreateReviews[review.key] = review
            return try Self.downloadCreateUnknownOutcome(
                status: statusIfUnconfirmed,
                taskID: nil,
                category: .unknown
            )
        }
        do {
            let tasks = try await loadAllOfficialDownloadTasks()
            if let task = tasks.first(where: {
                $0.id == expectedTaskID &&
                    !review.previousTaskIDs.contains($0.id) &&
                    Self.downloadCreateDestinationMatches(
                        expected: review.destination,
                        task: $0
                    )
            }) {
                pendingDownloadCreateReviews[review.key] = nil
                return try Self.downloadCreateOutcome(
                    status: .confirmedSuccess,
                    taskID: expectedTaskID,
                    task: task,
                    submitted: true,
                    requiresRefresh: false,
                    counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0),
                    errorCategory: nil,
                    tag: "download-task.create.confirmed"
                )
            }
        } catch {
            pendingDownloadCreateReviews[review.key] = review
            return try Self.downloadCreateUnknownOutcome(
                status: statusIfUnconfirmed,
                taskID: expectedTaskID,
                category: Self.downloadCreateErrorCategory(error)
            )
        }

        pendingDownloadCreateReviews[review.key] = review
        return try Self.downloadCreateUnknownOutcome(
            status: statusIfUnconfirmed,
            taskID: expectedTaskID,
            category: .unknown
        )
    }

    private func loadAllOfficialDownloadTasks() async throws -> [DownloadStationTask] {
        var offset = 0
        var expectedTotal: Int?
        var tasks: [DownloadStationTask] = []
        var seenIDs: Set<String> = []

        while true {
            try Task.checkCancellation()
            let limit = Self.downloadControlPageSize
            let value = try await callOfficialDownloadTask(
                method: "list",
                parameters: [
                    "offset": .integer(offset),
                    "limit": .integer(limit),
                    "additional": .string("detail,transfer")
                ]
            )
            let objects = try Self.strictRootObjects(value, keys: ["tasks"])
            let pageTasks = objects.compactMap(Self.officialDownloadTask)
            guard pageTasks.count == objects.count, pageTasks.count <= limit else {
                throw invalidServiceResponse()
            }
            if value["offset"] != nil {
                guard Self.downloadNumber(value, keys: ["offset"]) == Int64(offset) else {
                    throw invalidServiceResponse()
                }
            }
            if value["total"] != nil {
                guard let totalValue = Self.downloadNumber(value, keys: ["total"]),
                      let total = Int(exactly: totalValue) else { throw invalidServiceResponse() }
                guard total >= offset + pageTasks.count else {
                    throw invalidServiceResponse()
                }
                if let expectedTotal {
                    guard expectedTotal == total else {
                        throw invalidServiceResponse()
                    }
                } else {
                    expectedTotal = total
                }
            }
            for task in pageTasks {
                guard seenIDs.insert(task.id).inserted else {
                    throw invalidServiceResponse()
                }
                tasks.append(task)
            }
            offset += pageTasks.count
            if let expectedTotal {
                if offset == expectedTotal { return tasks }
                // 服务端可返回小于 limit 的非末页；总量未读完时必须继续。
                guard !pageTasks.isEmpty else { throw invalidServiceResponse() }
            } else if pageTasks.count < limit {
                return tasks
            }
        }
    }

    private static func downloadCreateDestinationMatches(
        expected: String?,
        task: DownloadStationTask
    ) -> Bool {
        guard let expected else {
            return true
        }
        guard let destination = Self.nonEmpty(task.destination) else {
            return true
        }
        return destination == expected
    }

    private static func downloadCreateTaskID(from value: ServiceJSON) -> String? {
        for key in ["taskid", "task_id", "taskId", "id"] {
            guard case .string(let raw)? = value[key] else {
                continue
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, !trimmed.contains(where: \.isNewline), !trimmed.contains("\0") {
                return trimmed
            }
        }
        return nil
    }

    private static func downloadCreateDigest(kind: String, values: [String]) -> String {
        var data = Data(kind.utf8)
        for value in values {
            let bytes = Data(value.utf8)
            var count = UInt32(bytes.count).bigEndian
            data.append(Data(bytes: &count, count: MemoryLayout<UInt32>.size))
            data.append(bytes)
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func downloadCreateErrorCategory(_ error: Error) -> MutationErrorCategory {
        if let appError = error as? AppError {
            switch appError.category {
            case .networkUnavailable, .timeout:
                return .network
            case .authenticationRequired, .otpRequired:
                return .authentication
            case .permissionDenied:
                return .permission
            case .apiUnavailable, .versionUnsupported:
                return .unsupported
            case .conflict, .notFound, .serverBusy:
                return .conflict
            case .invalidResponse:
                return .server
            default:
                return .unknown
            }
        }
        return .unknown
    }

    private static func downloadCreateUnknownOutcome(
        status: MutationResultStatus,
        taskID: String?,
        category: MutationErrorCategory
    ) throws -> DownloadTaskCreateOutcome {
        try downloadCreateOutcome(
            status: status,
            taskID: taskID,
            task: nil,
            submitted: true,
            requiresRefresh: true,
            counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 1),
            errorCategory: category,
            tag: status == .cancellationRequestedAfterSubmission
                ? "download-task.create.cancelled-after"
                : "download-task.create.unverified"
        )
    }

    private static func downloadCreateOutcome(
        status: MutationResultStatus,
        taskID: String?,
        task: DownloadStationTask?,
        submitted: Bool,
        requiresRefresh: Bool,
        counts: MutationResultCounts,
        errorCategory: MutationErrorCategory?,
        tag: String,
        requestAccepted: Bool = false
    ) throws -> DownloadTaskCreateOutcome {
        try DownloadTaskCreateOutcome(
            result: MutationResult(
                status: status,
                operation: "downloadCreate",
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                counts: counts,
                errorCategory: errorCategory,
                localizationKey: tag,
                diagnosticTag: tag
            ),
            taskID: taskID,
            task: task,
            requestAccepted: requestAccepted
        )
    }

    private func loadOfficialDownloadControlTask(id taskID: String) async throws -> DownloadStationTask? {
        try await loadAllOfficialDownloadTasks().first { $0.id == taskID }
    }

    private func finishDownloadControlReview(
        key: DownloadTaskControlKey,
        action: DownloadStationTaskAction,
        statusIfUnconfirmed: MutationResultStatus
    ) async throws -> DownloadTaskControlOutcome {
        do {
            // 写入可能已完成；提交后的取消不撤销只读结果查询。
            let current: DownloadStationTask?
            if Task.isCancelled {
                current = try await Task.detached {
                    try await self.loadOfficialDownloadControlTask(id: key.taskID)
                }.value
            } else {
                current = try await loadOfficialDownloadControlTask(id: key.taskID)
            }
            if let task = current,
               Self.confirmsDownloadControl(action: action, status: task.status) {
                pendingDownloadControlReviews[key] = nil
                return try downloadControlOutcome(
                    status: .confirmedSuccess,
                    action: action,
                    taskID: key.taskID,
                    task: task,
                    submitted: true,
                    requiresRefresh: true,
                    counts: MutationResultCounts(succeeded: 1, failed: 0, unknown: 0),
                    errorCategory: nil,
                    tag: "download-task.control.confirmed"
                )
            }
        } catch {
            pendingDownloadControlReviews[key] = DownloadTaskControlReview(key: key)
            return try downloadControlUnknownOutcome(
                action: action,
                taskID: key.taskID,
                status: statusIfUnconfirmed,
                category: Self.downloadControlErrorCategory(error)
            )
        }
        pendingDownloadControlReviews[key] = DownloadTaskControlReview(key: key)
        return try downloadControlUnknownOutcome(
            action: action,
            taskID: key.taskID,
            status: statusIfUnconfirmed,
            category: .unknown
        )
    }

    private func downloadControlConflictOutcome(
        action: DownloadStationTaskAction,
        taskID: String
    ) throws -> DownloadTaskControlOutcome {
        try downloadControlOutcome(
            status: .confirmedFailure,
            action: action,
            taskID: taskID,
            task: nil,
            submitted: false,
            requiresRefresh: false,
            counts: MutationResultCounts(succeeded: 0, failed: 1, unknown: 0),
            errorCategory: .conflict,
            tag: "download-task.control.conflict"
        )
    }

    private func downloadControlUnknownOutcome(
        action: DownloadStationTaskAction,
        taskID: String,
        status: MutationResultStatus,
        category: MutationErrorCategory
    ) throws -> DownloadTaskControlOutcome {
        try downloadControlOutcome(
            status: status,
            action: action,
            taskID: taskID,
            task: nil,
            submitted: true,
            requiresRefresh: true,
            counts: MutationResultCounts(succeeded: 0, failed: 0, unknown: 1),
            errorCategory: category,
            tag: status == .cancellationRequestedAfterSubmission
                ? "download-task.control.cancelled-after"
                : "download-task.control.unverified"
        )
    }

    private func downloadControlOutcome(
        status: MutationResultStatus,
        action: DownloadStationTaskAction,
        taskID: String,
        task: DownloadStationTask?,
        submitted: Bool,
        requiresRefresh: Bool,
        counts: MutationResultCounts,
        errorCategory: MutationErrorCategory?,
        tag: String
    ) throws -> DownloadTaskControlOutcome {
        try DownloadTaskControlOutcome(
            result: MutationResult(
                status: status,
                operation: Self.downloadControlOperation(for: action),
                submitted: submitted,
                requiresRefresh: requiresRefresh,
                counts: counts,
                errorCategory: errorCategory,
                localizationKey: tag,
                diagnosticTag: tag
            ),
            taskID: taskID,
            task: task
        )
    }

    private func invalidServiceResponse() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: true,
            safeUserMessage: L10n.string("shared.847fe982ab6f5ef7")
        )
    }

    private static func downloadControlOperation(for action: DownloadStationTaskAction) -> String {
        switch action {
        case .pause:
            "downloadPause"
        case .resume:
            "downloadResume"
        case .finish:
            "downloadControl"
        }
    }

    private static func downloadControlMethod(for action: DownloadStationTaskAction) -> String? {
        switch action {
        case .pause:
            "pause"
        case .resume:
            "resume"
        case .finish:
            nil
        }
    }

    private static func normalizedDownloadTaskStatus(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
    }

    private static func canSubmitDownloadControl(
        action: DownloadStationTaskAction,
        status: String
    ) -> Bool {
        let status = normalizedDownloadTaskStatus(status)
        switch action {
        case .pause:
            return [
                "waiting",
                "downloading",
                "checking",
                "hash_checking",
                "filehosting_waiting",
                "extracting",
                "seeding",
                "uploading"
            ].contains(status)
        case .resume:
            return status == "paused"
        case .finish:
            return false
        }
    }

    private static func confirmsDownloadControl(
        action: DownloadStationTaskAction,
        status: String
    ) -> Bool {
        let status = normalizedDownloadTaskStatus(status)
        switch action {
        case .pause:
            return status == "paused"
        case .resume:
            return [
                "waiting",
                "downloading",
                "checking",
                "hash_checking",
                "filehosting_waiting",
                "extracting",
                "seeding"
            ].contains(status)
        case .finish:
            return false
        }
    }

    private static func downloadControlErrorCategory(_ error: Error) -> MutationErrorCategory {
        guard let error = error as? AppError else {
            return .unknown
        }
        switch error.category {
        case .authenticationRequired, .otpRequired:
            return .authentication
        case .permissionDenied:
            return .permission
        case .networkUnavailable, .timeout, .tlsUntrusted, .tlsCertificateChanged:
            return .network
        case .apiUnavailable, .versionUnsupported:
            return .unsupported
        case .conflict, .notFound:
            return .conflict
        case .serverBusy, .invalidResponse, .unknown, .remoteStorageFull, .partialFailure:
            return .server
        case .cancelled:
            return .unknown
        case .localStorageFull:
            return .unknown
        }
    }

    private func apiURL(path: String) -> URL {
        var url = baseURL.appendingPathComponent("webapi", isDirectory: true)
        for segment in path.split(separator: "/") {
            url.appendPathComponent(String(segment), isDirectory: false)
        }
        return url
    }

    private func createDownloadMultipartBody(
        localURL: URL,
        boundary: String,
        fields: [String: String]
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LanStashDownload-\(UUID().uuidString).multipart")
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        #if os(iOS)
        attributes[.protectionKey] = FileProtectionType.complete
        #endif
        guard FileManager.default.createFile(
            atPath: bodyURL.path, contents: nil, attributes: attributes
        ) else {
            throw AppError(
                category: .localStorageFull,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.25e1b230ae17e73b")
            )
        }
        do {
            let output = try FileHandle(forWritingTo: bodyURL)
            defer { try? output.close() }
            func write(_ string: String) throws {
                guard let data = string.data(using: .utf8) else {
                    throw DsmRequestError.parameterEncodingFailed
                }
                try output.write(contentsOf: data)
            }

            for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                try write("--\(boundary)\r\n")
                try write("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
                try write("\(value)\r\n")
            }

            let safeFilename = localURL.lastPathComponent
                .replacingOccurrences(of: "\r", with: "")
                .replacingOccurrences(of: "\n", with: "")
                .replacingOccurrences(of: "\"", with: "'")
            try write("--\(boundary)\r\n")
            try write(
                "Content-Disposition: form-data; name=\"file\"; filename=\"\(safeFilename)\"\r\n"
            )
            try write("Content-Type: application/octet-stream\r\n\r\n")
            let input = try FileHandle(forReadingFrom: localURL)
            defer { try? input.close() }
            while true {
                let data = try input.read(upToCount: 1_024 * 1_024) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
            }
            try write("\r\n--\(boundary)--\r\n")
            return bodyURL
        } catch {
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    private static func downloadSettings(
        config: ServiceJSON,
        schedule: ServiceJSON?
    ) -> DownloadStationSettings {
        DownloadStationSettings(
            defaultDestination: config.firstString(["default_destination"]) ?? "",
            isEMuleEnabled: config.firstBoolean(["emule_enabled"]) ?? false,
            isAutoExtractEnabled: config.firstBoolean(["unzip_service_enabled"]) ?? false,
            btDownloadLimit: Int(config.firstInteger(["bt_max_download"]) ?? 0),
            btUploadLimit: Int(config.firstInteger(["bt_max_upload"]) ?? 0),
            httpDownloadLimit: Int(config.firstInteger(["http_max_download"]) ?? 0),
            ftpDownloadLimit: Int(config.firstInteger(["ftp_max_download"]) ?? 0),
            nzbDownloadLimit: Int(config.firstInteger(["nzb_max_download"]) ?? 0),
            emuleDownloadLimit: Int(config.firstInteger(["emule_max_download"]) ?? 0),
            emuleUploadLimit: Int(config.firstInteger(["emule_max_upload"]) ?? 0),
            isScheduleEnabled: schedule?.firstBoolean(["enabled"]) ?? false,
            isEMuleScheduleEnabled: schedule?.firstBoolean(["emule_enabled"]) ?? false
        )
    }

    private func loadVirtualMachineList() async throws -> (usesOfficialAPI: Bool, value: ServiceJSON) {
        if capabilities[DsmAPIName.virtualizationAPIGuest]?.selectedVersion != nil {
            do {
                return (
                    true,
                    try await call(DsmAPIName.virtualizationAPIGuest, method: "list")
                )
            } catch let error as AppError {
                guard shouldFallBackFromOfficialVirtualizationAPI(error),
                      capabilities[DsmAPIName.virtualizationGuest]?.selectedVersion != nil else {
                    throw error
                }
                return (
                    false,
                    try await call(DsmAPIName.virtualizationGuest, method: "list")
                )
            }
        }
        return (
            false,
            try await call(DsmAPIName.virtualizationGuest, method: "list")
        )
    }

    private func shouldFallBackFromOfficialVirtualizationAPI(_ error: AppError) -> Bool {
        switch error.category {
        case .apiUnavailable, .versionUnsupported, .invalidResponse, .notFound, .unknown:
            true
        default:
            false
        }
    }

    private func supplementaryCall(
        _ name: String,
        method: String,
        parameters: [String: DsmParameterValue] = [:]
    ) async throws -> ServiceJSON? {
        let result = try await supplementaryCall(
            name,
            methods: [method],
            parameters: parameters
        )
        return result.value
    }

    private func supplementaryCall(
        _ name: String,
        methods: [String],
        parameters: [String: DsmParameterValue] = [:]
    ) async throws -> SupplementaryServiceResult {
        guard capabilities[name]?.selectedVersion != nil else { return .unavailable }
        for method in methods {
            do {
                return .available(
                    try await call(name, method: method, parameters: parameters)
                )
            } catch let error as AppError {
                switch error.category {
                case .authenticationRequired, .otpRequired, .tlsUntrusted,
                     .tlsCertificateChanged, .cancelled:
                    throw error
                default:
                    continue
                }
            }
        }
        return .failed
    }

    private func call(
        _ name: String,
        method: String,
        parameters: [String: DsmParameterValue] = [:],
        fixedVersion: Int? = nil
    ) async throws -> ServiceJSON {
        guard let capability = capabilities[name],
              let version = capability.selectedVersion else {
            throw unavailableError()
        }
        if let fixedVersion {
            guard capability.name == name, capability.minVersion <= fixedVersion,
                  capability.maxVersion >= fixedVersion else { throw unavailableError() }
        }
        do {
            return try await client.call(
                path: capability.path,
                api: capability.name,
                version: fixedVersion ?? version,
                method: method,
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential,
                as: ServiceJSON.self
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private func callVoid(
        _ name: String,
        method: String,
        parameters: [String: DsmParameterValue],
        fixedVersion: Int? = nil
    ) async throws {
        guard let capability = capabilities[name],
              let version = capability.selectedVersion else {
            throw unavailableError()
        }
        if let fixedVersion {
            guard capability.name == name, capability.minVersion <= fixedVersion,
                  capability.maxVersion >= fixedVersion else { throw unavailableError() }
        }
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: fixedVersion ?? version,
                method: method,
                requestFormat: capability.requestFormat,
                parameters: parameters,
                credential: credential
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private func validatedIDs(_ values: [String]) throws -> [String] {
        let ids = values.compactMap(Self.nonEmpty)
        guard ids.count == values.count, !ids.isEmpty else {
            throw validationError(L10n.string("shared.e594e487c681e714"))
        }
        return Array(Set(ids)).sorted()
    }

    private func validatedName(_ value: String, message: String) throws -> String {
        guard let value = Self.nonEmpty(value), value.count <= 255 else {
            throw validationError(message)
        }
        return value
    }

    private func unavailableError() -> AppError {
        AppError(
            category: .apiUnavailable,
            isRetryable: false,
            safeUserMessage: L10n.string("shared.2096260091060844")
        )
    }

    private func validationError(_ message: String) -> AppError {
        AppError(category: .conflict, isRetryable: false, safeUserMessage: message)
    }

    private func verificationError(_ message: String) -> AppError {
        AppError(category: .conflict, isRetryable: true, safeUserMessage: message)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    private static func date(_ value: ServiceJSON, keys: [String]) -> Date? {
        if let seconds = value.firstDouble(keys), seconds > 0 {
            return Date(timeIntervalSince1970: seconds > 10_000_000_000 ? seconds / 1_000 : seconds)
        }
        for key in keys {
            guard let text = value[key]?.stringValue else { continue }
            if let date = ISO8601DateFormatter().date(from: text) {
                return date
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            for format in ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
        }
        return nil
    }

    /// 公开下载接口允许数字和十进制数字字符串；缺失、负数与非法类型不补零。
    private static func downloadNumber(_ value: ServiceJSON?, keys: [String]) -> Int64? {
        for key in keys {
            guard let node = value?[key] else { continue }
            let result: Int64?
            switch node {
            case .number(let number): result = Int64(exactly: number)
            case .string(let text): result = Int64(text)
            default: result = nil
            }
            if let result, result >= 0 { return result }
        }
        return nil
    }

    private static func officialDownloadTask(_ object: [String: ServiceJSON]) -> DownloadStationTask? {
        guard let id = strictNonEmptyString(object["id"], allowComma: false),
              case .string(let title)? = object["title"],
              let status = strictNonEmptyString(object["status"]) else { return nil }
        let value = ServiceJSON.object(object)
        let detail = value["additional"]?["detail"]
        let transfer = value["additional"]?["transfer"]
        return DownloadStationTask(
            id: id, title: title, status: status,
            sizeBytes: downloadNumber(value, keys: ["size"]),
            downloadedBytes: downloadNumber(transfer, keys: ["size_downloaded"]),
            uploadedBytes: downloadNumber(transfer, keys: ["size_uploaded"]),
            downloadBytesPerSecond: downloadNumber(transfer, keys: ["speed_download"]),
            uploadBytesPerSecond: downloadNumber(transfer, keys: ["speed_upload"]),
            destination: strictOptionalString(detail?["destination"]),
            errorDescription: strictOptionalString(value["status_extra"]?["error_detail"])
        )
    }

    private static func downloadTaskDetails(
        _ object: [String: ServiceJSON], task: DownloadStationTask
    ) throws -> DownloadStationTaskDetails {
        let value = ServiceJSON.object(object)
        let additional = value["additional"]
        let detail = additional?["detail"]
        func rows(_ key: String) throws -> [[String: ServiceJSON]]? {
            guard let additional, let node = additional[key] else { return nil }
            if case .null = node { return nil }
            return try strictRootObjects(additional, keys: [key])
        }
        func count(_ source: ServiceJSON?, _ key: String) -> Int? {
            downloadNumber(source, keys: [key]).flatMap(Int.init(exactly:))
        }
        let files = try rows("file")?.map { row -> DownloadStationTaskFile in
            guard case .string(let name)? = row["filename"], !name.isEmpty else {
                throw invalidServiceResponseStatic()
            }
            let row = ServiceJSON.object(row)
            return DownloadStationTaskFile(name: name,
                sizeBytes: downloadNumber(row, keys: ["size"]),
                downloadedBytes: downloadNumber(row, keys: ["size_downloaded"]),
                priority: strictOptionalString(row["priority"]))
        }
        let trackers = try rows("tracker")?.map { row -> DownloadStationTaskTracker in
            guard let address = strictOptionalString(row["url"]),
                  let url = URLComponents(string: address), let scheme = url.scheme, let host = url.host else {
                throw invalidServiceResponseStatic()
            }
            var display = URLComponents()
            display.scheme = scheme
            display.host = host
            display.port = url.port
            let row = ServiceJSON.object(row)
            return DownloadStationTaskTracker(displayAddress: display.string ?? host,
                status: strictOptionalString(row["status"]), seeds: count(row, "seeds"),
                peers: count(row, "peers"), nextUpdateSeconds: count(row, "update_timer"))
        }
        let peers = try rows("peer")?.map { row -> DownloadStationTaskPeer in
            guard let address = strictOptionalString(row["address"]) else {
                throw invalidServiceResponseStatic()
            }
            let row = ServiceJSON.object(row)
            var progress: Double?
            if case .number(let number)? = row["progress"], number.isFinite, (0...1).contains(number) {
                progress = number
            }
            return DownloadStationTaskPeer(address: address, client: strictOptionalString(row["agent"]),
                progress: progress, downloadBytesPerSecond: downloadNumber(row, keys: ["speed_download"]),
                uploadBytesPerSecond: downloadNumber(row, keys: ["speed_upload"]))
        }
        return DownloadStationTaskDetails(task: task, kind: strictOptionalString(value["type"]),
            owner: strictOptionalString(value["username"]),
            createdAt: downloadNumber(detail, keys: ["create_time"]).map { Date(timeIntervalSince1970: Double($0)) },
            priority: strictOptionalString(detail?["priority"]),
            connectedSeeders: count(detail, "connected_seeders"), connectedLeechers: count(detail, "connected_leechers"),
            totalPeers: count(detail, "total_peers"), files: files, trackers: trackers, peers: peers)
    }

    private static func downloadTask(_ object: [String: ServiceJSON]) -> DownloadStationTask? {
        let value = ServiceJSON.object(object)
        guard let id = value.firstString(["id", "task_id", "taskId"]) else { return nil }
        let detail = value["additional"]?["detail"] ?? value["detail"]
        let transfer = value["additional"]?["transfer"] ?? value["transfer"]
        return DownloadStationTask(
            id: id,
            title: value.firstString(["title", "name", "filename"]) ?? L10n.string("shared.e2106376a5ce15af"),
            status: value.firstString(["status", "state"]) ?? "unknown",
            sizeBytes: value.firstInteger(["size", "total_size"]),
            downloadedBytes: transfer?.firstInteger(["size_downloaded", "downloaded", "completed"])
                ?? value.firstInteger(["size_downloaded", "downloaded", "completed"]),
            uploadedBytes: transfer?.firstInteger(["size_uploaded", "uploaded"]),
            downloadBytesPerSecond: transfer?.firstInteger(["speed_download", "download_rate"]),
            uploadBytesPerSecond: transfer?.firstInteger(["speed_upload", "upload_rate"]),
            destination: value.firstString(["destination"])
                ?? detail?.firstString(["destination"]),
            errorDescription: value.firstString(["error", "error_detail", "message"])
        )
    }

    private static func downloadBTSearchCatalog(
        modulesValue: ServiceJSON,
        categoriesValue: ServiceJSON
    ) throws -> DownloadBTSearchCatalog {
        guard let moduleObjects = modulesValue["modules"]?.array,
              let categoryObjects = categoriesValue["categories"]?.array else {
            throw invalidDownloadBTSearchResponse()
        }
        var moduleIDs = Set<String>()
        let modules = try moduleObjects.map { node -> DownloadBTSearchModule in
            guard case .object(let object) = node,
                  let id = strictNonEmptyString(object["id"], allowComma: false),
                  let title = strictNonEmptyString(object["title"], allowComma: true),
                  let enabled = strictBoolean(object["enabled"]),
                  moduleIDs.insert(id).inserted else {
                throw invalidDownloadBTSearchResponse()
            }
            return DownloadBTSearchModule(id: id, title: title, isEnabled: enabled)
        }
        var categoryIDs = Set<String>()
        let categories = try categoryObjects.map { node -> DownloadBTSearchCategory in
            guard case .object(let object) = node,
                  let id = strictNonEmptyString(object["id"], allowComma: true),
                  let title = strictNonEmptyString(object["title"], allowComma: true),
                  categoryIDs.insert(id).inserted else {
                throw invalidDownloadBTSearchResponse()
            }
            return DownloadBTSearchCategory(id: id, title: title)
        }
        return DownloadBTSearchCatalog(modules: modules, categories: categories)
    }

    private struct PreparedDownloadBTSearchRequest: Sendable {
        let keyword: String
        let module: String
        let category: String
        let sort: String
        let direction: String
        let titleFilter: String
    }

    private static func preparedDownloadBTSearchRequest(
        _ request: DownloadBTSearchRequest
    ) throws -> PreparedDownloadBTSearchRequest {
        guard !containsControlCharacters(request.keyword) else {
            throw validationErrorStatic(L10n.string("shared.ee9bd6266a536859"))
        }
        let keyword = request.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty,
              keyword.count <= 200,
              !keyword.contains(where: \.isNewline),
              !containsControlCharacters(keyword) else {
            throw validationErrorStatic(L10n.string("shared.ee9bd6266a536859"))
        }
        guard !containsControlCharacters(request.titleFilter) else {
            throw validationErrorStatic(L10n.string("shared.ee9bd6266a536859"))
        }
        let titleFilter = request.titleFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard titleFilter.count <= 200,
              !titleFilter.contains(where: \.isNewline),
              !containsControlCharacters(titleFilter) else {
            throw validationErrorStatic(L10n.string("shared.ee9bd6266a536859"))
        }
        let category: String
        if let rawCategoryID = request.categoryID {
            guard !containsControlCharacters(rawCategoryID) else {
                throw validationErrorStatic(L10n.string("shared.ee9bd6266a536859"))
            }
            let categoryID = rawCategoryID.trimmingCharacters(in: .whitespacesAndNewlines)
            if categoryID.isEmpty {
                category = ""
            } else {
                guard isStableDownloadBTSearchIdentifier(categoryID, allowComma: true) else {
                    throw validationErrorStatic(L10n.string("shared.ee9bd6266a536859"))
                }
                category = categoryID
            }
        } else {
            category = ""
        }

        let module: String
        switch request.moduleScope {
        case .all:
            module = "all"
        case .enabled:
            module = "enabled"
        case .selected(let ids):
            guard ids.allSatisfy({ !containsControlCharacters($0) }) else {
                throw validationErrorStatic(L10n.string("shared.ee9bd6266a536859"))
            }
            let normalizedIDs = ids
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !normalizedIDs.isEmpty,
                  normalizedIDs.allSatisfy({ isStableDownloadBTSearchIdentifier($0, allowComma: false) }) else {
                throw validationErrorStatic(L10n.string("shared.ee9bd6266a536859"))
            }
            module = Array(Set(normalizedIDs)).sorted().joined(separator: ",")
        }
        return PreparedDownloadBTSearchRequest(
            keyword: keyword,
            module: module,
            category: category,
            sort: request.sort.rawValue,
            direction: request.direction.rawValue,
            titleFilter: titleFilter
        )
    }

    private static func downloadBTSearchResults(
        from value: ServiceJSON
    ) throws -> [DownloadBTSearchResult] {
        guard let itemNodes = value["items"]?.array,
              itemNodes.count <= downloadBTSearchResultLimit else {
            throw invalidDownloadBTSearchResponse()
        }
        var downloadURIs = Set<String>()
        return try itemNodes.map { node in
            guard case .object(let object) = node,
                  let downloadURI = strictNonEmptyString(object["download_uri"], allowComma: true),
                  downloadURIs.insert(downloadURI).inserted else {
                throw invalidDownloadBTSearchResponse()
            }
            return DownloadBTSearchResult(
                title: strictNonEmptyString(object["title"], allowComma: true) ?? downloadURI,
                sizeBytes: try strictOptionalNonNegativeInteger(object["size"]),
                listedAt: strictOptionalString(object["date"]),
                downloadURI: downloadURI,
                externalLink: strictOptionalString(object["external_link"]),
                peers: try strictOptionalInt(object["peers"]),
                seeds: try strictOptionalInt(object["seeds"]),
                leeches: try strictOptionalInt(object["leechs"]),
                provider: strictOptionalString(object["module_title"])
            )
        }
    }

    private static func strictNonEmptyString(
        _ value: ServiceJSON?,
        allowComma: Bool = true
    ) -> String? {
        guard let text = strictOptionalString(value),
              isStableDownloadBTSearchIdentifier(text, allowComma: allowComma) else {
            return nil
        }
        return text
    }

    private static func strictOptionalString(_ value: ServiceJSON?) -> String? {
        guard let value else { return nil }
        guard case .string(let text) = value else { return nil }
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized == text,
              !containsControlCharacters(normalized) else {
            return nil
        }
        return normalized
    }

    private static func strictBoolean(_ value: ServiceJSON?) -> Bool? {
        guard case .boolean(let bool)? = value else { return nil }
        return bool
    }

    private static func strictOptionalInt(_ value: ServiceJSON?) throws -> Int? {
        guard let integer = try strictOptionalNonNegativeInteger(value) else { return nil }
        guard let result = Int(exactly: integer) else {
            throw invalidDownloadBTSearchResponse()
        }
        return result
    }

    private static func strictOptionalNonNegativeInteger(
        _ value: ServiceJSON?
    ) throws -> Int64? {
        guard let value else { return nil }
        guard case .number(let number) = value,
              number.rounded() == number,
              let integer = Int64(exactly: number),
              integer >= 0 else {
            throw invalidDownloadBTSearchResponse()
        }
        return integer
    }

    private static func isStableDownloadBTSearchIdentifier(
        _ value: String,
        allowComma: Bool
    ) -> Bool {
        !value.isEmpty &&
            value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
            !containsControlCharacters(value) &&
            (allowComma || !value.contains(","))
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private static func invalidDownloadBTSearchResponse() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: true,
            safeUserMessage: L10n.string("shared.847fe982ab6f5ef7")
        )
    }

    private static func validationErrorStatic(_ message: String) -> AppError {
        AppError(category: .conflict, isRetryable: false, safeUserMessage: message)
    }

    private static func container(_ object: [String: ServiceJSON]) -> ContainerInstance? {
        let value = ServiceJSON.object(object)
        guard let id = value.firstString(["id", "container_id", "Id"]) else { return nil }
        var status = value.firstString(["status", "state", "State"]) ?? "unknown"
        if case .object(let runtime)? = object["State"], case .boolean(true)? = runtime["Restarting"] { status = "restarting" }
        return ContainerInstance(
            id: id,
            name: value.firstString(["name", "Names"]) ?? String(id.prefix(12)),
            image: value.firstString(["image", "image_name", "Image"]) ?? "—",
            project: value.firstString(["project", "project_name"]),
            status: status,
            cpuUsage: value.firstDouble(["cpu", "cpu_usage", "cpu_percent"]),
            memoryBytes: value.firstInteger(["memory", "memory_usage", "memory_bytes"]),
            createdAt: date(value, keys: ["created", "created_at", "CreateTime"])
        )
    }

    /// 移动端只读清单只接受已有合成证据覆盖的 Container.list v1 确定形状。
    private static func internalContainerV1Inventory(
        from value: ServiceJSON
    ) throws -> [ContainerInventoryItem] {
        guard case .object(let root) = value,
              case .array(let containers)? = root["containers"] else {
            throw invalidContainerInventoryError()
        }
        try requireCompleteServiceList(value, count: containers.count)
        var identifiers = Set<String>()
        return try containers.map { node in
            guard case .object(let object) = node,
                  let id = officialNonEmptyString(object["id"]),
                  let name = officialNonEmptyString(object["name"]),
                  let status = officialNonEmptyString(object["status"]),
                  identifiers.insert(id).inserted else {
                throw invalidContainerInventoryError()
            }
            let image: String?
            if let node = object["image"] {
                guard let value = officialNonEmptyString(node) else {
                    throw invalidContainerInventoryError()
                }
                image = value
            } else {
                image = nil
            }
            return ContainerInventoryItem(id: id, name: name, status: status, image: image)
        }
    }

    private static func invalidContainerInventoryError() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: true,
            safeUserMessage: L10n.string("container.inventory.invalid")
        )
    }

    private static func image(_ object: [String: ServiceJSON]) -> ContainerImage? {
        let value = ServiceJSON.object(object)
        guard let id = value.firstString(["id", "image_id", "Id"]) else { return nil }
        let repository = value.firstString(["repository", "repo", "name", "RepoTags"]) ?? "—"
        return ContainerImage(
            id: id,
            repository: repository,
            tag: value.firstString(["tag"]) ?? "—",
            sizeBytes: value.firstInteger(["size", "virtual_size", "Size"]),
            createdAt: date(value, keys: ["created", "created_at", "Created"]),
            isInUse: value.firstBoolean(["in_use", "is_used", "using"]) ?? false
        )
    }

    private static func containerImages(_ value: ServiceJSON) throws -> [ContainerImage] {
        let rows = try strictRootObjects(value, keys: ["images", "image"])
        try requireCompleteServiceList(value, count: rows.count)
        var result: [ContainerImage] = []
        for row in rows {
            guard let summary = image(row) else { throw invalidServiceResponseStatic() }
            guard let rawTags = row["tags"] else {
                result.append(summary)
                continue
            }
            guard case .array(let tags) = rawTags,
                  let sourceID = try imageString(row, "id"), let repository = try imageString(row, "repository") else {
                throw invalidServiceResponseStatic()
            }
            if tags.isEmpty { result.append(summary) }
            for rawTag in tags {
                guard case .string(let tag) = rawTag, stableImageText(tag) else { throw invalidServiceResponseStatic() }
                result.append(ContainerImage(id: ContainerImage.selectionID(imageID: sourceID, repository: repository, tag: tag),
                    repository: repository, tag: tag, sizeBytes: summary.sizeBytes, createdAt: summary.createdAt, sourceImageID: sourceID))
            }
        }
        let addresses = result.filter { $0.sourceImageID != nil && $0.tag != "<none>" }.map(imageAddress)
        guard Set(result.map(\.id)).count == result.count, Set(addresses).count == addresses.count else { throw invalidServiceResponseStatic() }
        return result
    }

    private static func requireCompleteServiceList(_ value: ServiceJSON, count: Int) throws {
        if let total = value["total"] {
            guard case .number(let number) = total, number == Double(count) else { throw invalidServiceResponseStatic() }
        }
        if let offset = value["offset"] {
            guard case .number(let number) = offset, number == 0 else { throw invalidServiceResponseStatic() }
        }
    }

    private static func containerImageUsage(_ images: [ContainerImage], containers: ServiceJSON) throws -> Set<String> {
        let rows = try strictRootObjects(containers, keys: ["containers", "container"])
        try requireCompleteServiceList(containers, count: rows.count)
        var used: Set<String> = []
        for row in rows {
            let rawImage = try imageString(row, "Image") ?? ""
            let match: ContainerImage?
            if rawImage.hasPrefix("sha256:") || rawImage.contains("@sha256:") {
                guard let sourceID = try imageString(row, "ImageID") else { throw invalidServiceResponseStatic() }
                let candidates = images.filter { $0.sourceImageID == sourceID }
                guard !candidates.isEmpty else { throw invalidServiceResponseStatic() }
                let marker = rawImage.hasPrefix("sha256:") ? rawImage : ":" + imageTag(String(rawImage.split(separator: "@")[0]))
                match = candidates.first { "\($0.repository):\($0.tag)".contains(marker) ||
                    $0.tag == "<none>" && ($0.sourceImageID?.contains(marker) ?? false) } ?? candidates.first
            } else {
                guard let name = try imageString(row, "image") else { throw invalidServiceResponseStatic() }
                match = images.first { $0.sourceImageID != nil && imageAddress($0) == normalizedImageName(name) }
            }
            if let match {
                used.insert(match.id)
                for bare in images where bare.tag == "<none>" && bare.sourceImageID == match.sourceImageID { used.insert(bare.id) }
            }
        }
        return used
    }

    private static func stableImageText(_ text: String) -> Bool {
        !text.isEmpty && text == text.trimmingCharacters(in: .whitespacesAndNewlines) && text.rangeOfCharacter(from: .controlCharacters) == nil
    }
    private static func imageString(_ row: [String: ServiceJSON], _ key: String) throws -> String? {
        guard let value = row[key] else { return nil }
        guard case .string(let text) = value, stableImageText(text) else { throw invalidServiceResponseStatic() }
        return text
    }
    private static func imageTag(_ name: String) -> String {
        let lastComponent = name.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? name
        return lastComponent.lastIndex(of: ":").map { String(lastComponent[lastComponent.index(after: $0)...]) } ?? "latest"
    }
    private static func normalizedImageName(_ raw: String) -> String {
        var name = raw
        for prefix in ["docker.io/", "index.docker.io/"] where name.hasPrefix(prefix) {
            name = String(name.dropFirst(prefix.count)); break
        }
        let lastComponent = name.split(separator: "/", omittingEmptySubsequences: false).last ?? ""
        return lastComponent.contains(":") ? name : name + ":latest"
    }
    private static func imageAddress(_ image: ContainerImage) -> String { normalizedImageName("\(image.repository):\(image.tag)") }

    private static func registryImage(
        _ object: [String: ServiceJSON]
    ) -> ContainerRegistryImage? {
        let value = ServiceJSON.object(object)
        guard let name = value.firstString(["name", "repository", "repo"]) else { return nil }
        return ContainerRegistryImage(
            name: name,
            registry: value.firstString(["registry"]) ?? "docker.io",
            description: value.firstString(["description"]),
            starCount: Int(value.firstInteger(["star_count", "stars"]) ?? 0),
            isOfficial: value.firstBoolean(["is_official", "official"]) ?? false,
            isAutomated: value.firstBoolean(["is_automated", "automated"]) ?? false,
            isTrusted: value.firstBoolean(["is_trusted", "trusted"]) ?? false
        )
    }

    private static func containerNetwork(
        _ object: [String: ServiceJSON]
    ) -> ContainerNetwork? {
        let value = ServiceJSON.object(object)
        guard let id = value.firstString(["id", "network_id", "Id"]) else { return nil }
        let count: Int
        if let connections = value["containers"] {
            guard let names = connections.array, names.allSatisfy({ if case .string = $0 { return true }; return false }) else { return nil }
            count = names.count
        } else {
            let rawCounts = ["container_count", "containers_count", "using"].compactMap { value[$0] }
            let counts = rawCounts.compactMap(containerNetworkCount)
            // 缺少、布尔、小数或互相冲突的计数不等于没有容器。
            guard !rawCounts.isEmpty, counts.count == rawCounts.count, Set(counts).count == 1 else { return nil }
            count = counts[0]
        }
        let ipv6: Bool?
        if case .boolean(let enabled)? = value["enable_ipv6"] { ipv6 = enabled }
        else { ipv6 = nil }
        return ContainerNetwork(
            id: id,
            name: value.firstString(["name", "Name"]) ?? String(id.prefix(12)),
            driver: value.firstString(["driver", "Driver", "type"]) ?? "—",
            connectedContainerCount: count,
            subnet: value.firstString(["subnet"]),
            gateway: value.firstString(["gateway"]),
            isIPv6Enabled: ipv6,
            connectedContainerNames: value["containers"]?.array?.compactMap(\.stringValue),
            ipRange: value.firstString(["iprange"])
        )
    }

    private static func containerNetworkCount(_ value: ServiceJSON) -> Int? {
        let parsed: Int?
        switch value {
        case .number(let number): parsed = Int(exactly: number)
        case .string(let text): parsed = Int(text)
        default: parsed = nil
        }
        guard let parsed, parsed >= 0 else { return nil }
        return parsed
    }

    /// 官方项目列表是以项目 ID 为键的对象，空对象表示没有项目；不影响其他分区的严格解析。
    private static func containerProjects(
        _ result: SupplementaryServiceResult,
        failedSections: inout Set<ContainerManagerSection>
    ) -> [ContainerProject] {
        guard case .available(let value) = result else { return [] }
        if let dictionary = value.object,
           ["projects", "project", "data", "result", "items"].allSatisfy({ dictionary[$0] == nil }) {
            var projects: [ContainerProject] = []
            for id in dictionary.keys.sorted() {
                guard !id.isEmpty, var object = dictionary[id]?.object else {
                    failedSections.insert(.projects)
                    return []
                }
                object["id"] = .string(id)
                guard let item = project(object) else {
                    failedSections.insert(.projects)
                    return []
                }
                projects.append(item)
            }
            return projects
        }
        return strictSupplementaryItems(
            result, keys: ["projects", "project"], parser: project,
            failedSection: .projects, failedSections: &failedSections
        )
    }

    private static func project(_ object: [String: ServiceJSON]) -> ContainerProject? {
        let value = ServiceJSON.object(object)
        guard let id = value.firstString(["id", "project_id"]),
              let name = value.firstString(["name", "project_name"]) else { return nil }
        return ContainerProject(
            id: id,
            name: name,
            status: value.firstString(["status", "state"]) ?? "unknown",
            containerCount: value["containerIds"]?.array?.count
                ?? Int(value.firstInteger(["container_count", "services"]) ?? 0)
        )
    }

    private static func machine(_ object: [String: ServiceJSON], internalMemoryKiB: Bool) -> VirtualMachine? {
        let value = ServiceJSON.object(object)
        guard let id = value.firstString(["guest_id", "id", "vm_id"]) else { return nil }
        let memoryScale: Int64 = internalMemoryKiB ? 1_024 : 1_024 * 1_024
        let memoryBytes = value.firstInteger(["memory", "memory_size", "ram"])
            ?? value.firstInteger(["vram_size"]).flatMap { raw -> Int64? in
                guard raw >= 0, raw <= Int64.max / memoryScale else { return nil }
                return raw * memoryScale
            }
        let reportedStorageBytes = value.firstInteger([
            "storage", "disk_size", "virtual_disk_size"
        ])
        let virtualDiskSizes = value["vdisks"]?.array?.compactMap {
            $0.firstInteger(["vdisk_size"])
        } ?? []
        let virtualDiskBytes = virtualDiskSizes.isEmpty
            ? nil
            : virtualDiskSizes.reduce(0, +) * 1_024 * 1_024
        let storageBytes = reportedStorageBytes ?? virtualDiskBytes
        return VirtualMachine(
            id: id,
            name: value.firstString(["guest_name", "name", "vm_name"]) ?? String(id.prefix(12)),
            status: value.firstString(["status", "state", "power_state"]) ?? "unknown",
            description: value.firstString(["desc", "description"]),
            hostID: value.firstString(["host_id"]),
            host: value.firstString(["host_name", "host", "node"]),
            storageID: value.firstString(["repo_id", "storage_id"]),
            cpuCount: value.firstInteger(["vcpu_num", "cpu", "cpu_count"]).map(Int.init),
            memoryBytes: memoryBytes,
            storageBytes: storageBytes,
            ipAddress: value.firstString(["ip", "ip_address", "guest_ip"]),
            keyboardLayout: value.firstString(["kb_layout", "keyboard_layout"]),
            cpuWeight: parseVirtualMachineCpuWeight(value["cpu_weight"]),
            startupBehavior: parseVirtualMachineStartupBehavior(value["autorun"])
        )
    }

    /// 移动端只读清单只接受公开 Guest v1 的确定形状，避免把内部兼容别名误报为正常数据。
    private static func publicGuestV1Inventory(
        from value: ServiceJSON
    ) throws -> [VirtualMachineInventoryItem] {
        guard case .object(let root) = value,
              case .array(let guests)? = root["guests"] else {
            throw invalidVirtualMachineInventoryError()
        }
        var identifiers = Set<String>()
        return try guests.map { node in
            guard case .object(let object) = node,
                  let id = officialIdentifier(object["guest_id"]),
                  let name = officialNonEmptyString(object["guest_name"]),
                  let status = officialNonEmptyString(object["status"]),
                  let startupBehavior = parseVirtualMachineStartupBehavior(object["autorun"]),
                  identifiers.insert(id).inserted else {
                throw invalidVirtualMachineInventoryError()
            }
            let cpuCount = try officialOptionalNonNegativeInteger(object["vcpu_num"])
                .map {
                    guard let value = Int(exactly: $0) else {
                        throw invalidVirtualMachineInventoryError()
                    }
                    return value
                }
            let memoryMiB = try officialOptionalNonNegativeInteger(object["vram_size"])
            let memoryBytes = try memoryMiB.map {
                try multipliedWithoutOverflow($0, by: 1_024 * 1_024)
            }
            let storageBytes = try officialVirtualDiskBytes(object["vdisks"])
            return VirtualMachineInventoryItem(
                id: id,
                name: name,
                status: status,
                cpuCount: cpuCount,
                memoryBytes: memoryBytes,
                storageBytes: storageBytes,
                startupBehavior: startupBehavior
            )
        }
    }

    private static func officialVirtualDiskBytes(_ node: ServiceJSON?) throws -> Int64? {
        guard let node else { return nil }
        guard case .array(let disks) = node else {
            throw invalidVirtualMachineInventoryError()
        }
        var totalMiB: Int64 = 0
        for disk in disks {
            guard case .object(let object) = disk,
                  let size = try officialOptionalNonNegativeInteger(object["vdisk_size"]) else {
                throw invalidVirtualMachineInventoryError()
            }
            let addition = totalMiB.addingReportingOverflow(size)
            guard !addition.overflow else { throw invalidVirtualMachineInventoryError() }
            totalMiB = addition.partialValue
        }
        return try multipliedWithoutOverflow(totalMiB, by: 1_024 * 1_024)
    }

    private static func officialIdentifier(_ node: ServiceJSON?) -> String? {
        switch node {
        case .string(let value): return nonEmpty(value)
        case .number(let value) where value.isFinite && value.rounded() == value:
            return String(format: "%.0f", locale: Locale(identifier: "en_US_POSIX"), value)
        default: return nil
        }
    }

    private static func officialNonEmptyString(_ node: ServiceJSON?) -> String? {
        guard case .string(let value) = node else { return nil }
        return nonEmpty(value)
    }

    private static func parseVirtualMachineStartupBehavior(_ node: ServiceJSON?) -> VirtualMachineStartupBehavior? {
        guard case .number(let raw)? = node, raw.isFinite, raw.rounded() == raw, (0...2).contains(raw) else { return nil }
        return VirtualMachineStartupBehavior(rawValue: Int(raw))
    }

    private static func parseVirtualMachineCpuWeight(_ node: ServiceJSON?) -> Int? {
        guard case .number(let raw)? = node, let value = Int(exactly: raw), value > 0 else { return nil }
        return value
    }

    private static func officialOptionalNonNegativeInteger(
        _ node: ServiceJSON?
    ) throws -> Int64? {
        guard let node else { return nil }
        guard case .number(let value) = node,
              value.isFinite,
              value >= 0,
              value.rounded() == value,
              value < Double(Int64.max) else {
            throw invalidVirtualMachineInventoryError()
        }
        return Int64(value)
    }

    private static func multipliedWithoutOverflow(_ value: Int64, by multiplier: Int64) throws -> Int64 {
        let result = value.multipliedReportingOverflow(by: multiplier)
        guard !result.overflow else { throw invalidVirtualMachineInventoryError() }
        return result.partialValue
    }

    private static func invalidVirtualMachineInventoryError() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: true,
            safeUserMessage: L10n.string("shared.847fe982ab6f5ef7")
        )
    }

    private static func strictRootObjects(
        _ value: ServiceJSON,
        keys: [String]
    ) throws -> [[String: ServiceJSON]] {
        if case .array(let nodes) = value {
            return try nodes.map { node in
                guard case .object(let object) = node else {
                    throw invalidServiceResponseStatic()
                }
                return object
            }
        }
        guard case .object(let root) = value else {
            throw invalidServiceResponseStatic()
        }
        for key in keys where root[key] != nil {
            guard case .array(let nodes)? = root[key] else {
                throw invalidServiceResponseStatic()
            }
            return try nodes.map { node in
                guard case .object(let object) = node else {
                    throw invalidServiceResponseStatic()
                }
                return object
            }
        }
        throw invalidServiceResponseStatic()
    }

    private static func strictMappedItems<Item: Identifiable>(
        _ value: ServiceJSON,
        keys: [String],
        parser: ([String: ServiceJSON]) -> Item?
    ) throws -> [Item] where Item.ID == String {
        let objects = try strictRootObjects(value, keys: keys)
        var identifiers = Set<String>()
        return try objects.map { object in
            guard let item = parser(object),
                  !item.id.isEmpty,
                  identifiers.insert(item.id).inserted else {
                throw invalidServiceResponseStatic()
            }
            return item
        }
    }

    private static func strictSupplementaryItems<Item: Identifiable, Section: Hashable>(
        _ result: SupplementaryServiceResult,
        keys: [String],
        parser: ([String: ServiceJSON]) -> Item?,
        failedSection: Section,
        failedSections: inout Set<Section>
    ) -> [Item] where Item.ID == String {
        guard case .available(let value) = result else { return [] }
        do {
            return try strictMappedItems(value, keys: keys, parser: parser)
        } catch {
            failedSections.insert(failedSection)
            return []
        }
    }

    private static func strictSupplementaryResources(
        _ result: SupplementaryServiceResult,
        keys: [String],
        failedSection: VirtualMachineManagerSection,
        failedSections: inout Set<VirtualMachineManagerSection>
    ) -> [VirtualizationResource] {
        strictSupplementaryItems(
            result,
            keys: keys,
            parser: resource,
            failedSection: failedSection,
            failedSections: &failedSections
        )
    }

    private static func strictSupplementaryEvents<Section: Hashable>(
        _ result: SupplementaryServiceResult,
        keys: [String],
        failedSection: Section,
        failedSections: inout Set<Section>
    ) -> [ServiceEvent] {
        guard case .available(let value) = result else { return [] }
        do {
            let objects = try strictRootObjects(value, keys: keys)
            var identifiers = Set<String>()
            return try objects.enumerated().map { offset, object in
                guard let event = strictEvent(object, offset: offset),
                      identifiers.insert(event.id).inserted else {
                    throw invalidServiceResponseStatic()
                }
                return event
            }
        } catch {
            failedSections.insert(failedSection)
            return []
        }
    }

    private static func strictSupplementaryProtection(
        _ result: SupplementaryServiceResult,
        failedSections: inout Set<VirtualMachineManagerSection>
    ) -> (
        plans: [VirtualizationResource],
        schedules: [VirtualizationResource],
        retentions: [VirtualizationResource]
    ) {
        guard case .available(let value) = result else { return ([], [], []) }
        do {
            guard case .object(let root) = value else {
                throw invalidServiceResponseStatic()
            }
            let groups: [([String], WritableKeyPath<ProtectionGroups, [VirtualizationResource]>)] = [
                (["plans", "plan", "protection_plans", "guest_protects"], \.plans),
                (["schedule_policies", "schedules", "schedule_policy"], \.schedules),
                (["retention_policies", "retentions", "retention_policy"], \.retentions)
            ]
            var parsed = ProtectionGroups()
            var foundArray = false
            for (keys, keyPath) in groups where keys.contains(where: { root[$0] != nil }) {
                parsed[keyPath: keyPath] = try strictMappedItems(value, keys: keys, parser: resource)
                foundArray = true
            }
            guard foundArray else { throw invalidServiceResponseStatic() }
            return (parsed.plans, parsed.schedules, parsed.retentions)
        } catch {
            failedSections.insert(.protection)
            return ([], [], [])
        }
    }

    private struct ProtectionGroups {
        var plans: [VirtualizationResource] = []
        var schedules: [VirtualizationResource] = []
        var retentions: [VirtualizationResource] = []
    }

    private static func resource(
        _ object: [String: ServiceJSON]
    ) -> VirtualizationResource? {
        let value = ServiceJSON.object(object)
        guard let id = value.firstString([
            "id", "storage_id", "repo_id", "network_id", "image_id", "host_id"
        ]),
        let name = value.firstString([
            "name", "host_name", "storage_name", "repo_name",
            "network_name", "image_name", "plan_name", "policy_name", "title", "id"
        ]) else {
            return nil
        }
        return VirtualizationResource(
            id: id,
            name: name,
            status: value.firstString(["status", "state", "health"]),
            detail: value.firstString(["description", "type", "path", "volume_path"]),
            hostID: value.firstString(["host_id"]),
            hostName: value.firstString(["host_name"]),
            allocatedBytes: value.firstInteger([
                "allocated_size", "allocated_bytes", "used_size"
            ]),
            capacityBytes: value.firstInteger(["size", "capacity", "total_size"])
        )
    }

    private static func resources(
        _ value: ServiceJSON?,
        keys: [String]
    ) -> [VirtualizationResource] {
        value?.objects(for: keys).compactMap(resource) ?? []
    }

    private static func invalidServiceResponseStatic() -> AppError {
        AppError(
            category: .invalidResponse,
            isRetryable: true,
            safeUserMessage: L10n.string("shared.847fe982ab6f5ef7")
        )
    }

    private static func randomVirtualMACAddress() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = [UInt8(0x02)] + (0..<5).map { _ in UInt8.random(in: 0...255, using: &generator) }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func isVirtualMachineRunning(_ status: String) -> Bool {
        ["running", "started", "up", "online"].contains(status.lowercased())
    }

    private static func event(
        offset: Int,
        element: [String: ServiceJSON]
    ) -> ServiceEvent {
        let value = ServiceJSON.object(element)
        let timestamp = date(
            value,
            keys: ["time", "timestamp", "date", "event_time", "create_time", "created_at"]
        )
        let message = value.firstString([
            "event", "message", "description", "msg", "content", "detail"
        ]) ?? "—"
        return ServiceEvent(
            id: value.firstString(["id", "log_id"])
                ?? "\(timestamp?.timeIntervalSince1970 ?? 0)-\(offset)-\(message.hashValue)",
            timestamp: timestamp,
            level: value.firstString(["level", "severity", "type", "priority"]) ?? L10n.string("shared.e7028601e7da793d"),
            user: value.firstString(["user", "username", "owner", "account", "user_name"]),
            message: message
        )
    }

    private static func strictEvent(
        _ element: [String: ServiceJSON],
        offset: Int
    ) -> ServiceEvent? {
        let value = ServiceJSON.object(element)
        guard let message = value.firstString([
            "event", "message", "description", "msg", "content", "detail"
        ]) else {
            return nil
        }
        let timestampKeys = ["time", "timestamp", "date", "event_time", "create_time", "created_at"]
        let timestamp = date(value, keys: timestampKeys)
        let level = value.firstString(["level", "severity", "type", "priority"])
            ?? L10n.string("shared.e7028601e7da793d")
        let user = value.firstString(["user", "username", "owner", "account", "user_name"])
        let timestampIdentity = timestamp?.timeIntervalSince1970.description ?? "unknown"
        let id = value.firstString(["id", "log_id"])
            ?? "event-\(timestampIdentity)-\(offset)"
        return ServiceEvent(
            id: id,
            timestamp: timestamp,
            level: level,
            user: user,
            message: message
        )
    }

}
