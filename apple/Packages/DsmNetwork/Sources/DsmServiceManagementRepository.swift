import DsmCore
import CryptoKit
import Foundation
import DsmLocalization

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

    var value: ServiceJSON? {
        guard case .available(let value) = self else { return nil }
        return value
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
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
    let key: DownloadTaskCreateKey
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
    private static let downloadControlReadbackLimit = 5_000
    private static let downloadControlPageSize = 500
    private static let downloadBTSearchResultLimit = 200
    private let capabilities: CapabilitySet
    private let credential: DsmSessionCredential
    private let baseURL: URL
    private let client: DsmAPIClient
    private let transport: any DsmHTTPTransport
    private var activeDownloadControlKeys: Set<DownloadTaskControlKey> = []
    private var pendingDownloadControlReviews: [DownloadTaskControlKey: DownloadTaskControlReview] = [:]
    private var activeDownloadCreateKeys: Set<DownloadTaskCreateKey> = []
    private var pendingDownloadCreateReviews: [DownloadTaskCreateKey: DownloadTaskCreateReview] = [:]
    private var activeContainerDeletionIDs: Set<String> = []
    private var activeVirtualMachineDeletionIDs: Set<String> = []
    private var activeDeletionIDsByOperation: [String: Set<String>] = [:]

    public init(
        profile: NasProfile,
        capabilities: CapabilitySet,
        session: AuthSession,
        transport: (any DsmHTTPTransport)? = nil
    ) throws {
        let resolvedTransport = transport ?? URLSessionTransport(
            expectedHost: profile.host,
            pinnedCertificateSHA256: profile.pinnedCertificateSHA256,
            requiresSystemCertificateTrust: DsmQuickConnectResolver.isTrustedRelayHost(profile.host)
        )
        let baseURL = try DsmEndpoint.baseURL(for: profile)
        self.capabilities = capabilities
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
        let statisticAPI = usesOfficial
            ? DsmAPIName.downloadStationStatistic
            : DsmAPIName.downloadStation2Statistic
        let statisticMethod = usesOfficial ? "getinfo" : "get"
        let statistic = try? await call(statisticAPI, method: statisticMethod)
        let location = usesOfficial
            ? nil
            : try? await call(DsmAPIName.downloadStation2Location, method: "get")

        return DownloadStationSnapshot(
            source: usesOfficial ? .official : .internalAPI,
            tasks: tasks,
            hasActivitySummary: statistic != nil,
            hasBTSearch: usesOfficial &&
                capabilities[DsmAPIName.downloadStationBTSearch]?.selectedVersion != nil,
            downloadBytesPerSecond: statistic?.firstInteger([
                "download_rate", "download_speed", "speed_download"
            ]) ?? 0,
            uploadBytesPerSecond: statistic?.firstInteger([
                "upload_rate", "upload_speed", "speed_upload"
            ]) ?? 0,
            emuleDownloadBytesPerSecond: statistic?.firstInteger([
                "emule_download_rate", "emule_download_speed", "emule_speed_download"
            ]) ?? 0,
            emuleUploadBytesPerSecond: statistic?.firstInteger([
                "emule_upload_rate", "emule_upload_speed", "emule_speed_upload"
            ]) ?? 0,
            defaultDestination: location?.firstString(["destination", "path", "default_destination"])
        )
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
        try await callVoid(api, method: "create", parameters: parameters)
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

        _ = try await callOfficialDownloadTaskV1FileCreate(
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
        try await callVoid(
            preferredDownloadTaskAPI(),
            method: action.rawValue,
            parameters: ["id": .string(ids.joined(separator: ","))]
        )
    }

    public func controlDownloadTaskResult(
        _ request: DownloadTaskControlRequest
    ) async throws -> DownloadTaskControlOutcome {
        guard let taskID = Self.nonEmpty(request.task.id) else {
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

    public func deleteDownloadTasks(ids: [String], removeData: Bool) async throws {
        let ids = try validatedIDs(ids)
        try await callVoid(
            preferredDownloadTaskAPI(),
            method: "delete",
            parameters: [
                "id": .string(ids.joined(separator: ",")),
                "force_complete": .boolean(removeData)
            ]
        )
        let remaining = try await loadDownloadStation().tasks.map(\.id)
        guard ids.allSatisfy({ !remaining.contains($0) }) else {
            throw verificationError(L10n.string("shared.7ca744fb7c598d20"))
        }
    }

    /// 下载任务删除通过任务列表逐项确认；删除任务和数据使用同一结果语义。
    public func deleteDownloadTasksResult(
        ids: [String],
        removeData: Bool
    ) async throws -> MutationResult {
        let api = preferredDownloadTaskAPI()
        return try await performServiceDeletion(
            ids: ids,
            context: ServiceDeletionContext(
                operation: "downloadTaskDelete",
                localizationPrefix: "download-task.delete"
            ),
            isSupported: capabilities[api]?.selectedVersion != nil,
            loadCurrentIDs: {
                Set(try await self.loadDownloadStation().tasks.map(\.id))
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

    public func loadContainerManager() async throws -> ContainerManagerSnapshot {
        async let containersValue = call(
            DsmAPIName.dockerContainer,
            method: "list",
            parameters: [
                "offset": .integer(0),
                "limit": .integer(-1),
                "type": .string("all")
            ]
        )
        async let imagesValue = supplementaryCall(DsmAPIName.dockerImage, method: "list")
        async let networksValue = supplementaryCall(DsmAPIName.dockerNetwork, method: "list")
        async let projectsValue = supplementaryCall(DsmAPIName.dockerProject, method: "list")
        async let eventsValue = supplementaryCall(
            DsmAPIName.dockerLog,
            method: "list",
            parameters: ["offset": .integer(0), "limit": .integer(200)]
        )
        let (containerJSON, imageJSON, networkJSON, projectJSON, eventJSON) =
            try await (containersValue, imagesValue, networksValue, projectsValue, eventsValue)

        return ContainerManagerSnapshot(
            containers: containerJSON.objects(for: ["containers", "container", "data", "list"])
                .compactMap(Self.container),
            images: imageJSON?.objects(for: ["images", "image", "data", "list"])
                .compactMap(Self.image) ?? [],
            networks: networkJSON?.objects(for: ["networks", "network", "data", "list"])
                .compactMap(Self.containerNetwork) ?? [],
            projects: projectJSON?.objects(for: ["projects", "project", "data", "list"])
                .compactMap(Self.project) ?? [],
            events: eventJSON?.objects(for: ["logs", "events", "data", "list"])
                .enumerated().map {
                    Self.event(offset: $0.offset, element: $0.element)
                } ?? []
        )
    }

    /// 移动端首个 Container Manager 闭环固定使用已记录的内部 Container.list v1。
    /// 只读取实例清单，不读取映像、网络、项目、事件、资源、进程或日志。
    public func loadContainerInventory() async throws -> ContainerInventorySnapshot {
        guard let capability = capabilities[DsmAPIName.dockerContainer],
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
        return ContainerInventorySnapshot(
            source: .internalAPI,
            containers: try Self.internalContainerV1Inventory(from: value)
        )
    }

    public func controlContainers(ids: [String], action: ContainerAction) async throws {
        let ids = try validatedIDs(ids)
        for id in ids {
            try await callVoid(
                DsmAPIName.dockerContainer,
                method: action.rawValue,
                parameters: ["id": .string(id)]
            )
        }
    }

    public func deleteContainers(ids: [String]) async throws {
        let ids = try validatedIDs(ids)
        for id in ids {
            try await callVoid(
                DsmAPIName.dockerContainer,
                method: "delete",
                parameters: ["id": .string(id)]
            )
        }
        let remaining = try await loadContainerManager().containers.map(\.id)
        guard ids.allSatisfy({ !remaining.contains($0) }) else {
            throw verificationError(L10n.string("shared.830e41a22a4f104d"))
        }
    }

    /// 容器删除使用内部接口；提交后通过容器列表逐项确认，未知结果不得自动重放。
    public func deleteContainersResult(ids: [String]) async throws -> MutationResult {
        let context = ServiceDeletionContext(
            operation: "containerDelete",
            localizationPrefix: "container.delete"
        )
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
        guard capabilities[DsmAPIName.dockerContainer]?.selectedVersion != nil else {
            return try deletionUnsupportedResult(
                targetCount: targets.count,
                context: context
            )
        }

        let targetSet = Set(targets)
        guard activeContainerDeletionIDs.isDisjoint(with: targetSet) else {
            return try deletionDuplicateResult(
                targetCount: targets.count,
                context: context
            )
        }
        activeContainerDeletionIDs.formUnion(targetSet)
        defer { activeContainerDeletionIDs.subtract(targetSet) }

        do {
            let currentIDs = Set(try await loadContainerManager().containers.map(\.id))
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

        for id in targets {
            if Task.isCancelled {
                return try deletionCancellationAfterSubmission(
                    targetCount: targets.count,
                    context: context
                )
            }
            do {
                try await callVoid(
                    DsmAPIName.dockerContainer,
                    method: "delete",
                    parameters: ["id": .string(id)]
                )
            } catch let error as AppError {
                return try deletionSubmissionResult(
                    error,
                    targetCount: targets.count,
                    context: context
                )
            } catch {
                return try deletionUnexpectedSubmissionResult(
                    targetCount: targets.count,
                    context: context
                )
            }
        }

        if Task.isCancelled {
            return try deletionCancellationAfterSubmission(
                targetCount: targets.count,
                context: context
            )
        }
        do {
            let remaining = Set(try await loadContainerManager().containers.map(\.id))
            return try deletionReadbackResult(
                targets: targetSet,
                remaining: remaining,
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

    public func searchContainerImages(query: String) async throws -> [ContainerRegistryImage] {
        let query = try validatedName(query, message: L10n.string("shared.7031852e2ed8042f"))
        let value = try await call(
            DsmAPIName.dockerRegistry,
            method: "search",
            parameters: [
                "offset": .integer(0),
                "limit": .integer(50),
                "page_size": .integer(50),
                "q": .string(query)
            ]
        )
        return value.objects(for: ["data", "items", "results"])
            .compactMap(Self.registryImage)
    }

    public func loadContainerImageTags(repository: String) async throws -> [String] {
        let repository = try validatedName(repository, message: L10n.string("shared.73537393048d9596"))
        let value = try await call(
            DsmAPIName.dockerRegistry,
            method: "tags",
            parameters: ["repo": .string(repository)]
        )
        return value.objects(for: ["data", "tags", "items"])
            .compactMap { ServiceJSON.object($0).firstString(["tag", "name"]) }
            .reduce(into: []) { result, tag in
                if !result.contains(tag) {
                    result.append(tag)
                }
            }
    }

    public func pullContainerImage(repository: String, tag: String) async throws {
        let repository = try validatedName(repository, message: L10n.string("shared.0c6ce91d30f67594"))
        let tag = try validatedName(tag, message: L10n.string("shared.6a2c72fe709bf1e8"))
        try await callVoid(
            DsmAPIName.dockerImage,
            method: "pull_start",
            parameters: ["repository": .string(repository), "tag": .string(tag)]
        )
    }

    public func deleteContainerImages(ids: [String]) async throws {
        let ids = try validatedIDs(ids)
        let currentIDs = Set(try await loadContainerManager().images.map(\.id))
        guard ids.allSatisfy(currentIDs.contains) else {
            throw validationError(L10n.string("shared.892f2476d57b950b"))
        }
        for id in ids {
            try await callVoid(
                DsmAPIName.dockerImage,
                method: "delete",
                parameters: ["id": .string(id)]
            )
        }
        let remaining = Set(try await loadContainerManager().images.map(\.id))
        guard ids.allSatisfy({ !remaining.contains($0) }) else {
            throw verificationError(L10n.string("shared.298bd4a069695e72"))
        }
    }

    /// 容器映像删除使用内部接口；提交后重新读取映像列表确认。
    public func deleteContainerImagesResult(ids: [String]) async throws -> MutationResult {
        try await performServiceDeletion(
            ids: ids,
            context: ServiceDeletionContext(
                operation: "containerImageDelete",
                localizationPrefix: "container-image.delete"
            ),
            isSupported: capabilities[DsmAPIName.dockerImage]?.selectedVersion != nil,
            loadCurrentIDs: {
                Set(try await self.loadContainerManager().images.map(\.id))
            },
            submit: { targets in
                for id in targets {
                    try await self.callVoid(
                        DsmAPIName.dockerImage,
                        method: "delete",
                        parameters: ["id": .string(id)]
                    )
                }
            }
        )
    }

    public func createContainerNetwork(name: String, driver: String) async throws {
        let name = try validatedName(name, message: L10n.string("shared.1750af3117ab4301"))
        let driver = try validatedName(driver, message: L10n.string("shared.a3a649e40dd55868"))
        try await callVoid(
            DsmAPIName.dockerNetwork,
            method: "create",
            parameters: ["name": .string(name), "driver": .string(driver)]
        )
        let networks = try await loadContainerManager().networks
        guard networks.contains(where: { $0.name == name }) else {
            throw verificationError(L10n.string("shared.ab9474d0616d3198"))
        }
    }

    public func deleteContainerNetworks(ids: [String]) async throws {
        let ids = try validatedIDs(ids)
        let currentIDs = Set(try await loadContainerManager().networks.map(\.id))
        guard ids.allSatisfy(currentIDs.contains) else {
            throw validationError(L10n.string("shared.d7cae8f9ca59d2d3"))
        }
        for id in ids {
            try await callVoid(
                DsmAPIName.dockerNetwork,
                method: "remove",
                parameters: ["id": .string(id)]
            )
        }
        let remaining = Set(try await loadContainerManager().networks.map(\.id))
        guard ids.allSatisfy({ !remaining.contains($0) }) else {
            throw verificationError(L10n.string("shared.3f7da50cab7bd49a"))
        }
    }

    /// 容器网络删除使用内部接口；提交后重新读取网络列表确认。
    public func deleteContainerNetworksResult(ids: [String]) async throws -> MutationResult {
        try await performServiceDeletion(
            ids: ids,
            context: ServiceDeletionContext(
                operation: "containerNetworkDelete",
                localizationPrefix: "container-network.delete"
            ),
            isSupported: capabilities[DsmAPIName.dockerNetwork]?.selectedVersion != nil,
            loadCurrentIDs: {
                Set(try await self.loadContainerManager().networks.map(\.id))
            },
            submit: { targets in
                for id in targets {
                    try await self.callVoid(
                        DsmAPIName.dockerNetwork,
                        method: "remove",
                        parameters: ["id": .string(id)]
                    )
                }
            }
        )
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
        let hostJSON = hostResult.value
        let storageJSON = storageResult.value
        let networkJSON = networkResult.value
        let imageJSON = imageResult.value
        let planJSON = planResult.value
        let eventJSON = eventResult.value
        var unavailableSections: Set<VirtualMachineManagerSection> = []
        if hostResult.isUnavailable { unavailableSections.insert(.hosts) }
        if storageResult.isUnavailable { unavailableSections.insert(.storages) }
        if networkResult.isUnavailable { unavailableSections.insert(.networks) }
        if imageResult.isUnavailable { unavailableSections.insert(.images) }
        if planResult.isUnavailable { unavailableSections.insert(.protection) }
        if eventResult.isUnavailable { unavailableSections.insert(.logs) }

        return VirtualMachineManagerSnapshot(
            source: official ? .official : .internalAPI,
            machines: guestJSON.objects(for: ["guests", "guest", "vms", "data", "list"])
                .compactMap(Self.machine),
            hosts: Self.resources(hostJSON, keys: ["hosts", "host", "data", "list"]),
            storages: Self.resources(storageJSON, keys: ["repos", "storages", "data", "list"]),
            networks: Self.resources(networkJSON, keys: ["networks", "network", "data", "list"]),
            images: Self.resources(imageJSON, keys: ["images", "image", "data", "list"]),
            protectionPlans: Self.resources(
                planJSON,
                keys: ["plans", "plan", "protection_plans", "guest_protects", "data", "list"]
            ),
            protectionSchedulePolicies: Self.resources(
                planJSON,
                keys: ["schedule_policies", "schedules", "schedule_policy"]
            ),
            protectionRetentionPolicies: Self.resources(
                planJSON,
                keys: ["retention_policies", "retentions", "retention_policy"]
            ),
            events: eventJSON?.objects(for: [
                "logs", "log", "events", "records", "entries", "items", "data", "list"
            ])
                .enumerated().map {
                    Self.event(offset: $0.offset, element: $0.element)
                } ?? [],
            unavailableSections: unavailableSections
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

    /// VMM 官方界面使用的内部创建契约；只有能力发现明确返回该接口时才启用。
    public func createVirtualMachine(_ configuration: VirtualMachineCreation) async throws {
        let name = try validatedName(configuration.name, message: L10n.string("shared.5350a51d42c2c339"))
        guard (1...64).contains(configuration.cpuCount) else {
            throw validationError(L10n.string("shared.f41be5e7aec143e3"))
        }
        guard (128...1_048_576).contains(configuration.memoryMiB) else {
            throw validationError(L10n.string("shared.4d40041e1ad34be1"))
        }
        guard (1...1_048_576).contains(configuration.diskGiB) else {
            throw validationError(L10n.string("shared.2b4d322a593abfbb"))
        }
        let storageID = try validatedName(
            configuration.storageID,
            message: L10n.string("shared.90d0c55da0db0537")
        )
        let networkID = try validatedName(
            configuration.networkID,
            message: L10n.string("shared.2b03964bdff5a681")
        )
        guard capabilities[DsmAPIName.virtualizationGuest]?.selectedVersion != nil else {
            throw unavailableError()
        }
        let snapshot = try await loadVirtualMachineManager()
        guard !snapshot.machines.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw validationError(L10n.string("shared.433935ad21c1d3da"))
        }
        guard let storage = snapshot.storages.first(where: { $0.id == storageID }) else {
            throw validationError(L10n.string("shared.893d2afe816fc362"))
        }
        guard let hostID = Self.nonEmpty(storage.hostID),
              let hostName = Self.nonEmpty(storage.hostName) else {
            throw unavailableError()
        }
        guard snapshot.networks.contains(where: { $0.id == networkID }) else {
            throw validationError(L10n.string("shared.6f6895462cc6e8ed"))
        }
        if let imageID = configuration.bootImageID,
           !imageID.isEmpty,
           !snapshot.images.contains(where: { $0.id == imageID }) {
            throw validationError(L10n.string("shared.015a36c415279fb5"))
        }

        let isWindows = configuration.operatingSystem == .windows
        let usesUEFI = configuration.firmware == .uefi
        let bootImages = [configuration.bootImageID ?? "", ""]
        let disk: [String: DsmJSONValue] = [
            "type": .string("add"),
            "vdisk_mode": .integer(1),
            "name": .string(L10n.string("shared.41781e3b2a5ef2db")),
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
            "vnic_type": .integer(1),
            "type": .string("add"),
            "mac": .string(Self.randomVirtualMACAddress()),
            "network_id": .string(networkID)
        ]
        var parameters: [String: DsmParameterValue] = [
            "guest_privilege": .objectArray([]),
            "iso_images": .stringArray(bootImages),
            "autorun": .integer(configuration.autoStart ? 1 : 0),
            "boot_from": .string(configuration.bootImageID == nil ? "disk" : "iso"),
            "bios": .string(usesUEFI ? "uefi" : "legacy"),
            "kb_layout": .string("Default"),
            "usb_version": .integer(0),
            "usbs": .stringArray(["", "", "", ""]),
            "is_windows_vm": .boolean(isWindows),
            "use_ovmf": .boolean(usesUEFI),
            "vnics": .objectArray([network]),
            "is_general_vm": .boolean(true),
            "increaseAllocatedSize": .integer(configuration.diskGiB),
            "vdisks": .objectArray([disk]),
            "auto_switch": .integer(0),
            "vdisk_struct": .objectArray([]),
            "name": .string(name),
            "vcpu_num": .integer(configuration.cpuCount),
            "vram_size": .integer(configuration.memoryMiB),
            "video_card": .string(isWindows ? "vga" : "vmvga"),
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
            "synovmm_ui_id": .string(UUID().uuidString.lowercased())
        ]
        if let allocated = storage.allocatedBytes {
            parameters["allocated_size"] = .string(String(allocated))
        }
        if let capacity = storage.capacityBytes {
            parameters["size"] = .string(String(capacity))
        }

        try await callVoid(
            DsmAPIName.virtualizationGuest,
            method: "create",
            parameters: parameters
        )
        let updated = try await loadVirtualMachineManager()
        guard updated.machines.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            throw verificationError(L10n.string("shared.9d66b1d56aebefdb"))
        }
    }

    /// VMM 官方界面使用的内部修改契约；运行中的虚拟机只提交允许在线调整的字段。
    public func updateVirtualMachine(
        id: String,
        configuration: VirtualMachineUpdate
    ) async throws {
        let id = try validatedIDs([id])[0]
        guard capabilities[DsmAPIName.virtualizationGuest]?.selectedVersion != nil else {
            throw unavailableError()
        }
        let snapshot = try await loadVirtualMachineManager()
        guard let current = snapshot.machines.first(where: { $0.id == id }) else {
            throw validationError(L10n.string("shared.706d4bbb975fcdc6"))
        }
        var parameters: [String: DsmParameterValue] = [
            "guest_id": .string(id),
            "synovmm_ui_id": .string(UUID().uuidString.lowercased())
        ]
        if let name = configuration.name {
            let name = try validatedName(name, message: L10n.string("shared.5350a51d42c2c339"))
            guard !snapshot.machines.contains(where: {
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
            guard (1...512).contains(cpuWeight) else {
                throw validationError(L10n.string("shared.4f060f32743040c5"))
            }
            parameters["cpu_weight"] = .integer(cpuWeight)
        }
        if let autoStart = configuration.autoStart {
            parameters["autorun"] = .integer(autoStart ? 1 : 0)
        }

        let isRunning = Self.isVirtualMachineRunning(current.status)
        if configuration.cpuCount != nil || configuration.memoryMiB != nil {
            guard !isRunning else {
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

        try await callVoid(
            DsmAPIName.virtualizationGuest,
            method: "set",
            parameters: parameters
        )
        let updated = try await loadVirtualMachineManager()
        guard let verified = updated.machines.first(where: { $0.id == id }),
              configuration.name.map({ verified.name == $0 }) ?? true,
              configuration.cpuCount.map({ verified.cpuCount == $0 }) ?? true,
              configuration.memoryMiB.map({
                  verified.memoryBytes == Int64($0) * 1_024 * 1_024
              }) ?? true else {
            throw verificationError(L10n.string("shared.f7c1562e7a9e3cd8"))
        }
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

    public func controlVirtualMachines(
        ids: [String],
        action: VirtualMachinePowerAction
    ) async throws {
        let ids = try validatedIDs(ids)
        if capabilities[DsmAPIName.virtualizationAPIGuestAction]?.selectedVersion != nil {
            let method: String = switch action {
            case .powerOn: "poweron"
            case .shutdown: "shutdown"
            case .powerOff: "poweroff"
            case .restart: "reboot"
            }
            try await callVoid(
                DsmAPIName.virtualizationAPIGuestAction,
                method: method,
                parameters: ["guest_id": .string(ids.joined(separator: ","))]
            )
        } else {
            let command: String = switch action {
            case .powerOn: "on"
            case .shutdown: "shutdown"
            case .powerOff: "off"
            case .restart: "reboot"
            }
            for id in ids {
                try await callVoid(
                    DsmAPIName.virtualizationGuestAction,
                    method: "pwr_ctl",
                    parameters: ["guest_id": .string(id), "action": .string(command)]
                )
            }
        }
    }

    public func deleteVirtualMachines(ids: [String]) async throws {
        let ids = try validatedIDs(ids)
        let api = capabilities[DsmAPIName.virtualizationAPIGuest]?.selectedVersion != nil
            ? DsmAPIName.virtualizationAPIGuest
            : DsmAPIName.virtualizationGuest
        try await callVoid(
            api,
            method: "delete",
            parameters: ["guest_id": .string(ids.joined(separator: ","))]
        )
        let remaining = try await loadVirtualMachineManager().machines.map(\.id)
        guard ids.allSatisfy({ !remaining.contains($0) }) else {
            throw verificationError(L10n.string("shared.bf17ba5ccdef0c83"))
        }
    }

    /// 虚拟机删除优先使用公开 API；提交后通过虚拟机列表逐项确认，未知结果不得自动重放。
    public func deleteVirtualMachinesResult(ids: [String]) async throws -> MutationResult {
        let context = ServiceDeletionContext(
            operation: "virtualMachineDelete",
            localizationPrefix: "virtual-machine.delete"
        )
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
        let api = capabilities[DsmAPIName.virtualizationAPIGuest]?.selectedVersion != nil
            ? DsmAPIName.virtualizationAPIGuest
            : DsmAPIName.virtualizationGuest
        guard capabilities[api]?.selectedVersion != nil else {
            return try deletionUnsupportedResult(
                targetCount: targets.count,
                context: context
            )
        }

        let targetSet = Set(targets)
        guard activeVirtualMachineDeletionIDs.isDisjoint(with: targetSet) else {
            return try deletionDuplicateResult(
                targetCount: targets.count,
                context: context
            )
        }
        activeVirtualMachineDeletionIDs.formUnion(targetSet)
        defer { activeVirtualMachineDeletionIDs.subtract(targetSet) }

        do {
            let currentIDs = Set(try await loadVirtualMachineManager().machines.map(\.id))
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
            try await callVoid(
                api,
                method: "delete",
                parameters: ["guest_id": .string(targets.joined(separator: ","))]
            )
        } catch let error as AppError {
            return try deletionSubmissionResult(
                error,
                targetCount: targets.count,
                context: context
            )
        } catch {
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
            let remaining = Set(try await loadVirtualMachineManager().machines.map(\.id))
            return try deletionReadbackResult(
                targets: targetSet,
                remaining: remaining,
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

    /// VMM 网页端网络修改使用的内部接口；公开 API 仅支持读取。
    public func updateVirtualMachineNetwork(
        id: String,
        configuration: VirtualMachineNetworkUpdate
    ) async throws {
        guard capabilities[DsmAPIName.virtualizationNetwork]?.selectedVersion != nil else {
            throw unavailableError()
        }
        let id = try validatedName(id, message: L10n.string("shared.ca7aaa6738684c9c"))
        let name = try validatedName(configuration.name, message: L10n.string("shared.1750af3117ab4301"))
        let current = try await loadVirtualMachineManager()
        guard current.networks.contains(where: { $0.id == id }) else {
            throw validationError(L10n.string("shared.27a4ede65c142b84"))
        }
        guard !current.networks.contains(where: {
            $0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) else {
            throw validationError(L10n.string("shared.ec86275315f695af"))
        }

        try await callVoid(
            DsmAPIName.virtualizationNetwork,
            method: "set",
            parameters: [
                "network_id": .string(id),
                "name": .string(name)
            ]
        )
        let updated = try await loadVirtualMachineManager()
        guard updated.networks.contains(where: { $0.id == id && $0.name == name }) else {
            throw verificationError(L10n.string("shared.35129033ee98c3ee"))
        }
    }

    /// VMM 网页端网络删除使用的内部接口；删除前由界面确认，提交后回读校验。
    public func deleteVirtualMachineNetworks(ids: [String]) async throws {
        guard capabilities[DsmAPIName.virtualizationNetwork]?.selectedVersion != nil else {
            throw unavailableError()
        }
        let ids = try validatedIDs(ids)
        let currentIDs = Set(try await loadVirtualMachineManager().networks.map(\.id))
        guard ids.allSatisfy(currentIDs.contains) else {
            throw validationError(L10n.string("shared.d7cae8f9ca59d2d3"))
        }
        for id in ids {
            try await callVoid(
                DsmAPIName.virtualizationNetwork,
                method: "delete",
                parameters: ["network_id": .string(id)]
            )
        }
        let remaining = Set(try await loadVirtualMachineManager().networks.map(\.id))
        guard ids.allSatisfy({ !remaining.contains($0) }) else {
            throw verificationError(L10n.string("shared.3f7da50cab7bd49a"))
        }
    }

    /// VMM 网络删除使用内部接口；提交后通过网络列表逐项确认。
    public func deleteVirtualMachineNetworksResult(ids: [String]) async throws -> MutationResult {
        try await performServiceDeletion(
            ids: ids,
            context: ServiceDeletionContext(
                operation: "virtualMachineNetworkDelete",
                localizationPrefix: "virtual-machine-network.delete"
            ),
            isSupported: capabilities[DsmAPIName.virtualizationNetwork]?.selectedVersion != nil,
            loadCurrentIDs: {
                Set(try await self.loadVirtualMachineManager().networks.map(\.id))
            },
            submit: { targets in
                for id in targets {
                    try await self.callVoid(
                        DsmAPIName.virtualizationNetwork,
                        method: "delete",
                        parameters: ["network_id": .string(id)]
                    )
                }
            }
        )
    }

    /// 映像删除优先使用公开 VMM API；内部分支只在公开能力缺失时启用。
    public func deleteVirtualMachineImages(ids: [String]) async throws {
        let ids = try validatedIDs(ids)
        let api = capabilities[DsmAPIName.virtualizationAPIGuestImage]?.selectedVersion != nil
            ? DsmAPIName.virtualizationAPIGuestImage
            : DsmAPIName.virtualizationGuestImage
        guard capabilities[api]?.selectedVersion != nil else {
            throw unavailableError()
        }
        let currentIDs = Set(try await loadVirtualMachineManager().images.map(\.id))
        guard ids.allSatisfy(currentIDs.contains) else {
            throw validationError(L10n.string("shared.892f2476d57b950b"))
        }
        for id in ids {
            if api == DsmAPIName.virtualizationAPIGuestImage {
                let result = try await call(
                    api,
                    method: "delete",
                    parameters: ["image_id": .string(id)]
                )
                if let taskID = result.firstString(["task_id", "task", "id"]) {
                    try await waitForVirtualizationTask(id: taskID)
                }
            } else {
                try await callVoid(
                    api,
                    method: "delete",
                    parameters: ["image_id": .string(id)]
                )
            }
        }
        let remaining = Set(try await loadVirtualMachineManager().images.map(\.id))
        guard ids.allSatisfy({ !remaining.contains($0) }) else {
            throw verificationError(L10n.string("shared.298bd4a069695e72"))
        }
    }

    /// VMM 映像删除优先使用公开 API；任务提交后仍以映像列表为最终依据。
    public func deleteVirtualMachineImagesResult(ids: [String]) async throws -> MutationResult {
        let api = capabilities[DsmAPIName.virtualizationAPIGuestImage]?.selectedVersion != nil
            ? DsmAPIName.virtualizationAPIGuestImage
            : DsmAPIName.virtualizationGuestImage
        return try await performServiceDeletion(
            ids: ids,
            context: ServiceDeletionContext(
                operation: "virtualMachineImageDelete",
                localizationPrefix: "virtual-machine-image.delete"
            ),
            isSupported: capabilities[api]?.selectedVersion != nil,
            loadCurrentIDs: {
                Set(try await self.loadVirtualMachineManager().images.map(\.id))
            },
            submit: { targets in
                for id in targets {
                    if api == DsmAPIName.virtualizationAPIGuestImage {
                        let result = try await self.call(
                            api,
                            method: "delete",
                            parameters: ["image_id": .string(id)]
                        )
                        if let taskID = result.firstString(["task_id", "task", "id"]) {
                            try await self.waitForVirtualizationTask(id: taskID)
                        }
                    } else {
                        try await self.callVoid(
                            api,
                            method: "delete",
                            parameters: ["image_id": .string(id)]
                        )
                    }
                }
            }
        )
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

    private func waitForVirtualizationTask(id: String) async throws {
        guard capabilities[DsmAPIName.virtualizationAPITaskInfo]?.selectedVersion != nil else {
            return
        }
        for _ in 0..<60 {
            let value = try await call(
                DsmAPIName.virtualizationAPITaskInfo,
                method: "get",
                parameters: ["task_id": .string(id)]
            )
            let status = value.firstString(["status", "state", "task_status"])?
                .lowercased() ?? ""
            if ["finished", "completed", "success", "succeeded", "done"].contains(status) {
                return
            }
            if ["failed", "error", "cancelled", "canceled"].contains(status) {
                throw verificationError(L10n.string("shared.71f5972b6a39b58a"))
            }
            try await Task.sleep(for: .seconds(1))
        }
        throw verificationError(L10n.string("shared.fad38b1708c3a0f5"))
    }

    private func preferredDownloadTaskAPI() -> String {
        capabilities[DsmAPIName.downloadStationTask]?.selectedVersion != nil
            ? DsmAPIName.downloadStationTask
            : DsmAPIName.downloadStation2Task
    }

    private func officialDownloadTaskV1Capability() -> ApiCapability? {
        guard let capability = capabilities[DsmAPIName.downloadStationTask],
              capability.selectedVersion != nil,
              capability.minVersion <= 1,
              capability.maxVersion >= 1,
              capability.requestFormat == .form else {
            return nil
        }
        return capability
    }

    private func callOfficialDownloadTaskV1(
        method: String,
        parameters: [String: DsmParameterValue]
    ) async throws -> ServiceJSON {
        guard let capability = officialDownloadTaskV1Capability() else {
            throw unavailableError()
        }
        do {
            return try await client.call(
                path: capability.path,
                api: capability.name,
                version: 1,
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

    private func callOfficialDownloadTaskV1FileCreate(
        fileURL: URL,
        destination: String?,
        unzipPassword: String?
    ) async throws -> ServiceJSON {
        guard let capability = officialDownloadTaskV1Capability(),
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
        if let destination = Self.nonEmpty(destination) {
            multipartFields["destination"] = destination
        }
        if let unzipPassword = Self.nonEmpty(unzipPassword) {
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
            URLQueryItem(name: "version", value: "1"),
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

        let response = try await binaryTransport.upload(request, from: bodyURL) { _, _ in }
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
        guard envelope.firstBoolean(["success"]) == true else {
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
        let normalizedDestination = Self.nonEmpty(request.destination)
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
            key: DownloadTaskCreateKey(
                digest: Self.downloadCreateDigest(
                    kind: "uri",
                    values: [normalizedURI, normalizedDestination ?? ""]
                )
            ),
            source: .uri(normalizedURI),
            destination: normalizedDestination
        ))
    }

    private static func validatedDownloadFileCreateRequest(
        _ request: DownloadTaskFileCreateRequest
    ) throws -> DownloadTaskCreateValidation {
        let normalizedURL = request.fileURL.standardizedFileURL
        let normalizedDestination = Self.nonEmpty(request.destination)
        let normalizedPassword = Self.nonEmpty(request.unzipPassword)
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
            return .success(PreparedDownloadTaskCreateRequest(
                key: DownloadTaskCreateKey(
                    digest: Self.downloadCreateDigest(
                        kind: "file",
                        values: [
                            normalizedURL.lastPathComponent,
                            String(values.fileSize ?? 0),
                            normalizedDestination ?? "",
                            normalizedPassword ?? ""
                        ]
                    )
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
        _ request: PreparedDownloadTaskCreateRequest
    ) async throws -> DownloadTaskCreateOutcome {
        guard officialDownloadTaskV1Capability() != nil else {
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

        let response: ServiceJSON
        do {
            response = try await submitDownloadTaskCreate(request)
        } catch let error as AppError where error.category == .permissionDenied {
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
            return try await callOfficialDownloadTaskV1(
                method: "create",
                parameters: parameters
            )
        case .file(let fileURL, let unzipPassword):
            return try await callOfficialDownloadTaskV1FileCreate(
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

        while offset < Self.downloadControlReadbackLimit {
            let limit = min(
                Self.downloadControlPageSize,
                Self.downloadControlReadbackLimit - offset
            )
            let value = try await callOfficialDownloadTaskV1(
                method: "list",
                parameters: [
                    "offset": .integer(offset),
                    "limit": .integer(limit),
                    "additional": .stringArray(["detail", "transfer"])
                ]
            )
            let objects = value.objects(for: ["tasks", "task", "items", "list"])
            let pageTasks = objects.compactMap(Self.downloadTask)
            guard pageTasks.count == objects.count, pageTasks.count <= limit else {
                throw invalidServiceResponse()
            }
            if let pageOffset = value.firstInteger(["offset"]),
               pageOffset != Int64(offset) {
                throw invalidServiceResponse()
            }
            if let totalValue = value.firstInteger(["total"]) {
                let total = Int(totalValue)
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
            if let expectedTotal, offset + pageTasks.count >= expectedTotal {
                break
            }
            if pageTasks.count < limit {
                break
            }
            guard !pageTasks.isEmpty else {
                throw invalidServiceResponse()
            }
            offset += pageTasks.count
        }
        return tasks
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
        tag: String
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
            task: task
        )
    }

    private func loadOfficialDownloadControlTask(id taskID: String) async throws -> DownloadStationTask? {
        var offset = 0
        var expectedTotal: Int?
        var found: DownloadStationTask?
        var seenIDs: Set<String> = []

        while offset < Self.downloadControlReadbackLimit {
            let limit = min(
                Self.downloadControlPageSize,
                Self.downloadControlReadbackLimit - offset
            )
            let value = try await callOfficialDownloadTaskV1(
                method: "list",
                parameters: [
                    "offset": .integer(offset),
                    "limit": .integer(limit),
                    "additional": .stringArray(["detail", "transfer"])
                ]
            )
            let objects = value.objects(for: ["tasks", "task", "items", "list"])
            let tasks = objects.compactMap(Self.downloadTask)
            guard tasks.count == objects.count, tasks.count <= limit else {
                throw invalidServiceResponse()
            }
            if let pageOffset = value.firstInteger(["offset"]),
               pageOffset != Int64(offset) {
                throw invalidServiceResponse()
            }
            if let totalValue = value.firstInteger(["total"]) {
                let total = Int(totalValue)
                guard total >= offset + tasks.count else {
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

            for task in tasks {
                guard seenIDs.insert(task.id).inserted else {
                    throw invalidServiceResponse()
                }
                if task.id == taskID {
                    guard found == nil else {
                        throw invalidServiceResponse()
                    }
                    found = task
                }
            }

            if let expectedTotal, offset + tasks.count >= expectedTotal {
                break
            }
            if tasks.count < limit {
                break
            }
            guard !tasks.isEmpty else {
                throw invalidServiceResponse()
            }
            offset += tasks.count
        }
        return found
    }

    private func finishDownloadControlReview(
        key: DownloadTaskControlKey,
        action: DownloadStationTaskAction,
        statusIfUnconfirmed: MutationResultStatus
    ) async throws -> DownloadTaskControlOutcome {
        do {
            if let task = try await loadOfficialDownloadControlTask(id: key.taskID),
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
                "seeding"
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
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw AppError(
                category: .localStorageFull,
                isRetryable: false,
                safeUserMessage: L10n.string("shared.25e1b230ae17e73b")
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: bodyURL.path
        )

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
        return .unavailable
    }

    private func call(
        _ name: String,
        method: String,
        parameters: [String: DsmParameterValue] = [:]
    ) async throws -> ServiceJSON {
        guard let capability = capabilities[name],
              let version = capability.selectedVersion else {
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
                as: ServiceJSON.self
            )
        } catch let error as DsmNetworkError {
            throw DsmErrorMapper.map(error)
        }
    }

    private func callVoid(
        _ name: String,
        method: String,
        parameters: [String: DsmParameterValue]
    ) async throws {
        guard let capability = capabilities[name],
              let version = capability.selectedVersion else {
            throw unavailableError()
        }
        do {
            try await client.callVoid(
                path: capability.path,
                api: capability.name,
                version: version,
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
        return ContainerInstance(
            id: id,
            name: value.firstString(["name", "Names"]) ?? String(id.prefix(12)),
            image: value.firstString(["image", "image_name", "Image"]) ?? "—",
            project: value.firstString(["project", "project_name"]),
            status: value.firstString(["status", "state", "State"]) ?? "unknown",
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
            safeUserMessage: L10n.string("shared.847fe982ab6f5ef7")
        )
    }

    private static func image(_ object: [String: ServiceJSON]) -> ContainerImage? {
        let value = ServiceJSON.object(object)
        guard let id = value.firstString(["id", "image_id", "Id"]) else { return nil }
        let repository = value.firstString(["repository", "repo", "name", "RepoTags"]) ?? "—"
        return ContainerImage(
            id: id,
            repository: repository,
            tag: value.firstString(["tag"]) ?? "latest",
            sizeBytes: value.firstInteger(["size", "virtual_size", "Size"]),
            createdAt: date(value, keys: ["created", "created_at", "Created"]),
            isInUse: value.firstBoolean(["in_use", "is_used", "using"]) ?? false
        )
    }

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
        return ContainerNetwork(
            id: id,
            name: value.firstString(["name", "Name"]) ?? String(id.prefix(12)),
            driver: value.firstString(["driver", "Driver", "type"]) ?? "—",
            connectedContainerCount: Int(value.firstInteger([
                "container_count", "containers_count", "using"
            ]) ?? 0)
        )
    }

    private static func project(_ object: [String: ServiceJSON]) -> ContainerProject? {
        let value = ServiceJSON.object(object)
        guard let name = value.firstString(["name", "project_name", "id"]) else { return nil }
        return ContainerProject(
            id: value.firstString(["id", "project_id"]) ?? name,
            name: name,
            status: value.firstString(["status", "state"]) ?? "unknown",
            containerCount: Int(value.firstInteger(["container_count", "services"]) ?? 0)
        )
    }

    private static func machine(_ object: [String: ServiceJSON]) -> VirtualMachine? {
        let value = ServiceJSON.object(object)
        guard let id = value.firstString(["guest_id", "id", "vm_id"]) else { return nil }
        let memoryBytes = value.firstInteger(["memory", "memory_size", "ram"])
            ?? value.firstInteger(["vram_size"]).map { $0 * 1_024 * 1_024 }
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
            autoStart: value.firstBoolean(["autorun", "auto_start"]) ?? false,
            cpuWeight: value.firstInteger(["cpu_weight"]).map(Int.init)
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
                  let autoStart = officialBoolean(object["autorun"]),
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
                autoStart: autoStart
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

    private static func officialBoolean(_ node: ServiceJSON?) -> Bool? {
        switch node {
        case .boolean(let value): return value
        case .number(0): return false
        case .number(1): return true
        default: return nil
        }
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

    private static func resources(
        _ value: ServiceJSON?,
        keys: [String]
    ) -> [VirtualizationResource] {
        value?.objects(for: keys).compactMap { object in
            let value = ServiceJSON.object(object)
            guard let name = value.firstString([
                "name", "host_name", "storage_name", "repo_name",
                "network_name", "image_name", "plan_name", "policy_name", "title", "id"
            ]) else {
                return nil
            }
            return VirtualizationResource(
                id: value.firstString([
                    "id", "storage_id", "repo_id", "network_id", "image_id", "host_id"
                ])
                    ?? name,
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
        } ?? []
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
}
