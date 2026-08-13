package io.github.qwertyuiop1995.dsmnativeclient.data

import io.github.qwertyuiop1995.dsmnativeclient.data.container.ContainerRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.container.ContainerRepositoryGateway
import io.github.qwertyuiop1995.dsmnativeclient.data.downloads.DownloadStationRepository
import io.github.qwertyuiop1995.dsmnativeclient.data.downloads.DownloadStationRepositoryGateway
import io.github.qwertyuiop1995.dsmnativeclient.domain.ActiveConnection
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveCompressionLevel
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveFormat
import io.github.qwertyuiop1995.dsmnativeclient.domain.ArchiveItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.CapacitySummary
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatConversation
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatMessagePage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatDeliveryState
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatUser
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatAttachment
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatReminder
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatScheduledMessage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatPoll
import io.github.qwertyuiop1995.dsmnativeclient.domain.ChatPollOption
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerOverview
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerSection
import io.github.qwertyuiop1995.dsmnativeclient.domain.ContainerRegistryImage
import io.github.qwertyuiop1995.dsmnativeclient.domain.ConversationKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationAction
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationBaseline
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskFile
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskPeer
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskTracker
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssSite
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssFeed
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchCatalog
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchModule
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchModuleScope
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchOptions
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadStationActivity
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmSession
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationExpectedOutput
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileServerMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskPage
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskState
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileBackgroundTaskSummary
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
import io.github.qwertyuiop1995.dsmnativeclient.domain.Module
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleAvailability
import io.github.qwertyuiop1995.dsmnativeclient.domain.ModuleUnavailableReason
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasAccount
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasGroup
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProfile
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSettingsSnapshot
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasEthernetInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDirectory
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsDraft
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsProvider
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDdnsRecord
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasFileServiceSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTerminalSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasProxySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRemoteAccessSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasManualDateTime
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasRegionSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasTimeZoneOption
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasDoSProtectionSetting
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasSecuritySettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.NasPowerAction
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
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageImportVerification
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineImageType
import io.github.qwertyuiop1995.dsmnativeclient.domain.isEligibleForVirtualMachineImageImport
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineSection
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineCreation
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineCreationDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.MAX_VIRTUAL_MACHINE_DISKS
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineDisk
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineDiskController
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineHardware
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineNetworkInterface
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineNetworkModel
import io.github.qwertyuiop1995.dsmnativeclient.domain.VirtualMachineSettings
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
import java.util.GregorianCalendar
import java.io.ByteArrayInputStream
import java.io.File
import java.io.OutputStream
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI
import java.security.MessageDigest
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonObject
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
private fun FileItem.matchesMutationBaseline(baseline: FileItem): Boolean =
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

data class ChatTextMutationOutcome(
    val result: MutationResult,
    val message: ChatMessage? = null,
)

data class ChatAttachmentMutationOutcome(
    val result: MutationResult,
    val message: ChatMessage? = null,
)

data class ChatReminderMutationOutcome(
    val result: MutationResult,
    val reminder: ChatReminder? = null,
    val reminders: List<ChatReminder>? = null,
)

data class ChatScheduleMutationOutcome(
    val result: MutationResult,
    val scheduledMessage: ChatScheduledMessage? = null,
    val scheduledMessages: List<ChatScheduledMessage>? = null,
)

data class ChatPollMutationOutcome(
    val result: MutationResult,
    val message: ChatMessage? = null,
)

data class ChatConversationMutationOutcome(
    val result: MutationResult,
    val conversation: ChatConversation? = null,
    val conversations: List<ChatConversation>? = null,
)

class DsmRepository(
    private val profile: NasProfile,
    private val session: DsmSession,
    private val api: DsmApiClient,
    private val capabilities: Map<String, ApiCapability>,
) {
    fun chatRealtimeClient(
        onConnectionChanged: (Boolean) -> Unit,
        onContentChanged: () -> Unit,
    ): ChatRealtimeClient = ChatRealtimeClient(
        api,
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
    private val chatSendLock = Mutex()
    private val activeChatSendRequestIds = mutableSetOf<String>()
    private val completedChatMessages = mutableMapOf<String, ChatMessage>()
    private val chatConversationMutationLock = Mutex()
    private val activeChatConversationRequestIds = mutableSetOf<String>()
    private val activeChatConversationTargets = mutableSetOf<String>()
    private val chatReminderMutationLock = Mutex()
    private val activeChatReminderRequestIds = mutableSetOf<String>()
    private val activeChatReminderTargets = mutableSetOf<String>()
    private val completedChatReminders = mutableMapOf<String, ChatReminder>()
    private val completedChatReminderDeletions = mutableSetOf<String>()
    private val chatScheduleMutationLock = Mutex()
    private val activeChatScheduleRequestIds = mutableSetOf<String>()
    private val activeChatScheduleTargets = mutableSetOf<String>()
    private val completedChatScheduledMessages = mutableMapOf<String, ChatScheduledMessage>()
    private val completedChatScheduledMessageDeletions = mutableSetOf<String>()
    private val chatPollMutationLock = Mutex()
    private val activeChatPollRequestIds = mutableSetOf<String>()
    private val activeChatPollTargets = mutableSetOf<String>()
    private val completedChatPolls = mutableMapOf<String, ChatMessage>()
    private val completedDirectConversations = mutableMapOf<String, ChatConversation>()
    private val completedGroupConversations = mutableMapOf<String, ChatConversation>()
    private val pendingChatGroupChannelIds = mutableMapOf<String, String>()
    @Volatile private var currentChatUserId: String? = null

    private val containerRepository = ContainerRepository(object : ContainerRepositoryGateway {
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

    fun availability(): List<ModuleAvailability> = listOf(
        ModuleAvailability(Module.FILES, supports("SYNO.FileStation.List")),
        ModuleAvailability(Module.PHOTOS, supports("SYNO.FileStation.List")),
        ModuleAvailability(
            Module.CHAT,
            supports("SYNO.Chat.Channel"),
            ModuleUnavailableReason.CHAT_SERVICE,
        ),
        ModuleAvailability(
            Module.DOWNLOADS,
            supports("SYNO.DownloadStation.Task") || supports("SYNO.DownloadStation2.Task"),
            ModuleUnavailableReason.DOWNLOAD_STATION,
        ),
        ModuleAvailability(
            Module.CONTAINERS,
            supports("SYNO.Docker.Container"),
            ModuleUnavailableReason.CONTAINER_MANAGER,
        ),
        ModuleAvailability(
            Module.VIRTUAL_MACHINES,
            supports("SYNO.Virtualization.Guest") || supports("SYNO.Virtualization.API.Guest"),
            ModuleUnavailableReason.VIRTUAL_MACHINE_MANAGER,
        ),
        ModuleAvailability(Module.NAS_SETTINGS, supports("SYNO.Core.System")),
        ModuleAvailability(Module.TRANSFERS, true),
        ModuleAvailability(Module.SETTINGS, true),
    )

    suspend fun listShares(
        offset: Int = 0,
        limit: Int = 200,
        sortBy: String = "name",
        sortAscending: Boolean = true,
    ): FilePage {
        val data = call(
            "SYNO.FileStation.List",
            "list_share",
            mapOf(
                "offset" to offset.toString(),
                "limit" to limit.toString(),
                "sort_by" to sortBy,
                "sort_direction" to if (sortAscending) "asc" else "desc",
                "additional" to "[\"real_path\",\"owner\",\"time\",\"perm\",\"mount_point_type\",\"volume_status\"]",
            ),
        )
        return filePage(data, "shares")
    }

    suspend fun listDirectory(
        path: String,
        offset: Int = 0,
        limit: Int = 200,
        sortBy: String = "name",
        sortAscending: Boolean = true,
        fileType: String = "all",
    ): FilePage {
        val data = call(
            "SYNO.FileStation.List",
            "list",
            mapOf(
                "folder_path" to path,
                "offset" to offset.toString(),
                "limit" to limit.toString(),
                "sort_by" to sortBy,
                "sort_direction" to if (sortAscending) "asc" else "desc",
                "filetype" to fileType,
                "additional" to "[\"real_path\",\"size\",\"owner\",\"time\",\"perm\",\"mount_point_type\"]",
            ),
        )
        return filePage(data, "files")
    }

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

    suspend fun fileInfo(path: String): FileItem? {
        val data = call(
            "SYNO.FileStation.List",
            "getinfo",
            mapOf(
                "path" to jsonStrings(listOf(path)),
                "additional" to "[\"real_path\",\"size\",\"owner\",\"time\",\"perm\",\"mount_point_type\"]",
            ),
        )
        return filePage(data, "files").items.firstOrNull { it.path == path }
    }

    /**
     * 读取 File Station 官方后台任务的有限分页脱敏摘要。
     *
     * 官方响应中的 `params`、`path`、`processing_path` 和消息字段不在白名单中，解析时
     * 直接丢弃。`finished=true` 只映射为任务已结束，不推断成功。
     */
    suspend fun listFileBackgroundTasks(
        offset: Int = 0,
        limit: Int = 100,
    ): FileBackgroundTaskPage {
        val requestedOffset = offset.coerceAtLeast(0)
        // 官方的 limit=0 会返回全部任务；客户端始终使用有限分页。
        val requestedLimit = limit.coerceIn(1, MAX_FILE_BACKGROUND_TASK_PAGE_SIZE)
        val data = call(
            FILE_STATION_BACKGROUND_TASK_API,
            "list",
            mapOf(
                "offset" to requestedOffset.toString(),
                "limit" to requestedLimit.toString(),
                "sort_by" to "crtime",
                "sort_direction" to "desc",
                "api_filter" to jsonStrings(FILE_BACKGROUND_TASK_APIS),
            ),
            version = 3,
        )
        val rawTasks = (data["tasks"] as? JsonArray)?.take(requestedLimit).orEmpty()
        val seenIds = mutableSetOf<String>()
        val tasks = rawTasks.mapNotNull { element ->
            val summary = (element as? JsonObject)?.let(::fileBackgroundTaskSummary)
                ?: return@mapNotNull null
            summary.takeIf { seenIds.add(it.id) }
        }
        val resolvedOffset = (data.long("offset") ?: requestedOffset.toLong())
            .coerceIn(0, Int.MAX_VALUE.toLong())
            .toInt()
        val nextOffset = (resolvedOffset.toLong() + rawTasks.size)
            .coerceAtMost(Int.MAX_VALUE.toLong())
            .toInt()
        val reportedTotal = (data.long("total") ?: nextOffset.toLong())
            .coerceIn(0, Int.MAX_VALUE.toLong())
            .toInt()
        val total = maxOf(nextOffset, reportedTotal)
        return FileBackgroundTaskPage(
            tasks = tasks,
            offset = resolvedOffset,
            nextOffset = nextOffset,
            total = total,
            hasMore = rawTasks.isNotEmpty() && nextOffset < total,
        )
    }

    private fun fileBackgroundTaskSummary(payload: JsonObject): FileBackgroundTaskSummary? {
        val id = normalizedFileBackgroundTaskId(payload.string("taskid")) ?: return null
        val kind = when (payload.string("api")) {
            FILE_STATION_COPY_MOVE_API -> FileBackgroundTaskKind.COPY_OR_MOVE
            FILE_STATION_DELETE_API -> FileBackgroundTaskKind.DELETE
            FILE_STATION_COMPRESS_API -> FileBackgroundTaskKind.COMPRESS
            FILE_STATION_EXTRACT_API -> FileBackgroundTaskKind.EXTRACT
            else -> return null
        }
        val state = when (payload.bool("finished")) {
            true -> FileBackgroundTaskState.FINISHED
            false -> FileBackgroundTaskState.ACTIVE
            null -> return null
        }
        val progress = payload.number("progress")?.takeIf { it > 0.0 && it <= 1.0 }
        val nowEpochSeconds = System.currentTimeMillis() / 1_000
        val createdAt = payload.number("crtime")
            ?.takeIf { it >= MIN_FILE_BACKGROUND_TASK_EPOCH_SECONDS && it <= nowEpochSeconds + 86_400 }
            ?.toLong()
        val processedItems = payload.long("processed_num")
            ?.takeIf { it in 0..Int.MAX_VALUE.toLong() }
            ?.toInt()
        val processedBytes = payload.long("processed_size")?.takeIf { it >= 0 }
        val total = payload.long("total")?.takeIf { it >= 0 }
        return FileBackgroundTaskSummary(
            id = id,
            kind = kind,
            state = state,
            progress = progress,
            createdAtEpochSeconds = createdAt,
            processedItemCount = processedItems,
            totalItemCount = if (kind == FileBackgroundTaskKind.DELETE) {
                total?.takeIf { it <= Int.MAX_VALUE }?.toInt()
            } else {
                null
            },
            processedBytes = processedBytes,
            totalBytes = if (kind == FileBackgroundTaskKind.COPY_OR_MOVE) total else null,
        )
    }

    private fun normalizedFileBackgroundTaskId(value: String?): String? {
        val normalized = value?.trim()?.takeIf(String::isNotEmpty) ?: return null
        if (normalized.encodeToByteArray().size > MAX_FILE_BACKGROUND_TASK_ID_BYTES) return null
        return normalized.takeIf { id ->
            id.all { character -> character.isLetterOrDigit() || character in "._-:" }
        }
    }

    suspend fun search(path: String, keyword: String): FilePage {
        val start = call(
            "SYNO.FileStation.Search",
            "start",
            mapOf(
                "folder_path" to path,
                "pattern" to keyword,
                "recursive" to "true",
            ),
        )
        val taskId = start.string("taskid")
            ?: throw DsmFailure(
                null,
                "The NAS did not start the search",
                "Try again later.",
                kind = DsmErrorKind.SEARCH_NOT_STARTED,
            )
        return try {
            val result = call(
                "SYNO.FileStation.Search",
                "list",
                mapOf(
                    "taskid" to taskId,
                    "offset" to "0",
                    "limit" to "1000",
                    "additional" to "[\"size\",\"owner\",\"time\",\"perm\"]",
                ),
            )
            filePage(result, "files")
        } finally {
            runCatching {
                call("SYNO.FileStation.Search", "stop", mapOf("taskid" to taskId))
            }
        }
    }

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
                val page = filePage(data, "files")
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
        supports(FILE_STATION_DOWNLOAD_API) && (!moveSource || supports(FILE_STATION_DELETE_API))

    internal fun supportsCrossNasTarget(includesDirectory: Boolean): Boolean =
        supportsUploads() && (!includesDirectory || supports(FILE_STATION_CREATE_FOLDER_API))

    fun supportsSharing(): Boolean = supports(FILE_STATION_SHARING_API)

    fun supportsCompression(): Boolean =
        capabilities[FILE_STATION_COMPRESS_API]?.maxVersion?.let { it >= 3 } == true

    fun supportsExtraction(): Boolean =
        capabilities[FILE_STATION_EXTRACT_API]?.maxVersion?.let { it >= 2 } == true

    fun supportsRemoteLocations(): Boolean = supports(FILE_STATION_VIRTUAL_FOLDER_API)

    suspend fun listRemoteLocations(offset: Int = 0, limit: Int = 200): FilePage {
        require(offset >= 0 && limit in 1..500)
        val data = call(
            FILE_STATION_VIRTUAL_FOLDER_API,
            "list",
            mapOf(
                "type" to "all",
                "offset" to offset.toString(),
                "limit" to limit.toString(),
                "sort_by" to "name",
                "sort_direction" to "asc",
                "additional" to "[\"real_path\",\"size\",\"owner\",\"time\",\"perm\"]",
            ),
        )
        return filePage(data, if (data["folders"] is JsonArray) "folders" else "files")
    }

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

    suspend fun thumbnail(path: String): ByteArray {
        val capability = requireCapability(FILE_STATION_THUMB_API)
        return api.readBinary(
            profile = profile,
            session = session,
            capability = capability,
            preferredVersion = 2,
            method = "get",
            parameters = mapOf("path" to path, "size" to "small", "rotate" to "0"),
            maximumBytes = MAX_THUMBNAIL_BYTES,
        )
    }

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
        val bytes = api.readBinary(
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
        val bytes = api.readBinary(
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
        api.downloadBinaryToFile(
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
        return api.readBinary(
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

    suspend fun download(
        item: FileItem,
        output: OutputStream,
        resumeFrom: Long = 0,
        onProgress: (Long, Long?) -> Unit = { _, _ -> },
    ): Long {
        if (!item.canRead) {
            throw DsmFailure(
                null,
                "This item cannot be downloaded with the current account",
                "Ask an administrator for read access and try again.",
                kind = DsmErrorKind.PERMISSION_DENIED,
            )
        }
        require(resumeFrom >= 0 && (!item.isDirectory || resumeFrom == 0L))
        val expected = item.size.takeIf { !item.isDirectory && it > 0 }
        require(resumeFrom == 0L || expected != null && resumeFrom < expected) {
            "The saved download position is invalid"
        }
        return api.downloadBinaryToOutput(
            profile = profile,
            session = session,
            capability = requireCapability(FILE_STATION_DOWNLOAD_API),
            preferredVersion = 2,
            method = "download",
            parameters = mapOf("path" to jsonStrings(listOf(item.path)), "mode" to "download"),
            output = output,
            expectedBytes = expected,
            range = expected?.takeIf { resumeFrom > 0 }?.let { resumeFrom..(it - 1) },
            initialBytes = resumeFrom,
            onProgress = onProgress,
        )
    }

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

    suspend fun listShareLinks(): List<FileShareLink> {
        val result = mutableListOf<FileShareLink>()
        var offset = 0
        do {
            val data = call(
                FILE_STATION_SHARING_API,
                "list",
                mapOf("offset" to offset.toString(), "limit" to SHARING_PAGE_SIZE.toString()),
            )
            val page = data.elements("links").mapNotNull(::shareLink)
            result += page
            offset += page.size
            val total = data.int("total") ?: offset
        } while (page.size == SHARING_PAGE_SIZE && offset < total)
        return result
    }

    internal suspend fun createShareLink(path: String): FileShareLink {
        val outcome = createShareLinkResult(path)
        requireConfirmedFileEntryMutation(outcome.result)
        return outcome.link ?: throw DsmFailure(
            null,
            "The share link could not be confirmed",
            "Refresh the shared links in DSM before trying again.",
            kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
        )
    }

    internal suspend fun createShareLinkResult(path: String): ShareLinkMutationOutcome =
        createShareLinkResult(path, itemBaseline = null)

    suspend fun createShareLinkResult(itemBaseline: FileItem): ShareLinkMutationOutcome =
        createShareLinkResult(itemBaseline.path, itemBaseline)

    private suspend fun createShareLinkResult(
        path: String,
        itemBaseline: FileItem?,
    ): ShareLinkMutationOutcome {
        val operation = "shareLinkCreate"
        if (!currentCoroutineContext().isActive) {
            return ShareLinkMutationOutcome(
                shareLinkMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "file-station.share-link.cancelled-before-submission",
                ),
            )
        }
        val normalized = path.trim().trimEnd('/')
        if (!normalized.startsWith('/') || normalized == "/") {
            return ShareLinkMutationOutcome(
                shareLinkMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.VALIDATION,
                    diagnosticTag = "file-station.share-link.invalid-input",
                ),
            )
        }
        if (!supports(FILE_STATION_SHARING_API)) {
            return ShareLinkMutationOutcome(
                shareLinkMutationResult(
                    operation,
                    MutationResultStatus.UNSUPPORTED,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.UNSUPPORTED,
                    diagnosticTag = "file-station.share-link.unsupported",
                ),
            )
        }
        val affectedPaths = setOf(normalized)
        if (!claimFilePathMutation(affectedPaths)) {
            return ShareLinkMutationOutcome(
                shareLinkMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.share-link.duplicate-submission",
                ),
            )
        }
        return try {
            if (itemBaseline != null) {
                val observed = try {
                    fileInfo(normalized)
                } catch (_: CancellationException) {
                    return ShareLinkMutationOutcome(
                        shareLinkMutationResult(
                            operation,
                            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                            submitted = false,
                            diagnosticTag = "file-station.share-link.cancelled-during-preflight",
                        ),
                    )
                } catch (failure: DsmFailure) {
                    return ShareLinkMutationOutcome(
                        shareLinkMutationResult(
                            operation,
                            if (failure.kind == DsmErrorKind.PERMISSION_DENIED) {
                                MutationResultStatus.PERMISSION_DENIED
                            } else {
                                MutationResultStatus.CONFIRMED_FAILURE
                            },
                            submitted = false,
                            failed = 1,
                            errorCategory = fileMutationErrorCategory(failure),
                            diagnosticTag = "file-station.share-link.preflight-failed",
                        ),
                    )
                }
                if (observed == null || !observed.matchesMutationBaseline(itemBaseline)) {
                    return ShareLinkMutationOutcome(
                        shareLinkMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_FAILURE,
                            submitted = false,
                            failed = 1,
                            errorCategory = MutationErrorCategory.CONFLICT,
                            diagnosticTag = "file-station.share-link.baseline-changed",
                        ),
                    )
                }
                if (!observed.canRead) {
                    return ShareLinkMutationOutcome(
                        shareLinkMutationResult(
                            operation,
                            MutationResultStatus.PERMISSION_DENIED,
                            submitted = false,
                            failed = 1,
                            errorCategory = MutationErrorCategory.PERMISSION,
                            diagnosticTag = "file-station.share-link.source-unreadable",
                        ),
                    )
                }
            }
            val existingLinkIds = if (itemBaseline != null) {
                try {
                    listShareLinks().mapTo(mutableSetOf(), FileShareLink::id)
                } catch (_: CancellationException) {
                    return ShareLinkMutationOutcome(
                        shareLinkMutationResult(
                            operation,
                            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                            submitted = false,
                            diagnosticTag = "file-station.share-link.cancelled-during-link-preflight",
                        ),
                    )
                } catch (failure: DsmFailure) {
                    return ShareLinkMutationOutcome(
                        shareLinkMutationResult(
                            operation,
                            if (failure.kind == DsmErrorKind.PERMISSION_DENIED) {
                                MutationResultStatus.PERMISSION_DENIED
                            } else {
                                MutationResultStatus.CONFIRMED_FAILURE
                            },
                            submitted = false,
                            failed = 1,
                            errorCategory = fileMutationErrorCategory(failure),
                            diagnosticTag = "file-station.share-link.link-preflight-failed",
                        ),
                    )
                }
            } else {
                emptySet()
            }
            val data = try {
                call(
                    FILE_STATION_SHARING_API,
                    "create",
                    mapOf("path" to jsonStrings(listOf(normalized))),
                )
            } catch (_: CancellationException) {
                return ShareLinkMutationOutcome(
                    shareLinkMutationResult(
                        operation,
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        diagnosticTag = "file-station.share-link.cancelled-after-submission",
                    ),
                )
            } catch (failure: DsmFailure) {
                return ShareLinkMutationOutcome(shareLinkSubmissionFailure(operation, failure))
            } catch (_: Throwable) {
                return ShareLinkMutationOutcome(
                    shareLinkMutationResult(
                        operation,
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        errorCategory = MutationErrorCategory.UNKNOWN,
                        diagnosticTag = "file-station.share-link.submission-unknown",
                    ),
                )
            }
            val submittedLink = data.elements("links").firstOrNull()?.let(::shareLink)
                ?: shareLink(data)
            try {
                val confirmed = listShareLinks().firstOrNull { link ->
                    link.path == normalized && if (submittedLink == null) {
                        link.id !in existingLinkIds
                    } else {
                        link.id == submittedLink.id || link.url == submittedLink.url
                    }
                }
                if (confirmed != null) {
                    ShareLinkMutationOutcome(
                        shareLinkMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_SUCCESS,
                            submitted = true,
                            succeeded = 1,
                            diagnosticTag = "file-station.share-link.confirmed-success",
                        ),
                        confirmed,
                    )
                } else {
                    ShareLinkMutationOutcome(
                        shareLinkMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_FAILURE,
                            submitted = true,
                            requiresRefresh = true,
                            failed = 1,
                            errorCategory = MutationErrorCategory.SERVER,
                            diagnosticTag = "file-station.share-link.readback-mismatch",
                        ),
                    )
                }
            } catch (_: CancellationException) {
                ShareLinkMutationOutcome(
                    shareLinkMutationResult(
                        operation,
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        diagnosticTag = "file-station.share-link.cancelled-during-readback",
                    ),
                )
            } catch (failure: DsmFailure) {
                ShareLinkMutationOutcome(
                    shareLinkMutationResult(
                        operation,
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        errorCategory = fileMutationErrorCategory(failure),
                        diagnosticTag = "file-station.share-link.readback-unverified",
                    ),
                )
            }
        } finally {
            releaseFilePathMutation(affectedPaths)
        }
    }

    private fun shareLinkSubmissionFailure(operation: String, failure: DsmFailure): MutationResult =
        if (failure.kind == DsmErrorKind.PERMISSION_DENIED) {
            shareLinkMutationResult(
                operation,
                MutationResultStatus.PERMISSION_DENIED,
                submitted = true,
                failed = 1,
                errorCategory = MutationErrorCategory.PERMISSION,
                diagnosticTag = "file-station.share-link.permission-denied",
            )
        } else {
            shareLinkMutationResult(
                operation,
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                submitted = true,
                requiresRefresh = true,
                unknown = 1,
                errorCategory = fileMutationErrorCategory(failure),
                diagnosticTag = "file-station.share-link.submission-unverified",
            )
        }

    private fun shareLinkMutationResult(
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
        localizationKey = "mutation.sharelinkcreate.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

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
            link.path.trim().trimEnd('/').takeIf { it.startsWith('/') && it != "/" }
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

    private suspend fun uploadResultInternal(
        source: UploadSource,
        destinationPath: String,
        overwrite: Boolean,
        onProgress: (Long, Long) -> Unit,
        targetBaseline: FileItem?,
    ): MutationResult {
        val destination = destinationPath.trim().trimEnd('/')
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
            val capability = checkNotNull(capabilities[FILE_STATION_UPLOAD_API])
            try {
                api.upload(
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
                )
            } catch (_: CancellationException) {
                val confirmed = withContext(NonCancellable) {
                    runCatching { uploadMatches(target, source.contentLength) }.getOrDefault(false)
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
                    uploadMatches(target, source.contentLength)
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

    internal suspend fun createFolder(parent: String, name: String) {
        requireConfirmedFileEntryMutation(createFolderResult(parent, name))
    }

    internal suspend fun createFolderResult(parent: String, name: String): MutationResult =
        createFolderResult(parent, name, parentBaseline = null)

    suspend fun createFolderResult(parentBaseline: FileItem, name: String): MutationResult =
        createFolderResult(parentBaseline.path, name, parentBaseline)

    private suspend fun createFolderResult(
        parent: String,
        name: String,
        parentBaseline: FileItem?,
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
        val normalizedParent = parent.trim().trimEnd('/').ifEmpty { "/" }
        val normalizedName = name.trim()
        val invalid = !normalizedParent.startsWith('/') ||
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
        require(root.startsWith('/') && target.startsWith('/'))
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

            val level = createFolderResult(current, component)
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
        val source = path.trim().trimEnd('/')
        val normalizedName = newName.trim()
        val parent = source.substringBeforeLast('/', "").ifEmpty { "/" }
        val target = join(parent, normalizedName)
        val invalid = !source.startsWith('/') ||
            source == "/" ||
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

    suspend fun deleteResult(itemBaseline: FileItem): MutationResult =
        deleteResult(
            paths = listOf(itemBaseline.path),
            itemBaselines = mapOf(itemBaseline.path to itemBaseline),
            requiresItemBaselines = true,
        )

    private suspend fun deleteResult(
        paths: List<String>,
        itemBaselines: Map<String, FileItem>?,
        requiresItemBaselines: Boolean = false,
    ): MutationResult {
        val operation = "fileDelete"
        if (!currentCoroutineContext().isActive) {
            return deleteMutationResult(
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "file-station.delete.cancelled-before-submission",
            )
        }
        val normalized = paths.map(String::trim).distinct().sorted()
        if (normalized.isEmpty() || normalized.any { !it.startsWith('/') || it == "/" }) {
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
                        "recursive" to "true",
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
        val normalized = paths.map(String::trim).distinct().sorted()
        val destination = destinationFolder.trim().trimEnd('/').ifEmpty { "/" }
        val invalid = normalized.isEmpty() ||
            normalized.any { !it.startsWith('/') || it == "/" } ||
            !destination.startsWith('/') ||
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
        val normalizedPaths = paths.map(String::trim).filter(String::isNotEmpty).distinct()
        val target = destinationFilePath.trim()
        val parent = target.substringBeforeLast('/', "")
        val sourceBaselinesByPath = sourceBaselines?.associateBy(FileItem::path)
        val valid = normalizedPaths.isNotEmpty() &&
            normalizedPaths.size == paths.size &&
            normalizedPaths.none { it == target } &&
            target.startsWith('/') &&
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
                        password?.takeIf(String::isNotBlank)?.let { put("password", it) }
                    },
                )
            }
        } finally {
            releaseFilePathMutation(affectedPaths)
        }
    }

    suspend fun listArchiveItems(
        filePath: String,
        codepage: String? = null,
        password: String? = null,
    ): List<ArchiveItem> {
        require(capabilities[FILE_STATION_EXTRACT_API]?.maxVersion?.let { it >= 2 } == true) {
            "Archive extraction requires File Station Extract version 2"
        }
        val data = call(
            FILE_STATION_EXTRACT_API,
            "list",
            buildMap {
                put("file_path", filePath)
                put("offset", "0")
                put("limit", MAX_ARCHIVE_ITEMS.toString())
                put("sort_by", "name")
                put("sort_direction", "asc")
                put("item_id", "-1")
                codepage?.takeIf(String::isNotBlank)?.let { put("codepage", it) }
                password?.takeIf(String::isNotBlank)?.let { put("password", it) }
            },
        )
        val items = data.elements("items").mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            ArchiveItem(
                id = item.int("itemid") ?: return@mapNotNull null,
                name = item.string("name") ?: return@mapNotNull null,
                path = item.string("path").orEmpty(),
                isDirectory = item.bool("is_dir") ?: false,
            )
        }
        require(items.size < MAX_ARCHIVE_ITEMS) { "The archive has too many top-level items" }
        return items
    }

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
        filePath: String,
        destinationFolder: String,
        sourceBaseline: FileItem?,
        destinationBaseline: FileItem?,
        password: String?,
        codepage: String?,
        onProgress: (Long, Long?) -> Unit,
        onExpectedOutputs: (List<FileServerMutationExpectedOutput>) -> Unit,
        onBeforeSubmit: () -> Unit,
        onTaskStarted: (String) -> Unit,
    ): MutationResult {
        val sourcePath = filePath.trim()
        val destinationPath = destinationFolder.trim()
        if (
            sourcePath.isBlank() || destinationPath.isBlank() ||
            !sourcePath.startsWith('/') || !destinationPath.startsWith('/') ||
            sourcePath == destinationPath ||
            (sourceBaseline != null &&
                (sourceBaseline.path != sourcePath || sourceBaseline.isDirectory)) ||
            (destinationBaseline != null &&
                (destinationBaseline.path != destinationPath || !destinationBaseline.isDirectory))
        ) {
            return archiveMutationResult(
                operation = "archiveExtract",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "file-station.archive-extract.invalid-input",
            )
        }
        if (capabilities[FILE_STATION_EXTRACT_API]?.maxVersion?.let { it >= 2 } != true) {
            return archiveMutationResult(
                operation = "archiveExtract",
                status = MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "file-station.archive-extract.unsupported",
            )
        }
        // 目标目录路径锁会覆盖其所有子路径，必须在归档预读前取得，消除 list/start 间的替换窗口。
        val affectedPaths = setOf(sourcePath, destinationPath)
        if (!claimFilePathMutation(affectedPaths)) {
            return archiveMutationResult(
                operation = "archiveExtract",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "file-station.archive-extract.duplicate-submission",
            )
        }
        try {
            val destination = try {
                fileInfo(destinationPath)
            } catch (_: CancellationException) {
                return archiveCancelledBeforeSubmission("archiveExtract", "archive-extract")
            } catch (failure: DsmFailure) {
                return archivePreflightFailure("archiveExtract", "archive-extract", failure)
            }
            if (destination == null || !destination.isDirectory) {
                return archiveMutationResult(
                    operation = "archiveExtract",
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.archive-extract.destination-missing",
                )
            }
            if (destinationBaseline != null &&
                !destination.matchesMutationBaseline(destinationBaseline)
            ) {
                return archiveMutationResult(
                    operation = "archiveExtract",
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.archive-extract.destination-baseline-drift",
                )
            }
            if (!destination.canWrite) {
                return archiveMutationResult(
                    operation = "archiveExtract",
                    status = MutationResultStatus.PERMISSION_DENIED,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.PERMISSION,
                    diagnosticTag = "file-station.archive-extract.destination-read-only",
                )
            }
            if (sourceBaseline != null) {
                val observedSource = try {
                    fileInfo(sourcePath)
                } catch (_: CancellationException) {
                    return archiveCancelledBeforeSubmission("archiveExtract", "archive-extract")
                } catch (failure: DsmFailure) {
                    return archivePreflightFailure("archiveExtract", "archive-extract", failure)
                }
                if (observedSource == null ||
                    !observedSource.matchesMutationBaseline(sourceBaseline)
                ) {
                    return archiveMutationResult(
                        operation = "archiveExtract",
                        status = MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "file-station.archive-extract.source-baseline-drift",
                    )
                }
            }
            val archiveItems = try {
                listArchiveItems(sourcePath, codepage, password)
            } catch (_: CancellationException) {
                return archiveCancelledBeforeSubmission("archiveExtract", "archive-extract")
            } catch (failure: DsmFailure) {
                return archivePreflightFailure("archiveExtract", "archive-extract", failure)
            }
            val topLevelItems = archiveItems.distinctBy(ArchiveItem::name)
            if (topLevelItems.isEmpty()) {
                return archiveMutationResult(
                    operation = "archiveExtract",
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.VALIDATION,
                    diagnosticTag = "file-station.archive-extract.empty-archive",
                )
            }
            val expectedOutputs = topLevelItems.map { item ->
                ArchiveExpectedOutput(
                    path = join(destinationPath, item.name),
                    isDirectory = item.isDirectory,
                )
            }
            onExpectedOutputs(
                expectedOutputs.map { FileServerMutationExpectedOutput(it.path, it.isDirectory) },
            )
            val existing = try {
                archiveExistingOutputCount(expectedOutputs)
            } catch (_: CancellationException) {
                return archiveCancelledBeforeSubmission("archiveExtract", "archive-extract")
            } catch (failure: DsmFailure) {
                return archivePreflightFailure("archiveExtract", "archive-extract", failure)
            }
            if (existing > 0) {
                return archiveMutationResult(
                    operation = "archiveExtract",
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = expectedOutputs.size,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-station.archive-extract.target-exists",
                )
            }
            return runArchiveMutationTask(
                operation = "archiveExtract",
                diagnosticOperation = "archive-extract",
                apiName = FILE_STATION_EXTRACT_API,
                expectedOutputs = expectedOutputs,
                onProgress = onProgress,
                onBeforeSubmit = onBeforeSubmit,
                onTaskStarted = onTaskStarted,
            ) {
                call(
                    FILE_STATION_EXTRACT_API,
                    "start",
                    buildMap {
                        put("file_path", sourcePath)
                        put("dest_folder_path", destinationPath)
                        put("overwrite", "false")
                        put("keep_dir", "true")
                        put("create_subfolder", "false")
                        codepage?.takeIf(String::isNotBlank)?.let { put("codepage", it) }
                        password?.takeIf(String::isNotBlank)?.let { put("password", it) }
                    },
                )
            }
        } finally {
            releaseFilePathMutation(affectedPaths)
        }
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
            ArchiveExpectedOutput(it.path, it.isDirectory, it.requiresNonEmptyFile)
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
                    val confirmed = archiveReadbackCount(outputs, DOWNLOAD_MUTATION_READBACK_ATTEMPTS)
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
    )

    private suspend fun archiveExistingOutputCount(expectedOutputs: List<ArchiveExpectedOutput>): Int =
        expectedOutputs.count { fileInfo(it.path) != null }

    private suspend fun archiveReadbackCount(
        expectedOutputs: List<ArchiveExpectedOutput>,
        attempts: Int = 1,
    ): Int {
        var confirmed = 0
        repeat(attempts.coerceAtLeast(1)) { attempt ->
            confirmed = expectedOutputs.count { expected ->
                val observed = fileInfo(expected.path)
                observed != null && observed.isDirectory == expected.isDirectory &&
                    (!expected.requiresNonEmptyFile || observed.size > 0)
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
            ): JsonObject = this@DsmRepository.call(apiName, method, parameters, version)

            override suspend fun fileInfo(path: String): FileItem? = this@DsmRepository.fileInfo(path)

            override suspend fun uploadDownloadTaskFile(
                capability: ApiCapability,
                filename: String,
                contentType: String?,
                contentLength: Long,
                destination: String?,
                unzipPassword: String?,
                openInputStream: () -> java.io.InputStream,
            ): JsonObject = api.uploadDownloadTaskFile(
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

    suspend fun refreshDownloadRssSiteResult(siteId: String): MutationResult =
        downloadStationRepository.refreshRssSiteResult(siteId)

    suspend fun searchDownloadBt(keyword: String): List<DownloadBtSearchResult> =
        downloadStationRepository.searchBt(keyword)

    suspend fun searchDownloadBt(options: DownloadBtSearchOptions): List<DownloadBtSearchResult> =
        downloadStationRepository.searchBt(options)

    suspend fun createDownload(uri: String, destination: String?) {
        downloadStationRepository.create(uri, destination)
    }

    suspend fun createDownloadResult(uri: String, destination: String?): MutationResult =
        downloadStationRepository.createResult(uri, destination)

    suspend fun createDownloadFromFile(
        source: UploadSource,
        destination: String? = null,
        unzipPassword: String? = null,
    ) {
        downloadStationRepository.createFromFile(source, destination, unzipPassword)
    }

    suspend fun createDownloadFromFileResult(
        source: UploadSource,
        destination: String? = null,
        unzipPassword: String? = null,
    ): MutationResult = downloadStationRepository.createFromFileResult(source, destination, unzipPassword)

    fun supportsDownloadSettings(): Boolean = downloadStationRepository.supportsSettings()

    fun supportsDownloadSchedule(): Boolean = downloadStationRepository.supportsSchedule()

    fun supportsDownloadTaskDestinationEditing(): Boolean =
        downloadStationRepository.supportsTaskDestinationEditing()

    fun supportsChatReminders(): Boolean = supportsVersion(CHAT_POST_REMINDER_API, 1)

    fun supportsChatScheduledMessages(): Boolean = supportsVersion(CHAT_POST_SCHEDULE_API, 1)

    fun supportsChatPollCreation(): Boolean =
        supportsVersion(CHAT_POST_VOTE_API, 1) && supports("SYNO.Chat.Post")

    suspend fun loadDownloadSettings(): DownloadSettings = downloadStationRepository.loadSettings()

    @Suppress("DEPRECATION")
    @Deprecated("Use saveDownloadSettingsResult(original, desired) from the formal UI flow")
    suspend fun saveDownloadSettings(settings: DownloadSettings) {
        downloadStationRepository.saveSettings(settings)
    }

    @Deprecated("Use saveDownloadSettingsResult(original, desired) to preserve the visible baseline")
    suspend fun saveDownloadSettingsResult(settings: DownloadSettings): MutationResult =
        downloadStationRepository.saveSettingsResult(settings)

    suspend fun saveDownloadSettingsResult(
        original: DownloadSettings,
        desired: DownloadSettings,
    ): MutationResult = downloadStationRepository.saveSettingsResult(original, desired)

    suspend fun controlDownloadsResult(
        baseline: List<DownloadTaskMutationBaseline>,
        action: DownloadTaskMutationAction,
    ): MutationResult = downloadStationRepository.controlTasksResult(baseline, action)

    suspend fun editDownloadDestinationResult(
        baseline: DownloadTaskMutationBaseline,
        destination: FileItem,
    ): MutationResult = downloadStationRepository.editDestinationResult(baseline, destination)

    suspend fun containerOverview(): ContainerOverview = containerRepository.overview()

    fun supportsContainerRegistry(): Boolean = containerRepository.supportsRegistry()

    /**
     * Container Manager 写接口尚未取得专用测试目标上的行为验证证据。
     *
     * 该门禁必须独立于运行时 API 能力发现：NAS 返回接口名称或版本范围，并不能证明写操作的
     * 参数、副作用和写后状态已经验证。完成版本化契约与实机行为验证前，Android 始终拒绝提交。
     */
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

    suspend fun virtualMachineOverview(): VirtualMachineOverview {
        val guestApi = preferred("SYNO.Virtualization.API.Guest", "SYNO.Virtualization.Guest")
        val hostApi = preferredOrNull("SYNO.Virtualization.API.Host", "SYNO.Virtualization.Host")
        val storageApi = preferredOrNull("SYNO.Virtualization.API.Storage", "SYNO.Virtualization.Repo")
        val networkApi = preferredOrNull("SYNO.Virtualization.API.Network", "SYNO.Virtualization.Network")
        val imageApi = preferredOrNull(
            "SYNO.Virtualization.API.Guest.Image",
            "SYNO.Virtualization.Guest.Image",
        )
        val unavailable = mutableSetOf<VirtualMachineSection>()
        val officialGuestRead = if (supportsVersion("SYNO.Virtualization.API.Guest", 1)) {
            try {
                officialVirtualMachineRead()
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Throwable) {
                unavailable += VirtualMachineSection.HARDWARE
                null
            }
        } else {
            unavailable += VirtualMachineSection.HARDWARE
            null
        }
        if (officialGuestRead?.hardware == null) {
            unavailable += VirtualMachineSection.HARDWARE
        }
        val machines = officialGuestRead?.machines
            ?: resourceList(guestApi, listOf("list"), "guests", "vms")
        suspend fun optional(
            section: VirtualMachineSection,
            apiName: String?,
            vararg roots: String,
        ): List<ManagedResource> {
            if (apiName == null) {
                unavailable += section
                return emptyList()
            }
            return runCatching { resourceList(apiName, listOf("list"), *roots) }.getOrElse {
                unavailable += section
                emptyList()
            }
        }
        val hosts = optional(
            VirtualMachineSection.HOSTS, hostApi, "hosts", "host", "data", "list",
        )
        val storages = optional(
            VirtualMachineSection.STORAGES, storageApi, "repos", "storages", "data", "list",
        )
        val networks = optional(
            VirtualMachineSection.NETWORKS, networkApi, "networks", "network", "data", "list",
        )
        val images = optional(
            VirtualMachineSection.IMAGES, imageApi, "images", "image", "data", "list",
        )
        val protectionData = if (supports("SYNO.Virtualization.GuestProtect.Plan")) {
            runCatching {
                firstSuccessful(
                    "SYNO.Virtualization.GuestProtect.Plan",
                    listOf("list", "get"),
                )
            }.getOrNull()
        } else {
            unavailable += VirtualMachineSection.PROTECTION
            null
        }
        if (supports("SYNO.Virtualization.GuestProtect.Plan") && protectionData == null) {
            unavailable += VirtualMachineSection.PROTECTION
        }
        val plans = protectionData?.let {
            genericResources(
                it,
                "plans",
                "plan",
                "protection_plans",
                "guest_protects",
                "data",
                "list",
            )
        }.orEmpty()
        val schedules = protectionData?.let {
            genericResources(it, "schedule_policies", "schedules", "schedule_policy")
        }.orEmpty()
        val retentions = protectionData?.let {
            genericResources(it, "retention_policies", "retentions", "retention_policy")
        }.orEmpty()
        val logs = if (supports("SYNO.Virtualization.Log")) {
            runCatching { virtualizationLogs() }.getOrElse {
                unavailable += VirtualMachineSection.LOGS
                emptyList()
            }
        } else {
            unavailable += VirtualMachineSection.LOGS
            emptyList()
        }
        val taskCenter = virtualMachineTaskCenter()
        if (taskCenter.state != VirtualMachineTaskCenterState.AVAILABLE) {
            unavailable += VirtualMachineSection.TASKS
        }
        return VirtualMachineOverview(
            machines = machines,
            hosts = hosts,
            storages = storages,
            networks = networks,
            images = images,
            protectionPlans = plans,
            protectionSchedules = schedules,
            retentionPolicies = retentions,
            logs = logs,
            machineHardware = officialGuestRead?.hardware.orEmpty(),
            tasks = taskCenter.tasks,
            taskCenterState = taskCenter.state,
            unavailableSections = unavailable,
        )
    }

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

    /**
     * 使用官方 Guest.Image.create v1 从 NAS 已有文件创建映像。提交后只跟踪本次返回的
     * task_id，并以终态 image_id 回读映像列表；连接中断或取消时绝不重放 create。
     */
    suspend fun importVirtualMachineImageResult(
        target: VirtualMachineImageImport,
        onTaskStarted: (String) -> Unit = {},
    ): MutationResult {
        val operation = "virtualMachineImageImport"
        val name = target.imageName.trim()
        val source = target.sourceFile
        val storage = target.storage
        val valid = name.isNotEmpty() && name.none(Char::isISOControl) &&
            source.path.isNotBlank() && source.path.startsWith('/') && !source.isDirectory &&
            source.canRead && storage.isEligibleForVirtualMachineImageImport()
        if (!valid) return settingsMutationResult(
            operation = operation,
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            total = 1,
            failed = 1,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "vmm.image.import.invalid-input",
        )
        if (!supportsOfficialVirtualMachineImageImport()) return settingsMutationResult(
            operation = operation,
            status = MutationResultStatus.UNSUPPORTED,
            submitted = false,
            total = 1,
            failed = 1,
            errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = "vmm.image.import.unsupported",
        )
        val targetKey = "virtual-machine-image-name:${name.lowercase(Locale.ROOT)}"
        if (!claimServiceMutation(targetKey)) return settingsMutationResult(
            operation = operation,
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            total = 1,
            failed = 1,
            errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "vmm.image.import.duplicate-submission",
        )
        var taskId: String? = null
        try {
            try {
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
                        it.id == storage.id && it.name == storage.name && it.state == storage.state
                            && it.isEligibleForVirtualMachineImageImport()
                    } ||
                    currentImages.any { it.name.equals(name, ignoreCase = true) }
                ) {
                    return settingsMutationResult(
                        operation = operation,
                        status = MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        total = 1,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "vmm.image.import.baseline-changed",
                    )
                }
                currentCoroutineContext().ensureActive()
            } catch (_: CancellationException) {
                return settingsMutationResult(
                    operation = operation,
                    status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    total = 1,
                    diagnosticTag = "vmm.image.import.cancelled-before-submission",
                )
            } catch (error: Throwable) {
                val failure = error.asRepositoryFailure()
                return settingsMutationResult(
                    operation = operation,
                    status = when (failure.kind) {
                        DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED ->
                            MutationResultStatus.PERMISSION_DENIED
                        DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED ->
                            MutationResultStatus.UNSUPPORTED
                        else -> MutationResultStatus.CONFIRMED_FAILURE
                    },
                    submitted = false,
                    total = 1,
                    failed = 1,
                    errorCategory = failure.mutationErrorCategory(),
                    diagnosticTag = "vmm.image.import.preflight-failed",
                )
            }

            try {
                val started = call(
                    "SYNO.Virtualization.API.Guest.Image",
                    "create",
                    mapOf(
                        "auto_clean_task" to "false",
                        "storage_ids" to jsonStrings(listOf(storage.id)),
                        "type" to target.imageType.apiValue,
                        "ds_file_path" to source.path,
                        "image_name" to name,
                    ),
                    version = 1,
                )
                taskId = started["task_id"].strictStringValue()?.takeIf(String::isNotBlank)
                if (taskId == null) return vmmImageImportUnverified("missing-task-id")
                onTaskStarted(checkNotNull(taskId))
            } catch (_: CancellationException) {
                return vmmImageImportCancelled("cancelled-after-submission")
            } catch (error: Throwable) {
                val failure = error.asRepositoryFailure()
                return if (failure.isAmbiguousSettingsFailure()) {
                    vmmImageImportUnverified(
                        "submission-unverified",
                        failure.mutationErrorCategory(),
                    )
                } else {
                    settingsMutationResult(
                        operation = operation,
                        status = when (failure.kind) {
                            DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED ->
                                MutationResultStatus.PERMISSION_DENIED
                            DsmErrorKind.FEATURE_UNSUPPORTED,
                            DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
                            -> MutationResultStatus.UNSUPPORTED
                            else -> MutationResultStatus.CONFIRMED_FAILURE
                        },
                        submitted = true,
                        total = 1,
                        failed = 1,
                        errorCategory = failure.mutationErrorCategory(),
                        diagnosticTag = "vmm.image.import.submission-failed",
                    )
                }
            }

            var imageId: String? = null
            try {
                for (attempt in 0 until MAX_VMM_CREATION_POLLS) {
                    currentCoroutineContext().ensureActive()
                    when (val task = readOfficialVmmImageImportTask(checkNotNull(taskId))) {
                        is VmmImageImportTaskState.Pending -> Unit
                        is VmmImageImportTaskState.Finished -> {
                            imageId = task.imageId
                            break
                        }
                        VmmImageImportTaskState.FinishedWithoutImage -> break
                    }
                    if (attempt + 1 < MAX_VMM_CREATION_POLLS) {
                        delay(VMM_CREATION_POLL_INTERVAL_MILLIS)
                    }
                }
            } catch (cancelled: CancellationException) {
                val readback = withContext(NonCancellable) {
                    runCatching { readOfficialVmmImageImportTask(checkNotNull(taskId)) }.getOrNull()
                }
                imageId = (readback as? VmmImageImportTaskState.Finished)?.imageId
                if (imageId == null) return vmmImageImportCancelled("cancelled-during-task")
            } catch (error: Throwable) {
                val failure = error.asRepositoryFailure()
                val readback = withContext(NonCancellable) {
                    runCatching { readOfficialVmmImageImportTask(checkNotNull(taskId)) }.getOrNull()
                }
                imageId = (readback as? VmmImageImportTaskState.Finished)?.imageId
                if (imageId == null) return vmmImageImportUnverified(
                    "task-unverified",
                    failure.mutationErrorCategory(),
                )
            }
            val stableImageId = imageId ?: return vmmImageImportUnverified("task-finished-without-image")
            val confirmed = try {
                strictVirtualizationResourceList(
                    "SYNO.Virtualization.API.Guest.Image",
                    listOf("list"),
                    "images",
                ).singleOrNull { it.id == stableImageId }?.let { image ->
                    image.name == name && image.metadata["type"] == target.imageType.apiValue
                } == true
            } catch (_: CancellationException) {
                return vmmImageImportCancelled("cancelled-during-readback")
            } catch (error: Throwable) {
                return vmmImageImportUnverified(
                    "readback-failed",
                    error.asRepositoryFailure().mutationErrorCategory(),
                )
            }
            return if (confirmed) {
                settingsMutationResult(
                    operation = operation,
                    status = MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    total = 1,
                    succeeded = 1,
                    diagnosticTag = "vmm.image.import.confirmed",
                )
            } else {
                vmmImageImportUnverified("readback-mismatch")
            }
        } finally {
            withContext(NonCancellable) { releaseServiceMutation(targetKey) }
        }
    }

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

    suspend fun createVirtualMachineResult(configuration: VirtualMachineCreation): MutationResult {
        val name = configuration.name.trim()
        val description = configuration.description.trim()
        val storageId = configuration.storageId.trim()
        val networkId = configuration.networkId?.trim().orEmpty()
        val imageId = configuration.diskImageId?.trim()?.takeIf(String::isNotEmpty)
        val disks = listOf(
            VirtualMachineCreationDisk(configuration.diskGiB, imageId),
        ) + configuration.additionalDisks.map {
            it.copy(diskImageId = it.diskImageId?.trim()?.takeIf(String::isNotEmpty))
        }
        val networkIds = listOf(networkId) + configuration.additionalNetworkInterfaces.map {
            it.networkId?.trim().orEmpty()
        }
        val valid = name.isNotEmpty() && name.length <= 64 && name.none(Char::isISOControl) &&
            description.length <= 1_024 && configuration.cpuCount in 1..64 &&
            configuration.memoryMiB in 128..1_048_576 &&
            disks.size in 1..MAX_VIRTUAL_MACHINE_DISKS && disks.all { disk ->
                (disk.diskImageId != null || disk.sizeGiB in 1..1_048_576) &&
                    disk.diskImageId?.let { id ->
                        id.isNotBlank() && id == id.trim() && id.none(Char::isISOControl)
                    } != false
            } && networkIds.all { it.none(Char::isISOControl) } && storageId.isNotEmpty()
        if (!valid) return settingsMutationResult(
            operation = "virtualMachineCreate",
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            total = 2,
            failed = 2,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "vmm.guest.create.invalid-input",
        )
        if (!supportsOfficialVirtualMachineCreation()) return settingsMutationResult(
            operation = "virtualMachineCreate",
            status = MutationResultStatus.UNSUPPORTED,
            submitted = false,
            total = 2,
            failed = 2,
            errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = "vmm.guest.create.unsupported",
        )
        val targetKey = "virtual-machine-name:${name.lowercase(Locale.ROOT)}"
        if (!claimServiceMutation(targetKey)) return settingsMutationResult(
            operation = "virtualMachineCreate",
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            total = 2,
            failed = 2,
            errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "vmm.guest.create.duplicate-submission",
        )
        var taskId: String? = null
        var taskClearAllowed = false
        try {
            val machines = try {
                officialVirtualMachines()
            } catch (_: CancellationException) {
                return vmmCreationCancelledBeforeSubmission("preflight")
            } catch (error: Throwable) {
                return vmmCreationFailure(error.asRepositoryFailure(), submitted = false, stage = "preflight")
            }
            if (machines.any { it.name.equals(name, ignoreCase = true) }) {
                return settingsMutationResult(
                    operation = "virtualMachineCreate",
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    total = 2,
                    failed = 2,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "vmm.guest.create.name-conflict",
                )
            }
            val storages = try {
                strictVirtualizationResourceList(
                    "SYNO.Virtualization.API.Storage",
                    listOf("list"),
                    "storages",
                )
            } catch (_: CancellationException) {
                return vmmCreationCancelledBeforeSubmission("storage-preflight")
            } catch (error: Throwable) {
                return vmmCreationFailure(error.asRepositoryFailure(), submitted = false, stage = "storage-preflight")
            }
            if (storages.none { it.id == storageId && it.state != ResourceState.ERROR }) {
                return settingsMutationResult(
                    operation = "virtualMachineCreate",
                    status = MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    total = 2,
                    failed = 2,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "vmm.guest.create.storage-changed",
                )
            }
            val connectedNetworkIds = networkIds.filter(String::isNotEmpty).toSet()
            if (connectedNetworkIds.isNotEmpty()) {
                if (!supportsVersion("SYNO.Virtualization.API.Network", 1)) {
                    return settingsMutationResult(
                        operation = "virtualMachineCreate",
                        status = MutationResultStatus.UNSUPPORTED,
                        submitted = false,
                        total = 2,
                        failed = 2,
                        errorCategory = MutationErrorCategory.UNSUPPORTED,
                        diagnosticTag = "vmm.guest.create.network-unsupported",
                    )
                }
                val networks = try {
                    strictVirtualizationResourceList(
                        "SYNO.Virtualization.API.Network",
                        listOf("list"),
                        "networks",
                    )
                } catch (_: CancellationException) {
                    return vmmCreationCancelledBeforeSubmission("network-preflight")
                } catch (error: Throwable) {
                    return vmmCreationFailure(error.asRepositoryFailure(), submitted = false, stage = "network-preflight")
                }
                if (!networks.map(ManagedResource::id).toSet().containsAll(connectedNetworkIds)) {
                    return settingsMutationResult(
                        operation = "virtualMachineCreate",
                        status = MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        total = 2,
                        failed = 2,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "vmm.guest.create.network-changed",
                    )
                }
            }
            val diskImageIds = disks.mapNotNull { it.diskImageId }.toSet()
            if (diskImageIds.isNotEmpty()) {
                if (!supportsVersion("SYNO.Virtualization.API.Guest.Image", 1)) {
                    return settingsMutationResult(
                        operation = "virtualMachineCreate",
                        status = MutationResultStatus.UNSUPPORTED,
                        submitted = false,
                        total = 2,
                        failed = 2,
                        errorCategory = MutationErrorCategory.UNSUPPORTED,
                        diagnosticTag = "vmm.guest.create.image-unsupported",
                    )
                }
                val images = try {
                    strictVirtualizationResourceList(
                        "SYNO.Virtualization.API.Guest.Image",
                        listOf("list"),
                        "images",
                    )
                } catch (_: CancellationException) {
                    return vmmCreationCancelledBeforeSubmission("image-preflight")
                } catch (error: Throwable) {
                    return vmmCreationFailure(error.asRepositoryFailure(), submitted = false, stage = "image-preflight")
                }
                val availableDiskImageIds = images.filter { it.metadata["type"] == "disk" }
                    .map(ManagedResource::id).toSet()
                if (!availableDiskImageIds.containsAll(diskImageIds)) {
                    return settingsMutationResult(
                        operation = "virtualMachineCreate",
                        status = MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        total = 2,
                        failed = 2,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "vmm.guest.create.image-changed",
                    )
                }
            }

            val requestDisks = disks.map { disk ->
                disk.diskImageId?.let { sourceImageId ->
                    JsonObject(
                        mapOf(
                            "create_type" to JsonPrimitive(1),
                            "image_id" to JsonPrimitive(sourceImageId),
                        ),
                    )
                } ?: JsonObject(
                    mapOf(
                        "create_type" to JsonPrimitive(0),
                        "vdisk_size" to JsonPrimitive(disk.sizeGiB * 1_024L),
                    ),
                )
            }
            var createdId: String? = null
            try {
                val started = call(
                    "SYNO.Virtualization.API.Guest",
                    "create",
                    mapOf(
                        "auto_clean_task" to "false",
                        "storage_id" to storageId,
                        "vnics" to JsonArray(networkIds.map { requestedNetworkId ->
                            JsonObject(mapOf("network_id" to JsonPrimitive(requestedNetworkId)))
                        }).toString(),
                        "vdisks" to JsonArray(requestDisks).toString(),
                        "guest_name" to name,
                    ),
                    version = 1,
                )
                taskId = started["task_id"].strictStringValue()?.takeIf(String::isNotBlank)
                if (taskId == null) {
                    withContext(NonCancellable) {
                        runCatching { findOfficialVirtualMachine(name) }
                    }
                    return settingsMutationResult(
                        operation = "virtualMachineCreate",
                        status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        submitted = true,
                        total = 2,
                        unknown = 2,
                        requiresRefresh = true,
                        errorCategory = MutationErrorCategory.SERVER,
                        diagnosticTag = "vmm.guest.create.missing-task-id",
                    )
                }
            } catch (_: CancellationException) {
                withContext(NonCancellable) {
                    runCatching { findOfficialVirtualMachine(name) }
                }
                return settingsMutationResult(
                    operation = "virtualMachineCreate",
                    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    total = 2,
                    unknown = 2,
                    requiresRefresh = true,
                    diagnosticTag = "vmm.guest.create.cancelled-after-submission",
                )
            } catch (error: Throwable) {
                val failure = error.asRepositoryFailure()
                withContext(NonCancellable) {
                    runCatching { findOfficialVirtualMachine(name) }
                }
                return if (failure.isAmbiguousSettingsFailure()) {
                    settingsMutationResult(
                        operation = "virtualMachineCreate",
                        status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        submitted = true,
                        total = 2,
                        unknown = 2,
                        requiresRefresh = true,
                        errorCategory = failure.mutationErrorCategory(),
                        diagnosticTag = "vmm.guest.create.submission-unverified",
                    )
                } else {
                    vmmCreationFailure(failure, submitted = true, stage = "submission")
                }
            }

            if (createdId == null) {
                try {
                    for (attempt in 0 until MAX_VMM_CREATION_POLLS) {
                        currentCoroutineContext().ensureActive()
                        when (val task = readOfficialVmmCreationTask(checkNotNull(taskId))) {
                            is VmmCreationTaskState.Pending -> Unit
                            is VmmCreationTaskState.Finished -> {
                                createdId = task.guestId
                                break
                            }
                            VmmCreationTaskState.FinishedWithoutGuest -> {
                                break
                            }
                        }
                        if (attempt + 1 < MAX_VMM_CREATION_POLLS) {
                            delay(VMM_CREATION_POLL_INTERVAL_MILLIS)
                        }
                    }
                } catch (_: CancellationException) {
                    withContext(NonCancellable) {
                        runCatching {
                            readOfficialVmmCreationTask(checkNotNull(taskId))
                        }
                    }
                    return settingsMutationResult(
                        operation = "virtualMachineCreate",
                        status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        submitted = true,
                        total = 2,
                        unknown = 2,
                        requiresRefresh = true,
                        diagnosticTag = "vmm.guest.create.cancelled-during-task",
                    )
                } catch (error: Throwable) {
                    val failure = error.asRepositoryFailure()
                    val scopedReadback = withContext(NonCancellable) {
                        runCatching { readOfficialVmmCreationTask(checkNotNull(taskId)) }.getOrNull()
                    }
                    when (scopedReadback) {
                        is VmmCreationTaskState.Finished -> {
                            createdId = scopedReadback.guestId
                        }
                        VmmCreationTaskState.FinishedWithoutGuest -> Unit
                        is VmmCreationTaskState.Pending, null -> Unit
                    }
                    if (createdId == null) return settingsMutationResult(
                        operation = "virtualMachineCreate",
                        status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        submitted = true,
                        total = 2,
                        unknown = 2,
                        requiresRefresh = true,
                        errorCategory = failure.mutationErrorCategory(),
                        diagnosticTag = "vmm.guest.create.task-unverified",
                    )
                }
                if (createdId == null) return settingsMutationResult(
                    operation = "virtualMachineCreate",
                    status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    total = 2,
                    unknown = 2,
                    requiresRefresh = true,
                    diagnosticTag = "vmm.guest.create.task-finished-without-guest",
                )
            }

            val guestId = checkNotNull(createdId)
            var configurationFailure: DsmFailure? = null
            var configurationCancelled = false
            try {
                call(
                    "SYNO.Virtualization.API.Guest",
                    "set",
                    mapOf(
                        "guest_id" to guestId,
                        "new_guest_name" to name,
                        "description" to description,
                        "vcpu_num" to configuration.cpuCount.toString(),
                        "vram_size" to configuration.memoryMiB.toString(),
                        "autorun" to if (configuration.autoStart) "2" else "0",
                    ),
                    version = 1,
                )
            } catch (_: CancellationException) {
                configurationCancelled = true
            } catch (error: Throwable) {
                configurationFailure = error.asRepositoryFailure()
            }
            var readbackFailure: DsmFailure? = null
            var readbackCancelled = false
            val settingsSnapshot = try {
                withContext(NonCancellable) { readOfficialVirtualMachineSettings(guestId) }
            } catch (_: CancellationException) {
                readbackCancelled = true
                null
            } catch (error: Throwable) {
                readbackFailure = error.asRepositoryFailure()
                null
            }
            val settingsVerified = settingsSnapshot == VmmGuestSettingsSnapshot(
                name = name,
                description = description,
                cpuCount = configuration.cpuCount,
                memoryMiB = configuration.memoryMiB,
                autoStart = configuration.autoStart,
            )
            val hardwareVerified = if (
                configuration.additionalDisks.isEmpty() &&
                configuration.additionalNetworkInterfaces.isEmpty()
            ) {
                true
            } else {
                val hardware = try {
                    withContext(NonCancellable) { readOfficialVirtualMachineHardware(guestId) }
                } catch (_: CancellationException) {
                    readbackCancelled = true
                    null
                } catch (error: Throwable) {
                    if (readbackFailure == null) readbackFailure = error.asRepositoryFailure()
                    null
                }
                hardware?.matchesCreatedHardware(disks, networkIds) == true
            }
            if (!currentCoroutineContext().isActive) readbackCancelled = true
            val hasImageBackedDisk = disks.any { it.diskImageId != null }
            return if (settingsVerified && hardwareVerified && !hasImageBackedDisk) {
                taskClearAllowed = true
                settingsMutationResult(
                    operation = "virtualMachineCreate",
                    status = MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    total = 2,
                    succeeded = 2,
                    diagnosticTag = "vmm.guest.create.confirmed",
                )
            } else {
                val ambiguous = configurationCancelled || readbackCancelled ||
                    readbackFailure != null || hasImageBackedDisk ||
                    configurationFailure?.isAmbiguousSettingsFailure() == true
                settingsMutationResult(
                    operation = "virtualMachineCreate",
                    status = MutationResultStatus.PARTIAL_SUCCESS,
                    submitted = true,
                    total = 2,
                    succeeded = 1,
                    failed = if (ambiguous) 0 else 1,
                    unknown = if (ambiguous) 1 else 0,
                    requiresRefresh = true,
                    errorCategory = readbackFailure?.mutationErrorCategory()
                        ?: configurationFailure?.mutationErrorCategory()
                        ?: MutationErrorCategory.CONFLICT,
                    diagnosticTag = when {
                        hasImageBackedDisk -> "vmm.guest.create.image-source-unverified"
                        readbackCancelled -> "vmm.guest.create.readback-cancelled"
                        readbackFailure != null -> "vmm.guest.create.readback-failed"
                        else -> "vmm.guest.create.configuration-partial"
                    },
                )
            }
        } finally {
            taskId?.takeIf { taskClearAllowed }?.let { id ->
                withContext(NonCancellable) {
                    runCatching {
                        call(
                            "SYNO.Virtualization.API.Task.Info",
                            "clear",
                            mapOf("task_id" to id),
                            version = 1,
                        )
                    }
                }
            }
            releaseServiceMutation(targetKey)
        }
    }

    private suspend fun officialVirtualMachines(): List<ManagedResource> = strictVirtualizationResourceList(
        "SYNO.Virtualization.API.Guest",
        listOf("list"),
        "guests",
        "vms",
    )

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

    /**
     * 清除用户刚刚确认过的已完成 VMM 任务。
     *
     * 服务端任务标识只在本次内存基线和请求边界内使用。提交异常或取消后仅进行一次严格回读，
     * 不自动重放 `clear`；进行中任务、基线漂移和重复批次均在任何写请求前关闭。
     */
    suspend fun clearFinishedVirtualMachineTasksResult(
        baseline: List<VirtualMachineTask>,
        onResultResolved: (MutationResult) -> Unit = {},
    ): MutationResult = clearFinishedVirtualMachineTasksResultInternal(baseline)
        .also(onResultResolved)

    private suspend fun clearFinishedVirtualMachineTasksResultInternal(
        baseline: List<VirtualMachineTask>,
    ): MutationResult {
        val operation = "virtualMachineTaskCleanup"
        val diagnosticPrefix = "vmm.task.cleanup"
        val targets = baseline.filter(VirtualMachineTask::isFinished)
        if (!supportsVersion("SYNO.Virtualization.API.Task.Info", 1)) {
            return settingsMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                total = targets.size,
                failed = targets.size,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "$diagnosticPrefix.unsupported",
            )
        }
        if (baseline.isEmpty() || targets.isEmpty() ||
            targets.map(VirtualMachineTask::taskToken).distinct().size != targets.size
        ) {
            return settingsMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                total = targets.size,
                failed = targets.size,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "$diagnosticPrefix.invalid-baseline",
            )
        }
        val targetKey = "vmm-task-cleanup"
        if (!claimServiceMutation(targetKey)) {
            return settingsMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                total = targets.size,
                failed = targets.size,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "$diagnosticPrefix.duplicate",
            )
        }
        try {
            val current = try {
                readOfficialVirtualMachineTaskRecords()
            } catch (_: CancellationException) {
                return settingsMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    total = targets.size,
                    diagnosticTag = "$diagnosticPrefix.cancelled-before-submission",
                )
            } catch (error: Throwable) {
                val failure = error.asRepositoryFailure()
                return settingsMutationResult(
                    operation,
                    if (failure.kind in setOf(
                            DsmErrorKind.PERMISSION_DENIED,
                            DsmErrorKind.SESSION_EXPIRED,
                            DsmErrorKind.AUTHENTICATION_FAILED,
                        )
                    ) MutationResultStatus.PERMISSION_DENIED else MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    total = targets.size,
                    failed = targets.size,
                    errorCategory = failure.mutationErrorCategory(),
                    diagnosticTag = "$diagnosticPrefix.preflight-failed",
                )
            }
            if (!virtualMachineTaskCleanupTargetsMatch(targets, current)) {
                return settingsMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    total = targets.size,
                    failed = targets.size,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "$diagnosticPrefix.baseline-changed",
                )
            }

            val submittedTokens = mutableListOf<String>()
            var submissionFailure: Throwable? = null
            for (target in targets) {
                try {
                    currentCoroutineContext().ensureActive()
                    submittedTokens += target.taskToken
                    call(
                        "SYNO.Virtualization.API.Task.Info",
                        "clear",
                        mapOf("task_id" to target.taskToken),
                        version = 1,
                    )
                } catch (error: Throwable) {
                    submissionFailure = error
                    break
                }
            }
            if (submittedTokens.isEmpty()) {
                return settingsMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    total = targets.size,
                    diagnosticTag = "$diagnosticPrefix.cancelled-before-submit",
                )
            }

            val remainingTokens = try {
                withContext(NonCancellable) {
                    readOfficialVirtualMachineTaskRecords().map(VirtualMachineTaskRecord::taskToken).toSet()
                }
            } catch (_: Throwable) {
                return settingsMutationResult(
                    operation,
                    if (submissionFailure is CancellationException) {
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    } else {
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                    },
                    submitted = true,
                    total = targets.size,
                    failed = targets.size - submittedTokens.size,
                    unknown = submittedTokens.size,
                    requiresRefresh = true,
                    errorCategory = submissionFailure?.asRepositoryFailure()?.mutationErrorCategory(),
                    diagnosticTag = "$diagnosticPrefix.readback-failed",
                )
            }
            val succeeded = submittedTokens.count { it !in remainingTokens }
            val unsubmitted = targets.size - submittedTokens.size
            if (submissionFailure != null) {
                val unknown = submittedTokens.count { it in remainingTokens }
                val status = when {
                    submissionFailure is CancellationException ->
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    submissionFailure.asRepositoryFailure().isAmbiguousSettingsFailure() ->
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                    succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
                    submissionFailure.asRepositoryFailure().kind in setOf(
                        DsmErrorKind.PERMISSION_DENIED,
                        DsmErrorKind.SESSION_EXPIRED,
                        DsmErrorKind.AUTHENTICATION_FAILED,
                    ) -> MutationResultStatus.PERMISSION_DENIED
                    else -> MutationResultStatus.CONFIRMED_FAILURE
                }
                return settingsMutationResult(
                    operation,
                    status,
                    submitted = true,
                    total = targets.size,
                    succeeded = succeeded,
                    failed = unsubmitted + if (status in setOf(
                            MutationResultStatus.PARTIAL_SUCCESS,
                            MutationResultStatus.PERMISSION_DENIED,
                            MutationResultStatus.CONFIRMED_FAILURE,
                        )
                    ) unknown else 0,
                    unknown = if (status in setOf(
                            MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        )
                    ) unknown else 0,
                    requiresRefresh = status in setOf(
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    ),
                    errorCategory = submissionFailure.asRepositoryFailure().mutationErrorCategory(),
                    diagnosticTag = "$diagnosticPrefix.submission-interrupted",
                )
            }
            val unknown = targets.size - succeeded
            return settingsMutationResult(
                operation,
                when {
                    succeeded == targets.size -> MutationResultStatus.CONFIRMED_SUCCESS
                    succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
                    else -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                },
                submitted = true,
                total = targets.size,
                succeeded = succeeded,
                unknown = unknown,
                requiresRefresh = unknown > 0,
                errorCategory = MutationErrorCategory.CONFLICT.takeIf { unknown > 0 },
                diagnosticTag = if (unknown == 0) {
                    "$diagnosticPrefix.confirmed"
                } else {
                    "$diagnosticPrefix.readback-mismatch"
                },
            )
        } finally {
            withContext(NonCancellable) { releaseServiceMutation(targetKey) }
        }
    }

    private fun virtualMachineTaskCleanupTargetsMatch(
        targets: List<VirtualMachineTask>,
        current: List<VirtualMachineTaskRecord>,
    ): Boolean {
        val currentByToken = current.associateBy(VirtualMachineTaskRecord::taskToken)
        return currentByToken.size == current.size && targets.all { expected ->
            val actual = currentByToken[expected.taskToken] ?: return@all false
            expected.id == actual.task.id &&
                actual.task.isFinished
        }
    }

    private fun virtualMachineTaskDigest(taskToken: String): String =
        MessageDigest.getInstance("SHA-256")
            .digest(taskToken.toByteArray(Charsets.UTF_8))
            .joinToString("") { byte ->
                (byte.toInt() and 0xff).toString(16).padStart(2, '0')
            }

    private suspend fun findOfficialVirtualMachine(name: String): ManagedResource? {
        return officialVirtualMachines().singleOrNull {
            it.name.equals(name, ignoreCase = true)
        }
    }

    private suspend fun readOfficialVmmCreationTask(taskId: String): VmmCreationTaskState {
        val task = call(
            "SYNO.Virtualization.API.Task.Info",
            "get",
            mapOf("task_id" to taskId),
            version = 1,
        )
        val finished = task["finish"].strictBooleanValue()
            ?: throw invalidVirtualizationResponse("task-finish")
        if (!finished) return VmmCreationTaskState.Pending
        val taskInfo = task["task_info"] as? JsonObject
            ?: return VmmCreationTaskState.FinishedWithoutGuest
        val guestId = taskInfo["guest_id"].strictStringValue()?.takeIf(String::isNotBlank)
            ?: return VmmCreationTaskState.FinishedWithoutGuest
        return VmmCreationTaskState.Finished(guestId)
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

    private suspend fun readOfficialVirtualMachineSettings(id: String): VmmGuestSettingsSnapshot {
        val guest = readOfficialVirtualMachineGuest(id, "guest-settings").payload
        val autorun = guest["autorun"].strictIntValue()
            ?: throw invalidVirtualizationResponse("guest-settings-autorun")
        if (autorun !in setOf(0, 2)) throw invalidVirtualizationResponse("guest-settings-autorun")
        return VmmGuestSettingsSnapshot(
            name = guest["guest_name"].strictStringValue()
                ?: throw invalidVirtualizationResponse("guest-settings-name"),
            description = guest["description"].strictStringValue()
                ?: throw invalidVirtualizationResponse("guest-settings-description"),
            cpuCount = guest["vcpu_num"].strictIntValue()
                ?: throw invalidVirtualizationResponse("guest-settings-cpu"),
            memoryMiB = guest["vram_size"].strictIntValue()
                ?: throw invalidVirtualizationResponse("guest-settings-memory"),
            autoStart = autorun == 2,
        )
    }

    private suspend fun readOfficialVirtualMachineHardware(id: String): VirtualMachineHardware {
        val guest = readOfficialVirtualMachineGuest(id, "guest-creation-hardware")
        return officialVirtualMachineHardware(guest.payload, guest.id, "guest-creation-hardware")
    }

    private fun VirtualMachineHardware.matchesCreatedHardware(
        requestedDisks: List<VirtualMachineCreationDisk>,
        requestedNetworkIds: List<String>,
    ): Boolean {
        if (disks.size != requestedDisks.size || networkInterfaces.size != requestedNetworkIds.size) {
            return false
        }
        val remainingSizes = disks.map(VirtualMachineDisk::sizeMiB).toMutableList()
        val allEmptyDiskSizesMatched = requestedDisks.filter { it.diskImageId == null }.all { requested ->
            remainingSizes.remove(requested.sizeGiB * 1_024)
        }
        return allEmptyDiskSizesMatched &&
            networkInterfaces.map(VirtualMachineNetworkInterface::networkId).groupingBy { it }.eachCount() ==
            requestedNetworkIds.groupingBy { it }.eachCount()
    }

    private sealed class VmmCreationTaskState {
        object Pending : VmmCreationTaskState()
        object FinishedWithoutGuest : VmmCreationTaskState()
        data class Finished(val guestId: String) : VmmCreationTaskState()
    }

    private sealed class VmmImageImportTaskState {
        object Pending : VmmImageImportTaskState()
        object FinishedWithoutImage : VmmImageImportTaskState()
        data class Finished(val imageId: String) : VmmImageImportTaskState()
    }

    private fun vmmImageImportUnverified(
        stage: String,
        errorCategory: MutationErrorCategory = MutationErrorCategory.UNKNOWN,
    ) = settingsMutationResult(
        operation = "virtualMachineImageImport",
        status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
        submitted = true,
        total = 1,
        unknown = 1,
        requiresRefresh = true,
        errorCategory = errorCategory,
        diagnosticTag = "vmm.image.import.$stage",
    )

    private fun vmmImageImportCancelled(stage: String) = settingsMutationResult(
        operation = "virtualMachineImageImport",
        status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
        submitted = true,
        total = 1,
        unknown = 1,
        requiresRefresh = true,
        diagnosticTag = "vmm.image.import.$stage",
    )

    private data class VmmGuestSettingsSnapshot(
        val name: String,
        val description: String,
        val cpuCount: Int,
        val memoryMiB: Int,
        val autoStart: Boolean,
    )

    private fun vmmCreationFailure(
        failure: DsmFailure,
        submitted: Boolean,
        stage: String,
    ) = settingsMutationResult(
        operation = "virtualMachineCreate",
        status = if (failure.kind in setOf(
                DsmErrorKind.PERMISSION_DENIED,
                DsmErrorKind.SESSION_EXPIRED,
                DsmErrorKind.AUTHENTICATION_FAILED,
            )
        ) {
            MutationResultStatus.PERMISSION_DENIED
        } else {
            MutationResultStatus.CONFIRMED_FAILURE
        },
        submitted = submitted,
        total = 2,
        failed = 2,
        errorCategory = failure.mutationErrorCategory(),
        diagnosticTag = "vmm.guest.create.$stage-failed",
    )

    private fun vmmCreationCancelledBeforeSubmission(stage: String) = settingsMutationResult(
        operation = "virtualMachineCreate",
        status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
        submitted = false,
        total = 2,
        diagnosticTag = "vmm.guest.create.$stage-cancelled",
    )

    suspend fun updateVirtualMachineSettingsResult(
        id: String,
        settings: VirtualMachineSettings,
    ): MutationResult = serviceMutationResult(
        operation = "virtualMachineSettings",
        status = MutationResultStatus.CONFIRMED_FAILURE,
        submitted = false,
        errorCategory = MutationErrorCategory.CONFLICT,
        diagnosticTag = "vmm.guest.settings.missing-baseline",
    )

    suspend fun updateVirtualMachineSettingsResult(
        id: String,
        baseline: VirtualMachineSettings,
        settings: VirtualMachineSettings,
    ): MutationResult {
        val normalizedId = id.trim()
        val name = settings.name.trim()
        val description = settings.description.trim()
        val expectedBaseline = VmmGuestSettingsSnapshot(
            name = baseline.name,
            description = baseline.description,
            cpuCount = baseline.cpuCount,
            memoryMiB = baseline.memoryMiB,
            autoStart = baseline.autoStart,
        )
        val valid = normalizedId.isNotEmpty() && name.isNotEmpty() && name.length <= 64 &&
            name.none(Char::isISOControl) && description.length <= 1_024 &&
            settings.cpuCount in 1..64 && settings.memoryMiB in 128..1_048_576 &&
            baseline.name.isNotEmpty() && baseline.name.length <= 64 &&
            baseline.description.length <= 1_024 && baseline.cpuCount in 1..64 &&
            baseline.memoryMiB in 128..1_048_576
        if (!valid) return serviceMutationResult(
            operation = "virtualMachineSettings",
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "vmm.guest.settings.invalid-input",
        )
        if (!supportsOfficialVirtualMachineSettings()) return unsupportedServiceMutation(
            "virtualMachineSettings",
            "vmm.guest.settings.unsupported",
        )
        var changedParameters: Map<String, String> = emptyMap()
        return verifiedServiceMutation(
            operation = "virtualMachineSettings",
            targetKey = "virtual-machine:$normalizedId",
            requiredApi = "SYNO.Virtualization.API.Guest",
            preflight = {
                val machines = officialVirtualMachines()
                val targetExists = machines.any { it.id == normalizedId }
                val nameAvailable = machines.none {
                    it.id != normalizedId && it.name.equals(name, ignoreCase = true)
                }
                if (!targetExists || !nameAvailable) {
                    false
                } else {
                    val current = readOfficialVirtualMachineSettings(normalizedId)
                    if (current != expectedBaseline) {
                        false
                    } else {
                        changedParameters = buildMap {
                            put("guest_id", normalizedId)
                            if (current.name != name) put("new_guest_name", name)
                            if (current.description != description) put("description", description)
                            if (current.cpuCount != settings.cpuCount) {
                                put("vcpu_num", settings.cpuCount.toString())
                            }
                            if (current.memoryMiB != settings.memoryMiB) {
                                put("vram_size", settings.memoryMiB.toString())
                            }
                            if (current.autoStart != settings.autoStart) {
                                put("autorun", if (settings.autoStart) "2" else "0")
                            }
                        }.takeIf { it.size > 1 }.orEmpty()
                        true
                    }
                }
            },
            submit = {
                if (changedParameters.isNotEmpty()) {
                    call(
                        "SYNO.Virtualization.API.Guest",
                        "set",
                        changedParameters,
                        version = 1,
                    )
                }
            },
            submissionRequired = { changedParameters.isNotEmpty() },
            verify = {
                readOfficialVirtualMachineSettings(normalizedId) == VmmGuestSettingsSnapshot(
                    name = name,
                    description = description,
                    cpuCount = settings.cpuCount,
                    memoryMiB = settings.memoryMiB,
                    autoStart = settings.autoStart,
                )
            },
        )
    }

    suspend fun controlVirtualMachineResult(
        id: String,
        action: String,
    ): MutationResult = serviceMutationResult(
        operation = "virtualMachineControl",
        status = MutationResultStatus.CONFIRMED_FAILURE,
        submitted = false,
        errorCategory = MutationErrorCategory.CONFLICT,
        diagnosticTag = "vmm.guest.control.missing-baseline",
    )

    suspend fun controlVirtualMachineResult(
        id: String,
        baselineState: ResourceState,
        action: String,
    ): MutationResult {
        val normalizedId = id.trim()
        val allowedBaseline = when (action) {
            "poweron" -> ResourceState.STOPPED
            "poweroff", "shutdown" -> ResourceState.RUNNING
            else -> null
        }
        if (
            normalizedId.isEmpty() ||
            allowedBaseline == null || baselineState != allowedBaseline
        ) {
            return serviceMutationResult(
                operation = "virtualMachineControl",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "vmm.guest.control.invalid-input",
            )
        }
        val guestApi = "SYNO.Virtualization.API.Guest".takeIf { supportsVersion(it, 1) }
            ?: return unsupportedServiceMutation("virtualMachineControl", "vmm.guest.control.unsupported")
        val actionApi = "SYNO.Virtualization.API.Guest.Action".takeIf { supportsVersion(it, 1) }
            ?: return unsupportedServiceMutation("virtualMachineControl", "vmm.guest.action.unsupported")
        val expectedState = when (action) {
            "poweroff", "shutdown" -> ResourceState.STOPPED
            else -> ResourceState.RUNNING
        }
        return verifiedServiceMutation(
            operation = "virtualMachineControl",
            targetKey = "virtual-machine:$normalizedId",
            requiredApi = actionApi,
            preflight = {
                strictVirtualizationResourceList(guestApi, listOf("list"), "guests", "vms")
                    .any { it.id == normalizedId && it.state == baselineState }
            },
            submit = {
                call(
                    actionApi,
                    action,
                    mapOf("guest_id" to normalizedId),
                    version = 1,
                )
            },
            verify = {
                strictVirtualizationResourceList(guestApi, listOf("list"), "guests", "vms")
                    .any { it.id == normalizedId && it.state == expectedState }
            },
        )
    }

    suspend fun deleteVirtualMachineResult(id: String): MutationResult {
        val guestApi = "SYNO.Virtualization.API.Guest".takeIf { supportsVersion(it, 1) }
            ?: return unsupportedServiceMutation("virtualMachineDelete", "vmm.guest.delete.unsupported")
        return deleteVirtualizationResourceResult(
            operation = "virtualMachineDelete",
            targetType = "virtual-machine",
            id = id,
            apiName = guestApi,
            roots = arrayOf("guests", "vms"),
            method = "delete",
            idParameter = "guest_id",
        )
    }

    suspend fun deleteVirtualMachineImageResult(id: String): MutationResult {
        val imageApi = "SYNO.Virtualization.API.Guest.Image".takeIf { supportsVersion(it, 1) }
            ?: return unsupportedServiceMutation("virtualMachineImageDelete", "vmm.image.delete.unsupported")
        return deleteVirtualizationResourceResult(
            operation = "virtualMachineImageDelete",
            targetType = "virtual-machine-image",
            id = id,
            apiName = imageApi,
            roots = arrayOf("images", "image"),
            method = "delete",
            idParameter = "image_id",
        )
    }

    suspend fun renameVirtualMachineNetworkResult(id: String, name: String): MutationResult {
        val normalizedId = id.trim()
        val normalizedName = name.trim()
        if (normalizedId.isEmpty() || normalizedName.isEmpty()) {
            return serviceMutationResult(
                operation = "virtualMachineNetworkRename",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "vmm.network.rename.invalid-input",
            )
        }
        return unsupportedServiceMutation(
            "virtualMachineNetworkRename",
            "vmm.network.rename.behavior-unverified",
        )
    }

    suspend fun deleteVirtualMachineNetworkResult(id: String): MutationResult {
        if (id.trim().isEmpty()) return serviceMutationResult(
            operation = "virtualMachineNetworkDelete",
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "vmm.network.delete.invalid-input",
        )
        return unsupportedServiceMutation(
            "virtualMachineNetworkDelete",
            "vmm.network.delete.behavior-unverified",
        )
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

    suspend fun chatConversations(): List<ChatConversation> {
        val users = runCatching { chatUsers().associateBy(ChatUser::id) }.getOrDefault(emptyMap())
        val data = call("SYNO.Chat.Channel", "list")
        return sequenceOf("channels", "channel_list", "items")
            .flatMap { data.elements(it).asSequence() }
            .distinctBy { (it as? JsonObject)?.string("channel_id") ?: it.toString() }
            .mapNotNull { element ->
                val item = element as? JsonObject ?: return@mapNotNull null
                val id = item.valueString("channel_id", "id") ?: return@mapNotNull null
                val memberIds = (item.elements("members") + item.elements("user_ids"))
                    .mapNotNull { member ->
                    (member as? JsonObject)?.valueString("user_id", "member_id", "id")
                        ?: (member as? JsonPrimitive)?.contentOrNull
                    }.distinct()
                val rawName = item.string("name") ?: item.string("channel_name").orEmpty()
                val normalizedType = (item.string("type") ?: item.string("channel_type"))
                    .orEmpty()
                    .lowercase()
                val direct = normalizedType in setOf("direct", "anonymous") ||
                    (rawName.isBlank() && memberIds.size <= 2 && normalizedType != "chatbot")
                val lastPost = item.objectValue("last_post")
                ChatConversation(
                    id = id,
                    title = rawName.ifBlank {
                        memberIds.mapNotNull { users[it]?.displayName }.joinToString("、")
                    },
                    kind = if (direct) {
                        ConversationKind.DIRECT
                    } else {
                        ConversationKind.GROUP
                    },
                    memberIds = memberIds,
                    unreadCount = item.int("unread") ?: item.int("unread_count") ?: 0,
                    memberCount = item.int("member_count") ?: memberIds.size,
                    latestPreview = lastPost?.string("message") ?: item.string("last_message"),
                    latestAtEpochSeconds = normalizeEpoch(
                        lastPost?.long("create_at") ?: item.long("last_update_at") ?: item.long("time"),
                    ),
                )
            }
            .toList()
    }

    suspend fun chatUsers(): List<ChatUser> {
        val data = call("SYNO.Chat.User", "list")
        data.valueString("current_user_id", "current_id", "my_user_id")?.let {
            currentChatUserId = it
        }
        val users = sequenceOf("users", "user_list", "items")
            .flatMap { data.elements(it).asSequence() }
            .distinctBy { (it as? JsonObject)?.valueString("user_id", "id") }
            .mapNotNull { element ->
                val item = element as? JsonObject ?: return@mapNotNull null
                val id = item.valueString("user_id", "id", "uid") ?: return@mapNotNull null
                if (item.bool("is_current") == true || item.bool("is_me") == true ||
                    item.firstNonBlank("username", "account", "name")
                        ?.equals(profile.username, ignoreCase = true) == true
                ) {
                    currentChatUserId = id
                }
                ChatUser(
                    id = id,
                    displayName = item.firstNonBlank("nickname", "display_name", "name", "username") ?: id,
                    username = item.firstNonBlank("username", "account", "name") ?: "",
                    isDisabled = item.bool("disabled") ?: item.bool("is_disabled") ?: false,
                    isCurrent = id == currentChatUserId,
                )
            }
            .toList()
        return users
    }

    suspend fun chatMessages(
        conversationId: String,
        offset: Int = 0,
        limit: Int = 50,
    ): ChatMessagePage {
        require(conversationId.isNotBlank())
        require(offset >= 0)
        val safeLimit = limit.coerceIn(1, 100)
        val data = call(
            "SYNO.Chat.Post",
            "list",
            mapOf(
                "channel_id" to conversationId,
                "offset" to offset.toString(),
                "limit" to safeLimit.toString(),
            ),
        )
        val rawPosts = data.elements("posts")
        val messages = rawPosts.mapNotNull { element ->
            val item = element as? JsonObject ?: return@mapNotNull null
            val id = item.valueString("post_id", "id") ?: return@mapNotNull null
            val creator = item.objectValue("creator") ?: item.objectValue("user") ?: item.objectValue("sender")
            val senderId = item.firstNonBlank("creator_id", "user_id", "sender_id")
                ?: creator?.valueString("user_id", "id")
                ?: "unknown"
            val senderName = item.firstNonBlank("creator_name", "sender_name", "nickname", "username")
                ?: creator?.firstNonBlank("nickname", "display_name", "name", "username")
            val body = item.string("message") ?: item.string("text") ?: item.string("content").orEmpty()
            val attachments = item.elements("files").ifEmpty { item.elements("attachments") }
                .mapIndexedNotNull { index, value ->
                    val file = value as? JsonObject ?: return@mapIndexedNotNull null
                    ChatAttachment(
                        id = file.valueString("file_id", "id") ?: "$id-$index",
                        name = file.firstNonBlank("name", "file_name", "filename")
                            ?: return@mapIndexedNotNull null,
                        mimeType = file.string("mime_type") ?: file.string("type"),
                        size = file.long("size") ?: file.long("file_size"),
                    )
                }
            val poll = chatPoll(item, id)
            if (body.isBlank() && attachments.isEmpty() && poll == null) return@mapNotNull null
            ChatMessage(
                id = id,
                conversationId = item.valueString("channel_id", "conversation_id") ?: conversationId,
                sender = ChatUser(senderId, senderName ?: senderId, ""),
                body = body,
                createdAtEpochSeconds = normalizeEpoch(
                    item.long("create_at") ?: item.long("created_at") ?: item.long("timestamp"),
                ) ?: 0,
                isMine = item.bool("is_my_post") ?: item.bool("is_mine") ?: (senderId == currentChatUserId),
                attachments = attachments,
                isPinned = (item.long("last_pin_at") ?: 0) > 0,
                poll = poll,
            )
        }.sortedBy(ChatMessage::createdAtEpochSeconds)
        val next = offset + rawPosts.size
        val total = data.int("total")
        val hasMore = total?.let { next < it } ?: (rawPosts.size == safeLimit)
        return ChatMessagePage(messages, next.takeIf { hasMore }, hasMore)
    }

    suspend fun openDirectChatConversation(
        userId: String,
        clientRequestId: String,
    ): ChatConversation {
        val outcome = openDirectChatConversationResult(userId, clientRequestId)
        outcome.conversation?.takeIf {
            outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS
        }?.let { return it }
        throw chatConversationResultFailure(outcome.result)
    }

    suspend fun openDirectChatConversationResult(
        userId: String,
        clientRequestId: String,
    ): ChatConversationMutationOutcome {
        val operation = "chatDirectCreate"
        val normalizedUserId = userId.trim()
        if (normalizedUserId.isEmpty() || clientRequestId.isBlank()) {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.VALIDATION,
                    diagnosticTag = "chat.conversation.direct.invalid-input",
                ),
            )
        }
        chatConversationMutationLock.withLock {
            completedDirectConversations[clientRequestId]
        }?.let {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "chat.conversation.direct.cached-success",
                ),
                it,
            )
        }
        if (!supportsVersion(CHAT_CHANNEL_ANONYMOUS_API, 2)) {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.UNSUPPORTED,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.UNSUPPORTED,
                    diagnosticTag = "chat.conversation.direct.unsupported",
                ),
            )
        }
        if (!currentCoroutineContext().isActive) {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "chat.conversation.direct.cancelled-before-submission",
                ),
            )
        }
        val targetKey = "direct\u0000$normalizedUserId"
        val claimed = chatConversationMutationLock.withLock {
            if (clientRequestId in activeChatConversationRequestIds ||
                targetKey in activeChatConversationTargets
            ) {
                false
            } else {
                activeChatConversationRequestIds.add(clientRequestId)
                activeChatConversationTargets.add(targetKey)
                true
            }
        }
        if (!claimed) {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "chat.conversation.direct.duplicate-submission",
                ),
            )
        }
        try {
            chatConversationMutationLock.withLock {
                completedDirectConversations[clientRequestId]
            }?.let {
                return ChatConversationMutationOutcome(
                    chatConversationMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.conversation.direct.cached-after-claim",
                    ),
                    it,
                )
            }
            val before = try {
                chatConversations()
            } catch (failure: Exception) {
                return ChatConversationMutationOutcome(
                    chatConversationPreflightFailure(operation, "direct", failure),
                )
            }
            before.firstOrNull {
                it.kind == ConversationKind.DIRECT && normalizedUserId in it.memberIds
            }?.let { existing ->
                chatConversationMutationLock.withLock {
                    completedDirectConversations[clientRequestId] = existing
                }
                return ChatConversationMutationOutcome(
                    chatConversationMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.conversation.direct.already-exists",
                    ),
                    existing,
                    before,
                )
            }
            val writeFailure = try {
                call(
                    CHAT_CHANNEL_ANONYMOUS_API,
                    "initiate",
                    mapOf(
                        "user_ids" to jsonStringArray(listOf(normalizedUserId)),
                        "encrypted" to "false",
                        "channel_key_encs" to "[]",
                    ),
                    version = 2,
                )
                null
            } catch (failure: Exception) {
                failure
            }
            val after = withContext(NonCancellable) {
                runCatching { chatConversations() }.getOrNull()
            }
            val verified = after?.firstOrNull {
                it.kind == ConversationKind.DIRECT && normalizedUserId in it.memberIds
            }
            if (verified != null) {
                withContext(NonCancellable) {
                    chatConversationMutationLock.withLock {
                        completedDirectConversations[clientRequestId] = verified
                    }
                }
                return ChatConversationMutationOutcome(
                    chatConversationMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = if (writeFailure == null) {
                            "chat.conversation.direct.confirmed-success"
                        } else {
                            "chat.conversation.direct.confirmed-after-error"
                        },
                    ),
                    verified,
                    after,
                )
            }
            return ChatConversationMutationOutcome(
                chatConversationSubmissionResult(operation, "direct", writeFailure),
                conversations = after,
            )
        } finally {
            withContext(NonCancellable) {
                chatConversationMutationLock.withLock {
                    activeChatConversationRequestIds.remove(clientRequestId)
                    activeChatConversationTargets.remove(targetKey)
                }
            }
        }
    }

    suspend fun createPrivateChatGroup(
        title: String,
        memberIds: List<String>,
        clientRequestId: String,
    ): ChatConversation {
        val outcome = createPrivateChatGroupResult(title, memberIds, clientRequestId)
        outcome.conversation?.takeIf {
            outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS
        }?.let { return it }
        throw chatConversationResultFailure(outcome.result)
    }

    suspend fun createPrivateChatGroupResult(
        title: String,
        memberIds: List<String>,
        clientRequestId: String,
    ): ChatConversationMutationOutcome {
        val operation = "chatGroupCreate"
        val normalizedTitle = title.trim()
        val normalizedMembers = memberIds.map(String::trim).filter(String::isNotEmpty).distinct().sorted()
        if (normalizedTitle.isEmpty() || normalizedTitle.length > MAX_CHAT_GROUP_TITLE_CHARACTERS ||
            normalizedMembers.size < 2 || clientRequestId.isBlank()
        ) {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.VALIDATION,
                    diagnosticTag = "chat.conversation.group.invalid-input",
                ),
            )
        }
        chatConversationMutationLock.withLock {
            completedGroupConversations[clientRequestId]
        }?.let {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "chat.conversation.group.cached-success",
                ),
                it,
            )
        }
        if (!supportsVersion(CHAT_CHANNEL_NAMED_API, 1) ||
            !supportsVersion(CHAT_CHANNEL_MEMBER_API, 1)
        ) {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.UNSUPPORTED,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.UNSUPPORTED,
                    diagnosticTag = "chat.conversation.group.unsupported",
                ),
            )
        }
        if (!currentCoroutineContext().isActive) {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "chat.conversation.group.cancelled-before-submission",
                ),
            )
        }
        val targetKey = "group\u0000$normalizedTitle\u0000${normalizedMembers.joinToString("\u0001")}"
        val claimed = chatConversationMutationLock.withLock {
            if (clientRequestId in activeChatConversationRequestIds ||
                targetKey in activeChatConversationTargets
            ) {
                false
            } else {
                activeChatConversationRequestIds.add(clientRequestId)
                activeChatConversationTargets.add(targetKey)
                true
            }
        }
        if (!claimed) {
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "chat.conversation.group.duplicate-submission",
                ),
            )
        }
        try {
            chatConversationMutationLock.withLock {
                completedGroupConversations[clientRequestId]
            }?.let {
                return ChatConversationMutationOutcome(
                    chatConversationMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.conversation.group.cached-after-claim",
                    ),
                    it,
                )
            }
            val before = try {
                chatConversations()
            } catch (failure: Exception) {
                return ChatConversationMutationOutcome(
                    chatConversationPreflightFailure(operation, "group", failure),
                )
            }
            before.firstOrNull {
                it.kind == ConversationKind.GROUP && it.title == normalizedTitle &&
                    it.memberIds.containsAll(normalizedMembers)
            }?.let { existing ->
                chatConversationMutationLock.withLock {
                    completedGroupConversations[clientRequestId] = existing
                }
                return ChatConversationMutationOutcome(
                    chatConversationMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.conversation.group.already-exists",
                    ),
                    existing,
                    before,
                )
            }
            var pendingChannelId = chatConversationMutationLock.withLock {
                pendingChatGroupChannelIds[targetKey]
            }
            if (pendingChannelId != null && before.none { it.id == pendingChannelId }) {
                chatConversationMutationLock.withLock {
                    pendingChatGroupChannelIds.remove(targetKey)
                }
                pendingChannelId = null
            }
            var channelId = pendingChannelId
            var stageFailure: Exception? = null
            var conversationsAfterCreate: List<ChatConversation>? = null
            if (channelId == null) {
                var createFailure: Exception? = null
                val created = try {
                    call(
                        CHAT_CHANNEL_NAMED_API,
                        "create",
                        mapOf("name" to normalizedTitle, "type" to "private"),
                        version = 1,
                    )
                } catch (failure: Exception) {
                    createFailure = failure
                    null
                }
                channelId = created?.valueString("channel_id", "id")
                    ?: created?.objectValue("channel")?.valueString("channel_id", "id")
                if (channelId == null) {
                    val afterCreate = withContext(NonCancellable) {
                        runCatching { chatConversations() }.getOrNull()
                    }
                    conversationsAfterCreate = afterCreate
                    val beforeIds = before.map(ChatConversation::id).toSet()
                    val candidates = afterCreate.orEmpty().filter {
                        it.kind == ConversationKind.GROUP && it.title == normalizedTitle &&
                            it.id !in beforeIds
                    }
                    channelId = candidates.singleOrNull()?.id
                    if (channelId == null) {
                        return ChatConversationMutationOutcome(
                            chatConversationSubmissionResult(operation, "group-create", createFailure),
                            conversations = afterCreate,
                        )
                    }
                }
                withContext(NonCancellable) {
                    chatConversationMutationLock.withLock {
                        pendingChatGroupChannelIds[targetKey] = channelId
                    }
                }
                if (createFailure is CancellationException || !currentCoroutineContext().isActive) {
                    stageFailure = (createFailure as? CancellationException)
                        ?: CancellationException("Chat group creation was cancelled after submission")
                } else {
                    val joinFailure = try {
                        call(
                            CHAT_CHANNEL_NAMED_API,
                            "join",
                            mapOf("channel_id" to channelId),
                            version = 1,
                        )
                        null
                    } catch (failure: Exception) {
                        if ((failure as? DsmFailure)?.code == 117) null else failure
                    }
                    if (joinFailure != null) {
                        stageFailure = joinFailure
                    }
                }
            }
            val stableChannelId = requireNotNull(channelId)
            val membersBeforeInvite = if (stageFailure != null) {
                emptySet()
            } else if (pendingChannelId != null) {
                try {
                    chatConversationMembers(stableChannelId).map(ChatUser::id).toSet()
                } catch (failure: Exception) {
                    return ChatConversationMutationOutcome(
                        chatConversationSubmittedReadbackFailure(
                            operation,
                            "group-members-preflight",
                            failure,
                        ),
                    )
                }
            } else {
                emptySet()
            }
            var inviteFailure: Exception? = stageFailure
            if (stageFailure == null && !membersBeforeInvite.containsAll(normalizedMembers)) {
                inviteFailure = try {
                    call(
                        CHAT_CHANNEL_NAMED_API,
                        "invite",
                        mapOf(
                            "channel_id" to stableChannelId,
                            "user_ids" to jsonStringArray(normalizedMembers.filterNot(membersBeforeInvite::contains)),
                            "channel_key_encs" to "[]",
                        ),
                        version = 1,
                    )
                    null
                } catch (failure: Exception) {
                    failure
                }
            }
            val finalState = withContext(NonCancellable) {
                val conversations = conversationsAfterCreate
                    ?: runCatching { chatConversations() }.getOrNull()
                val members = runCatching {
                    chatConversationMembers(stableChannelId).map(ChatUser::id).toSet()
                }.getOrNull()
                conversations to members
            }
            val conversations = finalState.first
            val verifiedMembers = finalState.second
            val conversation = conversations?.firstOrNull { it.id == stableChannelId }
            if (conversation == null || verifiedMembers == null) {
                return ChatConversationMutationOutcome(
                    chatConversationSubmissionResult(operation, "group-readback", inviteFailure),
                    conversations = conversations,
                )
            }
            if (!verifiedMembers.containsAll(normalizedMembers)) {
                val missingCount = normalizedMembers.count { it !in verifiedMembers }
                return ChatConversationMutationOutcome(
                    chatConversationMutationResult(
                        operation,
                        MutationResultStatus.PARTIAL_SUCCESS,
                        submitted = true,
                        requiresRefresh = true,
                        succeeded = 1,
                        failed = if (inviteFailure is DsmFailure) missingCount else 0,
                        unknown = if (inviteFailure is DsmFailure) 0 else missingCount,
                        errorCategory = (inviteFailure as? DsmFailure)?.let(::fileMutationErrorCategory),
                        diagnosticTag = "chat.conversation.group.members-incomplete",
                    ),
                    conversation = conversation.copy(
                        memberIds = verifiedMembers.sorted(),
                        memberCount = verifiedMembers.size,
                    ),
                    conversations = conversations,
                )
            }
            val verified = conversation.copy(
                memberIds = verifiedMembers.sorted(),
                memberCount = verifiedMembers.size,
            )
            withContext(NonCancellable) {
                chatConversationMutationLock.withLock {
                    completedGroupConversations[clientRequestId] = verified
                    pendingChatGroupChannelIds.remove(targetKey)
                }
            }
            return ChatConversationMutationOutcome(
                chatConversationMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = if (inviteFailure == null) {
                        "chat.conversation.group.confirmed-success"
                    } else {
                        "chat.conversation.group.confirmed-after-error"
                    },
                ),
                verified,
                conversations,
            )
        } finally {
            withContext(NonCancellable) {
                chatConversationMutationLock.withLock {
                    activeChatConversationRequestIds.remove(clientRequestId)
                    activeChatConversationTargets.remove(targetKey)
                }
            }
        }
    }

    suspend fun chatConversationMembers(conversationId: String): List<ChatUser> {
        val normalizedId = conversationId.trim()
        if (normalizedId.isEmpty()) throw invalidChatConversationRequest()
        if (!supportsVersion(CHAT_CHANNEL_MEMBER_API, 1)) throw unsupportedChatConversationMutation()
        val data = call(
            CHAT_CHANNEL_MEMBER_API,
            "get",
            mapOf("channel_id" to normalizedId),
            version = 1,
        )
        val ids = data.elements("user_ids").mapNotNull { (it as? JsonPrimitive)?.contentOrNull }.distinct()
        if (ids.isEmpty()) return emptyList()
        val users = chatUsers().associateBy(ChatUser::id)
        return ids.mapNotNull(users::get)
    }

    private suspend fun findDirectChatConversation(userId: String): ChatConversation? =
        chatConversations().firstOrNull {
            it.kind == ConversationKind.DIRECT && userId in it.memberIds
        }

    private suspend fun findMatchingChatGroup(
        title: String,
        memberIds: List<String>,
    ): ChatConversation? = chatConversations().firstOrNull {
        it.kind == ConversationKind.GROUP && it.title == title && it.memberIds.containsAll(memberIds)
    }

    private suspend fun readChatMemberIdsOrEmpty(conversationId: String): Set<String> = try {
        chatConversationMembers(conversationId).map(ChatUser::id).toSet()
    } catch (error: CancellationException) {
        throw error
    } catch (_: Throwable) {
        emptySet()
    }

    private suspend fun chatConversationPreflightFailure(
        operation: String,
        action: String,
        failure: Exception,
    ): MutationResult {
        if (failure is CancellationException || !currentCoroutineContext().isActive) {
            return chatConversationMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "chat.conversation.$action.cancelled-during-preflight",
            )
        }
        val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
            ?: MutationErrorCategory.UNKNOWN
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return chatConversationMutationResult(
            operation,
            status,
            submitted = false,
            failed = 1,
            errorCategory = category,
            diagnosticTag = "chat.conversation.$action.preflight-failed",
        )
    }

    private suspend fun chatConversationSubmittedReadbackFailure(
        operation: String,
        action: String,
        failure: Exception,
    ): MutationResult {
        if (failure is CancellationException || !currentCoroutineContext().isActive) {
            return chatConversationMutationResult(
                operation,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                submitted = true,
                requiresRefresh = true,
                unknown = 1,
                diagnosticTag = "chat.conversation.$action.cancelled-after-submission",
            )
        }
        val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
            ?: MutationErrorCategory.UNKNOWN
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            else -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
        }
        return chatConversationMutationResult(
            operation,
            status,
            submitted = true,
            requiresRefresh = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            failed = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 0 else 1,
            unknown = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 1 else 0,
            errorCategory = category,
            diagnosticTag = "chat.conversation.$action.readback-failed",
        )
    }

    private suspend fun chatConversationSubmissionResult(
        operation: String,
        action: String,
        failure: Exception?,
    ): MutationResult {
        if (failure is CancellationException || !currentCoroutineContext().isActive) {
            return chatConversationMutationResult(
                operation,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                submitted = true,
                requiresRefresh = true,
                unknown = 1,
                diagnosticTag = "chat.conversation.$action.cancelled-after-submission",
            )
        }
        val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
            ?: if (failure == null) MutationErrorCategory.SERVER else MutationErrorCategory.UNKNOWN
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            MutationErrorCategory.NETWORK,
            MutationErrorCategory.UNKNOWN,
            MutationErrorCategory.SERVER,
            -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return chatConversationMutationResult(
            operation,
            status,
            submitted = true,
            requiresRefresh = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            failed = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 0 else 1,
            unknown = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 1 else 0,
            errorCategory = category,
            diagnosticTag = "chat.conversation.$action.submission-unconfirmed",
        )
    }

    private fun chatConversationMutationResult(
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
        localizationKey = "mutation.chat_conversation.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private fun chatConversationResultFailure(result: MutationResult): Exception {
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            return invalidChatConversationRequest()
        }
        if (result.status == MutationResultStatus.CANCELLED_BEFORE_SUBMISSION ||
            result.status == MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
        ) return CancellationException("chat conversation mutation cancelled")
        return DsmFailure(
            null,
            "The NAS did not confirm the conversation change",
            "Refresh conversations before deciding whether to try again.",
            kind = when (result.status) {
                MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
            },
        )
    }

    private fun jsonStringArray(values: List<String>): String =
        JsonArray(values.map(::JsonPrimitive)).toString()

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

    private fun duplicateChatConversationMutation() = DsmFailure(
        null,
        "This conversation action is already running",
        "Wait for the current attempt to finish.",
        kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
    )

    private fun unconfirmedChatConversationMutation(message: String, recovery: String) = DsmFailure(
        null,
        message,
        recovery,
        kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
    )

    /** 客户端请求 ID 仅用于本进程防重复，不发送给 NAS，也不持久化。 */
    suspend fun sendChatTextMessage(
        conversationId: String,
        text: String,
        clientRequestId: String,
    ): ChatMessage {
        val outcome = sendChatTextMessageResult(conversationId, text, clientRequestId)
        outcome.message?.takeIf {
            outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS
        }?.let { return it }
        if (outcome.result.errorCategory == MutationErrorCategory.VALIDATION) {
            throw IllegalArgumentException("Invalid chat message")
        }
        when (outcome.result.status) {
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> throw CancellationException("chat message send cancelled")
            else -> throw DsmFailure(
                null,
                "The NAS did not confirm the sent message",
                "Refresh the conversation before deciding whether to retry.",
                kind = when (outcome.result.status) {
                    MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                    MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                    else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
                },
            )
        }
    }

    suspend fun sendChatTextMessageResult(
        conversationId: String,
        text: String,
        clientRequestId: String,
    ): ChatTextMutationOutcome {
        val operation = "chatTextSend"
        val normalizedConversationId = conversationId.trim()
        val normalizedText = text.trim()
        if (normalizedConversationId.isBlank() || normalizedText.isBlank() ||
            normalizedText.length > MAX_CHAT_MESSAGE_CHARACTERS || clientRequestId.isBlank()
        ) {
            return ChatTextMutationOutcome(
                chatTextMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.VALIDATION,
                    diagnosticTag = "chat.text.send.invalid-input",
                ),
            )
        }
        chatSendLock.withLock { completedChatMessages[clientRequestId] }?.let {
            return ChatTextMutationOutcome(
                chatTextMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "chat.text.send.cached-success",
                ),
                it,
            )
        }
        if (!supportsVersion("SYNO.Chat.Post", CHAT_POST_CREATE_VERSION)) {
            return ChatTextMutationOutcome(
                chatTextMutationResult(
                    operation,
                    MutationResultStatus.UNSUPPORTED,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.UNSUPPORTED,
                    diagnosticTag = "chat.text.send.unsupported",
                ),
            )
        }
        if (!currentCoroutineContext().isActive) {
            return ChatTextMutationOutcome(
                chatTextMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "chat.text.send.cancelled-before-submission",
                ),
            )
        }
        val claimed = chatSendLock.withLock { activeChatSendRequestIds.add(clientRequestId) }
        if (!claimed) {
            return ChatTextMutationOutcome(
                chatTextMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "chat.text.send.duplicate-submission",
                ),
            )
        }
        try {
            chatSendLock.withLock { completedChatMessages[clientRequestId] }?.let {
                return ChatTextMutationOutcome(
                    chatTextMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.text.send.cached-after-claim",
                    ),
                    it,
                )
            }
            val submittedAt = System.currentTimeMillis() / 1_000
            val data = try {
                call(
                    "SYNO.Chat.Post",
                    "create",
                    mapOf("channel_id" to normalizedConversationId, "message" to normalizedText),
                    version = CHAT_POST_CREATE_VERSION,
                )
            } catch (failure: Exception) {
                val recovered = withContext(NonCancellable) {
                    runCatching {
                        findRecentlySentChatMessage(
                            normalizedConversationId,
                            normalizedText,
                            submittedAt,
                        )
                    }.getOrNull()
                }
                if (recovered != null) {
                    val confirmed = recovered.copy(clientRequestId = clientRequestId)
                    chatSendLock.withLock { completedChatMessages[clientRequestId] = confirmed }
                    return ChatTextMutationOutcome(
                        chatTextMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_SUCCESS,
                            submitted = true,
                            succeeded = 1,
                            diagnosticTag = "chat.text.send.confirmed-after-error",
                        ),
                        confirmed,
                    )
                }
                if (failure is CancellationException) {
                    return ChatTextMutationOutcome(
                        chatTextMutationResult(
                            operation,
                            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                            submitted = true,
                            requiresRefresh = true,
                            unknown = 1,
                            diagnosticTag = "chat.text.send.cancelled-after-submission",
                        ),
                    )
                }
                val dsmFailure = failure as? DsmFailure
                val category = dsmFailure?.let(::fileMutationErrorCategory)
                    ?: MutationErrorCategory.UNKNOWN
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
                return ChatTextMutationOutcome(
                    chatTextMutationResult(
                        operation,
                        status,
                        submitted = true,
                        requiresRefresh = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        failed = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 0 else 1,
                        unknown = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 1 else 0,
                        errorCategory = category,
                        diagnosticTag = "chat.text.send.submission-failed",
                    ),
                )
            }
            val post = data.objectValue("post") ?: data
            val id = post.valueString("post_id", "id")
            val message = if (id != null) {
                ChatMessage(
                    id = id,
                    conversationId = post.valueString("channel_id", "conversation_id")
                        ?: normalizedConversationId,
                    sender = ChatUser("current", profile.username, profile.username),
                    body = post.string("message") ?: post.string("text") ?: normalizedText,
                    createdAtEpochSeconds = normalizeEpoch(
                        post.long("create_at") ?: post.long("created_at") ?: post.long("timestamp"),
                    ) ?: submittedAt,
                    isMine = true,
                    clientRequestId = clientRequestId,
                    deliveryState = ChatDeliveryState.SENT,
                )
            } else {
                withContext(NonCancellable) {
                    runCatching {
                        findRecentlySentChatMessage(
                            normalizedConversationId,
                            normalizedText,
                            submittedAt,
                        )
                    }.getOrNull()
                }?.copy(clientRequestId = clientRequestId)
            }
            if (message == null) {
                return ChatTextMutationOutcome(
                    chatTextMutationResult(
                        operation,
                        MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        errorCategory = MutationErrorCategory.SERVER,
                        diagnosticTag = "chat.text.send.response-unverified",
                    ),
                )
            }
            chatSendLock.withLock { completedChatMessages[clientRequestId] = message }
            return ChatTextMutationOutcome(
                chatTextMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "chat.text.send.confirmed-success",
                ),
                message,
            )
        } finally {
            chatSendLock.withLock { activeChatSendRequestIds.remove(clientRequestId) }
        }
    }

    private suspend fun findRecentlySentChatMessage(
        conversationId: String,
        text: String,
        submittedAt: Long,
    ): ChatMessage? = chatMessages(conversationId, 0, 50).messages.firstOrNull { message ->
        message.isMine && message.body == text && message.createdAtEpochSeconds > 0 &&
            message.createdAtEpochSeconds in
            (submittedAt - CHAT_SEND_READBACK_CLOCK_SKEW_SECONDS)..
            (submittedAt + CHAT_SEND_READBACK_WINDOW_SECONDS)
    }

    private fun chatTextMutationResult(
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
        localizationKey = "mutation.chat_text_send.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    suspend fun sendChatAttachmentMessage(
        conversationId: String,
        text: String,
        source: UploadSource,
        clientRequestId: String,
        onProgress: (Long, Long) -> Unit,
    ): ChatMessage {
        val outcome = sendChatAttachmentMessageResult(
            conversationId,
            text,
            source,
            clientRequestId,
            onProgress,
        )
        outcome.message?.takeIf {
            outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS
        }?.let { return it }
        if (outcome.result.errorCategory == MutationErrorCategory.VALIDATION) {
            throw IllegalArgumentException("Invalid chat attachment")
        }
        when (outcome.result.status) {
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> throw CancellationException("chat attachment send cancelled")
            else -> throw DsmFailure(
                null,
                "The NAS did not confirm the attachment",
                "Refresh the conversation before deciding whether to retry.",
                kind = when (outcome.result.status) {
                    MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                    MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                    else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
                },
            )
        }
    }

    suspend fun sendChatAttachmentMessageResult(
        conversationId: String,
        text: String,
        source: UploadSource,
        clientRequestId: String,
        onProgress: (Long, Long) -> Unit,
    ): ChatAttachmentMutationOutcome {
        val operation = "chatAttachmentSend"
        val normalizedConversationId = conversationId.trim()
        val normalizedText = text.trim()
        if (normalizedConversationId.isBlank() || clientRequestId.isBlank() ||
            normalizedText.length > MAX_CHAT_MESSAGE_CHARACTERS || source.displayName.isBlank() ||
            '/' in source.displayName || '\\' in source.displayName || source.contentLength < 0
        ) return ChatAttachmentMutationOutcome(
            chatAttachmentMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "chat.attachment.send.invalid-input",
            ),
        )
        chatSendLock.withLock { completedChatMessages[clientRequestId] }?.let {
            return ChatAttachmentMutationOutcome(
                chatAttachmentMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "chat.attachment.send.cached-success",
                ),
                it,
            )
        }
        val capability = capabilities["SYNO.Chat.Post"]
        if (capability == null || !supportsVersion("SYNO.Chat.Post", CHAT_POST_CREATE_VERSION)) {
            return ChatAttachmentMutationOutcome(
                chatAttachmentMutationResult(
                    operation,
                    MutationResultStatus.UNSUPPORTED,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.UNSUPPORTED,
                    diagnosticTag = "chat.attachment.send.unsupported",
                ),
            )
        }
        if (!currentCoroutineContext().isActive) {
            return ChatAttachmentMutationOutcome(
                chatAttachmentMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "chat.attachment.send.cancelled-before-submission",
                ),
            )
        }
        val claimed = chatSendLock.withLock { activeChatSendRequestIds.add(clientRequestId) }
        if (!claimed) return ChatAttachmentMutationOutcome(
            chatAttachmentMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "chat.attachment.send.duplicate-submission",
            ),
        )
        try {
            chatSendLock.withLock { completedChatMessages[clientRequestId] }?.let {
                return ChatAttachmentMutationOutcome(
                    chatAttachmentMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.attachment.send.cached-after-claim",
                    ),
                    it,
                )
            }
            val submittedAt = System.currentTimeMillis() / 1_000
            var uploadedBytes = 0L
            val data = try {
                api.uploadChatAttachment(
                    profile = profile,
                    session = session,
                    capability = capability,
                    conversationId = normalizedConversationId,
                    message = normalizedText,
                    filename = source.displayName,
                    contentType = source.contentType,
                    contentLength = source.contentLength,
                    openInputStream = source.openInputStream,
                ) { completed, total ->
                    uploadedBytes = maxOf(uploadedBytes, completed)
                    onProgress(completed, total)
                }
            } catch (failure: Exception) {
                val uploadCompleted = uploadedBytes >= source.contentLength
                val recovered = if (uploadCompleted) withContext(NonCancellable) {
                    runCatching {
                        findRecentlySentChatAttachment(
                            normalizedConversationId,
                            normalizedText,
                            source.displayName,
                            submittedAt,
                        )
                    }.getOrNull()
                } else null
                if (recovered != null) {
                    val confirmed = recovered.copy(clientRequestId = clientRequestId)
                    chatSendLock.withLock { completedChatMessages[clientRequestId] = confirmed }
                    return ChatAttachmentMutationOutcome(
                        chatAttachmentMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_SUCCESS,
                            submitted = true,
                            succeeded = 1,
                            diagnosticTag = "chat.attachment.send.confirmed-after-error",
                        ),
                        confirmed,
                    )
                }
                if (failure is CancellationException || !currentCoroutineContext().isActive) {
                    val status = if (uploadCompleted) {
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    } else {
                        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION
                    }
                    return ChatAttachmentMutationOutcome(
                        chatAttachmentMutationResult(
                            operation,
                            status,
                            submitted = uploadCompleted,
                            requiresRefresh = uploadCompleted,
                            unknown = if (uploadCompleted) 1 else 0,
                            diagnosticTag = if (uploadCompleted) {
                                "chat.attachment.send.cancelled-after-upload"
                            } else {
                                "chat.attachment.send.cancelled-during-upload"
                            },
                        ),
                    )
                }
                val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
                    ?: MutationErrorCategory.UNKNOWN
                if (!uploadCompleted) {
                    return ChatAttachmentMutationOutcome(
                        chatAttachmentMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_FAILURE,
                            submitted = false,
                            failed = 1,
                            errorCategory = category,
                            diagnosticTag = "chat.attachment.send.upload-failed",
                        ),
                    )
                }
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
                return ChatAttachmentMutationOutcome(
                    chatAttachmentMutationResult(
                        operation,
                        status,
                        submitted = true,
                        requiresRefresh = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                        failed = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 0 else 1,
                        unknown = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 1 else 0,
                        errorCategory = category,
                        diagnosticTag = "chat.attachment.send.submission-failed",
                    ),
                )
            }
            val post = data.objectValue("post") ?: data
            val id = post.valueString("post_id", "id")
            val parsed = if (id != null) {
                ChatMessage(
                    id = id,
                    conversationId = post.valueString("channel_id", "conversation_id")
                        ?: normalizedConversationId,
                    sender = ChatUser("current", profile.username, profile.username, isCurrent = true),
                    body = post.string("message") ?: post.string("text") ?: normalizedText,
                    createdAtEpochSeconds = normalizeEpoch(
                        post.long("create_at") ?: post.long("created_at") ?: post.long("timestamp"),
                    ) ?: System.currentTimeMillis() / 1_000,
                    isMine = true,
                    attachments = chatAttachments(post, id).ifEmpty {
                        listOf(ChatAttachment("local:$clientRequestId", source.displayName, source.contentType, source.contentLength))
                    },
                    clientRequestId = clientRequestId,
                    deliveryState = ChatDeliveryState.SENT,
                )
            } else {
                withContext(NonCancellable) {
                    runCatching {
                        findRecentlySentChatAttachment(
                            normalizedConversationId,
                            normalizedText,
                            source.displayName,
                            submittedAt,
                        )
                    }.getOrNull()
                }?.copy(clientRequestId = clientRequestId)
            }
            if (parsed == null) return ChatAttachmentMutationOutcome(
                chatAttachmentMutationResult(
                    operation,
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = MutationErrorCategory.SERVER,
                    diagnosticTag = "chat.attachment.send.response-unverified",
                ),
            )
            chatSendLock.withLock { completedChatMessages[clientRequestId] = parsed }
            return ChatAttachmentMutationOutcome(
                chatAttachmentMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "chat.attachment.send.confirmed-success",
                ),
                parsed,
            )
        } finally {
            chatSendLock.withLock { activeChatSendRequestIds.remove(clientRequestId) }
        }
    }

    private suspend fun findRecentlySentChatAttachment(
        conversationId: String,
        text: String,
        filename: String,
        submittedAt: Long,
    ): ChatMessage? = chatMessages(conversationId, 0, 50).messages.firstOrNull { message ->
        message.isMine && message.body == text &&
            message.attachments.any { it.name == filename } && message.createdAtEpochSeconds > 0 &&
            message.createdAtEpochSeconds in
            (submittedAt - CHAT_SEND_READBACK_CLOCK_SKEW_SECONDS)..
            (submittedAt + CHAT_ATTACHMENT_READBACK_WINDOW_SECONDS)
    }

    private fun chatAttachmentMutationResult(
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
        localizationKey = "mutation.chat_attachment_send.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    suspend fun chatAttachmentThumbnail(messageId: String): ByteArray {
        if (messageId.isBlank() || !supportsVersion(CHAT_POST_FILE_API, 2)) {
            throw unsupportedChatConversationMutation()
        }
        return api.readBinary(
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
        return api.downloadBinaryToOutput(
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
        return api.downloadBinaryToOutput(
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

    suspend fun chatReminders(conversationId: String): List<ChatReminder> {
        if (conversationId.isBlank() || !supportsVersion(CHAT_POST_REMINDER_API, 1)) {
            throw unsupportedChatConversationMutation()
        }
        val data = call(
            CHAT_POST_REMINDER_API,
            "list",
            mapOf("channel_id" to conversationId),
            version = 1,
        )
        val values = data.elements("posts").ifEmpty { data.elements("reminders") }
            .ifEmpty { data.elements("reminder_list") }
            .ifEmpty { data.elements("items") }
            .ifEmpty { data.elements("list") }
            .ifEmpty { data.elements("results") }
            .ifEmpty {
                if (data.valueString("post_id", "message_id") != null) listOf(data) else emptyList()
            }
        return values.mapNotNull { value ->
            val item = value as? JsonObject ?: return@mapNotNull null
            val messageId = item.valueString("post_id", "message_id") ?: return@mapNotNull null
            val props = item.objectValue("props")
            val rawTime = item.long("remind_at") ?: item.long("reminde_at")
                ?: item.long("reminder_at") ?: item.long("time")
                ?: props?.long("remind_at") ?: props?.long("reminde_at")
                ?: props?.long("reminder_at") ?: props?.long("time")
                ?: return@mapNotNull null
            val remindAt = normalizeEpochMillis(rawTime) ?: return@mapNotNull null
            ChatReminder(
                id = item.valueString("reminder_id", "id") ?: messageId,
                messageId = messageId,
                remindAtEpochMillis = remindAt,
            )
        }.distinctBy(ChatReminder::messageId).sortedBy(ChatReminder::remindAtEpochMillis)
    }

    suspend fun setChatReminder(
        conversationId: String,
        messageId: String,
        remindAtEpochMillis: Long,
        clientRequestId: String,
    ): ChatReminder {
        val outcome = setChatReminderResult(
            conversationId,
            messageId,
            remindAtEpochMillis,
            clientRequestId,
        )
        outcome.reminder?.takeIf {
            outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS
        }?.let { return it }
        throw chatReminderResultFailure(outcome.result)
    }

    suspend fun setChatReminderResult(
        conversationId: String,
        messageId: String,
        remindAtEpochMillis: Long,
        clientRequestId: String,
    ): ChatReminderMutationOutcome {
        val operation = "chatReminderSet"
        val normalizedConversationId = conversationId.trim()
        val normalizedMessageId = messageId.trim()
        val now = System.currentTimeMillis()
        if (normalizedConversationId.isBlank() || normalizedMessageId.isBlank() ||
            clientRequestId.isBlank() || remindAtEpochMillis <= now + MIN_CHAT_REMINDER_LEAD_MILLIS ||
            remindAtEpochMillis > now + MAX_CHAT_REMINDER_HORIZON_MILLIS
        ) return ChatReminderMutationOutcome(
            chatReminderMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "chat.reminder.set.invalid-input",
            ),
        )
        if (!supportsVersion(CHAT_POST_REMINDER_API, 1)) return ChatReminderMutationOutcome(
            chatReminderMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "chat.reminder.set.unsupported",
            ),
        )
        if (!currentCoroutineContext().isActive) return ChatReminderMutationOutcome(
            chatReminderMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "chat.reminder.set.cancelled-before-submission",
            ),
        )
        chatReminderMutationLock.withLock { completedChatReminders[clientRequestId] }
            ?.let {
                return ChatReminderMutationOutcome(
                    chatReminderMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.reminder.set.cached-success",
                    ),
                    reminder = it,
                )
            }
        val targetKey = chatReminderTargetKey(normalizedConversationId, normalizedMessageId)
        val claimed = chatReminderMutationLock.withLock {
            if (clientRequestId in activeChatReminderRequestIds ||
                targetKey in activeChatReminderTargets
            ) {
                false
            } else {
                activeChatReminderRequestIds.add(clientRequestId)
                activeChatReminderTargets.add(targetKey)
                true
            }
        }
        if (!claimed) return ChatReminderMutationOutcome(
            chatReminderMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "chat.reminder.set.duplicate-submission",
            ),
        )
        try {
            chatReminderMutationLock.withLock { completedChatReminders[clientRequestId] }
                ?.let {
                    return ChatReminderMutationOutcome(
                        chatReminderMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_SUCCESS,
                            submitted = true,
                            succeeded = 1,
                            diagnosticTag = "chat.reminder.set.cached-after-claim",
                        ),
                        reminder = it,
                    )
                }
            val before = try {
                chatReminders(normalizedConversationId)
            } catch (failure: Exception) {
                return ChatReminderMutationOutcome(
                    chatReminderPreflightFailure(operation, "set", failure),
                )
            }
            before.firstOrNull {
                it.messageId == normalizedMessageId &&
                    kotlin.math.abs(it.remindAtEpochMillis - remindAtEpochMillis) < 1_000
            }?.let {
                chatReminderMutationLock.withLock { completedChatReminders[clientRequestId] = it }
                return ChatReminderMutationOutcome(
                    chatReminderMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.reminder.set.already-matches",
                    ),
                    reminder = it,
                    reminders = before,
                )
            }
            val writeFailure = try {
                call(
                    CHAT_POST_REMINDER_API,
                    "set",
                    mapOf(
                        "post_id" to normalizedMessageId,
                        "remind_at" to remindAtEpochMillis.toString(),
                    ),
                    version = 1,
                )
                null
            } catch (failure: Exception) {
                failure
            }
            val after = withContext(NonCancellable) {
                runCatching { chatReminders(normalizedConversationId) }.getOrNull()
            }
            val confirmed = after?.firstOrNull {
                it.messageId == normalizedMessageId &&
                    kotlin.math.abs(it.remindAtEpochMillis - remindAtEpochMillis) < 1_000
            }
            if (confirmed != null) {
                chatReminderMutationLock.withLock {
                    completedChatReminders[clientRequestId] = confirmed
                }
                return ChatReminderMutationOutcome(
                    chatReminderMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = if (writeFailure == null) {
                            "chat.reminder.set.confirmed-success"
                        } else {
                            "chat.reminder.set.confirmed-after-error"
                        },
                    ),
                    reminder = confirmed,
                    reminders = after,
                )
            }
            return ChatReminderMutationOutcome(
                chatReminderSubmissionResult(operation, "set", writeFailure),
                reminders = after,
            )
        } finally {
            withContext(NonCancellable) {
                chatReminderMutationLock.withLock {
                    activeChatReminderRequestIds.remove(clientRequestId)
                    activeChatReminderTargets.remove(targetKey)
                }
            }
        }
    }

    suspend fun deleteChatReminder(
        conversationId: String,
        messageId: String,
        clientRequestId: String,
    ) {
        val outcome = deleteChatReminderResult(conversationId, messageId, clientRequestId)
        if (outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS) return
        throw chatReminderResultFailure(outcome.result)
    }

    suspend fun deleteChatReminderResult(
        conversationId: String,
        messageId: String,
        clientRequestId: String,
    ): ChatReminderMutationOutcome = deleteChatReminderResult(
        conversationId,
        messageId,
        clientRequestId,
        expectedBaseline = null,
    )

    suspend fun deleteChatReminderResult(
        conversationId: String,
        reminderBaseline: ChatReminder,
        clientRequestId: String,
    ): ChatReminderMutationOutcome = deleteChatReminderResult(
        conversationId,
        reminderBaseline.messageId,
        clientRequestId,
        expectedBaseline = reminderBaseline,
    )

    private suspend fun deleteChatReminderResult(
        conversationId: String,
        messageId: String,
        clientRequestId: String,
        expectedBaseline: ChatReminder?,
    ): ChatReminderMutationOutcome {
        val operation = "chatReminderDelete"
        val normalizedConversationId = conversationId.trim()
        val normalizedMessageId = messageId.trim()
        if (normalizedConversationId.isBlank() || normalizedMessageId.isBlank() ||
            clientRequestId.isBlank() || expectedBaseline?.let {
                it.id.isBlank() || it.messageId != normalizedMessageId
            } == true
        ) return ChatReminderMutationOutcome(
            chatReminderMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "chat.reminder.delete.invalid-input",
            ),
        )
        if (!supportsVersion(CHAT_POST_REMINDER_API, 1)) return ChatReminderMutationOutcome(
            chatReminderMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "chat.reminder.delete.unsupported",
            ),
        )
        if (!currentCoroutineContext().isActive) return ChatReminderMutationOutcome(
            chatReminderMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "chat.reminder.delete.cancelled-before-submission",
            ),
        )
        if (chatReminderMutationLock.withLock {
                clientRequestId in completedChatReminderDeletions
            }
        ) return ChatReminderMutationOutcome(
            chatReminderMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_SUCCESS,
                submitted = true,
                succeeded = 1,
                diagnosticTag = "chat.reminder.delete.cached-success",
            ),
        )
        val targetKey = chatReminderTargetKey(normalizedConversationId, normalizedMessageId)
        val claimed = chatReminderMutationLock.withLock {
            if (clientRequestId in activeChatReminderRequestIds ||
                targetKey in activeChatReminderTargets
            ) {
                false
            } else {
                activeChatReminderRequestIds.add(clientRequestId)
                activeChatReminderTargets.add(targetKey)
                true
            }
        }
        if (!claimed) return ChatReminderMutationOutcome(
            chatReminderMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "chat.reminder.delete.duplicate-submission",
            ),
        )
        try {
            if (chatReminderMutationLock.withLock {
                    clientRequestId in completedChatReminderDeletions
                }
            ) return ChatReminderMutationOutcome(
                chatReminderMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "chat.reminder.delete.cached-after-claim",
                ),
            )
            val before = try {
                chatReminders(normalizedConversationId)
            } catch (failure: Exception) {
                return ChatReminderMutationOutcome(
                    chatReminderPreflightFailure(operation, "delete", failure),
                )
            }
            if (expectedBaseline != null &&
                before.firstOrNull { it.messageId == normalizedMessageId } != expectedBaseline
            ) {
                return ChatReminderMutationOutcome(
                    chatReminderMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "chat.reminder.delete.baseline-changed",
                    ),
                    reminders = before,
                )
            }
            if (before.none { it.messageId == normalizedMessageId }) {
                chatReminderMutationLock.withLock {
                    completedChatReminderDeletions.add(clientRequestId)
                }
                return ChatReminderMutationOutcome(
                    chatReminderMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.reminder.delete.already-absent",
                    ),
                    reminders = before,
                )
            }
            val writeFailure = try {
                call(
                    CHAT_POST_REMINDER_API,
                    "delete",
                    mapOf("post_id" to normalizedMessageId),
                    version = 1,
                )
                null
            } catch (failure: Exception) {
                failure
            }
            val remaining = withContext(NonCancellable) {
                runCatching { chatReminders(normalizedConversationId) }.getOrNull()
            }
            if (remaining != null && remaining.none { it.messageId == normalizedMessageId }) {
                chatReminderMutationLock.withLock {
                    completedChatReminderDeletions.add(clientRequestId)
                }
                return ChatReminderMutationOutcome(
                    chatReminderMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = if (writeFailure == null) {
                            "chat.reminder.delete.confirmed-success"
                        } else {
                            "chat.reminder.delete.confirmed-after-error"
                        },
                    ),
                    reminders = remaining,
                )
            }
            return ChatReminderMutationOutcome(
                chatReminderSubmissionResult(operation, "delete", writeFailure),
                reminders = remaining,
            )
        } finally {
            withContext(NonCancellable) {
                chatReminderMutationLock.withLock {
                    activeChatReminderRequestIds.remove(clientRequestId)
                    activeChatReminderTargets.remove(targetKey)
                }
            }
        }
    }

    private fun chatReminderTargetKey(conversationId: String, messageId: String) =
        "$conversationId\u0000$messageId"

    private suspend fun chatReminderPreflightFailure(
        operation: String,
        action: String,
        failure: Exception,
    ): MutationResult {
        if (failure is CancellationException || !currentCoroutineContext().isActive) {
            return chatReminderMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "chat.reminder.$action.cancelled-during-preflight",
            )
        }
        val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
            ?: MutationErrorCategory.UNKNOWN
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return chatReminderMutationResult(
            operation,
            status,
            submitted = false,
            failed = 1,
            errorCategory = category,
            diagnosticTag = "chat.reminder.$action.preflight-failed",
        )
    }

    private suspend fun chatReminderSubmissionResult(
        operation: String,
        action: String,
        failure: Exception?,
    ): MutationResult {
        if (failure is CancellationException || !currentCoroutineContext().isActive) {
            return chatReminderMutationResult(
                operation,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                submitted = true,
                requiresRefresh = true,
                unknown = 1,
                diagnosticTag = "chat.reminder.$action.cancelled-after-submission",
            )
        }
        val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
            ?: if (failure == null) MutationErrorCategory.SERVER else MutationErrorCategory.UNKNOWN
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            MutationErrorCategory.NETWORK,
            MutationErrorCategory.UNKNOWN,
            MutationErrorCategory.SERVER,
            -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return chatReminderMutationResult(
            operation,
            status,
            submitted = true,
            requiresRefresh = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            failed = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 0 else 1,
            unknown = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 1 else 0,
            errorCategory = category,
            diagnosticTag = "chat.reminder.$action.submission-unconfirmed",
        )
    }

    private fun chatReminderMutationResult(
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
        localizationKey = "mutation.chat_reminder.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private fun chatReminderResultFailure(result: MutationResult): Exception {
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            return IllegalArgumentException("Invalid chat reminder")
        }
        if (result.status == MutationResultStatus.CANCELLED_BEFORE_SUBMISSION ||
            result.status == MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
        ) return CancellationException("chat reminder mutation cancelled")
        return DsmFailure(
            null,
            "The NAS did not confirm the reminder change",
            "Refresh reminders before deciding whether to try again.",
            kind = when (result.status) {
                MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
            },
        )
    }

    suspend fun chatScheduledMessages(conversationId: String): List<ChatScheduledMessage> {
        if (conversationId.isBlank() || !supportsVersion(CHAT_POST_SCHEDULE_API, 1)) {
            throw unsupportedChatConversationMutation()
        }
        val data = call(
            CHAT_POST_SCHEDULE_API,
            "list",
            mapOf("channel_id" to conversationId),
            version = 1,
        )
        val values = data.elements("schedules").ifEmpty { data.elements("schedule_posts") }
            .ifEmpty { data.elements("scheduled_posts") }
            .ifEmpty { data.elements("cronjobs") }
            .ifEmpty { data.elements("items") }
            .ifEmpty { data.elements("list") }
            .ifEmpty { data.elements("results") }
            .ifEmpty {
                if (data.valueString("cronjob_id", "schedule_id", "id") != null) listOf(data)
                else emptyList()
            }
        return values.mapNotNull { (it as? JsonObject)?.toChatScheduledMessage() }
            .distinctBy(ChatScheduledMessage::id)
            .sortedBy(ChatScheduledMessage::sendAtEpochMillis)
    }

    suspend fun createChatScheduledMessage(
        conversationId: String,
        text: String,
        sendAtEpochMillis: Long,
        clientRequestId: String,
    ): ChatScheduledMessage {
        val outcome = createChatScheduledMessageResult(
            conversationId,
            text,
            sendAtEpochMillis,
            clientRequestId,
        )
        outcome.scheduledMessage?.takeIf {
            outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS
        }?.let { return it }
        throw chatScheduleResultFailure(outcome.result)
    }

    suspend fun createChatScheduledMessageResult(
        conversationId: String,
        text: String,
        sendAtEpochMillis: Long,
        clientRequestId: String,
    ): ChatScheduleMutationOutcome {
        val operation = "chatScheduleCreate"
        val normalizedConversationId = conversationId.trim()
        val normalizedText = text.trim()
        val now = System.currentTimeMillis()
        if (normalizedConversationId.isBlank() || clientRequestId.isBlank() ||
            normalizedText.isBlank() || normalizedText.length > MAX_CHAT_MESSAGE_CHARACTERS ||
            sendAtEpochMillis <= now + MIN_CHAT_REMINDER_LEAD_MILLIS ||
            sendAtEpochMillis > now + MAX_CHAT_REMINDER_HORIZON_MILLIS
        ) return ChatScheduleMutationOutcome(
            chatScheduleMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "chat.schedule.create.invalid-input",
            ),
        )
        if (!supportsVersion(CHAT_POST_SCHEDULE_API, 1)) return ChatScheduleMutationOutcome(
            chatScheduleMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "chat.schedule.create.unsupported",
            ),
        )
        if (!currentCoroutineContext().isActive) return ChatScheduleMutationOutcome(
            chatScheduleMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "chat.schedule.create.cancelled-before-submission",
            ),
        )
        chatScheduleMutationLock.withLock { completedChatScheduledMessages[clientRequestId] }
            ?.let {
                return ChatScheduleMutationOutcome(
                    chatScheduleMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.schedule.create.cached-success",
                    ),
                    scheduledMessage = it,
                )
            }
        val targetKey = chatScheduleCreateTargetKey(
            normalizedConversationId,
            normalizedText,
            sendAtEpochMillis,
        )
        val claimed = chatScheduleMutationLock.withLock {
            if (clientRequestId in activeChatScheduleRequestIds ||
                targetKey in activeChatScheduleTargets
            ) {
                false
            } else {
                activeChatScheduleRequestIds.add(clientRequestId)
                activeChatScheduleTargets.add(targetKey)
                true
            }
        }
        if (!claimed) return ChatScheduleMutationOutcome(
            chatScheduleMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "chat.schedule.create.duplicate-submission",
            ),
        )
        try {
            chatScheduleMutationLock.withLock { completedChatScheduledMessages[clientRequestId] }
                ?.let {
                    return ChatScheduleMutationOutcome(
                        chatScheduleMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_SUCCESS,
                            submitted = true,
                            succeeded = 1,
                            diagnosticTag = "chat.schedule.create.cached-after-claim",
                        ),
                        scheduledMessage = it,
                    )
                }
            fun List<ChatScheduledMessage>.match() = firstOrNull {
                it.conversationId == normalizedConversationId && it.text == normalizedText &&
                    kotlin.math.abs(it.sendAtEpochMillis - sendAtEpochMillis) < 1_000
            }
            val before = try {
                chatScheduledMessages(normalizedConversationId)
            } catch (failure: Exception) {
                return ChatScheduleMutationOutcome(
                    chatSchedulePreflightFailure(operation, "create", failure),
                )
            }
            before.match()?.let {
                chatScheduleMutationLock.withLock {
                    completedChatScheduledMessages[clientRequestId] = it
                }
                return ChatScheduleMutationOutcome(
                    chatScheduleMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.schedule.create.already-matches",
                    ),
                    scheduledMessage = it,
                    scheduledMessages = before,
                )
            }
            val writeFailure = try {
                call(
                    CHAT_POST_SCHEDULE_API,
                    "create",
                    mapOf(
                        "channel_id" to normalizedConversationId,
                        "message" to normalizedText,
                        "send_at" to sendAtEpochMillis.toString(),
                    ),
                    version = 1,
                )
                null
            } catch (failure: Exception) {
                failure
            }
            val after = withContext(NonCancellable) {
                runCatching { chatScheduledMessages(normalizedConversationId) }.getOrNull()
            }
            val confirmed = after?.match()
            if (confirmed != null) {
                chatScheduleMutationLock.withLock {
                    completedChatScheduledMessages[clientRequestId] = confirmed
                }
                return ChatScheduleMutationOutcome(
                    chatScheduleMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = if (writeFailure == null) {
                            "chat.schedule.create.confirmed-success"
                        } else {
                            "chat.schedule.create.confirmed-after-error"
                        },
                    ),
                    scheduledMessage = confirmed,
                    scheduledMessages = after,
                )
            }
            return ChatScheduleMutationOutcome(
                chatScheduleSubmissionResult(operation, "create", writeFailure),
                scheduledMessages = after,
            )
        } finally {
            withContext(NonCancellable) {
                chatScheduleMutationLock.withLock {
                    activeChatScheduleRequestIds.remove(clientRequestId)
                    activeChatScheduleTargets.remove(targetKey)
                }
            }
        }
    }

    suspend fun deleteChatScheduledMessage(
        conversationId: String,
        scheduledMessageId: String,
        clientRequestId: String,
    ) {
        val outcome = deleteChatScheduledMessageResult(
            conversationId,
            scheduledMessageId,
            clientRequestId,
        )
        if (outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS) return
        throw chatScheduleResultFailure(outcome.result)
    }

    suspend fun deleteChatScheduledMessageResult(
        conversationId: String,
        scheduledMessageId: String,
        clientRequestId: String,
    ): ChatScheduleMutationOutcome = deleteChatScheduledMessageResult(
        conversationId,
        scheduledMessageId,
        clientRequestId,
        expectedBaseline = null,
    )

    suspend fun deleteChatScheduledMessageResult(
        conversationId: String,
        scheduledMessageBaseline: ChatScheduledMessage,
        clientRequestId: String,
    ): ChatScheduleMutationOutcome = deleteChatScheduledMessageResult(
        conversationId,
        scheduledMessageBaseline.id,
        clientRequestId,
        expectedBaseline = scheduledMessageBaseline,
    )

    private suspend fun deleteChatScheduledMessageResult(
        conversationId: String,
        scheduledMessageId: String,
        clientRequestId: String,
        expectedBaseline: ChatScheduledMessage?,
    ): ChatScheduleMutationOutcome {
        val operation = "chatScheduleDelete"
        val normalizedConversationId = conversationId.trim()
        val normalizedScheduledMessageId = scheduledMessageId.trim()
        if (normalizedConversationId.isBlank() || normalizedScheduledMessageId.isBlank() ||
            clientRequestId.isBlank() || expectedBaseline?.let {
                it.id != normalizedScheduledMessageId || it.conversationId != normalizedConversationId
            } == true
        ) return ChatScheduleMutationOutcome(
            chatScheduleMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "chat.schedule.delete.invalid-input",
            ),
        )
        if (!supportsVersion(CHAT_POST_SCHEDULE_API, 1)) return ChatScheduleMutationOutcome(
            chatScheduleMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "chat.schedule.delete.unsupported",
            ),
        )
        if (!currentCoroutineContext().isActive) return ChatScheduleMutationOutcome(
            chatScheduleMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "chat.schedule.delete.cancelled-before-submission",
            ),
        )
        if (chatScheduleMutationLock.withLock {
                clientRequestId in completedChatScheduledMessageDeletions
            }
        ) return ChatScheduleMutationOutcome(
            chatScheduleMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_SUCCESS,
                submitted = true,
                succeeded = 1,
                diagnosticTag = "chat.schedule.delete.cached-success",
            ),
        )
        val targetKey = chatScheduleDeleteTargetKey(
            normalizedConversationId,
            normalizedScheduledMessageId,
        )
        val claimed = chatScheduleMutationLock.withLock {
            if (clientRequestId in activeChatScheduleRequestIds ||
                targetKey in activeChatScheduleTargets
            ) {
                false
            } else {
                activeChatScheduleRequestIds.add(clientRequestId)
                activeChatScheduleTargets.add(targetKey)
                true
            }
        }
        if (!claimed) return ChatScheduleMutationOutcome(
            chatScheduleMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "chat.schedule.delete.duplicate-submission",
            ),
        )
        try {
            if (chatScheduleMutationLock.withLock {
                    clientRequestId in completedChatScheduledMessageDeletions
                }
            ) return ChatScheduleMutationOutcome(
                chatScheduleMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "chat.schedule.delete.cached-after-claim",
                ),
            )
            val before = try {
                chatScheduledMessages(normalizedConversationId)
            } catch (failure: Exception) {
                return ChatScheduleMutationOutcome(
                    chatSchedulePreflightFailure(operation, "delete", failure),
                )
            }
            if (expectedBaseline != null &&
                before.firstOrNull { it.id == normalizedScheduledMessageId } != expectedBaseline
            ) {
                return ChatScheduleMutationOutcome(
                    chatScheduleMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "chat.schedule.delete.baseline-changed",
                    ),
                    scheduledMessages = before,
                )
            }
            if (before.none { it.id == normalizedScheduledMessageId }) {
                chatScheduleMutationLock.withLock {
                    completedChatScheduledMessageDeletions.add(clientRequestId)
                }
                return ChatScheduleMutationOutcome(
                    chatScheduleMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.schedule.delete.already-absent",
                    ),
                    scheduledMessages = before,
                )
            }
            val writeFailure = try {
                call(
                    CHAT_POST_SCHEDULE_API,
                    "delete",
                    mapOf("cronjob_id" to normalizedScheduledMessageId),
                    version = 1,
                )
                null
            } catch (failure: Exception) {
                failure
            }
            val remaining = withContext(NonCancellable) {
                runCatching { chatScheduledMessages(normalizedConversationId) }.getOrNull()
            }
            if (remaining != null && remaining.none { it.id == normalizedScheduledMessageId }) {
                chatScheduleMutationLock.withLock {
                    completedChatScheduledMessageDeletions.add(clientRequestId)
                }
                return ChatScheduleMutationOutcome(
                    chatScheduleMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = if (writeFailure == null) {
                            "chat.schedule.delete.confirmed-success"
                        } else {
                            "chat.schedule.delete.confirmed-after-error"
                        },
                    ),
                    scheduledMessages = remaining,
                )
            }
            return ChatScheduleMutationOutcome(
                chatScheduleSubmissionResult(operation, "delete", writeFailure),
                scheduledMessages = remaining,
            )
        } finally {
            withContext(NonCancellable) {
                chatScheduleMutationLock.withLock {
                    activeChatScheduleRequestIds.remove(clientRequestId)
                    activeChatScheduleTargets.remove(targetKey)
                }
            }
        }
    }

    private fun chatScheduleCreateTargetKey(
        conversationId: String,
        text: String,
        sendAtEpochMillis: Long,
    ) = "$conversationId\u0000$text\u0000$sendAtEpochMillis"

    private fun chatScheduleDeleteTargetKey(conversationId: String, scheduledMessageId: String) =
        "$conversationId\u0000$scheduledMessageId"

    private suspend fun chatSchedulePreflightFailure(
        operation: String,
        action: String,
        failure: Exception,
    ): MutationResult {
        if (failure is CancellationException || !currentCoroutineContext().isActive) {
            return chatScheduleMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "chat.schedule.$action.cancelled-during-preflight",
            )
        }
        val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
            ?: MutationErrorCategory.UNKNOWN
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return chatScheduleMutationResult(
            operation,
            status,
            submitted = false,
            failed = 1,
            errorCategory = category,
            diagnosticTag = "chat.schedule.$action.preflight-failed",
        )
    }

    private suspend fun chatScheduleSubmissionResult(
        operation: String,
        action: String,
        failure: Exception?,
    ): MutationResult {
        if (failure is CancellationException || !currentCoroutineContext().isActive) {
            return chatScheduleMutationResult(
                operation,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                submitted = true,
                requiresRefresh = true,
                unknown = 1,
                diagnosticTag = "chat.schedule.$action.cancelled-after-submission",
            )
        }
        val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
            ?: if (failure == null) MutationErrorCategory.SERVER else MutationErrorCategory.UNKNOWN
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            MutationErrorCategory.NETWORK,
            MutationErrorCategory.UNKNOWN,
            MutationErrorCategory.SERVER,
            -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return chatScheduleMutationResult(
            operation,
            status,
            submitted = true,
            requiresRefresh = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            failed = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 0 else 1,
            unknown = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 1 else 0,
            errorCategory = category,
            diagnosticTag = "chat.schedule.$action.submission-unconfirmed",
        )
    }

    private fun chatScheduleMutationResult(
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
        localizationKey = "mutation.chat_schedule.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private fun chatScheduleResultFailure(result: MutationResult): Exception {
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            return IllegalArgumentException("Invalid scheduled chat message")
        }
        if (result.status == MutationResultStatus.CANCELLED_BEFORE_SUBMISSION ||
            result.status == MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
        ) return CancellationException("chat schedule mutation cancelled")
        return DsmFailure(
            null,
            "The NAS did not confirm the scheduled message change",
            "Refresh scheduled messages before deciding whether to try again.",
            kind = when (result.status) {
                MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
            },
        )
    }

    private fun JsonObject.toChatScheduledMessage(): ChatScheduledMessage? {
        val id = valueString("cronjob_id", "schedule_id", "id") ?: return null
        val conversationId = valueString("channel_id", "conversation_id") ?: return null
        val text = firstNonBlank("message", "text", "content") ?: return null
        val rawTime = long("send_at") ?: long("scheduled_at") ?: long("time") ?: return null
        return ChatScheduledMessage(
            id = id,
            conversationId = conversationId,
            text = text,
            sendAtEpochMillis = normalizeEpochMillis(rawTime) ?: return null,
        )
    }

    suspend fun createChatPoll(
        conversationId: String,
        question: String,
        options: List<String>,
        allowsMultipleSelection: Boolean,
        isAnonymous: Boolean,
        clientRequestId: String,
    ): ChatMessage {
        val outcome = createChatPollResult(
            conversationId,
            question,
            options,
            allowsMultipleSelection,
            isAnonymous,
            clientRequestId,
        )
        outcome.message?.takeIf {
            outcome.result.status == MutationResultStatus.CONFIRMED_SUCCESS
        }?.let { return it }
        throw chatPollResultFailure(outcome.result)
    }

    suspend fun createChatPollResult(
        conversationId: String,
        question: String,
        options: List<String>,
        allowsMultipleSelection: Boolean,
        isAnonymous: Boolean,
        clientRequestId: String,
    ): ChatPollMutationOutcome {
        val operation = "chatPollCreate"
        val normalizedConversationId = conversationId.trim()
        val normalizedQuestion = question.trim()
        val normalizedOptions = options.map(String::trim).filter(String::isNotBlank)
        val canonicalOptions = normalizedOptions.map { it.lowercase(Locale.ROOT) }
        if (normalizedConversationId.isBlank() || clientRequestId.isBlank() ||
            normalizedQuestion.isBlank() ||
            normalizedQuestion.length > MAX_CHAT_MESSAGE_CHARACTERS ||
            normalizedOptions.size !in 2..MAX_CHAT_POLL_OPTIONS ||
            normalizedOptions.any { it.length > MAX_CHAT_POLL_OPTION_CHARACTERS } ||
            canonicalOptions.distinct().size != canonicalOptions.size
        ) return ChatPollMutationOutcome(
            chatPollMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "chat.poll.create.invalid-input",
            ),
        )
        if (!supportsVersion(CHAT_POST_VOTE_API, 1)) return ChatPollMutationOutcome(
            chatPollMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "chat.poll.create.unsupported",
            ),
        )
        if (!currentCoroutineContext().isActive) return ChatPollMutationOutcome(
            chatPollMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "chat.poll.create.cancelled-before-submission",
            ),
        )
        chatPollMutationLock.withLock { completedChatPolls[clientRequestId] }?.let {
            return ChatPollMutationOutcome(
                chatPollMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "chat.poll.create.cached-success",
                ),
                it,
            )
        }
        val targetKey = buildString {
            append(normalizedConversationId)
            append('\u0000')
            append(normalizedQuestion)
            append('\u0000')
            append(canonicalOptions.joinToString("\u0001"))
            append('\u0000')
            append(allowsMultipleSelection)
            append('\u0000')
            append(isAnonymous)
        }
        val claimed = chatPollMutationLock.withLock {
            if (clientRequestId in activeChatPollRequestIds || targetKey in activeChatPollTargets) {
                false
            } else {
                activeChatPollRequestIds.add(clientRequestId)
                activeChatPollTargets.add(targetKey)
                true
            }
        }
        if (!claimed) return ChatPollMutationOutcome(
            chatPollMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "chat.poll.create.duplicate-submission",
            ),
        )
        try {
            chatPollMutationLock.withLock { completedChatPolls[clientRequestId] }?.let {
                return ChatPollMutationOutcome(
                    chatPollMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.poll.create.cached-after-claim",
                    ),
                    it,
                )
            }
            val preflightAt = System.currentTimeMillis() / 1_000
            fun ChatMessage.matchesPoll(referenceEpochSeconds: Long): Boolean {
                val observedPoll = poll ?: return false
                return isMine && body == normalizedQuestion &&
                    observedPoll.question == normalizedQuestion &&
                    observedPoll.options.map { it.text.trim().lowercase(Locale.ROOT) } == canonicalOptions &&
                    observedPoll.allowsMultipleSelection == allowsMultipleSelection &&
                    observedPoll.isAnonymous == isAnonymous &&
                    createdAtEpochSeconds > 0 &&
                    createdAtEpochSeconds in
                    (referenceEpochSeconds - CHAT_SEND_READBACK_CLOCK_SKEW_SECONDS)..
                    (referenceEpochSeconds + CHAT_SEND_READBACK_WINDOW_SECONDS)
            }
            val before = try {
                chatMessages(normalizedConversationId, 0, 50).messages
            } catch (failure: Exception) {
                return ChatPollMutationOutcome(chatPollPreflightFailure(operation, failure))
            }
            before.lastOrNull { it.matchesPoll(preflightAt) }?.let {
                val result = it.withPollDraft(
                    normalizedQuestion,
                    normalizedOptions,
                    allowsMultipleSelection,
                    isAnonymous,
                    clientRequestId,
                )
                chatPollMutationLock.withLock { completedChatPolls[clientRequestId] = result }
                return ChatPollMutationOutcome(
                    chatPollMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = "chat.poll.create.already-matches",
                    ),
                    result,
                )
            }
            val submittedAt = System.currentTimeMillis() / 1_000
            val settings = """{"add_option":false,"anonymous":$isAnonymous,"multiple":$allowsMultipleSelection}"""
            val writeFailure = try {
                call(
                    CHAT_POST_VOTE_API,
                    "create",
                    mapOf(
                        "channel_id" to normalizedConversationId,
                        "message" to normalizedQuestion,
                        "choices" to jsonStringArray(normalizedOptions),
                        "options" to settings,
                    ),
                    version = 1,
                )
                null
            } catch (failure: Exception) {
                failure
            }
            val parsed = withContext(NonCancellable) {
                runCatching { chatMessages(normalizedConversationId, 0, 50) }.getOrNull()
                    ?.messages?.lastOrNull { it.matchesPoll(submittedAt) }
            }
            if (parsed != null) {
                val result = parsed.withPollDraft(
                    normalizedQuestion,
                    normalizedOptions,
                    allowsMultipleSelection,
                    isAnonymous,
                    clientRequestId,
                )
                chatPollMutationLock.withLock { completedChatPolls[clientRequestId] = result }
                return ChatPollMutationOutcome(
                    chatPollMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_SUCCESS,
                        submitted = true,
                        succeeded = 1,
                        diagnosticTag = if (writeFailure == null) {
                            "chat.poll.create.confirmed-success"
                        } else {
                            "chat.poll.create.confirmed-after-error"
                        },
                    ),
                    result,
                )
            }
            return ChatPollMutationOutcome(
                chatPollSubmissionResult(operation, writeFailure),
            )
        } finally {
            withContext(NonCancellable) {
                chatPollMutationLock.withLock {
                    activeChatPollRequestIds.remove(clientRequestId)
                    activeChatPollTargets.remove(targetKey)
                }
            }
        }
    }

    private suspend fun chatPollPreflightFailure(
        operation: String,
        failure: Exception,
    ): MutationResult {
        if (failure is CancellationException || !currentCoroutineContext().isActive) {
            return chatPollMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "chat.poll.create.cancelled-during-preflight",
            )
        }
        val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
            ?: MutationErrorCategory.UNKNOWN
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return chatPollMutationResult(
            operation,
            status,
            submitted = false,
            failed = 1,
            errorCategory = category,
            diagnosticTag = "chat.poll.create.preflight-failed",
        )
    }

    private suspend fun chatPollSubmissionResult(
        operation: String,
        failure: Exception?,
    ): MutationResult {
        if (failure is CancellationException || !currentCoroutineContext().isActive) {
            return chatPollMutationResult(
                operation,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                submitted = true,
                requiresRefresh = true,
                unknown = 1,
                diagnosticTag = "chat.poll.create.cancelled-after-submission",
            )
        }
        val category = (failure as? DsmFailure)?.let(::fileMutationErrorCategory)
            ?: if (failure == null) MutationErrorCategory.SERVER else MutationErrorCategory.UNKNOWN
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            MutationErrorCategory.NETWORK,
            MutationErrorCategory.UNKNOWN,
            MutationErrorCategory.SERVER,
            -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return chatPollMutationResult(
            operation,
            status,
            submitted = true,
            requiresRefresh = status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
            failed = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 0 else 1,
            unknown = if (status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED) 1 else 0,
            errorCategory = category,
            diagnosticTag = "chat.poll.create.submission-unconfirmed",
        )
    }

    private fun chatPollMutationResult(
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
        localizationKey = "mutation.chat_poll.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private fun chatPollResultFailure(result: MutationResult): Exception {
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            return IllegalArgumentException("Invalid chat poll")
        }
        if (result.status == MutationResultStatus.CANCELLED_BEFORE_SUBMISSION ||
            result.status == MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
        ) return CancellationException("chat poll mutation cancelled")
        return DsmFailure(
            null,
            "The NAS did not confirm the poll",
            "Refresh the conversation before deciding whether to try again.",
            kind = when (result.status) {
                MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
            },
        )
    }

    private fun ChatMessage.withPollDraft(
        question: String,
        options: List<String>,
        allowsMultipleSelection: Boolean,
        isAnonymous: Boolean,
        clientRequestId: String,
    ): ChatMessage = copy(
        clientRequestId = clientRequestId,
        poll = poll ?: ChatPoll(
            id = id,
            question = question,
            allowsMultipleSelection = allowsMultipleSelection,
            isAnonymous = isAnonymous,
            options = options.mapIndexed { index, text ->
                ChatPollOption("$id-choice-$index", text)
            },
        ),
    )

    private fun chatPoll(post: JsonObject, messageId: String): ChatPoll? {
        val raw = post["vote"] ?: post["poll"] ?: post["vote_info"] ?: return null
        val poll = when (raw) {
            is JsonObject -> raw
            is JsonPrimitive -> raw.contentOrNull?.let {
                runCatching { Json.parseToJsonElement(it) as? JsonObject }.getOrNull()
            }
            else -> null
        } ?: return null
        val rawChoices = poll.elements("choices").ifEmpty { poll.elements("options") }
        val choices = rawChoices.mapIndexedNotNull { index, value ->
            when (value) {
                is JsonPrimitive -> value.contentOrNull?.takeIf(String::isNotBlank)?.let {
                    ChatPollOption("$messageId-choice-$index", it)
                }
                is JsonObject -> value.firstNonBlank("choice", "text", "name", "title")?.let { text ->
                    ChatPollOption(
                        id = value.valueString("choice_id", "option_id", "id")
                            ?: "$messageId-choice-$index",
                        text = text,
                        voteCount = (value.long("vote_count") ?: value.long("count")
                            ?: value.long("votes") ?: 0).coerceAtLeast(0).toInt(),
                        isSelectedByCurrentUser = value.bool("selected")
                            ?: value.bool("is_selected") ?: value.bool("is_voted")
                            ?: value.bool("voted") ?: false,
                    )
                }
                else -> null
            }
        }
        if (choices.isEmpty()) return null
        val settingsRaw = poll["options"]
        val settings = when (settingsRaw) {
            is JsonObject -> settingsRaw
            is JsonPrimitive -> settingsRaw.contentOrNull?.let {
                runCatching { Json.parseToJsonElement(it) as? JsonObject }.getOrNull()
            }
            else -> null
        } ?: poll
        return ChatPoll(
            id = poll.valueString("vote_id", "poll_id", "id") ?: messageId,
            question = poll.firstNonBlank("message", "question", "title")
                ?: post.firstNonBlank("message", "text", "content").orEmpty(),
            allowsMultipleSelection = settings.bool("multiple")
                ?: settings.bool("allow_multiple") ?: false,
            isAnonymous = settings.bool("anonymous") ?: settings.bool("is_anonymous") ?: false,
            isClosed = poll.bool("closed") ?: poll.bool("is_closed")
                ?: poll.bool("expired") ?: false,
            options = choices,
        )
    }

    private fun chatAttachments(post: JsonObject, messageId: String): List<ChatAttachment> =
        post.elements("files").ifEmpty { post.elements("attachments") }
            .mapIndexedNotNull { index, value ->
                val file = value as? JsonObject ?: return@mapIndexedNotNull null
                ChatAttachment(
                    id = file.valueString("file_id", "id") ?: "$messageId-$index",
                    name = file.firstNonBlank("name", "file_name", "filename")
                        ?: return@mapIndexedNotNull null,
                    mimeType = file.string("mime_type") ?: file.string("type"),
                    size = file.long("size") ?: file.long("file_size"),
                )
            }

    /**
     * 读取远程访问设置。单项能力或读取失败以 null 表示；两项都失败时整体不可用。
     * 内部写门禁仅承认已记录环境，不会因为 API 存在而自动开放。
     */
    suspend fun remoteAccessSettings(): NasRemoteAccessSettings {
        suspend fun readBoolean(
            apiName: String,
            version: Int,
            method: String,
            key: String,
        ): Result<Boolean> {
            if (!supportsVersion(apiName, version)) {
                return Result.failure(remoteAccessUnsupportedFailure())
            }
            return try {
                val data = call(apiName, method, version = version)
                Result.success(
                    data[key].strictBooleanValue()
                        ?: throw invalidSettingsResponse("remote-access-$key"),
                )
            } catch (error: CancellationException) {
                throw error
            } catch (error: Throwable) {
                Result.failure(error)
            }
        }

        val relay = readBoolean(QUICK_CONNECT_API, QUICK_CONNECT_VERSION, "get_misc_config", "relay_enabled")
        val router = readBoolean(QUICK_CONNECT_UPNP_API, QUICK_CONNECT_UPNP_VERSION, "get", "enabled")
        if (relay.isFailure && router.isFailure) {
            throw relay.exceptionOrNull() ?: router.exceptionOrNull()
                ?: invalidSettingsResponse("remote-access")
        }
        return NasRemoteAccessSettings(
            isRelayEnabled = relay.getOrNull(),
            isRouterConfigurationEnabled = router.getOrNull(),
            isConnectedThroughTrustedRelay = resolvedProfileUsesTrustedRelay(),
            canManage = recordedRemoteAccessEnvironment(),
        )
    }

    suspend fun activeRemoteAccessSettings(): NasRemoteAccessSettings = remoteAccessSettings()

    suspend fun saveRemoteAccessSettingsResult(
        original: NasRemoteAccessSettings,
        desired: NasRemoteAccessSettings,
    ): MutationResult {
        val operation = "remoteAccessSettingsUpdate"
        val sameAvailability = (original.isRelayEnabled == null) == (desired.isRelayEnabled == null) &&
            (original.isRouterConfigurationEnabled == null) ==
            (desired.isRouterConfigurationEnabled == null)
        if (
            !sameAvailability ||
            original.isConnectedThroughTrustedRelay != desired.isConnectedThroughTrustedRelay ||
            original.canManage != desired.canManage
        ) return invalidSettingsResult(operation, "remote-access.invalid-baseline")

        val fields = remoteAccessChangedFields(original, desired)
        if (fields.isEmpty()) return settingsMutationResult(
            operation, MutationResultStatus.CONFIRMED_FAILURE, false,
            total = 1, failed = 1, errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "remote-access.no-changes",
        )
        if (!original.canManage) return settingsMutationResult(
            operation, MutationResultStatus.UNSUPPORTED, false,
            total = fields.size, failed = fields.size,
            errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = "remote-access.environment-unverified",
        )
        if (
            REMOTE_ACCESS_RELAY_FIELD in fields && desired.isRelayEnabled == false &&
            original.isConnectedThroughTrustedRelay
        ) return settingsMutationResult(
            operation, MutationResultStatus.CONFIRMED_FAILURE, false,
            total = fields.size, failed = fields.size,
            errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "remote-access.active-relay-protected",
        )
        if (!remoteAccessFieldsSupported(fields)) return settingsMutationResult(
            operation, MutationResultStatus.UNSUPPORTED, false,
            total = fields.size, failed = fields.size,
            errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = "remote-access.unsupported",
        )
        if (!claimServiceMutation(REMOTE_ACCESS_MUTATION_KEY)) {
            return duplicateSettingsResult(operation, "remote-access.duplicate", fields.size)
        }
        try {
            val current = try {
                remoteAccessSettings()
            } catch (_: CancellationException) {
                return settingsMutationResult(
                    operation, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                    total = fields.size, diagnosticTag = "remote-access.cancelled-before-submission",
                )
            } catch (error: Throwable) {
                return serviceMutationFailure(
                    operation, error.asRepositoryFailure(), false, "remote-access.preflight-failed",
                    affectedCount = fields.size,
                )
            }
            if (current != original) return settingsMutationResult(
                operation, MutationResultStatus.CONFIRMED_FAILURE, false,
                total = fields.size, failed = fields.size,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "remote-access.baseline-changed",
            )

            var submitted = 0
            var currentStepMayHaveBeenSubmitted = false
            var submissionFailure: DsmFailure? = null
            var cancelled = false
            for (field in fields) {
                try {
                    currentCoroutineContext().ensureActive()
                    currentStepMayHaveBeenSubmitted = true
                    when (field) {
                        REMOTE_ACCESS_RELAY_FIELD -> call(
                            QUICK_CONNECT_API,
                            "set_misc_config",
                            mapOf("relay_enabled" to checkNotNull(desired.isRelayEnabled).toString()),
                            version = QUICK_CONNECT_VERSION,
                        )
                        REMOTE_ACCESS_ROUTER_FIELD -> call(
                            QUICK_CONNECT_UPNP_API,
                            "set",
                            mapOf(
                                "enabled" to checkNotNull(desired.isRouterConfigurationEnabled).toString(),
                            ),
                            version = QUICK_CONNECT_UPNP_VERSION,
                        )
                    }
                    submitted += 1
                    currentStepMayHaveBeenSubmitted = false
                } catch (_: CancellationException) {
                    cancelled = true
                    break
                } catch (error: Throwable) {
                    submissionFailure = error.asRepositoryFailure()
                    break
                }
            }
            if (submitted == 0 && cancelled && !currentStepMayHaveBeenSubmitted) {
                return settingsMutationResult(
                    operation, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                    total = fields.size, diagnosticTag = "remote-access.cancelled-before-submission",
                )
            }
            val actual = try {
                withContext(NonCancellable) { remoteAccessSettings() }
            } catch (readbackError: Throwable) {
                if (
                    submissionFailure != null && submitted == 0 &&
                    !submissionFailure.isAmbiguousSettingsFailure()
                ) {
                    return serviceMutationFailure(
                        operation, submissionFailure, true, "remote-access.submission-rejected",
                        affectedCount = fields.size,
                    )
                }
                val possible = (
                    submitted + if (
                        submissionFailure?.isAmbiguousSettingsFailure() == true || cancelled
                    ) 1 else 0
                    ).coerceAtMost(fields.size)
                return settingsMutationResult(
                    operation,
                    if (cancelled) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    true, fields.size, failed = fields.size - possible, unknown = possible,
                    requiresRefresh = true,
                    errorCategory = readbackError.asRepositoryFailure().mutationErrorCategory(),
                    diagnosticTag = "remote-access.readback-unverified",
                )
            }
            val unverifiableFields = fields.filter { field ->
                when (field) {
                    REMOTE_ACCESS_RELAY_FIELD -> actual.isRelayEnabled == null
                    REMOTE_ACCESS_ROUTER_FIELD -> actual.isRouterConfigurationEnabled == null
                    else -> true
                }
            }
            if (unverifiableFields.isNotEmpty()) {
                val succeeded = fields.count { field ->
                    field !in unverifiableFields && remoteAccessFieldMatches(field, actual, desired)
                }
                val unknown = fields.size - succeeded
                return settingsMutationResult(
                    operation,
                    if (succeeded > 0) MutationResultStatus.PARTIAL_SUCCESS
                    else if (cancelled) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    true,
                    fields.size,
                    succeeded = succeeded,
                    unknown = unknown,
                    requiresRefresh = true,
                    errorCategory = submissionFailure?.mutationErrorCategory()
                        ?: MutationErrorCategory.UNKNOWN,
                    diagnosticTag = "remote-access.readback-incomplete",
                )
            }
            val succeeded = fields.count { remoteAccessFieldMatches(it, actual, desired) }
            return settingsVerificationResult(
                operation, fields.size, succeeded, submissionFailure, cancelled, "remote-access",
            )
        } finally {
            withContext(NonCancellable) { releaseServiceMutation(REMOTE_ACCESS_MUTATION_KEY) }
        }
    }

    private fun remoteAccessChangedFields(
        original: NasRemoteAccessSettings,
        desired: NasRemoteAccessSettings,
    ): List<String> = buildList {
        if (original.isRelayEnabled != desired.isRelayEnabled) add(REMOTE_ACCESS_RELAY_FIELD)
        if (original.isRouterConfigurationEnabled != desired.isRouterConfigurationEnabled) {
            add(REMOTE_ACCESS_ROUTER_FIELD)
        }
    }

    private fun remoteAccessFieldsSupported(fields: List<String>): Boolean = fields.all { field ->
        when (field) {
            REMOTE_ACCESS_RELAY_FIELD -> supportsVersion(QUICK_CONNECT_API, QUICK_CONNECT_VERSION)
            REMOTE_ACCESS_ROUTER_FIELD ->
                supportsVersion(QUICK_CONNECT_UPNP_API, QUICK_CONNECT_UPNP_VERSION)
            else -> false
        }
    }

    private fun remoteAccessFieldMatches(
        field: String,
        actual: NasRemoteAccessSettings,
        desired: NasRemoteAccessSettings,
    ): Boolean = when (field) {
        REMOTE_ACCESS_RELAY_FIELD -> actual.isRelayEnabled == desired.isRelayEnabled
        REMOTE_ACCESS_ROUTER_FIELD ->
            actual.isRouterConfigurationEnabled == desired.isRouterConfigurationEnabled
        else -> false
    }

    private fun resolvedProfileUsesTrustedRelay(): Boolean {
        val host = runCatching {
            URI(if ("://" in profile.address) profile.address else "https://${profile.address}").host
        }.getOrNull() ?: return false
        return isTrustedQuickConnectRelayHost(host)
    }

    private suspend fun recordedRemoteAccessEnvironment(): Boolean {
        if (!supports(SYSTEM_API)) return false
        val system = try {
            call(SYSTEM_API, "info")
        } catch (error: CancellationException) {
            throw error
        } catch (_: Throwable) {
            return false
        }
        val firmware = system["firmware_ver"].strictStringValue() ?: return false
        val match = RECORDED_DSM_VERSION.matchEntire(firmware.trim()) ?: return false
        val embeddedBuild = match.groupValues[1].takeIf(String::isNotEmpty)?.toIntOrNull()
        val embeddedUpdate = match.groupValues[2].takeIf(String::isNotEmpty)?.toIntOrNull()
        val build = system["buildnumber"].strictIntValue(allowString = true) ?: return false
        val update = system["smallfixnumber"].strictIntValue(allowString = true) ?: return false
        return build == RECORDED_DSM_BUILD && update == RECORDED_DSM_UPDATE &&
            (embeddedBuild == null || embeddedBuild == RECORDED_DSM_BUILD) &&
            (embeddedUpdate == null || embeddedUpdate == RECORDED_DSM_UPDATE)
    }

    private fun remoteAccessUnsupportedFailure() = DsmFailure(
        102,
        "Remote access settings are unavailable",
        "Use DSM to manage remote access settings.",
        kind = DsmErrorKind.FEATURE_UNSUPPORTED,
    )

    suspend fun nasSettings(): NasSettingsSnapshot {
        val systemJson = runCatching { firstSuccessful("SYNO.Core.System", listOf("info", "get")) }.getOrNull()
        val storageJson = runCatching { firstSuccessful("SYNO.Storage.CGI.Storage", listOf("load_info", "get")) }.getOrNull()
        val packageResult = runCatching { packageList() }
        val accountResult = runCatching { accountList() }
        val groupResult = runCatching { groupList() }
        val logResult = runCatching {
            firstSuccessful(
                preferred("SYNO.LogCenter.History", "SYNO.Core.SyslogClient.Log"),
                listOf("list", "get"),
                mapOf("offset" to "0", "limit" to "200"),
            )
        }
        val connectionResult = runCatching { connectionList() }
        val ethernetResult = runCatching { ethernetInterfaces() }
        val ddnsResult = runCatching { ddnsDirectory() }
        val securitySettingsResult = runCatching { securitySettings() }
        val hardwareSettingsResult = runCatching { hardwareSettings() }
        val remoteAccessSettingsResult = runCatching { remoteAccessSettings() }
        return NasSettingsSnapshot(
            system = systemJson?.let(::systemSummary),
            volumes = storageJson?.let(::capacityList).orEmpty(),
            pools = storageJson?.let { genericResources(it, "storagePools", "pools") }.orEmpty(),
            disks = storageJson?.let { genericResources(it, "disks") }.orEmpty(),
            storageDisks = storageJson?.let(::storageDisks).orEmpty(),
            packages = packageResult.getOrDefault(emptyList()),
            packagesAvailable = packageResult.isSuccess,
            scheduledTasks = runCatching {
                resourceList("SYNO.Core.TaskScheduler", listOf("list", "get"), "tasks")
            }.getOrDefault(emptyList()),
            accounts = accountResult.getOrDefault(emptyList()),
            accountsAvailable = accountResult.isSuccess,
            groups = groupResult.getOrDefault(emptyList()),
            groupsAvailable = groupResult.isSuccess,
            logs = logResult.getOrNull()?.let(::logs).orEmpty(),
            connections = connectionResult.getOrDefault(emptyList()),
            connectionsAvailable = connectionResult.isSuccess,
            networkInterfaces = ethernetResult.getOrDefault(emptyList()),
            networkInterfacesAvailable = ethernetResult.isSuccess,
            ddnsDirectory = ddnsResult.getOrNull(),
            ddnsDirectoryAvailable = ddnsResult.isSuccess,
            fileServiceSettings = runCatching { fileServiceSettings() }.getOrNull(),
            terminalSettings = runCatching { terminalSettings() }.getOrNull(),
            proxySettings = runCatching { proxySettings() }.getOrNull(),
            regionSettings = runCatching { regionSettings() }.getOrNull(),
            securitySettings = securitySettingsResult.getOrNull(),
            hardwareSettings = hardwareSettingsResult.getOrNull(),
            security = securityResources(),
            securitySettingsAvailable = securitySettingsResult.isSuccess,
            hardwareSettingsAvailable = hardwareSettingsResult.isSuccess,
            remoteAccessSettings = remoteAccessSettingsResult.getOrNull(),
            remoteAccessSettingsAvailable = remoteAccessSettingsResult.isSuccess,
            logsAvailable = logResult.isSuccess,
        )
    }

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

    @Deprecated("Use loadDiskTestStatus(originalDisk) to preserve stable disk/device identity")
    suspend fun loadDiskTestStatus(diskId: String): NasDiskTestStatus {
        if (!supportsSmartTestV1()) throw smartUnsupportedFailure()
        val normalizedId = diskId.trim()
        val disk = strictStorageDisks().firstOrNull { it.id == normalizedId }
            ?: throw DsmFailure(
                null,
                "The selected drive is no longer available",
                "Refresh storage information and choose the drive again.",
                kind = DsmErrorKind.INVALID_RESPONSE,
            )
        if (!disk.supportsSmartTest) throw smartUnsupportedFailure()
        return strictDiskTestStatus(disk, includesHistory = true)
    }

    /** 普通状态页读取完整状态与历史，并严格核对调用方持有的稳定硬盘身份。 */
    suspend fun loadDiskTestStatus(originalDisk: NasStorageDisk): NasDiskTestStatus {
        if (!supportsSmartTestV1()) throw smartUnsupportedFailure()
        val current = strictStorageDisks().firstOrNull { it.id == originalDisk.id }
            ?: throw smartTargetUnavailableFailure()
        if (current.deviceId != originalDisk.deviceId) throw smartTargetUnavailableFailure()
        if (!current.supportsSmartTest) throw smartUnsupportedFailure()
        return strictDiskTestStatus(current, includesHistory = true)
    }

    /** 严格专项回读不会把目标消失、身份漂移或畸形状态折叠成“未运行”。 */
    suspend fun activeDiskTestStatus(originalDisk: NasStorageDisk): NasDiskTestStatus {
        if (!supportsSmartTestV1()) throw smartUnsupportedFailure()
        val current = strictStorageDisks().firstOrNull { it.id == originalDisk.id }
            ?: throw smartTargetUnavailableFailure()
        if (current.deviceId != originalDisk.deviceId) throw smartTargetUnavailableFailure()
        if (!current.supportsSmartTest) throw smartUnsupportedFailure()
        return strictDiskTestStatus(current, includesHistory = false)
    }

    suspend fun changeDiskTestResult(
        originalDisk: NasStorageDisk,
        originalStatus: NasDiskTestStatus,
        type: NasDiskTestType?,
    ): MutationResult = changeDiskTestResultInternal(originalDisk, originalStatus, type, null, null)

    @Deprecated("Use changeDiskTestResult(originalDisk, originalStatus, type) to preserve the SMART baseline")
    suspend fun changeDiskTestResult(
        diskId: String,
        type: NasDiskTestType?,
    ): MutationResult {
        val shouldRun = type != null
        val operation = if (shouldRun) "diskTestStart" else "diskTestStop"
        val normalizedId = diskId.trim()
        if (normalizedId.isBlank()) return serviceMutationResult(
            operation,
            MutationResultStatus.CONFIRMED_FAILURE,
            false,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "storage.disk-test.invalid-input",
        )
        if (!supportsSmartTestV1()) {
            return unsupportedServiceMutation(operation, "storage.disk-test.unsupported-version")
        }
        return try {
            val disk = strictStorageDisks().firstOrNull { it.id == normalizedId }
                ?: return smartConflictResult(operation, "storage.disk-test.target-changed")
            if (!disk.supportsSmartTest) return unsupportedServiceMutation(
                operation, "storage.disk-test.unsupported-drive",
            )
            val status = strictDiskTestStatus(disk, includesHistory = false)
            changeDiskTestResultInternal(disk, status, type, disk, status)
        } catch (_: CancellationException) {
            serviceMutationResult(
                operation, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                diagnosticTag = "storage.disk-test.cancelled-before-submission",
            )
        } catch (error: Throwable) {
            serviceMutationFailure(
                operation, error.asRepositoryFailure(), false, "storage.disk-test.legacy-preflight-failed",
            )
        }
    }

    private suspend fun changeDiskTestResultInternal(
        originalDisk: NasStorageDisk,
        originalStatus: NasDiskTestStatus,
        type: NasDiskTestType?,
        verifiedDisk: NasStorageDisk?,
        verifiedStatus: NasDiskTestStatus?,
    ): MutationResult {
        val shouldRun = type != null
        val operation = if (shouldRun) "diskTestStart" else "diskTestStop"
        val normalizedId = originalDisk.id.trim()
        if (
            normalizedId.isBlank() || originalDisk.deviceId.isBlank() ||
            originalStatus.diskId != originalDisk.id ||
            (originalStatus.isRunning && originalStatus.isBusyWithOtherTest) ||
            (originalStatus.isRunning && originalStatus.runningType == null) ||
            (!originalStatus.isRunning && originalStatus.runningType != null)
        ) return serviceMutationResult(
            operation, MutationResultStatus.CONFIRMED_FAILURE, false,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "storage.disk-test.invalid-baseline",
        )
        if (!supportsSmartTestV1()) {
            return unsupportedServiceMutation(operation, "storage.disk-test.unsupported-version")
        }
        return verifiedServiceMutation(
            operation = operation,
            targetKey = "disk-test:${normalizedId.lowercase(Locale.ROOT)}",
            requiredApi = STORAGE_DISK_API,
            preflight = {
                val disk = verifiedDisk ?: strictStorageDisks().firstOrNull { it.id == normalizedId }
                    ?: return@verifiedServiceMutation false
                if (!sameSmartDiskMutationBaseline(disk, originalDisk)) {
                    return@verifiedServiceMutation false
                }
                if (!disk.supportsSmartTest) throw smartUnsupportedFailure()
                val current = verifiedStatus ?: strictDiskTestStatus(disk, includesHistory = false)
                if (!sameSmartMutationBaseline(current, originalStatus)) {
                    return@verifiedServiceMutation false
                }
                if (shouldRun) {
                    !current.isRunning && !current.isBusyWithOtherTest
                } else {
                    current.isRunning && !current.isBusyWithOtherTest
                }
            },
            submit = {
                call(
                    STORAGE_DISK_API,
                    "do_smart_test",
                    mapOf(
                        "device" to originalDisk.deviceId,
                        "type" to when (type) {
                            NasDiskTestType.QUICK -> "quick"
                            NasDiskTestType.EXTENDED -> "extend"
                            null -> "stop"
                        },
                    ),
                    version = 1,
                )
            },
            verify = {
                smartReadbackAttempt {
                    val currentDisk = strictStorageDisks().firstOrNull { it.id == normalizedId }
                        ?: throw smartTargetUnavailableFailure()
                    if (
                        currentDisk.deviceId != originalDisk.deviceId ||
                        !currentDisk.supportsSmartTest
                    ) throw smartTargetUnavailableFailure()
                    val current = strictDiskTestStatus(currentDisk, includesHistory = false)
                    if (type == null) !current.isRunning
                    else current.isRunning && current.runningType == type
                }
            },
            successfulVerificationAttempts = SMART_READBACK_ATTEMPTS,
            successfulVerificationIntervalMillis = SMART_READBACK_INTERVAL_MILLIS,
            ambiguousVerificationAttempts = SMART_READBACK_ATTEMPTS,
            ambiguousVerificationIntervalMillis = SMART_READBACK_INTERVAL_MILLIS,
            cancellationVerificationAttempts = 1,
            cancellationVerificationIntervalMillis = 0,
        )
    }

    private fun supportsSmartTestV1(): Boolean =
        supportsVersion(STORAGE_OVERVIEW_API, SMART_API_VERSION) &&
            supportsVersion(STORAGE_DISK_API, SMART_API_VERSION)

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

    private suspend fun strictDiskTestStatus(
        disk: NasStorageDisk,
        includesHistory: Boolean,
    ): NasDiskTestStatus {
        val data = call(
            STORAGE_DISK_API,
            "get_smart_test_log",
            mapOf("device" to disk.deviceId),
            version = 1,
        )
        val statusRows = strictSettingsRows(data, setOf("testInfo"), "storage-smart-status")
        if (statusRows.size != 1) throw invalidSettingsResponse("storage-smart-status-count")
        val latest = statusRows.single()
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
        var lastQuick: String? = null
        var lastExtended: String? = null
        var historyResult: String? = null
        var historyAvailable = false
        if (includesHistory) {
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
                historyAvailable = true
            }
        }
        return NasDiskTestStatus(
            diskId = disk.id,
            isRunning = running,
            isBusyWithOtherTest = busy,
            runningType = runningType.takeIf { running },
            progressDescription = optionalString("remain", "progress"),
            lastQuickTest = lastQuick,
            lastExtendedTest = lastExtended,
            lastResult = optionalString(
                "latest_test_result", "result",
                normalize = { it.trim().lowercase(Locale.ROOT) },
            ) ?: historyResult,
            isHistoryAvailable = historyAvailable,
        )
    }

    private fun sameSmartMutationBaseline(
        current: NasDiskTestStatus,
        original: NasDiskTestStatus,
    ): Boolean = current.diskId == original.diskId &&
        current.isRunning == original.isRunning &&
        current.isBusyWithOtherTest == original.isBusyWithOtherTest &&
        current.runningType == original.runningType

    /** SMART 专项回读允许瞬时网络异常消耗一次轮询，但不吞掉取消、权限或契约错误。 */
    private suspend fun smartReadbackAttempt(verify: suspend () -> Boolean): Boolean = try {
        verify()
    } catch (error: CancellationException) {
        throw error
    } catch (error: Throwable) {
        val failure = error.asRepositoryFailure()
        if (failure.kind in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.UNKNOWN)) false else throw error
    }

    /** 温度、健康与展示状态会自然变化；危险写目标只绑定稳定身份和明确能力。 */
    private fun sameSmartDiskMutationBaseline(
        current: NasStorageDisk,
        original: NasStorageDisk,
    ): Boolean = current.id == original.id &&
        current.deviceId == original.deviceId &&
        current.supportsSmartTest == original.supportsSmartTest

    private fun smartConflictResult(operation: String, diagnosticTag: String) = serviceMutationResult(
        operation, MutationResultStatus.CONFIRMED_FAILURE, false,
        errorCategory = MutationErrorCategory.CONFLICT,
        diagnosticTag = diagnosticTag,
    )

    private fun smartUnsupportedFailure() = DsmFailure(
        102,
        "Drive testing is unavailable",
        "Use Storage Manager to check this drive.",
        kind = DsmErrorKind.FEATURE_UNSUPPORTED,
    )

    private fun smartTargetUnavailableFailure() = DsmFailure(
        null,
        "The selected drive is no longer available",
        "Refresh storage information and choose the drive again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    suspend fun disconnectConnectionResult(id: String): MutationResult {
        val normalizedId = id.trim()
        if (normalizedId.isEmpty()) {
            return serviceMutationResult(
                operation = "connectionDisconnect",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "connection.disconnect.invalid-input",
            )
        }
        if (!supportsVersion("SYNO.Core.CurrentConnection", 1)) {
            return unsupportedServiceMutation(
                operation = "connectionDisconnect",
                diagnosticTag = "connection.disconnect.unsupported-version",
            )
        }
        var target: ActiveConnection? = null
        return verifiedServiceMutation(
            operation = "connectionDisconnect",
            targetKey = "connection:$normalizedId",
            requiredApi = "SYNO.Core.CurrentConnection",
            preflight = {
                val current = connectionList().firstOrNull { it.id == normalizedId }
                target = current
                current?.canDisconnect == true && current.hasDisconnectIdentifier()
            },
            submit = {
                val connection = checkNotNull(target)
                val common = mapOf(
                    "who" to JsonPrimitive(connection.user),
                    "from" to JsonPrimitive(connection.client),
                )
                val isHttp = connection.type.equals("HTTP/HTTPS", ignoreCase = true)
                val serviceConnections = if (isHttp) {
                    JsonArray(emptyList())
                } else {
                    JsonArray(
                        listOf(
                            JsonObject(
                                common + mapOf(
                                    "pid" to JsonPrimitive(checkNotNull(connection.processId)),
                                    "type" to JsonPrimitive(connection.type.orEmpty()),
                                ),
                            ),
                        ),
                    )
                }
                val httpConnections = if (isHttp) {
                    JsonArray(
                        listOf(
                            JsonObject(
                                common + mapOf(
                                    "did" to JsonPrimitive(checkNotNull(connection.deviceId)),
                                    "descr" to JsonPrimitive(connection.description.orEmpty()),
                                ),
                            ),
                        ),
                    )
                } else {
                    JsonArray(emptyList())
                }
                call(
                    "SYNO.Core.CurrentConnection",
                    "kick_connection",
                    mapOf(
                        "service_conn" to serviceConnections.toString(),
                        "http_conn" to httpConnections.toString(),
                    ),
                    version = 1,
                )
            },
            verify = {
                val expected = checkNotNull(target)
                verifyConnectionAbsent(expected)
            },
        )
    }

    /** 读取当前连接并保留失败语义，供危险断开操作完成后专项核对。 */
    suspend fun activeConnections(): List<ActiveConnection> = connectionList()

    /** 危险操作完成后使用严格契约专项回读；失败不得折叠为空列表。 */
    suspend fun activeAccounts(): List<NasAccount> = strictAccountMutationList()

    /** 危险操作完成后使用严格契约专项回读；失败不得折叠为空列表。 */
    suspend fun activeGroups(): List<NasGroup> = strictGroupMutationList()

    /** 套件启停后使用严格契约专项回读；卸载专属字段缺失不影响启停状态核对。 */
    suspend fun activePackagesForControl(): List<PackageInfo> =
        strictPackageMutationList(requireUninstallFields = false)

    /** 套件卸载后使用严格契约专项回读；卸载许可字段必须完整。 */
    suspend fun activePackagesForUninstall(): List<PackageInfo> =
        strictPackageMutationList(requireUninstallFields = true)

    @Deprecated("Use the operation-specific activePackagesForControl/activePackagesForUninstall reader")
    suspend fun activePackages(): List<PackageInfo> = activePackagesForUninstall()

    suspend fun deleteAccountResult(original: NasAccount): MutationResult =
        deleteDirectoryEntryResult(original, null)

    suspend fun deleteGroupResult(original: NasGroup): MutationResult =
        deleteDirectoryEntryResult(original, null)

    @Deprecated("Use deleteAccountResult(original) to preserve the account baseline")
    suspend fun deleteAccountResult(name: String): MutationResult =
        deleteDirectoryEntryLegacyResult(name, isGroup = false)

    @Deprecated("Use deleteGroupResult(original) to preserve the group baseline")
    suspend fun deleteGroupResult(name: String): MutationResult =
        deleteDirectoryEntryLegacyResult(name, isGroup = true)

    /**
     * 兼容旧调用方的入口；无法提供编辑前基线，因此只保留既有目标预检。
     * 正式编辑流程必须调用接收 original 与 desired 的重载，避免覆盖并发修改。
     */
    suspend fun saveEthernetInterfaceResult(value: NasEthernetInterface): MutationResult =
        saveEthernetInterfaceResultInternal(original = null, desired = value)

    suspend fun saveEthernetInterfaceResult(
        original: NasEthernetInterface,
        desired: NasEthernetInterface,
    ): MutationResult = saveEthernetInterfaceResultInternal(original, desired)

    private suspend fun saveEthernetInterfaceResultInternal(
        original: NasEthernetInterface?,
        desired: NasEthernetInterface,
    ): MutationResult {
        val normalizedOriginal = original?.normalizedEthernetInput()
        val normalized = desired.normalizedEthernetInput()
        if (
            !isValidEthernetInterface(normalized) ||
            (normalizedOriginal != null && (
                !isValidEthernetInterface(normalizedOriginal) ||
                    normalizedOriginal.id != normalized.id
                ))
        ) {
            return serviceMutationResult(
                operation = "ethernetUpdate",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "network.ethernet.invalid-input",
            )
        }
        if (
            !supportsVersion(ETHERNET_API, 1) ||
            !supportsVersion(ETHERNET_API, 2)
        ) {
            return unsupportedServiceMutation(
                operation = "ethernetUpdate",
                diagnosticTag = "network.ethernet.unsupported-version",
            )
        }
        return verifiedServiceMutation(
            operation = "ethernetUpdate",
            targetKey = "ethernet:${normalized.id}",
            requiredApi = ETHERNET_API,
            preflight = {
                val current = ethernetInterfaces().firstOrNull { it.id == normalized.id }
                current != null &&
                    (normalizedOriginal == null || current.matches(normalizedOriginal)) &&
                    !current.matches(normalized)
            },
            submit = {
                call(
                    ETHERNET_API,
                    "set",
                    mapOf("configs" to ethernetConfiguration(normalized).toString()),
                    version = 1,
                )
            },
            verify = {
                ethernetInterfaceDetail(normalized.id).matches(normalized)
            },
        )
    }

    /** 读取物理网卡并保留能力、权限、网络与响应结构失败语义。 */
    suspend fun activeEthernetInterfaces(): List<NasEthernetInterface> = ethernetInterfaces()

    suspend fun testDdnsResult(value: NasDdnsDraft): MutationResult {
        val draft = value.normalized()
        if (!isValidDdnsDraft(draft)) return invalidDdnsResult("ddnsProviderTest")
        if (!supportsDdnsV1()) return unsupportedDdnsResult("ddnsProviderTest")
        val targetKey = ddnsProviderMutationKey(draft.providerId)
        if (!claimServiceMutation(targetKey)) return duplicateDdnsResult("ddnsProviderTest", "ddns.test.duplicate")
        var submitted = false
        return try {
            val directory = ddnsDirectory()
            if (
                directory.providers.none { it.id == draft.providerId } ||
                draft.originalProviderId?.let { it != draft.providerId } == true
            ) {
                invalidDdnsResult("ddnsProviderTest")
            } else {
                currentCoroutineContext().ensureActive()
                submitted = true
                call(DDNS_RECORD_API, "test", ddnsParameters(draft), version = 1)
                serviceMutationResult(
                    operation = "ddnsProviderTest",
                    status = MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    diagnosticTag = "ddns.test.accepted",
                )
            }
        } catch (cancelled: CancellationException) {
            serviceMutationResult(
                operation = "ddnsProviderTest",
                status = if (submitted) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                else MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = submitted,
                requiresRefresh = submitted,
                diagnosticTag = "ddns.test.cancelled",
            )
        } catch (error: Throwable) {
            serviceMutationFailure(
                operation = "ddnsProviderTest",
                failure = error.asRepositoryFailure(),
                submitted = submitted,
                diagnosticTag = "ddns.test.failed",
            )
        } finally {
            withContext(NonCancellable) { releaseServiceMutation(targetKey) }
        }
    }

    suspend fun saveDdnsResult(original: NasDdnsRecord?, desired: NasDdnsDraft): MutationResult {
        val draft = desired.normalized()
        if (!isValidDdnsDraft(draft)) return invalidDdnsResult("ddnsRecordSave")
        if (!supportsDdnsV1()) return unsupportedDdnsResult("ddnsRecordSave")
        if (
            (original == null) != (draft.originalProviderId == null) ||
            original?.providerId != draft.originalProviderId ||
            original?.providerId != null && original.providerId != draft.providerId
        ) return invalidDdnsResult("ddnsRecordSave")
        return verifiedServiceMutation(
            operation = "ddnsRecordSave",
            targetKey = ddnsProviderMutationKey(draft.providerId),
            requiredApi = DDNS_RECORD_API,
            preflight = {
                val directory = ddnsDirectory()
                directory.providers.any { it.id == draft.providerId } && if (original == null) {
                    directory.records.none { it.providerId == draft.providerId }
                } else {
                    directory.records.firstOrNull { it.providerId == draft.providerId }
                        ?.hasSameDdnsBaseline(original) == true
                }
            },
            submit = {
                call(
                    DDNS_RECORD_API,
                    if (original == null) "create" else "set",
                    ddnsParameters(draft),
                    version = 1,
                )
            },
            verify = {
                ddnsDirectory().records.firstOrNull { it.providerId == draft.providerId }
                    ?.matches(draft) == true
            },
            singleAmbiguousVerification = true,
        )
    }

    /** 兼容旧调用；编辑流程必须迁移到带原始记录的重载，才能拒绝陈旧覆盖。 */
    @Deprecated("Use saveDdnsResult(original, desired) to preserve the edit baseline")
    suspend fun saveDdnsResult(value: NasDdnsDraft): MutationResult {
        val draft = value.normalized()
        if (!isValidDdnsDraft(draft)) return invalidDdnsResult("ddnsRecordSave")
        if (!supportsDdnsV1()) return unsupportedDdnsResult("ddnsRecordSave")
        val original = draft.originalProviderId?.let { providerId ->
            try {
                ddnsDirectory().records.firstOrNull { it.providerId == providerId }
            } catch (error: Throwable) {
                return serviceMutationFailure(
                    operation = "ddnsRecordSave",
                    failure = error.asRepositoryFailure(),
                    submitted = false,
                    diagnosticTag = "ddns.legacy-baseline.failed",
                )
            }
        }
        return saveDdnsResult(original, draft)
    }

    suspend fun deleteDdnsResult(original: NasDdnsRecord): MutationResult {
        val providerId = original.providerId
        if (!isSafeDdnsProviderId(providerId)) return invalidDdnsResult("ddnsRecordDelete")
        if (!supportsDdnsV1()) return unsupportedDdnsResult("ddnsRecordDelete")
        return verifiedServiceMutation(
            operation = "ddnsRecordDelete",
            targetKey = ddnsProviderMutationKey(providerId),
            requiredApi = DDNS_RECORD_API,
            preflight = {
                ddnsDirectory().records.firstOrNull { it.providerId == providerId }
                    ?.hasSameDdnsBaseline(original) == true
            },
            submit = {
                call(
                    DDNS_RECORD_API,
                    "delete",
                    mapOf("id" to JsonArray(listOf(JsonPrimitive(providerId))).toString()),
                    version = 1,
                )
            },
            verify = { ddnsDirectory().records.none { it.providerId == providerId } },
            singleAmbiguousVerification = true,
        )
    }

    /** 兼容旧调用；正式删除必须携带用户确认时看到的完整原始记录。 */
    @Deprecated("Use deleteDdnsResult(original) to preserve the deletion baseline")
    suspend fun deleteDdnsResult(providerId: String): MutationResult {
        val normalized = providerId.trim()
        if (!isSafeDdnsProviderId(normalized)) return invalidDdnsResult("ddnsRecordDelete")
        if (!supportsDdnsV1()) return unsupportedDdnsResult("ddnsRecordDelete")
        val original = try {
            ddnsDirectory().records.firstOrNull { it.providerId == normalized }
        } catch (error: Throwable) {
            return serviceMutationFailure(
                operation = "ddnsRecordDelete",
                failure = error.asRepositoryFailure(),
                submitted = false,
                diagnosticTag = "ddns.legacy-baseline.failed",
            )
        }
        return original?.let { deleteDdnsResult(it) } ?: serviceMutationResult(
            operation = "ddnsRecordDelete",
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "ddns.delete.target-changed",
        )
    }

    suspend fun refreshDdnsResult(expectedProviderIds: Set<String>): MutationResult {
        val normalizedIds = expectedProviderIds.map(String::trim).toSet()
        if (
            normalizedIds.isEmpty() || normalizedIds.size != expectedProviderIds.size ||
            normalizedIds.any { !isSafeDdnsProviderId(it) }
        ) return invalidDdnsResult("ddnsAddressRefresh")
        if (!supportsDdnsV1()) return unsupportedDdnsResult("ddnsAddressRefresh")
        return verifiedServiceMutation(
            operation = "ddnsAddressRefresh",
            targetKey = DDNS_GLOBAL_MUTATION_KEY,
            requiredApi = DDNS_RECORD_API,
            preflight = {
                ddnsDirectory().records.map(NasDdnsRecord::providerId).toSet() == normalizedIds
            },
            submit = { call(DDNS_RECORD_API, "update_ip_address", version = 1) },
            verify = {
                ddnsDirectory()
                true
            },
            allowAmbiguousConfirmation = false,
        )
    }

    @Deprecated("Use refreshDdnsResult(expectedProviderIds) to preserve confirmed targets")
    suspend fun refreshDdnsResult(): MutationResult {
        if (!supportsDdnsV1()) return unsupportedDdnsResult("ddnsAddressRefresh")
        val ids = try {
            ddnsDirectory().records.map(NasDdnsRecord::providerId).toSet()
        } catch (error: Throwable) {
            return serviceMutationFailure(
                operation = "ddnsAddressRefresh",
                failure = error.asRepositoryFailure(),
                submitted = false,
                diagnosticTag = "ddns.legacy-baseline.failed",
            )
        }
        return refreshDdnsResult(ids)
    }

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

    private fun invalidDdnsResult(operation: String) = serviceMutationResult(
        operation = operation,
        status = MutationResultStatus.CONFIRMED_FAILURE,
        submitted = false,
        errorCategory = MutationErrorCategory.VALIDATION,
        diagnosticTag = "ddns.invalid-input",
    )

    private fun unsupportedDdnsResult(operation: String) = unsupportedServiceMutation(
        operation = operation,
        diagnosticTag = "ddns.unsupported-version",
    )

    private fun duplicateDdnsResult(operation: String, diagnosticTag: String) = serviceMutationResult(
        operation = operation,
        status = MutationResultStatus.CONFIRMED_FAILURE,
        submitted = false,
        errorCategory = MutationErrorCategory.CONFLICT,
        diagnosticTag = diagnosticTag,
    )

    suspend fun fileServiceSettings(): NasFileServiceSettings {
        val hasSmb = supports("SYNO.Core.FileServ.SMB")
        val hasNfs = supports("SYNO.Core.FileServ.NFS")
        val hasFtp = supportsVersion("SYNO.Core.FileServ.FTP", 1)
        val hasSftp = supportsVersion("SYNO.Core.FileServ.FTP.SFTP", 1)
        val hasWebDiscovery = supportsVersion("SYNO.Core.Web.DSM", 2)
        val hasFileDiscovery = supportsVersion("SYNO.Core.FileServ.ServiceDiscovery", 1)
        if (!hasSmb && !hasNfs && !hasFtp && !hasSftp && !hasWebDiscovery && !hasFileDiscovery) {
            throw DsmFailure(
                102,
                "Feature unsupported",
                "Update DSM or use another account.",
                kind = DsmErrorKind.FEATURE_UNSUPPORTED,
            )
        }
        val smb = if (hasSmb) call("SYNO.Core.FileServ.SMB", "get") else null
        val nfs = if (hasNfs) call("SYNO.Core.FileServ.NFS", "get") else null
        val ftp = if (hasFtp) call("SYNO.Core.FileServ.FTP", "get", version = 1) else null
        val sftp = if (hasSftp) call("SYNO.Core.FileServ.FTP.SFTP", "get", version = 1) else null
        val web = if (hasWebDiscovery) call("SYNO.Core.Web.DSM", "get", version = 2) else null
        val discovery = if (hasFileDiscovery) {
            call("SYNO.Core.FileServ.ServiceDiscovery", "get", version = 1)
        } else null
        return NasFileServiceSettings(
            isSmbEnabled = smb?.bool("enable_samba"),
            isNfsEnabled = nfs?.bool("enable_nfs"),
            isFtpEnabled = ftp?.bool("enable_ftp"),
            isFtpsEnabled = ftp?.bool("enable_ftps"),
            ftpPort = ftp?.int("portnum"),
            isSftpEnabled = sftp?.bool("enable"),
            sftpPort = sftp?.int("portnum") ?: sftp?.int("sftp_portnum"),
            isSsdpEnabled = web?.bool("enable_ssdp"),
            isBonjourEnabled = web?.bool("enable_avahi"),
            isSmbTimeMachineEnabled = discovery?.bool("enable_smb_time_machine"),
        )
    }

    suspend fun saveFileServiceSettingsResult(expected: NasFileServiceSettings): MutationResult {
        if (!isValidFileServiceSettings(expected)) {
            return invalidSettingsResult("fileServiceSettingsUpdate", "file-services.invalid-input")
        }
        if (!claimServiceMutation("file-services")) {
            return duplicateSettingsResult("fileServiceSettingsUpdate", "file-services.duplicate")
        }
        try {
            val current = try {
                fileServiceSettings()
            } catch (error: Throwable) {
                return serviceMutationFailure(
                    "fileServiceSettingsUpdate",
                    error.asRepositoryFailure(),
                    false,
                    "file-services.preflight-failed",
                )
            }
            val steps = fileServiceSteps(current, expected)
            if (steps.isEmpty()) {
                return settingsMutationResult(
                    "fileServiceSettingsUpdate",
                    MutationResultStatus.CONFIRMED_FAILURE,
                    false,
                    total = 1,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "file-services.no-changes",
                )
            }
            if (!fileServiceStepsSupported(steps)) {
                return settingsMutationResult(
                    "fileServiceSettingsUpdate",
                    MutationResultStatus.UNSUPPORTED,
                    false,
                    total = steps.size,
                    failed = steps.size,
                    errorCategory = MutationErrorCategory.UNSUPPORTED,
                    diagnosticTag = "file-services.unsupported",
                )
            }
            var submissionFailure: DsmFailure? = null
            var cancellationAfterSubmission = false
            var accepted = 0
            var submissionStarted = false
            for (step in steps) {
                try {
                    currentCoroutineContext().ensureActive()
                    // 进入网络调用后即可能已在 NAS 生效，不能等响应返回才标记为已提交。
                    submissionStarted = true
                    submitFileServiceStep(step, expected)
                    accepted += 1
                } catch (_: CancellationException) {
                    cancellationAfterSubmission = submissionStarted
                    break
                } catch (error: Throwable) {
                    submissionFailure = error.asRepositoryFailure()
                    break
                }
            }
            if (accepted == 0 && cancellationAfterSubmission.not() && submissionFailure == null) {
                return settingsMutationResult(
                    "fileServiceSettingsUpdate",
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    false,
                    total = steps.size,
                    diagnosticTag = "file-services.cancelled-before-submission",
                )
            }
            val actual = try {
                withContext(NonCancellable) { fileServiceSettings() }
            } catch (error: Throwable) {
                val failure = submissionFailure
                if (failure != null && !failure.isAmbiguousSettingsFailure()) {
                    return serviceMutationFailure(
                        "fileServiceSettingsUpdate",
                        failure,
                        true,
                        "file-services.submission-failed",
                    )
                }
                return settingsMutationResult(
                    "fileServiceSettingsUpdate",
                    if (cancellationAfterSubmission) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    true,
                    total = steps.size,
                    unknown = steps.size,
                    requiresRefresh = true,
                    errorCategory = error.asRepositoryFailure().mutationErrorCategory(),
                    diagnosticTag = "file-services.readback-unverified",
                )
            }
            val succeeded = steps.count { it.matches(actual, expected) }
            return settingsVerificationResult(
                operation = "fileServiceSettingsUpdate",
                total = steps.size,
                succeeded = succeeded,
                submissionFailure = submissionFailure,
                cancellationAfterSubmission = cancellationAfterSubmission,
                diagnosticPrefix = "file-services",
            )
        } finally {
            releaseServiceMutation("file-services")
        }
    }

    suspend fun terminalSettings(): NasTerminalSettings {
        val data = call("SYNO.Core.Terminal", "get")
        val ssh = data.bool("enable_ssh")
        val telnet = data.bool("enable_telnet")
        if (ssh == null || telnet == null) throw invalidSettingsResponse("terminal")
        return NasTerminalSettings(ssh, telnet, data.int("ssh_port")?.takeIf(::isValidPort))
    }

    suspend fun saveTerminalSettingsResult(expected: NasTerminalSettings): MutationResult {
        if (expected.sshPort?.let(::isValidPort) == false) {
            return invalidSettingsResult("terminalSettingsUpdate", "terminal.invalid-input")
        }
        return singleSettingsMutation(
            operation = "terminalSettingsUpdate",
            targetKey = "terminal-settings",
            requiredApi = "SYNO.Core.Terminal",
            expected = expected,
            load = ::terminalSettings,
            changedFields = { current, value ->
                buildList {
                    if (current.isSshEnabled != value.isSshEnabled) add("ssh")
                    if (current.isTelnetEnabled != value.isTelnetEnabled) add("telnet")
                    if (value.sshPort != null && current.sshPort != value.sshPort) add("ssh_port")
                }
            },
            submit = {
                val parameters = mutableMapOf(
                    "enable_ssh" to expected.isSshEnabled.toString(),
                    "enable_telnet" to expected.isTelnetEnabled.toString(),
                )
                expected.sshPort?.let { parameters["ssh_port"] = it.toString() }
                call("SYNO.Core.Terminal", "set", parameters, version = 1)
            },
            fieldMatches = { field, actual, value ->
                when (field) {
                    "ssh" -> actual.isSshEnabled == value.isSshEnabled
                    "telnet" -> actual.isTelnetEnabled == value.isTelnetEnabled
                    else -> actual.sshPort == value.sshPort
                }
            },
            diagnosticPrefix = "terminal",
        )
    }

    suspend fun proxySettings(): NasProxySettings {
        if (!supportsVersion(PROXY_API, 1)) throw invalidSettingsResponse("proxy")
        val data = call(PROXY_API, "get", version = 1)
        val enabled = data.bool("enable") ?: throw invalidSettingsResponse("proxy")
        return NasProxySettings(enabled, data.string("http_host").orEmpty(), data.int("http_port"))
    }

    suspend fun saveProxySettingsResult(value: NasProxySettings): MutationResult {
        val expected = value.copy(host = value.host.trim())
        if (!isValidProxySettings(expected)) {
            return invalidSettingsResult("proxySettingsUpdate", "proxy.invalid-input")
        }
        if (!supportsVersion(PROXY_API, 1)) {
            return unsupportedServiceMutation("proxySettingsUpdate", "proxy.unsupported-version")
        }
        return singleSettingsMutation(
            operation = "proxySettingsUpdate",
            targetKey = "proxy-settings",
            requiredApi = PROXY_API,
            expected = expected,
            load = ::proxySettings,
            changedFields = { current, target ->
                buildList {
                    if (current.isEnabled != target.isEnabled) add("enabled")
                    if (target.isEnabled && current.host != target.host) add("host")
                    if (target.isEnabled && current.port != target.port) add("port")
                }
            },
            submit = {
                val parameters = mutableMapOf("enable" to expected.isEnabled.toString())
                if (expected.isEnabled) {
                    parameters["http_host"] = expected.host
                    parameters["http_port"] = checkNotNull(expected.port).toString()
                }
                call(PROXY_API, "set", parameters, version = 1)
            },
            fieldMatches = { field, actual, target ->
                when (field) {
                    "enabled" -> actual.isEnabled == target.isEnabled
                    "host" -> actual.host == target.host
                    else -> actual.port == target.port
                }
            },
            diagnosticPrefix = "proxy",
        )
    }

    suspend fun regionSettings(): NasRegionSettings {
        if (!supportsVersion(REGION_API, 1) || !supportsVersion(REGION_API, 3)) {
            throw invalidSettingsResponse("region")
        }
        val data = call(REGION_API, "get", version = 3)
        val zonesData = call(REGION_API, "listzone", version = 1)
        val dateFormat = data.string("date_format")?.takeIf(String::isNotBlank)
        val timeFormat = data.string("time_format")?.takeIf(String::isNotBlank)
        val timeZone = data.string("timezone")?.takeIf(String::isNotBlank)
        val mode = data.string("enable_ntp")?.lowercase(Locale.ROOT)
        if (dateFormat == null || timeFormat == null || timeZone == null || mode == null) {
            throw invalidSettingsResponse("region")
        }
        val isNetworkTimeEnabled = when (mode) {
            "ntp", "true", "yes", "1", "enabled" -> true
            "manual", "false", "no", "0", "disabled" -> false
            else -> throw invalidSettingsResponse("region")
        }
        val zones = zonesData.elements("zonedata").mapNotNull { element ->
            val zone = element as? JsonObject ?: return@mapNotNull null
            val id = zone.string("value")?.takeIf(String::isNotBlank) ?: return@mapNotNull null
            NasTimeZoneOption(id, zone.string("display")?.takeIf(String::isNotBlank) ?: id)
        }.distinctBy(NasTimeZoneOption::id)
        if (zones.none { it.id == timeZone }) throw invalidSettingsResponse("region")
        return NasRegionSettings(
            dateFormat = dateFormat,
            timeFormat = timeFormat,
            timeZone = timeZone,
            isNetworkTimeEnabled = isNetworkTimeEnabled,
            timeServers = data.string("server").orEmpty().split(',')
                .map(String::trim).filter(String::isNotEmpty),
            manualDateTime = parseNasManualDateTime(
                data.string("date"), data.int("hour"), data.int("minute"), data.int("second"),
            ),
            timeZones = zones,
        )
    }

    /** 配置提交与立即校时是两个副作用边界；任一提交后的未知结果都禁止自动重放。 */
    suspend fun saveRegionSettingsResult(value: NasRegionSettings): MutationResult {
        val expectedInput = value.copy(
            dateFormat = value.dateFormat.trim(),
            timeFormat = value.timeFormat.trim(),
            timeServers = value.timeServers.map(String::trim).filter(String::isNotEmpty),
        )
        if (!isValidRegionSettings(expectedInput)) {
            return invalidSettingsResult("regionSettingsUpdate", "region.invalid-input")
        }
        if (
            !supportsVersion(REGION_API, 1) ||
            !supportsVersion(REGION_API, 2) ||
            !supportsVersion(REGION_API, 3)
        ) {
            return unsupportedServiceMutation("regionSettingsUpdate", "region.unsupported")
        }
        if (!claimServiceMutation("region-settings")) {
            return duplicateSettingsResult("regionSettingsUpdate", "region.duplicate")
        }
        try {
            val current = try {
                regionSettings()
            } catch (_: CancellationException) {
                return settingsMutationResult(
                    "regionSettingsUpdate",
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    total = 0,
                    diagnosticTag = "region.cancelled-before-submission",
                )
            } catch (error: Throwable) {
                return serviceMutationFailure(
                    "regionSettingsUpdate", error.asRepositoryFailure(), false, "region.preflight-failed",
                )
            }
            if (current.timeZones.none { it.id == expectedInput.timeZone }) {
                return invalidSettingsResult("regionSettingsUpdate", "region.timezone-not-returned")
            }
            val expected = expectedInput.copy(
                manualDateTime = if (expectedInput.isNetworkTimeEnabled) {
                    expectedInput.manualDateTime
                } else {
                    expectedInput.manualDateTime ?: current.manualDateTime
                },
                timeZones = current.timeZones,
            )
            if (!expected.isNetworkTimeEnabled && expected.manualDateTime == null) {
                return invalidSettingsResult("regionSettingsUpdate", "region.missing-manual-time")
            }
            val fields = regionChangedFields(current, expected, value.manualDateTime != null)
            val needsSync = expected.isNetworkTimeEnabled &&
                (!current.isNetworkTimeEnabled || current.timeServers != expected.timeServers)
            val total = fields.size + if (needsSync) 1 else 0
            if (fields.isEmpty()) {
                return settingsMutationResult(
                    "regionSettingsUpdate", MutationResultStatus.CONFIRMED_FAILURE, false,
                    total = 1, failed = 1, errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "region.no-changes",
                )
            }
            var setFailure: DsmFailure? = null
            var cancelled = false
            var submissionStarted = false
            try {
                currentCoroutineContext().ensureActive()
                submissionStarted = true
                call(REGION_API, "set", regionParameters(expected), version = 3)
            } catch (_: CancellationException) {
                if (!submissionStarted) {
                    return settingsMutationResult(
                        "regionSettingsUpdate",
                        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        submitted = false,
                        total = fields.size,
                        diagnosticTag = "region.cancelled-before-submission",
                    )
                }
                cancelled = true
            } catch (error: Throwable) {
                setFailure = error.asRepositoryFailure()
            }
            val afterSet = try {
                withContext(NonCancellable) { regionSettings() }
            } catch (readbackError: Throwable) {
                if (setFailure != null && !setFailure.isAmbiguousSettingsFailure()) {
                    return serviceMutationFailure(
                        "regionSettingsUpdate", setFailure, true, "region.submission-failed",
                        affectedCount = fields.size,
                    )
                }
                return settingsMutationResult(
                    "regionSettingsUpdate",
                    if (cancelled) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    true, total, unknown = total, requiresRefresh = true,
                    errorCategory = readbackError.asRepositoryFailure().mutationErrorCategory(),
                    diagnosticTag = "region.readback-unverified",
                )
            }
            val succeeded = fields.count { regionFieldMatches(it, afterSet, expected) }
            if (setFailure != null || cancelled || succeeded != fields.size) {
                val pendingSync = if (needsSync) 1 else 0
                val verifiedResult = settingsVerificationResult(
                    "regionSettingsUpdate", fields.size, succeeded, setFailure, cancelled, "region",
                )
                if (pendingSync == 0) return verifiedResult
                val failed = verifiedResult.counts.failed
                val unknown = verifiedResult.counts.unknown + pendingSync
                return settingsMutationResult(
                    "regionSettingsUpdate",
                    if (succeeded > 0) MutationResultStatus.PARTIAL_SUCCESS else verifiedResult.status,
                    true, total, succeeded, failed, unknown, requiresRefresh = true,
                    errorCategory = verifiedResult.errorCategory,
                    diagnosticTag = "region.configuration-not-fully-confirmed",
                )
            }
            if (!needsSync) {
                return settingsMutationResult(
                    "regionSettingsUpdate", MutationResultStatus.CONFIRMED_SUCCESS, true,
                    total, succeeded = fields.size, diagnosticTag = "region.confirmed",
                )
            }
            var syncFailure: DsmFailure? = null
            var syncCancelled = false
            try {
                call(
                    REGION_API, "sync",
                    mapOf("servers" to JsonArray(expected.timeServers.map(::JsonPrimitive)).toString()),
                    version = 2,
                )
            } catch (_: CancellationException) {
                syncCancelled = true
            } catch (error: Throwable) {
                syncFailure = error.asRepositoryFailure()
            }
            if (syncFailure != null || syncCancelled) {
                return settingsMutationResult(
                    "regionSettingsUpdate", MutationResultStatus.PARTIAL_SUCCESS, true,
                    total, succeeded = fields.size,
                    failed = if (syncFailure != null && !syncFailure.isAmbiguousSettingsFailure()) 1 else 0,
                    unknown = if (syncFailure == null || syncFailure.isAmbiguousSettingsFailure()) 1 else 0,
                    requiresRefresh = true,
                    errorCategory = syncFailure?.mutationErrorCategory(),
                    diagnosticTag = "region.sync-unverified",
                )
            }
            val final = try {
                withContext(NonCancellable) { regionSettings() }
            } catch (_: Throwable) {
                return settingsMutationResult(
                    "regionSettingsUpdate", MutationResultStatus.PARTIAL_SUCCESS, true,
                    total, succeeded = fields.size, unknown = 1, requiresRefresh = true,
                    diagnosticTag = "region.sync-readback-unverified",
                )
            }
            val finalSucceeded = fields.count { regionFieldMatches(it, final, expected) }
            return if (finalSucceeded == fields.size) {
                settingsMutationResult(
                    "regionSettingsUpdate", MutationResultStatus.CONFIRMED_SUCCESS, true,
                    total, succeeded = total, diagnosticTag = "region.sync-accepted",
                )
            } else {
                settingsMutationResult(
                    "regionSettingsUpdate", MutationResultStatus.PARTIAL_SUCCESS, true,
                    total, succeeded = finalSucceeded, failed = fields.size - finalSucceeded,
                    unknown = 1, requiresRefresh = true,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "region.sync-readback-mismatch",
                )
            }
        } finally {
            releaseServiceMutation("region-settings")
        }
    }

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
                if (states.map { it.first }.distinct().size != states.size ||
                    states.map { it.first }.toSet() != adapters.map { it.first }.toSet()
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

    suspend fun saveSecuritySettingsResult(
        original: NasSecuritySettings,
        desired: NasSecuritySettings,
    ): MutationResult = saveSecuritySettingsResultInternal(original, desired, null)

    private suspend fun saveSecuritySettingsResultInternal(
        original: NasSecuritySettings,
        desired: NasSecuritySettings,
        verifiedCurrent: NasSecuritySettings?,
    ): MutationResult {
        if (!isValidSecuritySettings(original) || !isValidSecuritySettings(desired)) {
            return invalidSettingsResult("securitySettingsUpdate", "security.invalid-input")
        }
        val plannedSteps = securitySteps(original, desired) ?: return invalidSettingsResult(
            "securitySettingsUpdate", "security.adapters-or-profile-invalid",
        )
        if (plannedSteps.isEmpty()) return settingsMutationResult(
            "securitySettingsUpdate", MutationResultStatus.CONFIRMED_FAILURE, false,
            total = 1, failed = 1, errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "security.no-changes",
        )
        if (!securityStepsSupported(plannedSteps, desired)) return settingsMutationResult(
            "securitySettingsUpdate", MutationResultStatus.UNSUPPORTED, false,
            total = plannedSteps.size, failed = plannedSteps.size,
            errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = "security.unsupported",
        )
        if (!claimServiceMutation("security-settings")) {
            return duplicateSettingsResult(
                "securitySettingsUpdate", "security.duplicate", plannedSteps.size,
            )
        }
        try {
            val current = verifiedCurrent ?: try {
                    securitySettings()
                } catch (_: CancellationException) {
                    return settingsMutationResult(
                        "securitySettingsUpdate", MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                        total = plannedSteps.size, diagnosticTag = "security.cancelled-before-submission",
                    )
                } catch (error: Throwable) {
                    return serviceMutationFailure(
                        "securitySettingsUpdate", error.asRepositoryFailure(), false, "security.preflight-failed",
                        affectedCount = plannedSteps.size,
                    )
                }
            if (!securityBaselineMatches(current, original)) return settingsMutationResult(
                "securitySettingsUpdate", MutationResultStatus.CONFIRMED_FAILURE, false,
                total = plannedSteps.size, failed = plannedSteps.size,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "security.baseline-changed",
            )
            val steps = securitySteps(current, desired) ?: return invalidSettingsResult(
                "securitySettingsUpdate", "security.adapters-or-profile-invalid",
            )
            var submissionFailure: DsmFailure? = null
            var cancelled = false
            var submitted = 0
            var currentStepMayHaveBeenSubmitted = false
            for (step in steps) {
                try {
                    currentCoroutineContext().ensureActive()
                    currentStepMayHaveBeenSubmitted = true
                    submitSecurityStep(step, desired, current)
                    submitted += 1
                    currentStepMayHaveBeenSubmitted = false
                } catch (_: CancellationException) {
                    cancelled = true
                    break
                } catch (error: Throwable) {
                    submissionFailure = error.asRepositoryFailure()
                    break
                }
            }
            if (submitted == 0 && cancelled && !currentStepMayHaveBeenSubmitted) {
                return settingsMutationResult(
                    "securitySettingsUpdate", MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    false, total = steps.size, diagnosticTag = "security.cancelled-before-submission",
                )
            }
            val actual = try {
                withContext(NonCancellable) { securitySettings() }
            } catch (readbackError: Throwable) {
                if (submissionFailure != null && submitted == 0 &&
                    !submissionFailure.isAmbiguousSettingsFailure()
                ) {
                    return serviceMutationFailure(
                        "securitySettingsUpdate", submissionFailure, true, "security.submission-rejected",
                        affectedCount = steps.size,
                    )
                }
                val possible = (submitted + if (submissionFailure?.isAmbiguousSettingsFailure() == true || cancelled) 1 else 0)
                    .coerceAtMost(steps.size)
                return settingsMutationResult(
                    "securitySettingsUpdate",
                    if (cancelled) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    true, steps.size, failed = steps.size - possible, unknown = possible,
                    requiresRefresh = true,
                    errorCategory = readbackError.asRepositoryFailure().mutationErrorCategory(),
                    diagnosticTag = "security.readback-unverified",
                )
            }
            val succeeded = steps.count { securityStepMatches(it, actual, desired) }
            return settingsVerificationResult(
                "securitySettingsUpdate", steps.size, succeeded,
                submissionFailure, cancelled, "security",
            )
        } finally {
            withContext(NonCancellable) { releaseServiceMutation("security-settings") }
        }
    }

    /** 兼容旧调用；正式保存必须携带用户确认时看到的完整原始设置。 */
    @Deprecated("Use saveSecuritySettingsResult(original, desired) to preserve the security baseline")
    suspend fun saveSecuritySettingsResult(expected: NasSecuritySettings): MutationResult {
        if (!isValidSecuritySettings(expected)) {
            return invalidSettingsResult("securitySettingsUpdate", "security.invalid-input")
        }
        val original = try {
            securitySettings()
        } catch (_: CancellationException) {
            return settingsMutationResult(
                "securitySettingsUpdate", MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                total = 1, diagnosticTag = "security.cancelled-before-submission",
            )
        } catch (error: Throwable) {
            return serviceMutationFailure(
                "securitySettingsUpdate", error.asRepositoryFailure(), false, "security.legacy-baseline-failed",
            )
        }
        return saveSecuritySettingsResultInternal(original, expected, original)
    }

    /** 关机与重启无法安全回读；明确成功仅表示 DSM 已接受请求。 */
    suspend fun performPowerActionResult(action: NasPowerAction): MutationResult {
        val operation = if (action == NasPowerAction.SHUTDOWN) "nasShutdown" else "nasReboot"
        val prefix = if (action == NasPowerAction.SHUTDOWN) "power.shutdown" else "power.reboot"
        if (!supports("SYNO.Core.System")) {
            return unsupportedServiceMutation(operation, "$prefix.unsupported")
        }
        if (!claimServiceMutation("power-action")) {
            return serviceMutationResult(
                operation, MutationResultStatus.CONFIRMED_FAILURE, false,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "$prefix.duplicate",
            )
        }
        try {
            try {
                call("SYNO.Core.System", "info")
            } catch (cancelled: CancellationException) {
                return serviceMutationResult(
                    operation, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                    diagnosticTag = "$prefix.cancelled-before-submission",
                )
            } catch (error: Throwable) {
                return serviceMutationFailure(
                    operation, error.asRepositoryFailure(), false, "$prefix.preflight-failed",
                )
            }
            val method = if (action == NasPowerAction.SHUTDOWN) "shutdown" else "reboot"
            return try {
                call("SYNO.Core.System", method)
                serviceMutationResult(
                    operation, MutationResultStatus.CONFIRMED_SUCCESS, true,
                    diagnosticTag = "$prefix.accepted",
                )
            } catch (_: CancellationException) {
                settingsMutationResult(
                    operation, MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION, true,
                    total = 1, requiresRefresh = true, unknown = 1,
                    diagnosticTag = "$prefix.cancelled-during-submission",
                )
            } catch (error: Throwable) {
                val failure = error.asRepositoryFailure()
                if (failure.isAmbiguousSettingsFailure()) {
                    settingsMutationResult(
                        operation, MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, true,
                        total = 1, unknown = 1, requiresRefresh = true,
                        errorCategory = failure.mutationErrorCategory(),
                        diagnosticTag = "$prefix.submission-unverified",
                    )
                } else {
                    serviceMutationFailure(operation, failure, true, "$prefix.rejected")
                }
            }
        } finally {
            releaseServiceMutation("power-action")
        }
    }

    suspend fun hardwareSettings(): NasHardwareSettings = hardwareSettingsRead().settings

    suspend fun activeHardwareSettings(): NasHardwareSettings = hardwareSettings()

    private suspend fun hardwareSettingsRead(): HardwareSettingsRead {
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
        if (fanMode != null && fanMode !in FAN_MODES) throw invalidSettingsResponse("hardware-fan-mode")
        val settings = NasHardwareSettings(
            restartsAfterPowerFailure = power?.let {
                strictRequiredSettingsBoolean(it, "rc_power_config", "hardware-power")
            },
            ledBrightness = ledBrightness,
            ledBrightnessMinimum = ledMin,
            ledBrightnessMaximum = ledMax,
            fanMode = fanMode,
            isFanFailureAlertEnabled = beep?.let { strictOptionalSettingsBoolean(it, "fan_fail", "hardware-beep") },
            isVolumeFailureAlertEnabled = beepVolumeFieldName?.let { field ->
                strictRequiredSettingsBoolean(checkNotNull(beep), field, "hardware-beep")
            },
            isPowerOnSoundEnabled = beep?.let {
                strictOptionalSettingsBoolean(it, "poweron_beep", "hardware-beep")
            },
            isPowerOffSoundEnabled = beep?.let {
                strictOptionalSettingsBoolean(it, "poweroff_beep", "hardware-beep")
            },
            isResetSoundEnabled = beep?.let {
                strictOptionalSettingsBoolean(it, "reset_beep", "hardware-beep")
            },
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
        )
        return HardwareSettingsRead(settings, beepVolumeFieldName)
    }

    suspend fun saveHardwareSettingsResult(
        original: NasHardwareSettings,
        desired: NasHardwareSettings,
    ): MutationResult = saveHardwareSettingsResultInternal(original, desired, null)

    private suspend fun saveHardwareSettingsResultInternal(
        original: NasHardwareSettings,
        desired: NasHardwareSettings,
        verifiedCurrent: HardwareSettingsRead?,
    ): MutationResult {
        val expected = normalizeHardwareSettings(desired)
        if (!isValidHardwareSettings(expected, original)) {
            return invalidSettingsResult("hardwareSettingsUpdate", "hardware.invalid-input")
        }
        val plannedSteps = hardwareSteps(original, expected)
        if (plannedSteps.isEmpty()) return settingsMutationResult(
            "hardwareSettingsUpdate", MutationResultStatus.CONFIRMED_FAILURE, false,
            total = 1, failed = 1, errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "hardware.no-changes",
        )
        if (!plannedSteps.all { supportsVersion(it.apiName, 1) }) return settingsMutationResult(
            "hardwareSettingsUpdate", MutationResultStatus.UNSUPPORTED, false,
            total = plannedSteps.size, failed = plannedSteps.size,
            errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = "hardware.unsupported",
        )
        if (!claimServiceMutation("hardware-settings")) {
            return duplicateSettingsResult(
                "hardwareSettingsUpdate", "hardware.duplicate", plannedSteps.size,
            )
        }
        try {
            val currentRead = verifiedCurrent ?: try {
                    hardwareSettingsRead()
                } catch (_: CancellationException) {
                    return settingsMutationResult(
                        "hardwareSettingsUpdate", MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                        total = plannedSteps.size, diagnosticTag = "hardware.cancelled-before-submission",
                    )
                } catch (error: Throwable) {
                    return serviceMutationFailure(
                        "hardwareSettingsUpdate", error.asRepositoryFailure(), false, "hardware.preflight-failed",
                        affectedCount = plannedSteps.size,
                    )
                }
            val current = currentRead.settings
            if (current != original) return settingsMutationResult(
                "hardwareSettingsUpdate", MutationResultStatus.CONFIRMED_FAILURE, false,
                total = plannedSteps.size, failed = plannedSteps.size,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "hardware.baseline-changed",
            )
            val steps = hardwareSteps(current, expected)
            var failure: DsmFailure? = null
            var cancelled = false
            var accepted = 0
            var currentStepMayHaveBeenSubmitted = false
            for (step in steps) {
                try {
                    currentCoroutineContext().ensureActive()
                    currentStepMayHaveBeenSubmitted = true
                    submitHardwareStep(step, expected, current, currentRead.beepVolumeFieldName)
                    accepted += 1
                    currentStepMayHaveBeenSubmitted = false
                } catch (_: CancellationException) {
                    cancelled = true
                    break
                } catch (error: Throwable) {
                    failure = error.asRepositoryFailure()
                    break
                }
            }
            if (accepted == 0 && cancelled && !currentStepMayHaveBeenSubmitted) {
                return settingsMutationResult(
                    "hardwareSettingsUpdate", MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                    total = steps.size, diagnosticTag = "hardware.cancelled-before-submission",
                )
            }
            val actual = try {
                withContext(NonCancellable) { hardwareSettingsRead().settings }
            } catch (readbackError: Throwable) {
                if (failure != null && accepted == 0 && !failure.isAmbiguousSettingsFailure()) {
                    return serviceMutationFailure(
                        "hardwareSettingsUpdate", failure, true, "hardware.submission-rejected",
                        affectedCount = steps.size,
                    )
                }
                val possible = (accepted + if (failure?.isAmbiguousSettingsFailure() == true || cancelled) 1 else 0)
                    .coerceAtMost(steps.size)
                return settingsMutationResult(
                    "hardwareSettingsUpdate",
                    if (cancelled) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    true, steps.size, failed = steps.size - possible, unknown = possible,
                    requiresRefresh = true,
                    errorCategory = readbackError.asRepositoryFailure().mutationErrorCategory(),
                    diagnosticTag = "hardware.readback-unverified",
                )
            }
            val succeeded = steps.count { hardwareStepMatches(it, actual, expected) }
            return settingsVerificationResult(
                "hardwareSettingsUpdate", steps.size, succeeded, failure, cancelled, "hardware",
            )
        } finally {
            withContext(NonCancellable) { releaseServiceMutation("hardware-settings") }
        }
    }

    /** 兼容旧调用；正式保存必须携带用户确认时看到的完整原始设置。 */
    @Deprecated("Use saveHardwareSettingsResult(original, desired) to preserve the hardware baseline")
    suspend fun saveHardwareSettingsResult(value: NasHardwareSettings): MutationResult {
        val originalRead = try {
            hardwareSettingsRead()
        } catch (_: CancellationException) {
            return settingsMutationResult(
                "hardwareSettingsUpdate", MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                total = 1, diagnosticTag = "hardware.cancelled-before-submission",
            )
        } catch (error: Throwable) {
            return serviceMutationFailure(
                "hardwareSettingsUpdate", error.asRepositoryFailure(), false, "hardware.legacy-baseline-failed",
            )
        }
        return saveHardwareSettingsResultInternal(originalRead.settings, value, originalRead)
    }

    private suspend fun deleteDirectoryEntryLegacyResult(name: String, isGroup: Boolean): MutationResult {
        val trimmed = name.trim()
        val operation = if (isGroup) "groupDelete" else "accountDelete"
        if (trimmed.isEmpty()) return serviceMutationResult(
            operation, MutationResultStatus.CONFIRMED_FAILURE, false,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "directory.delete.invalid-input",
        )
        if (isProtectedDirectoryEntry(trimmed, isGroup)) return serviceMutationResult(
            operation, MutationResultStatus.PERMISSION_DENIED, false,
            errorCategory = MutationErrorCategory.PERMISSION,
            diagnosticTag = "directory.delete.protected-entry",
        )
        val apiName = if (isGroup) GROUP_API else USER_API
        if (!supportsVersion(apiName, DIRECTORY_API_VERSION)) {
            return unsupportedServiceMutation(operation, "directory.delete.unsupported")
        }
        return try {
            if (isGroup) {
                val original = strictGroupMutationList().firstOrNull {
                    it.name.equals(trimmed, ignoreCase = true)
                } ?: return directoryTargetChangedResult(operation)
                deleteDirectoryEntryResult(original, original)
            } else {
                val original = strictAccountMutationList().firstOrNull {
                    it.name.equals(trimmed, ignoreCase = true)
                } ?: return directoryTargetChangedResult(operation)
                deleteDirectoryEntryResult(original, original)
            }
        } catch (_: CancellationException) {
            serviceMutationResult(
                operation, MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                diagnosticTag = "directory.delete.cancelled-before-submission",
            )
        } catch (error: Throwable) {
            serviceMutationFailure(
                operation, error.asRepositoryFailure(), false, "directory.delete.legacy-preflight-failed",
            )
        }
    }

    private suspend fun deleteDirectoryEntryResult(original: Any, verifiedCurrent: Any?): MutationResult {
        val isGroup = original is NasGroup
        val name = when (original) {
            is NasAccount -> original.name
            is NasGroup -> original.name
            else -> return serviceMutationResult(
                "directoryDelete", MutationResultStatus.CONFIRMED_FAILURE, false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "directory.delete.invalid-input",
            )
        }
        val trimmed = name.trim()
        val normalized = trimmed.lowercase(Locale.ROOT)
        val operation = if (isGroup) "groupDelete" else "accountDelete"
        val apiName = if (isGroup) GROUP_API else USER_API
        if (trimmed.isEmpty()) {
            return serviceMutationResult(
                operation = operation,
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "directory.delete.invalid-input",
            )
        }
        if (isProtectedDirectoryEntry(trimmed, isGroup)) {
            return serviceMutationResult(
                operation = operation,
                status = MutationResultStatus.PERMISSION_DENIED,
                submitted = false,
                errorCategory = MutationErrorCategory.PERMISSION,
                diagnosticTag = "directory.delete.protected-entry",
            )
        }
        if (!supportsVersion(apiName, DIRECTORY_API_VERSION)) {
            return unsupportedServiceMutation(operation, "directory.delete.unsupported")
        }
        return verifiedServiceMutation(
            operation = operation,
            targetKey = "${if (isGroup) "group" else "account"}:$normalized",
            requiredApi = apiName,
            preflight = {
                val current = verifiedCurrent ?: if (isGroup) {
                    strictGroupMutationList().firstOrNull { it.name.equals(trimmed, ignoreCase = true) }
                } else {
                    strictAccountMutationList().firstOrNull { it.name.equals(trimmed, ignoreCase = true) }
                }
                if (current == null || current != original) return@verifiedServiceMutation false
                val canDelete = when (current) {
                    is NasAccount -> current.canDelete
                    is NasGroup -> current.canDelete
                    else -> false
                }
                if (!canDelete) throw directoryPermissionFailure()
                true
            },
            submit = {
                call(
                    apiName,
                    "delete",
                    mapOf("name" to JsonArray(listOf(JsonPrimitive(trimmed))).toString()),
                    version = DIRECTORY_API_VERSION,
                )
            },
            verify = {
                if (isGroup) {
                    strictGroupMutationList().none { it.name.equals(trimmed, ignoreCase = true) }
                } else {
                    strictAccountMutationList().none { it.name.equals(trimmed, ignoreCase = true) }
                }
            },
        )
    }

    private fun isProtectedDirectoryEntry(name: String, isGroup: Boolean): Boolean {
        val normalized = name.trim().lowercase(Locale.ROOT)
        return if (isGroup) normalized in setOf("administrators", "users", "http")
        else normalized in setOf("admin", "guest") ||
            normalized == profile.username.trim().lowercase(Locale.ROOT)
    }

    private fun directoryTargetChangedResult(operation: String) = serviceMutationResult(
        operation, MutationResultStatus.CONFIRMED_FAILURE, false,
        errorCategory = MutationErrorCategory.CONFLICT,
        diagnosticTag = "directory.delete.target-changed",
    )

    private fun directoryPermissionFailure() = DsmFailure(
        105,
        "The current account cannot delete this directory entry",
        "Refresh the directory or use an account with the required permission.",
        kind = DsmErrorKind.PERMISSION_DENIED,
    )

    suspend fun controlPackageResult(original: PackageInfo, action: String): MutationResult =
        controlPackageResultInternal(original, action, null)

    @Deprecated("Use controlPackageResult(original, action) to preserve the package baseline")
    suspend fun controlPackageResult(id: String, action: String): MutationResult {
        val normalizedId = id.trim()
        if (normalizedId.isEmpty() || action !in setOf("start", "stop")) {
            return serviceMutationResult(
                operation = "packageControl",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "package.control.invalid-input",
            )
        }
        if (!supportsVersion(PACKAGE_API, PACKAGE_READ_VERSION) ||
            !supportsVersion(PACKAGE_CONTROL_API, PACKAGE_WRITE_VERSION)
        ) {
            return unsupportedServiceMutation("packageControl", "package.control.unsupported")
        }
        val original = try {
            strictPackageMutationList(requireUninstallFields = false)
                .firstOrNull { it.id == normalizedId }
                ?: return packageTargetChangedResult("packageControl")
        } catch (_: CancellationException) {
            return serviceMutationResult(
                "packageControl", MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                diagnosticTag = "package.control.cancelled-before-submission",
            )
        } catch (error: Throwable) {
            return serviceMutationFailure(
                "packageControl", error.asRepositoryFailure(), false, "package.control.legacy-preflight-failed",
            )
        }
        return controlPackageResultInternal(original, action, original)
    }

    private suspend fun controlPackageResultInternal(
        original: PackageInfo,
        action: String,
        verifiedCurrent: PackageInfo?,
    ): MutationResult {
        val normalizedId = original.id.trim()
        if (normalizedId.isEmpty() || action !in setOf("start", "stop")) return serviceMutationResult(
            "packageControl", MutationResultStatus.CONFIRMED_FAILURE, false,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "package.control.invalid-input",
        )
        if (!supportsVersion(PACKAGE_API, PACKAGE_READ_VERSION) ||
            !supportsVersion(PACKAGE_CONTROL_API, PACKAGE_WRITE_VERSION)
        ) return unsupportedServiceMutation("packageControl", "package.control.unsupported")
        var target: PackageInfo? = null
        val expectedState = if (action == "start") ResourceState.RUNNING else ResourceState.STOPPED
        return verifiedServiceMutation(
            operation = "packageControl",
            targetKey = "package:$normalizedId",
            requiredApi = PACKAGE_CONTROL_API,
            preflight = {
                val current = verifiedCurrent ?: strictPackageMutationList(false)
                    .firstOrNull { it.id == normalizedId }
                target = current
                if (current == null || current != original) return@verifiedServiceMutation false
                val allowed = if (action == "start") current.canStart else current.canStop
                if (!allowed) throw packagePermissionFailure()
                call(
                    PACKAGE_API,
                    "feasibility_check",
                    mapOf(
                        "type" to "${action}_check",
                        "packages" to JsonArray(listOf(JsonPrimitive(normalizedId))).toString(),
                    ),
                    version = PACKAGE_READ_VERSION,
                )
                true
            },
            submit = {
                val parameters = mutableMapOf("id" to normalizedId)
                if (action == "start") {
                    parameters["dsm_apps"] = JsonArray(
                        target?.dsmApps.orEmpty().map(::JsonPrimitive),
                    ).toString()
                }
                call(PACKAGE_CONTROL_API, action, parameters, version = PACKAGE_WRITE_VERSION)
            },
            verify = {
                strictPackageMutationList(false).any {
                    it.id == normalizedId && it.status == expectedState
                }
            },
            successfulVerificationAttempts = PACKAGE_CONFIRMED_READBACK_ATTEMPTS,
            successfulVerificationIntervalMillis = PACKAGE_READBACK_INTERVAL_MILLIS,
            ambiguousVerificationAttempts = PACKAGE_AMBIGUOUS_READBACK_ATTEMPTS,
            ambiguousVerificationIntervalMillis = PACKAGE_READBACK_INTERVAL_MILLIS,
            cancellationVerificationAttempts = 1,
            cancellationVerificationIntervalMillis = 0,
        )
    }

    suspend fun uninstallPackageResult(original: PackageInfo): MutationResult =
        uninstallPackageResultInternal(original, null)

    @Deprecated("Use uninstallPackageResult(original) to preserve the package baseline")
    suspend fun uninstallPackageResult(id: String): MutationResult {
        val normalizedId = id.trim()
        if (normalizedId.isEmpty()) {
            return serviceMutationResult(
                operation = "packageUninstall",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "package.uninstall.invalid-input",
            )
        }
        if (!supportsVersion(PACKAGE_API, PACKAGE_READ_VERSION) ||
            !supportsVersion(PACKAGE_UNINSTALL_API, PACKAGE_WRITE_VERSION)
        ) {
            return unsupportedServiceMutation("packageUninstall", "package.uninstall.unsupported")
        }
        val original = try {
            strictPackageMutationList(requireUninstallFields = true)
                .firstOrNull { it.id == normalizedId }
                ?: return packageTargetChangedResult("packageUninstall")
        } catch (_: CancellationException) {
            return serviceMutationResult(
                "packageUninstall", MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
                diagnosticTag = "package.uninstall.cancelled-before-submission",
            )
        } catch (error: Throwable) {
            return serviceMutationFailure(
                "packageUninstall", error.asRepositoryFailure(), false,
                "package.uninstall.legacy-preflight-failed",
            )
        }
        return uninstallPackageResultInternal(original, original)
    }

    private suspend fun uninstallPackageResultInternal(
        original: PackageInfo,
        verifiedCurrent: PackageInfo?,
    ): MutationResult {
        val normalizedId = original.id.trim()
        if (normalizedId.isEmpty()) return serviceMutationResult(
            "packageUninstall", MutationResultStatus.CONFIRMED_FAILURE, false,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "package.uninstall.invalid-input",
        )
        if (!supportsVersion(PACKAGE_API, PACKAGE_READ_VERSION) ||
            !supportsVersion(PACKAGE_UNINSTALL_API, PACKAGE_WRITE_VERSION)
        ) return unsupportedServiceMutation("packageUninstall", "package.uninstall.unsupported")
        var target: PackageInfo? = null
        return verifiedServiceMutation(
            operation = "packageUninstall",
            targetKey = "package:$normalizedId",
            requiredApi = PACKAGE_UNINSTALL_API,
            preflight = {
                val current = verifiedCurrent ?: strictPackageMutationList(true)
                    .firstOrNull { it.id == normalizedId }
                target = current
                if (current == null || current != original) return@verifiedServiceMutation false
                if (!current.canUninstall) throw packagePermissionFailure()
                call(
                    PACKAGE_API,
                    "feasibility_check",
                    mapOf(
                        "type" to "uninstall_check",
                        "packages" to JsonArray(listOf(JsonPrimitive(normalizedId))).toString(),
                    ),
                    version = PACKAGE_READ_VERSION,
                )
                true
            },
            submit = {
                call(
                    PACKAGE_UNINSTALL_API,
                    "uninstall",
                    mapOf(
                        "id" to normalizedId,
                        "dsm_apps" to JsonArray(
                            target?.dsmApps.orEmpty().map(::JsonPrimitive),
                        ).toString(),
                    ), version = PACKAGE_WRITE_VERSION,
                )
            },
            verify = {
                strictPackageMutationList(true).none { it.id == normalizedId }
            },
            successfulVerificationAttempts = PACKAGE_CONFIRMED_READBACK_ATTEMPTS,
            successfulVerificationIntervalMillis = PACKAGE_READBACK_INTERVAL_MILLIS,
            ambiguousVerificationAttempts = PACKAGE_AMBIGUOUS_READBACK_ATTEMPTS,
            ambiguousVerificationIntervalMillis = PACKAGE_READBACK_INTERVAL_MILLIS,
            cancellationVerificationAttempts = 1,
            cancellationVerificationIntervalMillis = 0,
        )
    }

    private fun packageTargetChangedResult(operation: String) = serviceMutationResult(
        operation, MutationResultStatus.CONFIRMED_FAILURE, false,
        errorCategory = MutationErrorCategory.CONFLICT,
        diagnosticTag = "package.target-changed",
    )

    private fun packagePermissionFailure() = DsmFailure(
        105,
        "The current account cannot perform this package operation",
        "Refresh the package list or use an account with the required permission.",
        kind = DsmErrorKind.PERMISSION_DENIED,
    )

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
    ): JsonObject {
        val capability = capabilities[apiName]
            ?: throw DsmFailure(
                102,
                "Feature unsupported",
                "Update DSM or the related package.",
                kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
        if (version == null) return api.call(profile, session, capability, method, parameters)
        if (version !in capability.minVersion..capability.maxVersion) {
            throw DsmFailure(
                103,
                "Feature unsupported",
                "Update DSM or the related package.",
                kind = DsmErrorKind.FEATURE_UNSUPPORTED,
            )
        }
        val path = if (capability.path.startsWith("/")) capability.path else "/webapi/${capability.path}"
        return api.call(
            profile = profile,
            session = session,
            api = capability.name,
            version = version,
            method = method,
            parameters = parameters,
            path = path,
        )
    }

    private fun requireCapability(apiName: String): ApiCapability = capabilities[apiName]
        ?: throw DsmFailure(
            102,
            "Feature unsupported",
            "Update DSM or use File Station in a browser.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )

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
        names.firstOrNull(::supports)

    private fun shareLink(element: JsonElement): FileShareLink? =
        (element as? JsonObject)?.let(::shareLink)

    private fun shareLink(item: JsonObject): FileShareLink? {
        val id = item.string("id") ?: return null
        val url = item.string("url") ?: return null
        val path = item.string("path").orEmpty()
        return FileShareLink(
            id = id,
            name = item.string("name") ?: path.substringAfterLast('/'),
            path = path,
            url = url,
            hasPassword = item.bool("has_password") ?: false,
            expiresAt = item.string("date_expired"),
        )
    }

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

    private suspend fun uploadMatches(path: String, expectedSize: Long): Boolean {
        val parent = path.substringBeforeLast('/', "")
        val uploaded = listDirectory(if (parent.isBlank()) "/" else parent)
            .items
            .firstOrNull { it.path == path }
        return uploaded != null && !uploaded.isDirectory && uploaded.size == expectedSize
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

    private fun requireConfirmedUploadMutation(result: MutationResult) {
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            throw IllegalArgumentException("Invalid upload request")
        }
        when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> return
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> throw CancellationException("upload cancelled")
            else -> throw DsmFailure(
                null,
                "The NAS did not confirm the uploaded file",
                "Refresh the folder before uploading again.",
                kind = when (result.status) {
                    MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                    MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                    else -> if (result.diagnosticTag == "file-station.upload.length-mismatch") {
                        DsmErrorKind.UPLOAD_LENGTH_MISMATCH
                    } else {
                        DsmErrorKind.CHANGE_NOT_CONFIRMED
                    }
                },
            )
        }
    }

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

    private suspend fun deleteVirtualizationResourceResult(
        operation: String,
        targetType: String,
        id: String,
        apiName: String,
        roots: Array<String>,
        method: String,
        idParameter: String,
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
                strictVirtualizationResourceList(apiName, listOf("list"), *roots)
                    .any { it.id == normalizedId }
            },
            submit = {
                call(
                    apiName,
                    method,
                    mapOf(idParameter to normalizedId),
                    version = 1,
                )
            },
            verify = {
                strictVirtualizationResourceList(apiName, listOf("list"), *roots)
                    .none { it.id == normalizedId }
            },
        )
    }

    private enum class SecurityStep { AUTO_BLOCK, DOS, PORT_SCAN, FIREWALL }

    private enum class HardwareStep(val apiName: String) {
        POWER_RECOVERY(HARDWARE_POWER_RECOVERY_API),
        LED(HARDWARE_LED_API),
        FAN(HARDWARE_FAN_API),
        BEEP(HARDWARE_BEEP_API),
        HIBERNATION(HARDWARE_HIBERNATION_API),
        UPS(HARDWARE_UPS_API),
    }

    private data class HardwareSettingsRead(
        val settings: NasHardwareSettings,
        val beepVolumeFieldName: String?,
    )

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

    private fun normalizeHardwareSettings(value: NasHardwareSettings) = value.copy(
        ups = value.ups?.copy(
            networkServerAddress = value.ups.networkServerAddress?.trim(),
            snmpServerAddress = value.ups.snmpServerAddress?.trim(),
        ),
    )

    private fun isValidHardwareSettings(
        expected: NasHardwareSettings,
        current: NasHardwareSettings,
    ): Boolean {
        val writableValues = listOf(
            expected.restartsAfterPowerFailure to current.restartsAfterPowerFailure,
            expected.ledBrightness to current.ledBrightness,
            expected.fanMode to current.fanMode,
            expected.isFanFailureAlertEnabled to current.isFanFailureAlertEnabled,
            expected.isVolumeFailureAlertEnabled to current.isVolumeFailureAlertEnabled,
            expected.isPowerOnSoundEnabled to current.isPowerOnSoundEnabled,
            expected.isPowerOffSoundEnabled to current.isPowerOffSoundEnabled,
            expected.isResetSoundEnabled to current.isResetSoundEnabled,
            expected.isExternalDriveDeepSleepEnabled to current.isExternalDriveDeepSleepEnabled,
            expected.isWakeUpLogEnabled to current.isWakeUpLogEnabled,
            expected.isSataSleepEnabled to current.isSataSleepEnabled,
            expected.ignoresNetworkDiscoveryDuringSleep to current.ignoresNetworkDiscoveryDuringSleep,
            expected.isAutomaticPowerOffEnabled to current.isAutomaticPowerOffEnabled,
        )
        if (writableValues.any { (desiredValue, originalValue) ->
                desiredValue != originalValue && originalValue == null
            }
        ) return false
        if (expected.ledBrightness != current.ledBrightness && expected.ledBrightness != null) {
            val min = current.ledBrightnessMinimum ?: return false
            val max = current.ledBrightnessMaximum ?: return false
            if (expected.ledBrightness !in min..max) return false
        }
        if (expected.fanMode != current.fanMode && expected.fanMode !in FAN_MODES) return false
        if ((expected.ups == null) != (current.ups == null)) return false
        val ups = expected.ups ?: return true
        val currentUps = current.ups ?: return false
        val writableUpsValues = listOf(
            ups.safeModeDelaySeconds to currentUps.safeModeDelaySeconds,
            ups.waitsUntilLowBattery to currentUps.waitsUntilLowBattery,
            ups.shutsDownUpsAfterSafeMode to currentUps.shutsDownUpsAfterSafeMode,
            ups.networkServerAddress to currentUps.networkServerAddress,
            ups.snmpServerAddress to currentUps.snmpServerAddress,
        )
        if (writableUpsValues.any { (desiredValue, originalValue) ->
                desiredValue != originalValue && originalValue == null
            }
        ) return false
        if (ups.mode !in UPS_MODES || ups.safeModeDelaySeconds?.let { it !in 0..604_800 } == true) {
            return false
        }
        if (ups.isEnabled && ups.mode == "SLAVE" && ups.networkServerAddress.isNullOrBlank()) return false
        if (ups.isEnabled && ups.mode == "SNMP" && ups.snmpServerAddress.isNullOrBlank()) return false
        return listOfNotNull(ups.networkServerAddress, ups.snmpServerAddress).all { address ->
            address.length <= 255 && "://" !in address && address.none { it.isWhitespace() || it in "/?#@" }
        }
    }

    private fun hardwareSteps(
        current: NasHardwareSettings,
        expected: NasHardwareSettings,
    ) = buildList {
        if (expected.restartsAfterPowerFailure != null &&
            expected.restartsAfterPowerFailure != current.restartsAfterPowerFailure
        ) add(HardwareStep.POWER_RECOVERY)
        if (expected.ledBrightness != null && expected.ledBrightness != current.ledBrightness) {
            add(HardwareStep.LED)
        }
        if (expected.fanMode != null && expected.fanMode != current.fanMode) add(HardwareStep.FAN)
        if (hardwareBeepChanged(expected, current)) add(HardwareStep.BEEP)
        if (hardwareHibernationParameters(expected, current).isNotEmpty()) add(HardwareStep.HIBERNATION)
        if (expected.ups != null && expected.ups != current.ups) add(HardwareStep.UPS)
    }

    private fun hardwareBeepParameters(
        expected: NasHardwareSettings,
        current: NasHardwareSettings,
        volumeFieldName: String?,
    ) = buildMap {
        putChanged("fan_fail", expected.isFanFailureAlertEnabled, current.isFanFailureAlertEnabled)
        volumeFieldName?.let { field ->
            putChanged(field, expected.isVolumeFailureAlertEnabled, current.isVolumeFailureAlertEnabled)
        }
        putChanged("poweron_beep", expected.isPowerOnSoundEnabled, current.isPowerOnSoundEnabled)
        putChanged("poweroff_beep", expected.isPowerOffSoundEnabled, current.isPowerOffSoundEnabled)
        putChanged("reset_beep", expected.isResetSoundEnabled, current.isResetSoundEnabled)
    }

    private fun hardwareBeepChanged(
        expected: NasHardwareSettings,
        current: NasHardwareSettings,
    ): Boolean = listOf(
        expected.isFanFailureAlertEnabled to current.isFanFailureAlertEnabled,
        expected.isVolumeFailureAlertEnabled to current.isVolumeFailureAlertEnabled,
        expected.isPowerOnSoundEnabled to current.isPowerOnSoundEnabled,
        expected.isPowerOffSoundEnabled to current.isPowerOffSoundEnabled,
        expected.isResetSoundEnabled to current.isResetSoundEnabled,
    ).any { (expectedValue, currentValue) -> expectedValue != null && expectedValue != currentValue }

    private fun hardwareHibernationParameters(
        expected: NasHardwareSettings,
        current: NasHardwareSettings,
    ) = buildMap {
        putChanged(
            "eunit_deep_sleep", expected.isExternalDriveDeepSleepEnabled,
            current.isExternalDriveDeepSleepEnabled,
        )
        putChanged("enable_log", expected.isWakeUpLogEnabled, current.isWakeUpLogEnabled)
        putChanged("sata_deep_sleep", expected.isSataSleepEnabled, current.isSataSleepEnabled)
        putChanged(
            "ignore_netbios_broadcast", expected.ignoresNetworkDiscoveryDuringSleep,
            current.ignoresNetworkDiscoveryDuringSleep,
        )
        putChanged(
            "auto_poweroff_enable", expected.isAutomaticPowerOffEnabled,
            current.isAutomaticPowerOffEnabled,
        )
    }

    private fun MutableMap<String, String>.putChanged(
        key: String,
        expected: Boolean?,
        current: Boolean?,
    ) {
        if (expected != null && expected != current) put(key, expected.toString())
    }

    private suspend fun submitHardwareStep(
        step: HardwareStep,
        expected: NasHardwareSettings,
        current: NasHardwareSettings,
        beepVolumeFieldName: String?,
    ) {
        when (step) {
            HardwareStep.POWER_RECOVERY -> call(
                step.apiName, "set",
                mapOf("rc_power_config" to checkNotNull(expected.restartsAfterPowerFailure).toString()),
                version = 1,
            )
            HardwareStep.LED -> {
                call(
                    step.apiName, "set_current_brightness",
                    mapOf("led_brightness" to checkNotNull(expected.ledBrightness).toString()),
                    version = 1,
                )
                call(step.apiName, "update", version = 1)
            }
            HardwareStep.FAN -> call(
                step.apiName, "set",
                mapOf("dual_fan_speed" to checkNotNull(expected.fanMode)), version = 1,
            )
            HardwareStep.BEEP -> call(
                step.apiName, "set",
                hardwareBeepParameters(expected, current, beepVolumeFieldName), version = 1,
            )
            HardwareStep.HIBERNATION -> call(
                step.apiName, "set", hardwareHibernationParameters(expected, current), version = 1,
            )
            HardwareStep.UPS -> call(
                step.apiName, "set", hardwareUpsParameters(checkNotNull(expected.ups), checkNotNull(current.ups)),
                version = 1,
            )
        }
    }

    private fun hardwareUpsParameters(expected: NasUpsSettings, current: NasUpsSettings) = buildMap {
        put("enable", expected.isEnabled.toString())
        put("mode", expected.mode)
        expected.safeModeDelaySeconds?.let { put("delay_time", it.toString()) }
        putChanged(
            "ups_set_safemode_until_lowbatt", expected.waitsUntilLowBattery,
            current.waitsUntilLowBattery,
        )
        putChanged(
            "shutdown_device", expected.shutsDownUpsAfterSafeMode,
            current.shutsDownUpsAfterSafeMode,
        )
        if (expected.networkServerAddress != current.networkServerAddress) {
            expected.networkServerAddress?.let { put("net_server_ip", it) }
        }
        if (expected.snmpServerAddress != current.snmpServerAddress) {
            expected.snmpServerAddress?.let { put("snmp_server_ip", it) }
        }
    }

    private fun hardwareStepMatches(
        step: HardwareStep,
        actual: NasHardwareSettings,
        expected: NasHardwareSettings,
    ): Boolean = when (step) {
        HardwareStep.POWER_RECOVERY ->
            actual.restartsAfterPowerFailure == expected.restartsAfterPowerFailure
        HardwareStep.LED -> actual.ledBrightness == expected.ledBrightness
        HardwareStep.FAN -> actual.fanMode == expected.fanMode
        HardwareStep.BEEP -> !hardwareBeepChanged(expected, actual)
        HardwareStep.HIBERNATION -> hardwareHibernationParameters(expected, actual).isEmpty()
        HardwareStep.UPS -> actual.ups == expected.ups
    }

    private fun isValidSecuritySettings(value: NasSecuritySettings): Boolean {
        if (value.failedAttempts !in 1..9_999 || value.withinMinutes !in 1..9_999_999) return false
        if (value.expirationDays?.let { it !in 1..999 } == true) return false
        val ids = value.dosProtection.map { it.id }
        return ids.distinct().size == ids.size && ids.all { id ->
            id.isNotEmpty() && id.all { it.isLetterOrDigit() || it == '_' || it == '-' }
        }
    }

    private fun securityBaselineMatches(
        current: NasSecuritySettings,
        original: NasSecuritySettings,
    ): Boolean = current.isAutoBlockEnabled == original.isAutoBlockEnabled &&
        current.failedAttempts == original.failedAttempts &&
        current.withinMinutes == original.withinMinutes &&
        current.expirationDays == original.expirationDays &&
        dosValues(current) == dosValues(original) &&
        current.isFirewallEnabled == original.isFirewallEnabled &&
        current.firewallProfileName == original.firewallProfileName &&
        current.isPortScanProtectionEnabled == original.isPortScanProtectionEnabled

    private fun securitySteps(
        current: NasSecuritySettings,
        expected: NasSecuritySettings,
    ): List<SecurityStep>? = buildList {
        if (
            current.isAutoBlockEnabled != expected.isAutoBlockEnabled ||
            current.failedAttempts != expected.failedAttempts ||
            current.withinMinutes != expected.withinMinutes ||
            current.expirationDays != expected.expirationDays
        ) add(SecurityStep.AUTO_BLOCK)
        if (dosValues(current) != dosValues(expected)) {
            if (dosValues(current).keys != dosValues(expected).keys) return null
            add(SecurityStep.DOS)
        }
        if (expected.isPortScanProtectionEnabled != null &&
            current.isPortScanProtectionEnabled != expected.isPortScanProtectionEnabled
        ) add(SecurityStep.PORT_SCAN)
        if (expected.isFirewallEnabled != null &&
            current.isFirewallEnabled != expected.isFirewallEnabled
        ) {
            if (expected.isFirewallEnabled && current.firewallProfileName.isNullOrBlank()) return null
            add(SecurityStep.FIREWALL)
        }
    }

    private fun securityStepsSupported(
        steps: List<SecurityStep>,
        expected: NasSecuritySettings,
    ): Boolean = steps.all { step ->
        when (step) {
            SecurityStep.AUTO_BLOCK -> supportsVersion(SECURITY_AUTO_BLOCK_API, 1)
            SecurityStep.DOS -> supportsVersion(ETHERNET_API, 2) &&
                supportsVersion(SECURITY_DOS_API, 2)
            SecurityStep.PORT_SCAN -> supportsVersion(SECURITY_FIREWALL_CONF_API, 1)
            SecurityStep.FIREWALL -> supportsVersion(SECURITY_FIREWALL_API, 1) &&
                (expected.isFirewallEnabled != true || supportsVersion(SECURITY_FIREWALL_APPLY_API, 1))
        }
    }

    private suspend fun submitSecurityStep(
        step: SecurityStep,
        expected: NasSecuritySettings,
        current: NasSecuritySettings,
    ) {
        when (step) {
            SecurityStep.AUTO_BLOCK -> call(
                SECURITY_AUTO_BLOCK_API, "set",
                mapOf(
                    "enable" to expected.isAutoBlockEnabled.toString(),
                    "attempts" to expected.failedAttempts.toString(),
                    "within_mins" to expected.withinMinutes.toString(),
                    "expire_day" to (expected.expirationDays ?: 0).toString(),
                ), version = 1,
            )
            SecurityStep.DOS -> call(
                SECURITY_DOS_API, "set",
                mapOf(
                    "configs" to JsonArray(expected.dosProtection.map { setting ->
                        JsonObject(
                            mapOf(
                                "adapter" to JsonPrimitive(setting.id),
                                "dos_protect_enable" to JsonPrimitive(setting.isEnabled),
                            ),
                        )
                    }).toString(),
                ), version = 2,
            )
            SecurityStep.PORT_SCAN -> call(
                SECURITY_FIREWALL_CONF_API, "set",
                mapOf("enable_port_check" to checkNotNull(expected.isPortScanProtectionEnabled).toString()),
                version = 1,
            )
            SecurityStep.FIREWALL -> if (expected.isFirewallEnabled == true) {
                applyFirewallProfile(checkNotNull(current.firewallProfileName))
            } else {
                call(
                    SECURITY_FIREWALL_API, "set", mapOf("set_type" to "disable"), version = 1,
                )
            }
        }
    }

    private suspend fun applyFirewallProfile(profile: String) {
        val started = call(
            SECURITY_FIREWALL_APPLY_API, "start",
            mapOf("name" to profile, "profile_applying" to "false"), version = 1,
        )
        val taskId = started.string("task_id")?.takeIf(String::isNotBlank)
            ?: throw invalidSettingsResponse("firewall-profile")
        try {
            repeat(30) { attempt ->
                if (attempt > 0) delay(1_000)
                val status = call(
                    SECURITY_FIREWALL_APPLY_API, "status", mapOf("task_id" to taskId), version = 1,
                )
                status.bool("success")?.let { success ->
                    if (success) return
                    throw DsmFailure(
                        null, "Firewall profile was not applied",
                        "Refresh the security settings and check the firewall state.",
                        kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
                    )
                }
            }
            throw DsmFailure(
                null, "Firewall profile is still being applied",
                "Refresh the security settings and check the firewall state.",
                kind = DsmErrorKind.CONNECTION_FAILED,
            )
        } finally {
            withContext(NonCancellable) {
                runCatching { call(SECURITY_FIREWALL_APPLY_API, "stop", version = 1) }
            }
        }
    }

    private fun securityStepMatches(
        step: SecurityStep,
        actual: NasSecuritySettings,
        expected: NasSecuritySettings,
    ): Boolean = when (step) {
        SecurityStep.AUTO_BLOCK -> actual.isAutoBlockEnabled == expected.isAutoBlockEnabled &&
            actual.failedAttempts == expected.failedAttempts &&
            actual.withinMinutes == expected.withinMinutes &&
            actual.expirationDays == expected.expirationDays
        SecurityStep.DOS -> dosValues(actual) == dosValues(expected)
        SecurityStep.PORT_SCAN ->
            actual.isPortScanProtectionEnabled == expected.isPortScanProtectionEnabled
        SecurityStep.FIREWALL -> actual.isFirewallEnabled == expected.isFirewallEnabled
    }

    private fun dosValues(value: NasSecuritySettings): Map<String, Boolean> =
        value.dosProtection.associate { it.id to it.isEnabled }

    private enum class FileServiceStep { SMB, NFS, FTP, SFTP, WEB_DISCOVERY, FILE_DISCOVERY }

    private fun fileServiceSteps(
        current: NasFileServiceSettings,
        expected: NasFileServiceSettings,
    ) = buildList {
        if (expected.isSmbEnabled != null && expected.isSmbEnabled != current.isSmbEnabled) add(FileServiceStep.SMB)
        if (expected.isNfsEnabled != null && expected.isNfsEnabled != current.isNfsEnabled) add(FileServiceStep.NFS)
        if (
            (expected.isFtpEnabled != null && expected.isFtpEnabled != current.isFtpEnabled) ||
            (expected.isFtpsEnabled != null && expected.isFtpsEnabled != current.isFtpsEnabled) ||
            (expected.ftpPort != null && expected.ftpPort != current.ftpPort)
        ) add(FileServiceStep.FTP)
        if (
            (expected.isSftpEnabled != null && expected.isSftpEnabled != current.isSftpEnabled) ||
            (expected.sftpPort != null && expected.sftpPort != current.sftpPort)
        ) add(FileServiceStep.SFTP)
        if (
            (expected.isSsdpEnabled != null && expected.isSsdpEnabled != current.isSsdpEnabled) ||
            (expected.isBonjourEnabled != null && expected.isBonjourEnabled != current.isBonjourEnabled)
        ) add(FileServiceStep.WEB_DISCOVERY)
        if (
            expected.isSmbTimeMachineEnabled != null &&
            expected.isSmbTimeMachineEnabled != current.isSmbTimeMachineEnabled
        ) add(FileServiceStep.FILE_DISCOVERY)
    }

    private fun fileServiceStepsSupported(steps: List<FileServiceStep>): Boolean = steps.all { step ->
        when (step) {
            FileServiceStep.SMB -> supports("SYNO.Core.FileServ.SMB")
            FileServiceStep.NFS -> supports("SYNO.Core.FileServ.NFS")
            FileServiceStep.FTP -> supportsVersion("SYNO.Core.FileServ.FTP", 1)
            FileServiceStep.SFTP -> supportsVersion("SYNO.Core.FileServ.FTP.SFTP", 1)
            FileServiceStep.WEB_DISCOVERY -> supportsVersion("SYNO.Core.Web.DSM", 2)
            FileServiceStep.FILE_DISCOVERY ->
                supportsVersion("SYNO.Core.FileServ.ServiceDiscovery", 1)
        }
    }

    private suspend fun submitFileServiceStep(
        step: FileServiceStep,
        value: NasFileServiceSettings,
    ) {
        when (step) {
            FileServiceStep.SMB -> call(
                "SYNO.Core.FileServ.SMB",
                "set",
                mapOf("enable_samba" to checkNotNull(value.isSmbEnabled).toString()),
                version = 1,
            )
            FileServiceStep.NFS -> call(
                "SYNO.Core.FileServ.NFS",
                "set",
                mapOf("enable_nfs" to checkNotNull(value.isNfsEnabled).toString()),
                version = 1,
            )
            FileServiceStep.FTP -> call(
                "SYNO.Core.FileServ.FTP",
                "set",
                buildMap {
                    value.isFtpEnabled?.let { put("enable_ftp", it.toString()) }
                    value.isFtpsEnabled?.let { put("enable_ftps", it.toString()) }
                    value.ftpPort?.let { put("portnum", it.toString()) }
                },
                version = 1,
            )
            FileServiceStep.SFTP -> call(
                "SYNO.Core.FileServ.FTP.SFTP",
                "set",
                buildMap {
                    value.isSftpEnabled?.let { put("enable", it.toString()) }
                    value.sftpPort?.let { put("portnum", it.toString()) }
                },
                version = 1,
            )
            FileServiceStep.WEB_DISCOVERY -> call(
                "SYNO.Core.Web.DSM",
                "set",
                buildMap {
                    value.isSsdpEnabled?.let { put("enable_ssdp", it.toString()) }
                    value.isBonjourEnabled?.let { put("enable_avahi", it.toString()) }
                },
                version = 2,
            )
            FileServiceStep.FILE_DISCOVERY -> call(
                "SYNO.Core.FileServ.ServiceDiscovery",
                "set",
                mapOf(
                    "enable_smb_time_machine" to
                        checkNotNull(value.isSmbTimeMachineEnabled).toString(),
                ),
                version = 1,
            )
        }
    }

    private fun FileServiceStep.matches(
        actual: NasFileServiceSettings,
        expected: NasFileServiceSettings,
    ): Boolean = when (this) {
        FileServiceStep.SMB -> actual.isSmbEnabled == expected.isSmbEnabled
        FileServiceStep.NFS -> actual.isNfsEnabled == expected.isNfsEnabled
        FileServiceStep.FTP ->
            (expected.isFtpEnabled == null || actual.isFtpEnabled == expected.isFtpEnabled) &&
                (expected.isFtpsEnabled == null || actual.isFtpsEnabled == expected.isFtpsEnabled) &&
                (expected.ftpPort == null || actual.ftpPort == expected.ftpPort)
        FileServiceStep.SFTP ->
            (expected.isSftpEnabled == null || actual.isSftpEnabled == expected.isSftpEnabled) &&
                (expected.sftpPort == null || actual.sftpPort == expected.sftpPort)
        FileServiceStep.WEB_DISCOVERY ->
            (expected.isSsdpEnabled == null || actual.isSsdpEnabled == expected.isSsdpEnabled) &&
                (expected.isBonjourEnabled == null || actual.isBonjourEnabled == expected.isBonjourEnabled)
        FileServiceStep.FILE_DISCOVERY ->
            actual.isSmbTimeMachineEnabled == expected.isSmbTimeMachineEnabled
    }

    private fun isValidFileServiceSettings(value: NasFileServiceSettings): Boolean {
        if (value.ftpPort?.let(::isValidPort) == false || value.sftpPort?.let(::isValidPort) == false) {
            return false
        }
        if (value.isSmbTimeMachineEnabled == true && value.isSmbEnabled == false) return false
        val ftpActive = value.isFtpEnabled == true || value.isFtpsEnabled == true
        return !(ftpActive && value.isSftpEnabled == true && value.ftpPort != null &&
            value.ftpPort == value.sftpPort)
    }

    private fun isValidProxySettings(value: NasProxySettings): Boolean {
        if (!value.isEnabled) return true
        val host = value.host
        return host.isNotBlank() && host.length <= 255 && value.port?.let(::isValidPort) == true &&
            "://" !in host && host.none { it.isWhitespace() || it in "/?#@" }
    }

    private fun isValidRegionSettings(value: NasRegionSettings): Boolean {
        if (value.dateFormat.isBlank() || value.timeFormat.isBlank()) return false
        if (value.timeServers.size > 3 || value.timeServers.distinct().size != value.timeServers.size) {
            return false
        }
        if (value.isNetworkTimeEnabled &&
            (value.timeServers.isEmpty() || value.timeServers.any { !isValidTimeServer(it) })
        ) return false
        return value.manualDateTime?.let(::isValidManualDateTime) != false
    }

    private fun isValidTimeServer(value: String): Boolean {
        val host = value.trim()
        return host.isNotEmpty() && host.length <= 253 &&
            host.all { it.isLetterOrDigit() || it in ".-:" } &&
            !host.startsWith('.') && !host.endsWith('.') && ".." !in host
    }

    private fun isValidManualDateTime(value: NasManualDateTime): Boolean = runCatching {
        GregorianCalendar().apply {
            isLenient = false
            set(value.year, value.month - 1, value.day, value.hour, value.minute, value.second)
            getTime()
        }
    }.isSuccess

    private fun parseNasManualDateTime(
        date: String?,
        hour: Int?,
        minute: Int?,
        second: Int?,
    ): NasManualDateTime? {
        val parts = date?.trim()?.split('/', '-') ?: return null
        if (parts.size != 3 || hour == null || minute == null || second == null) return null
        val value = NasManualDateTime(
            parts[0].toIntOrNull() ?: return null,
            parts[1].toIntOrNull() ?: return null,
            parts[2].toIntOrNull() ?: return null,
            hour, minute, second,
        )
        return value.takeIf(::isValidManualDateTime)
    }

    private fun regionChangedFields(
        current: NasRegionSettings,
        expected: NasRegionSettings,
        updatesManualTime: Boolean,
    ): List<String> = buildList {
        if (current.dateFormat != expected.dateFormat) add("date_format")
        if (current.timeFormat != expected.timeFormat) add("time_format")
        if (current.timeZone != expected.timeZone) add("timezone")
        if (current.isNetworkTimeEnabled != expected.isNetworkTimeEnabled) add("mode")
        if (current.timeServers != expected.timeServers) add("servers")
        if (updatesManualTime && current.manualDateTime != expected.manualDateTime) add("manual_time")
    }

    private fun regionFieldMatches(
        field: String,
        actual: NasRegionSettings,
        expected: NasRegionSettings,
    ): Boolean = when (field) {
        "date_format" -> actual.dateFormat == expected.dateFormat
        "time_format" -> actual.timeFormat == expected.timeFormat
        "timezone" -> actual.timeZone == expected.timeZone
        "mode" -> actual.isNetworkTimeEnabled == expected.isNetworkTimeEnabled
        "servers" -> actual.timeServers == expected.timeServers
        else -> manualTimesMatch(actual.manualDateTime, expected.manualDateTime)
    }

    private fun manualTimesMatch(
        actual: NasManualDateTime?,
        expected: NasManualDateTime?,
    ): Boolean {
        if (actual == null || expected == null) return actual == expected
        fun NasManualDateTime.millis() = GregorianCalendar().apply {
            isLenient = false
            set(year, month - 1, day, hour, minute, second)
        }.timeInMillis
        return kotlin.math.abs(actual.millis() - expected.millis()) <= 120_000
    }

    private fun regionParameters(value: NasRegionSettings): Map<String, String> = buildMap {
        put("date_format", value.dateFormat)
        put("time_format", value.timeFormat)
        put("timezone", value.timeZone)
        put("enable_ntp", if (value.isNetworkTimeEnabled) "ntp" else "manual")
        put("server", value.timeServers.joinToString(","))
        if (!value.isNetworkTimeEnabled) {
            val time = checkNotNull(value.manualDateTime)
            put("date", "${time.year}/${time.month}/${time.day}")
            put("hour", time.hour.toString())
            put("minute", time.minute.toString())
            put("second", time.second.toString())
        }
    }

    private fun isValidPort(value: Int): Boolean = value in 1..65_535

    private fun supportsVersion(apiName: String, version: Int): Boolean =
        capabilities[apiName]?.let { version in it.minVersion..it.maxVersion } == true

    private fun invalidSettingsResponse(scope: String) = DsmFailure(
        null,
        "$scope settings response is invalid",
        "Refresh the settings and try again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    private fun invalidSettingsResult(operation: String, diagnosticTag: String) =
        settingsMutationResult(
            operation,
            MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            total = 1,
            failed = 1,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = diagnosticTag,
        )

    private fun duplicateSettingsResult(
        operation: String,
        diagnosticTag: String,
        affectedCount: Int = 1,
    ) =
        settingsMutationResult(
            operation,
            MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            total = affectedCount,
            failed = affectedCount,
            errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = diagnosticTag,
        )

    private suspend fun <T> singleSettingsMutation(
        operation: String,
        targetKey: String,
        requiredApi: String,
        expected: T,
        load: suspend () -> T,
        changedFields: (T, T) -> List<String>,
        submit: suspend () -> Unit,
        fieldMatches: (String, T, T) -> Boolean,
        diagnosticPrefix: String,
    ): MutationResult {
        if (!supports(requiredApi)) return unsupportedServiceMutation(operation, "$diagnosticPrefix.unsupported")
        if (!claimServiceMutation(targetKey)) return duplicateSettingsResult(operation, "$diagnosticPrefix.duplicate")
        try {
            val current = try {
                load()
            } catch (_: CancellationException) {
                return settingsMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    total = 0,
                    diagnosticTag = "$diagnosticPrefix.cancelled-before-submission",
                )
            } catch (error: Throwable) {
                return serviceMutationFailure(
                    operation,
                    error.asRepositoryFailure(),
                    false,
                    "$diagnosticPrefix.preflight-failed",
                )
            }
            val fields = changedFields(current, expected)
            if (fields.isEmpty()) {
                return settingsMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    false,
                    total = 1,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "$diagnosticPrefix.no-changes",
                )
            }
            var failure: DsmFailure? = null
            var cancelled = false
            var submissionStarted = false
            try {
                currentCoroutineContext().ensureActive()
                // 从这里开始保守地视为请求可能已到达 NAS，取消后只能回读，不能重放。
                submissionStarted = true
                submit()
            } catch (_: CancellationException) {
                if (!submissionStarted) {
                    return settingsMutationResult(
                        operation,
                        MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                        submitted = false,
                        total = fields.size,
                        diagnosticTag = "$diagnosticPrefix.cancelled-before-submission",
                    )
                }
                cancelled = true
            } catch (error: Throwable) {
                failure = error.asRepositoryFailure()
            }
            val actual = try {
                withContext(NonCancellable) { load() }
            } catch (error: Throwable) {
                if (failure != null && !failure.isAmbiguousSettingsFailure()) {
                    return serviceMutationFailure(
                        operation,
                        failure,
                        true,
                        "$diagnosticPrefix.submission-failed",
                        affectedCount = fields.size,
                    )
                }
                return settingsMutationResult(
                    operation,
                    if (cancelled) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                    else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    true,
                    total = fields.size,
                    unknown = fields.size,
                    requiresRefresh = true,
                    errorCategory = error.asRepositoryFailure().mutationErrorCategory(),
                    diagnosticTag = "$diagnosticPrefix.readback-unverified",
                )
            }
            val succeeded = fields.count { fieldMatches(it, actual, expected) }
            return settingsVerificationResult(
                operation,
                fields.size,
                succeeded,
                failure,
                cancelled,
                diagnosticPrefix,
            )
        } finally {
            releaseServiceMutation(targetKey)
        }
    }

    private fun settingsVerificationResult(
        operation: String,
        total: Int,
        succeeded: Int,
        submissionFailure: DsmFailure?,
        cancellationAfterSubmission: Boolean,
        diagnosticPrefix: String,
    ): MutationResult {
        if (succeeded == total) {
            return settingsMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_SUCCESS,
                true,
                total,
                succeeded = succeeded,
                diagnosticTag = "$diagnosticPrefix.confirmed",
            )
        }
        val remaining = total - succeeded
        if (succeeded > 0) {
            val unknown = if (submissionFailure?.isAmbiguousSettingsFailure() == true ||
                cancellationAfterSubmission) remaining else 0
            return settingsMutationResult(
                operation,
                MutationResultStatus.PARTIAL_SUCCESS,
                true,
                total,
                succeeded = succeeded,
                failed = remaining - unknown,
                unknown = unknown,
                requiresRefresh = true,
                errorCategory = when {
                    submissionFailure != null -> submissionFailure.mutationErrorCategory()
                    cancellationAfterSubmission -> null
                    else -> MutationErrorCategory.CONFLICT
                },
                diagnosticTag = "$diagnosticPrefix.partial",
            )
        }
        if (cancellationAfterSubmission) {
            return settingsMutationResult(
                operation,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                true,
                total,
                unknown = total,
                requiresRefresh = true,
                diagnosticTag = "$diagnosticPrefix.cancelled-after-submission",
            )
        }
        if (submissionFailure != null) {
            if (!submissionFailure.isAmbiguousSettingsFailure()) {
                return serviceMutationFailure(
                    operation,
                    submissionFailure,
                    true,
                    "$diagnosticPrefix.submission-failed",
                    affectedCount = total,
                )
            }
            return settingsMutationResult(
                operation,
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                true,
                total,
                unknown = total,
                requiresRefresh = true,
                errorCategory = submissionFailure.mutationErrorCategory(),
                diagnosticTag = "$diagnosticPrefix.readback-mismatch",
            )
        }
        return settingsMutationResult(
            operation,
            MutationResultStatus.CONFIRMED_FAILURE,
            true,
            total,
            failed = total,
            errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "$diagnosticPrefix.readback-mismatch",
        )
    }

    private fun DsmFailure.isAmbiguousSettingsFailure(): Boolean = kind in setOf(
        DsmErrorKind.CONNECTION_FAILED,
        DsmErrorKind.INVALID_RESPONSE,
        DsmErrorKind.UNKNOWN,
    )

    private fun settingsMutationResult(
        operation: String,
        status: MutationResultStatus,
        submitted: Boolean,
        total: Int,
        succeeded: Int = 0,
        failed: Int = 0,
        unknown: Int = 0,
        requiresRefresh: Boolean = false,
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
        localizationKey = "mutation.service.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    ).also { check(total >= succeeded + failed + unknown) }

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
        val conflicts = when {
            target == DDNS_GLOBAL_MUTATION_KEY -> activeServiceMutationTargets.any {
                it == DDNS_GLOBAL_MUTATION_KEY || it.startsWith(DDNS_PROVIDER_MUTATION_PREFIX)
            }
            target.startsWith(DDNS_PROVIDER_MUTATION_PREFIX) ->
                DDNS_GLOBAL_MUTATION_KEY in activeServiceMutationTargets ||
                    target in activeServiceMutationTargets
            else -> target in activeServiceMutationTargets
        }
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
    ): MutationResult {
        val succeeded = if (status == MutationResultStatus.CONFIRMED_SUCCESS) affectedCount else 0
        val unknown = if (
            status == MutationResultStatus.SUBMITTED_BUT_UNVERIFIED ||
            status == MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
        ) affectedCount else 0
        val failed = if (
            status in setOf(
                MutationResultStatus.CONFIRMED_FAILURE,
                MutationResultStatus.PERMISSION_DENIED,
                MutationResultStatus.UNSUPPORTED,
            )
        ) affectedCount else 0
        return MutationResult(
            schemaVersion = 1,
            status = status,
            operation = operation,
            submitted = submitted,
            requiresRefresh = requiresRefresh,
            counts = MutationResultCounts(succeeded, failed, unknown),
            errorCategory = errorCategory,
            localizationKey = "mutation.service.${status.name.lowercase()}",
            diagnosticTag = diagnosticTag,
        )
    }

    private fun Throwable.asRepositoryFailure(): DsmFailure = this as? DsmFailure ?: DsmFailure(
        code = null,
        message = message ?: "Service request failed",
        recovery = "Refresh the list and check the current state.",
        kind = DsmErrorKind.UNKNOWN,
    )

    private fun DsmFailure.mutationErrorCategory(): MutationErrorCategory = when (kind) {
        DsmErrorKind.PERMISSION_DENIED -> MutationErrorCategory.PERMISSION
        DsmErrorKind.SESSION_EXPIRED,
        DsmErrorKind.AUTHENTICATION_FAILED,
        -> MutationErrorCategory.AUTHENTICATION
        DsmErrorKind.FEATURE_UNSUPPORTED,
        DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
        -> MutationErrorCategory.UNSUPPORTED
        DsmErrorKind.CONNECTION_FAILED,
        DsmErrorKind.INVALID_RESPONSE,
        -> MutationErrorCategory.NETWORK
        DsmErrorKind.CHANGE_NOT_CONFIRMED -> MutationErrorCategory.CONFLICT
        DsmErrorKind.UNKNOWN -> MutationErrorCategory.UNKNOWN
        else -> MutationErrorCategory.SERVER
    }

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

    private fun filePage(data: JsonObject, root: String): FilePage {
        return parseFilePageFixture(data, root)
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

    private suspend fun strictPackageMutationList(
        requireUninstallFields: Boolean,
    ): List<PackageInfo> {
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
        val result = rows.map { item ->
            val additional = item["additional"]?.let {
                it as? JsonObject ?: throw invalidSettingsResponse("package-additional")
            }
            fun element(key: String): JsonElement? = item[key] ?: additional?.get(key)
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
                is JsonPrimitive -> value.contentOrNull?.split(Regex("\\s+"))
                    ?.filter(String::isNotBlank) ?: throw invalidSettingsResponse("package-$key")
                null -> if (required) throw invalidSettingsResponse("package-$key") else emptyList()
                else -> throw invalidSettingsResponse("package-$key")
            }
            val status = requiredString("status")
            val currentState = state(status)
            if (currentState == ResourceState.UNKNOWN) {
                throw invalidSettingsResponse("package-status")
            }
            val operations = stringList("available_operation", required = true)
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
            if (requireUninstallFields && (installType == null || uninstallAllowed == null)) {
                throw invalidSettingsResponse("package-uninstall-permission")
            }
            PackageInfo(
                id = requiredString("id"),
                name = requiredString("name"),
                version = requiredString("version"),
                status = currentState,
                description = element("description")?.strictStringValue()
                    ?: if (element("description") != null) {
                        throw invalidSettingsResponse("package-description")
                    } else null,
                canStart = startable && currentState == ResourceState.STOPPED && "start" in operations,
                canStop = currentState == ResourceState.RUNNING && "stop" in operations,
                canUninstall = installType != null && installType != "system" &&
                    (uninstallAllowed == true || "uninstall" in operations),
                dsmApps = stringList("dsm_apps", required = true),
                isUpgradeAvailable = "upgrade" in operations,
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
            fun string(key: String) = item.string(key) ?: additional?.string(key)
            fun bool(key: String) = item.bool(key) ?: additional?.bool(key)
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
                canStart = startable && currentState == ResourceState.STOPPED && "start" in operations,
                canStop = currentState == ResourceState.RUNNING && "stop" in operations,
                canUninstall = installType != null && installType != "system" &&
                    (bool("ctl_uninstall") == true || "uninstall" in operations),
                dsmApps = stringList("dsm_apps"),
                isUpgradeAvailable = "upgrade" in operations,
            )
        }

    private suspend fun accountList(): List<NasAccount> = accounts(
        firstSuccessful(
            "SYNO.Core.User",
            listOf("list"),
            mapOf(
                "offset" to "0",
                "limit" to "1000",
                "additional" to "[\"uid\",\"description\",\"email\",\"expired\",\"groups\",\"can_edit\",\"can_delete\"]",
            ),
        ),
    )

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

    private suspend fun groupList(): List<NasGroup> = groups(
        firstSuccessful(
            "SYNO.Core.Group",
            listOf("list"),
            mapOf(
                "offset" to "0",
                "limit" to "1000",
                "additional" to "[\"gid\",\"description\",\"can_edit\",\"can_delete\"]",
            ),
        ),
    )

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

    private suspend fun connectionList(): List<ActiveConnection> {
        if (!supportsVersion("SYNO.Core.CurrentConnection", 1)) {
            throw DsmFailure(
                103,
                "Current connection API version is unsupported",
                "Update DSM and refresh the connection list.",
                kind = DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
            )
        }
        return connections(
            call(
                "SYNO.Core.CurrentConnection",
                "list",
                mapOf(
                    "start" to "0",
                    "limit" to "500",
                    "sort_by" to "time",
                    "sort_direction" to "DESC",
                ),
                version = 1,
            ),
        )
    }

    private fun connections(data: JsonObject): List<ActiveConnection> {
        val items = sequenceOf("connections", "items")
            .mapNotNull { data[it] }
            .firstOrNull()
        val array = items as? JsonArray ?: throw DsmFailure(
            null,
            "Current connection list has an invalid response",
            "Refresh the connection list and try again.",
            kind = DsmErrorKind.INVALID_RESPONSE,
        )
        if (array.any { it !is JsonObject }) {
            throw DsmFailure(
                null,
                "Current connection list has an invalid item",
                "Refresh the connection list and try again.",
                kind = DsmErrorKind.INVALID_RESPONSE,
            )
        }
        return array.asSequence()
            .map { element ->
                val item = element as JsonObject
                val user = item.string("who") ?: item.string("user") ?: item.string("username") ?: ""
                val type = item.string("type")
                val processId = item.string("pid")
                val deviceId = item.string("did")
                val isHttp = type.equals("HTTP/HTTPS", ignoreCase = true)
                val identifier = if (isHttp) deviceId else processId
                val fallbackIdentity = listOf(
                    user,
                    item.string("from").orEmpty(),
                    type.orEmpty(),
                    item.string("time").orEmpty(),
                ).takeIf { values -> values.any(String::isNotBlank) }?.joinToString("|")
                val identityMaterial = identifier?.takeIf(String::isNotBlank)
                    ?: item.string("id")?.takeIf(String::isNotBlank)
                    ?: item.string("connection_id")?.takeIf(String::isNotBlank)
                    ?: fallbackIdentity
                    ?: throw DsmFailure(
                        null,
                        "Current connection item has no usable identity",
                        "Refresh the connection list and try again.",
                        kind = DsmErrorKind.INVALID_RESPONSE,
                    )
                val stableId = UUID.nameUUIDFromBytes(
                    "${if (isHttp) "http" else "service"}:$identityMaterial".toByteArray(),
                ).toString()
                ActiveConnection(
                    id = stableId,
                    user = user,
                    service = item.string("protocol") ?: item.string("service") ?: type ?: "DSM",
                    client = item.string("from") ?: item.string("client") ?: item.string("ip") ?: "",
                    connectedAtEpochSeconds = item.long("time") ?: item.long("connected_at"),
                    isCurrent = item.bool("is_current_connected") ?: item.bool("current") ?: false,
                    processId = processId,
                    deviceId = deviceId,
                    type = type,
                    description = item.string("descr") ?: item.string("description"),
                    canDisconnect = item.bool("can_be_kicked") == true && !identifier.isNullOrBlank(),
                )
            }
            .toList()
    }

    private fun ActiveConnection.hasDisconnectIdentifier(): Boolean =
        if (type.equals("HTTP/HTTPS", ignoreCase = true)) {
            !deviceId.isNullOrBlank()
        } else {
            !processId.isNullOrBlank()
        }

    private fun ActiveConnection.hasSameDisconnectIdentity(other: ActiveConnection): Boolean =
        if (type.equals("HTTP/HTTPS", ignoreCase = true)) {
            !deviceId.isNullOrBlank() && deviceId == other.deviceId
        } else {
            !processId.isNullOrBlank() && processId == other.processId
        }

    private suspend fun verifyConnectionAbsent(expected: ActiveConnection): Boolean {
        val current = connectionList()
        if (current.any { expected.hasSameDisconnectIdentity(it) }) return false
        val expectedIsHttp = expected.type.equals("HTTP/HTTPS", ignoreCase = true)
        val identityBecameAmbiguous = current.any { candidate ->
            val candidateHasExpectedIdentity = if (expectedIsHttp) {
                !candidate.deviceId.isNullOrBlank()
            } else {
                !candidate.processId.isNullOrBlank()
            }
            !candidateHasExpectedIdentity &&
                candidate.user == expected.user && candidate.client == expected.client &&
                candidate.type.equals(expected.type, ignoreCase = true)
        }
        if (identityBecameAmbiguous) {
            throw DsmFailure(
                null,
                "Current connection identity is missing after disconnect",
                "Refresh the connection list before trying again.",
                kind = DsmErrorKind.INVALID_RESPONSE,
            )
        }
        return true
    }

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

    private fun NasDdnsDraft.normalized() = copy(
        originalProviderId = originalProviderId?.trim()?.takeIf(String::isNotEmpty),
        providerId = providerId.trim(),
        hostname = hostname.trim().lowercase(Locale.ROOT),
        username = username.trim(),
    )

    private fun isValidDdnsDraft(value: NasDdnsDraft): Boolean =
        isSafeDdnsProviderId(value.providerId) &&
            isValidDdnsHostname(value.hostname) &&
            isValidDdnsReadableFields(
                value.username,
                value.networkType,
                value.ipv4,
                value.ipv6,
                value.interfaceV4,
                value.interfaceV6,
            ) &&
            value.password.length <= 1_024 && !value.password.hasDdnsControlCharacter() &&
            (value.originalProviderId != null || value.providerId == "Synology" || value.password.isNotEmpty()) &&
            value.originalProviderId?.let(::isSafeDdnsProviderId) != false

    private fun isValidDdnsReadableFields(
        username: String,
        networkType: String,
        ipv4: String,
        ipv6: String,
        interfaceV4: String,
        interfaceV6: String,
    ): Boolean = username.isNotBlank() && username.length <= 1_024 &&
        !username.hasDdnsControlCharacter() && networkType.isNotBlank() && networkType.length <= 64 &&
        !networkType.hasDdnsControlCharacter() && isValidDdnsIpv4(ipv4) && isValidDdnsIpv6(ipv6) &&
        interfaceV4.length <= 128 && !interfaceV4.hasDdnsControlCharacter() &&
        interfaceV6.length <= 128 && !interfaceV6.hasDdnsControlCharacter()

    private fun String.hasDdnsControlCharacter(): Boolean = any(Char::isISOControl)

    private fun isValidDdnsIpv4(value: String): Boolean = value.length <= 15 &&
        value.split('.').let { parts ->
            parts.size == 4 && parts.all { part ->
                part.isNotEmpty() && part.length <= 3 && part.all(Char::isDigit) &&
                    part.toIntOrNull() in 0..255
            }
        }

    private fun isValidDdnsIpv6(value: String): Boolean = value.length in 2..64 &&
        value.all { it.isDigit() || it.lowercaseChar() in 'a'..'f' || it == ':' || it == '.' } &&
        runCatching { InetAddress.getByName(value) is Inet6Address }.getOrDefault(false)

    private fun isSafeDdnsProviderId(value: String): Boolean =
        value.isNotBlank() && value.length <= 128 &&
            value.all { it.isLetterOrDigit() || it in "._- " }

    private fun isValidDdnsHostname(value: String): Boolean {
        if (value.isBlank() || value.length > 253 || value.startsWith('.') || value.endsWith('.') ||
            ".." in value || value.any { it.isWhitespace() || !(it.isLetterOrDigit() || it == '.' || it == '-') }
        ) return false
        return value.split('.').all { label ->
            label.isNotEmpty() && label.length <= 63 && !label.startsWith('-') && !label.endsWith('-')
        }
    }

    private fun ddnsParameters(value: NasDdnsDraft): Map<String, String> = buildMap {
        put("provider", value.providerId)
        put("hostname", value.hostname)
        put("username", value.username)
        if (value.password.isNotEmpty() || value.providerId == "Synology") put("passwd", value.password)
        put("enable", value.isEnabled.toString())
        put("heartbeat", value.heartbeat.toString())
        put("net", value.networkType)
        put("ip", value.ipv4)
        put("ipv6", value.ipv6)
        put("interface_v4", value.interfaceV4)
        put("interface_v6", value.interfaceV6)
    }

    private fun NasDdnsRecord.matches(value: NasDdnsDraft): Boolean =
        providerId == value.providerId &&
            hostname.equals(value.hostname, ignoreCase = true) &&
            username == value.username &&
            isEnabled == value.isEnabled &&
            heartbeat == value.heartbeat

    private fun NasDdnsRecord.hasSameDdnsBaseline(expected: NasDdnsRecord): Boolean =
        providerId == expected.providerId &&
            hostname.equals(expected.hostname, ignoreCase = true) &&
            username == expected.username &&
            isEnabled == expected.isEnabled &&
            heartbeat == expected.heartbeat

    private fun supportsDdnsV1(): Boolean =
        supportsVersion(DDNS_PROVIDER_API, 1) && supportsVersion(DDNS_RECORD_API, 1)

    private fun ddnsProviderMutationKey(providerId: String) = "$DDNS_PROVIDER_MUTATION_PREFIX$providerId"

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

    private fun ethernetConfiguration(value: NasEthernetInterface): JsonArray {
        val config = buildMap<String, JsonElement> {
            put("ifname", JsonPrimitive(value.id))
            put("use_dhcp", JsonPrimitive(value.usesDhcp))
            put("is_default_gateway", JsonPrimitive(value.isDefaultGateway))
            put("mtu", JsonPrimitive(value.mtu))
            put("enable_vlan", JsonPrimitive(value.isVlanEnabled))
            if (!value.usesDhcp) {
                put("ip", JsonPrimitive(value.address))
                put("mask", JsonPrimitive(value.subnetMask))
                put("gateway", JsonPrimitive(value.gateway))
                put("dns", JsonPrimitive(value.dnsServers))
            }
            if (value.isVlanEnabled) put("vlan_id", JsonPrimitive(checkNotNull(value.vlanId)))
        }
        return JsonArray(listOf(JsonObject(config)))
    }

    private fun NasEthernetInterface.matches(expected: NasEthernetInterface): Boolean =
        id == expected.id &&
            usesDhcp == expected.usesDhcp &&
            (expected.usesDhcp || address == expected.address) &&
            (expected.usesDhcp || subnetMask == expected.subnetMask) &&
            (expected.usesDhcp || gateway == expected.gateway) &&
            (expected.usesDhcp || dnsServers == expected.dnsServers) &&
            isDefaultGateway == expected.isDefaultGateway &&
            mtu == expected.mtu &&
            isVlanEnabled == expected.isVlanEnabled &&
            (!expected.isVlanEnabled || vlanId == expected.vlanId)

    private fun isValidEthernetInterface(value: NasEthernetInterface): Boolean =
        isSafeEthernetId(value.id) &&
            value.mtu in 576..9_000 &&
            (!value.isVlanEnabled || value.vlanId?.let { it in 1..4_094 } == true) &&
            (value.usesDhcp || (
                isValidIpv4(value.address) &&
                    isValidIpv4SubnetMask(value.subnetMask) &&
                    (value.gateway.isEmpty() || isValidIpv4(value.gateway)) &&
                    isValidEthernetDns(value.dnsServers)
                ))

    private fun NasEthernetInterface.normalizedEthernetInput(): NasEthernetInterface = copy(
        address = address.trim(),
        subnetMask = subnetMask.trim(),
        gateway = gateway.trim(),
        dnsServers = dnsServers.trim(),
    )

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

    private fun isSafeEthernetId(value: String): Boolean =
        value.startsWith("eth") && value.matches(Regex("[A-Za-z0-9_-]+"))

    private fun isValidIpv4(value: String): Boolean {
        val parts = value.split('.', limit = 5)
        return parts.size == 4 && parts.all { part ->
            part.isNotEmpty() && part.length <= 3 && part.all(Char::isDigit) &&
                part.toIntOrNull()?.let { it in 0..255 } == true &&
                (part == "0" || !part.startsWith('0'))
        }
    }

    private fun isValidIpv4SubnetMask(value: String): Boolean {
        if (!isValidIpv4(value)) return false
        val mask = value.split('.').fold(0L) { result, part ->
            (result shl 8) or checkNotNull(part.toLongOrNull())
        }
        val inverse = mask xor 0xFFFF_FFFFL
        return inverse and (inverse + 1L) == 0L
    }

    /** 当前证据仅确认空值或单个 IPv4；未知分隔格式不猜测、不提交。 */
    private fun isValidEthernetDns(value: String): Boolean =
        value.isEmpty() || (value.length <= 15 && isValidIpv4(value))

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

    private fun supports(apiName: String) = capabilities.containsKey(apiName)

    private fun preferred(vararg names: String): String =
        names.firstOrNull(::supports)
            ?: throw DsmFailure(
                102,
                "Feature unsupported",
                "Update DSM or the related package.",
                kind = DsmErrorKind.FEATURE_UNSUPPORTED,
            )

    private fun jsonStrings(values: List<String>): String =
        JsonArray(values.map(::JsonPrimitive)).toString()

    private fun join(parent: String, child: String): String =
        if (parent.endsWith('/')) "$parent$child" else "$parent/$child"

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
        const val FILE_STATION_BACKGROUND_TASK_API = "SYNO.FileStation.BackgroundTask"
        const val FILE_STATION_VIRTUAL_FOLDER_API = "SYNO.FileStation.VirtualFolder"
        val FILE_BACKGROUND_TASK_APIS = listOf(
            FILE_STATION_COPY_MOVE_API,
            FILE_STATION_DELETE_API,
            FILE_STATION_EXTRACT_API,
            FILE_STATION_COMPRESS_API,
        )
        const val MAX_FILE_BACKGROUND_TASK_PAGE_SIZE = 100
        const val MAX_FILE_BACKGROUND_TASK_ID_BYTES = 256
        const val MIN_FILE_BACKGROUND_TASK_EPOCH_SECONDS = 946_684_800.0
        const val MAXIMUM_DUPLICATE_CANDIDATES = 400
        const val MAX_DOWNLOAD_URI_CHARACTERS = 8_192
        const val MAX_DOWNLOAD_DESTINATION_CHARACTERS = 2_048
        const val MAX_CHAT_MESSAGE_CHARACTERS = 10_000
        const val CHAT_POST_CREATE_VERSION = 5
        const val CHAT_SEND_READBACK_CLOCK_SKEW_SECONDS = 5L
        const val CHAT_SEND_READBACK_WINDOW_SECONDS = 120L
        const val CHAT_ATTACHMENT_READBACK_WINDOW_SECONDS = 180L
        const val CHAT_CHANNEL_ANONYMOUS_API = "SYNO.Chat.Channel.Anonymous"
        const val CHAT_CHANNEL_NAMED_API = "SYNO.Chat.Channel.Named"
        const val CHAT_CHANNEL_MEMBER_API = "SYNO.Chat.Channel.Member"
        const val CHAT_POST_FILE_API = "SYNO.Chat.Post.File"
        const val CHAT_POST_REMINDER_API = "SYNO.Chat.Post.Reminder"
        const val CHAT_POST_SCHEDULE_API = "SYNO.Chat.Post.Schedule"
        const val CHAT_POST_VOTE_API = "SYNO.Chat.Post.Vote"
        const val MAX_CHAT_GROUP_TITLE_CHARACTERS = 100
        const val MAX_CHAT_POLL_OPTIONS = 10
        const val MAX_CHAT_POLL_OPTION_CHARACTERS = 500
        const val MAX_CHAT_THUMBNAIL_BYTES = 8L * 1024 * 1024
        const val MAX_CHAT_VIDEO_PREVIEW_BYTES = 512L * 1024 * 1024
        const val MAX_CHAT_ATTACHMENT_DOWNLOAD_BYTES = 20L * 1024 * 1024 * 1024
        const val MIN_CHAT_REMINDER_LEAD_MILLIS = 60_000L
        const val MAX_CHAT_REMINDER_HORIZON_MILLIS = 10L * 365 * 24 * 60 * 60 * 1_000
        const val MAX_SEARCH_EMPTY_POLLS = 120
        val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp", "raw")
        val VIDEO_EXTENSIONS = setOf("mp4", "m4v", "mov", "avi", "mkv", "webm", "mpeg", "mpg", "ts", "m2ts")
        val AUDIO_EXTENSIONS = setOf("mp3", "m4a", "aac", "flac", "wav", "ogg", "ape", "alac")
        val DOCUMENT_EXTENSIONS = setOf("pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "md", "rtf", "pages", "numbers", "key")
        val ARCHIVE_EXTENSIONS = setOf("zip", "rar", "7z", "tar", "gz", "bz2", "xz", "dmg", "iso")
        const val SHARING_PAGE_SIZE = 500
        const val MAX_COPY_MOVE_POLLS = 120
        const val COPY_MOVE_POLL_INTERVAL_MILLIS = 500L
        const val MAX_FILE_TASK_POLLS = 120
        const val FILE_TASK_POLL_INTERVAL_MILLIS = 500L
        const val MAX_ARCHIVE_ITEMS = 1000
        const val MAX_THUMBNAIL_BYTES = 8L * 1024L * 1024L
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
        const val REGION_API = "SYNO.Core.Region.NTP"
        const val PROXY_API = "SYNO.Core.Network.Proxy"
        const val QUICK_CONNECT_API = "SYNO.Core.QuickConnect"
        const val QUICK_CONNECT_UPNP_API = "SYNO.Core.QuickConnect.Upnp"
        const val QUICK_CONNECT_VERSION = 3
        const val QUICK_CONNECT_UPNP_VERSION = 1
        const val REMOTE_ACCESS_MUTATION_KEY = "remote-access-settings"
        const val REMOTE_ACCESS_RELAY_FIELD = "relay"
        const val REMOTE_ACCESS_ROUTER_FIELD = "router"
        const val RECORDED_DSM_BUILD = 69057
        const val RECORDED_DSM_UPDATE = 12
        val RECORDED_DSM_VERSION = Regex(
            "^DSM\\s+7\\.2\\.1(?:-(\\d+))?(?:\\s+Update\\s+(\\d+))?$",
            RegexOption.IGNORE_CASE,
        )
        const val ETHERNET_API = "SYNO.Core.Network.Ethernet"
        const val DDNS_PROVIDER_API = "SYNO.Core.DDNS.Provider"
        const val DDNS_RECORD_API = "SYNO.Core.DDNS.Record"
        const val DDNS_PROVIDER_MUTATION_PREFIX = "ddns:provider:"
        const val DDNS_GLOBAL_MUTATION_KEY = "ddns:global"
        const val SECURITY_AUTO_BLOCK_API = "SYNO.Core.Security.AutoBlock"
        const val SECURITY_DOS_API = "SYNO.Core.Security.DoS"
        const val SECURITY_FIREWALL_API = "SYNO.Core.Security.Firewall"
        const val SECURITY_FIREWALL_CONF_API = "SYNO.Core.Security.Firewall.Conf"
        const val SECURITY_FIREWALL_APPLY_API = "SYNO.Core.Security.Firewall.Profile.Apply"
        const val USER_API = "SYNO.Core.User"
        const val GROUP_API = "SYNO.Core.Group"
        const val DIRECTORY_API_VERSION = 1
        const val PACKAGE_API = "SYNO.Core.Package"
        const val PACKAGE_CONTROL_API = "SYNO.Core.Package.Control"
        const val PACKAGE_UNINSTALL_API = "SYNO.Core.Package.Uninstallation"
        const val PACKAGE_THUMB_API = "SYNO.Core.Package.Thumb"
        const val PACKAGE_READ_VERSION = 2
        const val PACKAGE_WRITE_VERSION = 1
        const val PACKAGE_THUMB_VERSION = 1
        const val PACKAGE_CONFIRMED_READBACK_ATTEMPTS = 10
        const val PACKAGE_AMBIGUOUS_READBACK_ATTEMPTS = 3
        const val PACKAGE_READBACK_INTERVAL_MILLIS = 1_000L
        const val STORAGE_OVERVIEW_API = "SYNO.Storage.CGI.Storage"
        const val SMART_API_VERSION = 1
        const val SMART_READBACK_ATTEMPTS = 6
        const val SMART_READBACK_INTERVAL_MILLIS = 1_000L
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
        val FAN_MODES = setOf("highfan", "lowfan", "fullfan", "coolfan", "quietfan", "quietstopfan")
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

internal fun decodeTextPreview(bytes: ByteArray): String {
    val (content, charset) = when {
        bytes.startsWith(byteArrayOf(0xEF.toByte(), 0xBB.toByte(), 0xBF.toByte())) ->
            bytes.copyOfRange(3, bytes.size) to Charsets.UTF_8
        bytes.startsWith(byteArrayOf(0xFF.toByte(), 0xFE.toByte())) ->
            bytes.copyOfRange(2, bytes.size) to Charsets.UTF_16LE
        bytes.startsWith(byteArrayOf(0xFE.toByte(), 0xFF.toByte())) ->
            bytes.copyOfRange(2, bytes.size) to Charsets.UTF_16BE
        else -> bytes to Charsets.UTF_8
    }
    return content.toString(charset).replace("\u0000", "�")
}

private fun ByteArray.startsWith(prefix: ByteArray): Boolean =
    size >= prefix.size && prefix.indices.all { this[it] == prefix[it] }

/** 套件图标只接受 DSM 实际返回的常见位图格式，拒绝 HTML、SVG 和未知二进制内容。 */
internal fun hasKnownPackageIconSignature(bytes: ByteArray): Boolean = when {
    bytes.startsWith(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)) -> true
    bytes.startsWith(byteArrayOf(0xFF.toByte(), 0xD8.toByte(), 0xFF.toByte())) -> true
    bytes.startsWith(byteArrayOf(0x47, 0x49, 0x46, 0x38)) -> true
    bytes.size >= 12 && bytes.copyOfRange(0, 4).contentEquals(byteArrayOf(0x52, 0x49, 0x46, 0x46)) &&
        bytes.copyOfRange(8, 12).contentEquals(byteArrayOf(0x57, 0x45, 0x42, 0x50)) -> true
    else -> false
}

/**
 * 将 File Station 列表数据转换为稳定领域语义，供生产请求和脱敏 Fixture 共用。
 */
internal fun parseFilePageFixture(data: JsonObject, root: String = "files"): FilePage {
    val items = data.elements(root).mapNotNull { element ->
        val item = element as? JsonObject ?: return@mapNotNull null
        val additional = item.objectValue("additional")
        val time = additional?.objectValue("time")
        val permission = additional?.objectValue("perm")
        FileItem(
            path = item.string("path") ?: return@mapNotNull null,
            name = item.string("name") ?: item.string("path")?.substringAfterLast('/').orEmpty(),
            isDirectory = item.bool("isdir") ?: false,
            size = item.long("size") ?: additional?.long("size") ?: 0,
            modifiedAtEpochSeconds = time?.long("mtime") ?: item.long("mtime"),
            accessedAtEpochSeconds = time?.long("atime") ?: item.long("atime"),
            owner = additional?.objectValue("owner")?.string("user") ?: additional?.string("owner"),
            canRead = permission?.bool("read") ?: true,
            canWrite = permission?.bool("write") ?: false,
            canDelete = permission?.bool("delete") ?: false,
            mountPointType = additional?.string("mount_point_type") ?: item.string("mount_point_type"),
        )
    }
    return FilePage(
        items = items,
        total = data.int("total") ?: items.size,
        offset = data.int("offset") ?: 0,
    )
}

internal fun parseVirtualizationLogs(data: JsonObject): List<LogEntry> =
    sequenceOf("logs", "log", "events", "records", "entries", "items", "data", "list")
        .flatMap { data.elements(it).asSequence() }
        .distinctBy { it.toString() }
        .mapIndexedNotNull { index, element ->
            val item = element as? JsonObject ?: return@mapIndexedNotNull null
            val rawTime = item.long("time")
                ?: item.long("timestamp")
                ?: item.long("date")
                ?: item.long("event_time")
                ?: item.long("create_time")
                ?: item.long("created_at")
            val event = item.string("event")
                ?: item.string("message")
                ?: item.string("description")
                ?: item.string("msg")
                ?: item.string("content")
                ?: item.string("detail")
                ?: return@mapIndexedNotNull null
            LogEntry(
                id = item.string("id") ?: item.string("log_id") ?: "${rawTime ?: 0}:$index",
                level = parsedLogLevel(
                    item.string("level")
                        ?: item.string("severity")
                        ?: item.string("type")
                        ?: item.string("priority")
                ),
                timeEpochSeconds = rawTime?.let { if (it > 10_000_000_000) it / 1_000 else it },
                user = item.string("user")
                    ?: item.string("username")
                    ?: item.string("owner")
                    ?: item.string("account")
                    ?: item.string("user_name")
                    ?: "SYSTEM",
                event = event,
            )
        }
        .toList()

private fun parsedLogLevel(value: String?): LogLevel = when (value?.lowercase()) {
    "info", "information", "0" -> LogLevel.INFO
    "warning", "warn", "1" -> LogLevel.WARNING
    "error", "err", "2" -> LogLevel.ERROR
    else -> LogLevel.UNKNOWN
}

private fun JsonObject.elements(key: String): List<JsonElement> =
    (this[key] as? JsonArray)?.toList().orEmpty()

private fun JsonObject.bool(key: String): Boolean? =
    this[key]?.jsonPrimitive?.let { primitive ->
        primitive.booleanOrNull
            ?: primitive.contentOrNull?.let { value ->
                when (value.lowercase()) {
                    "1", "true" -> true
                    "0", "false" -> false
                    else -> null
                }
            }
    }

private fun JsonObject.number(key: String): Double? =
    (this[key] as? JsonPrimitive)?.contentOrNull?.toDoubleOrNull()?.takeIf { it.isFinite() }

private fun JsonObject.nonNegativeLong(key: String): Long? =
    long(key)?.coerceAtLeast(0)

private fun JsonObject.valueString(vararg keys: String): String? = keys.firstNotNullOfOrNull { key ->
    (this[key] as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank)
}

private fun JsonObject.firstNonBlank(vararg keys: String): String? =
    keys.firstNotNullOfOrNull { key -> string(key)?.trim()?.takeIf(String::isNotBlank) }

private fun normalizeEpoch(value: Long?): Long? = value?.let {
    when {
        it > 10_000_000_000L -> it / 1_000
        it > 0 -> it
        else -> null
    }
}

private fun normalizeEpochMillis(value: Long?): Long? = value?.let {
    when {
        it > 10_000_000_000L -> it
        it > 0 -> it * 1_000
        else -> null
    }
}
