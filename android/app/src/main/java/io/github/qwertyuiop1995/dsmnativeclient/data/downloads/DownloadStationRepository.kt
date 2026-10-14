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
import io.github.qwertyuiop1995.dsmnativeclient.domain.DownloadSettingsPartition
import io.github.qwertyuiop1995.dsmnativeclient.domain.DOWNLOAD_BASIC_SETTING_FIELDS
import io.github.qwertyuiop1995.dsmnativeclient.domain.DOWNLOAD_SCHEDULE_SETTING_FIELDS
import io.github.qwertyuiop1995.dsmnativeclient.domain.downloadSettingsParameters
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
import java.security.MessageDigest
import kotlinx.coroutines.Dispatchers
import java.net.URI
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

    suspend fun listDownloads(): List<DownloadTask> = if (gateway.supportsVersion("SYNO.DownloadStation.Task", 1)) {
        strictDownloadTaskList()
    } else {
        // 内部备用仅有摘要契约，不能作为不存在或写后完成的证据。
        downloadTaskList(strict = false)
    }

    suspend fun taskDetails(id: String): DownloadTask {
        require(validTaskId(id))
        val data = gateway.call("SYNO.DownloadStation.Task", "getinfo",
            mapOf("id" to id, "additional" to "detail,transfer,file,tracker,peer"), version = 1)
        val values = data["tasks"] as? JsonArray ?: throw invalidDownloadTaskList()
        if (values.size != 1) throw invalidDownloadTaskList()
        return downloadTask(values.single() as? JsonObject ?: throw invalidDownloadTaskList(), true)
            ?.takeIf { it.id == id } ?: throw invalidDownloadTaskList()
    }

    /** 对象外链按完整稳定列表重新确认任务，避免把后续分页中的现存任务误判为已删除。 */
    suspend fun downloadTask(taskId: String): DownloadTask? {
        require(taskId.isNotBlank()) { "Download task ID is required" }
        return strictDownloadTaskList().firstOrNull { it.id == taskId }
    }

    /** 公开完整目录：总量必须稳定，无总量以短页结束；中途错误不返回残缺列表。 */
    private suspend fun strictDownloadTaskList(): List<DownloadTask> {
        if (!gateway.supportsVersion("SYNO.DownloadStation.Task", 1)) throw DsmFailure(
            null, "The complete task list is unavailable", "Open Download Station in DSM.",
            kind = DsmErrorKind.FEATURE_UNSUPPORTED)
        val accumulated = mutableListOf<DownloadTask>()
        val seenIds = mutableSetOf<String>()
        var expectedTotal: Int? = null
        var first = true
        while (true) {
            val page = downloadTaskPage(true, accumulated.size, DOWNLOAD_MUTATION_LIST_PAGE_SIZE)
            if (first) { expectedTotal = page.total; first = false }
            else if (page.total != expectedTotal) throw invalidDownloadTaskList()
            if (page.tasks.size > DOWNLOAD_MUTATION_LIST_PAGE_SIZE || page.tasks.any { !seenIds.add(it.id) }) {
                throw invalidDownloadTaskList()
            }
            accumulated += page.tasks
            val total = expectedTotal
            if (total != null) {
                if (accumulated.size > total) throw invalidDownloadTaskList()
                if (accumulated.size == total) return accumulated
                if (page.tasks.isEmpty()) throw invalidDownloadTaskList()
            } else if (page.tasks.size < DOWNLOAD_MUTATION_LIST_PAGE_SIZE) return accumulated
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
                "additional" to "detail,transfer",
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
        val total = totalElement.strictIntValue()?.takeIf { it >= 0 }
        if (strict && totalElement != null && total == null) throw invalidDownloadTaskList()
        if (strict && "offset" in data && data["offset"].strictIntValue() != offset) throw invalidDownloadTaskList()
        return DownloadTaskPage(tasks, total)
    }

    private fun downloadTask(item: JsonObject, strict: Boolean): DownloadTask? {
        val id = item["id"].strictStringValue()
        if (id == null || !validTaskId(id)) {
            if (strict) throw invalidDownloadTaskList()
            return null
        }
        if (strict && (item["title"].strictStringValue().isNullOrBlank() ||
            item["status"].strictStringValue().isNullOrBlank())) throw invalidDownloadTaskList()
        val additional = item.objectValue("additional")
        val transfer = additional?.objectValue("transfer")
        val detail = additional?.objectValue("detail")
        val statusExtra = item.objectValue("status_extra")
        return DownloadTask(
            id = id,
            type = item.string("type"),
            title = item.string("title").orEmpty(),
            status = state(item.string("status")),
            isCompleted = item.string("status") == "finished",
            size = item.long("size")?.takeIf { it >= 0 },
            transferred = item.long("size_downloaded")?.takeIf { it >= 0 } ?: transfer?.long("size_downloaded")?.takeIf { it >= 0 },
            downloadSpeed = transfer?.long("speed_download")?.takeIf { it >= 0 },
            uploadSpeed = transfer?.long("speed_upload")?.takeIf { it >= 0 },
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
                    size = file.long("size")?.takeIf { it >= 0 },
                    downloaded = file.long("size_downloaded")?.takeIf { it >= 0 },
                    priority = file.string("priority")?.trim(),
                )
            },
            trackers = additional?.elements("tracker").orEmpty().mapNotNull { value ->
                val tracker = value as? JsonObject ?: return@mapNotNull null
                DownloadTaskTracker(
                    url = tracker["url"].strictStringValue()?.let { value -> runCatching {
                        val uri = URI(value)
                        if (uri.host == null || uri.scheme == null) null else URI(uri.scheme, null, uri.host, uri.port, null, null, null).toString()
                    }.getOrNull() } ?: return@mapNotNull null,
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
        gateway.supportsVersion("SYNO.DownloadStation.RSS.Site", 1) && gateway.supportsVersion("SYNO.DownloadStation.RSS.Feed", 1)

    fun supportsBtSearch(): Boolean = gateway.supportsVersion("SYNO.DownloadStation.BTSearch", 1)

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
                enabled = item["enabled"].strictBooleanValue()
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
        val id = item[key].strictStringValue() ?: throw invalidDownloadAdvancedResponse(key)
        if (id.isBlank() || id != id.trim() || id.any(Char::isISOControl) ||
            (commaSeparated && ',' in id)
        ) {
            throw invalidDownloadAdvancedResponse(key)
        }
        return id
    }

    private fun requiredDownloadSearchTitle(item: JsonObject): String {
        val title = item["title"].strictStringValue() ?: throw invalidDownloadAdvancedResponse("title")
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
        val sites = readRssPages("SYNO.DownloadStation.RSS.Site", emptyMap(), listOf("site", "sites")) { site ->
            val id = site["id"].strictIntValue()?.takeIf { it >= 0 } ?: throw invalidDownloadAdvancedResponse("site-id")
            DownloadRssSite(id.toString(), site["title"].strictStringValue()
                ?: throw invalidDownloadAdvancedResponse("site-title"),
                site["is_updating"].strictBooleanValue() ?: throw invalidDownloadAdvancedResponse("site-updating"),
                strictNonNegativeLong(site["last_update"]) ?: throw invalidDownloadAdvancedResponse("site-date"),
                downloadCreationKey("rss-site", id.toString(), site["url"].strictStringValue() ?: throw invalidDownloadAdvancedResponse("site-url"),
                    site["username"].strictStringValue() ?: throw invalidDownloadAdvancedResponse("site-user")))
        }
        if (sites.map { it.id }.distinct().size != sites.size) throw invalidDownloadAdvancedResponse("duplicate-site")
        return sites
    }

    suspend fun listRssFeeds(siteId: String): List<DownloadRssFeed> {
        require(siteId.toIntOrNull()?.let { it >= 0 && it.toString() == siteId } == true)
        return readRssPages("SYNO.DownloadStation.RSS.Feed", mapOf("id" to siteId), listOf("feeds")) { feed ->
            val size = feed["size"].strictStringValue()?.takeIf { it.isNotEmpty() && it.all(Char::isDigit) }
                ?.toLongOrNull() ?: throw invalidDownloadAdvancedResponse("feed-size")
            DownloadRssFeed(feed["title"].strictStringValue() ?: throw invalidDownloadAdvancedResponse("feed-title"),
                size, strictNonNegativeLong(feed["time"]) ?: throw invalidDownloadAdvancedResponse("feed-time"),
                feed["download_uri"].strictStringValue()?.takeIf(String::isNotBlank)
                    ?: throw invalidDownloadAdvancedResponse("feed-uri"), feed["external_link"].strictStringValue() ?: throw invalidDownloadAdvancedResponse("feed-link"))
        }.distinct()
    }

    private suspend fun <T> readRssPages(api: String, parameters: Map<String, String>, roots: List<String>, decode: (JsonObject) -> T): List<T> {
        val values = mutableListOf<T>()
        var expectedTotal: Int? = null
        var first = true
        while (true) {
            val data = gateway.call(api, "list", parameters + mapOf("offset" to values.size.toString(), "limit" to "500"), 1)
            val root = roots.filter { it in data }.singleOrNull() ?: throw invalidDownloadAdvancedResponse("rss-container")
            val page = data[root] as? JsonArray ?: throw invalidDownloadAdvancedResponse("rss-container")
            val total = data["total"].strictIntValue()?.takeIf { it >= 0 }
                ?: throw invalidDownloadAdvancedResponse("rss-total")
            if (first) { expectedTotal = total; first = false }
            else if (total != expectedTotal) throw invalidDownloadAdvancedResponse("rss-total-changed")
            if (data["offset"].strictIntValue() != values.size || page.size > 500) throw invalidDownloadAdvancedResponse("rss-offset")
            for (element in page) {
                val item = element as? JsonObject ?: throw invalidDownloadAdvancedResponse("rss-item")
                values += decode(item)
            }
            if (values.size > total) throw invalidDownloadAdvancedResponse("rss-total")
            if (values.size == total) return values
            if (page.isEmpty()) throw invalidDownloadAdvancedResponse("rss-incomplete")
        }
    }

    suspend fun refreshRssSiteResult(siteId: String,
        willSubmit: (DownloadRssSite) -> Unit = {}, didAccept: () -> Unit = {},
    ): MutationResult {
        val operation = "downloadRssRefresh"
        if (siteId.toIntOrNull()?.let { it >= 0 && it.toString() == siteId } != true) return serviceMutationResult(operation,
            MutationResultStatus.CONFIRMED_FAILURE, false, errorCategory = MutationErrorCategory.VALIDATION,
            diagnosticTag = "download-station.rss.refresh.invalid-target")
        val targetKey = "download-rss:$siteId"
        if (!claimServiceMutation(targetKey)) return serviceMutationResult(operation, MutationResultStatus.CONFIRMED_FAILURE,
            false, errorCategory = MutationErrorCategory.CONFLICT, diagnosticTag = "download-station.rss.refresh.duplicate-submission")
        var submitted = false
        var keepProtection = false
        try {
            val original = listRssSites().singleOrNull { it.id == siteId }
            if (original == null || original.isUpdating) return serviceMutationResult(operation, MutationResultStatus.CONFIRMED_FAILURE,
                false, errorCategory = MutationErrorCategory.CONFLICT, diagnosticTag = "download-station.rss.refresh.target-changed")
            currentCoroutineContext().ensureActive()
            willSubmit(original)
            submitted = true
            gateway.call("SYNO.DownloadStation.RSS.Site", "refresh", mapOf("id" to siteId), version = 1)
            withContext(NonCancellable) { didAccept() }
            val current = withContext(NonCancellable) { listRssSites().singleOrNull { it.id == siteId } }
            val complete = current != null && current.identityDigest == original.identityDigest && !current.isUpdating &&
                current.lastUpdatedAtEpochSeconds != null && original.lastUpdatedAtEpochSeconds != null &&
                current.lastUpdatedAtEpochSeconds > original.lastUpdatedAtEpochSeconds
            keepProtection = !complete
            return serviceMutationResult(operation, if (complete) MutationResultStatus.CONFIRMED_SUCCESS else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                true, requiresRefresh = !complete, diagnosticTag = "download-station.rss.refresh.${if (complete) "confirmed" else "updating"}")
        } catch (_: CancellationException) {
            keepProtection = submitted
            return serviceMutationResult(operation, if (submitted) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION else MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted, requiresRefresh = submitted, diagnosticTag = "download-station.rss.refresh.cancelled")
        } catch (failure: DsmFailure) {
            keepProtection = submitted && !definiteDownloadRejection(failure, settings = true)
            if (keepProtection) return serviceMutationResult(operation, MutationResultStatus.SUBMITTED_BUT_UNVERIFIED, true,
                requiresRefresh = true, errorCategory = failure.mutationErrorCategory(), diagnosticTag = "download-station.rss.refresh.unknown")
            return serviceMutationFailure(operation, failure, submitted, "download-station.rss.refresh.failed")
        } finally {
            if (!keepProtection) withContext(NonCancellable) { releaseServiceMutation(targetKey) }
        }
    }

    /** 只有持久层已保存终态之后才清理同连接的旧内存保护。 */
    suspend fun acknowledgeRssRefresh(siteId: String) = releaseServiceMutation("download-rss:$siteId")

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
        val taskId = started["taskid"].strictStringValue()?.takeIf { it.isNotBlank() && it.none(Char::isISOControl) } ?: throw DsmFailure(
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
                val finished = data["finished"].strictBooleanValue() ?: throw invalidDownloadAdvancedResponse("search-finished")
                if (finished) return parseDownloadBtResults(data)
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
        (data["items"] as? JsonArray ?: throw invalidDownloadAdvancedResponse("search-items")).map { value ->
            val item = value as? JsonObject ?: throw invalidDownloadAdvancedResponse("search-item")
            DownloadBtSearchResult(
                title = item["title"].strictStringValue() ?: throw invalidDownloadAdvancedResponse("search-title"),
                size = strictNonNegativeLong(item["size"]) ?: throw invalidDownloadAdvancedResponse("search-size"),
                listedAt = item["date"].strictStringValue(),
                downloadUri = item["download_uri"].strictStringValue()?.takeIf(String::isNotBlank)
                    ?: throw invalidDownloadAdvancedResponse("search-uri"),
                externalLink = item["external_link"].strictStringValue(),
                peers = item["peers"].strictIntValue()?.takeIf { it >= 0 },
                seeds = item["seeds"].strictIntValue()?.takeIf { it >= 0 },
                leeches = item["leechs"].strictIntValue()?.takeIf { it >= 0 },
                provider = item["module_title"].strictStringValue(),
            )
        }

    suspend fun create(uri: String, destination: String?) {
        requireConfirmedDownloadCreation(createResult(uri, destination))
    }

    suspend fun createResult(uri: String, destination: String?,
        willSubmit: (sourceKey: String, requestKey: String) -> Unit = { _, _ -> },
        didAccept: () -> Unit = {},
    ): MutationResult {
        val normalized = uri.trim()
        val parsedUri = runCatching { URI(normalized) }.getOrNull()
        val scheme = parsedUri?.scheme?.lowercase(Locale.ROOT)
        val normalizedDestination = downloadDestination(destination)
        val valid = normalized.isNotEmpty() &&
            normalized.length <= MAX_DOWNLOAD_URI_CHARACTERS &&
            scheme in setOf("http", "https", "ftp", "magnet") &&
            when (scheme) {
                "http", "https", "ftp" -> !parsedUri?.host.isNullOrBlank()
                "magnet" -> !parsedUri?.rawSchemeSpecificPart.isNullOrBlank()
                else -> false
            } &&
            (destination.isNullOrEmpty() || normalizedDestination != null)
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
        val apiName = "SYNO.DownloadStation.Task"
        if (!gateway.supportsVersion(apiName, 3)) return downloadMutationResult(
            "downloadCreate", MutationResultStatus.UNSUPPORTED, false, failed = 1,
            errorCategory = MutationErrorCategory.UNSUPPORTED, diagnosticTag = "download-station.create.unsupported-version")
        val sourceKey = downloadCreationKey("uri", normalized)
        val requestKey = downloadCreationKey("uri-request", sourceKey, normalizedDestination.orEmpty())
        return createDownloadTaskResult("downloadCreate", sourceKey, requestKey, normalizedDestination, willSubmit, didAccept) {
            gateway.call(apiName, "create", buildMap {
                put("uri", normalized)
                normalizedDestination?.let { put("destination", it) }
            }, version = 3)
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
        willSubmit: (sourceKey: String, requestKey: String) -> Unit = { _, _ -> },
        didAccept: () -> Unit = {},
    ): MutationResult {
        val extension = source.displayName.substringAfterLast('.', "").lowercase(Locale.ROOT)
        val normalizedDestination = downloadDestination(destination)
        val valid = extension in setOf("torrent", "nzb", "txt") &&
            source.displayName.isNotBlank() &&
            '\n' !in source.displayName &&
            '\r' !in source.displayName &&
            source.contentLength in 1..MAX_DOWNLOAD_TASK_FILE_BYTES &&
            unzipPassword.orEmpty().none { it == '\n' || it == '\r' || it == '\u0000' } &&
            (destination.isNullOrEmpty() || normalizedDestination != null)
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
        val version = if (normalizedDestination == null) 1 else 2
        val capability = gateway.capability("SYNO.DownloadStation.Task")
            ?.takeIf { version in it.minVersion..it.maxVersion }
            ?: return downloadMutationResult(
                operation = "downloadFileCreate",
                status = MutationResultStatus.UNSUPPORTED,
                submitted = false,
                failed = 1,
                errorCategory = MutationErrorCategory.UNSUPPORTED,
                diagnosticTag = "download-station.file-create.unsupported",
            )
        val sourceKey = withContext(Dispatchers.IO) {
            val digest = MessageDigest.getInstance("SHA-256")
            var count = 0L
            source.openInputStream().use { input ->
                val buffer = ByteArray(64 * 1024)
                while (true) {
                    currentCoroutineContext().ensureActive()
                    val size = input.read(buffer)
                    if (size < 0) break
                    count += size
                    require(count <= source.contentLength) { "Download task file changed" }
                    digest.update(buffer, 0, size)
                }
            }
            require(count == source.contentLength) { "Download task file changed" }
            downloadCreationKey("file", digest.digest().joinToString("") { "%02x".format(it) })
        }
        val requestKey = downloadCreationKey("file-request", sourceKey, normalizedDestination.orEmpty(), unzipPassword.orEmpty())
        return createDownloadTaskResult("downloadFileCreate", sourceKey, requestKey, normalizedDestination, willSubmit, didAccept) {
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

    /** 成功回执表示 NAS 接受创建；官方不提供可靠的任务归属查询，未知绝不按名称猜测。 */
    private suspend fun createDownloadTaskResult(
        operation: String,
        sourceKey: String,
        requestKey: String,
        destination: String?,
        willSubmit: (String, String) -> Unit,
        didAccept: () -> Unit,
        submit: suspend () -> JsonObject,
    ): MutationResult {
        val diagnostic = if (operation == "downloadFileCreate") "file-create" else "create"
        if (!currentCoroutineContext().isActive) return downloadMutationResult(operation,
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
            diagnosticTag = "download-station.$diagnostic.cancelled-before-submission")
        if (!creationMutationLock.withLock { activeCreationKeys.add(sourceKey) }) return downloadMutationResult(operation,
            MutationResultStatus.CONFIRMED_FAILURE, false, failed = 1, errorCategory = MutationErrorCategory.CONFLICT,
            diagnosticTag = "download-station.$diagnostic.duplicate-submission")
        var submitted = false
        var keepProtection = false
        try {
            if (destination != null) validateDownloadCreationDestination(operation, diagnostic, destination)?.let { return it }
            currentCoroutineContext().ensureActive()
            willSubmit(sourceKey, requestKey)
            // 本机保存后不再插入挂起点；传输层 one-shot 禁止正文被自动重放。
            submitted = true
            submit()
            withContext(NonCancellable) { didAccept() }
            return downloadMutationResult(operation, MutationResultStatus.CONFIRMED_SUCCESS, true, succeeded = 1,
                diagnosticTag = "download-station.$diagnostic.request-accepted")
        } catch (_: CancellationException) {
            keepProtection = submitted
            return downloadMutationResult(operation, if (submitted) MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                else MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, submitted, requiresRefresh = submitted,
                unknown = if (submitted) 1 else 0, diagnosticTag = "download-station.$diagnostic.cancelled")
        } catch (failure: DsmFailure) {
            val uncertain = submitted && !definiteDownloadRejection(failure)
            keepProtection = uncertain
            val status = when {
                uncertain -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                failure.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.AUTHENTICATION_FAILED) -> MutationResultStatus.PERMISSION_DENIED
                failure.kind == DsmErrorKind.FEATURE_UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
                else -> MutationResultStatus.CONFIRMED_FAILURE
            }
            return downloadMutationResult(operation, status, submitted, requiresRefresh = uncertain,
                failed = if (uncertain) 0 else 1, unknown = if (uncertain) 1 else 0,
                errorCategory = downloadMutationErrorCategory(failure), diagnosticTag = "download-station.$diagnostic.failed")
        } finally {
            if (!keepProtection) withContext(NonCancellable) { creationMutationLock.withLock { activeCreationKeys.remove(sourceKey) } }
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
            gateway.fileInfo("/$destination")
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

    fun supportsSettings(): Boolean = gateway.supportsVersion("SYNO.DownloadStation.Info", 1)
    fun supportsSchedule(): Boolean = gateway.supportsVersion("SYNO.DownloadStation.Schedule", 1)
    fun supportsTaskDestinationEditing(): Boolean = gateway.supportsVersion("SYNO.DownloadStation.Task", 1) &&
        gateway.supportsVersion("SYNO.DownloadStation.Task", 2) && gateway.supports("SYNO.FileStation.List")

    suspend fun loadSettings(): DownloadSettings {
        val manager = gateway.call("SYNO.DownloadStation.Info", "getinfo", version = 1)["is_manager"].strictBooleanValue() == true
        val version = if (gateway.supportsVersion("SYNO.DownloadStation.Info", 2)) 2 else 1
        var basicFailure: DsmFailure? = null
        val config = try { gateway.call("SYNO.DownloadStation.Info", "getconfig", version = version) }
            catch (failure: DsmFailure) { basicFailure = failure; JsonObject(emptyMap()) }
        val available = mutableSetOf<String>()
        fun boolean(name: String): Boolean = config[name].strictBooleanValue()?.also { available += name } ?: false
        fun limit(name: String): Int = config[name].strictIntValue()?.takeIf { it in 0..MAX_DOWNLOAD_LIMIT_KB }
            ?.also { available += name } ?: 0
        val destination = if (version == 2) config["default_destination"].strictStringValue()?.let(::downloadDestination)
            ?.also { available += "default_destination" }.orEmpty() else ""
        var result = DownloadSettings(destination, boolean("emule_enabled"), boolean("unzip_service_enabled"),
            limit("bt_max_download"), limit("bt_max_upload"), limit("http_max_download"), limit("ftp_max_download"),
            limit("nzb_max_download"), limit("emule_max_download"), limit("emule_max_upload"),
            availableFields = available, canManage = manager, basicFailure = basicFailure)
        if (result.httpDownloadLimitKb != result.ftpDownloadLimitKb ||
            !available.containsAll(setOf("http_max_download", "ftp_max_download"))) {
            available.removeAll(setOf("http_max_download", "ftp_max_download"))
        }
        if (supportsSchedule()) {
            try {
                val schedule = gateway.call("SYNO.DownloadStation.Schedule", "getconfig", version = 1)
                val enabled = schedule["enabled"].strictBooleanValue()?.also { available += "enabled" }
                val emule = schedule["emule_enabled"].strictBooleanValue()?.also { available += "schedule_emule_enabled" }
                result = result.copy(scheduleEnabled = enabled == true, emuleScheduleEnabled = emule == true)
            } catch (failure: DsmFailure) { result = result.copy(scheduleFailure = failure) }
        }
        return result.copy(availableFields = available.toSet())
    }

    @Deprecated("Use saveDownloadSettingsResult(original, desired) to preserve the visible baseline")
    suspend fun saveSettings(settings: DownloadSettings) { requireConfirmedDownloadCreation(saveSettingsResult(loadSettings(), settings)) }
    @Deprecated("Use saveDownloadSettingsResult(original, desired) to preserve the visible baseline")
    suspend fun saveSettingsResult(settings: DownloadSettings): MutationResult = saveSettingsResult(loadSettings(), settings)

    /** 每个分区按实际差量保存；当前权限和所改字段原值必须在发送前重新读取。 */
    suspend fun saveSettingsResult(original: DownloadSettings, desired: DownloadSettings,
        partition: DownloadSettingsPartition? = null,
        willSubmit: (DownloadSettingsPartition) -> Unit = {}, didAccept: (DownloadSettingsPartition) -> Unit = {},
    ): MutationResult {
        val operation = "downloadSettingsSave"
        if (!currentCoroutineContext().isActive) return downloadMutationResult(operation,
            MutationResultStatus.CANCELLED_BEFORE_SUBMISSION, false,
            diagnosticTag = "download-station.settings.cancelled-before-submission")
        var submitted = false
        var currentPartSubmitted = false
        var succeeded = 0
        val before = downloadSettingsParameters(original, false)
        val after = downloadSettingsParameters(desired, false).toMutableMap()
        val requested = after.filter { (key, value) -> value != before[key] }
        val fields = when (partition) {
            DownloadSettingsPartition.BASIC -> DOWNLOAD_BASIC_SETTING_FIELDS
            DownloadSettingsPartition.SCHEDULE -> DOWNLOAD_SCHEDULE_SETTING_FIELDS
            null -> before.keys
        }
        val delta = requested.filterKeys { it in fields }
        fun failed(category: MutationErrorCategory, tag: String) = downloadMutationResult(operation,
            when {
                succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
                category == MutationErrorCategory.PERMISSION -> MutationResultStatus.PERMISSION_DENIED
                category == MutationErrorCategory.UNSUPPORTED -> MutationResultStatus.UNSUPPORTED
                else -> MutationResultStatus.CONFIRMED_FAILURE
            }, submitted, succeeded = succeeded, failed = 1, errorCategory = category, diagnosticTag = "download-station.settings.$tag")
        if (delta.isEmpty()) return failed(MutationErrorCategory.CONFLICT, "no-changes")
        if (delta.keys.any { it in DOWNLOAD_SCHEDULE_SETTING_FIELDS } && !supportsSchedule() ||
            delta.keys.any { it in DOWNLOAD_BASIC_SETTING_FIELDS } && !supportsSettings())
            return failed(MutationErrorCategory.UNSUPPORTED, "partition-unavailable")
        if (!original.availableFields.containsAll(delta.keys)) return failed(MutationErrorCategory.UNSUPPORTED, "field-unavailable")
        if (delta.filterKeys { "max_" in it }.values.any { it.toIntOrNull() !in 0..MAX_DOWNLOAD_LIMIT_KB } ||
            "default_destination" in delta && downloadDestination(desired.defaultDestination) != desired.defaultDestination ||
            ("http_max_download" in delta || "ftp_max_download" in delta) &&
                (desired.httpDownloadLimitKb != desired.ftpDownloadLimitKb || !original.availableFields.containsAll(setOf("http_max_download", "ftp_max_download")))) {
            return failed(MutationErrorCategory.VALIDATION, "invalid-input")
        }
        if (!settingsMutationLock.withLock { if (isSettingsMutationActive()) false else { setSettingsMutationActive(true); true } })
            return failed(MutationErrorCategory.CONFLICT, "duplicate-submission")
        try {
            val partitions = DownloadSettingsPartition.entries.filter { part -> delta.keys.any {
                it in if (part == DownloadSettingsPartition.BASIC) DOWNLOAD_BASIC_SETTING_FIELDS else DOWNLOAD_SCHEDULE_SETTING_FIELDS } }
            for (part in partitions) {
                currentPartSubmitted = false
                val partFields = if (part == DownloadSettingsPartition.BASIC) DOWNLOAD_BASIC_SETTING_FIELDS else DOWNLOAD_SCHEDULE_SETTING_FIELDS
                val changes = delta.filterKeys { it in partFields }.toMutableMap()
                if (changes.keys.any { it in setOf("http_max_download", "ftp_max_download") }) {
                    changes["http_max_download"] = desired.httpDownloadLimitKb.toString()
                    changes["ftp_max_download"] = desired.ftpDownloadLimitKb.toString()
                }
                currentCoroutineContext().ensureActive()
                val current = loadSettings()
                if (!current.canManage) return failed(MutationErrorCategory.PERMISSION, "manager-required")
                val currentValues = downloadSettingsParameters(current)
                if (changes.keys.any { currentValues[it] == null || currentValues[it] != before[it] }) return failed(MutationErrorCategory.CONFLICT, "baseline-changed")
                willSubmit(part)
                submitted = true
                currentPartSubmitted = true
                gateway.call(if (part == DownloadSettingsPartition.BASIC) "SYNO.DownloadStation.Info" else "SYNO.DownloadStation.Schedule",
                    if (part == DownloadSettingsPartition.BASIC) "setserverconfig" else "setconfig",
                    changes.mapKeys { if (it.key == "schedule_emule_enabled") "emule_enabled" else it.key },
                    version = if (part == DownloadSettingsPartition.BASIC && gateway.supportsVersion("SYNO.DownloadStation.Info", 2)) 2 else 1)
                withContext(NonCancellable) { didAccept(part) }
                val observed = withContext(NonCancellable) { downloadSettingsParameters(loadSettings()) }
                if (changes.any { observed[it.key] != it.value }) return downloadMutationResult(operation,
                    if (succeeded > 0) MutationResultStatus.PARTIAL_SUCCESS else MutationResultStatus.SUBMITTED_BUT_UNVERIFIED,
                    true, requiresRefresh = true, succeeded = succeeded, unknown = 1,
                    diagnosticTag = "download-station.settings.readback-mismatch")
                succeeded++
            }
            return downloadMutationResult(operation, MutationResultStatus.CONFIRMED_SUCCESS, submitted, succeeded = succeeded,
                diagnosticTag = "download-station.settings.confirmed")
        } catch (_: CancellationException) {
            return downloadMutationResult(operation, when {
                succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
                currentPartSubmitted -> MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
                else -> MutationResultStatus.CANCELLED_BEFORE_SUBMISSION
            }, submitted, requiresRefresh = currentPartSubmitted, succeeded = succeeded, unknown = if (currentPartSubmitted) 1 else 0,
                diagnosticTag = "download-station.settings.cancelled")
        } catch (failure: DsmFailure) {
            val unknown = currentPartSubmitted && !definiteDownloadRejection(failure, settings = true)
            return downloadMutationResult(operation, when {
                succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
                unknown -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
                failure.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED, DsmErrorKind.AUTHENTICATION_FAILED) -> MutationResultStatus.PERMISSION_DENIED
                else -> MutationResultStatus.CONFIRMED_FAILURE
            }, submitted, requiresRefresh = unknown, succeeded = succeeded, failed = if (unknown) 0 else 1, unknown = if (unknown) 1 else 0,
                errorCategory = downloadMutationErrorCategory(failure), diagnosticTag = "download-station.settings.failed")
        } finally {
            withContext(NonCancellable) { settingsMutationLock.withLock { setSettingsMutationActive(false) } }
        }
    }

    /**
     * 正式任务控制入口。调用方必须传入用户看到并确认的稳定基线；Repository 在持锁后再次
     * 严格读取并逐项比对，任何身份或稳定字段漂移都在写请求前失败关闭。
     */
    suspend fun controlTasksResult(
        baseline: List<DownloadTaskMutationBaseline>,
        action: DownloadTaskMutationAction,
        willSubmit: () -> Unit = {},
        didAccept: () -> Unit = {},
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
            ids.isEmpty() || ids.any { !validTaskId(it) } ||
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
        val apiName = "SYNO.DownloadStation.Task"
        if (!gateway.supportsVersion(apiName, 1)) return downloadMutationResult(operation,
            MutationResultStatus.UNSUPPORTED, false, failed = ids.size, errorCategory = MutationErrorCategory.UNSUPPORTED,
            diagnosticTag = "download-station.${action.diagnosticName}.unsupported")
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

            try { willSubmit() } catch (failure: DsmFailure) {
                return serviceMutationFailure(operation, failure, false, "download-station.control.local-save-failed")
            }
            var submissionFailure: DsmFailure? = null
            var cancellationRequested = false
            var receipt: Map<String, Int>? = null
            try {
                val data = gateway.call(apiName, action.apiMethod, buildMap {
                    put("id", ids.joinToString(","))
                    action.forceComplete?.let { put("force_complete", it.toString()) }
                }, version = 1)
                receipt = taskReceipt(data, ids)
                if (receipt.values.all { it == 0 }) withContext(NonCancellable) { didAccept() }
                else if (receipt.values.all { it in KNOWN_TASK_ERRORS }) return downloadMutationResult(operation,
                    if (receipt.values.any { taskErrorCategory(it) == MutationErrorCategory.PERMISSION }) MutationResultStatus.PERMISSION_DENIED else MutationResultStatus.CONFIRMED_FAILURE,
                    true, failed = ids.size, errorCategory = taskErrorCategory(receipt.values.first()), diagnosticTag = "download-station.control.rejected")
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
                receipt = receipt,
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
     * 使用官方 Task.edit v2 修改单个任务的保存位置。目标目录和任务都在同一进程锁内
     * 重新读取完整基线；提交取消或传输失败后只回读，不自动重放写请求。
     */
    suspend fun editDestinationResult(
        baseline: DownloadTaskMutationBaseline,
        destination: FileItem,
        willSubmit: () -> Unit = {},
        didAccept: () -> Unit = {},
    ): MutationResult {
        val operation = "downloadEditDestination"
        val taskId = baseline.id
        val destinationPath = downloadDestination(destination.path)
        if (!currentCoroutineContext().isActive) {
            return downloadMutationResult(
                operation,
                MutationResultStatus.CANCELLED_BEFORE_SUBMISSION,
                submitted = false,
                diagnosticTag = "download-station.edit-destination.cancelled-before-submission",
            )
        }
        if (!validTaskId(taskId) || destinationPath == null || !destination.isDirectory || !destination.canWrite ||
            downloadDestination(baseline.destination) == destinationPath
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
                currentDestination = gateway.fileInfo(destination.path)
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

            try { willSubmit() } catch (failure: DsmFailure) {
                return serviceMutationFailure(operation, failure, false, "download-station.edit-destination.local-save-failed")
            }
            var submissionFailure: DsmFailure? = null
            var cancellationRequested = false
            var receiptCode: Int? = null
            try {
                val data = gateway.call("SYNO.DownloadStation.Task", "edit",
                    mapOf("id" to taskId, "destination" to destinationPath), version = 2)
                receiptCode = taskReceipt(data, listOf(taskId)).getValue(taskId)
                if (receiptCode == 0) withContext(NonCancellable) { didAccept() }
                else if (receiptCode in KNOWN_TASK_ERRORS) return downloadMutationResult(operation,
                    if (taskErrorCategory(receiptCode) == MutationErrorCategory.PERMISSION) MutationResultStatus.PERMISSION_DENIED else MutationResultStatus.CONFIRMED_FAILURE,
                    true, failed = 1, errorCategory = taskErrorCategory(receiptCode), diagnosticTag = "download-station.edit-destination.rejected")
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
            if (receiptCode == 0 && readback != null && sameTaskIdentity(baseline, readback) &&
                downloadDestination(readback.destination) == destinationPath) {
                return downloadMutationResult(
                    operation,
                    MutationResultStatus.CONFIRMED_SUCCESS,
                    submitted = true,
                    succeeded = 1,
                    diagnosticTag = "download-station.edit-destination.confirmed-success",
                )
            }
            val unchanged = readback?.let(DownloadTaskMutationBaseline::from) == baseline
            val failureCategory = receiptCode?.takeIf { it != 0 }?.let(::taskErrorCategory)
                ?: submissionFailure?.let(::downloadMutationErrorCategory)
            val explicitRejection = receiptCode in KNOWN_TASK_ERRORS || submissionFailure != null &&
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
            if (downloadDestination(task?.destination) == destination) break
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
        baseline: List<DownloadTaskMutationBaseline>, action: DownloadTaskMutationAction,
        receipt: Map<String, Int>?, readback: List<DownloadTask>, submissionFailure: DsmFailure?, cancellationRequested: Boolean,
    ): MutationResult {
        val byId = readback.associateBy(DownloadTask::id)
        val succeeded = baseline.count { expected ->
            receipt?.get(expected.id) == 0 && action.isConfirmed(byId[expected.id]) &&
                (byId[expected.id] == null || sameTaskIdentity(expected, byId.getValue(expected.id)))
        }
        val explicitFailure = submissionFailure?.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED,
            DsmErrorKind.AUTHENTICATION_FAILED, DsmErrorKind.FEATURE_UNSUPPORTED)
        val failed = baseline.count { expected ->
            (receipt?.get(expected.id) in KNOWN_TASK_ERRORS || explicitFailure) &&
                byId[expected.id]?.let(DownloadTaskMutationBaseline::from) == expected
        }
        val unknown = baseline.size - succeeded - failed
        val error = receipt?.values?.firstOrNull { it in KNOWN_TASK_ERRORS }?.let(::taskErrorCategory)
            ?: submissionFailure?.let(::downloadMutationErrorCategory)
        val status = when {
            succeeded == baseline.size -> MutationResultStatus.CONFIRMED_SUCCESS
            succeeded > 0 -> MutationResultStatus.PARTIAL_SUCCESS
            unknown > 0 && cancellationRequested -> MutationResultStatus.CANCELLATION_REQUESTED_AFTER_SUBMISSION
            unknown > 0 -> MutationResultStatus.SUBMITTED_BUT_UNVERIFIED
            error == MutationErrorCategory.PERMISSION || error == MutationErrorCategory.AUTHENTICATION -> MutationResultStatus.PERMISSION_DENIED
            else -> MutationResultStatus.CONFIRMED_FAILURE
        }
        return downloadMutationResult(action.downloadOperation, status, true, requiresRefresh = unknown > 0,
            succeeded = succeeded, failed = failed, unknown = unknown, errorCategory = error,
            diagnosticTag = "download-station.${action.diagnosticName}.${status.name.lowercase().replace('_', '-')}")
    }

    private val DownloadTaskMutationAction.apiMethod: String
        get() = when (this) {
            DownloadTaskMutationAction.PAUSE -> "pause"
            DownloadTaskMutationAction.RESUME -> "resume"
            DownloadTaskMutationAction.REMOVE_TASK,
            DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES,
            -> "delete"
        }

    private val DownloadTaskMutationAction.downloadOperation: String
        get() = when (this) {
            DownloadTaskMutationAction.PAUSE -> "downloadPause"
            DownloadTaskMutationAction.RESUME -> "downloadResume"
            DownloadTaskMutationAction.REMOVE_TASK -> "downloadDelete"
            DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES -> "downloadEndAndMove"
        }

    private val DownloadTaskMutationAction.diagnosticName: String
        get() = when (this) {
            DownloadTaskMutationAction.PAUSE -> "pause"
            DownloadTaskMutationAction.RESUME -> "resume"
            DownloadTaskMutationAction.REMOVE_TASK -> "delete"
            DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES -> "end-and-move"
        }

    private val DownloadTaskMutationAction.forceComplete: Boolean?
        get() = when (this) {
            DownloadTaskMutationAction.REMOVE_TASK -> false
            DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES -> true
            else -> null
        }

    private fun DownloadTaskMutationAction.effectCount(taskCount: Int): Int =
        taskCount

    private fun DownloadTaskMutationAction.accepts(status: ResourceState): Boolean = when (this) {
        DownloadTaskMutationAction.PAUSE -> status in setOf(ResourceState.RUNNING, ResourceState.WAITING)
        DownloadTaskMutationAction.RESUME -> status == ResourceState.PAUSED
        DownloadTaskMutationAction.REMOVE_TASK,
        DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES,
        -> true
    }

    private fun DownloadTaskMutationAction.isConfirmed(task: DownloadTask?): Boolean = when (this) {
        DownloadTaskMutationAction.PAUSE -> task?.status == ResourceState.PAUSED
        DownloadTaskMutationAction.RESUME -> task?.isCompleted == true || task?.status in setOf(ResourceState.RUNNING, ResourceState.WAITING)
        DownloadTaskMutationAction.REMOVE_TASK,
        DownloadTaskMutationAction.END_TASK_AND_MOVE_FILES,
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
        normalized in setOf("running", "started", "online", "active", "downloading", "uploading", "seeding", "checking", "hash_checking", "filehosting_waiting", "extracting") ->
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
    (this as? JsonPrimitive)?.takeIf { it.isString }?.contentOrNull

private fun JsonElement?.strictBooleanValue(allowString: Boolean = false): Boolean? {
    val primitive = this as? JsonPrimitive ?: return null
    if (!primitive.isString) return primitive.booleanOrNull
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
    return if (allowString || !primitive.isString) content.toIntOrNull() else null
}

private fun JsonObject.firstNonBlank(vararg keys: String): String? =
    keys.firstNotNullOfOrNull { key -> string(key)?.trim()?.takeIf(String::isNotBlank) }

private const val MAX_DOWNLOAD_URI_CHARACTERS = 8_192
private const val MAX_DOWNLOAD_DESTINATION_CHARACTERS = 2_048
private const val MAX_DOWNLOAD_TASK_FILE_BYTES = 100L * 1024L * 1024L
private const val MAX_DOWNLOAD_LIMIT_KB = 1_000_000
private const val MAX_DOWNLOAD_BT_SEARCH_POLLS = 60
private const val DOWNLOAD_BT_SEARCH_POLL_INTERVAL_MILLIS = 500L
private const val DOWNLOAD_MUTATION_READBACK_ATTEMPTS = 3
private const val DOWNLOAD_MUTATION_READBACK_INTERVAL_MILLIS = 500L
private const val DOWNLOAD_MUTATION_LIST_PAGE_SIZE = 500

private fun validTaskId(id: String): Boolean = id.isNotBlank() && id == id.trim() && ',' !in id && id.none(Char::isISOControl)

private fun strictNonNegativeLong(element: JsonElement?): Long? = (element as? JsonPrimitive)
    ?.takeUnless { it.isString }?.content?.toLongOrNull()?.takeIf { it >= 0 }

/** 目录来自 File Station；只移除一个根分隔符，合法文件名空格原样保留。 */
internal fun downloadDestination(value: String?): String? {
    if (value.isNullOrEmpty()) return null
    val path = value.removePrefix("/")
    return path.takeIf { it.length <= MAX_DOWNLOAD_DESTINATION_CHARACTERS && it.none(Char::isISOControl) &&
        it.split('/').none { part -> part.isEmpty() || part == "." || part == ".." } }
}

private fun taskReceipt(data: JsonObject, ids: List<String>): Map<String, Int> {
    val rows = data["_array"] as? JsonArray ?: throw invalidTaskReceipt()
    if (rows.size != ids.size) throw invalidTaskReceipt()
    val result = mutableMapOf<String, Int>()
    for (row in rows) {
        val item = row as? JsonObject ?: throw invalidTaskReceipt()
        val id = item["id"].strictStringValue() ?: throw invalidTaskReceipt()
        val error = item["error"].strictIntValue()?.takeIf { it >= 0 } ?: throw invalidTaskReceipt()
        if (id !in ids || result.put(id, error) != null) throw invalidTaskReceipt()
    }
    return result
}
private fun invalidTaskReceipt() = DsmFailure(null, "The task response was incomplete", "Refresh the task status.", kind = DsmErrorKind.INVALID_RESPONSE)
private val KNOWN_TASK_ERRORS = setOf( 101, 102, 103, 104, 105, 106, 107, 400, 401, 402, 403, 404, 405, 406, 407, 408)
private fun taskErrorCategory(code: Int): MutationErrorCategory = when (code) {
    105, 402 -> MutationErrorCategory.PERMISSION
    106, 107 -> MutationErrorCategory.AUTHENTICATION
    102, 103 -> MutationErrorCategory.UNSUPPORTED
    404 -> MutationErrorCategory.CONFLICT
    else -> MutationErrorCategory.SERVER
}
private fun sameTaskIdentity(expected: DownloadTaskMutationBaseline, current: DownloadTask): Boolean =
    expected.id == current.id && expected.type == current.type && expected.title == current.title &&
        expected.size == current.size && expected.createdAtEpochSeconds == current.createdAtEpochSeconds

private fun definiteDownloadRejection(failure: DsmFailure, settings: Boolean = false): Boolean {
    if (failure.isExplicitApiRejection) return failure.code in if (settings) (101..107).toSet() else KNOWN_TASK_ERRORS
    return failure.code in setOf(401, 403) && failure.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.SESSION_EXPIRED) ||
        failure.code == null && failure.kind in setOf(DsmErrorKind.PERMISSION_DENIED, DsmErrorKind.FEATURE_UNSUPPORTED, DsmErrorKind.PACKAGE_VERSION_UNSUPPORTED)
}
