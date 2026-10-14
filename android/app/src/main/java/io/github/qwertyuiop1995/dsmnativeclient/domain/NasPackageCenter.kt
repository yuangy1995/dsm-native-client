package io.github.qwertyuiop1995.dsmnativeclient.domain

import kotlinx.serialization.json.JsonPrimitive

/** 套件目录只呈现白名单字段；下载位置、任务标识和口令留在仓储当次内存。 */
internal data class NasPackageEntry(
    val packageId: String, val name: String, val version: String,
    val description: String = "", val releaseNotes: String = "", val publisher: String = "",
    val categories: List<String> = emptyList(), val beta: Boolean = false, val official: Boolean = false,
    val size: Long? = null, val installedVersion: String? = null, val updateAvailable: Boolean = false,
) { val id get() = packageId + if (beta) ":beta" else ":stable" }
internal data class NasPackageChoice(val id: String, val name: String)
internal data class NasPackageCatalog(val entries: List<NasPackageEntry>, val categories: List<NasPackageChoice>, val communityAvailable: Boolean)
internal enum class NasPackageUpdatePolicy { MANUAL, LATEST, IMPORTANT, SELECTED }
internal data class NasPackageUpdatePreference(val id: String, val name: String, val automaticAllowed: Boolean, val policy: NasPackageUpdatePolicy?)
internal data class NasPackagePreferences(
    val beta: Boolean, val email: Boolean, val desktop: Boolean, val policy: NasPackageUpdatePolicy,
    val defaultVolume: String, val volumes: List<NasPackageChoice>, val packages: List<NasPackageUpdatePreference>,
)
internal data class NasPackageSource(val name: String, val url: String)
internal data class NasPackageInstallItem(val entry: NasPackageEntry, val volumes: List<NasPackageChoice>, val defaultVolume: String)
internal data class NasPackageInstallPlan(val id: String, val items: List<NasPackageInstallItem>, val affected: List<String>)
internal enum class NasPackageInstallPhase { DOWNLOADING, OPTIONS, INSTALLING, COMPLETED, FAILED, CANCELLED, UNKNOWN }
internal enum class NasPackageFieldKind { DESCRIPTION, TEXT, PASSWORD, TOGGLE, RADIO, CHOICE }
internal data class NasPackageField(
    val id: String, val label: String, val kind: NasPackageFieldKind,
    val defaultValue: JsonPrimitive = JsonPrimitive(""), val choices: List<NasPackageChoice> = emptyList(),
    val group: String? = null, val required: Boolean = false, val minimumLength: Int? = null, val maximumLength: Int? = null,
)
internal data class NasPackageConfiguration(
    val name: String, val version: String, val license: String?, val fields: List<NasPackageField>,
    val volumes: List<NasPackageChoice>, val defaultVolume: String, val canStart: Boolean, val requiresRestart: Boolean,
)
internal data class NasPackageProgress(
    val id: String, val entry: NasPackageEntry, val completed: Int, val total: Int, val phase: NasPackageInstallPhase,
    val fraction: Double? = null, val configuration: NasPackageConfiguration? = null, val canCancel: Boolean = false,
    val problem: NasPackageProblem? = null,
)
internal enum class NasPackageProblem { INCOMPLETE, CHANGED, BUSY, DEPENDENCIES, VOLUME, BETA_AGREEMENT, PURCHASE,
    SIGNATURE, CUSTOM_OPTIONS, OPTIONS_REQUIRED, INVALID_FILE, INVALID_SOURCE, DUPLICATE_SOURCE, UNKNOWN, FAILED }
internal class NasPackageFailure(val problem: NasPackageProblem) : RuntimeException(problem.name)
internal enum class NasPackageWriteStep { SETTINGS, SOURCE, UPLOAD, DOWNLOAD, INSTALL, CANCEL_DOWNLOAD, CLEANUP, START, STOP, UNINSTALL }
internal enum class NasPackageWriteStage { WILL_SUBMIT, ACCEPTED, PREPARED, VERIFIED, REJECTED, NOT_SUBMITTED }
internal data class NasPackageCheckpoint(
    val operationId: String, val step: NasPackageWriteStep, val stage: NasPackageWriteStage,
    val entry: NasPackageEntry? = null, val index: Int = 0, val total: Int = 1,
)
internal typealias NasPackageObserver = suspend (NasPackageCheckpoint) -> Unit
