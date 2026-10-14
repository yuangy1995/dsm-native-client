package io.github.qwertyuiop1995.dsmnativeclient.data.nas

import io.github.qwertyuiop1995.dsmnativeclient.domain.*
import kotlinx.serialization.json.*

internal suspend fun NasPackageRepository.preferences(): NasPackagePreferences = exclusive { readPreferences() }
internal suspend fun NasPackageRepository.readPreferences(): NasPackagePreferences {
    val data = gateway.call(PACKAGE_SETTINGS, "get", 1)
    val volumes = packageVolumes(data["volume_list"])
    val packages = gateway.call(PACKAGE_API, "list", 2, mapOf("offset" to JsonPrimitive(0), "limit" to JsonPrimitive(1000),
        "additional" to packageStrings(listOf("silent_upgrade", "autoupdate", "status"))))
    val seen = mutableSetOf<String>()
    val updates = packageRows(packages, "packages", bounded = true).map { row ->
        val id = row.packageText("id"); if (!seen.add(id)) packageFailure()
        val info = row["additional"].packageObject()
        for (key in listOf("autoupdate", "autoupdate_important", "silent_upgrade")) {
            if (info[key] != null && info[key] !is JsonNull && info[key].packageBoolean() == null) packageFailure()
        }
        for (key in listOf("status", "limit_type")) if (info[key] != null && info[key] !is JsonNull && info[key].packageString() == null) packageFailure()
        val latest = info["autoupdate"].packageBoolean(); val important = info["autoupdate_important"].packageBoolean()
        val policy = when { latest == true -> NasPackageUpdatePolicy.LATEST; latest == null || important == null -> null
            important -> NasPackageUpdatePolicy.IMPORTANT; else -> NasPackageUpdatePolicy.MANUAL }
        NasPackageUpdatePreference(id, row.packageText("name"), info["silent_upgrade"].packageBoolean() == true &&
            (info["status"].packageString() != "version_limit" || info["limit_type"].packageString() !in setOf("non", "system")), policy)
    }.sortedBy { it.id }
    val automatic = data.packageFlag("enable_autoupdate"); val latest = data.packageFlag("autoupdateall"); val important = data.packageFlag("autoupdateimportant")
    val volume = data["default_vol"]?.takeUnless { it is JsonNull }?.let { it.packageString() ?: packageFailure() }.orEmpty()
    return NasPackagePreferences(data.packageFlag("update_channel"), data.packageFlag("enable_email"), data.packageFlag("enable_dsm"),
        when { !automatic -> NasPackageUpdatePolicy.MANUAL; latest -> NasPackageUpdatePolicy.LATEST; important -> NasPackageUpdatePolicy.IMPORTANT; else -> NasPackageUpdatePolicy.SELECTED },
        volume.takeUnless { it == "no_default_vol" }.orEmpty(), volumes, updates)
}
internal suspend fun NasPackageRepository.savePreferences(id: String, original: NasPackagePreferences, desired: NasPackagePreferences,
    observer: NasPackageObserver): NasPackagePreferences = exclusive {
    requireIdle()
    if (readPreferences() != original || desired.volumes != original.volumes ||
        desired.defaultVolume.isNotEmpty() && desired.volumes.none { it.id == desired.defaultVolume } ||
        original.packages.map { it.id } != desired.packages.map { it.id }) packageFailure(NasPackageProblem.CHANGED)
    for ((before, after) in original.packages.zip(desired.packages)) {
        if (before.copy(policy = after.policy) != after || !before.automaticAllowed && before.policy != after.policy ||
            desired.policy == NasPackageUpdatePolicy.SELECTED && after.policy in setOf(null, NasPackageUpdatePolicy.SELECTED)) packageFailure(NasPackageProblem.CHANGED)
    }
    if (desired == original) return@exclusive original
    val parameters = mutableMapOf<String, JsonElement>("update_channel" to JsonPrimitive(if (desired.beta) "beta" else "stable"),
        "enable_email" to JsonPrimitive(desired.email), "enable_dsm" to JsonPrimitive(desired.desktop),
        "enable_autoupdate" to JsonPrimitive(desired.policy != NasPackageUpdatePolicy.MANUAL),
        "autoupdateall" to JsonPrimitive(desired.policy == NasPackageUpdatePolicy.LATEST), "autoupdateimportant" to JsonPrimitive(desired.policy == NasPackageUpdatePolicy.IMPORTANT))
    if (desired.defaultVolume != original.defaultVolume) parameters["default_vol"] = JsonPrimitive(desired.defaultVolume.ifEmpty { "no_default_vol" })
    if (desired.policy == NasPackageUpdatePolicy.SELECTED) {
        parameters["packages"] = JsonPrimitive(packageStrings(desired.packages.filter { it.policy == NasPackageUpdatePolicy.LATEST }.map { it.id }).toString())
        parameters["packages_important"] = JsonPrimitive(packageStrings(desired.packages.filter { it.policy == NasPackageUpdatePolicy.IMPORTANT }.map { it.id }).toString())
    }
    preferenceWrite(id, NasPackageWriteStep.SETTINGS, PACKAGE_SETTINGS, "set", parameters, observer) {
        readPreferences().also { if (!it.matches(desired)) packageFailure(NasPackageProblem.UNKNOWN) }
    }
}
internal fun NasPackagePreferences.matches(expected: NasPackagePreferences): Boolean {
    if (copy(volumes = expected.volumes, packages = expected.packages) != expected) return false
    if (expected.policy != NasPackageUpdatePolicy.SELECTED) return true
    return expected.packages.all { wanted -> packages.any { it.id == wanted.id && it.policy == wanted.policy } } &&
        packages.filter { actual -> expected.packages.none { it.id == actual.id } }.all { it.policy == NasPackageUpdatePolicy.MANUAL }
}
internal suspend fun NasPackageRepository.sources(): List<NasPackageSource> = exclusive { readSources() }
internal suspend fun NasPackageRepository.readSources(): List<NasPackageSource> {
    val rows = packageRows(gateway.call(PACKAGE_FEED, "list", 1), "items").map { NasPackageSource(it.packageText("name"), it.packageText("feed")) }.sortedBy { it.url }
    if (rows.map { it.url }.distinct().size != rows.size) packageFailure()
    return rows
}
internal suspend fun NasPackageRepository.saveSource(id: String, original: NasPackageSource?, desired: NasPackageSource?, observer: NasPackageObserver): List<NasPackageSource> = exclusive {
    requireIdle()
    val target = desired?.let(::normalizedPackageSource)
    if (target == null && original == null) packageFailure(NasPackageProblem.CHANGED)
    val current = readSources()
    if (original != null && original !in current) packageFailure(NasPackageProblem.CHANGED)
    if (target != null && current.any { (it.url == target.url || it.name == target.name) && it.url != original?.url }) packageFailure(NasPackageProblem.DUPLICATE_SOURCE)
    if (target == original) return@exclusive current
    val method = if (target == null) "delete" else if (original == null) "add" else "set"
    val list = if (target == null) packageStrings(listOf(requireNotNull(original).url)) else buildJsonObject {
        put("name", target.name); put("feed", target.url); original?.let { put("orifeed", it.url) }
    }
    preferenceWrite(id, NasPackageWriteStep.SOURCE, PACKAGE_FEED, method, mapOf("list" to JsonPrimitive(list.toString())), observer) {
        readSources().also { actual ->
            if (target != null && target !in actual || original != null && original.url != target?.url && actual.any { it.url == original.url }) packageFailure(NasPackageProblem.UNKNOWN)
        }
    }
}
private suspend fun <T> NasPackageRepository.preferenceWrite(id: String, step: NasPackageWriteStep, api: String, method: String,
    parameters: Map<String, JsonElement>, observer: NasPackageObserver, readback: suspend () -> T): T {
    var sent = false; var accepted = false
    val event = NasPackageCheckpoint(id, step, NasPackageWriteStage.WILL_SUBMIT)
    try {
        write(api, method, parameters, event) { checkpoint ->
            observer(checkpoint)
            if (checkpoint.stage == NasPackageWriteStage.WILL_SUBMIT) { sent = true; preferencePending = true }
            if (checkpoint.stage == NasPackageWriteStage.ACCEPTED) accepted = true
        }
        val actual = readback()
        notify(event.copy(stage = NasPackageWriteStage.VERIFIED), observer)
        preferencePending = false
        return actual
    } catch (error: Exception) {
        if (sent && !accepted && error.packageRejection()) {
            notify(event.copy(stage = NasPackageWriteStage.REJECTED), observer); preferencePending = false
        }
        throw error
    }
}
