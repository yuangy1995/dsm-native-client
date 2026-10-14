package io.github.qwertyuiop1995.dsmnativeclient.domain

data class DownloadTask(
    val id: String,
    val type: String?,
    val title: String,
    val status: ResourceState,
    val size: Long?,
    val transferred: Long?,
    val downloadSpeed: Long?,
    val uploadSpeed: Long?,
    val destination: String?,
    val error: String?,
    val createdAtEpochSeconds: Long? = null,
    val priority: String? = null,
    val totalPeers: Int? = null,
    val connectedSeeders: Int? = null,
    val connectedLeechers: Int? = null,
    val files: List<DownloadTaskFile> = emptyList(),
    val trackers: List<DownloadTaskTracker> = emptyList(),
    val peers: List<DownloadTaskPeer> = emptyList(),
    val isCompleted: Boolean = false,
)

/** Download Station 任务控制使用的稳定操作类型，避免以自由字符串区分危险删除语义。 */
enum class DownloadTaskMutationAction {
    PAUSE,
    RESUME,
    REMOVE_TASK,
    END_TASK_AND_MOVE_FILES,
}

/**
 * 写入确认前保存的稳定任务基线。速率、已传输字节和 Peer 等易变字段不得参与写前冲突判断。
 */
data class DownloadTaskMutationBaseline(
    val id: String,
    val type: String?,
    val title: String,
    val status: ResourceState,
    val size: Long?,
    val destination: String?,
    val createdAtEpochSeconds: Long?,
) {
    companion object {
        fun from(task: DownloadTask) = DownloadTaskMutationBaseline(
            id = task.id,
            type = task.type,
            title = task.title,
            status = task.status,
            size = task.size,
            destination = task.destination,
            createdAtEpochSeconds = task.createdAtEpochSeconds,
        )
    }
}

data class DownloadTaskFile(
    val name: String,
    val size: Long?,
    val downloaded: Long?,
    val priority: String?,
)

data class DownloadTaskTracker(
    val url: String,
    val status: String?,
    val updateTimerSeconds: Int?,
    val seeds: Int?,
    val peers: Int?,
)

data class DownloadTaskPeer(
    val address: String,
    val agent: String?,
    val progress: Double?,
    val downloadSpeed: Long?,
    val uploadSpeed: Long?,
)

data class DownloadRssSite(
    val id: String,
    val title: String,
    val isUpdating: Boolean,
    val lastUpdatedAtEpochSeconds: Long?,
    val identityDigest: String = "",
)

data class DownloadRssFeed(
    val title: String,
    val size: Long?,
    val publishedAtEpochSeconds: Long?,
    val downloadUri: String,
    val externalLink: String?,
)

data class DownloadBtSearchResult(
    val title: String,
    val size: Long?,
    val listedAt: String?,
    val downloadUri: String,
    val externalLink: String?,
    val peers: Int?,
    val seeds: Int?,
    val leeches: Int?,
    val provider: String?,
)

data class DownloadBtSearchModule(
    val id: String,
    val title: String,
    val enabled: Boolean,
)

data class DownloadBtSearchCategory(
    val id: String,
    val title: String,
)

data class DownloadBtSearchCatalog(
    val modules: List<DownloadBtSearchModule>,
    val categories: List<DownloadBtSearchCategory>,
)

enum class DownloadDiscoveryTab {
    RSS,
    BT_SEARCH,
}

enum class DownloadBtSearchModuleScope {
    ALL,
    ENABLED,
    SELECTED,
}

enum class DownloadBtSearchSort(val apiValue: String) {
    TITLE("title"),
    SIZE("size"),
    DATE("date"),
    PEERS("peers"),
    PROVIDER("provider"),
    SEEDS("seeds"),
    LEECHES("leechs"),
}

enum class DownloadBtSearchDirection(val apiValue: String) {
    ASCENDING("asc"),
    DESCENDING("desc"),
}

/** 仅保存在 Workspace 内存中的 BT 搜索输入，不进入 SavedState、磁盘或日志。 */
data class DownloadBtSearchOptions(
    val keyword: String = "",
    val moduleScope: DownloadBtSearchModuleScope = DownloadBtSearchModuleScope.ENABLED,
    val selectedModuleIds: Set<String> = emptySet(),
    val categoryId: String? = null,
    val sort: DownloadBtSearchSort = DownloadBtSearchSort.SEEDS,
    val direction: DownloadBtSearchDirection = DownloadBtSearchDirection.DESCENDING,
    val titleFilter: String = "",
)

data class DownloadStationActivity(
    val downloadBytesPerSecond: Long,
    val uploadBytesPerSecond: Long,
    val emuleDownloadBytesPerSecond: Long,
    val emuleUploadBytesPerSecond: Long,
)

data class DownloadSettings(
    val defaultDestination: String = "",
    val emuleEnabled: Boolean = false,
    val autoExtractEnabled: Boolean = false,
    val btDownloadLimitKb: Int = 0,
    val btUploadLimitKb: Int = 0,
    val httpDownloadLimitKb: Int = 0,
    val ftpDownloadLimitKb: Int = 0,
    val nzbDownloadLimitKb: Int = 0,
    val emuleDownloadLimitKb: Int = 0,
    val emuleUploadLimitKb: Int = 0,
    val scheduleEnabled: Boolean = false,
    val emuleScheduleEnabled: Boolean = false,
    val availableFields: Set<String> = DOWNLOAD_SETTING_FIELDS,
    val canManage: Boolean = false,
    val scheduleFailure: DsmFailure? = null,
    val basicFailure: DsmFailure? = null,
)

enum class DownloadSettingsPartition { BASIC, SCHEDULE }

internal val DOWNLOAD_BASIC_SETTING_FIELDS = setOf("default_destination", "emule_enabled", "unzip_service_enabled",
    "bt_max_download", "bt_max_upload", "http_max_download", "ftp_max_download", "nzb_max_download", "emule_max_download", "emule_max_upload")
internal val DOWNLOAD_SCHEDULE_SETTING_FIELDS = setOf("enabled", "schedule_emule_enabled")
internal val DOWNLOAD_SETTING_FIELDS = DOWNLOAD_BASIC_SETTING_FIELDS + DOWNLOAD_SCHEDULE_SETTING_FIELDS

/** 字段存在性与默认显示值分离；缺失字段不得进入请求或被当作 false/0。 */
internal fun downloadSettingsParameters(value: DownloadSettings, availableOnly: Boolean = true): Map<String, String> = mapOf(
    "default_destination" to value.defaultDestination, "emule_enabled" to value.emuleEnabled.toString(),
    "unzip_service_enabled" to value.autoExtractEnabled.toString(), "bt_max_download" to value.btDownloadLimitKb.toString(),
    "bt_max_upload" to value.btUploadLimitKb.toString(), "http_max_download" to value.httpDownloadLimitKb.toString(),
    "ftp_max_download" to value.ftpDownloadLimitKb.toString(), "nzb_max_download" to value.nzbDownloadLimitKb.toString(),
    "emule_max_download" to value.emuleDownloadLimitKb.toString(), "emule_max_upload" to value.emuleUploadLimitKb.toString(),
    "enabled" to value.scheduleEnabled.toString(), "schedule_emule_enabled" to value.emuleScheduleEnabled.toString(),
).filterKeys { !availableOnly || it in value.availableFields }
