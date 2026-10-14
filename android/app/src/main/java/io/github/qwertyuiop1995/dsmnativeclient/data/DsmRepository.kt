package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.nas.supportedHardwareFanModes
import io.github.qwertyuiop1995.dsmnativeclient.data.container.ContainerRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAccessState
import io.github.qwertyuiop1995.dsmnativeclient.data.container.ContainerRepositoryGateway
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.DsmChatRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.chat.DsmChatRepositoryGateway
import io.github.qwertyuiop1995.dsmnativeclient.data.downloads.DownloadStationRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.downloads.DownloadStationRepositoryGateway
import io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileStationRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileStationRepositoryGateway
import io.github.qwertyuiop1995.dsmnativeclient.data.files.isFileMutationPath
import io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileSharingRepository
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileShareCreateRequest
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileShareEditRequest
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileSharePrincipalPage
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.DsmNasAdministrationRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.normalized
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.isSafeDdnsProviderId
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.isValidDdnsHostname
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.isValidDdnsReadableFields
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.isSafeEthernetId
import io.github.qwertyuiop1995.dsmnativeclient.data.nas.DsmNasAdministrationRepositoryGateway
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.DsmVirtualMachineRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.consoleKeyboard
import io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.DsmVirtualMachineRepositoryGateway
import io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveCompressionLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveFormat
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveItemPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileExtractionOptions
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileExtractionRequest
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileArchiveSelection
import io.github.qwertyuiop1995.dsmnativeclient.data.files.FileArchiveReader
import io.github.qwertyuiop1995.dsmnativeclient.data.files.extractionOutputs
import io.github.qwertyuiop1995.dsmnativeclient.domain.CapacitySummary
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerRegistryImage
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationAction
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationBaseline
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssSite
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssFeed
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchCatalog
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchOptions
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadStationActivity
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationExpectedOutput
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileShareLink
import io.github.qwertyuiop1995.dsmnativeclient.domain.FavoriteLocation
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.FilePreviewContent
import io.github.qwertyuiop1995.dsmnativeclient.domain.previewKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.RandomAccessMediaSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogEntry
import io.github.qwertyuiop1995.dsmnativeclient.domain.LogLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResource
import io.github.qwertyuiop1995.dsmnativeclient.domain.ManagedResourceLabel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsArea
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDirectory
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRemoteAccessSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDoSProtectionSetting
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasHardwareSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasUpsSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDiskTestType
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasStorageDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSystemUpdateInfo
import io.github.qwertyuiop1995.dsmnativeclient.domain.PackageInfo
import io.github.qwertyuiop1995.dsmnativeclient.domain.PerformanceSample
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.domain.RecycleLocation
import io.github.qwertyuiop1995.dsmnativeclient.domain.SystemSummary
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisOwner
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisProgress
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisShare
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageAnalysisSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageDuplicateGroup
import io.github.qwertyuiop1995.dsmnativeclient.domain.StorageFileCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageImportVerification
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageType
import io.github.qwertyuiop1995.dsmnativeclient.domain.isEligibleForVirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineDiskController
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineHardware
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineNetworkInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineNetworkModel
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineGuestDetails
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineTaskCenterState
import io.github.qwertyuiop1995.dsmnativeclient.network.DsmApiClient
import io.github.qwertyuiop1995.dsmnativeclient.network.isTrustedQuickConnectRelayHost
import io.github.qwertyuiop1995.dsmnativeclient.network.ChatRealtimeClient
import io.github.qwertyuiop1995.dsmnativeclient.network.arrayValue
import io.github.qwertyuiop1995.dsmnativeclient.network.int
import io.github.qwertyuiop1995.dsmnativeclient.network.long
import io.github.qwertyuiop1995.dsmnativeclient.network.objectValue
import io.github.qwertyuiop1995.dsmnativeclient.network.string
import java.util.UUID
import java.util.Locale
import java.io.ByteArrayInputStream
import java.io.File
import java.io.OutputStream
import java.net.URI
import java.security.MessageDigest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.longOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.coroutines.delay
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock

data class ShareLinkMutationOutcome(
    val result: MutationResult,
    val link: FileShareLink? = null,
)

/**
 * File Station 没有为普通文件公开独立稳定 ID，写入前用用户已看到的路径与关键属性
 * 再读取一次，避免路径已被替换或权限已变化时继续提交。
 * 目录大小和时间会因无关子项变化而自然漂移，不参与目录身份判断。
 */
internal fun FileItem.matchesMutationBaseline(baseline: FileItem): Boolean =
    path == baseline.path && name == baseline.name && isDirectory == baseline.isDirectory &&
        owner == baseline.owner && canRead == baseline.canRead && canWrite == baseline.canWrite &&
        canDelete == baseline.canDelete && mountPointType == baseline.mountPointType && (isDirectory ||
        size == baseline.size && modifiedAtEpochSeconds == baseline.modifiedAtEpochSeconds)

/** 写后移动结果只比较跨目录后仍应保持的内容属性，不把 ACL 继承变化误判为移动失败。 */
private fun FileItem.matchesMutationOutcome(baseline: FileItem, expectedPath: String): Boolean =
    path == expectedPath && name == expectedPath.substringAfterLast('/') &&
        isDirectory == baseline.isDirectory &&
        (isDirectory || size == baseline.size &&
            modifiedAtEpochSeconds == baseline.modifiedAtEpochSeconds)

data class TextSaveMutationOutcome(
    val result: MutationResult,
    val content: FilePreviewContent.Text? = null,
)

class DsmRepository internal constructor(
    private val profile: NasProfile,
    private val session: DsmSession,
    api: DsmApiClient,
    private val capabilities: Map<String, ApiCapability>,
    accessReader: WorkspaceAccessReader? = null,
) : SynologyPhotosProvider {
    private val workspaceAccess = WorkspaceRepositoryAccess(profile, session, api, capabilities, accessReader)
    internal val owner get() = workspaceAccess.owner
    internal val accessFailures get() = workspaceAccess.failures
    private val authorizedApi = workspaceAccess.transport
    override val synologyPhotos: SynologyPhotosRepository by lazy {
        SynologyPhotosRepository(profile, session, authorizedApi, capabilities)
    }
    private val capabilityResolver = DsmRepositoryCapabilityResolver(capabilities)
    private val requestBuilder = DsmRepositoryRequestBuilder(
        profile = profile,
        session = session,
        api = authorizedApi,
        capabilities = capabilityResolver,
    )
    private val mutationVerifier = DsmRepositoryMutationVerifier()

    private val nasManagementGateway = io.github.qwertyuiop1995.dsmnativeclient.data.nas.DsmNasPackageGateway(
        profile, session, authorizedApi, capabilities, refreshAccess = {
            refreshAccess()
            if (workspaceAccess.availability().single { it.module == Module.NAS_SETTINGS }.access != ModuleAccessState.ALLOWED)
                throw DsmFailure(null, "NAS management access unavailable", "Ask the NAS administrator for access.", kind = DsmErrorKind.PERMISSION_DENIED)
        })
    internal val nasServices = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasServiceSettingsRepository(nasManagementGateway, ::supportsVersion,
        remoteContext = { resolvedProfileUsesTrustedRelay() to (workspaceAccess.availability().single { it.module == Module.NAS_SETTINGS }.access == ModuleAccessState.ALLOWED) },
        ethernetReader = { ethernetInterfaceDetail(it) }, securityReader = { securitySettings() }, hardwareReader = { hardwareSettings() })
    internal val nasAccountDigest get() = io.github.qwertyuiop1995.dsmnativeclient.nas.packageDigest(profile.username.trim())
    internal val nasSmart = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasSmartTestRepository(nasManagementGateway, ::supportsVersion,
        ::strictStorageDisks, ::strictDiskTestStatus, ::strictDiskTestHistory)
    internal val nasConnections = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasConnectionRepository(nasManagementGateway, ::supportsVersion)
    internal val nasPower = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasPowerActionRepository(nasManagementGateway, ::supportsVersion)
    internal val nasPowerSessionDigest get(): String {
        requireCurrentOwner()
        if (session.sid.isBlank()) throw DsmFailure(null, "Sign in again", "Sign in to use power actions.", kind = DsmErrorKind.SESSION_EXPIRED)
        return io.github.qwertyuiop1995.dsmnativeclient.nas.packageDigest(session.sid)
    }
    internal val nasDdns = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasDdnsRepository(nasManagementGateway, ::supportsVersion, ::ddnsDirectory)
    internal val nasRegion = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasRegionSettingsRepository(nasManagementGateway, ::supportsVersion)
    internal val nasObservation = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasObservationRepository(nasManagementGateway, ::supportsVersion)
    internal val packageCenter = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasPackageRepository(nasManagementGateway, ::supportsVersion, { strictPackageMutationList() })
    internal val directory = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasDirectoryRepository(nasManagementGateway, profile.username)
    internal val scheduledTasks = io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasScheduledTaskRepository(
        nasManagementGateway, profile.username, { supportsVersion("SYNO.Core.TaskScheduler", it) })

    fun chatRealtimeClient(
        onConnectionChanged: (Boolean) -> Unit,
        onContentChanged: () -> Unit,
    ): ChatRealtimeClient = ChatRealtimeClient(
        authorizedApi,
        profile,
        session,
        onConnectionChanged,
        onContentChanged,
    )

    private val favoriteMutationLock = Mutex()
    private val favoriteMutations = mutableSetOf<String>()
    private val filePathMutationLock = Mutex()
    private val activeFilePathMutations = mutableListOf<Set<String>>()
    private val shareLinkDeletionLock = Mutex()
    private val activeShareLinkDeletionIds = mutableSetOf<String>()
    private val downloadMutationLock = Mutex()
    private val activeDownloadMutationIds = mutableSetOf<String>()
    private val downloadCreationMutationLock = Mutex()
    private val activeDownloadCreationKeys = mutableSetOf<String>()
    private val downloadSettingsMutationLock = Mutex()
    private var downloadSettingsMutationActive = false
    private val serviceMutationLock = Mutex()
    private val activeServiceMutationTargets = mutableSetOf<String>()
    @Volatile private var currentChatUserId: String? = null

    private val containerRepository = ContainerRepository(object : ContainerRepositoryGateway {
        override suspend fun requireManagementWrite() {
            refreshAccess()
            if (workspaceAccess.availability().single { it.module == Module.CONTAINERS }.access != ModuleAccessState.ALLOWED) {
                throw DsmFailure(null, "Container access unavailable", "Refresh or sign in again.", kind = DsmErrorKind.PERMISSION_DENIED)
            }
        }
        override suspend fun managementCall(api: String, method: String, parameters: Map<String, JsonElement>, write: Boolean): JsonObject =
            nasManagementGateway.call(api, method, 1, parameters, write)
        override fun supports(apiName: String): Boolean = this@DsmRepository.supports(apiName)

        override fun supportsVersion(apiName: String, version: Int): Boolean =
            this@DsmRepository.supportsVersion(apiName, version)

        override suspend fun call(
            apiName: String,
            method: String,
            parameters: Map<String, String>,
            version: Int?,
        ): JsonObject = this@DsmRepository.call(apiName, method, parameters, version)

        override fun strictResources(
            data: JsonObject,
            vararg roots: String,
        ): List<ManagedResource> = this@DsmRepository.strictContainerResources(data, *roots)

        override fun elements(data: JsonObject, key: String): List<JsonElement> = data.elements(key)

        override fun firstNonBlank(data: JsonObject, vararg keys: String): String? =
            data.firstNonBlank(*keys)

        override fun bool(data: JsonObject, key: String): Boolean? = data.bool(key)

        override suspend fun resourceList(
            apiName: String,
            methods: List<String>,
            vararg roots: String,
        ): List<ManagedResource> = this@DsmRepository.resourceList(apiName, methods, *roots)

        override fun unsupportedMutation(operation: String, diagnosticTag: String): MutationResult =
            this@DsmRepository.unsupportedServiceMutation(operation, diagnosticTag)

        override fun mutationResult(
            operation: String,
            status: MutationResultStatus,
            submitted: Boolean,
            requiresRefresh: Boolean,
            errorCategory: MutationErrorCategory?,
            diagnosticTag: String,
            affectedCount: Int,
        ): MutationResult = this@DsmRepository.serviceMutationResult(
            operation = operation,
            status = status,
            submitted = submitted,
            requiresRefresh = requiresRefresh,
            errorCategory = errorCategory,
            diagnosticTag = diagnosticTag,
            affectedCount = affectedCount,
        )

        override suspend fun verifiedMutation(
            operation: String,
            targetKey: String,
            requiredApi: String,
            preflight: suspend () -> Boolean,
            submit: suspend () -> Unit,
            verify: suspend () -> Boolean,
        ): MutationResult = this@DsmRepository.verifiedServiceMutation(
            operation = operation,
            targetKey = targetKey,
            requiredApi = requiredApi,
            preflight = preflight,
            submit = submit,
            verify = verify,
        )

        override suspend fun deleteResourceResult(
            operation: String,
            targetType: String,
            id: String,
            apiName: String,
            root: String,
            method: String,
        ): MutationResult = this@DsmRepository.deleteServiceResourceResult(
            operation = operation,
            targetType = targetType,
            id = id,
            apiName = apiName,
            root = root,
            method = method,
        )
    })

    internal val virtualMachineManagement = io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmManagementRepository(
        object : io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmManagementGateway {
            override fun supports(api: String, version: Int) = supportsVersion(api, version)
            override suspend fun requireWrite(source: io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmSource) {
                refreshAccess()
                if (workspaceAccess.availability().single { it.module == Module.VIRTUAL_MACHINES }.access != ModuleAccessState.ALLOWED) {
                    throw DsmFailure(null, "Virtual machine access unavailable", "Refresh or sign in again.", kind = DsmErrorKind.PERMISSION_DENIED)
                }
            }
            override suspend fun call(api: String, method: String, version: Int, fields: Map<String, JsonElement>, write: Boolean) =
                nasManagementGateway.call(api, method, version, fields, write)
        },
    )

    internal val supportsVirtualMachineConsole get() = supportsVersion("SYNO.Virtualization.Guest", 2)

    internal suspend fun prepareVirtualMachineConsole(target: io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmControlTarget): io.github.qwertyuiop1995.dsmnativeclient.network.VmmConsoleSession {
        requireCurrentOwner()
        refreshAccess()
        if (workspaceAccess.availability().single { it.module == Module.VIRTUAL_MACHINES }.access != ModuleAccessState.ALLOWED) {
            throw DsmFailure(null, "Virtual machine access unavailable", "Refresh or sign in again.", kind = DsmErrorKind.PERMISSION_DENIED)
        }
        val keyboard = virtualMachineManagement.consoleKeyboard(target)
        requireCurrentOwner()
        val address = profile.address.trim().let { if ("://" in it) it else "https://$it" }
        val policy = io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.VmmConsolePolicy(address, target.id, target.name, keyboard, port = profile.port)
        return authorizedApi.virtualMachineConsole(policy, session)
    }

    private val virtualMachineRepository = DsmVirtualMachineRepository(
        object : DsmVirtualMachineRepositoryGateway {
            override fun preferred(vararg names: String): String =
                this@DsmRepository.preferred(*names)

            override fun preferredOrNull(vararg names: String): String? =
                this@DsmRepository.preferredOrNull(*names)

            override fun supports(apiName: String): Boolean = this@DsmRepository.supports(apiName)

            override fun supportsVersion(apiName: String, version: Int): Boolean =
                this@DsmRepository.supportsVersion(apiName, version)

            override suspend fun officialRead(): Pair<List<ManagedResource>, List<VirtualMachineHardware>?> {
                val read = this@DsmRepository.officialVirtualMachineRead()
                return read.machines to read.hardware
            }

            override suspend fun resourceList(
                apiName: String,
                methods: List<String>,
                vararg roots: String,
            ): List<ManagedResource> = this@DsmRepository.resourceList(apiName, methods, *roots)

            override suspend fun firstSuccessful(
                apiName: String,
                methods: List<String>,
            ): JsonObject = this@DsmRepository.firstSuccessful(apiName, methods)

            override fun genericResources(
                data: JsonObject,
                vararg roots: String,
            ): List<ManagedResource> = this@DsmRepository.genericResources(data, *roots)

            override suspend fun logs(): List<LogEntry> = this@DsmRepository.virtualizationLogs()

            override suspend fun taskCenter(): Pair<List<VirtualMachineTask>, VirtualMachineTaskCenterState> {
                val center = this@DsmRepository.virtualMachineTaskCenter()
                return center.tasks to center.state
            }
        },
    )

    private val nasAdministrationRepository = DsmNasAdministrationRepository(
        object : DsmNasAdministrationRepositoryGateway {
            override suspend fun systemRead(): JsonObject =
                this@DsmRepository.firstSuccessful("SYNO.Core.System", listOf("info", "get"))

            override suspend fun storageRead(): JsonObject = this@DsmRepository.firstSuccessful(
                "SYNO.Storage.CGI.Storage",
                listOf("load_info", "get"),
            )

            override suspend fun packages(): List<PackageInfo> =
                this@DsmRepository.packageList()

            override suspend fun accounts(): List<NasAccount> =
                this@DsmRepository.accountList()

            override suspend fun groups(): List<NasGroup> = this@DsmRepository.groupList()

            override suspend fun logsRead(): JsonObject = this@DsmRepository.firstSuccessful(
                this@DsmRepository.preferred("SYNO.LogCenter.History", "SYNO.Core.SyslogClient.Log"),
                listOf("list", "get"),
                mapOf("offset" to "0", "limit" to "200"),
            )

            override suspend fun connections(): List<ActiveConnection> =
                this@DsmRepository.connectionList()

            override suspend fun ethernetInterfaces(): List<NasEthernetInterface> =
                this@DsmRepository.ethernetInterfaces()

            override suspend fun ddnsDirectory(): NasDdnsDirectory =
                this@DsmRepository.ddnsDirectory()

            override suspend fun securitySettings(): NasSecuritySettings =
                this@DsmRepository.securitySettings()

            override suspend fun hardwareSettings(): NasHardwareSettings =
                this@DsmRepository.hardwareSettings()

            override suspend fun remoteAccessSettings(): NasRemoteAccessSettings =
                this@DsmRepository.remoteAccessSettings()

            override suspend fun scheduledTasks(): List<ManagedResource> =
                this@DsmRepository.resourceList(
                    "SYNO.Core.TaskScheduler",
                    listOf("list", "get"),
                    "tasks",
                )

            override suspend fun fileServiceSettings(): NasFileServiceSettings =
                this@DsmRepository.fileServiceSettings()

            override suspend fun terminalSettings(): NasTerminalSettings =
                this@DsmRepository.terminalSettings()

            override suspend fun proxySettings(): NasProxySettings =
                this@DsmRepository.proxySettings()

            override suspend fun regionSettings(): NasRegionSettings =
                this@DsmRepository.regionSettings()

            override suspend fun securityResources(): List<ManagedResource> =
                this@DsmRepository.securityResources()

            override fun systemSummary(data: JsonObject): SystemSummary =
                this@DsmRepository.systemSummary(data)

            override fun capacityList(data: JsonObject): List<CapacitySummary> =
                this@DsmRepository.capacityList(data)

            override fun genericResources(
                data: JsonObject,
                vararg roots: String,
            ): List<ManagedResource> = this@DsmRepository.genericResources(data, *roots)

            override fun storageDisks(data: JsonObject): List<NasStorageDisk> =
                this@DsmRepository.storageDisks(data)

            override fun logs(data: JsonObject): List<LogEntry> = this@DsmRepository.logs(data)
        },
    )

    internal val chatRepository = DsmChatRepository(
        object : DsmChatRepositoryGateway {
            override suspend fun usersData(): JsonObject =
                this@DsmRepository.call("SYNO.Chat.User", "list")

            override suspend fun conversationsData(): JsonObject =
                this@DsmRepository.call("SYNO.Chat.Channel", "list")

            override suspend fun call(api: String, method: String, version: Int,
                parameters: Map<String, kotlinx.serialization.json.JsonElement>, oneShot: Boolean): JsonObject {
                val capability = requireCapability(api)
                val json = capability.requestFormat.equals("JSON", true)
                val values = parameters.mapValues { (_, value) ->
                    if (json || value !is JsonPrimitive) value.toString() else value.content
                }
                if (!supports(api, version)) throw unsupportedChatConversationMutation()
                return authorizedApi.call(profile, session, capability.copy(maxVersion = version), method, values, oneShot)
            }
            override fun supports(api: String, version: Int): Boolean = this@DsmRepository.supportsVersion(api, version)
            override suspend fun upload(channelId: String, text: String, source: UploadSource,
                willSubmit: () -> Unit, onProgress: (Long, Long) -> Unit): JsonObject {
                return authorizedApi.uploadChatAttachment(profile, session, requireCapability("SYNO.Chat.Post"), channelId, text, source.displayName,
                    source.contentType, source.contentLength, source.openInputStream, willSubmit, onProgress)
            }

            override suspend fun conversationMembersData(conversationId: String): JsonObject =
                this@DsmRepository.call(
                    CHAT_CHANNEL_MEMBER_API,
                    "get",
                    mapOf("channel_id" to conversationId),
                    version = 1,
                )

            override fun supportsConversationMembers(): Boolean =
                this@DsmRepository.supportsVersion(CHAT_CHANNEL_MEMBER_API, 1)

            override fun invalidConversationRequest(): DsmFailure =
                this@DsmRepository.invalidChatConversationRequest()

            override fun unsupportedConversationRead(): DsmFailure =
                this@DsmRepository.unsupportedChatConversationMutation()

            override fun username(): String = profile.username

            override fun currentUserId(): String? = currentChatUserId

            override fun updateCurrentUserId(userId: String?) {
                currentChatUserId = userId
            }

        },
    )

    internal val fileStationRepository = DsmFileStationRepository(
        object : DsmFileStationRepositoryGateway {
            override suspend fun call(
                apiName: String,
                method: String,
                parameters: Map<String, String>,
            ): JsonObject = this@DsmRepository.call(apiName, method, parameters)

            override fun jsonStrings(values: List<String>): String =
                this@DsmRepository.jsonStrings(values)
        },
    )

    internal fun bindOwner(value: io.github.qwertyuiop1995.dsmnativeclient.storage.WorkspaceOwner, validate: () -> Unit) = workspaceAccess.bindOwner(value, validate)
    internal fun requireCurrentOwner() = workspaceAccess.requireCurrentOwner()
    fun invalidateAccess() = workspaceAccess.invalidate()
    fun availability(): List<ModuleAvailability> = workspaceAccess.availability()
    internal val moduleAccessReadFailed: Boolean get() = workspaceAccess.readFailed
    internal val filePermissionAccess get() = workspaceAccess.filePermissionAccess
    suspend fun refreshAccess(requireSessionConfirmation: Boolean = false) = workspaceAccess.refresh(requireSessionConfirmation)

    suspend fun listShares(
        offset: Int = 0,
        limit: Int = 200,
        sortBy: String = "name",
        sortAscending: Boolean = true,
    ): FilePage = fileStationRepository.listShares(offset, limit, sortBy, sortAscending)

    suspend fun listDirectory(
        path: String,
        offset: Int = 0,
        limit: Int = 200,
        sortBy: String = "name",
        sortAscending: Boolean = true,
        fileType: String = "all",
    ): FilePage = fileStationRepository.listDirectory(
        path,
        offset,
        limit,
        sortBy,
        sortAscending,
        fileType,
    )

    /** 使用公开列表分页复查目标是否仍存在，不依赖内部文件接口。 */
    suspend fun itemExists(path: String): Boolean {
        val parent = path.substringBeforeLast('/', missingDelimiterValue = "")
        if (parent.isBlank()) return false
        var offset = 0
        do {
            val page = listDirectory(parent, offset, 500)
            if (page.items.any { it.path == path }) return true
            if (page.items.isEmpty()) return false
            offset += page.items.size
        } while (offset < page.total)
        return false
    }

    /** 单次分页扫描当前目录，避免批量上传为每个文件重复请求完整列表。 */
    suspend fun existingChildNames(parent: String, names: Collection<String>): Set<String> {
        if (names.isEmpty()) return emptySet()
        val requested = names.associateBy { it.lowercase(Locale.ROOT) }
        val found = mutableSetOf<String>()
        var offset = 0
        do {
            val page = listDirectory(parent, offset, 500)
            page.items.forEach { item ->
                requested[item.name.lowercase(Locale.ROOT)]?.let(found::add)
            }
            if (found.size == requested.size || page.items.isEmpty()) break
            offset += page.items.size
        } while (offset < page.total)
        return found
    }

    suspend fun fileInfo(path: String): FileItem? = fileStationRepository.fileInfo(path)

    /** 官方后台文件任务仅保留脱敏摘要，已结束不推断文件处理成功。 */
    suspend fun listFileBackgroundTasks(offset: Int = 0, limit: Int = 100): FileBackgroundTaskPage =
        fileBackgroundTasks.reader.page(offset, limit)

    internal val fileBackgroundTasks: io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileBackgroundTaskRepository by lazy { io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileBackgroundTaskRepository(
        supports = ::supportsVersion, call = { api, method, fields, version -> call(api, method, fields, version) },
        access = { filePermissionAccess }, refreshAccess = { refreshAccess() }, owner = { owner }, requireOwner = ::requireCurrentOwner,
    ) }

    suspend fun search(path: String, keyword: String): FilePage =
        searchWithReport(io.github.qwertyuiop1995.dsmnativeclient.domain.FileSearchRequest(listOf(path), name = keyword)).page

    suspend fun searchWithReport(request: io.github.qwertyuiop1995.dsmnativeclient.domain.FileSearchRequest) =
        io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileSearchRepository(call = { method, parameters ->
            call("SYNO.FileStation.Search", method, parameters, version = 2)
        }).search(request)

    /**
     * 使用 File Station 官方异步任务扫描当前账号可见的普通共享文件。
     * 取消协程时会停止并清理 NAS 任务，不保留路径、所有者或校验值。
     */
    suspend fun analyzeStorage(
        onProgress: suspend (StorageAnalysisProgress) -> Unit = {},
    ): StorageAnalysisSnapshot {
        requireCapability("SYNO.FileStation.List")
        requireCapability("SYNO.FileStation.Search")
        val shares = mutableListOf<FileItem>()
        var offset = 0
        do {
            currentCoroutineContext().ensureActive()
            val page = listShares(offset, 200)
            shares += page.items.filter {
                !it.isExcludedFromStorageAnalysis() &&
                    (it.mountPointType.isNullOrBlank() || it.mountPointType.equals("normal", true))
            }
            offset += page.items.size
            if (page.items.isEmpty()) break
        } while (offset < page.total)

        val files = mutableListOf<FileItem>()
        val shareRows = mutableListOf<StorageAnalysisShare>()
        shares.forEachIndexed { index, share ->
            currentCoroutineContext().ensureActive()
            onProgress(StorageAnalysisProgress("scanning", index, shares.size))
            val shareFiles = searchAllFiles(share.path)
                .filter { !it.isDirectory && !it.isExcludedFromStorageAnalysis() }
            files += shareFiles
            shareRows += StorageAnalysisShare(
                name = share.name,
                path = share.path,
                usedBytes = shareFiles.sumOf { it.size.coerceAtLeast(0) },
                fileCount = shareFiles.size,
            )
        }

        val duplicateResult = duplicateGroups(files, onProgress)
        data class Usage(var bytes: Long = 0, var count: Int = 0)
        val categories = mutableMapOf<StorageFileCategory, Usage>()
        val owners = mutableMapOf<String?, Usage>()
        files.forEach { file ->
            val size = file.size.coerceAtLeast(0)
            categories.getOrPut(file.storageCategory()) { Usage() }.apply {
                bytes += size
                count++
            }
            owners.getOrPut(file.owner?.takeIf(String::isNotBlank)) { Usage() }.apply {
                bytes += size
                count++
            }
        }
        onProgress(StorageAnalysisProgress("complete", 1, 1))
        return StorageAnalysisSnapshot(
            generatedAtEpochSeconds = System.currentTimeMillis() / 1_000,
            shares = shareRows.sortedByDescending(StorageAnalysisShare::usedBytes),
            categories = categories.map { (category, usage) ->
                StorageAnalysisCategory(category, usage.bytes, usage.count)
            }.sortedByDescending(StorageAnalysisCategory::usedBytes),
            owners = owners.map { (owner, usage) ->
                StorageAnalysisOwner(owner, usage.bytes, usage.count)
            }.sortedByDescending(StorageAnalysisOwner::usedBytes),
            largeFiles = files.sortedByDescending(FileItem::size).take(200),
            recentlyModifiedFiles = files.filter { it.modifiedAtEpochSeconds != null }
                .sortedByDescending(FileItem::modifiedAtEpochSeconds).take(200),
            leastRecentlyAccessedFiles = files.filter { it.accessedAtEpochSeconds != null }
                .sortedBy(FileItem::accessedAtEpochSeconds).take(200),
            duplicateGroups = duplicateResult.groups,
            scannedFileCount = files.size,
            scannedBytes = files.sumOf { it.size.coerceAtLeast(0) },
            duplicateCheckWasLimited = duplicateResult.limited,
            duplicateCheckUnavailable = duplicateResult.unavailable,
        )
    }

    private data class DuplicateAnalysis(
        val groups: List<StorageDuplicateGroup>,
        val limited: Boolean,
        val unavailable: Boolean,
    )

    private suspend fun duplicateGroups(
        files: List<FileItem>,
        onProgress: suspend (StorageAnalysisProgress) -> Unit,
    ): DuplicateAnalysis {
        val allCandidates = files.filter { it.size > 0 }
            .groupBy(FileItem::size).values
            .filter { it.size > 1 }
            .sortedByDescending { it.first().size }
            .flatten()
        val candidates = allCandidates.take(MAXIMUM_DUPLICATE_CANDIDATES)
        val checksums = mutableMapOf<String, MutableList<FileItem>>()
        var unavailable = false
        for ((index, file) in candidates.withIndex()) {
            currentCoroutineContext().ensureActive()
            onProgress(StorageAnalysisProgress("checksums", index, candidates.size))
            try {
                val checksum = fileMd5(file.path)
                checksums.getOrPut("${file.size}:$checksum") { mutableListOf() } += file
            } catch (error: DsmFailure) {
                if (error.kind == DsmErrorKind.FEATURE_UNSUPPORTED) {
                    unavailable = true
                    break
                }
            }
        }
        return DuplicateAnalysis(
            groups = checksums.mapNotNull { (key, group) ->
                if (group.size < 2) null else StorageDuplicateGroup(
                    checksum = key.substringAfter(':'),
                    sizeBytes = group.first().size,
                    files = group.sortedBy(FileItem::path),
                )
            }.sortedByDescending(StorageDuplicateGroup::reclaimableBytes),
            limited = allCandidates.size > candidates.size,
            unavailable = unavailable,
        )
    }

    suspend fun fileMd5(path: String): String {
        require(path.isNotBlank()) { "File path is required" }
        val start = call("SYNO.FileStation.MD5", "start", mapOf("file_path" to path))
        val taskId = start.string("taskid") ?: throw DsmFailure(
            null,
            "The NAS did not start content verification",
            "Try again later.",
            kind = DsmErrorKind.INVALID_RESPONSE,
        )
        var completed = false
        try {
            var waitMillis = 250L
            while (true) {
                currentCoroutineContext().ensureActive()
                val status = call("SYNO.FileStation.MD5", "status", mapOf("taskid" to taskId))
                if (status.bool("finished") == true) {
                    val checksum = status.string("md5")?.trim()?.lowercase(Locale.ROOT)?.takeIf(String::isNotBlank)
                        ?: throw DsmFailure(
                            null,
                            "The NAS did not return a checksum",
                            "Try the verification again.",
                            kind = DsmErrorKind.INVALID_RESPONSE,
                        )
                    completed = true
                    return checksum
                }
                delay(waitMillis)
                waitMillis = (waitMillis * 2).coerceAtMost(1_000)
            }
        } finally {
            if (!completed) {
                withContext(NonCancellable) {
                    runCatching { call("SYNO.FileStation.MD5", "stop", mapOf("taskid" to taskId)) }
                }
            }
        }
    }

    private suspend fun searchAllFiles(path: String): List<FileItem> {
        val start = call(
            "SYNO.FileStation.Search",
            "start",
            mapOf("folder_path" to path, "pattern" to "*", "recursive" to "true"),
        )
        val taskId = start.string("taskid") ?: throw DsmFailure(
            null,
            "The NAS did not start the scan",
            "Try again later.",
            kind = DsmErrorKind.SEARCH_NOT_STARTED,
        )
        val files = mutableListOf<FileItem>()
        try {
            var offset = 0
            var emptyPolls = 0
            while (true) {
                currentCoroutineContext().ensureActive()
                val data = call(
                    "SYNO.FileStation.Search",
                    "list",
                    mapOf(
                        "taskid" to taskId,
                        "offset" to offset.toString(),
                        "limit" to "500",
                        "additional" to "[\"size\",\"owner\",\"time\",\"perm\"]",
                    ),
                )
                val page = parseFilePageFixture(data, "files")
                files += page.items
                offset += page.items.size
                val finished = data.bool("finished") == true
                if (finished && (page.items.isEmpty() || offset >= page.total)) break
                if (page.items.isEmpty()) {
                    emptyPolls++
                    if (emptyPolls >= MAX_SEARCH_EMPTY_POLLS) throw DsmFailure(
                        null,
                        "The NAS scan did not finish",
                        "Try again after checking the connection.",
                        kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
                    )
                    delay(500)
                } else {
                    emptyPolls = 0
                }
            }
            return files.distinctBy(FileItem::path)
        } finally {
            withContext(NonCancellable) {
                runCatching { call("SYNO.FileStation.Search", "stop", mapOf("taskid" to taskId)) }
                runCatching { call("SYNO.FileStation.Search", "clean", mapOf("taskid" to taskId)) }
            }
        }
    }

    private fun FileItem.isExcludedFromStorageAnalysis(): Boolean {
        val segments = path.lowercase(Locale.ROOT).split('/')
        return segments.any { it == "#recycle" || it == "@eadir" } || path.contains("/@")
    }

    private fun FileItem.storageCategory(): StorageFileCategory = when (extension) {
        "" -> StorageFileCategory.NO_EXTENSION
        in IMAGE_EXTENSIONS -> StorageFileCategory.IMAGE
        in VIDEO_EXTENSIONS -> StorageFileCategory.VIDEO
        in AUDIO_EXTENSIONS -> StorageFileCategory.AUDIO
        in DOCUMENT_EXTENSIONS -> StorageFileCategory.DOCUMENT
        in ARCHIVE_EXTENSIONS -> StorageFileCategory.ARCHIVE
        else -> StorageFileCategory.OTHER
    }

    fun supportsFavorites(): Boolean = supports(FILE_STATION_FAVORITE_API)

    fun supportsUploads(): Boolean =
        supports(FILE_STATION_UPLOAD_API) && supports(FILE_STATION_CHECK_PERMISSION_API)

    fun supportsThumbnails(): Boolean = supports(FILE_STATION_THUMB_API)

    /** 已登记的内部只读图标接口；能力或 v1 不存在时不得发送请求。 */
    fun supportsPackageIcons(): Boolean = supportsVersion(PACKAGE_THUMB_API, PACKAGE_THUMB_VERSION)

    fun supportsCopyMove(): Boolean = supports(FILE_STATION_COPY_MOVE_API)

    internal fun supportsCrossNasSource(moveSource: Boolean): Boolean =
        supportsVersion("SYNO.FileStation.List", 2) && supports("SYNO.FileStation.MD5") && supports(FILE_STATION_DOWNLOAD_API) && (!moveSource || supports(FILE_STATION_DELETE_API))

    internal fun supportsCrossNasTarget(includesDirectory: Boolean): Boolean =
        supportsVersion("SYNO.FileStation.List", 2) && supports("SYNO.FileStation.MD5") && supportsUploads() && (!includesDirectory || supports(FILE_STATION_CREATE_FOLDER_API))

    fun supportsSharing(): Boolean = supportsVersion(FILE_STATION_SHARING_API, 3)

    fun supportsCompression(): Boolean =
        capabilities[FILE_STATION_COMPRESS_API]?.maxVersion?.let { it >= 3 } == true

    fun supportsExtraction(): Boolean =
        capabilities[FILE_STATION_EXTRACT_API]?.maxVersion?.let { it >= 2 } == true

    fun supportsPreview(item: FileItem): Boolean = when (item.previewKind()) {
        FilePreviewKind.IMAGE,
        FilePreviewKind.VIDEO,
        FilePreviewKind.AUDIO,
        -> supports(FILE_STATION_DOWNLOAD_API)
        FilePreviewKind.PDF,
        FilePreviewKind.TEXT,
        -> supports(FILE_STATION_DOWNLOAD_API)
        FilePreviewKind.UNSUPPORTED -> false
    }

    private val fileImages by lazy { io.github.qwertyuiop1995.dsmnativeclient.data.files.FileImageTransport(profile, session, authorizedApi, ::requireCapability) }
    suspend fun thumbnail(path: String): ByteArray = fileImages.thumbnail(path)

    /**
     * 读取已安装套件图标。凭据由统一传输层仅通过 Cookie 与请求头发送，返回内容只保留在内存。
     * `Package.Thumb` 不是公开 API，只有能力发现明确声明 v1 时才可调用。
     */
    suspend fun packageIcon(packageInfo: PackageInfo): ByteArray {
        if (!supportsPackageIcons()) throw DsmFailure(
            103,
            "Package icons are unavailable",
            "Use DSM to view package details.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
        val packageId = packageInfo.id.takeIf(String::isNotBlank)
            ?: throw invalidSettingsResponse("package-icon-name")
        val version = packageInfo.version.takeIf(String::isNotBlank)
            ?: throw invalidSettingsResponse("package-icon-version")
        val bytes = authorizedApi.readBinary(
            profile = profile,
            session = session,
            capability = requireCapability(PACKAGE_THUMB_API),
            preferredVersion = PACKAGE_THUMB_VERSION,
            method = "get",
            parameters = mapOf(
                "name" to packageId,
                "ver" to version,
                "size" to PACKAGE_ICON_REQUESTED_SIZE.toString(),
            ),
            maximumBytes = MAX_PACKAGE_ICON_BYTES,
        )
        if (!hasKnownPackageIconSignature(bytes)) {
            throw invalidSettingsResponse("package-icon-image")
        }
        return bytes
    }

    suspend fun readTextPreview(item: FileItem): Pair<String, Boolean> {
        require(item.previewKind() == FilePreviewKind.TEXT)
        if (item.size == 0L) return "" to false
        val maximum = MAX_TEXT_PREVIEW_BYTES
        val requestedLength = minOf(item.size.takeIf { it > 0 } ?: maximum, maximum)
        val bytes = authorizedApi.readBinary(
            profile = profile,
            session = session,
            capability = requireCapability(FILE_STATION_DOWNLOAD_API),
            preferredVersion = 2,
            method = "download",
            parameters = mapOf("path" to jsonStrings(listOf(item.path)), "mode" to "download"),
            maximumBytes = maximum,
            range = 0L..(requestedLength - 1L),
        )
        return decodeTextPreview(bytes) to (item.size <= 0 || item.size > bytes.size)
    }

    suspend fun saveText(
        item: FileItem,
        value: String,
        onProgress: (Long, Long) -> Unit = { _, _ -> },
    ): FilePreviewContent.Text {
        val outcome = saveTextResult(item, value, onProgress)
        requireConfirmedUploadMutation(outcome.result)
        return checkNotNull(outcome.content)
    }

    suspend fun saveTextResult(
        item: FileItem,
        value: String,
        onProgress: (Long, Long) -> Unit = { _, _ -> },
    ): TextSaveMutationOutcome {
        val bytes = value.encodeToByteArray()
        if (
            item.previewKind() != FilePreviewKind.TEXT || !item.canWrite ||
            bytes.size.toLong() > MAX_TEXT_PREVIEW_BYTES
        ) {
            return TextSaveMutationOutcome(
                uploadMutationResult(
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.VALIDATION,
                    diagnosticTag = "file-station.text-save.invalid-input",
                ).copy(
                    operation = "textSave",
                    localizationKey = "mutation.text_save.confirmed_failure",
                ),
            )
        }
        val upload = uploadResultInternal(
            source = UploadSource(
                displayName = item.name,
                contentType = "text/plain; charset=utf-8",
                contentLength = bytes.size.toLong(),
                openInputStream = { ByteArrayInputStream(bytes) },
            ),
            destinationPath = item.path.substringBeforeLast('/', ""),
            overwrite = true,
            onProgress = onProgress,
            targetBaseline = item,
        )
        if (upload.status != MutationResultStatus.CONFIRMED_SUCCESS) {
            return TextSaveMutationOutcome(
                upload.copy(
                    operation = "textSave",
                    localizationKey = "mutation.text_save.${upload.status.name.lowercase()}",
                    diagnosticTag = upload.diagnosticTag?.replace("upload", "text-save"),
                ),
            )
        }
        val updated = item.copy(size = bytes.size.toLong())
        val readback = try {
            readTextPreview(updated)
        } catch (_: CancellationException) {
            return TextSaveMutationOutcome(
                uploadMutationResult(
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "file-station.text-save.cancelled-during-readback",
                ).copy(operation = "textSave"),
            )
        } catch (failure: DsmFailure) {
            return TextSaveMutationOutcome(
                uploadMutationResult(
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = uploadMutationErrorCategory(failure),
                    diagnosticTag = "file-station.text-save.readback-failed",
                ).copy(operation = "textSave"),
            )
        }
        val (readbackValue, truncated) = readback
        if (truncated || readbackValue != value) {
            return TextSaveMutationOutcome(
                uploadMutationResult(
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = true,
                    requiresRefresh = true,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.text-save.readback-mismatch",
                ).copy(operation = "textSave"),
            )
        }
        return TextSaveMutationOutcome(
            uploadMutationResult(
                MutationResultStatus.CONFIRMED_SUCCESS,
                submitted = true,
                succeeded = 1,
                diagnosticTag = "file-station.text-save.confirmed-success",
            ).copy(operation = "textSave"),
            FilePreviewContent.Text(updated, readbackValue, truncated = false),
        )
    }

    suspend fun downloadPreview(item: FileItem, destination: File): File {
        val maximum = when (item.previewKind()) {
            FilePreviewKind.IMAGE -> MAX_IMAGE_PREVIEW_BYTES
            FilePreviewKind.VIDEO -> MAX_VIDEO_PREVIEW_BYTES
            FilePreviewKind.AUDIO -> MAX_AUDIO_PREVIEW_BYTES
            FilePreviewKind.PDF -> MAX_PDF_PREVIEW_BYTES
            else -> throw DsmFailure(
                null,
                "This file type cannot be previewed",
                "Download the file to open it in another app.",
                kind = DsmErrorKind.FEATURE_UNSUPPORTED,
            )
        }
        authorizedApi.downloadBinaryToFile(
            profile = profile,
            session = session,
            capability = requireCapability(FILE_STATION_DOWNLOAD_API),
            preferredVersion = 2,
            method = "download",
            parameters = mapOf("path" to jsonStrings(listOf(item.path)), "mode" to "download"),
            destination = destination,
            expectedBytes = item.size.takeIf { it > 0 },
            maximumBytes = maximum,
        )
        return destination
    }

    fun streamingMediaSource(item: FileItem): RandomAccessMediaSource {
        require(item.previewKind() in setOf(FilePreviewKind.VIDEO, FilePreviewKind.AUDIO))
        require(item.size > 0) { "The media file size is unavailable" }
        return RepositoryMediaSource(this, item)
    }

    internal suspend fun readMediaRange(item: FileItem, position: Long, length: Int): ByteArray {
        require(position >= 0 && length in 1..MAX_MEDIA_RANGE_BYTES)
        if (position >= item.size) return byteArrayOf()
        val last = minOf(item.size - 1, position + length - 1)
        return authorizedApi.readBinary(
            profile = profile,
            session = session,
            capability = requireCapability(FILE_STATION_DOWNLOAD_API),
            preferredVersion = 2,
            method = "download",
            parameters = mapOf("path" to jsonStrings(listOf(item.path)), "mode" to "download"),
            maximumBytes = MAX_MEDIA_RANGE_BYTES.toLong(),
            range = position..last,
        )
    }

    private val fileDownloads by lazy {
        io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileDownloadRepository(profile, session, authorizedApi) {
            requireCapability(FILE_STATION_DOWNLOAD_API)
        }
    }

    suspend fun download(item: FileItem, output: OutputStream, resumeFrom: Long = 0,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ): Long = fileDownloads.download(item, output, resumeFrom, onProgress)

    suspend fun downloadArchive(items: List<FileItem>, output: OutputStream,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ): Long = fileDownloads.downloadArchive(items, output, onProgress)

    suspend fun listFavorites(): List<FavoriteLocation> {
        val result = mutableListOf<FavoriteLocation>()
        var offset = 0
        do {
            val data = call(
                FILE_STATION_FAVORITE_API,
                "list",
                mapOf("offset" to offset.toString(), "limit" to FAVORITE_PAGE_SIZE.toString()),
            )
            val page = data.elements("favorites").mapNotNull { element ->
                val item = element as? JsonObject ?: return@mapNotNull null
                val path = item.string("path") ?: return@mapNotNull null
                FavoriteLocation(
                    path = path,
                    name = item.string("name") ?: path.substringAfterLast('/'),
                )
            }
            result += page
            offset += page.size
            val total = data.int("total") ?: offset
        } while (page.size == FAVORITE_PAGE_SIZE && offset < total)
        return result
    }

    internal suspend fun removeFavoriteResult(path: String): MutationResult =
        removeFavoriteResult(path, itemBaseline = null)

    suspend fun removeFavoriteResult(itemBaseline: FileItem): MutationResult =
        removeFavoriteResult(itemBaseline.path, itemBaseline)

    private suspend fun removeFavoriteResult(
        path: String,
        itemBaseline: FileItem?,
    ): MutationResult {
        if (!currentCoroutineContext().isActive) {
            return favoriteResult(
                operation = "favoriteRemove",
                status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.favorite.remove.cancelled-before-submission",
            )
        }
        if (!path.startsWith('/') || path.length <= 1) {
            return favoriteResult(
                operation = "favoriteRemove",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.favorite.remove.invalid-input",
            )
        }
        if (!supportsFavorites()) {
            return favoriteResult(
                operation = "favoriteRemove",
                status = MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.favorite.remove.unsupported",
            )
        }
        if (!claimFavoriteMutation(path)) {
            return favoriteResult(
                operation = "favoriteRemove",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.favorite.remove.duplicate",
            )
        }
        return try {
            if (itemBaseline != null) {
                val baselineMatches = try {
                    val observed = fileInfo(path)
                    observed != null && observed.matchesMutationBaseline(itemBaseline) &&
                        listFavorites().any { it.path == path }
                } catch (_: CancellationException) {
                    return favoriteResult(
                        operation = "favoriteRemove",
                        status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        submitted = false,
                        diagnosticTag = "file-station.favorite.remove.cancelled-during-preflight",
                    )
                } catch (failure: DsmFailure) {
                    return favoritePreflightFailure(failure, "favoriteRemove")
                }
                if (!baselineMatches) {
                    return favoriteResult(
                        operation = "favoriteRemove",
                        status = MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.favorite.remove.baseline-changed",
                    )
                }
            }
            try {
                call(FILE_STATION_FAVORITE_API, "delete", mapOf("path" to path))
            } catch (_: CancellationException) {
                return favoriteResult(
                    operation = "favoriteRemove",
                    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "file-station.favorite.remove.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                return favoriteSubmissionFailure(failure, "favoriteRemove")
            } catch (_: DsmFailure) {
                return favoriteResult(
                    operation = "favoriteRemove",
                    status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = MutationErrorCategory.UNKNOWN,
                    diagnosticTag = "file-station.favorite.remove.submission-unknown",
                )
            }

            try {
                val removed = listFavorites().none { it.path == path }
                favoriteResult(
                    operation = "favoriteRemove",
                    status = if (removed) MutationResultStatus.CONFIRMED_SUCCESS else MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = true,
                    succeeded = if (removed) 1 else 0,
                    failed = if (removed) 0 else 1,
                    errorCategory = if (removed) null else MutationErrorCategory.SERVER,
                    diagnosticTag = if (removed) {
                        "file-station.favorite.remove.confirmed"
                    } else {
                        "file-station.favorite.remove.readback-mismatch"
                    },
                )
            } catch (_: CancellationException) {
                favoriteResult(
                    operation = "favoriteRemove",
                    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "file-station.favorite.remove.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                favoriteReadbackFailure(failure, "favoriteRemove")
            } catch (_: Throwable) {
                favoriteResult(
                    operation = "favoriteRemove",
                    status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = MutationErrorCategory.UNKNOWN,
                    diagnosticTag = "file-station.favorite.remove.readback-unknown",
                )
            }
        } finally {
            releaseFavoriteMutation(path)
        }
    }

    internal val filePermissions: io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFilePermissionRepository by lazy { io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFilePermissionRepository(
        supports = ::supportsVersion, call = { api, method, parameters, version -> call(api, method, parameters, version) },
        access = { filePermissionAccess }, refreshAccess = { refreshAccess() }, principals = ::listFileSharePrincipals,
        claimPaths = ::claimFilePathMutation, releasePaths = ::releaseFilePathMutation,
        owner = { owner }, requireOwner = ::requireCurrentOwner,
        mountPendingPaths = { fileMounts.pendingPaths() },
    ) }
    internal val fileMounts: io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileMountRepository by lazy { io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileMountRepository(
        supports = ::supportsVersion, call = { api, method, parameters, version -> call(api, method, parameters, version) },
        access = { filePermissionAccess }, refreshAccess = { refreshAccess() },
        claimPaths = ::claimFilePathMutation, releasePaths = ::releaseFilePathMutation,
        permissionPendingPaths = { filePermissions.pending().map { it.path } },
        owner = { owner }, requireOwner = ::requireCurrentOwner, secureTransport = { authorizedApi.endpoint(profile).startsWith("https://") },
    ) }
    internal val fileSettings: io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileSettingsRepository by lazy { io.github.qwertyuiop1995.dsmnativeclient.data.files.DsmFileSettingsRepository(
        supports = ::supportsVersion, call = { api, method, parameters, version -> call(api, method, parameters, version) },
        access = { filePermissionAccess }, refreshAccess = { refreshAccess() },
        owner = { owner }, requireOwner = ::requireCurrentOwner,
        media = fileImages, fileInfo = ::fileInfo,
    ) }

    private val sharingRepository = DsmFileSharingRepository(
        supports = ::supportsVersion, call = { api, method, parameters, version -> call(api, method, parameters, version) },
        fileInfo = ::fileInfo, claimPaths = ::claimFilePathMutation, releasePaths = ::releaseFilePathMutation,
        owner = { owner }, requireOwner = ::requireCurrentOwner,
    )

    internal fun bindShareRecovery(store: io.github.qwertyuiop1995.dsmnativeclient.data.files.FileShareRecoveryStore) = sharingRepository.bindRecovery(store)
    internal suspend fun pendingShareChanges() = sharingRepository.pending()
    internal suspend fun recoverShareChanges() = sharingRepository.recover()

    suspend fun listShareLinks(): List<FileShareLink> = sharingRepository.list()
    suspend fun listFileSharePrincipals(prefix: String, offset: Int, limit: Int = 200): FileSharePrincipalPage =
        sharingRepository.principals(prefix, offset, limit)

    internal suspend fun createShareLinkResult(path: String): ShareLinkMutationOutcome = sharingRepository.create(
        FileShareCreateRequest(FileItem(path = path, name = path.substringAfterLast('/'), isDirectory = false)), checkBaseline = false)

    suspend fun createShareLinkResult(itemBaseline: FileItem): ShareLinkMutationOutcome =
        createShareLinkResult(FileShareCreateRequest(itemBaseline))

    suspend fun createShareLinkResult(request: FileShareCreateRequest): ShareLinkMutationOutcome = sharingRepository.create(request)
    suspend fun editShareLinkResult(request: FileShareEditRequest): ShareLinkMutationOutcome = sharingRepository.edit(request)

    internal suspend fun deleteShareLinks(ids: List<String>) {
        val result = deleteShareLinksResult(ids)
        when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> return
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> throw CancellationException("share link deletion cancelled")
            else -> throw DsmFailure(
                null,
                "The NAS did not confirm every share link removal",
                "Refresh shared links and review the remaining items before trying again.",
                kind = when (result.status) {
                    MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                    MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                    else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
                },
            )
        }
    }

    internal suspend fun deleteShareLinksResult(ids: List<String>): MutationResult =
        deleteShareLinksResultInternal(ids, baselineLinks = null)

    suspend fun deleteShareLinksResult(
        ids: List<String>,
        baselineLinks: List<FileShareLink>,
    ): MutationResult = deleteShareLinksResultInternal(ids, baselineLinks)

    private suspend fun deleteShareLinksResultInternal(
        ids: List<String>,
        baselineLinks: List<FileShareLink>?,
    ): MutationResult {
        val operation = "shareLinkDelete"
        val normalized = ids.map(String::trim).filter(String::isNotBlank).distinct().sorted()
        if (normalized.isEmpty() || normalized.size != ids.size) {
            return shareLinkDeleteResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = ids.size.coerceAtLeast(1),
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.share-link.delete.invalid-target",
            )
        }
        if (!supports(FILE_STATION_SHARING_API)) {
            return shareLinkDeleteResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = normalized.size,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.share-link.delete.unsupported",
            )
        }
        if (!currentCoroutineContext().isActive) {
            return shareLinkDeleteResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.share-link.delete.cancelled-before-submission",
            )
        }
        val existing = try {
            listShareLinks().filter { it.id in normalized }
        } catch (_: CancellationException) {
            return shareLinkDeleteResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.share-link.delete.cancelled-during-preflight",
            )
        } catch (failure: DsmFailure) {
            val category = fileMutationErrorCategory(failure)
            return shareLinkDeleteResult(
                operation,
                when (category) {
                    MutationErrorCategory.PERMISSION,
                    MutationErrorCategory.AUTHENTICATION,
                    -> MutationResultStatus.PERMISSION_DENIED
                    MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
                    else -> MutationResultStatus.CONFIRMED_FAILURE
                },
                submitted = false,
                failed = normalized.size,
                errorCategory = category,
                diagnosticTag = "file-station.share-link.delete.preflight-failed",
            )
        }
        if (existing.size != normalized.size) {
            return shareLinkDeleteResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = normalized.size,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.share-link.delete.target-changed",
            )
        }
        if (baselineLinks != null) {
            val normalizedBaseline = baselineLinks.distinctBy(FileShareLink::id)
                .sortedBy(FileShareLink::id)
            if (normalizedBaseline.size != normalized.size ||
                normalizedBaseline.map(FileShareLink::id) != normalized ||
                existing.sortedBy(FileShareLink::id) != normalizedBaseline
            ) {
                return shareLinkDeleteResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = normalized.size,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.share-link.delete.baseline-changed",
                )
            }
        }
        val claimedIds = shareLinkDeletionLock.withLock {
            if (normalized.any(activeShareLinkDeletionIds::contains)) {
                false
            } else {
                activeShareLinkDeletionIds += normalized
                true
            }
        }
        if (!claimedIds) {
            return shareLinkDeleteResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = normalized.size,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.share-link.delete.duplicate-submission",
            )
        }
        val affectedPaths = existing.mapNotNullTo(mutableSetOf()) { link ->
            link.path.trimEnd('/').takeIf { isFileMutationPath(it) }
        }
        val claimedPaths = affectedPaths.isEmpty() || claimFilePathMutation(affectedPaths)
        if (!claimedPaths) {
            shareLinkDeletionLock.withLock { activeShareLinkDeletionIds.removeAll(normalized.toSet()) }
            return shareLinkDeleteResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = normalized.size,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.share-link.delete.path-conflict",
            )
        }
        try {
            var submissionFailure: DsmFailure? = null
            var cancelledAfterSubmission = false
            try {
                call(FILE_STATION_SHARING_API, "delete", mapOf("id" to jsonStrings(normalized)))
            } catch (_: CancellationException) {
                cancelledAfterSubmission = true
            } catch (failure: DsmFailure) {
                submissionFailure = failure
            }

            val remaining = try {
                withContext(NonCancellable) {
                    listShareLinks().mapTo(mutableSetOf(), FileShareLink::id)
                }
            } catch (failure: DsmFailure) {
                val category = submissionFailure?.let(::fileMutationErrorCategory)
                    ?: fileMutationErrorCategory(failure)
                return shareLinkDeleteResult(
                    operation,
                    if (cancelledAfterSubmission) {
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    } else {
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                    },
                    submitted = true,
                    requiresRefresh = true,
                    unknown = normalized.size,
                    errorCategory = category,
                    diagnosticTag = if (cancelledAfterSubmission) {
                        "file-station.share-link.delete.cancelled-readback-failed"
                    } else {
                        "file-station.share-link.delete.readback-failed"
                    },
                )
            }
            val succeeded = normalized.count { it !in remaining }
            val failed = normalized.size - succeeded
            if (succeeded == normalized.size) {
                return shareLinkDeleteResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = succeeded,
                    diagnosticTag = if (submissionFailure == null && !cancelledAfterSubmission) {
                        "file-station.share-link.delete.confirmed-success"
                    } else {
                        "file-station.share-link.delete.confirmed-after-error"
                    },
                )
            }
            if (succeeded > 0) {
                return shareLinkDeleteResult(
                    operation,
                    MutationResultStatus.PARTIAL_SUCCESS,
                    submitted = true,
                    requiresRefresh = true,
                    succeeded = succeeded,
                    failed = failed,
                    errorCategory = submissionFailure?.let(::fileMutationErrorCategory)
                        ?: MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.share-link.delete.partial-success",
                )
            }
            if (cancelledAfterSubmission) {
                return shareLinkDeleteResult(
                    operation,
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = normalized.size,
                    diagnosticTag = "file-station.share-link.delete.cancelled-after-submission",
                )
            }
            if (submissionFailure != null) {
                val category = fileMutationErrorCategory(submissionFailure)
                val status = when (category) {
                    MutationErrorCategory.PERMISSION,
                    MutationErrorCategory.AUTHENTICATION,
                    -> MutationResultStatus.PERMISSION_DENIED
                    MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
                    MutationErrorCategory.NETWORK,
                    MutationErrorCategory.UNKNOWN,
                    -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                    else -> MutationResultStatus.CONFIRMED_FAILURE
                }
                return shareLinkDeleteResult(
                    operation,
                    status,
                    submitted = true,
                    requiresRefresh = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    failed = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 0 else failed,
                    unknown = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) failed else 0,
                    errorCategory = category,
                    diagnosticTag = "file-station.share-link.delete.submission-failed",
                )
            }
            return shareLinkDeleteResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = true,
                requiresRefresh = true,
                failed = failed,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.share-link.delete.readback-mismatch",
            )
        } finally {
            if (affectedPaths.isNotEmpty()) releaseFilePathMutation(affectedPaths)
            shareLinkDeletionLock.withLock { activeShareLinkDeletionIds.removeAll(normalized.toSet()) }
        }
    }

    private fun shareLinkDeleteResult(
        operation: String,
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
    ) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = operation,
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = MutationResultCounts(succeeded, failed, unknown),
        errorCategory = errorCategory,
        localizationKey = "mutation.sharelinkdelete.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    /** 收藏新增是 Android 接入统一写操作结果语义的低影响试点。 */
    internal suspend fun addFavoriteResult(path: String, name: String): MutationResult =
        addFavoriteResult(path, name, itemBaseline = null)

    suspend fun addFavoriteResult(itemBaseline: FileItem): MutationResult =
        addFavoriteResult(itemBaseline.path, itemBaseline.name, itemBaseline)

    private suspend fun addFavoriteResult(
        path: String,
        name: String,
        itemBaseline: FileItem?,
    ): MutationResult {
        val normalizedName = name.trim()
        if (!currentCoroutineContext().isActive) {
            return favoriteResult(
                status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.favorite.add.cancelled-before-submission",
            )
        }
        if (!path.startsWith('/') || path.length <= 1 || normalizedName.isBlank()) {
            return favoriteResult(
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.favorite.add.invalid-input",
            )
        }
        if (!supportsFavorites()) {
            return favoriteResult(
                status = MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.favorite.add.unsupported",
            )
        }
        if (!claimFavoriteMutation(path)) {
            return favoriteResult(
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.favorite.add.duplicate",
            )
        }

        return try {
            if (itemBaseline != null) {
                val baselineMatches = try {
                    val observed = fileInfo(path)
                    observed != null && observed.matchesMutationBaseline(itemBaseline) &&
                        listFavorites().none { it.path == path }
                } catch (_: CancellationException) {
                    return favoriteResult(
                        status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        submitted = false,
                        diagnosticTag = "file-station.favorite.add.cancelled-during-preflight",
                    )
                } catch (failure: DsmFailure) {
                    return favoritePreflightFailure(failure, "favoriteAdd")
                }
                if (!baselineMatches) {
                    return favoriteResult(
                        status = MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.favorite.add.baseline-changed",
                    )
                }
            }
            try {
                call(
                    FILE_STATION_FAVORITE_API,
                    "add",
                    mapOf("path" to path, "name" to normalizedName),
                )
            } catch (_: CancellationException) {
                return favoriteResult(
                    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "file-station.favorite.add.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                return favoriteSubmissionFailure(failure, "favoriteAdd")
            } catch (_: Throwable) {
                return favoriteResult(
                    status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = MutationErrorCategory.UNKNOWN,
                    diagnosticTag = "file-station.favorite.add.submission-unknown",
                )
            }

            try {
                val confirmed = listFavorites().any { it.path == path }
                if (confirmed) {
                    favoriteResult(
                        status = MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "file-station.favorite.add.confirmed",
                    )
                } else {
                    favoriteResult(
                        status = MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = true,
                        failed = 1,
                        errorCategory = MutationErrorCategory.SERVER,
                        diagnosticTag = "file-station.favorite.add.readback-mismatch",
                    )
                }
            } catch (_: CancellationException) {
                favoriteResult(
                    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "file-station.favorite.add.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                favoriteReadbackFailure(failure, "favoriteAdd")
            } catch (_: Throwable) {
                favoriteResult(
                    status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = MutationErrorCategory.UNKNOWN,
                    diagnosticTag = "file-station.favorite.add.readback-unknown",
                )
            }
        } finally {
            releaseFavoriteMutation(path)
        }
    }

    suspend fun upload(
        source: UploadSource,
        destinationPath: String,
        overwrite: Boolean = false,
        onProgress: (Long, Long) -> Unit,
    ) {
        requireConfirmedUploadMutation(
            uploadResult(source, destinationPath, overwrite, onProgress),
        )
    }

    suspend fun uploadResult(
        source: UploadSource,
        destinationPath: String,
        overwrite: Boolean = false,
        onProgress: (Long, Long) -> Unit = { _, _ -> },
    ): MutationResult = uploadResultInternal(
        source,
        destinationPath,
        overwrite,
        onProgress,
        targetBaseline = null,
    )

    internal suspend fun uploadOfficeResult(source: UploadSource, destination: String,
        beforeSubmission: suspend () -> Unit, onProgress: (Long, Long) -> Unit): MutationResult =
        uploadResultInternal(source, destination, true, onProgress, null, beforeSubmission)

    private suspend fun uploadResultInternal(
        source: UploadSource,
        destinationPath: String,
        overwrite: Boolean,
        onProgress: (Long, Long) -> Unit,
        targetBaseline: FileItem?,
        beforeSubmission: (suspend () -> Unit)? = null,
    ): MutationResult {
        val destination = destinationPath.trimEnd('/')
        val valid = destination.startsWith('/') && destination.length > 1 &&
            source.displayName.isNotBlank() &&
            '/' !in source.displayName &&
            '\\' !in source.displayName &&
            '\n' !in source.displayName &&
            '\r' !in source.displayName &&
            source.contentLength >= 0
        if (!valid) {
            return uploadMutationResult(
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.upload.invalid-input",
            )
        }
        if (!supports(FILE_STATION_CHECK_PERMISSION_API) || !supports(FILE_STATION_UPLOAD_API)) {
            return uploadMutationResult(
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.upload.unsupported",
            )
        }
        if (!currentCoroutineContext().isActive) {
            return uploadMutationResult(
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.upload.cancelled-before-submission",
            )
        }
        val target = join(destination, source.displayName)
        val affectedPaths = setOf(target)
        if (!claimFilePathMutation(affectedPaths)) {
            return uploadMutationResult(
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.upload.duplicate-submission",
            )
        }
        try {
            if (targetBaseline != null) {
                val observed = try {
                    fileInfo(target)
                } catch (_: CancellationException) {
                    return uploadMutationResult(
                        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        submitted = false,
                        diagnosticTag = "file-station.upload.cancelled-before-submission",
                    )
                } catch (failure: DsmFailure) {
                    return uploadPreflightFailure(failure)
                }
                if (observed == null || !observed.matchesMutationBaseline(targetBaseline)) {
                    return uploadMutationResult(
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.upload.target-baseline-drift",
                    )
                }
            }
            val permissionFilename = if (overwrite) {
                "LanStash-Write-Check-${UUID.randomUUID()}.tmp"
            } else {
                source.displayName
            }
            try {
                call(
                    FILE_STATION_CHECK_PERMISSION_API,
                    "write",
                    mapOf(
                        "path" to destination,
                        "filename" to permissionFilename,
                        "create_only" to "true",
                    ),
                )
            } catch (_: CancellationException) {
                return uploadMutationResult(
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "file-station.upload.cancelled-before-submission",
                )
            } catch (failure: DsmFailure) {
                return uploadPreflightFailure(failure)
            }
            beforeSubmission?.invoke()
            val capability = checkNotNull(capabilities[FILE_STATION_UPLOAD_API])
            val content = java.util.concurrent.atomic.AtomicReference<UploadContentFingerprint?>()
            try {
                authorizedApi.upload(
                    profile = profile,
                    session = session,
                    capability = capability,
                    destinationPath = destination,
                    filename = source.displayName,
                    contentType = source.contentType,
                    contentLength = source.contentLength,
                    overwrite = overwrite,
                    openInputStream = source.openInputStream,
                    onProgress = onProgress,
                    onContentRead = { fingerprint ->
                        content.set(fingerprint)
                        source.onContentRead(fingerprint)
                    },
                )
            } catch (_: CancellationException) {
                val confirmed = withContext(NonCancellable) {
                    kotlinx.coroutines.withTimeoutOrNull(15_000) {
                        runCatching { uploadMatches(target, source.contentLength, content.get(), true) }.getOrDefault(false)
                    } ?: false
                }
                return if (confirmed) {
                    uploadMutationResult(
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "file-station.upload.confirmed-after-cancel",
                    )
                } else {
                    uploadMutationResult(
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        diagnosticTag = "file-station.upload.cancelled-after-submission",
                    )
                }
            } catch (failure: DsmFailure) {
                val category = uploadMutationErrorCategory(failure)
                if (category in setOf(MutationErrorCategory.PERMISSION, MutationErrorCategory.AUTHENTICATION)) {
                    return uploadMutationResult(
                        MutationResultStatus.PERMISSION_DENIED,
                        submitted = true,
                        failed = 1,
                        errorCategory = category,
                        diagnosticTag = "file-station.upload.permission-denied",
                    )
                }
                val uncertain = failure.kind in setOf(
                    DsmErrorKind.CONNECTION_FAILED,
                    DsmErrorKind.INVALID_RESPONSE,
                    DsmErrorKind.UNKNOWN,
                )
                if (!uncertain) {
                    return uploadMutationResult(
                        if (category == MutationErrorCategory.UNSUPPORTED) {
                            MutationResultStatus.UNSUPPORTED
                        } else {
                            MutationResultStatus.CONFIRMED_FAILURE
                        },
                        submitted = true,
                        failed = 1,
                        errorCategory = category,
                        diagnosticTag = if (failure.kind == DsmErrorKind.UPLOAD_LENGTH_MISMATCH) {
                            "file-station.upload.length-mismatch"
                        } else {
                            "file-station.upload.rejected"
                        },
                    )
                }
                val confirmed = try {
                    uploadMatches(target, source.contentLength, content.get(), true)
                } catch (_: CancellationException) {
                    return uploadMutationResult(
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        diagnosticTag = "file-station.upload.cancelled-during-readback",
                    )
                } catch (_: DsmFailure) {
                    false
                }
                return if (confirmed) {
                    uploadMutationResult(
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "file-station.upload.confirmed-after-error",
                    )
                } else {
                    uploadMutationResult(
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        errorCategory = category,
                        diagnosticTag = "file-station.upload.submission-unverified",
                    )
                }
            }
            return try {
                if (uploadMatches(target, source.contentLength)) {
                    uploadMutationResult(
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "file-station.upload.confirmed-success",
                    )
                } else {
                    uploadMutationResult(
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = true,
                        requiresRefresh = true,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.upload.readback-mismatch",
                    )
                }
            } catch (_: CancellationException) {
                uploadMutationResult(
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "file-station.upload.cancelled-during-readback",
                )
            } catch (failure: DsmFailure) {
                uploadMutationResult(
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = uploadMutationErrorCategory(failure),
                    diagnosticTag = "file-station.upload.readback-failed",
                )
            }
        } finally {
            releaseFilePathMutation(affectedPaths)
        }
    }

    internal suspend fun createFolderResult(parent: String, name: String): MutationResult =
        createFolderResult(parent, name, parentBaseline = null)

    suspend fun createFolderResult(parentBaseline: FileItem, name: String, preserveSourceName: Boolean = false): MutationResult =
        createFolderResult(parentBaseline.path, name, parentBaseline, preserveSourceName)

    private suspend fun createFolderResult(
        parent: String,
        name: String,
        parentBaseline: FileItem?,
        preserveSourceName: Boolean = false,
    ): MutationResult {
        val operation = "folderCreate"
        if (!currentCoroutineContext().isActive) {
            return fileEntryMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.folder-create.cancelled-before-submission",
            )
        }
        val normalizedParent = if (parent == "/") parent else parent.trimEnd('/')
        val normalizedName = if (preserveSourceName) name else name.trim()
        val invalid = !isFileMutationPath(normalizedParent, allowRoot = true) ||
            normalizedName.isEmpty() ||
            '/' in normalizedName ||
            '\\' in normalizedName ||
            normalizedName == "." ||
            normalizedName == ".."
        if (invalid) {
            return fileEntryMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.folder-create.invalid-input",
            )
        }
        if (!supports(FILE_STATION_CREATE_FOLDER_API)) {
            return fileEntryMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.folder-create.unsupported",
            )
        }
        val target = join(normalizedParent, normalizedName)
        val affectedPaths = setOf(target)
        if (!claimFilePathMutation(affectedPaths)) {
            return fileEntryMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.folder-create.duplicate-submission",
            )
        }
        try {
            val parentItem = try {
                fileInfo(normalizedParent)
            } catch (_: CancellationException) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "file-station.folder-create.cancelled-before-submission",
                )
            } catch (failure: DsmFailure) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = fileMutationErrorCategory(failure),
                    diagnosticTag = "file-station.folder-create.preflight-failed",
                )
            }
            if (parentItem == null || !parentItem.isDirectory) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.folder-create.parent-missing",
                )
            }
            if (parentBaseline != null && !parentItem.matchesMutationBaseline(parentBaseline)) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.folder-create.parent-baseline-changed",
                )
            }
            if (!parentItem.canWrite) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.PERMISSION_DENIED,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.PERMISSION,
                    diagnosticTag = "file-station.folder-create.parent-read-only",
                )
            }
            val targetExists = try {
                itemExists(target)
            } catch (_: CancellationException) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "file-station.folder-create.cancelled-before-submission",
                )
            } catch (failure: DsmFailure) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = fileMutationErrorCategory(failure),
                    diagnosticTag = "file-station.folder-create.preflight-failed",
                )
            }
            if (targetExists) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.folder-create.name-conflict",
                )
            }
            try {
                call(
                    FILE_STATION_CREATE_FOLDER_API,
                    "create",
                    mapOf(
                        "folder_path" to normalizedParent,
                        "name" to normalizedName,
                        "force_parent" to "false",
                    ),
                )
            } catch (_: CancellationException) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "file-station.folder-create.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                return fileEntrySubmissionFailure(operation, "folder-create", failure)
            }
            return verifyFileEntryMutation(
                operation = operation,
                diagnosticOperation = "folder-create",
                expectedPath = target,
                expectedDirectory = true,
            )
        } finally {
            releaseFilePathMutation(affectedPaths)
        }
    }

    suspend fun ensureSubdirectory(root: String, target: String) {
        val result = ensureSubdirectoryResult(root, target)
        require(result.diagnosticTag != "file-station.backup-folder.ensure.blocked-by-file") {
            "A file blocks the backup folder"
        }
        requireConfirmedFileEntryMutation(result)
    }

    /**
     * 逐级确认后台上传目录。每个层级最多提交一次创建请求；失败后的额外访问仅用于读回确认，
     * 不会自动重放已经提交的创建请求。
     */
    suspend fun ensureSubdirectoryResult(root: String, target: String): MutationResult {
        require(isFileMutationPath(root, allowRoot = true) && isFileMutationPath(target, allowRoot = true))
        require(target == root || target.startsWith(root.trimEnd('/') + "/")) {
            "Backup destination is outside its configured root"
        }
        if (target == root) {
            return backupFolderEnsureResult(
                MutationResultStatus.CONFIRMED_SUCCESS,
                submitted = true,
                diagnosticTag = "file-station.backup-folder.ensure.already-satisfied",
            )
        }
        var current = root.trimEnd('/')
        var succeeded = 0
        var submitted = false
        for (component in target.removePrefix(current).trim('/').split('/')) {
            require(component.isNotBlank() && '/' !in component && '\\' !in component) {
                "Invalid backup folder name"
            }
            if (!currentCoroutineContext().isActive) {
                return backupFolderEnsureCancellationResult(succeeded, submitted, 0)
            }
            val next = join(current, component)
            val existing = try {
                if (itemExists(next)) fileInfo(next) else null
            } catch (_: CancellationException) {
                return backupFolderEnsureCancellationResult(succeeded, submitted, 0)
            } catch (failure: DsmFailure) {
                return backupFolderEnsureTerminalResult(
                    succeeded = succeeded,
                    submitted = submitted,
                    failed = 1,
                    unknown = 0,
                    fallbackStatus = MutationResultStatus.CONFIRMED_FAILURE,
                    requiresRefresh = false,
                    errorCategory = fileMutationErrorCategory(failure),
                    diagnosticTag = "file-station.backup-folder.ensure.preflight-failed",
                )
            }
            if (existing != null) {
                if (!existing.isDirectory) {
                    return backupFolderEnsureTerminalResult(
                        succeeded = succeeded,
                        submitted = submitted,
                        failed = 1,
                        unknown = 0,
                        fallbackStatus = MutationResultStatus.CONFIRMED_FAILURE,
                        requiresRefresh = false,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.backup-folder.ensure.blocked-by-file",
                    )
                }
                current = next
                continue
            }

            val level = createFolderResult(current, component, parentBaseline = null, preserveSourceName = true)
            if (level.status == MutationResultStatus.CONFIRMED_SUCCESS) {
                succeeded += level.counts.succeeded
                submitted = submitted || level.submitted
                current = next
                continue
            }
            if (level.status == MutationResultStatus.CANCELLED_BEFORE_SUBMISSION) {
                return backupFolderEnsureCancellationResult(succeeded, submitted, 0)
            }
            if (level.status == MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION) {
                return backupFolderEnsureCancellationResult(
                    succeeded,
                    submitted || level.submitted,
                    level.counts.unknown,
                )
            }

            val confirmedDirectory = try {
                fileInfo(next)?.isDirectory == true
            } catch (_: CancellationException) {
                return backupFolderEnsureCancellationResult(
                    succeeded,
                    submitted || level.submitted,
                    1,
                )
            } catch (_: DsmFailure) {
                false
            }
            if (confirmedDirectory) {
                succeeded++
                submitted = submitted || level.submitted
                current = next
                continue
            }
            return backupFolderEnsureTerminalResult(
                succeeded = succeeded,
                submitted = submitted || level.submitted,
                failed = level.counts.failed,
                unknown = level.counts.unknown,
                fallbackStatus = level.status,
                requiresRefresh = level.requiresRefresh,
                errorCategory = level.errorCategory,
                diagnosticTag = "file-station.backup-folder.ensure.${level.status.name.lowercase().replace('_', '-')}",
            )
        }
        return backupFolderEnsureResult(
            MutationResultStatus.CONFIRMED_SUCCESS,
            // MutationResult v1 的确认成功要求 submitted=true；诊断标签另外区分本次是否实际写入。
            submitted = true,
            succeeded = succeeded,
            diagnosticTag = if (submitted) {
                "file-station.backup-folder.ensure.confirmed-success"
            } else {
                "file-station.backup-folder.ensure.already-satisfied"
            },
        )
    }

    internal fun backupFolderEnsureCancellationResult(
        succeeded: Int,
        submitted: Boolean,
        unknown: Int,
    ): MutationResult = if (submitted) {
        backupFolderEnsureResult(
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            submitted = true,
            requiresRefresh = true,
            succeeded = succeeded,
            unknown = unknown,
            diagnosticTag = "file-station.backup-folder.ensure.cancelled-after-submission",
        )
    } else {
        backupFolderEnsureResult(
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            submitted = false,
            diagnosticTag = "file-station.backup-folder.ensure.cancelled-before-submission",
        )
    }

    private fun backupFolderEnsureTerminalResult(
        succeeded: Int,
        submitted: Boolean,
        failed: Int,
        unknown: Int,
        fallbackStatus: MutationResultStatus,
        requiresRefresh: Boolean,
        errorCategory: MutationErrorCategory?,
        diagnosticTag: String,
    ): MutationResult = backupFolderEnsureResult(
        status = if (succeeded > 0) MutationResultStatus.PARTIAL_SUCCESS else fallbackStatus,
        submitted = submitted || succeeded > 0,
        requiresRefresh = requiresRefresh || succeeded > 0 || unknown > 0,
        succeeded = succeeded,
        failed = failed,
        unknown = unknown,
        errorCategory = errorCategory,
        diagnosticTag = if (!submitted && succeeded > 0) {
            "$diagnosticTag.readback-only"
        } else {
            diagnosticTag
        },
    )

    private fun backupFolderEnsureResult(
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
    ): MutationResult = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = "backupFolderEnsure",
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = MutationResultCounts(succeeded, failed, unknown),
        errorCategory = errorCategory,
        localizationKey = "mutation.backup_folder_ensure.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    internal suspend fun rename(path: String, newName: String) {
        requireConfirmedFileEntryMutation(renameResult(path, newName))
    }

    internal suspend fun renameResult(path: String, newName: String): MutationResult =
        renameResult(path, newName, sourceBaseline = null)

    suspend fun renameResult(sourceBaseline: FileItem, newName: String): MutationResult =
        renameResult(sourceBaseline.path, newName, sourceBaseline)

    private suspend fun renameResult(
        path: String,
        newName: String,
        sourceBaseline: FileItem?,
    ): MutationResult {
        val operation = "fileRename"
        if (!currentCoroutineContext().isActive) {
            return fileEntryMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.rename.cancelled-before-submission",
            )
        }
        val source = path.trimEnd('/')
        val normalizedName = newName.trim()
        val parent = source.substringBeforeLast('/', "").ifEmpty { "/" }
        val target = join(parent, normalizedName)
        val invalid = !isFileMutationPath(source) ||
            normalizedName.isEmpty() ||
            '/' in normalizedName ||
            '\\' in normalizedName ||
            normalizedName == "." ||
            normalizedName == ".." ||
            target == source
        if (invalid) {
            return fileEntryMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.rename.invalid-input",
            )
        }
        if (!supports(FILE_STATION_RENAME_API)) {
            return fileEntryMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.rename.unsupported",
            )
        }
        val affectedPaths = setOf(source, target)
        if (!claimFilePathMutation(affectedPaths)) {
            return fileEntryMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.rename.duplicate-submission",
            )
        }
        try {
            val sourceItem: FileItem
            try {
                sourceItem = fileInfo(source) ?: return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.rename.source-missing",
                )
                if (sourceBaseline != null && !sourceItem.matchesMutationBaseline(sourceBaseline)) {
                    return fileEntryMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.rename.source-baseline-changed",
                    )
                }
                val parentItem = fileInfo(parent)
                if (parentItem == null || !parentItem.isDirectory) {
                    return fileEntryMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.rename.parent-missing",
                    )
                }
                if (!parentItem.canWrite) {
                    return fileEntryMutationResult(
                        operation,
                        MutationResultStatus.PERMISSION_DENIED,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.PERMISSION,
                        diagnosticTag = "file-station.rename.parent-read-only",
                    )
                }
                if (itemExists(target)) {
                    return fileEntryMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.rename.name-conflict",
                    )
                }
            } catch (_: CancellationException) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "file-station.rename.cancelled-before-submission",
                )
            } catch (failure: DsmFailure) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = fileMutationErrorCategory(failure),
                    diagnosticTag = "file-station.rename.preflight-failed",
                )
            }
            try {
                call(
                    FILE_STATION_RENAME_API,
                    "rename",
                    mapOf("path" to source, "name" to normalizedName),
                )
            } catch (_: CancellationException) {
                return fileEntryMutationResult(
                    operation,
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "file-station.rename.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                return fileEntrySubmissionFailure(operation, "rename", failure)
            }
            return verifyFileEntryMutation(
                operation = operation,
                diagnosticOperation = "rename",
                expectedPath = target,
                expectedDirectory = sourceItem.isDirectory,
                removedPath = source,
            )
        } finally {
            releaseFilePathMutation(affectedPaths)
        }
    }

    private suspend fun verifyFileEntryMutation(
        operation: String,
        diagnosticOperation: String,
        expectedPath: String,
        expectedDirectory: Boolean,
        removedPath: String? = null,
    ): MutationResult = try {
        val sourceRemoved = removedPath == null || !itemExists(removedPath)
        val target = fileInfo(expectedPath)
        if (sourceRemoved && target?.isDirectory == expectedDirectory) {
            fileEntryMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_SUCCESS,
                submitted = true,
                succeeded = 1,
                diagnosticTag = "file-station.$diagnosticOperation.confirmed-success",
            )
        } else {
            fileEntryMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = true,
                requiresRefresh = true,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.$diagnosticOperation.readback-mismatch",
            )
        }
    } catch (_: CancellationException) {
        fileEntryMutationResult(
            operation,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            submitted = true,
            requiresRefresh = true,
            unknown = 1,
            diagnosticTag = "file-station.$diagnosticOperation.cancelled-during-readback",
        )
    } catch (failure: DsmFailure) {
        fileEntryMutationResult(
            operation,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            submitted = true,
            requiresRefresh = true,
            unknown = 1,
            errorCategory = fileMutationErrorCategory(failure),
            diagnosticTag = "file-station.$diagnosticOperation.readback-unverified",
        )
    }

    private fun fileEntrySubmissionFailure(
        operation: String,
        diagnosticOperation: String,
        failure: DsmFailure,
    ): MutationResult = if (failure.kind == DsmErrorKind.PERMISSION_DENIED) {
        fileEntryMutationResult(
            operation,
            MutationResultStatus.PERMISSION_DENIED,
            submitted = true,
            failed = 1,
            errorCategory = MutationErrorCategory.PERMISSION,
            diagnosticTag = "file-station.$diagnosticOperation.permission-denied",
        )
    } else {
        fileEntryMutationResult(
            operation,
            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            submitted = true,
            requiresRefresh = true,
            unknown = 1,
            errorCategory = fileMutationErrorCategory(failure),
            diagnosticTag = "file-station.$diagnosticOperation.submission-unverified",
        )
    }

    private fun fileEntryMutationResult(
        operation: String,
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
    ) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = operation,
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = MutationResultCounts(succeeded, failed, unknown),
        errorCategory = errorCategory,
        localizationKey = "mutation.${operation.lowercase()}.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private fun requireConfirmedFileEntryMutation(result: MutationResult) {
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            throw IllegalArgumentException("Invalid file operation")
        }
        when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> return
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> throw CancellationException("file operation cancelled")
            else -> throw DsmFailure(
                null,
                "The NAS did not confirm the file operation",
                "Refresh the folder and check the item before trying again.",
                kind = when (result.status) {
                    MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                    MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                    else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
                },
            )
        }
    }

    suspend fun delete(paths: List<String>) {
        require(paths.isNotEmpty()) { "No item selected" }
        call(
            "SYNO.FileStation.Delete",
            "start",
            mapOf(
                "path" to jsonStrings(paths),
                "recursive" to "true",
                "accurate_progress" to "true",
            ),
        )
        waitUntil {
            paths.none { pathExists(it) }
        }
    }

    suspend fun deleteResult(paths: List<String>): MutationResult =
        deleteResult(paths, itemBaselines = null)

    @JvmName("deleteItemsResult")
    suspend fun deleteResult(itemBaselines: List<FileItem>): MutationResult =
        deleteResult(
            paths = itemBaselines.map(FileItem::path),
            itemBaselines = itemBaselines.associateBy(FileItem::path)
                .takeIf { it.size == itemBaselines.size },
            requiresItemBaselines = true,
        )

    suspend fun deleteResult(itemBaseline: FileItem, recursive: Boolean = true): MutationResult =
        deleteResult(listOf(itemBaseline.path), mapOf(itemBaseline.path to itemBaseline),
            requiresItemBaselines = true, recursive = recursive)

    private suspend fun deleteResult(
        paths: List<String>,
        itemBaselines: Map<String, FileItem>?,
        requiresItemBaselines: Boolean = false,
        recursive: Boolean = true,
    ): MutationResult {
        val operation = "fileDelete"
        if (!currentCoroutineContext().isActive) {
            return deleteMutationResult(
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.delete.cancelled-before-submission",
            )
        }
        val normalized = paths.distinct().sorted()
        if (normalized.isEmpty() || normalized.any { !isFileMutationPath(it) }) {
            return deleteMutationResult(
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = paths.size,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.delete.invalid-input",
            )
        }
        if (!supports(FILE_STATION_DELETE_API)) {
            return deleteMutationResult(
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = normalized.size,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.delete.unsupported",
            )
        }
        val affectedPaths = normalized.toSet()
        val claimed = claimFilePathMutation(affectedPaths)
        if (!claimed) {
            return deleteMutationResult(
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = normalized.size,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.delete.duplicate-submission",
            )
        }
        try {
            if (requiresItemBaselines) {
                if (itemBaselines?.keys != normalized.toSet()) {
                    return deleteMutationResult(
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = normalized.size,
                        errorCategory = MutationErrorCategory.VALIDATION,
                        diagnosticTag = "file-station.delete.invalid-baseline",
                    )
                }
                var permissionFailures = 0
                var baselineFailures = 0
                var preflightFailures = 0
                var preflightErrorCategory: MutationErrorCategory? = null
                for (path in normalized) {
                    val baseline = checkNotNull(itemBaselines[path])
                    val observed = try {
                        fileInfo(path)
                    } catch (_: CancellationException) {
                        return deleteMutationResult(
                            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                            submitted = false,
                            diagnosticTag = "file-station.delete.cancelled-during-preflight",
                        )
                    } catch (failure: DsmFailure) {
                        if (failure.kind == DsmErrorKind.PERMISSION_DENIED) permissionFailures++
                        else {
                            preflightFailures++
                            preflightErrorCategory = preflightErrorCategory
                                ?: fileMutationErrorCategory(failure)
                        }
                        continue
                    }
                    if (observed == null) baselineFailures++
                    else if (!observed.canDelete) permissionFailures++
                    else if (!observed.matchesMutationBaseline(baseline)) baselineFailures++
                }
                if (permissionFailures + baselineFailures + preflightFailures > 0) {
                    val status = if (permissionFailures > 0) {
                        MutationResultStatus.PERMISSION_DENIED
                    } else {
                        MutationResultStatus.CONFIRMED_FAILURE
                    }
                    val category = when {
                        permissionFailures > 0 -> MutationErrorCategory.PERMISSION
                        baselineFailures > 0 -> MutationErrorCategory.CONFLICT
                        else -> preflightErrorCategory ?: MutationErrorCategory.SERVER
                    }
                    val reason = when {
                        permissionFailures > 0 -> "not-allowed"
                        baselineFailures > 0 -> "baseline-changed"
                        else -> "preflight-failed"
                    }
                    return deleteMutationResult(
                        status,
                        submitted = false,
                        failed = normalized.size,
                        errorCategory = category,
                        diagnosticTag = "file-station.delete.$reason",
                    )
                }
            }
            val start = try {
                call(
                    FILE_STATION_DELETE_API,
                    "start",
                    mapOf(
                        "path" to jsonStrings(normalized),
                        "recursive" to recursive.toString(),
                        "accurate_progress" to "true",
                    ),
                )
            } catch (_: CancellationException) {
                return deleteMutationResult(
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = normalized.size,
                    diagnosticTag = "file-station.delete.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                return if (failure.kind == DsmErrorKind.PERMISSION_DENIED) {
                    deleteMutationResult(
                        MutationResultStatus.PERMISSION_DENIED,
                        submitted = true,
                        failed = normalized.size,
                        errorCategory = MutationErrorCategory.PERMISSION,
                        diagnosticTag = "file-station.delete.permission-denied",
                    )
                } else if (failure.kind in setOf(
                        DsmErrorKind.CONNECTION_FAILED,
                        DsmErrorKind.INVALID_RESPONSE,
                        DsmErrorKind.UNKNOWN,
                    )
                ) {
                    val counts = withContext(NonCancellable) {
                        readBackDeletedPaths(normalized, existingIsUnknown = true)
                    }
                    val status = when {
                        counts.succeeded == normalized.size -> MutationResultStatus.CONFIRMED_SUCCESS
                        counts.succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
                        else -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                    }
                    deleteMutationResult(
                        status,
                        submitted = true,
                        requiresRefresh = counts.unknown > 0,
                        succeeded = counts.succeeded,
                        failed = counts.failed,
                        unknown = counts.unknown,
                        errorCategory = if (counts.unknown > 0) {
                            if (failure.kind == DsmErrorKind.CONNECTION_FAILED) {
                                MutationErrorCategory.NETWORK
                            } else {
                                MutationErrorCategory.SERVER
                            }
                        } else {
                            null
                        },
                        diagnosticTag = "file-station.delete.submission-${status.name.lowercase().replace('_', '-')}",
                    )
                } else {
                    deleteMutationResult(
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = true,
                        failed = normalized.size,
                        errorCategory = fileMutationErrorCategory(failure),
                        diagnosticTag = "file-station.delete.submission-rejected",
                    )
                }
            }
            try {
                pollFileTask(FILE_STATION_DELETE_API, start, "file deletion") { _, _ -> }
            } catch (_: CancellationException) {
                return deleteMutationResult(
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = normalized.size,
                    diagnosticTag = "file-station.delete.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                val counts = withContext(NonCancellable) {
                    readBackDeletedPaths(normalized, existingIsUnknown = true)
                }
                val status = when {
                    counts.succeeded == normalized.size -> MutationResultStatus.CONFIRMED_SUCCESS
                    counts.succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
                    else -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                }
                return deleteMutationResult(
                    status,
                    submitted = true,
                    requiresRefresh = counts.unknown > 0,
                    succeeded = counts.succeeded,
                    failed = counts.failed,
                    unknown = counts.unknown,
                    errorCategory = fileMutationErrorCategory(failure).takeIf {
                        counts.unknown > 0
                    },
                    diagnosticTag = "file-station.delete.task-${status.name.lowercase().replace('_', '-')}",
                )
            }
            var succeeded = 0
            var failed = 0
            var unknown = 0
            for (path in normalized) {
                try {
                    if (fileInfo(path) == null) succeeded++ else failed++
                } catch (_: CancellationException) {
                    return deleteMutationResult(
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        submitted = true,
                        requiresRefresh = true,
                        succeeded = succeeded,
                        failed = failed,
                        unknown = normalized.size - succeeded - failed,
                        diagnosticTag = "file-station.delete.cancelled-during-readback",
                    )
                } catch (_: DsmFailure) {
                    unknown++
                }
            }
            val status = when {
                succeeded == normalized.size -> MutationResultStatus.CONFIRMED_SUCCESS
                succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
                unknown > 0 -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                else -> MutationResultStatus.CONFIRMED_FAILURE
            }
            return deleteMutationResult(
                status,
                submitted = true,
                requiresRefresh = failed + unknown > 0,
                succeeded = succeeded,
                failed = failed,
                unknown = unknown,
                errorCategory = if (unknown > 0) MutationErrorCategory.NETWORK else null,
                diagnosticTag = "file-station.delete.${status.name.lowercase().replace('_', '-')}",
            )
        } finally {
            releaseFilePathMutation(affectedPaths)
        }
    }

    private suspend fun readBackDeletedPaths(
        paths: List<String>,
        existingIsUnknown: Boolean,
    ): MutationResultCounts {
        var succeeded = 0
        var failed = 0
        var unknown = 0
        for (path in paths) {
            try {
                if (fileInfo(path) == null) succeeded++
                else if (existingIsUnknown) unknown++
                else failed++
            } catch (_: DsmFailure) {
                unknown++
            }
        }
        return MutationResultCounts(succeeded, failed, unknown)
    }

    private fun deleteMutationResult(
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
    ) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = "fileDelete",
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = MutationResultCounts(succeeded, failed, unknown),
        errorCategory = errorCategory,
        localizationKey = "mutation.file_delete.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private fun deletionPathsOverlap(left: String, right: String): Boolean =
        left == right || left.startsWith("$right/") || right.startsWith("$left/")

    private suspend fun claimFilePathMutation(paths: Set<String>): Boolean =
        filePathMutationLock.withLock {
            if (activeFilePathMutations.any { active ->
                    active.any { left -> paths.any { right -> deletionPathsOverlap(left, right) } }
                }
            ) {
                false
            } else {
                activeFilePathMutations += paths
                true
            }
        }

    private suspend fun releaseFilePathMutation(paths: Set<String>) {
        filePathMutationLock.withLock { activeFilePathMutations.remove(paths) }
    }

    internal suspend fun move(path: String, destinationFolder: String) =
        copyOrMove(listOf(path), destinationFolder, removeSource = true)

    internal suspend fun move(paths: List<String>, destinationFolder: String) =
        copyOrMove(paths, destinationFolder, removeSource = true)

    internal suspend fun copy(paths: List<String>, destinationFolder: String) =
        copyOrMove(paths, destinationFolder, removeSource = false)

    internal suspend fun moveResult(path: String, destinationFolder: String): MutationResult =
        copyOrMoveResult(listOf(path), destinationFolder, removeSource = true)

    internal suspend fun moveResult(paths: List<String>, destinationFolder: String): MutationResult =
        copyOrMoveResult(paths, destinationFolder, removeSource = true)

    internal suspend fun copyResult(paths: List<String>, destinationFolder: String): MutationResult =
        copyOrMoveResult(paths, destinationFolder, removeSource = false)

    suspend fun moveResult(
        sourceBaselines: List<FileItem>,
        destinationBaseline: FileItem,
    ): MutationResult = copyOrMoveResult(
        paths = sourceBaselines.map(FileItem::path),
        destinationFolder = destinationBaseline.path,
        removeSource = true,
        sourceBaselines = sourceBaselines.associateBy(FileItem::path),
        destinationBaseline = destinationBaseline,
    )

    suspend fun copyResult(
        sourceBaselines: List<FileItem>,
        destinationBaseline: FileItem,
    ): MutationResult = copyOrMoveResult(
        paths = sourceBaselines.map(FileItem::path),
        destinationFolder = destinationBaseline.path,
        removeSource = false,
        sourceBaselines = sourceBaselines.associateBy(FileItem::path),
        destinationBaseline = destinationBaseline,
    )

    private suspend fun copyOrMove(
        paths: List<String>,
        destinationFolder: String,
        removeSource: Boolean,
        preflight: Boolean = true,
    ) {
        val result = copyOrMoveResult(paths, destinationFolder, removeSource, preflight)
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            throw IllegalArgumentException("Invalid copy or move request")
        }
        when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> return
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> throw CancellationException("file copy or move cancelled")
            else -> throw DsmFailure(
                null,
                "The NAS did not confirm the file operation",
                "Refresh both folders and check the items before trying again.",
                kind = when (result.status) {
                    MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                    MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                    else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
                },
            )
        }
    }

    private suspend fun copyOrMoveResult(
        paths: List<String>,
        destinationFolder: String,
        removeSource: Boolean,
        preflight: Boolean = true,
        sourceBaselines: Map<String, FileItem>? = null,
        destinationBaseline: FileItem? = null,
    ): MutationResult {
        val operation = if (removeSource) "fileMove" else "fileCopy"
        if (!currentCoroutineContext().isActive) {
            return copyMoveMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.copy-move.cancelled-before-submission",
            )
        }
        val normalized = paths.distinct().sorted()
        val destination = if (destinationFolder == "/") "/" else destinationFolder.trimEnd('/')
        val invalid = normalized.isEmpty() ||
            normalized.any { !isFileMutationPath(it) } ||
            !isFileMutationPath(destination, allowRoot = true) ||
            normalized.map { it.substringAfterLast('/') }.distinct().size != normalized.size ||
            normalized.any { path ->
                path.substringBeforeLast('/', "").ifEmpty { "/" } == destination ||
                    destination.startsWith("$path/")
            }
        if (invalid) {
            return copyMoveMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = paths.size,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.copy-move.invalid-input",
            )
        }
        if (!supports(FILE_STATION_COPY_MOVE_API)) {
            return copyMoveMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = normalized.size,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.copy-move.unsupported",
            )
        }
        val targets = normalized.mapTo(mutableSetOf()) { path ->
            join(destination, path.substringAfterLast('/'))
        }
        val affectedPaths = (normalized + targets).toSet()
        val claimed = claimFilePathMutation(affectedPaths)
        if (!claimed) {
            return copyMoveMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = normalized.size,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.copy-move.duplicate-submission",
            )
        }
        try {
            if (preflight) {
                val destinationItem = try {
                    fileInfo(destination)
                } catch (_: CancellationException) {
                    return copyMoveMutationResult(
                        operation,
                        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        submitted = false,
                        diagnosticTag = "file-station.copy-move.cancelled-before-submission",
                    )
                } catch (failure: DsmFailure) {
                    return copyMoveMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = normalized.size,
                        errorCategory = fileMutationErrorCategory(failure),
                        diagnosticTag = "file-station.copy-move.preflight-failed",
                    )
                }
                if (destinationItem == null || !destinationItem.isDirectory) {
                    return copyMoveMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = normalized.size,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.copy-move.destination-missing",
                    )
                }
                if (destinationBaseline != null &&
                    !destinationItem.matchesMutationBaseline(destinationBaseline)
                ) {
                    return copyMoveMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = normalized.size,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.copy-move.destination-baseline-changed",
                    )
                }
                if (!destinationItem.canWrite) {
                    return copyMoveMutationResult(
                        operation,
                        MutationResultStatus.PERMISSION_DENIED,
                        submitted = false,
                        failed = normalized.size,
                        errorCategory = MutationErrorCategory.PERMISSION,
                        diagnosticTag = "file-station.copy-move.destination-read-only",
                    )
                }
                if (sourceBaselines != null) {
                    if (sourceBaselines.keys != normalized.toSet()) {
                        return copyMoveMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_FAILURE,
                            submitted = false,
                            failed = normalized.size,
                            errorCategory = MutationErrorCategory.VALIDATION,
                            diagnosticTag = "file-station.copy-move.invalid-baseline",
                        )
                    }
                    for (path in normalized) {
                        val observed = try {
                            fileInfo(path)
                        } catch (_: CancellationException) {
                            return copyMoveMutationResult(
                                operation,
                                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                                submitted = false,
                                diagnosticTag = "file-station.copy-move.cancelled-before-submission",
                            )
                        } catch (failure: DsmFailure) {
                            return copyMoveMutationResult(
                                operation,
                                MutationResultStatus.CONFIRMED_FAILURE,
                                submitted = false,
                                failed = normalized.size,
                                errorCategory = fileMutationErrorCategory(failure),
                                diagnosticTag = "file-station.copy-move.preflight-failed",
                            )
                        }
                        if (observed == null ||
                            !observed.matchesMutationBaseline(checkNotNull(sourceBaselines[path]))
                        ) {
                            return copyMoveMutationResult(
                                operation,
                                MutationResultStatus.CONFIRMED_FAILURE,
                                submitted = false,
                                failed = normalized.size,
                                errorCategory = MutationErrorCategory.CONFLICT,
                                diagnosticTag = "file-station.copy-move.source-baseline-changed",
                            )
                        }
                        if (removeSource && !observed.canDelete) {
                            return copyMoveMutationResult(
                                operation,
                                MutationResultStatus.PERMISSION_DENIED,
                                submitted = false,
                                failed = normalized.size,
                                errorCategory = MutationErrorCategory.PERMISSION,
                                diagnosticTag = "file-station.copy-move.source-not-deletable",
                            )
                        }
                    }
                }
                for (target in targets) {
                    val exists = try {
                        itemExists(target)
                    } catch (_: CancellationException) {
                        return copyMoveMutationResult(
                            operation,
                            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                            submitted = false,
                            diagnosticTag = "file-station.copy-move.cancelled-before-submission",
                        )
                    } catch (failure: DsmFailure) {
                        return copyMoveMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_FAILURE,
                            submitted = false,
                            failed = normalized.size,
                            errorCategory = fileMutationErrorCategory(failure),
                            diagnosticTag = "file-station.copy-move.preflight-failed",
                        )
                    }
                    if (exists) {
                        return copyMoveMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_FAILURE,
                            submitted = false,
                            failed = normalized.size,
                            errorCategory = MutationErrorCategory.CONFLICT,
                            diagnosticTag = "file-station.copy-move.name-conflict",
                        )
                    }
                }
            }
            val start = try {
                call(
                    FILE_STATION_COPY_MOVE_API,
                    "start",
                    mapOf(
                        "path" to jsonStrings(normalized),
                        "dest_folder_path" to destination,
                        "remove_src" to removeSource.toString(),
                        "overwrite" to "false",
                        "accurate_progress" to "true",
                    ),
                )
            } catch (_: CancellationException) {
                return copyMoveMutationResult(
                    operation,
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = normalized.size,
                    diagnosticTag = "file-station.copy-move.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                return if (failure.kind == DsmErrorKind.PERMISSION_DENIED) {
                    copyMoveMutationResult(
                        operation,
                        MutationResultStatus.PERMISSION_DENIED,
                        submitted = true,
                        failed = normalized.size,
                        errorCategory = MutationErrorCategory.PERMISSION,
                        diagnosticTag = "file-station.copy-move.permission-denied",
                    )
                } else {
                    copyMoveMutationResult(
                        operation,
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = normalized.size,
                        errorCategory = fileMutationErrorCategory(failure),
                        diagnosticTag = "file-station.copy-move.submission-unverified",
                    )
                }
            }
            val taskId = start.string("taskid") ?: return copyMoveMutationResult(
                operation,
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                submitted = true,
                requiresRefresh = true,
                unknown = normalized.size,
                errorCategory = MutationErrorCategory.SERVER,
                diagnosticTag = "file-station.copy-move.missing-task-id",
            )
            try {
                var finished = false
                var pollCount = 0
                while (!finished && pollCount < MAX_COPY_MOVE_POLLS) {
                    val status = call(
                        FILE_STATION_COPY_MOVE_API,
                        "status",
                        mapOf("taskid" to taskId),
                    )
                    finished = status.bool("finished") == true
                    pollCount++
                    if (!finished) delay(COPY_MOVE_POLL_INTERVAL_MILLIS)
                }
                if (!finished) {
                    return copyMoveMutationResult(
                        operation,
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = normalized.size,
                        errorCategory = MutationErrorCategory.SERVER,
                        diagnosticTag = "file-station.copy-move.task-timeout",
                    )
                }
            } catch (_: CancellationException) {
                withContext(NonCancellable) {
                    runCatching {
                        call(FILE_STATION_COPY_MOVE_API, "stop", mapOf("taskid" to taskId))
                    }
                }
                return copyMoveMutationResult(
                    operation,
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = normalized.size,
                    diagnosticTag = "file-station.copy-move.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                return copyMoveMutationResult(
                    operation,
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = normalized.size,
                    errorCategory = fileMutationErrorCategory(failure),
                    diagnosticTag = "file-station.copy-move.task-unverified",
                )
            }
            var succeeded = 0
            var failed = 0
            var unknown = 0
            for (path in normalized) {
                try {
                    val targetPath = join(destination, path.substringAfterLast('/'))
                    val confirmed = sourceBaselines?.get(path)?.let { baseline ->
                        val sourceExists = if (removeSource) fileInfo(path) != null else false
                        val target = fileInfo(targetPath)
                        target?.matchesMutationOutcome(baseline, targetPath) == true &&
                            (!removeSource || !sourceExists)
                    } ?: run {
                        val sourceExists = if (removeSource) itemExists(path) else false
                        itemExists(targetPath) && (!removeSource || !sourceExists)
                    }
                    if (confirmed) succeeded++ else failed++
                } catch (_: CancellationException) {
                    return copyMoveMutationResult(
                        operation,
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        submitted = true,
                        requiresRefresh = true,
                        succeeded = succeeded,
                        unknown = normalized.size - succeeded,
                        diagnosticTag = "file-station.copy-move.cancelled-during-readback",
                    )
                } catch (_: DsmFailure) {
                    unknown++
                }
            }
            val status = when {
                succeeded == normalized.size -> MutationResultStatus.CONFIRMED_SUCCESS
                succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
                unknown > 0 -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                else -> MutationResultStatus.CONFIRMED_FAILURE
            }
            return copyMoveMutationResult(
                operation,
                status,
                submitted = true,
                requiresRefresh = failed + unknown > 0,
                succeeded = succeeded,
                failed = failed,
                unknown = unknown,
                errorCategory = if (unknown > 0) MutationErrorCategory.NETWORK else null,
                diagnosticTag = "file-station.copy-move.${status.name.lowercase().replace('_', '-')}",
            )
        } finally {
            releaseFilePathMutation(affectedPaths)
        }
    }

    private fun copyMoveMutationResult(
        operation: String,
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
    ) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = operation,
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = MutationResultCounts(succeeded, failed, unknown),
        errorCategory = errorCategory,
        localizationKey = "mutation.${operation.lowercase()}.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private fun fileMutationErrorCategory(failure: DsmFailure): MutationErrorCategory = when (failure.kind) {
        DsmErrorKind.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
        DsmErrorKind.CONNECTION_FAILED -> MutationErrorCategory.NETWORK
        DsmErrorKind.FEATURE_UNSUPPORTED,
        DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
        -> MutationErrorCategory.UNSUPPORTED
        else -> MutationErrorCategory.SERVER
    }

    internal suspend fun restoreFromRecycle(path: String): String {
        val location = RecycleLocation.from(path)
            ?: throw IllegalArgumentException("The item is not in a supported recycle path")
        requireConfirmedFileEntryMutation(restoreFromRecycleResult(path))
        return location.originalPath
    }

    internal suspend fun restoreFromRecycleResult(path: String): MutationResult {
        return restoreFromRecycleResult(path, sourceBaseline = null)
    }

    suspend fun restoreFromRecycleResult(sourceBaseline: FileItem): MutationResult =
        restoreFromRecycleResult(sourceBaseline.path, sourceBaseline)

    private suspend fun restoreFromRecycleResult(
        path: String,
        sourceBaseline: FileItem?,
    ): MutationResult {
        val location = RecycleLocation.from(path)
            ?: return fileEntryMutationResult(
                operation = "fileRestore",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.restore.invalid-input",
            )
        val result = copyOrMoveResult(
            paths = listOf(path),
            destinationFolder = location.originalParentPath,
            removeSource = true,
            preflight = true,
            sourceBaselines = sourceBaseline?.let { mapOf(it.path to it) },
        )
        return result.copy(
            operation = "fileRestore",
            localizationKey = "mutation.filerestore.${result.status.name.lowercase()}",
            diagnosticTag = result.diagnosticTag?.replace("copy-move", "restore"),
        )
    }

    suspend fun compress(
        paths: List<String>,
        destinationFilePath: String,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel,
        password: String? = null,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ) {
        requireConfirmedArchiveMutation(
            compressResult(paths, destinationFilePath, format, level, password, onProgress),
        )
    }

    suspend fun compressResult(
        paths: List<String>,
        destinationFilePath: String,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel,
        password: String? = null,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
        onBeforeSubmit: () -> Unit = {},
        onTaskStarted: (String) -> Unit = {},
    ): MutationResult = compressResultInternal(
        paths = paths,
        sourceBaselines = null,
        destinationBaseline = null,
        destinationFilePath = destinationFilePath,
        format = format,
        level = level,
        password = password,
        onProgress = onProgress,
        onBeforeSubmit = onBeforeSubmit,
        onTaskStarted = onTaskStarted,
    )

    suspend fun compressResult(
        sourceBaselines: List<FileItem>,
        destinationBaseline: FileItem,
        destinationFilePath: String,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel,
        password: String? = null,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
        onBeforeSubmit: () -> Unit = {},
        onTaskStarted: (String) -> Unit = {},
    ): MutationResult = compressResultInternal(
        paths = sourceBaselines.map(FileItem::path),
        sourceBaselines = sourceBaselines,
        destinationBaseline = destinationBaseline,
        destinationFilePath = destinationFilePath,
        format = format,
        level = level,
        password = password,
        onProgress = onProgress,
        onBeforeSubmit = onBeforeSubmit,
        onTaskStarted = onTaskStarted,
    )

    private suspend fun compressResultInternal(
        paths: List<String>,
        sourceBaselines: List<FileItem>?,
        destinationBaseline: FileItem?,
        destinationFilePath: String,
        format: ArchiveFormat,
        level: ArchiveCompressionLevel,
        password: String?,
        onProgress: (Long, Long?) -> Unit,
        onBeforeSubmit: () -> Unit,
        onTaskStarted: (String) -> Unit,
    ): MutationResult {
        val normalizedPaths = paths.distinct()
        val target = destinationFilePath
        val parent = target.substringBeforeLast('/', "")
        val sourceBaselinesByPath = sourceBaselines?.associateBy(FileItem::path)
        val valid = normalizedPaths.isNotEmpty() &&
            normalizedPaths.size == paths.size &&
            normalizedPaths.all { isFileMutationPath(it) && it != target } &&
            isFileMutationPath(target) &&
            parent.isNotBlank() &&
            (sourceBaselines == null ||
                sourceBaselines.size == normalizedPaths.size &&
                sourceBaselinesByPath?.keys == normalizedPaths.toSet()) &&
            (destinationBaseline == null ||
                destinationBaseline.path == parent && destinationBaseline.isDirectory) &&
            target.substringAfterLast('/').lowercase(Locale.ROOT)
                .endsWith(".${format.fileExtension.lowercase(Locale.ROOT)}")
        if (!valid) {
            return archiveMutationResult(
                operation = "archiveCompress",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.archive-compress.invalid-input",
            )
        }
        if (capabilities[FILE_STATION_COMPRESS_API]?.maxVersion?.let { it >= 3 } != true) {
            return archiveMutationResult(
                operation = "archiveCompress",
                status = MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.archive-compress.unsupported",
            )
        }
        val affectedPaths = (normalizedPaths + target).toSet()
        if (!claimFilePathMutation(affectedPaths)) {
            return archiveMutationResult(
                operation = "archiveCompress",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.archive-compress.duplicate-submission",
            )
        }
        try {
            val destination = try {
                fileInfo(parent)
            } catch (_: CancellationException) {
                return archiveCancelledBeforeSubmission("archiveCompress", "archive-compress")
            } catch (failure: DsmFailure) {
                return archivePreflightFailure("archiveCompress", "archive-compress", failure)
            }
            if (destination == null || !destination.isDirectory) {
                return archiveMutationResult(
                    operation = "archiveCompress",
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.archive-compress.destination-missing",
                )
            }
            if (destinationBaseline != null && !destination.matchesMutationBaseline(destinationBaseline)) {
                return archiveMutationResult(
                    operation = "archiveCompress",
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.archive-compress.destination-baseline-drift",
                )
            }
            if (!destination.canWrite) {
                return archiveMutationResult(
                    operation = "archiveCompress",
                    status = MutationResultStatus.PERMISSION_DENIED,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.PERMISSION,
                    diagnosticTag = "file-station.archive-compress.destination-read-only",
                )
            }
            if (sourceBaselinesByPath != null) {
                for (path in normalizedPaths) {
                    val observed = try {
                        fileInfo(path)
                    } catch (_: CancellationException) {
                        return archiveCancelledBeforeSubmission("archiveCompress", "archive-compress")
                    } catch (failure: DsmFailure) {
                        return archivePreflightFailure("archiveCompress", "archive-compress", failure)
                    }
                    if (observed == null ||
                        !observed.matchesMutationBaseline(checkNotNull(sourceBaselinesByPath[path]))
                    ) {
                        return archiveMutationResult(
                            operation = "archiveCompress",
                            status = MutationResultStatus.CONFIRMED_FAILURE,
                            submitted = false,
                            failed = 1,
                            errorCategory = MutationErrorCategory.CONFLICT,
                            diagnosticTag = "file-station.archive-compress.source-baseline-drift",
                        )
                    }
                }
            }
            val targetExists = try {
                itemExists(target)
            } catch (_: CancellationException) {
                return archiveCancelledBeforeSubmission("archiveCompress", "archive-compress")
            } catch (failure: DsmFailure) {
                return archivePreflightFailure("archiveCompress", "archive-compress", failure)
            }
            if (targetExists) {
                return archiveMutationResult(
                    operation = "archiveCompress",
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.archive-compress.target-exists",
                )
            }
            return runArchiveMutationTask(
                operation = "archiveCompress",
                diagnosticOperation = "archive-compress",
                apiName = FILE_STATION_COMPRESS_API,
                expectedOutputs = listOf(
                    ArchiveExpectedOutput(target, isDirectory = false, requiresNonEmptyFile = true),
                ),
                onProgress = onProgress,
                onBeforeSubmit = onBeforeSubmit,
                onTaskStarted = onTaskStarted,
            ) {
                call(
                    FILE_STATION_COMPRESS_API,
                    "start",
                    buildMap {
                        put("path", jsonStrings(normalizedPaths))
                        put("dest_file_path", target)
                        put("level", level.apiValue)
                        put("mode", "add")
                        put("format", format.apiValue)
                        password?.takeIf(String::isNotEmpty)?.let { put("password", it) }
                    },
                )
            }
        } finally {
            releaseFilePathMutation(affectedPaths)
        }
    }

    private val archiveReader by lazy { FileArchiveReader { parameters ->
        if (!supportsExtraction()) throw DsmFailure(null, "Archive browsing is unavailable", "Choose another archive.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        call(FILE_STATION_EXTRACT_API, "list", parameters, version = 2)
    } }

    suspend fun listArchivePage(filePath: String, parentId: Int = -1, offset: Int = 0, limit: Int = 200,
                               codepage: String? = null, password: String? = null): ArchiveItemPage =
        archiveReader.page(filePath, parentId, offset, limit, codepage, password)

    suspend fun listArchiveItems(filePath: String, codepage: String? = null, password: String? = null): List<ArchiveItem> =
        archiveReader.children(filePath, codepage = codepage, password = password)

    suspend fun extractResult(request: FileExtractionRequest,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
        onExpectedOutputs: (List<FileServerMutationExpectedOutput>) -> Unit = {},
        onBeforeSubmit: () -> Unit = {}, onTaskStarted: (String) -> Unit = {},
    ): MutationResult = extractResultInternal(request.source.path, request.destination.path, request.source, request.destination,
        request.options.password, request.options.codepage, onProgress, onExpectedOutputs, onBeforeSubmit, onTaskStarted, request.options)

    suspend fun extract(
        filePath: String,
        destinationFolder: String,
        password: String? = null,
        codepage: String? = null,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ) {
        requireConfirmedArchiveMutation(
            extractResult(filePath, destinationFolder, password, codepage, onProgress),
        )
    }

    suspend fun extractResult(
        filePath: String,
        destinationFolder: String,
        password: String? = null,
        codepage: String? = null,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
        onBeforeSubmit: () -> Unit = {},
        onTaskStarted: (String) -> Unit = {},
    ): MutationResult = extractResultInternal(
        filePath = filePath,
        destinationFolder = destinationFolder,
        sourceBaseline = null,
        destinationBaseline = null,
        password = password,
        codepage = codepage,
        onProgress = onProgress,
        onExpectedOutputs = {},
        onBeforeSubmit = onBeforeSubmit,
        onTaskStarted = onTaskStarted,
    )

    suspend fun extractResult(
        sourceBaseline: FileItem,
        destinationBaseline: FileItem,
        password: String? = null,
        codepage: String? = null,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
        onExpectedOutputs: (List<FileServerMutationExpectedOutput>) -> Unit = {},
        onBeforeSubmit: () -> Unit = {},
        onTaskStarted: (String) -> Unit = {},
    ): MutationResult = extractResultInternal(
        filePath = sourceBaseline.path,
        destinationFolder = destinationBaseline.path,
        sourceBaseline = sourceBaseline,
        destinationBaseline = destinationBaseline,
        password = password,
        codepage = codepage,
        onProgress = onProgress,
        onExpectedOutputs = onExpectedOutputs,
        onBeforeSubmit = onBeforeSubmit,
        onTaskStarted = onTaskStarted,
    )

    private suspend fun extractResultInternal(
        filePath: String, destinationFolder: String, sourceBaseline: FileItem?, destinationBaseline: FileItem?,
        password: String?, codepage: String?, onProgress: (Long, Long?) -> Unit,
        onExpectedOutputs: (List<FileServerMutationExpectedOutput>) -> Unit,
        onBeforeSubmit: () -> Unit, onTaskStarted: (String) -> Unit,
        options: FileExtractionOptions = FileExtractionOptions(password = password, codepage = codepage),
    ): MutationResult {
        fun rejected(category: MutationErrorCategory, detail: String, status: MutationResultStatus = MutationResultStatus.CONFIRMED_FAILURE) =
            archiveMutationResult("archiveExtract", status, submitted = false, failed = 1, errorCategory = category,
                diagnosticTag = "file-station.archive-extract.$detail")
        val sourcePath = filePath
        val destinationPath = destinationFolder
        if (!options.isValid || !isFileMutationPath(sourcePath) || !isFileMutationPath(destinationPath) ||
            sourcePath == destinationPath || sourceBaseline?.let { it.path != sourcePath || it.isDirectory } == true ||
            destinationBaseline?.let { it.path != destinationPath || !it.isDirectory } == true
        ) return rejected(MutationErrorCategory.VALIDATION, "invalid-input")
        if (!supportsExtraction()) return rejected(MutationErrorCategory.UNSUPPORTED, "unsupported", MutationResultStatus.UNSUPPORTED)
        val affectedPaths = setOf(sourcePath, destinationPath)
        if (!claimFilePathMutation(affectedPaths)) return rejected(MutationErrorCategory.CONFLICT, "duplicate-submission")
        try {
            val destination = fileInfo(destinationPath)
            if (destination == null || !destination.isDirectory) return rejected(MutationErrorCategory.CONFLICT, "destination-missing")
            if (destinationBaseline != null && !destination.matchesMutationBaseline(destinationBaseline)) return rejected(MutationErrorCategory.CONFLICT, "destination-baseline-drift")
            if (!destination.canWrite) return rejected(MutationErrorCategory.PERMISSION, "destination-read-only", MutationResultStatus.PERMISSION_DENIED)
            // 旧路径入口也重新检查源文件读取权限，不能依赖归档列表接口的存在。
            val source = fileInfo(sourcePath)
            if (source == null || source.isDirectory || sourceBaseline != null && !source.matchesMutationBaseline(sourceBaseline)) return rejected(MutationErrorCategory.CONFLICT, "source-baseline-drift")
            if (!source.canRead) return rejected(MutationErrorCategory.PERMISSION, "source-read-only", MutationResultStatus.PERMISSION_DENIED)
            val inventory = archiveReader.inventory(sourcePath, options)
            var outputs = extractionOutputs(sourcePath, destinationPath, options, inventory)
            val existing = outputs.associate { it.path to fileInfo(it.path) }
            for (output in outputs) {
                val current = existing[output.path] ?: continue
                if (current.isDirectory != output.isDirectory || !output.isDirectory && !options.overwrite) return rejected(MutationErrorCategory.CONFLICT, "target-exists")
                if (!current.canWrite) return rejected(MutationErrorCategory.PERMISSION, "target-read-only", MutationResultStatus.PERMISSION_DENIED)
            }
            // 已有目录和覆盖文件不能用其旧存在状态确认本次解压完成。
            outputs = outputs.map { it.copy(requiresTaskCompletion = it.requiresTaskCompletion || existing[it.path] != null) }
            onExpectedOutputs(outputs)
            val expectedOutputs = outputs.map { it.toArchiveExpectedOutput() }
            return runArchiveMutationTask("archiveExtract", "archive-extract", FILE_STATION_EXTRACT_API,
                expectedOutputs, onProgress, onBeforeSubmit, onTaskStarted) {
                call(FILE_STATION_EXTRACT_API, "start", buildMap {
                    put("file_path", sourcePath); put("dest_folder_path", destinationPath)
                    put("overwrite", options.overwrite.toString()); put("keep_dir", options.keepDirectories.toString())
                    put("create_subfolder", options.createSubfolder.toString())
                    (options.selection as? FileArchiveSelection.Items)?.let { selected -> put("item_id", selected.items.map(ArchiveItem::id).sorted().joinToString(",")) }
                    options.codepage?.takeIf(String::isNotEmpty)?.let { put("codepage", it) }
                    options.password?.takeIf(String::isNotEmpty)?.let { put("password", it) }
                }, version = 2)
            }
        } catch (_: CancellationException) {
            return archiveCancelledBeforeSubmission("archiveExtract", "archive-extract")
        } catch (failure: DsmFailure) {
            return archivePreflightFailure("archiveExtract", "archive-extract", failure)
        } finally { releaseFilePathMutation(affectedPaths) }
    }

    private suspend fun runArchiveMutationTask(
        operation: String,
        diagnosticOperation: String,
        apiName: String,
        expectedOutputs: List<ArchiveExpectedOutput>,
        onProgress: (Long, Long?) -> Unit,
        onBeforeSubmit: () -> Unit,
        onTaskStarted: (String) -> Unit,
        submit: suspend () -> JsonObject,
    ): MutationResult {
        val start = try {
            onBeforeSubmit()
            submit()
        } catch (_: CancellationException) {
            val confirmed = withContext(NonCancellable) {
                runCatching { archiveReadbackCount(expectedOutputs) }.getOrDefault(0)
            }
            return archiveResultAfterCancellation(operation, diagnosticOperation, confirmed, expectedOutputs.size)
        } catch (failure: DsmFailure) {
            val category = archiveMutationErrorCategory(failure)
            if (category in setOf(MutationErrorCategory.PERMISSION, MutationErrorCategory.AUTHENTICATION)) {
                return archiveMutationResult(
                    operation,
                    MutationResultStatus.PERMISSION_DENIED,
                    submitted = true,
                    failed = expectedOutputs.size,
                    errorCategory = category,
                    diagnosticTag = "file-station.$diagnosticOperation.permission-denied",
                )
            }
            if (category == MutationErrorCategory.UNSUPPORTED) {
                return archiveMutationResult(
                    operation,
                    MutationResultStatus.UNSUPPORTED,
                    submitted = true,
                    failed = expectedOutputs.size,
                    errorCategory = category,
                    diagnosticTag = "file-station.$diagnosticOperation.unsupported",
                )
            }
            val submissionUncertain = failure.kind in setOf(
                DsmErrorKind.CONNECTION_FAILED,
                DsmErrorKind.INVALID_RESPONSE,
                DsmErrorKind.UNKNOWN,
            )
            if (!submissionUncertain) {
                return archiveMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = true,
                    failed = expectedOutputs.size,
                    errorCategory = category,
                    diagnosticTag = "file-station.$diagnosticOperation.rejected",
                )
            }
            val confirmed = try {
                archiveReadbackCount(expectedOutputs)
            } catch (_: CancellationException) {
                return archiveResultAfterCancellation(operation, diagnosticOperation, 0, expectedOutputs.size)
            } catch (_: DsmFailure) {
                0
            }
            if (confirmed > 0) {
                return archiveResultFromReadback(operation, diagnosticOperation, confirmed, expectedOutputs.size)
            }
            return archiveMutationResult(
                operation,
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                submitted = true,
                requiresRefresh = true,
                unknown = expectedOutputs.size,
                errorCategory = category,
                diagnosticTag = "file-station.$diagnosticOperation.submission-unverified",
            )
        }
        val taskId = start.string("taskid")
        if (taskId == null) {
            val confirmed = runCatching { archiveReadbackCount(expectedOutputs) }.getOrDefault(0)
            return if (confirmed > 0) {
                archiveResultFromReadback(operation, diagnosticOperation, confirmed, expectedOutputs.size)
            } else {
                archiveMutationResult(
                    operation,
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = expectedOutputs.size,
                    errorCategory = MutationErrorCategory.SERVER,
                    diagnosticTag = "file-station.$diagnosticOperation.task-id-missing",
                )
            }
        }
        onTaskStarted(taskId)
        try {
            repeat(MAX_FILE_TASK_POLLS) {
                val status = call(apiName, "status", mapOf("taskid" to taskId))
                val processed = status.long("processed_size") ?: status.long("processedSize")
                val total = status.long("total") ?: status.long("total_size")
                if (processed != null) {
                    onProgress(processed, total)
                } else {
                    status["progress"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()?.let { raw ->
                        onProgress(if (raw <= 1.0) (raw * 100).toLong() else raw.toLong(), 100)
                    }
                }
                if (status.bool("finished") == true) {
                    val confirmed = archiveReadbackCount(
                        expectedOutputs,
                        DOWNLOAD_MUTATION_READBACK_ATTEMPTS,
                        taskFinished = true,
                    )
                    return archiveResultFromReadback(
                        operation,
                        diagnosticOperation,
                        confirmed,
                        expectedOutputs.size,
                    )
                }
                delay(FILE_TASK_POLL_INTERVAL_MILLIS)
            }
            return archiveMutationResult(
                operation,
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                submitted = true,
                requiresRefresh = true,
                unknown = expectedOutputs.size,
                errorCategory = MutationErrorCategory.SERVER,
                diagnosticTag = "file-station.$diagnosticOperation.task-timeout",
            )
        } catch (_: CancellationException) {
            withContext(NonCancellable) {
                runCatching { call(apiName, "stop", mapOf("taskid" to taskId)) }
            }
            val confirmed = withContext(NonCancellable) {
                runCatching { archiveReadbackCount(expectedOutputs) }.getOrDefault(0)
            }
            return archiveResultAfterCancellation(
                operation,
                diagnosticOperation,
                confirmed,
                expectedOutputs.size,
            )
        } catch (failure: DsmFailure) {
            val confirmed = try {
                archiveReadbackCount(expectedOutputs)
            } catch (_: CancellationException) {
                return archiveResultAfterCancellation(operation, diagnosticOperation, 0, expectedOutputs.size)
            } catch (_: DsmFailure) {
                return archiveMutationResult(
                    operation,
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = expectedOutputs.size,
                    errorCategory = archiveMutationErrorCategory(failure),
                    diagnosticTag = "file-station.$diagnosticOperation.readback-failed",
                )
            }
            return if (confirmed > 0) {
                archiveResultFromReadback(operation, diagnosticOperation, confirmed, expectedOutputs.size)
            } else {
                archiveMutationResult(
                    operation,
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = expectedOutputs.size,
                    errorCategory = archiveMutationErrorCategory(failure),
                    diagnosticTag = "file-station.$diagnosticOperation.status-unverified",
                )
            }
        }
    }

    /**
     * 进程重建后只观察已经提交的压缩/解压任务；不会再次发送 start，也不会在观察取消时
     * 自动停止 NAS 任务。最终结果仍以目标回读为准，finished 本身不等同于成功。
     */
    suspend fun resumeArchiveMutationResult(
        operation: FileServerMutationOperation,
        taskId: String,
        expectedOutputs: List<FileServerMutationExpectedOutput>,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ): MutationResult {
        val stableTaskId = taskId.trim()
        val outputs = expectedOutputs.map {
            it.toArchiveExpectedOutput()
        }
        val operationName = when (operation) {
            FileServerMutationOperation.COMPRESS -> "archiveCompress"
            FileServerMutationOperation.EXTRACT -> "archiveExtract"
        }
        val diagnosticOperation = when (operation) {
            FileServerMutationOperation.COMPRESS -> "archive-compress"
            FileServerMutationOperation.EXTRACT -> "archive-extract"
        }
        val apiName = when (operation) {
            FileServerMutationOperation.COMPRESS -> FILE_STATION_COMPRESS_API
            FileServerMutationOperation.EXTRACT -> FILE_STATION_EXTRACT_API
        }
        if (stableTaskId.isBlank() || outputs.isEmpty()) {
            return archiveMutationResult(
                operation = operationName,
                status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                submitted = true,
                requiresRefresh = true,
                unknown = outputs.size.coerceAtLeast(1),
                errorCategory = MutationErrorCategory.SERVER,
                diagnosticTag = "file-station.$diagnosticOperation.restore-evidence-missing",
            )
        }
        return try {
            repeat(MAX_FILE_TASK_POLLS) {
                val status = call(apiName, "status", mapOf("taskid" to stableTaskId))
                val processed = status.long("processed_size") ?: status.long("processedSize")
                val total = status.long("total") ?: status.long("total_size")
                if (processed != null) {
                    onProgress(processed, total)
                } else {
                    status["progress"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()?.let { raw ->
                        onProgress(if (raw <= 1.0) (raw * 100).toLong() else raw.toLong(), 100)
                    }
                }
                if (status.bool("finished") == true) {
                    val confirmed = archiveReadbackCount(outputs, DOWNLOAD_MUTATION_READBACK_ATTEMPTS, taskFinished = true)
                    return archiveResultFromReadback(
                        operationName,
                        diagnosticOperation,
                        confirmed,
                        outputs.size,
                    )
                }
                delay(FILE_TASK_POLL_INTERVAL_MILLIS)
            }
            archiveMutationResult(
                operation = operationName,
                status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                submitted = true,
                requiresRefresh = true,
                unknown = outputs.size,
                errorCategory = MutationErrorCategory.SERVER,
                diagnosticTag = "file-station.$diagnosticOperation.restore-task-timeout",
            )
        } catch (error: CancellationException) {
            throw error
        } catch (failure: DsmFailure) {
            val confirmed = runCatching { archiveReadbackCount(outputs) }.getOrDefault(0)
            if (confirmed > 0) {
                archiveResultFromReadback(
                    operationName,
                    diagnosticOperation,
                    confirmed,
                    outputs.size,
                )
            } else {
                archiveMutationResult(
                    operation = operationName,
                    status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = outputs.size,
                    errorCategory = archiveMutationErrorCategory(failure),
                    diagnosticTag = "file-station.$diagnosticOperation.restore-status-unverified",
                )
            }
        }
    }

    private data class ArchiveExpectedOutput(
        val path: String,
        val isDirectory: Boolean,
        val requiresNonEmptyFile: Boolean = false,
        val expectedBytes: Long? = null,
        val requiresTaskCompletion: Boolean = false,
    )

    private fun FileServerMutationExpectedOutput.toArchiveExpectedOutput() =
        ArchiveExpectedOutput(path, isDirectory, requiresNonEmptyFile, expectedBytes, requiresTaskCompletion)

    internal suspend fun verifyExtractionCompletion(taskId: String, outputs: List<FileServerMutationExpectedOutput>): Boolean {
        if (taskId.isBlank() || outputs.isEmpty()) return false
        val status = call(FILE_STATION_EXTRACT_API, "status", mapOf("taskid" to taskId), version = 2)
        if (status.bool("finished") != true) return false
        return archiveReadbackCount(outputs.map { it.toArchiveExpectedOutput() }, taskFinished = true) == outputs.size
    }

    private suspend fun archiveExistingOutputCount(expectedOutputs: List<ArchiveExpectedOutput>): Int =
        expectedOutputs.count { fileInfo(it.path) != null }

    private suspend fun archiveReadbackCount(
        expectedOutputs: List<ArchiveExpectedOutput>,
        attempts: Int = 1,
        taskFinished: Boolean = false,
    ): Int {
        var confirmed = 0
        repeat(attempts.coerceAtLeast(1)) { attempt ->
            confirmed = expectedOutputs.count { expected ->
                if (expected.requiresTaskCompletion && !taskFinished) return@count false
                val observed = fileInfo(expected.path)
                observed != null && observed.isDirectory == expected.isDirectory &&
                    (!expected.requiresNonEmptyFile || observed.size > 0) &&
                    (expected.expectedBytes == null || observed.size == expected.expectedBytes)
            }
            if (confirmed == expectedOutputs.size) return confirmed
            if (attempt + 1 < attempts) delay(DOWNLOAD_MUTATION_READBACK_INTERVAL_MILLIS)
        }
        return confirmed
    }

    private suspend fun pollFileTask(
        apiName: String,
        start: JsonObject,
        operation: String,
        onProgress: (Long, Long?) -> Unit,
    ) {
        val taskId = start.string("taskid") ?: throw DsmFailure(
            null,
            "The NAS did not start $operation",
            "Refresh the folder and try again.",
            kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
        )
        try {
            repeat(MAX_FILE_TASK_POLLS) {
                val status = call(apiName, "status", mapOf("taskid" to taskId))
                val processed = status.long("processed_size") ?: status.long("processedSize")
                val total = status.long("total") ?: status.long("total_size")
                if (processed != null) {
                    onProgress(processed, total)
                } else {
                    status["progress"]?.jsonPrimitive?.contentOrNull?.toDoubleOrNull()?.let { raw ->
                        onProgress(if (raw <= 1.0) (raw * 100).toLong() else raw.toLong(), 100)
                    }
                }
                if (status.bool("finished") == true) return
                delay(FILE_TASK_POLL_INTERVAL_MILLIS)
            }
            throw DsmFailure(
                null,
                "The NAS has not confirmed $operation",
                "Refresh the folder and check the result before trying again.",
                kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
            )
        } catch (error: CancellationException) {
            withContext(NonCancellable) {
                runCatching { call(apiName, "stop", mapOf("taskid" to taskId)) }
            }
            throw error
        }
    }

    private fun archiveResultFromReadback(
        operation: String,
        diagnosticOperation: String,
        confirmed: Int,
        total: Int,
    ): MutationResult = when {
        confirmed == total -> archiveMutationResult(
            operation,
            MutationResultStatus.CONFIRMED_SUCCESS,
            submitted = true,
            succeeded = total,
            diagnosticTag = "file-station.$diagnosticOperation.confirmed-success",
        )
        confirmed > 0 -> archiveMutationResult(
            operation,
            MutationResultStatus.PARTIAL_SUCCESS,
            submitted = true,
            requiresRefresh = true,
            succeeded = confirmed,
            failed = total - confirmed,
            diagnosticTag = "file-station.$diagnosticOperation.partial-success",
        )
        else -> archiveMutationResult(
            operation,
            MutationResultStatus.CONFIRMED_FAILURE,
            submitted = true,
            requiresRefresh = true,
            failed = total,
            errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "file-station.$diagnosticOperation.readback-mismatch",
        )
    }

    private fun archiveResultAfterCancellation(
        operation: String,
        diagnosticOperation: String,
        confirmed: Int,
        total: Int,
    ): MutationResult = when {
        confirmed == total -> archiveResultFromReadback(operation, diagnosticOperation, confirmed, total)
        confirmed > 0 -> archiveResultFromReadback(operation, diagnosticOperation, confirmed, total)
        else -> archiveMutationResult(
            operation,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            submitted = true,
            requiresRefresh = true,
            unknown = total,
            diagnosticTag = "file-station.$diagnosticOperation.cancelled-after-submission",
        )
    }

    private fun archiveCancelledBeforeSubmission(
        operation: String,
        diagnosticOperation: String,
    ): MutationResult = archiveMutationResult(
        operation,
        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        submitted = false,
        diagnosticTag = "file-station.$diagnosticOperation.cancelled-before-submission",
    )

    private fun archivePreflightFailure(
        operation: String,
        diagnosticOperation: String,
        failure: DsmFailure,
    ): MutationResult {
        val category = archiveMutationErrorCategory(failure)
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return archiveMutationResult(
            operation,
            status,
            submitted = false,
            failed = 1,
            errorCategory = category,
            diagnosticTag = "file-station.$diagnosticOperation.preflight-failed",
        )
    }

    private fun archiveMutationErrorCategory(failure: DsmFailure): MutationErrorCategory =
        when (failure.kind) {
            DsmErrorKind.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
            DsmErrorKind.ARCHIVE_INVALID_SELECTION -> MutationErrorCategory.VALIDATION
            DsmErrorKind.SESSION_EXPIRED,
            DsmErrorKind.AUTHENTICATION_FAILED,
            -> MutationErrorCategory.AUTHENTICATION
            DsmErrorKind.FEATURE_UNSUPPORTED,
            DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
            -> MutationErrorCategory.UNSUPPORTED
            DsmErrorKind.CONNECTION_FAILED,
            DsmErrorKind.INVALID_RESPONSE,
            -> MutationErrorCategory.NETWORK
            else -> MutationErrorCategory.SERVER
        }

    private fun archiveMutationResult(
        operation: String,
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
    ) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = operation,
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = MutationResultCounts(succeeded, failed, unknown),
        errorCategory = errorCategory,
        localizationKey = "mutation.${operation.lowercase()}.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private fun requireConfirmedArchiveMutation(result: MutationResult) {
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            throw IllegalArgumentException("Invalid archive operation")
        }
        when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> return
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> throw CancellationException("archive operation cancelled")
            else -> throw DsmFailure(
                null,
                "The NAS did not confirm the archive operation",
                "Refresh the folder before trying again.",
                kind = when (result.status) {
                    MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                    MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                    else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
                },
            )
        }
    }

    suspend fun createEmptyFile(parent: String, name: String) {
        require(name.isNotBlank() && '/' !in name) { "Invalid file name" }
        // File Station 没有独立的空文件接口；该能力由 multipart 上传层实现。
        throw DsmFailure(
            null,
            "Creating an empty file directly is not supported",
            "Create the file on this device first, then upload it.",
            kind = DsmErrorKind.EMPTY_FILE_UNSUPPORTED,
        )
    }

    private val downloadStationRepository = DownloadStationRepository(
        gateway = object : DownloadStationRepositoryGateway {
            override fun supports(apiName: String): Boolean = this@DsmRepository.supports(apiName)

            override fun supportsVersion(apiName: String, version: Int): Boolean =
                this@DsmRepository.supportsVersion(apiName, version)

            override fun preferredOrNull(vararg names: String): String? =
                this@DsmRepository.preferredOrNull(*names)

            override fun capability(apiName: String): ApiCapability? = capabilities[apiName]

            override suspend fun call(
                apiName: String,
                method: String,
                parameters: Map<String, String>,
                version: Int?,
            ): JsonObject {
                val capability = requireCapability(apiName)
                if (version != null && !supportsVersion(apiName, version)) throw DsmFailure(
                    null, "Download Station does not support this action", "Update Download Station.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
                return authorizedApi.call(profile, session, if (version == null) capability else capability.copy(maxVersion = version),
                    method, parameters, oneShot = method in setOf("create", "pause", "resume", "delete", "edit", "refresh", "setserverconfig", "setconfig", "start", "clean"))
            }

            override suspend fun fileInfo(path: String): FileItem? = this@DsmRepository.fileInfo(path)

            override suspend fun uploadDownloadTaskFile(
                capability: ApiCapability,
                filename: String,
                contentType: String?,
                contentLength: Long,
                destination: String?,
                unzipPassword: String?,
                openInputStream: () -> java.io.InputStream,
            ): JsonObject = authorizedApi.uploadDownloadTaskFile(
                profile = profile,
                session = session,
                capability = capability,
                filename = filename,
                contentType = contentType,
                contentLength = contentLength,
                destination = destination,
                unzipPassword = unzipPassword,
                openInputStream = openInputStream,
            )
        },
        mutationLock = downloadMutationLock,
        activeMutationIds = activeDownloadMutationIds,
        creationMutationLock = downloadCreationMutationLock,
        activeCreationKeys = activeDownloadCreationKeys,
        settingsMutationLock = downloadSettingsMutationLock,
        isSettingsMutationActive = { downloadSettingsMutationActive },
        setSettingsMutationActive = { active -> downloadSettingsMutationActive = active },
    )

    suspend fun listDownloads(): List<DownloadTask> = downloadStationRepository.listDownloads()

    suspend fun downloadTaskDetails(taskId: String): DownloadTask = downloadStationRepository.taskDetails(taskId)

    suspend fun downloadTask(taskId: String): DownloadTask? = downloadStationRepository.downloadTask(taskId)

    suspend fun activeDownloadTasksForMutation(): List<DownloadTask> =
        downloadStationRepository.activeDownloadTasksForMutation()

    fun supportsDownloadRss(): Boolean = downloadStationRepository.supportsRss()

    fun supportsDownloadBtSearch(): Boolean = downloadStationRepository.supportsBtSearch()

    fun supportsDownloadActivity(): Boolean = downloadStationRepository.supportsActivity()

    suspend fun loadDownloadActivity(): DownloadStationActivity =
        downloadStationRepository.loadActivity()

    suspend fun loadDownloadBtSearchCatalog(): DownloadBtSearchCatalog =
        downloadStationRepository.loadBtSearchCatalog()

    suspend fun listDownloadRssSites(): List<DownloadRssSite> =
        downloadStationRepository.listRssSites()

    suspend fun listDownloadRssFeeds(siteId: String): List<DownloadRssFeed> =
        downloadStationRepository.listRssFeeds(siteId)

    suspend fun refreshDownloadRssSiteResult(siteId: String,
        willSubmit: (DownloadRssSite) -> Unit = {}, didAccept: () -> Unit = {},
    ): MutationResult = downloadStationRepository.refreshRssSiteResult(siteId, willSubmit, didAccept)

    suspend fun acknowledgeDownloadRssRefresh(siteId: String) = downloadStationRepository.acknowledgeRssRefresh(siteId)

    suspend fun searchDownloadBt(keyword: String): List<DownloadBtSearchResult> =
        downloadStationRepository.searchBt(keyword)

    suspend fun searchDownloadBt(options: DownloadBtSearchOptions): List<DownloadBtSearchResult> =
        downloadStationRepository.searchBt(options)

    suspend fun createDownloadResult(uri: String, destination: String?,
        willSubmit: (String, String) -> Unit = { _, _ -> }, didAccept: () -> Unit = {},
    ): MutationResult = downloadStationRepository.createResult(uri, destination, willSubmit, didAccept)

    suspend fun createDownloadFromFileResult(
        source: UploadSource,
        destination: String? = null,
        unzipPassword: String? = null,
        willSubmit: (String, String) -> Unit = { _, _ -> },
        didAccept: () -> Unit = {},
    ): MutationResult = downloadStationRepository.createFromFileResult(source, destination, unzipPassword, willSubmit, didAccept)

    fun supportsDownloadSettings(): Boolean = downloadStationRepository.supportsSettings()

    fun supportsDownloadSchedule(): Boolean = downloadStationRepository.supportsSchedule()

    fun supportsDownloadTaskDestinationEditing(): Boolean =
        downloadStationRepository.supportsTaskDestinationEditing()

    fun supportsChatReminders(): Boolean = supportsVersion(CHAT_POST_REMINDER_API, 1)

    fun supportsChatScheduledMessages(): Boolean = supportsVersion(CHAT_POST_SCHEDULE_API, 1)

    fun supportsChatPollCreation(): Boolean =
        supportsVersion(CHAT_POST_VOTE_API, 1) && supports("SYNO.Chat.Post")

    suspend fun loadDownloadSettings(): DownloadSettings = downloadStationRepository.loadSettings()

    suspend fun saveDownloadSettingsResult(
        original: DownloadSettings,
        desired: DownloadSettings,
        partition: io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettingsPartition? = null,
        willSubmit: (io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettingsPartition) -> Unit = {},
        didAccept: (io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettingsPartition) -> Unit = {},
    ): MutationResult = downloadStationRepository.saveSettingsResult(original, desired, partition, willSubmit, didAccept)

    suspend fun controlDownloadsResult(
        baseline: List<DownloadTaskMutationBaseline>,
        action: DownloadTaskMutationAction,
        willSubmit: () -> Unit = {}, didAccept: () -> Unit = {},
    ): MutationResult = downloadStationRepository.controlTasksResult(baseline, action, willSubmit, didAccept)

    suspend fun editDownloadDestinationResult(
        baseline: DownloadTaskMutationBaseline,
        destination: FileItem,
        willSubmit: () -> Unit = {}, didAccept: () -> Unit = {},
    ): MutationResult = downloadStationRepository.editDestinationResult(baseline, destination, willSubmit, didAccept)

    internal val containerManagement get() = containerRepository
    suspend fun containerOverview(): ContainerOverview = containerRepository.overview()

    fun supportsContainerRegistry(): Boolean = containerRepository.supportsRegistry()

    /** 旧无确认快照门面保持不可写；A8正式入口使用containerManagement及独立持久恢复，不代表真实NAS已验收。 */
    fun supportsVerifiedContainerWrites(): Boolean = containerRepository.supportsVerifiedWrites()

    suspend fun searchContainerRegistry(query: String): List<ContainerRegistryImage> =
        containerRepository.searchRegistry(query)

    suspend fun containerRegistryTags(repository: String): List<String> =
        containerRepository.registryTags(repository)

    suspend fun controlContainerResult(id: String, action: String): MutationResult =
        containerRepository.controlResult(id, action)

    suspend fun deleteContainerResult(id: String): MutationResult =
        containerRepository.deleteResult(id)

    suspend fun deleteContainerImageResult(id: String): MutationResult =
        containerRepository.deleteImageResult(id)

    suspend fun createContainerNetworkResult(name: String, driver: String): MutationResult =
        containerRepository.createNetworkResult(name, driver)

    suspend fun deleteContainerNetworkResult(id: String): MutationResult =
        containerRepository.deleteNetworkResult(id)

    suspend fun virtualMachineOverview(): VirtualMachineOverview =
        virtualMachineRepository.overview()

    /**
     * 仅用公开 Guest.get v1 重新读取一个 Guest；不能用列表或内部 Guest 接口替代这个身份核对。
     */
    suspend fun virtualMachineGuestDetails(guestId: String): VirtualMachineGuestDetails {
        val normalizedId = guestId.trim()
        require(normalizedId.isNotEmpty()) { "Virtual machine guest ID is required" }
        if (!supportsOfficialVirtualMachineGuestDetails()) throw DsmFailure(
            null,
            "Virtual machine guest details are unavailable",
            "Refresh Virtual Machine Manager and try again.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
        return readOfficialVirtualMachineGuestDetails(normalizedId)
    }

    fun supportsOfficialVirtualMachineCreation(): Boolean =
        supportsVersion("SYNO.Virtualization.API.Guest", 1) &&
            supportsVersion("SYNO.Virtualization.API.Task.Info", 1) &&
            supportsVersion("SYNO.Virtualization.API.Storage", 1)

    fun supportsOfficialVirtualMachineSettings(): Boolean =
        supportsVersion("SYNO.Virtualization.API.Guest", 1)

    /** Guest 详情只接受官方 Guest v1，不能以内部同名接口代替。 */
    fun supportsOfficialVirtualMachineGuestDetails(): Boolean =
        supportsOfficialVirtualMachineSettings()

    fun supportsOfficialVirtualMachineTasks(): Boolean =
        supportsVersion("SYNO.Virtualization.API.Task.Info", 1)

    /** 仅刷新公开 Task.Info 分区，不连带读取虚拟机、日志或其他附属资源。 */
    suspend fun virtualMachineTasks(): List<VirtualMachineTask> {
        if (!supportsOfficialVirtualMachineTasks()) throw DsmFailure(
            null,
            "Virtual machine tasks are unavailable",
            "Refresh Virtual Machine Manager and try again.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
        return readOfficialVirtualMachineTaskRecords().map(VirtualMachineTaskRecord::task)
    }

    fun supportsOfficialVirtualMachineImageImport(): Boolean =
        supportsVersion("SYNO.Virtualization.API.Guest.Image", 1) &&
            supportsVersion("SYNO.Virtualization.API.Task.Info", 1) &&
            supportsVersion("SYNO.Virtualization.API.Storage", 1) &&
            supportsVersion("SYNO.FileStation.List", 2)

    internal data class VirtualMachineImageTaskReadback(
        val finished: Boolean,
        val imageId: String?,
    )

    internal enum class VirtualMachineImageMatch { MATCH, MISSING, DIFFERS }

    /** 后台本地映像流程只调用一次；调用方必须在此前持久化 CREATE_SUBMITTING。 */
    internal suspend fun startVirtualMachineImageImportTask(
        source: FileItem,
        imageName: String,
        imageType: VirtualMachineImageType,
        storageId: String,
        storageName: String,
        storageStatus: String,
    ): String {
        require(supportsOfficialVirtualMachineImageImport()) { "vmm.image.import.unsupported" }
        val currentFile = fileInfo(source.path)
        val currentStorages = strictVirtualizationResourceList(
            "SYNO.Virtualization.API.Storage",
            listOf("list"),
            "storages",
        )
        val currentImages = strictVirtualizationResourceList(
            "SYNO.Virtualization.API.Guest.Image",
            listOf("list"),
            "images",
        )
        if (currentFile?.matchesMutationBaseline(source) != true || currentStorages.none {
                it.id == storageId && it.name == storageName &&
                    it.metadata["status"] == storageStatus &&
                    it.isEligibleForVirtualMachineImageImport()
            } || currentImages.any { it.name.equals(imageName, ignoreCase = true) }
        ) throw DsmFailure(
            null,
            "Virtual machine image import baseline changed",
            "Review the source file, storage, and image name before trying again.",
            kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
        )
        val started = call(
            "SYNO.Virtualization.API.Guest.Image",
            "create",
            mapOf(
                "auto_clean_task" to "false",
                "storage_ids" to jsonStrings(listOf(storageId)),
                "type" to imageType.apiValue,
                "ds_file_path" to source.path,
                "image_name" to imageName,
            ),
            version = 1,
        )
        return started["task_id"].strictStringValue()?.takeIf(String::isNotBlank)
            ?: throw invalidVirtualizationResponse("image-import-task-id")
    }

    internal suspend fun readVirtualMachineImageImportTask(
        taskId: String,
    ): VirtualMachineImageTaskReadback = when (val task = readOfficialVmmImageImportTask(taskId)) {
        VmmImageImportTaskState.Pending -> VirtualMachineImageTaskReadback(false, null)
        VmmImageImportTaskState.FinishedWithoutImage -> VirtualMachineImageTaskReadback(true, null)
        is VmmImageImportTaskState.Finished -> VirtualMachineImageTaskReadback(true, task.imageId)
    }

    internal suspend fun virtualMachineImageMatches(
        imageId: String,
        expectedName: String,
        expectedType: VirtualMachineImageType,
    ): VirtualMachineImageMatch {
        val image = strictVirtualizationResourceList(
            "SYNO.Virtualization.API.Guest.Image",
            listOf("list"),
            "images",
        ).singleOrNull { it.id == imageId } ?: return VirtualMachineImageMatch.MISSING
        return if (image.name == expectedName && image.metadata["type"] == expectedType.apiValue) {
            VirtualMachineImageMatch.MATCH
        } else {
            VirtualMachineImageMatch.DIFFERS
        }
    }

    internal suspend fun clearVirtualMachineImageImportTask(taskId: String) {
        clearOfficialVmmTask(taskId)
    }

    internal suspend fun virtualMachineTaskExists(taskId: String): Boolean {
        val list = call("SYNO.Virtualization.API.Task.Info", "list", version = 1)
        val ids = (list["task_ids"] as? JsonArray)?.map { element ->
            element.strictStringValue()?.trim()?.takeIf(String::isNotEmpty)
                ?: throw invalidVirtualizationResponse("task-list-id")
        } ?: throw invalidVirtualizationResponse("task-list-root")
        if (ids.size > MAX_VMM_TASK_CENTER_ITEMS || ids.distinct().size != ids.size) {
            throw invalidVirtualizationResponse("task-list-bounds")
        }
        return taskId in ids
    }

    /** 本地映像后台导入的结果刷新仍按原 task_id 核对；不重新创建映像。 */
    suspend fun verifyVirtualMachineImageImportTask(
        taskId: String,
        expectedName: String,
        expectedType: VirtualMachineImageType,
        onTaskCleared: (String) -> Unit = {},
    ): VirtualMachineImageImportVerification {
        return when (val task = readOfficialVmmImageImportTask(taskId)) {
            VmmImageImportTaskState.Pending -> VirtualMachineImageImportVerification.PENDING
            VmmImageImportTaskState.FinishedWithoutImage -> {
                clearOfficialVmmTask(taskId)
                onTaskCleared(taskId)
                VirtualMachineImageImportVerification.DIFFERS
            }
            is VmmImageImportTaskState.Finished -> {
                val image = strictVirtualizationResourceList(
                    "SYNO.Virtualization.API.Guest.Image",
                    listOf("list"),
                    "images",
                ).singleOrNull { it.id == task.imageId }
                    ?: return VirtualMachineImageImportVerification.PENDING
                val verification = if (
                    image.name == expectedName && image.metadata["type"] == expectedType.apiValue
                ) {
                    VirtualMachineImageImportVerification.MATCHES
                } else {
                    VirtualMachineImageImportVerification.DIFFERS
                }
                clearOfficialVmmTask(taskId)
                onTaskCleared(taskId)
                verification
            }
        }
    }

    private suspend fun clearOfficialVmmTask(taskId: String) {
        withContext(NonCancellable) {
            call(
                "SYNO.Virtualization.API.Task.Info",
                "clear",
                mapOf("task_id" to taskId),
                version = 1,
            )
        }
    }

    private data class OfficialVirtualMachineGuest(
        val id: String,
        val payload: JsonObject,
    )

    private suspend fun readOfficialVirtualMachineGuest(
        id: String,
        responseScope: String,
    ): OfficialVirtualMachineGuest {
        val guest = call(
            "SYNO.Virtualization.API.Guest",
            "get",
            mapOf("guest_id" to id, "additional" to "true"),
            version = 1,
        )
        val responseId = guest["guest_id"].strictStringValue()?.takeIf(String::isNotBlank)
            ?: throw invalidVirtualizationResponse("$responseScope-id")
        if (responseId != id) throw invalidVirtualizationResponse("$responseScope-id-mismatch")
        return OfficialVirtualMachineGuest(responseId, guest)
    }

    private suspend fun readOfficialVirtualMachineGuestDetails(
        id: String,
    ): VirtualMachineGuestDetails {
        val guest = readOfficialVirtualMachineGuest(id, "guest-details")
        val guestName = guest.payload["guest_name"].strictStringValue()
            ?.trim()
            ?.takeIf(String::isNotEmpty)
            ?: throw invalidVirtualizationResponse("guest-details-name")
        val resource = genericResources(
            JsonObject(mapOf("guests" to JsonArray(listOf(guest.payload)))),
            "guests",
        ).singleOrNull()?.takeIf { it.id == guest.id }?.copy(name = guestName)
            ?: throw invalidVirtualizationResponse("guest-details-resource")
        return VirtualMachineGuestDetails(
            resource = resource,
            hardware = officialVirtualMachineHardware(
                guest.payload,
                guest.id,
                "guest-details-hardware",
            ),
        )
    }

    private data class OfficialVirtualMachineRead(
        val machines: List<ManagedResource>,
        val hardware: List<VirtualMachineHardware>?,
    )

    /** 公开 Guest v1 的磁盘与网卡结构只在内存中保留，不读取或保存 MAC。 */
    private suspend fun officialVirtualMachineRead(): OfficialVirtualMachineRead {
        val data = call(
            "SYNO.Virtualization.API.Guest",
            "list",
            mapOf("additional" to "true"),
            version = 1,
        )
        val guests = data["guests"] as? JsonArray
            ?: throw invalidVirtualizationResponse("guest-hardware-root")
        val machineIds = mutableSetOf<String>()
        guests.forEach { element ->
            val guest = element as? JsonObject
                ?: throw invalidVirtualizationResponse("guest-hardware-item")
            val machineId = guest["guest_id"].strictStringValue()
                ?.trim()?.takeIf(String::isNotEmpty)
                ?: throw invalidVirtualizationResponse("guest-hardware-id")
            if (!machineIds.add(machineId)) {
                throw invalidVirtualizationResponse("guest-hardware-duplicate-id")
            }
        }
        val hardware = try {
            guests.map { element ->
                val guest = element as JsonObject
                val machineId = checkNotNull(guest["guest_id"].strictStringValue()).trim()
                val disks = (guest["vdisks"] as? JsonArray)
                    ?.map { diskElement -> officialVirtualMachineDisk(diskElement) }
                    ?: throw invalidVirtualizationResponse("guest-hardware-disks")
                if (disks.map(VirtualMachineDisk::id).distinct().size != disks.size) {
                    throw invalidVirtualizationResponse("guest-hardware-duplicate-disk")
                }
                val networkInterfaces = (guest["vnics"] as? JsonArray)
                    ?.map { networkElement -> officialVirtualMachineNetwork(networkElement) }
                    ?: throw invalidVirtualizationResponse("guest-hardware-networks")
                if (networkInterfaces.map(VirtualMachineNetworkInterface::id).distinct().size !=
                    networkInterfaces.size
                ) {
                    throw invalidVirtualizationResponse("guest-hardware-duplicate-network")
                }
                VirtualMachineHardware(machineId, disks, networkInterfaces)
            }
        } catch (_: DsmFailure) {
            null
        }
        return OfficialVirtualMachineRead(
            machines = genericResources(data, "guests"),
            hardware = hardware,
        )
    }

    private fun officialVirtualMachineDisk(element: JsonElement): VirtualMachineDisk {
        val disk = element as? JsonObject
            ?: throw invalidVirtualizationResponse("guest-hardware-disk")
        val id = disk["vdisk_id"].strictStringValue()?.trim()?.takeIf(String::isNotEmpty)
            ?: throw invalidVirtualizationResponse("guest-hardware-disk-id")
        val sizeMiB = disk["vdisk_size"].strictIntValue()?.takeIf { it >= 0 }
            ?: throw invalidVirtualizationResponse("guest-hardware-disk-size")
        val controller = when (disk["controller"].strictIntValue()) {
            1 -> VirtualMachineDiskController.VIRTIO
            2 -> VirtualMachineDiskController.IDE
            3 -> VirtualMachineDiskController.SATA
            else -> throw invalidVirtualizationResponse("guest-hardware-disk-controller")
        }
        val spaceReclamationEnabled = disk["unmap"].strictBooleanValue()
            ?: throw invalidVirtualizationResponse("guest-hardware-disk-unmap")
        return VirtualMachineDisk(id, sizeMiB, controller, spaceReclamationEnabled)
    }

    private fun officialVirtualMachineNetwork(element: JsonElement): VirtualMachineNetworkInterface {
        val network = element as? JsonObject
            ?: throw invalidVirtualizationResponse("guest-hardware-network")
        val id = network["vnic_id"].strictStringValue()?.trim()?.takeIf(String::isNotEmpty)
            ?: throw invalidVirtualizationResponse("guest-hardware-network-id")
        val networkId = network["network_id"].strictStringValue()
            ?: throw invalidVirtualizationResponse("guest-hardware-network-target")
        val networkName = network["network_name"].strictStringValue()
            ?: throw invalidVirtualizationResponse("guest-hardware-network-name")
        val model = when (network["model"].strictIntValue()) {
            1 -> VirtualMachineNetworkModel.VIRTIO
            2 -> VirtualMachineNetworkModel.E1000
            3 -> VirtualMachineNetworkModel.RTL8139
            else -> throw invalidVirtualizationResponse("guest-hardware-network-model")
        }
        return VirtualMachineNetworkInterface(id, networkId, networkName, model)
    }

    private fun officialVirtualMachineHardware(
        guest: JsonObject,
        machineId: String,
        responseScope: String,
    ): VirtualMachineHardware {
        val disks = (guest["vdisks"] as? JsonArray)?.map(::officialVirtualMachineDisk)
            ?: throw invalidVirtualizationResponse("$responseScope-disks")
        val networks = (guest["vnics"] as? JsonArray)?.map(::officialVirtualMachineNetwork)
            ?: throw invalidVirtualizationResponse("$responseScope-networks")
        if (disks.map(VirtualMachineDisk::id).distinct().size != disks.size ||
            networks.map(VirtualMachineNetworkInterface::id).distinct().size != networks.size
        ) throw invalidVirtualizationResponse("$responseScope-duplicates")
        return VirtualMachineHardware(machineId, disks, networks)
    }

    private data class VirtualMachineTaskCenterRead(
        val tasks: List<VirtualMachineTask>,
        val state: VirtualMachineTaskCenterState,
    )

    private data class VirtualMachineTaskRecord(
        val taskToken: String,
        val task: VirtualMachineTask,
    )

    private suspend fun virtualMachineTaskCenter(): VirtualMachineTaskCenterRead {
        if (!supportsOfficialVirtualMachineTasks()) {
            return VirtualMachineTaskCenterRead(
                emptyList(),
                VirtualMachineTaskCenterState.CAPABILITY_UNAVAILABLE,
            )
        }
        return try {
            VirtualMachineTaskCenterRead(
                tasks = readOfficialVirtualMachineTaskRecords().map(VirtualMachineTaskRecord::task),
                state = VirtualMachineTaskCenterState.AVAILABLE,
            )
        } catch (cancelled: CancellationException) {
            throw cancelled
        } catch (failure: DsmFailure) {
            io.github.qwertyuiop1995.dsmnativeclient.data.virtualmachines.vmmRethrowCritical(failure)
            VirtualMachineTaskCenterRead(
                emptyList(),
                if (failure.kind == DsmErrorKind.INVALID_RESPONSE) {
                    VirtualMachineTaskCenterState.INVALID_RESPONSE
                } else {
                    VirtualMachineTaskCenterState.LOAD_FAILED
                },
            )
        }
    }

    private suspend fun readOfficialVirtualMachineTaskRecords(): List<VirtualMachineTaskRecord> {
        val list = call(
            "SYNO.Virtualization.API.Task.Info",
            "list",
            version = 1,
        )
        val ids = (list["task_ids"] as? JsonArray)
            ?.map { element ->
                element.strictStringValue()?.trim()?.takeIf(String::isNotEmpty)
                    ?: throw invalidVirtualizationResponse("task-list-id")
            }
            ?: throw invalidVirtualizationResponse("task-list-root")
        if (ids.size > MAX_VMM_TASK_CENTER_ITEMS || ids.distinct().size != ids.size) {
            throw invalidVirtualizationResponse("task-list-bounds")
        }
        return ids.map { taskId ->
            val task = call(
                "SYNO.Virtualization.API.Task.Info",
                "get",
                mapOf("task_id" to taskId),
                version = 1,
            )
            val finished = task["finish"].strictBooleanValue()
                ?: throw invalidVirtualizationResponse("task-finish")
            val info = when (val value = task["task_info"]) {
                null -> null
                is JsonObject -> value
                else -> throw invalidVirtualizationResponse("task-info")
            }
            val progress = info?.get("progress")?.let { value ->
                value.strictIntValue()?.takeIf { it in 0..100 }
                    ?: throw invalidVirtualizationResponse("task-progress")
            }
            VirtualMachineTaskRecord(
                taskToken = taskId,
                task = VirtualMachineTask(
                    id = virtualMachineTaskDigest(taskId),
                    isFinished = finished,
                    progressPercent = progress,
                    taskToken = taskId,
                ),
            )
        }
    }

    private fun virtualMachineTaskDigest(taskToken: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(taskToken.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte ->
                (byte.toInt() and 0xff).toString(16).padStart(2, '0')
            }

    private suspend fun readOfficialVmmImageImportTask(taskId: String): VmmImageImportTaskState {
        val task = call(
            "SYNO.Virtualization.API.Task.Info",
            "get",
            mapOf("task_id" to taskId),
            version = 1,
        )
        val finished = task["finish"].strictBooleanValue()
            ?: throw invalidVirtualizationResponse("image-task-finish")
        if (!finished) return VmmImageImportTaskState.Pending
        val info = task["task_info"] as? JsonObject
            ?: return VmmImageImportTaskState.FinishedWithoutImage
        val imageId = info["image_id"].strictStringValue()?.takeIf(String::isNotBlank)
            ?: return VmmImageImportTaskState.FinishedWithoutImage
        return VmmImageImportTaskState.Finished(imageId)
    }

    private sealed class VmmImageImportTaskState {
        object Pending : VmmImageImportTaskState()
        object FinishedWithoutImage : VmmImageImportTaskState()
        data class Finished(val imageId: String) : VmmImageImportTaskState()
    }

    suspend fun virtualizationLogs(): List<LogEntry> {
        val data = call(
            "SYNO.Virtualization.Log",
            "list",
            mapOf(
                "offset" to "0",
                "limit" to "1000",
                "loglevel" to "",
                "filter_content" to "",
                "datefrom" to "0",
                "dateto" to "0",
                "sort_by" to "time",
                "sort_dir" to "DESC",
            ),
        )
        return parseVirtualizationLogs(data)
    }

    suspend fun chatConversations(): List<ChatConversation> = chatRepository.conversations()

    suspend fun chatUsers(): List<ChatUser> = chatRepository.users()

    suspend fun chatMessages(
        conversationId: String,
        before: String? = null,
        limit: Int = 50,
    ): ChatMessagePage = chatRepository.messages(conversationId, before, limit)

    suspend fun chatConversationMembers(conversationId: String): List<ChatUser> =
        chatRepository.conversationMembers(conversationId)

    private fun jsonStringArray(values: List<String>): String = requestBuilder.jsonStringArray(values)

    private fun invalidChatConversationRequest() = DsmFailure(
        null,
        "The conversation details are incomplete",
        "Choose valid members and try again.",
        kind = DsmErrorKind.REQUEST_FAILED,
    )

    private fun unsupportedChatConversationMutation() = DsmFailure(
        102,
        "This conversation action is unavailable",
        "Update Synology Chat or use Chat in a browser.",
        kind = DsmErrorKind.FEATURE_UNSUPPORTED,
    )

    suspend fun chatAttachmentThumbnail(messageId: String): ByteArray {
        if (messageId.isBlank() || !supportsVersion(CHAT_POST_FILE_API, 2)) {
            throw unsupportedChatConversationMutation()
        }
        return authorizedApi.readBinary(
            profile = profile,
            session = session,
            capability = requireCapability(CHAT_POST_FILE_API),
            preferredVersion = 2,
            method = "thumbnail",
            parameters = mapOf("post_id" to messageId, "type" to "sm"),
            maximumBytes = MAX_CHAT_THUMBNAIL_BYTES,
        )
    }

    suspend fun downloadChatAttachment(
        messageId: String,
        expectedBytes: Long?,
        output: OutputStream,
        onProgress: (Long, Long?) -> Unit,
    ): Long {
        if (messageId.isBlank() || !supportsVersion(CHAT_POST_FILE_API, 2)) {
            throw unsupportedChatConversationMutation()
        }
        expectedBytes?.let {
            if (it < 0 || it > MAX_CHAT_ATTACHMENT_DOWNLOAD_BYTES) throw DsmFailure(
                null,
                "The attachment is too large to save safely",
                "Use Synology Chat in a browser to save this attachment.",
                kind = DsmErrorKind.PREVIEW_TOO_LARGE,
            )
        }
        return authorizedApi.downloadBinaryToOutput(
            profile = profile,
            session = session,
            capability = requireCapability(CHAT_POST_FILE_API),
            preferredVersion = 2,
            method = "get",
            parameters = mapOf("post_id" to messageId),
            output = output,
            expectedBytes = expectedBytes,
            maximumBytes = MAX_CHAT_ATTACHMENT_DOWNLOAD_BYTES,
            onProgress = onProgress,
        )
    }

    suspend fun downloadChatVideoPreview(
        messageId: String,
        expectedBytes: Long?,
        output: OutputStream,
        onProgress: (Long, Long?) -> Unit,
    ): Long {
        if (messageId.isBlank() || !supportsVersion(CHAT_POST_FILE_API, 2)) {
            throw unsupportedChatConversationMutation()
        }
        expectedBytes?.let {
            if (it < 0 || it > MAX_CHAT_VIDEO_PREVIEW_BYTES) throw DsmFailure(
                null,
                "The video is too large to preview safely",
                "Save the attachment and open it with another app.",
                kind = DsmErrorKind.PREVIEW_TOO_LARGE,
            )
        }
        return authorizedApi.downloadBinaryToOutput(
            profile = profile,
            session = session,
            capability = requireCapability(CHAT_POST_FILE_API),
            preferredVersion = 2,
            method = "get",
            parameters = mapOf("post_id" to messageId),
            output = output,
            expectedBytes = expectedBytes,
            maximumBytes = MAX_CHAT_VIDEO_PREVIEW_BYTES,
            onProgress = onProgress,
        )
    }

    /**
     * 读取远程访问设置。单项能力或读取失败以 null 表示；两项都失败时整体不可用。
     * 写入仍检查当前授权、固定目标和结果，不按固件或套件版本禁用。
     */
    suspend fun remoteAccessSettings(): NasRemoteAccessSettings =
        (nasServices.load(io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind.REMOTE_ACCESS) as io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue.RemoteAccess).settings

    suspend fun activeRemoteAccessSettings(): NasRemoteAccessSettings = remoteAccessSettings()

    private fun resolvedProfileUsesTrustedRelay(): Boolean {
        val host = runCatching {
            URI(if ("://" in profile.address) profile.address else "https://${profile.address}").host
        }.getOrNull() ?: return false
        return isTrustedQuickConnectRelayHost(host)
    }

    suspend fun nasSettings(area: NasSettingsArea? = null, previous: NasSettingsSnapshot? = null): NasSettingsSnapshot =
        nasAdministrationRepository.settings(area, previous)

    /** 已登记的内部只读性能接口；运行时未发现 v1 时固定深页不得进入采样状态。 */
    fun supportsPerformance(): Boolean = supportsVersion(PERFORMANCE_API, 1)

    /**
     * 读取 DSM 当前性能采样。此内部只读接口仅在运行时发现 v1 时使用，原始响应不持久化。
     */
    suspend fun performanceSample(): PerformanceSample {
        val data = call(
            PERFORMANCE_API,
            "get",
            parameters = mapOf("resource" to "all", "type" to "current"),
            version = 1,
        )
        val cpu = data.objectValue("cpu")
        val memory = data.objectValue("memory")
        val networkTotal = data.elements("network")
            .mapNotNull { it as? JsonObject }
            .firstOrNull { it.string("device")?.equals("total", ignoreCase = true) == true }
        val diskTotal = data.objectValue("disk")?.objectValue("total")
        val volumeTotal = data.objectValue("space")?.objectValue("total")
        val cpuUser = cpu?.number("user_load")?.coerceIn(0.0, 100.0)
        val cpuSystem = cpu?.number("system_load")?.coerceIn(0.0, 100.0)
        val cpuOther = cpu?.number("other_load")?.coerceIn(0.0, 100.0)
        return PerformanceSample(
            timeEpochSeconds = normalizeEpoch(data.long("time"))
                ?: System.currentTimeMillis() / 1_000,
            cpuPercent = listOfNotNull(cpuUser, cpuSystem, cpuOther)
                .takeIf { it.isNotEmpty() }
                ?.sum()
                ?.coerceIn(0.0, 100.0),
            cpuUserPercent = cpuUser,
            cpuSystemPercent = cpuSystem,
            memoryPercent = memory?.number("real_usage")?.coerceIn(0.0, 100.0),
            swapPercent = memory?.number("swap_usage")?.coerceIn(0.0, 100.0),
            networkReceiveBytesPerSecond = networkTotal?.nonNegativeLong("rx"),
            networkSendBytesPerSecond = networkTotal?.nonNegativeLong("tx"),
            diskReadBytesPerSecond = diskTotal?.nonNegativeLong("read_byte"),
            diskWriteBytesPerSecond = diskTotal?.nonNegativeLong("write_byte"),
            volumeReadBytesPerSecond = volumeTotal?.nonNegativeLong("read_byte"),
            volumeWriteBytesPerSecond = volumeTotal?.nonNegativeLong("write_byte"),
            diskUtilizationPercent = diskTotal?.number("utilization")?.coerceIn(0.0, 100.0),
        )
    }

    /**
     * 使用当前已核对的 DSM 内部接口检查系统更新。只读取候选版本和说明，不触发下载或安装。
     */
    suspend fun checkSystemUpdate(): NasSystemUpdateInfo {
        if (!supports(SYSTEM_API) || !supportsVersion(SYSTEM_UPDATE_API, 3)) {
            throw DsmFailure(
                102,
                "System update checks are unavailable",
                "Open DSM in a browser to check for updates.",
                kind = DsmErrorKind.FEATURE_UNSUPPORTED,
            )
        }
        val system = call(SYSTEM_API, "info")
        val response = call(
            SYSTEM_UPDATE_API,
            "check",
            parameters = mapOf(
                "user_reading" to "true",
                "need_auto_smallupdate" to "true",
                "need_promotion" to "false",
            ),
            version = 3,
        )
        val update = response.objectValue("update")
        val currentVersion = system.firstNonBlank("firmware_ver", "version")
        val latestVersion = update?.firstNonBlank("version")
        return NasSystemUpdateInfo(
            isUpdateAvailable = latestVersion != null && latestVersion != currentVersion,
            currentVersion = currentVersion,
            latestVersion = latestVersion,
            releaseNotes = update?.firstNonBlank(
                "release_note",
                "release_notes",
                "whats_new",
                "description",
            ),
        )
    }

    private suspend fun strictStorageDisks(): List<NasStorageDisk> {
        val data = call(STORAGE_OVERVIEW_API, "load_info", version = SMART_API_VERSION)
        val rows = strictSettingsRows(data, setOf("disks"), "storage-disk-list")
        val disks = rows.map { item ->
            fun requiredString(key: String): String = item[key].strictStringValue()
                ?.takeIf(String::isNotBlank) ?: throw invalidSettingsResponse("storage-disk-$key")
            fun optionalString(vararg keys: String): String? {
                val value = keys.firstNotNullOfOrNull(item::get) ?: return null
                return value.strictStringValue() ?: throw invalidSettingsResponse("storage-disk-string")
            }
            val temperature = item["temp"]?.let { value ->
                val primitive = value as? JsonPrimitive
                    ?: throw invalidSettingsResponse("storage-disk-temperature")
                primitive.contentOrNull?.toDoubleOrNull()?.takeIf(Double::isFinite)
                    ?: throw invalidSettingsResponse("storage-disk-temperature")
            }
            NasStorageDisk(
                id = requiredString("id"),
                deviceId = requiredString("device"),
                name = optionalString("longName", "name", "device")
                    ?: throw invalidSettingsResponse("storage-disk-name"),
                model = optionalString("model"),
                status = optionalString(
                    "summary_status_key", "drive_status_key", "overview_status", "status",
                ),
                smartStatus = optionalString("smart_status"),
                temperatureCelsius = temperature,
                supportsSmartTest = item["smart_test_support"].strictBooleanValue(allowString = true)
                    ?: throw invalidSettingsResponse("storage-disk-smart-support"),
            )
        }
        if (disks.map { it.id }.distinct().size != disks.size ||
            disks.map { it.deviceId }.distinct().size != disks.size
        ) throw invalidSettingsResponse("storage-disk-duplicate-identity")
        return disks
    }

    private suspend fun strictDiskTestStatus(disk: NasStorageDisk): NasDiskTestStatus {
        val data = call(
            STORAGE_DISK_API,
            "get_smart_test_log",
            mapOf("device" to disk.deviceId),
            version = 1,
        )
        val statusRows = strictSettingsRows(data, setOf("testInfo"), "storage-smart-status")
        if (statusRows.size != 1) throw invalidSettingsResponse("storage-smart-status-count")
        val latest = statusRows.single()
        if (latest.containsKey("device") && latest["device"].strictStringValue() != disk.deviceId) {
            throw invalidSettingsResponse("storage-smart-response-device")
        }
        fun optionalBoolean(vararg keys: String): Boolean? {
            val values = keys.mapNotNull(latest::get)
            if (values.isEmpty()) return null
            val parsed = values.map { value ->
                value.strictBooleanValue(allowString = true)
                    ?: throw invalidSettingsResponse("storage-smart-status-boolean")
            }
            if (parsed.distinct().size != 1) {
                throw invalidSettingsResponse("storage-smart-status-boolean-conflict")
            }
            return parsed.singleOrNull() ?: parsed.first()
        }
        fun optionalString(
            vararg keys: String,
            normalize: (String) -> String = { it.trim() },
        ): String? {
            val values = keys.mapNotNull(latest::get)
            if (values.isEmpty()) return null
            val parsed = values.map { value ->
                value.strictStringValue()?.let(normalize)
                    ?: throw invalidSettingsResponse("storage-smart-status-string")
            }
            if (parsed.distinct().size != 1) {
                throw invalidSettingsResponse("storage-smart-status-string-conflict")
            }
            return parsed.first()
        }
        val running = optionalBoolean("testing", "is_testing")
            ?: throw invalidSettingsResponse("storage-smart-testing")
        val ihmRunning = optionalBoolean("ihm_testing")
            ?: throw invalidSettingsResponse("storage-smart-ihm-testing")
        val performanceRunning = optionalBoolean("perf_testing")
            ?: throw invalidSettingsResponse("storage-smart-perf-testing")
        val busy = !running && (ihmRunning || performanceRunning)
        val rawType = optionalString(
            "test_type", "testType", "type",
            normalize = { value ->
                when (value.trim().lowercase(Locale.ROOT)) {
                    "extended" -> "extend"
                    else -> value.trim().lowercase(Locale.ROOT)
                }
            },
        )
        val runningType = when (rawType) {
            "quick" -> NasDiskTestType.QUICK
            "extend", "extended" -> NasDiskTestType.EXTENDED
            else -> null
        }
        if (running && runningType == null) throw invalidSettingsResponse("storage-smart-running-type")
        if (rawType != null && runningType == null) throw invalidSettingsResponse("storage-smart-test-type")
        return NasDiskTestStatus(
            diskId = disk.id,
            isRunning = running,
            isBusyWithOtherTest = busy,
            runningType = runningType.takeIf { running },
            progressDescription = optionalString("remain", "progress"),
            lastQuickTest = null,
            lastExtendedTest = null,
            lastResult = optionalString(
                "latest_test_result", "result",
                normalize = { it.trim().lowercase(Locale.ROOT) },
            ),
            isHistoryAvailable = false,
        )
    }

    private suspend fun strictDiskTestHistory(disk: NasStorageDisk): io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasSmartHistory {
        var lastQuick: String? = null
        var lastExtended: String? = null
        var historyResult: String? = null
        call(
            STORAGE_DISK_API,
            "disk_test_log_get",
            mapOf(
                "device" to disk.deviceId,
                "offset" to "0",
                "limit" to "100",
                "sort_by" to "time",
                "sort_direction" to "DESC",
                "type" to "smart",
            ),
            version = SMART_API_VERSION,
        ).let { history ->
            val logs = strictSettingsRows(history, setOf("testLog"), "storage-smart-history")
            logs.forEach { log ->
                listOf("test_type", "time", "result").forEach { key ->
                    if (log.containsKey(key) && log[key].strictStringValue() == null) {
                        throw invalidSettingsResponse("storage-smart-history-$key")
                    }
                }
            }
            lastQuick = logs.firstOrNull { it.string("test_type")?.lowercase(Locale.ROOT) == "quick" }
                ?.string("time")
            lastExtended = logs.firstOrNull {
                it.string("test_type")?.lowercase(Locale.ROOT) in setOf("extend", "extended")
            }?.string("time")
            historyResult = logs.firstOrNull()?.string("result")
        }
        return io.github.qwertyuiop1995.dsmnativeclient.data.nas.NasSmartHistory(lastQuick, lastExtended, historyResult)
    }

    /** 危险操作完成后使用严格契约专项回读；失败不得折叠为空列表。 */
    suspend fun activeAccounts(): List<NasAccount> = strictAccountMutationList()

    /** 危险操作完成后使用严格契约专项回读；失败不得折叠为空列表。 */
    suspend fun activeGroups(): List<NasGroup> = strictGroupMutationList()

    /** 读取物理网卡并保留能力、权限、网络与响应结构失败语义。 */
    suspend fun activeEthernetInterfaces(): List<NasEthernetInterface> = ethernetInterfaces()

    /** 严格读取 DDNS 目录；结构失败不会降级成可信空目录。 */
    suspend fun activeDdnsDirectory(): NasDdnsDirectory {
        if (!supportsDdnsV1()) throw DsmFailure(
            103,
            "DDNS API version is unsupported",
            "Update DSM and refresh DDNS settings.",
            kind = DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
        )
        return ddnsDirectory()
    }

    suspend fun fileServiceSettings(): NasFileServiceSettings =
        (nasServices.load(io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind.FILES) as io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue.Files).settings

    suspend fun terminalSettings(): NasTerminalSettings =
        (nasServices.load(io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind.TERMINAL) as io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue.Terminal).settings

    suspend fun proxySettings(): NasProxySettings =
        (nasServices.load(io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceKind.PROXY) as io.github.qwertyuiop1995.dsmnativeclient.domain.NasServiceValue.Proxy).settings

    suspend fun regionSettings(): NasRegionSettings = nasRegion.load()

    suspend fun securitySettings(): NasSecuritySettings {
        if (!supportsVersion(SECURITY_AUTO_BLOCK_API, 1)) throw DsmFailure(
            103,
            "Security settings API version is unsupported",
            "Update DSM and refresh the security settings.",
            kind = DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
        )
        val autoBlock = call(SECURITY_AUTO_BLOCK_API, "get", version = 1)
        val enabled = strictRequiredSettingsBoolean(autoBlock, "enable", "security")
        val attempts = strictRequiredSettingsInt(autoBlock, "attempts", "security")
        val withinMinutes = strictRequiredSettingsInt(autoBlock, "within_mins", "security")
        val expiration = strictRequiredSettingsInt(autoBlock, "expire_day", "security")
        if (attempts !in 1..9_999 || withinMinutes !in 1..9_999_999 || expiration !in 0..999) {
            throw invalidSettingsResponse("security-range")
        }
        val firewall = if (supportsVersion(SECURITY_FIREWALL_API, 1)) {
            call(SECURITY_FIREWALL_API, "get", version = 1)
        } else null
        val firewallConf = if (supportsVersion(SECURITY_FIREWALL_CONF_API, 1)) {
            call(SECURITY_FIREWALL_CONF_API, "get", version = 1)
        } else null
        firewall?.let {
            strictRequiredSettingsBoolean(it, "enable_firewall", "security-firewall")
            strictRequiredSettingsString(it, "profile_name", "security-firewall")
        }
        firewallConf?.let {
            strictRequiredSettingsBoolean(it, "enable_port_check", "security-firewall-conf")
        }
        val dos = if (
            supportsVersion(ETHERNET_API, 2) && supportsVersion(SECURITY_DOS_API, 2)
        ) {
            val ethernet = call(ETHERNET_API, "list", version = 2)
            val adapterRows = strictSettingsRows(
                ethernet,
                setOf("interfaces", "adapters", "_array"),
                "security-ethernet",
            )
            val adapters = adapterRows.map { item ->
                val id = strictSettingsIdentity(item, listOf("ifname", "id", "name"), "security-adapter")
                if (!isSafeSecurityAdapterId(id)) throw invalidSettingsResponse("security-adapter")
                val name = strictOptionalSettingsString(item, "display")
                    ?: strictOptionalSettingsString(item, "display_name")
                    ?: id
                id to name
            }
            if (adapters.map { it.first }.distinct().size != adapters.size) {
                throw invalidSettingsResponse("security-adapter-duplicate")
            }
            if (adapters.isEmpty()) emptyList() else {
                val query = JsonArray(adapters.map { (id, _) ->
                    JsonObject(mapOf("adapter" to JsonPrimitive(id)))
                }).toString()
                val values = call(
                    SECURITY_DOS_API, "get", mapOf("configs" to query), version = 2,
                )
                val configRows = strictSettingsRows(
                    values,
                    setOf("configs", "_array"),
                    "security-dos",
                )
                val states = configRows.map { item ->
                    val id = item.strictString("adapter")
                        ?: throw invalidSettingsResponse("security-dos-adapter")
                    val state = item["dos_protect_enable"].strictBooleanValue(allowString = true)
                        ?: throw invalidSettingsResponse("security-dos-state")
                    id to state
                }
                if (states.map { it.first }.toSet() != adapters.map { it.first }.toSet()
                ) throw invalidSettingsResponse("security-dos-identity")
                val byId = states.toMap()
                adapters.map { (id, name) ->
                    NasDoSProtectionSetting(id, name, checkNotNull(byId[id]))
                }
            }
        } else emptyList()
        return NasSecuritySettings(
            enabled, attempts, withinMinutes, expiration.takeIf { it > 0 }, dos,
            firewall?.let { strictRequiredSettingsBoolean(it, "enable_firewall", "security-firewall") },
            firewall?.let { strictRequiredSettingsString(it, "profile_name", "security-firewall") },
            firewallConf?.let {
                strictRequiredSettingsBoolean(it, "enable_port_check", "security-firewall-conf")
            },
        )
    }

    suspend fun activeSecuritySettings(): NasSecuritySettings = securitySettings()

    suspend fun hardwareSettings(): NasHardwareSettings = hardwareSettingsRead()

    suspend fun activeHardwareSettings(): NasHardwareSettings = hardwareSettings()

    private suspend fun hardwareSettingsRead(): NasHardwareSettings {
        val available = HARDWARE_APIS.any { supportsVersion(it, 1) }
        if (!available) throw DsmFailure(
            103,
            "Hardware settings API version is unsupported",
            "Update DSM and refresh the hardware settings.",
            kind = DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
        )
        suspend fun optional(apiName: String, method: String = "get") =
            if (supportsVersion(apiName, 1)) call(apiName, method, version = 1) else null
        val power = optional(HARDWARE_POWER_RECOVERY_API)
        val led = optional(HARDWARE_LED_API)
        val ledStatic = optional(HARDWARE_LED_API, "get_static_data")
        val fan = optional(HARDWARE_FAN_API)
        val beep = optional(HARDWARE_BEEP_API)
        val hibernation = optional(HARDWARE_HIBERNATION_API)
        val ups = optional(HARDWARE_UPS_API)
        val beepVolumeFieldName = when {
            beep?.containsKey("volume_or_cache_crash") == true -> "volume_or_cache_crash"
            beep?.containsKey("volume_crash") == true -> "volume_crash"
            else -> null
        }
        if (beep != null && beepVolumeFieldName == null && HARDWARE_BEEP_FIELDS.none(beep::containsKey)) {
            throw invalidSettingsResponse("hardware-beep")
        }
        if (hibernation != null && HARDWARE_HIBERNATION_FIELDS.none(hibernation::containsKey)) {
            throw invalidSettingsResponse("hardware-hibernation")
        }
        val ledMin = ledStatic?.let { strictRequiredSettingsInt(it, "min", "hardware-led-range") }
        val ledMax = ledStatic?.let { strictRequiredSettingsInt(it, "max", "hardware-led-range") }
        if (ledMin != null && ledMax != null && ledMin > ledMax) {
            throw invalidSettingsResponse("hardware-led-range")
        }
        val ledBrightness = led?.let {
            strictRequiredSettingsInt(it, "led_brightness", "hardware-led")
        }
        if (ledBrightness != null && ledMin != null && ledMax != null && ledBrightness !in ledMin..ledMax) {
            throw invalidSettingsResponse("hardware-led-brightness")
        }
        val fanMode = fan?.let {
            strictRequiredSettingsString(it, "dual_fan_speed", "hardware-fan")
        }
        fun sound(field: String, support: String): Boolean? = beep?.let {
            if (strictOptionalSettingsBoolean(it, support, "hardware-beep-support") == false) null
            else strictOptionalSettingsBoolean(it, field, "hardware-beep")
        }
        val settings = NasHardwareSettings(
            restartsAfterPowerFailure = power?.let {
                strictRequiredSettingsBoolean(it, "rc_power_config", "hardware-power")
            },
            ledBrightness = ledBrightness,
            ledBrightnessMinimum = ledMin,
            ledBrightnessMaximum = ledMax,
            fanMode = fanMode,
            isFanFailureAlertEnabled = sound("fan_fail", "support_fan_fail"),
            isVolumeFailureAlertEnabled = beepVolumeFieldName?.let { field ->
                sound(field, "support_volume_crash")
            },
            isPowerOnSoundEnabled = sound("poweron_beep", "support_poweron_beep"),
            isPowerOffSoundEnabled = sound("poweroff_beep", "support_poweroff_beep"),
            isResetSoundEnabled = sound("reset_beep", "support_reset_beep"),
            isExternalDriveDeepSleepEnabled = hibernation?.let {
                strictOptionalSettingsBoolean(it, "eunit_deep_sleep", "hardware-hibernation")
            },
            isWakeUpLogEnabled = hibernation?.let {
                strictOptionalSettingsBoolean(it, "enable_log", "hardware-hibernation")
            },
            isSataSleepEnabled = hibernation?.let {
                strictOptionalSettingsBoolean(it, "sata_deep_sleep", "hardware-hibernation")
            },
            ignoresNetworkDiscoveryDuringSleep = hibernation?.let {
                strictOptionalSettingsBoolean(it, "ignore_netbios_broadcast", "hardware-hibernation")
            },
            isAutomaticPowerOffEnabled = hibernation?.let {
                strictOptionalSettingsBoolean(it, "auto_poweroff_enable", "hardware-hibernation")
            },
            ups = ups?.let(::parseUpsSettingsStrict),
            supportedFanModes = supportedHardwareFanModes(fan),
            beepVolumeFieldName = beepVolumeFieldName,
        )
        return settings
    }

    private suspend fun securityResources(): List<ManagedResource> {
        val apis = listOf(
            "SYNO.Core.Security.AutoBlock" to ManagedResourceLabel.SECURITY_AUTO_BLOCK,
            "SYNO.Core.Security.DoS" to ManagedResourceLabel.SECURITY_DOS_PROTECTION,
            "SYNO.Core.Security.Firewall" to ManagedResourceLabel.SECURITY_FIREWALL,
        )
        return apis.mapNotNull { (apiName, label) ->
            if (!supports(apiName)) return@mapNotNull null
            val data = runCatching { firstSuccessful(apiName, listOf("get", "list")) }.getOrNull()
                ?: return@mapNotNull null
            val enabled = data.bool("enable") ?: data.bool("enabled")
            ManagedResource(
                id = apiName,
                name = "",
                detail = "",
                state = if (enabled == false) ResourceState.WARNING else ResourceState.HEALTHY,
                localizedLabel = label,
            )
        }
    }

    private suspend fun resourceList(
        apiName: String,
        methods: List<String>,
        vararg roots: String,
    ): List<ManagedResource> {
        if (!supports(apiName)) return emptyList()
        val data = firstSuccessful(apiName, methods)
        return genericResources(data, *roots)
    }

    /** VMM 写操作依赖的列表必须具有唯一、稳定的显式标识。 */
    private suspend fun strictVirtualizationResourceList(
        apiName: String,
        methods: List<String>,
        vararg roots: String,
    ): List<ManagedResource> {
        if (!supports(apiName)) return emptyList()
        val data = firstSuccessful(apiName, methods)
        val acceptedRoots = (roots.asSequence() + sequenceOf("items")).distinct().toList()
        val presentRoots = acceptedRoots.filter(data::containsKey)
        if (presentRoots.size != 1) throw invalidVirtualizationResponse("list-root")
        val elements = data[presentRoots.single()] as? JsonArray
            ?: throw invalidVirtualizationResponse("list-array")
        val ids = elements.map { element ->
            val item = element as? JsonObject
                ?: throw invalidVirtualizationResponse("list-item")
            val explicitIds = listOf(
                "id", "uuid", "guest_id", "host_id", "storage_id", "network_id", "image_id",
            ).mapNotNull { key ->
                item[key].strictStringValue()?.trim()?.takeIf(String::isNotEmpty)
                    ?: item[key].strictIntValue()?.toString()
            }.distinct()
            if (explicitIds.size != 1) throw invalidVirtualizationResponse("list-id")
            explicitIds.single()
        }
        if (ids.distinct().size != ids.size) throw invalidVirtualizationResponse("list-duplicate-id")
        return genericResources(data, *roots)
    }

    private fun invalidVirtualizationResponse(scope: String) = DsmFailure(
        null,
        "Virtual Machine Manager returned an invalid response ($scope)",
        "Refresh Virtual Machine Manager and try again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    private fun genericResources(data: JsonObject, vararg roots: String): List<ManagedResource> {
        val elements = roots.asSequence()
            .flatMap { data.elements(it).asSequence() }
            .ifEmpty { data.arrayValue("items").asSequence() }
        return elements.mapIndexedNotNull { index, element ->
            val item = element as? JsonObject ?: return@mapIndexedNotNull null
            val id = item.string("id")
                ?: item.string("uuid")
                ?: item.string("guest_id")
                ?: item.string("host_id")
                ?: item.string("storage_id")
                ?: item.string("network_id")
                ?: item.string("image_id")
                ?: item.string("name")
                ?: item.long("id")?.toString()
                ?: "item-$index"
            val name = item.string("name")
                ?: item.string("title")
                ?: item.string("guest_name")
                ?: item.string("host_name")
                ?: item.string("storage_name")
                ?: item.string("network_name")
                ?: item.string("image_name")
                ?: item.string("repo")
                ?: id
            val statusText = item.string("status") ?: item.string("state") ?: item.string("health")
            ManagedResource(
                id = id,
                name = name,
                detail = statusText ?: item.string("description") ?: "",
                state = state(statusText),
                metadata = item.entries
                    .filter { (_, value) -> value is JsonPrimitive }
                    .associate { (key, value) ->
                        key to value.jsonPrimitive.contentOrNull.orEmpty()
                    },
            )
        }.distinctBy(ManagedResource::id).toList()
    }

    /** Container 列表必须出现对象数组；结构漂移不能静默冒充真实空列表。 */
    private fun strictContainerResources(
        data: JsonObject,
        vararg roots: String,
    ): List<ManagedResource> {
        val arrays = (roots.asSequence() + sequenceOf("items"))
            .mapNotNull { key -> data[key] as? JsonArray }
            .toList()
        if (arrays.isEmpty() || arrays.any { array -> array.any { it !is JsonObject } }) {
            throw DsmFailure(
                null,
                "Container Manager returned an invalid list",
                "Refresh this information and try again.",
                kind = DsmErrorKind.INVALID_RESPONSE,
            )
        }
        return genericResources(data, *roots)
    }

    private suspend fun firstSuccessful(
        apiName: String,
        methods: List<String>,
        parameters: Map<String, String> = emptyMap(),
    ): JsonObject {
        var last: Throwable? = null
        for (method in methods) {
            try {
                return call(apiName, method, parameters)
            } catch (error: DsmFailure) {
                last = error
                if (error.code !in setOf(102, 103)) throw error
            }
        }
        throw last ?: DsmFailure(
            null,
            "Feature unsupported",
            "Update the related package.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
    }

    private suspend fun call(
        apiName: String,
        method: String,
        parameters: Map<String, String> = emptyMap(),
        version: Int? = null,
    ): JsonObject = requestBuilder.call(apiName, method, parameters, version)

    private fun requireCapability(apiName: String): ApiCapability =
        capabilityResolver.requireCapability(apiName)

    private suspend fun claimFavoriteMutation(path: String): Boolean =
        favoriteMutationLock.withLock { favoriteMutations.add(path) }

    private suspend fun releaseFavoriteMutation(path: String) {
        favoriteMutationLock.withLock { favoriteMutations.remove(path) }
    }

    private fun favoriteSubmissionFailure(
        failure: DsmFailure,
        operation: String,
    ): MutationResult = when (failure.kind) {
        DsmErrorKind.PERMISSION_DENIED,
        DsmErrorKind.SESSION_EXPIRED,
        DsmErrorKind.AUTHENTICATION_FAILED,
        -> favoriteResult(
            operation = operation,
            status = MutationResultStatus.PERMISSION_DENIED,
            submitted = true,
            failed = 1,
            errorCategory = if (failure.kind == DsmErrorKind.PERMISSION_DENIED) {
                MutationErrorCategory.PERMISSION
            } else {
                MutationErrorCategory.AUTHENTICATION
            },
            diagnosticTag = "file-station.favorite.add.rejected",
        )
        DsmErrorKind.FEATURE_UNSUPPORTED,
        DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
        -> favoriteResult(
            operation = operation,
            status = MutationResultStatus.UNSUPPORTED,
            submitted = true,
            failed = 1,
            errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = "file-station.favorite.add.unsupported",
        )
        DsmErrorKind.CONNECTION_FAILED,
        DsmErrorKind.INVALID_RESPONSE,
        DsmErrorKind.UNKNOWN,
        -> favoriteResult(
            operation = operation,
            status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            submitted = true,
            requiresRefresh = true,
            unknown = 1,
            errorCategory = if (failure.kind == DsmErrorKind.UNKNOWN) {
                MutationErrorCategory.UNKNOWN
            } else {
                MutationErrorCategory.NETWORK
            },
            diagnosticTag = "file-station.favorite.add.submitted-unverified",
        )
        else -> favoriteResult(
            operation = operation,
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = true,
            failed = 1,
            errorCategory = MutationErrorCategory.SERVER,
            diagnosticTag = "file-station.favorite.add.rejected",
        )
    }

    private fun favoritePreflightFailure(
        failure: DsmFailure,
        operation: String,
    ): MutationResult {
        val category = fileMutationErrorCategory(failure)
        return favoriteResult(
            operation = operation,
            status = when (category) {
                MutationErrorCategory.PERMISSION,
                MutationErrorCategory.AUTHENTICATION,
                -> MutationResultStatus.PERMISSION_DENIED
                MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
                else -> MutationResultStatus.CONFIRMED_FAILURE
            },
            submitted = false,
            failed = 1,
            errorCategory = category,
            diagnosticTag = "file-station.favorite.${if (operation == "favoriteRemove") "remove" else "add"}.preflight-failed",
        )
    }

    private fun favoriteReadbackFailure(
        failure: DsmFailure,
        operation: String,
    ): MutationResult = favoriteResult(
        operation = operation,
        status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        submitted = true,
        requiresRefresh = true,
        unknown = 1,
        errorCategory = when (failure.kind) {
            DsmErrorKind.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
            DsmErrorKind.ARCHIVE_INVALID_SELECTION -> MutationErrorCategory.VALIDATION
            DsmErrorKind.SESSION_EXPIRED,
            DsmErrorKind.AUTHENTICATION_FAILED,
            -> MutationErrorCategory.AUTHENTICATION
            DsmErrorKind.FEATURE_UNSUPPORTED,
            DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
            -> MutationErrorCategory.UNSUPPORTED
            DsmErrorKind.CONNECTION_FAILED,
            DsmErrorKind.INVALID_RESPONSE,
            -> MutationErrorCategory.NETWORK
            else -> MutationErrorCategory.SERVER
        },
        diagnosticTag = "file-station.favorite.add.readback-unverified",
    )

    private fun favoriteResult(
        operation: String = "favoriteAdd",
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
    ) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = operation,
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = MutationResultCounts(succeeded, failed, unknown),
        errorCategory = errorCategory,
        localizationKey = "mutation.${if (operation == "favoriteRemove") "favorite_remove" else "favorite_add"}.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private fun preferredOrNull(vararg names: String): String? =
        capabilityResolver.preferredOrNull(*names)

    private suspend fun verifyExists(path: String) {
        val parent = path.substringBeforeLast('/', "")
        val name = path.substringAfterLast('/')
        val exists = listDirectory(if (parent.isBlank()) "/" else parent).items.any { it.name == name }
        if (!exists) {
            throw DsmFailure(
                null,
                "The NAS did not confirm the change",
                "Refresh the list and check the result.",
                kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
            )
        }
    }

    private fun uploadPreflightFailure(failure: DsmFailure): MutationResult {
        val category = uploadMutationErrorCategory(failure)
        return uploadMutationResult(
            status = when (category) {
                MutationErrorCategory.PERMISSION,
                MutationErrorCategory.AUTHENTICATION,
                -> MutationResultStatus.PERMISSION_DENIED
                MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
                else -> MutationResultStatus.CONFIRMED_FAILURE
            },
            submitted = false,
            failed = 1,
            errorCategory = category,
            diagnosticTag = "file-station.upload.preflight-failed",
        )
    }

    private fun uploadMutationErrorCategory(failure: DsmFailure): MutationErrorCategory =
        when (failure.kind) {
            DsmErrorKind.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
            DsmErrorKind.ARCHIVE_INVALID_SELECTION -> MutationErrorCategory.VALIDATION
            DsmErrorKind.SESSION_EXPIRED,
            DsmErrorKind.AUTHENTICATION_FAILED,
            -> MutationErrorCategory.AUTHENTICATION
            DsmErrorKind.FEATURE_UNSUPPORTED,
            DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
            -> MutationErrorCategory.UNSUPPORTED
            DsmErrorKind.CONNECTION_FAILED,
            DsmErrorKind.INVALID_RESPONSE,
            -> MutationErrorCategory.NETWORK
            else -> MutationErrorCategory.SERVER
        }

    private fun uploadMutationResult(
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
    ) = MutationResult(
        schemaVersion = 1,
        status = status,
        operation = "fileUpload",
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        counts = MutationResultCounts(succeeded, failed, unknown),
        errorCategory = errorCategory,
        localizationKey = "mutation.file_upload.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private suspend fun deleteServiceResourceResult(
        operation: String,
        targetType: String,
        id: String,
        apiName: String,
        root: String,
        method: String,
    ): MutationResult {
        val normalizedId = id.trim()
        if (normalizedId.isEmpty()) {
            return serviceMutationResult(
                operation = operation,
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "$targetType.delete.invalid-input",
            )
        }
        return verifiedServiceMutation(
            operation = operation,
            targetKey = "$targetType:$normalizedId",
            requiredApi = apiName,
            preflight = {
                resourceList(apiName, listOf("list", "get"), root).any { it.id == normalizedId }
            },
            submit = {
                call(apiName, method, mapOf("id" to normalizedId))
            },
            verify = {
                resourceList(apiName, listOf("list", "get"), root).none { it.id == normalizedId }
            },
        )
    }

    private fun parseUpsSettingsStrict(data: JsonObject): NasUpsSettings {
        val enabled = strictRequiredSettingsBoolean(data, "enable", "hardware-ups")
        val mode = strictRequiredSettingsString(data, "mode", "hardware-ups")
        if (mode !in UPS_MODES) throw invalidSettingsResponse("hardware-ups-mode")
        val delay = strictOptionalSettingsInt(data, "delay_time", "hardware-ups")
        if (delay?.let { it !in 0..604_800 } == true) {
            throw invalidSettingsResponse("hardware-ups-delay")
        }
        return NasUpsSettings(
            enabled, mode, delay,
            strictOptionalSettingsBoolean(data, "ups_set_safemode_until_lowbatt", "hardware-ups"),
            strictOptionalSettingsBoolean(data, "shutdown_device", "hardware-ups"),
            strictOptionalSettingsString(data, "net_server_ip")?.trim(),
            strictOptionalSettingsString(data, "snmp_server_ip")?.trim(),
        )
    }

    private fun strictSettingsRows(
        data: JsonObject,
        roots: Set<String>,
        scope: String,
    ): List<JsonObject> {
        val present = roots.mapNotNull { root -> data[root]?.let { root to it } }
        if (present.size != 1) throw invalidSettingsResponse(scope)
        val array = present.single().second as? JsonArray ?: throw invalidSettingsResponse(scope)
        return array.map { it as? JsonObject ?: throw invalidSettingsResponse(scope) }
    }

    private fun strictSettingsIdentity(
        item: JsonObject,
        keys: List<String>,
        scope: String,
    ): String {
        val values = keys.mapNotNull { key ->
            if (!item.containsKey(key)) null
            else item.strictString(key) ?: throw invalidSettingsResponse(scope)
        }
        if (values.isEmpty() || values.distinct().size != 1 || values.first().isBlank()) {
            throw invalidSettingsResponse(scope)
        }
        return values.first()
    }

    private fun strictOptionalSettingsString(data: JsonObject, key: String): String? {
        if (!data.containsKey(key)) return null
        return data.strictString(key) ?: throw invalidSettingsResponse("$key-type")
    }

    private fun strictRequiredSettingsString(data: JsonObject, key: String, scope: String): String =
        strictOptionalSettingsString(data, key)?.takeIf(String::isNotBlank)
            ?: throw invalidSettingsResponse(scope)

    private fun strictOptionalSettingsBoolean(data: JsonObject, key: String, scope: String): Boolean? {
        if (!data.containsKey(key)) return null
        return data[key].strictBooleanValue(allowString = true)
            ?: throw invalidSettingsResponse(scope)
    }

    private fun strictRequiredSettingsBoolean(data: JsonObject, key: String, scope: String): Boolean =
        strictOptionalSettingsBoolean(data, key, scope) ?: throw invalidSettingsResponse(scope)

    private fun strictOptionalSettingsInt(data: JsonObject, key: String, scope: String): Int? {
        if (!data.containsKey(key)) return null
        return data[key].strictIntValue(allowString = true) ?: throw invalidSettingsResponse(scope)
    }

    private fun strictRequiredSettingsInt(data: JsonObject, key: String, scope: String): Int =
        strictOptionalSettingsInt(data, key, scope) ?: throw invalidSettingsResponse(scope)

    private fun isSafeSecurityAdapterId(id: String): Boolean =
        id.isNotEmpty() && id.length <= 128 && id.all { it.isLetterOrDigit() || it == '_' || it == '-' }

    private fun supportsVersion(apiName: String, version: Int): Boolean =
        capabilityResolver.supportsVersion(apiName, version)

    private fun invalidSettingsResponse(scope: String) = DsmFailure(
        null,
        "$scope settings response is invalid",
        "Refresh the settings and try again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    private fun unsupportedServiceMutation(operation: String, diagnosticTag: String) =
        serviceMutationResult(
            operation = operation,
            status = MutationResultStatus.UNSUPPORTED,
            submitted = false,
            errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = diagnosticTag,
        )

    private suspend fun verifiedServiceMutation(
        operation: String,
        targetKey: String,
        requiredApi: String,
        preflight: suspend () -> Boolean,
        submit: suspend () -> Unit,
        verify: suspend () -> Boolean,
        submissionRequired: () -> Boolean = { true },
        allowAmbiguousConfirmation: Boolean = true,
        singleAmbiguousVerification: Boolean = false,
        successfulVerificationAttempts: Int = 8,
        successfulVerificationIntervalMillis: Long = 500L,
        ambiguousVerificationAttempts: Int = if (singleAmbiguousVerification) 1 else 8,
        ambiguousVerificationIntervalMillis: Long = 500L,
        cancellationVerificationAttempts: Int = if (singleAmbiguousVerification) 1 else 8,
        cancellationVerificationIntervalMillis: Long = 500L,
    ): MutationResult {
        if (!supports(requiredApi)) {
            return serviceMutationResult(
                operation = operation,
                status = MutationResultStatus.UNSUPPORTED,
                submitted = false,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "service.mutation.unsupported",
            )
        }
        if (!claimServiceMutation(targetKey)) {
            return serviceMutationResult(
                operation = operation,
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "service.mutation.duplicate",
            )
        }
        var submitted = false
        try {
            val targetReady = try {
                preflight()
            } catch (cancelled: CancellationException) {
                return serviceMutationResult(
                    operation = operation,
                    status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "service.mutation.cancelled-before-submission",
                )
            } catch (error: Throwable) {
                return serviceMutationFailure(
                    operation = operation,
                    failure = error.asRepositoryFailure(),
                    submitted = false,
                    diagnosticTag = "service.mutation.preflight-failed",
                )
            }
            if (!targetReady) {
                return serviceMutationResult(
                    operation = operation,
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "service.mutation.target-changed",
                )
            }
            if (!submissionRequired()) {
                return serviceMutationResult(
                    operation = operation,
                    status = MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    diagnosticTag = "service.mutation.no-change",
                )
            }

            try {
                currentCoroutineContext().ensureActive()
                submitted = true
                submit()
            } catch (cancelled: CancellationException) {
                if (!submitted) {
                    return serviceMutationResult(
                        operation = operation,
                        status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        submitted = false,
                        diagnosticTag = "service.mutation.cancelled-before-submit",
                    )
                }
                if (
                    allowAmbiguousConfirmation &&
                    confirmServiceState(
                        verify,
                        cancellationVerificationAttempts,
                        cancellationVerificationIntervalMillis,
                    )
                ) {
                    return serviceMutationResult(
                        operation = operation,
                        status = MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        diagnosticTag = "service.mutation.cancelled-but-confirmed",
                    )
                }
                return serviceMutationResult(
                    operation = operation,
                    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    diagnosticTag = "service.mutation.cancelled-after-submission",
                )
            } catch (error: Throwable) {
                val failure = error.asRepositoryFailure()
                if (
                    failure.kind in setOf(
                        DsmErrorKind.CONNECTION_FAILED,
                        DsmErrorKind.INVALID_RESPONSE,
                        DsmErrorKind.UNKNOWN,
                    ) && allowAmbiguousConfirmation &&
                    confirmServiceState(
                        verify,
                        ambiguousVerificationAttempts,
                        ambiguousVerificationIntervalMillis,
                    )
                ) {
                    return serviceMutationResult(
                        operation = operation,
                        status = MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        diagnosticTag = "service.mutation.ambiguous-submit-confirmed",
                    )
                }
                return serviceMutationFailure(
                    operation = operation,
                    failure = failure,
                    submitted = true,
                    diagnosticTag = "service.mutation.submission-failed",
                )
            }

            return try {
                withContext(NonCancellable) {
                    waitUntil(
                        attempts = successfulVerificationAttempts,
                        intervalMillis = successfulVerificationIntervalMillis,
                        condition = verify,
                    )
                }
                serviceMutationResult(
                    operation = operation,
                    status = MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    diagnosticTag = "service.mutation.confirmed",
                )
            } catch (error: Throwable) {
                serviceMutationResult(
                    operation = operation,
                    status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    errorCategory = error.asRepositoryFailure().mutationErrorCategory(),
                    diagnosticTag = "service.mutation.readback-unverified",
                )
            }
        } finally {
            withContext(NonCancellable) { releaseServiceMutation(targetKey) }
        }
    }

    private suspend fun confirmServiceState(
        verify: suspend () -> Boolean,
        attempts: Int,
        intervalMillis: Long,
    ): Boolean =
        try {
            withContext(NonCancellable) {
                waitUntil(attempts, intervalMillis, verify)
            }
            true
        } catch (_: Throwable) {
            false
        }

    private suspend fun claimServiceMutation(target: String): Boolean = serviceMutationLock.withLock {
        val conflicts = target in activeServiceMutationTargets
        if (conflicts) false else activeServiceMutationTargets.add(target)
    }

    private suspend fun releaseServiceMutation(target: String) {
        serviceMutationLock.withLock { activeServiceMutationTargets.remove(target) }
    }

    private fun serviceMutationFailure(
        operation: String,
        failure: DsmFailure,
        submitted: Boolean,
        diagnosticTag: String,
        affectedCount: Int = 1,
    ): MutationResult {
        val status = when (failure.kind) {
            DsmErrorKind.PERMISSION_DENIED,
            DsmErrorKind.SESSION_EXPIRED,
            DsmErrorKind.AUTHENTICATION_FAILED,
            -> MutationResultStatus.PERMISSION_DENIED
            DsmErrorKind.FEATURE_UNSUPPORTED,
            DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
            -> MutationResultStatus.UNSUPPORTED
            DsmErrorKind.CONNECTION_FAILED,
            DsmErrorKind.INVALID_RESPONSE,
            DsmErrorKind.UNKNOWN,
            -> if (submitted) {
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            } else {
                MutationResultStatus.CONFIRMED_FAILURE
            }
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return serviceMutationResult(
            operation = operation,
            status = status,
            submitted = submitted,
            requiresRefresh = submitted && status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            errorCategory = failure.mutationErrorCategory(),
            diagnosticTag = diagnosticTag,
            affectedCount = affectedCount,
        )
    }

    private fun serviceMutationResult(
        operation: String,
        status: MutationResultStatus,
        submitted: Boolean,
        requiresRefresh: Boolean = false,
        errorCategory: MutationErrorCategory? = null,
        diagnosticTag: String,
        affectedCount: Int = 1,
    ): MutationResult = mutationVerifier.serviceResult(
        operation = operation,
        status = status,
        submitted = submitted,
        requiresRefresh = requiresRefresh,
        errorCategory = errorCategory,
        diagnosticTag = diagnosticTag,
        affectedCount = affectedCount,
    )

    private fun Throwable.asRepositoryFailure(): DsmFailure = mutationVerifier.asRepositoryFailure(this)

    private fun DsmFailure.mutationErrorCategory(): MutationErrorCategory =
        mutationVerifier.mutationErrorCategory(this)

    private suspend fun pathExists(path: String): Boolean {
        val parent = path.substringBeforeLast('/', "")
        val items = if (parent.isBlank()) {
            listShares().items
        } else {
            listDirectory(parent).items
        }
        return items.any { it.path == path }
    }

    private suspend fun waitUntil(condition: suspend () -> Boolean) =
        waitUntil(attempts = 8, intervalMillis = 500L, condition = condition)

    private suspend fun waitUntil(
        attempts: Int,
        intervalMillis: Long,
        condition: suspend () -> Boolean,
    ) {
        require(attempts > 0)
        require(intervalMillis >= 0)
        repeat(attempts) { attempt ->
            if (condition()) return
            if (attempt < attempts - 1 && intervalMillis > 0) delay(intervalMillis)
        }
        throw DsmFailure(
            null,
            "The NAS did not confirm the change",
            "Refresh the list and check the result.",
            kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
        )
    }

    private fun systemSummary(data: JsonObject) = SystemSummary(
        serverName = data.string("server_name") ?: data.string("hostname") ?: "NAS",
        model = data.string("model") ?: "Synology NAS",
        serial = data.string("serial"),
        dsmVersion = data.string("firmware_ver") ?: data.string("version") ?: "DSM",
        uptimeSeconds = data.long("up_time") ?: data.long("uptime"),
        temperatureCelsius = data.string("temperature")?.toDoubleOrNull(),
    )

    private fun capacityList(data: JsonObject): List<CapacitySummary> =
        sequenceOf("volumes", "volume")
            .flatMap { data.elements(it).asSequence() }
            .mapNotNull { element ->
                val item = element as? JsonObject ?: return@mapNotNull null
                val total = item.long("size_total") ?: item.long("total_size") ?: return@mapNotNull null
                val used = item.long("size_used")
                    ?: item.long("used_size")
                    ?: (total - (item.long("size_free") ?: total))
                CapacitySummary(
                    id = item.string("id") ?: item.string("volume_path") ?: "volume",
                    name = item.string("display_name") ?: item.string("volume_path").orEmpty(),
                    totalBytes = total,
                    usedBytes = used,
                    status = state(item.string("status")),
                )
            }
            .toList()

    private fun storageDisks(data: JsonObject): List<NasStorageDisk> =
        data.elements("disks").mapIndexedNotNull { index, element ->
            val item = element as? JsonObject ?: return@mapIndexedNotNull null
            val id = item.valueString("id", "device", "name") ?: "disk-$index"
            val deviceId = item.string("device") ?: id
            val smartStatus = item.string("smart_status")
            NasStorageDisk(
                id = id,
                deviceId = deviceId,
                name = item.valueString("longName", "name", "device") ?: "Drive ${index + 1}",
                model = item.string("model"),
                status = item.valueString(
                    "summary_status_key", "drive_status_key", "overview_status", "status",
                ),
                smartStatus = smartStatus,
                temperatureCelsius = item.string("temp")?.toDoubleOrNull()
                    ?: item.long("temp")?.toDouble(),
                supportsSmartTest = item.bool("smart_test_support") ?: (smartStatus != null),
            )
        }

    private suspend fun packageList(): List<PackageInfo> = packages(
        firstSuccessful(
            "SYNO.Core.Package",
            listOf("list"),
            mapOf(
                "offset" to "0",
                "limit" to "1000",
                "additional" to "[\"status\",\"description\",\"install_type\",\"startable\",\"available_operation\",\"dsm_apps\",\"ctl_uninstall\"]",
            ),
        ),
    )

    private suspend fun strictPackageMutationList(): List<PackageInfo> {
        val data = call(
            PACKAGE_API,
            "list",
            mapOf(
                "offset" to "0",
                "limit" to "1000",
                "additional" to "[\"status\",\"description\",\"install_type\",\"startable\",\"available_operation\",\"dsm_apps\",\"ctl_uninstall\"]",
            ),
            version = PACKAGE_READ_VERSION,
        )
        val rows = strictSettingsRows(data, setOf("packages"), "package-list")
        if (rows.size >= 1000 || data["total"]?.takeUnless { it is JsonNull }?.let {
            val primitive = it as? JsonPrimitive
            primitive == null || primitive.isString || primitive.longOrNull != rows.size.toLong()
        } == true) throw invalidSettingsResponse("package-list-incomplete")
        val result = rows.map { item ->
            val additional = item["additional"]?.let {
                it as? JsonObject ?: throw invalidSettingsResponse("package-additional")
            }
            fun element(key: String): JsonElement? = additional?.get(key) ?: item[key]
            fun requiredString(key: String): String = element(key).strictStringValue()
                ?.takeIf(String::isNotBlank) ?: throw invalidSettingsResponse("package-$key")
            fun requiredBoolean(key: String): Boolean =
                element(key).strictBooleanValue(allowString = true)
                    ?: throw invalidSettingsResponse("package-$key")
            fun stringList(key: String, required: Boolean): List<String> = when (val value = element(key)) {
                is JsonArray -> value.map { entry ->
                    entry.strictStringValue()?.takeIf(String::isNotBlank)
                        ?: throw invalidSettingsResponse("package-$key")
                }
                is JsonPrimitive -> value.strictStringValue()?.split(Regex("\\s+"))
                    ?.filter(String::isNotBlank) ?: throw invalidSettingsResponse("package-$key")
                null -> if (required) throw invalidSettingsResponse("package-$key") else emptyList()
                else -> throw invalidSettingsResponse("package-$key")
            }
            val status = requiredString("status")
            val currentState = when (status.lowercase(Locale.ROOT)) {
                "running", "active" -> ResourceState.RUNNING
                "stopped", "inactive", "disabled" -> ResourceState.STOPPED
                "starting", "stopping", "waiting", "pending" -> ResourceState.WAITING
                "error", "failed" -> ResourceState.ERROR
                else -> ResourceState.UNKNOWN
            }
            if (currentState == ResourceState.UNKNOWN) {
                throw invalidSettingsResponse("package-status")
            }
            val operationDetails = element("available_operation") as? JsonObject
            val operations = if (operationDetails != null) emptySet() else stringList("available_operation", required = true)
                .map { it.lowercase(Locale.ROOT) }.toSet()
            val startable = requiredBoolean("startable")
            val installTypeElement = element("install_type")
            val installType = installTypeElement?.strictStringValue()?.lowercase(Locale.ROOT)
            if (installTypeElement != null && installType == null) {
                throw invalidSettingsResponse("package-install-type")
            }
            val uninstallElement = element("ctl_uninstall")
            val uninstallAllowed = uninstallElement.strictBooleanValue(allowString = true)
            if (uninstallElement != null && uninstallAllowed == null) {
                throw invalidSettingsResponse("package-uninstall-permission")
            }
            val id = requiredString("id")
            if (id.any(Char::isISOControl)) throw invalidSettingsResponse("package-id")
            val timestamp = item["timestamp"]?.takeUnless { it is JsonNull }?.let {
                val primitive = it as? JsonPrimitive ?: throw invalidSettingsResponse("package-timestamp")
                primitive.takeUnless { it.isString }?.doubleOrNull?.takeIf { it.isFinite() && it >= 0 }
                    ?: throw invalidSettingsResponse("package-timestamp")
            }
            PackageInfo(
                id = id,
                name = requiredString("name"),
                version = requiredString("version"),
                status = currentState,
                description = element("description")?.strictStringValue()
                    ?: if (element("description") != null) {
                        throw invalidSettingsResponse("package-description")
                    } else null,
                canStart = startable && currentState == ResourceState.STOPPED && (operationDetails != null || "start" in operations),
                canStop = startable && currentState == ResourceState.RUNNING && (operationDetails != null || "stop" in operations),
                canUninstall = !installType.isNullOrBlank() && installType !in setOf("system", "system_hidden") && uninstallAllowed != false &&
                    (uninstallAllowed == true || "uninstall" in operations),
                dsmApps = stringList("dsm_apps", required = true),
                isUpgradeAvailable = operationDetails?.get("upgrade") is JsonObject || "upgrade" in operations,
                installType = installType,
                installedAt = timestamp?.let { if (it > 10_000_000_000) it / 1_000 else it },
            )
        }
        if (result.map { it.id }.distinct().size != result.size) {
            throw invalidSettingsResponse("package-duplicate-id")
        }
        return result
    }

    private fun packages(data: JsonObject): List<PackageInfo> =
        data.elements("packages").mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val id = item.string("id") ?: item.string("package") ?: return@mapNotNull null
            val additional = item.objectValue("additional")
            fun string(key: String) = additional?.string(key) ?: item.string(key)
            fun bool(key: String) = additional?.bool(key) ?: item.bool(key)
            fun stringList(key: String): List<String> {
                val source = if (item[key] != null) item else additional
                return when (val value = source?.get(key)) {
                    is JsonArray -> value
                        .mapNotNull { (it as? JsonPrimitive)?.contentOrNull }
                        .filter(String::isNotBlank)
                    is JsonPrimitive -> value.contentOrNull
                        ?.split(Regex("\\s+"))
                        ?.filter(String::isNotBlank)
                        .orEmpty()
                    else -> emptyList()
                }
            }
            val status = string("status") ?: string("status_code")
            val installType = string("install_type")?.lowercase(Locale.ROOT)
            val operationDetails = (additional?.get("available_operation") ?: item["available_operation"]) as? JsonObject
            val operations = stringList("available_operation")
                .map { it.lowercase(Locale.ROOT) }
                .toSet()
            val startable = bool("startable") == true
            val currentState = state(status)
            PackageInfo(
                id = id,
                name = item.string("name") ?: id,
                version = item.string("version") ?: "",
                status = currentState,
                description = string("description"),
                canStart = startable && currentState == ResourceState.STOPPED && (operationDetails != null || "start" in operations),
                canStop = startable && currentState == ResourceState.RUNNING && (operationDetails != null || "stop" in operations),
                canUninstall = installType != null && installType !in setOf("system", "system_hidden") && bool("ctl_uninstall") != false &&
                    (bool("ctl_uninstall") == true || "uninstall" in operations),
                dsmApps = stringList("dsm_apps"),
                isUpgradeAvailable = operationDetails?.get("upgrade") is JsonObject || "upgrade" in operations,
            )
        }

    private suspend fun accountList(): List<NasAccount> = directory.accounts()

    private suspend fun strictAccountMutationList(): List<NasAccount> {
        val data = call(
            USER_API, "list",
            mapOf(
                "offset" to "0", "limit" to "1000",
                "additional" to "[\"uid\",\"description\",\"email\",\"expired\",\"groups\",\"can_edit\",\"can_delete\"]",
            ),
            version = DIRECTORY_API_VERSION,
        )
        val rows = strictSettingsRows(data, setOf("users"), "account-list")
        val result = rows.map { item ->
            val additional = item["additional"]?.let {
                it as? JsonObject ?: throw invalidSettingsResponse("account-additional")
            }
            val name = (item["name"] ?: item["username"]).strictStringValue()
                ?.takeIf(String::isNotBlank) ?: throw invalidSettingsResponse("account-name")
            val canDelete = (item["can_delete"] ?: additional?.get("can_delete"))
                .strictBooleanValue(allowString = true)
                ?: throw invalidSettingsResponse("account-can-delete")
            fun optionalBoolean(vararg keys: String): Boolean? {
                val value = keys.firstNotNullOfOrNull { key -> item[key] ?: additional?.get(key) }
                    ?: return null
                return value.strictBooleanValue(allowString = true)
                    ?: throw invalidSettingsResponse("account-boolean")
            }
            NasAccount(
                id = item.long("uid") ?: item.long("id") ?: additional?.long("uid"),
                name = name,
                description = item.strictOptionalMutationString("description")
                    ?: additional?.strictOptionalMutationString("description"),
                email = item.strictOptionalMutationString("email")
                    ?: additional?.strictOptionalMutationString("email"),
                disabled = optionalBoolean("disabled", "is_disabled", "expired") ?: false,
                canDelete = canDelete,
            )
        }
        if (result.map { it.name.lowercase(Locale.ROOT) }.distinct().size != result.size) {
            throw invalidSettingsResponse("account-duplicate-name")
        }
        return result
    }

    private suspend fun groupList(): List<NasGroup> = directory.groups()

    private suspend fun strictGroupMutationList(): List<NasGroup> {
        val data = call(
            GROUP_API, "list",
            mapOf(
                "offset" to "0", "limit" to "1000",
                "additional" to "[\"gid\",\"description\",\"can_edit\",\"can_delete\"]",
            ),
            version = DIRECTORY_API_VERSION,
        )
        val rows = strictSettingsRows(data, setOf("groups"), "group-list")
        val result = rows.map { item ->
            val additional = item["additional"]?.let {
                it as? JsonObject ?: throw invalidSettingsResponse("group-additional")
            }
            val name = item["name"].strictStringValue()?.takeIf(String::isNotBlank)
                ?: throw invalidSettingsResponse("group-name")
            val canDelete = (item["can_delete"] ?: additional?.get("can_delete"))
                .strictBooleanValue(allowString = true)
                ?: throw invalidSettingsResponse("group-can-delete")
            NasGroup(
                id = item.long("gid") ?: item.long("id") ?: additional?.long("gid"),
                name = name,
                description = item.strictOptionalMutationString("description")
                    ?: additional?.strictOptionalMutationString("description"),
                canDelete = canDelete,
            )
        }
        if (result.map { it.name.lowercase(Locale.ROOT) }.distinct().size != result.size) {
            throw invalidSettingsResponse("group-duplicate-name")
        }
        return result
    }

    private fun JsonObject.strictOptionalMutationString(key: String): String? {
        if (!containsKey(key)) return null
        return this[key].strictStringValue() ?: throw invalidSettingsResponse("$key-type")
    }

    private fun accounts(data: JsonObject): List<NasAccount> =
        data.elements("users").mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val additional = item.objectValue("additional")
            val name = item.string("name") ?: item.string("username") ?: return@mapNotNull null
            NasAccount(
                id = item.long("uid") ?: item.long("id") ?: additional?.long("uid"),
                name = name,
                description = item.string("description") ?: additional?.string("description"),
                email = item.string("email") ?: additional?.string("email"),
                disabled = item.bool("disabled") ?: item.bool("is_disabled")
                    ?: additional?.bool("expired") ?: false,
                canDelete = item.bool("can_delete") ?: additional?.bool("can_delete") ?: false,
            )
        }

    private fun groups(data: JsonObject): List<NasGroup> =
        data.elements("groups").mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val additional = item.objectValue("additional")
            NasGroup(
                id = item.long("gid") ?: item.long("id") ?: additional?.long("gid"),
                name = item.string("name") ?: return@mapNotNull null,
                description = item.string("description") ?: additional?.string("description"),
                canDelete = item.bool("can_delete") ?: additional?.bool("can_delete") ?: false,
            )
        }

    private fun logs(data: JsonObject): List<LogEntry> =
        sequenceOf("logs", "items", "data")
            .flatMap { data.elements(it).asSequence() }
            .mapIndexedNotNull { index, element ->
                val item = element as? JsonObject ?: return@mapIndexedNotNull null
                LogEntry(
                    id = item.string("id") ?: "log-$index",
                    level = logLevel(item.string("level") ?: item.string("priority")),
                    timeEpochSeconds = item.long("time") ?: item.long("timestamp"),
                    user = item.string("user") ?: item.string("username") ?: "SYSTEM",
                    event = item.string("event") ?: item.string("message") ?: return@mapIndexedNotNull null,
                )
            }
            .toList()

    private suspend fun connectionList(): List<ActiveConnection> = nasConnections.read().rows

    private suspend fun ddnsDirectory(): NasDdnsDirectory {
        if (!supportsDdnsV1()) throw DsmFailure(
            103,
            "DDNS API version is unsupported",
            "Update DSM and refresh DDNS settings.",
            kind = DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
        )
        val providerData = call(DDNS_PROVIDER_API, "list", version = 1)
        val providerRows = strictDdnsRows(providerData, setOf("providers", "items", "_array"), "providers")
        val providers = providerRows.map { item ->
            val id = strictDdnsIdentity(item, "id", "provider")
                ?: throw invalidDdnsResponse("provider-identity")
            if (!isSafeDdnsProviderId(id)) throw invalidDdnsResponse("provider-identity")
            val displayName = strictOptionalDdnsString(item, "display")
                ?: strictOptionalDdnsString(item, "name")
                ?: id
            NasDdnsProvider(id = id, displayName = displayName)
        }
        if (providers.map(NasDdnsProvider::id).distinct().size != providers.size) {
            throw invalidDdnsResponse("provider-duplicate")
        }
        val providerNames = providers.associate { it.id to it.displayName }
        val recordData = call(DDNS_RECORD_API, "list", version = 1)
        val recordRows = strictDdnsRows(recordData, setOf("records", "items", "_array"), "records")
        val records = recordRows.map { item ->
                val providerId = strictDdnsIdentity(item, "provider", "id")
                    ?: throw invalidDdnsResponse("record-identity")
                val hostname = item.strictString("hostname")
                    ?: throw invalidDdnsResponse("record-hostname")
                val username = item.strictString("username")
                    ?: throw invalidDdnsResponse("record-username")
                val isEnabled = item["enable"].strictBooleanValue(allowString = true)
                    ?: throw invalidDdnsResponse("record-enable")
                val heartbeat = item["heartbeat"].strictBooleanValue(allowString = true)
                    ?: throw invalidDdnsResponse("record-heartbeat")
                // DSM 只稳定回传五个核心字段；网络字段出现时严格校验，缺失时使用提交契约默认值。
                val networkType = strictOptionalDdnsString(item, "net") ?: "auto"
                val ipv4 = strictOptionalDdnsString(item, "ip") ?: "0.0.0.0"
                val ipv6 = strictOptionalDdnsString(item, "ipv6") ?: "0:0:0:0:0:0:0:0"
                val interfaceV4 = strictOptionalDdnsString(item, "interface_v4").orEmpty()
                val interfaceV6 = strictOptionalDdnsString(item, "interface_v6").orEmpty()
                if (
                    providerId !in providerNames || !isSafeDdnsProviderId(providerId) ||
                    !isValidDdnsHostname(hostname) || !isValidDdnsReadableFields(
                        username, networkType, ipv4, ipv6, interfaceV4, interfaceV6,
                    )
                ) throw invalidDdnsResponse("record-fields")
                val address = listOf(ipv4, ipv6)
                    .filter { it.isNotBlank() && it !in setOf("0.0.0.0", "0:0:0:0:0:0:0:0") }
                    .joinToString(" / ")
                    .ifBlank { null }
                NasDdnsRecord(
                    providerId = providerId,
                    providerName = providerNames[providerId] ?: providerId,
                    hostname = hostname,
                    address = address,
                    status = strictOptionalDdnsString(item, "status"),
                    lastUpdated = strictOptionalDdnsString(item, "lastupdated"),
                    isEnabled = isEnabled,
                    username = username,
                    networkType = networkType,
                    ipv4 = ipv4,
                    ipv6 = ipv6,
                    interfaceV4 = interfaceV4,
                    interfaceV6 = interfaceV6,
                    heartbeat = heartbeat,
                    knownNetworkFields = item.keys.intersect(setOf("net", "ip", "ipv6", "interface_v4", "interface_v6")),
                )
            }
        if (records.map(NasDdnsRecord::providerId).distinct().size != records.size) {
            throw invalidDdnsResponse("record-duplicate")
        }
        return NasDdnsDirectory(providers, records)
    }

    private fun strictDdnsRows(
        data: JsonObject,
        acceptedRoots: Set<String>,
        scope: String,
    ): List<JsonObject> {
        val roots = acceptedRoots.filter(data::containsKey)
        if (roots.size != 1) throw invalidDdnsResponse("$scope-root")
        val rows = data[roots.single()] as? JsonArray ?: throw invalidDdnsResponse("$scope-root-type")
        if (rows.any { it !is JsonObject }) throw invalidDdnsResponse("$scope-row-type")
        return rows.map { it as JsonObject }
    }

    private fun strictDdnsIdentity(item: JsonObject, primary: String, fallback: String): String? {
        val primaryValue = item.strictString(primary)
        val fallbackValue = item.strictString(fallback)
        if (primaryValue != null && fallbackValue != null && primaryValue != fallbackValue) {
            throw invalidDdnsResponse("identity-mismatch")
        }
        return primaryValue ?: fallbackValue
    }

    private fun strictOptionalDdnsString(item: JsonObject, key: String): String? {
        if (key !in item) return null
        return item.strictString(key) ?: throw invalidDdnsResponse("$key-type")
    }

    private fun invalidDdnsResponse(scope: String) = DsmFailure(
        null,
        "DDNS settings response is invalid",
        "Refresh DDNS settings and try again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    private fun supportsDdnsV1(): Boolean =
        supportsVersion(DDNS_PROVIDER_API, 1) && supportsVersion(DDNS_RECORD_API, 1)

    private suspend fun ethernetInterfaces(): List<NasEthernetInterface> {
        if (!supportsVersion(ETHERNET_API, 1) || !supportsVersion(ETHERNET_API, 2)) {
            throw DsmFailure(
                103,
                "Ethernet API version is unsupported",
                "Update DSM and refresh the network settings.",
                kind = DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
            )
        }
        val list = call(ETHERNET_API, "list", version = 2)
        val roots = listOf("interfaces", "ifaces", "_array").filter(list::containsKey)
        if (roots.size != 1) throw invalidEthernetResponse("list-root")
        val rows = list[roots.single()] as? JsonArray
            ?: throw invalidEthernetResponse("list-root-type")
        if (rows.any { it !is JsonObject }) throw invalidEthernetResponse("list-item-type")
        val identifiedRows = rows.map { element ->
            val row = element as JsonObject
            val id = row.strictString("ifname") ?: throw invalidEthernetResponse("list-identity")
            if (!isSafeEthernetId(id)) throw invalidEthernetResponse("list-identity")
            id to row
        }
        if (identifiedRows.map { it.first }.distinct().size != identifiedRows.size) {
            throw invalidEthernetResponse("list-duplicate-identity")
        }
        val result = mutableListOf<NasEthernetInterface>()
        for ((id, row) in identifiedRows) {
            result += ethernetInterfaceDetail(id, row)
        }
        return result
    }

    private suspend fun ethernetInterfaceDetail(
        id: String,
        fallback: JsonObject = JsonObject(emptyMap()),
    ): NasEthernetInterface {
        if (!isSafeEthernetId(id)) throw invalidEthernetResponse("detail-request-identity")
        val detail = call(
            ETHERNET_API,
            "get",
            mapOf("ifname" to id),
            version = 1,
        )
        fun detailElement(name: String): JsonElement? = detail[name] ?: detail["ethernet_$name"]
        fun detailString(name: String): String? = detailElement(name).strictStringValue()
        fun detailBool(name: String, allowString: Boolean = false): Boolean? =
            detailElement(name).strictBooleanValue(allowString)
        fun detailInt(name: String, allowString: Boolean = false): Int? =
            detailElement(name).strictIntValue(allowString)
        fun displayString(name: String): String? = detailString(name)
            ?: fallback[name].strictStringValue()
            ?: fallback["ethernet_$name"].strictStringValue()

        val responseId = detailString("ifname") ?: throw invalidEthernetResponse("detail-identity")
        if (responseId != id) throw invalidEthernetResponse("detail-identity-mismatch")
        val usesDhcp = detailBool("use_dhcp") ?: throw invalidEthernetResponse("detail-use-dhcp")
        val isDefaultGateway = detailBool("is_default_gateway")
            ?: throw invalidEthernetResponse("detail-default-gateway")
        val mtu = detailInt("mtu") ?: detailInt("mtu_config")
            ?: throw invalidEthernetResponse("detail-mtu")
        val isVlanEnabled = detailBool("enable_vlan", allowString = true)
            ?: throw invalidEthernetResponse("detail-vlan-state")
        val vlanId = if (isVlanEnabled) {
            detailInt("vlan_id", allowString = true)
                ?: throw invalidEthernetResponse("detail-vlan-id")
        } else {
            detailInt("vlan_id", allowString = true)
        }
        val address = if (usesDhcp) detailString("ip").orEmpty() else {
            detailString("ip") ?: throw invalidEthernetResponse("detail-ip")
        }
        val subnetMask = if (usesDhcp) detailString("mask").orEmpty() else {
            detailString("mask") ?: throw invalidEthernetResponse("detail-mask")
        }
        val gateway = if (usesDhcp) detailString("gateway").orEmpty() else {
            detailString("gateway") ?: throw invalidEthernetResponse("detail-gateway")
        }
        val dns = if (usesDhcp) detailString("dns").orEmpty() else {
            detailString("dns") ?: throw invalidEthernetResponse("detail-dns")
        }
        return NasEthernetInterface(
            id = id,
            displayName = displayString("title") ?: displayString("display") ?: id,
            status = displayString("status"),
            usesDhcp = usesDhcp,
            address = address,
            subnetMask = subnetMask,
            gateway = gateway,
            dnsServers = dns,
            isDefaultGateway = isDefaultGateway,
            mtu = mtu,
            isVlanEnabled = isVlanEnabled,
            vlanId = vlanId,
        )
    }

    private fun invalidEthernetResponse(scope: String) = DsmFailure(
        null,
        "Ethernet settings response is invalid",
        "Refresh the network settings and try again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    private fun JsonElement?.strictStringValue(): String? =
        (this as? JsonPrimitive)?.takeIf(JsonPrimitive::isString)?.contentOrNull

    private fun JsonObject.strictString(name: String): String? = this[name].strictStringValue()

    private fun JsonElement?.strictBooleanValue(allowString: Boolean = false): Boolean? {
        val primitive = this as? JsonPrimitive ?: return null
        if (!primitive.isString) primitive.booleanOrNull?.let { return it }
        if (!allowString) return null
        return when (primitive.contentOrNull?.lowercase(Locale.ROOT)) {
            "true", "1" -> true
            "false", "0" -> false
            else -> null
        }
    }

    private fun JsonElement?.strictIntValue(allowString: Boolean = false): Int? {
        val primitive = this as? JsonPrimitive ?: return null
        if (primitive.isString && !allowString) return null
        return primitive.contentOrNull?.toIntOrNull()
    }

    private fun state(value: String?): ResourceState {
        val normalized = value?.lowercase().orEmpty()
        return when {
            normalized in setOf("running", "started", "online", "active", "downloading", "seeding") ->
                ResourceState.RUNNING
            normalized in setOf("stopped", "shutdown", "offline", "inactive", "finished") ->
                ResourceState.STOPPED
            normalized in setOf("paused", "suspended") -> ResourceState.PAUSED
            normalized in setOf("waiting", "pending", "creating", "starting", "stopping") ->
                ResourceState.WAITING
            normalized in setOf("healthy", "normal", "good") -> ResourceState.HEALTHY
            normalized.contains("warn") || normalized.contains("degrad") -> ResourceState.WARNING
            normalized.contains("error") || normalized.contains("fail") || normalized.contains("critical") ->
                ResourceState.ERROR
            else -> ResourceState.UNKNOWN
        }
    }

    private fun logLevel(value: String?): LogLevel = when (value?.lowercase()) {
        "info", "information", "0" -> LogLevel.INFO
        "warning", "warn", "1" -> LogLevel.WARNING
        "error", "err", "2" -> LogLevel.ERROR
        else -> LogLevel.UNKNOWN
    }

    private fun supports(apiName: String): Boolean = capabilityResolver.supports(apiName)

    private fun preferred(vararg names: String): String = capabilityResolver.preferred(*names)

    private fun jsonStrings(values: List<String>): String = requestBuilder.jsonStrings(values)

    private fun join(parent: String, child: String): String = requestBuilder.join(parent, child)

    private companion object {
        const val FILE_STATION_FAVORITE_API = "SYNO.FileStation.Favorite"
        const val FAVORITE_PAGE_SIZE = 500
        const val FILE_STATION_UPLOAD_API = "SYNO.FileStation.Upload"
        const val FILE_STATION_CHECK_PERMISSION_API = "SYNO.FileStation.CheckPermission"
        const val FILE_STATION_THUMB_API = "SYNO.FileStation.Thumb"
        const val FILE_STATION_DOWNLOAD_API = "SYNO.FileStation.Download"
        const val FILE_STATION_CREATE_FOLDER_API = "SYNO.FileStation.CreateFolder"
        const val FILE_STATION_RENAME_API = "SYNO.FileStation.Rename"
        const val FILE_STATION_COPY_MOVE_API = "SYNO.FileStation.CopyMove"
        const val FILE_STATION_DELETE_API = "SYNO.FileStation.Delete"
        const val FILE_STATION_SHARING_API = "SYNO.FileStation.Sharing"
        const val FILE_STATION_COMPRESS_API = "SYNO.FileStation.Compress"
        const val FILE_STATION_EXTRACT_API = "SYNO.FileStation.Extract"
        const val MAXIMUM_DUPLICATE_CANDIDATES = 400
        const val MAX_DOWNLOAD_URI_CHARACTERS = 8_192
        const val MAX_DOWNLOAD_DESTINATION_CHARACTERS = 2_048
        const val CHAT_CHANNEL_MEMBER_API = "SYNO.Chat.Channel.Member"
        const val CHAT_POST_FILE_API = "SYNO.Chat.Post.File"
        const val CHAT_POST_REMINDER_API = "SYNO.Chat.Post.Reminder"
        const val CHAT_POST_SCHEDULE_API = "SYNO.Chat.Post.Schedule"
        const val CHAT_POST_VOTE_API = "SYNO.Chat.Post.Vote"
        const val MAX_CHAT_THUMBNAIL_BYTES = 8L * 1024 * 1024
        const val MAX_CHAT_VIDEO_PREVIEW_BYTES = 512L * 1024 * 1024
        const val MAX_CHAT_ATTACHMENT_DOWNLOAD_BYTES = 20L * 1024 * 1024 * 1024
        const val MAX_SEARCH_EMPTY_POLLS = 120
        val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "raw")
        val VIDEO_EXTENSIONS = setOf("mp4", "m4v", "mov", "avi", "mkv", "webm", "mpeg", "mpg", "ts", "m2ts")
        val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "aac", "flac", "wav", "ogg", "ape", "alac")
        val DOCUMENT_EXTENSIONS = setOf("pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "pages", "numbers", "key")
        val ARCHIVE_EXTENSIONS = setOf("zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso")
        const val MAX_COPY_MOVE_POLLS = 120
        const val COPY_MOVE_POLL_INTERVAL_MILLIS = 500L
        const val MAX_FILE_TASK_POLLS = 120
        const val FILE_TASK_POLL_INTERVAL_MILLIS = 500L
        internal const val PACKAGE_ICON_REQUESTED_SIZE = 128
        private const val MAX_PACKAGE_ICON_BYTES = 2L * 1024L * 1024L
        const val MAX_TEXT_PREVIEW_BYTES = 512L * 1024L
        const val MAX_IMAGE_PREVIEW_BYTES = 128L * 1024L * 1024L
        const val MAX_VIDEO_PREVIEW_BYTES = 256L * 1024L * 1024L
        const val MAX_AUDIO_PREVIEW_BYTES = 256L * 1024L * 1024L
        const val MAX_PDF_PREVIEW_BYTES = 128L * 1024L * 1024L
        const val MAX_MEDIA_RANGE_BYTES = 1024 * 1024
        const val MAX_DOWNLOAD_TASK_FILE_BYTES = 100L * 1024L * 1024L
        const val MAX_DOWNLOAD_LIMIT_KB = 1_000_000
        const val MAX_DOWNLOAD_BT_SEARCH_POLLS = 60
        const val DOWNLOAD_BT_SEARCH_POLL_INTERVAL_MILLIS = 500L
        const val MAX_VMM_CREATION_POLLS = 120
        const val MAX_VMM_TASK_CENTER_ITEMS = 100
        const val VMM_CREATION_READBACK_ATTEMPTS = 6
        const val VMM_CREATION_POLL_INTERVAL_MILLIS = 500L
        const val ETHERNET_API = "SYNO.Core.Network.Ethernet"
        const val DDNS_PROVIDER_API = "SYNO.Core.DDNS.Provider"
        const val DDNS_RECORD_API = "SYNO.Core.DDNS.Record"
        const val SECURITY_AUTO_BLOCK_API = "SYNO.Core.Security.AutoBlock"
        const val SECURITY_DOS_API = "SYNO.Core.Security.DoS"
        const val SECURITY_FIREWALL_API = "SYNO.Core.Security.Firewall"
        const val SECURITY_FIREWALL_CONF_API = "SYNO.Core.Security.Firewall.Conf"
        const val USER_API = "SYNO.Core.User"
        const val GROUP_API = "SYNO.Core.Group"
        const val DIRECTORY_API_VERSION = 1
        const val PACKAGE_API = "SYNO.Core.Package"
        const val PACKAGE_THUMB_API = "SYNO.Core.Package.Thumb"
        const val PACKAGE_READ_VERSION = 2
        const val PACKAGE_THUMB_VERSION = 1
        const val STORAGE_OVERVIEW_API = "SYNO.Storage.CGI.Storage"
        const val SMART_API_VERSION = 1
        const val STORAGE_DISK_API = "SYNO.Core.Storage.Disk"
        const val SYSTEM_API = "SYNO.Core.System"
        const val SYSTEM_UPDATE_API = "SYNO.Core.Upgrade.Server"
        const val PERFORMANCE_API = "SYNO.Core.System.Utilization"
        const val HARDWARE_POWER_RECOVERY_API = "SYNO.Core.Hardware.PowerRecovery"
        const val HARDWARE_LED_API = "SYNO.Core.Hardware.Led.Brightness"
        const val HARDWARE_FAN_API = "SYNO.Core.Hardware.FanSpeed"
        const val HARDWARE_BEEP_API = "SYNO.Core.Hardware.BeepControl"
        const val HARDWARE_HIBERNATION_API = "SYNO.Core.Hardware.Hibernation"
        const val HARDWARE_UPS_API = "SYNO.Core.ExternalDevice.UPS"
        val HARDWARE_APIS = setOf(
            HARDWARE_POWER_RECOVERY_API, HARDWARE_LED_API, HARDWARE_FAN_API,
            HARDWARE_BEEP_API, HARDWARE_HIBERNATION_API, HARDWARE_UPS_API,
        )
        val HARDWARE_BEEP_FIELDS = setOf(
            "fan_fail", "volume_or_cache_crash", "volume_crash",
            "poweron_beep", "poweroff_beep", "reset_beep",
        )
        val HARDWARE_HIBERNATION_FIELDS = setOf(
            "eunit_deep_sleep", "enable_log", "sata_deep_sleep",
            "ignore_netbios_broadcast", "auto_poweroff_enable",
        )
        val UPS_MODES = setOf("USB", "SNMP", "SLAVE")
        const val DOWNLOAD_MUTATION_READBACK_ATTEMPTS = 8
        const val DOWNLOAD_MUTATION_READBACK_INTERVAL_MILLIS = 500L
        const val DOWNLOAD_MUTATION_LIST_PAGE_SIZE = 1000
    }
}

private class RepositoryMediaSource(
    private val repository: DsmRepository,
    private val item: FileItem,
) : RandomAccessMediaSource {
    @Volatile
    private var closed = false
    override val size: Long = item.size

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, length: Int): Int {
        if (closed) throw java.io.IOException("The media source is closed")
        if (position < 0 || offset < 0 || length < 0 || offset + length > buffer.size) {
            throw IndexOutOfBoundsException("Invalid media read range")
        }
        if (length == 0) return 0
        if (position >= size) return -1
        val requested = minOf(length, 1024 * 1024)
        val bytes = kotlinx.coroutines.runBlocking(Dispatchers.IO) {
            repository.readMediaRange(item, position, requested)
        }
        if (bytes.isEmpty()) return -1
        bytes.copyInto(buffer, offset, 0, bytes.size)
        return bytes.size
    }

    override fun close() {
        closed = true
    }
}
