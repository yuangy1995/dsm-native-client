package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

internal class PackageJob(
    val id: String, val candidates: List<PackageCandidate>, val items: List<NasPackageInstallItem>,
    val volumes: Map<String, String>, val startAfterInstall: Boolean, val observer: NasPackageObserver,
    val manual: Boolean = false,
) {
    var index = 0
    var phase = NasPackageInstallPhase.INSTALLING
    var taskId: String? = null
    var fraction: Double? = null
    var configuration: NasPackageConfiguration? = null
    var checked: JsonObject? = null
    var finalSubmitted = false
    var outcomeUnknown = false
    var cancelRequested = false
    var cleanupSubmitted = false
    var submittedStep: NasPackageWriteStep? = null
    var problem: NasPackageProblem? = null
    val current get() = candidates[index.coerceAtMost(candidates.lastIndex)]
    val progress get() = NasPackageProgress(id, current.entry, index, candidates.size, phase, fraction, configuration,
        !cancelRequested && !cleanupSubmitted && !finalSubmitted && (phase in setOf(NasPackageInstallPhase.DOWNLOADING, NasPackageInstallPhase.UNKNOWN) && taskId != null ||
            phase == NasPackageInstallPhase.OPTIONS || phase == NasPackageInstallPhase.UNKNOWN && checked != null), problem)
    fun event(step: NasPackageWriteStep, stage: NasPackageWriteStage) = NasPackageCheckpoint(id, step, stage, current.entry, index, candidates.size)
}
internal suspend fun NasPackageRepository.start(planId: String, volumes: Map<String, String>, startAfterInstall: Boolean,
    observer: NasPackageObserver): NasPackageProgress = exclusive {
    requireIdle()
    val saved = plan?.takeIf { it.value.id == planId } ?: packageFailure(NasPackageProblem.CHANGED)
    readCatalog()
    val fresh = buildPlan(saved.requested.map { candidates[it] ?: packageFailure(NasPackageProblem.CHANGED) })
    if (fresh.value.items != saved.value.items || fresh.value.affected != saved.value.affected || fresh.queue != saved.queue ||
        fresh.candidates != saved.candidates || fresh.installed != saved.installed) packageFailure(NasPackageProblem.CHANGED)
    if (volumes.keys.any { key -> saved.value.items.none { it.entry.id == key } }) packageFailure(NasPackageProblem.VOLUME)
    saved.value.items.forEach { validatePackageVolume(volumes[it.entry.id] ?: it.defaultVolume, it.volumes) }
    currentCoroutineContext().ensureActive()
    val current = PackageJob(UUID.randomUUID().toString(), saved.candidates, saved.value.items, volumes.toMap(), startAfterInstall, observer)
    plan = null; job = current
    submitPackage(current)
}
internal fun validatePackageVolume(selected: String, available: List<NasPackageChoice>) {
    if (!(selected.isEmpty() && available.isEmpty()) && available.none { it.id == selected }) packageFailure(NasPackageProblem.VOLUME)
}
internal suspend fun NasPackageRepository.submitPackage(current: PackageJob): NasPackageProgress {
    val candidate = current.current
    try {
        if (candidate.raw["price"] != null && candidate.raw["price"] !is JsonNull && candidate.raw["type"].packageLong() != 0L) packageFailure(NasPackageProblem.PURCHASE)
        if (installed().singleOrNull { it.id == candidate.entry.packageId }?.version != candidate.entry.installedVersion) packageFailure(NasPackageProblem.CHANGED)
        feasibility(listOf(candidate.entry.packageId))
        val environment = environment(candidate)
        val volume = current.volumes[candidate.entry.id] ?: current.items[current.index].defaultVolume
        validatePackageVolume(volume, environment.volumes)
        val parameters = mutableMapOf<String, JsonElement>("name" to JsonPrimitive(candidate.entry.packageId), "blqinst" to JsonPrimitive(candidate.quick))
        if (candidate.quick) {
            parameters += mapOf("volume_path" to JsonPrimitive(volume), "is_syno" to JsonPrimitive(candidate.entry.official),
                "beta" to JsonPrimitive(candidate.entry.beta), "installrunpackage" to JsonPrimitive(current.startAfterInstall))
            current.phase = NasPackageInstallPhase.INSTALLING
        } else {
            val size = candidate.raw["size"].packageLong()?.takeIf { it > 0 } ?: packageFailure()
            parameters += mapOf("url" to JsonPrimitive(candidate.raw.packageText("link")), "checksum" to JsonPrimitive(candidate.raw.packageText("md5")),
                "filesize" to JsonPrimitive(size), "type" to JsonPrimitive(candidate.raw["type"].packageLong() ?: packageFailure()),
                "operation" to JsonPrimitive(if (candidate.entry.installedVersion == null) "install" else "upgrade"))
            current.phase = NasPackageInstallPhase.DOWNLOADING
        }
        val result = installationWrite(current, if (candidate.quick) NasPackageWriteStep.INSTALL else NasPackageWriteStep.DOWNLOAD,
            if (candidate.entry.installedVersion == null) "install" else "upgrade", parameters)
        if (result["progress"].packageNumber()?.let { it < 0 } == true) {
            notify(current.event(requireNotNull(current.submittedStep), NasPackageWriteStage.REJECTED), current.observer)
            current.phase = NasPackageInstallPhase.FAILED; current.problem = NasPackageProblem.FAILED
            return current.progress
        }
        val task = result["taskid"].packageString() ?: (result["data"] as? JsonObject)?.get("taskid").packageString()
        current.taskId = task?.takeIf { it.isNotBlank() }
        current.fraction = result["progress"].packageNumber()?.takeIf { it in 0.0..1.0 }
        if (current.taskId == null) { current.phase = NasPackageInstallPhase.UNKNOWN; current.outcomeUnknown = true; current.problem = NasPackageProblem.UNKNOWN }
        return current.progress
    } catch (error: Exception) { return failInstallation(current, error) }
}
internal suspend fun NasPackageRepository.installationWrite(current: PackageJob, step: NasPackageWriteStep, method: String,
    parameters: Map<String, JsonElement>): JsonObject {
    var accepted = false
    try {
        val result = write(PACKAGE_INSTALL, method, parameters, current.event(step, NasPackageWriteStage.WILL_SUBMIT)) { event ->
            // 接受已发生时先保留内存事实，即使后续本机记录写失败也不能认作未发送。
            if (event.stage == NasPackageWriteStage.ACCEPTED) accepted = true
            current.observer(event)
            if (event.stage == NasPackageWriteStage.WILL_SUBMIT) {
                current.submittedStep = step; current.outcomeUnknown = true
                if (step == NasPackageWriteStep.INSTALL) current.finalSubmitted = true
                if (step == NasPackageWriteStep.CANCEL_DOWNLOAD) current.cancelRequested = true
                if (step == NasPackageWriteStep.CLEANUP) { current.cancelRequested = true; current.cleanupSubmitted = true }
            }
        }
        current.outcomeUnknown = false
        return result
    } catch (error: Exception) {
        if (!accepted && error.packageRejection() && current.submittedStep == step) {
            notify(current.event(step, NasPackageWriteStage.REJECTED), current.observer)
            current.phase = NasPackageInstallPhase.FAILED; current.problem = NasPackageProblem.FAILED; current.outcomeUnknown = false
        }
        throw error
    }
}
internal suspend fun NasPackageRepository.failInstallation(current: PackageJob, error: Exception): NasPackageProgress {
    if (current.submittedStep == null && current.index > 0 && error !is PackageCheckpointFailure) {
        notify(current.event(NasPackageWriteStep.INSTALL, NasPackageWriteStage.NOT_SUBMITTED), current.observer)
    }
    if (current.phase != NasPackageInstallPhase.FAILED) {
        current.phase = if (current.submittedStep == null) NasPackageInstallPhase.FAILED else NasPackageInstallPhase.UNKNOWN
        current.problem = (error as? NasPackageFailure)?.problem ?: if (current.phase == NasPackageInstallPhase.FAILED) NasPackageProblem.FAILED else NasPackageProblem.UNKNOWN
    }
    if (error is PackageCheckpointFailure || error.packageTrustFailure()) throw error
    return current.progress
}
internal suspend fun NasPackageRepository.advance(id: String): NasPackageProgress = exclusive {
    val current = job?.takeIf { it.id == id } ?: packageFailure(NasPackageProblem.CHANGED)
    if (current.phase in setOf(NasPackageInstallPhase.COMPLETED, NasPackageInstallPhase.FAILED, NasPackageInstallPhase.CANCELLED, NasPackageInstallPhase.OPTIONS)) return@exclusive current.progress
    if (current.cleanupSubmitted) return@exclusive current.progress
    try {
        val task = current.taskId
        if (task != null) {
            val status = gateway.call(PACKAGE_INSTALL, "status", 1, mapOf("task_id" to JsonPrimitive(task)))
            current.fraction = status["progress"].packageNumber()?.takeIf { it in 0.0..1.0 }
            if (!status.packageFlag("finished")) {
                current.phase = if (current.finalSubmitted) NasPackageInstallPhase.INSTALLING else NasPackageInstallPhase.DOWNLOADING
                current.problem = null
                return@exclusive current.progress
            }
            val success = status.packageFlag("success")
            if (current.cancelRequested) {
                if (success) {
                    current.checked = gateway.call("SYNO.Core.Package.Installation.Download", "check", 1,
                        mapOf("taskid" to JsonPrimitive("@SYNOPKG_DOWNLOAD_" + current.current.entry.packageId)))
                    current.taskId = null
                    cleanPackage(current)
                }
                notify(current.event(NasPackageWriteStep.CANCEL_DOWNLOAD, NasPackageWriteStage.VERIFIED), current.observer)
                current.phase = NasPackageInstallPhase.CANCELLED; current.problem = null
                return@exclusive current.progress
            }
            if (!success) {
                notify(current.event(requireNotNull(current.submittedStep), NasPackageWriteStage.REJECTED), current.observer)
                current.phase = NasPackageInstallPhase.FAILED; current.problem = NasPackageProblem.FAILED
                return@exclusive current.progress
            }
            if (!current.finalSubmitted && current.checked == null) {
                current.checked = gateway.call("SYNO.Core.Package.Installation.Download", "check", 1,
                    mapOf("taskid" to JsonPrimitive("@SYNOPKG_DOWNLOAD_" + current.current.entry.packageId)))
                current.taskId = null
            }
        }
        if (current.checked != null && !current.finalSubmitted) {
            current.configuration = configuration(requireNotNull(current.checked), current.current.entry)
            notify(current.event(if (current.manual) NasPackageWriteStep.UPLOAD else NasPackageWriteStep.DOWNLOAD, NasPackageWriteStage.PREPARED), current.observer)
            current.phase = NasPackageInstallPhase.OPTIONS; current.problem = null
            return@exclusive current.progress
        }
        if (!current.finalSubmitted || !installationMatches(current, installed())) {
            current.phase = NasPackageInstallPhase.UNKNOWN; current.problem = NasPackageProblem.UNKNOWN
            return@exclusive current.progress
        }
        completePackage(current)
    } catch (error: Exception) {
        // 权限、证书和取消立即停止，不以第二次查询越过拒绝。
        if (error is PackageCheckpointFailure || error.packageTrustFailure()) {
            current.phase = NasPackageInstallPhase.UNKNOWN; current.problem = NasPackageProblem.UNKNOWN; throw error
        }
        if (error is NasPackageFailure && error.problem in setOf(NasPackageProblem.SIGNATURE, NasPackageProblem.CUSTOM_OPTIONS) && current.checked != null) {
            cleanPackage(current)
            current.phase = NasPackageInstallPhase.FAILED; current.problem = error.problem
            return@exclusive current.progress
        }
        if (current.finalSubmitted && current.phase != NasPackageInstallPhase.FAILED) {
            val installed = try { installed() } catch (readError: Exception) {
                if (readError.packageTrustFailure()) { current.phase = NasPackageInstallPhase.UNKNOWN; throw readError }; null
            }
            if (installed != null && installationMatches(current, installed)) return@exclusive completePackage(current)
        }
        failInstallation(current, error)
    }
}
private fun installationMatches(current: PackageJob, actual: List<PackageInstalled>): Boolean {
    if (!current.finalSubmitted || current.outcomeUnknown && current.current.entry.installedVersion == current.current.entry.version) return false
    return actual.any { it.id == current.current.entry.packageId && it.version == current.current.entry.version && it.status.lowercase() in setOf("running", "stopped", "active", "inactive") }
}
private suspend fun NasPackageRepository.completePackage(current: PackageJob): NasPackageProgress {
    notify(current.event(NasPackageWriteStep.INSTALL, NasPackageWriteStage.VERIFIED), current.observer)
    current.index++
    current.taskId = null; current.checked = null; current.configuration = null; current.fraction = null; current.problem = null
    current.outcomeUnknown = false; current.finalSubmitted = false; current.cancelRequested = false; current.submittedStep = null
    if (current.index == current.candidates.size) { current.phase = NasPackageInstallPhase.COMPLETED; return current.progress }
    return submitPackage(current)
}
internal suspend fun NasPackageRepository.configure(id: String, volume: String, startAfterInstall: Boolean, licenseAccepted: Boolean,
    values: Map<String, JsonPrimitive>): NasPackageProgress = exclusive {
    val current = job?.takeIf { it.id == id && it.phase == NasPackageInstallPhase.OPTIONS && !it.cancelRequested } ?: packageFailure(NasPackageProblem.CHANGED)
    val options = current.configuration ?: packageFailure(NasPackageProblem.OPTIONS_REQUIRED)
    val checked = current.checked ?: packageFailure()
    if (options.license != null && !licenseAccepted) packageFailure(NasPackageProblem.OPTIONS_REQUIRED)
    val extra = options.checkedValues(values)
    validatePackageVolume(volume, options.volumes)
    if (installed().singleOrNull { it.id == current.current.entry.packageId }?.version != current.current.entry.installedVersion) packageFailure(NasPackageProblem.CHANGED)
    feasibility(listOf(current.current.entry.packageId))
    val check = mutableMapOf<String, JsonElement>("id" to JsonPrimitive(current.current.entry.packageId), "blCheckDep" to JsonPrimitive(current.manual))
    for ((target, source) in listOf("install_type" to "install_type", "install_on_cold_storage" to "install_on_cold_storage", "breakpkgs" to "break_pkgs", "replacepkgs" to "replace_pkgs")) {
        checked.packageMetadata(source)?.takeUnless { it is JsonNull }?.let { check[target] = it }
    }
    val environment = gateway.call(PACKAGE_INSTALL, "check", 2, check)
    if (environment["is_occupied"].packageBoolean() != false) packageFailure(NasPackageProblem.BUSY)
    val system = checked.packageMetadata("install_type").packageString() in setOf("system", "system_hidden")
    val volumes = if (system && (environment["volume_list"] == null || environment["volume_list"] is JsonNull)) emptyList() else packageVolumes(environment["volume_list"])
    validatePackageVolume(volume, volumes)
    val type = checked["type"]?.takeUnless { it is JsonNull }?.let { it.packageLong() ?: packageFailure() } ?: 0L
    val parameters = mutableMapOf<String, JsonElement>("volume_path" to JsonPrimitive(volume), "extra_values" to JsonPrimitive(extra.toString()),
        "type" to JsonPrimitive(type), "check_codesign" to JsonPrimitive(true), "force" to JsonPrimitive(!current.manual), "installrunpackage" to JsonPrimitive(startAfterInstall && options.canStart))
    val task = checked.packageMetadata("task_id").packageString()
    if (!task.isNullOrBlank()) parameters["task_id"] = JsonPrimitive(task)
    else parameters["path"] = JsonPrimitive(checked.packageText("filename"))
    try {
        installationWrite(current, NasPackageWriteStep.INSTALL, if (current.current.entry.installedVersion == null) "install" else "upgrade", parameters)
        current.taskId = null; current.configuration = null; current.phase = NasPackageInstallPhase.INSTALLING; current.problem = null
        current.progress
    } catch (error: Exception) { failInstallation(current, error) }
}
internal suspend fun NasPackageRepository.cancel(id: String): NasPackageProgress = exclusive {
    val current = job?.takeIf { it.id == id } ?: packageFailure(NasPackageProblem.CHANGED)
    if (current.cancelRequested) return@exclusive current.progress
    if (!current.progress.canCancel) packageFailure(NasPackageProblem.BUSY)
    try {
        val task = current.taskId
        if (task != null && !current.finalSubmitted) {
            installationWrite(current, NasPackageWriteStep.CANCEL_DOWNLOAD, "cancel", mapOf("taskid" to JsonPrimitive(task)))
            // 取消旧状态读取可能留下 UNKNOWN；取消请求已接受后仍需等待下载结束并清理。
            current.phase = NasPackageInstallPhase.DOWNLOADING; current.problem = null
        } else {
            cleanPackage(current)
            current.phase = NasPackageInstallPhase.CANCELLED; current.configuration = null; current.checked = null
        }
        current.progress
    } catch (error: Exception) { failInstallation(current, error) }
}
internal suspend fun NasPackageRepository.cleanPackage(current: PackageJob) {
    if (current.cleanupSubmitted) packageFailure(NasPackageProblem.UNKNOWN)
    val checked = current.checked ?: packageFailure()
    val filename = checked["filename"].packageString()?.takeIf { it.isNotBlank() }
    val task = checked.packageMetadata("task_id").packageString()?.takeIf { it.isNotBlank() }
    val method = if (filename != null) "delete" else if (task != null) "clean" else packageFailure()
    val parameters = if (filename != null) mapOf("path" to JsonPrimitive(filename)) else mapOf("task_id" to JsonPrimitive(task))
    installationWrite(current, NasPackageWriteStep.CLEANUP, method, parameters)
    notify(current.event(NasPackageWriteStep.CLEANUP, NasPackageWriteStage.VERIFIED), current.observer)
}
