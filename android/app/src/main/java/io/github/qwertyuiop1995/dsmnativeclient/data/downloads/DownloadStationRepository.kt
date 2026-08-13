package io.github.qwertyuiop1995.dsmnativeclient.data.downloads

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.ApiCapability
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchCatalog
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchModule
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchModuleScope
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchOptions
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadBtSearchResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssFeed
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadRssSite
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettings
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadStationActivity
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTask
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskFile
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationAction
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskMutationBaseline
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskPeer
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadTaskTracker
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmErrorKind
import io.github.qwertyuiop1995.dsmnativeclient.domain.DsmFailure
import io.github.qwertyuiop1995.dsmnativeclient.domain.FileItem
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationErrorCategory
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResult
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultCounts
import io.github.qwertyuiop1995.dsmnativeclient.domain.MutationResultStatus
import io.github.qwertyuiop1995.dsmnativeclient.domain.ResourceState
import io.github.qwertyuiop1995.dsmnativeclient.network.int
import io.github.qwertyuiop1995.dsmnativeclient.network.long
import io.github.qwertyuiop1995.dsmnativeclient.network.objectValue
import io.github.qwertyuiop1995.dsmnativeclient.network.string
import java.io.InputStream
import java.net.URI
import java.security.MessageDigest
import java.util.Locale
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.jsonPrimitive

internal class DownloadStationRepository(
    private val gateway: DownloadStationRepositoryGateway,
    private val mutationLock: Mutex,
    private val activeMutationIds: MutableSet<String>,
    private val creationMutationLock: Mutex,
    private val activeCreationKeys: MutableSet<String>,
    private val settingsMutationLock: Mutex,
    private val isSettingsMutationActive: () -> Boolean,
    private val setSettingsMutationActive: (Boolean) -> Unit,
) {
    private val serviceMutationLock = Mutex()
    private val activeServiceMutationTargets = mutableSetOf<String>()

    private suspend fun claimServiceMutation(target: String): Boolean =
        serviceMutationLock.withLock {
            if (target in activeServiceMutationTargets) {
                false
            } else {
                activeServiceMutationTargets += target
                true
            }
        }

    private suspend fun releaseServiceMutation(target: String) {
        serviceMutationLock.withLock { activeServiceMutationTargets.remove(target) }
    }

    suspend fun listDownloads(): List<DownloadTask> = downloadTaskList(strict = false)

    /** 对象外链按完整稳定列表重新确认任务，避免把后续分页中的现存任务误判为已删除。 */
    suspend fun downloadTask(taskId: String): DownloadTask? {
        require(taskId.isNotBlank()) { "Download task ID is required" }
        return strictDownloadTaskList().firstOrNull { it.id == taskId }
    }

    /**
     * 写操作只能使用完整严格列表。带 `total` 的响应逐页读取并要求总数保持稳定；不带
     * `total` 时，只有不足一页的响应才能证明列表完整，满页必须失败关闭。
     */
    private suspend fun strictDownloadTaskList(): List<DownloadTask> {
        val accumulated = mutableListOf<DownloadTask>()
        val seenIds = mutableSetOf<String>()
        var offset = 0
        var expectedTotal: Int? = null
        while (true) {
            val page = downloadTaskPage(
                strict = true,
                offset = offset,
                limit = DOWNLOAD_MUTATION_LIST_PAGE_SIZE,
            )
            val pageTotal = page.total
            if (pageTotal != null && pageTotal < 0) throw invalidDownloadTaskList()
            if (expectedTotal == null) {
                expectedTotal = pageTotal
            } else if (pageTotal == null || pageTotal != expectedTotal) {
                throw invalidDownloadTaskList()
            }
            if (pageTotal == null) {
                if (page.tasks.size >= DOWNLOAD_MUTATION_LIST_PAGE_SIZE) {
                    throw invalidDownloadTaskList()
                }
                return page.tasks
            }
            if (page.tasks.size > DOWNLOAD_MUTATION_LIST_PAGE_SIZE ||
                page.tasks.any { !seenIds.add(it.id) }
            ) {
                throw invalidDownloadTaskList()
            }
            accumulated += page.tasks
            val total = checkNotNull(expectedTotal)
            if (accumulated.size > total) throw invalidDownloadTaskList()
            if (accumulated.size == total) return accumulated
            if (page.tasks.isEmpty()) throw invalidDownloadTaskList()
            offset += page.tasks.size
        }
    }

    /** 状态层专项刷新入口；只允许可信 `tasks` 数组，供写后核对而非普通列表展示。 */
    suspend fun activeDownloadTasksForMutation(): List<DownloadTask> =
        strictDownloadTaskList()

    private suspend fun downloadTaskList(strict: Boolean): List<DownloadTask> =
        downloadTaskPage(strict = strict, offset = 0, limit = DOWNLOAD_MUTATION_LIST_PAGE_SIZE).tasks

    private data class DownloadTaskPage(
        val tasks: List<DownloadTask>,
        val total: Int?,
    )

    private suspend fun downloadTaskPage(
        strict: Boolean,
        offset: Int,
        limit: Int,
    ): DownloadTaskPage {
        val apiName = gateway.preferred("SYNO.DownloadStation.Task", "SYNO.DownloadStation2.Task")
        val isOfficial = apiName == "SYNO.DownloadStation.Task"
        val data = gateway.call(
            apiName,
            "list",
            mapOf(
                "offset" to offset.toString(),
                "limit" to limit.toString(),
                "additional" to if (isOfficial) {
                    "detail,transfer,file,tracker,peer"
                } else {
                    "detail,transfer"
                },
            ),
            version = if (isOfficial) 1 else null,
        )
        val elements = if (strict) {
            (data["tasks"] as? JsonArray)?.toList() ?: throw invalidDownloadTaskList()
        } else {
            data.elements("tasks")
        }
        val tasks = elements.mapNotNull { element ->
            val item = element as? JsonObject
            if (strict && item == null) throw invalidDownloadTaskList()
            item?.let { downloadTask(it, strict) }
        }
        if (strict && tasks.map(DownloadTask::id).toSet().size != tasks.size) {
            throw invalidDownloadTaskList()
        }
        val totalElement = data["total"]
        val total = data.int("total")
        if (strict && totalElement != null && total == null) throw invalidDownloadTaskList()
        return DownloadTaskPage(tasks, total)
    }

    private fun downloadTask(item: JsonObject, strict: Boolean): DownloadTask? {
        val id = item.string("id")
        if (id.isNullOrBlank() || id != id.trim()) {
            if (strict) throw invalidDownloadTaskList()
            return null
        }
        val additional = item.objectValue("additional")
        val transfer = additional?.objectValue("transfer")
        val detail = additional?.objectValue("detail")
        val statusExtra = item.objectValue("status_extra")
        return DownloadTask(
            id = id,
            type = item.string("type"),
            title = item.string("title").orEmpty(),
            status = state(item.string("status")),
            size = item.long("size"),
            transferred = item.long("size_downloaded") ?: transfer?.long("size_downloaded"),
            downloadSpeed = transfer?.long("speed_download"),
            uploadSpeed = transfer?.long("speed_upload"),
            destination = detail?.string("destination"),
            error = statusExtra?.string("error_detail") ?: detail?.string("error_detail"),
            createdAtEpochSeconds = detail?.long("create_time"),
            priority = detail?.string("priority")?.trim(),
            totalPeers = detail?.int("total_peers"),
            connectedSeeders = detail?.int("connected_seeders"),
            connectedLeechers = detail?.int("connected_leechers"),
            files = additional?.elements("file").orEmpty().mapNotNull { value ->
                val file = value as? JsonObject ?: return@mapNotNull null
                DownloadTaskFile(
                    name = file.string("filename") ?: return@mapNotNull null,
                    size = file.long("size"),
                    downloaded = file.long("size_downloaded"),
                    priority = file.string("priority")?.trim(),
                )
            },
            trackers = additional?.elements("tracker").orEmpty().mapNotNull { value ->
                val tracker = value as? JsonObject ?: return@mapNotNull null
                DownloadTaskTracker(
                    url = tracker.string("url") ?: return@mapNotNull null,
                    status = tracker.string("status"),
                    updateTimerSeconds = tracker.int("update_timer"),
                    seeds = tracker.int("seeds"),
                    peers = tracker.int("peers"),
                )
            },
            peers = additional?.elements("peer").orEmpty().mapNotNull { value ->
                val peer = value as? JsonObject ?: return@mapNotNull null
                DownloadTaskPeer(
                    address = peer.string("address") ?: return@mapNotNull null,
                    agent = peer.string("agent"),
                    progress = peer["progress"]?.jsonPrimitive?.doubleOrNull,
                    downloadSpeed = peer.long("speed_download"),
                    uploadSpeed = peer.long("speed_upload"),
                )
            },
        )
    }

    private fun invalidDownloadTaskList() = DsmFailure(
        null,
        "The NAS returned an invalid download task list",
        "Refresh Download Station and try again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    fun supportsRss(): Boolean =
        gateway.supports("SYNO.DownloadStation.RSS.Site") && gateway.supports("SYNO.DownloadStation.RSS.Feed")

    fun supportsBtSearch(): Boolean = gateway.supports("SYNO.DownloadStation.BTSearch")

    fun supportsActivity(): Boolean =
        gateway.supportsVersion("SYNO.DownloadStation.Statistic", 1)

    suspend fun loadActivity(): DownloadStationActivity {
        if (!supportsActivity()) throw DsmFailure(
            null,
            "Download activity is unavailable",
            "Refresh Download Station or use DSM to view current speeds.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
        val data = gateway.call(
            "SYNO.DownloadStation.Statistic",
            "getinfo",
            version = 1,
        )
        fun requiredRate(key: String): Long = data.long(key)?.takeIf { it >= 0 }
            ?: throw invalidDownloadAdvancedResponse("activity-$key")
        return DownloadStationActivity(
            downloadBytesPerSecond = requiredRate("speed_download"),
            uploadBytesPerSecond = requiredRate("speed_upload"),
            emuleDownloadBytesPerSecond = requiredRate("emule_speed_download"),
            emuleUploadBytesPerSecond = requiredRate("emule_speed_upload"),
        )
    }

    suspend fun loadBtSearchCatalog(): DownloadBtSearchCatalog {
        if (!gateway.supportsVersion("SYNO.DownloadStation.BTSearch", 1)) throw DsmFailure(
            null,
            "Download search options are unavailable",
            "Refresh Download Station and try again.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
        val moduleData = gateway.call(
            "SYNO.DownloadStation.BTSearch",
            "getModule",
            version = 1,
        )
        val categoryData = gateway.call(
            "SYNO.DownloadStation.BTSearch",
            "getCategory",
            version = 1,
        )
        val moduleValues = moduleData["modules"] as? JsonArray
            ?: throw invalidDownloadAdvancedResponse("modules")
        val categoryValues = categoryData["categories"] as? JsonArray
            ?: throw invalidDownloadAdvancedResponse("categories")
        val modules = moduleValues.map { value ->
            val item = value as? JsonObject ?: throw invalidDownloadAdvancedResponse("module")
            DownloadBtSearchModule(
                id = requiredDownloadSearchId(item, "id", commaSeparated = true),
                title = requiredDownloadSearchTitle(item),
                enabled = item.bool("enabled")
                    ?: throw invalidDownloadAdvancedResponse("module-enabled"),
            )
        }
        val categories = categoryValues.map { value ->
            val item = value as? JsonObject ?: throw invalidDownloadAdvancedResponse("category")
            DownloadBtSearchCategory(
                id = requiredDownloadSearchId(item, "id", commaSeparated = false),
                title = requiredDownloadSearchTitle(item),
            )
        }
        if (modules.map { it.id }.toSet().size != modules.size) {
            throw invalidDownloadAdvancedResponse("duplicate-module")
        }
        if (categories.map { it.id }.toSet().size != categories.size) {
            throw invalidDownloadAdvancedResponse("duplicate-category")
        }
        return DownloadBtSearchCatalog(modules = modules, categories = categories)
    }

    private fun requiredDownloadSearchId(
        item: JsonObject,
        key: String,
        commaSeparated: Boolean,
    ): String {
        val id = item.string(key) ?: throw invalidDownloadAdvancedResponse(key)
        if (id.isBlank() || id != id.trim() || id.any(Char::isISOControl) ||
            (commaSeparated && ',' in id)
        ) {
            throw invalidDownloadAdvancedResponse(key)
        }
        return id
    }

    private fun requiredDownloadSearchTitle(item: JsonObject): String {
        val title = item.string("title") ?: throw invalidDownloadAdvancedResponse("title")
        if (title.isBlank() || title != title.trim() || title.any(Char::isISOControl)) {
            throw invalidDownloadAdvancedResponse("title")
        }
        return title
    }

    private fun invalidDownloadAdvancedResponse(scope: String) = DsmFailure(
        null,
        "The NAS returned invalid Download Station data",
        "Refresh Download Station and try again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    suspend fun listRssSites(): List<DownloadRssSite> {
        val data = gateway.call(
            "SYNO.DownloadStation.RSS.Site",
            "list",
            mapOf("offset" to "0", "limit" to "200"),
            version = 1,
        )
        val values = data.elements("sites").ifEmpty { data.elements("site") }
        return values.mapNotNull { value ->
            val site = value as? JsonObject ?: return@mapNotNull null
            DownloadRssSite(
                id = site.string("id") ?: return@mapNotNull null,
                title = site.string("title").orEmpty(),
                isUpdating = site.bool("is_updating") == true,
                lastUpdatedAtEpochSeconds = site.long("last_update"),
            )
        }
    }

    suspend fun listRssFeeds(siteId: String): List<DownloadRssFeed> {
        require(siteId.isNotBlank()) { "RSS site ID is required" }
        val data = gateway.call(
            "SYNO.DownloadStation.RSS.Feed",
            "list",
            mapOf("id" to siteId, "offset" to "0", "limit" to "200"),
            version = 1,
        )
        return data.elements("feeds").mapNotNull { value ->
            val feed = value as? JsonObject ?: return@mapNotNull null
            DownloadRssFeed(
                title = feed.string("title").orEmpty(),
                size = feed.long("size"),
                publishedAtEpochSeconds = feed.long("time"),
                downloadUri = feed.string("download_uri") ?: return@mapNotNull null,
                externalLink = feed.string("external_link"),
            )
        }
    }

    suspend fun refreshRssSiteResult(siteId: String): MutationResult {
        val operation = "downloadRssRefresh"
        val normalized = siteId.trim()
        if (normalized.isEmpty()) return serviceMutationResult(
            operation = operation,
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "download-station.rss.refresh.invalid-target",
        )
        if (!gateway.supportsVersion("SYNO.DownloadStation.RSS.Site", 1)) return serviceMutationResult(
            operation = operation,
            status = MutationResultStatus.UNSUPPORTED,
            submitted = false,
            errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = "download-station.rss.refresh.unsupported",
        )
        if (!currentCoroutineContext().isActive) return serviceMutationResult(
            operation = operation,
            status = MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            submitted = false,
            diagnosticTag = "download-station.rss.refresh.cancelled-before-submission",
        )

        val exists = try {
            listRssSites().any { it.id == normalized }
        } catch (failure: DsmFailure) {
            return serviceMutationFailure(
                operation,
                failure,
                submitted = false,
                diagnosticTag = "download-station.rss.refresh.preflight-failed",
            )
        }
        if (!exists) return serviceMutationResult(
            operation = operation,
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "download-station.rss.refresh.target-changed",
        )

        val targetKey = "download-rss:$normalized"
        if (!claimServiceMutation(targetKey)) return serviceMutationResult(
            operation = operation,
            status = MutationResultStatus.CONFIRMED_FAILURE,
            submitted = false,
            errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "download-station.rss.refresh.duplicate-submission",
        )
        try {
            try {
                gateway.call(
                    "SYNO.DownloadStation.RSS.Site",
                    "refresh",
                    mapOf("id" to normalized),
                    version = 1,
                )
            } catch (_: CancellationException) {
                return serviceMutationResult(
                    operation = operation,
                    status = MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    diagnosticTag = "download-station.rss.refresh.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                return serviceMutationFailure(
                    operation,
                    failure,
                    submitted = true,
                    diagnosticTag = "download-station.rss.refresh.submission-failed",
                )
            }

            val targetStillExists = try {
                withContext(NonCancellable) {
                    listRssSites().any { it.id == normalized }
                }
            } catch (failure: DsmFailure) {
                return serviceMutationResult(
                    operation = operation,
                    status = MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    errorCategory = failure.mutationErrorCategory(),
                    diagnosticTag = "download-station.rss.refresh.readback-failed",
                )
            }
            return serviceMutationResult(
                operation = operation,
                status = if (targetStillExists) {
                    MutationResultStatus.CONFIRMED_SUCCESS
                } else {
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                },
                submitted = true,
                requiresRefresh = !targetStillExists,
                errorCategory = if (targetStillExists) null else MutationErrorCategory.CONFLICT,
                diagnosticTag = if (targetStillExists) {
                    "download-station.rss.refresh.confirmed"
                } else {
                    "download-station.rss.refresh.target-missing-after-submission"
                },
            )
        } finally {
            withContext(NonCancellable) { releaseServiceMutation(targetKey) }
        }
    }

    suspend fun searchBt(keyword: String): List<DownloadBtSearchResult> =
        searchBt(DownloadBtSearchOptions(keyword = keyword))

    suspend fun searchBt(options: DownloadBtSearchOptions): List<DownloadBtSearchResult> {
        val normalized = options.keyword.trim()
        require(normalized.isNotEmpty() && normalized.length <= 200) {
            "Enter a search keyword up to 200 characters"
        }
        val titleFilter = options.titleFilter.trim()
        require(titleFilter.length <= 200 && titleFilter.none(Char::isISOControl)) {
            "Enter a title filter up to 200 characters"
        }
        val category = options.categoryId?.also { id ->
            require(id.isNotBlank() && id == id.trim() && id.none(Char::isISOControl)) {
                "Choose a valid search category"
            }
        }.orEmpty()
        val module = when (options.moduleScope) {
            DownloadBtSearchModuleScope.ALL -> {
                require(options.selectedModuleIds.isEmpty()) { "Selected modules require selected mode" }
                "all"
            }
            DownloadBtSearchModuleScope.ENABLED -> {
                require(options.selectedModuleIds.isEmpty()) { "Selected modules require selected mode" }
                "enabled"
            }
            DownloadBtSearchModuleScope.SELECTED -> {
                require(options.selectedModuleIds.isNotEmpty()) { "Choose at least one search provider" }
                options.selectedModuleIds.onEach { id ->
                    require(id.isNotBlank() && id == id.trim() && ',' !in id && id.none(Char::isISOControl)) {
                        "Choose valid search providers"
                    }
                }.sorted().joinToString(",")
            }
        }
        val started = gateway.call(
            "SYNO.DownloadStation.BTSearch",
            "start",
            mapOf("keyword" to normalized, "module" to module),
            version = 1,
        )
        val taskId = started.string("taskid") ?: throw DsmFailure(
            null,
            "The NAS did not start the search",
            "Try the search again.",
            kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
        )
        try {
            repeat(MAX_DOWNLOAD_BT_SEARCH_POLLS) {
                val data = gateway.call(
                    "SYNO.DownloadStation.BTSearch",
                    "list",
                    mapOf(
                        "taskid" to taskId,
                        "offset" to "0",
                        "limit" to "200",
                        "sort_by" to options.sort.apiValue,
                        "sort_direction" to options.direction.apiValue,
                        "filter_category" to category,
                        "filter_title" to titleFilter,
                    ),
                    version = 1,
                )
                if (data.bool("finished") == true) return parseDownloadBtResults(data)
                delay(DOWNLOAD_BT_SEARCH_POLL_INTERVAL_MILLIS)
            }
            throw DsmFailure(
                null,
                "The search is taking longer than expected",
                "Try again later.",
                kind = DsmErrorKind.CHANGE_NOT_CONFIRMED,
            )
        } finally {
            withContext(NonCancellable) {
                runCatching {
                    gateway.call(
                        "SYNO.DownloadStation.BTSearch",
                        "clean",
                        mapOf("taskid" to taskId),
                        version = 1,
                    )
                }
            }
        }
    }

    private fun parseDownloadBtResults(data: JsonObject): List<DownloadBtSearchResult> =
        data.elements("items").mapNotNull { value ->
            val item = value as? JsonObject ?: return@mapNotNull null
            DownloadBtSearchResult(
                title = item.string("title").orEmpty(),
                size = item.long("size"),
                listedAt = item.string("date"),
                downloadUri = item.string("download_uri") ?: return@mapNotNull null,
                externalLink = item.string("external_link"),
                peers = item.int("peers"),
                seeds = item.int("seeds"),
                leeches = item.int("leechs"),
                provider = item.string("module_title"),
            )
        }

    suspend fun create(uri: String, destination: String?) {
        requireConfirmedDownloadCreation(createResult(uri, destination))
    }

    suspend fun createResult(uri: String, destination: String?): MutationResult {
        val normalized = uri.trim()
        val parsedUri = runCatching { URI(normalized) }.getOrNull()
        val scheme = parsedUri?.scheme?.lowercase(Locale.ROOT)
        val normalizedDestination = destination?.trim()?.takeIf(String::isNotEmpty)
        val valid = normalized.isNotEmpty() &&
            normalized.length <= MAX_DOWNLOAD_URI_CHARACTERS &&
            scheme in setOf("http", "https", "ftp", "magnet") &&
            when (scheme) {
                "http", "https", "ftp" -> !parsedUri?.host.isNullOrBlank()
                "magnet" -> !parsedUri?.rawSchemeSpecificPart.isNullOrBlank()
                else -> false
            } &&
            (normalizedDestination == null || (
                normalizedDestination.length <= MAX_DOWNLOAD_DESTINATION_CHARACTERS &&
                    '\n' !in normalizedDestination &&
                    '\r' !in normalizedDestination
                ))
        if (!valid) {
            return downloadMutationResult(
                operation = "downloadCreate",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "download-station.create.invalid-input",
            )
        }
        val apiName = gateway.preferredOrNull("SYNO.DownloadStation.Task", "SYNO.DownloadStation2.Task")
            ?: return downloadMutationResult(
                operation = "downloadCreate",
                status = MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "download-station.create.unsupported",
            )
        val key = downloadCreationKey("uri", normalized, normalizedDestination.orEmpty())
        return createDownloadTaskResult("downloadCreate", key, normalizedDestination) {
            gateway.call(
                apiName,
                "create",
                buildMap {
                    put("uri", normalized)
                    normalizedDestination?.let { put("destination", it) }
                },
            )
        }
    }

    suspend fun createFromFile(
        source: UploadSource,
        destination: String? = null,
        unzipPassword: String? = null,
    ) {
        requireConfirmedDownloadCreation(
            createFromFileResult(source, destination, unzipPassword),
        )
    }

    suspend fun createFromFileResult(
        source: UploadSource,
        destination: String? = null,
        unzipPassword: String? = null,
    ): MutationResult {
        val extension = source.displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        val normalizedDestination = destination?.trim()?.takeIf(String::isNotEmpty)
        val valid = extension in setOf("torrent", "nzb", "txt") &&
            source.displayName.isNotBlank() &&
            '\n' !in source.displayName &&
            '\r' !in source.displayName &&
            source.contentLength in 1..MAX_DOWNLOAD_TASK_FILE_BYTES &&
            (normalizedDestination == null || (
                normalizedDestination.length <= MAX_DOWNLOAD_DESTINATION_CHARACTERS &&
                    '\n' !in normalizedDestination &&
                    '\r' !in normalizedDestination
                ))
        if (!valid) {
            return downloadMutationResult(
                operation = "downloadFileCreate",
                status = MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "download-station.file-create.invalid-input",
            )
        }
        val capability = gateway.capability("SYNO.DownloadStation.Task")
            ?: return downloadMutationResult(
                operation = "downloadFileCreate",
                status = MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "download-station.file-create.unsupported",
            )
        val key = downloadCreationKey(
            "file",
            source.requestToken,
            normalizedDestination.orEmpty(),
        )
        return createDownloadTaskResult("downloadFileCreate", key, normalizedDestination) {
            gateway.uploadDownloadTaskFile(
                capability = capability,
                filename = source.displayName,
                contentType = source.contentType,
                contentLength = source.contentLength,
                destination = normalizedDestination,
                unzipPassword = unzipPassword,
                openInputStream = source.openInputStream,
            )
        }
    }

    private suspend fun createDownloadTaskResult(
        operation: String,
        key: String,
        destination: String?,
        submit: suspend () -> JsonObject,
    ): MutationResult {
        val diagnosticOperation = if (operation == "downloadFileCreate") "file-create" else "create"
        if (!currentCoroutineContext().isActive) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "download-station.$diagnosticOperation.cancelled-before-submission",
            )
        }
        val claimed = creationMutationLock.withLock { activeCreationKeys.add(key) }
        if (!claimed) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "download-station.$diagnosticOperation.duplicate-submission",
            )
        }
        try {
            if (destination != null) {
                val destinationFailure = validateDownloadCreationDestination(
                    operation = operation,
                    diagnosticOperation = diagnosticOperation,
                    destination = destination,
                )
                if (destinationFailure != null) return destinationFailure
            }
            val previousIds = try {
                strictDownloadTaskList().mapTo(mutableSetOf(), DownloadTask::id)
            } catch (_: CancellationException) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "download-station.$diagnosticOperation.cancelled-before-submission",
                )
            } catch (failure: DsmFailure) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = downloadMutationErrorCategory(failure),
                    diagnosticTag = "download-station.$diagnosticOperation.preflight-failed",
                )
            }
            val submittedData = try {
                submit()
            } catch (_: CancellationException) {
                withContext(NonCancellable) {
                    // 取消时无法取得稳定任务 ID，只回读但绝不猜测新任务归属。
                    runCatching { strictDownloadTaskList() }
                }
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "download-station.$diagnosticOperation.cancelled-after-submission",
                )
            } catch (failure: DsmFailure) {
                val permission = failure.kind in setOf(
                    DsmErrorKind.PERMISSION_DENIED,
                    DsmErrorKind.SESSION_EXPIRED,
                    DsmErrorKind.AUTHENTICATION_FAILED,
                )
                val unverified = failure.kind in setOf(
                    DsmErrorKind.CONNECTION_FAILED,
                    DsmErrorKind.INVALID_RESPONSE,
                    DsmErrorKind.UNKNOWN,
                )
                if (permission) {
                    return downloadMutationResult(
                        operation,
                        MutationResultStatus.PERMISSION_DENIED,
                        submitted = true,
                        failed = 1,
                        errorCategory = downloadMutationErrorCategory(failure),
                        diagnosticTag = "download-station.$diagnosticOperation.permission-denied",
                    )
                }
                if (!unverified) {
                    return downloadMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = true,
                        failed = 1,
                        errorCategory = downloadMutationErrorCategory(failure),
                        diagnosticTag = "download-station.$diagnosticOperation.rejected",
                    )
                }
                try {
                    // 传输层失败时无稳定 ID；回读只用于更新证据，不作成功归属。
                    strictDownloadTaskList()
                } catch (_: CancellationException) {
                    return downloadMutationResult(
                        operation,
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        diagnosticTag = "download-station.$diagnosticOperation.cancelled-during-readback",
                    )
                } catch (_: DsmFailure) {
                    // 下方仍保持已提交但未确认，交由上层专项刷新。
                }
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = downloadMutationErrorCategory(failure),
                    diagnosticTag = "download-station.$diagnosticOperation.submission-unverified",
                )
            }
            val expectedId = (submittedData.string("taskid") ?: submittedData.string("id"))
                ?.trim()
                ?.takeIf { value -> value.isNotEmpty() && value.none(Char::isISOControl) }
            if (expectedId == null) {
                try {
                    // 成功响应未返回稳定 ID 时仍只做一次严格回读，不把其他端的新任务归属给本请求。
                    strictDownloadTaskList()
                } catch (_: CancellationException) {
                    return downloadMutationResult(
                        operation,
                        MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                        submitted = true,
                        requiresRefresh = true,
                        unknown = 1,
                        diagnosticTag = "download-station.$diagnosticOperation.cancelled-during-readback",
                    )
                } catch (_: DsmFailure) {
                    // 稳定 ID 本已缺失，回读失败不改变“已提交但未确认”语义。
                }
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = MutationErrorCategory.UNKNOWN,
                    diagnosticTag = "download-station.$diagnosticOperation.missing-task-id",
                )
            }
            try {
                repeat(DOWNLOAD_MUTATION_READBACK_ATTEMPTS) { attempt ->
                    val confirmed = findCreatedDownloadTask(
                        previousIds = previousIds,
                        expectedId = expectedId,
                        expectedDestination = destination,
                    )
                    if (confirmed != null) {
                        return downloadMutationResult(
                            operation,
                            MutationResultStatus.CONFIRMED_SUCCESS,
                            submitted = true,
                            succeeded = 1,
                            diagnosticTag = "download-station.$diagnosticOperation.confirmed-success",
                        )
                    }
                    if (attempt + 1 < DOWNLOAD_MUTATION_READBACK_ATTEMPTS) {
                        delay(DOWNLOAD_MUTATION_READBACK_INTERVAL_MILLIS)
                    }
                }
            } catch (_: CancellationException) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    diagnosticTag = "download-station.$diagnosticOperation.cancelled-during-readback",
                )
            } catch (failure: DsmFailure) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = 1,
                    errorCategory = downloadMutationErrorCategory(failure),
                    diagnosticTag = "download-station.$diagnosticOperation.readback-failed",
                )
            }
            return downloadMutationResult(
                operation,
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                submitted = true,
                requiresRefresh = true,
                unknown = 1,
                errorCategory = MutationErrorCategory.UNKNOWN,
                diagnosticTag = "download-station.$diagnosticOperation.readback-mismatch",
            )
        } finally {
            creationMutationLock.withLock { activeCreationKeys.remove(key) }
        }
    }

    private suspend fun validateDownloadCreationDestination(
        operation: String,
        diagnosticOperation: String,
        destination: String,
    ): MutationResult? {
        if (!gateway.supports("SYNO.FileStation.List")) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "download-station.$diagnosticOperation.destination-check-unsupported",
            )
        }
        val item = try {
            gateway.fileInfo(destination)
        } catch (_: CancellationException) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "download-station.$diagnosticOperation.cancelled-before-submission",
            )
        } catch (failure: DsmFailure) {
            val category = downloadMutationErrorCategory(failure)
            return downloadMutationResult(
                operation,
                when (category) {
                    MutationErrorCategory.PERMISSION,
                    MutationErrorCategory.AUTHENTICATION,
                    -> MutationResultStatus.PERMISSION_DENIED
                    MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
                    else -> MutationResultStatus.CONFIRMED_FAILURE
                },
                submitted = false,
                failed = 1,
                errorCategory = category,
                diagnosticTag = "download-station.$diagnosticOperation.destination-check-failed",
            )
        }
        if (item == null || !item.isDirectory) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "download-station.$diagnosticOperation.destination-missing",
            )
        }
        if (!item.canWrite) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.PERMISSION_DENIED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.PERMISSION,
                diagnosticTag = "download-station.$diagnosticOperation.destination-read-only",
            )
        }
        return null
    }

    private suspend fun findCreatedDownloadTask(
        previousIds: Set<String>,
        expectedId: String,
        expectedDestination: String?,
    ): DownloadTask? {
        val tasks = strictDownloadTaskList()
        return tasks.firstOrNull { task ->
            task.id !in previousIds && task.id == expectedId &&
                // 某些 DSM 响应不返回 detail；若返回了目标目录，必须与请求一致。
                (expectedDestination == null || task.destination == null ||
                    task.destination.trim() == expectedDestination)
        }
    }

    /** 活动集合只保留不可逆的摘要，不留存 URI、密码或目标路径。 */
    private fun downloadCreationKey(kind: String, vararg values: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
        sequenceOf(kind, *values).forEach { value ->
            val bytes = value.encodeToByteArray()
            digest.update(
                byteArrayOf(
                    (bytes.size ushr 24).toByte(),
                    (bytes.size ushr 16).toByte(),
                    (bytes.size ushr 8).toByte(),
                    bytes.size.toByte(),
                ),
            )
            digest.update(bytes)
        }
        return digest.digest().joinToString(separator = "") { byte ->
            (byte.toInt() and 0xff).toString(16).padStart(2, '0')
        }
    }

    private fun requireConfirmedDownloadCreation(result: MutationResult) {
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            throw IllegalArgumentException("Invalid download task request")
        }
        when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> return
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> throw CancellationException("download task creation cancelled")
            else -> throw DsmFailure(
                null,
                "The NAS did not confirm the download task",
                "Refresh the task list before trying again.",
                kind = when (result.status) {
                    MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                    MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                    else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
                },
            )
        }
    }

    fun supportsSettings(): Boolean = gateway.supports("SYNO.DownloadStation.Info")

    fun supportsSchedule(): Boolean = gateway.supports("SYNO.DownloadStation.Schedule")

    fun supportsTaskDestinationEditing(): Boolean =
        gateway.supportsVersion("SYNO.DownloadStation.Task", 1) &&
            gateway.supports("SYNO.FileStation.List")

    suspend fun loadSettings(): DownloadSettings = loadSettingsStrict()

    @Suppress("DEPRECATION")
    @Deprecated("Use saveDownloadSettingsResult(original, desired) from the formal UI flow")
    suspend fun saveSettings(settings: DownloadSettings) {
        val result = saveSettingsResult(settings)
        if (result.errorCategory == MutationErrorCategory.VALIDATION) {
            throw IllegalArgumentException("Invalid download settings")
        }
        when (result.status) {
            MutationResultStatus.CONFIRMED_SUCCESS -> return
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
            MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            -> throw CancellationException("download settings save cancelled")
            else -> throw DsmFailure(
                null,
                "The NAS did not confirm all download settings",
                "Refresh the settings and review every value before saving again.",
                kind = when (result.status) {
                    MutationResultStatus.PERMISSION_DENIED -> DsmErrorKind.PERMISSION_DENIED
                    MutationResultStatus.UNSUPPORTED -> DsmErrorKind.FEATURE_UNSUPPORTED
                    else -> DsmErrorKind.CHANGE_NOT_CONFIRMED
                },
            )
        }
    }

    /**
     * 兼容旧调用方。正式界面必须保存用户看到的基线并调用双参数入口，避免用刚读取的值
     * 冒充用户确认过的基线。
     */
    @Deprecated("Use saveDownloadSettingsResult(original, desired) to preserve the visible baseline")
    suspend fun saveSettingsResult(settings: DownloadSettings): MutationResult {
        val baseline = try {
            loadSettingsStrict()
        } catch (failure: DsmFailure) {
            return downloadSettingsPreflightFailure(
                operation = "downloadSettingsSave",
                failure = failure,
                diagnosticTag = "download-station.settings.compatibility-baseline-failed",
            )
        }
        return saveSettingsResult(baseline, settings)
    }

    /**
     * 正式设置保存入口。original 必须是用户开始编辑时看到的严格基线；持锁后再次读取，
     * 基线漂移时零写入关闭。基础设置和计划设置只提交实际变化的组件，任何模糊结果只回读、
     * 不自动重放。
     */
    suspend fun saveSettingsResult(
        original: DownloadSettings,
        desired: DownloadSettings,
    ): MutationResult {
        val operation = "downloadSettingsSave"
        val normalizedOriginal = normalizeDownloadSettingsInput(original)
        val normalizedDesired = normalizeDownloadSettingsInput(desired)
        val limits = listOf(
            normalizedDesired.btDownloadLimitKb,
            normalizedDesired.btUploadLimitKb,
            normalizedDesired.httpDownloadLimitKb,
            normalizedDesired.ftpDownloadLimitKb,
            normalizedDesired.nzbDownloadLimitKb,
            normalizedDesired.emuleDownloadLimitKb,
            normalizedDesired.emuleUploadLimitKb,
        )
        if (limits.any { it !in 0..MAX_DOWNLOAD_LIMIT_KB }) {
            return downloadSettingsMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "download-station.settings.invalid-limit",
            )
        }
        val destination = normalizedDesired.defaultDestination
        if (destination.isBlank() || destination.split('/').any { it.isBlank() || it == "." || it == ".." }) {
            return downloadSettingsMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "download-station.settings.invalid-destination",
            )
        }
        if (!supportsSettings()) {
            return downloadSettingsMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "download-station.settings.unsupported",
            )
        }
        if ((normalizedDesired.scheduleEnabled || normalizedDesired.emuleScheduleEnabled) &&
            !supportsSchedule()
        ) {
            return downloadSettingsMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "download-station.settings.schedule-unsupported",
            )
        }
        val changedComponents = downloadSettingsChangedComponents(
            normalizedOriginal,
            normalizedDesired,
        )
        if (changedComponents.isEmpty()) {
            return downloadSettingsMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "download-station.settings.no-changes",
            )
        }
        if (!currentCoroutineContext().isActive) {
            return downloadSettingsMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "download-station.settings.cancelled-before-submission",
            )
        }
        val componentCount = changedComponents.size
        val claimed = settingsMutationLock.withLock {
            if (isSettingsMutationActive()) false else {
                setSettingsMutationActive(true)
                true
            }
        }
        if (!claimed) {
            return downloadSettingsMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = componentCount,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "download-station.settings.duplicate-submission",
            )
        }
        try {
            val current = try {
                currentCoroutineContext().ensureActive()
                loadSettingsStrict()
            } catch (_: CancellationException) {
                return downloadSettingsMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "download-station.settings.cancelled-before-submission",
                )
            } catch (failure: DsmFailure) {
                return downloadSettingsPreflightFailure(
                    operation,
                    failure,
                    "download-station.settings.preflight-failed",
                )
            }
            if (current != normalizedOriginal) {
                return downloadSettingsMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = componentCount,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "download-station.settings.baseline-drifted",
                )
            }

            val attempted = linkedSetOf<DownloadSettingsComponent>()
            val completed = linkedSetOf<DownloadSettingsComponent>()
            var submissionFailure: Throwable? = null
            for (component in changedComponents) {
                try {
                    currentCoroutineContext().ensureActive()
                    attempted += component
                    submitDownloadSettingsComponent(component, normalizedDesired)
                    completed += component
                } catch (failure: Throwable) {
                    submissionFailure = failure
                    break
                }
            }
            if (attempted.isEmpty()) {
                return downloadSettingsMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "download-station.settings.cancelled-before-submission",
                )
            }
            return withContext(NonCancellable) {
                evaluateDownloadSettingsMutation(
                    operation = operation,
                    desired = normalizedDesired,
                    changed = changedComponents,
                    attempted = attempted,
                    completed = completed,
                    submissionFailure = submissionFailure,
                )
            }
        } finally {
            settingsMutationLock.withLock { setSettingsMutationActive(false) }
        }
    }

    private suspend fun loadSettingsStrict(): DownloadSettings {
        val basic = loadBasicSettingsStrict()
        if (!supportsSchedule()) return basic
        val (scheduleEnabled, emuleScheduleEnabled) = loadScheduleStrict()
        return basic.copy(
            scheduleEnabled = scheduleEnabled,
            emuleScheduleEnabled = emuleScheduleEnabled,
        )
    }

    private suspend fun loadBasicSettingsStrict(): DownloadSettings {
        val config = gateway.call("SYNO.DownloadStation.Info", "getconfig")
        val destination = config["default_destination"].strictStringValue()
            ?.trim()?.trim('/')
            ?.takeIf { value ->
                value.isNotBlank() && value.split('/').none { it.isBlank() || it == "." || it == ".." }
            }
            ?: throw invalidDownloadSettingsResponse("basic-destination")
        fun requiredBoolean(name: String): Boolean =
            config[name].strictBooleanValue(allowString = true)
                ?: throw invalidDownloadSettingsResponse("basic-$name")
        fun requiredLimit(name: String): Int =
            config[name].strictIntValue(allowString = true)
                ?.takeIf { it in 0..MAX_DOWNLOAD_LIMIT_KB }
                ?: throw invalidDownloadSettingsResponse("basic-$name")
        val httpLimit = requiredLimit("http_max_download")
        val ftpLimit = requiredLimit("ftp_max_download")
        if (httpLimit != ftpLimit) throw invalidDownloadSettingsResponse("basic-web-ftp-limit")
        return DownloadSettings(
            defaultDestination = destination,
            emuleEnabled = requiredBoolean("emule_enabled"),
            autoExtractEnabled = requiredBoolean("unzip_service_enabled"),
            btDownloadLimitKb = requiredLimit("bt_max_download"),
            btUploadLimitKb = requiredLimit("bt_max_upload"),
            httpDownloadLimitKb = httpLimit,
            ftpDownloadLimitKb = httpLimit,
            nzbDownloadLimitKb = requiredLimit("nzb_max_download"),
            emuleDownloadLimitKb = requiredLimit("emule_max_download"),
            emuleUploadLimitKb = requiredLimit("emule_max_upload"),
        )
    }

    private suspend fun loadScheduleStrict(): Pair<Boolean, Boolean> {
        val schedule = gateway.call("SYNO.DownloadStation.Schedule", "getconfig")
        val enabled = schedule["enabled"].strictBooleanValue(allowString = true)
            ?: throw invalidDownloadSettingsResponse("schedule-enabled")
        val emuleEnabled = schedule["emule_enabled"].strictBooleanValue(allowString = true)
            ?: throw invalidDownloadSettingsResponse("schedule-emule-enabled")
        return enabled to emuleEnabled
    }

    private fun normalizeDownloadSettingsInput(value: DownloadSettings): DownloadSettings {
        val sharedWebFtpLimit = value.httpDownloadLimitKb
        return value.copy(
            defaultDestination = value.defaultDestination.trim().trim('/'),
            httpDownloadLimitKb = sharedWebFtpLimit,
            ftpDownloadLimitKb = sharedWebFtpLimit,
        )
    }

    private fun downloadSettingsChangedComponents(
        original: DownloadSettings,
        desired: DownloadSettings,
    ): List<DownloadSettingsComponent> = buildList {
        if (!downloadBasicSettingsMatch(original, desired)) add(DownloadSettingsComponent.BASIC)
        if (supportsSchedule() && !downloadScheduleSettingsMatch(original, desired)) {
            add(DownloadSettingsComponent.SCHEDULE)
        }
    }

    private fun downloadBasicSettingsMatch(first: DownloadSettings, second: DownloadSettings): Boolean =
        first.copy(scheduleEnabled = false, emuleScheduleEnabled = false) ==
            second.copy(scheduleEnabled = false, emuleScheduleEnabled = false)

    private fun downloadScheduleSettingsMatch(first: DownloadSettings, second: DownloadSettings): Boolean =
        first.scheduleEnabled == second.scheduleEnabled &&
            first.emuleScheduleEnabled == second.emuleScheduleEnabled

    private suspend fun submitDownloadSettingsComponent(
        component: DownloadSettingsComponent,
        desired: DownloadSettings,
    ) = when (component) {
        DownloadSettingsComponent.BASIC -> gateway.call(
            "SYNO.DownloadStation.Info",
            "setserverconfig",
            mapOf(
                "default_destination" to desired.defaultDestination,
                "emule_enabled" to desired.emuleEnabled.toString(),
                "unzip_service_enabled" to desired.autoExtractEnabled.toString(),
                "bt_max_download" to desired.btDownloadLimitKb.toString(),
                "bt_max_upload" to desired.btUploadLimitKb.toString(),
                "http_max_download" to desired.httpDownloadLimitKb.toString(),
                "ftp_max_download" to desired.httpDownloadLimitKb.toString(),
                "nzb_max_download" to desired.nzbDownloadLimitKb.toString(),
                "emule_max_download" to desired.emuleDownloadLimitKb.toString(),
                "emule_max_upload" to desired.emuleUploadLimitKb.toString(),
            ),
        )
        DownloadSettingsComponent.SCHEDULE -> gateway.call(
            "SYNO.DownloadStation.Schedule",
            "setconfig",
            mapOf(
                "enabled" to desired.scheduleEnabled.toString(),
                "emule_enabled" to desired.emuleScheduleEnabled.toString(),
            ),
        )
    }

    private suspend fun evaluateDownloadSettingsMutation(
        operation: String,
        desired: DownloadSettings,
        changed: List<DownloadSettingsComponent>,
        attempted: Set<DownloadSettingsComponent>,
        completed: Set<DownloadSettingsComponent>,
        submissionFailure: Throwable?,
    ): MutationResult {
        var succeeded = 0
        var unknown = 0
        for (component in changed) {
            if (component !in attempted) {
                continue
            }
            val observation = runCatching {
                when (component) {
                    DownloadSettingsComponent.BASIC ->
                        downloadBasicSettingsMatch(loadBasicSettingsStrict(), desired)
                    DownloadSettingsComponent.SCHEDULE -> {
                        val (enabled, emuleEnabled) = loadScheduleStrict()
                        enabled == desired.scheduleEnabled && emuleEnabled == desired.emuleScheduleEnabled
                    }
                }
            }
            when {
                observation.getOrNull() == true -> succeeded += 1
                observation.isFailure -> unknown += 1
                component in completed -> Unit
                submissionFailure is CancellationException ||
                    submissionFailure !is DsmFailure ||
                    submissionFailure.kind in setOf(
                        DsmErrorKind.CONNECTION_FAILED,
                        DsmErrorKind.INVALID_RESPONSE,
                        DsmErrorKind.UNKNOWN,
                    ) -> unknown += 1
                else -> Unit
            }
        }
        val dsmFailure = submissionFailure as? DsmFailure
        val category = dsmFailure?.let(::downloadMutationErrorCategory)
        val status = when {
            succeeded == changed.size -> MutationResultStatus.CONFIRMED_SUCCESS
            succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
            submissionFailure is CancellationException ->
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
            unknown > 0 -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            dsmFailure?.kind in setOf(
                DsmErrorKind.PERMISSION_DENIED,
                DsmErrorKind.SESSION_EXPIRED,
                DsmErrorKind.AUTHENTICATION_FAILED,
            ) -> MutationResultStatus.PERMISSION_DENIED
            dsmFailure?.kind in setOf(
                DsmErrorKind.FEATURE_UNSUPPORTED,
                DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED,
            ) -> MutationResultStatus.UNSUPPORTED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        val finalUnknown = if (
            status == MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION && unknown == 0
        ) attempted.size.coerceAtLeast(1) else unknown
        val finalFailed = (changed.size - succeeded - finalUnknown).coerceAtLeast(0)
        return downloadSettingsMutationResult(
            operation = operation,
            status = status,
            submitted = true,
            requiresRefresh = status in setOf(
                MutationResultStatus.PARTIAL_SUCCESS,
                MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION,
            ),
            succeeded = succeeded,
            failed = finalFailed,
            unknown = finalUnknown,
            errorCategory = when {
                status == MutationResultStatus.CONFIRMED_SUCCESS -> null
                category != null -> category
                unknown > 0 -> MutationErrorCategory.NETWORK
                else -> MutationErrorCategory.CONFLICT
            },
            diagnosticTag = "download-station.settings.${status.name.lowercase().replace('_', '-')}",
        )
    }

    private fun downloadSettingsPreflightFailure(
        operation: String,
        failure: DsmFailure,
        diagnosticTag: String,
    ): MutationResult {
        val category = downloadMutationErrorCategory(failure)
        val status = when (category) {
            MutationErrorCategory.PERMISSION,
            MutationErrorCategory.AUTHENTICATION,
            -> MutationResultStatus.PERMISSION_DENIED
            MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return downloadSettingsMutationResult(
            operation,
            status,
            submitted = false,
            failed = 1,
            errorCategory = category,
            diagnosticTag = diagnosticTag,
        )
    }

    private fun invalidDownloadSettingsResponse(scope: String) = DsmFailure(
        null,
        "Download settings response is invalid",
        "Refresh Download Station settings before trying again.",
        kind = DsmErrorKind.INVALID_RESPONSE,
    )

    private fun downloadSettingsMutationResult(
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
        localizationKey = "mutation.download_settings.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

    private enum class DownloadSettingsComponent { BASIC, SCHEDULE }

    /**
     * 正式任务控制入口。调用方必须传入用户看到并确认的稳定基线；Repository 在持锁后再次
     * 严格读取并逐项比对，任何身份或稳定字段漂移都在写请求前失败关闭。
     */
    suspend fun controlTasksResult(
        baseline: List<DownloadTaskMutationBaseline>,
        action: DownloadTaskMutationAction,
    ): MutationResult {
        val operation = action.downloadOperation
        val sortedBaseline = baseline.sortedBy(DownloadTaskMutationBaseline::id)
        val ids = sortedBaseline.map(DownloadTaskMutationBaseline::id)
        if (!currentCoroutineContext().isActive) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "download-station.${action.diagnosticName}.cancelled-before-submission",
            )
        }
        if (
            ids.isEmpty() || ids.any { it.isBlank() || it != it.trim() } ||
            ids.toSet().size != ids.size
        ) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = action.effectCount(ids.size),
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "download-station.${action.diagnosticName}.invalid-baseline",
            )
        }
        val apiName = gateway.preferredOrNull("SYNO.DownloadStation.Task", "SYNO.DownloadStation2.Task")
            ?: return downloadMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = action.effectCount(ids.size),
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "download-station.${action.diagnosticName}.unsupported",
            )
        val claimed = try {
            mutationLock.withLock {
                if (ids.any(activeMutationIds::contains)) {
                    false
                } else {
                    activeMutationIds += ids
                    true
                }
            }
        } catch (_: CancellationException) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "download-station.${action.diagnosticName}.cancelled-before-lock",
            )
        }
        if (!claimed) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = action.effectCount(ids.size),
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "download-station.${action.diagnosticName}.duplicate-submission",
            )
        }
        try {
            val current = try {
                strictDownloadTaskList()
            } catch (_: CancellationException) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "download-station.${action.diagnosticName}.cancelled-during-preflight",
                )
            } catch (failure: DsmFailure) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = action.effectCount(ids.size),
                    errorCategory = downloadMutationErrorCategory(failure),
                    diagnosticTag = "download-station.${action.diagnosticName}.preflight-failed",
                )
            }
            val currentById = current.associateBy(DownloadTask::id)
            val baselineMatches = sortedBaseline.all { expected ->
                currentById[expected.id]?.let(DownloadTaskMutationBaseline::from) == expected
            }
            val actionAllowed = sortedBaseline.all { expected ->
                action.accepts(expected.status)
            }
            if (!baselineMatches || !actionAllowed) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = action.effectCount(ids.size),
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "download-station.${action.diagnosticName}.baseline-changed",
                )
            }

            try {
                currentCoroutineContext().ensureActive()
            } catch (_: CancellationException) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "download-station.${action.diagnosticName}.cancelled-before-write",
                )
            }

            var submissionFailure: DsmFailure? = null
            var cancellationRequested = false
            try {
                gateway.call(
                    apiName,
                    action.apiMethod,
                    buildMap {
                        put("id", ids.joinToString(","))
                        action.forceComplete?.let { put("force_complete", it.toString()) }
                    },
                    version = if (apiName == "SYNO.DownloadStation.Task") 1 else null,
                )
            } catch (_: CancellationException) {
                cancellationRequested = true
            } catch (failure: DsmFailure) {
                submissionFailure = failure
            }

            var readback: List<DownloadTask>? = null
            var readbackFailure: DsmFailure? = null
            try {
                val mustFinishReadback = cancellationRequested || submissionFailure != null
                readback = if (mustFinishReadback) {
                    withContext(NonCancellable) {
                        readbackDownloadMutation(ids, action)
                    }
                } else {
                    readbackDownloadMutation(ids, action)
                }
            } catch (_: CancellationException) {
                cancellationRequested = true
                try {
                    readback = withContext(NonCancellable) {
                        readbackDownloadMutation(ids, action)
                    }
                } catch (failure: DsmFailure) {
                    readbackFailure = failure
                }
            } catch (failure: DsmFailure) {
                readbackFailure = failure
            }
            if (readback == null) {
                val status = if (cancellationRequested) {
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                } else {
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                }
                return downloadMutationResult(
                    operation,
                    status,
                    submitted = true,
                    requiresRefresh = true,
                    unknown = action.effectCount(ids.size),
                    errorCategory = (submissionFailure ?: readbackFailure)
                        ?.let(::downloadMutationErrorCategory),
                    diagnosticTag = "download-station.${action.diagnosticName}.readback-failed",
                )
            }

            return downloadMutationReadbackResult(
                baseline = sortedBaseline,
                action = action,
                readback = checkNotNull(readback),
                submissionFailure = submissionFailure,
                cancellationRequested = cancellationRequested,
            )
        } finally {
            withContext(NonCancellable) {
                mutationLock.withLock { activeMutationIds.removeAll(ids.toSet()) }
            }
        }
    }

    /**
     * 使用官方 Task.edit v1 修改单个任务的保存位置。目标目录和任务都在同一进程锁内
     * 重新读取完整基线；提交取消或传输失败后只回读，不自动重放写请求。
     */
    suspend fun editDestinationResult(
        baseline: DownloadTaskMutationBaseline,
        destination: FileItem,
    ): MutationResult {
        val operation = "downloadEditDestination"
        val taskId = baseline.id
        val destinationPath = destination.path.trim()
        if (!currentCoroutineContext().isActive) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "download-station.edit-destination.cancelled-before-submission",
            )
        }
        if (taskId.isBlank() || taskId != taskId.trim() || destinationPath.isBlank() ||
            destinationPath != destination.path || !destination.isDirectory || !destination.canWrite ||
            baseline.destination?.trim() == destinationPath
        ) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.VALIDATION,
                diagnosticTag = "download-station.edit-destination.invalid-input",
            )
        }
        if (!supportsTaskDestinationEditing()) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "download-station.edit-destination.unsupported",
            )
        }
        val claimed = try {
            mutationLock.withLock {
                if (taskId in activeMutationIds) false else {
                    activeMutationIds += taskId
                    true
                }
            }
        } catch (_: CancellationException) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "download-station.edit-destination.cancelled-before-lock",
            )
        }
        if (!claimed) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CONFIRMED_FAILURE,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.CONFLICT,
                diagnosticTag = "download-station.edit-destination.duplicate-submission",
            )
        }
        try {
            val currentDestination: FileItem
            val currentTask: DownloadTask
            try {
                currentDestination = gateway.fileInfo(destinationPath)
                    ?: return downloadMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "download-station.edit-destination.destination-missing",
                    )
                currentTask = strictDownloadTaskList().singleOrNull { it.id == taskId }
                    ?: return downloadMutationResult(
                        operation,
                        MutationResultStatus.CONFIRMED_FAILURE,
                        submitted = false,
                        failed = 1,
                        errorCategory = MutationErrorCategory.CONFLICT,
                        diagnosticTag = "download-station.edit-destination.task-missing",
                    )
            } catch (_: CancellationException) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "download-station.edit-destination.cancelled-during-preflight",
                )
            } catch (failure: DsmFailure) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = downloadMutationErrorCategory(failure),
                    diagnosticTag = "download-station.edit-destination.preflight-failed",
                )
            }
            if (!currentDestination.matchesMutationBaseline(destination) ||
                DownloadTaskMutationBaseline.from(currentTask) != baseline
            ) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_FAILURE,
                    submitted = false,
                    failed = 1,
                    errorCategory = MutationErrorCategory.CONFLICT,
                    diagnosticTag = "download-station.edit-destination.baseline-changed",
                )
            }
            try {
                currentCoroutineContext().ensureActive()
            } catch (_: CancellationException) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                    submitted = false,
                    diagnosticTag = "download-station.edit-destination.cancelled-before-write",
                )
            }

            var submissionFailure: DsmFailure? = null
            var cancellationRequested = false
            try {
                gateway.call(
                    "SYNO.DownloadStation.Task",
                    "edit",
                    mapOf("id" to taskId, "destination" to destinationPath),
                    version = 1,
                )
            } catch (_: CancellationException) {
                cancellationRequested = true
            } catch (failure: DsmFailure) {
                submissionFailure = failure
            }

            var readback: DownloadTask? = null
            var readbackFailed = false
            try {
                readback = if (cancellationRequested || submissionFailure != null) {
                    withContext(NonCancellable) {
                        readbackDownloadDestination(taskId, destinationPath)
                    }
                } else {
                    readbackDownloadDestination(taskId, destinationPath)
                }
            } catch (_: CancellationException) {
                cancellationRequested = true
                readback = withContext(NonCancellable) {
                    runCatching { readbackDownloadDestination(taskId, destinationPath) }.getOrNull()
                }
                readbackFailed = readback == null
            } catch (_: DsmFailure) {
                readbackFailed = true
            }
            if (readback?.destination?.trim() == destinationPath) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "download-station.edit-destination.confirmed-success",
                )
            }
            val unchanged = readback?.let(DownloadTaskMutationBaseline::from) == baseline
            val failureCategory = submissionFailure?.let(::downloadMutationErrorCategory)
            val explicitRejection = submissionFailure != null &&
                submissionFailure.kind !in setOf(
                    DsmErrorKind.CONNECTION_FAILED,
                    DsmErrorKind.INVALID_RESPONSE,
                    DsmErrorKind.UNKNOWN,
                )
            if (unchanged && explicitRejection && !cancellationRequested) {
                val status = when (failureCategory) {
                    MutationErrorCategory.PERMISSION,
                    MutationErrorCategory.AUTHENTICATION,
                    -> MutationResultStatus.PERMISSION_DENIED
                    MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
                    else -> MutationResultStatus.CONFIRMED_FAILURE
                }
                return downloadMutationResult(
                    operation,
                    status,
                    submitted = true,
                    failed = 1,
                    errorCategory = failureCategory,
                    diagnosticTag = "download-station.edit-destination.confirmed-rejection",
                )
            }
            return downloadMutationResult(
                operation,
                if (cancellationRequested) {
                    MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                } else {
                    MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                },
                submitted = true,
                requiresRefresh = true,
                unknown = 1,
                errorCategory = failureCategory,
                diagnosticTag = if (readbackFailed) {
                    "download-station.edit-destination.readback-failed"
                } else {
                    "download-station.edit-destination.readback-mismatch"
                },
            )
        } finally {
            withContext(NonCancellable) {
                mutationLock.withLock { activeMutationIds.remove(taskId) }
            }
        }
    }

    private suspend fun readbackDownloadDestination(
        taskId: String,
        destination: String,
    ): DownloadTask? {
        var task: DownloadTask? = null
        for (attempt in 0 until DOWNLOAD_MUTATION_READBACK_ATTEMPTS) {
            task = strictDownloadTaskList().singleOrNull { it.id == taskId }
            if (task?.destination?.trim() == destination) break
            if (attempt + 1 < DOWNLOAD_MUTATION_READBACK_ATTEMPTS) {
                delay(DOWNLOAD_MUTATION_READBACK_INTERVAL_MILLIS)
            }
        }
        return task
    }

    private suspend fun readbackDownloadMutation(
        ids: List<String>,
        action: DownloadTaskMutationAction,
    ): List<DownloadTask> {
        var latest = emptyList<DownloadTask>()
        for (attempt in 0 until DOWNLOAD_MUTATION_READBACK_ATTEMPTS) {
            latest = strictDownloadTaskList()
            val byId = latest.associateBy(DownloadTask::id)
            if (ids.all { id -> action.isConfirmed(byId[id]) }) break
            if (attempt + 1 < DOWNLOAD_MUTATION_READBACK_ATTEMPTS) {
                delay(DOWNLOAD_MUTATION_READBACK_INTERVAL_MILLIS)
            }
        }
        return latest
    }

    private fun downloadMutationReadbackResult(
        baseline: List<DownloadTaskMutationBaseline>,
        action: DownloadTaskMutationAction,
        readback: List<DownloadTask>,
        submissionFailure: DsmFailure?,
        cancellationRequested: Boolean,
    ): MutationResult {
        val byId = readback.associateBy(DownloadTask::id)
        val confirmed = baseline.count { expected -> action.isConfirmed(byId[expected.id]) }
        val unchanged = baseline.all { expected ->
            byId[expected.id]?.let(DownloadTaskMutationBaseline::from) == expected
        }
        val explicitFailure = submissionFailure?.kind !in setOf(
            null,
            DsmErrorKind.CONNECTION_FAILED,
            DsmErrorKind.INVALID_RESPONSE,
            DsmErrorKind.UNKNOWN,
        )
        if (confirmed == 0 && unchanged && explicitFailure && !cancellationRequested) {
            val errorCategory = checkNotNull(submissionFailure).let(::downloadMutationErrorCategory)
            val status = when (errorCategory) {
                MutationErrorCategory.PERMISSION,
                MutationErrorCategory.AUTHENTICATION,
                -> MutationResultStatus.PERMISSION_DENIED
                MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
                else -> MutationResultStatus.CONFIRMED_FAILURE
            }
            return downloadMutationResult(
                action.downloadOperation,
                status,
                submitted = true,
                failed = action.effectCount(baseline.size),
                errorCategory = errorCategory,
                diagnosticTag = "download-station.${action.diagnosticName}.confirmed-rejection",
            )
        }

        val succeeded: Int
        val unknown: Int
        if (action == DownloadTaskMutationAction.REMOVE_TASK_AND_FILES) {
            // 每个任务包含“移除任务”和“删除文件”两个效果；公开接口只能回读前者。
            succeeded = confirmed
            unknown = baseline.size + (baseline.size - confirmed)
        } else {
            succeeded = confirmed
            unknown = baseline.size - confirmed
        }
        val status = when {
            unknown == 0 -> MutationResultStatus.CONFIRMED_SUCCESS
            succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
            cancellationRequested -> MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
            else -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
        }
        return downloadMutationResult(
            action.downloadOperation,
            status,
            submitted = true,
            requiresRefresh = unknown > 0,
            succeeded = succeeded,
            unknown = unknown,
            errorCategory = submissionFailure?.let(::downloadMutationErrorCategory),
            diagnosticTag = "download-station.${action.diagnosticName}.${status.name.lowercase().replace('_', '-')}",
        )
    }

    private val DownloadTaskMutationAction.apiMethod: String
        get() = when (this) {
            DownloadTaskMutationAction.PAUSE -> "pause"
            DownloadTaskMutationAction.RESUME -> "resume"
            DownloadTaskMutationAction.REMOVE_TASK,
            DownloadTaskMutationAction.REMOVE_TASK_AND_FILES,
            -> "delete"
        }

    private val DownloadTaskMutationAction.downloadOperation: String
        get() = when (this) {
            DownloadTaskMutationAction.PAUSE -> "downloadPause"
            DownloadTaskMutationAction.RESUME -> "downloadResume"
            DownloadTaskMutationAction.REMOVE_TASK -> "downloadDelete"
            DownloadTaskMutationAction.REMOVE_TASK_AND_FILES -> "downloadDeleteFiles"
        }

    private val DownloadTaskMutationAction.diagnosticName: String
        get() = when (this) {
            DownloadTaskMutationAction.PAUSE -> "pause"
            DownloadTaskMutationAction.RESUME -> "resume"
            DownloadTaskMutationAction.REMOVE_TASK -> "delete"
            DownloadTaskMutationAction.REMOVE_TASK_AND_FILES -> "delete-files"
        }

    private val DownloadTaskMutationAction.forceComplete: Boolean?
        get() = when (this) {
            DownloadTaskMutationAction.REMOVE_TASK -> false
            DownloadTaskMutationAction.REMOVE_TASK_AND_FILES -> true
            else -> null
        }

    private fun DownloadTaskMutationAction.effectCount(taskCount: Int): Int =
        if (this == DownloadTaskMutationAction.REMOVE_TASK_AND_FILES) taskCount * 2 else taskCount

    private fun DownloadTaskMutationAction.accepts(status: ResourceState): Boolean = when (this) {
        DownloadTaskMutationAction.PAUSE -> status in setOf(ResourceState.RUNNING, ResourceState.WAITING)
        DownloadTaskMutationAction.RESUME -> status == ResourceState.PAUSED
        DownloadTaskMutationAction.REMOVE_TASK,
        DownloadTaskMutationAction.REMOVE_TASK_AND_FILES,
        -> true
    }

    private fun DownloadTaskMutationAction.isConfirmed(task: DownloadTask?): Boolean = when (this) {
        DownloadTaskMutationAction.PAUSE -> task?.status == ResourceState.PAUSED
        DownloadTaskMutationAction.RESUME -> task?.status in setOf(ResourceState.RUNNING, ResourceState.WAITING)
        DownloadTaskMutationAction.REMOVE_TASK,
        DownloadTaskMutationAction.REMOVE_TASK_AND_FILES,
        -> task == null
    }

    private fun downloadMutationErrorCategory(failure: DsmFailure): MutationErrorCategory =
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

    private fun downloadMutationResult(
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
        localizationKey = "mutation.download_task.${status.name.lowercase()}",
        diagnosticTag = diagnosticTag,
    )

}

internal interface DownloadStationRepositoryGateway {
    fun supports(apiName: String): Boolean
    fun supportsVersion(apiName: String, version: Int): Boolean
    fun preferredOrNull(vararg names: String): String?
    fun capability(apiName: String): ApiCapability?
    suspend fun call(
        apiName: String,
        method: String,
        parameters: Map<String, String> = emptyMap(),
        version: Int? = null,
    ): JsonObject
    suspend fun fileInfo(path: String): FileItem?
    suspend fun uploadDownloadTaskFile(
        capability: ApiCapability,
        filename: String,
        contentType: String?,
        contentLength: Long,
        destination: String?,
        unzipPassword: String?,
        openInputStream: () -> InputStream,
    ): JsonObject
    fun preferred(vararg names: String): String = preferredOrNull(*names)
        ?: throw DsmFailure(
            102,
            "Feature unsupported",
            "Update DSM or the related package.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED,
        )
}

private fun FileItem.matchesMutationBaseline(baseline: FileItem): Boolean =
    path == baseline.path && name == baseline.name && isDirectory == baseline.isDirectory &&
        owner == baseline.owner && canRead == baseline.canRead && canWrite == baseline.canWrite &&
        canDelete == baseline.canDelete && mountPointType == baseline.mountPointType && (isDirectory ||
        size == baseline.size && modifiedAtEpochSeconds == baseline.modifiedAtEpochSeconds)

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
    else -> MutationErrorCategory.SERVER
}

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

private fun JsonObject.elements(key: String): List<JsonElement> =
    (this[key] as? JsonArray)?.toList().orEmpty()

private fun JsonElement?.strictStringValue(): String? =
    (this as? JsonPrimitive)?.contentOrNull?.takeIf(String::isNotBlank)

private fun JsonElement?.strictBooleanValue(allowString: Boolean = false): Boolean? {
    val primitive = this as? JsonPrimitive ?: return null
    primitive.booleanOrNull?.let { return it }
    if (!allowString) return null
    return when (primitive.contentOrNull?.lowercase()) {
        "1", "true", "yes", "on" -> true
        "0", "false", "no", "off" -> false
        else -> null
    }
}

private fun JsonElement?.strictIntValue(allowString: Boolean = false): Int? {
    val primitive = this as? JsonPrimitive ?: return null
    val content = primitive.contentOrNull ?: return null
    return if (allowString) content.toIntOrNull() else primitive.contentOrNull?.toIntOrNull()
}

private fun JsonObject.firstNonBlank(vararg keys: String): String? =
    keys.firstNotNullOfOrNull { key -> string(key)?.trim()?.takeIf(String::isNotBlank) }

private const val MAX_DOWNLOAD_URI_CHARACTERS = 8_192
private const val MAX_DOWNLOAD_DESTINATION_CHARACTERS = 2_048
private const val MAX_DOWNLOAD_TASK_FILE_BYTES = 100L * 1024L * 1024L
private const val MAX_DOWNLOAD_LIMIT_KB = 1_000_000
private const val MAX_DOWNLOAD_BT_SEARCH_POLLS = 60
private const val DOWNLOAD_BT_SEARCH_POLL_INTERVAL_MILLIS = 500L
private const val DOWNLOAD_MUTATION_READBACK_ATTEMPTS = 8
private const val DOWNLOAD_MUTATION_READBACK_INTERVAL_MILLIS = 500L
private const val DOWNLOAD_MUTATION_LIST_PAGE_SIZE = 1000
