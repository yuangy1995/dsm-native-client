package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.PackageMutationOperation
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import io.github.qwertyuiop1995.dsmnativeclient.nas.packageDigest
import kotlinx.coroutines.*
import kotlinx.serialization.json.*

internal fun PackageMutationOperation.controlStep() = when (this) {
    PackageMutationOperation.START -> NasPackageWriteStep.START
    PackageMutationOperation.STOP -> NasPackageWriteStep.STOP
    PackageMutationOperation.UNINSTALL -> NasPackageWriteStep.UNINSTALL
}
internal fun PackageInfo.allowsControl(action: PackageMutationOperation) = when (action) {
    PackageMutationOperation.START -> canStart
    PackageMutationOperation.STOP -> canStop
    PackageMutationOperation.UNINSTALL -> canUninstall
}
internal fun packageInstallationDigest(value: PackageInfo) = packageDigest(buildJsonObject {
    put("id", value.id); put("version", value.version); put("type", value.installType); put("time", value.installedAt)
}.toString())
internal fun samePackageBaseline(current: PackageInfo, original: PackageInfo) =
    packageInstallationDigest(current) == packageInstallationDigest(original) && current.status == original.status &&
        current.dsmApps == original.dsmApps && current.canStart == original.canStart && current.canStop == original.canStop && current.canUninstall == original.canUninstall
internal fun packageControlMatches(rows: List<PackageInfo>, id: String, digest: String, action: PackageMutationOperation): Boolean {
    val current = rows.singleOrNull { it.id == id }
    if (action == PackageMutationOperation.UNINSTALL) return current == null
    return current != null && packageInstallationDigest(current) == digest &&
        current.status == if (action == PackageMutationOperation.START) ResourceState.RUNNING else ResourceState.STOPPED
}
private fun NasPackageRepository.controlCapability(action: PackageMutationOperation? = null) {
    val api = if (action == PackageMutationOperation.UNINSTALL) "SYNO.Core.Package.Uninstallation" else "SYNO.Core.Package.Control"
    if (!controlSupports(PACKAGE_API, 2) || action != null && (!controlSupports(PACKAGE_API, 1) || !controlSupports(api, 1)))
        throw DsmFailure(null, "Package actions unavailable", "Open Package Center in DSM.", kind = DsmErrorKind.FEATURE_UNSUPPORTED)
}
internal fun NasPackageRepository.supportsControl(action: PackageMutationOperation) = runCatching { controlCapability(action) }.isSuccess
internal suspend fun NasPackageRepository.controlInstalled(): List<PackageInfo> = exclusive { controlCapability(); controlReader() }
internal suspend fun NasPackageRepository.recoverControl(action: PackageMutationOperation): List<PackageInfo> = exclusive { readControl(action) }
private suspend fun NasPackageRepository.readControl(action: PackageMutationOperation): List<PackageInfo> {
    controlCapability(action); gateway.requireWriteAccess(); return controlReader()
}

/** 启停、卸载共用安装管线；写前保存提交阶段，模糊回执和恢复都不重放。 */
internal suspend fun NasPackageRepository.performControl(id: String, original: PackageInfo, action: PackageMutationOperation,
    observer: NasPackageObserver): List<PackageInfo>? = exclusive {
    requireIdle()
    val event = NasPackageCheckpoint(id, action.controlStep(), NasPackageWriteStage.WILL_SUBMIT)
    var submitted = false
    var rejected = false
    suspend fun verify(attempts: Int): List<PackageInfo>? {
        var rows: List<PackageInfo>? = null
        var failure: DsmFailure? = null
        repeat(attempts) { attempt ->
            if (attempt > 0) controlPause()
            try {
                rows = readControl(action); failure = null
                if (packageControlMatches(requireNotNull(rows), original.id, packageInstallationDigest(original), action)) {
                    notify(event.copy(stage = NasPackageWriteStage.VERIFIED), observer)
                    preferencePending = false
                    return rows
                }
            } catch (error: DsmFailure) {
                if (error.kind !in setOf(DsmErrorKind.CONNECTION_FAILED, DsmErrorKind.UNKNOWN)) throw error
                failure = error
            }
        }
        failure?.let { throw it }
        return rows
    }
    try {
        val current = readControl(action).singleOrNull { it.id == original.id } ?: packageFailure(NasPackageProblem.CHANGED)
        if (!samePackageBaseline(current, original) || !current.allowsControl(action)) packageFailure(NasPackageProblem.CHANGED)
        val method = action.name.lowercase(java.util.Locale.ROOT)
        gateway.call(PACKAGE_API, "feasibility_check", 1,
            mapOf("type" to JsonPrimitive("${method}_check"), "packages" to packageStrings(listOf(current.id))))
        currentCoroutineContext().ensureActive()
        gateway.requireWriteAccess()
        notify(event, observer); submitted = true; preferencePending = true
        val parameters = mutableMapOf<String, JsonElement>("id" to JsonPrimitive(current.id))
        if (action != PackageMutationOperation.STOP) parameters["dsm_apps"] = packageStrings(current.dsmApps)
        try {
            gateway.call(if (action == PackageMutationOperation.UNINSTALL) "SYNO.Core.Package.Uninstallation" else "SYNO.Core.Package.Control",
                method, 1, parameters, write = true)
        } catch (error: Exception) {
            if (directoryExplicitRejection(error)) {
                rejected = true; notify(event.copy(stage = NasPackageWriteStage.REJECTED), observer); preferencePending = false; throw error
            }
            if (error is CancellationException || directoryTrustFailure(error)) throw error
            return@exclusive verify(if (action == PackageMutationOperation.UNINSTALL) 1 else 3)
        }
        notify(event.copy(stage = NasPackageWriteStage.ACCEPTED), observer)
        verify(if (action == PackageMutationOperation.UNINSTALL) 1 else 10)
    } catch (error: CancellationException) {
        if (submitted && !rejected) withContext(NonCancellable) {
            try { withTimeout(15_000) { verify(1) } } catch (_: Exception) { /* 保留已提交记录，后续仅只读恢复。 */ }
        }
        throw error
    }
}
