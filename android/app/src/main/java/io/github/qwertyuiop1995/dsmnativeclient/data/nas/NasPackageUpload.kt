package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.data.UploadSource
import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import java.util.UUID
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.serialization.json.*

internal suspend fun NasPackageRepository.upload(source: UploadSource, observer: NasPackageObserver): NasPackageProgress = exclusive {
    requireIdle()
    if (!source.displayName.endsWith(".spk", ignoreCase = true) || source.contentLength <= 0) packageFailure(NasPackageProblem.INVALID_FILE)
    gateway.requireWriteAccess()
    val id = UUID.randomUUID().toString()
    val event = NasPackageCheckpoint(id, NasPackageWriteStep.UPLOAD, NasPackageWriteStage.WILL_SUBMIT)
    notify(event, observer)
    currentCoroutineContext().ensureActive()
    val checked = try { gateway.upload(source) } catch (error: Exception) {
        if (error.packageRejection()) notify(event.copy(stage = NasPackageWriteStage.REJECTED), observer)
        throw error
    }
    notify(event.copy(stage = NasPackageWriteStage.ACCEPTED), observer)
    val installed = installed()
    val packageId = checked.packageMetadata("id").packageString()?.takeIf { it.isNotBlank() } ?: packageFailure()
    val version = checked.packageMetadata("version").packageString()?.takeIf { it.isNotBlank() } ?: packageFailure()
    val previous = installed.singleOrNull { it.id == packageId }?.version
    val entry = NasPackageEntry(packageId, checked.packageMetadata("name").packageString() ?: packageFailure(), version,
        checked.packageMetadata("description").packageString().orEmpty(), installedVersion = previous, updateAvailable = previous != null && previous != version)
    val current = PackageJob(id, listOf(PackageCandidate(entry, checked)), listOf(NasPackageInstallItem(entry, emptyList(), "")), emptyMap(), true, observer, manual = true)
    current.checked = checked; current.submittedStep = NasPackageWriteStep.UPLOAD; job = current
    try {
        current.configuration = configuration(checked, entry)
        notify(current.event(NasPackageWriteStep.UPLOAD, NasPackageWriteStage.PREPARED), observer)
        current.phase = NasPackageInstallPhase.OPTIONS
        current.progress
    } catch (error: Exception) {
        if (error is NasPackageFailure && error.problem in setOf(NasPackageProblem.SIGNATURE, NasPackageProblem.CUSTOM_OPTIONS)) {
            cleanPackage(current); current.phase = NasPackageInstallPhase.FAILED; current.problem = error.problem
        } else { current.phase = NasPackageInstallPhase.UNKNOWN; current.problem = NasPackageProblem.UNKNOWN }
        throw error
    }
}
internal suspend fun NasPackageRepository.configuration(checked: JsonObject, expected: NasPackageEntry): NasPackageConfiguration {
    if (checked["codesign_error"] != null && checked["codesign_error"] !is JsonNull) packageFailure(NasPackageProblem.SIGNATURE)
    if (checked.packageMetadata("id").packageString() != expected.packageId || checked.packageMetadata("version").packageString() != expected.version ||
        checked["errmsg"] != null && checked["errmsg"].packageString() != "") packageFailure()
    feasibility(listOf(expected.packageId))
    val settings = gateway.call(PACKAGE_SETTINGS, "get", 1, mapOf("option" to JsonPrimitive(
        if (checked.packageMetadata("install_on_cold_storage").packageBoolean() == true) "include_cold_storage" else "")))
    val default = gateway.call("SYNO.Core.Package.Setting.Volume", "get", 1)
    val volumes = packageVolumes(settings["volume_list"])
    val restart = checked.packageMetadata("install_reboot").packageBoolean() == true
    return NasPackageConfiguration(expected.name, expected.version, checked.packageMetadata("licence").packageString()?.takeIf { it.isNotEmpty() },
        packageFields(checked.packageMetadata("install_pages")), volumes, default["default_vol"].packageString() ?: volumes.singleOrNull()?.id.orEmpty(),
        checked.packageMetadata("startable").packageBoolean() == true && !restart, restart)
}
